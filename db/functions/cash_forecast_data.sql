CREATE OR REPLACE FUNCTION public.cash_forecast_data(p_week_start date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ws        date;
    v_end       date;
    v_asof      date;
    v_base      text;
    v_raw       jsonb;
    v_opening   jsonb;
    v_lines     jsonb;
    v_undated   jsonb;
    v_promises  jsonb;
    v_buckets   jsonb;
    v_buffer    jsonb;
    v_ccys      text[];
    v_missing   text[] := '{}';
    c           text;
    v_dummy     numeric;
BEGIN
    PERFORM require_permission('module.finance.view');

    v_ws := COALESCE(p_week_start, date_trunc('week', CURRENT_DATE)::date);
    IF v_ws <> date_trunc('week', v_ws)::date THEN
        RAISE EXCEPTION 'FORECAST_WEEK_START_NOT_MONDAY|%', v_ws::text;
    END IF;
    v_end  := v_ws + 91;                      -- 13 周,右开
    -- 【仓位读到哪一天】期初与 AR/AP 的仓位取【预测开始的前一天】;
    -- 而 ar/ap_aging_asof 拒绝未来的截至日(AGING_AS_OF_FUTURE),
    -- 所以往前推的那一份最多读到今天 —— 一份"从下周起"的预测,
    -- 它的期初就是今天的期初,而这是诚实的:未来的仓位没人知道。
    v_asof := LEAST(v_ws - 1, CURRENT_DATE);
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══ 期初:每个现金账户按【它自己的币种】════════════════════════════════
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_code', a.code,
               'account_name', a.name_en,
               'currency',     bank_native_currency(a.code),
               'amount',       bank_book_balance_asof(a.code, v_asof)
           ) ORDER BY a.code), '[]'::jsonb)
      INTO v_opening
      FROM accounts a WHERE a.is_cash;

    -- ══ 所有候选行(日期可能是 NULL —— 那正是要说出来的那一半)═══════════
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.due NULLS LAST, r.source, r.label), '[]'::jsonb)
      INTO v_raw
      FROM (
        -- AR:开了票的才有到期日,而到期日来自发票(实测 6/9 有)
        SELECT 'ar'::text AS source, 'committed'::text AS confidence, 'in'::text AS direction,
               e->>'currency' AS currency, (e->>'open_ccy')::numeric AS amount,
               NULLIF(e->>'due_date','')::date AS due,
               COALESCE(e->>'customer_name','?') AS label,
               COALESCE(e->>'invoice_code', e->>'doc_code') AS ref,
               NULL::text AS owner_name
          FROM jsonb_array_elements((ar_aging_asof(v_asof))->'rows') e
        UNION ALL
        -- AP:实测 0/13 有到期日 —— 整块落进"无日期"
        SELECT 'ap', 'committed', 'out',
               e->>'currency', (e->>'open_ccy')::numeric,
               NULLIF(e->>'due_date','')::date,
               COALESCE(e->>'supplier_name','?'), e->>'doc_code', NULL
          FROM jsonb_array_elements((ap_aging_asof(v_asof))->'rows') e
        UNION ALL
        -- PO 分期:五种事件,三种是估计、两种是事实
        SELECT 'po_instalment',
               CASE WHEN t.trigger_event IN ('fixed_date','on_order') THEN 'committed'
                    ELSE 'estimated' END,
               'out', po.currency,
               COALESCE(t.fixed_amount_ccy,
                        round(COALESCE(po.estimated_total_ccy,0) * COALESCE(t.percentage,0) / 100.0, 2)),
               CASE t.trigger_event WHEN 'fixed_date' THEN t.due_date
                                    WHEN 'on_order'   THEN po.order_date
                                    ELSE t.expected_date END,
               po.code || ' · ' || COALESCE(NULLIF(t.label,''), t.trigger_event),
               po.code, o.owner_name
          FROM purchase_order_payment_terms t
          JOIN purchase_orders po ON po.id = t.purchase_order_id
          LEFT JOIN payment_event_owners o ON o.trigger_event = t.trigger_event
         WHERE po.deleted_at IS NULL AND po.status IN ('confirmed','receiving')
        UNION ALL
        -- 工资:payment_date 是一个承诺
        SELECT 'payroll', 'committed', 'out', pp.currency,
               COALESCE(pp.net_pay_total,0) + COALESCE(pp.employer_cpf_total,0),
               pp.payment_date, 'Payroll ' || pp.code, pp.code, NULL
          FROM payroll_periods pp WHERE pp.deleted_at IS NULL
        UNION ALL
        -- 手工行,按 cadence 展开成一次次发生
        SELECT 'manual', 'manual', l.direction, l.currency, l.amount_ccy,
               occ.d::date, l.label, NULL, NULL
          FROM cash_forecast_lines l
          CROSS JOIN LATERAL generate_series(
                 l.start_date::timestamp,
                 LEAST(COALESCE(l.end_date, v_end), v_end)::timestamp,
                 CASE l.cadence WHEN 'weekly'    THEN interval '7 days'
                                WHEN 'monthly'   THEN interval '1 month'
                                WHEN 'quarterly' THEN interval '3 months'
                                WHEN 'annual'    THEN interval '1 year'
                                ELSE interval '1000 years' END) occ(d)
         WHERE l.is_active
      ) r;

    -- ══ 落得进 13 周的行 ═══════════════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(e || jsonb_build_object(
               'week_no', ((e->>'due')::date - v_ws) / 7 + 1)
           ORDER BY (e->>'due')::date, e->>'source'), '[]'::jsonb)
      INTO v_lines
      FROM jsonb_array_elements(v_raw) e
     WHERE e->>'due' IS NOT NULL
       AND (e->>'due')::date >= v_ws AND (e->>'due')::date < v_end
       AND (e->>'amount')::numeric <> 0;

    -- ══ ★【有钱、但落不进任何一周的那些】★ ════════════════════════════════
    -- 这是 4.5 那一条做成【结构】而不是脚注:一份悄悄漏掉大半应付的预测,
    -- 是一个会被人当真的数字。所以它们【出现在预测上】,只是拒绝被放进某一周。
    SELECT COALESCE(jsonb_agg(x ORDER BY x.source, x.currency), '[]'::jsonb)
      INTO v_undated
      FROM (
        SELECT e->>'source' AS source, e->>'direction' AS direction,
               e->>'currency' AS currency,
               count(*)::int AS row_count,
               round(sum((e->>'amount')::numeric), 2) AS amount,
               CASE WHEN e->>'due' IS NULL THEN 'no_date' ELSE 'before_window' END AS why,
               max(e->>'owner_name') AS owner_name
          FROM jsonb_array_elements(v_raw) e
         WHERE (e->>'amount')::numeric <> 0
           AND (e->>'due' IS NULL OR (e->>'due')::date < v_ws)
         GROUP BY 1,2,3,6
      ) x;

    -- ══ 客户承诺:【备查,不计入合计】═══════════════════════════════════════
    -- 一个承诺与它指向的那几张 AR 是【同一笔钱】,而 CHASE-1 实测过:
    -- 9 行未结 AR 里 8 行是未开票的销售,连一个客户认得的单号都没有 ——
    -- 系统【说不出】一个承诺覆盖的是哪几行。加进合计就是重复计算,
    -- 不放又丢掉了全系统唯一"客户自己答应过"的日期。所以:列出来,不求和。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'promise_id', ps.promise_id, 'chase_code', ps.chase_code,
               'customer_name', ps.customer_name,
               'currency', ps.currency, 'amount', ps.promised_amount_ccy,
               'promised_date', ps.promised_date,
               'week_no', (ps.promised_date - v_ws) / 7 + 1,
               'is_overdue', ps.is_overdue) ORDER BY ps.promised_date), '[]'::jsonb)
      INTO v_promises
      FROM collection_promise_status ps
     WHERE ps.is_open AND ps.promised_date >= v_ws AND ps.promised_date < v_end;

    -- ══ 币种集合:期初里出现的 ∪ 明细里出现的 ═════════════════════════════
    SELECT array_agg(DISTINCT c2 ORDER BY c2) INTO v_ccys FROM (
        SELECT e->>'currency' AS c2 FROM jsonb_array_elements(v_opening) e
        UNION SELECT e->>'currency' FROM jsonb_array_elements(v_lines) e
    ) q WHERE c2 IS NOT NULL;

    -- ══ 分周分币种的桶,带滚动期末 ═════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', b.currency, 'week_no', b.week_no,
               'week_start', b.wstart, 'week_end', b.wstart + 6,
               'inflow', b.inflow, 'outflow', b.outflow, 'net', b.net,
               'closing', b.closing) ORDER BY b.currency, b.week_no), '[]'::jsonb)
      INTO v_buckets
      FROM (
        SELECT cc.currency, w.week_no, v_ws + (w.week_no - 1) * 7 AS wstart,
               COALESCE(agg.inflow, 0)  AS inflow,
               COALESCE(agg.outflow, 0) AS outflow,
               COALESCE(agg.inflow, 0) - COALESCE(agg.outflow, 0) AS net,
               op.open0 + sum(COALESCE(agg.inflow,0) - COALESCE(agg.outflow,0))
                   OVER (PARTITION BY cc.currency ORDER BY w.week_no) AS closing
          FROM unnest(COALESCE(v_ccys, '{}')) AS cc(currency)
          CROSS JOIN generate_series(1, 13) AS w(week_no)
          LEFT JOIN LATERAL (
                SELECT COALESCE(round(sum(CASE WHEN e->>'direction'='in'  THEN (e->>'amount')::numeric END),2),0) AS inflow,
                       COALESCE(round(sum(CASE WHEN e->>'direction'='out' THEN (e->>'amount')::numeric END),2),0) AS outflow
                  FROM jsonb_array_elements(v_lines) e
                 WHERE e->>'currency' = cc.currency AND (e->>'week_no')::int = w.week_no
          ) agg ON true
          LEFT JOIN LATERAL (
                SELECT COALESCE(round(sum((e->>'amount')::numeric),2),0) AS open0
                  FROM jsonb_array_elements(v_opening) e WHERE e->>'currency' = cc.currency
          ) op ON true
      ) b;

    -- ══ 固定 OPEX 与覆盖月数(KPI T2)═══════════════════════════════════════
    -- 【固定 OPEX = 经常性的那些,不含 once】一笔一次性的设备尾款不是 OPEX,
    -- 把它算进去会让覆盖月数随便一条一次性录入就跳一下。
    -- 【覆盖月数按【预测低点】,并把今天的一起列出】T2 的原话是"最低现金储备"
    -- 与"任何【预计】的突破",指的是谷底而不是今天 —— 只量今天,会在预测说
    -- 你第 9 周就见底的那一周,报告一个宽裕的缓冲。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', z.currency,
               'monthly_fixed_opex', z.opex,
               'opening', z.open0,
               'projected_min', z.pmin,
               'months_cover_today', CASE WHEN z.opex > 0 THEN round(z.open0 / z.opex, 1) END,
               'months_cover_min',   CASE WHEN z.opex > 0 THEN round(z.pmin  / z.opex, 1) END
           ) ORDER BY z.currency), '[]'::jsonb)
      INTO v_buffer
      FROM (
        SELECT cc.currency,
               COALESCE((SELECT round(sum(
                     CASE l.cadence WHEN 'weekly'    THEN l.amount_ccy * 52.0 / 12.0
                                    WHEN 'monthly'   THEN l.amount_ccy
                                    WHEN 'quarterly' THEN l.amount_ccy / 3.0
                                    WHEN 'annual'    THEN l.amount_ccy / 12.0 END), 2)
                   FROM cash_forecast_lines l
                  WHERE l.is_active AND l.direction = 'out' AND l.cadence <> 'once'
                    AND l.currency = cc.currency), 0) AS opex,
               COALESCE((SELECT round(sum((e->>'amount')::numeric),2) FROM jsonb_array_elements(v_opening) e
                          WHERE e->>'currency' = cc.currency), 0) AS open0,
               COALESCE((SELECT min((e->>'closing')::numeric) FROM jsonb_array_elements(v_buckets) e
                          WHERE e->>'currency' = cc.currency), 0) AS pmin
          FROM unnest(COALESCE(v_ccys, '{}')) AS cc(currency)
      ) z;

    -- ══ 有没有一个【跨币种的合计】可谈 ═════════════════════════════════════
    -- 实测:今天 USD 折不出 SGD。所以这里【逐个币种去问那支函数】,
    -- 问不出来的记下来 —— 屏幕上那一格因此是"一个有名字的缺席",不是 0。
    FOREACH c IN ARRAY COALESCE(v_ccys, '{}') LOOP
        IF c <> v_base THEN
            BEGIN
                v_dummy := fx_rate_for(c, v_asof, 'mid');
            EXCEPTION WHEN OTHERS THEN
                v_missing := v_missing || c;
            END;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'week_start',    v_ws,
        'week_end',      v_end - 1,
        'horizon_weeks', 13,
        'as_of',         v_asof,
        'base_currency', v_base,
        'currencies',    COALESCE(to_jsonb(v_ccys), '[]'::jsonb),
        'opening',       v_opening,
        'lines',         v_lines,
        'buckets',       v_buckets,
        'undated',       v_undated,
        'promises_memo', v_promises,
        'buffer',        v_buffer,
        -- 【能不能给一个跨币种合计】以及【为什么不能】
        'base_total_available',  (array_length(v_missing, 1) IS NULL),
        'base_total_missing_fx', COALESCE(to_jsonb(v_missing), '[]'::jsonb)
    );
END;
$function$

;

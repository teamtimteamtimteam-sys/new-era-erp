-- db/functions/ap_aging_asof.sql
-- AGING-1(2026-08-27):AP 账龄【截至某一天】。
--
-- 【为什么是函数不是视图】视图接不了参数,而 ap_open_items 把 CURRENT_DATE 焊在
-- 视图体里。但"截至"不止这一层 —— 完整的四层写在函数注释与
-- db/migrations/2026-08-27-aging1-as-at-a-date.sql 的抬头里:
--   ① 视图接不了参数 ② 结清额按付款日回推 ③ 单据在那天存在不存在 ④ 金额在那天是多少
--
-- 【p_as_of 默认今天,并且【等于今天时逐行复现 ap_open_items】】
-- db/fixtures/135 的 A 臂两个方向的差集都断言为空 —— 一次悄悄改变了当前数字的
-- 重构是这里能出的最坏结果,所以它由测量钉住,不由声明保证。
--
-- 【一处刻意的分歧】单据日期晚于 D 的单据本函数不收,而 ap_open_items 的进料支
-- 没有日期过滤、会收。fixture 135 的 H 臂把它变成一条被断言的行为。
--
-- NOTE: introduced by db/migrations/2026-08-27-aging1-as-at-a-date.sql.

CREATE OR REPLACE FUNCTION public.ap_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of    date;
    v_today    date := CURRENT_DATE;
    v_start    date;
    v_base     text;
    v_rows     jsonb;
    v_buckets  jsonb;
    v_total    numeric;
    v_unpriced integer;
BEGIN
    -- 没有财务模块 → 【按名拒绝】,不是 0 行。两张老视图给的是 0 行
    -- (视图没有别的表达方式),而 0 行在页面上读作「没有未结单据」——
    -- 一句假话。函数有更好的表达方式,就该用。
    PERFORM require_permission('module.finance.view');

    -- 只读查询的"截至哪天",默认今天 —— 与 leave_balance / accrued_annual_leave
    -- 一族同一个惯用法,并已记在 docs/empty-string-to-rpc-audit.md 的白名单里。
    -- 【它不是那条"不许给日期默认值"的规矩的例外,是那条规矩的射程之外】:
    -- 那条管的是决定汇率、期间、金额的【写入】日期,而这里什么都不写。
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.doc_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:已计价、在册的进料批次 ────────────────────────────────
        SELECT 'inbound'::text                                   AS doc_kind,
               ib.id                                             AS doc_id,
               ib.code                                           AS doc_code,
               ib.id                                             AS inbound_batch_id,
               ib.supplier_id                                    AS supplier_id,
               sup.legal_name                                    AS supplier_name,
               COALESCE(ib.arrival_date, ib.created_at::date)    AS doc_date,
               NULL::date                                        AS due_date,
               round(ib.quantity * pr.price, 2)                  AS doc_value_base,
               round(COALESCE(s.settled, 0) + COALESCE(pp.applied, 0), 2) AS settled_base,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_base,
               v_base                                            AS currency,
               round(round(ib.quantity * pr.price, 2)
                     - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2) AS open_ccy,
               (v_as_of - COALESCE(ib.arrival_date, ib.created_at::date))   AS days_outstanding,
               aging_bucket(v_as_of - COALESCE(ib.arrival_date, ib.created_at::date)) AS bucket,
               'supplier'::text                                  AS counterparty_kind,
               ib.supplier_id                                    AS counterparty_id,
               sup.legal_name                                    AS counterparty_name
          FROM inbound_batches_masked ib
          JOIN suppliers sup ON sup.id = ib.supplier_id
          -- 价格:D 那天的价,再套上与 inbound_batches_masked.unit_price
          -- 【逐字同源】的那道 data.view_prices 遮罩(见抬头)。
          CROSS JOIN LATERAL (
                SELECT CASE WHEN has_permission('data.view_prices')
                            THEN inbound_unit_price_asof(ib.id, v_as_of)
                       END AS price
          ) pr
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.inbound_batch_id = ib.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_base) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.inbound_batch_id = ib.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND pr.price IS NOT NULL

        UNION ALL

        -- ── 支二:挂账开支 ─────────────────────────────────────────────
        SELECT 'expense'::text, e.id, e.code, NULL::uuid,
               e.supplier_id, sup.legal_name,
               e.expense_date, NULL::date,
               e.amount_base,
               round((COALESCE(s.settled, 0) + COALESCE(pp.applied, 0)) * e.fx_rate, 2),
               round((e.amount_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0)) * e.fx_rate, 2),
               e.currency,
               round(e.amount_ccy - COALESCE(s.settled, 0) - COALESCE(pp.applied, 0), 2),
               (v_as_of - e.expense_date),
               aging_bucket(v_as_of - e.expense_date),
               CASE WHEN e.employee_id IS NOT NULL THEN 'employee' ELSE 'supplier' END::text,
               COALESCE(e.supplier_id, e.employee_id),
               COALESCE(sup.legal_name, emp.legal_name)
          FROM expenses e
          LEFT JOIN suppliers sup ON sup.id = e.supplier_id
          LEFT JOIN employees emp ON emp.id = e.employee_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.expense_id = e.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT sum(ppa.amount_ccy) AS applied
                  FROM prepayment_applications_masked ppa
                  LEFT JOIN journal_entries je ON je.id = ppa.journal_entry_id
                 WHERE ppa.expense_id = e.id
                   AND COALESCE(je.entry_date, ppa.created_at::date) <= v_as_of
          ) pp ON true
         WHERE e.expense_date <= v_as_of
           -- 【为什么 payment_status 这个"现在"的标志还留着,而且必须留着】
           -- 实测:EXP-2026-0002 与 EXP-2026-0005 是 payment_status='paid' 却
           -- 【一条核销行都没有】—— 它们是当场付掉的,那笔钱根本不走 allocation。
           -- 所以"已付"在这套系统里【推导不出来】,只有那个标志说得出来。
           -- 于是判据写成:今天还挂着账 【或者】 它的结清发生在 D 【之后】。
           -- D = 今天时,后半永远为假(没有晚于今天的收付款 —— 实测 0 笔),
           -- 于是它逐字退化成今天那张视图的 `payment_status='unpaid'`。
           -- 这就是"默认今天等于今天的行为"在这一支上的落点。
           AND (e.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.expense_id = e.id AND p2.payment_date > v_as_of)
                OR EXISTS (SELECT 1 FROM prepayment_applications ppa2
                             LEFT JOIN journal_entries je2 ON je2.id = ppa2.journal_entry_id
                            WHERE ppa2.expense_id = e.id
                              AND COALESCE(je2.entry_date, ppa2.created_at::date) > v_as_of))
           -- 单据在 D 那天【站着没有】:今天 posted 的站着;今天是 reversed 的,
           -- 若那次冲销发生在 D 之后,它在 D 那天也是站着的。
           AND (e.status = 'posted'
                OR (e.status = 'reversed'
                    AND (SELECT m.expense_date FROM expenses m
                          WHERE m.id = e.reversed_by_expense) > v_as_of))
           -- 镜像行照旧排除(它是冲销的记账凭证,不是一张新的应付单)
           AND NOT EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = e.id)

        UNION ALL

        -- ── 支三:未付运费单 ───────────────────────────────────────────
        SELECT 'freight'::text, fd.id, fd.code, NULL::uuid,
               fd.supplier_id, sup.legal_name,
               fd.doc_date, NULL::date,
               fd.amount_base,
               round(COALESCE(s.settled, 0) * fd.fx_rate, 2),
               round((fd.amount_ccy - COALESCE(s.settled, 0)) * fd.fx_rate, 2),
               fd.currency,
               round(fd.amount_ccy - COALESCE(s.settled, 0), 2),
               (v_as_of - fd.doc_date),
               aging_bucket(v_as_of - fd.doc_date),
               'supplier'::text, fd.supplier_id, sup.legal_name
          FROM freight_documents fd
          JOIN suppliers sup ON sup.id = fd.supplier_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.freight_document_id = fd.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
         WHERE fd.doc_date <= v_as_of
           AND (fd.deleted_at IS NULL OR fd.deleted_at::date > v_as_of)
           AND (fd.payment_status = 'unpaid'
                OR EXISTS (SELECT 1 FROM payment_allocations pa2
                             JOIN payments p2 ON p2.id = pa2.payment_id
                            WHERE pa2.freight_document_id = fd.id AND p2.payment_date > v_as_of))
           -- 运费单的冲销日:优先取【冲销分录的分录日】(那是业务日),
           -- 取不到才退回 reversed_at 的录入时刻。与 reverse_freight_document
           -- 用 CURRENT_DATE 立那张冲销分录逐字对应。
           AND (fd.status = 'posted'
                OR (fd.status = 'reversed'
                    AND COALESCE((SELECT je.entry_date FROM journal_entries je
                                   WHERE je.id = fd.reversal_entry_id),
                                 fd.reversed_at::date) > v_as_of))
      ) x
     WHERE x.open_ccy > 0;

    -- 档位合计:四档【一档不落】,没有的那一档是 0 而不是缺席 ——
    -- 一个缺席的键在页面上会渲染成空白,读起来像"没算出来"。
    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0))
      INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_rows) e
             WHERE e->>'bucket' = b.bucket
      ) agg ON true;

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0)
      INTO v_total FROM jsonb_array_elements(v_rows) e;

    -- 【被"那天还没有价"挡掉的批次有几张】—— 一个缺席要说得出数目,
    -- 否则它与"本来就没有这笔应付"在屏幕上长得一模一样。
    -- 没有 data.view_prices 时这个数是 NULL 而不是 0:那不是"零张",
    -- 是"你看不到这一栏",与价格本身遮成 NULL 同一个道理。
    IF has_permission('data.view_prices') THEN
        SELECT count(*) INTO v_unpriced
          FROM inbound_batches ib
         WHERE (ib.deleted_at IS NULL OR ib.deleted_at::date > v_as_of)
           AND COALESCE(ib.arrival_date, ib.created_at::date) <= v_as_of
           AND inbound_unit_price_asof(ib.id, v_as_of) IS NULL;
    ELSE
        v_unpriced := NULL;
    END IF;

    RETURN jsonb_build_object(
        'side',                'ap',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- 机器令牌,不是给人读的句子 —— 双语措辞留在 messages/,按语言选一条。
        'amount_basis',        'quantity_now_price_asof',
        'unpriced_excluded',   v_unpriced,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ap_aging_asof(date) IS
    'AGING-1:AP 账龄【截至某一天】。视图接不了参数,而"截至"有四层而不是一层:① CURRENT_DATE 焊在视图体里;② 结清额要按付款日回推(晚于 D 的付款不算);③ 单据在 D 那天站着没有(D 之后的冲销/删除不回溯);④ 金额在 D 那天是多少(单价按 price_history 回推 —— 实测 2026-07-05 之前九张在开批次全部无价)。数量没有历史表,所以金额 = 今天的数量 × D 那天的价,由 amount_basis 明说。未来日期按名拒 AGING_AS_OF_FUTURE。截止日早于 system_start_date 不拒绝,返回 before_system_start 由页面与 CSV 各说一句(方向是把欠款报多)。p_as_of 默认今天,且【等于今天时逐行复现今天那张视图】—— db/fixtures/135 的 A 臂钉住。';
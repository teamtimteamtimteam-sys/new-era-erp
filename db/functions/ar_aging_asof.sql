-- db/functions/ar_aging_asof.sql
-- AGING-1(2026-08-27):AR 账龄【截至某一天】。两支:直接销售记录 + 订单流发票。
--
-- 【第二支把 order_invoice_balance_all 的算术抄了下来,而不是引用它】
-- 那张视图算的是"现在":已结只认 posted 收款、已贷记不问贷项日、发票在不在只看
-- status。三处都要按 D 回推,而【视图接不了参数】—— 这正是本刀存在的理由本身,
-- 在第二支上再出现一次。**两处注释互指:一边改了,另一边必须跟着改。**
--
-- 【到期日只是一列,档位仍按单据日】实测 invoices.due_date 6/6 已填,而供应商
-- 0/8、客户 0/3 填了账期 —— 让一份报表里一支的"账龄"意思是"逾期"、另外四支是
-- "开出至今",比整份都不精确更坏。Tim 2026-08-27 裁定。
--
-- NOTE: introduced by db/migrations/2026-08-27-aging1-as-at-a-date.sql.

CREATE OR REPLACE FUNCTION public.ar_aging_asof(p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_as_of   date;
    v_today   date := CURRENT_DATE;
    v_start   date;
    v_base    text;
    v_rows    jsonb;
    v_buckets jsonb;
    v_total   numeric;
BEGIN
    PERFORM require_permission('module.finance.view');
    v_as_of := COALESCE(p_as_of, v_today);

    IF v_as_of > v_today THEN
        RAISE EXCEPTION 'AGING_AS_OF_FUTURE|%|%', v_as_of, v_today;
    END IF;

    SELECT fs.system_start_date INTO v_start FROM finance_settings fs LIMIT 1;
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;

    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.sale_date, x.doc_code), '[]'::jsonb)
      INTO v_rows
      FROM (
        -- ── 支一:直接销售记录 ─────────────────────────────────────────
        SELECT sr.id                                     AS sales_record_id,
               ob.code                                   AS doc_code,
               sr.customer_id                            AS customer_id,
               c.legal_name                              AS customer_name,
               sr.sale_date                              AS sale_date,
               -- 销售支的到期日:它自己没有,但它挂着的那张【在册】发票有。
               -- 实测 invoices.due_date 6/6 已填,所以这一列在 AR 上是有内容的。
               inv.due_date                              AS due_date,
               sr.amount_base                            AS amount_base,
               sr.currency                               AS currency,
               round(sr.quantity * sr.unit_price, 2)     AS amount_ccy,
               round(COALESCE(s.settled, 0), 2)          AS settled_ccy,
               round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) AS open_ccy,
               round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base,
               (v_as_of - sr.sale_date)                  AS days_outstanding,
               aging_bucket(v_as_of - sr.sale_date)      AS bucket,
               inv.invoice_id                            AS invoice_id,
               inv.invoice_code                          AS invoice_code,
               'sale'::text                              AS doc_kind,
               round(COALESCE(s.settled, 0) * sr.fx_rate, 2) AS settled_base,
               0::numeric                                AS credited_ccy,
               0::numeric                                AS credited_base
          FROM sales_records_masked sr
          JOIN output_batches ob ON ob.id = sr.output_batch_id
          LEFT JOIN customers c ON c.id = sr.customer_id
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.sales_record_id = sr.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                SELECT i.id AS invoice_id, i.code AS invoice_code, i.due_date
                  FROM invoice_lines_masked il
                  JOIN invoices_masked i ON i.id = il.invoice_id
                 WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
                 LIMIT 1
          ) inv ON true
         WHERE sr.sale_date <= v_as_of
           AND sr.sales_order_line_id IS NULL

        UNION ALL

        -- ── 支二:订单流发票 ───────────────────────────────────────────
        -- 【为什么这里把 order_invoice_balance_all 的算术抄了下来,而不是引用它】
        -- 那张视图是"现在"的算术:已结只认 posted 收款、已贷记不问贷项日、
        -- 发票在不在只看 status。三处都要按 D 回推,而【视图接不了参数】——
        -- 这正是本刀存在的理由本身,在第二支上再出现一次。
        -- 算术本身逐列同源,任何一边改了另一边必须跟着改,两处注释互指。
        SELECT NULL::uuid, i.code, i.customer_id, c.legal_name,
               i.issue_date, i.due_date,
               round(l.amount_ccy * i.fx_rate, 2),
               i.currency, l.amount_ccy,
               round(COALESCE(s.settled, 0), 2),
               round(l.amount_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0), 2),
               round((l.amount_ccy - COALESCE(s.settled, 0) - COALESCE(cn.credited, 0)) * i.fx_rate, 2),
               (v_as_of - i.issue_date),
               aging_bucket(v_as_of - i.issue_date),
               i.id, i.code, 'invoice'::text,
               round(COALESCE(s.settled, 0) * i.fx_rate, 2),
               round(COALESCE(cn.credited, 0), 2),
               round(COALESCE(cn.credited, 0) * i.fx_rate, 2)
          FROM invoices i
          LEFT JOIN customers c ON c.id = i.customer_id
          JOIN LATERAL (
                SELECT COALESCE(sum(il.amount_ccy), 0) AS amount_ccy
                  FROM invoice_lines il WHERE il.invoice_id = i.id
          ) l ON true
          LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                  FROM payment_allocations pa
                  JOIN payments p ON p.id = pa.payment_id
                  LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
                 WHERE pa.invoice_id = i.id
                   AND p.payment_date <= v_as_of
                   AND (p.status = 'posted'
                        OR (p.status = 'reversed' AND rev.payment_date > v_as_of))
          ) s ON true
          LEFT JOIN LATERAL (
                -- 贷项凭证有自己的业务日(note_date),所以它照 D 截断,
                -- 与收款同一条:D 之后开的贷项凭证不往回渗。
                SELECT sum(cl.amount) AS credited
                  FROM credit_note_lines cl
                  JOIN credit_notes cc ON cc.id = cl.credit_note_id
                 WHERE cc.invoice_id = i.id AND cc.note_date <= v_as_of
          ) cn ON true
         WHERE i.kind = 'order'
           AND i.issue_date <= v_as_of
           -- 作废日优先取【那张冲销分录的分录日】(void_invoice 的 p_reversal_date
           -- 就是它),取不到才退回 voided_at 的录入时刻。
           AND (i.status = 'issued'
                OR (i.status = 'void'
                    AND COALESCE((SELECT r.entry_date
                                    FROM journal_entries o
                                    JOIN journal_entries r ON r.id = o.reversed_by
                                   WHERE o.id = i.entry_id),
                                 i.voided_at::date) > v_as_of))
           -- 第二支与今天那张视图同效:显式要 data.view_prices。
           -- 第一支靠 sales_records_masked 把 unit_price 遮成 NULL 自然消失,
           -- 两支对同一读者同进同退。
           AND has_permission('data.view_prices')
      ) x
     WHERE x.open_ccy > 0;

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

    RETURN jsonb_build_object(
        'side',                'ar',
        'as_of',               v_as_of,
        'today',               v_today,
        'is_past',             (v_as_of < v_today),
        'system_start_date',   v_start,
        'before_system_start', (v_start IS NOT NULL AND v_as_of < v_start),
        'base_currency',       v_base,
        -- AR 两支的金额都是【冻住的】(销售记录的量价、发票行的生成列),
        -- 没有 AP 那个"数量按今天"的近似,所以基准令牌不同。
        'amount_basis',        'amounts_as_recorded',
        'unpriced_excluded',   NULL,
        'total_open_base',     v_total,
        'buckets',             v_buckets,
        'rows',                v_rows
    );
END;
$function$;

COMMENT ON FUNCTION public.ar_aging_asof(date) IS
    'AGING-1:AR 账龄【截至某一天】。两支:直接销售记录 + 订单流发票。结清按收款日回推、贷记按 note_date 回推、发票在不在按【作废分录的分录日】回推(晚于 D 的作废不回溯)。第二支把 order_invoice_balance_all 的算术抄了下来而不是引用它 —— 那张视图是「现在」的算术且接不了参数,正是本刀存在的理由再出现一次;两处注释互指,一边改另一边必须跟着改。到期日:发票支取 invoices.due_date,销售支取它挂着的在册发票的 due_date(实测 6/6 已填);【档位仍按单据日,不按到期日】。p_as_of 默认今天,等于今天时逐行复现今天那张视图 —— db/fixtures/135 的 A 臂钉住。';
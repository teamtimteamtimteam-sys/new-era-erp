CREATE OR REPLACE FUNCTION public.customer_statement_data(p_customer_id uuid, p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        customers%ROWTYPE;
    v_base     text;
    v_open     jsonb;
    v_close    jsonb;
    v_opening  numeric;
    v_closing  numeric;
    v_charges  numeric;
    v_credits  numeric;
    v_receipts numeric;
    v_applied  numeric;
    v_onaccount numeric;
    v_lines    jsonb;
    v_byccy    jsonb;
    v_buckets  jsonb;
    v_diff     numeric;
BEGIN
    PERFORM require_permission('module.finance.view');

    SELECT * INTO v_c FROM customers WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'STATEMENT_PERIOD_REQUIRED';
    END IF;
    IF p_to < p_from THEN
        RAISE EXCEPTION 'STATEMENT_PERIOD_INVALID|%|%', p_from::text, p_to::text;
    END IF;
    -- 【未来的期末不给出】与 ar_aging_asof 的 AGING_AS_OF_FUTURE 同一条:
    -- 一份"截至下个月"的对账单不是一份对账单,是一次推测。
    IF p_to > CURRENT_DATE THEN
        RAISE EXCEPTION 'STATEMENT_PERIOD_FUTURE|%|%', p_to::text, CURRENT_DATE::text;
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 期初 = 截至【期间开始的前一天】那个客户还欠的;期末 = 截至期末。
    v_open  := ar_aging_asof(p_from - 1);
    v_close := ar_aging_asof(p_to);

    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0) INTO v_opening
      FROM jsonb_array_elements(v_open->'rows') e
     WHERE (e->>'customer_id') = p_customer_id::text;
    SELECT COALESCE(round(sum((e->>'open_base')::numeric), 2), 0) INTO v_closing
      FROM jsonb_array_elements(v_close->'rows') e
     WHERE (e->>'customer_id') = p_customer_id::text;

    -- ══ 期间内的发生额 —— 三支,全部来自基表(与上面两个数是【两份独立推导】)══
    -- 【收款的"站着没有"判据必须与 ar_aging_asof 同源】一笔在期末之后才被冲销的
    -- 收款,在期末那天是算数的。两边不同源,那条勾稽等式就会莫名其妙地对不上 ——
    -- 而它对不上的时候会 STATEMENT_DOES_NOT_TIE 按名拒,不会悄悄寄出去。
    -- ★【收款 ≠ 核销 —— 这一条是实测出来的,不是设计出来的】★
    -- 第一版把"期间内的收款"直接减进等式,而它在【七月】对不上,两个客户各差
    -- 一笔:RCPT-2026-0003(USD 2,800)与 RCPT-2026-0001(USD 250)——
    -- 两笔都是【收了钱但一行核销都没有】的挂账收款。
    -- `ar_aging_asof` 的期末是【各张单据未结额之和】,而一笔挂在账上的钱
    -- 【没有减少任何一张单据】,所以它不改变期末余额。
    -- 于是勾稽用的必须是【核销额】,不是收款额;而收款额仍然要显示 ——
    -- 客户确实付了钱,一份不提这笔钱的对账单是错的。
    --
    -- 【顺带证明了 as-at 那一半是对的】同一段期间里 RCPT-2026-0002 是
    -- 【7-30 收、7-29 冲销】,它被正确地排除在外 —— 排除它的正是下面这条
    -- 与 ar_aging_asof 同源的"在期末那天站着没有"判据。
    SELECT COALESCE(round(sum(
               CASE WHEN p.currency = v_base THEN p.amount_ccy
                    ELSE round(p.amount_ccy * p.fx_rate, 2) END), 2), 0)
      INTO v_receipts
      FROM payments p
      LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
     WHERE p.customer_id = p_customer_id
       AND p.direction = 'in'
       AND p.payment_date BETWEEN p_from AND p_to
       AND (p.status = 'posted'
            OR (p.status = 'reversed' AND rev.payment_date > p_to));

    -- 核销额:期间内收款【真的抵掉单据】的那一部分,按单据自己的入账汇率折本位币
    -- —— 与 ar_aging_asof 的 settled_base 同一口径,所以两边【能够】对上;
    -- 而它走的是 payment_allocations 这条路,与那支函数按单据算未结额【不是同一次推导】,
    -- 所以它们【也能够】对不上 —— 那正是这条勾稽有意义的原因(OPS-17)。
    SELECT COALESCE(round(sum(
               CASE WHEN pa.sales_record_id IS NOT NULL THEN pa.allocated_ccy * sr.fx_rate
                    ELSE pa.allocated_ccy * i.fx_rate END), 2), 0)
      INTO v_applied
      FROM payment_allocations pa
      JOIN payments p ON p.id = pa.payment_id
      LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
      LEFT JOIN sales_records sr ON sr.id = pa.sales_record_id
      LEFT JOIN invoices i ON i.id = pa.invoice_id
     WHERE p.direction = 'in'
       AND p.payment_date BETWEEN p_from AND p_to
       AND (p.status = 'posted'
            OR (p.status = 'reversed' AND rev.payment_date > p_to))
       AND ((sr.id IS NOT NULL AND sr.customer_id = p_customer_id)
            OR (i.id IS NOT NULL AND i.customer_id = p_customer_id));

    -- 挂账余额(截至期末,累计):收到但还没抵到任何单据上的钱。
    -- 【为什么它要单独说】它不在期末余额里(那是单据未结额之和),但客户已经付了 ——
    -- 不说,对账单就少了一笔他确实付过的钱;混进期末余额,那个数就不再是
    -- 任何一张单据的和。所以它是【单独一行】,并据此给出"净欠"。
    SELECT COALESCE(round(sum(
               CASE WHEN p.currency = v_base
                    THEN p.amount_ccy - COALESCE(al.applied_pay, 0)
                    ELSE round((p.amount_ccy - COALESCE(al.applied_pay, 0)) * p.fx_rate, 2)
               END), 2), 0)
      INTO v_onaccount
      FROM payments p
      LEFT JOIN payments rev ON rev.id = p.reversed_by_payment
      LEFT JOIN LATERAL (SELECT sum(pa.allocated_pay) AS applied_pay
                           FROM payment_allocations pa WHERE pa.payment_id = p.id) al ON true
     WHERE p.customer_id = p_customer_id
       AND p.direction = 'in'
       AND p.payment_date <= p_to
       AND (p.status = 'posted'
            OR (p.status = 'reversed' AND rev.payment_date > p_to));

    -- 贷项凭证:按 note_date 落期,挂在这个客户的发票上
    -- 【口径必须与账龄那一侧【逐条同源】,否则等式会因为一个筛子不同而对不上】
    -- 账龄的贷记只算在【order 型、且在期末那天仍然在册】的发票上
    -- (order_invoice_balance_all 的 kind='order';作废按【作废分录的分录日】回推)。
    -- 少任何一条,一张期末之前就作废了的发票上的贷项凭证会只出现在这一侧,
    -- 而它出现的方式是【等式差了那么多】—— 那时 STATEMENT_DOES_NOT_TIE 会拦住它,
    -- 但拦住不等于对:该做的是两边问同一个问题。
    SELECT COALESCE(round(sum(cl.amount * cn.fx_rate), 2), 0) INTO v_credits
      FROM credit_note_lines cl
      JOIN credit_notes cn ON cn.id = cl.credit_note_id
      JOIN invoices i ON i.id = cn.invoice_id
     WHERE i.customer_id = p_customer_id
       AND i.kind = 'order'
       AND cn.note_date BETWEEN p_from AND p_to
       AND (i.status = 'issued'
            OR (i.status = 'void'
                AND COALESCE((SELECT r.entry_date FROM journal_entries o
                                JOIN journal_entries r ON r.id = o.reversed_by
                               WHERE o.id = i.entry_id),
                             i.voided_at::date) > p_to));

    -- 发生额:期间内的订单流发票 + 期间内的直接销售记录。
    -- 【两支互斥,与 ar_open_items 同一条谓词】发货产生的销售记录带着
    -- sales_order_line_id,那笔债在开票当刻已经记过,不能再记一次。
    SELECT COALESCE(round(
             (SELECT COALESCE(sum(round(l.amount_ccy * i.fx_rate, 2)), 0)
                FROM invoices i
                JOIN LATERAL (SELECT COALESCE(sum(il.amount_ccy),0) AS amount_ccy
                                FROM invoice_lines il WHERE il.invoice_id = i.id) l ON true
               WHERE i.customer_id = p_customer_id AND i.kind = 'order'
                 AND i.issue_date BETWEEN p_from AND p_to
                 -- 同上:在期末那天【还站着】的才算发生额,而不是"今天还没作废的"
                 AND (i.status = 'issued'
                      OR (i.status = 'void'
                          AND COALESCE((SELECT r.entry_date FROM journal_entries o
                                          JOIN journal_entries r ON r.id = o.reversed_by
                                         WHERE o.id = i.entry_id),
                                       i.voided_at::date) > p_to)))
           + (SELECT COALESCE(sum(sr.amount_base), 0)
                FROM sales_records sr
               WHERE sr.customer_id = p_customer_id
                 AND sr.sales_order_line_id IS NULL
                 AND sr.sale_date BETWEEN p_from AND p_to), 2), 0)
      INTO v_charges;

    -- ══ 勾稽:两份独立推导必须相等 ══════════════════════════════════════════
    -- ★ 勾稽用【核销额】,不是收款额(见上面那一段实测)
    v_diff := round(v_opening + v_charges - v_credits - v_applied - v_closing, 2);

    -- 明细行:期末仍未结清的每一张单据(读 ar_aging_asof,不自己分档)
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'doc_kind',  e->>'doc_kind',
               'doc_code',  e->>'doc_code',
               'doc_date',  e->>'sale_date',
               'due_date',  e->>'due_date',
               'currency',  e->>'currency',
               'amount_ccy', (e->>'amount_ccy')::numeric,
               'open_ccy',  (e->>'open_ccy')::numeric,
               'open_base', (e->>'open_base')::numeric,
               'days_outstanding', (e->>'days_outstanding')::int,
               'bucket',    e->>'bucket'
           ) ORDER BY (e->>'sale_date')::date, e->>'doc_code'), '[]'::jsonb)
      INTO v_lines
      FROM jsonb_array_elements(v_close->'rows') e
     WHERE (e->>'customer_id') = p_customer_id::text;

    -- 每币种一段
    SELECT COALESCE(jsonb_agg(x ORDER BY x.currency), '[]'::jsonb) INTO v_byccy
      FROM (
        SELECT ccy AS currency,
               round(sum(open_ccy), 2) AS closing_ccy
          FROM (SELECT e->>'currency' AS ccy, (e->>'open_ccy')::numeric AS open_ccy
                  FROM jsonb_array_elements(v_close->'rows') e
                 WHERE (e->>'customer_id') = p_customer_id::text) q
         GROUP BY ccy
      ) x;

    -- 期末账龄四档:只数这个客户的
    SELECT jsonb_object_agg(b.bucket, COALESCE(agg.total, 0)) INTO v_buckets
      FROM (VALUES ('b0_30'), ('b31_60'), ('b61_90'), ('b90_plus')) AS b(bucket)
      LEFT JOIN LATERAL (
            SELECT round(sum((e->>'open_base')::numeric), 2) AS total
              FROM jsonb_array_elements(v_close->'rows') e
             WHERE (e->>'customer_id') = p_customer_id::text
               AND e->>'bucket' = b.bucket
      ) agg ON true;

    RETURN jsonb_build_object(
        'customer_id',   p_customer_id,
        'customer_code', v_c.code,
        'customer_name', v_c.legal_name,
        'period_start',  p_from,
        'period_end',    p_to,
        'base_currency', v_base,
        'opening_base',  v_opening,
        'charges_base',  v_charges,
        'credits_base',  v_credits,
        'receipts_base', v_receipts,
        'applied_base',  v_applied,
        'on_account_base', v_onaccount,
        -- 净欠 = 期末单据余额 − 挂在账上的钱。两个数都要给出来:
        -- 只给期末,客户会问"我付的那笔呢";只给净欠,它就不再等于任何单据之和。
        'net_due_base',  round(v_closing - v_onaccount, 2),
        'closing_base',  v_closing,
        'tie_difference', v_diff,
        'ties',          (v_diff = 0),
        -- 【期间内什么都没发生,是一个【有名字的状态】,不是一张空表】
        'no_movement',   (v_charges = 0 AND v_credits = 0 AND v_receipts = 0),
        'lines',         v_lines,
        'by_currency',   v_byccy,
        'buckets',       v_buckets);
END;
$function$

;

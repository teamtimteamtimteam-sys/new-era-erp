-- db/scripts/2026-10-03-at1c1-live-proof.sql
-- AUDIT-TRAIL-1c-1 · 线上的证明(形状照 1b-3 的那一份)。以 postgres 跑,读者一律是【真账号】的会话(SET LOCAL ROLE authenticated + JWT)。
--   A  只读:七个新主语在线上的【每一条】记录,以 tim@(cfo)读 —— 不许被拒;根行自己的建立在(线上每一行都早于记录,所以是
--      拼回来的那一条);发票的作废戳在(Q9);付款的冲销:原单的记录里有镜像单的建立(Q31);分录的冲销:原分录的记录里
--      有冲销分录的建立、【没有】冲销分录的行(Q33);一行只出现一次。读出来的行写进临时表,末尾一并吐成 JSON(给造句器)。
--   B  回滚:chooer@(finance)提与付、tim@(cfo)批(审批开着,两个【不同的人】—— admin@ 与 tim@ 是同一个人的两个账号,
--      提单人与决定人按人认,所以 admin@ 只负责建订单、批次这些不需要审批的布景),建一张人工分录(→ 冲销)、两张发票(作废一张 · 开贷项通知一张)、
--      两张费用(付一张 · 冲销一张)、一张付款申请(→ 付 → 冲销)、一个进料批次(定价 + 附件);以 tim@ 读它们的审计记录。
--   整个文件一笔事务,末尾 ROLLBACK —— 不留下任何东西(前后两份读数逐字相同为证)。
-- 线上登记了 GST:测试用的发票走零税率(ZR)、费用走范围外(OP)—— 只为让它们开得出来,税不是本证明证的东西。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f db/scripts/2026-10-03-at1c1-live-proof.sql > out.txt;  PROOF_OWN_EXIT=$?
BEGIN;
SET LOCAL statement_timeout = '600s';

CREATE TEMP TABLE p_out (label text, subject text, id text, rows jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp.p_trail(p_user uuid, p_subject text, p_id text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, 500) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE EXCEPTION 'PROOF|% % refused or failed: %', p_subject, p_id, SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.p_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

CREATE FUNCTION pg_temp.p_has(p_trail jsonb, p_table text, p_op text, p_id text, p_prelog boolean DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                    WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND e -> 'row_key' ->> 'id' = p_id
                      AND (p_prelog IS NULL OR (e ->> 'prelog')::boolean = p_prelog))
$f$;

-- ══════════════ A · 只读:线上的每一条 ══════════════
DO $a$
DECLARE
    tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';
    t record; v jsonb; x text; n int := 0; v_lines int; v_got int;
BEGIN
    FOR t IN SELECT 'journal_entry' AS s, 'journal_entries' AS tbl, id::text AS id, code FROM journal_entries
             UNION ALL SELECT 'invoice', 'invoices', id::text, code FROM invoices
             UNION ALL SELECT 'credit_note', 'credit_notes', id::text, code FROM credit_notes
             UNION ALL SELECT 'payment', 'payments', id::text, code FROM payments
             UNION ALL SELECT 'payment_request', 'payment_requests', id::text, code FROM payment_requests
             UNION ALL SELECT 'expense', 'expenses', id::text, code FROM expenses
             UNION ALL SELECT 'payable', 'inbound_batches', id::text, code FROM inbound_batches ORDER BY 1, 4 LOOP
        v := pg_temp.p_trail(tim, t.s, t.id);
        n := n + 1;
        -- 根行自己的建立(线上每一行都早于记录 → 拼回来的那一条;payments.created_at 可以为空 —— 那一行没有建立可拼)
        IF NOT pg_temp.p_has(v, t.tbl, 'INSERT', t.id)
           AND NOT (t.tbl = 'payments' AND (SELECT created_at IS NULL FROM payments WHERE id::text = t.id)) THEN
            RAISE EXCEPTION 'PROOF A|% %: its own creation is missing', t.s, t.code; END IF;
        x := pg_temp.p_twice(v);
        IF x IS NOT NULL THEN RAISE EXCEPTION 'PROOF A|% %: shown twice: %', t.s, t.code, x; END IF;
        INSERT INTO p_out VALUES ('A', t.s, t.id, v);
    END LOOP;
    RAISE NOTICE 'PROOF A read % live records as tim@', n;

    -- 分录:每一张的行都在(条数相等);被冲销的那几张:冲销分录的建立在、它的行【不】在(Q33)
    FOR t IN SELECT id, code, reversed_by FROM journal_entries LOOP
        SELECT rows INTO v FROM p_out WHERE label = 'A' AND subject = 'journal_entry' AND id = t.id::text;
        SELECT count(*) INTO v_lines FROM journal_lines WHERE entry_id = t.id;
        SELECT count(*) INTO v_got FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'journal_lines'
           AND e -> 'row_key' ->> 'id' IN (SELECT id::text FROM journal_lines WHERE entry_id = t.id);
        IF v_got <> v_lines THEN RAISE EXCEPTION 'PROOF A|journal %: % of % lines on its trail', t.code, v_got, v_lines; END IF;
        IF t.reversed_by IS NOT NULL THEN
            IF NOT pg_temp.p_has(v, 'journal_entries', 'INSERT', t.reversed_by::text) THEN
                RAISE EXCEPTION 'PROOF A|journal %: its reversal is not on its trail', t.code; END IF;
            IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'journal_lines'
                          AND e -> 'row_key' ->> 'id' IN (SELECT id::text FROM journal_lines WHERE entry_id = t.reversed_by)) THEN
                RAISE EXCEPTION 'PROOF A|journal %: the reversal''s lines are on the original (Q33)', t.code; END IF;
        END IF;
    END LOOP;
    -- 发票:每一张的行都在;作废了的三张,作废那一戳拼回来了(Q9)
    FOR t IN SELECT id, code, voided_at FROM invoices LOOP
        SELECT rows INTO v FROM p_out WHERE label = 'A' AND subject = 'invoice' AND id = t.id::text;
        IF (SELECT count(*) FROM invoice_lines WHERE invoice_id = t.id) <> (SELECT count(*) FROM jsonb_array_elements(v) e
             WHERE e ->> 'table_name' = 'invoice_lines') THEN RAISE EXCEPTION 'PROOF A|invoice %: a line is missing', t.code; END IF;
        IF t.voided_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'invoices'
              AND (e ->> 'prelog')::boolean AND e -> 'changed_columns' ? 'voided_at') THEN
            RAISE EXCEPTION 'PROOF A|invoice %: the void stamp did not come back (Q9)', t.code; END IF;
    END LOOP;
    -- 收付款:被冲销的那几笔,镜像单的建立在原单的记录里(Q31);核销行都在
    FOR t IN SELECT id, code, reversed_by_payment FROM payments LOOP
        SELECT rows INTO v FROM p_out WHERE label = 'A' AND subject = 'payment' AND id = t.id::text;
        IF t.reversed_by_payment IS NOT NULL AND NOT pg_temp.p_has(v, 'payments', 'INSERT', t.reversed_by_payment::text)
           AND (SELECT created_at IS NOT NULL FROM payments WHERE id = t.reversed_by_payment) THEN
            RAISE EXCEPTION 'PROOF A|payment %: the mirror''s creation is not on its trail (Q31)', t.code; END IF;
        IF (SELECT count(*) FROM payment_allocations WHERE payment_id = t.id AND created_at IS NOT NULL)
           <> (SELECT count(*) FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'payment_allocations'
                 AND e -> 'row_key' ->> 'id' IN (SELECT id::text FROM payment_allocations WHERE payment_id = t.id)) THEN
            RAISE EXCEPTION 'PROOF A|payment %: an allocation is missing', t.code; END IF;
    END LOOP;
    -- 应付:注销了的那几批,注销那一戳在;价格的每一次改动都在
    FOR t IN SELECT id, code, deleted_at FROM inbound_batches LOOP
        SELECT rows INTO v FROM p_out WHERE label = 'A' AND subject = 'payable' AND id = t.id::text;
        IF t.deleted_at IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'inbound_batches'
              AND e -> 'changed_columns' ? 'deleted_at') THEN
            RAISE EXCEPTION 'PROOF A|payable %: the write-off is missing', t.code; END IF;
        IF (SELECT count(*) FROM price_history WHERE inbound_batch_id = t.id) <> (SELECT count(*) FROM jsonb_array_elements(v) e
             WHERE e ->> 'table_name' = 'price_history') THEN RAISE EXCEPTION 'PROOF A|payable %: a price change is missing', t.code; END IF;
    END LOOP;
    RAISE NOTICE 'PROOF A passed';
END;
$a$;

-- ══════════════ B · 回滚:建 · 改 · 读(chooer@ 提与付,tim@ 批;admin@ 布景;审批开着)══════════════
DO $b$
DECLARE
    adm uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@swm-os.test(admin;与 tim@ 是同一个人)
    fin uuid := '476bf8c8-c248-4352-9a75-945bf52ca390';   -- chooer@evoltrya.test(finance)
    tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';   -- tim@evoltrya.test(cfo,二级审批)
    d date := CURRENT_DATE;
    v_base text; v_acct text := '6100';
    v_res jsonb; v_sup uuid; v_cust uuid; v_mat uuid; so1 uuid; so2 uuid; l1 uuid; l2 uuid; inv1 uuid; inv2 uuid; il2 uuid; v_cn uuid;
    je uuid; jer uuid; jr uuid; ex1 uuid; ex2 uuid; pr1 uuid; pr2 uuid; p1 uuid; p1m uuid; b1 uuid;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'PROOF B|approvals must be ON'; END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    -- 供应商由第三个人建(sandra@,cco):建户人既不能是付款人,也不能是批准人(批准时的试跑就以批准人的身份付一遍,SOD)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', '01ae00e4-306f-4527-8537-10291e4750c7'), true);
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ-AT1C1-PROOF-SUP', 'AT-1c-1 live proof supplier — rolled back', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ-AT1C1-PROOF-C', 'AT-1c-1 live proof customer — rolled back', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-AT1C1-PROOF-M', 'AT-1c-1 live proof material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    -- 分录:提(在等)→ tim@ 批(过账)→ 提冲销 → tim@ 批(冲销)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    jr := (submit_journal_request(d, 'AT-1c-1 live proof accrual', jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 12),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 12))) ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_journal_request(jr, true, 'proof');
    SELECT result_journal_entry_id INTO je FROM journal_requests WHERE id = jr;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    jr := (submit_journal_reversal_request(je, d, 'AT-1c-1 live proof: booked to the wrong account') ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_journal_request(jr, true, NULL);
    SELECT reversed_by INTO jer FROM journal_entries WHERE id = je;

    -- 发票两张:一张作废,一张开贷项通知
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d), v_cust, d, v_base, 1) RETURNING id INTO so1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so1, 1, v_mat, 10, 10) RETURNING id INTO l1;
    PERFORM set_sales_order_status(so1, 'confirmed');
    inv1 := (create_order_invoice(so1, d, NULL, NULL, NULL, ARRAY[l1], 'ZR') ->> 'invoice_id')::uuid;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d), v_cust, d, v_base, 1) RETURNING id INTO so2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so2, 1, v_mat, 10, 10) RETURNING id INTO l2;
    PERFORM set_sales_order_status(so2, 'confirmed');
    inv2 := (create_order_invoice(so2, d, NULL, NULL, NULL, ARRAY[l2], 'ZR') ->> 'invoice_id')::uuid;
    SELECT id INTO il2 FROM invoice_lines WHERE invoice_id = inv2;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    v_res := submit_invoice_void_request(inv1, 'AT-1c-1 live proof: wrong customer', d);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_invoice_request((v_res ->> 'request_id')::uuid, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    v_res := submit_credit_note_request(inv2, d, 'AT-1c-1 live proof: two units not delivered',
        jsonb_build_array(jsonb_build_object('invoice_line_id', il2, 'kind', 'unshipped_cancel', 'amount', 20, 'qty', 2)));
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_invoice_request((v_res ->> 'request_id')::uuid, true, NULL);
    SELECT id INTO v_cn FROM credit_notes WHERE invoice_id = inv2;

    -- 费用两张 + 付款申请(→ 付 → 冲销)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    ex1 := (record_expense(p_expense_date := d, p_account_code := v_acct, p_amount := 30, p_currency := v_base, p_supplier_id := v_sup, p_notes := 'AT-1c-1 live proof bill', p_tax_code := 'OP') ->> 'expense_id')::uuid;
    INSERT INTO finance_attachments (expense_id, file_name, file_path, doc_type) VALUES (ex1, 'at1c1-proof-bill.pdf', 'at1c1-proof/bill.pdf', 'invoice');
    ex2 := (record_expense(p_expense_date := d, p_account_code := v_acct, p_amount := 8, p_currency := v_base, p_supplier_id := v_sup, p_notes := 'AT-1c-1 live proof: to be reversed', p_tax_code := 'OP') ->> 'expense_id')::uuid;
    PERFORM reverse_expense(ex2, 'AT-1c-1 live proof: entered twice');
    pr1 := (submit_payment_request(v_sup, 30, v_base, NULL, NULL, d, 'AT-1c-1 live proof payment',
            jsonb_build_array(jsonb_build_object('expense_id', ex1, 'amount_doc', 30))) ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_payment_request(pr1, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM pay_payment_request(pr1, d, NULL);
    SELECT result_payment_id INTO p1 FROM payment_requests WHERE id = pr1;
    pr2 := (submit_payment_reversal_request(p1, 'AT-1c-1 live proof: paid twice') ->> 'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    PERFORM decide_payment_request(pr2, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fin), true);
    PERFORM pay_payment_request(pr2, NULL, NULL);
    SELECT reversed_by_payment INTO p1m FROM payments WHERE id = p1;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);

    -- 应付:一个进料批次 + 定价 + 一份财务附件
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ-AT1C1-PROOF-IB', v_mat, v_sup, 100, 100, 'kg', d, 'other', 'AT-1c-1 live proof') RETURNING id INTO b1;
    PERFORM reprice_inbound_batch(b1, 2.5, v_base, NULL, 'AT-1c-1 live proof price');
    INSERT INTO finance_attachments (inbound_batch_id, file_name, file_path, doc_type) VALUES (b1, 'at1c1-proof-grn.pdf', 'at1c1-proof/grn.pdf', 'receipt');
    PERFORM set_config('request.jwt.claims', '', true);

    INSERT INTO p_out VALUES
        ('B journal (reversed)', 'journal_entry', je::text, pg_temp.p_trail(tim, 'journal_entry', je::text)),
        ('B journal (the reversal)', 'journal_entry', jer::text, pg_temp.p_trail(tim, 'journal_entry', jer::text)),
        ('B invoice (voided)', 'invoice', inv1::text, pg_temp.p_trail(tim, 'invoice', inv1::text)),
        ('B invoice (credited)', 'invoice', inv2::text, pg_temp.p_trail(tim, 'invoice', inv2::text)),
        ('B credit note', 'credit_note', v_cn::text, pg_temp.p_trail(tim, 'credit_note', v_cn::text)),
        ('B payment (reversed)', 'payment', p1::text, pg_temp.p_trail(tim, 'payment', p1::text)),
        ('B payment (the mirror)', 'payment', p1m::text, pg_temp.p_trail(tim, 'payment', p1m::text)),
        ('B payment request (paid)', 'payment_request', pr1::text, pg_temp.p_trail(tim, 'payment_request', pr1::text)),
        ('B payment request (reversal)', 'payment_request', pr2::text, pg_temp.p_trail(tim, 'payment_request', pr2::text)),
        ('B expense (paid)', 'expense', ex1::text, pg_temp.p_trail(tim, 'expense', ex1::text)),
        ('B expense (reversed)', 'expense', ex2::text, pg_temp.p_trail(tim, 'expense', ex2::text)),
        ('B payable', 'payable', b1::text, pg_temp.p_trail(tim, 'payable', b1::text));
    RAISE NOTICE 'PROOF B passed: journal %, invoices %/%, credit note %, payment %/%, requests %/%, expenses %/%, batch %',
        (SELECT code FROM journal_entries WHERE id = je), (SELECT code FROM invoices WHERE id = inv1), (SELECT code FROM invoices WHERE id = inv2),
        (SELECT code FROM credit_notes WHERE id = v_cn), (SELECT code FROM payments WHERE id = p1), (SELECT code FROM payments WHERE id = p1m),
        (SELECT code FROM payment_requests WHERE id = pr1), (SELECT code FROM payment_requests WHERE id = pr2),
        (SELECT code FROM expenses WHERE id = ex1), (SELECT code FROM expenses WHERE id = ex2), 'ZZ-AT1C1-PROOF-IB';
END;
$b$;

-- 给造句器的那一份:每一条一行 JSON
\pset tuples_only on
\pset format unaligned
SELECT jsonb_build_object('label', label, 'subject', subject, 'id', id, 'rows', rows)::text FROM p_out ORDER BY label LIKE 'B%', label, subject, id;

ROLLBACK;

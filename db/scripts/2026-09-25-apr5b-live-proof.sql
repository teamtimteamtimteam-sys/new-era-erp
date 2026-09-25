-- db/scripts/2026-09-25-apr5b-live-proof.sql
-- APR-5b · 线上证明(一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接(rolbypassrls = t);每一格用 request.jwt.claims 换成一个【真账号】,在
-- SET LOCAL ROLE authenticated 下跑,拒绝与读回各印一行 CELL。任何一格与期望不符 → RAISE,整笔回滚,
-- psql 以非零退出(PROOF_OWN_EXIT)。
--   sandra@ = cco · tim@ = cfo · fusheng@ = warehouse · chooer@ = finance · admin@ = admin(与 tim@ 同一个人)
-- 线上没有一张可发的订单(Step 0 以 postgres 读基表:0 张 confirmed / partially_shipped),所以本证明
-- 【在事务里】按正常的门造一张:sandra@ 建单、确认、预留;chooer@ 开票 —— 然后走完整条放行 → 发货的生命周期。
-- 用到的线上行(2026-09-25 19:3x 以 postgres 读基表):客户 CUS-2026-0004(无额度、未冻结、没有地址 ——
-- 事务里补一个,证明它到得了仓库的队列;它也没有付款条件与默认税码 —— 开票时递 30 天与 ZR(零税率),那是 create_order_invoice 的参数);产出批次 OUT-2026-0002(MAT-2026-0002,available 1,000,买进来的、
-- 没有单位成本 —— 所以 CFO 的毛利那一格走的是「未计成本」:NULL,不是 0)。
-- ☞ 第一次跑选的是 OUT-2026-0007(有单位成本 2.6667),预留当场按名拒 SALE_FORM_NOT_SET|OUT-2026-0007:
--   它是加工产出的,而它的物料没有设形态(assert_output_batch_saleable)—— 整笔回滚,一格都没跑。
--   线上 available ≥ 17、可预留的产出批次只有 OUT-2026-0002 一个(19:4x 以 postgres 读基表),而它没有成本。
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS started_at;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.as_user(text) TO authenticated;

CREATE FUNCTION pg_temp.try_as(p_email text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END $$;

CREATE FUNCTION pg_temp.call_as(p_email text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

CREATE FUNCTION pg_temp.bal(p_code text) RETURNS numeric LANGUAGE sql AS $$
    SELECT round(COALESCE(sum(l.debit - l.credit), 0), 2) FROM accounts a
      LEFT JOIN journal_lines l ON l.account_id = a.id WHERE a.code = p_code
$$;

CREATE FUNCTION pg_temp.recon() RETURNS TABLE(side text, list numeric, ledger numeric, unexplained numeric) LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    RETURN QUERY SELECT s->>'side', (s->>'list_base')::numeric, (s->>'ledger_base')::numeric, (s->>'unexplained_base')::numeric
                   FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s;
    EXECUTE 'RESET ROLE';
END $$;

DO $proof$
DECLARE
    v_cust uuid; v_mat uuid; v_ob uuid; v_base text;
    so uuid; so_code text; soB uuid; soB_code text; L1 uuid; L2 uuid; LB uuid;
    inv uuid; inv_code text; invB uuid; il1 uuid; res1 uuid; res2 uuid; resB uuid;
    q uuid; qB uuid; qc uuid; v_res jsonb; v_msg text; v_n int; v_je0 int;
    v_1100 numeric; v_1220 numeric; v_2500 numeric; v_4000 numeric; v_5000 numeric;
    r record; d date := CURRENT_DATE;
BEGIN
    SELECT id INTO v_cust FROM customers WHERE code = 'CUS-2026-0004';
    SELECT ob.id, ob.material_id INTO v_ob, v_mat FROM output_batches ob WHERE ob.code = 'OUT-2026-0002';
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF v_cust IS NULL OR v_ob IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|a live row this proof names is not there'; END IF;
    UPDATE customers SET address = '8 Proof Street, Singapore 050005' WHERE id = v_cust;

    -- ── S · 布景:sandra@ 建单、确认、预留;chooer@ 开票(都走正常的门)────────────────
    v_res := pg_temp.call_as('sandra@evoltrya.test', format(
        'SELECT create_sales_order(%L, %L, %L, 1, %L::jsonb)', v_cust, d, v_base,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10, 'unit_price', 20),
                          jsonb_build_object('material_id', v_mat, 'quantity', 5, 'unit_price', 20))));
    so := (v_res->>'id')::uuid;
    SELECT code INTO so_code FROM sales_orders WHERE id = so;
    SELECT id INTO L1 FROM sales_order_lines WHERE sales_order_id = so AND line_no = 1;
    SELECT id INTO L2 FROM sales_order_lines WHERE sales_order_id = so AND line_no = 2;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT set_sales_order_status(%L, %L)', so, 'confirmed'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'PROOF_SETUP|confirm: %', v_msg; END IF;
    res1 := (pg_temp.call_as('sandra@evoltrya.test', format('SELECT reserve_stock(%L, %L, 10)', L1, v_ob))->>'reservation_id')::uuid;
    res2 := (pg_temp.call_as('sandra@evoltrya.test', format('SELECT reserve_stock(%L, %L, 5)', L2, v_ob))->>'reservation_id')::uuid;
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT create_order_invoice(%L, %L, 30, NULL, NULL, NULL, %L)', so, d, 'ZR'));
    inv := (v_res->>'invoice_id')::uuid; inv_code := v_res->>'code';
    SELECT id INTO il1 FROM invoice_lines WHERE invoice_id = inv AND sales_order_line_id = L1;
    -- 第二张单(N 臂 admin@ 与 V 臂作废)
    v_res := pg_temp.call_as('sandra@evoltrya.test', format(
        'SELECT create_sales_order(%L, %L, %L, 1, %L::jsonb)', v_cust, d, v_base,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 2, 'unit_price', 20))));
    soB := (v_res->>'id')::uuid;
    SELECT code INTO soB_code FROM sales_orders WHERE id = soB;
    SELECT id INTO LB FROM sales_order_lines WHERE sales_order_id = soB;
    PERFORM pg_temp.try_as('sandra@evoltrya.test', format('SELECT set_sales_order_status(%L, %L)', soB, 'confirmed'));
    resB := (pg_temp.call_as('sandra@evoltrya.test', format('SELECT reserve_stock(%L, %L, 2)', LB, v_ob))->>'reservation_id')::uuid;
    invB := (pg_temp.call_as('chooer@evoltrya.test', format('SELECT create_order_invoice(%L, %L, 30, NULL, NULL, NULL, %L)', soB, d, 'ZR'))->>'invoice_id')::uuid;
    RAISE NOTICE 'CELL S0 setup · % (2 lines, invoiced %, reserved 10 + 5 on OUT-2026-0002) · % (1 line) — both built through the ordinary doors', so_code, inv_code, soB_code;

    v_1100 := pg_temp.bal('1100'); v_1220 := pg_temp.bal('1220'); v_2500 := pg_temp.bal('2500');
    v_4000 := pg_temp.bal('4000'); v_5000 := pg_temp.bal('5000');
    SELECT count(*) INTO v_je0 FROM journal_entries;
    RAISE NOTICE 'CELL S1 postgres · after invoicing: 1100 % · 1220 % · 2500 % · 4000 % · 5000 % · JE %', v_1100, v_1220, v_2500, v_4000, v_5000, v_je0;

    -- ── A · 放行之前 ─────────────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', so, d,
        jsonb_build_array(jsonb_build_object('reservation_id', res1))));
    IF v_msg <> 'SO_SHIP_NOT_RELEASED|' || so_code || '|1' THEN RAISE EXCEPTION 'CELL A1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL A1 fusheng@ · ship before any release → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', so, d,
        jsonb_build_array(jsonb_build_object('reservation_id', res1))));
    IF v_msg <> 'PERMISSION_DENIED|action.ship_goods' THEN RAISE EXCEPTION 'CELL A2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL A2 sandra@ · ship → % (cco no longer ships)', v_msg;

    -- ── B · sandra@ 提放行 ──────────────────────────────────────────────────────
    v_res := pg_temp.call_as('sandra@evoltrya.test', format('SELECT submit_shipping_release(%L)', so));
    q := (v_res->>'release_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'line_count')::int <> 2 THEN RAISE EXCEPTION 'CELL B1 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL B1 sandra@ · raise → % submitted, 2 lines, amount_base % (JE unchanged: %)', v_res->>'label',
        (SELECT amount_base FROM shipping_releases WHERE id = q), (SELECT count(*) FROM journal_entries) = v_je0;
    SELECT count(*) INTO v_n FROM approval_pending_documents() p
     WHERE p.subject_type = 'shipping_release' AND p.doc_id = q AND p.blocks_disable AND p.fixed_level = 2;
    IF v_n <> 1 THEN RAISE EXCEPTION 'CELL B2 wrong: pending arm'; END IF;
    RAISE NOTICE 'CELL B2 postgres · pending arm: blocks_disable, fixed_level 2 · deciders: %',
        (SELECT string_agg(u.email::text, ' ') FROM approval_deciders('shipping_release', 'decide_shipping_release', 2::smallint,
            (SELECT created_by FROM shipping_releases WHERE id = q), NULL,
            (SELECT approval_level1_role_code FROM finance_settings), (SELECT approval_level2_role_code FROM finance_settings)) dd
          JOIN auth.users u ON u.id = dd.user_id);
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT submit_shipping_release(%L)', so));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_OPEN|%' THEN RAISE EXCEPTION 'CELL B3 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL B3 sandra@ · second raise → %', v_msg;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT decide_shipping_release(%L, true)', q));
    IF v_msg NOT LIKE 'SELF_APPROVAL_FORBIDDEN|raiser%' THEN RAISE EXCEPTION 'CELL B4 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL B4 sandra@ · decide own → %', v_msg;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT submit_shipping_release(%L)', soB));
    IF v_msg <> 'PERMISSION_DENIED|action.request_shipping_release' THEN RAISE EXCEPTION 'CELL B5 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL B5 fusheng@ · raise → %', v_msg;

    -- ── N · admin@ 提:没有别人批得了 ──────────────────────────────────────────────
    SELECT count(*) INTO v_n FROM shipping_releases;
    v_msg := pg_temp.try_as('admin@swm-os.test', format('SELECT submit_shipping_release(%L)', soB));
    IF v_msg <> 'SHIPPING_RELEASE_NO_OTHER_DECIDER|' || soB_code OR (SELECT count(*) FROM shipping_releases) <> v_n THEN
        RAISE EXCEPTION 'CELL N1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL N1 admin@ · raise on % → % (0 rows left)', soB_code, v_msg;

    -- ── C · CFO 的读者 ──────────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT shipping_release_context(%L)', q));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|%' THEN RAISE EXCEPTION 'CELL C1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL C1 fusheng@ · CFO context → %', v_msg;
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT shipping_release_context(%L)', q));
    IF (v_res->'lines'->0->>'costed')::boolean IS DISTINCT FROM false
       OR jsonb_typeof(v_res->'lines'->0->'margin_base') <> 'null' OR jsonb_typeof(v_res->'lines'->0->'cost_base') <> 'null' THEN
        RAISE EXCEPTION 'CELL C2 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL C2 tim@ · context: limit % · hold % · exposure % · invoice % open % paid % · line 1 invoiced % cost % margin % (% pct)',
        COALESCE(v_res->'customer'->>'credit_limit_base', 'none'), v_res->'customer'->>'credit_hold', v_res->'customer'->>'exposure_base',
        v_res->'invoices'->0->>'code', v_res->'invoices'->0->>'open_base', v_res->'invoices'->0->>'paid',
        v_res->'lines'->0->>'invoiced_base', v_res->'lines'->0->>'cost_base', v_res->'lines'->0->>'margin_base', v_res->'lines'->0->>'margin_pct';

    -- ── G · tim@ 批准 = 放行 ────────────────────────────────────────────────────
    v_res := pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_shipping_release(%L, true, %L)', q, 'APR5B live proof'));
    IF (SELECT status FROM shipping_releases WHERE id = q) <> 'approved'
       OR NOT EXISTS (SELECT 1 FROM approval_log al JOIN auth.users u ON u.id = al.actor_user_id
                       WHERE al.subject_id = q AND al.decision = 'approved' AND al.level = 2 AND u.email = 'tim@evoltrya.test'
                         AND NOT al.self_decided)
       OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN RAISE EXCEPTION 'CELL G1 wrong: %', v_res; END IF;
    RAISE NOTICE 'CELL G1 tim@ · approve → approved; log approved, level 2, tim@, self_decided false; nothing posted (JE %)', v_je0;

    -- ── Q · 仓库的队列 ──────────────────────────────────────────────────────────
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*), max(delivery_address), max(customer_name) INTO v_n, v_msg, so_code FROM shipping_queue_rows() WHERE sales_order_id = so;
    EXECUTE 'RESET ROLE';
    SELECT code INTO so_code FROM sales_orders WHERE id = so;
    IF v_n <> 2 OR v_msg IS DISTINCT FROM '8 Proof Street, Singapore 050005' THEN RAISE EXCEPTION 'CELL Q1 wrong: % rows, %', v_n, v_msg; END IF;
    RAISE NOTICE 'CELL Q1 fusheng@ · queue: % rows for %, delivery address "%", columns: %', v_n, so_code, v_msg,
        (SELECT string_agg(n, ',' ORDER BY o) FROM pg_proc p, unnest(p.proargnames, p.proargmodes) WITH ORDINALITY a(n, m, o)
          WHERE p.oid = 'public.shipping_queue_rows()'::regprocedure AND a.m = 't');
    v_msg := pg_temp.try_as('sandra@evoltrya.test', 'SELECT count(*) FROM shipping_queue_rows()');
    IF v_msg <> 'PERMISSION_DENIED|action.ship_goods' THEN RAISE EXCEPTION 'CELL Q2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL Q2 sandra@ · queue → %', v_msg;

    -- ── H · 发货那一刻客户冻结 ──────────────────────────────────────────────────
    v_msg := pg_temp.try_as('tim@evoltrya.test', format('SELECT set_customer_credit(%L, NULL, true)', v_cust));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'CELL H0 wrong: %', v_msg; END IF;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', so, d,
        jsonb_build_array(jsonb_build_object('reservation_id', res1))));
    IF v_msg NOT LIKE 'SO_SHIP_CUSTOMER_ON_HOLD|' || so_code || '|CUS-2026-0004' THEN RAISE EXCEPTION 'CELL H1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL H1 fusheng@ · ship with the customer on hold → %', v_msg;
    PERFORM pg_temp.try_as('tim@evoltrya.test', format('SELECT set_customer_credit(%L, NULL, false)', v_cust));

    -- ── F · fusheng@ 发货:部分 4 / 10,然后第 2 行整条 ───────────────────────────
    v_res := pg_temp.call_as('fusheng@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', so, d,
        jsonb_build_array(jsonb_build_object('reservation_id', res1, 'qty', 4))));
    IF v_res ?| ARRAY['revenue_ccy', 'revenue_base', 'currency', 'fx_rate'] THEN RAISE EXCEPTION 'CELL F1 wrong: money in %', v_res; END IF;
    RAISE NOTICE 'CELL F1 fusheng@ · ship line 1 qty 4 → % (return keys: %)', v_res->>'code',
        (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(v_res) k);
    RAISE NOTICE 'CELL F2 postgres · after 4 × 20: 2500 % → % · 4000 % → % · 1220 % → % · 5000 % → %',
        v_2500, pg_temp.bal('2500'), v_4000, pg_temp.bal('4000'), v_1220, pg_temp.bal('1220'), v_5000, pg_temp.bal('5000');
    PERFORM pg_temp.call_as('fusheng@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', so, d,
        jsonb_build_array(jsonb_build_object('reservation_id', res2))));
    PERFORM pg_temp.as_user('fusheng@evoltrya.test');
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM shipments WHERE sales_order_id = so;
    SELECT shipment_document((SELECT id FROM shipments WHERE sales_order_id = so ORDER BY created_at LIMIT 1)) INTO v_res;
    EXECUTE 'RESET ROLE';
    IF v_n <> 2 OR v_res::text LIKE '%price%' OR v_res::text LIKE '%amount%' THEN RAISE EXCEPTION 'CELL F3 wrong: % / %', v_n, v_res; END IF;
    RAISE NOTICE 'CELL F3 fusheng@ · reads % shipments of % and the delivery note (customer %, % line, no price)', v_n, so_code,
        v_res->>'customer_name', jsonb_array_length(v_res->'lines');
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT record_shipment_issue(%L, %L, %L)',
        (v_res->>'id')::uuid, 'apr5b-proof/x.pdf', repeat('a', 64)));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'CELL F4 wrong: %', v_msg; END IF;
    v_msg := pg_temp.try_as('sandra@evoltrya.test', format('SELECT record_shipment_issue(%L, %L, %L)',
        (v_res->>'id')::uuid, 'apr5b-proof/y.pdf', repeat('a', 64)));
    IF v_msg <> 'PERMISSION_DENIED|action.ship_goods' THEN RAISE EXCEPTION 'CELL F5 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL F4 fusheng@ · issue delivery note → OK · CELL F5 sandra@ → %', v_msg;

    -- ── K · Q8:未发货取消的数量 ─────────────────────────────────────────────────
    v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_credit_note_request(%L, %L, %L, %L::jsonb)', inv, d, 'APR5B proof',
        jsonb_build_array(jsonb_build_object('invoice_line_id', il1, 'kind', 'unshipped_cancel', 'amount', 40))));
    IF v_msg NOT LIKE 'CN_UNSHIPPED_CANCEL_QTY_REQUIRED|%' THEN RAISE EXCEPTION 'CELL K1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL K1 chooer@ · unshipped-cancel credit without qty → %', v_msg;
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_credit_note_request(%L, %L, %L, %L::jsonb)', inv, d, 'APR5B proof',
        jsonb_build_array(jsonb_build_object('invoice_line_id', il1, 'kind', 'unshipped_cancel', 'amount', 40, 'qty', 2))));
    qc := (v_res->>'request_id')::uuid;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_invoice_request(%L, true, %L)', qc, 'APR5B proof'));
    res1 := (pg_temp.call_as('sandra@evoltrya.test', format('SELECT reserve_stock(%L, %L, 6)', L1, v_ob))->>'reservation_id')::uuid;
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', so, d,
        jsonb_build_array(jsonb_build_object('reservation_id', res1))));
    IF v_msg <> 'SO_SHIP_EXCEEDS_RELEASABLE|' || so_code || '|1|6|4' THEN RAISE EXCEPTION 'CELL K2 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL K2 fusheng@ · after cancelling 2 (tim@ approved it), ship the remaining 6 → % (10 − 2 − 4 = 4)', v_msg;
    PERFORM pg_temp.call_as('fusheng@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', so, d,
        jsonb_build_array(jsonb_build_object('reservation_id', res1, 'qty', 4))));
    RAISE NOTICE 'CELL K3 fusheng@ · ship 4 → OK; order status %', (SELECT status FROM sales_orders WHERE id = so);

    -- ── V · 作废让放行自己失效 ──────────────────────────────────────────────────
    qB := (pg_temp.call_as('sandra@evoltrya.test', format('SELECT submit_shipping_release(%L)', soB))->>'release_id')::uuid;
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_shipping_release(%L, true)', qB));
    v_res := pg_temp.call_as('chooer@evoltrya.test', format('SELECT submit_invoice_void_request(%L, %L, %L)', invB, 'APR5B proof', d));
    PERFORM pg_temp.call_as('tim@evoltrya.test', format('SELECT decide_invoice_request(%L, true)', (v_res->>'request_id')::uuid));
    PERFORM pg_temp.call_as('chooer@evoltrya.test', format('SELECT create_order_invoice(%L, %L, 30, NULL, NULL, NULL, %L)', soB, d, 'ZR'));
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT ship_order(%L, %L, %L::jsonb)', soB, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resB))));
    IF v_msg <> 'SO_SHIP_NOT_RELEASED|' || soB_code || '|1' OR (SELECT status FROM shipping_releases WHERE id = qB) <> 'approved' THEN
        RAISE EXCEPTION 'CELL V1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL V1 tim@ approved % release, then voided its invoice; re-invoiced → fusheng@ ship → % (release row still approved)', soB_code, v_msg;

    -- ── I · 内层算子调不到 ──────────────────────────────────────────────────────
    v_msg := pg_temp.try_as('fusheng@evoltrya.test', format('SELECT release_reservation_internal(%L, 1, %L)', resB, 'x'));
    IF v_msg NOT LIKE 'permission denied for function release_reservation_internal%' THEN RAISE EXCEPTION 'CELL I1 wrong: %', v_msg; END IF;
    RAISE NOTICE 'CELL I1 fusheng@ · release_reservation_internal → %', v_msg;

    -- ── L · 清单对总账:两边都 0.00 未解释 ───────────────────────────────────────
    FOR r IN SELECT * FROM pg_temp.recon() LOOP
        IF r.unexplained <> 0 THEN RAISE EXCEPTION 'CELL L1 wrong: % unexplained %', r.side, r.unexplained; END IF;
        RAISE NOTICE 'CELL L1 tim@ · list_ledger_reconciliation % after the lifecycle: list % / ledger % / unexplained %', r.side, r.list, r.ledger, r.unexplained;
    END LOOP;
    RAISE NOTICE 'CELL L2 postgres · inside the transaction: 1100 % · 1220 % · 2500 % · 4000 % · 5000 % · JE %',
        pg_temp.bal('1100'), pg_temp.bal('1220'), pg_temp.bal('2500'), pg_temp.bal('4000'), pg_temp.bal('5000'),
        (SELECT count(*) FROM journal_entries);
    IF (SELECT count(*) FROM shipping_releases WHERE status = 'submitted') <> 0
       OR (SELECT count(*) FROM invoice_requests WHERE status = 'submitted') <> 0 THEN
        RAISE EXCEPTION 'CELL L3 wrong: something left waiting'; END IF;
    RAISE NOTICE 'CELL L3 postgres · nothing left waiting inside the transaction; ROLLBACK removes all of it';
END;
$proof$;
SELECT 'PROOF PASSED (inside the transaction; ROLLBACK follows)' AS verdict, now() AS finished_at;
ROLLBACK;

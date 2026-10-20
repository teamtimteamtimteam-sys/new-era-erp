-- 279 FIN-CHAIN-1:挂着在册发票的订单作废不得;订单流的销售不许再开一张 sale 票;短装的订单有一个显式的收尾(2026-10-20)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Tim APR-5 Q12;FIN-CHAIN-1 Step 0 Q4 · Q5,2026-10-20)
--   A  ★ B1 · APR5-CANCEL-INVOICED-ORDER-LEAVES-INVOICE-LIVE:一张确认了、开了票(在册订单流发票)的订单 →
--        作废 SO_CANCEL_HAS_LIVE_INVOICE|订单|发票,状态原样、发票原样;票作废之后,同一张订单作废得了;
--        一张确认了、没开票的订单照旧作废得了(这条新闸只认在册发票)
--   B  ★ B2 · APR5-SALE-INVOICE-RE-BILLS-ORDER-FLOW-SALES:ship_order 写下的那一笔销售(sales_order_line_id 非空)→
--        create_invoice 按名拒 SALE_IS_ORDER_FLOW|批次,一张票都不建;一笔直接销售(record_output_sale)照旧开得了票
--   C  ★ B3 · APR5-PARTIALLY-SHIPPED-HAS-NO-EXIT:开票 10、发 4 → partially_shipped;
--        作废仍然 SO_TRANSITION_NOT_ALLOWED;收尾不给理由 → SO_CLOSE_REASON_REQUIRED;
--        开了票没发的 6 还没被贷项取消 → SO_CLOSE_INVOICED_UNSHIPPED|订单|1|6;
--        贷项取消 6 之后收尾通过:closed、closed_at 有值、历史一行 closed 带理由、剩下的预留被释放(还许出去的 3 回来)
--   D  短装收尾不需要贷项的那一种:第 2 行从来没开票 —— 第 1 行发完,订单 partially_shipped;收尾直接通过(没开票 = 没欠)
--   E  ★ 故障注入:把新闸从 set_sales_order_status 里拿掉(换回只认 confirmed → cancelled 的旧体),A 臂那一句当场作废得了 ——
--        证明 A 臂的断言会咬人,而不是因为别的什么碰巧拒了
--
-- 自带数据(README 第 2 条);审批关着(本支测的是订单与发票的规矩,不是审批;贷项与放行生下来就落账/放行)。
-- 全部本位币、汇率 1、不带税。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f279_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END;
$f$;

DO $$
DECLARE
    u_set  uuid := gen_random_uuid();
    r_all  uuid;
    v_base text; v_cust uuid; v_mat uuid; v_ob uuid; v_ob2 uuid; v_ob_code text;
    soA uuid; soA_code text; soA2 uuid; soC uuid; soC_code text; soD uuid;
    LA uuid; LA2 uuid; LC uuid; LD1 uuid; LD2 uuid;
    invA uuid; invA_code text; invC uuid; ilC uuid;
    resC uuid; resD uuid; v_sale uuid; v_sale2 uuid;
    v_res jsonb; v_msg text; v_n int; v_def text;
    d  date := CURRENT_DATE;
    d0 date := CURRENT_DATE - 3;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL, gst_registered = false;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_set, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx279-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_set, r_all);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_set), true);

    INSERT INTO customers (code, legal_name, country, payment_terms_days, address)
    VALUES ('ZZ279-C1', 'fixture 279 customer', 'SG', 30, '1 Fixture Road') RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX279-M', 'f279 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    v_ob  := (create_output_batch(v_mat, 100, 'kg', d0, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    v_ob2 := (create_output_batch(v_mat, 50, 'kg', d0, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    SELECT code INTO v_ob_code FROM output_batches WHERE id = v_ob;

    -- ══════════════ A · B1:挂着在册发票的订单作废不得 ══════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id, code INTO soA, soA_code;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA, 1, v_mat, 5, 10) RETURNING id INTO LA;
    PERFORM set_sales_order_status(soA, 'confirmed');
    v_res := create_order_invoice(soA, d0, NULL, NULL, NULL, ARRAY[LA]);
    invA := (v_res->>'invoice_id')::uuid; invA_code := v_res->>'code';
    v_msg := pg_temp.f279_try(format('SELECT set_sales_order_status(%L, %L, %L)', soA, 'cancelled', 'customer withdrew'));
    IF v_msg <> 'SO_CANCEL_HAS_LIVE_INVOICE|' || soA_code || '|' || invA_code THEN
        RAISE EXCEPTION 'FIXTURE 279A1 失败:挂着在册发票的订单作废应当按名拒并点名那张票,实得 %', v_msg; END IF;
    IF (SELECT status FROM sales_orders WHERE id = soA) <> 'confirmed'
       OR (SELECT status FROM invoices WHERE id = invA) <> 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 279A2 失败:被拒的作废不该动订单或发票'; END IF;
    -- 票作废之后(CFO 批的那一步的引擎;本支不测审批),同一张订单作废得了
    PERFORM void_invoice_internal(invA, 'f279 A', d);
    PERFORM set_sales_order_status(soA, 'cancelled', 'customer withdrew');
    IF (SELECT status FROM sales_orders WHERE id = soA) <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 279A3 失败:票作废之后订单应当作废得了'; END IF;
    -- 没开票的确认单照旧作废得了
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soA2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA2, 1, v_mat, 1, 10) RETURNING id INTO LA2;
    PERFORM set_sales_order_status(soA2, 'confirmed');
    PERFORM set_sales_order_status(soA2, 'cancelled', 'no invoice');
    IF (SELECT status FROM sales_orders WHERE id = soA2) <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 279A4 失败:没开票的确认单应当照旧作废得了'; END IF;

    -- ══════════════ C · B3:短装收尾(先建它 —— B 臂要用它发货写下的那一笔销售)══════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id, code INTO soC, soC_code;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soC, 1, v_mat, 10, 10) RETURNING id INTO LC;
    PERFORM set_sales_order_status(soC, 'confirmed');
    invC := (create_order_invoice(soC, d0, NULL, NULL, NULL, ARRAY[LC]) ->> 'invoice_id')::uuid;
    SELECT id INTO ilC FROM invoice_lines WHERE invoice_id = invC AND sales_order_line_id = LC;
    resC := (reserve_stock(LC, v_ob, 10) ->> 'reservation_id')::uuid;
    PERFORM submit_shipping_release(soC);       -- 审批关着:生下来 approved
    PERFORM ship_order(soC, d, jsonb_build_array(jsonb_build_object('reservation_id', resC, 'qty', 4)));
    IF (SELECT status FROM sales_orders WHERE id = soC) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 279C0 前提失败:开票 10、发 4 应当是 partially_shipped'; END IF;
    -- 销售把剩下的 3 再许出去(收尾时要被释放)
    resC := (reserve_stock(LC, v_ob, 3) ->> 'reservation_id')::uuid;

    v_msg := pg_temp.f279_try(format('SELECT set_sales_order_status(%L, %L, %L)', soC, 'cancelled', 'x'));
    IF v_msg NOT LIKE 'SO_TRANSITION_NOT_ALLOWED|partially_shipped|cancelled%' THEN
        RAISE EXCEPTION 'FIXTURE 279C1 失败:发过货的单仍然作废不得,实得 %', v_msg; END IF;
    v_msg := pg_temp.f279_try(format('SELECT set_sales_order_status(%L, %L, %L)', soC, 'closed', '  '));
    IF v_msg <> 'SO_CLOSE_REASON_REQUIRED|' || soC_code THEN
        RAISE EXCEPTION 'FIXTURE 279C2 失败:短装收尾不给理由应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f279_try(format('SELECT set_sales_order_status(%L, %L, %L)', soC, 'closed', 'buyer took only 4'));
    IF v_msg <> 'SO_CLOSE_INVOICED_UNSHIPPED|' || soC_code || '|1|6' THEN
        RAISE EXCEPTION 'FIXTURE 279C3 失败:开了票没发的 6 还没被取消,应当按名拒并说出 1 号行与 6,实得 %', v_msg; END IF;
    IF (SELECT status FROM sales_orders WHERE id = soC) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 279C4 失败:被拒的收尾不该动订单'; END IF;

    -- 贷项取消没发的 6(审批关着:当场落账)
    PERFORM submit_credit_note_request(invC, d, 'f279 C',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilC, 'kind', 'unshipped_cancel', 'amount', 60, 'qty', 6)));
    SELECT count(*) INTO v_n FROM sales_order_history WHERE sales_order_id = soC AND change_type = 'closed';
    v_res := set_sales_order_status(soC, 'closed', 'buyer took only 4');
    IF (SELECT status FROM sales_orders WHERE id = soC) <> 'closed'
       OR (SELECT closed_at FROM sales_orders WHERE id = soC) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 279C5 失败:取消之后短装收尾应当走到 closed,实得 %', v_res; END IF;
    IF (SELECT count(*) FROM sales_order_history WHERE sales_order_id = soC AND change_type = 'closed'
         AND detail = 'buyer took only 4') <> v_n + 1 THEN
        RAISE EXCEPTION 'FIXTURE 279C6 失败:收尾应当写一行带理由的历史'; END IF;
    IF EXISTS (SELECT 1 FROM sales_order_reservations r WHERE r.sales_order_line_id = LC
                AND r.released_at IS NULL AND r.consumed_at IS NULL)
       OR (v_res->>'released_qty')::numeric <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 279C7 失败:收尾应当释放还许出去的 3,实得 %', v_res; END IF;
    v_msg := pg_temp.f279_try(format('SELECT set_sales_order_status(%L, %L, %L)', soC, 'cancelled', 'x'));
    IF v_msg NOT LIKE 'SO_TRANSITION_NOT_ALLOWED|closed|%' THEN
        RAISE EXCEPTION 'FIXTURE 279C8 失败:closed 仍然是终态,实得 %', v_msg; END IF;

    -- ══════════════ B · B2:订单流的销售不许再开一张 sale 票 ══════════════
    SELECT id INTO v_sale FROM sales_records WHERE sales_order_line_id = LC LIMIT 1;
    IF v_sale IS NULL THEN RAISE EXCEPTION 'FIXTURE 279B0 前提失败:ship_order 应当写下一笔带订单行的销售'; END IF;
    SELECT count(*) INTO v_n FROM invoices;
    v_msg := pg_temp.f279_try(format('SELECT create_invoice(%L, %L::uuid[], %L)', v_cust, ARRAY[v_sale], d));
    IF v_msg <> 'SALE_IS_ORDER_FLOW|' || v_ob_code THEN
        RAISE EXCEPTION 'FIXTURE 279B1 失败:订单流的销售再开 sale 票应当按名拒,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM invoices) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 279B2 失败:被拒的开票不该留下一张票'; END IF;
    v_sale2 := (record_output_sale(v_ob2, 2, 10, v_base, NULL, v_cust, d0) ->> 'sale_id')::uuid;
    IF v_sale2 IS NULL THEN
        SELECT id INTO v_sale2 FROM sales_records WHERE output_batch_id = v_ob2 AND sales_order_line_id IS NULL LIMIT 1;
    END IF;
    v_res := create_invoice(v_cust, ARRAY[v_sale2], d);
    IF (v_res->>'invoice_id') IS NULL AND (v_res->>'id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 279B3 失败:一笔直接销售应当照旧开得了票,实得 %', v_res; END IF;

    -- ══════════════ D · 没开票的那一截不需要贷项 ══════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soD;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soD, 1, v_mat, 2, 10) RETURNING id INTO LD1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soD, 2, v_mat, 2, 10) RETURNING id INTO LD2;
    PERFORM set_sales_order_status(soD, 'confirmed');
    PERFORM create_order_invoice(soD, d0, NULL, NULL, NULL, ARRAY[LD1]);
    resD := (reserve_stock(LD1, v_ob, 2) ->> 'reservation_id')::uuid;
    PERFORM submit_shipping_release(soD);
    PERFORM ship_order(soD, d, jsonb_build_array(jsonb_build_object('reservation_id', resD)));
    IF (SELECT status FROM sales_orders WHERE id = soD) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 279D0 前提失败:第 1 行发完、第 2 行没开票应当是 partially_shipped'; END IF;
    PERFORM set_sales_order_status(soD, 'closed', 'line 2 dropped before invoicing');
    IF (SELECT status FROM sales_orders WHERE id = soD) <> 'closed' THEN
        RAISE EXCEPTION 'FIXTURE 279D1 失败:没开票的那一截不欠任何人,收尾应当直接通过'; END IF;

    -- ══════════════ E · 故障注入:把 B1 那道闸拿掉,A 臂那一句应当作废得了 ══════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soA;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA, 1, v_mat, 1, 10) RETURNING id INTO LA;
    PERFORM set_sales_order_status(soA, 'confirmed');
    PERFORM create_order_invoice(soA, d0, NULL, NULL, NULL, ARRAY[LA]);
    v_def := pg_get_functiondef('public.set_sales_order_status(uuid, text, text)'::regprocedure);
    IF position('SO_CANCEL_HAS_LIVE_INVOICE' IN v_def) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 279E0 前提失败:函数体里找不到那道闸'; END IF;
    EXECUTE replace(v_def, 'IF p_to = ''cancelled'' THEN
        SELECT i.code INTO v_inv', 'IF false THEN
        SELECT i.code INTO v_inv');
    v_msg := pg_temp.f279_try(format('SELECT set_sales_order_status(%L, %L, %L)', soA, 'cancelled', 'x'));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 279E 失败:拿掉那道闸之后作废应当通过 —— 否则 A 臂是被别的东西拒的,实得 %', v_msg; END IF;

    RAISE NOTICE 'FIXTURE 279 全部通过:A 挂票的订单作废不得 · B 订单流的销售不再开票 · C 短装收尾(理由 · 未取消按名拒 · 取消后收尾 · 释放预留)· D 没开票不需要贷项 · E 注入';
END;
$$;
ROLLBACK;

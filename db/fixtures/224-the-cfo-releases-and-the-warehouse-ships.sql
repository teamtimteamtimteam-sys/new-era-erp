-- 224 APR-5b:发货前 CFO 放行,仓库照放行发货;仓库一个价格都看不见(2026-09-25)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(APR-5 grilling Q2–Q8 · Q13;5b grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   A  登记:链的名册只有二级一行,门 = module.sales.view + data.view_prices;operations_now 有两支;
--        两支内层算子 authenticated 调不到;ship_order / record_shipment_issue 的门是 action.ship_goods;
--        ★ 发货队列读者的返回列【逐字】是裁定的那一份 —— 没有价格、币种、汇率、金额、毛利、发票编号、余额
--   B  ★★ cco 提放行(审批开着):submitted;点名两条已开票的行;金额 = 发票行本位币之和;留痕 submitted 二级;
--        在途清单那一支 blocks_disable、fixed_level = 2;在途时关不了审批;放行之前发货 → SO_SHIP_NOT_RELEASED
--   C  提不了:第二张 → SHIPPING_RELEASE_OPEN;草稿单 → …ORDER_NOT_SHIPPABLE;没开票 → …NO_LINES;
--        别的订单的发票行 → …LINE_NOT_INVOICED;仓库 → PERMISSION_DENIED
--   D  批不了:提单人 → SELF_APPROVAL_FORBIDDEN|raiser;一级 → APPROVAL_NOT_AUTHORISED|2;仓库 → PERMISSION_DENIED;
--        驳回不给理由 → …REJECT_REASON_REQUIRED
--   E  ★★ 提单人之外没人批得动:CFO 那个人的另一个账号提 → SHIPPING_RELEASE_NO_OTHER_DECIDER,一行不落
--   F  CFO 的读者:额度、冻结、敞口、开放余额、没收齐;★ 没有成本的批次 → 成本与毛利 NULL,【不是 0】;仓库读不到
--   G  ★★ 批准 = 放行:approved,留痕 approved 二级
--   H  ★★ 仓库的队列:两行、送货地址、放行数量 / 已发 / 剩余、预留;cco 读不到
--   I  ★★ 仓库发货:cco 发不了;仓库部分发(4/10)—— 多出来的 6 回到 available(内层算子,仓库不持 sales.edit);返回值里没有钱;仓库读得到发货单
--        与发货单文件的读者,开得了发货单;cco 开不了
--   J  发货那一刻客户被冻结 → SO_SHIP_CUSTOMER_ON_HOLD;解冻照发
--   K  ★★ Q8 / 5b Q1:未发货取消不带数量 → CN_UNSHIPPED_CANCEL_QTY_REQUIRED;超过 开票 − 已发 → …QTY_EXCEEDS;
--        取消 2 之后天花板 = 10 − 2 − 4 = 4:发整条 6 → SO_SHIP_EXCEEDS_RELEASABLE|…|6|4;发 4 通;队列里这一行没了
--   L  ★ 放行之后开票的行要它自己的放行:发它 → SO_SHIP_NOT_RELEASED;再提默认只点名它;点名已覆盖的 → …ALREADY_RELEASED
--   M  ★ 作废让放行自己失效:作废、重开 → 发货 SO_SHIP_NOT_RELEASED;队列里没有它
--   N  撤回:仓库撤不了;另一个 cco 撤得了;撤回不写留痕
--   O  审批关着:生下来 approved,留痕 auto_approved
--   P  ★ 故障注入:给队列读者加一列 unit_price → 列清单断言当场变红(那条断言会咬人)
--
-- 自带数据(README 第 2 条);锁期自己设(第 4 条)。全部本位币、汇率 1、不带税。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f224_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f224_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 发货队列读者的返回列 —— 逐字就是 Tim 的裁定(5b Q6)。多一列、少一列、改一个名字都算失败:
-- 这张清单就是"仓库看得见什么"的全部答案。返回 NULL = 通过,否则返回实得的清单。
CREATE FUNCTION pg_temp.f224_queue_cols_bad() RETURNS text
LANGUAGE sql AS $f$
    SELECT CASE WHEN got = want THEN NULL ELSE got::text END
      FROM (SELECT (SELECT array_agg(n ORDER BY o)
                      FROM pg_proc p,
                           unnest(p.proargnames, p.proargmodes) WITH ORDINALITY AS a(n, m, o)
                     WHERE p.oid = 'public.shipping_queue_rows()'::regprocedure AND a.m = 't') AS got,
                   ARRAY['sales_order_id', 'order_code', 'order_date', 'customer_name', 'delivery_address',
                         'released_at', 'sales_order_line_id', 'line_no', 'material_code', 'material_name', 'unit',
                         'released_qty', 'shipped_qty', 'remaining_qty', 'reservation_id', 'output_batch_code',
                         'location_code', 'location_name', 'reserved_qty']::text[] AS want) x
$f$;

DO $$
DECLARE
    u_set  uuid := gen_random_uuid();   -- 布景:全部码(建单、开票、预留、贷项申请),不是任何一级的审批角色
    u_cco  uuid := gen_random_uuid();   -- cco 的形状:提放行、订单、看得见;【不】发货
    u_cco2 uuid := gen_random_uuid();   -- 另一个 cco(撤回那一臂)
    u_cfo  uuid := gen_random_uuid();   -- 二级:CFO 的形状;在册员工 e_cfo 的主账号
    u_cfo2 uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持 cco 角色 —— "同一个人提的"那一臂
    u_l1   uuid := gen_random_uuid();   -- 一级
    u_wh   uuid := gen_random_uuid();   -- 仓库的形状:action.ship_goods,【没有】sales.view、没有任何价格码
    r_all uuid; r_cco uuid; r_l1 uuid; r_l2 uuid; r_wh uuid;
    e_cfo uuid := gen_random_uuid();
    v_base text; v_cust uuid; v_cust_code text; v_mat uuid; v_ob uuid;
    soA uuid; soA_code text; soB uuid; soC uuid; soD uuid; soE uuid; soF uuid;
    LA1 uuid; LA2 uuid; LB1 uuid; LC1 uuid; LC2 uuid; LD1 uuid; LE1 uuid; LF1 uuid;
    invA uuid; invA_code text; invC2 uuid; invD uuid; invD2 uuid;
    ilA1 uuid; ilA2 uuid; ilB1 uuid; ilC1 uuid;
    resA1 uuid; resA2 uuid; resC2 uuid; resD uuid; resE uuid;
    q uuid; q2 uuid; v_res jsonb; v_msg text; v_n int; v_log int; v_amt numeric; v_ship uuid;
    d  date := CURRENT_DATE;
    d0 date := CURRENT_DATE - 3;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_set, now()), (u_cco, now()), (u_cco2, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_wh, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx224-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx224-cco','f','f',true) RETURNING id INTO r_cco;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx224-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx224-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx224-wh','f','f',true)  RETURNING id INTO r_wh;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_cco, 'action.request_shipping_release'), (r_cco, 'module.sales.view'), (r_cco, 'module.sales.edit'),
        (r_cco, 'data.view_prices'),
        -- 一级:审批开得了(每条分档链的门它都持)—— 批不了放行只能因为【级别】
        (r_l1, 'module.purchasing.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'),
        (r_l1, 'module.finance.view'), (r_l1, 'module.hr.view'), (r_l1, 'data.view_pay'), (r_l1, 'module.inbound.view'),
        (r_l1, 'module.sales.view'),
        -- 二级:CFO 的形状 —— 读得到、看得见,【没有】提单码、没有发货码
        (r_l2, 'module.purchasing.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'),
        (r_l2, 'module.finance.view'), (r_l2, 'module.hr.view'), (r_l2, 'data.view_pay'), (r_l2, 'module.inbound.view'),
        (r_l2, 'module.sales.view'),
        -- 仓库:发货、看库存与产出、物流;【没有】sales.view、customers.view、任何价格码
        (r_wh, 'action.ship_goods'), (r_wh, 'module.inventory.view'), (r_wh, 'module.output.view'),
        (r_wh, 'module.logistics.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_set, r_all), (u_cco, r_cco), (u_cco2, r_cco), (u_cfo, r_l2), (u_cfo2, r_cco), (u_l1, r_l1), (u_wh, r_wh);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_cfo, 'FX224-CFO', 'FX224 CFO', 'full_time', 'office', d - 400, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    INSERT INTO customers (code, legal_name, country, payment_terms_days, address)
    VALUES ('ZZ224-C1', 'fixture 224 customer', 'SG', 30, '1 Fixture Road, Singapore 224224')
    RETURNING id, code INTO v_cust, v_cust_code;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX224-M', 'f224 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    PERFORM pg_temp.f224_as(u_set);
    -- A:两行,都开票
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id, code INTO soA, soA_code;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA, 1, v_mat, 10, 10) RETURNING id INTO LA1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soA, 2, v_mat, 20, 10) RETURNING id INTO LA2;
    PERFORM set_sales_order_status(soA, 'confirmed');
    v_res := create_order_invoice(soA, d0, NULL, NULL, NULL, ARRAY[LA1, LA2]);
    invA := (v_res->>'invoice_id')::uuid; invA_code := v_res->>'code';
    SELECT id INTO ilA1 FROM invoice_lines WHERE invoice_id = invA AND sales_order_line_id = LA1;
    SELECT id INTO ilA2 FROM invoice_lines WHERE invoice_id = invA AND sales_order_line_id = LA2;
    -- B:一行,开票(E 臂"同一个人提")
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soB;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soB, 1, v_mat, 5, 10) RETURNING id INTO LB1;
    PERFORM set_sales_order_status(soB, 'confirmed');
    PERFORM create_order_invoice(soB, d0, NULL, NULL, NULL, ARRAY[LB1]);
    SELECT id INTO ilB1 FROM invoice_lines WHERE sales_order_line_id = LB1;
    -- C:两行,先只开第 1 行(L 臂)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soC;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soC, 1, v_mat, 3, 10) RETURNING id INTO LC1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soC, 2, v_mat, 3, 10) RETURNING id INTO LC2;
    PERFORM set_sales_order_status(soC, 'confirmed');
    PERFORM create_order_invoice(soC, d0, NULL, NULL, NULL, ARRAY[LC1]);
    SELECT id INTO ilC1 FROM invoice_lines WHERE sales_order_line_id = LC1;
    -- D:一行,开票(M 臂:作废让放行失效)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soD;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soD, 1, v_mat, 2, 10) RETURNING id INTO LD1;
    PERFORM set_sales_order_status(soD, 'confirmed');
    invD := (create_order_invoice(soD, d0, NULL, NULL, NULL, ARRAY[LD1]) ->> 'invoice_id')::uuid;
    -- E:确认了、没开票(C 臂 NO_LINES);F:草稿(C 臂 ORDER_NOT_SHIPPABLE)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soE;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soE, 1, v_mat, 1, 10) RETURNING id INTO LE1;
    PERFORM set_sales_order_status(soE, 'confirmed');
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d0), v_cust, d0, v_base, 1) RETURNING id INTO soF;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (soF, 1, v_mat, 1, 10) RETURNING id INTO LF1;

    -- 预留(没有成本的产出批次:create_output_batch 不生 processing_outputs 那一行)
    v_ob := (create_output_batch(v_mat, 100, 'kg', d0, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    resA1 := (reserve_stock(LA1, v_ob, 10) ->> 'reservation_id')::uuid;
    resA2 := (reserve_stock(LA2, v_ob, 20) ->> 'reservation_id')::uuid;
    resC2 := (reserve_stock(LC2, v_ob, 3) ->> 'reservation_id')::uuid;
    resD  := (reserve_stock(LD1, v_ob, 2) ->> 'reservation_id')::uuid;

    -- 策略:一级 fx224-l1、二级 fx224-l2;审批打开
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx224-l1', approval_level2_role_code = 'fx224-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 登记 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'shipping_release')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'shipping_release')
         IS DISTINCT FROM ARRAY['module.sales.view', 'data.view_prices']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 224A1 失败:链的名册应当只有二级一行,门 = sales.view + view_prices'; END IF;
    IF position('shipping_release_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0
       OR position('shipping_release_ready' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 224A2 失败:operations_now 应当有 shipping_release_pending 与 shipping_release_ready 两支'; END IF;
    IF has_function_privilege('authenticated', 'public.release_reservation_internal(uuid, numeric, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.reserve_stock_internal(uuid, uuid, numeric, uuid)', 'EXECUTE')
       OR has_table_privilege('authenticated', 'public.sales_order_line_releasable_all', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 224A3 失败:两支内层算子与天花板基视图 authenticated 不该够得着'; END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.ship_order(uuid, date, jsonb)'::regprocedure)
         NOT LIKE '%require_permission(''action.ship_goods'')%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.ship_order(uuid, date, jsonb)'::regprocedure)
         LIKE '%require_permission(''module.sales.edit'')%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.record_shipment_issue(uuid, text, text)'::regprocedure)
         NOT LIKE '%require_permission(''action.ship_goods'')%' THEN
        RAISE EXCEPTION 'FIXTURE 224A4 失败:发货与开发货单的门应当是 action.ship_goods,而且只有它'; END IF;
    v_msg := pg_temp.f224_queue_cols_bad();
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 224A5 失败:发货队列的返回列应当逐字是裁定的那一份(没有任何价格),实得 %', v_msg; END IF;

    -- ══════════════ B · cco 提放行(审批开着)══════════════
    SELECT count(*) INTO v_log FROM approval_log;
    PERFORM pg_temp.f224_as(u_cco);
    v_res := submit_shipping_release(soA);
    q := (v_res->>'release_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'line_count')::int <> 2
       OR (SELECT count(*) FROM shipping_release_lines WHERE release_id = q) <> 2
       OR (SELECT amount_base FROM shipping_releases WHERE id = q)
          <> (SELECT sum(amount_base) FROM invoice_lines WHERE id IN (ilA1, ilA2)) THEN
        RAISE EXCEPTION 'FIXTURE 224B1 失败:应当 submitted、点名两行、金额 = 发票行本位币之和,实得 %', v_res; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'shipping_release' AND subject_id = q
                    AND decision = 'submitted' AND level = 2) THEN
        RAISE EXCEPTION 'FIXTURE 224B2 失败:留痕应当是 submitted、二级'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() p
                    WHERE p.subject_type = 'shipping_release' AND p.doc_id = q
                      AND p.blocks_disable AND p.fixed_level = 2 AND p.raiser_user_id = u_cco
                      AND p.subject_employee_id IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 224B3 失败:在途清单那一支应当 blocks_disable、fixed_level = 2、提单人 u_cco、主角 NULL'; END IF;
    v_msg := NULL;
    BEGIN
        PERFORM set_config('request.jwt.claims', '', true);
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF v_msg NOT LIKE 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%' THEN
        RAISE EXCEPTION 'FIXTURE 224B4 失败:一张在等的放行应当挡住关审批,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soA, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resA1))));
    IF v_msg <> 'SO_SHIP_NOT_RELEASED|' || soA_code || '|1' THEN
        RAISE EXCEPTION 'FIXTURE 224B5 失败:放行之前发货应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ C · 提不了 ══════════════
    PERFORM pg_temp.f224_as(u_cco);
    v_msg := pg_temp.f224_try(format('SELECT submit_shipping_release(%L)', soA));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_OPEN|' || soA_code || '|%' THEN
        RAISE EXCEPTION 'FIXTURE 224C1 失败:一张订单同时只挂一张,实得 %', v_msg; END IF;
    v_msg := pg_temp.f224_try(format('SELECT submit_shipping_release(%L)', soF));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE|%|draft' THEN
        RAISE EXCEPTION 'FIXTURE 224C2 失败:草稿单提不了放行,实得 %', v_msg; END IF;
    v_msg := pg_temp.f224_try(format('SELECT submit_shipping_release(%L)', soE));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_NO_LINES|%' THEN
        RAISE EXCEPTION 'FIXTURE 224C3 失败:没开票的单没有可放行的行,实得 %', v_msg; END IF;
    v_msg := pg_temp.f224_try(format('SELECT submit_shipping_release(%L, %L::uuid[])', soC, ARRAY[ilB1]));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_LINE_NOT_INVOICED|%|' || ilB1::text THEN
        RAISE EXCEPTION 'FIXTURE 224C4 失败:别的订单的发票行不许点名,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT submit_shipping_release(%L)', soC));
    IF v_msg <> 'PERMISSION_DENIED|action.request_shipping_release' THEN
        RAISE EXCEPTION 'FIXTURE 224C5 失败:仓库提不了放行,实得 %', v_msg; END IF;

    -- ══════════════ D · 批不了 ══════════════
    PERFORM pg_temp.f224_as(u_cco);
    v_msg := pg_temp.f224_try(format('SELECT decide_shipping_release(%L, true)', q));
    IF v_msg NOT LIKE 'SELF_APPROVAL_FORBIDDEN|raiser%' THEN
        RAISE EXCEPTION 'FIXTURE 224D1 失败:提单人批不了自己的放行,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_l1);
    v_msg := pg_temp.f224_try(format('SELECT decide_shipping_release(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN
        RAISE EXCEPTION 'FIXTURE 224D2 失败:一级批不了二级的链,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT decide_shipping_release(%L, true)', q));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|%' THEN
        RAISE EXCEPTION 'FIXTURE 224D3 失败:仓库批不了,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_cfo);
    v_msg := pg_temp.f224_try(format('SELECT decide_shipping_release(%L, false, %L)', q, '  '));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_REJECT_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 224D4 失败:驳回要理由,实得 %', v_msg; END IF;

    -- ══════════════ E · 提单人之外没人批得动 ══════════════
    SELECT count(*) INTO v_n FROM shipping_releases;
    PERFORM pg_temp.f224_as(u_cfo2);
    v_msg := pg_temp.f224_try(format('SELECT submit_shipping_release(%L)', soB));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_NO_OTHER_DECIDER|%' THEN
        RAISE EXCEPTION 'FIXTURE 224E1 失败:CFO 那个人的另一个账号提,应当按名拒,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM shipping_releases) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 224E2 失败:被拒的提交不该留下一行'; END IF;

    -- ══════════════ F · CFO 的读者 ══════════════
    PERFORM pg_temp.f224_as(u_cfo);
    v_res := shipping_release_context(q);
    IF (v_res->'customer'->>'code') <> v_cust_code
       OR (v_res->'customer'->>'credit_hold')::boolean IS DISTINCT FROM false
       OR (v_res->'customer'->>'exposure_base') IS NULL
       OR jsonb_array_length(v_res->'invoices') <> 1
       OR (v_res->'invoices'->0->>'open_base')::numeric <> 300
       OR (v_res->'invoices'->0->>'paid')::boolean IS DISTINCT FROM false
       OR jsonb_array_length(v_res->'lines') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 224F1 失败:读者应当给出客户、敞口、一张开放 300 未收齐的发票、两行,实得 %', v_res; END IF;
    IF (v_res->'lines'->0->>'costed')::boolean IS DISTINCT FROM false
       OR jsonb_typeof(v_res->'lines'->0->'cost_base') <> 'null'
       OR jsonb_typeof(v_res->'lines'->0->'margin_base') <> 'null'
       OR (v_res->'lines'->0->>'invoiced_base')::numeric <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 224F2 失败:没有成本的批次 → 成本与毛利应当是 NULL(不是 0),开票额 100,实得 %', v_res->'lines'->0; END IF;
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT shipping_release_context(%L)', q));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|%' THEN
        RAISE EXCEPTION 'FIXTURE 224F3 失败:仓库读不到 CFO 的读者,实得 %', v_msg; END IF;

    -- ══════════════ G · 批准 = 放行 ══════════════
    PERFORM pg_temp.f224_as(u_cfo);
    v_res := decide_shipping_release(q, true, 'fixture 224 G');
    IF v_res->>'status' <> 'approved' OR (SELECT status FROM shipping_releases WHERE id = q) <> 'approved'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'shipping_release' AND subject_id = q
                       AND decision = 'approved' AND level = 2 AND actor_user_id = u_cfo) THEN
        RAISE EXCEPTION 'FIXTURE 224G 失败:批准应当 approved、留痕 approved 二级、决定人 u_cfo,实得 %', v_res; END IF;

    -- ══════════════ H · 仓库的队列 ══════════════
    PERFORM pg_temp.f224_as(u_wh);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM shipping_queue_rows() r WHERE r.sales_order_id = soA;
    SELECT r.delivery_address INTO v_msg FROM shipping_queue_rows() r WHERE r.sales_order_id = soA LIMIT 1;
    SELECT r.released_qty + r.shipped_qty * 100 + r.remaining_qty * 10000 + r.reserved_qty * 1000000 INTO v_amt
      FROM shipping_queue_rows() r WHERE r.sales_order_line_id = LA1;
    RESET ROLE;
    IF v_n <> 2 OR v_msg <> '1 Fixture Road, Singapore 224224' OR v_amt <> 10 + 0 + 100000 + 10000000 THEN
        RAISE EXCEPTION 'FIXTURE 224H1 失败:队列应当两行、带送货地址、第 1 行放行 10 / 已发 0 / 剩余 10 / 预留 10,实得 % 行 · % · %', v_n, v_msg, v_amt; END IF;
    PERFORM pg_temp.f224_as(u_cco);
    v_msg := pg_temp.f224_try('SELECT * FROM shipping_queue_rows()', true);
    IF v_msg <> 'PERMISSION_DENIED|action.ship_goods' THEN
        RAISE EXCEPTION 'FIXTURE 224H2 失败:cco 读不到发货队列,实得 %', v_msg; END IF;

    -- ══════════════ I · 仓库发货 ══════════════
    PERFORM pg_temp.f224_as(u_cco);
    v_msg := pg_temp.f224_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soA, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resA1))));
    IF v_msg <> 'PERMISSION_DENIED|action.ship_goods' THEN
        RAISE EXCEPTION 'FIXTURE 224I1 失败:cco 从此不发货,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_wh);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := ship_order(soA, d, jsonb_build_array(jsonb_build_object('reservation_id', resA1, 'qty', 4)));
    RESET ROLE;
    v_ship := (v_res->>'shipment_id')::uuid;
    IF v_ship IS NULL OR v_res ?| ARRAY['revenue_ccy', 'revenue_base', 'currency', 'fx_rate'] THEN
        RAISE EXCEPTION 'FIXTURE 224I2 失败:发货应当成功,而且返回值里没有任何金额、币种或汇率,实得 %', v_res; END IF;
    -- 部分发货:多出来的那一截(10 − 4 = 6)由 release_reservation_internal 放回 available —— 仓库不持
    -- module.sales.edit,正是这一步要内层算子的理由。这一行此刻没有活预留,已许出去 = 已发 4。
    IF EXISTS (SELECT 1 FROM sales_order_reservations
                WHERE sales_order_line_id = LA1 AND released_at IS NULL AND consumed_at IS NULL)
       OR line_spoken_for(LA1) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 224I3 失败:部分发 4 之后多出来的 6 应当回到 available(没有活预留,已许出去 4)'; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM shipments WHERE id = v_ship;
    v_res := shipment_document(v_ship);
    RESET ROLE;
    IF v_n <> 1 OR jsonb_array_length(v_res->'lines') <> 1 OR (v_res->>'customer_name') <> 'fixture 224 customer'
       OR v_res::text LIKE '%price%' OR v_res::text LIKE '%amount%' THEN
        RAISE EXCEPTION 'FIXTURE 224I4 失败:仓库应当读得到自己发的货与发货单(一行、客户名、没有价格),实得 % 行 · %', v_n, v_res; END IF;
    v_msg := pg_temp.f224_try(format('SELECT record_shipment_issue(%L, %L, %L)', v_ship, 'f224/x.pdf', repeat('a', 64)), true);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 224I5 失败:仓库开得了发货单,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_cco);
    v_msg := pg_temp.f224_try(format('SELECT record_shipment_issue(%L, %L, %L)', v_ship, 'f224/y.pdf', repeat('a', 64)), true);
    IF v_msg <> 'PERMISSION_DENIED|action.ship_goods' THEN
        RAISE EXCEPTION 'FIXTURE 224I6 失败:cco 从此不开发货单,实得 %', v_msg; END IF;

    -- ══════════════ J · 发货那一刻客户被冻结 ══════════════
    PERFORM pg_temp.f224_as(u_set);
    PERFORM set_customer_credit(v_cust, NULL, true);
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soA, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resA2))));
    IF v_msg <> 'SO_SHIP_CUSTOMER_ON_HOLD|' || soA_code || '|' || v_cust_code THEN
        RAISE EXCEPTION 'FIXTURE 224J1 失败:冻结的客户按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_set);
    PERFORM set_customer_credit(v_cust, NULL, false);
    PERFORM pg_temp.f224_as(u_wh);
    PERFORM ship_order(soA, d, jsonb_build_array(jsonb_build_object('reservation_id', resA2)));

    -- ══════════════ K · Q8:未发货取消的数量 ══════════════
    PERFORM pg_temp.f224_as(u_set);
    resA1 := (reserve_stock(LA1, v_ob, 6) ->> 'reservation_id')::uuid;   -- 销售把剩下的 6 再许出去
    v_msg := pg_temp.f224_try(format('SELECT submit_credit_note_request(%L, %L, %L, %L::jsonb)', invA, d0, 'f224 K',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilA1, 'kind', 'unshipped_cancel', 'amount', 20))));
    IF v_msg <> 'CN_UNSHIPPED_CANCEL_QTY_REQUIRED|' || invA_code || '|1' THEN
        RAISE EXCEPTION 'FIXTURE 224K1 失败:未发货取消不带数量应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f224_try(format('SELECT submit_credit_note_request(%L, %L, %L, %L::jsonb)', invA, d0, 'f224 K',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilA1, 'kind', 'unshipped_cancel', 'amount', 60, 'qty', 7))));
    IF v_msg <> 'CN_UNSHIPPED_CANCEL_QTY_EXCEEDS|' || invA_code || '|1|7|6' THEN
        RAISE EXCEPTION 'FIXTURE 224K2 失败:取消 7 超过 开票 10 − 已发 4,应当按名拒,实得 %', v_msg; END IF;
    v_res := submit_credit_note_request(invA, d0, 'f224 K',
        jsonb_build_array(jsonb_build_object('invoice_line_id', ilA1, 'kind', 'unshipped_cancel', 'amount', 20, 'qty', 2)));
    PERFORM pg_temp.f224_as(u_cfo);
    PERFORM decide_invoice_request((v_res->>'request_id')::uuid, true, 'f224 K');
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soA, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resA1))));
    IF v_msg <> 'SO_SHIP_EXCEEDS_RELEASABLE|' || soA_code || '|1|6|4' THEN
        RAISE EXCEPTION 'FIXTURE 224K3 失败:取消 2 之后天花板 = 10 − 2 − 4 = 4,发整条 6 应当按名拒,实得 %', v_msg; END IF;
    PERFORM ship_order(soA, d, jsonb_build_array(jsonb_build_object('reservation_id', resA1, 'qty', 4)));
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM shipping_queue_rows() r WHERE r.sales_order_line_id = LA1;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 224K4 失败:发满放行数量(10 − 2)之后,这一行应当离开队列,实得 % 行', v_n; END IF;

    -- ══════════════ L · 放行之后开票的行要它自己的放行 ══════════════
    PERFORM pg_temp.f224_as(u_cco);
    q2 := (submit_shipping_release(soC) ->> 'release_id')::uuid;
    PERFORM pg_temp.f224_as(u_cfo);
    PERFORM decide_shipping_release(q2, true);
    PERFORM pg_temp.f224_as(u_set);
    invC2 := (create_order_invoice(soC, d0, NULL, NULL, NULL, ARRAY[LC2]) ->> 'invoice_id')::uuid;
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soC, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resC2))));
    IF v_msg NOT LIKE 'SO_SHIP_NOT_RELEASED|%|2' THEN
        RAISE EXCEPTION 'FIXTURE 224L1 失败:放行之后才开票的行要它自己的放行,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_cco);
    v_msg := pg_temp.f224_try(format('SELECT submit_shipping_release(%L, %L::uuid[])', soC, ARRAY[ilC1]));
    IF v_msg NOT LIKE 'SHIPPING_RELEASE_LINE_ALREADY_RELEASED|%|1' THEN
        RAISE EXCEPTION 'FIXTURE 224L2 失败:已经被覆盖的行不许再点名,实得 %', v_msg; END IF;
    v_res := submit_shipping_release(soC);
    IF (v_res->>'line_count')::int <> 1
       OR (SELECT sales_order_line_id FROM shipping_release_lines WHERE release_id = (v_res->>'release_id')::uuid) <> LC2 THEN
        RAISE EXCEPTION 'FIXTURE 224L3 失败:默认只点名还没被覆盖的那一行(第 2 行),实得 %', v_res; END IF;
    PERFORM pg_temp.f224_as(u_cfo);
    PERFORM decide_shipping_release((v_res->>'release_id')::uuid, true);

    -- ══════════════ M · 作废让放行自己失效 ══════════════
    PERFORM pg_temp.f224_as(u_cco);
    q2 := (submit_shipping_release(soD) ->> 'release_id')::uuid;
    PERFORM pg_temp.f224_as(u_cfo);
    PERFORM decide_shipping_release(q2, true);
    PERFORM pg_temp.f224_as(u_set);
    PERFORM void_invoice_internal(invD, 'f224 M', d);
    invD2 := (create_order_invoice(soD, d0, NULL, NULL, NULL, ARRAY[LD1]) ->> 'invoice_id')::uuid;
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT ship_order(%L, %L, %L::jsonb)', soD, d,
        jsonb_build_array(jsonb_build_object('reservation_id', resD))));
    IF v_msg NOT LIKE 'SO_SHIP_NOT_RELEASED|%|1' THEN
        RAISE EXCEPTION 'FIXTURE 224M1 失败:作废之后原放行不再覆盖重开的发票,实得 %', v_msg; END IF;
    IF (SELECT status FROM shipping_releases WHERE id = q2) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 224M2 失败:作废不该去改放行本身 —— 覆盖是现算的'; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM shipping_queue_rows() r WHERE r.sales_order_id = soD;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 224M3 失败:失效的放行不该把订单留在队列里,实得 % 行', v_n; END IF;

    -- ══════════════ N · 撤回 ══════════════
    PERFORM pg_temp.f224_as(u_cco);
    q2 := (submit_shipping_release(soD) ->> 'release_id')::uuid;
    PERFORM pg_temp.f224_as(u_wh);
    v_msg := pg_temp.f224_try(format('SELECT withdraw_shipping_release(%L, %L)', q2, 'x'));
    IF v_msg <> 'PERMISSION_DENIED|action.request_shipping_release' THEN
        RAISE EXCEPTION 'FIXTURE 224N1 失败:不是提单人、又不持提单码的人撤不了,实得 %', v_msg; END IF;
    PERFORM pg_temp.f224_as(u_cco2);
    PERFORM withdraw_shipping_release(q2, 'f224 N');
    IF (SELECT status FROM shipping_releases WHERE id = q2) <> 'withdrawn'
       OR EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'shipping_release' AND subject_id = q2
                   AND decision <> 'submitted') THEN
        RAISE EXCEPTION 'FIXTURE 224N2 失败:另一个 cco 撤得了,撤回不写留痕'; END IF;

    -- ══════════════ O · 审批关着 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f224_as(u_cco);
    v_res := submit_shipping_release(soD);
    q2 := (v_res->>'release_id')::uuid;
    IF v_res->>'status' <> 'approved' OR (SELECT status FROM shipping_releases WHERE id = q2) <> 'approved'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'shipping_release' AND subject_id = q2
                       AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 224O 失败:审批关着时放行生下来就是 approved、留痕 auto_approved,实得 %', v_res; END IF;
    PERFORM pg_temp.f224_as(u_wh);
    PERFORM ship_order(soD, d, jsonb_build_array(jsonb_build_object('reservation_id', resD)));

    -- ══════════════ P · 故障注入:给队列读者加一列价格 ══════════════
    -- 列清单断言要证明它会咬人:换一支多出 unit_price 的读者,断言必须当场变红。
    DROP FUNCTION public.shipping_queue_rows();
    EXECUTE $inj$
        CREATE FUNCTION public.shipping_queue_rows()
         RETURNS TABLE(sales_order_id uuid, order_code text, order_date date, customer_name text, delivery_address text,
                       released_at timestamp with time zone, sales_order_line_id uuid, line_no integer,
                       material_code text, material_name text, unit text, released_qty numeric, shipped_qty numeric,
                       remaining_qty numeric, reservation_id uuid, output_batch_code text, location_code text,
                       location_name text, reserved_qty numeric, unit_price numeric)
         LANGUAGE sql STABLE AS $f$ SELECT NULL::uuid, NULL, NULL::date, NULL, NULL, NULL::timestamptz, NULL::uuid,
            NULL::int, NULL, NULL, NULL, NULL::numeric, NULL::numeric, NULL::numeric, NULL::uuid, NULL, NULL, NULL,
            NULL::numeric, NULL::numeric WHERE false $f$;
    $inj$;
    IF pg_temp.f224_queue_cols_bad() IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 224P 失败:队列读者多了一列 unit_price,列清单断言却仍然说通过 —— 那条断言在空转'; END IF;

    RAISE NOTICE 'FIXTURE 224 全部通过:A 登记 · B 提放行 · C 提不了 · D 批不了 · E 没有别人 · F CFO 的读者 · G 批准即放行 · H 仓库的队列 · I 仓库发货 · J 冻结 · K 取消的数量 · L 后开票的行 · M 作废失效 · N 撤回 · O 审批关着 · P 注入';
END;
$$;
ROLLBACK;

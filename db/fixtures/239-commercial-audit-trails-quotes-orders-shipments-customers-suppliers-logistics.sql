-- 239 AUDIT-TRAIL-1b-2:商务那一半的审计记录 —— 报价 · 销售订单 · 发货单(M1)· 客户 · 佣金协议 · 供应商 · 货代(M3)·
--     集装箱 · 航段与港口 · 公司执照(只有清单页的三种)(2026-09-30)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1b Step 0 §a 的登记表与 Q1 · Q2 · Q4 · M1 · M3,Tim 2026-09-29 全部照建议裁定)
--   每一个新主语各三样:一次【字段编辑】、一次【子行改动】、一次【关键事件】都在它的审计记录里(按表、按操作、按改了哪一列认)。
--   Q  报价:改备注 · 改明细的数量 · 签发(签发档 + 事件史 issued)· 转成订单(事件史 converted)
--   S  销售订单:改单头备注(改单)· 改明细的数量(改单,事件史 line_update)· 确认 · 签发
--   H  发货单(M1):module.sales.view 或 action.ship_goods 任一个都进得去;两个都不持的按名拒;装箱(container_id)· 送货单签发;
--      明细行只在变更记录里(合成行)也找得到
--   C  客户:改备注 · 加联系人 · 信用(客户那一行 + 信用史);对账单只给财务读 —— 只持客户权限的读者那一行是 row_hidden(Q4)
--   K  佣金协议:改条款 · 删掉(没有子行)
--   P  供应商:改备注 · 加合规证书 · 加联系人 · 送审与批准(状态史 + 审批留痕)
--   F  货代(M3):只持 module.logistics.view 的读者进得去,供应商那一行对他是 row_hidden、物流属性与报价看得见;
--      只持 module.suppliers.view(没有物流的门)的按名拒
--   T  集装箱:改船名 · 加单据并收到 · 里程碑 · 拆箱(那一行里程碑带着理由)
--   L  航段 · 港口 · 执照(只有清单页):航段带着它的单据要求与"清单核过";港口带着从它出发、到它为止的航段(两个外键两行);
--      执照带着状态的改动;物流的人读得到航段与港口、读不到执照;只持供应商权限的读得到执照
--   N  原来的两段"历史"一行不少:报价与订单的事件史(建单之后写的、记录开始之前的)每一行都在审计记录里
--   D  不出现两次:记录开始之前,订单的建单与事件史的 created 是同一刻 → 同一条记录;签发档(so_issues · qt_issues)
--      【不】登记(事件史的 issued 已经说了,Step 0 §a)—— 所以那两张表的"之前"一行都不拼;每一行在一条记录里只出现一次
--
-- 【整支是一笔事务】所以本刀写下的变更记录共享一个 txid —— 每一臂认的是【行】(表 · 操作 · 改了哪一列),不是"分成几条记录";
--   "归成一条"那一半由 D 臂在【记录开始之前】那一段证(拼回来的行按时刻归组,本支把时刻写死)。
--   措辞(每一句英文)不在这里证 —— 数据库不造句;它在 scripts/check-trail-wording.mjs 的"商务样例"那一臂(⑥)逐句钉住。
-- 自带数据(README 第 2 条):账号、角色、员工、客户、供应商、物料、港口、航段全部本支自建。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f239_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f239_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f239_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, p_n) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

-- 这条记录里有没有这一种行:表 · 操作 ·(可选)改了这一列 ·(可选)新影像里包含这一段
CREATE FUNCTION pg_temp.f239_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT jsonb_typeof(p_trail) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                   WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                     AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
                     AND (p_new IS NULL OR e -> 'new' @> p_new))
$f$;

-- 一个读者读得到(没被拒);拒了就把拒绝原样报出来
CREATE FUNCTION pg_temp.f239_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 239 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

-- 一个读者被【按名】拒(不是一张空表)
CREATE FUNCTION pg_temp.f239_refused(p_arm text, p_trail jsonb) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) = 'array' OR p_trail ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 239 %: the reader should be refused by name (TRAIL_NOT_PERMITTED), got %', p_arm, p_trail;
    END IF;
END;
$f$;

-- D:一行在一条记录里只出现一次(记录开始之后按 seq;之前按 表 · 键 · 操作 · 改了哪几列)
CREATE FUNCTION pg_temp.f239_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 持全部码
    u_rel  uuid := gen_random_uuid();   -- 另一个持全部码的人(批准不能是建档人自己)
    u_sales uuid := gen_random_uuid();  -- 只有 module.sales.view
    u_ship uuid := gen_random_uuid();   -- 只有 action.ship_goods
    u_cust uuid := gen_random_uuid();   -- 只有 module.customers.view
    u_sup  uuid := gen_random_uuid();   -- 只有 module.suppliers.view
    u_log  uuid := gen_random_uuid();   -- 只有 module.logistics.view
    u_no   uuid := gen_random_uuid();   -- 一个码都不持
    r_all uuid; r_sales uuid; r_ship uuid; r_cust uuid; r_sup uuid; r_log uuid;
    e_all uuid := gen_random_uuid();
    v_began timestamptz := change_log_began_at();
    t0 timestamptz;
    v_ccy text; v_ct text; v_mat uuid; v_cus uuid; v_sup uuid; v_agent uuid; v_fwd uuid; v_p1 uuid; v_p2 uuid; v_lane uuid;
    v_qt uuid; v_qline uuid; v_so uuid; v_so2 uuid; v_soline uuid; v_shp uuid; v_ctr uuid; v_doc uuid; v_cm uuid; v_lic uuid; v_req uuid;
    v_old_so uuid; v_old_qt uuid; v_old_sup uuid;
    v_r jsonb; v_j jsonb; v_x text; v_n int;
    k_sha constant text := repeat('a', 64);
BEGIN
    -- ══════════════ 布景 ══════════════
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT code INTO v_ct FROM certificate_types ORDER BY sort_order, code LIMIT 1;
    UPDATE finance_settings SET locked_before = NULL, approvals_enabled = false;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx239-all@test.local', now()), (u_rel, 'fx239-rel@test.local', now()), (u_sales, 'fx239-sales@test.local', now()),
        (u_ship, 'fx239-ship@test.local', now()), (u_cust, 'fx239-cust@test.local', now()), (u_sup, 'fx239-sup@test.local', now()),
        (u_log, 'fx239-log@test.local', now()), (u_no, 'fx239-no@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx239-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx239-sales', 'f', 'f', true) RETURNING id INTO r_sales;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx239-ship', 'f', 'f', true) RETURNING id INTO r_ship;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx239-cust', 'f', 'f', true) RETURNING id INTO r_cust;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx239-sup', 'f', 'f', true) RETURNING id INTO r_sup;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx239-log', 'f', 'f', true) RETURNING id INTO r_log;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_sales, 'module.sales.view'), (r_ship, 'action.ship_goods'), (r_cust, 'module.customers.view'),
        (r_sup, 'module.suppliers.view'), (r_log, 'module.logistics.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all, r_all), (u_rel, r_all), (u_sales, r_sales), (u_ship, r_ship), (u_cust, r_cust), (u_sup, r_sup), (u_log, r_log);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, user_id)
    VALUES (e_all, 'FX239-ALL', 'Fixture Two Three Nine', 'Fx239 Tim', 'full_time', 'office', DATE '2020-01-01', 'active', u_all);
    PERFORM pg_temp.f239_as(u_all);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ239-M1', 'Fixture 239 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZ239-C1', 'Fixture 239 Customer', 'SG') RETURNING id INTO v_cus;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('draft', 'ZZ239-S1', 'Fixture 239 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ239-AG', 'Fixture 239 Agent', 'SG', 'service_vendor') RETURNING id INTO v_agent;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ239-FW', 'Fixture 239 Forwarder', 'SG', 'forwarder') RETURNING id INTO v_fwd;
    INSERT INTO ports (code, name, country) VALUES ('ZZ239A', 'Fixture port A', 'SG') RETURNING id INTO v_p1;
    INSERT INTO ports (code, name, country) VALUES ('ZZ239B', 'Fixture port B', 'CN') RETURNING id INTO v_p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_p1, v_p2) RETURNING id INTO v_lane;

    -- ══════════════ Q · 报价 ══════════════
    INSERT INTO quotes (code, customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES ('ZZ239-QT1', v_cus, CURRENT_DATE, CURRENT_DATE + 30, v_ccy, 1) RETURNING id INTO v_qt;
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price) VALUES (v_qt, 1, v_mat, 10, 5) RETURNING id INTO v_qline;
    UPDATE quotes SET notes = 'fixture 239 quote notes' WHERE id = v_qt;
    UPDATE quote_lines SET quantity = 12 WHERE id = v_qline;
    PERFORM record_qt_issue(v_qt, 'quotes/zz239/v1.pdf', k_sha);
    v_r := convert_quote(v_qt, CURRENT_DATE);
    v_j := pg_temp.f239_ok('Q', pg_temp.f239_trail(u_all, 'quote', v_qt::text));
    IF NOT pg_temp.f239_has(v_j, 'quotes', 'UPDATE', 'notes') THEN RAISE EXCEPTION 'FIXTURE 239 Q: the notes edit is missing: %', v_j; END IF;
    IF NOT pg_temp.f239_has(v_j, 'quote_lines', 'UPDATE', 'quantity') THEN RAISE EXCEPTION 'FIXTURE 239 Q: the line change is missing: %', v_j; END IF;
    IF NOT pg_temp.f239_has(v_j, 'qt_issues', 'INSERT') OR NOT pg_temp.f239_has(v_j, 'quote_history', 'INSERT', NULL, '{"change_type": "issued"}')
       OR NOT pg_temp.f239_has(v_j, 'quote_history', 'INSERT', NULL, '{"change_type": "converted"}') THEN
        RAISE EXCEPTION 'FIXTURE 239 Q: the issue / conversion events are missing: %', v_j;
    END IF;
    v_so2 := (v_r ->> 'sales_order_id')::uuid;
    PERFORM pg_temp.f239_refused('Q (no code)', pg_temp.f239_trail(u_no, 'quote', v_qt::text));
    PERFORM pg_temp.f239_refused('Q (customers only)', pg_temp.f239_trail(u_cust, 'quote', v_qt::text));

    -- ══════════════ S · 销售订单 ══════════════
    v_r := create_sales_order(v_cus, CURRENT_DATE, v_ccy, 1, jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10, 'unit_price', 5)));
    v_so := (v_r ->> 'id')::uuid;
    SELECT id INTO v_soline FROM sales_order_lines WHERE sales_order_id = v_so;
    PERFORM set_sales_order_status(v_so, 'confirmed');
    PERFORM amend_sales_order(v_so, 'fixture 239 amend', jsonb_build_object('notes', 'Deliver in one lot'),
        jsonb_build_array(jsonb_build_object('id', v_soline, 'quantity', 8, 'unit_price', 5)));
    PERFORM record_so_issue(v_so, 'sales-orders/zz239/v1.pdf', k_sha);
    v_j := pg_temp.f239_ok('S', pg_temp.f239_trail(u_all, 'sales_order', v_so::text));
    IF NOT pg_temp.f239_has(v_j, 'sales_orders', 'UPDATE', 'notes') THEN RAISE EXCEPTION 'FIXTURE 239 S: the notes amendment is missing: %', v_j; END IF;
    IF NOT pg_temp.f239_has(v_j, 'sales_order_lines', 'UPDATE', 'quantity')
       OR NOT pg_temp.f239_has(v_j, 'sales_order_history', 'INSERT', NULL, '{"change_type": "line_update"}') THEN
        RAISE EXCEPTION 'FIXTURE 239 S: the line amendment is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f239_has(v_j, 'sales_order_history', 'INSERT', NULL, '{"change_type": "confirmed"}') OR NOT pg_temp.f239_has(v_j, 'so_issues', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 239 S: the confirmation / issue events are missing: %', v_j;
    END IF;
    -- N:原来那一段"历史"的每一行都在(这张订单的事件史 + 从报价转来的那一张)
    SELECT string_agg(h.change_type, ', ') INTO v_x FROM sales_order_history h
     WHERE h.sales_order_id IN (v_so, v_so2)
       AND NOT pg_temp.f239_has(pg_temp.f239_trail(u_all, 'sales_order', h.sales_order_id::text), 'sales_order_history', 'INSERT', NULL,
                                jsonb_build_object('change_type', h.change_type));
    IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 239 N: sales-order history rows missing from the trail: %', v_x; END IF;
    SELECT count(*) INTO v_n FROM sales_order_history WHERE sales_order_id = v_so2 AND change_type = 'converted_from_quote';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 239 N: the converted order should carry its converted_from_quote row (got %)', v_n; END IF;
    SELECT string_agg(h.change_type, ', ') INTO v_x FROM quote_history h
     WHERE h.quote_id = v_qt
       AND NOT pg_temp.f239_has(pg_temp.f239_trail(u_all, 'quote', v_qt::text), 'quote_history', 'INSERT', NULL, jsonb_build_object('change_type', h.change_type));
    IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 239 N: quote history rows missing from the trail: %', v_x; END IF;

    -- ══════════════ H · 发货单(M1)══════════════
    INSERT INTO shipments (code, sales_order_id, ship_date) VALUES ('ZZ239-SHP1', v_so, CURRENT_DATE) RETURNING id INTO v_shp;
    PERFORM record_shipment_issue(v_shp, 'shipments/zz239/v1.pdf', k_sha);
    v_r := create_container(v_lane, CURRENT_DATE, 'ZZCU2390001', NULL, NULL, v_fwd);
    v_ctr := (v_r ->> 'id')::uuid;
    PERFORM attach_shipment_to_container(v_shp, v_ctr);
    -- 一行只在变更记录里的发货单明细(它自己的 txid)—— 按影像里的 shipment_id 找得到
    INSERT INTO change_log (occurred_at, txid, table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role, changed_columns, old, new)
    VALUES (now(), 9239001, 'shipment_lines', jsonb_build_object('id', gen_random_uuid()), 'INSERT', u_all, e_all, 'user', 'authenticated', NULL, NULL,
            jsonb_build_object('shipment_id', v_shp, 'qty', 3, 'sales_order_line_id', v_soline));
    v_j := pg_temp.f239_ok('H (sales)', pg_temp.f239_trail(u_sales, 'shipment', v_shp::text));
    IF NOT pg_temp.f239_has(v_j, 'shipments', 'UPDATE', 'container_id') OR NOT pg_temp.f239_has(v_j, 'shipment_issues', 'INSERT')
       OR NOT pg_temp.f239_has(v_j, 'shipment_lines', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 239 H: packing into a container / the delivery note / the line is missing: %', v_j;
    END IF;
    v_j := pg_temp.f239_ok('H (ship_goods only, M1)', pg_temp.f239_trail(u_ship, 'shipment', v_shp::text));
    IF NOT pg_temp.f239_has(v_j, 'shipments', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 239 H: the shipper should see the shipment itself: %', v_j; END IF;
    PERFORM pg_temp.f239_refused('H (no code)', pg_temp.f239_trail(u_no, 'shipment', v_shp::text));
    PERFORM pg_temp.f239_refused('H (logistics only)', pg_temp.f239_trail(u_log, 'shipment', v_shp::text));

    -- ══════════════ C · 客户 ══════════════
    UPDATE customers SET notes = 'fixture 239 customer notes' WHERE id = v_cus;
    PERFORM save_counterparty_contact(p_customer_id => v_cus, p_name => 'Ada Fixture', p_email => 'ada@fixture.test', p_is_primary => true);
    PERFORM set_customer_credit(v_cus, 5000, true);
    -- 一张对账单(只给财务读)—— 合成的变更记录行,它自己的 txid
    INSERT INTO change_log (occurred_at, txid, table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role, changed_columns, old, new)
    VALUES (now(), 9239002, 'customer_statements', jsonb_build_object('id', gen_random_uuid()), 'INSERT', u_all, e_all, 'user', 'authenticated', NULL, NULL,
            jsonb_build_object('customer_id', v_cus, 'code', 'STMT-ZZ239', 'period_start', CURRENT_DATE - 30, 'period_end', CURRENT_DATE));
    v_j := pg_temp.f239_ok('C', pg_temp.f239_trail(u_all, 'customer', v_cus::text));
    IF NOT pg_temp.f239_has(v_j, 'customers', 'UPDATE', 'notes') OR NOT pg_temp.f239_has(v_j, 'counterparty_contacts', 'INSERT')
       OR NOT pg_temp.f239_has(v_j, 'customers', 'UPDATE', 'credit_hold') OR NOT pg_temp.f239_has(v_j, 'customer_credit_history', 'INSERT')
       OR NOT pg_temp.f239_has(v_j, 'customer_statements', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 239 C: an edit / the contact / the credit change / the statement is missing: %', v_j;
    END IF;
    v_j := pg_temp.f239_ok('C (customers only)', pg_temp.f239_trail(u_cust, 'customer', v_cus::text));
    IF pg_temp.f239_has(v_j, 'customer_statements', 'INSERT')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 239 C: a statement must be a Restricted row for a reader without finance (Q4), got %', v_j;
    END IF;
    IF NOT pg_temp.f239_has(v_j, 'counterparty_contacts', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 239 C: the customer reader should see the contact: %', v_j; END IF;
    PERFORM pg_temp.f239_refused('C (sales only)', pg_temp.f239_trail(u_sales, 'customer', v_cus::text));

    -- ══════════════ K · 佣金协议 ══════════════
    INSERT INTO commission_agreements (agent_supplier_id, side, basis, rate_pct, recognition_trigger, valid_from, valid_to)
    VALUES (v_agent, 'sale', 'percentage_of_value', 2, 'on_invoice', CURRENT_DATE, CURRENT_DATE + 365) RETURNING id INTO v_cm;
    UPDATE commission_agreements SET remarks = 'fixture 239 clause' WHERE id = v_cm;
    UPDATE commission_agreements SET deleted_at = now() WHERE id = v_cm;
    v_j := pg_temp.f239_ok('K', pg_temp.f239_trail(u_sup, 'commission_agreement', v_cm::text));
    IF NOT pg_temp.f239_has(v_j, 'commission_agreements', 'INSERT') OR NOT pg_temp.f239_has(v_j, 'commission_agreements', 'UPDATE', 'remarks')
       OR NOT pg_temp.f239_has(v_j, 'commission_agreements', 'UPDATE', 'deleted_at') THEN
        RAISE EXCEPTION 'FIXTURE 239 K: the agreement, its clause edit or its deletion is missing: %', v_j;
    END IF;
    PERFORM pg_temp.f239_refused('K (sales only)', pg_temp.f239_trail(u_sales, 'commission_agreement', v_cm::text));

    -- ══════════════ P · 供应商 ══════════════
    UPDATE suppliers SET notes = 'fixture 239 supplier notes' WHERE id = v_sup;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (v_sup, v_ct, 'ZZ239-CERT', CURRENT_DATE, CURRENT_DATE + 365);
    PERFORM save_counterparty_contact(p_supplier_id => v_sup, p_name => 'Bo Fixture', p_phone => '+65 6000 0239');
    PERFORM set_supplier_status(v_sup, 'pending_review', 'ready for review');
    PERFORM pg_temp.f239_as(u_rel);   -- 建档人不能批自己建的
    PERFORM set_supplier_status(v_sup, 'approved', 'licence checked');
    PERFORM pg_temp.f239_as(u_all);
    v_j := pg_temp.f239_ok('P', pg_temp.f239_trail(u_sup, 'supplier', v_sup::text));
    IF NOT pg_temp.f239_has(v_j, 'suppliers', 'UPDATE', 'notes') OR NOT pg_temp.f239_has(v_j, 'supplier_compliance', 'INSERT')
       OR NOT pg_temp.f239_has(v_j, 'counterparty_contacts', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 239 P: an edit / the certificate / the contact is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f239_has(v_j, 'suppliers', 'UPDATE', 'status')
       OR NOT pg_temp.f239_has(v_j, 'supplier_status_history', 'INSERT', NULL, '{"to_status": "pending_review"}')
       OR NOT pg_temp.f239_has(v_j, 'supplier_status_history', 'INSERT', NULL, '{"to_status": "approved"}')
       OR NOT pg_temp.f239_has(v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "supplier", "decision": "approved"}') THEN
        RAISE EXCEPTION 'FIXTURE 239 P: the review / approval steps are missing: %', v_j;
    END IF;
    PERFORM pg_temp.f239_refused('P (logistics only)', pg_temp.f239_trail(u_log, 'supplier', v_sup::text));

    -- ══════════════ F · 货代(M3)══════════════
    INSERT INTO forwarder_details (supplier_id, main_routes) VALUES (v_fwd, 'SG → CN');
    UPDATE forwarder_details SET main_routes = 'SG → CN, SG → KR' WHERE supplier_id = v_fwd;
    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency, valid_from, valid_to, free_days)
    VALUES (v_fwd, v_lane, 1200, v_ccy, CURRENT_DATE, CURRENT_DATE + 90, 5);
    v_j := pg_temp.f239_ok('F (logistics only, M3)', pg_temp.f239_trail(u_log, 'forwarder', v_fwd::text));
    IF NOT pg_temp.f239_has(v_j, 'forwarder_details', 'UPDATE', 'main_routes') OR NOT pg_temp.f239_has(v_j, 'forwarder_rate_quotes', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 239 F: the logistics reader should see the details change and the rate quote: %', v_j;
    END IF;
    IF pg_temp.f239_has(v_j, 'suppliers', 'INSERT')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 239 F: the supplier row must be Restricted for a reader without suppliers.view (M3), got %', v_j;
    END IF;
    v_j := pg_temp.f239_ok('F (all)', pg_temp.f239_trail(u_all, 'forwarder', v_fwd::text));
    IF NOT pg_temp.f239_has(v_j, 'suppliers', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 239 F: a reader with suppliers.view sees the root row: %', v_j; END IF;
    PERFORM pg_temp.f239_refused('F (suppliers only — no logistics door)', pg_temp.f239_trail(u_sup, 'forwarder', v_fwd::text));

    -- ══════════════ T · 集装箱 ══════════════
    UPDATE containers SET vessel = 'MV Fixture' WHERE id = v_ctr;
    INSERT INTO container_documents (container_id, document_type, status) VALUES (v_ctr, 'Import permit', 'pending') RETURNING id INTO v_doc;
    UPDATE container_documents SET status = 'received' WHERE id = v_doc;
    INSERT INTO container_milestones (container_id, milestone, event_date, note) VALUES (v_ctr, 'departed', CURRENT_DATE, 'sailed');
    PERFORM detach_shipment_from_container(v_shp, 'wrong box');
    v_j := pg_temp.f239_ok('T', pg_temp.f239_trail(u_log, 'container', v_ctr::text));
    IF NOT pg_temp.f239_has(v_j, 'containers', 'UPDATE', 'vessel') OR NOT pg_temp.f239_has(v_j, 'container_documents', 'UPDATE', 'status')
       OR NOT pg_temp.f239_has(v_j, 'container_milestones', 'INSERT', NULL, '{"milestone": "departed"}')
       OR NOT pg_temp.f239_has(v_j, 'container_milestones', 'INSERT', NULL, jsonb_build_object('milestone', 'other', 'note', 'detached ZZ239-SHP1: wrong box')) THEN
        RAISE EXCEPTION 'FIXTURE 239 T: an edit / the document / a milestone / the detachment is missing: %', v_j;
    END IF;
    PERFORM pg_temp.f239_refused('T (sales only)', pg_temp.f239_trail(u_sales, 'container', v_ctr::text));

    -- ══════════════ L · 航段 · 港口 · 执照(只有清单页)══════════════
    INSERT INTO lane_document_requirements (lane_id, document_type, regime) VALUES (v_lane, 'Import permit', 'Basel') RETURNING id INTO v_req;
    UPDATE lanes SET checklist_reviewed_at = now() WHERE id = v_lane;
    UPDATE ports SET name = 'Fixture port A (renamed)' WHERE id = v_p1;
    v_j := pg_temp.f239_ok('L (lane)', pg_temp.f239_trail(u_log, 'lane', v_lane::text));
    IF NOT pg_temp.f239_has(v_j, 'lanes', 'INSERT') OR NOT pg_temp.f239_has(v_j, 'lanes', 'UPDATE', 'checklist_reviewed_at')
       OR NOT pg_temp.f239_has(v_j, 'lane_document_requirements', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 239 L: the lane, its checklist review or its requirement is missing: %', v_j;
    END IF;
    v_j := pg_temp.f239_ok('L (origin port)', pg_temp.f239_trail(u_log, 'port', v_p1::text));
    IF NOT pg_temp.f239_has(v_j, 'ports', 'UPDATE', 'name') OR NOT pg_temp.f239_has(v_j, 'lanes', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 239 L: the origin port should carry its rename and the lane leaving it: %', v_j;
    END IF;
    v_j := pg_temp.f239_ok('L (destination port)', pg_temp.f239_trail(u_log, 'port', v_p2::text));
    IF NOT pg_temp.f239_has(v_j, 'lanes', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 239 L: the destination port should carry the lane arriving at it: %', v_j; END IF;
    INSERT INTO company_compliance (cert_type_code, cert_no, status, issuing_body) VALUES (v_ct, 'ZZ239-LIC', 'active', 'NEA') RETURNING id INTO v_lic;
    UPDATE company_compliance SET status = 'suspended' WHERE id = v_lic;
    v_j := pg_temp.f239_ok('L (licence)', pg_temp.f239_trail(u_sup, 'company_licence', v_lic::text));
    IF NOT pg_temp.f239_has(v_j, 'company_compliance', 'INSERT') OR NOT pg_temp.f239_has(v_j, 'company_compliance', 'UPDATE', 'status') THEN
        RAISE EXCEPTION 'FIXTURE 239 L: the licence or its standing change is missing: %', v_j;
    END IF;
    PERFORM pg_temp.f239_refused('L (licence, logistics only)', pg_temp.f239_trail(u_log, 'company_licence', v_lic::text));
    PERFORM pg_temp.f239_refused('L (lane, no code)', pg_temp.f239_trail(u_no, 'lane', v_lane::text));

    -- ══════════════ D · 记录开始之前:同一刻的建单与事件史 → 一条;签发档不登记 → 不出现两次 ══════════════
    t0 := v_began - interval '10 days';
    SET LOCAL session_replication_role = replica;   -- 只为拼出"记录开始之前"的样子:不写变更记录、不跑事件史触发器
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, status, cancel_reason, created_at, created_by)
    VALUES ('ZZ239-SO-OLD', v_cus, (t0)::date, v_ccy, 1, 'cancelled', 'fixture 239 old order', t0, u_all) RETURNING id INTO v_old_so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price, created_at) VALUES (v_old_so, 1, v_mat, 5, 7, t0);
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_at, changed_by) VALUES
        (v_old_so, 'created', 'ZZ239-SO-OLD', t0, u_all),
        (v_old_so, 'confirmed', NULL, t0 + interval '1 hour', u_all),
        (v_old_so, 'issued', 'v1', t0 + interval '2 hours', u_all),
        (v_old_so, 'invoiced', 'INV-2026-9239', t0 + interval '3 hours', u_all),
        (v_old_so, 'shipped', 'SHP-2026-9239 · 5/5', t0 + interval '4 hours', u_all),
        (v_old_so, 'cancelled', 'fixture 239 old order', t0 + interval '5 hours', u_all);
    INSERT INTO so_issues (sales_order_id, version, file_path, sha256, issued_at, issued_by)
    VALUES (v_old_so, 1, 'sales-orders/zz239-old/v1.pdf', k_sha, t0 + interval '2 hours', u_all);
    INSERT INTO quotes (code, customer_id, quote_date, valid_until, currency, fx_rate, status, created_at, created_by)
    VALUES ('ZZ239-QT-OLD', v_cus, (t0)::date, (t0)::date + 30, v_ccy, 1, 'issued', t0, u_all) RETURNING id INTO v_old_qt;
    INSERT INTO quote_history (quote_id, change_type, detail, changed_at, changed_by) VALUES
        (v_old_qt, 'created', 'ZZ239-QT-OLD', t0, u_all), (v_old_qt, 'issued', 'v1', t0 + interval '1 hour', u_all);
    INSERT INTO qt_issues (quote_id, version, file_path, sha256, issued_at, issued_by)
    VALUES (v_old_qt, 1, 'quotes/zz239-old/v1.pdf', k_sha, t0 + interval '1 hour 15 ms', u_all);
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, created_at, created_by, approved_at, approved_by)
    VALUES ('approved', 'ZZ239-S-OLD', 'Fixture 239 old supplier', 'SG', 'goods_supplier', t0, u_all, t0 + interval '1 day', u_rel) RETURNING id INTO v_old_sup;
    SET LOCAL session_replication_role = origin;

    v_j := pg_temp.f239_ok('D (old order)', pg_temp.f239_trail(u_all, 'sales_order', v_old_so::text));
    -- 订单的建单(拼回来的 INSERT)与事件史的 created 在同一条记录里
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) a, jsonb_array_elements(v_j) b
                    WHERE a ->> 'table_name' = 'sales_orders' AND a ->> 'op' = 'INSERT' AND (a ->> 'prelog')::boolean
                      AND b ->> 'table_name' = 'sales_order_history' AND b -> 'new' ->> 'change_type' = 'created'
                      AND a ->> 'entry_no' = b ->> 'entry_no') THEN
        RAISE EXCEPTION 'FIXTURE 239 D: the pre-log order creation and its history row should be one entry: %', v_j;
    END IF;
    -- N(记录开始之前那一段):六行事件史一行不少
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'sales_order_history' AND (e ->> 'prelog')::boolean;
    IF v_n <> 6 THEN RAISE EXCEPTION 'FIXTURE 239 N: the old order''s six history rows should all be there, got % in %', v_n, v_j; END IF;
    -- 签发档不登记(事件史的 issued 已经说了):so_issues 一行都不拼
    IF pg_temp.f239_has(v_j, 'so_issues', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 239 D: so_issues must not be rebuilt before the log (shown twice): %', v_j; END IF;
    v_x := pg_temp.f239_twice(v_j);
    IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 239 D: rows shown twice in the old order''s trail: %', v_x; END IF;

    v_j := pg_temp.f239_ok('D (old quote)', pg_temp.f239_trail(u_all, 'quote', v_old_qt::text));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) a, jsonb_array_elements(v_j) b
                    WHERE a ->> 'table_name' = 'quotes' AND a ->> 'op' = 'INSERT' AND (a ->> 'prelog')::boolean
                      AND b ->> 'table_name' = 'quote_history' AND b -> 'new' ->> 'change_type' = 'created'
                      AND a ->> 'entry_no' = b ->> 'entry_no') THEN
        RAISE EXCEPTION 'FIXTURE 239 D: the pre-log quote creation and its history row should be one entry: %', v_j;
    END IF;
    IF pg_temp.f239_has(v_j, 'qt_issues', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 239 D: qt_issues must not be rebuilt before the log (shown twice): %', v_j; END IF;
    IF NOT pg_temp.f239_has(v_j, 'quote_history', 'INSERT', NULL, '{"change_type": "issued"}') THEN
        RAISE EXCEPTION 'FIXTURE 239 N: the old quote''s issue (its history row) is missing: %', v_j;
    END IF;

    v_j := pg_temp.f239_ok('D (old supplier)', pg_temp.f239_trail(u_all, 'supplier', v_old_sup::text));
    IF NOT pg_temp.f239_has(v_j, 'suppliers', 'UPDATE', 'approved_at') THEN
        RAISE EXCEPTION 'FIXTURE 239 D: a supplier approved before the log should be rebuilt from its approved_at stamp: %', v_j;
    END IF;

    -- D(记录开始之后):上面每一条读过的记录里,一行都不出现两次
    FOR v_x IN SELECT pg_temp.f239_twice(pg_temp.f239_trail(u_all, s, i::text)) FROM (VALUES
        ('quote', v_qt), ('sales_order', v_so), ('sales_order', v_so2), ('shipment', v_shp), ('customer', v_cus), ('commission_agreement', v_cm),
        ('supplier', v_sup), ('forwarder', v_fwd), ('container', v_ctr), ('lane', v_lane), ('port', v_p1), ('company_licence', v_lic)) t(s, i) LOOP
        IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 239 D: rows shown twice: %', v_x; END IF;
    END LOOP;

    RAISE NOTICE 'FIXTURE 239 全部通过:Q · S · H(M1)· C · K · P · F(M3)· T · L · N · D';
END;
$$;

ROLLBACK;

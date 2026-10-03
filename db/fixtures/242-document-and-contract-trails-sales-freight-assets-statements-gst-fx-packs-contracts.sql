-- 242 AUDIT-TRAIL-1c-2:其余单据与合同的审计记录 —— 销售 · 运费单 · 资产(财务那一页)· 对账单 · GST 期间 · 汇率 · 管理包 · 合同;
--     外加 1c-1 留下的缺口:付款申请与贷项通知的【字段编辑】(2026-10-04)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1c Step 0 §a 的登记表与 Q6 · Q7 · Q9 · Q10 · Q14 · Q21 · Q22 · Q23 · Q24 · Q25,Tim 2026-10-03 全部照建议)
--   每一个主语一次字段编辑 · 一次子行改动 · 一次关键事件(能改的照常改;不能改的 —— 销售、管理包 —— 证它【按名拒】,
--   那就是它没有"字段编辑"这一样的原因);每一条记录:一行只出现一次。
--   S   销售(Q14):记销售(出库同一笔)· 归属客户(字段编辑 + 归属留痕子行)· 销售不可直改(按名拒);
--       /settings/change-history 的 Record 一栏:销售那一行与它的归属留痕都归到【这一笔销售】,链到应收页
--   F   运费单:记账(分摊 = 子行)· 改备注(字段编辑)· 冲销(关键事件,冲销分录往上一跳够得到);
--       Q9:记录开始之前的冲销,那一戳是那件事唯一的记录 —— 拼回来
--   A   资产(Q10):建卡(资产卡 + 修改史 'created',一件事两行 —— 两行同一个 op_key)· 改使用年限(字段编辑)·
--       追加成本(费用 → 成本条目 = 子行)· 处置申请 → CFO 批准(关键事件:申请、审批留痕、资产翻 disposed 同一笔);
--       记录开始之前的修改史那一行拼得回来
--   B   对账单(Q6 · Q24):导入(行 = 子行)· 忽略一行(子行改动)· 对账(关键事件:对账单翻 reconciled + 一行对账记录同一笔)·
--       撤销对账(备注后面那一截机器字与对账记录被取代同一笔)· 改备注(字段编辑);删掉的那一张:记录照样读得到,
--       deleted_records 列出它、"谁"取自变更记录;Q9:记录开始之前的对账,那一戳拼得回来
--   G   GST 期间(Q22 · Q23):开期(关键事件)· 改备注(字段编辑)· 申报申请 → CFO 批准(子行;抄下来的每一格与批准同一个 op_key)·
--       记下申报;为它开的更正件【不】出现在原件的记录里,更正件自己的记录以它的建立(corrects_period_id)开头
--   X   汇率(Q7):录入(汇率 + 修改史 'created' 同一笔)· 更正(字段编辑,带理由)· 撤回(关键事件);撤回之后,只持
--       module.finance.view 的读者照样读得到它的记录(Q7:对本来的读者只读打开)
--   K   管理包(Q25):产出(关键事件)· 再产出一份取代它(旧那一份翻 superseded —— 新那一份的建立【不】挂在旧的上面)·
--       管理包不可改(按名拒)
--   C   合同(Q21):建立(关键事件)· 改标题(字段编辑)· 加一条计价条款(子行)· 生效申请 → CFO 批准(合同翻 active);
--       不持 module.pricing.view 的合同读者:CFO 的决定那几行是 Restricted,合同与条款照常看得见
--   P   1c-1 的缺口:付款申请 —— 一个读者直接改它落不了地(RLS 没有 UPDATE 的策略:零行,不报错);一次系统写入(数据修补)
--       在记录里是一次字段编辑(改了哪一列);贷项通知 —— 任何改动按名拒(CREDIT_NOTE_IMMUTABLE),变更记录一行都不多
-- 【整支是一笔事务】措辞(每一句英文)不在这里证 —— 它在 scripts/check-trail-wording.mjs 的 ⑨ 其余的单据与合同那一臂。
-- 自带数据(README 第 2 条):账号、角色、客户、供应商、货代、物料、批次、合同全部本支自建;科目、币种是稳定的引导数据。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f242_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f242_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f242_as(p_user);
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

CREATE FUNCTION pg_temp.f242_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 242 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

-- 这条记录里有没有这一种行:表 · 操作 ·(可选)改了这一列 ·(可选)新影像里包含这一段
CREATE FUNCTION pg_temp.f242_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT jsonb_typeof(p_trail) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                   WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                     AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
                     AND (p_new IS NULL OR e -> 'new' @> p_new))
$f$;

CREATE FUNCTION pg_temp.f242_need(p_arm text, p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF NOT pg_temp.f242_has(p_trail, p_table, p_op, p_col, p_new) THEN
        RAISE EXCEPTION 'FIXTURE 242 %: expected a % % row% in the trail, got %', p_arm, p_table, p_op,
            COALESCE(' changing ' || p_col, '') || COALESCE(' with ' || p_new::text, ''), p_trail;
    END IF;
END;
$f$;

-- 一行在一条记录里只出现一次
CREATE FUNCTION pg_temp.f242_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 持全部码:建单、提申请
    u_sup  uuid := gen_random_uuid();   -- 建供应商 / 货代的人
    u_cfo  uuid := gen_random_uuid();   -- 二级审批角色
    u_l1   uuid := gen_random_uuid();   -- 一级审批角色
    u_fin  uuid := gen_random_uuid();   -- 只有 module.finance.view + 价格码(Q7:撤回的汇率照样读得到)
    u_con  uuid := gen_random_uuid();   -- 合同的读者:module.suppliers.view,不持 module.pricing.view(Q21)
    r_all uuid; r_l1 uuid; r_l2 uuid; r_fin uuid; r_con uuid;
    v_base text; v_acct text; v_began timestamptz := change_log_began_at(); t0 timestamptz;
    d date := CURRENT_DATE - 1;
    v_res jsonb; v_j jsonb; v_j2 jsonb; v_x text; v_n int; v_k text; v_k2 text; v_rec jsonb;
    v_sup uuid; v_fwd uuid; v_cust uuid; v_mat uuid;
    ob uuid; sale uuid; ib1 uuid; ib2 uuid; frt uuid; frt2 uuid; frt_je uuid; frt_rev uuid;
    fa uuid; exp1 uuid; adr uuid;
    bs1 uuid; bs2 uuid; bs3 uuid; bl1 uuid; bl2 uuid;
    gp uuid; gp_c uuid; gfr uuid;
    fx uuid; pk1 uuid; pk2 uuid;
    con uuid; tr uuid;
    so1 uuid; l1 uuid; inv1 uuid; il1 uuid; v_cn uuid; pr uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    IF v_base IS NULL OR v_acct IS NULL THEN RAISE EXCEPTION 'FIXTURE 242 布景失败:缺本位币或费用科目'; END IF;
    t0 := v_began - interval '10 days';

    -- ══════════════ 布景 ══════════════
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx242-all@test.local', now()), (u_sup, 'fx242-sup@test.local', now()), (u_cfo, 'fx242-cfo@test.local', now()),
        (u_l1, 'fx242-l1@test.local', now()), (u_fin, 'fx242-fin@test.local', now()), (u_con, 'fx242-con@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx242-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx242-l1', 'f', 'f', true) RETURNING id INTO r_l1;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx242-l2', 'f', 'f', true) RETURNING id INTO r_l2;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx242-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx242-con', 'f', 'f', true) RETURNING id INTO r_con;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, code FROM permissions, unnest(ARRAY[r_all, r_l1, r_l2]) r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.view'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices'),
        (r_con, 'module.suppliers.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_sup, r_all), (u_cfo, r_l2), (u_l1, r_l1), (u_fin, r_fin), (u_con, r_con);
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx242-l1', approval_level2_role_code = 'fx242-l2', approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    PERFORM pg_temp.f242_as(u_sup);
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'FX242-SUP', 'FX242 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'FX242-FWD', 'FX242 Forwarder', 'SG', 'forwarder') RETURNING id INTO v_fwd;
    PERFORM pg_temp.f242_as(u_all);
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ242-C1', 'fixture 242 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ242-M', 'f242 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    -- ══════════════ S · 销售(Q14)══════════════
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES ('ZZ242-OB', v_mat, 1000, 1000, d) RETURNING id INTO ob;
    sale := (record_output_sale(ob, 100, 10, v_base, NULL, NULL, d, 'fixture 242 walk-in', 'manual', NULL) ->> 'sale_id')::uuid;
    IF sale IS NULL THEN RAISE EXCEPTION 'FIXTURE 242 布景:销售没有记上'; END IF;
    PERFORM attribute_sale_customer(sale, v_cust, 'fixture 242 it was Acme');
    v_j := pg_temp.f242_ok('S', pg_temp.f242_trail(u_all, 'sale', sale::text));
    PERFORM pg_temp.f242_need('S (key event: recorded)', v_j, 'sales_records', 'INSERT');
    PERFORM pg_temp.f242_need('S (child: the stock movement of the sale)', v_j, 'sales_record_movements', 'INSERT');
    PERFORM pg_temp.f242_need('S (field edit: customer attributed)', v_j, 'sales_records', 'UPDATE', 'customer_id');
    PERFORM pg_temp.f242_need('S (child: the attribution log)', v_j, 'sales_attribution_log', 'INSERT');
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 S: shown twice: %', v_x; END IF;
    -- 销售不可直改(除了归属客户、成本分录这两件由函数写的事)—— 没有别的"字段编辑"
    BEGIN
        UPDATE sales_records SET notes = 'x' WHERE id = sale;
        RAISE EXCEPTION 'FIXTURE 242 S: a sale''s notes could be edited directly';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FIXTURE 242%' THEN RAISE; END IF;
    END;
    -- Q14:Record 一栏 —— 销售那一行与它的归属留痕都归到这一笔销售,链到应收页
    v_rec := trail_row_record('sales_records', jsonb_build_object('id', sale), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'sales_records' OR v_rec ->> 'route' IS DISTINCT FROM '/finance/receivables' OR v_rec ->> 'link_mode' IS DISTINCT FROM 'detail'
       OR COALESCE(v_rec ->> 'label', '') NOT LIKE 'ZZ242-OB sale %' THEN
        RAISE EXCEPTION 'FIXTURE 242 S (Q14): the sale''s Record should be itself, named and linked to its receivable page, got %', v_rec; END IF;
    v_rec := trail_row_record('sales_attribution_log', jsonb_build_object('id', (SELECT id FROM sales_attribution_log WHERE sales_record_id = sale LIMIT 1)), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'sales_records' OR v_rec ->> 'id' IS DISTINCT FROM sale::text THEN
        RAISE EXCEPTION 'FIXTURE 242 S (Q14): the attribution log should home to the sale (not the output batch), got %', v_rec; END IF;

    -- ══════════════ F · 运费单 ══════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZ242-IB1', v_mat, v_sup, 100, 100, 'kg', d, 10, 'other', 'fixture 242') RETURNING id INTO ib1;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZ242-IB2', v_mat, v_sup, 50, 50, 'kg', d, 10, 'other', 'fixture 242') RETURNING id INTO ib2;
    frt := (record_freight_document(d, v_fwd, 300, v_base, 'weight', 'unpaid', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', ib1), jsonb_build_object('inbound_batch_id', ib2)), 'fixture 242 port to yard', NULL)
            ->> 'freight_document_id')::uuid;
    UPDATE freight_documents SET notes = 'fixture 242 port to yard (corrected)' WHERE id = frt;
    PERFORM reverse_freight_document(frt, 'fixture 242 billed twice');
    SELECT journal_entry_id, reversal_entry_id INTO frt_je, frt_rev FROM freight_documents WHERE id = frt;
    v_j := pg_temp.f242_ok('F', pg_temp.f242_trail(u_all, 'freight', frt::text));
    PERFORM pg_temp.f242_need('F (recorded)', v_j, 'freight_documents', 'INSERT');
    PERFORM pg_temp.f242_need('F (child: the apportionment)', v_j, 'freight_allocations', 'INSERT');
    PERFORM pg_temp.f242_need('F (field edit: notes)', v_j, 'freight_documents', 'UPDATE', 'notes');
    PERFORM pg_temp.f242_need('F (key event: reversed)', v_j, 'freight_documents', 'UPDATE', 'reversed_at');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'journal_entries' AND e -> 'row_key' ->> 'id' = frt_rev::text) THEN
        RAISE EXCEPTION 'FIXTURE 242 F: the reversal journal is not on the freight document''s trail: %', v_j; END IF;
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 F: shown twice: %', v_x; END IF;
    v_rec := trail_row_record('freight_allocations', jsonb_build_object('id', (SELECT id FROM freight_allocations WHERE freight_document_id = frt LIMIT 1)), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'freight_documents' THEN
        RAISE EXCEPTION 'FIXTURE 242 F: a freight allocation should home to its freight document, got %', v_rec; END IF;
    -- Q9:记录开始之前的冲销 —— 那一戳是唯一的记录
    frt2 := (record_freight_document(d, v_fwd, 100, v_base, 'weight', 'unpaid', NULL,
             jsonb_build_array(jsonb_build_object('inbound_batch_id', ib1)), 'fixture 242 old one', NULL) ->> 'freight_document_id')::uuid;
    SET LOCAL session_replication_role = replica;
    UPDATE freight_documents SET status = 'reversed', reversed_at = t0, reversed_by = u_all, reversal_reason = 'fixture 242 old reversal' WHERE id = frt2;
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f242_ok('F (Q9)', pg_temp.f242_trail(u_all, 'freight', frt2::text));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'freight_documents' AND (e ->> 'prelog')::boolean
                      AND e -> 'changed_columns' ? 'reversed_at' AND e -> 'new' ->> 'reversal_reason' = 'fixture 242 old reversal') THEN
        RAISE EXCEPTION 'FIXTURE 242 F (Q9): a freight reversal before the log should come back from its stamp: %', v_j; END IF;

    -- ══════════════ A · 资产(Q10)══════════════
    fa := (create_fixed_asset('fixture 242 shredder', 60, d, 'equipment', '6700', 'fixture 242') ->> 'asset_id')::uuid;
    UPDATE fixed_assets SET useful_life_months = 84 WHERE id = fa;
    exp1 := (record_expense(d, '1500', 500, v_base, NULL, 'unpaid', NULL, v_sup, NULL, 'fixture 242 install', jsonb_build_object('asset_id', fa)) ->> 'expense_id')::uuid;
    PERFORM set_asset_in_service(fa, d);
    adr := (submit_asset_disposal_request(fa, 0, NULL, 'fixture 242 scrapped') ->> 'request_id')::uuid;
    PERFORM pg_temp.f242_as(u_cfo);
    PERFORM decide_asset_disposal_request(adr, true, 'fine');
    PERFORM pg_temp.f242_as(u_all);
    IF (SELECT status FROM fixed_assets WHERE id = fa) IS DISTINCT FROM 'disposed' THEN RAISE EXCEPTION 'FIXTURE 242 布景:处置批准之后资产应当已处置'; END IF;
    v_j := pg_temp.f242_ok('A', pg_temp.f242_trail(u_all, 'fixed_asset', fa::text));
    PERFORM pg_temp.f242_need('A (card created)', v_j, 'fixed_assets', 'INSERT');
    -- 一件事两行:建卡与修改史 'created' 在同一笔 —— 同一个 op_key(界面只说一次)
    SELECT e ->> 'op_key' INTO v_k FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'fixed_assets' AND e ->> 'op' = 'INSERT';
    SELECT e ->> 'op_key' INTO v_k2 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'fixed_asset_history' AND e -> 'new' ->> 'change_type' = 'created';
    IF v_k IS NULL OR v_k IS DISTINCT FROM v_k2 THEN
        RAISE EXCEPTION 'FIXTURE 242 A: the card and its history row ''created'' should be one operation: % vs %', v_k, v_k2; END IF;
    PERFORM pg_temp.f242_need('A (field edit: useful life)', v_j, 'fixed_assets', 'UPDATE', 'useful_life_months');
    PERFORM pg_temp.f242_need('A (child: the cost entry)', v_j, 'fixed_asset_cost_entries', 'INSERT');
    PERFORM pg_temp.f242_need('A (put into service)', v_j, 'fixed_assets', 'UPDATE', 'in_service_date');
    PERFORM pg_temp.f242_need('A (key event: the disposal request)', v_j, 'asset_disposal_requests', 'INSERT');
    PERFORM pg_temp.f242_need('A (key event: its approval)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "asset_disposal_request", "decision": "approved"}');
    PERFORM pg_temp.f242_need('A (key event: disposed)', v_j, 'fixed_assets', 'UPDATE', 'status', '{"status": "disposed"}');
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 A: shown twice: %', v_x; END IF;
    v_rec := trail_row_record('fixed_asset_cost_entries', jsonb_build_object('id', (SELECT id FROM fixed_asset_cost_entries WHERE asset_id = fa LIMIT 1)), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'fixed_assets' THEN
        RAISE EXCEPTION 'FIXTURE 242 A: an asset cost entry should home to its asset, got %', v_rec; END IF;
    -- 记录开始之前的一次修改:修改史那一行拼回来,带着它那一对 old_ / new_ 列
    SET LOCAL session_replication_role = replica;
    INSERT INTO fixed_asset_history (fixed_asset_id, change_type, changed_columns, changed_at, changed_by, changed_by_kind,
                                     old_useful_life_months, new_useful_life_months)
    VALUES (fa, 'updated', ARRAY['useful_life_months'], t0, u_all, 'user', 48, 60);
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f242_ok('A (pre-log)', pg_temp.f242_trail(u_all, 'fixed_asset', fa::text));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'fixed_asset_history' AND (e ->> 'prelog')::boolean
                      AND (e -> 'new' ->> 'new_useful_life_months')::int = 60) THEN
        RAISE EXCEPTION 'FIXTURE 242 A (Q10): a history row from before the log should come back: %', v_j; END IF;
    -- 加工那一页的 equipment 主语不受影响(同一张根表,两个主语)
    PERFORM pg_temp.f242_ok('A (the equipment subject still reads the same root)', pg_temp.f242_trail(u_all, 'equipment', fa::text));

    -- ══════════════ B · 对账单(Q6 · Q24)══════════════
    bs1 := (import_bank_statement('1000', d - 5, d, 1000, 1300, 'fx242.csv', jsonb_build_array(
            jsonb_build_object('line_date', d - 2, 'amount', 200, 'description', 'fixture 242 in'),
            jsonb_build_object('line_date', d - 1, 'amount', 100, 'description', 'fixture 242 in 2'))) ->> 'statement_id')::uuid;
    IF bs1 IS NULL THEN RAISE EXCEPTION 'FIXTURE 242 布景:对账单没有导入'; END IF;
    SELECT id INTO bl1 FROM bank_statement_lines WHERE statement_id = bs1 AND line_no = 1;
    SELECT id INTO bl2 FROM bank_statement_lines WHERE statement_id = bs1 AND line_no = 2;
    UPDATE bank_statements SET notes = 'fixture 242 re-checked' WHERE id = bs1;
    PERFORM ignore_bank_line(bl1, 'fixture 242 interest');
    PERFORM ignore_bank_line(bl2, 'fixture 242 rounding');
    -- 账面余额由本支之前写进 1000 的分录决定 —— 不猜它:先不带说明对一次,读出拒绝里写着的差额,再把那个差额写成一项说明
    BEGIN
        PERFORM reconcile_statement(bs1, NULL);
        RAISE EXCEPTION 'FIXTURE 242 布景:对账单与账面不该恰好相等(两行都忽略了)';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'BALANCE_DISAGREES|%' THEN RAISE; END IF;
        v_x := split_part(SQLERRM, '|', 4);
    END;
    PERFORM reconcile_statement(bs1, jsonb_build_array(jsonb_build_object('kind', 'timing', 'amount', v_x::numeric, 'note', 'fixture 242 both ignored')));
    PERFORM unreconcile_statement(bs1, 'fixture 242 wrong period');
    v_j := pg_temp.f242_ok('B', pg_temp.f242_trail(u_all, 'bank_statement', bs1::text));
    PERFORM pg_temp.f242_need('B (imported)', v_j, 'bank_statements', 'INSERT');
    PERFORM pg_temp.f242_need('B (child: its lines)', v_j, 'bank_statement_lines', 'INSERT');
    PERFORM pg_temp.f242_need('B (child change: a line ignored)', v_j, 'bank_statement_lines', 'UPDATE', 'match_status', '{"match_status": "ignored"}');
    PERFORM pg_temp.f242_need('B (field edit: notes)', v_j, 'bank_statements', 'UPDATE', 'notes', '{"notes": "fixture 242 re-checked"}');
    PERFORM pg_temp.f242_need('B (key event: reconciled)', v_j, 'bank_statements', 'UPDATE', 'status', '{"status": "reconciled"}');
    PERFORM pg_temp.f242_need('B (the reconciliation record)', v_j, 'bank_reconciliations', 'INSERT');
    PERFORM pg_temp.f242_need('B (the explained difference)', v_j, 'bank_reconciliation_variance_items', 'INSERT');
    -- Q24:撤销对账 —— 对账单翻回 open(备注后面那一截机器字)与对账记录被取代,同一个 op_key
    SELECT e ->> 'op_key' INTO v_k FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'bank_statements' AND e -> 'new' ->> 'status' = 'open';
    SELECT e ->> 'op_key' INTO v_k2 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'bank_reconciliations' AND e -> 'changed_columns' ? 'superseded_at';
    IF v_k IS NULL OR v_k IS DISTINCT FROM v_k2 THEN
        RAISE EXCEPTION 'FIXTURE 242 B (Q24): undoing a reconciliation should be one operation (statement + superseded record): % vs %', v_k, v_k2; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'bank_statements' AND e -> 'new' ->> 'notes' LIKE '%UNRECONCILED %: fixture 242 wrong period') THEN
        RAISE EXCEPTION 'FIXTURE 242 B (Q24): the machine suffix the renderer recognises is not where it expects it: %', v_j; END IF;
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 B: shown twice: %', v_x; END IF;
    -- Q6:删掉的那一张 —— 它的记录照样读得到(读规则不过滤已删的行);deleted_records 列出它,"谁"取自变更记录
    bs2 := (import_bank_statement('1000', d - 5, d, 1300, 1310, 'fx242-bad.csv', jsonb_build_array(
            jsonb_build_object('line_date', d - 1, 'amount', 10, 'description', 'fixture 242 bad import'))) ->> 'statement_id')::uuid;
    UPDATE bank_statements SET deleted_at = now() WHERE id = bs2;
    v_j := pg_temp.f242_ok('B (Q6: deleted)', pg_temp.f242_trail(u_all, 'bank_statement', bs2::text));
    PERFORM pg_temp.f242_need('B (Q6: the deletion)', v_j, 'bank_statements', 'UPDATE', 'deleted_at');
    PERFORM pg_temp.f242_as(u_all);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT jsonb_build_object('n', count(*), 'by', max(deleted_by::text)) INTO v_rec FROM deleted_records WHERE record_kind = 'bank_statement' AND record_id = bs2;
    EXECUTE 'RESET ROLE';
    IF (v_rec ->> 'n')::int <> 1 OR v_rec ->> 'by' IS DISTINCT FROM u_all::text THEN
        RAISE EXCEPTION 'FIXTURE 242 B (Q6): a deleted statement should be listed once in deleted_records with who deleted it (from the log), got %', v_rec; END IF;
    -- Q9:记录开始之前的对账 —— 那一戳是那件事唯一的记录(BS-2026-0002 的形状:对过账,却没有一行对账记录)
    bs3 := (import_bank_statement('1000', d - 5, d, 1310, 1320, 'fx242-old.csv', jsonb_build_array(
            jsonb_build_object('line_date', d - 1, 'amount', 10, 'description', 'fixture 242 old'))) ->> 'statement_id')::uuid;
    SET LOCAL session_replication_role = replica;
    UPDATE bank_statements SET status = 'reconciled', reconciled_at = t0, reconciled_by = u_all WHERE id = bs3;
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f242_ok('B (Q9)', pg_temp.f242_trail(u_all, 'bank_statement', bs3::text));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'bank_statements' AND (e ->> 'prelog')::boolean
                      AND e -> 'changed_columns' ? 'reconciled_at') THEN
        RAISE EXCEPTION 'FIXTURE 242 B (Q9): a reconciliation before the log should come back from its stamp: %', v_j; END IF;

    -- ══════════════ G · GST 期间(Q22 · Q23)══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = DATE '2025-04-01';
    PERFORM pg_temp.f242_as(u_all);
    gp := (open_gst_period(DATE '2025-01-01', DATE '2025-03-31') ->> 'gst_period_id')::uuid;
    IF gp IS NULL THEN RAISE EXCEPTION 'FIXTURE 242 布景:GST 期间没有开出来'; END IF;
    UPDATE gst_periods SET notes = 'fixture 242 checked' WHERE id = gp;
    gfr := (submit_gst_filing_request(gp, 'fixture 242 ready') ->> 'request_id')::uuid;
    PERFORM pg_temp.f242_as(u_cfo);
    PERFORM decide_gst_filing_request(gfr, true, NULL);
    PERFORM pg_temp.f242_as(u_all);
    PERFORM record_gst_filing(gp, DATE '2025-04-20', 'fixture 242 IRAS ack');
    gp_c := (correct_gst_return(gp, 'fixture 242 late supplier invoice') ->> 'gst_period_id')::uuid;
    v_j := pg_temp.f242_ok('G', pg_temp.f242_trail(u_all, 'gst_period', gp::text));
    PERFORM pg_temp.f242_need('G (key event: opened)', v_j, 'gst_periods', 'INSERT');
    PERFORM pg_temp.f242_need('G (field edit: notes)', v_j, 'gst_periods', 'UPDATE', 'notes');
    PERFORM pg_temp.f242_need('G (child: the filing request)', v_j, 'gst_filing_requests', 'INSERT');
    PERFORM pg_temp.f242_need('G (its approval)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "gst_filing_request", "decision": "approved"}');
    PERFORM pg_temp.f242_need('G (the boxes locked)', v_j, 'gst_return_boxes', 'INSERT');
    PERFORM pg_temp.f242_need('G (key event: filed)', v_j, 'gst_periods', 'UPDATE', 'filed_at');
    -- Q23:抄下来的每一格与批准是同一次操作(界面把它们并进申报那一条)
    SELECT e ->> 'op_key' INTO v_k FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'approval_log' AND e -> 'new' ->> 'subject_type' = 'gst_filing_request';
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'gst_return_boxes' AND e ->> 'op_key' IS DISTINCT FROM v_k) THEN
        RAISE EXCEPTION 'FIXTURE 242 G (Q23): every box should be written in the approval''s operation: %', v_j; END IF;
    -- Q22:更正件【不】出现在原件的记录里
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e -> 'row_key' ->> 'id' = gp_c::text) THEN
        RAISE EXCEPTION 'FIXTURE 242 G (Q22): the correction period leaked onto the original''s trail: %', v_j; END IF;
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 G: shown twice: %', v_x; END IF;
    v_j := pg_temp.f242_ok('G (correction)', pg_temp.f242_trail(u_all, 'gst_period', gp_c::text));
    PERFORM pg_temp.f242_need('G (Q22: the correction opens with its creation, naming the original)', v_j, 'gst_periods', 'INSERT', NULL, jsonb_build_object('corrects_period_id', gp));

    -- ══════════════ X · 汇率(Q7)══════════════
    fx := (record_fx_rate('USD', d, 'tt_sell', 1.3521, 'DBS', 'fixture 242') ->> 'id')::uuid;
    IF fx IS NULL THEN SELECT id INTO fx FROM fx_rates WHERE currency = 'USD' AND rate_date = d AND rate_type = 'tt_sell' AND deleted_at IS NULL; END IF;
    PERFORM record_fx_rate('USD', d, 'tt_sell', 1.3512, 'DBS', 'fixture 242', 'fixture 242 typed the buy rate');
    PERFORM withdraw_fx_rate(fx, 'fixture 242 bank holiday');
    v_j := pg_temp.f242_ok('X', pg_temp.f242_trail(u_all, 'fx_rate', fx::text));
    PERFORM pg_temp.f242_need('X (recorded)', v_j, 'fx_rates', 'INSERT');
    PERFORM pg_temp.f242_need('X (child: its history, created)', v_j, 'fx_rate_history', 'INSERT', NULL, '{"action": "created"}');
    PERFORM pg_temp.f242_need('X (field edit: the rate corrected)', v_j, 'fx_rates', 'UPDATE', 'rate_sgd_per_unit');
    PERFORM pg_temp.f242_need('X (the correction''s reason)', v_j, 'fx_rate_history', 'INSERT', NULL, '{"action": "corrected", "reason": "fixture 242 typed the buy rate"}');
    PERFORM pg_temp.f242_need('X (key event: withdrawn)', v_j, 'fx_rates', 'UPDATE', 'deleted_at');
    PERFORM pg_temp.f242_need('X (the withdrawal''s reason)', v_j, 'fx_rate_history', 'INSERT', NULL, '{"action": "withdrawn", "reason": "fixture 242 bank holiday"}');
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 X: shown twice: %', v_x; END IF;
    -- Q7:撤回之后,这一页本来的读者(只持 module.finance.view)照样读得到它的记录
    v_j := pg_temp.f242_ok('X (Q7: a finance-only reader opens a withdrawn rate)', pg_temp.f242_trail(u_fin, 'fx_rate', fx::text));
    PERFORM pg_temp.f242_need('X (Q7: the withdrawal reads for that reader)', v_j, 'fx_rates', 'UPDATE', 'deleted_at');

    -- ══════════════ K · 管理包(Q25)══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = DATE '2025-04-01';
    PERFORM pg_temp.f242_as(u_all);
    pk1 := (freeze_management_pack(DATE '2025-02-01', 'fixture 242 board pack') ->> 'pack_id')::uuid;
    IF pk1 IS NULL THEN SELECT id INTO pk1 FROM management_packs WHERE period_month = DATE '2025-02-01' AND superseded_at IS NULL; END IF;
    pk2 := (freeze_management_pack(DATE '2025-02-01', 'fixture 242 board pack v2', 'fixture 242 late accrual') ->> 'pack_id')::uuid;
    IF pk2 IS NULL THEN SELECT id INTO pk2 FROM management_packs WHERE period_month = DATE '2025-02-01' AND superseded_at IS NULL; END IF;
    v_j := pg_temp.f242_ok('K', pg_temp.f242_trail(u_all, 'management_pack', pk1::text));
    PERFORM pg_temp.f242_need('K (key event: produced)', v_j, 'management_packs', 'INSERT');
    PERFORM pg_temp.f242_need('K (key event: replaced)', v_j, 'management_packs', 'UPDATE', 'superseded_at');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e -> 'row_key' ->> 'id' = pk2::text) THEN
        RAISE EXCEPTION 'FIXTURE 242 K: the newer pack''s creation leaked onto the older pack''s trail (no self-link through superseded_by): %', v_j; END IF;
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 K: shown twice: %', v_x; END IF;
    PERFORM pg_temp.f242_need('K (the newer pack, its own trail)', pg_temp.f242_ok('K2', pg_temp.f242_trail(u_all, 'management_pack', pk2::text)), 'management_packs', 'INSERT');
    -- 管理包不可改(冻结的就是冻结的)—— 没有"字段编辑"那一样
    BEGIN
        UPDATE management_packs SET notes = 'x' WHERE id = pk2;
        RAISE EXCEPTION 'FIXTURE 242 K: a frozen pack''s notes could be edited directly';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FIXTURE 242%' THEN RAISE; END IF;
    END;

    -- ══════════════ C · 合同(Q21)══════════════
    PERFORM pg_temp.f242_as(u_all);
    INSERT INTO contracts (supplier_id, kind, title, effective_from, currency) VALUES (v_sup, 'supply', 'fixture 242 supply', d, v_base) RETURNING id INTO con;
    UPDATE contracts SET title = 'fixture 242 supply (revised)' WHERE id = con;
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (con, (SELECT code FROM substances ORDER BY code LIMIT 1), 10);
    tr := (submit_contract_activation_request(con, 'fixture 242 signed') ->> 'request_id')::uuid;
    PERFORM pg_temp.f242_as(u_cfo);
    PERFORM decide_terms_request(tr, true, NULL);
    PERFORM pg_temp.f242_as(u_all);
    IF (SELECT status FROM contracts WHERE id = con) IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'FIXTURE 242 布景:批准之后合同应当已生效'; END IF;
    v_j := pg_temp.f242_ok('C', pg_temp.f242_trail(u_all, 'contract', con::text));
    PERFORM pg_temp.f242_need('C (key event: created)', v_j, 'contracts', 'INSERT');
    PERFORM pg_temp.f242_need('C (field edit: title)', v_j, 'contracts', 'UPDATE', 'title');
    PERFORM pg_temp.f242_need('C (child: a grade specification)', v_j, 'contract_grade_specs', 'INSERT');
    PERFORM pg_temp.f242_need('C (the activation request)', v_j, 'terms_requests', 'INSERT');
    PERFORM pg_temp.f242_need('C (its approval)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "terms_request", "decision": "approved"}');
    PERFORM pg_temp.f242_need('C (key event: activated)', v_j, 'contracts', 'UPDATE', 'status', '{"status": "active"}');
    v_x := pg_temp.f242_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 242 C: shown twice: %', v_x; END IF;
    -- Q21:不持 module.pricing.view 的合同读者 —— CFO 的决定那几行是 Restricted(在,不消失);合同与条款照常看得见
    v_j := pg_temp.f242_ok('C (Q21, a contract reader without pricing.view)', pg_temp.f242_trail(u_con, 'contract', con::text));
    PERFORM pg_temp.f242_need('C (Q21: the contract stays visible)', v_j, 'contracts', 'UPDATE', 'title');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 242 C (Q21): the CFO''s decision should read Restricted (a hidden row), not disappear: %', v_j; END IF;
    IF pg_temp.f242_has(v_j, 'approval_log', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 242 C (Q21): a reader without module.pricing.view saw the terms-request decision: %', v_j; END IF;

    -- ══════════════ P · 1c-1 的缺口:付款申请与贷项通知的字段编辑 ══════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d), v_cust, d, v_base, 1) RETURNING id INTO so1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so1, 1, v_mat, 10, 10) RETURNING id INTO l1;
    PERFORM set_sales_order_status(so1, 'confirmed');
    inv1 := (create_order_invoice(so1, d, NULL, NULL, NULL, ARRAY[l1]) ->> 'invoice_id')::uuid;
    SELECT id INTO il1 FROM invoice_lines WHERE invoice_id = inv1;
    v_res := submit_credit_note_request(inv1, d, 'fixture 242 price adjustment',
        jsonb_build_array(jsonb_build_object('invoice_line_id', il1, 'kind', 'unshipped_cancel', 'amount', 20, 'qty', 2)));
    PERFORM pg_temp.f242_as(u_cfo);
    PERFORM decide_invoice_request((v_res ->> 'request_id')::uuid, true, NULL);
    PERFORM pg_temp.f242_as(u_all);
    SELECT id INTO v_cn FROM credit_notes WHERE invoice_id = inv1;
    IF v_cn IS NULL THEN RAISE EXCEPTION 'FIXTURE 242 布景:贷项通知没有开出来'; END IF;
    -- 贷项通知:任何改动按名拒,变更记录一行都不多
    SELECT count(*) INTO v_n FROM change_log WHERE table_name = 'credit_notes' AND row_key = jsonb_build_object('id', v_cn);
    BEGIN
        UPDATE credit_notes SET reason = 'fixture 242 edited' WHERE id = v_cn;
        RAISE EXCEPTION 'FIXTURE 242 P: a credit note could be edited';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FIXTURE 242%' THEN RAISE; END IF;
        IF SQLERRM NOT LIKE 'CREDIT_NOTE_IMMUTABLE%' THEN RAISE EXCEPTION 'FIXTURE 242 P: a credit note edit should be refused by name (CREDIT_NOTE_IMMUTABLE), got %', SQLERRM; END IF;
    END;
    IF (SELECT count(*) FROM change_log WHERE table_name = 'credit_notes' AND row_key = jsonb_build_object('id', v_cn)) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 242 P: a refused credit-note edit still wrote a change-log row'; END IF;
    -- 付款申请:读者直接改它落不了地(没有 UPDATE 的策略 —— 零行、不报错);一次系统写入在记录里是一次字段编辑
    exp1 := (record_expense(d, v_acct, 50, v_base, NULL, 'unpaid', NULL, v_sup) ->> 'expense_id')::uuid;
    pr := (submit_payment_request(v_sup, 50, v_base, NULL, NULL, d, 'fixture 242 pay',
           jsonb_build_array(jsonb_build_object('expense_id', exp1, 'amount_doc', 50))) ->> 'request_id')::uuid;
    IF pr IS NULL THEN RAISE EXCEPTION 'FIXTURE 242 布景:付款申请没有提出来'; END IF;
    PERFORM pg_temp.f242_as(u_all);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        UPDATE payment_requests SET planned_date = d + 30 WHERE id = pr;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    EXECUTE 'RESET ROLE';
    IF (SELECT planned_date FROM payment_requests WHERE id = pr) IS DISTINCT FROM d THEN
        RAISE EXCEPTION 'FIXTURE 242 P: a reader''s direct edit of a payment request landed'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE payment_requests SET planned_date = d + 7 WHERE id = pr;
    v_j := pg_temp.f242_ok('P (payment request)', pg_temp.f242_trail(u_all, 'payment_request', pr::text));
    PERFORM pg_temp.f242_need('P (field edit: planned date — a system write, worded as "Request changed")', v_j, 'payment_requests', 'UPDATE', 'planned_date');
    IF (SELECT e -> 'actor' ->> 'state' FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'payment_requests' AND e -> 'changed_columns' ? 'planned_date') IS DISTINCT FROM 'system' THEN
        RAISE EXCEPTION 'FIXTURE 242 P: the system write should read "System (automatic)": %', v_j; END IF;

    -- 门:一个码都不持的人按名拒(不是一张空表)
    v_j := pg_temp.f242_trail(gen_random_uuid(), 'contract', con::text);
    IF jsonb_typeof(v_j) = 'array' OR v_j ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 242: a reader with no codes should be refused by name, got %', v_j; END IF;

    RAISE NOTICE 'FIXTURE 242 全部通过:S(Q14)· F(Q9)· A(Q10)· B(Q6 · Q9 · Q24)· G(Q22 · Q23)· X(Q7)· K(Q25)· C(Q21)· P(字段编辑)';
END;
$$;

ROLLBACK;

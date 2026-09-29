-- 236 AUDIT-TRAIL-1a:一页底部的审计记录 —— 只说这一条记录的事,一次操作一条,看不见的说 Restricted,
--     拒绝一律按名 RAISE,变更记录开始之前的那一段拼回来且不重复(2026-09-29)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AUDIT-TRAIL-0 Q1–Q43,Tim 2026-09-29 全部照建议裁定)
--   P  采购单(record_trail('purchase_order', …)):
--      P1 建单那一笔事务(单头 + 明细行 + 自动审批 + 合同条款)= 【一条】记录(Q2);
--      P2 单头字段编辑 = 一条,只含改了的列;P3 明细行改动 + 理由(三行同一笔事务)= 一条,行在"记录的行"里(Q3);
--      P4 关键事件(取消)由无会话写入 → actor.state = system(Q17);P5 账号与人都不在 → removed(Q17);
--      P6 被引用的物料已被硬删 → 名字从它最后的影像取,gone = true;连影像都没有 → label NULL + gone(Q13);
--      P7 只在记录影像里的子行(已删的明细行)也找得到(Q6,GIN);
--      P8 记录开始之前:领域历史拼成 prelog 行、排在最后;已被记录的那一行只出现一次(Q1);
--      P9 遮蔽:只持 module.purchasing.view 的合成读者 → 单价是受限标记,本来就空的留 null;持价格码的看得见(Q5);
--      P10 读者看不见的子行(合同条款要 module.suppliers.view)→ 时间还在,其余为空、row_hidden(Q4);持码的看得见;
--      P11 机器写的中文(自动审批的说明)仍在那一行上、decision = auto_approved —— 界面据此换成英文(Q8);
--      P12 范围:另一张采购单的行一行都不进来;P13 分页:p_entries 之外的不返回,more 为真
--   R  拒绝:R1 不认识的主语 → TRAIL_SUBJECT_UNKNOWN;R2 没有页面的查看码 → TRAIL_NOT_PERMITTED(采购单与角色两半;
--      角色那一半在 L 之后跑,因为那个角色在那里才建出来);
--      R3 有码但那条记录不存在 → TRAIL_NOT_PERMITTED;【一律 RAISE,绝不返回空列表】
--   W  加工单:W1 建单那一笔(单 + 投入 + 产出)= 一条;W2 字段编辑;W3 成本条目(只在影像里)与它的修改史同一条;
--      W4 关键事件(分摊)两行同一条;W5 只持 module.processing.view 的读者:成本受限,持 data.view_prices 的看得见
--   L  角色:L1 一次保存加一个码、拿掉一个码 = 一条两行,码的名字取 permissions.name_en;L2 字段编辑;
--      L3 记录开始之前的授权拼成 prelog(没有 action.manage_permissions 的拒绝归在 R2)
--   S  汇总页的读法(change_log_rows):S1 按事务分页(p_by_entry)一页一笔事务;S2 明细行与审批行都属于它的采购单
--      (审批行没有外键,只有登记表认得);
--      S3 按单据号找得到;S4 两个读法对同一行给出同一个受限标记(同一个遮蔽步骤)
--
-- 自带数据(README 第 2 条):账号、角色、员工、供应商、物料、合同、采购单、批次、加工单全部本支自建。
-- 【为什么后几次操作是直接插进 change_log 的】整支 fixture 是【一笔】事务 —— txid 只有一个。要造出"几次操作",
--   只能用各自的 txid 插合成的记录行(fixture 234 的遮蔽几臂同一个做法:它问的是读法,不是写法;写法由 234 钉)。
--   "记录开始之前"那一段用 ALTER TABLE … DISABLE TRIGGER zzz_change_log 造 —— 与线上 2026-09-28 之前的样子相同。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f236_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份(authenticated)跑一句返回 jsonb 的查询;失败返回 {"error": …}
CREATE FUNCTION pg_temp.f236_json(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f236_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

-- 以某人的身份读一条记录的审计记录(jsonb 数组,按 entry_no、seq);拒绝 → {"error": …}
CREATE FUNCTION pg_temp.f236_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 100) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT pg_temp.f236_json(p_user, format(
        'SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), ''[]''::jsonb) FROM record_trail(%L, %L, %s) r',
        p_subject, p_id, p_n))
$f$;

-- 插一行合成的记录(本支的"另一次操作")
CREATE FUNCTION pg_temp.f236_log(p_tx bigint, p_at timestamptz, p_table text, p_key jsonb, p_op text, p_kind text,
                                 p_account uuid, p_employee uuid, p_cols text[], p_old jsonb, p_new jsonb) RETURNS bigint
LANGUAGE sql AS $f$
    INSERT INTO change_log (occurred_at, txid, table_name, row_key, op, actor_account, actor_employee, actor_kind, db_role,
                            changed_columns, old, new)
    VALUES (p_at, p_tx, p_table, p_key, p_op, p_account, p_employee, p_kind,
            CASE WHEN p_kind = 'no_session' THEN 'postgres' ELSE 'authenticated' END, p_cols, p_old, p_new)
    RETURNING seq
$f$;

DO $$
DECLARE
    k_restricted constant jsonb := '{"$restricted": true}'::jsonb;
    u_all  uuid := gen_random_uuid();   -- 持全部码
    u_buy  uuid := gen_random_uuid();   -- 合成读者:只有 module.purchasing.view(进得了采购单页,没有价格码、没有供应商码)
    u_pp   uuid := gen_random_uuid();   -- 合成读者:module.purchasing.view + data.view_purchase_prices
    u_proc uuid := gen_random_uuid();   -- 合成读者:只有 module.processing.view
    u_cl   uuid := gen_random_uuid();   -- 合成读者:data.view_change_log + module.purchasing.view(汇总页,没有价格码)
    u_no   uuid := gen_random_uuid();   -- 一个码都不持
    u_gone uuid := gen_random_uuid();   -- 一个早已不在的账号(auth.users 里没有)
    r_all uuid; r_buy uuid; r_pp uuid; r_proc uuid; r_cl uuid; r_fx uuid;
    e_all uuid := gen_random_uuid();
    v_ccy text; v_sup uuid; v_mat uuid; v_mat_gone uuid := gen_random_uuid(); v_never uuid := gen_random_uuid();
    v_con uuid; v_r jsonb; v_po uuid; v_po2 uuid; v_line uuid; v_line_gone uuid := gen_random_uuid();
    v_ib uuid; v_matB uuid; v_run uuid; v_out uuid; v_cost uuid := gen_random_uuid();
    v_tx0 bigint := txid_current(); v_tx bigint;
    v_now timestamptz := clock_timestamp();
    v_j jsonb; v_e jsonb; v_x jsonb; v_n int; v_n2 int; v_first int; v_last int; v_msg text;
BEGIN
    -- ══════════════ 布景 ══════════════
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, approvals_enabled = false;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx236-all@test.local', now()), (u_buy, 'fx236-buy@test.local', now()), (u_pp, 'fx236-pp@test.local', now()),
        (u_proc, 'fx236-proc@test.local', now()), (u_cl, 'fx236-cl@test.local', now()), (u_no, 'fx236-no@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx236-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx236-buy', 'f', 'f', true) RETURNING id INTO r_buy;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx236-pp', 'f', 'f', true) RETURNING id INTO r_pp;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx236-proc', 'f', 'f', true) RETURNING id INTO r_proc;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx236-cl', 'f', 'f', true) RETURNING id INTO r_cl;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_buy, 'module.purchasing.view'), (r_proc, 'module.processing.view');
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_pp, c FROM unnest(ARRAY['module.purchasing.view', 'data.view_purchase_prices']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_cl, c FROM unnest(ARRAY['data.view_change_log', 'module.purchasing.view']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all, r_all), (u_buy, r_buy), (u_pp, r_pp), (u_proc, r_proc), (u_cl, r_cl);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, user_id)
    VALUES (e_all, 'FX236-ALL', 'Fixture Two Three Six', 'Fx236 Tim', 'full_time', 'office', DATE '2020-01-01', 'active', u_all);
    PERFORM pg_temp.f236_as(u_all);

    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ236-S1', 'Fixture 236 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ236-M1', 'Fixture 236 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ236-M2', 'Fixture 236 output', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, effective_to, status, currency, incoterm, payment_terms_days)
    VALUES (v_sup, 'supply', 'Fixture 236 supply agreement', '2026-01-01', '2027-12-31', 'active', v_ccy, 'CIF', 30)
    RETURNING id INTO v_con;

    -- ══════════════ P · 采购单 ══════════════
    -- 建单那一笔(本支的 txid):单头 + 明细行 + 自动审批(机器写的中文说明)+ 合同条款
    v_r := create_purchase_order(v_sup, CURRENT_DATE, CURRENT_DATE + 30, v_ccy, NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg', 'estimated_unit_price', 10)),
        p_category => 'equipment_goods');
    v_po := (v_r ->> 'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    PERFORM link_document_to_contract('purchase_order', v_po, v_con);
    v_r := create_purchase_order(v_sup, CURRENT_DATE, CURRENT_DATE + 30, v_ccy, NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 5, 'unit', 'kg', 'estimated_unit_price', 3)),
        p_category => 'equipment_goods');
    v_po2 := (v_r ->> 'purchase_order_id')::uuid;

    -- 一份已被硬删的物料:只剩它的 DELETE 影像
    PERFORM pg_temp.f236_log(v_tx0 - 50, v_now - interval '1 day', 'materials', jsonb_build_object('id', v_mat_gone), 'DELETE',
        'user', u_all, e_all, NULL, jsonb_build_object('id', v_mat_gone, 'code', 'ZZ236-GONE', 'name', 'Fixture 236 retired material'), NULL);

    -- P2 单头字段编辑
    PERFORM pg_temp.f236_log(v_tx0 + 1, v_now + interval '1 min', 'purchase_orders', jsonb_build_object('id', v_po), 'UPDATE',
        'user', u_all, e_all, ARRAY['incoterm', 'notes'], '{"incoterm": "CIF", "notes": null}', '{"incoterm": "FOB", "notes": "Pay 50/50"}');
    -- P3 明细行改动(数量与单价 · 物料从一份已删的换回来)+ 修改理由,同一笔事务
    PERFORM pg_temp.f236_log(v_tx0 + 2, v_now + interval '2 min', 'purchase_order_lines', jsonb_build_object('id', v_line), 'UPDATE',
        'user', u_all, e_all, ARRAY['quantity', 'estimated_unit_price'], '{"quantity": 100, "estimated_unit_price": 10}',
        '{"quantity": 120, "estimated_unit_price": 11}');
    PERFORM pg_temp.f236_log(v_tx0 + 2, v_now + interval '2 min', 'purchase_order_lines', jsonb_build_object('id', v_line), 'UPDATE',
        'user', u_all, e_all, ARRAY['material_id'], jsonb_build_object('material_id', v_mat_gone), jsonb_build_object('material_id', v_mat));
    PERFORM pg_temp.f236_log(v_tx0 + 2, v_now + interval '2 min', 'purchase_order_history', jsonb_build_object('id', gen_random_uuid()), 'INSERT',
        'user', u_all, e_all, NULL, NULL,
        jsonb_build_object('purchase_order_id', v_po, 'purchase_order_line_id', v_line, 'line_no', 1, 'change_type', 'line_update',
                           'old_quantity', 100, 'new_quantity', 120, 'amend_reason', 'Supplier confirmed more stock'));
    -- P4 关键事件:取消,由无会话写入
    PERFORM pg_temp.f236_log(v_tx0 + 3, v_now + interval '3 min', 'purchase_orders', jsonb_build_object('id', v_po), 'UPDATE',
        'no_session', NULL, NULL, ARRAY['status', 'cancel_reason'], '{"status": "confirmed", "cancel_reason": null}',
        '{"status": "cancelled", "cancel_reason": "Wrong supplier"}');
    -- P5 一个早已不在的账号改了备注;P6b 一份从未存在的物料(连影像都没有)
    PERFORM pg_temp.f236_log(v_tx0 + 4, v_now + interval '4 min', 'purchase_orders', jsonb_build_object('id', v_po), 'UPDATE',
        'user', u_gone, NULL, ARRAY['notes'], '{"notes": "Pay 50/50"}', '{"notes": "Pay 40/60"}');
    PERFORM pg_temp.f236_log(v_tx0 + 5, v_now + interval '5 min', 'purchase_order_lines', jsonb_build_object('id', v_line), 'UPDATE',
        'user', u_all, e_all, ARRAY['material_id'], jsonb_build_object('material_id', v_never), jsonb_build_object('material_id', v_mat));
    -- P7 一条明细行,只存在于记录影像里(加上又删掉)
    PERFORM pg_temp.f236_log(v_tx0 + 6, v_now + interval '6 min', 'purchase_order_lines', jsonb_build_object('id', v_line_gone), 'INSERT',
        'user', u_all, e_all, NULL, NULL,
        jsonb_build_object('id', v_line_gone, 'purchase_order_id', v_po, 'line_no', 2, 'material_id', v_mat, 'quantity', 7, 'unit', 'kg'));
    PERFORM pg_temp.f236_log(v_tx0 + 7, v_now + interval '7 min', 'purchase_order_lines', jsonb_build_object('id', v_line_gone), 'DELETE',
        'user', u_all, e_all, NULL,
        jsonb_build_object('id', v_line_gone, 'purchase_order_id', v_po, 'line_no', 2, 'material_id', v_mat, 'quantity', 7, 'unit', 'kg'), NULL);
    -- P8 记录开始之前:一行没有被记录过的修改史(触发器关掉插),与一行被记录过的(触发器开着插,只该出现一次)
    ALTER TABLE purchase_order_history DISABLE TRIGGER zzz_change_log;
    INSERT INTO purchase_order_history (purchase_order_id, change_type, old_incoterm, new_incoterm, amend_reason, changed_at, changed_by)
    VALUES (v_po, 'header_update', 'EXW', 'CIF', 'Before the log began', TIMESTAMPTZ '2026-09-01 10:00+08', u_all);
    ALTER TABLE purchase_order_history ENABLE TRIGGER zzz_change_log;
    INSERT INTO purchase_order_history (purchase_order_id, change_type, old_notes, new_notes, amend_reason, changed_at, changed_by)
    VALUES (v_po, 'header_update', NULL, 'x', 'Logged although back-dated', TIMESTAMPTZ '2026-09-02 10:00+08', u_all);

    -- ── 读 ──
    v_j := pg_temp.f236_trail(u_all, 'purchase_order', v_po::text);
    IF jsonb_typeof(v_j) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'FIXTURE 236P 失败:持全部码的读者应读得到采购单的审计记录,实为 %', v_j;
    END IF;
    -- P11 机器写的中文:自动审批那一行在,decision = auto_approved,说明是中文(界面据此换英文)
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'approval_log';
    IF v_e -> 'new' ->> 'decision' IS DISTINCT FROM 'auto_approved' OR v_e -> 'new' ->> 'note' !~ '[一-龥]' THEN
        RAISE EXCEPTION 'FIXTURE 236P11 失败:审批关着时建单应当带着一行 auto_approved(说明是机器写的中文),实为 %', v_e -> 'new';
    END IF;
    -- P1 建单那一笔 = 一条记录,里面有单头、明细行、自动审批、合同条款
    SELECT count(DISTINCT (e ->> 'entry_no')), count(DISTINCT (e ->> 'table_name'))
      INTO v_n, v_n2
      FROM jsonb_array_elements(v_j) e
     WHERE (e ->> 'prelog')::boolean = false
       AND e ->> 'table_name' IN ('purchase_orders', 'purchase_order_lines', 'approval_log', 'contract_document_terms')
       AND e ->> 'op' = 'INSERT'
       AND e -> 'row_key' IS DISTINCT FROM jsonb_build_object('id', v_line_gone);   -- P7 那一行是另一次操作
    IF v_n IS DISTINCT FROM 1 OR v_n2 IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'FIXTURE 236P1 失败:建单那一笔事务的四张表应当同属【一条】记录,实为 % 条 / % 张表', v_n, v_n2;
    END IF;
    -- P7 只在影像里的子行:加上、删掉,两条
    SELECT count(DISTINCT (e ->> 'entry_no')) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE e -> 'row_key' = jsonb_build_object('id', v_line_gone);
    IF v_n IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 236P7 失败:只在记录影像里的明细行(加上又删掉)应当找得到、两条,实为 %', v_n;
    END IF;
    -- P2 单头字段编辑:一条,改了的两列
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'purchase_orders' AND e -> 'new' ->> 'incoterm' = 'FOB';
    IF v_e IS NULL OR v_e -> 'changed_columns' IS DISTINCT FROM '["incoterm", "notes"]'::jsonb
       OR v_e -> 'old' -> 'notes' IS DISTINCT FROM 'null'::jsonb
       OR v_e -> 'actor' IS DISTINCT FROM '{"state": "person", "name": "Fx236 Tim"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P2 失败:单头编辑应当是一条两列、本来为空的留 null、做的人叫 Fx236 Tim,实为 %', v_e;
    END IF;
    -- P3 明细行改动 + 理由 = 一条三行
    SELECT count(*), count(DISTINCT (e ->> 'entry_no')) INTO v_n, v_n2 FROM jsonb_array_elements(v_j) e
     WHERE (e -> 'changed_columns' ?| ARRAY['estimated_unit_price'] AND e -> 'old' ->> 'material_id' IS NULL
            AND e ->> 'table_name' = 'purchase_order_lines')
        OR (e ->> 'table_name' = 'purchase_order_lines' AND e -> 'old' ->> 'material_id' = v_mat_gone::text)
        OR (e ->> 'table_name' = 'purchase_order_history' AND e -> 'new' ->> 'amend_reason' = 'Supplier confirmed more stock');
    IF v_n IS DISTINCT FROM 3 OR v_n2 IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236P3 失败:明细行的两处改动与修改理由(同一笔事务)应当是一条三行,实为 % 行 / % 条', v_n, v_n2;
    END IF;
    -- 明细行的上下文:第几行、哪个物料(子行标题用)
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'purchase_order_lines' AND e -> 'old' ->> 'material_id' = v_mat_gone::text;
    IF v_e -> 'ctx' ->> 'line_no' IS DISTINCT FROM '1'
       OR v_e -> 'refs' -> 'material_id' -> v_mat::text ->> 'label' IS DISTINCT FROM 'Fixture 236 material' THEN
        RAISE EXCEPTION 'FIXTURE 236P3 失败:子行应当带着它今天的样子(第 1 行)与物料的名字,实为 ctx=% refs=%', v_e -> 'ctx', v_e -> 'refs';
    END IF;
    -- P6 已删的引用:名字从最后的影像取,gone;连影像都没有 → label NULL + gone
    IF v_e -> 'refs' -> 'material_id' -> v_mat_gone::text IS DISTINCT FROM
           '{"label": "Fixture 236 retired material", "gone": true}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P6 失败:已删的物料应当读作它最后的名字并标 gone,实为 %', v_e -> 'refs';
    END IF;
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'purchase_order_lines' AND e -> 'old' ->> 'material_id' = v_never::text;
    IF v_e -> 'refs' -> 'material_id' -> v_never::text IS DISTINCT FROM '{"label": null, "gone": true}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P6 失败:连影像都没有的引用应当是 label null + gone,绝不是一串 id,实为 %', v_e -> 'refs';
    END IF;
    -- P4 / P5 谁做的
    SELECT e -> 'actor' INTO v_x FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'purchase_orders' AND e -> 'new' ->> 'status' = 'cancelled';
    IF v_x IS DISTINCT FROM '{"state": "system"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P4 失败:无会话写入的关键事件应当是 system,实为 %', v_x;
    END IF;
    SELECT e -> 'actor' INTO v_x FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'purchase_orders' AND e -> 'new' ->> 'notes' = 'Pay 40/60';
    IF v_x IS DISTINCT FROM '{"state": "removed"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P5 失败:账号与人都不在的写应当是 removed,实为 %', v_x;
    END IF;
    -- P8 记录开始之前:恰好一条 prelog 记录、排在最后、只有那一行没被记录过的;被记录过的那一行只出现一次
    SELECT count(*), max((e ->> 'entry_no')::int) INTO v_n, v_last FROM jsonb_array_elements(v_j) e
     WHERE (e ->> 'prelog')::boolean;
    SELECT max((e ->> 'entry_no')::int) INTO v_first FROM jsonb_array_elements(v_j) e WHERE NOT (e ->> 'prelog')::boolean;
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean;
    IF v_n IS DISTINCT FROM 1 OR v_last IS DISTINCT FROM v_first + 1
       OR v_e ->> 'table_name' IS DISTINCT FROM 'purchase_order_history'
       OR v_e -> 'new' ->> 'amend_reason' IS DISTINCT FROM 'Before the log began' OR v_e ->> 'seq' IS NOT NULL
       OR v_e -> 'actor' IS DISTINCT FROM '{"state": "person", "name": "Fx236 Tim"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P8 失败:记录开始之前的那一行应当拼成唯一一条 prelog 记录、排在最后,实为 % 行 / 第 % 条(最后一条记录是 %)/ %',
            v_n, v_last, v_first, v_e;
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE e -> 'new' ->> 'amend_reason' = 'Logged although back-dated';
    IF v_n IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236P8 失败:已经被记录的那一行历史应当【只出现一次】,实为 % 次', v_n;
    END IF;
    -- P12 范围:另一张采购单的行一行都不进来
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE e -> 'row_key' ->> 'id' = v_po2::text
        OR e -> 'new' ->> 'purchase_order_id' = v_po2::text OR e -> 'old' ->> 'purchase_order_id' = v_po2::text
        OR e -> 'ctx' ->> 'purchase_order_id' = v_po2::text;
    IF v_n IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 236P12 失败:另一张采购单的 % 行进了这张单的审计记录', v_n;
    END IF;
    -- P13 分页
    v_x := pg_temp.f236_trail(u_all, 'purchase_order', v_po::text, 2);
    IF (SELECT max((e ->> 'entry_no')::int) FROM jsonb_array_elements(v_x) e) IS DISTINCT FROM 2
       OR (SELECT bool_and((e ->> 'more')::boolean) FROM jsonb_array_elements(v_x) e) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 236P13 失败:p_entries = 2 应当只返回两条记录并说后面还有,实为 %', v_x;
    END IF;

    -- P9 遮蔽:只持查看码的读者 → 单价受限,本来就空的留 null;持价格码的看得见
    v_j := pg_temp.f236_trail(u_buy, 'purchase_order', v_po::text);
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'purchase_order_lines' AND e -> 'changed_columns' ? 'estimated_unit_price'
       AND e -> 'new' ->> 'quantity' = '120';
    IF v_e -> 'new' -> 'estimated_unit_price' IS DISTINCT FROM k_restricted
       OR v_e -> 'old' -> 'estimated_unit_price' IS DISTINCT FROM k_restricted
       OR v_e -> 'new' -> 'quantity' IS DISTINCT FROM '120'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P9 失败:没有价格码的读者看到的单价应当是受限标记、数量照常,实为 %', v_e;
    END IF;
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'purchase_orders' AND e -> 'new' ->> 'incoterm' = 'FOB';
    IF v_e -> 'old' -> 'notes' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P9 失败:本来就空的值对任何读者都留 null(不是受限),实为 %', v_e -> 'old';
    END IF;
    v_x := pg_temp.f236_trail(u_pp, 'purchase_order', v_po::text);
    SELECT e INTO v_e FROM jsonb_array_elements(v_x) e
     WHERE e ->> 'table_name' = 'purchase_order_lines' AND e -> 'changed_columns' ? 'estimated_unit_price'
       AND e -> 'new' ->> 'quantity' = '120';
    IF v_e -> 'new' -> 'estimated_unit_price' IS DISTINCT FROM '11'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P9 失败:持价格码的读者应当看得到单价 11,实为 %', v_e -> 'new';
    END IF;
    -- P10 看不见的子行:合同条款要 module.suppliers.view —— 时间还在,其余为空
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean LIMIT 1;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean;
    IF v_n IS DISTINCT FROM 1 OR v_e ->> 'occurred_at' IS NULL OR v_e ->> 'table_name' IS NOT NULL
       OR v_e -> 'actor' IS DISTINCT FROM 'null'::jsonb OR v_e -> 'new' IS DISTINCT FROM 'null'::jsonb
       OR v_e -> 'old' IS DISTINCT FROM 'null'::jsonb OR v_e -> 'row_key' IS DISTINCT FROM 'null'::jsonb
       OR v_e -> 'refs' IS DISTINCT FROM 'null'::jsonb OR v_e -> 'ctx' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236P10 失败:看不见的合同条款应当只留时间(一行,其余全空),实为 % 行 / %', v_n, v_e;
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(pg_temp.f236_trail(u_all, 'purchase_order', v_po::text)) e
     WHERE e ->> 'table_name' = 'contract_document_terms' AND NOT (e ->> 'row_hidden')::boolean;
    IF v_n IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236P10 失败:持供应商码的读者应当看得见那一行合同条款,实为 %', v_n;
    END IF;

    -- ══════════════ R · 拒绝:一律按名 RAISE,绝不是空列表 ══════════════
    v_x := pg_temp.f236_trail(u_all, 'purchase_orders', v_po::text);
    IF v_x ->> 'error' NOT LIKE 'TRAIL_SUBJECT_UNKNOWN|%' OR v_x ->> 'error' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 236R1 失败:不认识的主语(表名不是主语)应当 TRAIL_SUBJECT_UNKNOWN,实为 %', v_x;
    END IF;
    v_x := pg_temp.f236_trail(u_no, 'purchase_order', v_po::text);
    IF v_x ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED|%' OR v_x ->> 'error' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 236R2 失败:没有查看码的读者应当 TRAIL_NOT_PERMITTED,实为 %', v_x;
    END IF;
    v_x := pg_temp.f236_trail(u_buy, 'purchase_order', gen_random_uuid()::text);
    IF v_x ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED|%' OR v_x ->> 'error' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 236R3 失败:不存在的记录应当 TRAIL_NOT_PERMITTED(不是空列表),实为 %', v_x;
    END IF;
    v_x := pg_temp.f236_trail(u_buy, 'purchase_order', 'not-a-uuid');
    IF v_x ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED|%' OR v_x ->> 'error' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 236R3 失败:一个不像 id 的 id 也应当按名拒,实为 %', v_x;
    END IF;

    -- ══════════════ W · 加工单 ══════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ236-IB1', v_mat, v_sup, 100, 100, 'kg', CURRENT_DATE, 'other', 'fixture 236 自带数据') RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'fixture 236 price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib JOIN materials m ON m.id = ib.material_id JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE ib.id = v_ib AND mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s WHERE s.inbound_batch_id = ib.id);
    v_run := commit_processing_run(CURRENT_DATE, 'fixture 236 run', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 80)), 'metal_value', NULL, NULL, 'manual_disassembly');
    SELECT id INTO v_out FROM processing_outputs WHERE run_id = v_run;
    -- W2 字段编辑
    PERFORM pg_temp.f236_log(v_tx0 + 11, v_now + interval '11 min', 'processing_runs', jsonb_build_object('id', v_run), 'UPDATE',
        'user', u_all, e_all, ARRAY['notes'], '{"notes": "fixture 236 run"}', '{"notes": "Night shift"}');
    -- W3 成本条目(只在影像里)与它的修改史,同一笔事务
    PERFORM pg_temp.f236_log(v_tx0 + 12, v_now + interval '12 min', 'processing_cost_entries', jsonb_build_object('id', v_cost), 'INSERT',
        'user', u_all, e_all, NULL, NULL,
        jsonb_build_object('id', v_cost, 'run_id', v_run, 'cost_type', 'labour', 'amount_base', 200, 'is_estimate', false));
    PERFORM pg_temp.f236_log(v_tx0 + 12, v_now + interval '12 min', 'processing_cost_entry_history', jsonb_build_object('id', gen_random_uuid()), 'INSERT',
        'user', u_all, e_all, NULL, NULL,
        jsonb_build_object('entry_id', v_cost, 'run_id', v_run, 'change_type', 'create', 'new_amount_base', 200, 'new_cost_type', 'labour'));
    -- W4 关键事件:分摊 —— 单头与产出同一笔
    PERFORM pg_temp.f236_log(v_tx0 + 13, v_now + interval '13 min', 'processing_runs', jsonb_build_object('id', v_run), 'UPDATE',
        'user', u_all, e_all, ARRAY['allocated_at', 'allocated_by', 'capitalized_cost_base'],
        '{"allocated_at": null, "allocated_by": null, "capitalized_cost_base": null}',
        jsonb_build_object('allocated_at', v_now + interval '13 min', 'allocated_by', u_all, 'capitalized_cost_base', 200));
    PERFORM pg_temp.f236_log(v_tx0 + 13, v_now + interval '13 min', 'processing_outputs', jsonb_build_object('id', v_out), 'UPDATE',
        'user', u_all, e_all, ARRAY['allocated_cost_base'], '{"allocated_cost_base": null}', '{"allocated_cost_base": 200}');

    v_j := pg_temp.f236_trail(u_all, 'processing_run', v_run::text);
    SELECT count(DISTINCT (e ->> 'entry_no')), count(DISTINCT (e ->> 'table_name')) INTO v_n, v_n2
      FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'op' = 'INSERT' AND e ->> 'table_name' IN ('processing_runs', 'processing_inputs', 'processing_outputs');
    IF v_n IS DISTINCT FROM 1 OR v_n2 IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'FIXTURE 236W1 失败:加工单、投入、产出同一笔事务应当是一条记录,实为 % 条 / % 张表 —— %', v_n, v_n2, v_j;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                    WHERE e ->> 'table_name' = 'processing_runs' AND e -> 'new' ->> 'notes' = 'Night shift') THEN
        RAISE EXCEPTION 'FIXTURE 236W2 失败:加工单的字段编辑不在它的审计记录里';
    END IF;
    SELECT count(*), count(DISTINCT (e ->> 'entry_no')) INTO v_n, v_n2 FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' IN ('processing_cost_entries', 'processing_cost_entry_history');
    IF v_n IS DISTINCT FROM 2 OR v_n2 IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236W3 失败:成本条目(只在影像里)与它的修改史应当是一条两行,实为 % 行 / % 条', v_n, v_n2;
    END IF;
    SELECT count(*), count(DISTINCT (e ->> 'entry_no')) INTO v_n, v_n2 FROM jsonb_array_elements(v_j) e
     WHERE e -> 'changed_columns' ?| ARRAY['allocated_at', 'allocated_cost_base'];
    IF v_n IS DISTINCT FROM 2 OR v_n2 IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236W4 失败:分摊(单头 + 产出)应当是一条两行,实为 % 行 / % 条', v_n, v_n2;
    END IF;
    v_x := pg_temp.f236_trail(u_proc, 'processing_run', v_run::text);
    SELECT e INTO v_e FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'processing_cost_entries';
    IF v_e -> 'new' -> 'amount_base' IS DISTINCT FROM k_restricted
       OR (SELECT e -> 'new' -> 'capitalized_cost_base' FROM jsonb_array_elements(v_x) e
            WHERE e -> 'changed_columns' ? 'allocated_at') IS DISTINCT FROM k_restricted THEN
        RAISE EXCEPTION 'FIXTURE 236W5 失败:没有 data.view_prices 的加工读者看到的成本应当受限,实为 %', v_e;
    END IF;
    IF (SELECT e -> 'new' -> 'amount_base' FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'processing_cost_entries')
       IS DISTINCT FROM '200'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 236W5 失败:持全部码的读者应当看得到成本 200';
    END IF;

    -- ══════════════ L · 角色 ══════════════
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx236-buyer', 'Fixture Buyer', '采购', true) RETURNING id INTO r_fx;
    PERFORM set_role_permissions(r_fx, ARRAY['module.purchasing.view']);
    -- L3 记录开始之前的一条授权
    ALTER TABLE role_permissions DISABLE TRIGGER zzz_change_log;
    INSERT INTO role_permissions (role_id, permission_code, created_at, created_by)
    VALUES (r_fx, 'module.inbound.view', TIMESTAMPTZ '2026-09-10 09:00+08', u_all);
    ALTER TABLE role_permissions ENABLE TRIGGER zzz_change_log;
    -- L1 一次保存:加一个码、拿掉一个码
    PERFORM pg_temp.f236_log(v_tx0 + 21, v_now + interval '21 min', 'role_permissions',
        jsonb_build_object('role_id', r_fx, 'permission_code', 'module.suppliers.view'), 'INSERT', 'user', u_all, e_all, NULL, NULL,
        jsonb_build_object('role_id', r_fx, 'permission_code', 'module.suppliers.view', 'created_by', u_all));
    PERFORM pg_temp.f236_log(v_tx0 + 21, v_now + interval '21 min', 'role_permissions',
        jsonb_build_object('role_id', r_fx, 'permission_code', 'module.purchasing.view'), 'DELETE', 'user', u_all, e_all, NULL,
        jsonb_build_object('role_id', r_fx, 'permission_code', 'module.purchasing.view', 'created_by', u_all), NULL);
    -- L2 字段编辑
    PERFORM pg_temp.f236_log(v_tx0 + 22, v_now + interval '22 min', 'roles', jsonb_build_object('id', r_fx), 'UPDATE',
        'user', u_all, e_all, ARRAY['name_en'], '{"name_en": "Fixture Buyer"}', '{"name_en": "Fixture Purchasing"}');

    v_j := pg_temp.f236_trail(u_all, 'role', r_fx::text);
    SELECT count(*), count(DISTINCT (e ->> 'entry_no')) INTO v_n, v_n2 FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'role_permissions' AND e -> 'row_key' ->> 'permission_code' IN ('module.suppliers.view')
        OR (e ->> 'table_name' = 'role_permissions' AND e ->> 'op' = 'DELETE');
    IF v_n IS DISTINCT FROM 2 OR v_n2 IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236L1 失败:一次保存(加一个、拿掉一个)应当是一条两行,实为 % 行 / % 条', v_n, v_n2;
    END IF;
    SELECT e INTO v_e FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'role_permissions' AND e ->> 'op' = 'DELETE';
    IF v_e -> 'refs' -> 'permission_code' -> 'module.purchasing.view' ->> 'label'
       IS DISTINCT FROM (SELECT name_en FROM permissions WHERE code = 'module.purchasing.view') THEN
        RAISE EXCEPTION 'FIXTURE 236L1 失败:拿掉的码应当带着它在 permissions.name_en 里的名字,实为 %', v_e -> 'refs';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
                    WHERE e ->> 'table_name' = 'roles' AND e -> 'new' ->> 'name_en' = 'Fixture Purchasing') THEN
        RAISE EXCEPTION 'FIXTURE 236L2 失败:角色的字段编辑不在它的审计记录里';
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE (e ->> 'prelog')::boolean AND e -> 'new' ->> 'permission_code' = 'module.inbound.view' AND e ->> 'op' = 'INSERT';
    IF v_n IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236L3 失败:记录开始之前的授权应当拼成一行 prelog,实为 % —— %', v_n, v_j;
    END IF;
    -- R2(第二半):角色的读规则是 true,挡住 u_buy 的【只有】页面的查看码 action.manage_permissions ——
    --   所以"查看码没被检查"这一种故障只有在这里才看得见(采购单那一半有根行的读规则兜着)
    v_x := pg_temp.f236_trail(u_buy, 'role', r_fx::text);
    IF v_x ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED|%' OR v_x ->> 'error' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 236R2 失败:没有 action.manage_permissions 的读者读角色应当 TRAIL_NOT_PERMITTED,实为 %', v_x;
    END IF;

    -- ══════════════ S · 汇总页的读法 ══════════════
    v_x := pg_temp.f236_json(u_all,
        'SELECT jsonb_agg(to_jsonb(r)) FROM change_log_rows(p_table => ''purchase_order_lines'', p_by_entry => true, p_limit => 1) r');
    IF (SELECT count(DISTINCT e ->> 'txid') FROM jsonb_array_elements(v_x) e) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 236S1 失败:按事务分页一页一笔事务,实为 %', v_x;
    END IF;
    v_x := pg_temp.f236_json(u_all, format(
        'SELECT jsonb_agg(to_jsonb(r)) FROM change_log_rows(p_table => ''purchase_order_lines'', p_record => %L, p_limit => 200) r', v_line));
    IF (SELECT bool_and(e -> 'belongs_to' ->> 'id' = v_po::text AND e -> 'belongs_to' ->> 'table' = 'purchase_orders')
          FROM jsonb_array_elements(v_x) e) IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 236S2 失败:明细行的每一行记录都应当属于它的采购单,实为 %', v_x;
    END IF;
    -- approval_log.subject_id 没有外键(多态),只有登记表认得它属于哪张采购单 —— 沿父键走那一步不走,这一行就认不出主
    v_x := pg_temp.f236_json(u_all, format(
        'SELECT jsonb_agg(r.belongs_to) FROM change_log_rows(p_table => ''approval_log'', p_limit => 200) r WHERE r.new ->> ''subject_id'' = %L', v_po));
    IF (SELECT bool_and(e ->> 'id' = v_po::text AND e ->> 'table' = 'purchase_orders') FROM jsonb_array_elements(v_x) e)
       IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 236S2 失败:采购单的审批行应当属于那张采购单(只有登记表认得),实为 %', v_x;
    END IF;
    v_x := pg_temp.f236_json(u_all, format('SELECT to_jsonb(change_log_find_records(%L))',
                                           (SELECT code FROM purchase_orders WHERE id = v_po)));
    IF NOT (v_x ? v_po::text) THEN
        RAISE EXCEPTION 'FIXTURE 236S3 失败:按单据号应当找得到那张采购单,实为 %', v_x;
    END IF;
    v_x := pg_temp.f236_json(u_cl, format(
        'SELECT r.new -> ''estimated_unit_price'' FROM change_log_rows(p_table => ''purchase_order_lines'', p_record => %L, p_limit => 200) r WHERE r.changed_columns @> ARRAY[''estimated_unit_price''] AND r.new ->> ''quantity'' = ''120''', v_line));
    SELECT e -> 'new' -> 'estimated_unit_price' INTO v_e
      FROM jsonb_array_elements(pg_temp.f236_trail(u_cl, 'purchase_order', v_po::text)) e
     WHERE e -> 'changed_columns' ? 'estimated_unit_price' AND e -> 'new' ->> 'quantity' = '120';
    IF v_x IS DISTINCT FROM k_restricted OR v_e IS DISTINCT FROM k_restricted THEN
        RAISE EXCEPTION 'FIXTURE 236S4 失败:两个读法对同一行应当给出同一个受限标记,实为 汇总页 % / 审计记录 %', v_x, v_e;
    END IF;

    PERFORM pg_temp.f236_as(NULL);
    RAISE NOTICE 'FIXTURE 236 全部通过:P1–P13 · R1–R3 · W1–W5 · L1–L3 · S1–S4';
END;
$$;

ROLLBACK;

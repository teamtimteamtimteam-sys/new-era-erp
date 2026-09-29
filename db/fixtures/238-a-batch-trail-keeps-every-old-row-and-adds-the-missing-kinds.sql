-- 238 AUDIT-TRAIL-1b-1:批次的统一审计记录 —— 旧批次审计记录的每一行一行不少(含往上一跳的那几种),
--     加上化验、金属含量、安全状态、申请、销毁证书、盘点的每一次清点;注销的批次与回滚的加工单照样读得到(2026-09-29)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1b Step 0 的 Q4 · Q5 · Q6 · Q11 · Q12 · Q21 · Q32 · Q33,Tim 2026-09-29 全部照建议裁定)
--   B  逐行对照(Q32 · Q33):对本支造出来的每一个批次,旧视图 batch_audit_trail_all 的【每一行】的来源行
--      (source_table, source_id)都出现在 record_trail 里(持全部码的读者);少一行 = 红,并点名那一行。
--      B1 进料批次 · B2 产出批次 · B3 被注销的进料批次 · B4 被回滚的加工单消耗过的进料批次
--      B5 旧视图里【往上一跳】的那几种这一支确实造出来了(成本修改史 · 采购单审批 · 工单审批 · 工单修改史 ·
--         采购单修改史 · 加工成本分录 · 成本分摊分录 · 盘点分录 · 冲销分录)—— 否则 B1 的"一行不少"是在一个空集上说的
--      B6 垫脚石不进来:采购单本身、加工单本身、工单本身、盘点本身的行一行都不在批次的记录里(Q4:只限碰到这个批次的事)
--   K  新加的几种(Q33):K1 化验与它的金属 · K2 金属含量 · K3 安全状态 · K4 仓库申请(注销)与它的审批 ·
--      K5 销毁证书 · K6 盘点的每一次清点(stocktake_counts)
--   H  看不见的行(Q6,旧 183 的意图):只持 module.inbound.view 的读者读同一个批次 —— 行数与持全部码的读者【一样多】
--      (看不见的占着位置,不消失);看不见的行没有表名、主键、值(row_hidden);没有任何相关模块的读者 → TRAIL_NOT_PERMITTED
--   J  冲销(旧 181 的意图):原分录与它的冲销都在;冲销是按 reversed_by 结构上够到的,备注里一个 "REVERSAL" 都不写也够得到
--   N  状态说明的依据(Q5,旧 182 的意图):没挂采购行的批次,根行今天那份 purchase_order_line_id 为空;
--      消耗它的加工单回滚之后,投入那一行还在,而它指着的加工单解析出 ended = true(界面据此说"later rolled back")
--   Q  Q21:注销了的批次(只持 module.inbound.view 的普通读者)与回滚了的加工单(只持 module.processing.view)照样读得到,
--      注销 / 回滚那一次在记录里
--   S  盘点(Q11):过账与它的(自动)审批在同一条记录里;22/09 之前过账的盘点只有 posted_at 那一戳 —— 拼成一条 prelog 改动
--   W  /inventory 的申请那一块(Q12):只持 module.inventory.view 的读者读得到申请(M1:两个码任一)、金额是受限标记;
--      持 data.view_prices 的看得见;直接读 warehouse_requests.amount_base 被拒(42501);只持财务的也读得到申请
--
-- 自带数据(README 第 2 条):账号、角色、员工、供应商、物料、采购单、工单、批次、加工单、盘点、销售全部本支自建。
-- 【为什么大部分操作都在同一笔事务里】整支 fixture 是一笔事务。B 问的是"来源行在不在",不问"分成几条",所以一个 txid
--   不影响它;S 的"同一条记录"正好要的就是同一个 txid。"记录开始之前"那一段用 DISABLE TRIGGER zzz_change_log 造。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f238_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f238_json(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f238_as(p_user);
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

CREATE FUNCTION pg_temp.f238_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT pg_temp.f238_json(p_user, format(
        'SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), ''[]''::jsonb) FROM record_trail(%L, %L, %s) r',
        p_subject, p_id, p_n))
$f$;

-- B:旧视图对这个批次的每一行 → 在不在新的记录里(按来源表 + 来源 id);返回缺的那几行
CREATE FUNCTION pg_temp.f238_missing(p_kind text, p_batch uuid, p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(o.event_kind || ':' || o.source_table || ':' || o.source_id, ', ' ORDER BY o.event_kind)
      FROM batch_audit_trail_all o
     WHERE o.batch_kind = p_kind AND o.batch_id = p_batch
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                        WHERE e ->> 'table_name' = o.source_table AND e -> 'row_key' ->> 'id' = o.source_id::text)
$f$;

DO $$
DECLARE
    k_restricted constant jsonb := '{"$restricted": true}'::jsonb;
    u_all  uuid := gen_random_uuid();   -- 持全部码
    u_inb  uuid := gen_random_uuid();   -- 只有 module.inbound.view(进料批次页的普通读者)
    u_proc uuid := gen_random_uuid();   -- 只有 module.processing.view
    u_inv  uuid := gen_random_uuid();   -- 只有 module.inventory.view(/inventory 那一块,没有价格码)
    u_invp uuid := gen_random_uuid();   -- module.inventory.view + data.view_prices
    u_fin  uuid := gen_random_uuid();   -- 只有 module.finance.view
    u_out  uuid := gen_random_uuid();   -- 只有 module.output.view
    u_no   uuid := gen_random_uuid();   -- 一个码都不持
    u_rel  uuid := gen_random_uuid();   -- 下达工单的另一个人(建单人不能自己下达)
    r_all uuid; r_inb uuid; r_proc uuid; r_inv uuid; r_invp uuid; r_fin uuid; r_out uuid; r_rel uuid;
    e_all uuid := gen_random_uuid();
    v_ccy text; v_sup uuid; v_mat uuid; v_matB uuid; v_r jsonb; v_po uuid; v_line uuid;
    v_ib uuid; v_ib2 uuid; v_ib3 uuid; v_ob uuid; v_wo uuid; v_run uuid; v_run2 uuid; v_st uuid; v_st_old uuid; v_je uuid;
    v_wr uuid; v_assay uuid;
    v_began timestamptz := change_log_began_at();
    v_j jsonb; v_j2 jsonb; v_miss text; v_n int; v_n2 int; v_msg text; v_x jsonb;
BEGIN
    -- ══════════════ 布景 ══════════════
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, approvals_enabled = false;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx238-all@test.local', now()), (u_inb, 'fx238-inb@test.local', now()), (u_proc, 'fx238-proc@test.local', now()),
        (u_inv, 'fx238-inv@test.local', now()), (u_invp, 'fx238-invp@test.local', now()), (u_fin, 'fx238-fin@test.local', now()),
        (u_out, 'fx238-out@test.local', now()), (u_no, 'fx238-no@test.local', now()), (u_rel, 'fx238-rel@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-inb', 'f', 'f', true) RETURNING id INTO r_inb;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-proc', 'f', 'f', true) RETURNING id INTO r_proc;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-inv', 'f', 'f', true) RETURNING id INTO r_inv;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-invp', 'f', 'f', true) RETURNING id INTO r_invp;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-out', 'f', 'f', true) RETURNING id INTO r_out;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx238-rel', 'f', 'f', true) RETURNING id INTO r_rel;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_inb, 'module.inbound.view'), (r_proc, 'module.processing.view'), (r_inv, 'module.inventory.view'),
        (r_invp, 'module.inventory.view'), (r_invp, 'data.view_prices'), (r_fin, 'module.finance.view'), (r_out, 'module.output.view'), (r_rel, 'action.wo_release'), (r_rel, 'module.processing.view'), (r_rel, 'action.stocktake_post'), (r_rel, 'module.stocktakes.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all, r_all), (u_inb, r_inb), (u_proc, r_proc), (u_inv, r_inv), (u_invp, r_invp), (u_fin, r_fin), (u_out, r_out), (u_rel, r_rel);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, user_id)
    VALUES (e_all, 'FX238-ALL', 'Fixture Two Three Eight', 'Fx238 Tim', 'full_time', 'office', DATE '2020-01-01', 'active', u_all);
    PERFORM pg_temp.f238_as(u_all);

    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ238-S1', 'Fixture 238 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ238-M1', 'Fixture 238 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ238-M2', 'Fixture 238 output', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;

    -- 采购单(自动批准 → 一行 purchase_order 审批留痕)+ 一次修改(一行 purchase_order_history)
    v_r := create_purchase_order(v_sup, CURRENT_DATE, CURRENT_DATE + 30, v_ccy, NULL, 'CIF', NULL, NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg', 'estimated_unit_price', 10)),
        p_category => 'equipment_goods');
    v_po := (v_r ->> 'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    PERFORM amend_purchase_order(v_po, 'fixture 238 amend', jsonb_build_object('notes', 'Deliver in two lots'));

    -- 进料批次 ①(挂采购行)· ②(没挂,给注销)· ③(给回滚)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('ZZ238-IB1', v_mat, v_sup, 100, 100, 'kg', CURRENT_DATE, v_po, v_line) RETURNING id INTO v_ib;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ238-IB2', v_mat, v_sup, 50, 50, 'kg', CURRENT_DATE, 'other', 'fixture 238 自带数据') RETURNING id INTO v_ib2;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ238-IB3', v_mat, v_sup, 40, 40, 'kg', CURRENT_DATE, 'other', 'fixture 238 自带数据') RETURNING id INTO v_ib3;
    PERFORM reprice_inbound_batch(v_ib, 2, v_ccy, NULL, 'fixture 238 price');
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT b, 'discharged_verified' FROM unnest(ARRAY[v_ib, v_ib2, v_ib3]) b
     WHERE NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s WHERE s.inbound_batch_id = b);

    -- K1 · K2 化验(带金属)与金属含量
    v_r := record_assay_result(CURRENT_DATE, '[{"metal": "ni", "content_pct": 12.5}, {"metal": "co", "content_pct": 3}]'::jsonb,
        NULL, 'CERT-238', NULL, true, 'fixture 238 assay', v_ib, NULL, 'dry', NULL, 'ours');
    SELECT id INTO v_assay FROM assay_results WHERE inbound_batch_id = v_ib ORDER BY created_at DESC LIMIT 1;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (v_ib, 'li', 4, 'manual') ON CONFLICT DO NOTHING;

    -- 工单(自动放行 → 一行 work_order 审批留痕 + 修改史)
    v_r := create_work_order(jsonb_build_array(jsonb_build_object('material_id', v_mat, 'planned_qty', 100)), NULL, CURRENT_DATE, 'fixture 238 wo');
    v_wo := COALESCE((v_r ->> 'work_order_id')::uuid, (v_r ->> 'id')::uuid);
    PERFORM pg_temp.f238_as(u_rel);
    PERFORM release_work_order(v_wo);
    PERFORM pg_temp.f238_as(u_all);

    -- 加工:把 ① 整批用完 → 产出批次、投入 / 产出、流水、阶段、销毁证书
    v_run := commit_processing_run(CURRENT_DATE, 'fixture 238 run', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 80)), 'weight', v_wo, NULL, 'manual_disassembly');
    SELECT output_batch_id INTO v_ob FROM processing_outputs WHERE run_id = v_run;
    -- 成本条目(→ 修改史 + processing_cost 分录)与分摊(→ allocation 分录 + 批次成本分摊)
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes, created_by, updated_by)
    VALUES (v_run, 'labour', 200, false, 'fixture 238 labour', u_all, u_all);
    PERFORM allocate_processing_costs(v_run, 'weight');

    -- 盘点:一次清点(→ stocktake_counts)· 过账(自动批准 → 审批留痕 · 有差 → 盘点分录)
    v_st := (open_stocktake('fixture 238 stocktake') ->> 'stocktake_id')::uuid;
    PERFORM record_stocktake_count(v_st, NULL, v_ob, 78, 'two kg short');
    PERFORM pg_temp.f238_as(u_rel);   -- 开单与录数的人不能过账(四眼)
    PERFORM post_stocktake(v_st);
    PERFORM pg_temp.f238_as(u_all);

    -- 销售(→ 销售记录 · 出库流水 · 销售流水 · 成本分录)
    PERFORM record_output_sale(v_ob, 10, 5, v_ccy, NULL, NULL, CURRENT_DATE, 'fixture 238 sale');

    -- J 冲销批次 ① 的计价分录(备注里一个 REVERSAL 都不写)
    SELECT id INTO v_je FROM journal_entries WHERE source_id = v_ib AND status = 'posted' ORDER BY created_at LIMIT 1;
    PERFORM reverse_journal_entry_internal(v_je, CURRENT_DATE, 'plain words only');

    -- K4 · Q 注销批次 ②(审批关着 → 申请生下来就批准并当场生效)
    PERFORM submit_inbound_write_off_request(v_ib2, 'fixture 238 write-off');
    SELECT id INTO v_wr FROM warehouse_requests WHERE inbound_batch_id = v_ib2;

    -- N · Q 批次 ③ 被一张加工单消耗,那张单随后回滚
    v_run2 := commit_processing_run(CURRENT_DATE, 'fixture 238 run 2', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib3, 'quantity_consumed', 10)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 10)), 'weight', NULL, NULL, 'manual_disassembly');
    PERFORM rollback_processing_run_internal(v_run2, 'fixture 238 rollback');

    -- ══════════════ B · 逐行对照 ══════════════
    v_j := pg_temp.f238_trail(u_all, 'inbound_batch', v_ib::text);
    IF v_j ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 B1: %', v_j; END IF;
    v_miss := pg_temp.f238_missing('inbound', v_ib, v_j);
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 B1: inbound batch trail is missing old rows: %', v_miss; END IF;
    v_j2 := pg_temp.f238_trail(u_all, 'output_batch', v_ob::text);
    IF v_j2 ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 B2: %', v_j2; END IF;
    v_miss := pg_temp.f238_missing('output', v_ob, v_j2);
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 B2: output batch trail is missing old rows: %', v_miss; END IF;
    v_x := pg_temp.f238_trail(u_all, 'inbound_batch', v_ib2::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 B3: %', v_x; END IF;
    v_miss := pg_temp.f238_missing('inbound', v_ib2, v_x);
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 B3: written-off batch trail is missing old rows: %', v_miss; END IF;
    v_x := pg_temp.f238_trail(u_all, 'inbound_batch', v_ib3::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 B4: %', v_x; END IF;
    v_miss := pg_temp.f238_missing('inbound', v_ib3, v_x);
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 B4: rolled-back batch trail is missing old rows: %', v_miss; END IF;
    -- B5 往上一跳的那几种这一支真的造出来了(否则 B1 是在空集上说"一行不少")
    SELECT string_agg(k, ', ') INTO v_miss FROM unnest(ARRAY['cost_entry_change', 'approval', 'work_order_change', 'po_change',
        'journal_entry:processing_cost', 'journal_entry:allocation', 'journal_entry:purchase']) k
     WHERE NOT EXISTS (
        SELECT 1 FROM batch_audit_trail_all o LEFT JOIN journal_entries je ON o.source_table = 'journal_entries' AND je.id = o.source_id
         WHERE o.batch_id = v_ib AND (o.event_kind = k OR o.event_kind || ':' || COALESCE(je.source_type, '') = k));
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 B5: the fixture did not exercise the upward kinds: %', v_miss; END IF;
    SELECT string_agg(DISTINCT k, ', ') INTO v_miss FROM unnest(ARRAY['journal_entry:stocktake', 'journal_entry:sale', 'sale', 'sale_movement',
        'stocktake_line', 'run_output', 'movement']) k
     WHERE NOT EXISTS (
        SELECT 1 FROM batch_audit_trail_all o LEFT JOIN journal_entries je ON o.source_table = 'journal_entries' AND je.id = o.source_id
         WHERE o.batch_id = v_ob AND (o.event_kind = k OR o.event_kind || ':' || COALESCE(je.source_type, '') = k));
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 B5: the fixture did not exercise the output kinds: %', v_miss; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e JOIN journal_entries je ON je.id::text = e -> 'row_key' ->> 'id'
                    WHERE e ->> 'table_name' = 'journal_entries' AND je.id <> v_je AND je.source_id = v_je) THEN
        RAISE EXCEPTION 'FIXTURE 238 J: the reversal of the batch''s pricing journal is not in the trail';
    END IF;
    -- B6 垫脚石的行一行都不在
    SELECT string_agg(DISTINCT e ->> 'table_name', ', ') INTO v_miss FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' IN ('purchase_orders', 'processing_runs', 'work_orders', 'stocktakes', 'processing_cost_entries', 'sales_order_lines');
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 B6: stepping-stone rows leaked into the batch trail: %', v_miss; END IF;

    -- ══════════════ K · 新加的几种 ══════════════
    SELECT string_agg(k, ', ') INTO v_miss FROM unnest(ARRAY['assay_results', 'assay_result_metals', 'inbound_batch_metals',
        'inbound_batch_safety_states', 'certificates_of_destruction']) k
     WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = k);
    IF v_miss IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 238 K1-K3/K5: missing added kinds on the inbound batch: %', v_miss; END IF;
    v_x := pg_temp.f238_trail(u_all, 'inbound_batch', v_ib2::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 K4: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'warehouse_requests')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'approval_log' AND e -> 'new' ->> 'subject_type' = 'warehouse_request') THEN
        RAISE EXCEPTION 'FIXTURE 238 K4: the write-off request and its approval are not on the written-off batch';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j2) e WHERE e ->> 'table_name' = 'stocktake_counts') THEN
        RAISE EXCEPTION 'FIXTURE 238 K6: the stocktake count is not on the output batch';
    END IF;

    -- ══════════════ H · 看不见的行占着位置 ══════════════
    v_x := pg_temp.f238_trail(u_inb, 'inbound_batch', v_ib::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 H: an inbound-only reader was refused: %', v_x; END IF;
    IF jsonb_array_length(v_x) <> jsonb_array_length(v_j) THEN
        RAISE EXCEPTION 'FIXTURE 238 H: the inbound-only reader got % rows, the full reader %', jsonb_array_length(v_x), jsonb_array_length(v_j);
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_x) e WHERE (e ->> 'row_hidden')::boolean;
    IF v_n = 0 THEN RAISE EXCEPTION 'FIXTURE 238 H: the inbound-only reader should see some rows as Restricted (journals, movements)'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE (e ->> 'row_hidden')::boolean
                 AND (e ->> 'table_name' IS NOT NULL OR e -> 'row_key' <> 'null'::jsonb OR e -> 'new' <> 'null'::jsonb OR e -> 'actor' <> 'null'::jsonb)) THEN
        RAISE EXCEPTION 'FIXTURE 238 H: a hidden row still carries a table, key, value or actor';
    END IF;
    v_x := pg_temp.f238_trail(u_no, 'inbound_batch', v_ib::text);
    IF COALESCE(v_x ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 238 H: a reader with no module should be refused by name, got %', v_x;
    END IF;

    -- ══════════════ N · 状态说明的依据 ══════════════
    v_x := pg_temp.f238_trail(u_all, 'inbound_batch', v_ib2::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 N: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e
                    WHERE e ->> 'table_name' = 'inbound_batches' AND e -> 'ctx' ? 'purchase_order_line_id'
                      AND e -> 'ctx' -> 'purchase_order_line_id' = 'null'::jsonb) THEN
        RAISE EXCEPTION 'FIXTURE 238 N: the batch without a PO line does not carry an empty purchase_order_line_id in its context';
    END IF;
    v_x := pg_temp.f238_trail(u_all, 'inbound_batch', v_ib3::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 N: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e
                    WHERE e ->> 'table_name' = 'processing_inputs'
                      AND (e -> 'refs' -> 'run_id' -> (v_run2::text) ->> 'ended')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 238 N: the input of a rolled-back run does not say the run ended: %', v_x;
    END IF;

    -- ══════════════ Q · Q21 ══════════════
    v_x := pg_temp.f238_trail(u_inb, 'inbound_batch', v_ib2::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 Q: an inbound reader was refused a written-off batch: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e
            WHERE e ->> 'table_name' = 'inbound_batches' AND e ->> 'op' = 'UPDATE' AND 'deleted_at' = ANY (ARRAY(SELECT jsonb_array_elements_text(e -> 'changed_columns')))) THEN
        RAISE EXCEPTION 'FIXTURE 238 Q: an inbound reader cannot read the write-off on a written-off batch: %', v_x;
    END IF;
    v_x := pg_temp.f238_trail(u_proc, 'processing_run', v_run2::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 Q: a processing reader was refused a reversed run: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e
            WHERE e ->> 'table_name' = 'processing_runs' AND e -> 'new' ->> 'status' = 'reversed') THEN
        RAISE EXCEPTION 'FIXTURE 238 Q: a processing reader cannot read the reversal of a reversed run: %', v_x;
    END IF;

    -- ══════════════ S · 盘点:过账与审批同一条;22/09 之前的过账只有一戳 ══════════════
    v_x := pg_temp.f238_trail(u_all, 'stocktake', v_st::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 S: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) a, jsonb_array_elements(v_x) b
                    WHERE a ->> 'table_name' = 'stocktakes' AND a -> 'new' ->> 'status' = 'posted'
                      AND b ->> 'table_name' = 'approval_log' AND b -> 'new' ->> 'subject_type' = 'stocktake'
                      AND a ->> 'entry_no' = b ->> 'entry_no') THEN
        RAISE EXCEPTION 'FIXTURE 238 S: the posting and its approval are not one entry: %', v_x;
    END IF;
    ALTER TABLE stocktakes DISABLE TRIGGER zzz_change_log;
    INSERT INTO stocktakes (code, status, notes, created_at, posted_at, started_at)
    VALUES ('ZZ238-ST-OLD', 'posted', 'fixture 238 pre-log stocktake', v_began - interval '5 days', v_began - interval '4 days', v_began - interval '5 days')
    RETURNING id INTO v_st_old;
    ALTER TABLE stocktakes ENABLE TRIGGER zzz_change_log;
    v_x := pg_temp.f238_trail(u_all, 'stocktake', v_st_old::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 S: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e
                    WHERE (e ->> 'prelog')::boolean AND e ->> 'op' = 'UPDATE' AND e -> 'new' ->> 'status' = 'posted'
                      AND e -> 'changed_columns' ? 'posted_at') THEN
        RAISE EXCEPTION 'FIXTURE 238 S: a pre-22/09 posting is not rebuilt from its posted_at stamp: %', v_x;
    END IF;

    -- ══════════════ W · /inventory 的申请那一块 ══════════════
    v_x := pg_temp.f238_trail(u_inv, 'warehouse_request', v_wr::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 W: an inventory reader was refused the request trail: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'warehouse_requests' AND e ->> 'op' = 'INSERT'
                     AND e -> 'new' -> 'amount_base' = k_restricted) THEN
        RAISE EXCEPTION 'FIXTURE 238 W: the amount should be Restricted for a reader without data.view_prices: %', v_x;
    END IF;
    v_x := pg_temp.f238_trail(u_invp, 'warehouse_request', v_wr::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 W: %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_x) e WHERE e ->> 'table_name' = 'warehouse_requests' AND e ->> 'op' = 'INSERT'
                     AND jsonb_typeof(e -> 'new' -> 'amount_base') = 'number') THEN
        RAISE EXCEPTION 'FIXTURE 238 W: a reader with data.view_prices should see the amount: %', v_x;
    END IF;
    v_x := pg_temp.f238_trail(u_fin, 'warehouse_request', v_wr::text);
    IF v_x ? 'error' THEN RAISE EXCEPTION 'FIXTURE 238 W: a finance-only reader was refused (M1 any-of): %', v_x; END IF;
    v_x := pg_temp.f238_trail(u_out, 'warehouse_request', v_wr::text);
    IF COALESCE(v_x ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 238 W: a reader with neither code should be refused, got %', v_x;
    END IF;
    v_x := pg_temp.f238_json(u_inv, format('SELECT to_jsonb(count(*)) FROM warehouse_requests_masked WHERE id = %L AND amount_base IS NULL', v_wr));
    IF v_x IS DISTINCT FROM '1'::jsonb THEN RAISE EXCEPTION 'FIXTURE 238 W: the masked view should give the inventory reader a NULL amount, got %', v_x; END IF;
    v_x := pg_temp.f238_json(u_inv, format('SELECT to_jsonb(count(*)) FROM warehouse_requests WHERE id = %L', v_wr));
    IF v_x IS DISTINCT FROM '1'::jsonb THEN RAISE EXCEPTION 'FIXTURE 238 W: the inventory reader should read the request row itself, got %', v_x; END IF;
    v_x := pg_temp.f238_json(u_invp, format('SELECT to_jsonb(max(amount_base)) FROM warehouse_requests WHERE id = %L', v_wr));
    IF COALESCE(v_x ->> 'error', '') NOT LIKE '%permission denied%' THEN
        RAISE EXCEPTION 'FIXTURE 238 W: amount_base should not be readable from the base table, got %', v_x;
    END IF;

    RAISE NOTICE 'FIXTURE 238 全部通过:B1–B6 · K1–K6 · H · J · N · Q · S · W';
END;
$$;

ROLLBACK;

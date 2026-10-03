-- 240 AUDIT-TRAIL-1b-3:主数据与工具的审计记录 —— 物料 · 库位(Q13:只写变了的)· 金属价格 · 定价公式与条款申请 ·
--     任务(Q3:私人任务也是;原来那段"变更记录"一行不少)· 三个阈值面板(M5 · M6)· 删掉的主数据进被删记录(Q9)
--     (2026-10-03)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1b Step 0 §a 的登记表与 Q2 · Q3 · Q9 · Q13 · M2 · M5 · M6,Tim 2026-09-29 全部照建议裁定)
--   每一个新主语各三样:一次【字段编辑】、一次【子行改动】、一次【关键事件】都在它的审计记录里(按表、按操作、按改了哪一列认)。
--   A  物料:改规格 · 化验要求(整组换,set_material_required_metals)· 附件 · 删掉;只持物料权限的人读得到,一个码都不持的按名拒;
--      删掉的物料照样读得到(读规则不过滤 deleted_at —— 删掉的物料只读打开,Q21)
--   L  库位(Q13):save_storage_location 一次调用 —— 改名 + 换一个分类 = 恰好一行库位改动、一行删、一行加;
--      什么都没变的保存一行都不写;只拿掉一个分类 = 恰好一行删;没有 module.inventory.edit 的人按名拒(PERMISSION_DENIED)
--   P  金属价格:录入 · 改价 · 删掉;门是 action.metal_prices(编辑页的守卫),只持 module.pricing.view 的按名拒
--   F  定价公式:送 CFO(新公式)→ CFO 批准 → 送 CFO(改条款)→ 批准:公式、应付金属、修改史、两张条款申请、它们的审批
--      都在;只持 module.pricing.view(没有价格码)的读者:公式看得见,条款申请那几行是 Restricted(Q4),不是消失
--   T  任务(Q3 · M2):团队任务 —— 建、加步骤、打勾、改标题、加参与者;修改史的【每一行】都在审计记录里(原来那一段印的
--      就是这些行:Q26 的"一行不少");私人任务 —— 归属人读得到、持 module.tasks.view_all 的读得到、别人按名拒
--   N  任务"记录开始之前":修改史 + 任务的建行 + 步骤的建行与打勾戳都拼回来(人是员工 id,M2,不是 "Removed account");
--      一行只出现一次
--   S  三个阈值面板(M5 · M6):页面传 'true';每一块只交回它自己编辑的那几列 —— 只动了别的列的那一次改动整条不算;
--      门各是各的(收货面板要 module.inbound.view)
--   D  被删记录(Q9 · Q8):客户 · 供应商 · 物料 · 定价公式进 deleted_records;"谁"取自变更记录;
--      记录开始之前删掉的(变更记录里没有那一次)deleted_by 是 NULL —— 横幅只说日期,不猜
-- 【整支是一笔事务】所以本支写下的变更记录共享一个 txid —— 每一臂认的是【行】(表 · 操作 · 改了哪一列);L 臂按
--   change_log 的 seq 前后数"这一次保存写了几行"。措辞(每一句英文)不在这里证 —— 数据库不造句;它在
--   scripts/check-trail-wording.mjs 的 ⑦ 主数据样例那一臂逐句钉住。
-- 自带数据(README 第 2 条):账号、角色、员工、物料、库位、废物分类、客户、供应商全部本支自建;金属是稳定的引导数据。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f240_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f240_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f240_as(p_user);
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
CREATE FUNCTION pg_temp.f240_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT jsonb_typeof(p_trail) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                   WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                     AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
                     AND (p_new IS NULL OR e -> 'new' @> p_new))
$f$;

-- 一个读者读得到(没被拒);拒了就把拒绝原样报出来
CREATE FUNCTION pg_temp.f240_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 240 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

-- 一个读者被【按名】拒(不是一张空表)
CREATE FUNCTION pg_temp.f240_refused(p_arm text, p_trail jsonb) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) = 'array' OR p_trail ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 240 %: the reader should be refused by name (TRAIL_NOT_PERMITTED), got %', p_arm, p_trail;
    END IF;
END;
$f$;

-- 一行在一条记录里只出现一次(记录开始之后按 seq;之前按 表 · 键 · 操作 · 改了哪几列)
CREATE FUNCTION pg_temp.f240_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

-- L:自某个 seq 之后,一张表上各种操作写了几行(一次保存写了什么)
CREATE FUNCTION pg_temp.f240_wrote(p_after bigint, p_table text, p_op text) RETURNS int
LANGUAGE sql AS $f$
    SELECT count(*)::int FROM change_log c WHERE c.seq > p_after AND c.table_name = p_table AND c.op = p_op
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 持全部码(送 CFO 的人)
    u_rel  uuid := gen_random_uuid();   -- 另一个持全部码的人(批准不能是送审人自己)
    u_mat  uuid := gen_random_uuid();   -- 只有 module.materials.view
    u_inv  uuid := gen_random_uuid();   -- 只有 module.inventory.view
    u_mp   uuid := gen_random_uuid();   -- 只有 action.metal_prices
    u_pv   uuid := gen_random_uuid();   -- 只有 module.pricing.view(没有价格码)
    u_t1   uuid := gen_random_uuid();   -- module.tasks.view + edit(两张任务的归属人)
    u_t2   uuid := gen_random_uuid();   -- module.tasks.view(团队任务的参与者;不是私人任务的归属人)
    u_va   uuid := gen_random_uuid();   -- module.tasks.view + module.tasks.view_all
    u_proc uuid := gen_random_uuid();   -- 只有 module.processing.view
    u_no   uuid := gen_random_uuid();   -- 一个码都不持
    r_all uuid; r_mat uuid; r_inv uuid; r_mp uuid; r_pv uuid; r_t1 uuid; r_t2 uuid; r_va uuid; r_proc uuid;
    e_all uuid := gen_random_uuid(); e_rel uuid := gen_random_uuid(); e_t1 uuid := gen_random_uuid(); e_t2 uuid := gen_random_uuid();
    v_began timestamptz := change_log_began_at();
    t0 timestamptz;
    c1 text; c2 text; c3 text;
    v_mat uuid; v_att uuid; v_loc uuid; v_mp uuid; v_pf uuid; v_req uuid; v_req2 uuid;
    v_task uuid; v_node uuid; v_ptask uuid; v_old_task uuid; v_old_node uuid;
    v_cus uuid; v_sup uuid; v_old_sup uuid;
    v_r jsonb; v_j jsonb; v_x text; v_n int; v_s bigint;
BEGIN
    -- ══════════════ 布景 ══════════════
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx240-all@test.local', now()), (u_rel, 'fx240-rel@test.local', now()), (u_mat, 'fx240-mat@test.local', now()),
        (u_inv, 'fx240-inv@test.local', now()), (u_mp, 'fx240-mp@test.local', now()), (u_pv, 'fx240-pv@test.local', now()),
        (u_t1, 'fx240-t1@test.local', now()), (u_t2, 'fx240-t2@test.local', now()), (u_va, 'fx240-va@test.local', now()),
        (u_proc, 'fx240-proc@test.local', now()), (u_no, 'fx240-no@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-mat', 'f', 'f', true) RETURNING id INTO r_mat;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-inv', 'f', 'f', true) RETURNING id INTO r_inv;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-mp', 'f', 'f', true) RETURNING id INTO r_mp;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-pv', 'f', 'f', true) RETURNING id INTO r_pv;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-t1', 'f', 'f', true) RETURNING id INTO r_t1;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-t2', 'f', 'f', true) RETURNING id INTO r_t2;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-va', 'f', 'f', true) RETURNING id INTO r_va;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx240-proc', 'f', 'f', true) RETURNING id INTO r_proc;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_mat, 'module.materials.view'), (r_inv, 'module.inventory.view'), (r_mp, 'action.metal_prices'), (r_pv, 'module.pricing.view'),
        (r_t1, 'module.tasks.view'), (r_t1, 'module.tasks.edit'), (r_t2, 'module.tasks.view'),
        (r_va, 'module.tasks.view'), (r_va, 'module.tasks.view_all'), (r_proc, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all, r_all), (u_rel, r_all), (u_mat, r_mat), (u_inv, r_inv), (u_mp, r_mp), (u_pv, r_pv),
        (u_t1, r_t1), (u_t2, r_t2), (u_va, r_va), (u_proc, r_proc);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, user_id) VALUES
        (e_all, 'FX240-ALL', 'Fixture Two Four Zero', 'Fx240 All', 'full_time', 'office', DATE '2020-01-01', 'active', u_all),
        (e_rel, 'FX240-REL', 'Fixture Two Four Zero Rel', 'Fx240 Rel', 'full_time', 'office', DATE '2020-01-01', 'active', u_rel),
        (e_t1, 'FX240-T1', 'Fixture Task Owner', 'Fx240 Owner', 'full_time', 'office', DATE '2020-01-01', 'active', u_t1),
        (e_t2, 'FX240-T2', 'Fixture Task Helper', 'Fx240 Helper', 'full_time', 'office', DATE '2020-01-01', 'active', u_t2);
    -- 条款申请的批准要审批开着、二级审批人是一个有人持有的角色(decide_terms_request)
    --   (这四列有一道守卫:属主那一侧也要显式举旗,一次只授权这一行 —— guard_approvals_policy_write)
    PERFORM set_config('evoltrya.approvals_policy_ctx', 'fixture-240', true);
    UPDATE finance_settings SET approvals_enabled = true, approval_level1_role_code = 'fx240-all', approval_level2_role_code = 'fx240-all',
                                approval_threshold_base = 1000;
    -- 三个本支自己的废物分类(引导数据只种了两条,而 README 第 4 条:要什么自己建)
    c1 := 'ZZ240-WC1'; c2 := 'ZZ240-WC2'; c3 := 'ZZ240-WC3';
    INSERT INTO waste_classifications (code, name_en, name_zh, is_controlled) VALUES
        (c1, 'Fixture class one', 'f', false), (c2, 'Fixture class two', 'f', false), (c3, 'Fixture class three', 'f', false);
    PERFORM pg_temp.f240_as(u_all);

    -- ══════════════ A · 物料 ══════════════
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ240-M1', 'Fixture 240 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    UPDATE materials SET spec = 'fixture 240 spec' WHERE id = v_mat;
    PERFORM set_material_required_metals(v_mat, ARRAY['ni', 'co']);
    PERFORM set_material_required_metals(v_mat, ARRAY['ni', 'li']);
    INSERT INTO material_attachments (material_id, storage_path, file_name, doc_category)
    VALUES (v_mat, 'zz240/coa.pdf', 'coa.pdf', 'coa') RETURNING id INTO v_att;
    UPDATE materials SET deleted_at = now() WHERE id = v_mat;
    v_j := pg_temp.f240_ok('A (materials reader)', pg_temp.f240_trail(u_mat, 'material', v_mat::text));
    IF NOT pg_temp.f240_has(v_j, 'materials', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'materials', 'UPDATE', 'spec') THEN
        RAISE EXCEPTION 'FIXTURE 240 A: the creation / the spec edit is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f240_has(v_j, 'material_required_metals', 'INSERT', NULL, '{"metal": "li"}')
       OR NOT pg_temp.f240_has(v_j, 'material_required_metals', 'DELETE') THEN
        RAISE EXCEPTION 'FIXTURE 240 A: the assay-requirement change (a child line) is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f240_has(v_j, 'material_attachments', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 240 A: the attachment is missing: %', v_j; END IF;
    IF NOT pg_temp.f240_has(v_j, 'materials', 'UPDATE', 'deleted_at') THEN
        RAISE EXCEPTION 'FIXTURE 240 A: the deletion (the key event) is missing, or a deleted material is no longer readable: %', v_j;
    END IF;
    PERFORM pg_temp.f240_refused('A (no code)', pg_temp.f240_trail(u_no, 'material', v_mat::text));
    PERFORM pg_temp.f240_refused('A (inventory only)', pg_temp.f240_trail(u_inv, 'material', v_mat::text));

    -- ══════════════ L · 库位(Q13)══════════════
    v_loc := save_storage_location('ZZ240-L1', 'Fixture bay', ARRAY[c1, c2], NULL, 'A', NULL);
    -- 改名 + 换一个分类(c2 → c3):恰好一行库位改动(名字)、一行删(c2)、一行加(c3)
    SELECT max(seq) INTO v_s FROM change_log;
    PERFORM save_storage_location('ZZ240-L1', 'Fixture bay (north)', ARRAY[c1, c3], v_loc, 'A', NULL);
    IF pg_temp.f240_wrote(v_s, 'storage_locations', 'UPDATE') <> 1
       OR pg_temp.f240_wrote(v_s, 'storage_location_allowed_classes', 'DELETE') <> 1
       OR pg_temp.f240_wrote(v_s, 'storage_location_allowed_classes', 'INSERT') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 240 L: a rename + one class swapped should write 1 location update, 1 delete, 1 insert — got % / % / %',
            pg_temp.f240_wrote(v_s, 'storage_locations', 'UPDATE'), pg_temp.f240_wrote(v_s, 'storage_location_allowed_classes', 'DELETE'),
            pg_temp.f240_wrote(v_s, 'storage_location_allowed_classes', 'INSERT');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.seq > v_s AND c.table_name = 'storage_locations' AND c.changed_columns = ARRAY['name']) THEN
        RAISE EXCEPTION 'FIXTURE 240 L: the location update should touch only the name';
    END IF;
    -- 什么都没变的保存:一行都不写 —— 既不进变更记录,也【真的没有写】:变更记录不记一次值没变的 UPDATE,
    --   所以光看它会把"写了一次空改动"读成"没写"(本支第一版的注入就是这么没咬人的);再看行的物理版本(ctid):
    --   任何一次 UPDATE 都会留下一个新的行版本
    SELECT max(seq) INTO v_s FROM change_log;
    SELECT ctid::text || '|' || (SELECT string_agg(a.ctid::text, ',' ORDER BY a.classification_code) FROM storage_location_allowed_classes a WHERE a.location_id = v_loc)
      INTO v_x FROM storage_locations WHERE id = v_loc;
    PERFORM save_storage_location('ZZ240-L1', 'Fixture bay (north)', ARRAY[c3, c1], v_loc, 'A', NULL);
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > v_s AND c.table_name IN ('storage_locations', 'storage_location_allowed_classes')) THEN
        RAISE EXCEPTION 'FIXTURE 240 L: a save that changes nothing should write nothing';
    END IF;
    IF v_x IS DISTINCT FROM (SELECT ctid::text || '|' || (SELECT string_agg(a.ctid::text, ',' ORDER BY a.classification_code) FROM storage_location_allowed_classes a WHERE a.location_id = v_loc)
                              FROM storage_locations WHERE id = v_loc) THEN
        RAISE EXCEPTION 'FIXTURE 240 L: a save that changes nothing should write nothing (a row was rewritten)';
    END IF;
    -- 只拿掉一个分类:恰好一行删,不写别的
    SELECT max(seq) INTO v_s FROM change_log;
    PERFORM save_storage_location('ZZ240-L1', 'Fixture bay (north)', ARRAY[c1], v_loc, 'A', NULL);
    IF pg_temp.f240_wrote(v_s, 'storage_location_allowed_classes', 'DELETE') <> 1
       OR pg_temp.f240_wrote(v_s, 'storage_location_allowed_classes', 'INSERT') <> 0
       OR pg_temp.f240_wrote(v_s, 'storage_locations', 'UPDATE') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 240 L: removing one class should write exactly one delete';
    END IF;
    -- 没有 module.inventory.edit 的人:按名拒,不是一次静默的空操作
    BEGIN
        PERFORM pg_temp.f240_as(u_inv);
        PERFORM save_storage_location('ZZ240-L1', 'Hijack', ARRAY[]::text[], v_loc, NULL, NULL);
        RAISE EXCEPTION 'FIXTURE 240 L: a reader without module.inventory.edit saved a location';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'PERMISSION_DENIED|module.inventory.edit%' THEN RAISE; END IF;
    END;
    PERFORM pg_temp.f240_as(u_all);
    v_j := pg_temp.f240_ok('L (inventory reader)', pg_temp.f240_trail(u_inv, 'storage_location', v_loc::text));
    IF NOT pg_temp.f240_has(v_j, 'storage_locations', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'storage_locations', 'UPDATE', 'name') THEN
        RAISE EXCEPTION 'FIXTURE 240 L: the creation / the rename is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f240_has(v_j, 'storage_location_allowed_classes', 'INSERT', NULL, jsonb_build_object('classification_code', c3))
       OR NOT pg_temp.f240_has(v_j, 'storage_location_allowed_classes', 'DELETE') THEN
        RAISE EXCEPTION 'FIXTURE 240 L: the class change (a child line) is missing: %', v_j;
    END IF;
    PERFORM pg_temp.f240_refused('L (materials only)', pg_temp.f240_trail(u_mat, 'storage_location', v_loc::text));

    -- ══════════════ P · 金属价格 ══════════════
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 16250, DATE '2026-09-29', 'broker_quote') RETURNING id INTO v_mp;
    UPDATE metal_prices SET price_usd_per_tonne = 16300 WHERE id = v_mp;
    UPDATE metal_prices SET deleted_at = now() WHERE id = v_mp;
    v_j := pg_temp.f240_ok('P (metal prices)', pg_temp.f240_trail(u_mp, 'metal_price', v_mp::text));
    IF NOT pg_temp.f240_has(v_j, 'metal_prices', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'metal_prices', 'UPDATE', 'price_usd_per_tonne')
       OR NOT pg_temp.f240_has(v_j, 'metal_prices', 'UPDATE', 'deleted_at') THEN
        RAISE EXCEPTION 'FIXTURE 240 P: the price, its change or its deletion is missing: %', v_j;
    END IF;
    PERFORM pg_temp.f240_refused('P (pricing view only)', pg_temp.f240_trail(u_pv, 'metal_price', v_mp::text));

    -- ══════════════ F · 定价公式与条款申请 ══════════════
    v_r := submit_formula_create_request(jsonb_build_object('name', 'Fixture 240 formula', 'direction', 'purchase', 'price_basis', 'spot',
             'treatment_charge_usd_per_tonne', 300, 'flat_discount_pct', 2, 'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 75))),
             'fixture 240 new formula');
    v_pf := (v_r ->> 'formula_id')::uuid;
    v_req := (v_r ->> 'request_id')::uuid;
    IF v_pf IS NULL OR v_req IS NULL THEN RAISE EXCEPTION 'FIXTURE 240 F setup: submit_formula_create_request returned %', v_r; END IF;
    PERFORM pg_temp.f240_as(u_rel);
    PERFORM decide_terms_request(v_req, true, 'fixture 240 approved');
    PERFORM pg_temp.f240_as(u_all);
    v_r := submit_formula_change_request(v_pf, jsonb_build_object('name', 'Fixture 240 formula', 'direction', 'purchase', 'price_basis', 'spot',
             'treatment_charge_usd_per_tonne', 280, 'flat_discount_pct', 2, 'metals', jsonb_build_array(jsonb_build_object('metal', 'ni', 'payable_pct', 78))),
             'fixture 240 change');
    v_req2 := (v_r ->> 'request_id')::uuid;
    PERFORM pg_temp.f240_as(u_rel);
    PERFORM decide_terms_request(v_req2, true, NULL);
    PERFORM pg_temp.f240_as(u_all);
    v_j := pg_temp.f240_ok('F (all)', pg_temp.f240_trail(u_all, 'pricing_formula', v_pf::text));
    IF NOT pg_temp.f240_has(v_j, 'pricing_formulas', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'pricing_formulas', 'UPDATE', 'treatment_charge_usd_per_tonne') THEN
        RAISE EXCEPTION 'FIXTURE 240 F: the formula, or its change (a field edit), is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f240_has(v_j, 'pricing_formula_metals', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'pricing_formula_metals', 'UPDATE', 'payable_pct') THEN
        RAISE EXCEPTION 'FIXTURE 240 F: the payable metal, or its change (a child line), is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f240_has(v_j, 'pricing_formula_history', 'INSERT', NULL, '{"change_type": "create"}') THEN
        RAISE EXCEPTION 'FIXTURE 240 F: the formula''s history is missing: %', v_j;
    END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'terms_requests' AND e ->> 'op' = 'INSERT';
    IF v_n <> 2 OR NOT pg_temp.f240_has(v_j, 'terms_requests', 'UPDATE', 'status', '{"status": "approved"}')
       OR NOT pg_temp.f240_has(v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "terms_request", "decision": "approved"}') THEN
        RAISE EXCEPTION 'FIXTURE 240 F: the two terms requests, a decision (the key event) or its approval is missing (requests %): %', v_n, v_j;
    END IF;
    v_j := pg_temp.f240_ok('F (pricing view, no price codes)', pg_temp.f240_trail(u_pv, 'pricing_formula', v_pf::text));
    IF NOT pg_temp.f240_has(v_j, 'pricing_formulas', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 240 F: a pricing reader should see the formula: %', v_j; END IF;
    IF pg_temp.f240_has(v_j, 'terms_requests', 'INSERT')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 240 F: terms requests must be Restricted rows for a reader without the price codes (Q4), got %', v_j;
    END IF;
    PERFORM pg_temp.f240_refused('F (no code)', pg_temp.f240_trail(u_no, 'pricing_formula', v_pf::text));

    -- ══════════════ T · 任务(Q3 · M2)══════════════
    PERFORM pg_temp.f240_as(u_t1);
    INSERT INTO tasks (code, title, task_type, owner_id) VALUES ('', 'Fixture 240 team task', 'team', e_t1) RETURNING id INTO v_task;
    INSERT INTO task_nodes (task_id, title, sort_order, created_by) VALUES (v_task, 'Pack boxes', 1024, e_t1) RETURNING id INTO v_node;
    UPDATE task_nodes SET done = true, done_at = now(), done_by = e_t1 WHERE id = v_node;
    UPDATE tasks SET title = 'Fixture 240 team task (renamed)' WHERE id = v_task;
    INSERT INTO task_participants (task_id, employee_id, added_by) VALUES (v_task, e_t2, e_t1);
    v_j := pg_temp.f240_ok('T (team task, participant)', pg_temp.f240_trail(u_t2, 'task', v_task::text));
    IF NOT pg_temp.f240_has(v_j, 'tasks', 'UPDATE', 'title') THEN RAISE EXCEPTION 'FIXTURE 240 T: the title edit is missing: %', v_j; END IF;
    IF NOT pg_temp.f240_has(v_j, 'task_nodes', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'task_nodes', 'UPDATE', 'done') THEN
        RAISE EXCEPTION 'FIXTURE 240 T: the step (a child line) or its tick is missing: %', v_j;
    END IF;
    IF NOT pg_temp.f240_has(v_j, 'task_participants', 'INSERT') THEN RAISE EXCEPTION 'FIXTURE 240 T: the participant (the key event) is missing: %', v_j; END IF;
    -- Q26:原来那一段"变更记录"印的就是 task_history 的行 —— 一行不少
    SELECT string_agg(h.change_type, ', ') INTO v_x FROM task_history h WHERE h.task_id = v_task
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'task_history'
                          AND e -> 'row_key' ->> 'id' = h.id::text AND NOT (e ->> 'row_hidden')::boolean);
    IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 240 T: task history rows missing from the trail: %', v_x; END IF;
    SELECT count(*) INTO v_n FROM task_history WHERE task_id = v_task;
    IF v_n < 3 THEN RAISE EXCEPTION 'FIXTURE 240 T setup: expected at least 3 history rows on the team task, got %', v_n; END IF;
    -- 私人任务:归属人读得到,持 view_all 的读得到,别人按名拒
    PERFORM pg_temp.f240_as(u_t1);
    INSERT INTO tasks (code, title, task_type, owner_id) VALUES ('', 'Fixture 240 personal task', 'personal', e_t1) RETURNING id INTO v_ptask;
    UPDATE tasks SET status = 'in_progress' WHERE id = v_ptask;
    PERFORM pg_temp.f240_as(u_all);
    IF EXISTS (SELECT 1 FROM task_history WHERE task_id = v_ptask) THEN
        RAISE EXCEPTION 'FIXTURE 240 T setup: a personal task should have no task_history rows (trg_tasks_history)';
    END IF;
    v_j := pg_temp.f240_ok('T (personal task, owner)', pg_temp.f240_trail(u_t1, 'task', v_ptask::text));
    IF NOT pg_temp.f240_has(v_j, 'tasks', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'tasks', 'UPDATE', 'status') THEN
        RAISE EXCEPTION 'FIXTURE 240 T: the owner should see the personal task''s creation and edit (Q3): %', v_j;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_restricted')::boolean OR (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 240 T: the owner''s own personal task must not be Restricted: %', v_j;
    END IF;
    v_j := pg_temp.f240_ok('T (personal task, view_all)', pg_temp.f240_trail(u_va, 'task', v_ptask::text));
    IF NOT pg_temp.f240_has(v_j, 'tasks', 'UPDATE', 'status') THEN RAISE EXCEPTION 'FIXTURE 240 T: a view_all reader should see the personal task: %', v_j; END IF;
    PERFORM pg_temp.f240_refused('T (personal task, someone else)', pg_temp.f240_trail(u_t2, 'task', v_ptask::text));
    PERFORM pg_temp.f240_refused('T (no code)', pg_temp.f240_trail(u_no, 'task', v_task::text));

    -- ══════════════ N · 任务"记录开始之前"(M2:人是员工 id)══════════════
    t0 := v_began - interval '10 days';
    SET LOCAL session_replication_role = replica;   -- 只为拼出"记录开始之前"的样子:不写变更记录、不跑触发器
    INSERT INTO tasks (code, title, task_type, owner_id, status, created_at, created_by)
    VALUES ('ZZ240-OLD', 'Fixture 240 old task', 'team', e_t1, 'todo', t0, u_t1) RETURNING id INTO v_old_task;
    INSERT INTO task_nodes (task_id, title, sort_order, created_at, created_by, done, done_at, done_by)
    VALUES (v_old_task, 'Old step', 1024, t0 + interval '1 hour', e_t1, true, t0 + interval '2 hours', e_t1) RETURNING id INTO v_old_node;
    INSERT INTO task_history (task_id, change_type, node_id, changed_at, changed_by, new_node_title, new_sort_order) VALUES
        (v_old_task, 'node_added', v_old_node, t0 + interval '1 hour', e_t1, 'Old step', 1024);
    INSERT INTO task_history (task_id, change_type, node_id, changed_at, changed_by, old_node_done, new_node_done) VALUES
        (v_old_task, 'node_done', v_old_node, t0 + interval '2 hours', e_t1, false, true);
    INSERT INTO task_history (task_id, change_type, changed_at, changed_by, old_status, new_status) VALUES
        (v_old_task, 'header_update', t0 + interval '3 hours', e_t1, 'todo', 'done');
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f240_ok('N (old task)', pg_temp.f240_trail(u_t1, 'task', v_old_task::text));
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'task_history' AND (e ->> 'prelog')::boolean;
    IF v_n <> 3 THEN RAISE EXCEPTION 'FIXTURE 240 N: the old task''s three history rows should all be there, got % in %', v_n, v_j; END IF;
    IF NOT pg_temp.f240_has(v_j, 'tasks', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'task_nodes', 'INSERT') OR NOT pg_temp.f240_has(v_j, 'task_nodes', 'UPDATE', 'done_at') THEN
        RAISE EXCEPTION 'FIXTURE 240 N: the task''s creation, the step''s creation or its tick stamp is missing before the log: %', v_j;
    END IF;
    -- M2:修改史与步骤里的人是员工 id —— 读成那个人,不是 "Removed account"
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' IN ('task_history', 'task_nodes') AND e -> 'actor' ->> 'state' = 'removed') THEN
        RAISE EXCEPTION 'FIXTURE 240 N: an employee id was read as an account (M2): %', v_j;
    END IF;
    -- 同一时刻的步骤建行与 node_added、打勾戳与 node_done 在同一条记录里(界面并成一句)
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) a, jsonb_array_elements(v_j) b
                    WHERE a ->> 'table_name' = 'task_nodes' AND a ->> 'op' = 'INSERT' AND b ->> 'table_name' = 'task_history'
                      AND b -> 'new' ->> 'change_type' = 'node_added' AND a ->> 'entry_no' = b ->> 'entry_no') THEN
        RAISE EXCEPTION 'FIXTURE 240 N: the step''s creation and its node_added row should be one entry: %', v_j;
    END IF;
    v_x := pg_temp.f240_twice(v_j);
    IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 240 N: rows shown twice in the old task''s trail: %', v_x; END IF;

    -- ══════════════ S · 三个阈值面板(M5 · M6)══════════════
    UPDATE processing_settings SET notes = 'fixture 240 — not a panel column' WHERE id;
    UPDATE processing_settings SET wo_input_overrun_pct = wo_input_overrun_pct + 1 WHERE id;
    UPDATE pricing_settings SET notes_en = 'fixture 240 — not a panel column' WHERE id;
    UPDATE pricing_settings SET metal_price_change_warn_pct = metal_price_change_warn_pct + 1 WHERE id;
    UPDATE receiving_settings SET notes = 'fixture 240 — not a panel column' WHERE id;
    UPDATE receiving_settings SET grn_short_pct = grn_short_pct + 1, grn_over_pct = grn_over_pct + 1 WHERE id;
    FOR v_x, v_r IN SELECT * FROM (VALUES
        ('processing_settings', '["wo_input_overrun_pct", "wo_output_shortfall_pct"]'::jsonb),
        ('pricing_settings',    '["metal_price_change_warn_pct"]'::jsonb),
        ('receiving_settings',  '["grn_short_pct", "grn_over_pct", "grn_assay_tolerance_pct"]'::jsonb)) t(s, cols) LOOP
        v_j := pg_temp.f240_ok('S (' || v_x || ')', pg_temp.f240_trail(u_all, v_x, 'true'));
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = v_x AND e ->> 'op' = 'UPDATE') THEN
            RAISE EXCEPTION 'FIXTURE 240 S: % — the panel''s own change is missing (M5: the boolean key must match): %', v_x, v_j;
        END IF;
        -- M6:只交回面板自己的那几列 —— 只动了别的列的那一次整条不算;交回来的每一列都在面板的那一组里
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e, jsonb_array_elements_text(COALESCE(e -> 'changed_columns', '[]'::jsonb)) c
                    WHERE NOT (v_r ? c)) THEN
            RAISE EXCEPTION 'FIXTURE 240 S: % — a column the panel does not edit reached its trail (M6): %', v_x, v_j;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e, jsonb_object_keys(COALESCE(e -> 'new', '{}'::jsonb)) k WHERE NOT (v_r ? k)) THEN
            RAISE EXCEPTION 'FIXTURE 240 S: % — a value the panel does not edit reached its trail (M6): %', v_x, v_j;
        END IF;
        IF (SELECT count(DISTINCT e ->> 'entry_no') FROM jsonb_array_elements(v_j) e) <> 1 THEN
            RAISE EXCEPTION 'FIXTURE 240 S: % — expected exactly one entry (the panel''s change; the other column''s change dropped): %', v_x, v_j;
        END IF;
    END LOOP;
    PERFORM pg_temp.f240_ok('S (processing reader)', pg_temp.f240_trail(u_proc, 'processing_settings', 'true'));
    PERFORM pg_temp.f240_refused('S (processing reader, receiving panel)', pg_temp.f240_trail(u_proc, 'receiving_settings', 'true'));
    PERFORM pg_temp.f240_refused('S (no code)', pg_temp.f240_trail(u_no, 'pricing_settings', 'true'));

    -- ══════════════ D · 被删记录(Q9 · Q8)══════════════
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZ240-C1', 'Fixture 240 Customer', 'SG') RETURNING id INTO v_cus;
    UPDATE customers SET deleted_at = now() WHERE id = v_cus;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('draft', 'ZZ240-S1', 'Fixture 240 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    UPDATE suppliers SET deleted_at = now() WHERE id = v_sup;
    PERFORM delete_pricing_formula(v_pf);
    SET LOCAL session_replication_role = replica;   -- 记录开始之前删掉的:变更记录里没有那一次
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, created_at, deleted_at)
    VALUES ('draft', 'ZZ240-S-OLD', 'Fixture 240 old supplier', 'SG', 'goods_supplier', t0, t0 + interval '1 day') RETURNING id INTO v_old_sup;
    SET LOCAL session_replication_role = origin;
    -- 记录开始之后有人改过它的备注(不是删):那个人【不是】删它的人 —— "谁删的"不许从别的改动里猜
    UPDATE suppliers SET notes = 'fixture 240 — a later edit, not the deletion' WHERE id = v_old_sup;
    PERFORM pg_temp.f240_as(u_all);
    FOR v_x, v_r IN SELECT * FROM (VALUES ('customer', to_jsonb(v_cus)), ('supplier', to_jsonb(v_sup)), ('material', to_jsonb(v_mat)),
                                          ('pricing_formula', to_jsonb(v_pf))) t(k, i) LOOP
        SELECT count(*) INTO v_n FROM deleted_records d
         WHERE d.record_kind = v_x AND d.record_id = (v_r #>> '{}')::uuid AND d.deleted_by = u_all AND d.deleted_at IS NOT NULL;
        IF v_n <> 1 THEN
            RAISE EXCEPTION 'FIXTURE 240 D: a deleted % should be in deleted_records with the person taken from the change log (got % rows): %', v_x, v_n,
                (SELECT jsonb_agg(to_jsonb(d)) FROM deleted_records d WHERE d.record_id = (v_r #>> '{}')::uuid);
        END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM deleted_records d WHERE d.record_kind = 'supplier' AND d.record_id = v_old_sup AND d.deleted_by IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 240 D: a supplier deleted before the log should be listed with no person (date only, Q8), got % rows', v_n;
    END IF;
    -- 每一类跟着它自己模块的读权限:只持物料权限的人看得见物料那一行,看不见客户那一行
    PERFORM pg_temp.f240_as(u_mat);
    IF NOT EXISTS (SELECT 1 FROM deleted_records WHERE record_id = v_mat) OR EXISTS (SELECT 1 FROM deleted_records WHERE record_id = v_cus) THEN
        RAISE EXCEPTION 'FIXTURE 240 D: each deleted kind must follow its own module''s read permission';
    END IF;
    PERFORM pg_temp.f240_as(u_all);

    -- 上面每一条读过的记录里,一行都不出现两次
    FOR v_x IN SELECT pg_temp.f240_twice(pg_temp.f240_trail(u_all, s, i::text)) FROM (VALUES
        ('material', v_mat), ('storage_location', v_loc), ('metal_price', v_mp), ('pricing_formula', v_pf), ('task', v_task), ('task', v_ptask)) t(s, i) LOOP
        IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 240: rows shown twice: %', v_x; END IF;
    END LOOP;

    RAISE NOTICE 'FIXTURE 240 全部通过:A · L(Q13)· P · F · T(Q3)· N(M2)· S(M5 · M6)· D(Q9)';
END;
$$;

ROLLBACK;

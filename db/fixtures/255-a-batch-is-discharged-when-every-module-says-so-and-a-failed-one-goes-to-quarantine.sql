-- 255 MES-5a-1:一批料放没放完电,由它的每一个模组说了算;失败的模组要么再放一次,要么拆成一批进隔离;
--     放电的三处老毛病(P1 · P2 · P3)关掉(MES-5a Step 0 Q3–Q18 · Q29–Q34,Tim;v1.4.43)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-08-mes5a1-fixture-injections.py)必须让它红在它点名的那一臂。
--   MC     模组数:收货时给(两支收货函数末尾的参数)· 之后在批次页给(set_batch_module_count,批次模块编辑码或加工提交码;只看的人不行)·
--          非电芯形态拒 · 不是正数拒 · 记第一条结果之前必须有(BATCH_MODULE_COUNT_REQUIRED)· 不许低于已有结论的模组数 ·
--          核实之后锁住(函数与直连 UPDATE 两条路 —— 直连那一条证明 SECURITY DEFINER 的触发器在 EXECUTE 收回之后照样触发)·
--          进料批这一列在列级授权与 inbound_batches_masked 里(三件事)(Q4)
--   COMMIT verifies_by_unit 的工序提交只记下这一炉、不动状态;一张单单靠提交永远核实不了;库存一克没动;提醒臂 discharge_unverified 出现(Q5)
--   VER    每一个模组都通过 → 核实(结束"带电未放电"并记下是哪一炉、写上"已放电并核实"记下是哪一炉 —— 状态史)· 有一个判失败要再放电 → 不核实 ·
--          又一个新模组超过模组数拒 · 同一炉同一个模组记第二次拒 · 再放一次电沿用同一个模组标识、最新的赢、重放次数是推出来的 ·
--          核实之后提醒臂消失、模组数锁住 · 判失败不给处置拒、判通过却给处置拒(Q6 · Q7 · Q12)
--   CORR   更正是新行、要理由;更正过的那一条不能再更正;什么都没改拒;把通过更正成失败让一批已经核实的料重新拦在火闸外,改回来又核实(Q7)
--   REV    一炉放电回滚之后它的结果不再算数:状态撤回、"带电未放电"重开,结论数归零(Q6 · 状态史与回滚)
--   P1     只放一部分(10 kg / 100 kg,两个模组里只记了一个)不核实整批
--   P2     一炉放电之后这一批被别的单用掉一部分,再回滚那一炉放电:能回滚,库存不被"还原"成不存在的数,没有还原流水
--   P3     放一批自产料:库存一克没动,不写 processing_consume
--   RES    字段与按名拒:未来的判定时刻 · 早于那一炉开始 · 负电压 · 不认识的判定 · 不是这一炉的投料 · 不按逐件核实的工序 · 没有采集码的人(Q7 · Q10)
--   V9     通过电压为空 → 判不了(NULL);给了之后,与它矛盾的判定被标出来却照样记下、照样算数(从不替人判);待补的值 V9 在这种物料有了
--          放电结果之后才列,给了就消失(Q8 · Q32)
--   CHAN   通道分配只追加:一个通道一个模组、一个模组一个通道;结果带的通道号与分配矛盾拒;更正 / 撤回是新行;直连改拒;只有 aftercare 码(Q9)
--   SPLIT  拆去隔离:没有隔离库位拒 · 拆一个不是"失败 · 隔离"的模组拒 · 拆走的质量从原批扣掉 · 新批同一物料、模组数 = 拆走的个数、
--          带"带电未放电"、整批在那个隔离库位上 · 原批照规则核实(通过 + 拆走 = 模组数),记下是拆分那一炉 · 拆走的模组不能再在原批上记结果 ·
--          提醒臂 discharge_quarantine_pending 出现又消失 · 回滚拆分那一炉:原批不再核实、那个模组回到"待拆" · 没有 aftercare 码拒(Q11)
--   ING    discharge_module 这一类的设备转换器【没有建】(格式没人给过 —— MES-3b Q25 · MES-4a Q14):设备来的行只会停在 awaiting_transform,
--          不会悄悄变成一条结果
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的调用真的切成 authenticated + 那个人的 JWT。日期 = 昨天,一炉从 09:00 跑到 11:00,
-- 判定在 10:00 与 10:30(不在将来、不早于开始)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f255_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 之后身份回到【调用之前】的那一个(没有就回到 p_back)—— 一句以别人身份跑的调用不许把后面的提交悄悄换成那个人。
CREATE FUNCTION pg_temp.f255_do(p_user uuid, p_sql text, p_back uuid) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f255_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    IF v_prev IS NOT NULL THEN PERFORM set_config('request.jwt.claims', v_prev, true); ELSE PERFORM pg_temp.f255_as(p_back); END IF;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    IF v_prev IS NOT NULL THEN PERFORM set_config('request.jwt.claims', v_prev, true); ELSE PERFORM pg_temp.f255_as(p_back); END IF;
    RETURN SQLERRM;
END;
$f$;

-- 以某个人读一个值(读不到就抛 —— 读的失败不许被读成一个答案)
CREATE FUNCTION pg_temp.f255_get(p_user uuid, p_sql text, p_back uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f255_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    IF v_prev IS NOT NULL THEN PERFORM set_config('request.jwt.claims', v_prev, true); ELSE PERFORM pg_temp.f255_as(p_back); END IF;
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    IF v_prev IS NOT NULL THEN PERFORM set_config('request.jwt.claims', v_prev, true); ELSE PERFORM pg_temp.f255_as(p_back); END IF;
    RAISE;
END;
$f$;

-- 一批进料:定价、化学确定、带一个安全状态、可选一个模组数(直写,以 postgres 跑)
CREATE FUNCTION pg_temp.f255_ib(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_state text, p_d date, p_count integer DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 module_count)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, 'kg', p_d - 1, 'other', 'fixture 255 自带数据', p_count) RETURNING id INTO v;
    PERFORM reprice_inbound_batch(v, 1, v_ccy, NULL, 'f255');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v;
    IF p_state IS NOT NULL THEN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, p_state);
    END IF;
    RETURN v;
END;
$f$;

-- 提交一炉(以当前的 JWT、authenticated 跑);返回 run id,失败抛原文
CREATE FUNCTION pg_temp.f255_run(p_op text, p_inputs jsonb, p_outputs jsonb, p_d date) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v := commit_processing_run(p_d, 'f255', NULL, p_inputs, p_outputs, 'weight', NULL, NULL, p_op,
                               p_started_at => p_d::timestamptz + interval '9 hours', p_ended_at => p_d::timestamptz + interval '11 hours',
                               p_shift_code => 'day');
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f255_in(p_ib uuid, p_q numeric) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT jsonb_build_object('inbound_batch_id', p_ib, 'quantity_consumed', p_q) $f$;

-- 记一条结果(以当前 JWT、authenticated):返回 'OK' 或错误原文
CREATE FUNCTION pg_temp.f255_res(p_user uuid, p_run uuid, p_kind text, p_batch uuid, p_ref text, p_v numeric, p_verdict text, p_at timestamptz,
                                 p_disp text DEFAULT NULL, p_channel integer DEFAULT NULL) RETURNS text
LANGUAGE sql AS $f$
    SELECT pg_temp.f255_do(p_user, format($q$SELECT record_discharge_module_result(%L, %L, %L, %L, %L, %L, %L, %L, %L)$q$,
                                         p_run, p_kind, p_batch, p_ref, p_v, p_verdict, p_at, p_disp, p_channel),
                           p_user)
$f$;

-- 这一批此刻开着哪几个状态(排好序的一串)
CREATE FUNCTION pg_temp.f255_states(p_batch uuid) RETURNS text
LANGUAGE sql AS $f$
    SELECT COALESCE(string_agg(safety_state_code, ',' ORDER BY safety_state_code), '')
      FROM (SELECT safety_state_code FROM inbound_batch_safety_states WHERE inbound_batch_id = p_batch AND ended_at IS NULL
            UNION ALL
            SELECT safety_state_code FROM output_batch_safety_states WHERE output_batch_id = p_batch AND ended_at IS NULL) s
$f$;

DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 全部码
    u_view  uuid := gen_random_uuid();   -- 只看加工
    u_cap   uuid := gen_random_uuid();   -- 采集确认 + 看加工
    u_after uuid := gen_random_uuid();   -- 提交之后的记录(aftercare)+ 看加工
    u_inb   uuid := gen_random_uuid();   -- 进料编辑 + 看进料
    r uuid;
    d   date := CURRENT_DATE - 1;
    t9  timestamptz;
    t10 timestamptz;
    t1030 timestamptz;
    v_sup uuid; m_mod uuid; m_bm uuid; m_cell uuid;
    ba uuid; bb uuid; bc uuid; bd uuid; bf uuid; bg uuid; bn uuid; bx uuid; ob uuid;
    run1 uuid; run2 uuid; run_b uuid; run_c uuid; run_d uuid; run_f uuid; run_g uuid; run_md uuid; run_ob uuid; run_x uuid;
    l_norm uuid; l_q uuid;
    v_msg text; v_n bigint; v_num numeric; v_j jsonb; v_id bigint; v_id2 bigint; v_txt text; v_split uuid; v_new uuid;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    t9 := d::timestamptz + interval '9 hours';
    t10 := d::timestamptz + interval '10 hours';
    t1030 := d::timestamptz + interval '10 hours 30 minutes';

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx255-all@test.local', now(), now()), (u_view, 'fx255-view@test.local', now(), now()),
        (u_cap, 'fx255-cap@test.local', now(), now()), (u_after, 'fx255-after@test.local', now(), now()),
        (u_inb, 'fx255-inb@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx255-all', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx255-view', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_view, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx255-cap', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view'), (r, 'action.confirm_capture');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_cap, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx255-after', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view'), (r, 'action.processing_aftercare');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_after, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx255-inb', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.inbound.view'), (r, 'module.inbound.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_inb, r);
    PERFORM pg_temp.f255_as(u_all);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ255-S', 'f255 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ255-MOD', 'f255 modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ255-CELL', 'f255 cells', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction') RETURNING id INTO m_cell;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ255-BM', 'f255 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO storage_locations (code, name, is_active, is_quarantine) VALUES ('ZZ255-NORM', 'f255 shelf', true, false) RETURNING id INTO l_norm;

    -- ══════════════ MC · 模组数 ══════════════
    RAISE NOTICE 'fixture 255 · MC';
    -- 收货时给(末尾的参数)
    v_j := pg_temp.f255_get(u_all, format($q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f255', p_module_count => 3)$q$, m_mod, v_sup, d), u_all);
    IF (SELECT module_count FROM inbound_batches WHERE id = (v_j ->> 'batch_id')::uuid) IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'FIXTURE 255 MC: the receipt did not record the module count'; END IF;
    -- 收货时不给 = 没记;之后在批次页给(进料编辑码);只看的人给不了
    v_j := pg_temp.f255_get(u_all, format($q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f255')$q$, m_mod, v_sup, d), u_all);
    bn := (v_j ->> 'batch_id')::uuid;
    IF (SELECT module_count FROM inbound_batches WHERE id = bn) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 255 MC: a receipt without a module count should leave it empty'; END IF;
    v_msg := pg_temp.f255_do(u_view, format($q$SELECT set_batch_module_count('inbound', %L, 4)$q$, bn), u_all);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.inbound.edit%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: a viewer must not set it, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_inb, format($q$SELECT set_batch_module_count('inbound', %L, 4)$q$, bn), u_all);
    IF v_msg <> 'OK' OR (SELECT module_count FROM inbound_batches WHERE id = bn) IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'FIXTURE 255 MC: the batch module''s edit code should set it later, got %', v_msg; END IF;
    -- 非电芯形态拒;不是正数拒(收货与批次页两条路)
    bx := pg_temp.f255_ib('ZZ255-BX', m_bm, v_sup, 10, NULL, d);
    v_msg := pg_temp.f255_do(u_inb, format($q$SELECT set_batch_module_count('inbound', %L, 2)$q$, bx), u_all);
    IF v_msg NOT LIKE 'MODULE_COUNT_NOT_APPLICABLE|ZZ255-BX|black_mass%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: black mass must not carry a module count, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_inb, format($q$SELECT set_batch_module_count('inbound', %L, 0)$q$, bn), u_all);
    IF v_msg NOT LIKE 'MODULE_COUNT_INVALID|0%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: zero modules, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_all, format($q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 10,
        p_arrival_date => %L, p_source_reason_code => 'other', p_source_reason_note => 'f255', p_module_count => -1)$q$, m_mod, v_sup, d), u_all);
    IF v_msg NOT LIKE 'MODULE_COUNT_INVALID|-1%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: a negative count at receipt, got %', v_msg; END IF;
    -- 进料批这一列可读(列级授权)并且在遮蔽视图里(三件事)
    IF has_column_privilege('authenticated', 'public.inbound_batches'::regclass, 'module_count', 'SELECT') IS NOT TRUE
       OR NOT EXISTS (SELECT 1 FROM information_schema.columns
                       WHERE table_schema = 'public' AND table_name = 'inbound_batches_masked' AND column_name = 'module_count') THEN
        RAISE EXCEPTION 'FIXTURE 255 MC: inbound_batches.module_count must be in the column grant and in inbound_batches_masked'; END IF;
    -- 记第一条结果之前必须有
    bx := pg_temp.f255_ib('ZZ255-NOC', m_mod, v_sup, 50, 'charged_not_discharged', d);
    run_x := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(bx, 50)), '[]'::jsonb, d);
    v_msg := pg_temp.f255_res(u_cap, run_x, 'inbound', bx, 'M01', 0.4, 'pass', t10);
    IF v_msg NOT LIKE 'BATCH_MODULE_COUNT_REQUIRED|ZZ255-NOC%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: a result before the module count, got %', v_msg; END IF;

    -- ══════════════ COMMIT · 提交只记下这一炉 ══════════════
    RAISE NOTICE 'fixture 255 · COMMIT';
    ba := pg_temp.f255_ib('ZZ255-A', m_mod, v_sup, 200, 'charged_not_discharged', d, 2);
    run1 := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(ba, 200)), '[]'::jsonb, d);
    IF pg_temp.f255_states(ba) <> 'charged_not_discharged' THEN
        RAISE EXCEPTION 'FIXTURE 255 COMMIT: a commit on a verifies_by_unit operation must leave the state alone, got %', pg_temp.f255_states(ba); END IF;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = ba) <> 200 THEN
        RAISE EXCEPTION 'FIXTURE 255 COMMIT: a discharge must not take stock'; END IF;
    v_n := (pg_temp.f255_get(u_view, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'discharge_unverified' AND subject = 'ZZ255-A' AND item_id = %L$q$, run1), u_all))::text::bigint;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 255 COMMIT: discharge_unverified should list the batch after a commit (got %)', v_n; END IF;

    -- ══════════════ VER · 每一个模组都说了才核实 ══════════════
    RAISE NOTICE 'fixture 255 · VER';
    v_msg := pg_temp.f255_res(u_cap, run1, 'inbound', ba, 'M01', 0.4, 'pass', t10);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 255 VER: recording a pass, got %', v_msg; END IF;
    IF pg_temp.f255_states(ba) <> 'charged_not_discharged' THEN
        RAISE EXCEPTION 'FIXTURE 255 VER: one of two modules passed — the batch must not be verified yet'; END IF;
    v_msg := pg_temp.f255_res(u_cap, run1, 'inbound', ba, 'M02', 8.1, 'fail', t10);
    IF v_msg NOT LIKE 'DISCHARGE_DISPOSITION_REQUIRED|M02%' THEN RAISE EXCEPTION 'FIXTURE 255 VER: a fail without a disposition, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run1, 'inbound', ba, 'M02', 0.4, 'pass', t10, 'quarantine');
    IF v_msg NOT LIKE 'DISCHARGE_DISPOSITION_ON_PASS|M02%' THEN RAISE EXCEPTION 'FIXTURE 255 VER: a pass with a disposition, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run1, 'inbound', ba, 'M02', 8.1, 'fail', t10, 're_discharge');
    IF v_msg <> 'OK' OR pg_temp.f255_states(ba) <> 'charged_not_discharged' THEN
        RAISE EXCEPTION 'FIXTURE 255 VER: a module failed for re-discharge — the batch must stay charged (%)', v_msg; END IF;
    IF (SELECT failed_redischarge FROM discharge_batch_status_all WHERE batch_id = ba) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 255 VER: the status should count one module awaiting re-discharge'; END IF;
    v_msg := pg_temp.f255_res(u_cap, run1, 'inbound', ba, 'M03', 0.4, 'pass', t10);
    IF v_msg NOT LIKE 'DISCHARGE_MODULES_EXCEED_COUNT|ZZ255-A|2%' THEN RAISE EXCEPTION 'FIXTURE 255 VER: a third module on a two-module batch, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run1, 'inbound', ba, 'M01', 0.3, 'pass', t1030);
    IF v_msg NOT LIKE 'DISCHARGE_RESULT_ALREADY_RECORDED|M01%' THEN RAISE EXCEPTION 'FIXTURE 255 VER: the same module twice on one run, got %', v_msg; END IF;
    -- 再放一次电:沿用 M02,最新的赢 → 核实,记下是这一炉
    run2 := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(ba, 100)), '[]'::jsonb, d);
    v_msg := pg_temp.f255_res(u_cap, run2, 'inbound', ba, 'M02', 0.5, 'pass', t1030);
    IF v_msg <> 'OK' OR pg_temp.f255_states(ba) <> 'discharged_verified' THEN
        RAISE EXCEPTION 'FIXTURE 255 VER: after the re-discharge passed every module, the batch should be verified (%, %)', v_msg, pg_temp.f255_states(ba); END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = ba AND safety_state_code = 'charged_not_discharged'
                     AND ended_by_run_id = run2 AND end_reason LIKE 'verified by module results (PROC-%')
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = ba AND safety_state_code = 'discharged_verified'
                        AND ended_at IS NULL AND created_by_run_id = run2) THEN
        RAISE EXCEPTION 'FIXTURE 255 VER: the state history must name the run that verified the batch'; END IF;
    IF (SELECT redischarge_count FROM discharge_module_current_all WHERE batch_id = ba AND module_ref = 'M02') <> 1
       OR (SELECT verdict FROM discharge_module_current_all WHERE batch_id = ba AND module_ref = 'M02') <> 'pass' THEN
        RAISE EXCEPTION 'FIXTURE 255 VER: the latest result should win and the re-discharge count should be derived (1)'; END IF;
    v_n := (pg_temp.f255_get(u_view, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'discharge_unverified' AND subject = 'ZZ255-A'$q$, u_all))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 255 VER: discharge_unverified should clear once the batch is verified'; END IF;
    -- 核实之后模组数锁住:函数与直连 UPDATE 两条路(直连那一条证明触发器在 EXECUTE 收回之后照样触发)
    v_msg := pg_temp.f255_do(u_inb, format($q$SELECT set_batch_module_count('inbound', %L, 3)$q$, ba), u_all);
    IF v_msg NOT LIKE 'MODULE_COUNT_LOCKED|ZZ255-A%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: the count must lock once verified, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_inb, format($q$UPDATE inbound_batches SET module_count = 3 WHERE id = %L$q$, ba), u_all);
    IF v_msg NOT LIKE 'MODULE_COUNT_LOCKED|ZZ255-A%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: a direct UPDATE must meet the same lock, got %', v_msg; END IF;

    -- ══════════════ CORR · 更正是新行 ══════════════
    RAISE NOTICE 'fixture 255 · CORR';
    SELECT id INTO v_id FROM discharge_module_results WHERE run_id = run1 AND inbound_batch_id = ba AND module_ref = 'M01';
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT correct_discharge_module_result(%L, 7.9, 'fail', %L, 're_discharge', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)$q$, v_id, t10), u_all);
    IF v_msg NOT LIKE 'DISCHARGE_CORRECTION_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 255 CORR: a correction without a reason, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT correct_discharge_module_result(%L, 0.4, 'pass', %L, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'no change')$q$, v_id, t10), u_all);
    IF v_msg NOT LIKE 'DISCHARGE_CORRECTION_SAME_VALUE%' THEN RAISE EXCEPTION 'FIXTURE 255 CORR: a correction that changes nothing, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT correct_discharge_module_result(%L, 7.9, 'fail', %L, 're_discharge', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'misread the screen')$q$, v_id, t10), u_all);
    IF v_msg <> 'OK' OR pg_temp.f255_states(ba) <> 'charged_not_discharged' THEN
        RAISE EXCEPTION 'FIXTURE 255 CORR: correcting a pass to a fail must put the batch back behind the fire gate (%, %)', v_msg, pg_temp.f255_states(ba); END IF;
    IF (SELECT count(*) FROM discharge_module_results WHERE corrects_id = v_id AND correction_reason = 'misread the screen') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 255 CORR: the correction should be a new row pointing at the original, with its reason'; END IF;
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT correct_discharge_module_result(%L, 0.2, 'pass', %L, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'again')$q$, v_id, t10), u_all);
    IF v_msg NOT LIKE format('DISCHARGE_RESULT_SUPERSEDED|%s%%', v_id) THEN RAISE EXCEPTION 'FIXTURE 255 CORR: a superseded row may not be corrected again, got %', v_msg; END IF;
    SELECT id INTO v_id2 FROM discharge_module_results WHERE corrects_id = v_id;
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT correct_discharge_module_result(%L, 0.2, 'pass', %L, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'second reading')$q$, v_id2, t10), u_all);
    IF v_msg <> 'OK' OR pg_temp.f255_states(ba) <> 'discharged_verified' THEN
        RAISE EXCEPTION 'FIXTURE 255 CORR: correcting back to a pass should verify the batch again (%, %)', v_msg, pg_temp.f255_states(ba); END IF;
    v_msg := pg_temp.f255_do(NULL, format($q$UPDATE discharge_module_results SET verdict = 'pass' WHERE id = %L$q$, v_id), u_all);
    IF v_msg IS DISTINCT FROM 'OK' THEN NULL; END IF;   -- 以 authenticated 直连:RLS 下零行(没有写策略)—— 下面以属主再试一次
    BEGIN
        UPDATE discharge_module_results SET verdict = 'pass' WHERE id = v_id;
        RAISE EXCEPTION 'FIXTURE 255 CORR: a result row was updated in place';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'APPEND_ONLY|discharge_module_results|update%' THEN RAISE; END IF;
    END;

    -- ══════════════ REV · 回滚之后结果不再算数 ══════════════
    RAISE NOTICE 'fixture 255 · REV';
    bb := pg_temp.f255_ib('ZZ255-B', m_mod, v_sup, 100, 'charged_not_discharged', d, 1);
    run_b := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(bb, 100)), '[]'::jsonb, d);
    v_msg := pg_temp.f255_res(u_cap, run_b, 'inbound', bb, 'M01', 0.4, 'pass', t10);
    IF v_msg <> 'OK' OR pg_temp.f255_states(bb) <> 'discharged_verified' THEN RAISE EXCEPTION 'FIXTURE 255 REV: setup should verify (%)', v_msg; END IF;
    PERFORM rollback_processing_run_internal(run_b, 'f255 wrong batch', u_all);
    IF pg_temp.f255_states(bb) <> 'charged_not_discharged'
       OR (SELECT modules_recorded FROM discharge_batch_status_all WHERE batch_id = bb) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 255 REV: after reversing the run its results must not count and charged must be open again (%)', pg_temp.f255_states(bb); END IF;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = bb) <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 255 REV: reversing a discharge must not move stock'; END IF;

    -- ══════════════ P1 · 只放一部分不核实整批 ══════════════
    RAISE NOTICE 'fixture 255 · P1';
    bd := pg_temp.f255_ib('ZZ255-D', m_mod, v_sup, 100, 'charged_not_discharged', d, 2);
    run_d := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(bd, 10)), '[]'::jsonb, d);
    IF pg_temp.f255_states(bd) <> 'charged_not_discharged' THEN RAISE EXCEPTION 'FIXTURE 255 P1: a 10 kg discharge marked the whole 100 kg batch'; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', bd, 'M01', 0.4, 'pass', t10);
    IF v_msg <> 'OK' OR pg_temp.f255_states(bd) <> 'charged_not_discharged' THEN
        RAISE EXCEPTION 'FIXTURE 255 P1: one module of two passed — the batch must not be verified (%)', v_msg; END IF;
    -- 模组数不许低于已有结论的模组数(清空也不行)
    v_msg := pg_temp.f255_do(u_inb, format($q$SELECT set_batch_module_count('inbound', %L, NULL)$q$, bd), u_all);
    IF v_msg NOT LIKE 'MODULE_COUNT_BELOW_RESULTS|ZZ255-D|1%' THEN RAISE EXCEPTION 'FIXTURE 255 MC: clearing a count below the results, got %', v_msg; END IF;

    -- ══════════════ P2 · 被别的单用掉一部分之后,放电照样回滚得了 ══════════════
    RAISE NOTICE 'fixture 255 · P2';
    bc := pg_temp.f255_ib('ZZ255-C', m_mod, v_sup, 100, 'charged_not_discharged', d, 1);
    run_c := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(bc, 100)), '[]'::jsonb, d);
    v_msg := pg_temp.f255_res(u_cap, run_c, 'inbound', bc, 'M01', 0.4, 'pass', t10);
    run_md := pg_temp.f255_run('manual_disassembly', jsonb_build_array(pg_temp.f255_in(bc, 50)),
                               jsonb_build_array(jsonb_build_object('material_id', m_cell, 'weight_kg', 50)), d);
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = bc) <> 50 THEN RAISE EXCEPTION 'FIXTURE 255 P2: setup — 50 kg should have been consumed'; END IF;
    BEGIN
        PERFORM rollback_processing_run_internal(run_c, 'f255 discharge recorded on the wrong batch', u_all);
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FIXTURE 255 P2: a discharge must be reversible after part of its batch was used, got %', SQLERRM;
    END;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = bc) <> 50
       OR EXISTS (SELECT 1 FROM inventory_movements WHERE run_id = run_c AND movement_type = 'reversal_restore') THEN
        RAISE EXCEPTION 'FIXTURE 255 P2: reversing a discharge must restore nothing (the discharge took nothing)'; END IF;

    -- ══════════════ P3 · 放一批自产料不扣库存 ══════════════
    RAISE NOTICE 'fixture 255 · P3';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ255-OB', m_mod, 100, 100, 'kg', d - 1, '库存中') RETURNING id INTO ob;
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (ob, 'charged_not_discharged');
    run_ob := pg_temp.f255_run('deep_discharge', jsonb_build_array(jsonb_build_object('output_batch_id', ob, 'quantity_consumed', 10)), '[]'::jsonb, d);
    IF (SELECT remaining_qty FROM output_batches WHERE id = ob) <> 100
       OR EXISTS (SELECT 1 FROM inventory_movements WHERE run_id = run_ob AND movement_type = 'processing_consume') THEN
        RAISE EXCEPTION 'FIXTURE 255 P3: discharging a self-produced batch must leave its stock unchanged'; END IF;

    -- ══════════════ RES · 字段与按名拒 ══════════════
    RAISE NOTICE 'fixture 255 · RES';
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', bd, 'M02', 0.4, 'pass', now() + interval '1 hour');
    IF v_msg NOT LIKE 'DISCHARGE_VERDICT_IN_FUTURE%' THEN RAISE EXCEPTION 'FIXTURE 255 RES: a verdict in the future, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', bd, 'M02', 0.4, 'pass', t9 - interval '1 hour');
    IF v_msg NOT LIKE 'DISCHARGE_VERDICT_BEFORE_RUN|%' THEN RAISE EXCEPTION 'FIXTURE 255 RES: a verdict before the run started, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', bd, 'M02', -1, 'pass', t10);
    IF v_msg NOT LIKE 'DISCHARGE_VOLTAGE_INVALID%' THEN RAISE EXCEPTION 'FIXTURE 255 RES: a negative voltage, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', bd, 'M02', 0.4, 'maybe', t10);
    IF v_msg NOT LIKE 'DISCHARGE_VERDICT_UNKNOWN|maybe%' THEN RAISE EXCEPTION 'FIXTURE 255 RES: an unknown verdict, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', ba, 'M02', 0.4, 'pass', t10);
    IF v_msg NOT LIKE 'DISCHARGE_BATCH_NOT_INPUT|%' THEN RAISE EXCEPTION 'FIXTURE 255 RES: a batch that is not this run''s input, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_md, 'inbound', bc, 'M01', 0.4, 'pass', t10);
    IF v_msg NOT LIKE 'DISCHARGE_RUN_NOT_BY_UNIT|%|manual_disassembly%' THEN RAISE EXCEPTION 'FIXTURE 255 RES: a run of an operation not verified by unit, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_view, run_d, 'inbound', bd, 'M02', 0.4, 'pass', t10);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN RAISE EXCEPTION 'FIXTURE 255 RES: a viewer must not record a result, got %', v_msg; END IF;

    -- ══════════════ V9 · 通过电压只标出,从不替人判 ══════════════
    RAISE NOTICE 'fixture 255 · V9';
    bf := pg_temp.f255_ib('ZZ255-F', m_mod, v_sup, 100, 'charged_not_discharged', d, 3);
    run_f := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(bf, 100)), '[]'::jsonb, d);
    v_msg := pg_temp.f255_res(u_cap, run_f, 'inbound', bf, 'M01', 1.5, 'pass', t10);
    IF (SELECT contradicts_pass_voltage FROM discharge_module_results WHERE run_id = run_f AND module_ref = 'M01') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 255 V9: with no pass voltage the contradiction cannot be judged (NULL), not false'; END IF;
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V9' AND item_id = m_cell) THEN
        RAISE EXCEPTION 'FIXTURE 255 V9: a cell material with no discharge result yet must not be listed (the page would fill with every cell material)'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V9' AND item_id = m_mod) THEN
        RAISE EXCEPTION 'FIXTURE 255 V9: the material should be listed as pending once a discharge result exists on a batch of it'; END IF;
    UPDATE materials SET discharge_pass_voltage_v = 1.0 WHERE id = m_mod;
    IF EXISTS (SELECT 1 FROM pending_values WHERE value_code = 'V9' AND item_id = m_mod) THEN
        RAISE EXCEPTION 'FIXTURE 255 V9: giving the pass voltage must clear its row'; END IF;
    IF (SELECT contradicts_pass_voltage FROM discharge_module_results WHERE run_id = run_f AND module_ref = 'M01') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 255 V9: a later pass voltage must not re-judge an old row'; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_f, 'inbound', bf, 'M02', 1.6, 'pass', t10);
    v_msg := pg_temp.f255_res(u_cap, run_f, 'inbound', bf, 'M03', 0.6, 'fail', t10, 're_discharge');
    IF (SELECT contradicts_pass_voltage FROM discharge_module_results WHERE run_id = run_f AND module_ref = 'M02') IS NOT TRUE
       OR (SELECT contradicts_pass_voltage FROM discharge_module_results WHERE run_id = run_f AND module_ref = 'M03') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 255 V9: a pass above the line and a fail at or below it should both be flagged'; END IF;
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT correct_discharge_module_result(%L, 0.6, 'pass', %L, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'operator re-read')$q$,
        (SELECT id FROM discharge_module_results WHERE run_id = run_f AND module_ref = 'M03'), t10), u_all);
    -- 判通过而高于线(M01 判不了 · M02 矛盾):照样算数 → 三个都通过 → 核实。线从不替人判。
    IF v_msg <> 'OK' OR pg_temp.f255_states(bf) <> 'discharged_verified'
       OR (SELECT contradictions FROM discharge_batch_status_all WHERE batch_id = bf) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 255 V9: a flagged pass still counts — the batch should verify, with one contradiction shown (%)', v_msg; END IF;

    -- ══════════════ CHAN · 通道分配 ══════════════
    RAISE NOTICE 'fixture 255 · CHAN';
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT assign_discharge_channel(%L, 'inbound', %L, 1, 'M02')$q$, run_d, bd), u_all);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.processing_aftercare%' THEN RAISE EXCEPTION 'FIXTURE 255 CHAN: assigning needs aftercare, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_after, format($q$SELECT assign_discharge_channel(%L, 'inbound', %L, 1, 'M02')$q$, run_d, bd), u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 255 CHAN: assigning channel 1, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_after, format($q$SELECT assign_discharge_channel(%L, 'inbound', %L, 1, 'M01')$q$, run_d, bd), u_all);
    IF v_msg NOT LIKE 'DISCHARGE_CHANNEL_TAKEN|1|M02%' THEN RAISE EXCEPTION 'FIXTURE 255 CHAN: a channel already in use, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_after, format($q$SELECT assign_discharge_channel(%L, 'inbound', %L, 2, 'M02')$q$, run_d, bd), u_all);
    IF v_msg NOT LIKE 'DISCHARGE_MODULE_ALREADY_ON_CHANNEL|M02|1%' THEN RAISE EXCEPTION 'FIXTURE 255 CHAN: a module already on a channel, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_after, format($q$SELECT assign_discharge_channel(%L, 'inbound', %L, 2, 'M01')$q$, run_d, bd), u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 255 CHAN: assigning channel 2, got %', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', bd, 'M02', 0.4, 'pass', t10, NULL, 2);
    IF v_msg NOT LIKE 'DISCHARGE_CHANNEL_MODULE_MISMATCH|2|M01%' THEN RAISE EXCEPTION 'FIXTURE 255 CHAN: a result on a channel assigned to another module, got %', v_msg; END IF;
    SELECT id INTO v_id FROM discharge_channel_assignments WHERE run_id = run_d AND channel_no = 1;
    v_msg := pg_temp.f255_do(u_after, format($q$SELECT correct_discharge_channel(%L, 3, 'M02', false, 'moved to channel 3')$q$, v_id), u_all);
    IF v_msg <> 'OK' OR (SELECT count(*) FROM discharge_channel_assignments WHERE run_id = run_d) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 255 CHAN: a correction should be a new row (%)', v_msg; END IF;
    v_msg := pg_temp.f255_res(u_cap, run_d, 'inbound', bd, 'M02', 0.4, 'pass', t10, NULL, 3);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 255 CHAN: a result on its corrected channel, got %', v_msg; END IF;
    SELECT id INTO v_id2 FROM discharge_channel_assignments WHERE run_id = run_d AND corrects_id = v_id;
    v_msg := pg_temp.f255_do(u_after, format($q$SELECT correct_discharge_channel(%L, NULL, NULL, true, 'channel freed')$q$, v_id2), u_all);
    IF v_msg <> 'OK' OR NOT EXISTS (SELECT 1 FROM discharge_channel_assignments WHERE corrects_id = v_id2 AND withdrawn) THEN
        RAISE EXCEPTION 'FIXTURE 255 CHAN: withdrawing should be a withdrawn correction row (%)', v_msg; END IF;
    BEGIN
        DELETE FROM discharge_channel_assignments WHERE id = v_id;
        RAISE EXCEPTION 'FIXTURE 255 CHAN: an assignment row was deleted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'APPEND_ONLY|discharge_channel_assignments|delete%' THEN RAISE; END IF;
    END;

    -- ══════════════ SPLIT · 拆去隔离 ══════════════
    RAISE NOTICE 'fixture 255 · SPLIT';
    bg := pg_temp.f255_ib('ZZ255-G', m_mod, v_sup, 300, 'charged_not_discharged', d, 3);
    run_g := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(bg, 300)), '[]'::jsonb, d);
    v_msg := pg_temp.f255_res(u_cap, run_g, 'inbound', bg, 'M01', 0.4, 'pass', t10);
    v_msg := pg_temp.f255_res(u_cap, run_g, 'inbound', bg, 'M02', 0.4, 'pass', t10);
    v_msg := pg_temp.f255_res(u_cap, run_g, 'inbound', bg, 'M03', 9.0, 'fail', t10, 'quarantine');
    IF v_msg <> 'OK' OR pg_temp.f255_states(bg) <> 'charged_not_discharged' THEN RAISE EXCEPTION 'FIXTURE 255 SPLIT: setup (%)', v_msg; END IF;
    v_n := (pg_temp.f255_get(u_view, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'discharge_quarantine_pending' AND subject = 'ZZ255-G'$q$, u_all))::text::bigint;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 255 SPLIT: discharge_quarantine_pending should list the batch (got %)', v_n; END IF;
    v_msg := pg_temp.f255_do(u_all, format($q$SELECT split_failed_modules_to_quarantine(%L, 'inbound', %L, ARRAY['M03'], %L, %L, %L, 'day', %L, 90)$q$,
        run_g, bg, d, t10, t1030, l_norm), u_all);
    IF v_msg NOT LIKE 'QUARANTINE_LOCATION_REQUIRED|charged_not_discharged|ZZ255-NORM%' THEN RAISE EXCEPTION 'FIXTURE 255 SPLIT: no quarantine location, got %', v_msg; END IF;
    INSERT INTO storage_locations (code, name, is_active, is_quarantine) VALUES ('ZZ255-Q', 'f255 quarantine', true, true) RETURNING id INTO l_q;
    v_msg := pg_temp.f255_do(u_all, format($q$SELECT split_failed_modules_to_quarantine(%L, 'inbound', %L, ARRAY['M01'], %L, %L, %L, 'day', %L, 90)$q$,
        run_g, bg, d, t10, t1030, l_q), u_all);
    IF v_msg NOT LIKE 'DISCHARGE_SPLIT_MODULE_NOT_QUARANTINE|M01%' THEN RAISE EXCEPTION 'FIXTURE 255 SPLIT: a passed module may not be split, got %', v_msg; END IF;
    v_msg := pg_temp.f255_do(u_cap, format($q$SELECT split_failed_modules_to_quarantine(%L, 'inbound', %L, ARRAY['M03'], %L, %L, %L, 'day', %L, 90)$q$,
        run_g, bg, d, t10, t1030, l_q), u_all);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.processing_aftercare%' THEN RAISE EXCEPTION 'FIXTURE 255 SPLIT: splitting needs aftercare, got %', v_msg; END IF;
    v_j := pg_temp.f255_get(u_all, format($q$SELECT split_failed_modules_to_quarantine(%L, 'inbound', %L, ARRAY['M03'], %L, %L, %L, 'day', %L, 90)$q$,
        run_g, bg, d, t10, t1030, l_q), u_all);
    v_split := (v_j ->> 'split_run_id')::uuid;
    v_new := (v_j ->> 'batch_id')::uuid;
    IF (SELECT remaining_qty FROM inbound_batches WHERE id = bg) <> 210 THEN
        RAISE EXCEPTION 'FIXTURE 255 SPLIT: the split mass (90) should be consumed from the parent (300 → 210)'; END IF;
    IF (SELECT material_id FROM output_batches WHERE id = v_new) <> m_mod
       OR (SELECT quantity FROM output_batches WHERE id = v_new) <> 90
       OR (SELECT module_count FROM output_batches WHERE id = v_new) IS DISTINCT FROM 1
       OR pg_temp.f255_states(v_new) <> 'charged_not_discharged' THEN
        RAISE EXCEPTION 'FIXTURE 255 SPLIT: the new batch should be the same material, 90 kg, one module, charged and not discharged'; END IF;
    IF (SELECT COALESCE(sum(qty_delta), 0) FROM inventory_movements WHERE output_batch_id = v_new AND location_id = l_q) <> 90
       OR (SELECT COALESCE(sum(qty_delta), 0) FROM inventory_movements WHERE output_batch_id = v_new AND location_id IS NULL) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 255 SPLIT: the whole new batch should sit in the quarantine location'; END IF;
    IF pg_temp.f255_states(bg) <> 'discharged_verified'
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = bg AND safety_state_code = 'discharged_verified'
                        AND ended_at IS NULL AND created_by_run_id = v_split) THEN
        RAISE EXCEPTION 'FIXTURE 255 SPLIT: two passed + one split out of three — the parent should verify, owned by the split run (%)', pg_temp.f255_states(bg); END IF;
    v_n := (pg_temp.f255_get(u_view, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'discharge_quarantine_pending' AND subject = 'ZZ255-G'$q$, u_all))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 255 SPLIT: discharge_quarantine_pending should clear after the split'; END IF;
    run_x := pg_temp.f255_run('deep_discharge', jsonb_build_array(pg_temp.f255_in(bg, 210)), '[]'::jsonb, d);   -- 一炉新的放电:只有"已拆走"拦得住
    v_msg := pg_temp.f255_res(u_cap, run_x, 'inbound', bg, 'M03', 0.4, 'pass', t1030);
    IF v_msg NOT LIKE 'DISCHARGE_MODULE_SPLIT_OUT|M03|%' THEN RAISE EXCEPTION 'FIXTURE 255 SPLIT: a split-out module may not get a result on the parent, got %', v_msg; END IF;
    PERFORM rollback_processing_run_internal(v_split, 'f255 split by mistake', u_all);
    IF pg_temp.f255_states(bg) <> 'charged_not_discharged'
       OR (SELECT failed_quarantine FROM discharge_batch_status_all WHERE batch_id = bg) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 255 SPLIT: reversing the split should un-verify the parent and put M03 back to awaiting the split (%)', pg_temp.f255_states(bg); END IF;

    -- ══════════════ ING · 设备转换器没有建 ══════════════
    RAISE NOTICE 'fixture 255 · ING';
    IF (SELECT transform_function FROM ingest_data_classes WHERE code = 'discharge_module') IS NOT NULL
       OR (SELECT creates_draft FROM ingest_data_classes WHERE code = 'discharge_module') THEN
        RAISE EXCEPTION 'FIXTURE 255 ING: no discharge_module transform was built (no device has supplied a format) — device rows must wait as awaiting_transform'; END IF;

    RAISE NOTICE 'FIXTURE 255 全部通过:MC · COMMIT · VER · CORR · REV · P1 · P2 · P3 · RES · V9 · CHAN · SPLIT · ING';
END
$$;

ROLLBACK;

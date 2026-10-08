-- 257 MES-5b-1:一批料的每一公斤都去了某个地方,而树上每一层都精确加得起来;月度平衡、库存滚动、得率与"动作码蕴含查看码"
--     (MES-5b Step 0 Q3–Q15 · Q30–Q35,Tim;v1.4.45)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-08-mes5b1-fixture-injections.py)必须让它红在它点名的那一臂。
--   CONS   什么算消耗(Q3):消耗那一炉算(flow = consumption);深度放电是穿过去(pass_through),不是消耗;拆去隔离是一次搬运(transfer),
--          没有损耗行、没有余数行,子批接着带走同一份;回滚的单是 reversed;没有工序的老单仍按转化型算
--   ATTR   归属(Q4):一炉两进(A 200 · B 100)两出(170 · 80)加一类有名字的损耗,按投入质量分给每一条腿;一个产出喂进下一炉,带着它分到的
--          那一份;份额是精确的一对数,每一层的孩子之和【精确】等于父亲(有理数比较,不比四舍五入后的数);同一炉在两个源头上的份额加起来正好是它自己
--   BAL    一个批次的平衡(Q5):收进来的 = 在手 + 卖出 + 注销 + 调整 + 回滚作废 + 消耗 + 拆去隔离(+ 单位不是 kg 的消耗),未解释 = 0 ——
--          进料批(带放电事件、拆分、一张回滚的单与更正它的那一张)与产出批两边都钉
--   PRE    MES-4a 之前的单(Q6):照样进质量合计,余数状态 before_closure,era_mes4a = false;回滚的单不进任何合计、另列,更正它的那一炉连回去(Q7)
--   MONTH  月度平衡(Q8):每一个(月 × 范围 × 工序)投入 = Σ 产出 + Σ 有名字的损耗 + Σ 余数;全厂 = 各工序之和;穿过去的(放电 · 拆分)
--          与回滚的另列;余数按状态分(closed_within · closed_explained · open · before_closure)
--   ROLL   库存滚动(Q8):每个月 期末 = 期初 + 本月各行之和,各行等于流水直接按类型加起来的数;没有"对得上"的旗标
--   NOTKG  单位不是 kg(Q10):那一炉不进任何合计,另列;批次上记作 consumed_not_kg、树上是一个 not_kg 事件
--   INV    /inventory 的平衡合计(Q12):读月度平衡全期之和,与旧算法(每一张没删的单的表头之和)正好差放电 + 拆分 + 单位不是 kg 的投入
--   YIELD  得率(Q13):每一炉每一种形态 ÷ 总投入;除尘粉尘是产出;扫地料是可回收的损耗;放电 / 拆分 / 回滚 / 单位不是 kg 的单没有得率;
--          老单在、标着;按工序 × 月的合计分母是那一格全部消耗炉次的投入
--   GROUP  分组(Q14):化学体系(含"没记")与供应商按份额分到源头批次,各组之和 = 全部;机器;供应商的名字只给持 module.inbound.view 的人,
--          不持的人读到"受限"(group_label 空、group_label_restricted 真),不是"没有"
--   V37    预期得率(Q15):低于它标出来、高于它不标、没给为空;它从不拒(给了之后照样提交);待补的值 V37 只在那道工序有了 MES-4a 之后的
--          消耗炉次之后才列,给了那一格就消失
--   READ   读者的门:月度平衡与滚动(加工 / 财务 / 库存查看任一)、批次树(加工查看,或根批次自己的查看码)、得率(加工查看);什么码都没有读到 0 行
--   FCHECK 动作码蕴含查看码(Q30 · Q31):set_role_permissions 拒一个持动作码而不持它那一页任何一个查看码的角色(ACTION_REQUIRES_VIEW,
--          点出码与它要的查看码),持其中【任一】就放行,页面由码自己把门的持码即可;目录的声明合法、除了没有屏幕的那一个都声明了;
--          重建库里【每一个】角色都满足;引导的 admin 持目录里除 module.tasks.view_all 之外的每一个码;引导的财务持 module.processing.view
--   LOG    没有新表 —— 变更记录覆盖零缺口、豁免仍是 8;V37 的改动进变更记录
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);读者那几臂真的切成 authenticated + 那个人的 JWT。日期 = 昨天,一炉从 09:00 跑到 11:00。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f257_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某个人跑一句:成功回 'OK',失败回原文;身份回到 p_back
CREATE FUNCTION pg_temp.f257_do(p_user uuid, p_sql text, p_back uuid) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f257_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f257_as(p_back);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f257_as(p_back);
    RETURN SQLERRM;
END;
$f$;

-- 以某个人读一个值(读的失败照样抛)
CREATE FUNCTION pg_temp.f257_get(p_user uuid, p_sql text, p_back uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f257_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f257_as(p_back);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f257_as(p_back);
    RAISE;
END;
$f$;

-- 一批进料(直写,以 postgres 跑):定价、化学确定、一个安全状态、可选模组数与单位
CREATE FUNCTION pg_temp.f257_ib(p_code text, p_mat uuid, p_sup uuid, p_qty numeric, p_state text, p_d date,
                                p_count integer DEFAULT NULL, p_unit text DEFAULT 'kg') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid; v_ccy text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 module_count)
    VALUES (p_code, p_mat, p_sup, p_qty, p_qty, p_unit, p_d - 1, 'other', 'fixture 257 自带数据', p_count) RETURNING id INTO v;
    PERFORM reprice_inbound_batch(v, 1, v_ccy, NULL, 'f257');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v;
    IF p_state IS NOT NULL THEN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v, p_state);
    END IF;
    RETURN v;
END;
$f$;

-- 提交一炉(以当前 JWT、authenticated);返回 run id,失败抛原文
CREATE FUNCTION pg_temp.f257_run(p_op text, p_inputs jsonb, p_outputs jsonb, p_d date, p_eq uuid DEFAULT NULL, p_corrects uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    v := commit_processing_run(p_d, 'f257', NULL, p_inputs, p_outputs, 'weight', NULL, p_eq, p_op,
                               p_started_at => p_d::timestamptz + interval '9 hours', p_ended_at => p_d::timestamptz + interval '11 hours',
                               p_shift_code => 'day', p_corrects_run_id => p_corrects);
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f257_in(p_kind text, p_b uuid, p_q numeric) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT jsonb_build_object(CASE p_kind WHEN 'inbound' THEN 'inbound_batch_id' ELSE 'output_batch_id' END, p_b, 'quantity_consumed', p_q) $f$;
CREATE FUNCTION pg_temp.f257_out(p_mat uuid, p_kg numeric) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT jsonb_build_object('material_id', p_mat, 'weight_kg', p_kg) $f$;
-- 一炉里某种物料的那一条产出批
CREATE FUNCTION pg_temp.f257_ob(p_run uuid, p_mat uuid) RETURNS uuid
LANGUAGE sql AS $f$ SELECT po.output_batch_id FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
                    WHERE po.run_id = p_run AND ob.material_id = p_mat $f$;

-- 【每一层精确加得起来】一棵树(或全部)里违反恒等式的结点,逐个点名;空 = 全对。有理数比较:同一层的孩子共用一对份额,
--   Σ 孩子.x × 孩子.num × 父.den = 父.x × 父.num × 孩子.den。批次结点:Σ 去向 = 收进来的、未解释 = 0、消耗 = Σ 消耗炉、拆分 = Σ 拆分炉。
CREATE FUNCTION pg_temp.f257_tree_bad(p_root uuid) RETURNS text
LANGUAGE sql AS $f$
    WITH t AS (SELECT * FROM batch_balance_tree_all WHERE p_root IS NULL OR root_id = p_root),
    runs AS (
        SELECT p.root_id, p.node_key, p.x, p.share_num, p.share_den,
               (SELECT count(DISTINCT (c.share_num, c.share_den)) FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key) AS shares,
               (SELECT sum(c.x) FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key) AS sx,
               (SELECT min(c.share_num) FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key) AS cn,
               (SELECT min(c.share_den) FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key) AS cd
          FROM t p WHERE p.node_type = 'run'),
    bats AS (
        SELECT p.root_id, p.node_key, p.x,
               (SELECT sum(c.x) FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key AND c.node_type = 'fate' AND c.line_key <> 'unexplained') AS fates,
               (SELECT c.x FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key AND c.line_key = 'unexplained') AS unexpl,
               (SELECT c.x FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key AND c.node_type = 'fate' AND c.line_key = 'consumed') AS consumed,
               (SELECT COALESCE(sum(c.x), 0) FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key AND c.node_type = 'run' AND c.line_key = 'consumption') AS cons_runs,
               (SELECT c.x FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key AND c.node_type = 'fate' AND c.line_key = 'split') AS split,
               (SELECT COALESCE(sum(c.x), 0) FROM t c WHERE c.root_id = p.root_id AND c.parent_key = p.node_key AND c.node_type = 'run' AND c.line_key = 'transfer') AS split_runs
          FROM t p WHERE p.node_type IN ('batch', 'run_output'))
    SELECT string_agg(k, '; ') FROM (
        SELECT 'run ' || node_key || ' shares=' || shares || ' Σx=' || sx || ' x=' || x AS k FROM runs
         WHERE sx IS NOT NULL AND (shares <> 1 OR sx * cn * share_den <> x * share_num * cd)
        UNION ALL
        SELECT 'batch ' || node_key || ' x=' || x || ' Σfates=' || fates || ' unexplained=' || unexpl || ' consumed=' || consumed || '/' || cons_runs
               || ' split=' || split || '/' || split_runs FROM bats
         WHERE fates <> x OR unexpl <> 0 OR consumed <> cons_runs OR split <> split_runs) z
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码
    u_view uuid := gen_random_uuid();   -- 只看加工
    u_vinb uuid := gen_random_uuid();   -- 看加工 + 看进料
    u_inb  uuid := gen_random_uuid();   -- 只看进料
    u_fin  uuid := gen_random_uuid();   -- 只看财务
    u_none uuid := gen_random_uuid();   -- 什么码都没有
    r uuid; r_x uuid;
    d   date := CURRENT_DATE - 1;
    mon date;
    t10 timestamptz; t1030 timestamptz;
    s1 uuid; s2 uuid; eq uuid; lq uuid;
    m_pack1 uuid; m_pack2 uuid; m_bm uuid; m_dust uuid; m_mod uuid; m_cell uuid;
    ba uuid; bb uuid; bc uuid; be uuid; bn uuid; o1 uuid; o2 uuid; o3 uuid; q uuid;
    r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid; r6 uuid; r7 uuid; rd uuid; rs uuid;
    v_msg text; v_n bigint; v_num numeric; v_num2 numeric; v_j jsonb; v_txt text; v_bad text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    mon := date_trunc('month', d)::date;
    t10 := d::timestamptz + interval '10 hours';
    t1030 := d::timestamptz + interval '10 hours 30 minutes';

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx257-all@test.local', now(), now()), (u_view, 'fx257-view@test.local', now(), now()),
        (u_vinb, 'fx257-vinb@test.local', now(), now()), (u_inb, 'fx257-inb@test.local', now(), now()),
        (u_fin, 'fx257-fin@test.local', now(), now()), (u_none, 'fx257-none@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx257-all', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx257-view', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_view, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx257-vinb', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view'), (r, 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_vinb, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx257-inb', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_inb, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx257-fin', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r);
    PERFORM pg_temp.f257_as(u_all);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ257-S1', 'f257 supplier one', 'SG', 'active', 'goods_supplier') RETURNING id INTO s1;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ257-S2', 'f257 supplier two', 'SG', 'active', 'goods_supplier') RETURNING id INTO s2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code, chemistry) VALUES
        ('ZZ257-P1', 'f257 packs NMC', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction', 'NMC') RETURNING id INTO m_pack1;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ257-P2', 'f257 packs, chemistry not recorded', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO m_pack2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ257-BM', 'f257 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ257-DUST', 'f257 collected dust', 'battery_material', true, 'collected_dust', 'end_of_life') RETURNING id INTO m_dust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ257-MOD', 'f257 modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ257-CELL', 'f257 cells', 'battery_material', true, 'loose_cells', 'end_of_life', 'ev_traction') RETURNING id INTO m_cell;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base)
    VALUES ('ZZ257-EQ', 'f257 powder line', 'equipment', d - 200, 0, (SELECT code FROM currencies WHERE is_base), 0, 1, 'active', 100, 0) RETURNING id INTO eq;
    INSERT INTO storage_locations (code, name, is_active, is_quarantine) VALUES ('ZZ257-Q', 'f257 quarantine', true, true) RETURNING id INTO lq;

    ba := pg_temp.f257_ib('ZZ257-A', m_pack1, s1, 200, 'discharged_verified', d);
    bb := pg_temp.f257_ib('ZZ257-B', m_pack2, s2, 100, 'discharged_verified', d);

    -- ══════════════ V37 · 第一炉之前:那道工序没有 MES-4a 之后的消耗炉次,一行都不列 ══════════════
    RAISE NOTICE 'fixture 257 · V37 (before)';
    v_n := (pg_temp.f257_get(u_view, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V37' AND item_code LIKE 'battery_powder_line/%'$q$, u_all))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 257 V37: before any MES-4a-era run of the operation V37 must list nothing (got %)', v_n; END IF;

    -- ══════════════ 一炉两进两出 + 一个产出喂进下一炉 ══════════════
    r1 := pg_temp.f257_run('battery_powder_line',
                           jsonb_build_array(pg_temp.f257_in('inbound', ba, 200), pg_temp.f257_in('inbound', bb, 100)),
                           jsonb_build_array(pg_temp.f257_out(m_bm, 170), pg_temp.f257_out(m_dust, 80)), d, eq);
    PERFORM record_run_loss(r1, 'sweepings', 20);
    o1 := pg_temp.f257_ob(r1, m_bm);
    o2 := pg_temp.f257_ob(r1, m_dust);

    RAISE NOTICE 'fixture 257 · V37 (after the first run)';
    v_n := (pg_temp.f257_get(u_view, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V37' AND item_code LIKE 'battery_powder_line/%'$q$, u_all))::text::bigint;
    IF v_n <> (SELECT count(*) FROM operation_type_output_forms WHERE operation_type_code = 'battery_powder_line') THEN
        RAISE EXCEPTION 'FIXTURE 257 V37: once the operation has an MES-4a-era consuming run, every output form of it with no expected yield is listed (got %)', v_n; END IF;
    v_n := (pg_temp.f257_get(u_view, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V37' AND item_code LIKE 'electrode_powder_line/%'$q$, u_all))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 257 V37: an operation with no run must not be listed (got %)', v_n; END IF;
    -- 给了 black_mass 的预期得率(70 %),之后照样提交 —— 它从不拒
    v_msg := pg_temp.f257_do(u_all, $q$UPDATE operation_type_output_forms SET expected_yield_pct = 70 WHERE operation_type_code = 'battery_powder_line' AND form_code = 'black_mass'$q$, u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 257 V37: module.processing.edit should set the expected yield, got %', v_msg; END IF;
    v_msg := pg_temp.f257_do(u_view, $q$UPDATE operation_type_output_forms SET expected_yield_pct = 10 WHERE operation_type_code = 'battery_powder_line' AND form_code = 'black_mass'$q$, u_all);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.processing.edit%' THEN RAISE EXCEPTION 'FIXTURE 257 V37: a viewer must not set it, got %', v_msg; END IF;
    v_n := (pg_temp.f257_get(u_view, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V37' AND item_code = 'battery_powder_line/black_mass'$q$, u_all))::text::bigint;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 257 V37: a set expected yield must leave the pending list'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'operation_type_output_forms' AND op = 'UPDATE' AND 'expected_yield_pct' = ANY (changed_columns)) THEN
        RAISE EXCEPTION 'FIXTURE 257 LOG: the V37 change must be in the change log'; END IF;

    -- O1 的 170 里 100 喂进下一炉(带它分到的那一份往下走),70 留在手上
    INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (o1, 'discharged_verified');
    r2 := pg_temp.f257_run('battery_powder_line', jsonb_build_array(pg_temp.f257_in('output', o1, 100)),
                           jsonb_build_array(pg_temp.f257_out(m_bm, 90)), d);
    PERFORM record_run_loss(r2, 'moisture', 4);
    o3 := pg_temp.f257_ob(r2, m_bm);

    -- ══════════════ 放电 · 拆去隔离 · 一张回滚的单与更正它的那一张(都在 C 上)══════════════
    bc := pg_temp.f257_ib('ZZ257-C', m_mod, s1, 400, 'charged_not_discharged', d, 3);
    rd := pg_temp.f257_run('deep_discharge', jsonb_build_array(pg_temp.f257_in('inbound', bc, 400)), '[]'::jsonb, d);
    PERFORM record_discharge_module_result(rd, 'inbound', bc, 'M01', 0.4, 'pass', t10);
    PERFORM record_discharge_module_result(rd, 'inbound', bc, 'M02', 0.4, 'pass', t10);
    PERFORM record_discharge_module_result(rd, 'inbound', bc, 'M03', 9.0, 'fail', t10, 'quarantine');
    v_j := split_failed_modules_to_quarantine(rd, 'inbound', bc, ARRAY['M03'], d, t10, t1030, 'day', lq, 90);
    rs := (v_j ->> 'split_run_id')::uuid;
    q := (v_j ->> 'batch_id')::uuid;
    r4 := pg_temp.f257_run('manual_disassembly', jsonb_build_array(pg_temp.f257_in('inbound', bc, 50)), jsonb_build_array(pg_temp.f257_out(m_cell, 50)), d);
    PERFORM rollback_processing_run_internal(r4, 'f257 recorded by mistake', u_all);
    r5 := pg_temp.f257_run('manual_disassembly', jsonb_build_array(pg_temp.f257_in('inbound', bc, 60)), jsonb_build_array(pg_temp.f257_out(m_cell, 55)), d, NULL, r4);
    r3 := pg_temp.f257_run('manual_disassembly', jsonb_build_array(pg_temp.f257_in('inbound', bc, 200)), jsonb_build_array(pg_temp.f257_out(m_cell, 190)), d);
    PERFORM record_run_loss(r3, 'equipment_holdup', 4);

    -- MES-4a 之前的单:照常提交,再以属主身份把开始 / 结束 / 班次抹掉(那正是 MES-4a 之前的单的样子;fixture 178 / 253 的先例)
    be := pg_temp.f257_ib('ZZ257-E', m_pack2, s2, 50, 'discharged_verified', d);
    r6 := pg_temp.f257_run('battery_powder_line', jsonb_build_array(pg_temp.f257_in('inbound', be, 50)), jsonb_build_array(pg_temp.f257_out(m_bm, 40)), d);
    ALTER TABLE processing_runs DISABLE TRIGGER USER;
    UPDATE processing_runs SET started_at = NULL, ended_at = NULL, shift_code = NULL WHERE id = r6;
    ALTER TABLE processing_runs ENABLE TRIGGER USER;

    -- 单位不是 kg 的一炉(投料腿在提交时不判单位 —— Q10 登记,不在本刀建)
    bn := pg_temp.f257_ib('ZZ257-N', m_pack2, s2, 10, 'discharged_verified', d, NULL, 'pcs');
    r7 := pg_temp.f257_run('battery_powder_line', jsonb_build_array(pg_temp.f257_in('inbound', bn, 10)), jsonb_build_array(pg_temp.f257_out(m_bm, 8)), d);

    -- 结平:R1 容差没给 → 要说明(closed_explained);R3 给 5 %,余数 6 / 200 = 3 % 在容差里(closed_within)
    PERFORM close_run_balance(r1, 'f257: 30 kg unaccounted for on the first test run');
    UPDATE operation_types SET balance_tolerance_pct = 5 WHERE code = 'manual_disassembly';
    PERFORM close_run_balance(r3, NULL);

    -- ══════════════ CONS · 什么算消耗 ══════════════
    RAISE NOTICE 'fixture 257 · CONS';
    SELECT string_agg(run_code || '=' || flow, ',' ORDER BY run_code) INTO v_txt FROM processing_run_flow_all WHERE run_id IN (r1, r2, r3, r4, r5, r6, r7, rd, rs);
    IF (SELECT flow FROM processing_run_flow_all WHERE run_id = r1) <> 'consumption'
       OR (SELECT flow FROM processing_run_flow_all WHERE run_id = rd) <> 'pass_through'
       OR (SELECT flow FROM processing_run_flow_all WHERE run_id = rs) <> 'transfer'
       OR (SELECT flow FROM processing_run_flow_all WHERE run_id = r4) <> 'reversed'
       OR (SELECT flow FROM processing_run_flow_all WHERE run_id = r6) <> 'consumption'
       OR NOT (SELECT not_kg FROM processing_run_flow_all WHERE run_id = r7)
       OR (SELECT not_kg FROM processing_run_flow_all WHERE run_id = r1) THEN
        RAISE EXCEPTION 'FIXTURE 257 CONS: flows %', v_txt; END IF;
    -- 拆分那一炉在树上:一次搬运 —— 一条产出(子批 Q,90)、没有损耗行、没有余数行;子批带着同一份(90 / 90)往下
    IF NOT EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bc AND node_type = 'run' AND run_id = rs AND line_key = 'transfer' AND x = 90)
       OR EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bc AND run_id = rs AND node_type IN ('run_loss', 'run_remainder'))
       OR NOT EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bc AND node_type = 'run_output' AND batch_id = q AND x = 90
                        AND share_num * 1 = share_den * 1) THEN
        RAISE EXCEPTION 'FIXTURE 257 CONS: the quarantine split must read as a transfer to its child (no loss, no remainder, the child carries the share)'; END IF;
    -- 放电在批次上是一个事件(穿过去的 400),不是消耗
    IF NOT EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bc AND node_type = 'event' AND line_key = 'pass_through' AND run_id = rd AND x = 400) THEN
        RAISE EXCEPTION 'FIXTURE 257 CONS: deep discharge should be an event line (pass-through 400) on the batch'; END IF;

    -- ══════════════ ATTR · 按投入质量成比例,逐层精确 ══════════════
    RAISE NOTICE 'fixture 257 · ATTR';
    -- A 在 R1 里的那一份:200 / 300;四个孩子(170 · 80 · 扫地料 20 · 余数 30)共用那一对份额
    IF (SELECT count(*) FROM batch_balance_tree_all WHERE root_id = ba AND depth = 2 AND share_num = 200 AND share_den = 300) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 257 ATTR: A''s share of R1 should be 200/300 on each of its four children'; END IF;
    -- O1 喂进 R2 的 100:A 那一份 = 200·100 / 300·100;R2 的孩子(90 · 水分 4 · 余数 6)
    IF (SELECT count(*) FROM batch_balance_tree_all WHERE root_id = ba AND run_id = r2 AND node_type IN ('run_output', 'run_loss', 'run_remainder')
          AND share_num = 200 * 100 AND share_den = 300 * 100) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 257 ATTR: an output fed onward must carry its share into the next run (200·100 / 300·100)'; END IF;
    -- 每一层精确加得起来(这几棵树,也包括重建库里的每一棵)
    v_bad := pg_temp.f257_tree_bad(NULL);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 257 ATTR: a level does not add up exactly: %', v_bad; END IF;
    -- 同一炉在两个源头上的份额加起来正好是它自己(R1:200/1 + 100/1 = 300;R2:100·200/300 + 100·100/300 = 100)
    SELECT sum(x * share_num / share_den) INTO v_num FROM batch_balance_tree_all WHERE node_type = 'run' AND run_id = r1 AND root_id IN (ba, bb);
    IF v_num <> 300 THEN RAISE EXCEPTION 'FIXTURE 257 ATTR: R1 attributed to A and B should total 300, got %', v_num; END IF;
    IF (SELECT sum(x * share_num) FROM batch_balance_tree_all WHERE node_type = 'run' AND run_id = r2 AND root_id IN (ba, bb)) <> 100 * 300 THEN
        RAISE EXCEPTION 'FIXTURE 257 ATTR: R2 attributed to A and B should total exactly 100 (100·200 + 100·100 over 300)'; END IF;
    SELECT sum(share) INTO v_num FROM processing_run_origin_share_all WHERE run_id = r2;
    IF abs(v_num - 1) > 0.000000000001 THEN RAISE EXCEPTION 'FIXTURE 257 ATTR: R2''s origin shares should add up to 1, got %', v_num; END IF;

    -- ══════════════ BAL · 一个批次的平衡 ══════════════
    RAISE NOTICE 'fixture 257 · BAL';
    -- C:收 400 = 在手 50 + 消耗 260(R5 60 + R3 200)+ 拆去隔离 90;放电 400 与回滚的 R4(50)是事件;R5 连回它更正的 R4
    SELECT jsonb_object_agg(line_key, x) INTO v_j FROM batch_balance_tree_all WHERE root_id = bc AND node_type = 'fate' AND parent_key = 'r';
    IF (v_j ->> 'on_hand')::numeric <> 50 OR (v_j ->> 'consumed')::numeric <> 260 OR (v_j ->> 'split')::numeric <> 90 OR (v_j ->> 'unexplained')::numeric <> 0
       OR (SELECT x FROM batch_balance_tree_all WHERE root_id = bc AND node_type = 'batch') <> 400 THEN
        RAISE EXCEPTION 'FIXTURE 257 BAL: inbound C should read 400 = 50 on hand + 260 consumed + 90 split, got %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bc AND node_type = 'event' AND line_key = 'reversed' AND run_id = r4 AND x = 50
                     AND reversed_at IS NOT NULL AND corrected_by_run_code = (SELECT code FROM processing_runs WHERE id = r5))
       OR NOT EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bc AND node_type = 'run' AND run_id = r5
                        AND corrects_run_code = (SELECT code FROM processing_runs WHERE id = r4)) THEN
        RAISE EXCEPTION 'FIXTURE 257 BAL: the reversed run should be listed apart (50 kg, when) and linked to the run that corrected it'; END IF;
    -- 产出批 O1 作根:收 170 = 消耗 100 + 在手 70;子批 Q 作根:收 90 = 在手 90
    SELECT jsonb_object_agg(line_key, x) INTO v_j FROM batch_balance_tree_all WHERE root_id = o1 AND node_type = 'fate' AND parent_key = 'r';
    IF (v_j ->> 'on_hand')::numeric <> 70 OR (v_j ->> 'consumed')::numeric <> 100 OR (v_j ->> 'unexplained')::numeric <> 0
       OR (SELECT x FROM batch_balance_tree_all WHERE root_id = o1 AND node_type = 'batch') <> 170 THEN
        RAISE EXCEPTION 'FIXTURE 257 BAL: output O1 should read 170 = 100 consumed + 70 on hand, got %', v_j; END IF;
    IF (SELECT x FROM batch_balance_tree_all WHERE root_id = q AND node_type = 'fate' AND parent_key = 'r' AND line_key = 'on_hand') <> 90
       OR (SELECT x FROM batch_balance_tree_all WHERE root_id = q AND node_type = 'batch') <> 90 THEN
        RAISE EXCEPTION 'FIXTURE 257 BAL: the split''s child should read 90 received, 90 on hand'; END IF;
    -- 回滚作废那一行:R4 的产出批收 50、回滚作废 50
    IF (SELECT x FROM batch_balance_tree_all WHERE root_id = pg_temp.f257_ob(r4, m_cell) AND node_type = 'fate' AND parent_key = 'r' AND line_key = 'voided') <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 257 BAL: the reversed run''s output batch should read 50 voided by the reversal'; END IF;

    -- ══════════════ PRE · MES-4a 之前的单 ══════════════
    RAISE NOTICE 'fixture 257 · PRE';
    IF (SELECT remainder_state FROM processing_run_flow_all WHERE run_id = r6) <> 'before_closure'
       OR (SELECT era_mes4a FROM processing_run_flow_all WHERE run_id = r6)
       OR (SELECT remainder_qty FROM processing_run_flow_all WHERE run_id = r6) <> 10
       OR NOT EXISTS (SELECT 1 FROM processing_run_yield_all WHERE run_id = r6 AND NOT era_mes4a) THEN
        RAISE EXCEPTION 'FIXTURE 257 PRE: a pre-MES-4a run is in the mass (remainder 10 before closure) and in yield, labelled'; END IF;
    IF EXISTS (SELECT 1 FROM processing_run_yield_all WHERE run_id IN (r4, rd, rs, r7)) THEN
        RAISE EXCEPTION 'FIXTURE 257 YIELD: reversed, pass-through, split and non-kg runs have no yield'; END IF;

    -- ══════════════ INV · /inventory 的平衡合计 ══════════════
    RAISE NOTICE 'fixture 257 · INV';
    SELECT sum(qty) INTO v_num FROM processing_balance_monthly_all WHERE scope = 'plant' AND line = 'input';
    SELECT sum(total_input) INTO v_num2 FROM processing_runs WHERE deleted_at IS NULL;
    IF v_num <> 710 OR v_num2 - v_num <> 400 + 90 + 10 THEN
        RAISE EXCEPTION 'FIXTURE 257 INV: lifetime input should be 710 and differ from the old sum (%) by discharge 400 + split 90 + non-kg 10 exactly, got %', v_num2, v_num; END IF;

    -- ══════════════ MONTH · 月度平衡 ══════════════
    RAISE NOTICE 'fixture 257 · MONTH';
    -- 每一个(月 × 范围 × 工序):投入 = Σ 产出 + Σ 损耗 + Σ 余数
    SELECT string_agg(scope || '/' || COALESCE(operation_type_code, '-') || ' ' || month, ', ') INTO v_bad FROM (
        SELECT month, scope, operation_type_code,
               COALESCE(sum(qty) FILTER (WHERE line = 'input'), 0) AS i,
               COALESCE(sum(qty) FILTER (WHERE line IN ('output', 'loss', 'remainder')), 0) AS o
          FROM processing_balance_monthly_all GROUP BY month, scope, operation_type_code) z WHERE i <> o;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 257 MONTH: input <> outputs + losses + remainder in %', v_bad; END IF;
    -- 全厂 = 各工序之和(每一条线)
    SELECT string_agg(line || '/' || COALESCE(line_key, '-'), ', ') INTO v_bad FROM (
        SELECT line, line_key, basis, sum(qty) FILTER (WHERE scope = 'plant') AS p, sum(qty) FILTER (WHERE scope = 'operation') AS o
          FROM processing_balance_monthly_all WHERE month = mon GROUP BY line, line_key, basis) z WHERE p IS DISTINCT FROM o;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 257 MONTH: plant-wide is not the sum of the operations for %', v_bad; END IF;
    SELECT jsonb_object_agg(line || COALESCE(':' || line_key, '') || COALESCE(':' || basis, ''), qty) INTO v_j
      FROM processing_balance_monthly_all WHERE month = mon AND scope = 'plant';
    IF (v_j ->> 'input')::numeric <> 710                                  -- R1 300 + R2 100 + R3 200 + R5 60 + R6 50
       OR (v_j ->> 'output:black_mass')::numeric <> 300 OR (v_j ->> 'output:collected_dust')::numeric <> 80 OR (v_j ->> 'output:loose_cells')::numeric <> 245
       OR (v_j ->> 'loss:sweepings:measured')::numeric <> 20 OR (v_j ->> 'loss:moisture:measured')::numeric <> 4 OR (v_j ->> 'loss:equipment_holdup:measured')::numeric <> 4
       OR (v_j ->> 'remainder:closed_explained')::numeric <> 30 OR (v_j ->> 'remainder:closed_within')::numeric <> 6
       OR (v_j ->> 'remainder:open')::numeric <> 11 OR (v_j ->> 'remainder:before_closure')::numeric <> 10
       OR (v_j ->> 'pass_through:discharge')::numeric <> 400 OR (v_j ->> 'pass_through:split')::numeric <> 90
       OR (v_j ->> 'reversed')::numeric <> 50 THEN
        RAISE EXCEPTION 'FIXTURE 257 MONTH: plant lines %', v_j; END IF;
    IF (SELECT runs FROM processing_balance_monthly_all WHERE month = mon AND scope = 'plant' AND line = 'not_kg') <> 1
       OR (SELECT qty FROM processing_balance_monthly_all WHERE month = mon AND scope = 'plant' AND line = 'not_kg') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 257 NOTKG: the non-kg run should be listed (1 run, no quantity) and not summed'; END IF;

    -- ══════════════ NOTKG · 批次与树 ══════════════
    RAISE NOTICE 'fixture 257 · NOTKG';
    IF (SELECT x FROM batch_balance_tree_all WHERE root_id = bn AND node_type = 'fate' AND parent_key = 'r' AND line_key = 'consumed_not_kg') <> 10
       OR NOT EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bn AND node_type = 'event' AND line_key = 'not_kg' AND run_id = r7)
       OR EXISTS (SELECT 1 FROM batch_balance_tree_all WHERE root_id = bn AND node_type = 'run') THEN
        RAISE EXCEPTION 'FIXTURE 257 NOTKG: a non-kg leg is listed (consumed_not_kg, a not_kg event) and not expanded'; END IF;

    -- ══════════════ ROLL · 库存滚动 ══════════════
    RAISE NOTICE 'fixture 257 · ROLL';
    SELECT string_agg(unit || ' ' || month, ', ') INTO v_bad FROM stock_rollforward_monthly_all
     WHERE month IS NOT NULL AND closing <> opening + received + produced + consumed + sold + written_off + adjusted + voided + moved;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 257 ROLL: closing <> opening + the month''s lines in %', v_bad; END IF;
    SELECT jsonb_build_object('received', received, 'produced', produced, 'consumed', consumed, 'voided', voided, 'moved', moved) INTO v_j
      FROM stock_rollforward_monthly_all WHERE month = mon AND unit = 'kg';
    IF (v_j ->> 'received')::numeric <> (SELECT sum(m.qty_delta) FROM inventory_movements m LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
                                          WHERE m.movement_type = 'receipt' AND date_trunc('month', m.business_date) = mon AND COALESCE(ib.unit, ob.unit) = 'kg')
       OR (v_j ->> 'produced')::numeric <> (SELECT sum(m.qty_delta) FROM inventory_movements m LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
                                          WHERE m.movement_type = 'processing_produce' AND date_trunc('month', m.business_date) = mon AND ob.unit = 'kg')
       OR (v_j ->> 'consumed')::numeric <> (SELECT sum(m.qty_delta) FROM inventory_movements m LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
                                          WHERE m.movement_type IN ('processing_consume', 'reversal_restore') AND date_trunc('month', m.business_date) = mon AND COALESCE(ib.unit, ob.unit) = 'kg')
       OR (v_j ->> 'voided')::numeric <> -50 OR (v_j ->> 'moved')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 257 ROLL: the month''s lines should equal the movements summed by type, got %', v_j; END IF;
    IF (SELECT closing FROM stock_rollforward_monthly_all WHERE unit = 'kg' AND month = (SELECT max(month) FROM stock_rollforward_monthly_all WHERE unit = 'kg'))
       <> (SELECT sum(m.qty_delta) FROM inventory_movements m LEFT JOIN inbound_batches ib ON ib.id = m.inbound_batch_id LEFT JOIN output_batches ob ON ob.id = m.output_batch_id
            WHERE m.business_date IS NOT NULL AND COALESCE(ib.unit, ob.unit) = 'kg') THEN
        RAISE EXCEPTION 'FIXTURE 257 ROLL: the last closing should be every dated kg movement summed'; END IF;

    -- ══════════════ YIELD · 得率 ══════════════
    RAISE NOTICE 'fixture 257 · YIELD';
    IF (SELECT yield_pct FROM processing_run_yield_all WHERE run_id = r1 AND line_kind = 'output' AND line_key = 'black_mass') <> 170 * 100::numeric / 300
       OR (SELECT yield_pct FROM processing_run_yield_all WHERE run_id = r1 AND line_kind = 'output' AND line_key = 'collected_dust') <> 80 * 100::numeric / 300
       OR (SELECT qty FROM processing_run_yield_all WHERE run_id = r1 AND line_kind = 'total_output') <> 250
       OR NOT (SELECT recoverable FROM processing_run_yield_all WHERE run_id = r1 AND line_kind = 'loss' AND line_key = 'sweepings')
       OR (SELECT recoverable FROM processing_run_yield_all WHERE run_id = r2 AND line_kind = 'loss' AND line_key = 'moisture')
       OR (SELECT qty FROM processing_run_yield_all WHERE run_id = r1 AND line_kind = 'remainder') <> 30 THEN
        RAISE EXCEPTION 'FIXTURE 257 YIELD: per run (black mass 170/300, collected dust 80/300 as an output, total 250, sweepings recoverable, moisture not)'; END IF;
    -- 工序 × 月:battery_powder_line 的分母是三炉的投入 450(R1 300 · R2 100 · R6 50 —— 单位不是 kg 的 R7 不在)
    IF (SELECT input_qty FROM processing_yield_summary_all WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'output' AND line_key = 'black_mass') <> 450
       OR (SELECT qty FROM processing_yield_summary_all WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'output' AND line_key = 'collected_dust') <> 80
       OR (SELECT input_qty FROM processing_yield_summary_all WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'output' AND line_key = 'collected_dust') <> 450
       OR (SELECT runs FROM processing_yield_summary_all WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output') <> 3
       OR (SELECT pre_mes4a_runs FROM processing_yield_summary_all WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 257 YIELD: per operation and month the denominator is every consuming run''s input (450), 3 runs, 1 before MES-4a'; END IF;

    -- ══════════════ V37 · 只标,不拒 ══════════════
    RAISE NOTICE 'fixture 257 · V37';
    IF (SELECT below_expected FROM processing_run_yield_all WHERE run_id = r1 AND line_kind = 'output' AND line_key = 'black_mass') IS NOT TRUE
       OR (SELECT below_expected FROM processing_run_yield_all WHERE run_id = r2 AND line_kind = 'output' AND line_key = 'black_mass') IS NOT FALSE
       OR (SELECT below_expected FROM processing_run_yield_all WHERE run_id = r1 AND line_kind = 'output' AND line_key = 'collected_dust') IS NOT NULL
       OR (SELECT below_expected FROM processing_yield_summary_all WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'output' AND line_key = 'black_mass') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 257 V37: below 70 %% is flagged (R1 56.7, the month 66.7), above it is not (R2 90), with no value set it is NULL'; END IF;
    UPDATE operation_type_output_forms SET expected_yield_pct = 60 WHERE operation_type_code = 'battery_powder_line' AND form_code = 'black_mass';
    IF (SELECT below_expected FROM processing_yield_summary_all WHERE group_kind = 'all' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'output' AND line_key = 'black_mass') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 257 V37: the month (66.7 %%) is not below 60 %%'; END IF;

    -- ══════════════ GROUP · 分组 ══════════════
    RAISE NOTICE 'fixture 257 · GROUP';
    -- 化学体系:NMC(A 的物料)2/3 · 没记(B 与 E)—— 两组之和 = 450
    SELECT sum(input_qty) INTO v_num FROM processing_yield_summary_all WHERE group_kind = 'chemistry' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output';
    SELECT input_qty INTO v_num2 FROM processing_yield_summary_all WHERE group_kind = 'chemistry' AND group_key IS NULL AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output';
    IF abs(v_num - 450) > 0.000000001 OR v_num2 IS NULL OR abs(v_num2 - (100 + 100 * 100::numeric / 300 + 50)) > 0.000000001
       OR NOT EXISTS (SELECT 1 FROM processing_yield_summary_all WHERE group_kind = 'chemistry' AND group_key = 'NMC' AND operation_type_code = 'battery_powder_line' AND month = mon) THEN
        RAISE EXCEPTION 'FIXTURE 257 GROUP: chemistry groups (NMC and "not recorded") should split the 450 by share, got % / %', v_num, v_num2; END IF;
    SELECT sum(input_qty) INTO v_num FROM processing_yield_summary_all WHERE group_kind = 'supplier' AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output';
    SELECT input_qty INTO v_num2 FROM processing_yield_summary_all WHERE group_kind = 'supplier' AND group_key = s1::text AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output';
    IF abs(v_num - 450) > 0.000000001 OR abs(v_num2 - (200 + 100 * 200::numeric / 300)) > 0.000000001 THEN
        RAISE EXCEPTION 'FIXTURE 257 GROUP: supplier groups should split the 450 by share through the attribution (S1 = 200 + 66.67), got % / %', v_num, v_num2; END IF;
    IF (SELECT input_qty FROM processing_yield_summary_all WHERE group_kind = 'machine' AND group_key = eq::text AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output') <> 300
       OR (SELECT input_qty FROM processing_yield_summary_all WHERE group_kind = 'machine' AND group_key IS NULL AND operation_type_code = 'battery_powder_line' AND month = mon AND line_kind = 'total_output') <> 150 THEN
        RAISE EXCEPTION 'FIXTURE 257 GROUP: machine groups (the line 300, no machine recorded 150)'; END IF;
    -- 供应商的名字:持 module.inbound.view 的读到,不持的读到"受限"(不是"没有")
    v_j := pg_temp.f257_get(u_view, format($q$SELECT jsonb_build_object('label', group_label, 'restricted', group_label_restricted) FROM processing_yield_summary
                                              WHERE group_kind = 'supplier' AND group_key = %L AND line_kind = 'total_output' LIMIT 1$q$, s1), u_all);
    IF v_j ->> 'label' IS NOT NULL OR (v_j ->> 'restricted')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 257 GROUP: without module.inbound.view the supplier name must read restricted, got %', v_j; END IF;
    v_j := pg_temp.f257_get(u_vinb, format($q$SELECT jsonb_build_object('label', group_label, 'restricted', group_label_restricted) FROM processing_yield_summary
                                              WHERE group_kind = 'supplier' AND group_key = %L AND line_kind = 'total_output' LIMIT 1$q$, s1), u_all);
    IF v_j ->> 'label' <> 'f257 supplier one' OR (v_j ->> 'restricted')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 257 GROUP: with module.inbound.view the supplier name shows, got %', v_j; END IF;
    v_j := pg_temp.f257_get(u_view, $q$SELECT jsonb_build_object('label', group_label, 'restricted', group_label_restricted) FROM processing_yield_summary
                                       WHERE group_kind = 'chemistry' AND group_key IS NULL LIMIT 1$q$, u_all);
    IF v_j ->> 'label' IS NOT NULL OR (v_j ->> 'restricted')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 257 GROUP: "chemistry not recorded" is not a restriction, got %', v_j; END IF;

    -- ══════════════ READ · 读者的门 ══════════════
    RAISE NOTICE 'fixture 257 · READ';
    IF (pg_temp.f257_get(u_fin, $q$SELECT to_jsonb(count(*)) FROM processing_balance_monthly$q$, u_all))::text::bigint = 0
       OR (pg_temp.f257_get(u_fin, $q$SELECT to_jsonb(count(*)) FROM stock_rollforward_monthly$q$, u_all))::text::bigint = 0
       OR (pg_temp.f257_get(u_none, $q$SELECT to_jsonb(count(*)) FROM processing_balance_monthly$q$, u_all))::text::bigint <> 0
       OR (pg_temp.f257_get(u_none, $q$SELECT to_jsonb(count(*)) FROM stock_rollforward_monthly$q$, u_all))::text::bigint <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 257 READ: the monthly balance and roll-forward read for finance view and for nobody without a code'; END IF;
    IF (pg_temp.f257_get(u_inb, format($q$SELECT to_jsonb(count(*)) FROM batch_balance_tree WHERE root_id = %L$q$, ba), u_all))::text::bigint = 0
       OR (pg_temp.f257_get(u_inb, format($q$SELECT to_jsonb(count(*)) FROM batch_balance_tree WHERE root_id = %L$q$, o1), u_all))::text::bigint <> 0
       OR (pg_temp.f257_get(u_view, format($q$SELECT to_jsonb(count(*)) FROM batch_balance_tree WHERE root_id = %L$q$, o1), u_all))::text::bigint = 0
       OR (pg_temp.f257_get(u_none, format($q$SELECT to_jsonb(count(*)) FROM batch_balance_tree WHERE root_id = %L$q$, ba), u_all))::text::bigint <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 257 READ: a batch tree reads with processing view or the root batch''s own view code, and not otherwise'; END IF;
    IF (pg_temp.f257_get(u_view, $q$SELECT to_jsonb(count(*)) FROM processing_run_yield$q$, u_all))::text::bigint = 0
       OR (pg_temp.f257_get(u_inb, $q$SELECT to_jsonb(count(*)) FROM processing_run_yield$q$, u_all))::text::bigint <> 0
       OR (pg_temp.f257_get(u_inb, $q$SELECT to_jsonb(count(*)) FROM processing_yield_summary$q$, u_all))::text::bigint <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 257 READ: yield reads with processing view only'; END IF;
    BEGIN
        PERFORM pg_temp.f257_get(u_view, $q$SELECT to_jsonb(count(*)) FROM batch_balance_tree_all$q$, u_all);
        RAISE EXCEPTION 'FIXTURE 257 READ: the base views must not be readable by authenticated';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;

    -- ══════════════ FCHECK · 动作码蕴含查看码 ══════════════
    RAISE NOTICE 'fixture 257 · FCHECK';
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx257-x', 'f', 'f', true) RETURNING id INTO r_x;
    v_msg := pg_temp.f257_do(u_all, format($q$SELECT set_role_permissions(%L, ARRAY['action.manage_devices'])$q$, r_x), u_all);
    IF v_msg <> 'ACTION_REQUIRES_VIEW|action.manage_devices|module.processing.view' THEN
        RAISE EXCEPTION 'FIXTURE 257 FCHECK: an action code without any of its views must be refused by name, got %', v_msg; END IF;
    v_msg := pg_temp.f257_do(u_all, format($q$SELECT set_role_permissions(%L, ARRAY['action.receive_goods', 'module.inventory.view'])$q$, r_x), u_all);
    IF v_msg <> 'ACTION_REQUIRES_VIEW|action.receive_goods|module.inbound.view,module.logistics.view,module.processing.view,module.purchasing.view' THEN
        RAISE EXCEPTION 'FIXTURE 257 FCHECK: a view code that is not one of the declared ones does not count, got %', v_msg; END IF;
    v_msg := pg_temp.f257_do(u_all, format($q$SELECT set_role_permissions(%L, ARRAY['action.receive_goods', 'module.logistics.view'])$q$, r_x), u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 257 FCHECK: any ONE of the declared views is enough, got %', v_msg; END IF;
    v_msg := pg_temp.f257_do(u_all, format($q$SELECT set_role_permissions(%L, ARRAY['action.bulk_import'])$q$, r_x), u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 257 FCHECK: a code whose page it gates itself needs nothing else, got %', v_msg; END IF;
    v_msg := pg_temp.f257_do(u_all, format($q$SELECT set_role_permissions(%L, ARRAY['action.anonymise_employee'])$q$, r_x), u_all);
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 257 FCHECK: the one action with no screen declares nothing, got %', v_msg; END IF;
    v_msg := pg_temp.f257_do(u_all, format($q$SELECT set_role_permissions(%L, ARRAY['module.processing.edit'])$q$, r_x), u_all);
    IF v_msg <> 'EDIT_REQUIRES_VIEW|processing' THEN RAISE EXCEPTION 'FIXTURE 257 FCHECK: the edit-implies-view guard is unchanged, got %', v_msg; END IF;
    -- 目录的声明:只有动作码声明;除了没有屏幕的那一个都声明了;每一个元素是一个模块的查看码或这个码自己
    SELECT string_agg(code, ', ') INTO v_bad FROM permissions
     WHERE (category = 'action' AND requires_view_any IS NULL AND code <> 'action.anonymise_employee')
        OR (category <> 'action' AND requires_view_any IS NOT NULL)
        OR EXISTS (SELECT 1 FROM unnest(requires_view_any) v WHERE NOT (v = code OR v LIKE 'module.%.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 257 FCHECK: catalogue declarations wrong for %', v_bad; END IF;
    -- 重建库里【每一个】角色(引导的,与这支 fixture 自己的)都满足这条规矩
    SELECT string_agg(ro.code || ' -> ' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 257 FCHECK: a role holds an action without any of its views: %', v_bad; END IF;
    -- 引导:admin 持目录里除 module.tasks.view_all 之外的每一个码;财务持 module.processing.view(它持下达工单,那一页的门)
    SELECT string_agg(p.code, ', ') INTO v_bad FROM permissions p
     WHERE p.code <> 'module.tasks.view_all'
       AND NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = 'admin' AND rp.permission_code = p.code);
    IF v_bad IS NOT NULL OR EXISTS (SELECT 1 FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = 'admin' AND rp.permission_code = 'module.tasks.view_all') THEN
        RAISE EXCEPTION 'FIXTURE 257 FCHECK: the bootstrap admin should hold every code but module.tasks.view_all; missing %', v_bad; END IF;
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id WHERE ro.code = 'finance' AND rp.permission_code = 'module.processing.view') THEN
        RAISE EXCEPTION 'FIXTURE 257 FCHECK: the bootstrap finance role should hold module.processing.view'; END IF;

    -- ══════════════ LOG · 没有新表 ══════════════
    RAISE NOTICE 'fixture 257 · LOG';
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 257 LOG: change-log coverage %', v_j; END IF;

    RAISE NOTICE 'FIXTURE 257 全部通过:CONS · ATTR · BAL · PRE · MONTH · NOTKG · ROLL · INV · YIELD · V37 · GROUP · READ · FCHECK · LOG';
END
$$;

ROLLBACK;

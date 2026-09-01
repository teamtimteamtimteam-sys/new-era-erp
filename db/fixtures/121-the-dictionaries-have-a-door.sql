-- 121 五张字典【有门了】—— 而门通向的是同一间屋子
--
-- 【本刀是纯 app 层的:零迁移、零 schema 改动】那这份 fixture 钉什么?
-- **钉那扇门通向的地方。** 屏幕本身 fixture 到不了(那几行进手走清单 §12),
-- 但屏幕做的四件事 —— 加一个值、改名字与顺序、停用、以及权限 ——
-- 每一件在库那一侧都有一个可断言的结果,而那正是"门开了没有"的实质。
--
-- 【每一臂钉什么】
-- F1 前提:五张字典【现在读出来的东西一个字没变】。断言值,不是"查询跑通了"。
-- F2 **门通向同一间屋子**:事务里往字典加一行,读它的那一侧【立刻】用得上。
-- F3 D2 两个方向:停用【挡住新选】,而【不让已经记下的失效】。
-- F4 D5 顺序照设的来,而且与插入次序【不同】(否则这一臂证明不了任何事)。
-- F5 D7 权限:**没有权限的人拿到的是一次【拒绝】,不是一张空表。**
--    fixture 以 postgres 跑、RLS 对它不生效,所以这一臂必须 SET LOCAL ROLE
--    (README 第 6 条 —— 不切角色的可见性断言是在证明空话)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_none uuid := gen_random_uuid();
    r_all uuid; r_none uuid;
    v_sup uuid; v_mat uuid; v_ib uuid;
    v_n int; v_denied boolean; v_msg text;
    v_by_sort text; v_by_insert text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-121', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    -- 【一个什么权限都没有的人】—— F5 用它
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-121-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_none, r_none);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ F1 · 前提:五张字典读出来的东西一个字没变 ════════════════════
    RAISE NOTICE 'fixture 121 · 进入 F1';
    IF (SELECT count(*) FROM substances WHERE is_active) < 7
       OR (SELECT count(*) FROM battery_chemistries WHERE is_active) < 8
       OR (SELECT count(*) FROM material_kinds) < 5
       OR (SELECT count(*) FROM inbound_safety_states) < 5
       OR (SELECT count(*) FROM laboratories) < 1 THEN
        RAISE EXCEPTION 'FIXTURE 121F1 失败:进入 F1 —— 五张字典的引导行必须原样都在。**本刀是纯 app 层的,库里一个字都不该动**;这一条红了说明动了不该动的东西';
    END IF;
    -- 断言【值】,不只是条数:规则列尤其要原样
    IF (SELECT may_be_fed FROM inbound_safety_states WHERE code = 'discharged_verified') IS NOT TRUE
       OR (SELECT may_be_fed FROM inbound_safety_states WHERE code = 'water_exposed') IS NOT FALSE
       OR (SELECT has_condition_axes FROM material_kinds WHERE code = 'battery_material') IS NOT TRUE
       OR (SELECT has_condition_axes FROM material_kinds WHERE code = 'ewaste') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 121F1 失败:进入 F1 —— 规则列的取值必须一个都没变(那几个布尔是 PROC-3/4 的闸在读的东西)';
    END IF;

    -- ══════════ F2 · 门通向同一间屋子 ═══════════════════════════════════════
    RAISE NOTICE 'fixture 121 · 进入 F2';
    -- 【这一臂是本刀的意义】屏幕做的第一件事是"加一个值";
    -- 而它值钱与否,取决于**读这张字典的那一侧能不能立刻用上它**。
    INSERT INTO inbound_safety_states (code, name_en, name_zh, may_be_fed, sort_order)
    VALUES ('ZZ121_STATE', 'Fixture state', 'fixture 状态', false, 90);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ121-S', 'f121 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ121-M', 'f121 feed', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ121-IB', v_mat, v_sup, 100, 100, 'kg', CURRENT_DATE - 1) RETURNING id INTO v_ib;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        VALUES (v_ib, 'ZZ121_STATE');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 121F2 失败:进入 F2 —— 刚加进字典的值必须【立刻】能被记到一车货上。加得进字典却用不上,那扇门就通向别处。实得「%」', v_msg;
    END IF;

    -- 而且那个【规则】也立刻生效:may_be_fed = false 的新状态,投料闸要拦
    PERFORM reprice_inbound_batch(v_ib, 1, (SELECT code FROM currencies WHERE is_base), NULL, 'f121');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(CURRENT_DATE - 1, 'f121', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_SAFETY_STATE_NOT_ACCEPTED%' THEN
        RAISE EXCEPTION 'FIXTURE 121F2 失败:进入 F2 —— 新加的那个状态 may_be_fed = false,**PROC-3 的闸必须立刻按它拦**(PROC-SUPPORT-1 起这条码是 _NOT_ACCEPTED:工序必填之后,受理由 operation_type_safety_states 回答 —— 新加一个状态没有被任何工序列进清单,所以它照样被拦)。加一行字典要连它的【规则】一起生效,否则那扇门只是把值放进去、规则留在外面。实得「%」', COALESCE(v_msg,'(放行了)');
    END IF;

    -- ══════════ F3 · D2 两个方向 ════════════════════════════════════════════
    RAISE NOTICE 'fixture 121 · 进入 F3';
    UPDATE inbound_safety_states SET is_active = false WHERE code = 'ZZ121_STATE';
    -- 方向一:【已经记下的那一行一个字没变,而且照样在】
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states
                    WHERE inbound_batch_id = v_ib AND safety_state_code = 'ZZ121_STATE') THEN
        RAISE EXCEPTION 'FIXTURE 121F3 失败:进入 F3 —— **停用绝不能让已经记下的事实消失。** 那一行是当时有人记下的,不因为今天不再选它而变成假的';
    END IF;
    -- 而那条【规则】也照旧成立 —— PROC-3 定死过:停用的安全状态照样拦货
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(CURRENT_DATE - 1, 'f121 after deactivate', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_SAFETY_STATE_NOT_ACCEPTED%' THEN
        RAISE EXCEPTION 'FIXTURE 121F3 失败:进入 F3 —— **一个被停用的安全状态照样拦住这车货**(PROC-3 定死的那一条)。这一臂在防的是把 is_active 读成"这条规则作废了" —— 那会是一条无痕迹、且一次性对所有批次生效的释放路径。实得「%」', COALESCE(v_msg,'(放行了)');
    END IF;
    -- 方向二:它从【可选集合】里消失 —— 那正是屏幕上的选单读的那条查询
    IF EXISTS (SELECT 1 FROM inbound_safety_states WHERE is_active AND code = 'ZZ121_STATE') THEN
        RAISE EXCEPTION 'FIXTURE 121F3 失败:进入 F3 —— 停用之后它必须从"还能新选"的那一组里消失';
    END IF;

    -- ══════════ F4 · D5 顺序照设的来,且与插入次序不同 ═══════════════════════
    RAISE NOTICE 'fixture 121 · 进入 F4';
    -- 【先造出"两者会不同"的局面】按插入次序它们是 A、B、C;把 sort_order 反过来设。
    INSERT INTO laboratories (code, name_en, name_zh, sort_order) VALUES
        ('ZZ121_LA', 'Lab A', '实验室 A', 30),
        ('ZZ121_LB', 'Lab B', '实验室 B', 20),
        ('ZZ121_LC', 'Lab C', '实验室 C', 10);
    SELECT string_agg(code, ',' ORDER BY sort_order) INTO v_by_sort
      FROM laboratories WHERE code LIKE 'ZZ121\_L%';
    SELECT string_agg(code, ',' ORDER BY code) INTO v_by_insert
      FROM laboratories WHERE code LIKE 'ZZ121\_L%';
    IF v_by_sort = v_by_insert THEN
        RAISE EXCEPTION 'FIXTURE 121F4 前置失败:进入 F4 —— 这一臂要求【设的顺序】与【插入次序】不同,否则它什么都证明不了。实得两者都是「%」', v_by_sort;
    END IF;
    IF v_by_sort <> 'ZZ121_LC,ZZ121_LB,ZZ121_LA' THEN
        RAISE EXCEPTION 'FIXTURE 121F4 失败:进入 F4 —— 顺序必须照【设的那个】来(C,B,A),实得「%」。**一个新值默认排到最后也是一个决定** —— PROC-4 量过不设它的后果:同一批金属,下拉里镍第一、报表里铝第一', v_by_sort;
    END IF;

    -- ══════════ F5 · D7 权限:拒绝,不是空表 ════════════════════════════════
    RAISE NOTICE 'fixture 121 · 进入 F5';
    -- 【必须切数据库角色】fixture 以 postgres 跑,RLS 对超级用户完全不生效 ——
    -- 不切角色的可见性断言是在证明空话(README 第 6 条,fixture 26 栽过)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO laboratories (code, name_en, name_zh, sort_order)
        VALUES ('ZZ121_DENIED', 'nope', '不该进去', 99);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 121F5 失败:进入 F5 —— 一个没有 module.inbound.edit 的人【不该】加得进实验室。RLS 那条 INSERT 策略就是这扇门的锁';
    END IF;
    -- 【而它必须是一次【拒绝】,不是一张空表】——
    -- 屏幕那一侧据此说"你不能做这件事";若这里静静地什么都没发生,
    -- 屏幕就会画出一张空清单,而【受限不是零】(lib/permissions.ts 存在的全部理由)。
    IF v_msg NOT LIKE '%row-level security%' AND v_msg NOT LIKE '%42501%'
       AND v_msg NOT LIKE '%permission denied%' THEN
        RAISE EXCEPTION 'FIXTURE 121F5 失败:进入 F5 —— 拒绝要是一条【认得出来的】权限拒绝,屏幕才翻得成"你不能做这件事"。实得「%」', v_msg;
    END IF;
    IF EXISTS (SELECT 1 FROM laboratories WHERE code = 'ZZ121_DENIED') THEN
        RAISE EXCEPTION 'FIXTURE 121F5 失败:进入 F5 —— 被拒的那一行不该留在库里';
    END IF;
END $$;
ROLLBACK;

-- 179 一个预期产出必须说出它的数【是怎么来的】 · PROC-SUPPORT-1(R3)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉什么】
-- P1 ★ 新建工单时,一条不说出处的预期产出被按名拒(WO_EXPECTED_BASIS_REQUIRED)。
--    先注入证明:同一份载荷【带上出处】就建得了 —— 否则这一臂可能只是因为
--    别的原因被拒。
-- P2 ★ 空串与缺席走【同一条】拒绝 —— 一个空串在库里不是 NULL,却和"没人说过"
--    是同一件事,而它会绕过任何只看 NULL 的检查。
-- P3 ★ 三个取值都存得进去,而且【存进去的就是读出来的那一个】。
--    这一臂在防的是"把三个来源折成一个布尔"那种简化。
-- P4 ★ 一个不在值域里的出处被拒 —— 值域是数据库的事,不是屏幕的自觉。
-- P5 ★ 改单可以【只改出处】,而且那次改动【留痕】:
--    seeded_industry → calibrated 是这张表上最重要的一次变化(猜的变成验证过的),
--    让它悄悄发生,六个月后没有人说得出它是什么时候变的。
-- P6 ★ 出处【不覆盖】expected_qty —— 表注早就规定了这个形状。
--
-- 【本 fixture 不播种任何比例数字】它用的每一个数都只是为了让约束跑起来,
-- 不是一条收率。R3 明写:一个顶着"播种"标签的发明出来的比例仍然是发明出来的。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_mat uuid; v_mat2 uuid;
    v_wo jsonb; v_wo_id uuid;
    v_msg text; v_denied boolean;
    v_basis text; v_ref text; v_qty numeric; v_n integer;
    v_detail text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-179', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ179-IN', 'f179 feed', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;
    -- 【产出物料用一个【没有状态轴】的种类】battery_material 那一类由
    -- guard_material_condition_axes 强制要求 form_code + source_code
    -- (「两者都永远不会替你填」)。本臂测的是【出处】,不是那条守卫 ——
    -- 借它一个前提只会让失败时分不清是谁的错。
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZ179-OUT', 'f179 output', 'ewaste', true) RETURNING id INTO v_mat2;

    -- ══════════ P1 · ★ 不说出处 → 按名拒 ★ ══════════
    RAISE NOTICE 'fixture 179 · 进入 P1';
    -- 【先证明注入确实改变了东西】带上出处的同一份载荷必须建得了。
    v_wo := NULL; v_msg := NULL;
    BEGIN
        v_wo := create_work_order(
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'planned_qty', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat2, 'expected_qty', 60,
                                                'basis', 'planner_estimate')),
            NULL, 'f179 control');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_wo IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 179P1 前置失败:**带着出处的同一份载荷必须建得了工单。** 少了这一句,一个把所有预期产出都拒掉的实现会让本臂变绿 —— 那不是"必须说出出处",那是"不许有预期产出"。实得「%」', COALESCE(v_msg, '(返回空)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_work_order(
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'planned_qty', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat2, 'expected_qty', 60)),
            NULL, 'f179 no basis');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_EXPECTED_BASIS_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 179P1 失败:一条【不说出处】的预期产出必须被按名拒。**这不是一次数据校验,是这一列存在的全部理由** —— 六个月后 Tim 要分得出哪些数字被真实生产验证过、哪些还是当初那个猜测,而那件事只有现在记下来才记得住。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ P2 · ★ 空串与缺席走同一条拒绝 ★ ══════════
    RAISE NOTICE 'fixture 179 · 进入 P2';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_work_order(
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'planned_qty', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat2, 'expected_qty', 60,
                                                'basis', '   ')),
            NULL, 'f179 blank basis');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WO_EXPECTED_BASIS_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 179P2 失败:一个【全是空白】的出处与【没有出处】是同一件事,必须走同一条拒绝。**空串在库里不是 NULL** —— 它会绕过任何只看 NULL 的检查,然后在屏幕上显示成一个看不出问题的空格。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ P4 · ★ 值域是数据库的事 ★ ══════════
    RAISE NOTICE 'fixture 179 · 进入 P4';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_work_order(
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'planned_qty', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat2, 'expected_qty', 60,
                                                'basis', 'vibes')),
            NULL, 'f179 bad basis');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 179P4 失败:一个不在值域里的出处必须被拒。值域是数据库的事,不是屏幕的自觉 —— 屏幕只是第一道。';
    END IF;

    -- ══════════ P3 · ★ 三个取值都存得进,而且存进去的就是读出来的 ★ ══════════
    RAISE NOTICE 'fixture 179 · 进入 P3';
    v_wo := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'planned_qty', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat2, 'expected_qty', 60,
                                             'basis', 'seeded_industry',
                                             'basis_reference', 'f179:一份假想的行业报告,不是一条收率')),
        NULL, 'f179 seeded');
    v_wo_id := (v_wo->>'work_order_id')::uuid;
    SELECT basis, basis_reference, expected_qty INTO v_basis, v_ref, v_qty
      FROM work_order_expected_outputs WHERE work_order_id = v_wo_id AND material_id = v_mat2;
    IF v_basis IS DISTINCT FROM 'seeded_industry' THEN
        RAISE EXCEPTION 'FIXTURE 179P3 失败:**存进去的出处必须就是读出来的那一个。** 这一臂在防的是"把三个来源折成一个布尔"那种简化 —— seeded_industry 与 planner_estimate 都不是 calibrated,但它们【错的时候要找的人不是同一个】。应得 seeded_industry,实得「%」', COALESCE(v_basis, '(空)');
    END IF;
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 179P3 失败:凭据(basis_reference)必须一起存下来 —— 它是证据,不是数据。没有它,"照行业经验播的"这句话本身无法被核查。';
    END IF;

    -- ══════════ P6 · ★ 出处不覆盖那个估计 ★ ══════════
    RAISE NOTICE 'fixture 179 · 进入 P6';
    IF v_qty IS DISTINCT FROM 60 THEN
        RAISE EXCEPTION 'FIXTURE 179P6 失败:**贴一个标签绝不许改动那个数。** 表注早就规定了这个形状:新来源作为【另一个带标签的来源】进来,不覆盖既有的估计 —— 覆盖会把"人估的"与"标准算的"混成一个数,而那两个数错的时候要找的人不是同一个。应得 60,实得「%」', COALESCE(v_qty::text, '(空)');
    END IF;

    -- ══════════ P5 · ★ 只改出处,也是一次改动,而且留痕 ★ ══════════
    RAISE NOTICE 'fixture 179 · 进入 P5';
    -- 【草稿就可以改单 —— 不多走一步 release】那一步与本臂要测的东西无关,
    -- 而它自己会带来一组前提(WO-1b 的放行条件),失败时分不清是谁的错。
    -- 【先证明起点】改之前它确实是 seeded_industry。
    SELECT basis INTO v_basis FROM work_order_expected_outputs
     WHERE work_order_id = v_wo_id AND material_id = v_mat2;
    IF v_basis IS DISTINCT FROM 'seeded_industry' THEN
        RAISE EXCEPTION 'FIXTURE 179P5 前置失败:这一臂要的起点是 seeded_industry,实得「%」', COALESCE(v_basis, '(空)');
    END IF;

    PERFORM amend_work_order(
        p_work_order_id => v_wo_id,
        p_reason        => 'f179:第一次真实炉次跑完,这个数被校准了',
        p_expected      => jsonb_build_array(jsonb_build_object(
                               'material_id', v_mat2, 'expected_qty', 60,
                               'basis', 'calibrated')));

    SELECT basis, expected_qty INTO v_basis, v_qty FROM work_order_expected_outputs
     WHERE work_order_id = v_wo_id AND material_id = v_mat2;
    IF v_basis IS DISTINCT FROM 'calibrated' THEN
        RAISE EXCEPTION 'FIXTURE 179P5 失败:**只改出处必须算一次改动。** 数量一个字没动、出处从"播的"变成"校准过的" —— 那是这张表上最重要的一次变化。一个只比数量的实现会在这里报 WO_AMEND_NO_CHANGES,于是那次变化【永远不会发生】。应得 calibrated,实得「%」', COALESCE(v_basis, '(空)');
    END IF;
    IF v_qty IS DISTINCT FROM 60 THEN
        RAISE EXCEPTION 'FIXTURE 179P5 失败:改出处不该动那个数,应得 60,实得「%」', COALESCE(v_qty::text, '(空)');
    END IF;

    -- ★【留痕:六个月后要说得出它是什么时候变的】★
    SELECT count(*), max(detail) INTO v_n, v_detail FROM work_order_history
     WHERE work_order_id = v_wo_id AND change_type = 'expected_update';
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 179P5 失败:**那次改动必须留痕。** 猜的变成验证过的,是这张表上最要紧的一刻;让它悄悄发生,六个月后没有人说得出它是什么时候变的 —— 而那正是这一整列存在的理由。';
    END IF;
    IF v_detail IS NULL OR v_detail NOT LIKE '%seeded_industry%' OR v_detail NOT LIKE '%calibrated%' THEN
        RAISE EXCEPTION 'FIXTURE 179P5 失败:留痕里要说得出【从什么变成了什么】。只记"改过一次"等于没记 —— 读的人还得去猜前一个值是什么。实得「%」', COALESCE(v_detail, '(空)');
    END IF;
END $$;
ROLLBACK;

-- 180 交接班:签收要说得出【是谁】与【什么时候】 · PROC-SUPPORT-1(R4/R5)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉什么】
-- H1 ★ 一张交接班建得起来,而且刚建好时【未签收】—— 两列都是空的。
-- H2 ★ 签收记下【是谁】与【什么时候】,而且未签收与已签收【分得开】。
--    先注入证明:签收之前那两列确实是空的,否则这一臂等于什么都没测。
-- H3 ★ 只有【这张交接班点名的接班人】签得动 —— 别人代签按名拒。
--    放宽这一条,acknowledged_at 就退化成一个永远是满的时间戳,
--    而它本来要回答的问题(下一个班的人真的看过这些话了吗)从此没有答案。
-- H4 ★ 签过的不能再签一次 —— 覆盖会把第一次签收的人与时刻抹掉。
-- H5 ★ 一个人不能交给自己。
-- H6 ★ 内容是【行】:加第七类内容 = 字典加一行,函数一个字不用改。
-- H7 ★ 设备状态是一条【引用】,不是一份副本 —— 交接班上存的是 downtime 的 id,
--    而那条停机的正文仍然只有一份。
-- H8 ★ 签收那两列【要么都空、要么都满】—— 一次说不出是谁签的签收比没签更坏。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    r_all uuid;
    v_out_user uuid := gen_random_uuid();
    v_in_user  uuid := gen_random_uuid();
    v_third_user uuid := gen_random_uuid();
    v_dept uuid; v_out_emp uuid; v_in_emp uuid; v_third_emp uuid;
    v_asset uuid; v_dt uuid;
    v_ho uuid; v_msg text; v_denied boolean; v_ccy text;
    v_at timestamptz; v_by uuid; v_n integer; v_reason text;
    v_d date := DATE '2027-12-05';
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-180', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_out_user, r_all), (v_in_user, r_all), (v_third_user, r_all);

    -- 【自带三个人】线上 work_category = 'shopfloor' 的员工数是 0,
    -- 所以这三个人只能自己造 —— 那正是"第一天交接班里几乎什么都没有"的另一面。
    -- employees.user_id 自 EXEC-2 起有指向 auth.users 的外键,所以登录身份要
    -- 真的存在(与 fixture 126 同一条)。签收读的是 current_user_employee(),
    -- 也就是 auth.uid() → employees.user_id 那一跳 —— 这三行是那一跳的前提。
    INSERT INTO auth.users (id) VALUES (v_out_user), (v_in_user), (v_third_user);
    INSERT INTO employees (code, legal_name, preferred_name, work_category,
                           employment_type, employment_status, hire_date, user_id)
    VALUES ('ZZ180-E1', 'f180 outgoing', 'Outgoing', 'shopfloor', 'full_time', 'active', v_d - 30, v_out_user)
    RETURNING id INTO v_out_emp;
    INSERT INTO employees (code, legal_name, preferred_name, work_category,
                           employment_type, employment_status, hire_date, user_id)
    VALUES ('ZZ180-E2', 'f180 incoming', 'Incoming', 'shopfloor', 'full_time', 'active', v_d - 30, v_in_user)
    RETURNING id INTO v_in_emp;
    INSERT INTO employees (code, legal_name, preferred_name, work_category,
                           employment_type, employment_status, hire_date, user_id)
    VALUES ('ZZ180-E3', 'f180 bystander', 'Bystander', 'shopfloor', 'full_time', 'active', v_d - 30, v_third_user)
    RETURNING id INTO v_third_emp;

    -- 设备停机一段(R5:交接班要【指着】它,不复述它)
    -- 【列全部写齐,抄 fixture 120 的形状】cost_ccy / currency / fx_rate 都是
    -- NOT NULL —— 这台机器的成本与本臂无关,但前提要显式设定(README 第 5 条)。
    INSERT INTO fixed_assets (code, description, category, acquisition_date,
                              cost_base, currency, cost_ccy, fx_rate, status,
                              useful_life_months, residual_base)
    VALUES ('ZZ180-FA', 'f180 machine', 'equipment', v_d - 60,
            0, v_ccy, 0, 1, 'active', 100, 0) RETURNING id INTO v_asset;
    -- 【这一段停机必须落在【过去】】guard_downtime_period 拒绝未来的开始时刻
    -- (DOWNTIME_START_IN_FUTURE)—— 一段"还没发生的停机"不是一个可记录的事实。
    -- 所以这里用 now() 相对时刻,而不是本 fixture 那个自带的未来日期:
    -- 交接班的日期是一个【世界侧的日子】,停机的开始是一个【已经发生的时刻】,
    -- 两者不必是同一个数,而这条守卫正是那个区别的执行者。
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
    VALUES (v_asset, now() - interval '1 day', NULL, 'f180:轴承异响,停机待检')
    RETURNING id INTO v_dt;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_out_user), true);

    -- ══════════ H5 · ★ 一个人不能交给自己 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H5';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM submit_shift_handover('day', v_d, v_out_emp, v_out_emp, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'HANDOVER_SAME_PERSON%' THEN
        RAISE EXCEPTION 'FIXTURE 180H5 失败:交班人与接班人是同一个人时必须被按名拒 —— 那样的"交接"没有把任何东西传给任何人,而它会在计数里冒充一次真的交接。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ H1 · ★ 建得起来,而且刚建好时未签收 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H1';
    v_ho := submit_shift_handover(
        p_shift_code           => 'day',
        p_handover_date        => v_d,
        p_outgoing_employee_id => v_out_emp,
        p_incoming_employee_id => v_in_emp,
        p_notes                => 'f180 交接',
        p_items                => jsonb_build_array(jsonb_build_object(
                                      'item_type_code', 'unfinished_work',
                                      'body', '3 号料斗还有半批没喂完')),
        p_downtime_ids         => ARRAY[v_dt]);
    IF v_ho IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 180H1 失败:**这是整份 fixture 的铰链** —— 一张交接班必须建得起来。只测拒绝的话,一个把所有交接班都拦住的实现会全绿。';
    END IF;

    -- 【先证明注入确实改变了东西】签收之前那两列【真的】是空的。
    SELECT acknowledged_at, acknowledged_by INTO v_at, v_by FROM shift_handovers WHERE id = v_ho;
    IF v_at IS NOT NULL OR v_by IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 180H1 失败:一张刚提交的交接班必须是【未签收】的。**空 = 还没有人签收**,不是"签收了但没记时间" —— 少了这一句,下面那一臂等于什么都没测。';
    END IF;

    -- ══════════ H6 · ★ 内容是行 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H6';
    SELECT count(*) INTO v_n FROM shift_handover_items WHERE handover_id = v_ho;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 180H6 前置失败:那一条交接内容没落上去,应得 1 行,实得 %', v_n;
    END IF;
    -- ★ 加第七类内容 = 字典加一行,函数一个字不用改 ★
    INSERT INTO handover_item_types (code, name_en, name_zh, is_required, sort_order, is_active, notes)
    VALUES ('zz180_seventh', 'f180 seventh field', 'f180 第七项', false, 99, true, 'fixture 180 H6');
    PERFORM submit_shift_handover(
        p_shift_code           => 'night',
        p_handover_date        => v_d,
        p_outgoing_employee_id => v_out_emp,
        p_incoming_employee_id => v_in_emp,
        p_notes                => NULL,
        p_items                => jsonb_build_array(jsonb_build_object(
                                      'item_type_code', 'zz180_seventh',
                                      'body', '第七项的内容')),
        p_downtime_ids         => NULL);
    IF NOT EXISTS (SELECT 1 FROM shift_handover_items WHERE item_type_code = 'zz180_seventh') THEN
        RAISE EXCEPTION 'FIXTURE 180H6 失败:**第七个交接班字段必须是【一行】,不是一次改代码。** 这是 Tim 点名要的形状:内容不知道会长成什么样,所以内容是数据。一个把类别写死在函数里的实现在这里会红。';
    END IF;

    -- ══════════ H7 · ★ 设备状态是引用,不是副本 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H7';
    IF NOT EXISTS (SELECT 1 FROM shift_handover_equipment_refs
                    WHERE handover_id = v_ho AND downtime_id = v_dt) THEN
        RAISE EXCEPTION 'FIXTURE 180H7 前置失败:那条设备停机引用没挂上去';
    END IF;
    -- ★ 那条停机的正文仍然【只有一份】—— 交接班这一侧没有第二份 reason ★
    SELECT reason INTO v_reason FROM equipment_downtime WHERE id = v_dt;
    IF v_reason IS DISTINCT FROM 'f180:轴承异响,停机待检' THEN
        RAISE EXCEPTION 'FIXTURE 180H7 失败:停机的正文只应当有一份,而且在 equipment_downtime 上,实得「%」', COALESCE(v_reason, '(空)');
    END IF;
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'shift_handover_equipment_refs'
           AND column_name IN ('reason', 'notes', 'equipment_state', 'started_at', 'ended_at')) THEN
        RAISE EXCEPTION 'FIXTURE 180H7 失败:**交接班【指着】一段停机,绝不【复述】它。** 这张引用表上出现了一列看起来像在抄写停机正文的字段。一次事件两份记录,迟早会不一致,而人们读到的那一份会是错的那一份 —— 同一条论证仓库已经对保险用过一次(「保险就是一种证书,不是第二套到期机制」)。';
    END IF;

    -- ══════════ H3 · ★ 只有点名的接班人签得动 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H3';
    -- (a) 交班的人自己签 → 拒
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM acknowledge_shift_handover(v_ho);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'HANDOVER_ACK_NOT_INCOMING%' THEN
        RAISE EXCEPTION 'FIXTURE 180H3(a) 失败:**交班的人不能签自己的交接班。** 那样的签收没有传递任何东西 —— 它只是同一个人又说了一遍自己写的话。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- (b) 一个不相干的第三人签 → 拒
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_third_user), true);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM acknowledge_shift_handover(v_ho);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'HANDOVER_ACK_NOT_INCOMING%' THEN
        RAISE EXCEPTION 'FIXTURE 180H3(b) 失败:**别人代签必须被拒。** 放宽这一条,acknowledged_at 就退化成一个永远是满的时间戳,而它本来要回答的问题 ——【下一个班的人真的看过这些话了吗】—— 从此没有答案。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ H2 · ★ 点名的接班人签得动,而且记下是谁与什么时候 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H2';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_in_user), true);
    PERFORM acknowledge_shift_handover(v_ho);
    SELECT acknowledged_at, acknowledged_by INTO v_at, v_by FROM shift_handovers WHERE id = v_ho;
    IF v_at IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 180H2 失败:签收之后 acknowledged_at 必须有值 —— 未签收与已签收要分得开,而这一列就是那个区别。';
    END IF;
    IF v_by IS DISTINCT FROM v_in_emp THEN
        RAISE EXCEPTION 'FIXTURE 180H2 失败:**签收要说得出【是谁】。** 而且它落在一个【员工】身上,不是一个登录账号 —— 车间可能共用工位账号,而"谁接的班"必须是一个人。应得那位接班人,实得「%」', COALESCE(v_by::text, '(空)');
    END IF;

    -- ══════════ H4 · ★ 签过的不能再签 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H4';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM acknowledge_shift_handover(v_ho);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'HANDOVER_ALREADY_ACKNOWLEDGED%' THEN
        RAISE EXCEPTION 'FIXTURE 180H4 失败:**签收不是一个可以重来的动作。** 再签一次会把第一次签收的人与时刻覆盖掉,而那两个值正是这一列存在的理由。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ H8 · ★ 那两列要么都空、要么都满 ★ ══════════
    RAISE NOTICE 'fixture 180 · 进入 H8';
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE shift_handovers SET acknowledged_by = NULL WHERE id = v_ho;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%shift_handover_ack_paired%' THEN
        RAISE EXCEPTION 'FIXTURE 180H8 失败:**一次说不出是谁签的签收,比没签更坏** —— 它看起来像有人负责了。所以那两列要么都空(未签收),要么都满。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;
END $$;
ROLLBACK;

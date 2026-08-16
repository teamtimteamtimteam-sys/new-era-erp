-- 79 工单差异:两个阈值、两种坏消息、两种触发时机(EXEC-3a)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西】
--
--   ① 【两个阈值是两个数,而且各管各的】把 wo_input_overrun_pct 调大,只有
--      投入那一条该消失;把 wo_output_shortfall_pct 调大,只有产出那一条该消失。
--      一个把两者合成一个数的实现,在这里两条会一起动 —— 当场红。
--   ② 【边界 ± 1】恰好等于阈值不报,超过一点点才报。判据是 > 与 <,不是 >= 与 <=。
--   ③ 【触发时机不同】投入超耗在【放行中】的单上就报;产出短交【只在收工后】报。
--      一个对两者一视同仁的实现,在 C 臂当场红。
--   ④ 【没记录预期的行永远不报】没估过不是估了零 —— 一个 COALESCE(...,0) 会让
--      每一次产出都成为"短交 100%"。D 臂。
--   ⑤ 【被冲销的加工不算数】它的消耗不再是发生过的事实(WO-1b 的规则),
--      所以它不该把一张工单推过超耗线。E 臂。
--
-- 【阈值现读,不是记住的】F 臂在同一个事务里改配置、看那一支动 —— 与 fixture 76
-- 同一个形状,而这里要分别改两个数,证明它们【互不影响】。
--
-- 注入放在最后:两条腿的阈值判据都没有第二层(表上没有任何东西阻止一张超耗的
-- 工单不出现在看板上)。原样定义在任何注入之前取。
-- 自带数据(README 第 2 条);日期落在 2029(第 4 条);期间锁显式清空(第 5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    v_other uuid := gen_random_uuid();
    r_all uuid; r_other uuid;
    v_sup uuid; v_matA uuid; v_matB uuid; v_ib uuid; v_ib2 uuid;
    woOpen uuid; woClosed uuid; woNoExp uuid; woRev uuid;
    v_res jsonb; v_run uuid; v_n integer;
    def_view text; v_inj text;
    d date := DATE '2029-03-10';
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-79', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-79-other', 'f', 'f', true) RETURNING id INTO r_other;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_other, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_other, r_other);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    UPDATE finance_settings SET locked_before = NULL;
    -- 【前提显式设】两个阈值都是运营改得动的列(README 第 5 条)
    UPDATE processing_settings SET wo_input_overrun_pct = 10, wo_output_shortfall_pct = 10;

    def_view := pg_get_viewdef('public.operations_now'::regclass, true);

    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('ZZ79-S', 'fixture 79 supplier', 'SG') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, category) VALUES ('ZZ79-MA','f79 raw','black_mass')
        RETURNING id INTO v_matA;
    INSERT INTO materials (code, name, category) VALUES ('ZZ79-MB','f79 fine','black_mass')
        RETURNING id INTO v_matB;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ79-IB', v_matA, v_sup, 1000, 1000, 'kg', d) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'f79 price');

    -- ══════════ A. 边界:恰好等于阈值【不报】,多一点【报】═══════════════════
    -- 计划投 100,阈值 10% → 线在 110。先吃 110(恰好),再补到 111(过线)。
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100)),
        NULL, d, 'f79 open');
    woOpen := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woOpen);
    PERFORM commit_processing_run(d, 'f79 exactly at the line', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 110)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', woOpen);

    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'work_order_variance_beyond' AND item_id = woOpen;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 79A 失败:吃到【恰好等于】阈值(110 = 100 × 1.10)不该报,实得 % 行 —— 判据是 > 不是 >=', v_n;
    END IF;

    PERFORM commit_processing_run(d, 'f79 one over the line', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 1)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 1)), 'weight', woOpen);
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'work_order_variance_beyond' AND item_id = woOpen;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 79A 失败:吃到 111(过线一点点)应当报一行,实得 % 行', v_n;
    END IF;

    -- ══════════ B. 【投入超耗在放行中的单上就报】═══════════════════════════
    IF (SELECT status FROM work_orders WHERE id = woOpen) <> 'released' THEN
        RAISE EXCEPTION 'FIXTURE 79B 前提不成立:这张单应当还是 released';
    END IF;
    -- A 臂已经证明它在 released 上报了出来 —— 这一句把那个事实钉成断言:
    -- 超耗在它发生的那一刻就是可处理的事,不必等收工。
    IF NOT EXISTS (SELECT 1 FROM operations_now
                    WHERE item_type = 'work_order_variance_beyond' AND item_id = woOpen
                      AND subject LIKE 'input overrun%') THEN
        RAISE EXCEPTION 'FIXTURE 79B 失败:投入超耗应当在【放行中】的单上就报出来';
    END IF;

    -- ══════════ C. 【产出短交只在收工后报】═════════════════════════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ79-IB2', v_matA, v_sup, 1000, 1000, 'kg', d) RETURNING id INTO v_ib2;
    PERFORM reprice_inbound_batch(v_ib2, 1, 'SGD', NULL, 'f79 price');
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'expected_qty', 100)),
        d, 'f79 closed');
    woClosed := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woClosed);
    -- 吃 100(不超耗),产出 80(短交 20% > 10%)
    PERFORM commit_processing_run(d, 'f79 shortfall', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 80)), 'weight', woClosed);

    -- 【收工之前:不报】"少"在这时只是"还没做完"
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'work_order_variance_beyond' AND item_id = woClosed;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 79C 失败:收工【之前】的短交不该报 —— 那时它只是"还没做完",实得 % 行', v_n;
    END IF;

    PERFORM close_work_order(woClosed, 'f79:收工');
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'work_order_variance_beyond' AND item_id = woClosed
       AND subject LIKE 'output shortfall%';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 79C 失败:收工【之后】的短交应当报一行,实得 % 行', v_n;
    END IF;

    -- ══════════ D. 【没记录预期的行永远不报】═══════════════════════════════
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 10)),
        NULL, d, 'f79 no expectation');
    woNoExp := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woNoExp);
    PERFORM commit_processing_run(d, 'f79 noexp', 9,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 10)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 1)), 'weight', woNoExp);
    PERFORM close_work_order(woNoExp, 'f79:收工(没估过产出)');
    -- 产出 1、没有预期 —— 一个把"没估过"当零的实现会说它短交 100%
    IF EXISTS (SELECT 1 FROM operations_now
                WHERE item_type = 'work_order_variance_beyond' AND item_id = woNoExp
                  AND subject LIKE 'output shortfall%') THEN
        RAISE EXCEPTION 'FIXTURE 79D 失败:没记录过预期的产出不该报短交 —— 没估过不是估了零,一个 COALESCE(...,0) 会让每一次产出都成为短交 100%%';
    END IF;

    -- ══════════ E. 【被冲销的加工不算数】═══════════════════════════════════
    v_res := create_work_order(
        jsonb_build_array(jsonb_build_object('material_id', v_matA, 'planned_qty', 100)),
        NULL, d, 'f79 reversed');
    woRev := (v_res->>'work_order_id')::uuid;
    PERFORM release_work_order(woRev);
    v_run := commit_processing_run(d, 'f79 to be reversed', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 200)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 180)), 'weight', woRev);
    IF NOT EXISTS (SELECT 1 FROM operations_now
                    WHERE item_type = 'work_order_variance_beyond' AND item_id = woRev) THEN
        RAISE EXCEPTION 'FIXTURE 79E 前提不成立:吃掉 200 / 计划 100 应当先报出来';
    END IF;
    PERFORM rollback_processing_run(v_run);
    IF EXISTS (SELECT 1 FROM operations_now
                WHERE item_type = 'work_order_variance_beyond' AND item_id = woRev) THEN
        RAISE EXCEPTION 'FIXTURE 79E 失败:被冲销的加工不该把工单推过超耗线 —— 它的消耗不再是发生过的事实(WO-1b 的规则)';
    END IF;

    -- ══════════ F. 两个阈值【各管各的】,而且是现读的 ═══════════════════════
    -- 此刻:woOpen 报投入超耗(111/100),woClosed 报产出短交(80/100)。
    -- 把【投入】阈值调到 20% → 只有投入那一条该消失,产出那一条【原样还在】。
    UPDATE processing_settings SET wo_input_overrun_pct = 20;
    IF EXISTS (SELECT 1 FROM operations_now
                WHERE item_type = 'work_order_variance_beyond' AND item_id = woOpen) THEN
        RAISE EXCEPTION 'FIXTURE 79F 失败:投入阈值调到 20%% 之后,111/100 不该再报 —— 说明那个数不是从 processing_settings 读的';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM operations_now
                    WHERE item_type = 'work_order_variance_beyond' AND item_id = woClosed) THEN
        RAISE EXCEPTION 'FIXTURE 79F 失败:改【投入】阈值不该影响【产出】那一条 —— 两个数合成一个的实现在这里当场红';
    END IF;
    -- 反过来:投入调回 10、产出调到 30% → 投入那条回来,产出那条消失
    UPDATE processing_settings SET wo_input_overrun_pct = 10, wo_output_shortfall_pct = 30;
    IF NOT EXISTS (SELECT 1 FROM operations_now
                    WHERE item_type = 'work_order_variance_beyond' AND item_id = woOpen) THEN
        RAISE EXCEPTION 'FIXTURE 79F 失败:投入阈值调回 10%% 之后那一条应当回来(只验一个方向,恒空的实现也能蒙混过去)';
    END IF;
    IF EXISTS (SELECT 1 FROM operations_now
                WHERE item_type = 'work_order_variance_beyond' AND item_id = woClosed) THEN
        RAISE EXCEPTION 'FIXTURE 79F 失败:产出阈值调到 30%% 之后,80/100(短 20%%)不该再报';
    END IF;
    UPDATE processing_settings SET wo_output_shortfall_pct = 10;

    -- ══════════ G. 权限:别的模块看见的是【空】,不是报错 ═══════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type IN ('work_order_variance_beyond','work_order_overdue',
                         'qualification_expiring','qualification_missing');
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 79G 失败:只持 module.hr.view 的读者不该看见这四支,实得 % 行', v_n;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ 注入:把投入阈值换成写死的 10 ═══════════════════════════════
    -- 【这条判据没有第二层】表上没有任何东西阻止一张超耗的工单不出现在看板上。
    v_inj := regexp_replace(def_view,
        '\(\s*SELECT ps\.wo_input_overrun_pct\s+FROM processing_settings ps\s+LIMIT 1\)',
        '10', 'g');
    IF v_inj = def_view THEN
        RAISE EXCEPTION 'FIXTURE 79 注入 失败:在视图定义里没找到读【投入阈值】那段子查询 —— 这个注入什么也没删,下面那句"应当不再起作用"会变成空转';
    END IF;
    EXECUTE 'CREATE OR REPLACE VIEW public.operations_now AS ' || v_inj;
    UPDATE processing_settings SET wo_input_overrun_pct = 20;
    IF NOT EXISTS (SELECT 1 FROM operations_now
                    WHERE item_type = 'work_order_variance_beyond' AND item_id = woOpen) THEN
        RAISE EXCEPTION 'FIXTURE 79 注入 失败:把阈值换成写死的 10 之后,改配置应当【不再起作用】(111/100 应当仍然报)—— 走到这里说明 F 臂并没有被证明有牙';
    END IF;
END $$;
ROLLBACK;

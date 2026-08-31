-- 166 在制品看得见,而且【只被数一次】 —— PROC-WIRE-1B-ii(R3)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【它钉的第一件事:【没有】WIP 表】★ R3 说得很清楚:在制品不需要新对象。
-- purpose_code = 'process_feed' 的产出批**就是**在制品那一行(PROC-WIRE-1A 立的)。
-- 再建一张表,同一批料就会被数两遍,而两处迟早各说各话。
-- L2 直接对着 pg_class 断言:**没有任何一张叫 wip 的基表。**
-- 一份只断言"视图有几行"的 fixture 拦不住有人顺手加一张表。
--
-- 【每一臂钉什么】
-- L1 一批被指定的料出现在那块屏上,带着数量与它在等的工序。
-- L2 ★ 只被数一次:processing_wip 的行数 == 【非可售用途 + 还有余量】的产出批数,
--    而且**库里没有任何 WIP 基表**。
-- L3 ★ 在制品【不是】可售库存:卖它必须被第四条拒绝挡住。
--    这一臂把两条轴接起来 —— 屏幕上看得见的东西,与那道闸拦住的东西是同一批。
-- L4 释放指定 → 它离开那块屏,而且【那个指针被一并清掉】。
--    留着指针会造出"既可售、又在排队"的自相矛盾行。
-- L5 ★ 守卫:可售库存的批次上不许挂"在等哪一道"。
-- L6 被吃光的投料【不再在等】—— 而它的 state 仍然不是"已售罄"(两条轴不许合并)。
-- L7 ★ 判据读的是【字典那一列】,不是写死的 'process_feed' —— 加一种不可售用途,
--    那块屏自动跟着走。一个把码写死的实现在这里红。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_mat uuid; v_ob uuid; v_ob2 uuid; v_ob3 uuid;
    v_d date := DATE '2027-10-13';
    v_msg text; v_denied boolean; v_n int; v_expect int; v_op text; v_qty numeric;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-166', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ166-M', 'f162 cathode', 'battery_material', true, 'cathode_sheet', 'end_of_life')
    RETURNING id INTO v_mat;

    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ166-OB', v_mat, 100, 100, 'kg', v_d, '库存中') RETURNING id INTO v_ob;

    -- ══════════ L1 · 它出现在那块屏上,带着数量与它在等的工序 ══════════
    RAISE NOTICE 'fixture 166 · 进入 L1';
    -- 【先证明起点是空的】否则"它出现了"这句话没有内容。
    IF EXISTS (SELECT 1 FROM processing_wip WHERE output_batch_id = v_ob) THEN
        RAISE EXCEPTION 'FIXTURE 166L1 前置失败:还没指定,它就已经在那块屏上了 —— 后面每一句断言都是空的';
    END IF;
    PERFORM set_output_batch_purpose(v_ob, 'process_feed', 'electrode_powder_line');
    SELECT awaiting_operation_type_code, remaining_qty INTO v_op, v_qty
      FROM processing_wip WHERE output_batch_id = v_ob;
    IF v_op IS DISTINCT FROM 'electrode_powder_line' OR v_qty IS DISTINCT FROM 100 THEN
        RAISE EXCEPTION 'FIXTURE 166L1 失败:那块屏要回答【什么在等 · 多少 · 等哪一道】。实得 工序「%」数量「%」', COALESCE(v_op,'(空)'), COALESCE(v_qty::text,'(空)');
    END IF;

    -- ══════════ L2 · ★ 只被数一次,而且【没有】WIP 表 ★ ══════════
    RAISE NOTICE 'fixture 166 · 进入 L2';
    SELECT count(*) INTO v_n FROM processing_wip;
    SELECT count(*) INTO v_expect
      FROM output_batches ob JOIN output_batch_purposes p ON p.code = ob.purpose_code
     WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0 AND p.is_saleable_stock IS FALSE;
    IF v_n <> v_expect THEN
        RAISE EXCEPTION 'FIXTURE 166L2 失败:在制品是 output_batches 的一个【投影】,不是第二份台账。行数必须与"非可售用途 + 还有余量"的产出批数一致。实得 视图 % 行,应得 % 行', v_n, v_expect;
    END IF;
    -- ★【没有任何 WIP 基表】—— 一份只数视图行数的 fixture 拦不住有人顺手加一张表。
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
                WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relname LIKE '%wip%') THEN
        RAISE EXCEPTION 'FIXTURE 166L2 失败:**不许建 WIP 表。** 在制品那一行已经在 output_batches 里了(PROC-WIRE-1A 立的),再存一份就会把同一批料数两遍,而两处迟早各说各话。R3:在制品不需要新对象。';
    END IF;

    -- ══════════ L3 · ★ 在制品不是可售库存 ★ ══════════
    RAISE NOTICE 'fixture 166 · 进入 L3';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assert_output_batch_saleable(v_ob); EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 166L3 失败:屏幕上看得见的在制品,与那道闸拦住的东西必须是【同一批】。一批出现在在制品屏上、却又卖得掉的料,会被数两遍:一次算在制品,一次算可售库存。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ L5 · ★ 守卫:可售库存不许挂"在等哪一道" ══════════
    -- (排在 L4 之前:L4 要用释放这个动作,而这一臂证明释放【必须】清指针。)
    RAISE NOTICE 'fixture 166 · 进入 L5';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ166-OB2', v_mat, 50, 50, 'kg', v_d, '库存中') RETURNING id INTO v_ob2;
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE output_batches SET awaiting_operation_type_code = 'electrode_powder_line' WHERE id = v_ob2;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'WIP_AWAITING_ON_SALEABLE_BATCH|%' THEN
        RAISE EXCEPTION 'FIXTURE 166L5 失败:一批【可售库存】不会在等任何工序。留着这一列指向一道工序,会造出一个"既可售、又在排队"的自相矛盾行 —— 那正是 material_sources 那条列注说的"迟早会跟它的孪生兄弟打架的那一列"。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ L4 · 释放 → 离开那块屏,而且指针被清掉 ══════════
    RAISE NOTICE 'fixture 166 · 进入 L4';
    PERFORM set_output_batch_purpose(v_ob, 'saleable_stock');
    IF EXISTS (SELECT 1 FROM processing_wip WHERE output_batch_id = v_ob) THEN
        RAISE EXCEPTION 'FIXTURE 166L4 失败:释放了指定,它就不再是在制品';
    END IF;
    IF (SELECT awaiting_operation_type_code FROM output_batches WHERE id = v_ob) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 166L4 失败:**释放指定必须把那个指针一并清掉。** 留着它,下一次任何一句 UPDATE 都会撞上守卫,于是"释放"这个动作会莫名其妙地失败 —— 清掉是那扇门的责任,不是调用者要记得的一步。';
    END IF;

    -- ══════════ L6 · 吃光了就不再在等(而它【不是】已售罄) ══════════
    RAISE NOTICE 'fixture 166 · 进入 L6';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ166-OB3', v_mat, 30, 30, 'kg', v_d, '库存中') RETURNING id INTO v_ob3;
    PERFORM set_output_batch_purpose(v_ob3, 'process_feed', 'electrode_powder_line');
    IF NOT EXISTS (SELECT 1 FROM processing_wip WHERE output_batch_id = v_ob3) THEN
        RAISE EXCEPTION 'FIXTURE 166L6 前置失败:它得先在那块屏上,这一臂才有内容';
    END IF;
    UPDATE output_batches SET remaining_qty = 0 WHERE id = v_ob3;
    IF EXISTS (SELECT 1 FROM processing_wip WHERE output_batch_id = v_ob3) THEN
        RAISE EXCEPTION 'FIXTURE 166L6 失败:被工序吃光的投料不再"在等"';
    END IF;
    IF (SELECT state FROM output_batches WHERE id = v_ob3) = '已售罄' THEN
        RAISE EXCEPTION 'FIXTURE 166L6 失败:**吃光【不是】已售罄。** 两条轴合并就必须凭空造一个销售取值,那会认下一笔从来没发生过的收入(PROC-WIRE-1A 的原话)。';
    END IF;

    -- ══════════ L7 · ★ 判据读的是【字典那一列】,不是写死的码 ══════════
    RAISE NOTICE 'fixture 166 · 进入 L7';
    INSERT INTO output_batch_purposes (code, name_en, name_zh, is_saleable_stock, sort_order, notes)
    VALUES ('zz166_hold', 'f162 hold', 'f162 暂存', false, 99, 'fixture 166 L7');
    PERFORM set_output_batch_purpose(v_ob2, 'zz166_hold');
    IF NOT EXISTS (SELECT 1 FROM processing_wip WHERE output_batch_id = v_ob2) THEN
        RAISE EXCEPTION 'FIXTURE 166L7 失败:那块屏读的是 output_batch_purposes.is_saleable_stock 那一列,不是写死的 process_feed —— 加一种不可售用途,它必须自动跟着走。一个把码写死的实现在这里红。';
    END IF;
END $$;
ROLLBACK;

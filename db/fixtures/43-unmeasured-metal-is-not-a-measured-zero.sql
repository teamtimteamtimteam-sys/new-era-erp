-- 43 回收率:【根本没测】与【测出来是零】分得开;守恒只在两侧都测过时才说话
--
-- 【判别臂是 A/B 的对照】同一个位置的"0",一边是没测(NULL,界面印"未测"),
-- 一边是化验测得含量为零(0,界面照印 0)。只测其中一种的 fixture,对一个
-- 仍在 COALESCE(...,0) 的实现照样全绿 —— 而那正是走查撞见的实现:
-- PROC-2026-0164 的钴投入印着 0,读起来像无中生有,其实那个金属从没被测过。
-- 注入方式:把视图里的 i.input_metal_kg 改回 COALESCE(i.input_metal_kg, 0),
-- A 臂即红并指出"未测被说成了 0"。
--
-- 【C:守恒提示只在两侧都测过时才为真】没测过的投入没有可守恒的对象 ——
-- 对它报警等于把测量缺口说成异常,而那正是 Tim 否掉的方向。
-- 【D:整单无从计算】投入侧从未化验的单子,要能对整单说出这句话(界面据此出横幅),
-- 而不是摆一桌 0 和横杠。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_mat uuid; v_sup uuid;
    ib_zero uuid; ib_none uuid; ib_rich uuid;
    ob_a uuid; ob_b uuid; ob_bare uuid;
    run_zero uuid; run_none uuid; run_cons uuid; run_outmiss uuid;
    v_row record; v_n int;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-43', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['module.processing.view','module.processing.edit',
                           'module.inbound.view','module.output.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX43-M', 'fixture 43 material', 'battery_material', true) RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX43-S', 'fixture 43 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;

    -- 三个投入批:① 化验【测了 co,含量 0】 ② 一个金属都没测 ③ co 20%(守恒臂用)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX43-IB-ZERO', v_mat, v_sup, 100, 100, CURRENT_DATE) RETURNING id INTO ib_zero;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (ib_zero, 'co', 0, 'manual');          -- 【测出来是零】—— 一行真实存在的化验行

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX43-IB-NONE', v_mat, v_sup, 100, 100, CURRENT_DATE) RETURNING id INTO ib_none;
    -- 【根本没测】—— 故意不插任何 inbound_batch_metals 行

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX43-IB-RICH', v_mat, v_sup, 100, 100, CURRENT_DATE) RETURNING id INTO ib_rich;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (ib_rich, 'co', 20, 'manual');         -- 20 kg co 投入

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. 投入【测出来是零】而产出有量 → 0(不是"未测"),且是真异常 ═══
    -- 【产出含量是提交【之后】才录的】—— 函数自己建产出批,人再回头补含量。
    -- 这正是元素守恒当不成提交时硬闸的第二条结构性理由,fixture 照着真实次序走。
    run_zero := commit_processing_run(CURRENT_DATE, 'fixture 43 zero-input', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_zero, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 50)), 'weight');
    SELECT po.output_batch_id INTO ob_a FROM processing_outputs po WHERE po.run_id = run_zero;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob_a, 'co', 10, 'manual');

    SELECT * INTO v_row FROM processing_metal_recovery
     WHERE run_id = run_zero AND metal = 'co';
    IF NOT v_row.input_measured THEN
        RAISE EXCEPTION 'FIXTURE 43A 失败:投入侧【有一行化验记着 co = 0%%】,应当算"测过",实得未测 —— 把"测出来是零"说成"没测",与反过来说一样错';
    END IF;
    IF v_row.input_metal_kg <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 43A 失败:测得含量为零的投入应为 0 kg,实得 %', v_row.input_metal_kg;
    END IF;
    IF v_row.recovery_blocked_by <> 'input_measured_zero' THEN
        RAISE EXCEPTION 'FIXTURE 43A 失败:算不出的原因应是 input_measured_zero(测过、就是没有),实得 % —— 原因说错,界面就会劝人去做一件没用的事',
            COALESCE(v_row.recovery_blocked_by, '(空)');
    END IF;
    IF NOT v_row.conservation_warning THEN
        RAISE EXCEPTION 'FIXTURE 43A 失败:投入测得为零而产出 5 kg,两侧都测过 —— 这正是"无中生有",守恒提示必须亮';
    END IF;

    -- ══════════ B. 投入【根本没测】→ NULL,且【不】报守恒 ═══════════════════════
    run_none := commit_processing_run(CURRENT_DATE, 'fixture 43 unassayed input', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_none, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 50)), 'weight');
    SELECT po.output_batch_id INTO ob_b FROM processing_outputs po WHERE po.run_id = run_none;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob_b, 'co', 10, 'manual');

    SELECT * INTO v_row FROM processing_metal_recovery
     WHERE run_id = run_none AND metal = 'co';
    IF v_row.input_measured OR v_row.input_metal_kg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 43B 失败:投入侧从未测过 co,应为 NULL/未测,实得 measured=% kg=% —— 压成 0 就是把"没测"说成"测了是零",两者导向相反的结论',
            v_row.input_measured, v_row.input_metal_kg;
    END IF;
    IF v_row.recovery_blocked_by <> 'input_not_measured' THEN
        RAISE EXCEPTION 'FIXTURE 43B 失败:算不出的原因应是 input_not_measured,实得 %', COALESCE(v_row.recovery_blocked_by, '(空)');
    END IF;
    IF v_row.conservation_warning THEN
        RAISE EXCEPTION 'FIXTURE 43B 失败:投入没测过就没有可守恒的对象,守恒提示【不许】亮 —— 那会把测量缺口说成异常,正是被否掉的方向';
    END IF;

    -- ══════════ C. 两侧都测过、产出 > 投入 → 守恒提示亮 ═══════════════════════
    -- 投入 100 kg × 20% = 20 kg co;产出 50 kg × 60% = 30 kg co → 多出来 10 kg
    run_cons := commit_processing_run(CURRENT_DATE, 'fixture 43 conservation', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_rich, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 50)), 'weight');
    SELECT po.output_batch_id INTO ob_bare FROM processing_outputs po WHERE po.run_id = run_cons;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob_bare, 'co', 60, 'manual');

    SELECT * INTO v_row FROM processing_metal_recovery
     WHERE run_id = run_cons AND metal = 'co';
    IF v_row.input_metal_kg <> 20 OR v_row.output_metal_kg <> 30 THEN
        RAISE EXCEPTION 'FIXTURE 43C 前置失败:应为 投入 20 kg / 产出 30 kg,实得 % / %',
            v_row.input_metal_kg, v_row.output_metal_kg;
    END IF;
    IF NOT v_row.conservation_warning THEN
        RAISE EXCEPTION 'FIXTURE 43C 失败:两侧都测过且产出(30)> 投入(20),守恒提示必须亮 —— 投错批/产出录错/污染都是这个形状';
    END IF;
    IF v_row.recovery_pct <> 150.00 THEN
        RAISE EXCEPTION 'FIXTURE 43C 失败:回收率应为 150.00%%(30/20),实得 % —— 提示归提示,数照算',
            COALESCE(v_row.recovery_pct::text, '(空)');
    END IF;
    -- 【提示不是闸】:上面这单是【提交成功了的】—— 若哪天有人把它做成硬拦截,
    -- 这一句会先红。产出含量本来就是提交之后才录的,拦不住也不该拦。
    IF NOT EXISTS (SELECT 1 FROM processing_runs WHERE id = run_cons AND status = 'committed') THEN
        RAISE EXCEPTION 'FIXTURE 43C 失败:守恒只是提示,这一单必须提交成功 —— 变成硬闸就会把正当作业挡在门外';
    END IF;

    -- ══════════ D. 整单无从计算:投入从未化验的单子要说得出这件事 ═══════════════
    SELECT bool_and(NOT run_recovery_computable) INTO v_row.input_measured
    FROM processing_metal_recovery WHERE run_id = run_none;
    IF NOT v_row.input_measured THEN
        RAISE EXCEPTION 'FIXTURE 43D 失败:投入侧从未化验的单子,run_recovery_computable 应为 false —— 界面靠它对整单说"回收率无从计算",而不是摆一桌 0 与横杠';
    END IF;
    SELECT count(*) INTO v_n FROM processing_metal_recovery
     WHERE run_id = run_cons AND run_recovery_computable;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 43D 失败:两侧都测过的单子应当是"算得出"的,实得 false —— 否则每张单都会挂上那条横幅,等于没有横幅';
    END IF;

    -- ══════════ E. 产出侧未测:同样是"未测"而不是 0(产出侧更常见 —— 13 个产出批
    --              只有 4 个录了含量)═══════════════════════════════════════════
    SELECT * INTO v_row FROM processing_metal_recovery
     WHERE run_id = run_zero AND metal = 'co';
    IF NOT v_row.output_measured THEN
        RAISE EXCEPTION 'FIXTURE 43E 前置失败:本单产出录了 co,应算测过';
    END IF;
    -- 造一单:投入测了、产出批一个金属都没录
    DECLARE ob_empty uuid; run_e uuid;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
        VALUES ('ZZFIX43-IB-E', v_mat, v_sup, 100, 100, CURRENT_DATE) RETURNING id INTO ib_rich;
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (ib_rich, 'ni', 30, 'manual');
        -- 产出批照常建出来,但【一个金属都不录】—— 线上 13 个产出批只有 4 个录了
        run_e := commit_processing_run(CURRENT_DATE, 'fixture 43 output unmeasured', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_rich, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 40)), 'weight');
        SELECT po.output_batch_id INTO ob_empty FROM processing_outputs po WHERE po.run_id = run_e;
        SELECT * INTO v_row FROM processing_metal_recovery WHERE run_id = run_e AND metal = 'ni';
        IF v_row.output_measured OR v_row.output_metal_kg IS NOT NULL THEN
            RAISE EXCEPTION 'FIXTURE 43E 失败:产出批没录任何金属含量,产出侧应为未测/NULL,实得 measured=% kg=% —— 印成 0 会被读成"一点都没回收出来"',
                v_row.output_measured, v_row.output_metal_kg;
        END IF;
        IF v_row.recovery_blocked_by <> 'output_not_measured' THEN
            RAISE EXCEPTION 'FIXTURE 43E 失败:原因应是 output_not_measured(录一下产出含量就能补齐),实得 %',
                COALESCE(v_row.recovery_blocked_by, '(空)');
        END IF;
    END;
END $$;
ROLLBACK;

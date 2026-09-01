-- 54 产出化验:记录共享、应用拆开、过期看得见、守恒永远只是提示
--
-- 【D 臂是这份 fixture 的要点】一个"含量抄对了、但忘了让过期机制看见"的实现,
-- 能通过这里除 D 之外的每一条断言:单据建了、编号连续、含量带出处落地、
-- 应付一分没动、取代链成立。而它留下的东西恰恰是 PROC-1 要关掉的缺口:
-- metal_value 按产出金属含量拆成本,"先分摊、后应用化验"是正常次序 ——
-- 忘了举旗,拆分就永远停在化验之前的那份含量上,毫无信号。
-- D 臂两个方向都钉:metal_value 的单必须过期(D1),weight 的单必须【不】过期
-- (D2)—— 无条件举旗是喊狼来了,和忘了举旗一样通不过这两条。
--
-- 其余各臂:
--   A 记录与编号共享:进料化验与产出化验落同一张表、同一条 ASY 序列(连号);
--     双父 XOR 点名拒;权限跟着父走(只有 inbound 权限的人记不了产出化验)。
--   B 应用拆开:apply_assay_result 拒产出化验(ASSAY_IS_OUTPUT),
--     apply_output_assay 拒进料化验(ASSAY_IS_INBOUND)—— 各自点名指路。
--   C 产出化验的应用只抄含量:行带出处(assay + 单据 id),不产生任何分录,
--     不动任何单位成本 —— 产出批没有一张应付可以重述。
--   E 取代链按父各自成链:产出链上后应用取代先应用,进料链不受扰;
--     撤销只许撤最新一环;撤销不回含量(与进料侧同一条纪律)。
--   F 回收率视图每侧说出自己除的是哪一种数:assay / manual / mixed。
--   G 守恒永远只是提示:一份把产出测得远大于投入的化验【照常落账】,
--     视图举 conservation_warning —— 拦下一张真实验室单据等于替实验室改数,
--     压掉的恰恰是"有什么不对"的证据。
--   H 出处的一致性由约束把门:assay 必须指得出单据,manual 不许指;
--     进料新行必须声明出处(NOT VALID:老行放过,新行必填 —— FIN-32 的形状)。
--   I 试算与应用同构(PROC-1b,fixture 40 的纪律):preview_apply_output_assay
--     在应用会拒的地方【同码】拒;它说"会过期"的地方 D1 断言视图真的过期,
--     说"不会"的地方(weight)D2 断言它真的不动 —— 谓词与第六过期源钉在一起。
--
-- 化验日期用 CURRENT_DATE(record_assay_result 拒未来日期);编号断言只断
-- 【连续】与【同前缀】,不断绝对值 —— 序列起点取决于库里已有的化验数。
-- 其余日期同样落在 CURRENT_DATE,锁与 system_start 显式自设(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    u1 uuid := gen_random_uuid();      -- 全权限
    u2 uuid := gen_random_uuid();      -- 只有 inbound 权限 —— A 臂的权限探针
    r1 uuid; r2 uuid;
    v_sup uuid; v_mat uuid;
    ib1 uuid; ib2 uuid;
    run1 uuid; run2 uuid;
    ob_a uuid; ob_b uuid; ob_c uuid;
    a1 jsonb; a2 jsonb; a3 jsonb; a4 jsonb; v_rep jsonb; v_prev jsonb;
    a1_id uuid; a2_id uuid; a3_id uuid; a4_id uuid;
    v_seq1 int; v_seq2 int;
    v_n int; v_je0 bigint; v_je1 bigint;
    v_cost_a numeric; v_cost_a2 numeric;
    v_stale boolean; v_warn boolean;
    v_in_src text; v_out_src text;
    v_in_kg numeric; v_out_kg numeric;
    v_denied boolean; v_msg text;
    v_row record;
BEGIN
    -- PROC-5:实验室现在是一张字典(laboratories),lab_name 指向它。
    -- 【自带数据的另一面:自带字典行】本支要用一个自己的实验室名,
    -- 那就自己加那一行 —— 而"加一行就能用"正是把它做成字典换来的东西。
    INSERT INTO laboratories (code, name_en, name_zh, sort_order)
    VALUES ('fixture 54 lab', 'fixture 54 lab', 'fixture 54 lab', 99);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = '2020-01-01';

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-54', 'f', 'f', true) RETURNING id INTO r1;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r1, unnest(ARRAY['module.processing.edit','module.processing.view',
                            'module.inbound.edit','module.inbound.view',
                            'module.output.edit','module.output.view',
                            'module.finance.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u1, r1);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-54-inbound-only', 'f', 'f', true) RETURNING id INTO r2;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r2, unnest(ARRAY['module.inbound.edit','module.inbound.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u2, r2);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZFIX54-S', 'fixture 54 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX54-M', 'fixture 54 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, pricing_status)
    VALUES ('ZZFIX54-IB1', v_mat, v_sup, 100, 100, CURRENT_DATE, 10, 'final')
    RETURNING id INTO ib1;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, pricing_status)
    VALUES ('ZZFIX54-IB2', v_mat, v_sup, 100, 100, CURRENT_DATE, 10, 'final')
    RETURNING id INTO ib2;

    -- metal_value 基准要金属行情;插得足够早,spot 的"就近向前取"覆盖任何参考日
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 20000, '2020-01-01', 'broker_quote');

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u1), true);

    -- run1:metal_value —— D1 的主角。两个产出各 20 kg,含量先手工挂(80 / 10),
    -- 分摊在化验之前 —— 这正是"正常次序"。
    -- PROC-3:这一支要投料,所以它的电池料批次得带一条【可投料】的安全状态。
    -- 【为什么是一条带 JOIN 的 SELECT,而不是逐个批次写死】本支里哪些批次【吃】
    -- 状态轴,由 material_kinds 回答 —— 实测 ewaste 可加工却【没有】状态轴,
    -- 所以"可加工"并不蕴含"有状态轴"。而没有状态轴的批次插安全状态会被
    -- PROC-2c 的适用性守卫按名拒,所以这个过滤不是优化,是正确性。
    -- 【它出现在每一次投料之前,而不是只在开头一次】批次是各臂【边跑边造】的,
    -- 开头那一次覆盖不到后面才出生的批次。NOT EXISTS 让它重复执行也不撞主键。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    run1 := commit_processing_run(CURRENT_DATE, 'fixture 54 run1', 60,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib1, 'quantity_consumed', 100)),
        jsonb_build_array(
            jsonb_build_object('material_id', v_mat, 'quantity', 20, 'unit', 'kg'),
            jsonb_build_object('material_id', v_mat, 'quantity', 20, 'unit', 'kg')),
        'metal_value', NULL, NULL, 'manual_disassembly');
    SELECT po.output_batch_id INTO ob_a FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = run1 ORDER BY ob.code LIMIT 1;
    SELECT po.output_batch_id INTO ob_b FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = run1 ORDER BY ob.code DESC LIMIT 1;
    IF ob_a = ob_b THEN
        RAISE EXCEPTION 'FIXTURE 54 前置失败:run1 的两个产出批取成了同一个';
    END IF;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source)
    VALUES (ob_a, 'ni', 80, 'manual'), (ob_b, 'ni', 10, 'manual');
    PERFORM allocate_processing_costs(run1, 'metal_value');

    -- run2:weight —— D2 与 G 的主角。投入手工测得 ni 10%(10 kg),产出 50 kg。
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source)
    VALUES (ib2, 'ni', 10, 'manual');
    -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    run2 := commit_processing_run(CURRENT_DATE, 'fixture 54 run2', 50,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', ib2, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 50, 'unit', 'kg')),
        'weight', NULL, NULL, 'manual_disassembly');
    SELECT po.output_batch_id INTO ob_c FROM processing_outputs po
     WHERE po.run_id = run2 LIMIT 1;
    PERFORM allocate_processing_costs(run2, 'weight');

    -- ══════════ A. 记录与编号共享;双父 XOR;权限跟着父走 ═══════════════════
    a1 := record_assay_result(p_assay_date => CURRENT_DATE,
        p_metals => jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 50)),
        p_lab_name => 'fixture 54 lab', p_inbound_batch_id => ib1, p_weight_basis => 'as_received', p_result_party => 'ours');
    a1_id := (a1->>'assay_result_id')::uuid;
    a2 := record_assay_result(p_assay_date => CURRENT_DATE,
        p_metals => jsonb_build_array(
            jsonb_build_object('metal', 'ni', 'content_pct', 75),
            jsonb_build_object('metal', 'co', 'content_pct', 5)),
        p_lab_name => 'fixture 54 lab', p_output_batch_id => ob_a, p_weight_basis => 'as_received', p_result_party => 'ours');
    a2_id := (a2->>'assay_result_id')::uuid;

    -- 同一条序列:紧随其后、同一个 'ASY-YYYY' 前缀。绝对值不断(取决于库里已有几份)。
    v_seq1 := split_part(a1->>'code', '-', 3)::int;
    v_seq2 := split_part(a2->>'code', '-', 3)::int;
    IF v_seq2 <> v_seq1 + 1
       OR split_part(a1->>'code', '-', 2) <> split_part(a2->>'code', '-', 2) THEN
        RAISE EXCEPTION 'FIXTURE 54A 失败:进料与产出化验没有共用一条编号序列(% vs %)——"记录共享"的那一半丢了',
            a1->>'code', a2->>'code';
    END IF;

    v_denied := false;
    BEGIN
        PERFORM record_assay_result(p_assay_date => CURRENT_DATE,
            p_metals => jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 1)),
            p_inbound_batch_id => ib1, p_output_batch_id => ob_a, p_weight_basis => 'as_received', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_ONE_PARENT' THEN
        RAISE EXCEPTION 'FIXTURE 54A 失败:两个父都挂的化验该被点名拒(ASSAY_ONE_PARENT),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;
    v_denied := false;
    BEGIN
        PERFORM record_assay_result(p_assay_date => CURRENT_DATE,
            p_metals => jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 1)), p_weight_basis => 'as_received', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_ONE_PARENT' THEN
        RAISE EXCEPTION 'FIXTURE 54A 失败:一个父都不挂的化验该被点名拒(ASSAY_ONE_PARENT),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;

    -- 权限探针:只有 inbound 权限的人,记产出化验要被拒 —— 权限跟着父走,
    -- 不跟着"化验功能建在哪个目录"。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u2), true);
    v_denied := false;
    BEGIN
        PERFORM record_assay_result(p_assay_date => CURRENT_DATE,
            p_metals => jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 1)),
            p_output_batch_id => ob_a, p_weight_basis => 'as_received', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'PERMISSION_DENIED|module.output.edit' THEN
        RAISE EXCEPTION 'FIXTURE 54A 失败:只有 inbound 权限的人记产出化验,该按 module.output.edit 拒,实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u1), true);

    -- ══════════ B. 应用拆开,各自点名指路 ═══════════════════════════════════
    v_denied := false;
    BEGIN
        PERFORM apply_assay_result(a2_id);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_IS_OUTPUT|' || (a2->>'code') THEN
        RAISE EXCEPTION 'FIXTURE 54B 失败:apply_assay_result 收产出化验该点名拒(ASSAY_IS_OUTPUT),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 应付被一份产出化验重述了' END;
    END IF;
    v_denied := false;
    BEGIN
        PERFORM apply_output_assay(a1_id);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_IS_INBOUND|' || (a1->>'code') THEN
        RAISE EXCEPTION 'FIXTURE 54B 失败:apply_output_assay 收进料化验该点名拒(ASSAY_IS_INBOUND),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 进料化验绕过了重算应付的那一半' END;
    END IF;

    -- I(其一):试算在应用会拒的地方【同码】拒 —— 进料化验、挂错批次
    v_denied := false;
    BEGIN
        PERFORM preview_apply_output_assay(ob_a, a1_id);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_IS_INBOUND|' || (a1->>'code') THEN
        RAISE EXCEPTION 'FIXTURE 54I 失败:试算收进料化验该与应用同码拒(ASSAY_IS_INBOUND),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;
    v_denied := false;
    BEGIN
        PERFORM preview_apply_output_assay(ob_b, a2_id);   -- a2 挂在 ob_a 上
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_NOT_FOUND|' || (a2->>'code') THEN
        RAISE EXCEPTION 'FIXTURE 54I 失败:试算收挂在别批上的化验该拒(ASSAY_NOT_FOUND),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了 —— 一份化验被预览到了别的批次头上' END;
    END IF;

    -- ══════════ C+D1. 产出化验的应用:抄含量带出处、不动钱、【让过期看得见】════
    -- 先应用进料化验(ib1 无公式 → 只抄含量,不触发重计价,不污染过期源),
    -- 这也给 F 臂备好"投入侧 = assay"。
    PERFORM apply_assay_result(a1_id);
    SELECT count(*) INTO v_n FROM inbound_batch_metals
     WHERE inbound_batch_id = ib1 AND content_source = 'assay' AND source_assay_id = a1_id;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 54C 失败:进料化验应用后,批次含量行该带出处 assay+单据 id,实际 % 行', v_n;
    END IF;

    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = run1;
    IF v_stale THEN
        RAISE EXCEPTION 'FIXTURE 54D 前置失败:run1 在产出化验之前就已过期 —— D1 会因错的理由通过';
    END IF;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    SELECT po.unit_cost_base INTO v_cost_a FROM processing_outputs po WHERE po.output_batch_id = ob_a;

    -- I(其二):按下"应用"之前,试算说清"换成什么、什么会过期" ——
    -- 换的两侧都齐(当前 1 行手工 ni 80 → 化验 2 行),过期谓词指名 run1
    v_prev := preview_apply_output_assay(ob_a, a2_id);
    IF jsonb_array_length(v_prev->'current_metals') <> 1
       OR (v_prev->'current_metals'->0->>'content_source') <> 'manual'
       OR jsonb_array_length(v_prev->'assay_metals') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 54I 失败:试算没把"当前(手工 1 行)→ 化验后(2 行)"两侧摆齐:%', v_prev;
    END IF;
    IF NOT (v_prev->>'will_flag_stale')::boolean
       OR (v_prev->>'producing_run_code') <> (SELECT code FROM processing_runs WHERE id = run1) THEN
        RAISE EXCEPTION 'FIXTURE 54I 失败:metal_value 已分摊的单,试算该在应用【之前】点名说"会过期":%', v_prev;
    END IF;
    -- 不带 assay id 的形态(录入页):批次的过期后果与当前含量照答
    v_prev := preview_apply_output_assay(ob_a);
    IF NOT (v_prev->>'will_flag_stale')::boolean OR v_prev->'assay_metals' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 54I 失败:不带化验 id 的试算(录入页形态)该只答批次侧:%', v_prev;
    END IF;

    v_rep := apply_output_assay(a2_id);

    SELECT count(*) INTO v_n FROM output_batch_metals
     WHERE output_batch_id = ob_a AND content_source = 'assay' AND source_assay_id = a2_id;
    IF v_n <> 2 OR (SELECT count(*) FROM output_batch_metals WHERE output_batch_id = ob_a) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 54C 失败:产出批含量该整体换成本化验的 2 行(assay + 单据 id),实际共 % 行、带出处 % 行',
            (SELECT count(*) FROM output_batch_metals WHERE output_batch_id = ob_a), v_n;
    END IF;
    IF (SELECT content_pct FROM output_batch_metals WHERE output_batch_id = ob_a AND metal = 'ni') <> 75 THEN
        RAISE EXCEPTION 'FIXTURE 54C 失败:ni 含量该是化验说的 75';
    END IF;
    IF (SELECT content_source FROM output_batch_metals WHERE output_batch_id = ob_b AND metal = 'ni') <> 'manual' THEN
        RAISE EXCEPTION 'FIXTURE 54C 失败:没被化验的邻批 ob_b 的含量出处被动了';
    END IF;
    SELECT count(*) INTO v_je1 FROM journal_entries;
    SELECT po.unit_cost_base INTO v_cost_a2 FROM processing_outputs po WHERE po.output_batch_id = ob_a;
    IF v_je1 <> v_je0 OR v_cost_a2 IS DISTINCT FROM v_cost_a THEN
        RAISE EXCEPTION 'FIXTURE 54C 失败:产出化验的应用动了钱(分录 %→%,单位成本 %→%)—— 产出批没有应付可重述,金额只能由显式重跑分摊来动',
            v_je0, v_je1, v_cost_a, v_cost_a2;
    END IF;

    -- D1:metal_value 的单必须过期 —— 抄对含量但忘了举旗的实现,死在这一条。
    -- 分摊与化验各自成交易,时间戳自然有先后;now() 是事务时间,这里把
    -- allocated_at 拨早一秒还原那个先后(fixture 18 的同一句)。判别力不受影响:
    -- run1 没有成本条目、没有运费、没有重定价、没有上游重分摊、没改过基准 ——
    -- 它的 last_cost_change 【只可能】来自产出含量这一支,少了第六源就是 NULL。
    UPDATE processing_runs SET allocated_at = allocated_at - interval '1 second' WHERE id = run1;
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = run1;
    IF NOT v_stale THEN
        RAISE EXCEPTION 'FIXTURE 54D1 失败:metal_value 的单在产出化验应用后不过期 —— 拆分停在化验之前的含量上,而没有任何信号(第六过期源丢了)';
    END IF;
    IF NOT (v_rep->>'allocation_now_stale')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 54D1 失败:apply_output_assay 的回执没说清分摊已过期';
    END IF;

    -- ══════════ D2+G. weight 不举旗;守恒永远只是提示 ═══════════════════════
    -- 同 D1 的一秒:先拨早,再化验 —— 于是无条件举旗的实现在这里现形。
    UPDATE processing_runs SET allocated_at = allocated_at - interval '1 second' WHERE id = run2;
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = run2;
    IF v_stale THEN
        RAISE EXCEPTION 'FIXTURE 54D2 前置失败:run2 已过期,D2 无从判别';
    END IF;
    -- ni 80% × 50 kg = 40 kg 产出,而投入只测得 10 kg —— 守恒破了,但这是一次
    -- 【测量】:拒绝落账等于替实验室改数,压掉的正是"有什么不对"的证据。
    a3 := record_assay_result(p_assay_date => CURRENT_DATE,
        p_metals => jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 80)),
        p_lab_name => 'fixture 54 lab', p_output_batch_id => ob_c, p_weight_basis => 'as_received', p_result_party => 'ours');
    a3_id := (a3->>'assay_result_id')::uuid;
    -- I(其三):weight 的单,试算说"不会过期" —— 与 D2 是同一条谓词的两个观察点
    v_prev := preview_apply_output_assay(ob_c, a3_id);
    IF (v_prev->>'will_flag_stale')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 54I 失败:weight 的单试算却说"会过期" —— 喊狼来了的那一半回来了:%', v_prev;
    END IF;
    v_rep := apply_output_assay(a3_id);   -- 必须成功 —— 守恒不是闸
    SELECT conservation_warning, input_metal_kg, output_metal_kg, input_source, output_source
      INTO v_warn, v_in_kg, v_out_kg, v_in_src, v_out_src
      FROM processing_metal_recovery WHERE run_id = run2 AND metal = 'ni';
    IF NOT v_warn OR v_in_kg <> 10 OR v_out_kg <> 40 THEN
        RAISE EXCEPTION 'FIXTURE 54G 失败:产出(%)大于投入(%)时 conservation_warning 该举而未举(%)—— 或两侧数字不对',
            v_out_kg, v_in_kg, v_warn;
    END IF;
    IF v_in_src <> 'manual' OR v_out_src <> 'assay' THEN
        RAISE EXCEPTION 'FIXTURE 54G 失败:这次警告该读作「实验室 vs 手敲」(manual/assay),实际 %/% —— 出处列没说实话',
            v_in_src, v_out_src;
    END IF;
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = run2;
    IF v_stale THEN
        RAISE EXCEPTION 'FIXTURE 54D2 失败:weight 的单因产出含量变动被标过期 —— weight 拆分不读含量,无条件举旗是喊狼来了';
    END IF;

    -- ══════════ E. 取代链按父;撤销只撤最新、不回含量 ═══════════════════════
    v_denied := false;
    BEGIN
        PERFORM apply_output_assay(a2_id);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_ALREADY_APPLIED|' || (a2->>'code') THEN
        RAISE EXCEPTION 'FIXTURE 54E 失败:重复应用该被拒(ASSAY_ALREADY_APPLIED),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;
    -- I(其四):已应用的化验,试算与应用同码拒
    v_denied := false;
    BEGIN
        PERFORM preview_apply_output_assay(ob_a, a2_id);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'ASSAY_ALREADY_APPLIED|' || (a2->>'code') THEN
        RAISE EXCEPTION 'FIXTURE 54I 失败:已应用化验的试算该与应用同码拒(ASSAY_ALREADY_APPLIED),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;

    a4 := record_assay_result(p_assay_date => CURRENT_DATE,
        p_metals => jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 70)),
        p_lab_name => 'fixture 54 lab', p_output_batch_id => ob_a, p_weight_basis => 'as_received', p_result_party => 'ours');
    a4_id := (a4->>'assay_result_id')::uuid;
    PERFORM apply_output_assay(a4_id);

    IF (SELECT superseded_by FROM assay_results WHERE id = a2_id) IS DISTINCT FROM a4_id THEN
        RAISE EXCEPTION 'FIXTURE 54E 失败:同一产出批上后应用的化验该取代先应用的';
    END IF;
    IF (SELECT superseded_by FROM assay_results WHERE id = a1_id) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 54E 失败:进料链被产出链搅了 —— 取代链必须按父各自成链';
    END IF;
    IF (SELECT count(*) FROM output_batch_metals WHERE output_batch_id = ob_a) <> 1
       OR (SELECT content_pct FROM output_batch_metals WHERE output_batch_id = ob_a AND metal = 'ni') <> 70 THEN
        RAISE EXCEPTION 'FIXTURE 54E 失败:第二份化验只报了 ni=70,批次含量该整体换成这一行(化验是完整陈述,不是差量)';
    END IF;

    v_denied := false;
    BEGIN
        PERFORM unapply_assay_result(a2_id, 'fixture 54: not latest');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'NOT_LATEST_ASSAY|' || (a2->>'code') THEN
        RAISE EXCEPTION 'FIXTURE 54E 失败:撤销链条中间一环该被拒(NOT_LATEST_ASSAY),实际:%',
            CASE WHEN v_denied THEN v_msg ELSE '成功了' END;
    END IF;
    PERFORM unapply_assay_result(a4_id, 'fixture 54: retest disputed');
    IF (SELECT applied_at FROM assay_results WHERE id = a4_id) IS NOT NULL
       OR (SELECT superseded_by FROM assay_results WHERE id = a2_id) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 54E 失败:撤销后 applied 标记该清、上一环的取代该解开';
    END IF;
    IF (SELECT content_pct FROM output_batch_metals WHERE output_batch_id = ob_a AND metal = 'ni') <> 70 THEN
        RAISE EXCEPTION 'FIXTURE 54E 失败:撤销回滚了含量 —— 撤销只是承认这份结果不再作数,含量退到哪一版是新化验或手工格子的显式动作(与进料侧同一条纪律)';
    END IF;

    -- ══════════ F. 回收率视图:每侧说出自己除的是哪一种数 ═══════════════════
    -- run1 × ni:投入侧 ib1 全部来自化验 → assay;产出侧 ob_a(化验 70)+
    -- ob_b(手工 10)混着 → mixed。
    SELECT input_source, output_source INTO v_in_src, v_out_src
      FROM processing_metal_recovery WHERE run_id = run1 AND metal = 'ni';
    IF v_in_src <> 'assay' OR v_out_src <> 'mixed' THEN
        RAISE EXCEPTION 'FIXTURE 54F 失败:run1 × ni 该读作 assay / mixed,实际 % / %', v_in_src, v_out_src;
    END IF;

    -- ══════════ H. 出处的一致性由约束把门 ═══════════════════════════════════
    v_denied := false;
    BEGIN
        INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source)
        VALUES (ob_b, 'co', 5, 'assay');    -- assay 却指不出单据
    EXCEPTION WHEN check_violation THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 54H 失败:content_source=assay 而 source_assay_id 为空的行落进去了 —— 一个指不出单据的"化验出处"就是伪造';
    END IF;
    v_denied := false;
    BEGIN
        INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source, source_assay_id)
        VALUES (ob_b, 'co', 5, 'manual', a2_id);    -- manual 却拉化验背书
    EXCEPTION WHEN check_violation THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 54H 失败:content_source=manual 却带 source_assay_id 的行落进去了 —— 手工数不许拉化验单背书';
    END IF;
    v_denied := false;
    BEGIN
        INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct)
        VALUES (ib2, 'co', 5);              -- 新行不声明出处
    EXCEPTION WHEN check_violation THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 54H 失败:不声明出处的进料新行落进去了 —— NOT VALID 只放过 PROC-1 之前的老行,新行必填';
    END IF;
END $$;
ROLLBACK;

-- 34 分摊基准:必须选、选了算得出不同的数、改了就过期
--
-- 【为什么值得常设(FIN-36)】此前 processing_runs.allocation_basis 带着
-- DEFAULT 'metal_value',commit_processing_run 从不设它 —— 线上九张单全部拿着那个
-- 谁也没见过的默认值。Doc 2 明写这是错的:分摊基准应当是"显式、可配置的选择,
-- 而不是隐含假设 —— 因为这个答案直接决定每个产出批次的报告毛利"。
--
-- 三臂,各钉一件:
--   A 不给基准 → 【点名】拒绝(ALLOCATION_BASIS_REQUIRED)。不回退到公司配置:
--     那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。
--   B 同一张单按两种基准分摊,单位成本【必须不同】。没有这一臂,A 臂只是在测一个
--     必填参数;有了它,才证明这个选择是【承重的】—— 选错方向就是报错毛利。
--   C 改了基准而不重算 → is_stale 变 true。此前基准不是过期源,一次
--     UPDATE ... SET allocation_basis 会让存着的单位成本与单据自称的方法对不上
--     而毫无信号 —— FIN-25 给输入价格关掉的那个缺口,换了个来源。
--
-- 【日期自设】(README 第 4 条),全部落在 2027,locked_before 显式清空。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_sup uuid; v_mat uuid; v_ccy text;
    ib1 uuid; ib2 uuid;
    v_run uuid;
    v_inputs jsonb; v_outputs jsonb;
    ob_a uuid; ob_b uuid;
    cost_metal_a numeric; cost_metal_b numeric;
    cost_weight_a numeric; cost_weight_b numeric;
    v_stale boolean; v_stale_margin boolean;
    v_denied boolean; v_msg text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = '2027-01-01';

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-34', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r, 'module.processing.edit'), (r, 'module.processing.view'),
           (r, 'module.inbound.edit'), (r, 'module.inbound.view'),
           (r, 'module.finance.view'), (r, 'data.view_prices');
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZFIX34-S', 'fixture 34 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX34-M', 'fixture 34 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;

    -- 一批有价的投料:100 kg,单价 10 → 材料成本 1000
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, pricing_status)
    VALUES ('ZZFIX34-IB', v_mat, v_sup, 100, 100, '2027-01-05', 10, 'final')
    RETURNING id INTO ib1;

    -- metal_value 基准要拿金属行情算价值比 —— 没有行情它会 NO_METAL_VALUE。
    -- 自己设,不继承(README 第 4 条)。
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source)
    VALUES ('ni', 20000, '2027-01-01', 'broker_quote');

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    v_inputs := jsonb_build_array(jsonb_build_object(
        'inbound_batch_id', ib1, 'quantity_consumed', 100));
    -- 【两个产出的重量与金属价值【故意不成比例】】——
    -- A:20 kg;B:20 kg(等重)。金属含量让 A 的金属价值远高于 B。
    -- 等重意味着"按重量"给两者相同的单位成本,而"按金属价值"不会 —— 两种基准
    -- 因此必然分岔,这一臂才有判别力。
    -- 【金属含量不走 commit_processing_run】它只收 material_id/quantity/unit;
    -- 含量在 output_batch_metals 上,提交之后再挂(界面上是化验/金属含量那一块)。
    v_outputs := jsonb_build_array(
        jsonb_build_object('material_id', v_mat, 'quantity', 20, 'unit', 'kg'),
        jsonb_build_object('material_id', v_mat, 'quantity', 20, 'unit', 'kg'));

    -- ══════════ A. 不给基准 → 点名拒绝 ══════════════════════════════════════
    v_denied := false;
    BEGIN
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
        PERFORM commit_processing_run('2027-02-01'::date, NULL, NULL, v_inputs, v_outputs, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 34A 失败:没给分摊基准的加工单建成功了 —— 成本方法又被某个默认值替所有人挑了';
    END IF;
    IF v_msg <> 'ALLOCATION_BASIS_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 34A 失败:拒绝了,但报的不是 ALLOCATION_BASIS_REQUIRED,而是「%」', v_msg;
    END IF;

    -- ══════════ B. 两种基准给出【不同】的单位成本 ═══════════════════════════
    -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run := commit_processing_run('2027-02-01'::date, NULL, NULL, v_inputs, v_outputs, 'metal_value');
    IF (SELECT allocation_basis FROM processing_runs WHERE id = v_run) <> 'metal_value' THEN
        RAISE EXCEPTION 'FIXTURE 34B 失败:选了 metal_value,单据上记的却不是 —— 选择没有被记录下来';
    END IF;

    -- 两个【等重】产出,金属含量 80% 与 10% —— 于是"按重量"必给相同单位成本,
    -- "按金属价值"必给不同的,两种方法因此可判别。
    SELECT po.output_batch_id INTO ob_a FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = v_run ORDER BY ob.code LIMIT 1;
    SELECT po.output_batch_id INTO ob_b FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = v_run ORDER BY ob.code DESC LIMIT 1;
    IF ob_a = ob_b THEN
        RAISE EXCEPTION 'FIXTURE 34B 前置失败:两个产出批取成了同一个';
    END IF;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source)
    VALUES (ob_a, 'ni', 80, 'manual'), (ob_b, 'ni', 10, 'manual');

    PERFORM allocate_processing_costs(v_run, 'metal_value');
    SELECT po.unit_cost_base INTO cost_metal_a FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = v_run ORDER BY ob.code LIMIT 1;
    SELECT po.unit_cost_base INTO cost_metal_b FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = v_run ORDER BY ob.code DESC LIMIT 1;

    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT po.unit_cost_base INTO cost_weight_a FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = v_run ORDER BY ob.code LIMIT 1;
    SELECT po.unit_cost_base INTO cost_weight_b FROM processing_outputs po
      JOIN output_batches ob ON ob.id = po.output_batch_id
     WHERE po.run_id = v_run ORDER BY ob.code DESC LIMIT 1;

    IF cost_metal_a IS NULL OR cost_weight_a IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 34B 前置失败:分摊没算出单位成本(metal %,weight %)—— 后面的比较是空转的',
            cost_metal_a, cost_weight_a;
    END IF;
    IF cost_metal_a = cost_weight_a THEN
        RAISE EXCEPTION 'FIXTURE 34B 失败:两种基准给出【同一个】单位成本(%)—— 那么这个选择就不承重,而 Doc 2 与 FIN-25 都说它承重。构造的产出金属含量可能没有拉开差距',
            cost_metal_a;
    END IF;
    -- 按重量时两个等重产出必须【相等】;按金属价值时必须【不等】——
    -- 这一对断言才真正说明两种方法在做不同的事,而不只是数值碰巧不同。
    IF cost_weight_a <> cost_weight_b THEN
        RAISE EXCEPTION 'FIXTURE 34B 失败:两个等重产出按重量分摊应得【相同】单位成本,实得 % 与 %',
            cost_weight_a, cost_weight_b;
    END IF;
    IF cost_metal_a = cost_metal_b THEN
        RAISE EXCEPTION 'FIXTURE 34B 失败:金属含量 80%% 与 10%% 的两个产出按金属价值分摊应得【不同】单位成本,实得都是 %',
            cost_metal_a;
    END IF;

    -- ══════════ C. 改了基准而不重算 → 过期 ══════════════════════════════════
    -- 先确认此刻【不过期】:刚分摊完(否则 C 臂分不清"本来就过期")
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run;
    IF v_stale THEN
        RAISE EXCEPTION 'FIXTURE 34C 前置失败:刚重分摊完就已经是过期的 —— 说明基准这一支把自己也算了进去(应当用严格大于)';
    END IF;

    -- 裸改基准,不重算 —— 存着的单位成本此刻按的是 weight,单据却自称 metal_value
    UPDATE processing_runs SET allocation_basis = 'metal_value' WHERE id = v_run;

    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run;
    IF NOT v_stale THEN
        RAISE EXCEPTION 'FIXTURE 34C 失败:改了分摊基准却没有标记过期 —— 存着的单位成本按的是旧方法,单据自称新方法,而屏幕上没有任何信号(FIN-25 给输入价格关掉的正是这个缺口)';
    END IF;

    -- batch_margin 就地重算了同一份定义(OPS-20),必须给出同一个答案 ——
    -- fixture 31E 钉的是"两边一致",这里钉的是"新加的这一支两边都加了"
    SELECT bool_or(is_stale) INTO v_stale_margin FROM batch_margin WHERE run_id = v_run;
    IF v_stale_margin IS NOT NULL AND NOT v_stale_margin THEN
        RAISE EXCEPTION 'FIXTURE 34C 失败:processing_run_allocation_status 说过期,batch_margin 说不过期 —— 两份定义漂了,而毛利页正是靠后者提醒读者的';
    END IF;
    -- ══════════ D. 绕过 RPC 直接 INSERT 不给基准 → 必须失败 ═══════════════════
    -- 【这一臂是删掉 schema 默认值买到的东西】没有它,把 DEFAULT 'metal_value' 装回去
    -- 本 fixture 照样全绿 —— 实测过:A 臂测的是函数的必填参数,与列上有没有默认值无关。
    -- fixtures 30/31 当初正是靠那个默认值直插的,删掉之后它们立刻报错,这一臂把
    -- 那个保证钉住。
    v_denied := false;
    BEGIN
        INSERT INTO processing_runs (code, status) VALUES ('ZZFIX34-RAW', 'committed');
    EXCEPTION WHEN OTHERS THEN
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 34D 失败:漏给基准的直接 INSERT 成功了,拿到 % —— 说明列上又有 schema 默认值了,成本方法重新变回"没人选过"',
            (SELECT allocation_basis FROM processing_runs WHERE code = 'ZZFIX34-RAW');
    END IF;
END $$;
ROLLBACK;

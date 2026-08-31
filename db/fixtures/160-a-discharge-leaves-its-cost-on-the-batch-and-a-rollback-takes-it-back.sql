-- 160 一炉放电把成本留在那批料身上,而回滚把它拿回去
--     PROC-COST-1
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【它钉的是什么】状态改变型工序没有产出腿,成本资本化【回投料批】。
-- 而这条路上有四件事,每一件都能在【每一笔分录都正确】的情况下悄悄错掉:
--
-- F1 ★ **累加**:一批料放电两次,两笔成本都在。一个"覆盖"的实现(把载体做成
--      批次上的一列,读-改-写)在这里红 —— 它会只剩第二笔。
-- F2 ★ **unit_price 与供应商应付分毫未动**。这是上一刀【停下来】的那个理由:
--      unit_price 是应付之锚,并进去就是凭空捏造供应商债务。两半各断言一次 ——
--      只断言 unit_price 的话,一个"顺手也改了应付"的实现照样通过。
-- F3 ★ **冲销解除,台账与分录一起**。三个时点都量:挂之前 / 挂之后 / 回滚之后。
--      【起点必须非零】—— 0 → 0 对任何实现都成立(fixture 101 B 臂同一条)。
-- F4 ★ **外来批次挂不上去**。走 allocate 天然不会,但这张表对 authenticated 可写,
--      所以"走那条路不会"与"不可能"是两件事。这一臂直接 INSERT,按名拒。
-- F5 ★ **第七过期源**:放电把成本挂到一批【已经被下游吃掉的】料上,那张下游单
--      必须过期。两个方向都钉:挂之前不过期(否则这一臂空转),挂之后过期。
--      **而放电单自己不许因为自己的分摊而过期**(排除自己那一句)。
-- F6 ★ **R4**:鼓包漏液走整电池粉料线;深度放电【仍然】拒绝它。
-- F7 ★ **3c**:今天一道工序都不受理的安全状态,点名 —— 恰好是 water_exposed。
-- F8 ★ **质量不动**:in = out = 通过量、损耗 0、而且 remaining_qty 一克没少。
--      成本移动,质量不动。
-- F9 ★ **零成本不写载体行,也不举旗**(fu3):载体行是第七过期源,一张一分钱
--      成本都没有的放电单若也写下一行,会把下游单标成"过期"而什么都没变。
--      **两个方向都钉**:零 → 不写;而 300 → 0 的重分摊仍然要【真的把行拿掉】。
--      删是无条件的,插是有条件的 —— 这处不对称本身就是断言对象。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_mat uuid;
    v_ib uuid; v_ib_other uuid; v_ib_dn uuid;
    v_run1 uuid; v_run2 uuid; v_run_dn uuid; v_run_bp uuid;
    v_d date := DATE '2027-10-04';
    v_msg text; v_denied boolean;
    v_base numeric; v_before numeric; v_after numeric;
    v_price numeric; v_price_after numeric;
    v_ap numeric; v_ap_after numeric;
    v_cap uuid; v_cap_status text;
    v_stale boolean; v_remaining numeric;
    v_orphans text;
    v_ib_z uuid; v_run_z uuid; v_run_zd uuid; v_cnt integer;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-160', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ160-S', 'f', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ160-M', 'f160 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;

    -- 一批 100kg @ 5,已放电并核验(深度放电受理它,而且不解决什么)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ160-A', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 5, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');

    -- ══════════ F1 · 累加:放电两次,两笔成本都在 ══════════
    RAISE NOTICE 'fixture 160 · 进入 F1';
    -- 【起点非零的反面:起点必须是零,否则后面的等式说明不了是谁加上去的】
    IF batch_processing_cost_base(v_ib) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 160F1 前置失败:一批刚收进来的料身上不该有已资本化的加工成本,实得 %', batch_processing_cost_base(v_ib);
    END IF;

    v_run1 := commit_processing_run(v_d, 'f160 放电一', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run1, 'electricity', 300);
    PERFORM allocate_processing_costs(v_run1, 'weight');

    IF batch_processing_cost_base(v_ib) <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 160F1 失败(第一炉):成本应资本化回投料批,应得 300,实得 %', batch_processing_cost_base(v_ib);
    END IF;

    v_run2 := commit_processing_run(v_d, 'f160 放电二', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 10)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run2, 'electricity', 200);
    PERFORM allocate_processing_costs(v_run2, 'weight');

    v_base := batch_processing_cost_base(v_ib);
    IF v_base <> 500 THEN
        RAISE EXCEPTION 'FIXTURE 160F1 失败:**一批料放电两次,两笔成本都要在。** 应得 500(300 + 200),实得 %。一个把载体做成批次上一列的实现(读-改-写)在这里只剩 200 —— 累加是"台账 + SUM"这个形状免费提供的,一列做不到。', v_base;
    END IF;

    -- ══════════ F2 · ★ unit_price 与供应商应付分毫未动 ★ ══════════
    -- 【这是上一刀停下来的那个理由】unit_price 是应付之锚:ap_open_items 按
    -- quantity × unit_price 算欠供应商多少钱。把我们自己烧的电并进去 = 凭空捏造
    -- 供应商债务。**两半各断言一次** —— 只断言 unit_price 的话,一个"顺手也改了
    -- 应付"的实现照样通过。
    RAISE NOTICE 'fixture 160 · 进入 F2';
    SELECT unit_price INTO v_price_after FROM inbound_batches WHERE id = v_ib;
    IF v_price_after <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 160F2 失败(前半):**unit_price 是应付之锚,一个字节都不许动。** 应仍为 5,实得 % —— 改它就是改我们欠供应商的钱,而那笔钱与我们自己烧的电毫无关系。', v_price_after;
    END IF;
    SELECT COALESCE(SUM(open_base), 0) INTO v_ap_after FROM ap_open_items WHERE supplier_id = v_sup;
    IF v_ap_after <> 500 THEN
        RAISE EXCEPTION 'FIXTURE 160F2 失败(后半):**供应商应付分毫未动。** 100kg × 5 = 500,实得 % —— 资本化 500 的加工成本之后,如果这个数变成了 1000,系统就在说我们欠供应商多一倍的钱。只断言 unit_price 的 fixture 抓不到这一种。', v_ap_after;
    END IF;

    -- ══════════ F3 · ★ 冲销解除:台账与分录一起 ★ ══════════
    RAISE NOTICE 'fixture 160 · 进入 F3';
    v_before := batch_processing_cost_base(v_ib);            -- 500,非零 —— 这一臂不空转
    IF v_before = 0 THEN
        RAISE EXCEPTION 'FIXTURE 160F3 前置失败:回滚前必须非零,否则 0 → 0 对任何实现都成立';
    END IF;
    SELECT capitalization_entry_id INTO v_cap FROM processing_runs WHERE id = v_run2;
    IF v_cap IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 160F3 前置失败:第二炉应当留下一张资本化分录';
    END IF;

    PERFORM rollback_processing_run(v_run2, 'f160 回滚第二炉');

    v_after := batch_processing_cost_base(v_ib);
    IF v_after <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 160F3 失败(台账半):**回滚必须把它加上去的那一笔【恰好】拿回去** —— 不是全清、也不是不动。应回到 300(第一炉还在),实得 %。', v_after;
    END IF;
    SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_cap;
    IF v_cap_status <> 'reversed' THEN
        RAISE EXCEPTION 'FIXTURE 160F3 失败(分录半):**台账与分录必须一起解除。** 资本化分录应为 reversed,实得「%」—— 少做这一半,成本就留在 1200 上而那张单已经不存在了:账挂在一张不存在的单上,而每一笔分录仍然是平的。', COALESCE(v_cap_status, '(没有这张分录)');
    END IF;

    -- ══════════ F4 · ★ 外来批次挂不上去 ★ ══════════
    -- 走 allocate_processing_costs 天然不会,但这张表对 authenticated 可写 ——
    -- "走那条路不会"与"不可能"是两件事。
    RAISE NOTICE 'fixture 160 · 进入 F4';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ160-B', v_mat, v_sup, 50, 50, 'kg', v_d - 1) RETURNING id INTO v_ib_other;
    PERFORM reprice_inbound_batch(v_ib_other, 5, v_ccy, NULL, 'f');
    -- 【先证明这批料确实不是那张单的投料】
    IF EXISTS (SELECT 1 FROM processing_inputs WHERE run_id = v_run1 AND inbound_batch_id = v_ib_other) THEN
        RAISE EXCEPTION 'FIXTURE 160F4 前置失败:本臂要的是一批【没有投进那张单】的料';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO batch_processing_cost_allocations
            (run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
        VALUES (v_run1, v_ib_other, 999, 10, 10);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'BPCA_BATCH_NOT_AN_INPUT|%' THEN
        RAISE EXCEPTION 'FIXTURE 160F4 失败:**一笔加工成本只能挂到它自己那张单投过的料身上。** 挂到别的批次上,成本会跟着那批货走进【别人的】产出单位成本里,而每一张分录仍然是平的 —— 错的是货,不是账。实得「%」', COALESCE(v_msg, '(写进去了)');
    END IF;
    -- 而且它真的没写进去
    IF batch_processing_cost_base(v_ib_other) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 160F4 失败:拒绝之后那一行仍然落了地,实得 %', batch_processing_cost_base(v_ib_other);
    END IF;

    -- ══════════ F5 · ★ 第七过期源 ★ ══════════
    -- 放电把成本挂到一批【已经被下游转化单吃掉的】料上 —— 那张下游单必须过期,
    -- 否则它的 batch_margin 永远停在放电之前那个数,而放电那张分录完全正确。
    RAISE NOTICE 'fixture 160 · 进入 F5';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ160-C', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib_dn;
    PERFORM reprice_inbound_batch(v_ib_dn, 5, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib_dn;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib_dn, 'discharged_verified');

    -- 下游:一张【转化型】单吃掉它,并且分摊过(于是它有 allocated_at)
    v_run_dn := commit_processing_run(v_d, 'f160 下游转化', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib_dn, 'quantity_consumed', 40)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 40)), 'weight',
        NULL, NULL, 'manual_disassembly');
    PERFORM allocate_processing_costs(v_run_dn, 'weight');

    -- 【先证明注入前它不过期】—— 否则这一臂对任何实现都成立
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run_dn;
    IF COALESCE(v_stale, true) THEN
        RAISE EXCEPTION 'FIXTURE 160F5 前置失败:刚分摊完的下游单不该是过期的,实得 % —— 这一臂要的是一个从"不过期"到"过期"的转变,起点必须是"不过期"', v_stale;
    END IF;

    -- 现在放电那批已经被吃掉的料,并把成本挂上去
    v_run_bp := commit_processing_run(v_d, 'f160 迟到的放电', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib_dn, 'quantity_consumed', 10)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run_bp, 'electricity', 700);
    PERFORM allocate_processing_costs(v_run_bp, 'weight');

    -- ════════════════════════════════════════════════════════════════════════
    -- 【把这笔成本事件挪到分摊【之后】—— 这不是在迁就 fixture,是在还原那个场景】
    -- `now()` 是【事务开始时刻】,不是语句时刻(AGENTS.md 为 AGING-1 记过一次):
    -- 一笔事务里写下的每一个 now() 一模一样,所以"迟到的成本"这个关系在一笔事务里
    -- 根本表达不出来 —— 而那正是这一臂唯一要测的东西。
    -- 【为什么动的是载体行,不是把别的东西推回过去】price_history 是不可变的
    -- (PRICE_HISTORY_IMMUTABLE,一条对的规矩,不该为一支 fixture 让路),
    -- 而这一行是本刀自己的表。把【那笔迟到的成本】标成迟到,比把整个世界推回过去
    -- 更贴近它要描述的事:成本晚于分摊到达。
    -- 【线上不需要这一步】:放电发生在另一笔事务里,时间自然往前走。
    -- 【顺带,它让"排除自己"那一句变得可鉴别】—— 见下面那一段。
    -- ════════════════════════════════════════════════════════════════════════
    UPDATE batch_processing_cost_allocations
       SET created_at = now() + interval '1 hour'
     WHERE run_id = v_run_bp;

    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run_dn;
    IF NOT COALESCE(v_stale, false) THEN
        RAISE EXCEPTION 'FIXTURE 160F5 失败:**迟到的加工成本必须让吃过那批料的单过期。** 不然它的 batch_margin 永远停在放电之前那个数,而放电那张分录本身完全正确 —— 每一笔都对、总数错,本仓库最坏的失败形状。FRT-1 把漏掉同构的那一臂称作"本刀的头号缺陷"。';
    END IF;

    -- 【排除自己】放电单不该因为自己的分摊而过期 —— 一面永远举着的旗等于没有旗。
    -- ★【上面那一步让这一臂真的有鉴别力,值得说清楚】★ 载体行现在【晚于】
    -- 放电单自己的 allocated_at,所以一个漏掉 `run_id <> r.id` 的实现会在这里
    -- 把放电单标成过期 —— 它刚刚才算完,却因为自己写下的那一行而"过期"。
    -- (若不挪时间,载体行与 allocated_at 同刻、`>` 恒假,这一臂对两种实现都绿。)
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run_bp;
    IF COALESCE(v_stale, false) THEN
        RAISE EXCEPTION 'FIXTURE 160F5 失败(排除自己):**放电单不该因为自己写下的那笔成本而过期。** 它刚刚才算完 —— 一面永远举着的旗等于没有旗。一个漏掉 run_id <> r.id 的实现在这里红。';
    END IF;

    -- ══════════ F6 · ★ R4:鼓包漏液的去处 ★ ══════════
    RAISE NOTICE 'fixture 160 · 进入 F6';
    UPDATE inbound_batches SET remaining_qty = 100 WHERE id = v_ib_other;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib_other;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib_other, 'swollen_leaking');

    -- 【前半】整电池粉料线【受理】它 —— 那正是 R4
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f160 粉料线收鼓包', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib_other, 'quantity_consumed', 10)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10)), 'weight',
            NULL, NULL, 'battery_powder_line');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 160F6 失败(前半):**R4 —— 鼓包漏液走整电池粉料线,与损坏料同一处置。** 它应当被受理,实得「%」', v_msg;
    END IF;

    -- 【后半】深度放电【仍然】拒绝它 —— 放电机解决不了起火风险
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f160 放电不收鼓包', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib_other, 'quantity_consumed', 10)),
            '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 160F6 失败(后半):**深度放电仍然不受理鼓包漏液。** R4 放宽的是【整电池粉料线】那一行,不是那道闸本身 —— 一个把 R4 读成"鼓包漏液从此可投"的实现在这里绿,而它会把一块漏液的电池送进放电机。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ F7 · ★ 3c:一道工序都不受理的安全状态 ★ ══════════
    -- Tim 要知道院子里【处理不了】的是什么。本刀之后这个集合恰好是 {water_exposed}。
    RAISE NOTICE 'fixture 160 · 进入 F7';
    SELECT COALESCE(string_agg(s.code, ', ' ORDER BY s.code), '(空集)') INTO v_orphans
      FROM inbound_safety_states s
     WHERE NOT EXISTS (SELECT 1 FROM operation_type_safety_states o WHERE o.safety_state_code = s.code);
    IF v_orphans <> 'water_exposed' THEN
        RAISE EXCEPTION 'FIXTURE 160F7 失败:**没有任何工序受理的安全状态,必须恰好是 water_exposed。** 实得「%」。多出来一个 = 院子里有一种料没有任何去处而没人说;少了一个(尤其少了 water_exposed)= 有人在没有裁定的情况下替那种料开了一条路 —— 而这是全系统唯一一道失败后果是【起火】的闸。', v_orphans;
    END IF;

    -- ══════════ F8 · ★ 质量不动:成本移动,质量不动 ★ ══════════
    RAISE NOTICE 'fixture 160 · 进入 F8';
    -- ZZ160-A 走过两炉放电(第二炉已回滚),而它一克都不该少 —— 直通式不扣库存。
    SELECT remaining_qty INTO v_remaining FROM inbound_batches WHERE id = v_ib;
    IF v_remaining <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 160F8 失败:**放电结束之后那批货还在院子里,还是那么多克。** remaining_qty 应仍为 100,实得 % —— 扣掉它等于在账上把一批还存在的货销掉。成本移动,质量不动。', v_remaining;
    END IF;
    -- 而它身上的成本【确实】变了 —— 否则这一臂只是在证明"什么都没发生"
    IF batch_processing_cost_base(v_ib) <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 160F8 前置失败:这一臂要证明的是"质量没动而成本动了",所以成本必须非零且已知,实得 %', batch_processing_cost_base(v_ib);
    END IF;
    -- 通过量:in = out,损耗 0
    IF EXISTS (SELECT 1 FROM processing_runs WHERE id = v_run1
                 AND (loss_qty <> 0 OR total_input <> total_output)) THEN
        RAISE EXCEPTION 'FIXTURE 160F8 失败:状态改变型不带走质量 —— in = out = 通过量,损耗恒 0';
    END IF;

    -- ══════════ F9 · ★ 零成本的放电单不写载体行,也不举旗 ★ ══════════
    -- 载体行是【第七过期源】。一张一分钱成本都没有的放电单若也写下一行 0,
    -- 它会把吃过那批料的下游单标成过期 —— 而那张单重跑出来的数与现在【一模一样】。
    -- 本仓库对无条件举旗有成文处置(fixture 54:"没人看的旗和没有旗是同一样东西")。
    RAISE NOTICE 'fixture 160 · 进入 F9';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ160-D', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib_z;
    PERFORM reprice_inbound_batch(v_ib_z, 5, v_ccy, NULL, 'f');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib_z;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib_z, 'discharged_verified');

    v_run_zd := commit_processing_run(v_d, 'f160 下游(零成本臂)', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib_z, 'quantity_consumed', 40)),
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 40)), 'weight',
        NULL, NULL, 'manual_disassembly');
    PERFORM allocate_processing_costs(v_run_zd, 'weight');

    -- 一张【没有任何成本条目】的放电单
    v_run_z := commit_processing_run(v_d, 'f160 零成本放电', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib_z, 'quantity_consumed', 10)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    PERFORM allocate_processing_costs(v_run_z, 'weight');

    SELECT count(*) INTO v_cnt
      FROM batch_processing_cost_allocations WHERE run_id = v_run_z;
    IF v_cnt <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 160F9 失败:**一分钱成本都没有的放电单不该写载体行。** 实得 % 行 —— 那一行是第七过期源,它会把吃过这批料的下游单标成过期,而那张单重跑出来的数与现在一模一样。无条件举旗是喊狼来了。', v_cnt;
    END IF;

    -- 【而且它确实没有举旗】—— 上面那条只证明"没写行",这条证明"没有后果"
    UPDATE batch_processing_cost_allocations
       SET created_at = now() + interval '1 hour' WHERE run_id = v_run_z;   -- 有行才会动到
    SELECT is_stale INTO v_stale FROM processing_run_allocation_status WHERE run_id = v_run_zd;
    IF COALESCE(v_stale, false) THEN
        RAISE EXCEPTION 'FIXTURE 160F9 失败(后果半):零成本的放电把下游单标成了过期 —— 而什么都没变。';
    END IF;

    -- 【先删仍然是无条件的】300 → 0 的重分摊必须真的把那一行拿掉,
    -- 否则基函数还会读到 300。这一半与上面那一半方向相反,两个都要。
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run_z, 'electricity', 300);
    PERFORM allocate_processing_costs(v_run_z, 'weight');
    IF batch_processing_cost_base(v_ib_z) <> 300 THEN
        RAISE EXCEPTION 'FIXTURE 160F9 前置失败:补一笔成本之后应当是 300,实得 %', batch_processing_cost_base(v_ib_z);
    END IF;
    UPDATE processing_cost_entries SET deleted_at = now() WHERE run_id = v_run_z;
    PERFORM allocate_processing_costs(v_run_z, 'weight');
    IF batch_processing_cost_base(v_ib_z) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 160F9 失败(先删半):成本条目全被软删之后,载体行必须【真的被拿掉】—— 应回到 0,实得 %。一个"零就整个跳过、连删都不删"的实现在这里红。', batch_processing_cost_base(v_ib_z);
    END IF;
END $$;
ROLLBACK;

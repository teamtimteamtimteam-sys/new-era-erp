-- 161 注销解除的是【全部落地成本】,而一次"点少了再点回来"必须净得零
--     PROC-COST-2
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【它钉的是什么】Tim 的裁定 R1:一批料被注销或盘亏,**它的全部落地成本一次
-- 解除** —— 采购价 + 运费 + 已资本化的加工成本。不许为一批已经不存在的货在
-- 存货科目上留下任何东西。而这条规矩有四种错法,每一种都能在【每一笔分录都
-- 正确】的情况下发生:
--
-- A ★ **整批注销之后 1200 上一分不剩**。改之前:落地 1150,只解除 500(采购价),
--     **650 留在 1200 上**。起点与终点都量,而且断言的是【差】不是余额本身 ——
--     重建库与线上的 1200 起点不同,断言余额就是断言一个环境。
-- B ★ **部分按【比例】解除,不是全有或全无**。半批解除一半落地成本,剩下一半
--     仍然留在 1200 上;把剩下的也注销掉,才归零。**两个方向都断言** ——
--     只断言"解除了 575"的话,一个"解除全部 1150"的实现照样通过前半句。
-- C ★★ **先减后加,1200 必须回到起点**。post_stocktake 的盘盈与盘亏共用同一个
--     v_value。**一个只改盘亏方向的实现在这里红** —— 而那正是这一臂的全部意义:
--     它会永久销毁一批【一克都没离开过厂房】的料的运费与加工成本。
--     **一次修复造出来的新缺陷,比被修的那个更坏。**
-- D ★ **注销与盘点读的是【同一支】函数**。R1 要求两者一起改,理由是它们必须
--     永远对"这批货值多少钱"给出同一个答案。这一臂用同一批数据走两条路,
--     断言两个金额相等 —— 一个"只改了其中一条路"的实现在这里红。
-- E ★ **被冲销的加工单不再计入落地成本**,而且【载体行仍然物理存在】——
--     排除靠的是 processing_runs.deleted_at,不是删行。两件事分开断言:
--     只断言基函数为 0 的话,一个"回滚时把载体行删掉"的实现也通过,
--     而那会毁掉审计痕迹。
-- F ★ **unit_price 一个字节没动**(应付之锚,fixture 160 F2 同源)。
--     落地成本变了而供应商应付不许变。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_fwd uuid; v_mat uuid;
    v_d date := DATE '2027-12-04';
    v_ib uuid; v_ib2 uuid; v_run uuid; v_st uuid;
    v_0 numeric; v_a numeric; v_b numeric; v_c numeric;
    v_rate numeric; v_wo numeric; v_stk numeric;
    v_price numeric; v_ap numeric; v_rows int;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-161', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ161-S', 'f', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ161-F', 'f', 'SG', 'active', 'forwarder') RETURNING id INTO v_fwd;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ161-M', 'f161 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;

    -- ══════════ A · 整批注销 → 1200 上一分不剩 ══════════
    RAISE NOTICE 'fixture 161 · 进入 A';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ161-A', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');

    -- 【起点在【建完批次之后、计价之前】取】—— 这样这个差就只含这批货的三项。
    SELECT COALESCE(SUM(signed_base),0) INTO v_0
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';

    PERFORM reprice_inbound_batch(v_ib, 5, v_ccy, NULL, 'f161');          -- 采购 500
    PERFORM record_freight_document(v_d, v_fwd, 250, v_ccy, 'weight', 'unpaid', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib)), 'f161');  -- 运费 250
    v_run := commit_processing_run(v_d, 'f161 放电 A', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run, 'electricity', 400);
    PERFORM allocate_processing_costs(v_run, 'weight');                    -- 加工 400

    -- 【单位落地成本是一个可以逐项推出来的数,所以断言它本身】(README 第 1 条)
    --   5(单价) + 250/100(运费) + 400/100(加工) = 11.50
    v_rate := inbound_batch_landed_unit_cost(v_ib);
    IF v_rate <> 11.50 THEN
        RAISE EXCEPTION 'FIXTURE 161A 失败:单位落地成本应为 11.50(= 5 + 250/100 + 400/100),实得 %', v_rate;
    END IF;

    SELECT COALESCE(SUM(signed_base),0) INTO v_a
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    IF v_a - v_0 <> 1150.00 THEN
        RAISE EXCEPTION 'FIXTURE 161A 前置失败:三项应把 1150.00 送进 1200,实得 % —— 起点非零是这一臂不空转的前提', v_a - v_0;
    END IF;

    PERFORM soft_delete_inbound_batch(v_ib, 'f161 整批注销');
    SELECT COALESCE(SUM(signed_base),0) INTO v_b
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    IF v_b - v_0 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 161A 失败:**整批注销之后 1200 上必须一分不剩**,实得 %。一个按 unit_price 计值的实现在这里留下 650(= 运费 250 + 加工 400)—— 那是一笔【没有对应实物】的存货。', v_b - v_0;
    END IF;
    v_wo := v_a - v_b;   -- D 臂要用

    -- ══════════ F · unit_price 与供应商应付分毫未动 ══════════
    SELECT unit_price INTO v_price FROM inbound_batches WHERE id = v_ib;
    IF v_price <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 161F 失败:**unit_price 是应付之锚,一个字节都不许动。** 应仍为 5,实得 %', v_price;
    END IF;

    -- ══════════ B · 部分:半批解除一半,剩一半;再注销才归零 ══════════
    RAISE NOTICE 'fixture 161 · 进入 B';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ161-B', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    SELECT COALESCE(SUM(signed_base),0) INTO v_0
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    PERFORM reprice_inbound_batch(v_ib, 5, v_ccy, NULL, 'f161');
    PERFORM record_freight_document(v_d, v_fwd, 250, v_ccy, 'weight', 'unpaid', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib)), 'f161');
    v_run := commit_processing_run(v_d, 'f161 放电 B', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run, 'electricity', 400);
    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT COALESCE(SUM(signed_base),0) INTO v_a
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';

    INSERT INTO stocktakes (code, status) VALUES ('ZZ161-ST1', 'open') RETURNING id INTO v_st;
    INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty)
    VALUES (v_st, v_ib, 100, 50);
    PERFORM post_stocktake(v_st);
    SELECT COALESCE(SUM(signed_base),0) INTO v_b
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    v_stk := v_a - v_b;   -- D 臂要用

    -- 【两个方向都断言】解除了一半,而且【剩下】的也正好是一半。
    -- 只断言前半句的话,一个"一次解除全部 1150"的实现照样通过。
    IF (v_a - v_b) <> 575.00 THEN
        RAISE EXCEPTION 'FIXTURE 161B 失败(解除侧):半批盘亏应解除落地成本的【一半】575.00(= 1150/2),实得 %', v_a - v_b;
    END IF;
    IF (v_b - v_0) <> 575.00 THEN
        RAISE EXCEPTION 'FIXTURE 161B 失败(剩余侧):**剩下的一半必须还在 1200 上**,应为 575.00,实得 % —— 一个"部分注销就解除全部"的实现在这里红,而它通过了解除侧那一句', v_b - v_0;
    END IF;

    PERFORM soft_delete_inbound_batch(v_ib, 'f161 剩余注销');
    SELECT COALESCE(SUM(signed_base),0) INTO v_c
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    IF (v_c - v_0) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 161B 失败:两步走完 1200 必须归零,实得 %', v_c - v_0;
    END IF;

    -- ══════════ D · 注销与盘点【同一个答案】══════════
    -- A 臂整批注销解除 1150,B 臂半批盘亏解除 575 —— 两者都是同一个单位费率乘量。
    -- 【为什么这一臂不是多余的】R1 要求两条路一起改,正因为它们可以【分别】错。
    IF v_wo <> 2 * v_stk THEN
        RAISE EXCEPTION 'FIXTURE 161D 失败:注销与盘点必须用【同一支】计值函数。整批注销解除 %,半批盘亏解除 % —— 前者应恰为后者的两倍。一个"只改了其中一条路"的实现在这里红。', v_wo, v_stk;
    END IF;

    -- ══════════ C · ★ 先减后加,1200 必须回到起点 ★ ══════════
    RAISE NOTICE 'fixture 161 · 进入 C';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ161-C', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    PERFORM reprice_inbound_batch(v_ib, 5, v_ccy, NULL, 'f161');
    v_run := commit_processing_run(v_d, 'f161 放电 C', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run, 'electricity', 400);
    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT COALESCE(SUM(signed_base),0) INTO v_a
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';

    INSERT INTO stocktakes (code, status) VALUES ('ZZ161-ST2', 'open') RETURNING id INTO v_st;
    INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty)
    VALUES (v_st, v_ib, 100, 50);
    PERFORM post_stocktake(v_st);
    SELECT COALESCE(SUM(signed_base),0) INTO v_b
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    -- 【先断言盘亏那一步确实按落地成本走了】否则 C 臂可能靠"两边都错得一样"通过
    IF (v_a - v_b) <> 450.00 THEN
        RAISE EXCEPTION 'FIXTURE 161C 前置失败:盘亏 50kg 应按落地成本解除 450.00(= 50 × 9.00),实得 %', v_a - v_b;
    END IF;

    INSERT INTO stocktakes (code, status) VALUES ('ZZ161-ST3', 'open') RETURNING id INTO v_st;
    INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty)
    VALUES (v_st, v_ib, 50, 100);
    PERFORM post_stocktake(v_st);
    SELECT COALESCE(SUM(signed_base),0) INTO v_c
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    IF (v_c - v_a) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 161C 失败:**"点少了、再点回来"必须净得零,实得 %。** 盘盈与盘亏共用同一个单位费率;一个只改盘亏方向的实现会在这里永久销毁 200 的运费与加工成本 —— 而那批料一克都没有离开过厂房。**那是一次修复造出来的新缺陷,比被修的那个更坏。**', v_c - v_a;
    END IF;

    -- ══════════ E · 冲销即解除,而载体行【仍然在】══════════
    RAISE NOTICE 'fixture 161 · 进入 E';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ161-E', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib2;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib2;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib2, 'discharged_verified');
    PERFORM reprice_inbound_batch(v_ib2, 5, v_ccy, NULL, 'f161');
    v_run := commit_processing_run(v_d, 'f161 放电 E', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib2, 'quantity_consumed', 100)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run, 'electricity', 300);
    PERFORM allocate_processing_costs(v_run, 'weight');
    -- 【起点必须非零】0 → 0 对任何实现都成立(fixture 160 F3 同一条)
    IF inbound_batch_landed_unit_cost(v_ib2) <> 8.00 THEN
        RAISE EXCEPTION 'FIXTURE 161E 前置失败:冲销前单位落地成本应为 8.00(= 5 + 300/100),实得 %',
            inbound_batch_landed_unit_cost(v_ib2);
    END IF;

    PERFORM rollback_processing_run(v_run, 'f161 冲销');
    IF inbound_batch_landed_unit_cost(v_ib2) <> 5.00 THEN
        RAISE EXCEPTION 'FIXTURE 161E 失败:一张被冲销的加工单的成本不该再计入落地成本,应回到 5.00(只剩采购价),实得 %',
            inbound_batch_landed_unit_cost(v_ib2);
    END IF;
    -- 【两件事分开断言】排除靠 deleted_at,不是删行 —— 删行会毁掉审计痕迹。
    SELECT count(*) INTO v_rows FROM batch_processing_cost_allocations WHERE inbound_batch_id = v_ib2;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 161E 失败:冲销之后载体行必须【仍然物理存在】(排除靠 processing_runs.deleted_at),应为 1 行,实得 % —— 一个"回滚时删掉载体行"的实现同样能让上一句通过,而它毁掉的是审计痕迹', v_rows;
    END IF;

    RAISE NOTICE 'fixture 161 · 全部通过';
END $$;
ROLLBACK;

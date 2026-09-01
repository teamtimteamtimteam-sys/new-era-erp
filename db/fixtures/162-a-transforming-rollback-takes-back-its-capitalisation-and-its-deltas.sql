-- 162 转化型加工单回滚,把它的资本化【与差额】分录一起拿回去
--     PROC-COST-2
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【它钉的是什么】PROC-COST-1 只为【状态改变型】加了资本化的解除,并把转化型
-- 那一侧写成一条明写的待办。实测:一张转化型加工单回滚之后,它的资本化分录
-- (借 1220 / 贷 1200 / 贷 5xxx)**原样立着** —— 产出批已经被软删了,
-- 1220 上却还挂着它的成本。**每一笔分录都正确,而总数错。**
--
-- 三个方向,而它们可以【分别】错:
--
-- A ★ **1220 回到起点** —— 资本化分录被冲销。改之前它留着 800。
-- B ★★ **差额分录也要冲**。转化型重分摊走差额路径:capitalization_entry_id 仍指
--      首挂,新的差额分录记在 allocation_snapshot->'delta_entry_ids' 里。
--      **只冲首挂的实现在这里红** —— 而那是最坏的一种半修:它对没被重分摊过的
--      单是对的,于是看起来已经修好了。这一臂先断言差额分录【确实存在】,
--      否则它就在空转。
-- C ★ **1200 也回到起点** —— 投料的价值随 remaining_qty 一起退回来。
--      只断言 1220 的话,一个"把 1220 那一腿单独冲掉"的实现照样通过。
-- D ★ **capitalization_entry_id 清空、capitalized_cost_base 归零** ——
--      一张已删的单不该还指着一张已冲销的分录。
-- E ★ **状态改变型走【同一段代码】**。PROC-COST-2 把工序种类的判断拿掉了;
--      这一臂断言状态改变型的行为一个字没变 —— 一个"给转化型另写一条路"的
--      实现能通过 A–D,却会在这里让两条路开始漂移。
--
-- 【第四个候选:sales_records 上的 COGS 分录 —— 不需要任何处置,故不设臂】
-- rollback_processing_run 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝
-- 回滚,而一次销售必然动 remaining_qty。**够不到的东西不需要修,但需要被点名。**
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_mat uuid; v_matout uuid;
    v_d date := DATE '2027-12-05';
    v_ib uuid; v_run uuid;
    a1200 numeric; a1220 numeric; b1200 numeric; b1220 numeric;
    v_cap uuid; v_deltas jsonb; v_n numeric; v_base numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-162', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ162-S', 'f', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ162-M', 'f162 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;
    -- 【黑粉没有规格尺寸】guard_material_condition_axes 会按名拒一个填了它的黑粉
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ162-O', 'f162 powder', 'battery_material', true, 'black_mass', 'end_of_life', NULL)
    RETURNING id INTO v_matout;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ162-A', v_mat, v_sup, 100, 100, 'kg', v_d - 1, 'other', 'fixture 162 自带数据') RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    PERFORM reprice_inbound_batch(v_ib, 5, v_ccy, NULL, 'f162');

    SELECT COALESCE(SUM(signed_base),0) INTO a1200
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    SELECT COALESCE(SUM(signed_base),0) INTO a1220
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1220';

    -- 转化型:整电池粉料线,100kg 进、80kg 出、损耗 20
    v_run := commit_processing_run(v_d, 'f162 粉料线', 20,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matout, 'quantity', 80, 'unit', 'kg')),
        'weight', NULL, NULL, 'battery_powder_line');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run, 'electricity', 300);
    PERFORM allocate_processing_costs(v_run, 'weight');

    SELECT capitalization_entry_id INTO v_cap FROM processing_runs WHERE id = v_run;
    IF v_cap IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 162 前置失败:转化型分摊之后必须有一张资本化分录 —— 没有它,后面每一臂都在空转';
    END IF;

    -- ★ 制造一张【差额分录】—— B 臂的全部意义。断言它确实存在,否则空转。
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run, 'labour', 120);
    PERFORM allocate_processing_costs(v_run, 'weight');
    SELECT allocation_snapshot->'delta_entry_ids' INTO v_deltas FROM processing_runs WHERE id = v_run;
    IF COALESCE(jsonb_array_length(v_deltas), 0) < 1 THEN
        RAISE EXCEPTION 'FIXTURE 162B 前置失败:这一臂要求重分摊【确实】写出了差额分录,实得 % —— 没有差额分录,B 臂证明不了任何事', COALESCE(v_deltas::text, 'NULL');
    END IF;

    SELECT COALESCE(SUM(signed_base),0) INTO b1220
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1220';
    -- 【起点必须非零】—— 800 首挂 + 120 差额 = 920
    IF b1220 - a1220 <> 920.00 THEN
        RAISE EXCEPTION 'FIXTURE 162 前置失败:回滚前 1220 上应有 920.00(= 材料 500 + 电 300 + 人工 120),实得 % —— 0 → 0 对任何实现都成立', b1220 - a1220;
    END IF;

    -- ══════════ 回滚 ══════════
    PERFORM rollback_processing_run(v_run, 'f162 回滚');

    SELECT COALESCE(SUM(signed_base),0) INTO b1220
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1220';
    SELECT COALESCE(SUM(signed_base),0) INTO b1200
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';

    -- A + B:1220 必须一分不剩地回到起点。差 120 = 只冲了首挂;差 920 = 一张都没冲。
    IF b1220 - a1220 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 162A/B 失败:**转化型回滚之后 1220 必须回到起点**,实得 %。差 920 = 资本化分录一张都没被冲销(产出批已经软删,成本却还挂在 1220 上);差 120 = 只冲了首挂、漏了重分摊的差额分录 —— 后者是最坏的一种半修,因为它对没被重分摊过的单是对的。', b1220 - a1220;
    END IF;

    -- C:1200 也要回到起点 —— 投料的价值随 remaining_qty 一起退回来
    IF b1200 - a1200 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 162C 失败:回滚之后 1200 必须回到起点(投料的价值退回来),实得 % —— 一个"只把 1220 那一腿单独冲掉"的实现能通过 A/B 而在这里红', b1200 - a1200;
    END IF;

    -- D:一张已删的单不该还指着一张已冲销的分录
    SELECT capitalization_entry_id, capitalized_cost_base INTO v_cap, v_n
      FROM processing_runs WHERE id = v_run;
    IF v_cap IS NOT NULL OR v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 162D 失败:回滚之后 capitalization_entry_id 应为 NULL、capitalized_cost_base 应为 0,实得 % / %', v_cap, v_n;
    END IF;

    -- ══════════ E · 状态改变型走【同一段代码】,行为一个字没变 ══════════
    RAISE NOTICE 'fixture 162 · 进入 E(状态改变型仍然同样解除)';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ162-E', v_mat, v_sup, 100, 100, 'kg', v_d - 1, 'other', 'fixture 162 自带数据') RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'discharged_verified');
    PERFORM reprice_inbound_batch(v_ib, 5, v_ccy, NULL, 'f162');
    SELECT COALESCE(SUM(signed_base),0) INTO a1200
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    v_run := commit_processing_run(v_d, 'f162 放电', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base) VALUES (v_run, 'electricity', 250);
    PERFORM allocate_processing_costs(v_run, 'weight');
    v_base := batch_processing_cost_base(v_ib);
    IF v_base <> 250 THEN
        RAISE EXCEPTION 'FIXTURE 162E 前置失败:放电应把 250 资本化回投料批,实得 %', v_base;
    END IF;
    PERFORM rollback_processing_run(v_run, 'f162 放电回滚');
    SELECT COALESCE(SUM(signed_base),0) INTO b1200
      FROM journal_activity_lines(NULL, NULL, true) WHERE account_code = '1200';
    IF batch_processing_cost_base(v_ib) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 162E 失败(台账侧):状态改变型回滚之后载体不该再计,实得 %', batch_processing_cost_base(v_ib);
    END IF;
    IF b1200 - a1200 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 162E 失败(分录侧):状态改变型回滚之后 1200 必须回到起点,实得 % —— **拿掉工序种类的判断不许改变这一侧的行为**;一个"给转化型另写一条路"的实现能通过 A–D,而两条路从此开始漂移', b1200 - a1200;
    END IF;

    RAISE NOTICE 'fixture 162 · 全部通过';
END $$;
ROLLBACK;

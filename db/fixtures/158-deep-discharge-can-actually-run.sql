-- 158 深度放电【真的跑得起来】—— 而它今天跑不起来的理由不是 NO_OUTPUTS
--     PROC-WIRE-1B-i
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【它钉的是本刀的那一条发现】
-- charged_not_discharged 的 may_be_fed = false,而 guard_processing_input 拒掉
-- 任何带着不可投料状态的投料 —— **于是那道闸拒绝投喂的,恰恰是深度放电存在的
-- 全部理由那一种料。** 两条拒绝互相指着对方。
--
-- 【每一臂钉什么】
-- A ★ 死锁复现:**没有工序类型时,一批未放电的料进不了任何工序。**
--   这一臂同时是"今天的行为一个字没变"的证据 —— 它必须仍然是 _NOT_FEEDABLE。
-- B 转化型工序也拒它,但**换了一条码**(_NOT_ACCEPTED)—— 两句话不一样:
--   前者说"这批料不可投料",后者说"这道工序不收它,换一道也许就行"。
--   合并这两条,会把"去走放电"这条唯一的出路藏起来。
-- C ★★ **深度放电受理它,而且这一炉真的提交得了。** 本 fixture 的铰链。
-- D 直通式的四条后果,逐条断言:
--   D1 库存【一克没动】(只放松 NO_OUTPUTS 的实现会把它扣到 0);
--   D2 **没有产出批**(R3);
--   D3 质量账:投入 = 产出 = 通过量,损耗【真的是 0】
--      (只放松 NO_OUTPUTS 的实现会记下一笔等于全部投入的损耗);
--   D4 批次身份还在,而**状态变了**:未放电没了,已放电有了。
-- E ★ 死锁真的解开了:**放完电之后,转化型工序收得下它。**
--   少了这一臂,一个"把放电做成什么都不改"的实现照样绿。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_ccy text; v_sup uuid; v_mat uuid; v_ib uuid; v_run uuid;
    v_d date := DATE '2027-09-05';
    v_msg text; v_denied boolean; v_rem numeric; v_n int;
    v_in numeric; v_out numeric; v_loss numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-158', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ158-S', 'f158 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ158-M', 'f158 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ158-IB', v_mat, v_sup, 100, 100, 'kg', v_d - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, v_ccy, NULL, 'f158');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;

    -- 【前提:这一批是【未放电】的,而那个状态今天不可投料】
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'charged_not_discharged');
    IF (SELECT may_be_fed FROM inbound_safety_states WHERE code = 'charged_not_discharged') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 158 前置失败:本份 fixture 的整个意义在于【未放电 = 不可投料】。那一行若变了,这个死锁就不存在了,而这一份要跟着重写,不是删掉';
    END IF;

    -- ══════════ A · ★ 没有工序的单,在提交那一刻就被按名拒 ★ ══════════
    -- 【这一臂在 PROC-SUPPORT-1 换了主语,而它换得对】
    -- 原本它钉的是"没有工序类型时,行为与 PROC-WIRE-1B-i 之前一个字不差"——
    -- 一批未放电的料仍然撞 INPUT_SAFETY_STATE_NOT_FEEDABLE。
    -- **工序在提交时必填之后,那个世界不存在了**:这张单连投入腿都走不到,
    -- 在 commit_processing_run 的必填检查那里就停住了。
    -- 照原样留着这一臂,它会【断言一个已经不可能发生的世界】—— 那不是测试,
    -- 是给下一个人看的一张过期地图。**新的拒绝站在旧的拒绝原来站的位置上**,
    -- 所以这一臂保住了它的主语:一张说不出工序的单,进不了这道门。
    RAISE NOTICE 'fixture 158 · 进入 A';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f158 no op', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100)), 'weight');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'OPERATION_TYPE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 158A 失败(PROC-SUPPORT-1):**一张没有说出工序的加工单,必须在提交那一刻被按名拒**,而且是它【自己那一条码】—— 不是 NO_INPUTS、不是安全状态那几条。合并进任何一条既有拒绝,屏幕上就会有一句话对应两个去处。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ B · 转化型工序拒它,但【是另一条码】 ══════════
    RAISE NOTICE 'fixture 158 · 进入 B';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f158 electrode', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100)), 'weight',
            NULL, NULL, 'electrode_line');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'INPUT_SAFETY_STATE_NOT_ACCEPTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 158B 失败:转化型工序【不受理】未放电的料,而且拒绝必须是【另一条码】——"这道工序不收它"与"这批料不可投料"是两句话,下一步动作也不同。实得「%」', COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════ C · ★ 深度放电受理它,而且提交得了 ★ ══════════
    RAISE NOTICE 'fixture 158 · 进入 C';
    v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_d, 'f158 discharge', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 158C 失败:**深度放电必须跑得起来。** 这是整份 fixture 的铰链,也是本刀存在的理由 —— 少了它,一刀会报告成功却什么都没演示。实得「%」', COALESCE(v_msg, '(返回空)');
    END IF;

    -- ══════════ D · 直通式的四条后果 ══════════
    RAISE NOTICE 'fixture 158 · 进入 D';
    -- D1 库存一克没动
    SELECT remaining_qty INTO v_rem FROM inbound_batches WHERE id = v_ib;
    IF v_rem <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 158D1 失败:直通式【不扣库存】—— 放完电那批货还在院子里,还是那么多克。实得 %。**只放松 NO_OUTPUTS 的实现会把它扣到 0**,那是账上把一批还存在的货销掉', v_rem;
    END IF;
    -- D2 没有产出批
    SELECT count(*) INTO v_n FROM processing_outputs WHERE run_id = v_run;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 158D2 失败:R3 说得很清楚 —— 同一批进、同一批出,【不产新批次】。实得 % 条产出腿', v_n;
    END IF;
    -- D3 质量账
    SELECT total_input, total_output, loss_qty INTO v_in, v_out, v_loss
      FROM processing_runs WHERE id = v_run;
    IF v_in <> 100 OR v_out <> 100 OR v_loss <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 158D3 失败:直通式的质量账必须是 投入=产出=通过量、损耗=0,实得 % / % / %。**只放松 NO_OUTPUTS 的实现会得到 100 / 0 / 100** —— 一张放电单报告它把碰过的东西全毁了', v_in, v_out, v_loss;
    END IF;
    -- D4 身份还在,状态变了
    IF NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = v_ib AND code = 'ZZ158-IB') THEN
        RAISE EXCEPTION 'FIXTURE 158D4 失败:同一批进、同一批出 —— 批次的身份必须活下来';
    END IF;
    IF EXISTS (SELECT 1 FROM inbound_batch_safety_states
                WHERE inbound_batch_id = v_ib AND safety_state_code = 'charged_not_discharged') THEN
        RAISE EXCEPTION 'FIXTURE 158D4 失败:放完电之后【未放电】这个状态必须被删掉 —— 不删的话这批货永远带着它,下一道工序仍然拒绝它,那个死锁只是换了个位置复发';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states
                    WHERE inbound_batch_id = v_ib AND safety_state_code = 'discharged_verified') THEN
        RAISE EXCEPTION 'FIXTURE 158D4 失败:放完电之后必须【写上】已放电并核实 —— R3 的"改状态"就是这一件事';
    END IF;

    -- ══════════ E · ★ 死锁真的解开了 ★ ══════════
    RAISE NOTICE 'fixture 158 · 进入 E';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM commit_processing_run(v_d, 'f158 now ok', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 50)),
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 50)), 'weight',
            NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 158E 失败:**放完电之后,转化型工序必须收得下它** —— 那才叫死锁解开了。少了这一臂,一个"把放电做成什么都不改"的实现照样全绿。实得「%」', v_msg;
    END IF;
END $$;
ROLLBACK;

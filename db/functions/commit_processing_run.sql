CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ended_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_shift_code text DEFAULT NULL::text, p_recipe_version_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, p_corrects_run_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_output_id    uuid;   -- FIN-25:再加工投料(产出批为源)
    v_consumed     numeric;
    v_remaining    numeric;
    v_available     numeric;
    v_held          numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
    v_wo           work_orders%ROWTYPE;   -- WO-1b
    -- PROC-WIRE-1B-i:这一炉跑的是哪道工序,以及那道工序【吃不吃料、产不产批】。
    -- 【分支读的是字典那两列,不是一个写死的字符串,也不是调用方传的旗标】
    -- 【PROC-SUPPORT-1】v_consumes / v_produces 不再有"没有工序时"的默认值 ——
    -- 到得了这里就一定有工序,两个值都由字典填。留着 := true 会是一句谎:
    -- 它读起来像"还有一条没有工序的路",而那条路已经在上面被拒掉了。
    v_op           text;
    v_consumes     boolean;
    v_produces     boolean;
    v_result_state text;
    -- MES-4a:机器的挂接、更正的原单、配方那一版、每条产出腿的称重
    v_corr         processing_runs%ROWTYPE;
    v_recipe       record;
    v_since        date;
    v_n            integer;
    v_wid          uuid;
    v_w            weighings%ROWTYPE;
    v_wcal         record;
    v_dev          uuid;
    v_out_qty      numeric[] := ARRAY[]::numeric[];
    v_out_wid      uuid[] := ARRAY[]::uuid[];
    v_key          text;
    -- MES-4b:电芯结构 —— 这道工序要不要它、每一批投料带着什么、产出继承什么
    v_req_cc       boolean;
    v_batch_code   text;
    v_cc           text;
    v_cc_vals      text[] := ARRAY[]::text[];
    v_cc_any_null  boolean := false;
    v_cc_inherit   text;
    v_dismantles   boolean;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25):提交加工归仓库 —— action.processing_commit(warehouse · admin)。
    PERFORM require_permission('action.processing_commit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;

    -- FIN-36:分摊基准【必填】。不在这里回退到 finance_settings 的公司默认值 ——
    -- 那只会把"没人选过"从 schema 挪进函数,同一个病换一层楼。表单永远带着值来
    -- (预选自 finance_settings.default_allocation_basis),所以必填没有代价。
    IF p_allocation_basis IS NULL THEN
        RAISE EXCEPTION 'ALLOCATION_BASIS_REQUIRED';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★【PROC-SUPPORT-1:工序【必填】,而且【自己一条码】】★
    --
    -- 【为什么它必须与下面那四条拒绝分开,绝不合并】
    -- 下一步动作完全不同:
    --   · OPERATION_TYPE_REQUIRED        → 【你还没选工序】,回去选一个;
    --   · OPERATION_TYPE_UNKNOWN         → 选了,但那个码不存在或已停用;
    --   · OPERATION_PRODUCES_NO_OUTPUTS  → 选对了码,但这一单的形状与它矛盾;
    --   · STATE_CHANGE_LOSS_NOT_ZERO     → 同上,矛盾在损耗那一栏;
    --   · INPUT_SAFETY_STATE_NOT_ACCEPTED→ 码没错,是这一批料这道工序不收。
    -- 合并任何两条,屏幕上就会有一句话对应两个去处,而操作员会走错门。
    -- (与 PROC-3 那三条"听起来绝不一样"的拒绝同一条理由,fixture 154 钉着。)
    --
    -- 【位置为什么在这里】紧跟 PROCESS_DATE_REQUIRED / ALLOCATION_BASIS_REQUIRED,
    -- 也就是【所有必填项一起,在任何业务判断之前】。放到下面去,一张没选工序的
    -- 单会先撞上 NO_INPUTS 之类的话,而那句话是【真的,但没用】。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_operation_type_code IS NULL THEN
        RAISE EXCEPTION 'OPERATION_TYPE_REQUIRED'
          USING HINT = '从今天起每一张加工单必须说出它跑的是哪一道工序。产出有无、状态改变型的损耗守恒、逐工序安全状态受理、工序本身是否存在 —— 四道闸全都读这一列,而它为空时前三道要么关掉、要么降级成一条更弱的规则。历史上那 14 张没有工序的单是测试残留,刻意不回填,报表把它们显示成【未归属】。';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q42;MES-4a Step 0 Q7,Tim):【开始、结束、班次】与上面三条必填【一起】,在任何业务判断之前。
    --   判据只有一份(assert_run_header):表上的 INSERT 触发器问的是同一支,correct_run_header 改时刻时也问它。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM assert_run_header(p_process_date, p_started_at, p_ended_at, p_shift_code);

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:解析工序类型。**分支由【工序】决定,不由调用方传旗标决定** ——
    -- 一个 p_is_state_changing 参数会让"这一炉算不算直通"变成调用方的意见,
    -- 而它是那道工序的事实。两者的区别在第一次有人传错的时候才显形,那太晚了。
    -- 【PROC-SUPPORT-1:这一段不再被 IF ... IS NOT NULL 包着】—— 上面那条拒绝
    -- 已经保证到得了这里就有工序。留着那个 IF 会读起来像"还有一条没有工序的路"。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT ot.code, k.consumes_input, k.produces_outputs, ot.resulting_safety_state_code, ot.requires_cell_construction
      INTO v_op, v_consumes, v_produces, v_result_state, v_req_cc
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = p_operation_type_code AND ot.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OPERATION_TYPE_UNKNOWN|%', p_operation_type_code
          USING HINT = '未知或已停用的工序。停用的意思是"以后别再选它",不是"把历史改掉"。';
    END IF;
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    -- ── WO-1b:工单这一支【只在给了参数的时候才存在】────────────────────────
    -- 【为什么是可选的,而不是必填】临时起意的加工是合法的 —— 车间不会为了系统
    -- 先去补一张计划。把它变成必填,得到的不是纪律,是一堆事后补的假工单。
    -- 差异报表因此必须把 work_order_id 为空的那些显示成【计划外】这一个具名的
    -- 类别,而不是让它们悄悄消失(那是 WO-1c 的事,规则记在这里)。
    IF p_work_order_id IS NOT NULL THEN
        SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WO_NOT_FOUND|%', p_work_order_id;
        END IF;
        -- 【只有放行了的工单可以开工】草稿是还没答应的事(与 reserve_stock 只认
        -- 已确认订单同一条);而 closed / cancelled 是【已经结束的事】,再往上挂
        -- 一次加工会让那张单的完成度在它收工之后继续变 —— 收工时写进理由行的
        -- 那句"runs=N"从此不再复算得出来。
        IF v_wo.status <> 'released' THEN
            RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
        END IF;
    END IF;

    -- ── EQP-2a:机器这一支【也只在给了参数的时候才存在】────────────────────
    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【PROC-SUPPORT-1 / R2:equipment_id 【不】跟着 operation_type_code
    --      一起变成必填。这不是一次对称性偏好,是一次【字典完整性】判断。】★★
    --
    -- 【量出来的,不是想出来的】线上 fixed_assets 只有 2 行,而且两行【都是
    --  深度放电机】(FA-2026-0001 Bosch Deep Discharging Machine、
    --  FA-2026-0002 Mobile Discharging Solution),两行的 in_service_date 都是 NULL。
    -- 于是"一台机器一道工序"这个假设在线上【两个方向都是假的】:
    --   · deep_discharge ↔ 两台机器 → 工序【推不出】机器,不能"顺手带出来";
    --   · manual_disassembly / electrode_line / electrode_powder_line /
    --     battery_powder_line —— 五道工序里的【四道】,一台在册机器都没有。
    --     一旦 equipment_id 必填,这四道工序的加工单【一张都提交不了】。
    --
    -- 所以两列的区别是:
    --   · operation_type_code 的字典【完整】—— 5 道工序全部已播种,任何一张单
    --     都答得出来,于是必填的代价是零;
    --   · equipment_id 的字典【残缺】—— 5 道里 4 道无资产可指,于是必填的代价
    --     是让四道工序停摆。
    --
    -- ★【给后来人:不要"修"掉这处不对称】★ 它看起来像是漏了一半,不是。
    -- 要让 equipment_id 也必填,前置条件是【可以查询的】,不是一次感觉:
    --   (1) 每一道启用的工序至少有一台在册、在役的资产;
    --   (2) 而那需要一条【工序 ↔ 资产】的关联,**今天这个库里根本没有这条关联**
    --       —— 那才是真正的前置缺口,记在 docs/processing-support-as-built.md。
    -- 在那之前,空【是一个具名类别(未归属)】,不是零。
    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-2a 的三条(没找到 · 早于取得 · 晚于处置)与 MES-4a 的工序 ↔ 资产规则,判据都在 assert_run_equipment ——
    -- correct_run_header 改机器时问的是同一支。投用之前不拒、试车照收的理由见那支函数与上面这段。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q41;MES-4a Step 0 Q9,Tim):【上面那段等的前置条件到了】—— 工序 ↔ 资产的关联
    --   (operation_type_equipment)。一道工序只要挂着【至少一台没处置的】机器,这一炉就必须说出是哪一台,而且必须是挂着的那几台之一。
    --   处置掉的机器不算数(一道只挂着一台已处置机器的工序 = 没有挂机器)。没有挂任何机器的工序照旧:机器可选。
    --   【为什么不在"没挂机器"时也拒一台被点名的机器】那正是 U1-B 的可选选择器今天的样子,而挂不挂是 Tim 的数据 ——
    --   在他挂之前,一张记下了用哪台机器的单是更多的信息,不是错。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM assert_run_equipment(v_op, p_equipment_id, p_process_date);

    -- ── MES-4a(MES-0 Q49;Q31):这一张来更正哪一张 —— 原单必须已经回滚,而且只能被更正一次 ─────────────
    IF p_corrects_run_id IS NOT NULL THEN
        SELECT * INTO v_corr FROM processing_runs WHERE id = p_corrects_run_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_corrects_run_id;
        END IF;
        IF v_corr.status <> 'reversed' THEN
            RAISE EXCEPTION 'RUN_CORRECTS_NOT_REVERSED|%', v_corr.code
              USING HINT = '数量的更正 = 先经回滚申请(CFO 批)把原单冲掉,再记这一张新单指回它。原单还没冲销。';
        END IF;
        IF EXISTS (SELECT 1 FROM processing_runs r WHERE r.corrects_run_id = p_corrects_run_id) THEN
            RAISE EXCEPTION 'RUN_ALREADY_CORRECTED|%|%', v_corr.code,
                (SELECT r.code FROM processing_runs r WHERE r.corrects_run_id = p_corrects_run_id);
        END IF;
    END IF;

    -- ── MES-4a(MES-0 Q44;Q16):配方的那一版 —— 必须是这道工序的、配方还启用着 ─────────────
    IF p_recipe_version_id IS NOT NULL THEN
        SELECT rv.id, rv.version, rv.param_values, rc.code, rc.operation_type_code, rc.is_active INTO v_recipe
          FROM process_recipe_versions rv JOIN process_recipes rc ON rc.id = rv.recipe_id
         WHERE rv.id = p_recipe_version_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOUND|%', p_recipe_version_id;
        END IF;
        IF v_recipe.operation_type_code <> v_op THEN
            RAISE EXCEPTION 'RECIPE_VERSION_NOT_FOR_OPERATION|%|%', v_recipe.code, v_op;
        END IF;
        IF NOT v_recipe.is_active THEN
            RAISE EXCEPTION 'RECIPE_INACTIVE|%', v_recipe.code;
        END IF;
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:产出的有无,由【工序】说了算
    --   * 会产出的工序(转化型)少了产出 → 照旧 NO_OUTPUTS,一个字没松;
    --   * 不产出的工序(状态改变型,R3)带着产出来 → 【也是拒】,而且是另一条码。
    -- 后者容易被漏掉:只放松一侧会让一张"放电还产出了黑粉"的单悄悄成立。
    -- 【PROC-SUPPORT-1:这道闸现在【总是】有一个工序可读】—— 此前 v_produces
    -- 在无工序时默认 true,于是这条 IF 走的是"照旧"那一支,闸等于不存在。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_produces THEN
        IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
            RAISE EXCEPTION 'NO_OUTPUTS';
        END IF;
    ELSE
        IF p_outputs IS NOT NULL AND jsonb_array_length(p_outputs) > 0 THEN
            RAISE EXCEPTION 'OPERATION_PRODUCES_NO_OUTPUTS|%', v_op
              USING HINT = '这道工序【按定义】不产新批次(R3:同一批进、同一批出,只改状态)。带着产出提交它,说明选错了工序或者选错了单。';
        END IF;
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一批次(不论来源)不能重复添加。FIN-25:投料可为进料批或产出批,
    --     恰一非空;两个都给或都不给 → INPUT_PARENT_INVALID。
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_inputs) elem
        WHERE num_nonnulls(elem->>'inbound_batch_id', elem->>'output_batch_id') <> 1
    ) THEN
        RAISE EXCEPTION 'INPUT_PARENT_INVALID';
    END IF;
    IF (SELECT count(DISTINCT COALESCE(elem->>'inbound_batch_id', elem->>'output_batch_id'))
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        IF v_inbound_id IS NOT NULL THEN
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches
            WHERE id = v_inbound_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
            END IF;
        ELSE
            -- FIN-25:产出批投料 —— 同一套校验、同一把锁。库存机器本就共用
            -- (inventory_movements 两侧 XOR,remaining_qty 两表同义)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches
            WHERE id = v_output_id AND deleted_at IS NULL
            FOR UPDATE;
            IF v_remaining IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_output_id;
            END IF;
        END IF;
        -- IOD-1:投得进去的是【可用】,不是【物理剩余】—— 被扣住的货还在批次里,
        -- 但它不可动用。拒绝同时说出可用与暂扣两个数,否则人看着 remaining 够
        -- 却投不进去,屏幕上没有任何解释。
        v_available := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                                 WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                                   AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                                   AND m.stock_status = 'available'), 0);
        v_held := COALESCE((SELECT sum(qty_delta) FROM inventory_movements m
                            WHERE m.inbound_batch_id IS NOT DISTINCT FROM v_inbound_id
                              AND m.output_batch_id IS NOT DISTINCT FROM v_output_id
                              AND m.stock_status = 'on_hold'), 0);
        IF v_consumed > v_available THEN
            RAISE EXCEPTION 'IOD_CONSUME_EXCEEDS_AVAILABLE|%|%|%', v_consumed, v_available, v_held;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,规格 §3.2 · §4.1;MES-0 Q22;MES-4a Step 0 Q24–Q26,Tim):【每一条产出腿都是称出来的】
    --   一条腿二选一:
    --     · weighing_id —— 挑一条现成的称重:确认了的、单独的净重(不挂地磅单)、没被更正过、没给别的腿用过;
    --     · weight_kg(+ 可选 device_id)—— 在这里敲一个重量:经正常的录入路径在同一笔事务里落一条手工称重(record_manual_weighing_internal)。
    --   腿的数量【就是】那次称重的公斤数(单位只能是 kg —— OUTPUT_UNIT_NOT_KG);再带一个不一样的 quantity → OUTPUT_QTY_NOT_WEIGHING。
    --   两样都没有 → OUTPUT_WEIGHING_REQUIRED|<第几条>。
    --   校准(MES-3a 的裁定 1,同一个判据 weighing_calibration_all):仪器在读数那一天【已知】不在校准期内 → 永远拒
    --   (READING_INSTRUMENT_NOT_CALIBRATED);没有记录仪器 → 开关 require_calibrated_since 空着时只标出来,开关给了且加工日在它之后才拒。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    v_n := 0;
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_n := v_n + 1;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        IF NULLIF(v_output->>'unit', '') IS NOT NULL AND v_output->>'unit' <> 'kg' THEN
            RAISE EXCEPTION 'OUTPUT_UNIT_NOT_KG|%|%', v_n, v_output->>'unit';
        END IF;
        v_wid := NULLIF(v_output->>'weighing_id', '')::uuid;
        IF v_wid IS NOT NULL AND NULLIF(v_output->>'weight_kg', '') IS NOT NULL THEN
            RAISE EXCEPTION 'OUTPUT_WEIGHING_AMBIGUOUS|%', v_n;
        END IF;
        IF v_wid IS NULL THEN
            IF NULLIF(v_output->>'weight_kg', '') IS NULL THEN
                RAISE EXCEPTION 'OUTPUT_WEIGHING_REQUIRED|%', v_n
                  USING HINT = 'MES-4a 起每一条产出腿都要有一次称重:挑一条现成的,或在这里敲重量(会记成一次手工称重)。';
            END IF;
            v_qty := (v_output->>'weight_kg')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
            END IF;
            v_dev := NULLIF(v_output->>'device_id', '')::uuid;
            v_wid := record_manual_weighing_internal(v_qty, v_dev);
        END IF;
        SELECT * INTO v_w FROM weighings WHERE id = v_wid;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'WEIGHING_NOT_FOUND|%', v_wid;
        END IF;
        IF v_w.ticket_id IS NOT NULL OR v_w.role <> 'net' THEN
            RAISE EXCEPTION 'WEIGHING_NOT_STANDALONE_NET|%', v_n;
        END IF;
        IF EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = v_w.id) THEN
            RAISE EXCEPTION 'WEIGHING_SUPERSEDED|%', v_w.id;
        END IF;
        IF v_wid = ANY (v_out_wid) THEN
            RAISE EXCEPTION 'WEIGHING_ALREADY_USED|%', v_n;
        END IF;
        IF EXISTS (SELECT 1 FROM processing_outputs po WHERE po.weighing_id = v_wid) THEN
            RAISE EXCEPTION 'WEIGHING_ALREADY_USED|%', (SELECT r.code FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id
                                                         WHERE po.weighing_id = v_wid);
        END IF;
        SELECT wc.status, wc.device_code, wc.captured_on INTO v_wcal FROM weighing_calibration_all wc WHERE wc.weighing_id = v_wid;
        IF v_wcal.status = 'not_recorded' THEN
            IF v_since IS NOT NULL AND v_process_date >= v_since THEN
                RAISE EXCEPTION 'OUTPUT_WEIGHING_INSTRUMENT_NOT_RECORDED|%', v_n;
            END IF;
        ELSIF v_wcal.status <> 'in_calibration' THEN
            RAISE EXCEPTION 'READING_INSTRUMENT_NOT_CALIBRATED|%|%', v_wcal.device_code, to_char(v_wcal.captured_on, 'YYYY-MM-DD');
        END IF;
        v_qty := v_w.weight_kg;
        IF NULLIF(v_output->>'quantity', '') IS NOT NULL AND (v_output->>'quantity')::numeric <> v_qty THEN
            RAISE EXCEPTION 'OUTPUT_QTY_NOT_WEIGHING|%|%|%', v_n, v_output->>'quantity', v_qty;
        END IF;
        v_out_wid := array_append(v_out_wid, v_wid);
        v_out_qty := array_append(v_out_qty, v_qty);
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-WIRE-1B-i:直通式的质量账
    -- **料【穿过】工序,没有被吃掉** —— 所以投入 = 产出 = 通过量,损耗【真的是 0】
    -- (放电不带走任何质量;这不是"没量过所以填 0",是 R3 说的同一批进同一批出)。
    -- 不这么写的话:total_output = 0 会让质量平衡读成"投了 100 出来 0",
    -- 而 loss_qty = COALESCE(p_loss_qty, 100 - 0) 会凭空记下一笔【等于全部投入】
    -- 的损耗 —— 一张放电单会报告它把碰过的东西全毁了。
    -- 【PROC-SUPPORT-1 实测:无工序时这一整段【从不执行】】—— v_produces 默认
    -- true,于是 NOT v_produces 永远为假。线上量到的那 3 公斤损耗就是这么来的。
    -- ════════════════════════════════════════════════════════════════════════
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,规格 §4.1;MES-4a Step 0 Q17,Tim):【loss_qty 是推出来的:投入 − 产出】
    --   此前它是 COALESCE(p_loss_qty, 投入 − 产出)—— 调用方敲一个不同的数,那个数就被相信了,而它与投入 − 产出之间的差
    --   没有任何人过问(规格 §4.1:一笔只以差额存在的损耗没有审计价值)。现在敲一个不同的数按名拒;
    --   有名字的损耗(processing_run_losses)不许超过它,剩下的就是余数,由结平说出来。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_produces AND p_loss_qty IS NOT NULL AND p_loss_qty <> v_total_input - v_total_output THEN
        RAISE EXCEPTION 'LOSS_QTY_NOT_INPUT_MINUS_OUTPUT|%|%', p_loss_qty, v_total_input - v_total_output
          USING HINT = '损耗总量就是投入减产出,不另填。有名字的损耗在加工单页上分类记;剩下没解释的由结平说出来。';
    END IF;

    IF NOT v_produces THEN
        v_total_output := v_total_input;
        IF COALESCE(p_loss_qty, 0) <> 0 THEN
            RAISE EXCEPTION 'STATE_CHANGE_LOSS_NOT_ZERO|%|%', v_op, p_loss_qty
              USING HINT = '状态改变型工序不带走质量,所以它的损耗只能是 0。填了别的数,要么选错了工序,要么这一炉其实是转化型。';
        END IF;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, work_order_id, created_by, updated_by, equipment_id,
        operation_type_code, started_at, ended_at, shift_code, recipe_version_id, corrects_run_id
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        CASE WHEN v_produces THEN v_total_input - v_total_output ELSE 0 END,
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id,
        v_op, p_started_at, p_ended_at, p_shift_code, p_recipe_version_id, p_corrects_run_id
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    --    FIN-25:ctx 提前到这里 —— 投入腿的守卫触发器(guard_processing_input)
    --    只放行函数上下文;原来 ctx 在第 6 步(产出)才设,投入腿就会被自己拒掉。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_output_id  := (v_input->>'output_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_inbound_id IS NOT NULL THEN
            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:【直通式不扣库存】
            -- 一炉深度放电结束之后,那批货还在院子里,还是那么多克。
            -- 扣掉它 = 账上把一批还存在的货销掉,而这是那个"只放松 NO_OUTPUTS"
            -- 的实现最先造成的破坏(它会把 remaining_qty 扣到 0)。
            -- **投入腿照记** —— 那是【通过量】,记的是"这批料走过这道工序",
            -- 不是"这批料被吃掉了"。设备用量与工时因此仍然读得到它。
            -- ════════════════════════════════════════════════════════════
            IF v_consumes THEN
                SELECT remaining_qty INTO v_remaining
                FROM inbound_batches WHERE id = v_inbound_id;
                v_new_remaining := v_remaining - v_consumed;

                UPDATE inbound_batches
                SET remaining_qty = v_new_remaining,
                    stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                    updated_by = v_user_id,
                    updated_at = now()
                WHERE id = v_inbound_id;

                -- IOD-1:投料走 drain_stock —— 可能跨几个库位桶,于是写出多行(规则见其函数头)
                PERFORM drain_stock(
                    p_qty => v_consumed, p_movement_type => 'processing_consume',
                    p_business_date => v_process_date, p_inbound_batch_id => v_inbound_id,
                    p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);
            END IF;

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-i:**R3 的"改状态"就落在这里**
            -- 被这道工序【解决掉】的状态从批次上删掉,再写上结果状态。
            -- 不删的话,一批放完电的货会永远带着"未放电",于是下一道工序
            -- 仍然拒绝它 —— 那正是本刀要解的那个死锁,只是换了个位置复发。
            -- ════════════════════════════════════════════════════════════
            -- ★ MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q2,Tim):解决掉的状态被【结束】(记下是哪一张加工单),
            --   不再被删;写上的结果状态记 created_by_run_id —— 回滚据这两列把这一炉做过的事原样撤回。
            --   结果状态已经开着(批次本来就带着它)→ 不插(开着的只有一条),于是回滚也不会结束那条不是它写的。
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                UPDATE inbound_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = v_run_id,
                       end_reason = 'resolved by processing run ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_run_id)
                 WHERE s.inbound_batch_id = v_inbound_id AND s.ended_at IS NULL
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)
                VALUES (v_inbound_id, v_result_state, v_run_id)
                ON CONFLICT (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
            END IF;
        ELSE
            -- ════════════════════════════════════════════════════════════
            -- ★【PROC-WIRE-1B-ii:那条占位的拒绝在这里被【拆掉】】★
            -- 此前这里按名拒 STATE_CHANGE_OUTPUT_INPUT_UNSUPPORTED,理由是
            -- 结构性的:安全状态只有进料批有,"把状态改成已放电"这件事在
            -- 产出批上【无处可写】,放过去会得到一炉什么都没改的放电。
            -- **PROC-WIRE-1B-ii 建了 output_batch_safety_states,那个理由不复存在** ——
            -- 于是拒绝也必须跟着走。R1 说得很清楚:闸问的是【这批料和它的
            -- 状态】,不是【这批料从哪来】;一道工序因为料是自己产的就拒绝它,
            -- 正是那处不对称本身。
            -- 【留着它会更坏】表建好了、拒绝还在,下一个人会以为这条路仍然
            -- 没通,而 fixture 会对着一条早该消失的拒绝变绿。
            -- ════════════════════════════════════════════════════════════
            -- FIN-25:产出批投料。state 是【销售状态】(表注),消耗不碰它 ——
            -- 只扣 remaining_qty,流水挂 output_batch_id(XOR 的另一侧)。
            SELECT remaining_qty INTO v_remaining
            FROM output_batches WHERE id = v_output_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_output_id;

            PERFORM drain_stock(
                p_qty => v_consumed, p_movement_type => 'processing_consume',
                p_business_date => v_process_date, p_output_batch_id => v_output_id,
                p_statuses => ARRAY['available'], p_run_id => v_run_id, p_created_by => v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);

            -- ════════════════════════════════════════════════════════════
            -- PROC-WIRE-1B-ii:**R3 的"改状态",产出批这一侧** ——
            -- 与上面进料那一段逐字同形。不删被解决掉的状态,一批放完电的
            -- 自产料会永远带着"未放电",下一道工序仍然拒绝它 —— 那就是
            -- 1B-i 解掉的那个死锁,换到产出批上原样复发。
            -- ════════════════════════════════════════════════════════════
            -- ★ MES-3a:与进料侧逐字同形 —— 结束,不删;结果状态记 created_by_run_id。
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                UPDATE output_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = v_run_id,
                       end_reason = 'resolved by processing run ' || (SELECT pr.code FROM processing_runs pr WHERE pr.id = v_run_id)
                 WHERE s.output_batch_id = v_output_id AND s.ended_at IS NULL
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code, created_by_run_id)
                VALUES (v_output_id, v_result_state, v_run_id)
                ON CONFLICT (output_batch_id, safety_state_code) WHERE ended_at IS NULL DO NOTHING;
            END IF;
        END IF;
        -- ════════════════════════════════════════════════════════════════════
        -- ★ MES-4b(2026-10-07,规格 §3.4;MES-0 Q45;MES-4b Step 0 Q5 · Q6,Tim):【分极片的工序要知道电芯是卷绕还是叠片】
        --   operation_types.requires_cell_construction 为真(引导:electrode_separation · electrode_line)时,每一批投料都必须带一个
        --   确定的结构(cell_constructions.is_determined)—— 没记或 unknown → INPUT_CELL_CONSTRUCTION_REQUIRED|<批号>。
        --   是一个标志,不是这里的一张码表。【放在投入腿落下之后】—— 投入腿的守卫先判安全状态(起火那一道闸先说话:
        --   一批没放电的料,要先听到"这道工序不收它",而不是"先记下它是卷绕还是叠片")。同时记下每一批的值,第 6 步据此决定产出继承什么。
        -- ════════════════════════════════════════════════════════════════════
        IF v_inbound_id IS NOT NULL THEN
            SELECT b.code, b.cell_construction_code INTO v_batch_code, v_cc FROM inbound_batches b WHERE b.id = v_inbound_id;
        ELSE
            SELECT b.code, b.cell_construction_code INTO v_batch_code, v_cc FROM output_batches b WHERE b.id = v_output_id;
        END IF;
        IF v_req_cc AND (v_cc IS NULL OR NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = v_cc AND c.is_determined)) THEN
            RAISE EXCEPTION 'INPUT_CELL_CONSTRUCTION_REQUIRED|%', v_batch_code
              USING HINT = '这道工序按电芯结构分设备(卷绕 / 叠片)。先在批次页上记下这一批是哪一种 —— 没记或"看过分不出"都过不去。';
        END IF;
        IF v_cc IS NULL THEN
            v_cc_any_null := true;
        ELSE
            v_cc_vals := array_append(v_cc_vals, v_cc);
        END IF;
    END LOOP;

    -- MES-4b(Q6):每一批投料都带着【同一个】结构 → 装电芯的产出继承它;有一批没记、或彼此不同 → 留空,到批次页上补。
    IF NOT v_cc_any_null AND (SELECT count(DISTINCT x) FROM unnest(v_cc_vals) x) = 1 THEN
        v_cc_inherit := v_cc_vals[1];
    END IF;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    v_n := 0;
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_n := v_n + 1;
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := v_out_qty[v_n];     -- MES-4a:称出来的公斤数(上面第 2 步定下的)
        v_unit        := 'kg';
        v_purity      := NULLIF(v_output->>'purity', '');
        -- MES-4b(Q6):只有【明确装着电芯】的形态继承结构(没有形态的物料不继承 —— 不知道它装不装电芯)。
        SELECT f.implies_dismantling INTO v_dismantles
          FROM materials m JOIN material_forms f ON f.code = m.form_code WHERE m.id = v_material_id;

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by, cell_construction_code
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id, CASE WHEN v_dismantles IS TRUE THEN v_cc_inherit END
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced, weighing_id)
        VALUES (v_run_id, v_new_output_id, v_qty, v_out_wid[v_n]);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- ★ MES-4a(2026-10-07,MES-0 Q43 · Q44;MES-4a Step 0 Q11 · Q16,Tim):【这一炉记下的参数与指标】
    --   配方那一版先预填它的参数(source = 'recipe');p_values 里给了的字段用给的值(source = 'manual')。
    --   配方里一个后来退役了的字段不预填(退役 = 以后别再用它)。必填【不在这里判】—— 在结平时判(Q11)。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_values IS NOT NULL AND jsonb_typeof(p_values) <> 'object' THEN
        RAISE EXCEPTION 'RUN_VALUES_INVALID';
    END IF;
    IF p_recipe_version_id IS NOT NULL THEN
        FOR v_key IN SELECT k FROM jsonb_object_keys(v_recipe.param_values) k ORDER BY k LOOP
            CONTINUE WHEN p_values IS NOT NULL AND p_values ? v_key;
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM operation_type_fields f
                                       WHERE f.operation_type_code = v_op AND f.field_code = v_key AND f.is_active);
            PERFORM record_run_value_internal(v_run_id, v_key, v_recipe.param_values -> v_key, 'recipe', NULL, NULL);
        END LOOP;
    END IF;
    IF p_values IS NOT NULL THEN
        FOR v_key IN SELECT k FROM jsonb_object_keys(p_values) k ORDER BY k LOOP
            CONTINUE WHEN jsonb_typeof(p_values -> v_key) = 'null';
            PERFORM record_run_value_internal(v_run_id, v_key, p_values -> v_key, 'manual', NULL, NULL);
        END LOOP;
    END IF;

    -- ── COD-1:这一投料可能【刚好把某一票货加工完】────────────────────────
    -- 销毁证书是一条【必须存在】的记录(像化验报告),不等谁打开页面。
    -- 幂等,没完成就什么也不做;判据在 cod_delivery_completion(),不在这里。
    FOR v_inbound_id IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = v_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_inbound_id);
    END LOOP;

    RETURN v_run_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text)
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
    v_eq           fixed_assets%ROWTYPE;  -- EQP-2a:这一炉归给哪台机器
    -- PROC-WIRE-1B-i:这一炉跑的是哪道工序,以及那道工序【吃不吃料、产不产批】。
    -- 【分支读的是字典那两列,不是一个写死的字符串,也不是调用方传的旗标】
    -- 【PROC-SUPPORT-1】v_consumes / v_produces 不再有"没有工序时"的默认值 ——
    -- 到得了这里就一定有工序,两个值都由字典填。留着 := true 会是一句谎:
    -- 它读起来像"还有一条没有工序的路",而那条路已经在上面被拒掉了。
    v_op           text;
    v_consumes     boolean;
    v_produces     boolean;
    v_result_state text;
BEGIN
    PERFORM require_permission('module.processing.edit');
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
    -- PROC-WIRE-1B-i:解析工序类型。**分支由【工序】决定,不由调用方传旗标决定** ——
    -- 一个 p_is_state_changing 参数会让"这一炉算不算直通"变成调用方的意见,
    -- 而它是那道工序的事实。两者的区别在第一次有人传错的时候才显形,那太晚了。
    -- 【PROC-SUPPORT-1:这一段不再被 IF ... IS NOT NULL 包着】—— 上面那条拒绝
    -- 已经保证到得了这里就有工序。留着那个 IF 会读起来像"还有一条没有工序的路"。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT ot.code, k.consumes_input, k.produces_outputs, ot.resulting_safety_state_code
      INTO v_op, v_consumes, v_produces, v_result_state
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
    IF p_equipment_id IS NOT NULL THEN
        SELECT * INTO v_eq FROM fixed_assets WHERE id = p_equipment_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_FOUND|%', p_equipment_id;
        END IF;
        -- 【拒绝的边界钉在"真的不可能"上,不钉在"还没投用"上】
        -- 加工日早于取得日 = 那天这台机器还不是我们的。
        IF p_process_date < v_eq.acquisition_date THEN
            RAISE EXCEPTION 'EQUIPMENT_NOT_ACQUIRED|%|%|%',
                v_eq.code, v_eq.acquisition_date, p_process_date
              USING HINT = '这一炉的日期早于这台机器的取得日 —— 那天它还不是我们的';
        END IF;
        -- 处置之后它已经不在了。
        IF v_eq.status = 'disposed' AND v_eq.disposal_date IS NOT NULL
           AND p_process_date > v_eq.disposal_date THEN
            RAISE EXCEPTION 'EQUIPMENT_DISPOSED|%|%|%',
                v_eq.code, v_eq.disposal_date, p_process_date
              USING HINT = '这一炉的日期晚于这台机器的处置日 —— 那时它已经不在了';
        END IF;
        -- 【投用之前【不】拒 —— 这是 EQP-2a 对原设计改动最大的一处】
        -- 原设计要拒"加工日那天机器不在役",而 in_service_date 是【投用】日。
        -- 投用之前的试车是这盘生意里一件有名有姓的事:
        -- docs/equipment-survey.md 的资本化边界那一节把"试车料"与安装、调试并列。
        -- 拒掉它们,系统就【记不下那些正好用来证明投用日的加工】,也丢掉了
        -- 那段真实的磨损 —— 而 EQP-2b 的保养间隔要读它。
        -- 剩下被拒的两种都是真的不可能,所以它们【是拒绝,不是警告】。
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
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
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
        operation_type_code
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        CASE WHEN v_produces THEN COALESCE(p_loss_qty, v_total_input - v_total_output)
             ELSE 0 END,
        p_notes, 'committed', p_allocation_basis, p_work_order_id, v_user_id, v_user_id,
        p_equipment_id,
        v_op
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
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                DELETE FROM inbound_batch_safety_states s
                 WHERE s.inbound_batch_id = v_inbound_id
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
                VALUES (v_inbound_id, v_result_state)
                ON CONFLICT (inbound_batch_id, safety_state_code) DO NOTHING;
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
            IF NOT v_produces AND v_result_state IS NOT NULL THEN
                DELETE FROM output_batch_safety_states s
                 WHERE s.output_batch_id = v_output_id
                   AND s.safety_state_code IN (
                       SELECT a.safety_state_code FROM operation_type_safety_states a
                        WHERE a.operation_type_code = v_op AND a.resolves);

                INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code)
                VALUES (v_output_id, v_result_state)
                ON CONFLICT (output_batch_id, safety_state_code) DO NOTHING;
            END IF;
        END IF;
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    -- 用毕即清(price_ctx 同一条理由:免得同事务内后续的直改被误放行 ——
    -- fixture 19F 实测:不清,守卫触发器对残留 ctx 放行裸 INSERT)
    PERFORM set_config('evoltrya.movement_ctx', '', true);

    RETURN v_run_id;
END;
$function$


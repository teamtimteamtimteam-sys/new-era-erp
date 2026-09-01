-- PROC-SUPPORT-1 · 一张加工单必须说出它跑的是哪一道工序
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这不是一个报表改进,是四道闸的总开关】
-- 一个空的 operation_type_code 让 commit_processing_run 同时【关掉三道闸、
-- 把第四道降级】。全部在线上量过(PROC-SUPPORT-1 2a,同一份载荷跑两遍:
-- 一遍不给工序、一遍点名工序,差额【就是】那道闸):
--
--   闸 ①【产出有无由工序说了算】
--        无工序 → 提交成功,单号 PROC-2026-0588,operation_type_code 为 NULL。
--                 一张"深度放电还产出了黑粉"的单就这样成立了。
--        点名 deep_discharge → OPERATION_PRODUCES_NO_OUTPUTS。
--
--   闸 ②【状态改变型损耗必须为零】
--        无工序 → 提交成功,loss_qty 记下 3 —— 一炉放电报告它毁掉了 3 公斤,
--                 而放电【不带走任何质量】。
--        点名 deep_discharge → STATE_CHANGE_LOSS_NOT_ZERO。
--        (对照臂:无工序 + 空产出只得到 NO_OUTPUTS —— 也就是说,不给工序时
--         "状态改变型"这个概念【根本没有主语】,那条规则无从谈起。)
--
--   闸 ③【逐工序安全状态受理】★ 这一道是【降级】,不是【敞开】★
--        ★★ 这里更正一处此前写错的说法。★★ 本刀的 brief 说无工序会"绕过"
--        这道闸。**不对,而且这个差别要紧。** 无工序时闸【仍然在】,只是换了
--        一条更弱的规则:inbound_safety_states.may_be_fed(这批料可不可以投给
--        【任何】工序),而不是 operation_type_safety_states(【这一道】工序
--        受不受理它)。于是:
--          · may_be_fed = false 的料,无工序时【照样被拒】;
--          · may_be_fed = true 但这道工序不受理的料,无工序时【溜过去】。
--        线上实测:may_be_fed = true 的状态今天【只有 1 个】
--        (discharged_verified),而它被【全部五道】工序受理 —— 所以两条规则
--        今天【重合】。**那是种子行的巧合,不是构造上的保证**:字典多一个
--        "一般可投、但某道工序不收"的状态,缺口当天就出现。
--        用一行探针状态量过机制本身:无工序 → 提交成功;点名
--        manual_disassembly → INPUT_SAFETY_STATE_NOT_ACCEPTED。
--        **把一处降级说成一处敞开是它自己的一种伤害** —— 下一个读的人会照着
--        那句夸大的话校准,于是要么高估了历史数据的危险,要么在发现"其实没
--        那么糟"之后连真的那一半也不信了。
--
--   闸 ④【工序必须存在且启用】
--        无工序 → 字典查询【整个不发生】(旧代码把它包在 IF ... IS NOT NULL 里)。
--        给一个不存在的码 → OPERATION_TYPE_UNKNOWN。
--        **NULL 是唯一一个绕开字典的取值。**
--
-- 【为什么现在立规矩,而不是等产线跑起来】
-- docs/proc-operations-wired.md 当时写"那是产线跑起来那天的事"。**在产线跑
-- 起来【之后】立规矩,意味着第一批真实炉次正是没被规矩管住的那些。**
-- 今天真实炉次为 0,界面早已必填,所以现在立规矩的迁移成本【是零】,
-- 而晚立的成本不可回收。强制力应当先于流量到场,不是随流量到场。
--
-- 【那 14 张历史单(10 张未软删)一个字不动】它们是测试残留。
-- 一条 NOT NULL 会把它们就地冻住,并【强迫给它们猜一个工序】—— 而猜出来的
-- 工序与真的工序长得一模一样,还会流进设备用量、回收率、工单实绩。
-- **那正是本刀要防的那个错误。** 所以:
--   · 函数里一条具名拒绝,只管【新提交】的单;
--   · 表上一条 NOT VALID 的 CHECK,只管【新行】,老行原样放过
--     (抄 inbound_batch_metals_content_source_required 的形状)。
-- 报表必须把这 10 张显示成【未归属】,不是丢掉、也不是归零 ——
-- 抄 EQP-2c 已有的 unattributed_runs_in_window。
--
-- 【为什么函数与约束【都】要,不是二选一】
-- 与 work_orders_closed_consistent 的注释同一条理由:
--   · 函数那条给出【可本地化的错误信息】,而且是操作员唯一看得见的地方;
--   · 表那条对【任何写入者】都成立 —— 实测:processing_runs 有一条
--     "insert by permission" 的 RLS 策略,于是任何拿到 module.processing.edit
--     的人都可以【直接 INSERT 一张加工单】,绕开这个函数。
--     (processing_inputs 那一侧拦得住裸插:PROCESSING_INPUT_DIRECT_INSERT
--      要求函数上下文。但一张【没有投入腿】的空单仍然能被直接造出来,
--      而它会永远落在"未归属"那一组里,没有任何报表能把它归给谁。)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── ① 函数:去掉 p_operation_type_code 的 DEFAULT,加一条具名拒绝 ───────────
-- 【为什么 DROP 再 CREATE 而不是 CREATE OR REPLACE】要去掉的是一个【默认值】,
-- 也就是说旧的 8 参数调用形态必须【不再存在】。CREATE OR REPLACE 留着它,
-- 于是一个漏传工序的调用方仍然编译得过、仍然跑得通,只是在运行期才炸 ——
-- 而这一刀的全部意义就是让"没说工序"在【尽可能早】的地方变成一次失败。
-- 让签名自己说实话。(抄 PROC-WIRE-1B-i 与 EQP-2a 两次改签名的形状。)
DROP FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text);

CREATE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text)
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
$function$;

REVOKE EXECUTE ON FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text) TO authenticated, service_role;

-- ── ② 表上的那一条:对【任何写入者】都成立 ──────────────────────────────────
-- NOT VALID = 新行必填、老行放过。抄 inbound_batch_metals_content_source_required
-- (FIN-32)的形状,它的注释已经把理由写好。
-- **绝不 VALIDATE 它** —— VALIDATE 会去检查那 14 张历史单,而它们【本来就该】
-- 不满足这条约束。它们不满足不是一处待修的破损,是一条被记下来的事实。
ALTER TABLE public.processing_runs
    ADD CONSTRAINT processing_runs_operation_type_required
    CHECK (operation_type_code IS NOT NULL) NOT VALID;

COMMENT ON CONSTRAINT processing_runs_operation_type_required ON public.processing_runs IS
    'PROC-SUPPORT-1:一张加工单必须说出它跑的是哪一道工序。
【NOT VALID 是刻意的,而且永远不要 VALIDATE 它】线上 14 张(10 张未软删)没有工序的加工单是【测试残留】,不是待修的破损。VALIDATE 会去检查它们,于是唯一能让约束通过的办法是【给它们猜一个工序】—— 而猜出来的工序与真的工序长得一模一样,会流进设备用量、回收率、工单实绩,并且会让那四道闸【看起来对这些单生效过】,而它们从未生效过。这正是本刀存在的理由。
【它与函数里那条拒绝不是重复】函数那条给操作员一句可本地化的话;这一条对【任何写入者】都成立 —— processing_runs 有一条 "insert by permission" 的 RLS 策略,任何拿到 module.processing.edit 的人都可以直接 INSERT 一张加工单绕开函数。(投入腿那一侧拦得住裸插:PROCESSING_INPUT_DIRECT_INSERT 要求函数上下文;但一张没有投入腿的空单仍然造得出来,而它会永远落在"未归属"那一组里。)
【报表怎么显示那 10 张】显示成【未归属】,不是丢掉、也不是归零 —— 抄 EQP-2c 的 unattributed_runs_in_window。';

-- ── ③ 把 R2 的实测理由钉在列上 ────────────────────────────────────────────
COMMENT ON COLUMN public.processing_runs.equipment_id IS
    'EQP-2a:这一炉是哪台机器跑的。可空,而"空"是一个【具名类别】(未归属),不是零。
★【PROC-SUPPORT-1 / R2:这一列【不】跟着 operation_type_code 一起变成必填 —— 不要"修"掉这处不对称】★
理由是一次【测量】,不是一次对称性偏好:线上 fixed_assets 只有 2 行,两行都是深度放电机(FA-2026-0001 / FA-2026-0002,in_service_date 均为 NULL)。于是 deep_discharge 对应【两台】机器(工序推不出机器,不可派生),而另外【四道】工序 —— manual_disassembly、electrode_line、electrode_powder_line、battery_powder_line —— 【一台在册机器都没有】。一旦这一列必填,这四道工序的加工单一张都提交不了。
所以:operation_type_code 的字典【完整】(5/5 已播种)→ 必填代价为零;equipment_id 的字典【残缺】(5 道里 4 道无资产可指)→ 必填代价是让四道工序停摆。**这是字典完整性判断,不是对称性判断。**
【真正的前置条件,可查询而不是凭感觉】(1) 每一道启用的工序至少有一台在册在役资产;(2) 而那需要一条【工序 ↔ 资产】的关联 —— **今天这个库里没有这条关联**,那才是缺口本身。记在 docs/processing-support-as-built.md。';

-- ── ④ may_be_fed 在这一刀失去了它最后一个消费者 ──────────────────────────
COMMENT ON COLUMN public.inbound_safety_states.may_be_fed IS
    'PROC-2:这个状态的料可不可以投料 —— 【引导默认值】,不是决定;Tim 改一行即可。
★★【2026-09-01 · PROC-SUPPORT-1:这一列在本刀失去了它【最后一个消费者】】★★
它此前唯一的读者是 guard_processing_input 里 `v_op IS NULL` 那一支 —— 也就是"这张加工单没说工序时,拿什么回答受理问题"。本刀让 operation_type_code 在提交时【必填】,于是那一支【再也到不了】,受理问题从今往后一律由 operation_type_safety_states 回答。
【为什么不顺手做成"两条规则取交集"】那会【故意】弄坏 battery_powder_line:Tim 的closed ruling 让它受理 charged_not_discharged,而那一行的 may_be_fed = false。一个看起来更安全、却与一条已下裁定相抵触的改法,并不更安全。
【为什么不就这么留着】一列没人读的数据,读起来仍然像一条还在生效的规则 —— 下一个人会照着它做决定。waste_classifications.is_controlled 已经是这个病的一例,本仓库把它记成了债。**把死的东西宣告为死的**,所以这句话在这里,而不只是在某份文档里。
【排队】要么给它找一个真正的消费者(例如:新增 operation_type_safety_states 行时用它做引导默认),要么删掉它。见 docs/processing-support-as-built.md。';

-- ════════════════════════════════════════════════════════════════════════════
-- 第二件 · 预期产出的【出处】(R3)
--
-- 【本刀不发明这个设计,它兑现一条已经写在表上的规定】
-- work_order_expected_outputs 的表注释,原文一字不改:
--     「【将来有了 BOM 怎么办】它作为【另一个带标签的来源】进来(新列
--       basis/source,或另一张表),【不覆盖这一张】。覆盖会把"人估的"与
--       "标准算的"混成一个数,而那两个数错的时候要找的人不是同一个。」
-- 所以:**一个新列,绝不覆盖既有的那个估计**。列名取表注自己说的 basis。
--
-- 【Tim 要这一列满足的那个要求】六个月之后他打开一行,必须分得出这个数是
-- **被真实生产验证过的**,还是**当初那个猜测**。
-- 这就是本仓库那条「零 vs 不适用」的标准,施加到【置信度】上。
--
-- 【三个取值,以及为什么是三个而不是两个】
--   planner_estimate  排计划的人估的 —— 这张表【按定义】装的就是它;
--   seeded_industry   照行业经验播下的 —— 低置信占位符,Tim 已接受这个说法;
--   calibrated        对着真实生产校准过的 —— **今天线上真实炉次为 0,
--                     所以这个值一次都不该出现。它出现的那一天是一件大事。**
--
-- 【没有默认值 —— 抄 metal_prices.source,连理由一起抄】
--     「四取一,没有默认值 —— 漏填就是一次失败,而不是悄悄补上一个看起来
--       像答案的值。」
-- ★ 一个【缺席】的 basis 绝不许读成 calibrated,也不许读成一个空白格。
--   它的意思是【没有人说过】,屏幕上必须照这句话显示。
--
-- 【为什么【不】另建一张比例表】两条:
--   (1) 与这张表【自己的注释】明写的"不覆盖这一张"相抵触;
--   (2) 那张表的主键要挂在 materials.form_code / chemistry 上,而线上
--       未软删的 5 行物料里只有 1 行有 form_code、9 行里只有 2 行有 chemistry
--       —— **今天几乎无处可挂。**
--
-- 【Tim 的"比例必须逐投料种类"这个要求,已经被结构满足 —— 说出来,不要默认它成立】
--     work_order_expected_outputs.work_order_id → work_orders
--       → work_order_lines.material_id  ← 【这张工单吃什么】(表注:"按物料,不按批次")
-- 一张工单【就是】一种(或一组)投料的计划,所以挂在工单上的预期产出
-- **天然是"这一种投料的预期产出"**,而不是一套全局数字。
-- **这个要求是被满足的,不是被悄悄放弃的。**
--
-- 【本刀【不】播种任何数字】seeded_industry 这个取值现在就可用、就可编辑,
-- 但一个数都不由本刀写进去。Tim 给,或者它就空着 ——
-- **一个顶着"播种"标签的发明出来的比例,仍然是发明出来的。**
-- 本仓库已经三次裁定"一个在有数据之前发明出来的标准是虚构"
-- (forward-queue.md:117 / :1355 / :1563)。带出处的估计不违反那条裁定,
-- 而【由我代 Tim 编一个数】会。
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE public.work_order_expected_outputs
    ADD COLUMN basis           text,
    ADD COLUMN basis_reference text;

COMMENT ON COLUMN public.work_order_expected_outputs.basis IS
    'PROC-SUPPORT-1(R3):这个预期产出【是怎么来的】。三取一,**没有默认值**。
  planner_estimate  排计划的人估的(这张表按定义装的就是它)
  seeded_industry   照行业经验播下的低置信占位符 —— 它【不是】一条标准
  calibrated        对着真实生产校准过的
【为什么没有默认值】抄 metal_prices.source,连理由一起抄:「漏填就是一次失败,而不是悄悄补上一个看起来像答案的值」。
★【缺席的意思是"没有人说过"】★ 绝不许读成 calibrated,也绝不许在屏幕上显示成一个空白格 —— 空白格看起来像"这一栏不重要",而这一栏正是六个月后唯一能回答"这个数可不可信"的东西。
【它不覆盖 expected_qty】这是本表表注早就规定好的形状:新来源作为【另一个带标签的来源】进来,不覆盖既有的估计。混成一个数,两个数错的时候要找的人不是同一个。
【今天线上 calibrated 应当一次都不出现】真实炉次为 0。它第一次出现的那一天是一件大事,不是一次例行填表。';

COMMENT ON COLUMN public.work_order_expected_outputs.basis_reference IS
    'PROC-SUPPORT-1(R3):这个出处的【凭据】—— 哪一份行业报告、哪一次校准跑批、哪一个人的估计。
抄 metal_prices.source_reference,连它那句话一起抄:**自由文本是刻意的 —— 它是证据,不是数据。** 不要把它做成外键或字典:一份凭据可能是一封邮件、一份 PDF、一句"2026-09 与 PROC-2026-0xxx 对过",而把这些硬塞进一张字典表,得到的是一堆假的分类。';

-- 【值域 + 必填,一条 NOT VALID 的 CHECK】新行必须说出出处;老行放过。
-- 抄 inbound_batch_metals_content_source_required(FIN-32)的形状。
ALTER TABLE public.work_order_expected_outputs
    ADD CONSTRAINT work_order_expected_basis_required
    CHECK (basis IS NOT NULL AND basis IN ('planner_estimate','seeded_industry','calibrated'))
    NOT VALID;

COMMENT ON CONSTRAINT work_order_expected_basis_required ON public.work_order_expected_outputs IS
    'PROC-SUPPORT-1(R3):新的预期产出行必须说出它的出处;NOT VALID 让既有行不被强迫穿上一个猜出来的标签。
【线上那唯一一行是被【明写】成 planner_estimate 的,不是被回填的】这两件事在数据里长得一样,所以必须在这里说清楚是哪一件:这张表的表注写着「这里的数是排计划那个人的【估计】,不是一条标准」—— 也就是说 planner_estimate 是这张表【定义上】装的东西。给它贴这个标签是**把一条定义写下来**,不是**猜一个值**。
对比:processing_runs 那 14 张没有工序的单【不】被回填,因为"这一炉跑的是哪道工序"不是任何定义能推出来的,只能猜。**两处形状相同、判断相反,而判断的依据是"这个值推得出来吗",不是"回填方便吗"。**';

-- 【线上那一行:明写,不是回填 —— 理由见上面那条约束注释】
UPDATE public.work_order_expected_outputs
   SET basis = 'planner_estimate'
 WHERE basis IS NULL;

COMMENT ON TABLE public.work_order_expected_outputs IS
    'WO-1a:预期产出 —— 【这里的数是排计划那个人的估计,不是一条标准】。
【为什么这句话必须写在表上】WO-1 的调查量过:今天这个库里【没有】任何可以推出预期产出的东西 —— 没有配方/BOM(Doc 2 明写它留给多工序那一次升级),投料侧 19 条含量行的 content_source 全是 NULL(一条化验来源都没有,PROC-1 刻意不回填),而两侧都测过的 (加工单, 金属) 组合【只有 3 个】。三个观测不是一个回收率。所以这个数只能是手敲的,而手敲的数与标准值意义完全不同:它比出来的差异是【估计 vs 实际】,不是【标准 vs 实际】。把它当标准读,会让一次估得保守的计划看起来像一次超产。
【行是可选的】没有行 = 没人记录过预期,而不是预期为零 —— 差异视图(WO-1b)必须把这两件事分开说。一个 COALESCE(...,0) 会把"没估过"变成"估了零",于是任何产出都是超额完成。
★【PROC-SUPPORT-1 兑现了这张表自己的那条规定】★ 上面那句「将来有了 BOM 怎么办 —— 它作为另一个带标签的来源进来(新列 basis/source,或另一张表),不覆盖这一张」,现在落地成了 basis / basis_reference 两列。**标签在,原来的估计一个字没动。**
【比例是逐投料种类的,而这一点是被【结构】满足的】work_order_id → work_orders → work_order_lines.material_id 就是"这张工单吃什么"。一张工单一套数字,不是一套全局数字。**这个要求是被满足的,不是被放弃的。**
【今天分不出组的那一半,照直说】materials 未软删 5 行里只有 1 行有 form_code、全 9 行里只有 2 行有 chemistry —— 所以"按 NMC/LFP 比较收率"今天【分不出组】。那不挡住本表,但它是一条具名缺口(见 docs/processing-support-as-built.md)。';

-- ── create_work_order:预期产出行必须带 basis ─────────────────────────────
CREATE OR REPLACE FUNCTION public.create_work_order(p_lines jsonb, p_expected jsonb DEFAULT NULL::jsonb, p_scheduled_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
    v_elem jsonb;
    v_mat  uuid;
    v_qty  numeric;
BEGIN
    PERFORM require_permission('module.processing.edit');

    -- 【拒绝的顺序就是"人下一步该改什么"的顺序】两条同时不成立时,先说哪一条
    -- 决定了他打开哪个输入框(与 record_invoice_issue 的四条同一条道理)。
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'WO_NO_LINES';
    END IF;

    -- 投料行:先把每一行自己看一遍,再看行与行之间
    FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_qty := (v_elem->>'planned_qty')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
        END IF;
        v_mat := (v_elem->>'material_id')::uuid;
        IF v_mat IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
        END IF;
    END LOOP;
    -- 【重复物料按名拒,而不是靠唯一约束抛 23505】约束是兜底,不是文案:
    -- 一条 duplicate key value violates unique constraint 到不了人眼里就是机器串。
    SELECT (elem->>'material_id')::uuid INTO v_mat
      FROM jsonb_array_elements(p_lines) elem
     GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
    IF v_mat IS NOT NULL THEN
        RAISE EXCEPTION 'WO_DUPLICATE_MATERIAL|%', v_mat;
    END IF;

    -- 预期产出:【可以整个不给】—— 没有预期是一种诚实的状态,不是缺失。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_qty := (v_elem->>'expected_qty')::numeric;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            END IF;
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
        END LOOP;
        SELECT (elem->>'material_id')::uuid INTO v_mat
          FROM jsonb_array_elements(p_expected) elem
         GROUP BY 1 HAVING count(*) > 1 LIMIT 1;
        IF v_mat IS NOT NULL THEN
            RAISE EXCEPTION 'WO_DUPLICATE_EXPECTED|%', v_mat;
        END IF;
    END IF;

    v_code := next_work_order_code(COALESCE(p_scheduled_date, CURRENT_DATE));
    -- 【注意这个 COALESCE 是给【年份】用的,不是给 scheduled_date 用的】
    -- 存进表里的仍然是 p_scheduled_date 本身(可以是 NULL)。取号要一个年份,
    -- 而"没排期"的单子只能落在今年 —— 这与"永不给日期默认值"不冲突:
    -- 被默认的是号码的年段,不是那句对外的承诺。
    INSERT INTO work_orders (code, status, scheduled_date, notes, created_by, updated_by)
    VALUES (v_code, 'draft', p_scheduled_date, NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user)
    RETURNING id INTO v_id;

    INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
    SELECT v_id, (elem->>'material_id')::uuid, (elem->>'planned_qty')::numeric
      FROM jsonb_array_elements(p_lines) elem;

    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array'
       AND jsonb_array_length(p_expected) > 0 THEN
        -- ════════════════════════════════════════════════════════════════
        -- PROC-SUPPORT-1(R3):每一条预期产出必须说出它的【出处】。
        -- 【自己一条码,不与 WO_EXPECTED_QTY_INVALID 合并】下一步动作不同:
        --   · 数量非法 → 回去改那个数;
        --   · 出处没说 → 回去说这个数【是怎么来的】。
        -- 后者不是一次数据校验,是这一列存在的全部理由 —— 六个月后要分得出
        -- "被真实生产验证过的"与"当初那个猜测"。
        -- 【空字符串与缺席一样被拒】—— 一个空串在数据库里不是 NULL,却和
        -- "没人说过"是同一件事,而它会绕过 NOT NULL 类的检查。
        -- ════════════════════════════════════════════════════════════════
        -- 【一条谓词同时管住"没说"与"说错了"】btrim 之后的空串落不进那三个
        -- 取值里,所以缺席、空串、错值走的是同一条拒绝 —— 它们对操作员是同一件事:
        -- 【这一栏还没有一个正当的答案】。
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_expected) elem
             WHERE btrim(COALESCE(elem->>'basis',''))
                   NOT IN ('planner_estimate','seeded_industry','calibrated')
        ) THEN
            RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
              USING HINT = '每一条预期产出都要说出它是怎么来的:排计划的人估的、照行业经验播的、还是对着真实生产校准过的。没有默认值 —— 漏填是一次失败,不是悄悄补上一个看起来像答案的值。';
        END IF;

        INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty, basis, basis_reference)
        SELECT v_id, (elem->>'material_id')::uuid, (elem->>'expected_qty')::numeric,
               btrim(elem->>'basis'),
               NULLIF(btrim(COALESCE(elem->>'basis_reference','')), '')
          FROM jsonb_array_elements(p_expected) elem;
    END IF;

    INSERT INTO work_order_history (work_order_id, change_type, detail, changed_by)
    VALUES (v_id, 'created', v_code, v_user);

    RETURN jsonb_build_object('work_order_id', v_id, 'code', v_code, 'status', 'draft');
END;
$function$;


-- ── amend_work_order:出处可改,而且改了要留痕 ─────────────────────────────
CREATE OR REPLACE FUNCTION public.amend_work_order(p_work_order_id uuid, p_reason text, p_scheduled_date date DEFAULT NULL::date, p_set_scheduled boolean DEFAULT false, p_notes text DEFAULT NULL::text, p_set_notes boolean DEFAULT false, p_lines jsonb DEFAULT NULL::jsonb, p_expected jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_wo       work_orders%ROWTYPE;
    v_elem     jsonb;
    v_line     work_order_lines%ROWTYPE;
    v_exp      work_order_expected_outputs%ROWTYPE;
    v_basis    text;   -- PROC-SUPPORT-1(R3):这一条预期产出的出处
    v_ref      text;   -- 同上,凭据(自由文本)
    v_mat      uuid;
    v_qty      numeric;
    v_consumed numeric;
    v_changes  integer := 0;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_AMENDABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    -- 【理由必填,而且在动手之前就问】—— 一次没有理由的计划改动,过两天没人
    -- 说得清当时是为了什么(与 hold_stock 的 STK_REASON_REQUIRED 同一条)。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_AMEND_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- ── 表头 ────────────────────────────────────────────────────────────────
    -- 【为什么要 p_set_* 这个布尔】NULL 在这里有两个意思:"不改这一项"与
    -- "把它清空"。少了这个开关,"取消排期"就表达不出来 —— 而取消排期是一件
    -- 真实的事(计划推迟到不知道什么时候)。
    IF p_set_scheduled AND p_scheduled_date IS DISTINCT FROM v_wo.scheduled_date THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_scheduled_date, new_scheduled_date, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.scheduled_date, p_scheduled_date,
                btrim(p_reason), v_user);
        UPDATE work_orders SET scheduled_date = p_scheduled_date WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;
    IF p_set_notes AND NULLIF(btrim(COALESCE(p_notes,'')),'') IS DISTINCT FROM v_wo.notes THEN
        INSERT INTO work_order_history (work_order_id, change_type,
                    old_notes, new_notes, amend_reason, changed_by)
        VALUES (p_work_order_id, 'header_update', v_wo.notes,
                NULLIF(btrim(COALESCE(p_notes,'')),''), btrim(p_reason), v_user);
        UPDATE work_orders SET notes = NULLIF(btrim(COALESCE(p_notes,'')),'')
         WHERE id = p_work_order_id;
        v_changes := v_changes + 1;
    END IF;

    -- ── 计划投料行 ──────────────────────────────────────────────────────────
    -- 每个元素:{material_id, planned_qty}。planned_qty 省略或为 null = 删这一行。
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'planned_qty')::numeric;

            -- 【地板:已经吃掉的量】—— 挂在这张工单上的加工单,吃掉了多少这种料。
            -- 投料腿指向批次,批次才有物料,所以两侧都要 join 过去(进料批与
            -- 再加工的产出批各一条腿,FIN-25 的 XOR)。
            SELECT COALESCE(sum(pi.quantity_consumed), 0) INTO v_consumed
              FROM processing_runs r
              JOIN processing_inputs pi ON pi.run_id = r.id
              LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
              LEFT JOIN output_batches  ob ON ob.id = pi.output_batch_id
             WHERE r.work_order_id = p_work_order_id
               AND r.deleted_at IS NULL
               AND r.status = 'committed'
               AND COALESCE(ib.material_id, ob.material_id) = v_mat;

            SELECT * INTO v_line FROM work_order_lines
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                -- 删行
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_LINE_NOT_FOUND|%', v_mat;
                END IF;
                -- 【删掉一条已经吃过料的行,与把它改成 0 是同一件事】所以同一道地板
                IF v_consumed > 0 THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, 0, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_remove', v_line.id, v_mat,
                        v_line.planned_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_lines WHERE id = v_line.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_LINE_QTY_INVALID';
            ELSIF NOT FOUND THEN
                -- 加行
                INSERT INTO work_order_lines (work_order_id, material_id, planned_qty)
                VALUES (p_work_order_id, v_mat, v_qty) RETURNING * INTO v_line;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_add', v_line.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_line.planned_qty THEN
                -- 改量 —— 地板在这里
                IF v_qty < v_consumed THEN
                    RAISE EXCEPTION 'WO_LINE_BELOW_CONSUMED|%|%|%', v_mat, v_qty, v_consumed;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_line_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'line_update', v_line.id, v_mat,
                        v_line.planned_qty, v_qty, btrim(p_reason), v_user);
                UPDATE work_order_lines SET planned_qty = v_qty WHERE id = v_line.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    -- ── 预期产出行 ──────────────────────────────────────────────────────────
    -- 【预期产出没有地板】它是一句估计,不是一个已经发生的事实 —— 改小它不会
    -- 与任何已经发生的事情矛盾。这与计划投料行刻意不同,而不同的理由值得写下来:
    -- 地板护的是"实绩不可否认",预期产出这一侧没有实绩可否认。
    IF p_expected IS NOT NULL AND jsonb_typeof(p_expected) = 'array' THEN
        FOR v_elem IN SELECT * FROM jsonb_array_elements(p_expected)
        LOOP
            v_mat := (v_elem->>'material_id')::uuid;
            IF v_mat IS NULL OR NOT EXISTS (
                SELECT 1 FROM materials WHERE id = v_mat AND deleted_at IS NULL) THEN
                RAISE EXCEPTION 'WO_EXPECTED_MATERIAL_NOT_FOUND|%', COALESCE(v_mat::text, '?');
            END IF;
            v_qty := (v_elem->>'expected_qty')::numeric;
            -- PROC-SUPPORT-1(R3):出处。**改一行预期产出时它是可选的** ——
            -- 不给就是"这一次不改出处",给了就必须是三个取值之一。
            -- 【新增一行时它是必填的】,那一条在下面的 add 分支里。
            v_basis := NULLIF(btrim(COALESCE(v_elem->>'basis','')), '');
            v_ref   := NULLIF(btrim(COALESCE(v_elem->>'basis_reference','')), '');
            IF v_basis IS NOT NULL
               AND v_basis NOT IN ('planner_estimate','seeded_industry','calibrated') THEN
                RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
                  USING HINT = '出处只有三个取值:planner_estimate / seeded_industry / calibrated。';
            END IF;
            SELECT * INTO v_exp FROM work_order_expected_outputs
             WHERE work_order_id = p_work_order_id AND material_id = v_mat;

            IF v_qty IS NULL THEN
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'WO_EXPECTED_NOT_FOUND|%', v_mat;
                END IF;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_remove', v_exp.id, v_mat,
                        v_exp.expected_qty, NULL, btrim(p_reason), v_user);
                DELETE FROM work_order_expected_outputs WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            ELSIF v_qty <= 0 THEN
                RAISE EXCEPTION 'WO_EXPECTED_QTY_INVALID';
            ELSIF NOT FOUND THEN
                -- PROC-SUPPORT-1(R3):**新增一行必须说出出处。**
                IF v_basis IS NULL THEN
                    RAISE EXCEPTION 'WO_EXPECTED_BASIS_REQUIRED'
                      USING HINT = '新增一条预期产出要说出它是怎么来的:排计划的人估的、照行业经验播的、还是对着真实生产校准过的。';
                END IF;
                INSERT INTO work_order_expected_outputs (work_order_id, material_id, expected_qty, basis, basis_reference)
                VALUES (p_work_order_id, v_mat, v_qty, v_basis, v_ref) RETURNING * INTO v_exp;
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by)
                VALUES (p_work_order_id, 'expected_add', v_exp.id, v_mat, NULL, v_qty,
                        btrim(p_reason), v_user);
                v_changes := v_changes + 1;
            ELSIF v_qty IS DISTINCT FROM v_exp.expected_qty
                  OR (v_basis IS NOT NULL AND v_basis IS DISTINCT FROM v_exp.basis)
                  OR (jsonb_exists(v_elem, 'basis_reference')
                      AND v_ref IS DISTINCT FROM v_exp.basis_reference) THEN
                -- ════════════════════════════════════════════════════════════
                -- PROC-SUPPORT-1(R3):**改出处也算一次改动,而且要留痕。**
                -- 一个数从 seeded_industry 变成 calibrated,是这张表上
                -- 【最重要】的一次变化 —— 那是"猜的"变成"验证过的"那一刻。
                -- 让它悄悄发生,六个月后就没有人说得出它是什么时候变的。
                -- 【出处的新旧值写进 detail】—— old_qty/new_qty 那一对是给数字的,
                -- 借用它去装文本会让那一对的含义在第二种用法上就开始漂。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO work_order_history (work_order_id, change_type, work_order_expected_id,
                            material_id, old_qty, new_qty, amend_reason, changed_by, detail)
                VALUES (p_work_order_id, 'expected_update', v_exp.id, v_mat,
                        v_exp.expected_qty, v_qty, btrim(p_reason), v_user,
                        CASE WHEN v_basis IS NOT NULL AND v_basis IS DISTINCT FROM v_exp.basis
                             THEN format('basis: %s -> %s', COALESCE(v_exp.basis, '(none stated)'), v_basis)
                        END);
                UPDATE work_order_expected_outputs
                   SET expected_qty    = v_qty,
                       basis           = COALESCE(v_basis, basis),
                       basis_reference = CASE WHEN jsonb_exists(v_elem, 'basis_reference')
                                              THEN v_ref ELSE basis_reference END
                 WHERE id = v_exp.id;
                v_changes := v_changes + 1;
            END IF;
        END LOOP;
    END IF;

    IF v_changes = 0 THEN
        RAISE EXCEPTION 'WO_AMEND_NO_CHANGES|%', v_wo.code;
    END IF;

    UPDATE work_orders SET updated_at = now(), updated_by = v_user WHERE id = p_work_order_id;
    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'changes', v_changes);
END;
$function$;

-- ════════════════════════════════════════════════════════════════════════════
-- 第三件 · 班次与交接班(R4 / R5 / R6)
--
-- 【本刀建它,是因为 Tim 已经裁定"照建";本节记的是【怎么】建才不撒谎】
--
-- ★★【最要紧的一句,放在最前面而不是脚注里】★★
-- **交接班要说"这个班处理了什么",而这个库【答不出来】。**
-- 理由是一次测量:`public` 架构里 `time` / `timetz` 类型的列**总数为 0**,
-- 加工这一族唯一的世界侧时间是 `processing_runs.process_date`,一个 **date**。
-- 于是**一张加工单归不到某一个班次上** —— 早班与晚班的单在数据里长得一模一样。
-- 这正是排在阶段 7 的 **G8「一炉的时长 / 跨班次」**。
--
-- 【所以这一栏【不建】,而不是建一个自由文本让人手写】
-- 手写的"这个班处理了 800 公斤"与加工单算出来的数迟早会不一致,
-- 而**人们读到的那一份会是错的那一份**。一个会装猜测的字段比一个缺席的字段更坏:
-- 缺席看得见,不一致看不见。**G8 落地之前,这一栏就是缺的,并且说出它是缺的。**
--
-- ★【本刀新增的 shifts.starts_at / ends_at 是【全库第一个】time 列】★
-- 这件事值得记下来,因为它解释了**为什么那条 join 不存在** ——
-- 不是谁忘了写,是这个库到今天为止【没有任何时刻维度】。
-- 班次有了时刻之后,缺的仍然是加工单那一侧的时刻(G8),不是这一侧。
--
-- 【R5:交接班【指向】,不【复述】】
--   · 设备状态 → 已有载体 equipment_downtime(EQP-2a),一行一段,
--     ended_at 可空表示"还没结束"。交接班挂一条引用,**不抄一份**。
--   · 事故     → 属于那本【尚未建】的 WSH 事故与未遂事件登记簿。
-- 一次事件两份记录,迟早不一致,而人们读到的那一份会是错的那一份。
--
-- ★【事故这一项现在【不留列】】★ 不留一个指向还不存在的表的空外键 ——
-- EQP-2a 已经拒绝过这种做法,原话:「留一个指向不存在的表的空列,读起来像
-- '忘了填'」。WSH 登记簿的触发条件(第一个技师上岗)与交接班真的被填的
-- 触发条件是【同一个】,所以两者会一起解锁,那时再加这一列。
--
-- ★★【R6:NEA 的那项义务【不在】交接班上,而且请不要图省事把它搬过来】★★
-- 「工伤或火灾事故须【立即通报】,并在【两个工作日内】提交书面报告」——
-- 【码】全仓搜索确认:这项义务**今天由任何东西都没有承载**。
--   · company_compliance 装的是【牌照】,不是事故(而且它 0 行,空是事实);
--   · kpi_position_templates 里那两处"2 个工作日"是 KPI 措辞的巧合,不是它;
--   · docs/index-pricing-spec.md 的"3 个工作日"是计价条款,不是它。
-- 它应当落在 forward-queue.md:1198 已经排队的**WSH 事故与未遂事件登记簿**上。
-- **法定时限只能有一个载体。** 交接班里"顺手填一下"会造出第二个,
-- 而两个载体里的时限迟早会有一个是错的 —— 那一个恰好会是被人读到的那一个。
-- (同一条论证 forward-queue.md 已经对保险用过一次:「保险【就是一种证书】,
--  不是第二套到期机制」。)
--
-- 【R4:内容是【数据】不是【代码】】
-- handover_item_types 是一张 RUNTIME CONFIG 字典 —— **第七个交接班字段是
-- 【一行】,不是一次改代码**。形状抄 operation_type_input_forms /
-- _output_forms / operation_type_safety_states 那一套已经被用了三次的 N×M,
-- 以及 output_batch_purposes.is_saleable_stock 那种【规则列】。
--
-- 【第一天它会装什么?几乎什么都没有 —— 照直说】
-- 【码】employees 里 work_category = 'shopfloor' 的人数是 **0**。
-- 所以第一天:没有人交班、没有人接班、没有一条 handover 行。
-- 本刀交付的是【承载它的形状】与【两块屏幕】,不是内容。
-- **Tim 已经接受这一点,而它不许被打扮成别的样子。**
-- ════════════════════════════════════════════════════════════════════════════

-- ── 班次字典 ──────────────────────────────────────────────────────────────
CREATE TABLE public.shifts (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    -- ★ 全库第一个 time 列。可空 —— 【空 = 还没有人说过几点到几点】,不是 00:00。
    starts_at  time,
    ends_at    time,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- 【起止时刻要么都有、要么都没有】只有一头的班次说不出它覆盖哪一段。
    CONSTRAINT shifts_hours_paired CHECK (num_nonnulls(starts_at, ends_at) <> 1)
);

COMMENT ON TABLE public.shifts IS
    'PROC-SUPPORT-1(R4):班次字典。RUNTIME CONFIG —— 加一个班次是加一行。
【Tim:会有两个班】所以引导播两行。班次的【定义】不取决于产线怎么跑,这是它可以现在就建的全部理由。
★【starts_at / ends_at 是这个数据库里【第一对】time 类型的列】★ 在本刀之前,`public` 架构里 time/timetz 类型的列**总数为 0**。记下这件事,因为它解释了下面那条缺口【不是一次疏忽】。
★★【它连不到加工单,而这不是本表的毛病】★★ processing_runs 唯一的世界侧时间是 process_date,一个 **date**。于是**没有任何办法判断一张加工单属于哪一个班次**。那是阶段 7 的 **G8「一炉的时长 / 跨班次」**。在 G8 落地之前,交接班【答不出】"这个班处理了什么" —— 本刀因此**不建那一栏**,而不是建一个会装猜测的自由文本。';

COMMENT ON COLUMN public.shifts.starts_at IS
    '这个班几点开始。**可空,而空的意思是【还没有人说过】,不是 00:00。**
【为什么引导的两行都空着】Tim 说了「会有两个班」—— 那是他的话,所以两行是有出处的;但他【没有】说几点到几点,而这个库的规矩是:一个没人说过的数不许被发明出来填上。与 metal_prices.source 没有默认值、work_order_expected_outputs.basis 没有默认值同一条。Tim 在班次这一屏上填一次,线上就与镜像文件不同,那是系统在正常工作。';

INSERT INTO public.shifts (code, name_en, name_zh, starts_at, ends_at, is_active, sort_order, notes) VALUES
    ('day',   'Day shift',   '早班', NULL, NULL, true, 1,
     '【Tim:会有两个班】名字有出处,时刻没有 —— 所以时刻留空,等他说。'),
    ('night', 'Night shift', '晚班', NULL, NULL, true, 2,
     '同上。**两行都不带时刻是刻意的**,不是漏填。');

ALTER TABLE public.shifts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shifts select all" ON public.shifts
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "shifts write by permission" ON public.shifts
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shifts TO authenticated;

-- ── 交接班内容字典(R4:第七项 = 一行,不是一次改代码)────────────────────
CREATE TABLE public.handover_item_types (
    code        text PRIMARY KEY,
    name_en     text NOT NULL,
    name_zh     text NOT NULL,
    is_required boolean NOT NULL DEFAULT false,
    sort_order  integer NOT NULL DEFAULT 0,
    is_active   boolean NOT NULL DEFAULT true,
    notes       text
);

COMMENT ON TABLE public.handover_item_types IS
    'PROC-SUPPORT-1(R4):交接班【记哪几类内容】。RUNTIME CONFIG —— ★ 第七个交接班字段是【加一行】,不是一次改代码 ★,那正是 Tim 要的形状。
形状抄仓库里已经被用了三次的那一套(operation_type_input_forms / _output_forms / operation_type_safety_states),规则列抄 output_batch_purposes.is_saleable_stock:**行为由数据回答,不由写死的字符串回答。**
★【第一天这张字典里只有【一行】,而那正是重点】★ Tim 列的七项确定内容里:
  · 哪个班、几点到几点 → shifts 那张表(时刻待 Tim 填);
  · 谁交给谁 / 接班人签收 → shift_handovers 上的列(它们是每张交接班【恰好一份】的事实,不是可增删的条目);
  · 设备状态 → **引用** equipment_downtime(R5,不复述);
  · 事故 → 属于那本尚未建的 WSH 登记簿(R5/R6),**现在连列都不留**;
  · 这个班处理了什么 → **答不出来,阻塞在 G8**,所以不建;
  · 未完成工作 → **就是这一行**,而且它是这一件里【唯一】没有现成载体的实质内容。
所以一行不是"建少了",是把每一项都放回了它该在的地方之后剩下的那一项。';

COMMENT ON COLUMN public.handover_item_types.is_required IS
    '这一类内容是不是【必须至少有一条】才算交接完成。规则列 —— 由数据回答,不由代码里的 if 回答(抄 output_batch_purposes.is_saleable_stock)。
【unfinished_work 引导为 false,理由要说出来】"没有未完成的工作"是一个【合法且常见】的班次结果,而必填会逼着人写一句"无" —— 那句"无"与"没人填"在数据里长得一样,于是必填反而毁掉了这一栏的意义。这与 inbound_batches 那条"没有行 = 没人记录过,不是记录了零"同一条。';

INSERT INTO public.handover_item_types (code, name_en, name_zh, is_required, sort_order, is_active, notes) VALUES
    ('unfinished_work', 'Unfinished work', '未完成工作', false, 1, true,
     '料还在机器里、批次喂了一半、某台机器停在半程 —— **这一件里唯一没有现成载体的实质内容**。引导 is_required = false:"这个班没有未完成的工作"是一个合法结果,必填会逼出一句毫无信息量的"无"。');

ALTER TABLE public.handover_item_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "handover_item_types select all" ON public.handover_item_types
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "handover_item_types write by permission" ON public.handover_item_types
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.handover_item_types TO authenticated;

-- ── 交接班本体 ────────────────────────────────────────────────────────────
CREATE TABLE public.shift_handovers (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_code           text NOT NULL REFERENCES public.shifts (code),
    handover_date        date NOT NULL,
    outgoing_employee_id uuid NOT NULL REFERENCES public.employees (id),
    incoming_employee_id uuid NOT NULL REFERENCES public.employees (id),
    notes                text,
    submitted_at         timestamptz NOT NULL DEFAULT now(),
    submitted_by         uuid,
    -- ★【签收:没签 vs 签了】两列一起空、一起满。抄 attendance_lines.recorded_at
    --   那条"没记 vs 记了是零"的形状。
    acknowledged_at      timestamptz,
    acknowledged_by      uuid REFERENCES public.employees (id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid,
    CONSTRAINT shift_handover_one_per_shift_date UNIQUE (shift_code, handover_date),
    -- 一个人不能交给自己 —— 那样的"交接"没有传递任何东西。
    CONSTRAINT shift_handover_two_people
        CHECK (outgoing_employee_id <> incoming_employee_id),
    -- ★ 签收的两列要么都空(未签收),要么都满(签收了,而且说得出是谁、什么时候)。
    --   只有时间没有人 = 一次说不出是谁签的签收,那比没签更坏。
    CONSTRAINT shift_handover_ack_paired
        CHECK (num_nonnulls(acknowledged_at, acknowledged_by) <> 1)
);

COMMENT ON TABLE public.shift_handovers IS
    'PROC-SUPPORT-1(R4/R5):一次交接班。**它【指向】别处的记录,不【复述】它们。**
【一张交接班上确定有的东西】哪个班(shift_code)、哪一天、谁交给谁、接班人的签收。
【刻意【没有】的东西,逐条给理由 —— 请不要"补全"它们】
  ① **"这个班处理了什么、多少" —— 没有这一栏。** processing_runs 只有 process_date(一个 date),全库 time 列在本刀之前为 0,所以**一张加工单归不到某一个班次上**。这是阶段 7 的 **G8**。一个自由文本会装一个猜测,而那个猜测会与加工单算出来的数打架 —— **人们读到的那一份会是错的那一份**。缺席看得见,不一致看不见。
  ② **设备状态 —— 不在这张表上,在 equipment_downtime(EQP-2a)。** 交接班经 shift_handover_equipment_refs 挂一条【引用】。同一件事记两遍,迟早不一致。
  ③ **事故 —— 连一列都不留。** 它属于那本尚未建的 WSH 事故与未遂事件登记簿(forward-queue.md:1198,触发条件"第一个技师上岗")。留一个指向不存在的表的空外键,读起来像"忘了填" —— EQP-2a 已经按名拒绝过这种做法。
  ④ **NEA 的法定时限(立即通报 / 两个工作日内书面报告)不在这里。** 见 R6 与 docs/processing-support-as-built.md:法定时限只能有一个载体。
【第一天它会装什么】**零行。** 线上 work_category = ''shopfloor'' 的员工数是 **0** —— 没有人交班,也没有人接班。本刀交付的是形状与屏幕,不是内容,而这一点不许被打扮成别的样子。';

COMMENT ON COLUMN public.shift_handovers.acknowledged_at IS
    'PROC-SUPPORT-1(R4):接班人签收的时刻。**空 = 还没有人签收**,不是"签收了但没记时间"。
与 acknowledged_by 由 shift_handover_ack_paired 绑成一对:要么都空,要么都满。**一次说不出是谁签的签收比没签更坏** —— 它看起来像有人负责了。
【未签收必须在屏幕上看得见】不是靠一个空白格,而是一个具名的状态(【待签收】)。空白格读起来像"这一栏不重要"。';

COMMENT ON COLUMN public.shift_handovers.acknowledged_by IS
    'PROC-SUPPORT-1(R4):是谁签收的 —— 一个 employees 引用,不是一个 auth 用户 id。
【为什么指向 employees 而不是 user_id】交接班是【车间里两个人】之间的事,而不是两个登录账号之间的事;一个技师可能共用工位账号,而"谁接的班"必须是一个人。acknowledge_shift_handover() 只认 current_user_employee(),并且**只允许这张交接班点名的那位接班人签收** —— 见该函数的函数头。';

ALTER TABLE public.shift_handovers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handovers select by permission" ON public.shift_handovers
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "shift_handovers write by permission" ON public.shift_handovers
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_handovers TO authenticated;

CREATE TRIGGER trg_shift_handovers_updated_at
    BEFORE UPDATE ON public.shift_handovers
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ── 交接班条目(内容 = 行)──────────────────────────────────────────────
CREATE TABLE public.shift_handover_items (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    handover_id    uuid NOT NULL REFERENCES public.shift_handovers (id) ON DELETE CASCADE,
    item_type_code text NOT NULL REFERENCES public.handover_item_types (code),
    body           text NOT NULL,
    sort_order     integer NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    CONSTRAINT shift_handover_item_body_stated CHECK (btrim(body) <> '')
);

COMMENT ON TABLE public.shift_handover_items IS
    'PROC-SUPPORT-1(R4):交接班的逐条内容。**一类内容可以有【多条】** —— 三件没做完的活是三行,不是一段挤在一起的文字,因为下一个班要一件一件地接。
【为什么没有 (handover_id, item_type_code) 唯一约束】那会把"三件未完成的工作"压成一行文本,而**一段文本没法逐件被接手、被划掉**。
【body 不许是空串】一条内容为空的条目与没有这条条目是同一件事,而它会在计数里冒充"填过了"。';

ALTER TABLE public.shift_handover_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handover_items select by permission" ON public.shift_handover_items
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "shift_handover_items write by permission" ON public.shift_handover_items
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_handover_items TO authenticated;

-- ── 设备状态:一条【引用】,不是一份副本(R5)────────────────────────────
CREATE TABLE public.shift_handover_equipment_refs (
    handover_id uuid NOT NULL REFERENCES public.shift_handovers (id) ON DELETE CASCADE,
    downtime_id uuid NOT NULL REFERENCES public.equipment_downtime (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    PRIMARY KEY (handover_id, downtime_id)
);

COMMENT ON TABLE public.shift_handover_equipment_refs IS
    'PROC-SUPPORT-1(R5):这次交接班【指着】哪几段设备停机。
★★【为什么是一张引用表,而不是交接班上的几个字段】★★ 设备状态已经有载体:equipment_downtime(EQP-2a),一行一段,ended_at 可空正好表示"到交班这一刻还没结束" —— 那恰恰是交班的人要说的话。
**一次事件两份记录,迟早会不一致,而人们读到的那一份会是错的那一份。** 所以这里存的是 downtime_id,不是 reason 的一份抄写。想知道那台机器怎么了,读 equipment_downtime;这张表只回答"交班的人当时要下一个班注意哪几段"。
同一条论证 forward-queue.md 已经对保险用过一次:「保险【就是一种证书】,不是第二套到期机制」。';

ALTER TABLE public.shift_handover_equipment_refs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handover_equipment_refs select by permission" ON public.shift_handover_equipment_refs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "shift_handover_equipment_refs write by permission" ON public.shift_handover_equipment_refs
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_handover_equipment_refs TO authenticated;

-- ── 车间上能看见的人 ──────────────────────────────────────────────────────
-- ★【为什么需要这张视图,而不是直接读 employees】★
-- 【码】employees 的 SELECT 策略要 module.hr.view。一个只有 module.processing.*
-- 的车间技师**读不到任何人的名字** —— 于是交接班那两个下拉框会是空的,
-- 而屏幕上没有任何解释。**那正是 docs/silent-disable-inventory.md 记的那个病。**
-- 【为什么这不是一次放宽】这张视图只透出 id / code / preferred_name 三列。
-- legal_name、身份、联系方式、薪酬**一列都不透** —— 那些本来就靠
-- employees_masked 的字段级遮蔽护着,与本视图无关。
-- 属主权限 + 把模块谓词原样写回视图体,形状抄 processing_runs_masked。
CREATE VIEW public.handover_people WITH (security_invoker = off) AS
 SELECT e.id,
        e.code,
        e.preferred_name,
        e.work_category
   FROM employees e
  WHERE e.deleted_at IS NULL
    AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.handover_people IS
    'PROC-SUPPORT-1(R4):交接班那两个人选框读的名单。
【为什么它存在】employees 的行策略要 module.hr.view,而交接班的使用者是车间技师(module.processing.*)。不给这张视图,两个下拉框会**静默地空着** —— 屏幕上没有任何解释,而这正是 docs/silent-disable-inventory.md 记的那个病。
【它透出什么、不透出什么】只有 id / code / preferred_name / work_category 四列。legal_name、身份证件、联系方式、薪酬**一列都不透**(那些由 employees_masked 的字段级遮蔽护着,与本视图无关)。**给同事看见同事的工号与称呼是相称的;给他看见薪酬不是。**
★【第一天它会返回几行?】★ 未软删员工 6 人(2 真 + 4 张 ZZ 刮擦行),而 work_category = ''shopfloor'' 的是 **0 人**。**本视图刻意【不】按 work_category 过滤** —— 过滤会让它第一天返回 0 行,于是屏幕在还没有技师的时候连"这里应该有人"都说不出来;而按 work_category 限制谁能交接班,本身是一条【没有人下过】的政策裁定。不发明它。';

GRANT SELECT ON public.handover_people TO authenticated;

-- ── 提交一次交接班 ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.submit_shift_handover(
    p_shift_code text,
    p_handover_date date,
    p_outgoing_employee_id uuid,
    p_incoming_employee_id uuid,
    p_notes text DEFAULT NULL::text,
    p_items jsonb DEFAULT NULL::jsonb,
    p_downtime_ids uuid[] DEFAULT NULL::uuid[]
)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_elem jsonb;
    v_bad  text;
BEGIN
    PERFORM require_permission('module.processing.edit');

    -- 【世界侧日期不给默认值】与 FIN-10「永不给日期默认值」同一条:
    -- 交接班发生在哪一天是一件世界里的事实,不是 now() 的一个副产品。
    IF p_handover_date IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_DATE_REQUIRED';
    END IF;
    IF p_shift_code IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shifts WHERE code = p_shift_code AND is_active) THEN
        RAISE EXCEPTION 'HANDOVER_SHIFT_UNKNOWN|%', p_shift_code
          USING HINT = '未知或已停用的班次。停用的意思是"以后别再排它",不是"把历史改掉"。';
    END IF;
    -- 【交与接【两个人都要有名有姓】】一次说不出是谁交的班,不是一次交接班。
    IF p_outgoing_employee_id IS NULL OR p_incoming_employee_id IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_PEOPLE_REQUIRED'
          USING HINT = '交班的人与接班的人都要点名 —— 一次说不出是谁交给谁的交接班,没有传递任何责任。';
    END IF;
    IF p_outgoing_employee_id = p_incoming_employee_id THEN
        RAISE EXCEPTION 'HANDOVER_SAME_PERSON'
          USING HINT = '交班人与接班人是同一个人 —— 那样的"交接"没有把任何东西传给任何人。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_outgoing_employee_id AND deleted_at IS NULL)
       OR NOT EXISTS (SELECT 1 FROM employees WHERE id = p_incoming_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'HANDOVER_EMPLOYEE_NOT_FOUND';
    END IF;

    -- 【条目的类型必须是字典里的】—— 加第七类内容是【加一行字典】,
    -- 而不是在这里放行一个自由字符串。
    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        SELECT elem->>'item_type_code' INTO v_bad
          FROM jsonb_array_elements(p_items) elem
         WHERE NOT EXISTS (SELECT 1 FROM handover_item_types t
                            WHERE t.code = elem->>'item_type_code' AND t.is_active)
         LIMIT 1;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_TYPE_UNKNOWN|%', v_bad;
        END IF;
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) elem
                    WHERE btrim(COALESCE(elem->>'body','')) = '') THEN
            RAISE EXCEPTION 'HANDOVER_ITEM_BODY_REQUIRED'
              USING HINT = '一条内容为空的条目与没有这条条目是同一件事,而它会在计数里冒充"填过了"。';
        END IF;
    END IF;

    -- 【必填的那几类:字典说了算,不是代码说了算】
    SELECT t.name_zh INTO v_bad
      FROM handover_item_types t
     WHERE t.is_active AND t.is_required
       AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(COALESCE(p_items,'[]'::jsonb)) elem
            WHERE elem->>'item_type_code' = t.code
              AND btrim(COALESCE(elem->>'body','')) <> '')
     LIMIT 1;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'HANDOVER_REQUIRED_ITEM_MISSING|%', v_bad;
    END IF;

    INSERT INTO shift_handovers (shift_code, handover_date, outgoing_employee_id,
                                 incoming_employee_id, notes, submitted_by, created_by, updated_by)
    VALUES (p_shift_code, p_handover_date, p_outgoing_employee_id, p_incoming_employee_id,
            NULLIF(btrim(COALESCE(p_notes,'')), ''), v_user, v_user, v_user)
    RETURNING id INTO v_id;

    IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
        INSERT INTO shift_handover_items (handover_id, item_type_code, body, sort_order, created_by)
        SELECT v_id, elem->>'item_type_code', btrim(elem->>'body'),
               COALESCE((elem->>'sort_order')::integer, ord::integer), v_user
          FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(elem, ord);
    END IF;

    -- R5:设备状态是一条【引用】。这里存 downtime_id,绝不抄一份 reason。
    IF p_downtime_ids IS NOT NULL AND array_length(p_downtime_ids, 1) > 0 THEN
        IF EXISTS (SELECT 1 FROM unnest(p_downtime_ids) d
                    WHERE NOT EXISTS (SELECT 1 FROM equipment_downtime e WHERE e.id = d)) THEN
            RAISE EXCEPTION 'HANDOVER_DOWNTIME_NOT_FOUND';
        END IF;
        INSERT INTO shift_handover_equipment_refs (handover_id, downtime_id, created_by)
        SELECT v_id, d, v_user FROM unnest(p_downtime_ids) d
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_id;
END;
$function$;

COMMENT ON FUNCTION public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[]) IS
    'PROC-SUPPORT-1(R4/R5):提交一次交接班 —— 表头、逐条内容、设备停机引用,一次事务写完。
【它【不】收"这个班处理了什么"】那一栏在这一刀里不存在:加工单只有 process_date(一个 date),归不到班次上,那是 G8。**加一个自由文本参数会让这个函数收下一个猜测**,而那个猜测将来会与加工单打架。
【它【不】收事故】那属于尚未建的 WSH 登记簿(R6)。NEA 的"立即通报 + 两个工作日内书面报告"只能有一个载体。
【必填哪几类内容,由 handover_item_types.is_required 这一列回答】—— 不是由这个函数里的一串 if 回答。第七类内容是加一行字典。';

REVOKE EXECUTE ON FUNCTION public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[]) TO authenticated, service_role;

-- ── 签收 ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.acknowledge_shift_handover(p_handover_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ho  shift_handovers%ROWTYPE;
    v_emp uuid := current_user_employee();
BEGIN
    PERFORM require_permission('module.processing.edit');

    SELECT * INTO v_ho FROM shift_handovers WHERE id = p_handover_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'HANDOVER_NOT_FOUND|%', p_handover_id;
    END IF;
    IF v_ho.acknowledged_at IS NOT NULL THEN
        RAISE EXCEPTION 'HANDOVER_ALREADY_ACKNOWLEDGED|%', v_ho.acknowledged_at
          USING HINT = '这张交接班已经被签收过了。**签收不是一个可以重来的动作** —— 覆盖它会把第一次签收的人与时刻抹掉,而那正是这一列存在的理由。';
    END IF;
    -- ════════════════════════════════════════════════════════════════════════
    -- ★【签收的人必须【是这张交接班点名的那位接班人】】★
    -- Tim 的原话是"**接班的那个人**的签收"。放宽成"任何有权限的人都能签",
    -- 这一列就退化成一个时间戳 —— 它会永远是满的,而它本来要回答的问题
    -- (**下一个班的人真的看过这些话了吗**)从此没有答案。
    -- 【为什么按 employee 而不是按 auth 用户】车间可能共用工位账号,
    -- 而"谁接的班"必须是一个人。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'HANDOVER_ACK_NO_EMPLOYEE'
          USING HINT = '签收要落到一个【员工】身上,而这个登录账号没有对应的员工档案。签收是一个人做的事,不是一个账号做的事。';
    END IF;
    IF v_emp <> v_ho.incoming_employee_id THEN
        RAISE EXCEPTION 'HANDOVER_ACK_NOT_INCOMING'
          USING HINT = '只有这张交接班点名的那位【接班人】能签收它。别人代签,这一栏就只是一个时间戳,而它本来要回答的是"下一个班的人真的看过这些话了吗"。接班的人换了,就先把交接班改成他。';
    END IF;

    UPDATE shift_handovers
       SET acknowledged_at = now(),
           acknowledged_by = v_emp,
           updated_by      = auth.uid()
     WHERE id = p_handover_id;

    RETURN p_handover_id;
END;
$function$;

COMMENT ON FUNCTION public.acknowledge_shift_handover(uuid) IS
    'PROC-SUPPORT-1(R4):接班人签收一张交接班 —— 记下【是谁】与【什么时候】。
【三条具名拒绝,而且它们的下一步动作各不相同】
  HANDOVER_ALREADY_ACKNOWLEDGED → 已经签过了,别覆盖第一次的人与时刻;
  HANDOVER_ACK_NO_EMPLOYEE      → 这个登录账号没有员工档案,去补档案;
  HANDOVER_ACK_NOT_INCOMING     → 你不是这张交接班点名的接班人,先改交接班。
【为什么只许接班人本人签】放宽成"任何有权限的人都能签",这一列就退化成一个永远是满的时间戳,而它本来要回答的问题(下一个班的人真的看过这些话了吗)从此没有答案。';

REVOKE EXECUTE ON FUNCTION public.acknowledge_shift_handover(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.acknowledge_shift_handover(uuid) TO authenticated, service_role;

COMMIT;

-- FIN-36:分摊基准必须是【选出来的】,不是默认出来的
--
-- processing_runs.allocation_basis 带着 DEFAULT 'metal_value',commit_processing_run
-- 从不设它,于是线上九张加工单【全部】拿着那个默认值 —— 成本方法是被一个谁也没见过的
-- schema 默认值挑的。Doc 2 明写这是错的:"重新设计后的模块把分摊基准做成一个显式、
-- 可配置的选择,而不是一个隐含假设 —— 因为这个答案直接决定每个产出批次的报告毛利。"
-- FIN-25 已经量过两种基准给出实质不同的单位成本(同一张单 62.50 对 27.50),
-- OPS-20 的批次毛利就坐在它上面。
--
-- 【区别不在"有没有默认值",在于谁看得见】一个 schema 默认值没有人看得见、也无法改;
-- 一个表单预选项【看得见、改得动、并且记下了选的是什么】。后者完全正当 ——
-- 所以本切做的是把前者换成后者,而不是简单地把默认值删掉了事。
--
-- 四件事:
--   1. finance_settings.default_allocation_basis —— 公司默认值【声明出来】,
--      与 fy_end_month / system_start_date 同一形状(RUNTIME CONFIG,操作员可改)。
--      表单从这里预选。它自己带默认值是【正当的】:那是一条配置行的初值,
--      操作员在设置页上看得见(FIN-35 的判别法:看得见的默认值不是假设)。
--   2. processing_runs.allocation_basis 去掉 schema 默认值,并由
--      commit_processing_run 的新参数【必填】—— 缺就 ALLOCATION_BASIS_REQUIRED 点名拒绝。
--      【为什么不在函数里回退到配置值】那只会把"没人选过"从 schema 挪到函数里,
--      同一个病换一层。表单永远带着值来(预选自配置),所以"必填"没有代价。
--   3. 基准变更成为【第四个过期源】。此前 is_stale 只看成本条目、输入批的
--      price_history、上游单重分摊 —— 一次 UPDATE ... SET allocation_basis 会
--      让存着的单位成本与单据自称的方法对不上,而没有任何信号。这正是 FIN-25
--      给输入价格关掉的那个缺口,换了个来源。
--   4. 九张既有单不改:它们的 metal_value 是【真的】—— 算术当时用的就是它。
--      假的只是"有人选过"这层含义,而它们在 cutover 会消失(known-wrong 有记)。
--
-- 【只实现了两种基准,Doc 2 说三种 —— 这是一条分歧,不在本切里补】
-- 缺的是"按各产出的市场价值"分摊。记在 docs/as-built-divergences.md,
-- 不在这里顺手建:它需要每个产出批次的市场价,而那是另一套取数。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

-- ── 1. 公司默认值:声明出来的配置,不是编进代码的常量 ────────────────────────
ALTER TABLE public.finance_settings
    ADD COLUMN default_allocation_basis text NOT NULL DEFAULT 'metal_value'
        CHECK (default_allocation_basis IN ('weight','metal_value'));

COMMENT ON COLUMN public.finance_settings.default_allocation_basis IS
    '新建加工单时表单【预选】的分摊基准(FIN-36)。这是一个 RUNTIME CONFIG:操作员在设置页上看得见、改得动 —— 与 processing_runs 上那个已被删掉的 schema 默认值的区别就在这里,后者谁也看不见。真正记录"这一单用了什么"的仍然是 processing_runs.allocation_basis,由表单显式送上来。';

-- ── 2. 运行单上的基准:去掉 schema 默认值 ──────────────────────────────────
ALTER TABLE public.processing_runs ALTER COLUMN allocation_basis DROP DEFAULT;

COMMENT ON COLUMN public.processing_runs.allocation_basis IS
    '这一单的成本分摊基准 —— 【选出来的,不是默认出来的】(FIN-36)。没有 schema 默认值是有意的:成本方法直接决定每个产出批次的报告毛利(FIN-25 量过 62.50 对 27.50),而一个谁也看不见的默认值等于替所有人做了这个判断。commit_processing_run 必填,表单从 finance_settings.default_allocation_basis 预选。改动它会把本单标记为过期(见 allocation_basis_changed_at)。';

-- ── 3. 基准变更时点:第四个过期源 ────────────────────────────────────────────
ALTER TABLE public.processing_runs
    ADD COLUMN allocation_basis_changed_at timestamptz;

COMMENT ON COLUMN public.processing_runs.allocation_basis_changed_at IS
    '分摊基准最后一次被改动的时点(FIN-36),由 trg_processing_runs_basis_changed 维护。processing_run_allocation_status.is_stale 与 batch_margin.is_stale 把它当【第四个过期源】—— 前三个是成本条目、输入批的 price_history、上游单重分摊。少了它,一次 UPDATE ... SET allocation_basis 会让存着的单位成本与单据自称的方法对不上而毫无信号。allocate_processing_costs 在同一个事务里改基准并重算,两个时点相等,所以重分摊【不会】把自己标成过期。';

CREATE OR REPLACE FUNCTION public.stamp_allocation_basis_changed()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- now() 是事务时间:allocate_processing_costs 在同一个事务里既改基准又写
    -- allocated_at,两者相等,而 is_stale 用的是【严格大于】—— 所以重分摊不会
    -- 把自己标成过期。一次裸 UPDATE 则晚于 allocated_at,正是要抓的那种。
    NEW.allocation_basis_changed_at := now();
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_processing_runs_basis_changed
    BEFORE UPDATE OF allocation_basis ON public.processing_runs
    FOR EACH ROW
    WHEN (NEW.allocation_basis IS DISTINCT FROM OLD.allocation_basis)
    EXECUTE FUNCTION public.stamp_allocation_basis_changed();

REVOKE SELECT ON public.processing_runs FROM authenticated, anon;
GRANT SELECT (id, code, process_date, total_input, total_output, loss_qty, notes,
              status, deleted_at, created_at, created_by, updated_at, updated_by,
              allocation_basis, allocation_snapshot, allocated_at, allocated_by,
              capitalization_entry_id, allocation_basis_changed_at)
    ON public.processing_runs TO authenticated;


-- ── 4. commit_processing_run 收下基准并必填 ────────────────────────────────
-- 【DROP + CREATE,不是 CREATE OR REPLACE】签名变了就是重载而不是替换,
-- db/preflight_migration.py 会拒(FIN-21 的教训:旧签名会活下来变成镜像看不见的漂移)。
-- DROP 带走的 EXECUTE 由 apply_migration.sh 在同事务里补跑 zzz_function_grants 授回。
DROP FUNCTION public.commit_processing_run(date, text, numeric, jsonb, jsonb);

CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text)
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
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
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
    IF p_allocation_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', p_allocation_basis;
    END IF;

    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
        RAISE EXCEPTION 'NO_OUTPUTS';
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
        IF v_consumed > v_remaining THEN
            RAISE EXCEPTION 'CONSUMED_EXCEEDS_REMAINING|%|%', v_consumed, v_remaining;
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

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status,
        allocation_basis, created_by, updated_by
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        COALESCE(p_loss_qty, v_total_input - v_total_output),
        p_notes, 'committed', p_allocation_basis, v_user_id, v_user_id
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
            SELECT remaining_qty INTO v_remaining
            FROM inbound_batches WHERE id = v_inbound_id;
            v_new_remaining := v_remaining - v_consumed;

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_inbound_id;

            INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
            VALUES (v_inbound_id, 'processing_consume', -v_consumed, v_run_id, v_process_date, v_user_id);

            INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
            VALUES (v_run_id, v_inbound_id, v_consumed);
        ELSE
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

            INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
            VALUES (v_output_id, 'processing_consume', -v_consumed, v_run_id, v_process_date, v_user_id);

            INSERT INTO processing_inputs (run_id, output_batch_id, quantity_consumed)
            VALUES (v_run_id, v_output_id, v_consumed);
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

COMMIT;

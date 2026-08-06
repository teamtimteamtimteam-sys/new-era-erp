-- db/migrations/2026-08-06-fin25-reprocessing.sql
--
-- FIN-25:再加工 —— 产出批喂回下一段加工。立账公理是全链路可溯,粉线多段加工
-- 是大概率需求;FIN-24 时它在 schema 上不可表示(known-issues 有账,本切同一
-- commit 清账 —— 拆分扩展与模型改动必须同落,否则第一炉二段加工就记错科目)。
--
-- 【成本传导不递归】FIN-24 的停车-收回本来就是通解:上游差额里"被下游耗掉"的
-- 份额 → 5000 停车 + 下游过期(状态视图第三支);下游重跑,其材料差额贷 5000
-- 收回。一条边一步,靠过期旗逐级走;边永远指向更早的提交(B 只能耗 A 已存在的
-- 产出),图是有限 DAG,每步幂等 —— 三段链三次重跑收敛,每步各自正确。
--
-- 【无价上游:允许,不拒绝】(Tim 裁定)车间按天,财务分摊按月 —— 拒绝让车间等
-- 财务。零不静默:cost_incomplete 打在产出上、层层传染,上游补分摊后下游过期,
-- 重跑即清。
--
-- 【预检(FIN-23b 例)】新触发器函数 → REVOKE(本迁移内);新视图 → GRANT
-- authenticated;1200/1220/5000/5200 已全 is_system;processing_outputs 是列清单
-- 授权表 → 新列同迁移进 GRANT + masked 视图(FIN-6 之坑)。

BEGIN;

-- ── 1. processing_inputs:双亲 XOR(inventory_movements/payment_allocations 同款)──
ALTER TABLE public.processing_inputs ALTER COLUMN inbound_batch_id DROP NOT NULL;
ALTER TABLE public.processing_inputs ADD COLUMN output_batch_id uuid REFERENCES public.output_batches (id);
ALTER TABLE public.processing_inputs ADD CONSTRAINT processing_inputs_one_parent
    CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1);
CREATE INDEX idx_processing_inputs_output ON public.processing_inputs (output_batch_id);

COMMENT ON COLUMN public.processing_inputs.output_batch_id IS
    '再加工投料:消耗的上游产出批(FIN-25)。与 inbound_batch_id 恰一非空。估值用上游 processing_outputs.unit_cost_base,解除的是 1220 而非 1200。';

-- 自吞守卫:一张单不能消耗自己的产出。经 commit_processing_run 走【按时序不可能】
-- (产出在提交时才诞生),但本表有直插 RLS 策略(module.processing.edit),裸
-- INSERT 能造出同单边。【这个触发器同时堵住进料边的既有直插洞】—— 直插进料边
-- 不会扣 remaining_qty,账实即分道;所以两种边的直插一律拒,只放行函数上下文。
-- 【别因为"只有再加工用它"而删】:它守的是两侧。
CREATE OR REPLACE FUNCTION public.guard_processing_input()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF current_setting('evoltrya.movement_ctx', true) NOT LIKE 'processing:%'
       AND current_setting('evoltrya.movement_ctx', true) NOT LIKE 'reversal:%' THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_DIRECT_INSERT';
    END IF;
    IF NEW.output_batch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM processing_outputs po
        WHERE po.output_batch_id = NEW.output_batch_id AND po.run_id = NEW.run_id
    ) THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_SELF_CONSUME|%', NEW.run_id;
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_processing_input() FROM PUBLIC, anon;
CREATE TRIGGER trg_processing_inputs_guard
    BEFORE INSERT ON public.processing_inputs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_input();

-- ── 2. processing_outputs:不完整成本标记(列清单授权表 —— 同迁移进 GRANT + masked)──
ALTER TABLE public.processing_outputs ADD COLUMN cost_incomplete boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.processing_outputs.cost_incomplete IS
    '本产出的单位成本含【计 0 的无价投料】或【上游产出自己带着此标记】(FIN-25)。零永不静默,层层传染;上游补分摊后本单过期(状态视图第三支),重跑分摊即清。';
GRANT SELECT (cost_incomplete) ON public.processing_outputs TO authenticated;

CREATE OR REPLACE VIEW public.processing_outputs_masked WITH (security_invoker = off) AS
 SELECT id,
    run_id,
    output_batch_id,
    quantity_produced,
    created_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN allocated_cost_base
            ELSE NULL::numeric
        END AS allocated_cost_base,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_cost_base
            ELSE NULL::numeric
        END AS unit_cost_base,
    cost_incomplete
   FROM processing_outputs
  WHERE has_permission('module.processing.view'::text);

-- ── 3. commit_processing_run ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb)
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
        process_date, total_input, total_output, loss_qty, notes, status, created_by, updated_by
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        COALESCE(p_loss_qty, v_total_input - v_total_output),
        p_notes, 'committed', v_user_id, v_user_id
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

    RETURN v_run_id;
END;
$function$;

-- ── 4. rollback_processing_run ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. 锁定加工单，校验存在且未删除
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, created_by)
                VALUES (v_input.inbound_batch_id, 'reversal_restore', v_new_remaining - COALESCE(v_old_remaining, 0), p_run_id, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, run_id, created_by)
                VALUES (v_input.output_batch_id, 'reversal_restore', v_new_remaining - COALESCE(v_old_remaining, 0), p_run_id, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    UPDATE output_batches
    SET deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
END;
$function$;

-- ── 5. allocate_processing_costs ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(ib.unit_price, 0)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', 'SGD', 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', 'SGD', 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', 'SGD', 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'SGD', 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'SGD', 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'SGD', 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- ── 6. 状态视图:第三过期源 —— 上游重分摊(其 allocated_at 即单位成本的变时点)──
DROP VIEW public.processing_run_allocation_status;
CREATE VIEW public.processing_run_allocation_status WITH (security_invoker = on) AS
 SELECT r.id AS run_id,
    r.code,
    r.allocated_at,
    c.last_cost_change,
    r.allocated_at IS NOT NULL AND c.last_cost_change IS NOT NULL AND c.last_cost_change > r.allocated_at AS is_stale,
    COALESCE(g.cogs_posted, 0::bigint) AS cogs_posted,
    (r.capitalization_entry_id IS NULL OR je.status = 'posted') AS safe_to_reallocate
   FROM processing_runs r
     LEFT JOIN journal_entries je ON je.id = r.capitalization_entry_id
     LEFT JOIN LATERAL ( SELECT max(x.ts) AS last_cost_change
           FROM ( SELECT GREATEST(e.created_at, e.updated_at) AS ts
                    FROM processing_cost_entries e
                   WHERE e.run_id = r.id
                  UNION ALL
                  SELECT ph.created_at
                    FROM price_history ph
                    JOIN processing_inputs pi ON pi.inbound_batch_id = ph.inbound_batch_id
                   WHERE pi.run_id = r.id
                  UNION ALL
                  -- FIN-25:上游重分摊 = 本单再加工投料的估值变了
                  SELECT r2.allocated_at
                    FROM processing_inputs pi2
                    JOIN processing_outputs po2 ON po2.output_batch_id = pi2.output_batch_id
                    JOIN processing_runs r2 ON r2.id = po2.run_id
                   WHERE pi2.run_id = r.id AND r2.allocated_at IS NOT NULL) x) c ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS cogs_posted
           FROM sales_records sr
             JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = r.id
          WHERE sr.cogs_entry_id IS NOT NULL) g ON true
  WHERE r.deleted_at IS NULL;
GRANT SELECT ON public.processing_run_allocation_status TO authenticated;

-- ── 7. 回收率视图:投入金属两路来源(修静默错报 —— 旧内联 join 丢掉产出边投料,
--     投入金属被低报、回收率被【高报】,而这是评判工艺的数字)──
DROP VIEW public.processing_metal_recovery;
CREATE VIEW public.processing_metal_recovery WITH (security_invoker = true) AS
WITH ins AS (
    SELECT pi.run_id, m.metal,
           SUM(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg
    FROM public.processing_inputs pi
    JOIN LATERAL (
        SELECT ibm.metal, ibm.content_pct
        FROM public.inbound_batch_metals ibm
        WHERE ibm.inbound_batch_id = pi.inbound_batch_id
        UNION ALL
        SELECT obm.metal, obm.content_pct
        FROM public.output_batch_metals obm
        WHERE obm.output_batch_id = pi.output_batch_id
    ) m ON true
    GROUP BY pi.run_id, m.metal
),
outs AS (
    SELECT po.run_id, obm.metal,
           SUM(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg
    FROM public.processing_outputs po
    JOIN public.output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
    GROUP BY po.run_id, obm.metal
)
SELECT r.id            AS run_id,
       r.code          AS run_code,
       r.process_date,
       COALESCE(i.metal, o.metal) AS metal,
       COALESCE(i.input_metal_kg, 0)  AS input_metal_kg,
       COALESCE(o.output_metal_kg, 0) AS output_metal_kg,
       CASE WHEN COALESCE(i.input_metal_kg, 0) = 0 THEN NULL
            ELSE round(COALESCE(o.output_metal_kg, 0) / i.input_metal_kg * 100, 2)
       END AS recovery_pct
FROM ins i
FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
JOIN public.processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
WHERE r.status = 'committed' AND r.deleted_at IS NULL;
GRANT SELECT ON public.processing_metal_recovery TO authenticated;

-- ── 8. 血缘视图(展示用):批次的全部祖先。边指向更早的提交 → 无环,递归安全 ──
CREATE VIEW public.batch_lineage WITH (security_invoker = on) AS
WITH RECURSIVE up AS (
    SELECT po.output_batch_id AS batch_id,
           pr.id AS via_run_id, pr.code AS via_run_code,
           pi.inbound_batch_id AS parent_inbound_id,
           pi.output_batch_id  AS parent_output_id,
           pi.quantity_consumed, 1 AS depth
    FROM public.processing_outputs po
    JOIN public.processing_runs pr ON pr.id = po.run_id AND pr.deleted_at IS NULL
    JOIN public.processing_inputs pi ON pi.run_id = pr.id
  UNION ALL
    SELECT up.batch_id, pr2.id, pr2.code,
           pi2.inbound_batch_id, pi2.output_batch_id,
           pi2.quantity_consumed, up.depth + 1
    FROM up
    JOIN public.processing_outputs po2 ON po2.output_batch_id = up.parent_output_id
    JOIN public.processing_runs pr2 ON pr2.id = po2.run_id AND pr2.deleted_at IS NULL
    JOIN public.processing_inputs pi2 ON pi2.run_id = pr2.id
    WHERE up.parent_output_id IS NOT NULL
)
SELECT up.batch_id AS output_batch_id,
       up.depth,
       up.via_run_id,
       up.via_run_code,
       CASE WHEN up.parent_inbound_id IS NOT NULL THEN 'inbound' ELSE 'output' END AS parent_kind,
       COALESCE(up.parent_inbound_id, up.parent_output_id) AS parent_batch_id,
       COALESCE(ib.code, ob.code) AS parent_code,
       up.quantity_consumed
FROM up
LEFT JOIN public.inbound_batches ib ON ib.id = up.parent_inbound_id
LEFT JOIN public.output_batches ob ON ob.id = up.parent_output_id;
GRANT SELECT ON public.batch_lineage TO authenticated;

COMMIT;

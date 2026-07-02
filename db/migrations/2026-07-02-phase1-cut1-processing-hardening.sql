-- ============================================================
-- Phase 1 / Cut 1 — processing lifecycle hardening
-- Date: 2026-07-02
-- Precondition: fresh verified pg_dump backup exists.
-- ============================================================
BEGIN;

-- 1) Honest run status --------------------------------------
-- Backfill history first. rollback_processing_run is the only
-- path that soft-deletes runs, so deleted_at IS NOT NULL means
-- the run was reversed.
UPDATE processing_runs
SET status = CASE WHEN deleted_at IS NULL THEN 'committed'
                  ELSE 'reversed' END;

-- Explicit over implicit: commit_processing_run now sets status
-- itself; any other insert path must state a status or fail loudly.
ALTER TABLE processing_runs ALTER COLUMN status DROP DEFAULT;

ALTER TABLE processing_runs
  DROP CONSTRAINT IF EXISTS processing_runs_status_check;
ALTER TABLE processing_runs
  ADD CONSTRAINT processing_runs_status_check
  CHECK (status IN ('committed', 'reversed'));

-- 2) Guard the two active lifecycle vocabularies -------------
-- Full option sets from app/inbound/options.ts (including values
-- not yet present in data), so the forms are never blocked.
ALTER TABLE inbound_batches
  DROP CONSTRAINT IF EXISTS inbound_batches_stage_check;
ALTER TABLE inbound_batches
  ADD CONSTRAINT inbound_batches_stage_check
  CHECK (stage IN ('待加工', '加工中', '已加工完'));

ALTER TABLE output_batches
  DROP CONSTRAINT IF EXISTS output_batches_state_check;
ALTER TABLE output_batches
  ADD CONSTRAINT output_batches_state_check
  CHECK (state IN ('库存中', '部分售出', '已售罄'));

-- 3) Audit legs must survive: cascade -> restrict -------------
ALTER TABLE processing_inputs
  DROP CONSTRAINT processing_inputs_run_id_fkey;
ALTER TABLE processing_inputs
  ADD CONSTRAINT processing_inputs_run_id_fkey
  FOREIGN KEY (run_id) REFERENCES processing_runs(id)
  ON DELETE RESTRICT;

ALTER TABLE processing_outputs
  DROP CONSTRAINT processing_outputs_run_id_fkey;
ALTER TABLE processing_outputs
  ADD CONSTRAINT processing_outputs_run_id_fkey
  FOREIGN KEY (run_id) REFERENCES processing_runs(id)
  ON DELETE RESTRICT;

-- 4) commit_processing_run: canonical body + status = 'committed'
--    on the processing_runs INSERT (only change vs current).
CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date := COALESCE(p_process_date, CURRENT_DATE);
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_consumed     numeric;
    v_remaining    numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
BEGIN
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

    -- 0b. 同一进料批次不能重复添加
    IF (SELECT count(DISTINCT elem->>'inbound_batch_id')
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        SELECT remaining_qty INTO v_remaining
        FROM inbound_batches
        WHERE id = v_inbound_id AND deleted_at IS NULL
        FOR UPDATE;

        IF v_remaining IS NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
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

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        SELECT remaining_qty INTO v_remaining
        FROM inbound_batches WHERE id = v_inbound_id;
        v_new_remaining := v_remaining - v_consumed;

        UPDATE inbound_batches
        SET remaining_qty = v_new_remaining,
            stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
            updated_by = v_user_id,
            updated_at = now()
        WHERE id = v_inbound_id;

        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
        VALUES (v_run_id, v_inbound_id, v_consumed);
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
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

-- 5) rollback_processing_run: canonical body with:
--      * SECURITY DEFINER removed (now SECURITY INVOKER)
--      * v_user_id := auth.uid()
--      * updated_by = v_user_id on the inbound-restore + output soft-delete UPDATEs
--      * status = 'reversed', updated_by = v_user_id on the run soft-delete UPDATE
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_run_deleted_at timestamptz;
    v_bad_output record;
    v_input record;
    v_new_remaining numeric;
    v_quantity numeric;
BEGIN
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

    -- 3. 还原进料：加回 remaining_qty，重判 stage
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        SELECT quantity INTO v_quantity
        FROM inbound_batches
        WHERE id = v_input.inbound_batch_id
        FOR UPDATE;

        IF NOT FOUND THEN
            CONTINUE;  -- 进料批次已被删，跳过
        END IF;

        v_new_remaining := LEAST(
            COALESCE((SELECT remaining_qty FROM inbound_batches WHERE id = v_input.inbound_batch_id), 0)
                + v_input.quantity_consumed,
            v_quantity
        );

        UPDATE inbound_batches
        SET remaining_qty = v_new_remaining,
            stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
            updated_by = v_user_id,
            updated_at = now()
        WHERE id = v_input.inbound_batch_id;
    END LOOP;

    -- 4. 软删这张单生成的产出批次
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

COMMIT;

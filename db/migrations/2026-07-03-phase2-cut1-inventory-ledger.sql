-- ============================================================
-- Phase 2 / Cut 1 — inventory movement ledger (foundation)
-- Date: 2026-07-03
-- Precondition: fresh verified pg_dump backup exists.
--
-- Core invariant: for every batch (inbound or output),
--   remaining_qty = Σ qty_delta of its inventory_movements
-- enforced by a DEFERRABLE INITIALLY DEFERRED constraint trigger.
-- remaining_qty is now a guarded cache; movements are the truth and are
-- IMMUTABLE (no UPDATE/DELETE ever). storage_locations is reserved for later.
-- ============================================================
BEGIN;

-- B1. storage_locations — pure reservation, zero rows.
CREATE TABLE public.storage_locations (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code        text NOT NULL UNIQUE,
    name        text,
    notes       text,
    deleted_at  timestamptz,
    created_by  uuid DEFAULT auth.uid(),
    updated_by  uuid DEFAULT auth.uid(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_storage_locations_updated_at
    BEFORE UPDATE ON public.storage_locations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.storage_locations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on storage_locations"
    ON public.storage_locations AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- B2. inventory_movements — immutable append-only ledger.
CREATE TABLE public.inventory_movements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id  uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    movement_type    text NOT NULL CHECK (movement_type IN
        ('receipt','processing_consume','processing_produce','reversal_restore','reversal_void','sale','writeoff','adjustment')),
    qty_delta        numeric NOT NULL CHECK (qty_delta <> 0),
    run_id           uuid REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    location_id      uuid REFERENCES public.storage_locations (id) ON DELETE RESTRICT,
    business_date    date,
    notes            text,
    occurred_at      timestamptz NOT NULL DEFAULT now(),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    -- exactly one batch reference
    CONSTRAINT inventory_movements_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL)),
    -- sign must match movement_type
    CONSTRAINT inventory_movements_sign CHECK (CASE movement_type
        WHEN 'receipt' THEN qty_delta > 0
        WHEN 'processing_produce' THEN qty_delta > 0
        WHEN 'reversal_restore' THEN qty_delta > 0
        WHEN 'processing_consume' THEN qty_delta < 0
        WHEN 'reversal_void' THEN qty_delta < 0
        WHEN 'sale' THEN qty_delta < 0
        WHEN 'writeoff' THEN qty_delta < 0
        ELSE true END),
    -- batch side must match movement_type
    CONSTRAINT inventory_movements_side CHECK (CASE movement_type
        WHEN 'processing_consume' THEN inbound_batch_id IS NOT NULL
        WHEN 'reversal_restore' THEN inbound_batch_id IS NOT NULL
        WHEN 'processing_produce' THEN output_batch_id IS NOT NULL
        WHEN 'reversal_void' THEN output_batch_id IS NOT NULL
        WHEN 'sale' THEN output_batch_id IS NOT NULL
        ELSE true END)
);
-- No deleted_at, no updated_at: immutable by design.

CREATE INDEX idx_inventory_movements_inbound ON public.inventory_movements (inbound_batch_id);
CREATE INDEX idx_inventory_movements_output  ON public.inventory_movements (output_batch_id);
CREATE INDEX idx_inventory_movements_run     ON public.inventory_movements (run_id);
CREATE INDEX idx_inventory_movements_occurred ON public.inventory_movements (occurred_at);

ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
-- authenticated may SELECT and INSERT only — no UPDATE/DELETE policies at all.
CREATE POLICY "authenticated select on inventory_movements"
    ON public.inventory_movements AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on inventory_movements"
    ON public.inventory_movements AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);

-- B4. Trigger functions ------------------------------------------------------

-- immutability: movements can never be updated or deleted (belt-and-braces on top of RLS)
CREATE OR REPLACE FUNCTION public.reject_movement_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'MOVEMENT_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_inventory_movements_immutable
    BEFORE UPDATE OR DELETE ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.reject_movement_mutation();

-- (a) emit-on-create: new stock in
CREATE OR REPLACE FUNCTION public.emit_batch_receipt_movement()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_ctx text := current_setting('evoltrya.movement_ctx', true);
    v_run uuid;
BEGIN
    IF NEW.remaining_qty IS NULL OR NEW.remaining_qty <= 0 THEN
        RETURN NULL;
    END IF;

    IF TG_TABLE_NAME = 'inbound_batches' THEN
        INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, created_by)
        VALUES (NEW.id, 'receipt', NEW.remaining_qty, NEW.arrival_date, NEW.created_by);
    ELSE  -- output_batches
        IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'processing' THEN
            v_run := split_part(v_ctx, ':', 2)::uuid;
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
            VALUES (NEW.id, 'processing_produce', NEW.remaining_qty, v_run, NEW.output_date, NEW.created_by);
        ELSE
            INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, business_date, created_by)
            VALUES (NEW.id, 'receipt', NEW.remaining_qty, NEW.output_date, NEW.created_by);
        END IF;
    END IF;

    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_emit_receipt
    AFTER INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.emit_batch_receipt_movement();
CREATE TRIGGER trg_output_batches_emit_receipt
    AFTER INSERT ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.emit_batch_receipt_movement();

-- (b) writeoff-on-softdelete: stock out + zero the cache
CREATE OR REPLACE FUNCTION public.emit_batch_writeoff_movement()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_ctx text := current_setting('evoltrya.movement_ctx', true);
    v_run uuid;
BEGIN
    IF OLD.remaining_qty > 0 THEN
        IF TG_TABLE_NAME = 'inbound_batches' THEN
            INSERT INTO public.inventory_movements (inbound_batch_id, movement_type, qty_delta, created_by)
            VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
        ELSE  -- output_batches
            IF v_ctx IS NOT NULL AND split_part(v_ctx, ':', 1) = 'reversal' THEN
                v_run := split_part(v_ctx, ':', 2)::uuid;
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, run_id, created_by)
                VALUES (OLD.id, 'reversal_void', -OLD.remaining_qty, v_run, NEW.updated_by);
            ELSE
                INSERT INTO public.inventory_movements (output_batch_id, movement_type, qty_delta, created_by)
                VALUES (OLD.id, 'writeoff', -OLD.remaining_qty, NEW.updated_by);
            END IF;
        END IF;
        NEW.remaining_qty := 0;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_writeoff
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION public.emit_batch_writeoff_movement();
CREATE TRIGGER trg_output_batches_writeoff
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION public.emit_batch_writeoff_movement();

-- (c) quantity guard: quantity is immutable after creation
CREATE OR REPLACE FUNCTION public.reject_quantity_change()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'QUANTITY_IMMUTABLE|%', OLD.code;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_quantity_guard
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION public.reject_quantity_change();
CREATE TRIGGER trg_output_batches_quantity_guard
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION public.reject_quantity_change();

-- (d) invariant: remaining_qty must equal Σ movements for the affected batch(es)
CREATE OR REPLACE FUNCTION public.check_ledger_invariant()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_inbound uuid;
    v_output  uuid;
    v_code    text;
    v_remaining numeric;
    v_sum     numeric;
BEGIN
    IF TG_TABLE_NAME = 'inbound_batches' THEN
        v_inbound := NEW.id;
    ELSIF TG_TABLE_NAME = 'output_batches' THEN
        v_output := NEW.id;
    ELSE  -- inventory_movements
        v_inbound := NEW.inbound_batch_id;
        v_output  := NEW.output_batch_id;
    END IF;

    IF v_inbound IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.inbound_batches WHERE id = v_inbound;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE inbound_batch_id = v_inbound;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    IF v_output IS NOT NULL THEN
        SELECT code, remaining_qty INTO v_code, v_remaining FROM public.output_batches WHERE id = v_output;
        SELECT COALESCE(SUM(qty_delta), 0) INTO v_sum FROM public.inventory_movements WHERE output_batch_id = v_output;
        IF v_remaining IS DISTINCT FROM v_sum THEN
            RAISE EXCEPTION 'LEDGER_INVARIANT|%|%|%', v_code, v_remaining, v_sum;
        END IF;
    END IF;

    RETURN NULL;
END;
$fn$;

CREATE CONSTRAINT TRIGGER trg_inbound_batches_invariant
    AFTER INSERT OR UPDATE ON public.inbound_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_ledger_invariant();
CREATE CONSTRAINT TRIGGER trg_output_batches_invariant
    AFTER INSERT OR UPDATE ON public.output_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_ledger_invariant();
CREATE CONSTRAINT TRIGGER trg_inventory_movements_invariant
    AFTER INSERT ON public.inventory_movements
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_ledger_invariant();

-- B6. record_output_sale --------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_sale_date date DEFAULT NULL, p_notes text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_deleted   timestamptz;
    v_remaining numeric;
    v_new_remaining numeric;
    v_state     text;
BEGIN
    SELECT deleted_at, remaining_qty INTO v_deleted, v_remaining
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, COALESCE(p_sale_date, CURRENT_DATE), p_notes, v_user);

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state
    );
END;
$function$;

-- B5. commit_processing_run — emit consume movements + set produce context.
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

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
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

        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
        VALUES (v_inbound_id, 'processing_consume', -v_consumed, v_run_id, v_process_date, v_user_id);

        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
        VALUES (v_run_id, v_inbound_id, v_consumed);
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

-- B5. rollback_processing_run — reversal context + restore movements.
CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid)
 RETURNS void
 LANGUAGE plpgsql
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

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
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

-- B3. Hardening (placed after B6, before backfill DML so no pending trigger events
--     block the ALTER; all current remaining_qty >= 0, so validated immediately).
ALTER TABLE public.inbound_batches
  ADD CONSTRAINT inbound_batches_remaining_qty_nonneg CHECK (remaining_qty >= 0);
ALTER TABLE public.output_batches
  ADD CONSTRAINT output_batches_remaining_qty_nonneg CHECK (remaining_qty >= 0);

-- B7. Backfill (occurred_at from source timestamps; notes 'backfill') ---------
-- inbound receipts
INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, occurred_at, created_by, notes)
SELECT id, 'receipt', quantity, created_at, created_by, 'backfill' FROM inbound_batches;

-- every input leg -> processing_consume at run created_at
INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, occurred_at, created_by, notes)
SELECT pi.inbound_batch_id, 'processing_consume', -pi.quantity_consumed, pi.run_id, r.created_at, r.created_by, 'backfill'
FROM processing_inputs pi JOIN processing_runs r ON r.id = pi.run_id;

-- reversed runs' legs -> reversal_restore at run deleted_at
INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, occurred_at, created_by, notes)
SELECT pi.inbound_batch_id, 'reversal_restore', pi.quantity_consumed, pi.run_id, r.deleted_at, r.updated_by, 'backfill'
FROM processing_inputs pi JOIN processing_runs r ON r.id = pi.run_id
WHERE r.status = 'reversed' AND r.deleted_at IS NOT NULL;

-- output WITH a leg -> processing_produce at run created_at
INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, run_id, occurred_at, created_by, notes)
SELECT po.output_batch_id, 'processing_produce', ob.quantity, po.run_id, r.created_at, r.created_by, 'backfill'
FROM processing_outputs po
JOIN output_batches ob ON ob.id = po.output_batch_id
JOIN processing_runs r ON r.id = po.run_id;

-- output WITHOUT a leg -> receipt at batch created_at
INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, occurred_at, created_by, notes)
SELECT ob.id, 'receipt', ob.quantity, ob.created_at, ob.created_by, 'backfill'
FROM output_batches ob
WHERE NOT EXISTS (SELECT 1 FROM processing_outputs po WHERE po.output_batch_id = ob.id);

-- soft-deleted run-linked outputs -> reversal_void at run deleted_at, then zero the dead rows
INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, run_id, occurred_at, created_by, notes)
SELECT po.output_batch_id, 'reversal_void', -ob.quantity, po.run_id, r.deleted_at, r.updated_by, 'backfill'
FROM processing_outputs po
JOIN output_batches ob ON ob.id = po.output_batch_id
JOIN processing_runs r ON r.id = po.run_id
WHERE ob.deleted_at IS NOT NULL AND r.deleted_at IS NOT NULL;

UPDATE output_batches SET remaining_qty = 0 WHERE deleted_at IS NOT NULL AND remaining_qty <> 0;

-- per-batch true-up: reconcile any residual with a single 'adjustment'
INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, occurred_at, notes)
SELECT ib.id, 'adjustment', ib.remaining_qty - COALESCE(m.s, 0), now(), 'backfill reconciliation'
FROM inbound_batches ib
LEFT JOIN (SELECT inbound_batch_id, SUM(qty_delta) s FROM inventory_movements WHERE inbound_batch_id IS NOT NULL GROUP BY inbound_batch_id) m
       ON m.inbound_batch_id = ib.id
WHERE (ib.remaining_qty - COALESCE(m.s, 0)) <> 0;

INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, occurred_at, notes)
SELECT ob.id, 'adjustment', ob.remaining_qty - COALESCE(m.s, 0), now(), 'backfill reconciliation'
FROM output_batches ob
LEFT JOIN (SELECT output_batch_id, SUM(qty_delta) s FROM inventory_movements WHERE output_batch_id IS NOT NULL GROUP BY output_batch_id) m
       ON m.output_batch_id = ob.id
WHERE (ob.remaining_qty - COALESCE(m.s, 0)) <> 0;

COMMIT;

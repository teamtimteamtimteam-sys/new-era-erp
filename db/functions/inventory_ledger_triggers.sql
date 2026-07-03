-- db/functions/inventory_ledger_triggers.sql
-- NEW MIRROR CONVENTION: this file holds the SHARED trigger functions of the inventory
-- ledger PLUS the CREATE TRIGGER attachments on the pre-existing batch tables
-- (inbound_batches / output_batches), which have no mirror file of their own. The
-- inventory_movements table's own triggers live in db/tables/inventory_movements.sql.
--
-- Ledger rule: remaining_qty is a guarded cache; inventory_movements is the truth.
--   (a) emit-on-create        AFTER INSERT  on both batch tables  -> +remaining_qty in
--   (b) writeoff-on-softdelete BEFORE UPDATE on both batch tables -> -remaining_qty out, zero cache
--   (c) quantity guard        BEFORE UPDATE on both batch tables  -> quantity is immutable
--   (d) invariant             deferred constraint trigger on both batch tables + movements
--   immutability              BEFORE UPDATE OR DELETE on inventory_movements (rejects both)
--
-- Context marker: commit_processing_run / rollback_processing_run set
--   set_config('evoltrya.movement_ctx', 'processing:<run>' | 'reversal:<run>', true)
-- so the create/writeoff triggers can tag processing_produce / reversal_void with run_id.
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut1-inventory-ledger.sql.
-- Run AFTER inbound_batches/output_batches/inventory_movements exist. First-run script.

-- immutability: movements can never be updated or deleted (belt-and-braces on top of RLS)
CREATE OR REPLACE FUNCTION public.reject_movement_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'MOVEMENT_IMMUTABLE';
END;
$fn$;

-- (a) emit-on-create: new stock in (receipt, or processing_produce under processing ctx)
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

-- (b) writeoff-on-softdelete: stock out + zero the cache (reversal_void under reversal ctx)
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

-- (c) quantity guard: quantity is immutable after creation
CREATE OR REPLACE FUNCTION public.reject_quantity_change()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'QUANTITY_IMMUTABLE|%', OLD.code;
END;
$fn$;

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

-- ---- batch-table trigger attachments (the movements-table triggers are in its own file) ----
CREATE TRIGGER trg_inbound_batches_emit_receipt
    AFTER INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.emit_batch_receipt_movement();
CREATE TRIGGER trg_output_batches_emit_receipt
    AFTER INSERT ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.emit_batch_receipt_movement();

CREATE TRIGGER trg_inbound_batches_writeoff
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION public.emit_batch_writeoff_movement();
CREATE TRIGGER trg_output_batches_writeoff
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION public.emit_batch_writeoff_movement();

CREATE TRIGGER trg_inbound_batches_quantity_guard
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION public.reject_quantity_change();
CREATE TRIGGER trg_output_batches_quantity_guard
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION public.reject_quantity_change();

CREATE CONSTRAINT TRIGGER trg_inbound_batches_invariant
    AFTER INSERT OR UPDATE ON public.inbound_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_ledger_invariant();
CREATE CONSTRAINT TRIGGER trg_output_batches_invariant
    AFTER INSERT OR UPDATE ON public.output_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_ledger_invariant();

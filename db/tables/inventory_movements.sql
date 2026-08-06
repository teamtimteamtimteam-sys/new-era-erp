-- db/tables/inventory_movements.sql
-- Inventory movement ledger — immutable, append-only. THE source of truth for stock.
-- Core invariant: for every batch, remaining_qty = Σ qty_delta of its movements
-- (enforced by a DEFERRABLE INITIALLY DEFERRED constraint trigger; remaining_qty is a
-- guarded cache). Movements are NEVER updated or deleted.
--
-- Its two triggers below reference functions defined in
-- db/functions/inventory_ledger_triggers.sql (reject_movement_mutation, check_ledger_invariant)
-- — run that file first.
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut1-inventory-ledger.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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
    -- FIN-25b:consume/restore 放开为任一侧(再加工耗产出批);恰一批次由
    -- one_batch XOR 把守。produce/void/sale 仍钉产出侧。
    CONSTRAINT inventory_movements_side CHECK (CASE movement_type
        WHEN 'processing_produce' THEN output_batch_id IS NOT NULL
        WHEN 'reversal_void' THEN output_batch_id IS NOT NULL
        WHEN 'sale' THEN output_batch_id IS NOT NULL
        ELSE true END)
);
-- No deleted_at, no updated_at: immutable by design.

CREATE INDEX idx_inventory_movements_inbound  ON public.inventory_movements (inbound_batch_id);
CREATE INDEX idx_inventory_movements_output   ON public.inventory_movements (output_batch_id);
CREATE INDEX idx_inventory_movements_run      ON public.inventory_movements (run_id);
CREATE INDEX idx_inventory_movements_occurred ON public.inventory_movements (occurred_at);

-- RLS: authenticated may SELECT and INSERT only — no UPDATE/DELETE policies exist.
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inventory_movements select by permission"
    ON public.inventory_movements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'::text));

CREATE POLICY "inventory_movements insert by permission"
    ON public.inventory_movements
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inventory.edit'::text));

-- Its own triggers (functions live in db/functions/inventory_ledger_triggers.sql):
--   * immutability belt-and-braces
CREATE TRIGGER trg_inventory_movements_immutable
    BEFORE UPDATE OR DELETE ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.reject_movement_mutation();
--   * the shared remaining_qty invariant (deferred)
CREATE CONSTRAINT TRIGGER trg_inventory_movements_invariant
    AFTER INSERT ON public.inventory_movements
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_ledger_invariant();

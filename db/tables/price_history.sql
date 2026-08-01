-- db/tables/price_history.sql
-- Audit trail for inbound unit_price changes. Written only by
-- set_inbound_unit_price; direct UPDATEs of inbound_batches.unit_price are
-- rejected by trg_inbound_batches_price_guard (PRICE_VIA_FUNCTION) unless the
-- evoltrya.price_ctx GUC is set by that function (same pattern as movement_ctx).
-- inbound_batches.unit_price stays the USD column; original currency + fx here.
-- IMMUTABLE (INSERT+SELECT RLS only + trigger).
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.price_history (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id uuid NOT NULL REFERENCES public.inbound_batches (id),
    old_unit_price   numeric,           -- 变更前 USD 单价(首次定价为 NULL)
    new_unit_price   numeric NOT NULL,  -- 变更后 USD 单价
    currency         text NOT NULL,
    original_price   numeric NOT NULL,  -- 原币单价(录入值)
    fx_rate          numeric NOT NULL,
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid()
);

CREATE INDEX idx_price_history_batch ON public.price_history (inbound_batch_id);

CREATE OR REPLACE FUNCTION public.reject_price_history_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'PRICE_HISTORY_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_price_history_immutable
    BEFORE UPDATE OR DELETE ON public.price_history
    FOR EACH ROW EXECUTE FUNCTION public.reject_price_history_mutation();

ALTER TABLE public.price_history ENABLE ROW LEVEL SECURITY;
CREATE POLICY "price_history select by permission"
    ON public.price_history
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));

CREATE POLICY "price_history insert by permission"
    ON public.price_history
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));

-- 直改拦截(挂在 inbound_batches 上;INSERT 带价仍允许 —— 建单定价是正常路径)
CREATE OR REPLACE FUNCTION public.guard_inbound_price_change()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.unit_price IS DISTINCT FROM OLD.unit_price
       AND NULLIF(current_setting('evoltrya.price_ctx', true), '') IS NULL THEN
        RAISE EXCEPTION 'PRICE_VIA_FUNCTION';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_inbound_batches_price_guard
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_price_change();

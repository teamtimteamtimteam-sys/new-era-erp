-- db/tables/storage_locations.sql
-- Storage locations — table + updated_at trigger + RLS.
-- Pure reservation for a later cut (zero rows today); inventory_movements.location_id
-- references it. Conventions match existing tables:
--   * soft delete via deleted_at
--   * audit fields created_by/updated_by default auth.uid(), created_at/updated_at default now()
--   * updated_at auto-bumped by the shared update_updated_at() function (do NOT redefine it)
--   * RLS: authenticated-only full access
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut1-inventory-ledger.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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

CREATE POLICY "storage_locations select by permission"
    ON public.storage_locations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'::text));

CREATE POLICY "storage_locations insert by permission"
    ON public.storage_locations
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inventory.edit'::text));

CREATE POLICY "storage_locations update by permission"
    ON public.storage_locations
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inventory.edit'::text)) WITH CHECK (has_permission('module.inventory.edit'::text));

CREATE POLICY "storage_locations delete by permission"
    ON public.storage_locations
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inventory.edit'::text));

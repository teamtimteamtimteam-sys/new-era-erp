-- db/tables/accounts.sql
-- Chart of accounts (bilingual names). NO soft delete: posted journals must
-- always resolve their account — deactivate (is_active=false) instead.
-- Seeded with the 35-account chart (asset/liability/equity/revenue/cogs/expense).
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql
-- (see it for the full seed list).
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.accounts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code         text NOT NULL UNIQUE,
    name_en      text NOT NULL,
    name_zh      text NOT NULL,
    account_type text NOT NULL CHECK (account_type IN ('asset','liability','equity','revenue','cogs','expense')),
    is_active    boolean NOT NULL DEFAULT true,
    notes        text,
    created_by   uuid DEFAULT auth.uid(),
    updated_by   uuid DEFAULT auth.uid(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_accounts_updated_at
    BEFORE UPDATE ON public.accounts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on accounts"
    ON public.accounts AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

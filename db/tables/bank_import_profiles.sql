-- db/tables/bank_import_profiles.sql
-- 银行 CSV 导入映射档:每个银行账户可存多套命名映射,月度导入不必重新映射。
-- mapping 只是存储 —— DB 不解释它。UI 用它解析 CSV,再把解析好的行数组交给
-- import_bank_statement。形状(UI 约定):
--   {date_column, description_column, reference_column,
--    amount_column | debit_column + credit_column,
--    date_format, decimal_separator, thousands_separator, sign_convention}
-- 软删 + (bank_account_code, name) 在册唯一(部分唯一索引)。
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.bank_import_profiles (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    bank_account_code text NOT NULL CHECK (bank_account_code IN ('1000','1010')),
    name              text NOT NULL,
    mapping           jsonb NOT NULL,
    deleted_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid()
);

CREATE UNIQUE INDEX uq_bank_import_profiles_account_name
    ON public.bank_import_profiles (bank_account_code, name)
    WHERE deleted_at IS NULL;

CREATE TRIGGER trg_bank_import_profiles_updated_at
    BEFORE UPDATE ON public.bank_import_profiles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.bank_import_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on bank_import_profiles"
    ON public.bank_import_profiles AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

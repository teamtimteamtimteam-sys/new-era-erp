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
CREATE POLICY "bank_import_profiles select by permission"
    ON public.bank_import_profiles
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "bank_import_profiles insert by permission"
    ON public.bank_import_profiles
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_import_profiles update by permission"
    ON public.bank_import_profiles
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_import_profiles delete by permission"
    ON public.bank_import_profiles
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_import_profiles
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');

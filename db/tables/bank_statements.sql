-- db/tables/bank_statements.sql
-- 银行对账单(一次导入 = 一张报表),无缝编号 'BS-YYYY-NNNN'(import_bank_statement
-- 在事务内按咨询锁分配,同 JE/收付款/开支手法)。currency 恒为账户本币
-- (bank_native_currency:1000 → SGD,1010 → USD),报表金额一律以本币记。
-- 余额恒等式 opening + Σ 行金额 = closing 由导入函数在门口强制。
-- 软删:坏导入必须能丢弃;但【已对账(reconciled)的报表不许软删】——
-- 守卫触发器在 deleted_at 首次落下时抛 STATEMENT_RECONCILED(先 unreconcile)。
--
-- NOTE: introduced by db/migrations/2026-07-30-phase3-s3a-bank-reconciliation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.bank_statements (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,  -- gapless 'BS-YYYY-NNNN', assigned by import_bank_statement
    bank_account_code text NOT NULL CHECK (bank_account_code IN ('1000','1010')),
    currency          text NOT NULL REFERENCES public.currencies (code),
    period_start      date NOT NULL,
    period_end        date NOT NULL CHECK (period_end >= period_start),
    opening_balance   numeric NOT NULL,
    closing_balance   numeric NOT NULL,
    file_name         text,
    status            text NOT NULL DEFAULT 'open' CHECK (status IN ('open','reconciled')),
    reconciled_at     timestamptz,
    reconciled_by     uuid,
    notes             text,
    deleted_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid()
);

CREATE TRIGGER trg_bank_statements_updated_at
    BEFORE UPDATE ON public.bank_statements
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE OR REPLACE FUNCTION public.guard_bank_statement_delete()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL AND OLD.status = 'reconciled' THEN
        RAISE EXCEPTION 'STATEMENT_RECONCILED';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_bank_statements_no_delete_reconciled
    BEFORE UPDATE ON public.bank_statements
    FOR EACH ROW EXECUTE FUNCTION public.guard_bank_statement_delete();

ALTER TABLE public.bank_statements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_statements select by permission"
    ON public.bank_statements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "bank_statements insert by permission"
    ON public.bank_statements
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_statements update by permission"
    ON public.bank_statements
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "bank_statements delete by permission"
    ON public.bank_statements
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.bank_statements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.finance.edit');

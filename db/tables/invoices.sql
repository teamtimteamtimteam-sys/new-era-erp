-- db/tables/invoices.sql
-- 客户发票。无缝编号 'INV-YYYY-NNNN'(create_invoice 在事务内按 issue_date 的年份
-- 用咨询锁分配,同 JE/收付款/开支/对账单手法)。
--
-- 【发票不过任何分录】:收入与应收在销售当刻就由 record_output_sale 确认了
-- (sales_records 行本身就是 AR 单据)。发票只是把同一客户名下若干张已存在的销售
-- 归拢成一份可以寄出去的文件;收付款照旧核销到 sales_records,发票的已结/未结
-- 由 invoice_status 从明细行背后的销售推导。
--
-- IMMUTABLE:已开出的发票不可改,更正靠"作废 + 重开",故没有 updated_at/deleted_at。
-- 守卫触发器只放行 issued→void(连同 void_reason/voided_at/voided_by);
-- RLS 给 SELECT+INSERT,外加一条窄用途 UPDATE 策略供作废路径使用(改哪些列由触发器管)。
--
-- bill_to_snapshot:开票当刻客户抬头的快照,列取自 customers 上【确实存在】的字段
-- (code/legal_name/short_name/country/tax_id/address/payment_terms/incoterm)——
-- 该表没有联系人/邮箱/电话列。客户资料日后变更,几年后重打这张发票仍显示当时寄出的内容。
--
-- GST:公司尚未登记,tax_rate_pct/tax_base 目前恒为 0(由 finance_settings.gst_registered
-- 控制)。把 GST 接进分录属于后续切次,且【正确的确认时点是销售而不是开票】。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut2a-invoices.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.invoices (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code               text NOT NULL UNIQUE,  -- gapless 'INV-YYYY-NNNN'
    customer_id        uuid NOT NULL REFERENCES public.customers (id),
    issue_date         date NOT NULL,
    due_date           date NOT NULL,
    payment_terms_days integer NOT NULL CHECK (payment_terms_days >= 0),
    currency           text NOT NULL REFERENCES public.currencies (code),
    subtotal_base       numeric NOT NULL,
    tax_rate_pct       numeric NOT NULL DEFAULT 0,
    tax_base            numeric NOT NULL DEFAULT 0,
    total_base          numeric NOT NULL,
    status             text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','void')),
    void_reason        text,
    voided_at          timestamptz,
    voided_by          uuid,
    notes              text,
    terms_text         text,
    bill_to_snapshot   jsonb NOT NULL,
    created_at         timestamptz DEFAULT now(),
    created_by         uuid DEFAULT auth.uid()
);

CREATE INDEX idx_invoices_customer ON public.invoices (customer_id);
CREATE INDEX idx_invoices_issue_date ON public.invoices (issue_date);

CREATE OR REPLACE FUNCTION public.guard_invoice_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NEW.id                 IS DISTINCT FROM OLD.id
       OR NEW.code               IS DISTINCT FROM OLD.code
       OR NEW.customer_id        IS DISTINCT FROM OLD.customer_id
       OR NEW.issue_date         IS DISTINCT FROM OLD.issue_date
       OR NEW.due_date           IS DISTINCT FROM OLD.due_date
       OR NEW.payment_terms_days IS DISTINCT FROM OLD.payment_terms_days
       OR NEW.currency           IS DISTINCT FROM OLD.currency
       OR NEW.subtotal_base       IS DISTINCT FROM OLD.subtotal_base
       OR NEW.tax_rate_pct       IS DISTINCT FROM OLD.tax_rate_pct
       OR NEW.tax_base            IS DISTINCT FROM OLD.tax_base
       OR NEW.total_base          IS DISTINCT FROM OLD.total_base
       OR NEW.notes              IS DISTINCT FROM OLD.notes
       OR NEW.terms_text         IS DISTINCT FROM OLD.terms_text
       OR NEW.bill_to_snapshot   IS DISTINCT FROM OLD.bill_to_snapshot
       OR NEW.created_at         IS DISTINCT FROM OLD.created_at
       OR NEW.created_by         IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'issued' AND NEW.status = 'void'
            AND OLD.voided_at IS NULL AND NEW.voided_at IS NOT NULL) THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_invoices_immutable
    BEFORE UPDATE OR DELETE ON public.invoices
    FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_mutation();

-- 作废时把标记同步到明细行(见 invoice_lines.invoice_voided 与其部分唯一索引),
-- 释放这些销售以便重开。
CREATE OR REPLACE FUNCTION public.propagate_invoice_void()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.status = 'void' AND OLD.status IS DISTINCT FROM 'void' THEN
        UPDATE invoice_lines SET invoice_voided = true WHERE invoice_id = NEW.id;
    END IF;
    RETURN NULL;
END;
$fn$;

CREATE TRIGGER trg_invoices_propagate_void
    AFTER UPDATE ON public.invoices
    FOR EACH ROW EXECUTE FUNCTION public.propagate_invoice_void();

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;
CREATE POLICY "invoices select by permission"
    ON public.invoices
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "invoices insert by permission"
    ON public.invoices
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "invoices update by permission"
    ON public.invoices
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 invoices_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.invoices FROM authenticated, anon;
GRANT SELECT (id, code, customer_id, issue_date, due_date, payment_terms_days, currency, tax_rate_pct, status, void_reason, voided_at, voided_by, notes, terms_text, bill_to_snapshot, created_at, created_by)
    ON public.invoices TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.invoices.subtotal_base IS '本位币小计(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 subtotal_usd)。';
COMMENT ON COLUMN public.invoices.tax_base IS '本位币税额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 tax_usd)。';
COMMENT ON COLUMN public.invoices.total_base IS '本位币总额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 total_usd)。';

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
    created_by         uuid DEFAULT auth.uid(),
    -- ── SO-3a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【kind 是判别列,NULL 不是】发票从此有两种:'sale' = 归拢已过账的销售
    -- (SO-3a 之前唯一的一种,不过任何分录);'order' = 订单流的【过账单据】,
    -- 开票即 借 1100 应收 / 贷 2500 合同负债(选项 C,Tim 定)。下面三列只在
    -- order 上非空 —— 由 invoices_kind_consistency 双向钉死,所以 sale 行上的
    -- NULL 不是"一列两义"的病:含义由 kind 说,NULL 只是"此列不适用"。
    kind               text NOT NULL DEFAULT 'sale' CHECK (kind IN ('sale','order')),
    -- 开票分录(order 专有)。作废时不清 —— 冲销分录经 reversed_by 挂在它上面。
    entry_id           uuid REFERENCES public.journal_entries (id),
    -- 【入账汇率,从订单【抄】来 —— FIN-27 一族】它是结算解除应收、发货释放
    -- 负债都要用的那一个数;开屏现查行情会让同一张发票在不同日子值不同的钱。
    fx_rate            numeric,
    sales_order_id     uuid REFERENCES public.sales_orders (id),
    CONSTRAINT invoices_kind_consistency CHECK (
        (kind = 'sale'  AND sales_order_id IS NULL     AND entry_id IS NULL     AND fx_rate IS NULL)
     OR (kind = 'order' AND sales_order_id IS NOT NULL AND entry_id IS NOT NULL AND fx_rate IS NOT NULL AND fx_rate > 0))
);

CREATE INDEX idx_invoices_customer ON public.invoices (customer_id);
CREATE INDEX idx_invoices_issue_date ON public.invoices (issue_date);

CREATE INDEX idx_invoices_order ON public.invoices (sales_order_id);

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
       -- SO-3a:判别列与订单流三列同样不可变(entry_id 在 INSERT 当刻就写好,
       -- 作废也不清它 —— 冲销分录经 journal_entries.reversed_by 挂在原分录上)
       OR NEW.kind               IS DISTINCT FROM OLD.kind
       OR NEW.entry_id           IS DISTINCT FROM OLD.entry_id
       OR NEW.fx_rate            IS DISTINCT FROM OLD.fx_rate
       OR NEW.sales_order_id     IS DISTINCT FROM OLD.sales_order_id
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
-- SO-3a:三列非敏感,进列清单;fx_rate 与金额同档(sales_records.fx_rate 的先例),
-- 【不进清单】—— 只能经 invoices_masked 按 data.view_prices 读(colgrant 由此闭合)。
GRANT SELECT (kind, sales_order_id, entry_id)
    ON public.invoices TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.invoices.subtotal_base IS '本位币小计(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 subtotal_usd)。';
COMMENT ON COLUMN public.invoices.tax_base IS '本位币税额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 tax_usd)。';
COMMENT ON COLUMN public.invoices.total_base IS '本位币总额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 total_usd)。';

-- SO-3a:两列的说明写进数据库,重建出来的库也带着(与 business_date 同办)。
COMMENT ON COLUMN public.invoices.kind IS
    'SO-3a:发票的种类。''sale'' = 归拢已过账销售的文件(不过分录,SO-3a 之前唯一的一种);''order'' = 订单流的过账单据 —— 开票即 借 1100 应收 / 贷 2500 合同负债(选项 C),发货(3b)再释放负债进收入。entry_id/fx_rate/sales_order_id 只在 order 上非空,由 invoices_kind_consistency 双向钉死 —— NULL 的含义由 kind 说,不是一列两义。';
COMMENT ON COLUMN public.invoices.fx_rate IS
    'SO-3a:入账汇率,【从订单抄来】(FIN-27 一族:承诺抄下来,不再看行情)。开票分录按它过、结算按它解除、7100 已实现汇兑从它算起 —— 一个数,三处同源。sale 头恒 NULL(那种发票不过账,行背后的销售各有各的汇率)。';

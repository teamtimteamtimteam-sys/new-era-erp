-- db/tables/invoice_lines.sql
-- 发票明细行:一行对应一张已存在的 sales_record(发票是"归拢",不是新的应收)。
-- 行内容在开票当刻定死(摘要 = 产出批次编号 + 物料名,数量/单位/单价/金额取自
-- sales_record),即便日后物料改名,重打发票仍是当时寄出的内容。
--
-- 【一张销售只能挂在一张在册发票上,作废后可以重开】—— 落地方式:
--   部分唯一索引的 WHERE 子句不能引用另一张表(void 状态在 invoices 上),
--   所以单靠 invoice_lines 上的索引做不到。这里两条腿一起用:
--   1) 冗余列 invoice_voided,由 invoices 的 AFTER UPDATE 触发器
--      (propagate_invoice_void)自动同步 —— 作废是唯一会改它的路径,不会漂移 ——
--      再对它建部分唯一索引。这是【硬保证】:并发下也不可能让同一张销售挂上两张
--      在册发票。重复开票给客户是真实的账务事故,值得一个索引级的保证,而不是
--      "先查后插"那种带竞态窗口的写法。
--   2) create_invoice 里先做一次友好检查,抛 'ALREADY_INVOICED|sale_code|invoice_code',
--      让用户看到"这张销售已在 INV-xxxx 上",而不是一条原始唯一约束报错。
--   索引负责正确性,函数检查负责可读性。
--
-- IMMUTABLE:INSERT+SELECT RLS + 守卫触发器逐列锁死;唯一例外是触发器写的
-- invoice_voided 标记(故另给一条 UPDATE 策略,列级限制仍由守卫执行)。
--
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut2a-invoices.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.invoice_lines (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id      uuid NOT NULL REFERENCES public.invoices (id) ON DELETE RESTRICT,
    sales_record_id uuid NOT NULL REFERENCES public.sales_records (id),
    line_no         integer NOT NULL,
    description     text NOT NULL,
    quantity        numeric NOT NULL,
    unit            text NOT NULL,
    unit_price      numeric NOT NULL,
    amount_usd      numeric NOT NULL,
    -- 冗余的作废标记,仅供下面的部分唯一索引使用;由 invoices 的触发器维护,
    -- 应用代码不要直接写它。
    invoice_voided  boolean NOT NULL DEFAULT false,
    created_at      timestamptz DEFAULT now(),
    UNIQUE (invoice_id, line_no)
);

CREATE INDEX idx_invoice_lines_invoice ON public.invoice_lines (invoice_id);
CREATE INDEX idx_invoice_lines_sale ON public.invoice_lines (sales_record_id);

-- 硬保证:一张销售最多出现在一张未作废的发票上
CREATE UNIQUE INDEX uq_invoice_lines_live_sale
    ON public.invoice_lines (sales_record_id)
    WHERE NOT invoice_voided;

CREATE OR REPLACE FUNCTION public.guard_invoice_line_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.invoice_id      IS DISTINCT FROM OLD.invoice_id
       OR NEW.sales_record_id IS DISTINCT FROM OLD.sales_record_id
       OR NEW.line_no         IS DISTINCT FROM OLD.line_no
       OR NEW.description     IS DISTINCT FROM OLD.description
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit            IS DISTINCT FROM OLD.unit
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.amount_usd      IS DISTINCT FROM OLD.amount_usd
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_invoice_lines_immutable
    BEFORE UPDATE OR DELETE ON public.invoice_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_line_mutation();

ALTER TABLE public.invoice_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated select on invoice_lines"
    ON public.invoice_lines FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated insert on invoice_lines"
    ON public.invoice_lines FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "authenticated update on invoice_lines"
    ON public.invoice_lines FOR UPDATE TO authenticated
    USING (true) WITH CHECK (true);

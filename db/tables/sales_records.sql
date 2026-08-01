-- db/tables/sales_records.sql
-- Sales facts (quantity + price + currency + USD amount), written only by
-- record_output_sale alongside the 'sale' inventory movement (movement_id link).
-- IMMUTABLE (INSERT+SELECT RLS only + trigger): sales are facts; corrections go
-- through a future credit-note concept, not edits.
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.sales_records (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    output_batch_id uuid NOT NULL REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    customer_id     uuid REFERENCES public.customers (id),
    quantity        numeric NOT NULL CHECK (quantity > 0),
    unit_price      numeric NOT NULL CHECK (unit_price > 0),
    currency        text NOT NULL REFERENCES public.currencies (code),
    fx_rate         numeric NOT NULL CHECK (fx_rate > 0),
    amount_usd      numeric NOT NULL,  -- round(quantity × unit_price × fx_rate, 2)
    sale_date       date NOT NULL,
    notes           text,
    movement_id     uuid REFERENCES public.inventory_movements (id),
    created_at      timestamptz DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    -- 在列序末尾:cut 2a 用 ALTER ADD COLUMN 追加(镜像按线上 attnum 排)。
    -- COGS 分录链接(售时或 allocate 补挂)。
    cogs_entry_id   uuid REFERENCES public.journal_entries (id)
);

CREATE INDEX idx_sales_records_batch ON public.sales_records (output_batch_id);

-- cut 2a:放宽一个精确迁移 —— cogs_entry_id 首挂(NULL → 非 NULL),其余列逐列锁死。
CREATE OR REPLACE FUNCTION public.reject_sales_record_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.output_batch_id IS DISTINCT FROM OLD.output_batch_id
       OR NEW.customer_id     IS DISTINCT FROM OLD.customer_id
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate         IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_usd      IS DISTINCT FROM OLD.amount_usd
       OR NEW.sale_date       IS DISTINCT FROM OLD.sale_date
       OR NEW.notes           IS DISTINCT FROM OLD.notes
       OR NEW.movement_id     IS DISTINCT FROM OLD.movement_id
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
       OR NEW.created_by      IS DISTINCT FROM OLD.created_by
       OR OLD.cogs_entry_id   IS NOT NULL
       OR NEW.cogs_entry_id   IS NULL
    THEN
        RAISE EXCEPTION 'SALE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_sales_records_immutable
    BEFORE UPDATE OR DELETE ON public.sales_records
    FOR EACH ROW EXECUTE FUNCTION public.reject_sales_record_mutation();

ALTER TABLE public.sales_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sales_records select by permission"
    ON public.sales_records
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "sales_records insert by permission"
    ON public.sales_records
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "sales_records update by permission"
    ON public.sales_records
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

-- cut 2a:窄用途 UPDATE 策略 —— 仅为 SECURITY INVOKER 函数补挂 cogs_entry_id 放行;
-- 列级限制由上面的守卫触发器执行(除 COGS 首挂外一律 SALE_IMMUTABLE)。

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 sales_records_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.sales_records FROM authenticated, anon;
GRANT SELECT (id, output_batch_id, customer_id, quantity, currency, sale_date, notes, movement_id, created_at, created_by, cogs_entry_id)
    ON public.sales_records TO authenticated;

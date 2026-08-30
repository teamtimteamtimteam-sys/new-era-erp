-- db/tables/sales_records.sql
-- Sales facts (quantity + price + currency + USD amount), written only by
-- record_output_sale alongside the 'sale' inventory movement(s).
-- 【SO-2b:movement_id 那一列没有了】一次销售可以跨几个库位桶而写出【多行】流水
-- (IOD-1 起),而一个单值外键只装得下第一条 —— 那一列因此一直在说半句真话。
-- 腿在 db/tables/sales_record_movements.sql 里,一条一行。
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
    amount_base      numeric NOT NULL,  -- round(quantity × unit_price × fx_rate, 2)
    sale_date       date NOT NULL,
    notes           text,
    created_at      timestamptz DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    -- 在列序末尾:cut 2a 用 ALTER ADD COLUMN 追加(镜像按线上 attnum 排)。
    -- COGS 分录链接(售时或 allocate 补挂)。
    cogs_entry_id   uuid REFERENCES public.journal_entries (id),
    -- ── SAL-A 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 售价出处(FIN-26 的卖方半边):computed 必带依据、manual 明说、NULL = SAL-A
    -- 之前的行(不回填)。配对 CHECK 让"没有依据的 computed"不可表示。
    price_source     text CHECK (price_source IN ('computed', 'manual')),
    price_provenance jsonb,
    -- ── SO-3b 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 【这一行是不是订单流发货产生的】非空 = 是,并指向它满足的那条订单行。
    -- 后果【就在本刀落地】,不是将来:这样的行【不产生应收】——
    -- 应收在开票当刻就记过了(借 1100 / 贷 2500),发货只是把负债释放进收入。
    -- ar_open_items 的第一支与 customer_ar_exposure_base 的第一项都排除它,
    -- 于是同一笔债不会被数两遍(选项 C 的核心不变量:应收只创建一次)。
    -- 【一次性写入】:由 ship_order 在 INSERT 当刻写好,之后不可改。
    sales_order_line_id uuid REFERENCES public.sales_order_lines (id),
    CONSTRAINT sales_records_provenance_pairing
        CHECK ((price_source = 'computed') = (price_provenance IS NOT NULL))
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
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.currency        IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate         IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base      IS DISTINCT FROM OLD.amount_base
       OR NEW.sale_date       IS DISTINCT FROM OLD.sale_date
       OR NEW.notes           IS DISTINCT FROM OLD.notes
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
       OR NEW.created_by      IS DISTINCT FROM OLD.created_by
       -- SAL-A:出处两列同样不可变 —— 卖出去之后改口"这是算出来的"与改价同罪
       OR NEW.price_source     IS DISTINCT FROM OLD.price_source
       OR NEW.price_provenance IS DISTINCT FROM OLD.price_provenance
       -- SO-3b:订单行标记同样不可变 —— 改它就是把一笔"已在发票上认过的债"
       -- 悄悄变成一笔新的应收(或反过来),而两者的差别正是选项 C 的全部。
       OR NEW.sales_order_line_id IS DISTINCT FROM OLD.sales_order_line_id
       -- cut 2a:cogs_entry_id 首挂(NULL → 非 NULL),挂上之后不许再动
       OR (NEW.cogs_entry_id IS DISTINCT FROM OLD.cogs_entry_id
           AND NOT (OLD.cogs_entry_id IS NULL AND NEW.cogs_entry_id IS NOT NULL))
       -- SAL-C:customer_id 的【单向】放宽 —— 只允许 NULL → 某客户,且只允许
       -- attribute_sale_customer 那一次(ctx 在场)。改投他人 / 退回 NULL 一律拒:
       -- 把已存在的债改记到另一个人头上是另一种行为,不该从这条路够得着。
       OR (NEW.customer_id IS DISTINCT FROM OLD.customer_id
           AND NOT (OLD.customer_id IS NULL
                    AND NEW.customer_id IS NOT NULL
                    AND current_setting('evoltrya.attribution_ctx', true) = 'attribute_sale_customer'))
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
GRANT SELECT (id, output_batch_id, customer_id, quantity, currency, sale_date, notes, created_at, created_by, cogs_entry_id, price_source)
    ON public.sales_records TO authenticated;
-- SO-3b:订单行标记非敏感,进列清单(colgrant 由此闭合)。
GRANT SELECT (sales_order_line_id) ON public.sales_records TO authenticated;

-- FIN-1a:改名列的注释(说明写在数据库里,重建出来的库也带着)
COMMENT ON COLUMN public.sales_records.amount_base IS '本位币金额(以 currencies.is_base 为币种 —— 不写死币种;FIN-1a 前列名 amount_usd)。';

COMMENT ON COLUMN public.sales_records.price_source IS
    '售价的出处(SAL-A,FIN-26 的卖方半边):computed = 报价按钮产出(必带 price_provenance);manual = 手填。NULL = SAL-A 之前的行,当时没记 —— 【不回填猜测】,界面画"未知"。不要从公式在不在推断。';
COMMENT ON COLUMN public.sales_records.price_provenance IS
    'computed 行的重导出依据(SAL-A):逐金属行情与日期、金属含量、应付比例、处理费与折扣、汇率与 as-of 与【边】(tt_buy —— 收钱进来)、以及 price_series(当前恒为 metal_prices:每金属只有一条序列,LME/SMM 表达不了,出处只写真正查过的东西)。不能重导出的出处只是标签。';

COMMENT ON COLUMN public.sales_records.sales_order_line_id IS
    'SO-3b:这一行是不是【订单流发货】产生的。非空 = 是,并指向它满足的那条订单行。后果就在本刀落地:这样的行【不产生应收】—— 那笔债在开票当刻已经记过(借 1100 / 贷 2500),发货只是把负债释放进收入。ar_open_items 的第一支与 customer_ar_exposure_base 的第一项都显式排除它,于是同一笔债不会被数两遍(选项 C 的核心不变量:应收只创建一次)。由 ship_order 在 INSERT 当刻写好,之后不可改(SALE_IMMUTABLE)。';

-- PROC-BUILD-1(R5):**record_output_sale 与 ship_order 共用的那一个门。**
-- output_batch_id 是 NOT NULL,所以货真的离场的每一条路都经过这里 ——
-- 拦一条放一条比不拦更糟,因为它制造信心。
CREATE TRIGGER trg_sales_records_form_saleable
    BEFORE INSERT ON public.sales_records
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_form_saleable();

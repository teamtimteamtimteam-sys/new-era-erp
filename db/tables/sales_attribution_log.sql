-- db/tables/sales_attribution_log.sql
-- 无主销售【补挂客户】的只增不改留痕(SAL-C)。
--
-- 补挂记录的是一个【已经成立】的事实(货卖了、钱欠着),不是新的承诺 ——
-- 所以 attribute_sale_customer 不做信用检查。但"谁在什么时候把哪笔债记到了谁
-- 头上"必须留下来,并且【连补挂那一刻的敞口一起记】:那常常正是越限发生的时刻。
--
-- 唯一写入口是 attribute_sale_customer(SECURITY DEFINER)—— 所以没有 INSERT 策略。
-- NOTE: introduced by db/migrations/2026-08-10-salc-attribute-ownerless-sale.sql.

CREATE TABLE public.sales_attribution_log (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_record_id  uuid NOT NULL REFERENCES public.sales_records (id),
    customer_id      uuid NOT NULL REFERENCES public.customers (id),
    amount_base      numeric NOT NULL,
    exposure_after   numeric NOT NULL,
    note             text,
    attributed_at    timestamptz NOT NULL DEFAULT now(),
    attributed_by    uuid
);

CREATE INDEX idx_sales_attribution_log_sale
    ON public.sales_attribution_log (sales_record_id, attributed_at DESC);

CREATE TRIGGER trg_sales_attribution_log_append_only
    BEFORE UPDATE OR DELETE ON public.sales_attribution_log
    FOR EACH ROW EXECUTE FUNCTION public.guard_sales_attribution_log_append_only();

ALTER TABLE public.sales_attribution_log ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sales_attribution_log select by permission"
    ON public.sales_attribution_log
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.sales_attribution_log IS
    '无主销售【补挂客户】的只增不改留痕(SAL-C)。补挂是记录一个已经成立的事实,所以不做信用检查;但谁在什么时候把哪笔债记到了谁头上,必须留下来 —— 补挂当时的敞口一并记下(exposure_after),因为它常常是"越限"的那一刻。';

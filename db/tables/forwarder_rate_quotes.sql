-- db/tables/forwarder_rate_quotes.sql
-- LOG-1a。镜像与 db/migrations/2026-08-19-log1a-*.sql 同源。
-- 守卫函数 guard_forwarder_rate_quote() 的定义在 db/functions/,这里只挂触发器。

CREATE TABLE public.forwarder_rate_quotes (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id  uuid NOT NULL REFERENCES public.suppliers (id),
    lane_id      uuid NOT NULL REFERENCES public.lanes (id),
    amount_ccy   numeric NOT NULL CHECK (amount_ccy > 0),
    currency     text NOT NULL REFERENCES public.currencies (code),
    valid_from   date NOT NULL,
    valid_to     date NOT NULL,
    notes        text,
    deleted_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    CONSTRAINT frq_validity_order CHECK (valid_to >= valid_from)
);

COMMENT ON TABLE public.forwarder_rate_quotes IS
'LOG-1a:某家货代在某条航段上的报价,带有效期与币种。
**它什么都不入账** —— 没有分录、没有应付、不进 ap_open_items。报价是"他说要多少",实际运费是 freight_documents 那张【凭证】,两者是两件事。
把它们混成一张表,就等于让一份报价看起来像一笔负债 —— 而本仓库对"看起来像答案的东西"点过很多次名。
汇率在这里【不锁】:报价只带币种,锁率发生在实际运费凭证上(freight_documents.fx_rate)。';

CREATE TRIGGER trg_forwarder_rate_quotes_guard
    BEFORE INSERT OR UPDATE ON public.forwarder_rate_quotes
    FOR EACH ROW EXECUTE FUNCTION guard_forwarder_rate_quote();

ALTER TABLE public.forwarder_rate_quotes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "forwarder_rate_quotes select" ON public.forwarder_rate_quotes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "forwarder_rate_quotes write" ON public.forwarder_rate_quotes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

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
    CONSTRAINT frq_validity_order CHECK (valid_to >= valid_from),
    -- ── LOG-5a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【NULL 与 0 是两件不同的事】—— 见列注释,免柜期那一支告警整个压在这条区别上。
    free_days    integer CHECK (free_days IS NULL OR free_days >= 0)
);

COMMENT ON TABLE public.forwarder_rate_quotes IS
'LOG-1a:某家货代在某条航段上的报价,带有效期与币种。
**它什么都不入账** —— 没有分录、没有应付、不进 ap_open_items。报价是"他说要多少",实际运费是 freight_documents 那张【凭证】,两者是两件事。
把它们混成一张表,就等于让一份报价看起来像一笔负债 —— 而本仓库对"看起来像答案的东西"点过很多次名。
汇率在这里【不锁】:报价只带币种,锁率发生在实际运费凭证上(freight_documents.fx_rate)。';

COMMENT ON COLUMN public.forwarder_rate_quotes.amount_ccy IS
    'LOG-4a:分母是【每一个集装箱】(Tim 定)。这一列不带单位列,是因为单位是一条
【决定】而不是一个字段:改成每票或每重量单位,要动的是这条决定与随之而来的比较口径,
不是给这张表加一列。实际运费与它的比较在 LOG-4b 之后才成立 —— 那时读的仍是这个分母。';

COMMENT ON COLUMN public.forwarder_rate_quotes.free_days IS
    'LOG-5a:这份报价给了几个免柜天。
【NULL 与 0 是两件不同的事,而这条区别撑着整支告警】
  * NULL = 【这份报价没有写免柜期】—— 我们不知道,于是那一支告警【保持沉默】;
  * 0    = 【零个免费天】—— 一到港就开始计滞港费,告警从第一天起就该响。
把 NULL 当成 0,会让每一个到港的箱子从第一天起报警(喊狼来了);
把 0 当成 NULL,会让一个【真的从第一天起就在烧钱】的箱子一声不吭。
两种错的方向相反,而后一种更贵 —— 所以两者都不许被推断,只能被写下来。
CHECK 允许 0,正因为 0 是一个【有人做过的决定】,不是"没填"。';

CREATE TRIGGER trg_forwarder_rate_quotes_guard
    BEFORE INSERT OR UPDATE ON public.forwarder_rate_quotes
    FOR EACH ROW EXECUTE FUNCTION guard_forwarder_rate_quote();

ALTER TABLE public.forwarder_rate_quotes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "forwarder_rate_quotes select" ON public.forwarder_rate_quotes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.logistics.view'::text));
CREATE POLICY "forwarder_rate_quotes write" ON public.forwarder_rate_quotes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.purchasing.edit'::text))
    WITH CHECK (has_permission('module.purchasing.edit'::text));

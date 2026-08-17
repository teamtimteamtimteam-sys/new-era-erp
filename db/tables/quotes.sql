-- db/tables/quotes.sql
-- SO-4a:报价单头 —— 承诺【之前】的那张单据。
--
-- NOTE: introduced by db/migrations/2026-08-15-so4a-quotation-engine.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.quotes (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text NOT NULL UNIQUE,          -- 'QT-YYYY-NNNN',无缝,自己的咨询锁
    -- 【报价的主语就是那个客户】与销售订单同一条(sales_records 那种"事后归属"
    -- 只对已经发生的销售成立;一张报价是"报给某人"的)。
    -- 【但它不要求客户是"正式客户"】customers 只强制 legal_name 与 country,
    -- status 是自由文本、默认 'draft',而且【全库没有任何一处按它把关】——
    -- 所以给一个潜在客户报价,不需要先走完开户。这是现有地基,不是本刀放宽的。
    customer_id   uuid NOT NULL REFERENCES public.customers (id),
    -- 【两个物理日期,都必填、都永不默认】(AGENTS.md 的日期规矩)
    quote_date    date NOT NULL,
    valid_until   date NOT NULL,
    currency      text NOT NULL REFERENCES public.currencies (code),
    -- 【汇率没有默认值 —— FIN-35】假设出来的 1:1 在非本位币单据上永远是错的,
    -- 而且看起来完全正常。转换时它被【原样抄】进订单(见本文件抬头)。
    fx_rate       numeric NOT NULL CHECK (fx_rate > 0),
    status        text NOT NULL DEFAULT 'draft'
                  CHECK (status IN ('draft','issued','declined','converted')),
    -- 谢绝要给理由:一张没有理由的谢绝,三个月后没有人说得出对方为什么没买。
    decline_reason text,
    -- 【只写一次】由 convert_quote 与 status='converted' 在同一条语句里写下,
    -- 此后守卫拒绝任何改动(见 guard_quote_converted_immutable)。
    converted_order_id uuid REFERENCES public.sales_orders (id),
    notes         text,
    terms_text    text,
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid,
    -- 【有效期不能早于报价日】一张"从来没有有效过"的报价是录入错误,不是业务情形。
    CONSTRAINT quotes_validity_window CHECK (valid_until >= quote_date),
    CONSTRAINT quotes_decline_reason_required
        CHECK (status <> 'declined' OR decline_reason IS NOT NULL),
    -- 状态与那个外键必须一起成立:converted 却没有订单,或者有订单却不是 converted,
    -- 两者都是"说了一半"的行。
    CONSTRAINT quotes_converted_pairing
        CHECK ((status = 'converted') = (converted_order_id IS NOT NULL)),
    -- ── AUDEL-1b 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    deleted_by    uuid,
    delete_reason text
);

COMMENT ON TABLE public.quotes IS
    'SO-4a:报价单 —— 承诺【之前】的那张单据。它不碰库存、不碰总账(没有预留、没有发货、没有分录、没有应收),因此也没有销售订单那三条下限。唯一的特权是经 convert_quote 变成一张订单,而那扇门不是新写的:它【调用】create_sales_order,把行、价、出处、币种、汇率原样抄过去。【冻结点与订单刻意不同】:订单在【确认】时冻,因为确认之后有钱和货站在那些数字上;报价是谈判过程中的东西,改价改量本来就是它的用途,所以 draft/issued 的行【不上冻结守卫】—— 被冻住的是每一次【签发】的那份字节(qt_issues,sha256 对得上才给取回)。"签发之后又改过"由 updated_at 与最新一版 issued_at 两个时间戳比出来,不由状态位记着。converted 的行是冻的(QT_CONVERTED_IMMUTABLE)。过期【算出来,不存】:quote_is_expired(valid_until),三个消费方读同一份。';

COMMENT ON COLUMN public.quotes.valid_until IS
    'SO-4a:这张报价有效到哪一天(含当天)。【物理承诺日,必填、永不默认】—— 一个补出来的有效期永远不会在它该过期的那天过期,于是"留空"比"填对"更容易通过。过期是【读的时候算】的(quote_is_expired,valid_until < CURRENT_DATE),不存状态位、不跑定时任务:标志位要有人去清,而没有人会记得清它。边界含当天 —— 有效期等于今天的报价【仍然转得了单】,那是"有效到某日"这句话的字面意思。';

COMMENT ON COLUMN public.quotes.converted_order_id IS
    'SO-4a:这张报价变成的那张销售订单。【只写一次】:由 convert_quote 与 status=''converted'' 在同一条语句里写下,此后守卫拒绝任何改动(QT_CONVERTED_IMMUTABLE)。有它就是 converted、是 converted 就必须有它(quotes_converted_pairing)—— 两者说的是同一件事,分开成立就是"说了一半"的行。';

CREATE INDEX idx_quotes_customer ON public.quotes (customer_id, quote_date DESC);
CREATE INDEX idx_quotes_status   ON public.quotes (status);
CREATE INDEX idx_quotes_valid    ON public.quotes (valid_until) WHERE deleted_at IS NULL;

-- 【converted 之后整行冻住】它已经变成一张订单了,再改它就是让"当初报的是什么"
-- 与"照它下的单是什么"分家。converted_order_id 的【只写一次】也落在这里。
-- 【draft / issued 【不】上冻结守卫,这是设计】—— 见表注释:报价是谈判过程中的
-- 东西,被冻住的是每一次【签发】的那份字节(qt_issues),不是这张单据本身。
CREATE TRIGGER trg_quotes_converted_immutable
    BEFORE UPDATE OR DELETE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_converted_immutable();

-- updated_at 由它维护 —— "签发之后又改过"那个信号比的就是它与最新一版
-- qt_issues.issued_at,所以它不是装饰。
-- 【自己的时钟,不借共用的 update_updated_at —— fu1】那个助手写的是 now(),
-- 而 now() 是事务开始时刻、在一个事务里是常量:同一事务里先签发后改动会拿到
-- 同一个时间戳,信号于是永远不亮(fixture 72 G 臂撞出来的)。这一列的全部用途
-- 就是比出先后,所以它要一个【会走】的时钟(clock_timestamp)。其余十几张表的
-- updated_at 是审计痕迹、没有人拿去比先后,继续用共用的那个。
CREATE TRIGGER trg_quotes_updated_at
    BEFORE UPDATE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.quotes_touch_updated_at();

-- 【单号由触发器填,不由客户端取】next_quote_code 对 authenticated 收权,而建报价
-- 走直连、没有 RPC 门可以代取 —— 解法是让号根本不由客户端取(先例:
-- customers.generate_customer_code)。客户端插的是一行【没有号】的报价。
CREATE TRIGGER trg_quotes_generate_code
    BEFORE INSERT ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.generate_quote_code();

-- 【建单留痕靠触发器,不靠一扇门】SO-1 的建单留痕被 RLS 拒且错误被丢掉,
-- 线上 SO-2026-0001 至今缺着那一行;SO-2b 的修法是收门,而报价这边直接编辑
-- 就是设计,收门走不通 —— 换成 AFTER INSERT。两种解法,同一条保证。
CREATE TRIGGER trg_quotes_history_created
    AFTER INSERT ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.trg_quote_history_created();

ALTER TABLE public.quotes ENABLE ROW LEVEL SECURITY;

-- 【报价可以直连增删改,而这是设计,不是疏忽】改价改量就是报价的用途。
-- 真正不能绕的两件事各有机制:'created' 留痕由触发器保证,converted 之后的
-- 冻结由守卫保证。
CREATE POLICY "quotes select by permission" ON public.quotes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "quotes insert by permission" ON public.quotes
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "quotes update by permission" ON public.quotes
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));

-- AUDEL-1b:置 deleted_at 必须走【门】(函数),且 deleted_by / delete_reason 必须填好。
-- 光加两列挡不住任何事 —— 软删本来就是一次直连 UPDATE。
CREATE TRIGGER trg_quotes_soft_delete_provenance
    BEFORE UPDATE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();

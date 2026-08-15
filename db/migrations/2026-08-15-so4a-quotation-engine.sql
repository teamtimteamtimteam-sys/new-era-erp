-- SO-4a(2026-08-15):报价 —— 承诺【之前】的那张单据,而它唯一的特权是变成订单
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【一句话:报价不碰库存、不碰总账】它没有预留、没有发货、没有分录、没有应收,
-- 因此也【没有】订单那三条下限(已发/已开票/已预留)。它唯一的特权是经
-- convert_quote 变成一张订单 —— 而那扇门本身不是新写的,是 create_sales_order。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【冻结点在哪:这是本刀最要紧的一个设计判断】
-- 订单的冻结点是【确认】(guard_sales_order_confirmed_immutable 认 status='draft'),
-- 因为确认之后有钱和货站在那些数字上。报价没有那样的下游 —— 它是一件
-- 【谈判过程中的东西】:改价、改量、加一行、去一行,本来就是它的用途。
-- 所以:
--
--   * draft 与 issued 的行【不上冻结守卫】。这不是漏了,是设计:给一个还在谈的
--     东西上锁,只会逼出"作废重开"这种假动作(SO-1b 那一刀的整个由来)。
--   * 【被冻住的是每一次「签发」】—— qt_issues 里的那份字节。客户手里拿着的是
--     某一个具体版本,而那份字节此后一个字都不会变(sha256 对得上才给取回)。
--   * 于是"这张报价在签发之后又改过"这件事由【两个时间戳比出来】,不由一个
--     状态位记着:quotes.updated_at vs 最新一版 qt_issues.issued_at。
--     标志位要有人去清,而没有人会记得清它(SO-1b 的 amendedSinceIssue 同一条)。
--     ※ 因此本刀给 quote_lines 加了一个【回touch 父行 updated_at】的触发器:
--       改一行明细而表头的 updated_at 不动,那个信号就会对最常见的一种改动
--       视而不见 —— 而一个看漏了的信号比没有信号更坏。
--   * 【converted 的行是冻的】(QT_CONVERTED_IMMUTABLE):它已经变成一张订单了,
--     再改它就是让"当初报的是什么"与"照它下的单是什么"分家。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【建单留痕:这次靠触发器,不靠一扇门 —— 而这是同一个教训的另一种解法】
-- SO-1 的建单是三条客户端直插,第三条(留痕)被 RLS 拒、错误被丢掉,于是线上
-- SO-2026-0001 至今缺着 'created' 那一行;SO-2b 的修法是把建单收进一扇门。
-- 报价这边【直接编辑就是设计本身】,所以收门是走不通的 —— 换成一个 AFTER INSERT
-- 触发器写 'created'。两种解法,同一条保证:留痕不能是"想写才写"的。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【过期是【算】出来的,不是存下来的,也没有定时任务】
-- quote_is_expired(valid_until) —— 一个纯日期函数,三个消费方读同一份:
-- quote_status 视图(4b 的列表与详情)、convert_quote 的拒绝。
-- 先例是 CMP-1/CMP-2 的证书过期(视图 supplier_receiving_blocked + 收货触发器),
-- 【但那一对把谓词写了两遍】,它自己的注释写着"改一边要改两边"。这里不重演:
-- 一个函数,三个消费方。CURRENT_DATE 可靠,因为 FIN-20 把库的时区设成了
-- Asia/Singapore,而 fixture 15 钉着"库的今天就是新加坡的今天"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【转换:一处实现,一扇门】convert_quote 不重写建单 —— 它【调用】
-- create_sales_order,把报价的行、价、出处、币种、汇率【原样抄过去】。
--   * DEFINER 调 DEFINER 不会绕过权限:require_permission 解析的是【调用者】的
--     JWT,与谁拥有函数无关。
--   * 【汇率抄报价的,不是转换当天现取的】—— 这是 SO-4 调查里点名的那个未决问题,
--     本刀按"抄"落地。代价要说清楚:报价三周前按 X 定的价,今天转成订单仍按 X
--     记账,于是发票的 1100/2500 会用一个三周前的汇率。选它的理由是【价格是
--     谈定的条款】(FIN-27 一族),而汇率与价格在这张报价上是一体的一句话;
--     若哪天判断反过来,改的是这一处,不是四处。
--   * 【订单日不抄】它是一个【新的】物理事实(客户接受的那一天),而且决定单号
--     年份与汇率期间。抄报价日就是把一次今天做出的承诺记到过去。它由调用方递入,
--     空值由 create_sales_order 自己按名拒(ORDER_DATE_REQUIRED)—— 不在这里
--     再写一遍那条规则。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 单据头 ════════════════════════════════════════════════════════════
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
        CHECK ((status = 'converted') = (converted_order_id IS NOT NULL))
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

-- ═══ 2 · 单据行 ════════════════════════════════════════════════════════════
CREATE TABLE public.quote_lines (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id    uuid NOT NULL REFERENCES public.quotes (id) ON DELETE CASCADE,
    line_no     integer NOT NULL CHECK (line_no >= 1),
    -- 【行指向物料,不指向批次】与订单行逐字同一条:客户买的是"一种产品"。
    -- 报价更是如此 —— 报的时候那批货可能还没生产出来。
    material_id uuid NOT NULL REFERENCES public.materials (id),
    quantity    numeric NOT NULL CHECK (quantity > 0),
    unit_price  numeric NOT NULL CHECK (unit_price > 0),
    -- FIN-26 的形状,与订单行【逐字同一条约束】:出处记录、不事后推断,
    -- 要么都有要么都没有。转换时这两列【原样抄】进订单行 —— 一次转换不该
    -- 把"这个价是算出来的"变成"这个价是手敲的"。
    price_source     text CHECK (price_source IN ('computed','manual')),
    price_provenance jsonb,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (quote_id, line_no),
    CONSTRAINT quote_lines_provenance_pairing CHECK (
        (price_source IS NULL AND price_provenance IS NULL)
        OR (price_source IS NOT NULL AND price_provenance IS NOT NULL)
    )
);

COMMENT ON TABLE public.quote_lines IS
    'SO-4a:报价行 —— 与 sales_order_lines 同形(指向物料不指向批次;price_source/price_provenance 按 FIN-26 成对)。转换时这几列【原样抄】进订单行:一次转换不该把"这个价是算出来的"改写成"手敲的",也不该重算任何一个数 —— 那等于系统替人重新谈了一次。【draft/issued 的行可以自由增删改】(报价就是谈判过程),但父报价一旦 converted 就整个冻住。';

CREATE INDEX idx_quote_lines_quote ON public.quote_lines (quote_id, line_no);

-- ═══ 3 · 历史 ══════════════════════════════════════════════════════════════
CREATE TABLE public.quote_history (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id    uuid NOT NULL REFERENCES public.quotes (id),
    -- 【只记生命周期的四件事,不记逐行编辑】报价的每一次改动都是谈判本身,
    -- 记进来只会把这四件真正的事件淹掉;而"当时报的是什么"有一个更硬的答案 ——
    -- qt_issues 里那份签发过的字节。
    change_type text NOT NULL CHECK (change_type IN ('created','issued','declined','converted')),
    detail      text,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    changed_by  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.quote_history IS
    'SO-4a:报价的生命周期留痕,只增不改(形状取自 sales_order_history)。【只记四件事】created / issued / declined / converted —— 逐行编辑不进来:报价的每一次改动都是谈判本身,记进来会把这四个真正的事件淹掉,而"当时报的是什么"有一个更硬的答案(qt_issues 里签发过的那份字节)。【created 由触发器写,不由某扇门写】:SO-1 的建单是三条客户端直插、留痕那条被 RLS 拒且错误被丢掉,于是线上 SO-2026-0001 至今缺着那一行;SO-2b 的修法是收门,而报价这边【直接编辑就是设计】,收门走不通 —— 换成 AFTER INSERT 触发器。两种解法,同一条保证:留痕不能是"想写才写"的。';

CREATE INDEX idx_quote_history_quote ON public.quote_history (quote_id, changed_at DESC);

-- ═══ 4 · 签发档(so_issues 的第五份,一个字没改)═════════════════════════════
CREATE TABLE public.qt_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    quote_id   uuid NOT NULL REFERENCES public.quotes (id),
    version    integer NOT NULL CHECK (version >= 1),
    file_path  text NOT NULL,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (quote_id, version)
);

COMMENT ON TABLE public.qt_issues IS
    'SO-4a:报价的签发档,形状逐字取自 so_issues / po_issues / shipment_issues / cn_issues(这是第五份)。【它比别处更要紧】:报价的 draft/issued 行不上冻结守卫,所以"当初报的是什么"这个问题的唯一硬答案就是这里的字节 —— 客户手里那份是某个具体版本,sha256 对不上就拒绝给出。唯一写入口 record_qt_issue();第一次签发把 draft 翻成 issued。';

CREATE INDEX idx_qt_issues_quote ON public.qt_issues (quote_id, version DESC);

-- ═══ 5 · 守卫 ══════════════════════════════════════════════════════════════
-- 【converted 之后整行冻住】它已经变成一张订单了,再改它就是让"当初报的是什么"
-- 与"照它下的单是什么"分家。converted_order_id 的【只写一次】也落在这里:
-- 写它的那一刻 OLD.status 还是 'issued',所以下面第一支放行;此后 OLD.status
-- 已是 'converted',任何改动都撞第一支。第二支是给"状态没跟上却想换订单"那种
-- 畸形路径留的,它今天走不到,但守卫不该依赖"今天走不到"。
CREATE OR REPLACE FUNCTION public.guard_quote_converted_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'converted' THEN
            RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|delete|%', OLD.code;
        END IF;
        RETURN OLD;
    END IF;
    IF OLD.status = 'converted' THEN
        RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|row|%', OLD.code;
    END IF;
    IF OLD.converted_order_id IS NOT NULL
       AND NEW.converted_order_id IS DISTINCT FROM OLD.converted_order_id THEN
        RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|converted_order_id|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_quotes_converted_immutable
    BEFORE UPDATE OR DELETE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_converted_immutable();

CREATE TRIGGER trg_quotes_updated_at
    BEFORE UPDATE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- 【单号由触发器填,不由客户端取】—— 这一条是被自己的 REVOKE 逼出来的,记下来:
-- next_quote_code 对 authenticated 是收权的(取号器无调用者检查,靠调不到),
-- 而建报价【走直连】是本刀的设计,没有 RPC 门可以以属主身份代取。两者放在一起,
-- 客户端就永远拿不到号 —— 除非号根本不由客户端取。
-- 先例就在库里:customers.generate_customer_code 也是 BEFORE INSERT 填 code。
-- 【为什么这不是把门开回来】客户端插的是一行【没有号】的报价,号由属主身份的
-- 触发器在同一条语句里补上:它偷不到别人的号,也伪造不了一个。
CREATE OR REPLACE FUNCTION public.generate_quote_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.code IS NULL OR btrim(NEW.code) = '' THEN
        NEW.code := next_quote_code(NEW.quote_date);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_quotes_generate_code
    BEFORE INSERT ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.generate_quote_code();

-- 【行也跟着父报价冻】—— 否则"整行冻住"只冻了表头,而报价的内容全在行上。
CREATE OR REPLACE FUNCTION public.guard_quote_line_converted_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q quotes%ROWTYPE;
BEGIN
    SELECT * INTO v_q FROM quotes WHERE id = COALESCE(NEW.quote_id, OLD.quote_id);
    IF v_q.status = 'converted' THEN
        RAISE EXCEPTION 'QT_CONVERTED_IMMUTABLE|lines|%', v_q.code;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER trg_quote_lines_converted_immutable
    BEFORE INSERT OR UPDATE OR DELETE ON public.quote_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_line_converted_immutable();

-- 【改一行明细,把父报价的 updated_at 顶上去】"签发之后又改过"那个信号比的是
-- quotes.updated_at 与最新一版 qt_issues.issued_at。改行而表头不动,信号就会
-- 对【最常见的一种改动】视而不见 —— 而一个看漏了的信号比没有信号更坏。
CREATE OR REPLACE FUNCTION public.trg_quote_line_touches_parent()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【父行已经不在时是一次空更新,而不是一个错误】整张报价被硬删时,级联
    -- 删子行会走到这里,而那时父行在本快照里已经删掉 —— UPDATE 命中 0 行。
    -- 写下来是因为"命中 0 行"在别处通常是要报警的(失败不是空集),这里它
    -- 恰恰是对的:父行没了,没有 updated_at 需要顶。
    UPDATE quotes SET updated_at = now(), updated_by = auth.uid()
     WHERE id = COALESCE(NEW.quote_id, OLD.quote_id);
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE TRIGGER trg_quote_lines_touch_parent
    AFTER INSERT OR UPDATE OR DELETE ON public.quote_lines
    FOR EACH ROW EXECUTE FUNCTION public.trg_quote_line_touches_parent();

-- 【建单留痕靠触发器 —— 见 quote_history 的表注释】
CREATE OR REPLACE FUNCTION public.trg_quote_history_created()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    INSERT INTO quote_history (quote_id, change_type, detail, changed_by)
    VALUES (NEW.id, 'created', NEW.code, NEW.created_by);
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_quotes_history_created
    AFTER INSERT ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.trg_quote_history_created();

CREATE OR REPLACE FUNCTION public.guard_quote_history_append_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 自己报名,不靠外键顺带挡(FIN-31)
    RAISE EXCEPTION 'QT_HISTORY_IMMUTABLE|%', TG_OP;
END;
$function$;

CREATE TRIGGER trg_quote_history_append_only
    BEFORE UPDATE OR DELETE ON public.quote_history
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_history_append_only();

CREATE TRIGGER trg_qt_issues_append_only
    BEFORE UPDATE OR DELETE ON public.qt_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_history_append_only();

-- ═══ 6 · RLS ═══════════════════════════════════════════════════════════════
-- 【报价可以直连增删改,而这是设计,不是疏忽】见本文件抬头:draft/issued 的行
-- 不上冻结守卫,因为改价改量就是报价的用途。真正不能绕的两件事各有机制:
-- 'created' 留痕由触发器保证(不靠哪扇门),converted 之后的冻结由守卫保证。
ALTER TABLE public.quotes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_lines   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.qt_issues     ENABLE ROW LEVEL SECURITY;

CREATE POLICY "quotes select by permission" ON public.quotes
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "quotes insert by permission" ON public.quotes
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "quotes update by permission" ON public.quotes
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));

CREATE POLICY "quote_lines select by permission" ON public.quote_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "quote_lines insert by permission" ON public.quote_lines
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "quote_lines update by permission" ON public.quote_lines
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.sales.edit'::text)) WITH CHECK (has_permission('module.sales.edit'::text));
CREATE POLICY "quote_lines delete by permission" ON public.quote_lines
    AS PERMISSIVE FOR DELETE TO authenticated USING (has_permission('module.sales.edit'::text));

-- 留痕与签发档【没有 INSERT 策略】:唯一写入口是属主权限的触发器/函数
-- (同 approval_log / so_issues:档案不该有第二个写法)。
CREATE POLICY "quote_history select by permission" ON public.quote_history
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));
CREATE POLICY "qt_issues select by permission" ON public.qt_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.sales.view'::text));

-- ═══ 7 · 取号 ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.next_quote_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】QT 与 SO / INV / CN 各自连号 —— 共用一把会让一种单据
    -- 烧掉另一种的号,而无缝的意思正是"号码之间没有洞"。
    PERFORM pg_advisory_xact_lock(hashtext('quote_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM quotes
    WHERE code LIKE 'QT-' || v_year::text || '-%';
    RETURN 'QT-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- ═══ 8 · 过期:一处推导,三个消费方 ═════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.quote_is_expired(p_valid_until date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    -- SO-4a:【过期是算出来的,不存,也没有定时任务】
    -- 三个消费方读这一份:quote_status(列表与详情)、convert_quote 的拒绝。
    --
    -- 【为什么不是一个状态位】位要有人去清 —— 而 valid_until 一改,那个位就
    -- 立刻是假的,并且不会有任何东西提醒谁去改它。两个日期一比,答案永远是
    -- 当下的真相(同 SO-1b 的 amendedSinceIssue、FIN-30 的 ties)。
    --
    -- 【为什么不抄 CMP-1 那一对】证书过期的先例是【视图一遍 + 触发器一遍】,
    -- 它自己的注释写着"改一边要改两边",靠 fixture 37F 钉着两者一致。
    -- 这里不重演:一个函数,三个消费方。
    --
    -- 【边界含当天】valid_until = 今天的报价【仍然有效】—— "有效到 8 月 15 日"
    -- 的字面意思就是 15 日当天还算数。所以是严格小于。
    --
    -- 【不是 SECURITY DEFINER,所以不进 B2 那道判词】它只做日期算术,不读任何
    -- 一行业务数据,没有可保护的东西,也就没有"靠调不到"这回事。
    SELECT p_valid_until < CURRENT_DATE;
$function$;

COMMENT ON FUNCTION public.quote_is_expired(date) IS
    'SO-4a:这张报价过期了没有 —— valid_until < CURRENT_DATE,【边界含当天】(有效期等于今天仍然有效)。一处推导,三个消费方:quote_status 视图(4b 的列表与详情)与 convert_quote 的拒绝。不存状态位、不跑定时任务:位要有人去清,而 valid_until 一改那个位就立刻是假的。CURRENT_DATE 可靠 —— FIN-20 把库的时区设成 Asia/Singapore,fixture 15 钉着"库的今天就是新加坡的今天"。';

CREATE VIEW public.quote_status WITH (security_invoker = off) AS
 SELECT q.id AS quote_id,
    q.code,
    q.customer_id,
    c.code AS customer_code,
    c.legal_name AS customer_name,
    q.quote_date,
    q.valid_until,
    q.currency,
    q.fx_rate,
    q.status,
    q.decline_reason,
    q.converted_order_id,
    so.code AS converted_order_code,
    -- 【派生态,与存下来的 status 并列而不是替代它】—— 与 medical_claim_status
    -- 的 settlement_state 同一个形状:存的那个说"人做了什么",派生的那个说
    -- "日历走到哪了"。合成一个会让"过期"看起来像一次有人做过的动作。
    quote_is_expired(q.valid_until) AS expired,
    -- 转得了单吗:issued、没过期、没转过。这一句与 convert_quote 的拒绝
    -- 【顺序一致】,于是屏幕上禁用的理由与服务端拒绝的名字对得上(CMP-2)。
    (q.status = 'issued' AND NOT quote_is_expired(q.valid_until)) AS convertible,
    (SELECT max(i.version) FROM qt_issues i WHERE i.quote_id = q.id) AS issue_version,
    -- 【签发之后又改过】两个时间戳一比 —— 见本表的设计:被冻住的是每一次签发
    -- 的那份字节,而不是这张单据本身。
    -- 【没签发过 → false,不是 NULL】一张从没签发过的报价谈不上"签发之后又改过"。
    -- 留 NULL 会让屏幕上出现第三种状态,而 NULL 在这个仓库里已经有含义了
    -- (lib/permissions.ts:遮蔽的"受限")—— 借它去表达"不适用"是借错了词。
    COALESCE((SELECT max(i.issued_at) FROM qt_issues i WHERE i.quote_id = q.id) < q.updated_at,
             false) AS amended_since_issue,
    q.notes,
    q.terms_text,
    q.updated_at
   FROM quotes q
     JOIN customers c ON c.id = q.customer_id
     LEFT JOIN sales_orders so ON so.id = q.converted_order_id
  WHERE q.deleted_at IS NULL AND has_permission('module.sales.view'::text);

COMMENT ON VIEW public.quote_status IS
    'SO-4a:报价的读取面 —— 存下来的 status 加三个【派生】列:expired(quote_is_expired,一处推导)、convertible(与 convert_quote 的拒绝顺序一致,于是屏幕上禁用的理由与服务端拒绝的名字对得上)、amended_since_issue(quotes.updated_at 晚于最新一版签发时刻)。派生列与 status 【并列而不是替代】:存的那个说"人做了什么",派生的那个说"日历走到哪了"—— 合成一个会让"过期"看起来像一次有人做过的动作。属主权限 + 整表挂 module.sales.view。';

GRANT SELECT ON public.quote_status TO authenticated;

-- ═══ 9 · 签发 ══════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_qt_issue(p_quote_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q    quotes%ROWTYPE;
    v_next integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_q FROM quotes WHERE id = p_quote_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QT_NOT_FOUND|%', COALESCE(p_quote_id::text, '?');
    END IF;
    -- 谢绝了的、已经转成订单的,都不再签发:那两个状态说的是"这件事结束了",
    -- 而签发是把一份【还在谈】的东西发出去。
    IF v_q.status NOT IN ('draft', 'issued') THEN
        RAISE EXCEPTION 'QT_NOT_ISSUABLE|%|%', v_q.code, v_q.status;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('qt_issue_' || p_quote_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM qt_issues WHERE quote_id = p_quote_id;

    INSERT INTO qt_issues (quote_id, version, file_path, sha256, issued_by)
    VALUES (p_quote_id, v_next, p_file_path, p_sha256, auth.uid());

    -- 【第一次签发就是 draft → issued 那次转换】签发是"发给对方"这件事本身,
    -- 而 issued 的意思正是它。第二次起只追加版本,状态不动。
    IF v_q.status = 'draft' THEN
        UPDATE quotes SET status = 'issued', updated_by = auth.uid() WHERE id = p_quote_id;
        INSERT INTO quote_history (quote_id, change_type, detail)
        VALUES (p_quote_id, 'issued', 'v' || v_next::text);
    END IF;

    RETURN jsonb_build_object('version', v_next, 'status',
        CASE WHEN v_q.status = 'draft' THEN 'issued' ELSE v_q.status END);
END;
$function$;

-- ═══ 10 · 谢绝 ═════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.decline_quote(p_quote_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q quotes%ROWTYPE;
BEGIN
    PERFORM require_permission('module.sales.edit');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'QT_DECLINE_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_q FROM quotes WHERE id = p_quote_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QT_NOT_FOUND|%', COALESCE(p_quote_id::text, '?');
    END IF;
    -- 【只有签发出去的才谈得上谢绝】草稿还没发给任何人,没有人能拒绝它;
    -- 已转成订单的更不必说。
    IF v_q.status <> 'issued' THEN
        RAISE EXCEPTION 'QT_NOT_ISSUED|%|%', v_q.code, v_q.status;
    END IF;
    -- 【过期的报价谢绝得了,这是有意的】过期只是日历走过去了,而"对方明确说
    -- 不要"是一个真实发生的事实 —— 拒绝记录它,只会让那条信息无处安放。

    UPDATE quotes SET status = 'declined', decline_reason = btrim(p_reason),
                      updated_by = auth.uid()
     WHERE id = p_quote_id;

    INSERT INTO quote_history (quote_id, change_type, detail)
    VALUES (p_quote_id, 'declined', btrim(p_reason));

    RETURN jsonb_build_object('quote_id', p_quote_id, 'code', v_q.code, 'status', 'declined');
END;
$function$;

-- ═══ 11 · 转换 —— 一处实现,一扇门 ═════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.convert_quote(p_quote_id uuid, p_order_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q       quotes%ROWTYPE;
    v_lines   jsonb := '[]'::jsonb;
    v_l       record;
    v_n       int := 0;
    v_res     jsonb;
    v_order   uuid;
    v_ocode   text;
    v_made    int;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_q FROM quotes WHERE id = p_quote_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QT_NOT_FOUND|%', COALESCE(p_quote_id::text, '?');
    END IF;

    -- 【拒绝的顺序:先说最具体的那一条】已经转过、被谢绝了,都是比"状态不对"
    -- 更有信息量的答案 —— 而"已经转过"还要说出【转成了哪一张单】,否则人会
    -- 再转一次去找它。
    IF v_q.status = 'converted' THEN
        RAISE EXCEPTION 'QT_ALREADY_CONVERTED|%|%', v_q.code,
            COALESCE((SELECT code FROM sales_orders WHERE id = v_q.converted_order_id), '?');
    END IF;
    IF v_q.status = 'declined' THEN
        RAISE EXCEPTION 'QT_DECLINED|%', v_q.code;
    END IF;
    IF v_q.status <> 'issued' THEN
        RAISE EXCEPTION 'QT_NOT_ISSUED|%|%', v_q.code, v_q.status;
    END IF;
    -- 【过期:边界含当天】有效期等于今天仍然转得了。消息里点出补救办法 ——
    -- 改 valid_until 再签发一版,而不是让人对着一句"过期了"猜下一步。
    IF quote_is_expired(v_q.valid_until) THEN
        RAISE EXCEPTION 'QT_EXPIRED|%|%', v_q.code, v_q.valid_until;
    END IF;

    -- ── 抄行:【一个字都不重算】────────────────────────────────────────────
    -- 【出处两列要么都递、要么都不递 —— 这是一个真的坑】create_sales_order 的
    -- 配对检查问的是【键在不在】(v_line ? 'price_source'),不是值是不是 NULL。
    -- 若无条件把两个键都放进去、值给 NULL,那检查会认为"两个都有",于是
    -- price_provenance 会以 jsonb 的 null【字面量】写进去 —— 它不是 SQL NULL,
    -- 于是 sales_order_lines_provenance_pairing 当场违约。所以按行条件拼。
    -- 【也不用 jsonb_strip_nulls】那个函数是递归的:它会钻进 price_provenance
    -- 里把内层的 null 也删掉 —— 那正是"转换悄悄改了这笔交易"。
    FOR v_l IN SELECT * FROM quote_lines WHERE quote_id = p_quote_id ORDER BY line_no
    LOOP
        v_n := v_n + 1;
        v_lines := v_lines || (
            jsonb_build_object(
                'material_id', v_l.material_id,
                'quantity',    v_l.quantity,
                'unit_price',  v_l.unit_price)
            || CASE WHEN v_l.notes IS NOT NULL
                    THEN jsonb_build_object('notes', v_l.notes) ELSE '{}'::jsonb END
            || CASE WHEN v_l.price_source IS NOT NULL
                    THEN jsonb_build_object('price_source', v_l.price_source,
                                            'price_provenance', v_l.price_provenance)
                    ELSE '{}'::jsonb END);
    END LOOP;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'QT_NO_LINES|%', v_q.code;
    END IF;

    -- ── 建单:【调用那扇门,不重写它】──────────────────────────────────────
    -- DEFINER 调 DEFINER 不绕过权限:require_permission 解析的是【调用者】的
    -- JWT,与谁拥有函数无关。订单日【不抄报价日】—— 它是客户接受的那一天,
    -- 空值由 create_sales_order 自己按名拒(ORDER_DATE_REQUIRED),这里不重写
    -- 那条规则。币种与汇率原样抄(见本文件抬头那一段的代价说明)。
    v_res := create_sales_order(v_q.customer_id, p_order_date, v_q.currency, v_q.fx_rate,
                                v_lines, v_q.notes, v_q.terms_text);
    v_order := (v_res->>'id')::uuid;
    v_ocode := v_res->>'code';

    -- 【断言,不是假设】抄过去几行,就该建出几行。将来有人给上面那个循环加一个
    -- 提前 CONTINUE,这里当场炸,而不是留下一张【少了几行】的订单 —— 而那张单
    -- 与报价的差别没有任何东西会报出来。
    SELECT count(*) INTO v_made FROM sales_order_lines WHERE sales_order_id = v_order;
    IF v_made <> v_n THEN
        RAISE EXCEPTION 'QT_CONVERT_LINES_LOST|%|%', v_n, v_made;
    END IF;

    -- ── 收尾:只写一次的那一列 + 两边各留一行痕 ────────────────────────────
    UPDATE quotes SET status = 'converted', converted_order_id = v_order,
                      updated_by = auth.uid()
     WHERE id = p_quote_id;

    INSERT INTO quote_history (quote_id, change_type, detail)
    VALUES (p_quote_id, 'converted', v_ocode);

    -- 【订单那一侧也要留一行】否则从订单看不出它是照哪张报价下的 —— 而那正是
    -- 三个月后有人会问的第一个问题。
    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (v_order, 'converted_from_quote', v_q.code, auth.uid());

    RETURN jsonb_build_object(
        'quote_id', p_quote_id,
        'quote_code', v_q.code,
        'sales_order_id', v_order,
        'sales_order_code', v_ocode,
        'order_date', p_order_date,
        'currency', v_q.currency,
        'fx_rate', v_q.fx_rate,
        'lines', v_n);
END;
$function$;

COMMENT ON FUNCTION public.convert_quote(uuid, date) IS
    'SO-4a:把一张报价变成一张销售订单 —— 【它不重写建单,它调用 create_sales_order】。行、数量、单价、出处两列、币种、汇率全部【原样抄】,一个字不重算:重算等于系统替人重新谈了一次。订单日【不抄】报价日 —— 它是客户接受的那一天,空值由 create_sales_order 按名拒。四条拒绝按"最具体的先说"排:QT_ALREADY_CONVERTED(点名转成了哪张单)、QT_DECLINED、QT_NOT_ISSUED、QT_EXPIRED(边界含当天,消息给出补救:改 valid_until 再签发一版)。收尾写 converted_order_id(只写一次,此后整行冻)并在【两边】各留一行痕。';

-- ═══ 12 · 订单历史的新类型 ═════════════════════════════════════════════════
ALTER TABLE public.sales_order_history
    DROP CONSTRAINT IF EXISTS sales_order_history_change_type_check;
ALTER TABLE public.sales_order_history
    ADD CONSTRAINT sales_order_history_change_type_check CHECK (change_type IN
        ('created','confirmed','closed','cancelled','line_added','line_changed','line_removed','issued',
         'reserved','released','invoiced','invoice_voided','shipped',
         'header_update','line_update','line_add','line_remove','credit_noted',
         -- SO-4a:这张单是照哪一张报价下的。从订单看不出它的出处,正是三个月后
         -- 有人会问的第一个问题。
         'converted_from_quote'));

-- ═══ 13 · 桶 + 它的两条门(同一支迁移里 —— SO-1 那次桶先建门后补,
--          签发当场 500,是手走才发现的)═══════════════════════════════════
INSERT INTO storage.buckets (id, name, public)
VALUES ('qt-documents', 'qt-documents', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read qt-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'qt-documents'::text);

CREATE POLICY "authenticated upload qt-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'qt-documents'::text);

COMMIT;

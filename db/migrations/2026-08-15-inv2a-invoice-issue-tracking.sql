-- INV-2a(2026-08-15):发票的签发档 —— 最后一个没有版本记录的对外单据族
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是发票最后一个补上,而它本该最先】采购单、销售订单、发货单、贷项凭证、
-- 报价单都有签发档(版本、字节、摘要);发票没有 —— 它的 PDF 是【每次现渲染】的
-- GET,没有桶、没有版本、没有摘要,也没有任何一行记着"某年某月某日发出去过一份"。
--
-- 【代价是实测过的,不是设想】INV-1 那次修的是:PDF 拿单据币种的标签去标本位币的
-- 数,已发出的两张发票各多报 1,440 / 336 USD。那两份 PDF 真的到过客户手上,而
-- 今天【没有任何东西说得出当时印的是什么】—— 重渲染只会给出今天的数字。
-- 这一刀不能追回那两份,但它让下一次有据可查。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【只存字节,不存第二份数字 —— 这是一个记录在案的决定】
-- 快照就是桶里那份对象加它的 sha256。理由是调查查出来的:这份 PDF 的每一个输入
-- 本来就冻着 ——
--   * 明细行逐列不可改(guard_invoice_line_mutation);
--   * 表头的编号/日期/币种/汇率/条款逐列不可改(guard_invoice_mutation);
--   * invoice_document_totals 由那些不可改的行派生,而且【不减贷项凭证】;
--   * bill_to_snapshot 本来就是一份快照。
-- 会漂的只有两样:invoices.status(作废会翻出 VOID 水印)与公司抬头(信笺)。
-- 两样都被字节盖住了。再存一份 total_ccy / currency 之类的列,就是同一个事实的
-- 【第三份】拷贝 —— 这个仓库为"同一个数两份实现"付过四次账。
-- 【代价说清楚】"v1 当时的合计是多少"这个问题,答案要打开那份 PDF 才看得到,
-- 查不了 SQL。若哪天真的要查,那时再加列,而且要明写它是【印出去的记录】,
-- 不是一处可以拿来算余额的推导。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【两道门,而且【刻意】是两道,谁都不是顺带继承来的】
--   record_invoice_issue  要 module.finance.edit —— 它是"把这一版记进档案"这个动作。
--   PDF 渲染那条路      要 data.view_banking  —— 那份文件上印着公司收款账号,
--                        而一张银行区块空着的发票【客户付不了款,经手人还看不出来】
--                        (那条判断与它的理由早就写在 pdf/route.ts 里,本刀一字未动)。
-- 签发这件事同时是两者:记一笔档案,并产生一份带银行信息的文件。所以两道门都在,
-- 而且是【合取】—— 把它写在这里,是因为"继承来的门"是最容易在下一次重构里被
-- 顺手拆掉的那种门。
-- 【线上今天分辨不出这个合取】:持 finance.edit 的三个角色(admin/finance/gm)
-- 同时都持 view_banking,而 auditor 两个都没有。也就是说合取此刻没有可观察的后果。
-- 【残留的口子,照直说】将来若真配出一个"有 finance.edit、没有 view_banking"的
-- 角色,他渲染不出 PDF,却仍然能调 record_invoice_issue 记一行(路径与摘要由调用方
-- 递入)。这与其余四个族的处境完全一样(record_so_issue 等同样信任调用方递来的
-- 路径与摘要,真正的产出口只有那条路由),所以这里不另加第三道门 —— 但它是一句
-- 需要有人知道的话,而不是一个可以不说的细节。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀之前签发过多少次,永远查不出来了 —— 而这是"拒绝补录"那一族】
-- 没有桶、没有摘要、没有生成日志,连一个时间戳都没有:【没有任何东西可以拿来补】。
-- 今天重渲染一份补进去,得到的是【今天的数字与今天的信笺】—— 那是一份伪造的
-- 出处记录,而伪造的出处比空白更坏(FIN-26 那条,原话是"编一条比留空坏得多")。
-- 所以记录【从这一刀开始】,之前的空白就是空白。这句话写在 invoice_issues 的
-- 表注释里 —— 那是有人问"这张发票什么时候发出去的"时会撞见的地方。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 签发档(so_issues 的第六份,一个字没改)═════════════════════════════
CREATE TABLE public.invoice_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id uuid NOT NULL REFERENCES public.invoices (id),
    version    integer NOT NULL CHECK (version >= 1),
    file_path  text NOT NULL,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (invoice_id, version)
);

COMMENT ON TABLE public.invoice_issues IS
    'INV-2a:发票的签发档,形状逐字取自 so_issues / po_issues / shipment_issues / cn_issues / qt_issues(这是第六份)。谁、何时、第几版、哪个对象、字节摘要。【快照就是那份字节】—— 不另存一份金额:这份 PDF 的每一个输入本来就冻着(行与表头逐列不可改、totals 由不可改的行派生且不减贷项凭证、bill_to 本来就是快照),会漂的只有 status 的 VOID 水印与公司信笺,而两样都被字节盖住了;再存一份数字就是同一个事实的第三份拷贝。代价:"v1 当时合计多少"要打开那份 PDF 才看得到。【本刀之前签发过多少次,永远查不出来】:没有桶、没有摘要、没有日志,没有任何东西可以拿来补;重渲染一份补进去得到的是今天的数字与今天的信笺,那是伪造的出处,而伪造的出处比空白更坏。记录从这一刀开始。【没有"已发送"标志】—— 系统不知道对方收没收到。';

CREATE INDEX idx_invoice_issues_invoice ON public.invoice_issues (invoice_id, version DESC);

CREATE OR REPLACE FUNCTION public.guard_invoice_issue_append_only()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【自己报名,不靠外键顺带挡】(FIN-31)—— 一句约束名既没说是哪张单据,
    -- 也没说下一步该做什么。客户手里那一份是某个具体版本:改它或删它,
    -- 就是把"当时发出去的是什么"这个问题变成没有答案。
    RAISE EXCEPTION 'INVOICE_ISSUE_IMMUTABLE|%', TG_OP;
END;
$function$;

CREATE TRIGGER trg_invoice_issues_append_only
    BEFORE UPDATE OR DELETE ON public.invoice_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_invoice_issue_append_only();

ALTER TABLE public.invoice_issues ENABLE ROW LEVEL SECURITY;

-- 【读:module.finance.view】auditor 因此读得到每一版的版本号、时刻与摘要,
-- 也取得回那份字节 —— 而他【签发不了】(那要 finance.edit)。审计要看的正是
-- "发出去的是什么",所以读这一侧不该比看发票本身更严。
CREATE POLICY "invoice_issues select by permission" ON public.invoice_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 record_invoice_issue(属主权限)——
-- 与 approval_log / so_issues / cn_issues 同一条:档案不该有第二个写法。
-- 留着侧门,任何持 finance.edit 的人都能插一行指着不存在对象的"签发记录",
-- 而签发档正是"不可伪造"才有意义的东西。

-- ═══ 2 · 唯一写入口 ════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.record_invoice_issue(p_invoice_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv   invoices%ROWTYPE;
    v_name  text;
    v_lines integer;
    v_next  integer;
BEGIN
    -- 【第一道门:记档案这个动作】另一道(data.view_banking)在渲染那条路上 ——
    -- 见本刀迁移抬头:两道门是【合取】,而且都不是顺带继承来的。
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;

    -- 【作废了的发票不再签发,但既有的版本仍然读得到、取得回】
    -- 作废不删任何东西(status/void_reason/voided_at/voided_by 留在行上,明细行
    -- 由 trg_invoices_propagate_void 打上标记但一行不少)。所以"已经发出去过的
    -- 那几版"仍然是真实发生过的事;被拒的只是【再发一版】——
    -- 那两个状态的意思是"这张单据结束了"(与 record_qt_issue 拒 declined/converted
    -- 同一条)。作废后的 PDF 仍然打得开,而且会印上 VOID 水印,那正是它的用途:
    -- 让手里拿着旧件的人认得出来。
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INV_VOIDED_NOT_ISSUABLE|%|%', v_inv.code, v_inv.status;
    END IF;

    -- 【没有行的发票不给签发】那是一张白纸,而客户要照着上面的数付款。
    -- 渲染那条路也拦得住(它拿不到 totals 就 409),但那道拦截报的是
    -- "金额取不到",既可能是没有行、也可能是没有权限 —— 两件事该分开说。
    SELECT count(*) INTO v_lines FROM invoice_lines WHERE invoice_id = p_invoice_id;
    IF v_lines = 0 THEN
        RAISE EXCEPTION 'INV_NO_LINES|%', v_inv.code;
    END IF;

    -- 【公司抬头没填就不给签发】一张没有公司名的发票寄出去是真实事故,而这条
    -- 判断在渲染那条路上已经有了(它 409 并指去 /finance/company)。这里【也】
    -- 有一份,不是重复:那一份挡的是"渲染出一份残缺的 PDF",这一份挡的是
    -- "把一份残缺的东西记进档案"。档案说"某年某月发出去过第 1 版",而那一版
    -- 没有抬头 —— 记录本身就成了一句假话。
    SELECT btrim(COALESCE(legal_name, '')) INTO v_name FROM company_profile LIMIT 1;
    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'INV_PROFILE_INCOMPLETE';
    END IF;

    -- 【版本由数据库裁决】对象键不含版本号,并发安全靠这把每单据一把的咨询锁
    -- (与其余五个族逐字同一套)。
    PERFORM pg_advisory_xact_lock(hashtext('invoice_issue_' || p_invoice_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next
      FROM invoice_issues WHERE invoice_id = p_invoice_id;

    INSERT INTO invoice_issues (invoice_id, version, file_path, sha256, issued_by)
    VALUES (p_invoice_id, v_next, p_file_path, p_sha256, auth.uid());

    -- 【两种 kind 走同一个函数,而这不是偷懒】sale 与 order 的区别在【它们怎么
    -- 产生应收】(一个什么都不过账、一个开票即过账),而"这一版发出去了"这件事
    -- 与那个区别毫无关系:客户手里拿到的都是一张纸。分成两个函数会让同一件事
    -- 有两处实现,而它们迟早各说各话。
    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'kind', v_inv.kind,
        'version', v_next);
END;
$function$;

COMMENT ON FUNCTION public.record_invoice_issue(uuid, text, text) IS
    'INV-2a:把发票的这一版记进签发档 —— 唯一写入口(invoice_issues 没有 INSERT 策略)。三条按名拒:INV_VOIDED_NOT_ISSUABLE(作废了的单据不再发新版,但既有版本仍读得到、取得回,而且那份 PDF 会印 VOID 水印)、INV_NO_LINES(白纸)、INV_PROFILE_INCOMPLETE(没有公司抬头的发票寄出去是真实事故;渲染那条路也拦,但那一份挡的是"渲染出残缺的 PDF",这一份挡的是"把残缺的东西记进档案")。【两道门是合取】:本函数要 module.finance.edit,渲染那条路要 data.view_banking —— 签发同时是"记一笔档案"与"产生一份带银行信息的文件"。sale 与 order 两种 kind 走同一个函数:它们的区别在怎么产生应收,而"这一版发出去了"与那个区别无关。';

-- ═══ 3 · 桶 + 它的两条门(【同一支迁移里】—— SO-1 那次桶先建门后补,
--          签发当场 500,是手走才发现的;此后不再重演)══════════════════════
INSERT INTO storage.buckets (id, name, public)
VALUES ('invoice-documents', 'invoice-documents', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read invoice-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'invoice-documents'::text);

CREATE POLICY "authenticated upload invoice-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'invoice-documents'::text);

COMMIT;

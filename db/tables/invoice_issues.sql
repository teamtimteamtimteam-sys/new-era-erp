-- db/tables/invoice_issues.sql
-- INV-2a:发票的签发档,so_issues 的第六份 —— 一个字没改。
--
-- NOTE: introduced by db/migrations/2026-08-15-inv2a-invoice-issue-tracking.sql.
-- First-run script (plain CREATEs).
--
-- 【本刀之前签发过多少次,永远查不出来了】没有桶、没有摘要、没有生成日志,
-- 连一个时间戳都没有 —— 没有任何东西可以拿来补。今天重渲染一份补进去,得到的是
-- 今天的数字与今天的信笺,那是一份伪造的出处记录,而伪造的出处比空白更坏
-- (FIN-26)。所以记录【从这一刀开始】,之前的空白就是空白。

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

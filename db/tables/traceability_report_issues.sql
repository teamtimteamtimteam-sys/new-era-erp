-- db/tables/traceability_report_issues.sql
-- AUD-1:客户审计报告(可追溯报告)的签发档,so_issues 的第七份 —— 一个字没改。
--
-- 【与另外六份唯一的不同:它有 code】另外六个族的号在【单据本身】上
-- (发票有 code、发货单有 code),而可追溯报告没有一张"单据"—— 它是围着一个
-- 产出批临时组装出来的。所以报告号住在这里。
-- **code 属于"这个批次的报告",不属于每一版**:第 1 版铸号,重发沿用同一个号。
-- 客户引用的是那个号;重发一版而让他手里的引用失效,是把一份已经寄出去的
-- 文件变成查无此物。
--
-- NOTE: introduced by db/migrations/2026-08-17-aud1-traceability-report.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.traceability_report_issues (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    output_batch_id uuid NOT NULL REFERENCES public.output_batches (id),
    code            text NOT NULL,
    version         integer NOT NULL CHECK (version >= 1),
    file_path       text NOT NULL,
    sha256          text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at       timestamptz NOT NULL DEFAULT now(),
    issued_by       uuid,
    UNIQUE (output_batch_id, version),
    UNIQUE (code, version)
);

COMMENT ON TABLE public.traceability_report_issues IS
    'AUD-1:客户审计报告(可追溯报告)的签发档,形状逐字取自 so_issues / po_issues / shipment_issues / cn_issues / qt_issues / invoice_issues(这是第七份)。谁、何时、第几版、哪个产出批、字节摘要。【快照就是那份字节】—— 不另存一份推导结果:报告的每一个输入(血缘、回收率、含量出处)都可能随后续录入而变,而客户手里那一份必须停在发出去的那一刻。code = TRC-YYYY-NNNN,属于【这个批次的报告】而不是每一版:第 1 版铸号,重发沿用,客户的引用因此不会失效。【没有"已发送"标志】—— 系统不知道对方收没收到。';

CREATE INDEX idx_traceability_report_issues_batch
    ON public.traceability_report_issues (output_batch_id, version DESC);

CREATE TRIGGER trg_traceability_report_issues_append_only
    BEFORE UPDATE OR DELETE ON public.traceability_report_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_traceability_report_issue_append_only();

ALTER TABLE public.traceability_report_issues ENABLE ROW LEVEL SECURITY;

-- 【读:与报告本身同一道门(OR)】能看这份报告的人就能看它发过几版 ——
-- 审计要看的正是"发出去的是什么"。OR 而不是 AND 的理由(实测的角色矩阵)
-- 写在那支迁移的抬头:AND 会把销售与运营两头都挡在外面。
CREATE POLICY "traceability_report_issues select by permission"
    ON public.traceability_report_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.sales.view', 'module.processing.view']));
-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 record_traceability_report_issue
-- (属主权限)—— 与 approval_log / 另外六个族同一条:档案不该有第二个写法。

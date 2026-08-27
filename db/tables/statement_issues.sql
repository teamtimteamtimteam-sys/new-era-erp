-- db/tables/statement_issues.sql
-- STATEMENT-1:对账单的签发档 —— 签发机制的第八个成员,形状逐字取自 cn_issues。
--
-- NOTE: introduced by db/migrations/2026-08-27-statement1-customer-statements-of-account.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.statement_issues (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id uuid NOT NULL REFERENCES public.customer_statements (id),
    version      integer NOT NULL CHECK (version >= 1),
    file_path    text NOT NULL,
    sha256       text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at    timestamptz NOT NULL DEFAULT now(),
    issued_by    uuid,
    UNIQUE (statement_id, version)
);

COMMENT ON TABLE public.statement_issues IS
    'STATEMENT-1:对账单的签发档 —— 签发机制的【第八个】成员,形状逐字取自 cn_issues / so_issues / po_issues(一个字没改)。谁、何时、第几版、哪一份对账单、字节摘要。【没有"已发送"标志】—— 系统不知道对方收没收到,而一个永远为 false 的标志会被读成"没发出去"。唯一写入口 record_statement_issue();重新渲染 = 新的一版,绝不覆盖旧行。【注意它与 customer_statements 分两层】这一层版本化的是【同一份对账单的 PDF】;数字变了要出的是【另一份对账单】(新的 customer_statements 行),不是这里的 v2。';

CREATE INDEX idx_statement_issues_statement
    ON public.statement_issues (statement_id, version DESC);

CREATE TRIGGER trg_statement_issues_append_only
    BEFORE UPDATE OR DELETE ON public.statement_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

ALTER TABLE public.statement_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "statement_issues select by permission" ON public.statement_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

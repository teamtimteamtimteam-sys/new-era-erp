-- db/tables/supplier_statement_issues.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q9):供应商对账单的签发档 —— statement_issues 的形状(一份对账单可以渲染好几版,每一版一行),
--   而记录它的那支函数照分析证书那一份写(F17 的三条从第一天起就在):哈希一律小写存;路径必须在 <对账单 id>/ 之下;同一份对账单上
--   同一串字节【只记一次】(SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED)。字节在私有桶 supplier-statement-documents;取档时重算
--   sha256,对不上就拒(409)。只追加(trg_supplier_statement_issues_append_only),唯一写入口 record_supplier_statement_issue()。
--   【没有"已发送"标志】—— 系统不知道供应商收没收到(statement_issues 的同一条)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.supplier_statement_issues (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    statement_id uuid NOT NULL REFERENCES public.supplier_statements (id),
    version      integer NOT NULL CHECK (version >= 1),
    file_path    text NOT NULL,
    sha256       text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at    timestamptz NOT NULL DEFAULT now(),
    issued_by    uuid,
    UNIQUE (statement_id, version),
    UNIQUE (statement_id, sha256)
);

COMMENT ON TABLE public.supplier_statement_issues IS
    'MES-8a:供应商对账单的签发档(*_issues 族,形状取自 statement_issues)。谁、何时、第几版、哪一份对账单、字节摘要。哈希小写;路径在 <对账单 id>/ 之下;同一份对账单同一串字节只记一次。字节在私有桶 supplier-statement-documents,取档重算 sha256、对不上 409。只追加;唯一写入口 record_supplier_statement_issue()。数字变了要出的是【另一份对账单】(新的 supplier_statements 行),不是这里的下一版。';

CREATE INDEX idx_supplier_statement_issues_statement
    ON public.supplier_statement_issues (statement_id, version DESC);

CREATE TRIGGER trg_supplier_statement_issues_append_only
    BEFORE UPDATE OR DELETE ON public.supplier_statement_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_supplier_statement_issue_write();

ALTER TABLE public.supplier_statement_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "supplier_statement_issues select by permission" ON public.supplier_statement_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
GRANT SELECT ON public.supplier_statement_issues TO authenticated;
REVOKE ALL ON public.supplier_statement_issues FROM anon;

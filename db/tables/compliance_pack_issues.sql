-- db/tables/compliance_pack_issues.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q16,Tim):合规包的签发档 —— supplier_statement_issues 的形状(一份包可以渲染好几版,每一版一行),
--   记录它的那支函数照分析证书那一份写:哈希一律小写存;路径必须在 <包 id>/ 之下;同一份包上同一串字节【只记一次】
--   (COMPLIANCE_PACK_BYTES_ALREADY_RECORDED)。字节在私有桶 compliance-documents;取档时重算 sha256,对不上就拒(409)。
--   只追加(trg_compliance_pack_issues_append_only),唯一写入口 record_compliance_pack_issue()。
--   【没有"已寄出"标志】—— 系统不知道 NEA 或买家收没收到。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.compliance_pack_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id    uuid NOT NULL REFERENCES public.compliance_packs (id),
    version    integer NOT NULL CHECK (version >= 1),
    file_path  text NOT NULL,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (pack_id, version),
    UNIQUE (pack_id, sha256)
);

COMMENT ON TABLE public.compliance_pack_issues IS
    'MES-8b-1:合规包的签发档(*_issues 族)。谁、何时、第几版、哪一份包、字节摘要。哈希小写;路径在 <包 id>/ 之下;同一份包同一串字节只记一次。字节在私有桶 compliance-documents,取档重算 sha256、对不上 409。只追加;唯一写入口 record_compliance_pack_issue()。数字变了要出的是【另一份包】(CPK-…-2),不是这里的下一版。';

CREATE INDEX idx_compliance_pack_issues_pack
    ON public.compliance_pack_issues (pack_id, version DESC);

CREATE TRIGGER trg_compliance_pack_issues_append_only
    BEFORE UPDATE OR DELETE ON public.compliance_pack_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_compliance_pack_issue_write();

ALTER TABLE public.compliance_pack_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "compliance_pack_issues select by permission" ON public.compliance_pack_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.compliance.view'::text));
GRANT SELECT ON public.compliance_pack_issues TO authenticated;
REVOKE ALL ON public.compliance_pack_issues FROM anon;

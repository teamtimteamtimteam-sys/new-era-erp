-- db/tables/coa_issues.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q31,Tim):分析证书的字节档案 —— *_issues 那一族的第十份,形状取自 cod_issues。
--   * 【没有 version】数据变了就作废旧的、发一张新号的,所以永远没有第二版(与 cod_issues 同一条);
--   * 只追加(改、删、清空一律语句级拒 APPEND_ONLY),唯一写入口是 record_coa_issue();
--   * 作废【不动本表】—— 买方手里那份仍然对得上哈希;
--   * 字节在私有桶 coa-documents,键 <证书 id>/<随机 id>.pdf(record_coa_issue 核对前缀);GET ?coa= 流出存下的字节并重算 sha256,
--     对不上就 409。
--   * 读跟着证书(module.output.view)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.coa_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    coa_id     uuid NOT NULL REFERENCES public.certificates_of_analysis (id),
    file_path  text NOT NULL UNIQUE,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (coa_id)
);

COMMENT ON TABLE public.coa_issues IS
    'MES-6b-2:分析证书的字节档案(*_issues 族的第十份,形状取自 cod_issues)。一张证书一份字节,【没有 version】;只追加;作废不动它。字节在私有桶 coa-documents(键 <证书 id>/<随机 id>.pdf),sha256 在这里 —— 取签发档时重算,对不上就拒(409)。';

ALTER TABLE public.coa_issues ENABLE ROW LEVEL SECURITY;
CREATE POLICY "coa_issues select by permission" ON public.coa_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));
-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 record_coa_issue()。
GRANT SELECT ON public.coa_issues TO authenticated;
REVOKE ALL ON public.coa_issues FROM anon;

-- 只追加:改、删、清空一律语句级拒 APPEND_ONLY|<表>|<操作>(没有写策略时行级触发器在 RLS 那里醒不过来 —— guard_append_only_log 的理由)
CREATE TRIGGER trg_coa_issues_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.coa_issues
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

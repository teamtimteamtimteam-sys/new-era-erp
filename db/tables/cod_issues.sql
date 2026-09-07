-- db/tables/cod_issues.sql
-- COD-1:销毁证书的字节档案,so_issues 那一族的第九份。
--   * 【与另外八份唯一的不同:没有 version】重发的定义在本族不同 —— 数据变了就
--     作废旧的、发一张新号的,所以永远没有第二版;
--   * append-only(trg_cod_issues_append_only),唯一写入口是 record_cod_issue();
--   * 作废【不动本表】—— 供应商手里那份仍然查得到、仍然对得上哈希。
--
-- NOTE: introduced by db/migrations/2026-09-07-cod1-certificate-of-destruction.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.cod_issues (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cod_id     uuid NOT NULL REFERENCES public.certificates_of_destruction (id),
    file_path  text NOT NULL,
    sha256     text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at  timestamptz NOT NULL DEFAULT now(),
    issued_by  uuid,
    UNIQUE (cod_id)
);

COMMENT ON TABLE public.cod_issues IS
    'COD-1:销毁证书的字节档案,形状取自 so_issues / po_issues / shipment_issues / cn_issues / qt_issues / invoice_issues / statement_issues / traceability_report_issues(这是第九份)。【没有 version】—— 重发的定义在本族不同:数据变了就作废旧的、发一张新号的,所以永远没有第二版。【作废【不动】本表一个字】—— 供应商手里那份仍然查得到、仍然对得上哈希,这正是 append-only 的意义。';

-- 守卫函数见 db/functions/guard_cod_issue_append_only.sql。
CREATE TRIGGER trg_cod_issues_append_only
    BEFORE UPDATE OR DELETE ON public.cod_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_cod_issue_append_only();

ALTER TABLE public.cod_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "cod_issues select by permission"
    ON public.cod_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('action.issue_cod'::text));
-- 【没有 INSERT 策略,这是刻意的】唯一写入口是 record_cod_issue()。

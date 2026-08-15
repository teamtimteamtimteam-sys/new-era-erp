-- db/tables/cn_issues.sql
-- CN-1:贷项凭证的签发档,形状逐字取自 so_issues(第四份,一个字没改)。
--
-- NOTE: introduced by db/migrations/2026-08-15-cn1-credit-note.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.cn_issues (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    credit_note_id uuid NOT NULL REFERENCES public.credit_notes (id),
    version        integer NOT NULL CHECK (version >= 1),
    file_path      text NOT NULL,
    sha256         text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at      timestamptz NOT NULL DEFAULT now(),
    issued_by      uuid,
    UNIQUE (credit_note_id, version)
);

COMMENT ON TABLE public.cn_issues IS
    'CN-1:贷项凭证的签发档,形状逐字取自 so_issues / po_issues / shipment_issues(这是第四份,一个字没改)。谁、何时、第几版、哪个对象、字节摘要。【没有"已发送"标志】—— 系统不知道对方收没收到,而一个永远为 false 的标志会被读成"没发出去"。唯一写入口 record_cn_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 客户手里那份是某个具体版本。';

CREATE INDEX idx_cn_issues_note ON public.cn_issues (credit_note_id, version DESC);

CREATE TRIGGER trg_cn_issues_append_only
    BEFORE UPDATE OR DELETE ON public.cn_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

ALTER TABLE public.cn_issues ENABLE ROW LEVEL SECURITY;

-- 签发档【没有 INSERT 策略】:唯一写入口是 record_cn_issue(属主权限)——
-- 与 so_issues / po_issues / approval_log 同一条:档案不该有第二个写法。
CREATE POLICY "cn_issues select by permission" ON public.cn_issues
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));

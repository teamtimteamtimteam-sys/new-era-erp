-- db/tables/portal_certificate_submissions.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §5 · Q19 · Q25 / V39,Tim):【门户交上来的证书】—— 一位门户账号为它自己那一家传上来的一份合规证书或资质文件,
--   等员工审核。一行一份:谁(链接 · 账号 · 供应商)、什么(证书类型 · 号 · 有效期 · 文件名 · 类型 · 大小 · 桶里的路径)、到了哪一步。
--
-- 【一份上传只是一份等审核的申请】(委托书):它不建 supplier_compliance 行、不动库存、价钱或总账 —— 什么都不改,只多这一行与桶里一份字节。
-- 【状态】uploading(登记了,字节还没到)→ submitted(字节到了,等审核)| abandoned(字节没到 —— 传失败了,路由收回)
--        submitted → accepted(员工接受:同一笔事务里建 supplier_compliance 行、把文件抄进 supplier-attachments 的那一行挂上)
--                  | rejected(员工驳回:理由必填,供应商在门户里看得见)。没有审批链(Q19)。
-- 【谁写】只经函数:门户那一侧 portal_submission_begin / _finish / _abandon(只授 supplier_portal,先过 portal_require_link,
--   供应商只从链接推出来);员工那一侧 portal_submission_accept / _reject(module.suppliers.edit,Q19)。没有任何写策略,
--   authenticated 与 anon 连写的授权都没有。
-- 【V39】portal_submission_begin 在【任何一个字节存下之前】对着 account_settings 的上限按名拒(PORTAL_UPLOAD_TOO_LARGE /
--   PORTAL_UPLOAD_TYPE_NOT_ACCEPTED);桶 portal-uploads 自己再拦一道(10 MB · PDF / JPEG / PNG)。
-- 【谁读】员工:module.suppliers.view(供应商页上审核那一块)。门户会话自己不直接读 —— 经 portal_certificates()。
-- 【变更记录】记(不是豁免:豁免仍是 9 张);审计记录里它挂在供应商那一条下(trail_subject_members),
--   门户账号做的那几步读作「Supplier portal — <供应商名>」(trail_actor)。没有遮蔽的列。
--
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.portal_certificate_submissions (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    portal_user_id   uuid NOT NULL REFERENCES public.supplier_portal_users (id) ON DELETE RESTRICT,
    user_id          uuid NOT NULL,
    supplier_id      uuid NOT NULL REFERENCES public.suppliers (id) ON DELETE RESTRICT,
    cert_type_code   text NOT NULL REFERENCES public.certificate_types (code),
    cert_no          text CHECK (cert_no IS NULL OR length(cert_no) <= 120),
    valid_from       date,
    valid_until      date,
    file_name        text NOT NULL CHECK (length(file_name) BETWEEN 1 AND 200),
    file_type        text NOT NULL,
    file_size        bigint NOT NULL CHECK (file_size > 0),
    bucket_id        text NOT NULL DEFAULT 'portal-uploads' CHECK (bucket_id = 'portal-uploads'),
    storage_path     text NOT NULL UNIQUE,
    status           text NOT NULL DEFAULT 'uploading'
                     CHECK (status IN ('uploading', 'submitted', 'abandoned', 'accepted', 'rejected')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    submitted_at     timestamptz,
    decided_at       timestamptz,
    decided_by       uuid,
    reject_reason    text,
    compliance_id    uuid REFERENCES public.supplier_compliance (id),
    attachment_id    uuid REFERENCES public.supplier_attachments (id),
    CONSTRAINT portal_certificate_submissions_dates CHECK (valid_from IS NULL OR valid_until IS NULL OR valid_until >= valid_from),
    CONSTRAINT portal_certificate_submissions_submitted CHECK ((status IN ('uploading', 'abandoned')) = (submitted_at IS NULL)),
    CONSTRAINT portal_certificate_submissions_decided CHECK ((status IN ('accepted', 'rejected')) = (decided_at IS NOT NULL AND decided_by IS NOT NULL)),
    CONSTRAINT portal_certificate_submissions_reason CHECK ((status = 'rejected') = (reject_reason IS NOT NULL AND btrim(reject_reason) <> '')),
    CONSTRAINT portal_certificate_submissions_accepted CHECK ((status = 'accepted') = (compliance_id IS NOT NULL AND attachment_id IS NOT NULL))
);

CREATE INDEX idx_portal_certificate_submissions_supplier ON public.portal_certificate_submissions (supplier_id, created_at DESC);
CREATE INDEX idx_portal_certificate_submissions_link ON public.portal_certificate_submissions (portal_user_id, created_at DESC);

COMMENT ON TABLE public.portal_certificate_submissions IS
    'MES-9c:门户交上来的证书(一份一行),等员工审核。uploading → submitted | abandoned;submitted → accepted(建 supplier_compliance 行、文件抄进 supplier-attachments)| rejected(理由必填,供应商看得见)。只经函数写;员工读 module.suppliers.view。一份上传什么别的都不改。';

ALTER TABLE public.portal_certificate_submissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "portal_certificate_submissions select by permission" ON public.portal_certificate_submissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
REVOKE ALL ON public.portal_certificate_submissions FROM authenticated, anon;
GRANT SELECT ON public.portal_certificate_submissions TO authenticated;

-- db/migrations/2026-10-20-mes9c-certificate-uploads.sql
-- MES-9c —— 供应商门户交证书与员工审核,连同变更记录页的超时修法(F19)。一位门户账号现在能为它自己那一家传一份合规证书或资质文件
--   (PDF、JPEG 或 PNG,每份至多 10 MB —— V39),它等员工接受或驳回(驳回的理由供应商看得见);在员工接受之前,供应商传上来的东西什么都不改。
--   变更记录页在一次几百行的批量操作之后也打得开了。(MES 组的第二十五刀、最后一刀,v1.4.62;发布那一行在 docs/handbacks/MES-9c.md 的抬头。)
--   由 db/scripts/build_mes9c_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-20 委托书:V39 = 10 MB · PDF / JPEG / PNG;MES-9 Step 0 §5 · Q19 · Q25 照推荐;F19)
--   ① account_settings 加两列 V39(portal_upload_max_bytes · portal_upload_types),以 Tim 定的值作默认 —— ADD COLUMN … DEFAULT 让线上那一行
--      当场得到它,不经一次 UPDATE(于是本事务一行变更记录都不写);待补的值 pending_values 加一支 V39(设着时 0 行)。
--   ② 一张新表 portal_certificate_submissions(门户交上来的证书;只经函数写;员工 module.suppliers.view 读;被变更记录记 —— 豁免仍是 9)。
--   ③ 五支门户函数,只授 supplier_portal:portal_certificates · portal_submission_begin(先按 V39 拒,任何字节存下之前)· _finish · _abandon ·
--      portal_can_upload_object(两条存储策略的判据);两支员工函数 portal_submission_accept · _reject(module.suppliers.edit,Q19)。
--   ④ 存储:一个新桶 portal-uploads(10 MB · PDF / JPEG / PNG)、门户角色得到 storage.objects 的 INSERT、三条策略(门户传 / 读回它自己一行
--      uploading 申请登记的那一条路径;员工 module.suppliers.view 读)。没有删除、没有改的策略。存储策略 53 → 56,桶 19 → 20。
--   ⑤ 审计记录:申请表挂在供应商主语下(trail_subject_members 换成多一行的那一份)。
--   ⑥ F19:change_log_rows 多两个参数(p_row_before · p_row_limit)—— 同一组事务里的行按 seq 分页取,一次调用的行数有上界;不给它们 = 原样。
--      签名变了,所以先 DROP 旧签名(函数权限由 apply_migration.sh 随后整份重放 zzz_function_grants.sql 恢复)。
--   门户角色够得着的每一样新东西都按名进了 db/portal-grants-baseline.tsv(判词八):五支函数 · storage.objects 的 INSERT · 两条策略。
--
-- 【不做什么】不碰 hook、登录、刷新、空闲登出与大屏的豁免;不建任何门户账号;不建、不停、不改七个账号中的任何一个;不碰审批开关;
--   不改任何既有的行;不改任何既有的存储对象、桶或别的策略;授权表一行不动;不回填;require_calibrated_since 保持空。
--
-- 【破窗】这一窗什么都不坏:旧应用不读任何新东西;线上没有门户账号;旧的变更记录页不传那两个新参数,读到的与之前逐行相同。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变,hook 对它们每一个仍逐字节原样返回;没有任何门户
--   账号;supplier_portal 能执行的 public 函数恰好十一支、能读的关系恰好 storage.objects、能写的只有 storage.objects 的 INSERT;作用于它的存储策略
--   恰好三条;存储策略 56 条、既有 53 条逐字未变;桶 20 个、既有 19 个逐字未变;存储对象一个字节不动(两张 COD 在内);V39 是 Tim 的值;
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;既有的行逐字未变;本事务一行变更记录都没写;变更记录覆盖零缺口、豁免 9;
--   325 张表;没有一张视图对 anon / authenticated 带写授权。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES9C_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.portal_certificate_submissions') IS NOT NULL OR to_regprocedure('public.portal_certificates()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'portal-uploads')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_settings' AND column_name = 'portal_upload_max_bytes') THEN
        RAISE EXCEPTION 'MES9C_PRE|MES-9c objects already exist';
    END IF;
    IF to_regprocedure('public.portal_document_open(text,uuid)') IS NULL
       OR to_regprocedure('public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[])') IS NULL THEN
        RAISE EXCEPTION 'MES9C_PRE|MES-9b and the twelve-argument change_log_rows are expected on live';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected the 7 real accounts';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN
        RAISE EXCEPTION 'MES9C_PRE|no portal account is expected on live';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 324 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected 324 public tables';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 53 OR (SELECT count(*) FROM storage.buckets) <> 19 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected 53 storage policies and 19 buckets';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected 9 change-log exclusions';
    END IF;
    IF has_table_privilege('supplier_portal', 'storage.objects', 'INSERT') THEN
        RAISE EXCEPTION 'MES9C_PRE|supplier_portal already inserts into storage.objects';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9C_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes9c_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE mes9c_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes9c_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes9c_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE mes9c_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE mes9c_buckets_before ON COMMIT DROP AS
SELECT id, name, public, file_size_limit, allowed_mime_types::text AS mimes FROM storage.buckets;
CREATE TEMP TABLE mes9c_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM counterparty_contacts t ) AS counterparty_contacts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_portal_users t ) AS supplier_portal_users,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'portal_upload_max_bytes' - 'portal_upload_types')::text, '|' ORDER BY (to_jsonb(t) - 'portal_upload_max_bytes' - 'portal_upload_types')::text), '')) FROM account_settings t ) AS account_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_compliance t ) AS supplier_compliance,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_attachments t ) AS supplier_attachments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificate_types t ) AS certificate_types,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) AS purchase_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM po_issues t ) AS po_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) AS certificates_of_destruction,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) AS supplier_statements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statement_issues t ) AS supplier_statement_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM portal_document_downloads t ) AS portal_document_downloads,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM floor_board_settings t ) AS floor_board_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) AS document_types;

-- ── 1 · V39(Tim 2026-10-20):account_settings 加两列,Tim 的值作默认 —— ADD COLUMN … DEFAULT 填上线上那一行,不经 UPDATE ──
ALTER TABLE public.account_settings ADD COLUMN portal_upload_max_bytes     bigint DEFAULT 10485760 CHECK (portal_upload_max_bytes IS NULL OR portal_upload_max_bytes > 0);
ALTER TABLE public.account_settings ADD COLUMN portal_upload_types         text[] DEFAULT ARRAY['application/pdf'::text, 'image/jpeg'::text, 'image/png'::text] CHECK (portal_upload_types IS NULL OR cardinality(portal_upload_types) > 0);
COMMENT ON TABLE public.account_settings IS
    'MES-9a:账号那一侧的待补的值(单行)。V38 = initial_password_valid_days(初始密码在第一次登录之前有效几天);V40 = password_min_length(项目的密码最短长度,Supabase 设置 —— 这里记 Tim 定的数)。引导为空;今天两者都不被执行(known issues MES9A-V38-NOT-ENFORCED · MES9A-V40-IS-A-RECORD)。action.manage_permissions 经 set_account_setting 改。MES-9c:V39 = portal_upload_max_bytes · portal_upload_types(门户上传的上限,Tim 2026-10-20 定 10 MB · PDF / JPEG / PNG,作默认值;portal_submission_begin 执行)。';

-- ── 2 · 新表(镜像原样):门户交上来的证书 ──

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

-- 变更记录的两条触发器(与 db/views/zzz_change_log_triggers.sql 同一串字)
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.portal_certificate_submissions
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.portal_certificate_submissions
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 3 · 新函数(镜像原样):五支门户函数 · 两支员工审核函数 ──

-- db/functions/portal_certificates.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §4 · §5 · Q19 · V39,Tim):【门户的证书一页】—— 调用者自己那一家的在册证书,与它自己交上来的每一份及其状态。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话);供应商只从链接推出来,没有任何参数。
--   回:
--     compliance  它那一家在册的合规证书(supplier_compliance,没删的):类型 · 号 · 有效期至(§4 —— 不回备注、发证机构、谁录的)
--     submissions 它【自己这个账号】交上来的每一份(uploading 与 abandoned 不列 —— 那是传到一半与没传成的,没有东西可等):
--                 类型 · 号 · 有效期 · 文件名 · 交上来的时刻 · 状态(waiting / accepted / rejected)· 驳回理由(Q19:供应商看得见)·
--                 决定的时刻。【不回谁决定的】(员工的名字不给门户,§4)
--     types       可以交的证书类型(certificate_types 里启用的:码 · 英文名 · 中文名)—— 门户角色读不到那张表,所以这里给
--     limits      V39:每份最大字节数与收的文件类型(account_settings);任一为空 → set = false,上传会按名拒
--   别家的一个字都不回;一个价钱都没有。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_certificates()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link     uuid := portal_require_link();
    v_supplier uuid;
    v_max      bigint;
    v_types    text[];
BEGIN
    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = v_link;
    SELECT a.portal_upload_max_bytes, a.portal_upload_types INTO v_max, v_types FROM account_settings a WHERE a.id;
    RETURN jsonb_build_object(
        'supplier_code', (SELECT s.code FROM suppliers s WHERE s.id = v_supplier),
        'compliance', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'cert_type_code', c.cert_type_code,
                       'type_name_en', ct.name_en,
                       'type_name_zh', ct.name_zh,
                       'cert_no', c.cert_no,
                       'valid_until', c.valid_until)
                   ORDER BY ct.sort_order, c.valid_until DESC NULLS LAST, c.created_at DESC)
              FROM supplier_compliance c JOIN certificate_types ct ON ct.code = c.cert_type_code
             WHERE c.supplier_id = v_supplier AND c.deleted_at IS NULL), '[]'::jsonb),
        'submissions', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', s.id,
                       'cert_type_code', s.cert_type_code,
                       'type_name_en', ct.name_en,
                       'type_name_zh', ct.name_zh,
                       'cert_no', s.cert_no,
                       'valid_from', s.valid_from,
                       'valid_until', s.valid_until,
                       'file_name', s.file_name,
                       'submitted_at', s.submitted_at,
                       'state', CASE s.status WHEN 'submitted' THEN 'waiting' ELSE s.status END,
                       'reject_reason', CASE WHEN s.status = 'rejected' THEN s.reject_reason END,
                       'decided_at', s.decided_at)
                   ORDER BY s.submitted_at DESC)
              FROM portal_certificate_submissions s JOIN certificate_types ct ON ct.code = s.cert_type_code
             WHERE s.portal_user_id = v_link AND s.status IN ('submitted', 'accepted', 'rejected')), '[]'::jsonb),
        'types', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('code', ct.code, 'name_en', ct.name_en, 'name_zh', ct.name_zh) ORDER BY ct.sort_order, ct.code)
              FROM certificate_types ct WHERE ct.is_active), '[]'::jsonb),
        'limits', jsonb_build_object('set', v_max IS NOT NULL AND v_types IS NOT NULL, 'max_bytes', v_max, 'types', to_jsonb(v_types)));
END;
$function$;

-- db/functions/portal_submission_begin.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §5 · V39,Tim):【门户开始交一份证书】—— 在【任何一个字节存下之前】按 V39 判,过了才登记一行、给出桶里的路径。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话);供应商只从链接推出来 —— 一份证书只能交给调用者自己那一家。
--   依次按名拒(第一条不过就停,什么都不写):
--     V39 没给(account_settings 两列任一为空)            → PORTAL_UPLOAD_LIMITS_NOT_SET
--     文件类型不在 V39 里(路由按文件头认出的类型)        → PORTAL_UPLOAD_TYPE_NOT_ACCEPTED|<类型>
--     大小 ≤ 0 或超过 V39 的上限                          → PORTAL_UPLOAD_TOO_LARGE|<上限字节数>(≤ 0 → PORTAL_UPLOAD_EMPTY)
--     证书类型不认识或已停用                              → PORTAL_CERT_TYPE_UNKNOWN|<码>
--     有效期至早于有效期起                                → PORTAL_CERT_DATES_INVALID
--     文件名空                                            → PORTAL_UPLOAD_NAME_REQUIRED
--   过了:写一行 status = uploading(路径 = <供应商 id>/<这一行的 id>.<扩展名>,扩展名由类型定,不取文件名里的),回 id · 桶 · 路径。
--   字节随后由路由以【这个会话自己的令牌】传进 portal-uploads(存储策略只放行一行 uploading 的、这位账号自己的、十分钟内登记的路径),
--   然后 portal_submission_finish 确认字节到了;没到 → portal_submission_abandon。
--   【什么别的都不写】:没有 supplier_compliance 行,没有库存、价钱、总账的改动(委托书)。
--   证书号与有效期可空(DEFAULT NULL,排在最后)—— 门户表单上这三格可以不填,PostgREST 收到没有这几个键的调用也认得出这支函数。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_submission_begin(p_cert_type text, p_file_name text, p_file_type text, p_file_size bigint, p_cert_no text DEFAULT NULL::text, p_valid_from date DEFAULT NULL::date, p_valid_until date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link     uuid := portal_require_link();
    v_user     uuid;
    v_supplier uuid;
    v_max      bigint;
    v_types    text[];
    v_id       uuid := gen_random_uuid();
    v_ext      text;
    v_path     text;
    v_name     text := left(btrim(regexp_replace(COALESCE(p_file_name, ''), '[\\/[:cntrl:]]+', '_', 'g')), 200);
BEGIN
    SELECT p.user_id, p.supplier_id INTO v_user, v_supplier FROM supplier_portal_users p WHERE p.id = v_link;
    SELECT a.portal_upload_max_bytes, a.portal_upload_types INTO v_max, v_types FROM account_settings a WHERE a.id;
    IF v_max IS NULL OR v_types IS NULL THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_LIMITS_NOT_SET';
    END IF;
    IF p_file_type IS NULL OR NOT (p_file_type = ANY (v_types)) THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_TYPE_NOT_ACCEPTED|%', COALESCE(p_file_type, '');
    END IF;
    IF p_file_size IS NULL OR p_file_size <= 0 THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_EMPTY';
    END IF;
    IF p_file_size > v_max THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_TOO_LARGE|%', v_max;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM certificate_types ct WHERE ct.code = p_cert_type AND ct.is_active) THEN
        RAISE EXCEPTION 'PORTAL_CERT_TYPE_UNKNOWN|%', COALESCE(p_cert_type, '');
    END IF;
    IF p_valid_from IS NOT NULL AND p_valid_until IS NOT NULL AND p_valid_until < p_valid_from THEN
        RAISE EXCEPTION 'PORTAL_CERT_DATES_INVALID';
    END IF;
    IF v_name = '' THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_NAME_REQUIRED';
    END IF;
    v_ext := CASE p_file_type WHEN 'application/pdf' THEN 'pdf' WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/png' THEN 'png' ELSE 'bin' END;
    v_path := v_supplier::text || '/' || v_id::text || '.' || v_ext;
    INSERT INTO portal_certificate_submissions (id, portal_user_id, user_id, supplier_id, cert_type_code, cert_no, valid_from, valid_until,
                                                file_name, file_type, file_size, storage_path)
    VALUES (v_id, v_link, v_user, v_supplier, p_cert_type, NULLIF(left(btrim(COALESCE(p_cert_no, '')), 120), ''), p_valid_from, p_valid_until,
            v_name, p_file_type, p_file_size, v_path);
    RETURN jsonb_build_object('id', v_id, 'bucket', 'portal-uploads', 'path', v_path);
END;
$function$;

-- db/functions/portal_submission_finish.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §5 · V39,Tim):【门户交完一份证书】—— 确认字节真的到了桶里,这一份才变成一份等审核的申请。
--   先过 portal_require_link();只认调用者【自己这个账号】的、还在 uploading 的那一行(别人的、别家的、不存在的同一句拒:
--   PORTAL_SUBMISSION_NOT_FOUND;已经不是 uploading 的 → PORTAL_SUBMISSION_NOT_UPLOADING|<状态>)。
--   字节:portal-uploads 里那条路径上必须有一个对象(否则 PORTAL_UPLOAD_NOT_STORED);存储记下了大小 / 类型的,
--   大小必须等于登记时说的、类型必须是登记时那一种(否则 PORTAL_UPLOAD_MISMATCH —— 路由随后 abandon)。
--   过了:status → submitted,submitted_at = now()。【什么别的都不写】。
--   EXECUTE 只授 supplier_portal。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_submission_finish(p_submission_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link uuid := portal_require_link();
    s      portal_certificate_submissions%ROWTYPE;
    v_meta jsonb;
BEGIN
    SELECT * INTO s FROM portal_certificate_submissions x WHERE x.id = p_submission_id AND x.portal_user_id = v_link FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_FOUND';
    END IF;
    IF s.status <> 'uploading' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_UPLOADING|%', s.status;
    END IF;
    SELECT COALESCE(o.metadata, '{}'::jsonb) INTO v_meta FROM storage.objects o WHERE o.bucket_id = s.bucket_id AND o.name = s.storage_path;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_NOT_STORED';
    END IF;
    IF (v_meta ? 'size' AND (v_meta ->> 'size')::bigint <> s.file_size)
       OR (v_meta ? 'mimetype' AND v_meta ->> 'mimetype' <> s.file_type) THEN
        RAISE EXCEPTION 'PORTAL_UPLOAD_MISMATCH';
    END IF;
    UPDATE portal_certificate_submissions SET status = 'submitted', submitted_at = now() WHERE id = s.id;
    RETURN jsonb_build_object('id', s.id, 'state', 'waiting');
END;
$function$;

-- db/functions/portal_submission_abandon.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §5,Tim):【门户收回一份没传成的证书】—— 字节没到(或到了却对不上)时,路由把那一行标成 abandoned。
--   先过 portal_require_link();只认调用者自己这个账号的、还在 uploading 的那一行(否则 PORTAL_SUBMISSION_NOT_FOUND /
--   PORTAL_SUBMISSION_NOT_UPLOADING|<状态>)。abandoned 的那一行员工看不见、门户不列;它在桶里若留下了字节(字节到了却对不上的那一种),
--   字节留着 —— portal-uploads 没有删除策略(docs/known-issues.md MES9C-ABANDONED-UPLOAD-BYTES-STAY)。
--   EXECUTE 只授 supplier_portal。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_submission_abandon(p_submission_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link   uuid := portal_require_link();
    v_status text;
BEGIN
    SELECT x.status INTO v_status FROM portal_certificate_submissions x WHERE x.id = p_submission_id AND x.portal_user_id = v_link FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_FOUND';
    END IF;
    IF v_status <> 'uploading' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_UPLOADING|%', v_status;
    END IF;
    UPDATE portal_certificate_submissions SET status = 'abandoned' WHERE id = p_submission_id;
    RETURN jsonb_build_object('id', p_submission_id, 'state', 'abandoned');
END;
$function$;

-- db/functions/portal_can_upload_object.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §3 · §5 · Q27,Tim):【存储策略的判据】—— 一个门户会话能不能往 portal-uploads 的这一条路径传字节(与读回它刚传的那一行)。
--   storage.objects 上两条 TO supplier_portal 的策略只调它(INSERT 的 WITH CHECK 与 SELECT 的 USING —— 后者给 Storage API 插入之后读回那一行用)。
--   成立 = 这是一个有效的门户会话(portal_require_link 不拒)并且【这位账号自己有一行 uploading 的申请,路径正是这一条,登记在十分钟内】
--   —— 那一行只由 portal_submission_begin 在 V39 判过之后写。于是:没先过 V39 的字节存不进来;别家的路径、别人的路径、已经交完的、
--   过了十分钟的,一律存不进来;改与删没有策略(门户角色只有 SELECT 与 INSERT 的授权)。
--   【绝不抛】在 RLS 里抛会把一次上传变成一次 500;任何一步不成立都回 false。
--   EXECUTE 只授 supplier_portal(策略以调用者身份求值;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_can_upload_object(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link uuid;
BEGIN
    BEGIN
        v_link := portal_require_link();
    EXCEPTION WHEN OTHERS THEN
        RETURN false;
    END;
    RETURN p_bucket = 'portal-uploads'
       AND EXISTS (SELECT 1 FROM portal_certificate_submissions s
                    WHERE s.portal_user_id = v_link AND s.storage_path = p_name AND s.status = 'uploading'
                      AND s.created_at > now() - interval '10 minutes');
END;
$function$;

-- db/functions/portal_submission_accept.sql
-- MES-9c(2026-10-20,MES-9 Step 0 Q19,Tim):【员工接受一份门户交上来的证书】—— 同一笔事务里:建 supplier_compliance 行,把已经抄进
--   supplier-attachments 的那份文件登记成那家供应商的一行附件,并把证书挂上它;这一份申请 → accepted。没有审批链(Q19)。
--   门 module.suppliers.edit(Q19 —— 与在供应商页上手工加一张证书同一个码;没有它 → PERMISSION_DENIED|module.suppliers.edit)。
--   p_attachment_path:服务端动作先以【员工自己的会话】把文件从 portal-uploads 抄到 supplier-attachments 的这一条路径
--   (<供应商 id>/…),这里确认它真的在那儿、大小与交上来的那份相同(否则 PORTAL_SUBMISSION_FILE_NOT_COPIED);
--   路径不在这家供应商的目录下 → PORTAL_SUBMISSION_FILE_PATH_INVALID。
--   只接受还在等审核的(status = submitted;否则 PORTAL_SUBMISSION_NOT_WAITING|<状态>;不存在 → PORTAL_SUBMISSION_NOT_FOUND)。
--   证书的类型取交上来的那一份(不改);号 · 发证机构 · 有效期由员工核对后给(空着的号与有效期取交上来的值)。
--   supplier_compliance 行与附件行都以【员工】为建立人(created_by = auth.uid()),审计记录读作那位员工;交上来的那几步读作门户账号。
--   号 · 发证机构 · 有效期都可空(DEFAULT NULL)—— 员工可以不改交上来的值。返回 {submission, compliance_id, attachment_id}。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_submission_accept(p_submission_id uuid, p_attachment_path text, p_cert_no text DEFAULT NULL::text, p_issuing_body text DEFAULT NULL::text, p_valid_from date DEFAULT NULL::date, p_valid_until date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    s       portal_certificate_submissions%ROWTYPE;
    v_uid   uuid := auth.uid();
    v_size  text;
    v_att   uuid;
    v_comp  uuid;
    v_from  date;
    v_until date;
BEGIN
    PERFORM require_permission('module.suppliers.edit');
    SELECT * INTO s FROM portal_certificate_submissions x WHERE x.id = p_submission_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_FOUND';
    END IF;
    IF s.status <> 'submitted' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_WAITING|%', s.status;
    END IF;
    IF p_attachment_path IS NULL OR left(p_attachment_path, 37) <> s.supplier_id::text || '/' OR p_attachment_path LIKE '%..%' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_FILE_PATH_INVALID';
    END IF;
    SELECT o.metadata ->> 'size' INTO v_size FROM storage.objects o WHERE o.bucket_id = 'supplier-attachments' AND o.name = p_attachment_path;
    IF NOT FOUND OR (v_size IS NOT NULL AND v_size::bigint <> s.file_size) THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_FILE_NOT_COPIED';
    END IF;
    v_from := COALESCE(p_valid_from, s.valid_from);
    v_until := COALESCE(p_valid_until, s.valid_until);
    IF v_from IS NOT NULL AND v_until IS NOT NULL AND v_until < v_from THEN
        RAISE EXCEPTION 'PORTAL_CERT_DATES_INVALID';
    END IF;
    INSERT INTO supplier_attachments (supplier_id, storage_path, file_name, file_type, file_size, created_by, updated_by)
    VALUES (s.supplier_id, p_attachment_path, s.file_name, s.file_type, s.file_size, v_uid, v_uid)
    RETURNING id INTO v_att;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, issuing_body, valid_from, valid_until, document_id, created_by, updated_by)
    VALUES (s.supplier_id, s.cert_type_code, COALESCE(NULLIF(btrim(COALESCE(p_cert_no, '')), ''), s.cert_no),
            NULLIF(btrim(COALESCE(p_issuing_body, '')), ''), v_from, v_until, v_att, v_uid, v_uid)
    RETURNING id INTO v_comp;
    UPDATE portal_certificate_submissions
       SET status = 'accepted', decided_at = now(), decided_by = v_uid, compliance_id = v_comp, attachment_id = v_att
     WHERE id = s.id;
    RETURN jsonb_build_object('submission', s.id, 'compliance_id', v_comp, 'attachment_id', v_att);
END;
$function$;

-- db/functions/portal_submission_reject.sql
-- MES-9c(2026-10-20,MES-9 Step 0 Q19,Tim):【员工驳回一份门户交上来的证书】—— 理由必填(PORTAL_SUBMISSION_REASON_REQUIRED),
--   供应商在门户里看得见这句理由。门 module.suppliers.edit(Q19)。只驳回还在等审核的(PORTAL_SUBMISSION_NOT_WAITING|<状态>)。
--   什么别的都不写:没有证书行、没有附件行;交上来的那份字节留在 portal-uploads 里(它是那一份申请的凭据;那个桶没有删除策略)。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_submission_reject(p_submission_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_status text;
    v_reason text := btrim(COALESCE(p_reason, ''));
BEGIN
    PERFORM require_permission('module.suppliers.edit');
    IF v_reason = '' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_REASON_REQUIRED';
    END IF;
    SELECT x.status INTO v_status FROM portal_certificate_submissions x WHERE x.id = p_submission_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_FOUND';
    END IF;
    IF v_status <> 'submitted' THEN
        RAISE EXCEPTION 'PORTAL_SUBMISSION_NOT_WAITING|%', v_status;
    END IF;
    UPDATE portal_certificate_submissions
       SET status = 'rejected', decided_at = now(), decided_by = auth.uid(), reject_reason = left(v_reason, 1000)
     WHERE id = p_submission_id;
    RETURN jsonb_build_object('submission', p_submission_id, 'state', 'rejected');
END;
$function$;

-- ── 4 · 换掉的函数(镜像原样,同签名):审计记录的主语成员多一行 ──

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q39):一份化验的指标(残粉 · 箔纯度 · 粒径)与它的金属行同一个形状 ——
        --    住在那份化验挂着的那一批下(化验没有自己的主语;它的金属行也是这样挂的)。──
        ('inbound_batch',     47, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        ('output_batch',      45, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-1(2026-10-15,MES-6b Step 0 Q39):不合格报告也出现在它那一批上(家在报告自己那里);质量验收限的判定住在产出批下
        --    (判定挂在批次上,没有自己的主语);合同的第八张条款表住在合同下。──
        ('inbound_batch',     48, 'nonconformance_reports',           'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      46, 'nonconformance_reports',           'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      47, 'quality_limit_judgements',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, true),
        ('contract',          11, 'contract_quality_limits',          'contracts',                    'contract_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书 —— 它的字节档案(家在证书)、作废它的 CFO 申请与那张申请的审批。
        --    证书也出现在两个批次主语下(家在证书自己那里):产出批 —— 它自己的证书、字节、作废申请与审批;进料批 —— 吃过这一批的加工单
        --    做出来的产出批上的证书(垫脚石:加工单 → 它的产出腿 → 那一批产出,只走一层;证书说的"来料化学确定度"正是这一批的事)。──
        ('coa',                1, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, true),
        ('coa',                2, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('coa',                3, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch',      48, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      49, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      50, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      51, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch',     49, 'processing_outputs',               'processing_runs',              'run_id',              '{}'::jsonb, 'down', false, false),
        ('inbound_batch',     50, 'output_batches',                   'processing_outputs',           'output_batch_id',     '{}'::jsonb, 'up',   false, false),
        ('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7a-2(2026-10-16,MES-7a Step 0 Q20):备件出给保养与退回 —— 没有自己的主语(它没有自己的页)。家在设备(经那一条保养记录);
        --    也出现在进料批下(出的是这一批),连同那张分录(借 6800 / 贷 1200,source_type = maintenance_part,财务读)。──
        ('equipment',          5, 'maintenance_part_issues',          'equipment_maintenance',        'maintenance_id',      '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     52, 'maintenance_part_issues',          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     53, 'journal_entries',                  'maintenance_part_issues',      'source_id',           '{"source_type": "maintenance_part"}'::jsonb, 'down', true, false),
        -- ── MES-7b-1(2026-10-16,MES-7b Step 0 Q12 · Q19):一件事故 —— 之后的事实与批次链接住在这里;交接班的引用住在交接班下(家),
        --    也出现在事故上;来源 incident 的不合格报告也出现在事故上(家在报告自己那里)。批次链接也出现在那一批上(Q19:事故在批次上看得见)。──
        ('incident',           1, 'incident_updates',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           2, 'incident_batches',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           3, 'shift_handover_incident_refs',     'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('incident',           4, 'nonconformance_reports',           'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('shift_handover',     3, 'shift_handover_incident_refs',     'shift_handovers',              'handover_id',         '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     54, 'incident_batches',                 'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      52, 'incident_batches',                 'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7b-2(2026-10-16,MES-7b Step 0 Q19):一次巡检 —— 它的结果、发现与发现的关闭住在这里;引用一条发现的不合格报告也出现在这里
        --    (家在报告自己那里)。一张巡检清单 —— 它的检查项住在这里。──
        ('inspection_run',      1, 'inspection_results',               'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      2, 'inspection_findings',              'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      3, 'inspection_finding_closures',      'inspection_findings',          'finding_id',          '{}'::jsonb, 'down', true, true),
        ('inspection_run',      4, 'nonconformance_reports',           'inspection_findings',          'inspection_finding_id', '{}'::jsonb, 'down', true, false),
        ('inspection_template', 1, 'inspection_template_items',        'inspection_templates',         'template_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8a(2026-10-16,MES-8 Step 0 Q22):一份供应商对账单 —— 它的签发档住在这里。一家供应商的评审也出现在它下面
        --    (家在评分卡页那条集合记录里)。──
        ('supplier_statement',  1, 'supplier_statement_issues',        'supplier_statements',          'statement_id',        '{}'::jsonb, 'down', true, true),
        ('supplier',            6, 'supplier_scorecard_reviews',       'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, false),
        -- ── MES-9a(2026-10-19,MES-9 Step 0 §6 · Q21):一家供应商的门户账号 —— 开、撤销、匿名化住在这里 ──
        ('supplier',            7, 'supplier_portal_users',            'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-9c(2026-10-20,MES-9 Step 0 §5 · §6 · Q19 · Q21):门户交上来的证书 —— 交、接受、驳回住在这里 ──
        ('supplier',            8, 'portal_certificate_submissions',   'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包 —— 它的签发档住在这里。──
        ('compliance_pack',     1, 'compliance_pack_issues',           'compliance_packs',             'pack_id',             '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 5 · F19:change_log_rows 多两个参数 —— 签名变了,先 DROP 旧签名,再按镜像建 ──

DROP FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[]);

-- db/functions/change_log_rows.sql
-- HISTORY-1(Tim 的 Q10 · Q26 · Q6):变更记录的【唯一】全局读法。/settings/change-history 读它。
-- AUDIT-TRAIL-1a(Tim 的 Q5 · Q30 · Q31 · Q40):仍是这一支、仍是这一道门;加了读法,没有放宽。
--
-- 【门】data.view_change_log(只授 admin 与 cfo,不捆进任何别的角色)。没有它 → PERMISSION_DENIED。
-- 【遮蔽】逐行走 change_log_mask_row —— 与每一页底部的审计记录(record_trail)【同一步】(Q5),规则仍是
--   HISTORY-1 的 change_log_mask_rules():读者在源屏幕上看不见的值换成 {"$restricted": true},本来就是 null 的留 null;
--   任务四张表先问 change_log_task_visible(),不过 → 整份影像受限(row_restricted = true)。
-- 【筛选】日期(按库时区 Asia/Singapore,to 含当天)· 表(p_table 一张,或 p_tables 一组 —— "Area"与"Record type")·
--   记录(p_record:主键里任一值等于它;p_record_ids:主键里任一值在这一组里 —— 按单据号或名字找到的,见
--   change_log_find_records)· 人(账号 id 或员工 id 任一相等)· 只看无会话的写 · 只看"Removed account"的写。
-- 【分页】按 seq 倒序,键集分页(p_before)。p_by_entry = false:每页 p_limit 行(HISTORY-1 的原样);
--   p_by_entry = true:每页 p_limit 笔【事务】(一次操作一条,Q2),返回这些事务里符合筛选的全部行,
--   p_before 比的是一笔事务里最大的 seq。
-- 【每一行多带回】txid · actor(trail_actor:人名 / System (automatic) / Removed account …)·
--   belongs_to(trail_row_record:这一行属于哪张单据 / 哪条记录)· refs(trail_refs:每个引用值 → 名字)。
--   任务隐私受限的行不带 belongs_to 与 refs —— 任务标题本身就是被藏起来的东西。
-- 【它仍然列出每一次写入】(Q31):系统的、冒烟的、账号事件的,一行不少。
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q13):【每一行再过一次它自己那张表的读规则】—— 与每一页底部的审计记录
--   (record_trail 的第三道)同一个判法、同一支函数(trail_row_visible,对这一行今天的样子;已经删掉的,对它最后的影像)。
--   过不了 → 整份影像受限(row_restricted = true,与任务隐私同一个形状:界面说这一类记录被改过、内容受限)。
--   为什么:这一页的门是 data.view_change_log;以前只按 HISTORY-1 的列规则遮,而几张表是按【行】管的 ——
--   调薪申请要 hr.view 加 data.view_pay,评审与 KPI 要 data.view_reviews,账号事件要 manage_permissions。
--   一个持 view_change_log 而没有 view_pay 的人,以前在这里读得到每一笔调薪的金额。今天持这个码的两个人(admin、cfo)
--   两样都有,所以那时没有人读到 —— 它是一个躺着的洞,不是一次泄漏。同一行在同一次调用里只判一次(v_vis_cache)。
-- F19(MES-9c,2026-10-20,Tim):p_by_entry 时再给一个【行的】键集 —— p_row_limit(1–200)与 p_row_before(seq)。
--   事务照旧由 p_before / p_limit 选出(同一组 txid),只是那组事务里的行按 seq 倒序、一次最多交 p_row_limit 行,
--   p_row_before = 上一次交到的最小 seq。为什么:每一行要算一次审计记录(trail_row_record · trail_refs · 读规则),
--   一次批量授权就是几百行一笔事务 —— 一次调用的代价随"最近那几次操作有多少行"涨,撞上 authenticated 的 8 秒上限
--   (CHANGE-HISTORY-8S-AFTER-BULK-GRANTS:381 行 6.5–9.6 秒)。分页之后每一次调用的行数有上界,而几次调用合起来交出的行
--   与不分页那一次【逐行相同】(fixture 278)。不给 p_row_limit = 原样,一行都不变。
-- 【SECURITY DEFINER 的理由】change_log 对应用角色没有任何授权;读 auth.users 取邮箱与账号是否还在。
CREATE OR REPLACE FUNCTION public.change_log_rows(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_record text DEFAULT NULL::text, p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_before bigint DEFAULT NULL::bigint, p_limit integer DEFAULT 50, p_tables text[] DEFAULT NULL::text[], p_removed_account boolean DEFAULT false, p_by_entry boolean DEFAULT false, p_record_ids text[] DEFAULT NULL::text[], p_row_before bigint DEFAULT NULL::bigint, p_row_limit integer DEFAULT NULL::integer)
 RETURNS TABLE(seq bigint, occurred_at timestamp with time zone, table_name text, row_key jsonb, op text, actor_account uuid, actor_email text, actor_employee uuid, actor_employee_code text, actor_employee_name text, actor_kind text, db_role text, changed_columns text[], old jsonb, new jsonb, redacted_at timestamp with time zone, row_restricted boolean, txid bigint, actor jsonb, belongs_to jsonb, refs jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    r        record;
    v_mask   jsonb;
    v_limit  integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
    v_txids  bigint[];
    v_vkey   text;
    v_vis    boolean;
    v_cache  jsonb := '{}'::jsonb;
    v_cimg   record;
BEGIN
    PERFORM require_permission('data.view_change_log');

    IF COALESCE(p_by_entry, false) THEN
        SELECT array_agg(g.g_tx ORDER BY g.g_mx DESC) INTO v_txids FROM (
            SELECT c.txid AS g_tx, max(c.seq) AS g_mx
              FROM change_log c
             WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
               AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
               AND (p_table IS NULL OR c.table_name = p_table)
               AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
               AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
               AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
               AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
               AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
               AND (NOT COALESCE(p_removed_account, false)
                    OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                        AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)))
             GROUP BY c.txid
            HAVING p_before IS NULL OR max(c.seq) < p_before
             ORDER BY max(c.seq) DESC
             LIMIT v_limit) g;
        IF v_txids IS NULL THEN
            RETURN;
        END IF;
    END IF;

    FOR r IN
        SELECT c.seq AS c_seq, c.occurred_at AS c_at, c.table_name AS c_table, c.row_key AS c_key,
               c.op AS c_op, c.actor_account AS c_account, u.email::text AS c_email,
               c.actor_employee AS c_employee, e.code AS c_emp_code,
               COALESCE(e.preferred_name, e.legal_name) AS c_emp_name,
               c.actor_kind AS c_kind, c.db_role AS c_role, c.changed_columns AS c_cols,
               c.old AS c_old, c.new AS c_new, c.redacted_at AS c_redacted, c.txid AS c_tx
          FROM change_log c
          LEFT JOIN auth.users u ON u.id = c.actor_account
          LEFT JOIN employees e ON e.id = c.actor_employee
         WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
           AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
           AND (p_table IS NULL OR c.table_name = p_table)
           AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
           AND (p_record IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = p_record))
           AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
           AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
           AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
           AND (NOT COALESCE(p_removed_account, false)
                OR (c.actor_kind = 'user' AND c.actor_employee IS NULL AND u.id IS NULL))
           AND (CASE WHEN COALESCE(p_by_entry, false) THEN c.txid = ANY (v_txids)
                                                           AND (p_row_before IS NULL OR c.seq < p_row_before)
                     ELSE (p_before IS NULL OR c.seq < p_before) END)
         ORDER BY c.seq DESC
         LIMIT CASE WHEN COALESCE(p_by_entry, false) THEN (CASE WHEN p_row_limit IS NOT NULL THEN LEAST(GREATEST(p_row_limit, 1), 200) END) ELSE v_limit END
    LOOP
        seq := r.c_seq;
        occurred_at := r.c_at;
        table_name := r.c_table;
        row_key := r.c_key;
        op := r.c_op;
        actor_account := r.c_account;
        actor_email := r.c_email;
        actor_employee := r.c_employee;
        actor_employee_code := r.c_emp_code;
        actor_employee_name := r.c_emp_name;
        actor_kind := r.c_kind;
        db_role := r.c_role;
        changed_columns := r.c_cols;
        redacted_at := r.c_redacted;
        txid := r.c_tx;
        actor := trail_actor(r.c_kind, r.c_account, r.c_employee);

        v_mask := change_log_mask_row(r.c_table, r.c_key, r.c_old, r.c_new);
        old := NULLIF(v_mask -> 'old', 'null'::jsonb);
        new := NULLIF(v_mask -> 'new', 'null'::jsonb);
        row_restricted := (v_mask ->> 'row_restricted')::boolean;
        -- Q13:这一行过不过它自己那张表的读规则(每一行只判一次)
        v_vkey := r.c_table || '|' || COALESCE(r.c_key::text, '');
        IF v_cache ? v_vkey THEN
            v_vis := (v_cache ->> v_vkey)::boolean;
        ELSE
            SELECT * INTO v_cimg FROM trail_current_image(r.c_table, r.c_key);
            v_vis := COALESCE(trail_row_visible(r.c_table, r.c_key, COALESCE(v_cimg.image, r.c_new, r.c_old)), false);
            v_cache := v_cache || jsonb_build_object(v_vkey, v_vis);
        END IF;
        IF NOT v_vis AND NOT row_restricted THEN
            old := change_log_restrict(r.c_old, NULL);
            new := change_log_restrict(r.c_new, NULL);
            row_restricted := true;
        END IF;
        IF row_restricted OR r.c_table = 'auth.users' THEN
            belongs_to := NULL;
            refs := '{}'::jsonb;
        ELSE
            belongs_to := trail_row_record(r.c_table, r.c_key, old, new);
            refs := trail_refs(r.c_table, old, new, r.c_key);
        END IF;
        RETURN NEXT;
    END LOOP;
END;
$function$;

-- ── 6 · 待补的值多一支 V39(镜像原样)──
CREATE OR REPLACE VIEW public.pending_values WITH (security_invoker = off) AS
 SELECT p.value_code,
    p.permission,
    p.item_id,
    p.item_code,
    p.item_label,
    p.href
   FROM ( SELECT 'V5'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = 'gateway'::text AND d.retired_at IS NULL AND d.heartbeat_interval_s IS NULL
        UNION ALL
         SELECT 'V6'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            sh.code AS item_code,
            sh.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM shifts sh
          WHERE sh.is_active AND sh.starts_at IS NULL AND sh.ends_at IS NULL
        UNION ALL
         SELECT 'V8'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            'calibration_lead_days'::text AS item_code,
            'Calibration reminder lead days'::text AS item_label,
            '/operation/calibration'::text AS href
           FROM ingest_settings st
          WHERE st.id AND st.calibration_lead_days IS NULL
        UNION ALL
         SELECT 'V33'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
            AND d.retired_at IS NULL AND d.interface_status <> 'reserved'::text AND d.capacity IS NULL
        UNION ALL
         SELECT 'V2'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            c.code AS item_code,
            (cc.cert_no || ' · '::text) || c.name_en AS item_label,
            '/purchasing/licences'::text AS href
           FROM company_compliance cc
             CROSS JOIN nea_waste_categories c
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date) AND c.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM licence_storage_limits l
                  WHERE l.licence_id = cc.id AND l.category_code = c.code))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_waste_categories'::text AS item_code,
            'NEA waste categories'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.nea_waste_category_code IS NULL
            AND (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V3'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.dwell_warning_days IS NULL
        UNION ALL
         SELECT 'V4'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.requires_quarantine IS NULL
        UNION ALL
         SELECT 'V34'::text AS value_code,
            'module.inventory.view'::text AS permission,
            NULL::uuid AS item_id,
            'quarantine_location'::text AS item_code,
            'Quarantine location'::text AS item_label,
            '/inventory/locations'::text AS href
          WHERE (EXISTS ( SELECT 1
                   FROM inbound_safety_states st
                  WHERE st.is_active AND st.requires_quarantine IS TRUE))
            AND NOT (EXISTS ( SELECT 1
                   FROM storage_locations l
                  WHERE l.is_active AND l.is_quarantine))
        UNION ALL
         SELECT 'V30'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            g.code AS item_code,
            g.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM dangerous_goods_codes g
          WHERE g.is_active AND (g.marking_text IS NULL OR g.packing_instruction IS NULL OR g.label_size IS NULL)
        UNION ALL
         SELECT 'V31'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.hs_code IS NULL
        UNION ALL
         SELECT 'V35'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.dg_code IS NULL
        UNION ALL
         SELECT 'V1'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
             JOIN operation_kinds k ON k.code = ot.kind_code
          WHERE ot.is_active AND k.produces_outputs AND ot.balance_tolerance_pct IS NULL
        UNION ALL
         SELECT 'V36'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (f.operation_type_code || '/'::text) || f.field_code AS item_code,
            f.name_en AS item_label,
            '/operation/operation-types/'::text || f.operation_type_code AS href
           FROM operation_type_fields f
             JOIN operation_types ot ON ot.code = f.operation_type_code
          WHERE f.is_active AND ot.is_active AND f.has_range AND f.range_min IS NULL AND f.range_max IS NULL
        UNION ALL
         SELECT 'V10'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            ot.code AS item_code,
            ot.name_en AS item_label,
            '/operation/operation-types/'::text || ot.code AS href
           FROM operation_types ot
          WHERE ot.is_active AND ot.electrolyte_loss_applies AND ot.electrolyte_share_pct IS NULL
        UNION ALL
         SELECT 'V11'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            cs.code AS item_code,
            cs.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM contamination_streams cs
          WHERE cs.is_active AND cs.warning_pct IS NULL
        UNION ALL
         SELECT 'V9'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.discharge_pass_voltage_v IS NULL AND (EXISTS ( SELECT 1
                   FROM discharge_module_results r
                     LEFT JOIN inbound_batches ib ON ib.id = r.inbound_batch_id
                     LEFT JOIN output_batches ob ON ob.id = r.output_batch_id
                  WHERE COALESCE(ib.material_id, ob.material_id) = m.id))
        UNION ALL
         SELECT 'V25'::text AS value_code,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            'shared_pool_rule'::text AS item_code,
            'Shared-pool electricity rule'::text AS item_label,
            '/finance/electricity'::text AS href
           FROM electricity_settings es
          WHERE es.id AND es.shared_pool_rule IS NULL AND (EXISTS ( SELECT 1
                   FROM devices d
                  WHERE d.kind = 'meter'::text AND d.equipment_id IS NULL AND d.retired_at IS NULL))
        UNION ALL
         SELECT 'V37'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            (tf.operation_type_code || '/'::text) || tf.form_code AS item_code,
            (ot.name_en || ' · '::text) || COALESCE(mf.name_en, tf.form_code) AS item_label,
            '/operation/operation-types/'::text || tf.operation_type_code AS href
           FROM operation_type_output_forms tf
             JOIN operation_types ot ON ot.code = tf.operation_type_code
             LEFT JOIN material_forms mf ON mf.code = tf.form_code
          WHERE ot.is_active AND tf.expected_yield_pct IS NULL AND (EXISTS ( SELECT 1
                   FROM processing_run_flow_all f
                  WHERE f.operation_type_code = tf.operation_type_code AND f.flow = 'consumption'::text AND f.era_mes4a))
        UNION ALL
         SELECT 'V16'::text AS value_code,
            'module.quality.view'::text AS permission,
            NULL::uuid AS item_id,
            'internal_retention_days'::text AS item_code,
            'Internal sample retention (days)'::text AS item_label,
            '/quality/samples'::text AS href
           FROM quality_settings qs
          WHERE qs.id AND qs.internal_retention_days IS NULL AND (EXISTS ( SELECT 1
                   FROM samples s
                  WHERE s.retain_until_source = 'not_set'::text AND NOT (EXISTS ( SELECT 1
                           FROM sample_events e
                          WHERE e.sample_id = s.id AND e.event_kind = 'disposed'::text))))
        UNION ALL
         SELECT 'V14'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND (EXISTS ( SELECT 1
                   FROM assay_disputes d
                     JOIN contract_document_terms t ON t.sales_order_id = d.sales_order_id
                  WHERE t.contract_id = c.id AND (d.status = ANY (ARRAY['open'::text, 'resolved'::text])))) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.arbitration_fee_rule IS NOT NULL))
        UNION ALL
         SELECT 'V17'::text AS value_code,
            'module.customers.view'::text AS permission,
            c.id AS item_id,
            c.code AS item_code,
            c.title AS item_label,
            '/contracts/'::text || c.id::text AS href
           FROM contracts c
          WHERE c.deleted_at IS NULL AND c.customer_id IS NOT NULL AND (EXISTS ( SELECT 1
                   FROM contract_document_terms t
                  WHERE t.contract_id = c.id AND t.sales_order_id IS NOT NULL)) AND NOT (EXISTS ( SELECT 1
                   FROM contract_settlement_terms cst
                  WHERE cst.contract_id = c.id AND cst.quality_limit_basis IS NOT NULL))
        UNION ALL
         SELECT 'V21'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            ('/materials/'::text || m.id::text) || '/edit'::text AS href
           FROM materials m
          WHERE m.deleted_at IS NULL AND m.kind_code = 'spare_part'::text AND m.safety_stock_qty IS NULL AND (EXISTS ( SELECT 1
                   FROM inbound_batches b
                  WHERE b.material_id = m.id))
        UNION ALL
         SELECT 'V19'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_report_working_days'::text AS item_code,
            'NEA written-report deadline (working days)'::text AS item_label,
            '/safety/incidents'::text AS href
           FROM safety_settings ss
          WHERE ss.id AND (ss.nea_report_working_days IS NULL OR ss.nea_report_days_confirmed_at IS NULL)
        UNION ALL
         SELECT 'V18'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'inspection_templates'::text AS item_code,
            'Inspection checklists'::text AS item_label,
            '/safety/inspections'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM inspection_templates t
                  WHERE t.is_active))
        UNION ALL
         SELECT 'V18'::text AS value_code,
            'module.safety.view'::text AS permission,
            t.id AS item_id,
            t.code AS item_code,
            t.name AS item_label,
            '/safety/inspections/templates/'::text || t.id::text AS href
           FROM inspection_templates t
          WHERE t.is_active AND t.frequency_days IS NULL
        UNION ALL
         SELECT 'V20'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            'environmental_parameters'::text AS item_code,
            'Monitored environmental parameters'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM environmental_parameters ep))
        UNION ALL
         SELECT 'V20'::text AS value_code,
            'module.safety.view'::text AS permission,
            NULL::uuid AS item_id,
            ep.code AS item_code,
            ep.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM environmental_parameters ep
          WHERE ep.is_active AND ep.limit_value IS NULL
        UNION ALL
         SELECT 'V23'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            NULL::uuid AS item_id,
            'supplier_score_settings'::text AS item_code,
            'Supplier scorecard weights, grade lines and review window'::text AS item_label,
            '/suppliers/scorecards'::text AS href
           FROM supplier_score_settings ss
          WHERE ss.id AND (ss.weights IS NULL OR ss.grade_lines IS NULL OR ss.review_window_days IS NULL)
        UNION ALL
         SELECT 'V24'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            NULL::uuid AS item_id,
            gl.value ->> 'grade'::text AS item_code,
            'Grade '::text || (gl.value ->> 'grade'::text) AS item_label,
            '/suppliers/scorecards'::text AS href
           FROM supplier_score_settings ss
             CROSS JOIN LATERAL jsonb_array_elements(ss.grade_lines) gl(value)
          WHERE ss.id AND ss.grade_lines IS NOT NULL
            AND ((((ss.grade_caps -> (gl.value ->> 'grade'::text)) ->> 'prepayment_cap_pct'::text) IS NULL)
                 OR (((ss.grade_caps -> (gl.value ->> 'grade'::text)) ->> 'sampling_level'::text) IS NULL))
        UNION ALL
         SELECT 'V26'::text AS value_code,
            'module.compliance.view'::text AS permission,
            NULL::uuid AS item_id,
            'compliance_settings'::text AS item_code,
            'NEA return format and frequency'::text AS item_label,
            '/compliance/packs'::text AS href
           FROM compliance_settings cs
          WHERE cs.id AND (cs.nea_return_format IS NULL OR cs.nea_return_frequency IS NULL)
        UNION ALL
         SELECT 'V27'::text AS value_code,
            'module.compliance.view'::text AS permission,
            NULL::uuid AS item_id,
            'compliance_settings'::text AS item_code,
            'EU recycling-efficiency method and targets'::text AS item_label,
            '/compliance/packs'::text AS href
           FROM compliance_settings cs
          WHERE cs.id AND (cs.eu_efficiency_method IS NULL OR cs.eu_efficiency_targets IS NULL)
        UNION ALL
         SELECT 'V28'::text AS value_code,
            'action.manage_permissions'::text AS permission,
            NULL::uuid AS item_id,
            'floor_board_settings'::text AS item_code,
            'Wall-display refresh interval and tiles'::text AS item_label,
            '/display'::text AS href
           FROM floor_board_settings fb
          WHERE fb.id AND (fb.refresh_seconds IS NULL OR fb.tiles IS NULL)
            AND (EXISTS ( SELECT 1
                   FROM user_roles ur
                     JOIN roles r ON r.id = ur.role_id
                     JOIN auth.users u ON u.id = ur.user_id
                  WHERE r.code = 'floor_display'::text AND ur.revoked_at IS NULL AND r.is_active AND u.deleted_at IS NULL
                    AND (u.banned_until IS NULL OR u.banned_until < now())))
        UNION ALL
         SELECT 'V38'::text AS value_code,
            'action.manage_permissions'::text AS permission,
            NULL::uuid AS item_id,
            'account_settings'::text AS item_code,
            'Initial password validity (days)'::text AS item_label,
            '/settings/accounts'::text AS href
           FROM account_settings acs
          WHERE acs.id AND acs.initial_password_valid_days IS NULL
        UNION ALL
         SELECT 'V40'::text AS value_code,
            'action.manage_permissions'::text AS permission,
            NULL::uuid AS item_id,
            'account_settings'::text AS item_code,
            'Password minimum length'::text AS item_label,
            '/settings/accounts'::text AS href
           FROM account_settings acs
          WHERE acs.id AND acs.password_min_length IS NULL
        UNION ALL
         SELECT 'V39'::text AS value_code,
            'action.manage_permissions'::text AS permission,
            NULL::uuid AS item_id,
            'account_settings'::text AS item_code,
            'Supplier portal upload limits (size and file types)'::text AS item_label,
            '/settings/accounts'::text AS href
           FROM account_settings acs
          WHERE acs.id AND (acs.portal_upload_max_bytes IS NULL OR acs.portal_upload_types IS NULL)) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号);MES-4a 加 V1(转化型工序的物料平衡容差)与 V36(声明了有范围的参数的上下限),并把 V6 的去处搬到班次字典(V6 同时答 V7);MES-4b 加 V10(勾了电解液挥发的工序的电解液份额)与 V11(交叉污染流的警戒线)。MES-5a-1 加 V9(物料的放电通过电压,只在那种物料有了放电结果之后才列);MES-5a-2 加 V25(共用池的电怎么摊,有共用池电表而规则为空时一行)。MES-5b-1 加 V37(每道工序 × 每种产出形态的预期质量得率;只在那道工序有了至少一张 MES-4a 之后的消耗炉次时才列 —— V9 的先例:没人能动手的行不列)。MES-6a-1 加 V16(没有合同天数的样品留多少天;只在有一份没处置、留样日 Not yet set 的样品时才列)与 V14(仲裁费怎么分;每一份有过一件开着或已结案的争议而规则为空的合同一行)。MES-6b-1 加 V17(卖方合同的质量验收限;每一份挂了销售单而口径没声明的卖方合同一行)。MES-7a-2 加 V21(备件的最低库存;每一种收过至少一批而最低库存为空的备件物料一行)。MES-7b-1 加 V19(NEA 书面报告的工作日数;空着或还没对着执照确认时一行)。MES-7b-2 加 V18(巡检清单的频率与检查项;一张启用的清单都没有时一行,之后每一张频率空着的启用清单一行)与 V20(监测参数的排放限值;字典空着时一行,之后每一个没有限值的启用参数一行)。MES-8a 加 V23(供应商评分的权重、等级线与评审周期;三样里有一样空着就一行)与 V24(每一个等级的预付上限与抽样级别;有了等级线之后,每一个缺其中一样的等级一行)。MES-8b-1 加 V26(NEA 申报的格式与频率)与 V27(欧盟回收效率的方法与目标)—— 两支都是从第一天起就一行(合规包的设定一行、全空),读 module.compliance.view。MES-8b-2 加 V28(车间大屏自己刷新的间隔与画哪几块牌子;设定那一行有一样空着、并且有一个在用的 floor_display 账号时一行 —— 没有大屏就没有人能动手,读 action.manage_permissions)。MES-9a 加 V38(初始密码在第一次登录之前有效几天)与 V40(项目的密码最短长度)—— 两支都从第一天起就一行(account_settings 一行、全空),读 action.manage_permissions,去处 /settings/accounts。MES-9c 加 V39(门户上传的上限:每份最大字节数与收哪几种文件;Tim 已定 10 MB · PDF / JPEG / PNG,作默认值写进 account_settings,所以这一支从第一天起就是空的 —— 清掉它才出一行),读 action.manage_permissions,去处 /settings/accounts。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 7 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):一个桶 · 一条授权 · 三条策略 ──
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('portal-uploads', 'portal-uploads', false, 10485760, ARRAY['application/pdf', 'image/jpeg', 'image/png'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

GRANT INSERT ON storage.objects TO supplier_portal;

DROP POLICY IF EXISTS "portal uploads its own pending submission file" ON storage.objects;
CREATE POLICY "portal uploads its own pending submission file"
    ON storage.objects AS PERMISSIVE FOR INSERT TO supplier_portal
    WITH CHECK (((bucket_id = 'portal-uploads'::text) AND public.portal_can_upload_object(bucket_id, name)));

DROP POLICY IF EXISTS "portal reads its own pending submission file" ON storage.objects;
CREATE POLICY "portal reads its own pending submission file"
    ON storage.objects AS PERMISSIVE FOR SELECT TO supplier_portal
    USING (((bucket_id = 'portal-uploads'::text) AND public.portal_can_upload_object(bucket_id, name)));

DROP POLICY IF EXISTS "portal-uploads read by suppliers.view" ON storage.objects;
CREATE POLICY "portal-uploads read by suppliers.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'portal-uploads'::text) AND has_permission('module.suppliers.view'::text)));


-- ── 8 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.portal_certificates() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_certificates() TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_submission_begin(text, text, text, bigint, text, date, date) TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_submission_finish(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_submission_finish(uuid) TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_submission_abandon(uuid) TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.portal_can_upload_object(text, text) TO supplier_portal;
REVOKE EXECUTE ON FUNCTION public.portal_submission_accept(uuid, text, text, text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_submission_accept(uuid, text, text, text, date, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.portal_submission_reject(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.portal_submission_reject(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[], bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[], bigint, integer) TO authenticated, service_role;

-- ── 9 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes9c_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE mes9c_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_ev    jsonb;
    k       text;
    a       record;
BEGIN
    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变;没有任何门户账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES9C_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes9c_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes9c_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES9C_PROOF|an account or its roles changed';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) OR EXISTS (SELECT 1 FROM portal_certificate_submissions) THEN
        RAISE EXCEPTION 'MES9C_PROOF|no portal account and no submission may exist';
    END IF;

    -- ② hook 不变:七个真账号的 event 逐字节原样返回(本刀不碰 hook —— 这一句证它)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test') ORDER BY email LOOP
        v_ev := jsonb_build_object('user_id', a.id, 'authentication_method', 'password',
                    'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', a.id, 'email', a.email,
                                                 'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', gen_random_uuid(),
                                                 'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                                 'user_metadata', '{}'::jsonb, 'amr', '[]'::jsonb));
        v_j := portal_access_token_hook(v_ev);
        IF v_j IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'MES9C_PROOF|the hook changed the claims of %', a.email;
        END IF;
    END LOOP;

    -- ③ 门户角色的可达面:public 函数恰好十一支;能读的关系恰好 storage.objects;能写的只有 storage.objects 的 INSERT;作用于它的存储策略恰好三条;
    --    storage 架构只有 USAGE;仍不是任何角色的成员
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'MES9C_PROOF|supplier_portal executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY 1), '') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_schema_privilege('supplier_portal', n.oid, 'USAGE') AND has_table_privilege('supplier_portal', c.oid, 'SELECT');
    IF v_bad <> 'storage.objects' THEN RAISE EXCEPTION 'MES9C_PROOF|supplier_portal reads: %', v_bad; END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname || ':' || p.priv, ', ' ORDER BY 1), '') INTO v_bad
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_table_privilege('supplier_portal', c.oid, p.priv);
    IF v_bad <> 'storage.objects:INSERT' THEN RAISE EXCEPTION 'MES9C_PROOF|supplier_portal can write: %', v_bad; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE 'supplier_portal' = ANY (roles)) <> 3
       OR NOT has_schema_privilege('supplier_portal', 'storage', 'USAGE') OR has_schema_privilege('supplier_portal', 'storage', 'CREATE')
       OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = 'supplier_portal'::regrole) THEN
        RAISE EXCEPTION 'MES9C_PROOF|supplier_portal: three policies, USAGE on storage only, a member of nothing';
    END IF;
    IF has_table_privilege('authenticated', 'public.portal_certificate_submissions', 'INSERT,UPDATE,DELETE,TRUNCATE')
       OR has_table_privilege('anon', 'public.portal_certificate_submissions', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
       OR NOT has_table_privilege('authenticated', 'public.portal_certificate_submissions', 'SELECT') THEN
        RAISE EXCEPTION 'MES9C_PROOF|portal_certificate_submissions grants: authenticated SELECT only, anon nothing';
    END IF;

    -- ④ 存储:策略 56 条,既有的 53 条逐字未变;桶 20 个,既有的 19 个逐字未变;存储对象一个字节不动(两张 COD 在内)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 56
       OR EXISTS (SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM mes9c_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage') THEN
        RAISE EXCEPTION 'MES9C_PROOF|storage policies: expected the 53 unchanged plus three';
    END IF;
    IF (SELECT count(*) FROM storage.buckets) <> 20
       OR EXISTS (SELECT id, name, public, file_size_limit, mimes FROM mes9c_buckets_before
                  EXCEPT SELECT id, name, public, file_size_limit, allowed_mime_types::text FROM storage.buckets)
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'portal-uploads' AND NOT public AND file_size_limit = 10485760
                       AND allowed_mime_types = ARRAY['application/pdf', 'image/jpeg', 'image/png']) THEN
        RAISE EXCEPTION 'MES9C_PROOF|buckets: expected the 19 unchanged plus a private portal-uploads (10 MB · PDF / JPEG / PNG)';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM mes9c_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM mes9c_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'MES9C_PROOF|a stored object changed';
    END IF;

    -- ⑤ V39 是 Tim 的值;它的待补那一支是空的
    IF (SELECT portal_upload_max_bytes FROM account_settings WHERE id) IS DISTINCT FROM 10485760
       OR (SELECT portal_upload_types FROM account_settings WHERE id) IS DISTINCT FROM ARRAY['application/pdf', 'image/jpeg', 'image/png'] THEN
        RAISE EXCEPTION 'MES9C_PROOF|V39 is not 10 MB · PDF / JPEG / PNG';
    END IF;

    -- ⑥ 在途单据一张不少、一张不多;既有的行逐字未变;本事务一行变更记录都没写
    IF EXISTS ((SELECT b.k, b.id FROM mes9c_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes9c_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes9c_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes9c_pending_before b)) THEN
        RAISE EXCEPTION 'MES9C_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) IS DISTINCT FROM (SELECT suppliers FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM counterparty_contacts t ) IS DISTINCT FROM (SELECT counterparty_contacts FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_portal_users t ) IS DISTINCT FROM (SELECT supplier_portal_users FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'portal_upload_max_bytes' - 'portal_upload_types')::text, '|' ORDER BY (to_jsonb(t) - 'portal_upload_max_bytes' - 'portal_upload_types')::text), '')) FROM account_settings t ) IS DISTINCT FROM (SELECT account_settings FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_compliance t ) IS DISTINCT FROM (SELECT supplier_compliance FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_attachments t ) IS DISTINCT FROM (SELECT supplier_attachments FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificate_types t ) IS DISTINCT FROM (SELECT certificate_types FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t ) IS DISTINCT FROM (SELECT inbound_batches FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM purchase_orders t ) IS DISTINCT FROM (SELECT purchase_orders FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM po_issues t ) IS DISTINCT FROM (SELECT po_issues FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM certificates_of_destruction t ) IS DISTINCT FROM (SELECT certificates_of_destruction FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statements t ) IS DISTINCT FROM (SELECT supplier_statements FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM supplier_statement_issues t ) IS DISTINCT FROM (SELECT supplier_statement_issues FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM portal_document_downloads t ) IS DISTINCT FROM (SELECT portal_document_downloads FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) IS DISTINCT FROM (SELECT permissions FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) IS DISTINCT FROM (SELECT role_permissions FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM floor_board_settings t ) IS DISTINCT FROM (SELECT floor_board_settings FROM mes9c_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t ) IS DISTINCT FROM (SELECT document_types FROM mes9c_rows_before) THEN
        RAISE EXCEPTION 'MES9C_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes9c_log_before), 0) AND c.txid = txid_current()) THEN
        RAISE EXCEPTION 'MES9C_PROOF|this migration wrote change_log rows';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9C_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:325 张表;变更记录覆盖零缺口、豁免 9、新表被记录;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'MES9C_PROOF|expected 325 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9
       OR EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = 'portal_certificate_submissions') THEN
        RAISE EXCEPTION 'MES9C_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'MES9C_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES9C_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑧ 匿名面不变;五支门户函数 authenticated · anon 都调不到;两支员工函数门户 · anon 调不到;change_log_rows 只有新签名那一支
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES9C_PROOF|anon executes: %', v_bad;
    END IF;
    FOREACH k IN ARRAY ARRAY['public.portal_certificates()', 'public.portal_submission_begin(text, text, text, bigint, text, date, date)', 'public.portal_submission_finish(uuid)', 'public.portal_submission_abandon(uuid)', 'public.portal_can_upload_object(text, text)'] LOOP
        IF has_function_privilege('authenticated', k::regprocedure, 'EXECUTE') OR has_function_privilege('anon', k::regprocedure, 'EXECUTE')
           OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = k::regprocedure) THEN
            RAISE EXCEPTION 'MES9C_PROOF|%: expected SECURITY DEFINER, executable by supplier_portal only', k;
        END IF;
    END LOOP;
    FOREACH k IN ARRAY ARRAY['public.portal_submission_accept(uuid, text, text, text, date, date)', 'public.portal_submission_reject(uuid, text)'] LOOP
        IF has_function_privilege('supplier_portal', k::regprocedure, 'EXECUTE') OR has_function_privilege('anon', k::regprocedure, 'EXECUTE')
           OR NOT has_function_privilege('authenticated', k::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'MES9C_PROOF|%: expected executable by authenticated, not by the portal or anon', k;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'change_log_rows') <> 1
       OR to_regprocedure('public.change_log_rows(date,date,text,text,uuid,boolean,bigint,integer,text[],boolean,boolean,text[],bigint,integer)') IS NULL THEN
        RAISE EXCEPTION 'MES9C_PROOF|change_log_rows: expected exactly the fourteen-argument signature';
    END IF;

    -- ⑨ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes9c_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES9C pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes9c_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES9C_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes9c_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;

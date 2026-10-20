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

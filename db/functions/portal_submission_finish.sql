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

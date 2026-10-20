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

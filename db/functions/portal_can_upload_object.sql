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

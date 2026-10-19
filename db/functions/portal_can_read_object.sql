-- db/functions/portal_can_read_object.sql
-- MES-9b(2026-10-19,MES-9 Step 0 §3 · Q14 · Q22 · Q27,Tim):【存储策略的判据】—— 一个门户会话能不能读桶里的这一个对象。
--   storage.objects 上那条 TO supplier_portal 的 SELECT 策略只调它(db/storage/buckets-and-policies.sql)。
--   成立 = 这是一个有效的门户会话(portal_require_link 不拒)并且【这位门户账号在两分钟内为这一个对象写下过一行下载记录】
--   (portal_document_open 写的那一行 —— 它只为调用者自己那一家的、没作废的签发档写)。
--   ★ 为什么要求那一行,而不只是"这是自己那一家的档案":门户会话的令牌够得着 Storage API;只认"自己的",它就能绕过路由直接取字节,
--     下载记录(Q22)就有了漏网的那一份。要求【先有一行】,每一次取字节前面就都有一行 —— 记录完整是机制,不是约定。
--   【绝不抛】在 RLS 里抛会把一次读变成一次 500;这里任何一步不成立都回 false(于是存储那一侧是"没有这个对象")。
--   拒的理由由 portal_document_open 自己按名说(撤销 · 会话结束 · 不是自己的 · 作废)。
--   EXECUTE 只授 supplier_portal(策略以调用者身份求值;zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.
CREATE OR REPLACE FUNCTION public.portal_can_read_object(p_bucket text, p_name text)
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
    RETURN EXISTS (SELECT 1 FROM portal_document_downloads d
                    WHERE d.portal_user_id = v_link AND d.bucket_id = p_bucket AND d.file_path = p_name
                      AND d.downloaded_at > now() - interval '2 minutes');
END;
$function$;

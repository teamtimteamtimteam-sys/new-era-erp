-- db/functions/guard_portal_document_download_append_only.sql
-- MES-9b(2026-10-19,MES-9 Step 0 Q22,Tim):门户下载记录【只追加】。一行写下就是"那一刻,这位门户账号要走了这一份签发档"的事实 ——
--   改一个字、删一行,它就不再证明任何事。UPDATE 拒(行级);DELETE / TRUNCATE 拒(【语句级】—— 没有 DELETE 策略时员工的 DELETE 在 RLS 那里
--   就是零行,行级触发器不会醒,U1-B 的那一课)。PORTAL_DOWNLOAD_LOG_APPEND_ONLY|<操作>。
--   写只经 portal_document_open()(SECURITY DEFINER,门户会话自己的那一行);它也是变更记录的第九张豁免(本身就是一份只追加的日志)。
--
-- NOTE: introduced by db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql.

CREATE OR REPLACE FUNCTION public.guard_portal_document_download_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'PORTAL_DOWNLOAD_LOG_APPEND_ONLY|%', lower(TG_OP);
END;
$function$;

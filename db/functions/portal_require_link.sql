-- db/functions/portal_require_link.sql
-- MES-9a(2026-10-19,MES-0 Q85 · MES-9 Step 0 Q8 · Q11,Tim):【每一支门户函数的第一句】—— 这个会话是不是一个还有效的门户会话。
--   依次判,第一条不过就按名拒:
--     ① 数据库角色是 supplier_portal(PostgREST 按令牌切过来的那个;`role` 这个设置在 SECURITY DEFINER 里不变),
--        并且令牌自己的 role 声明也是它 → 否则 PORTAL_ROLE_REQUIRED。hook 被关掉时门户账号拿到的是 authenticated:
--        门户于是看得见地停下,而不是悄悄变宽(Q11)。(authenticated 本来就调不到任何一支 portal_*,这一条是第二道。)
--     ② auth.uid() 有一条门户链接 → 否则 PORTAL_NOT_A_PORTAL_ACCOUNT;
--     ③ 链接没有撤销、账号没有被封 → 否则 PORTAL_ACCESS_REVOKED(Q85:一个被封的号手里的令牌还能用到过期,所以每一次调用都问);
--     ④ 令牌的 session_id 还在 auth.sessions 里 → 否则 PORTAL_SESSION_ENDED(Q8:撤销时删掉它的会话 = 全局登出,下一次调用就拒)。
--   返回链接的 id。【没有任何参数】—— 供应商从来不是一个参数,只从 auth.uid() 推出来(Step 0 §3)。
--   EXECUTE 不授任何人:只由 portal_* 在它们自己的 DEFINER 体内调用。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_require_link()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_uid  uuid := auth.uid();
    v_sid  uuid;
    v_link uuid;
    v_rev  timestamptz;
BEGIN
    IF COALESCE(current_setting('role', true), '') <> 'supplier_portal'
       OR COALESCE(auth.jwt() ->> 'role', '') <> 'supplier_portal' THEN
        RAISE EXCEPTION 'PORTAL_ROLE_REQUIRED';
    END IF;
    SELECT p.id, p.revoked_at INTO v_link, v_rev FROM supplier_portal_users p WHERE p.user_id = v_uid;
    IF v_link IS NULL THEN
        RAISE EXCEPTION 'PORTAL_NOT_A_PORTAL_ACCOUNT';
    END IF;
    IF v_rev IS NOT NULL
       OR EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.banned_until IS NOT NULL AND u.banned_until > now()) THEN
        RAISE EXCEPTION 'PORTAL_ACCESS_REVOKED';
    END IF;
    BEGIN
        v_sid := NULLIF(auth.jwt() ->> 'session_id', '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
        v_sid := NULL;
    END;
    IF v_sid IS NULL OR NOT EXISTS (SELECT 1 FROM auth.sessions s WHERE s.id = v_sid AND s.user_id = v_uid) THEN
        RAISE EXCEPTION 'PORTAL_SESSION_ENDED';
    END IF;
    RETURN v_link;
END;
$function$;

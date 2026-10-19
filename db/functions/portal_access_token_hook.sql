-- db/functions/portal_access_token_hook.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q2 · Q11,Tim):Supabase 的 custom access token hook —— 【一个门户账号的令牌带 role = supplier_portal】。
--   Supabase Auth 在【每一次】签发令牌(登录、刷新)时以 supabase_auth_admin 的身份调它,传入 {user_id, claims, authentication_method},
--   用它返回的 claims 签令牌;PostgREST 再按令牌里的 role 切换数据库角色(supplier_portal 由 authenticator 持有,迁移里授)。
--
-- 【员工的令牌一个字节都不变 —— 这是本函数的第一条义务】(委托书「Sign-in safety」)
--   · 不是门户账号 → 原样返回 event(claims 逐字不动);
--   · 函数里【任何】失败(user_id 不是 uuid、读不到表、权限没授上……)→ 同样原样返回 event —— 绝不抛:
--     一支抛错的 hook 让【每一个人】都登录不了、刷新不了(AUTH-BLAST-RADIUS 的形状)。
--     代价照直写:失败时一个门户账号拿到的是 role = authenticated 的令牌 —— 它于是是一个【没有角色的会话】
--     (门户账号不许持角色、不许是员工 —— guard_portal_account_separation),只够得着判词七的基线;
--     而每一支 portal_* 只授 supplier_portal,authenticated 调不到(42501),门户于是【看得见地停下】,不会悄悄变宽(Q11);
--     中间件看见一个门户账号拿着不是 supplier_portal 的令牌,会把它登出。
--   · 查表只有一次按唯一索引的查询(supplier_portal_users.user_id UNIQUE)。
-- 【撤销了的门户账号也拿 supplier_portal】撤销 = 链接撤销 + 封禁 + 删会话(portal_user_revoke),所以它本来就拿不到新令牌;
--   万一拿到了(封禁失败的那一瞬),它仍然被关在门户角色里,而门户函数按"已撤销"拒绝 —— 而不是被放成一个员工那一面的无角色会话。
-- 【调用者权限,不是 DEFINER】Supabase 的做法:EXECUTE 只授 supabase_auth_admin,它对 supplier_portal_users 有一条只读策略与 SELECT。
--   authenticated / anon / PUBLIC 都调不到(zzz_function_grants.sql)。
-- 【怎么关掉它 —— 一步】Supabase 项目设置 Authentication → Hooks → "Customize Access Token (JWT) Claims hook" 关掉,
--   或 Management API PATCH /v1/projects/<ref>/config/auth {"hook_custom_access_token_enabled": false}。见 docs/fresh-install-checklist.md。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.portal_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_portal boolean := false;
BEGIN
    BEGIN
        SELECT true INTO v_portal
          FROM public.supplier_portal_users p
         WHERE p.user_id = (event ->> 'user_id')::uuid;
        IF v_portal IS TRUE AND jsonb_typeof(event -> 'claims') = 'object' THEN
            RETURN jsonb_set(event, '{claims,role}', to_jsonb('supplier_portal'::text));
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN event;
    END;
    RETURN event;
END;
$function$;

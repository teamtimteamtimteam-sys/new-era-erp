-- db/platform-prelude.sql
-- 【照镜像重建一个库时,必须先跑这个文件】
--
-- OPS-1 第一次真的做了这个实验:开一个【全新的空库】,只用 db/functions + db/tables +
-- db/views 重放一遍。结论是 —— 镜像【重建不出来】,连着撞三堵墙,每一堵都是从没写下来过的:
--
--   1. 镜像文件不是能直接 psql -f 的。pg_get_functiondef 的输出【不带结尾分号】,
--      多函数文件里下一条 CREATE 会被吞进上一条,报语法错。补分号那一行代码此前
--      只存在于 check_mirrors.py 的 rewrite() 里:
--          sed -E 's/^\$function\$$/$function$;/'
--   2. 镜像依赖 Supabase 平台提供的东西,而这些东西【不在本仓库里】:
--      auth.uid() 出现 134 处(每一个 created_by/updated_by 默认值、每一条自助策略),
--      auth.users 被 suppliers / supplier_compliance 外键引用、被 user_directory 读取,
--      角色 authenticated(270 处 GRANT)/ anon(20 处 REVOKE)。
--   3. 遮蔽机制依赖【默认权限】。镜像里的 "REVOKE SELECT …; GRANT SELECT (列…)" 是在
--      【收窄】一个已经存在的整表授权 —— 那个授权由 ALTER DEFAULT PRIVILEGES 在建表当下
--      自动给出。少了它,被遮蔽的表最后是【一个授权都没有】,而不是收窄后的那一组。
--
-- 所以完整的重建过程是:
--     psql "$DSN" -f db/platform-prelude.sql
--     for f in db/functions/*.sql; do sed -E 's/^\$function\$$/$function$;/' "$f"; done | psql "$DSN"   # 先 SET check_function_bodies = off
--     db/tables/*.sql   按 FK / 跨表触发器拓扑序(check_mirrors.py 的 toposort 就是那份顺序)
--     db/views/*.sql    按视图间引用排序
-- 实测:84 个函数 + 72 张表 + 38 个视图全部建起,与线上【结构完全一致】(列、类型、
-- 默认值、生成列、约束、索引、触发器、RLS、策略、表级与列级 GRANT、序列、注释),
-- 安装种子逐行一致,启动后有完整的权限目录(33 个码)与一个拿着全部权限的 admin。
--
-- 【本文件是幂等的】CREATE ... IF NOT EXISTS + 建角色的 DO 块 —— 重建体检
-- (db/verify_rebuild.py)会反复跑它,而全新安装只跑一次;两种用法都得成立。
--
-- WARNING 【绝不要对着真实的 Supabase 项目跑这个文件】不是多余,是【会直接报错】:
--    auth 架构归 supabase_auth_admin 所有,连接用的 postgres 角色对它没有 CREATE 权限,
--    CREATE TABLE IF NOT EXISTS auth.users 会以 permission denied for schema auth 失败。
--    (OPS-2 走安装清单时实测到的。)db/verify_rebuild.py 会自己认出目标是不是真项目并跳过本文件。
--
-- 【线上不需要跑这个文件】Supabase 已经把这些都准备好了。它是给"从零重建"用的,
-- 也是把那份一直没写下来的依赖清单落到纸面上。
-- 1. Platform roles. 270 GRANT ... TO authenticated + 20 REVOKE ... FROM authenticated, anon.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

-- 2. The auth schema. auth.uid() appears in 134 places (every created_by/updated_by default
--    and every self-service RLS predicate); auth.users is FK'd from suppliers and
--    supplier_compliance and read by the user_directory view.
CREATE SCHEMA IF NOT EXISTS auth;

CREATE TABLE IF NOT EXISTS auth.users (
    id                uuid PRIMARY KEY,
    email             character varying,
    created_at        timestamptz,
    last_sign_in_at   timestamptz
);

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim.sub', true), ''),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    NULLIF(current_setting('request.jwt.claim', true), ''),
    NULLIF(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

GRANT USAGE ON SCHEMA auth TO authenticated, anon, service_role;
GRANT USAGE ON SCHEMA public TO authenticated, anon, service_role;

-- 3. Supabase's default privileges on schema public. Every table/sequence/function created
--    in public is granted to anon/authenticated/service_role AT CREATE TIME by these.
--    Verified against live pg_default_acl: {anon=arwdDxtm, authenticated=arwdDxtm,
--    service_role=arwdDxtm} for tables. The mirrors' REVOKE/GRANT column lists then
--    narrow this down — which only works if the blanket grant existed first.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;

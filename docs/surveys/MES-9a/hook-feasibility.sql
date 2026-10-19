-- MES-9a · the first act (Q2): a rolled-back live feasibility dry run of the supplier_portal role and the access-token hook.
-- Runs as postgres over the pooler, BEGIN … ROLLBACK; creates a role, a grant and a function inside the transaction only.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL statement_timeout = '60s';
SELECT 'WHO|' || current_user || '|createrole=' || (SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user)
       || '|super=' || (SELECT rolsuper FROM pg_roles WHERE rolname = current_user);
SELECT 'ROLE|' || rolname || '|login=' || rolcanlogin || '|bypassrls=' || rolbypassrls || '|inherit=' || rolinherit
  FROM pg_roles WHERE rolname IN ('authenticator', 'supabase_auth_admin', 'authenticated', 'anon', 'supplier_portal') ORDER BY 1;
SELECT 'AUTHENTICATOR_MEMBER_OF|' || string_agg(r.rolname, ',' ORDER BY r.rolname)
  FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid WHERE m.member = 'authenticator'::regrole;
SELECT 'SCHEMA_PUBLIC_USAGE|' || nspname || '|public_usage=' || has_schema_privilege('public', oid, 'USAGE')
  FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema' ORDER BY nspname;
SELECT 'SESSIONS_COLS|' || string_agg(column_name || ':' || data_type, ',' ORDER BY ordinal_position)
  FROM information_schema.columns WHERE table_schema = 'auth' AND table_name = 'sessions';
SELECT 'AUTH_ADMIN_PUBLIC_USAGE|' || has_schema_privilege('supabase_auth_admin', 'public', 'USAGE');

CREATE ROLE supplier_portal NOLOGIN NOINHERIT;
GRANT supplier_portal TO authenticator;
GRANT USAGE ON SCHEMA public TO supplier_portal;
SELECT 'AFTER_GRANT|authenticator member of supplier_portal=' || pg_has_role('authenticator', 'supplier_portal', 'MEMBER');

CREATE FUNCTION public.zz_mes9a_feasibility_hook(event jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE AS $f$
DECLARE c jsonb := event -> 'claims';
BEGIN
    IF (event ->> 'user_id') = '00000000-0000-4000-8000-0000000009a1' THEN
        c := jsonb_set(c, '{role}', '"supplier_portal"');
        RETURN jsonb_build_object('claims', c);
    END IF;
    RETURN event;
EXCEPTION WHEN OTHERS THEN
    RETURN event;
END $f$;
SELECT 'HOOK_STAFF|' || (public.zz_mes9a_feasibility_hook(jsonb_build_object('user_id', '11111111-1111-4111-8111-111111111111',
        'claims', jsonb_build_object('sub', '11111111-1111-4111-8111-111111111111', 'role', 'authenticated', 'aal', 'aal1')))
        -> 'claims' ->> 'role');
SELECT 'HOOK_PORTAL|' || (public.zz_mes9a_feasibility_hook(jsonb_build_object('user_id', '00000000-0000-4000-8000-0000000009a1',
        'claims', jsonb_build_object('sub', '00000000-0000-4000-8000-0000000009a1', 'role', 'authenticated', 'aal', 'aal1')))
        -> 'claims' ->> 'role');
GRANT EXECUTE ON FUNCTION public.zz_mes9a_feasibility_hook(jsonb) TO supabase_auth_admin;
SELECT 'HOOK_AUTH_ADMIN_EXECUTE|' || has_function_privilege('supabase_auth_admin', 'public.zz_mes9a_feasibility_hook(jsonb)', 'EXECUTE');
-- (postgres may not SET ROLE supabase_auth_admin on Supabase — measured: permission denied — so the grant is read from the catalog)

-- what the bare role reaches: relations / functions it may use (schema USAGE AND object privilege)
SET LOCAL ROLE supplier_portal;
SELECT 'AS_PORTAL|current_user=' || current_user || '|role_guc=' || current_setting('role');
RESET ROLE;
SELECT 'PORTAL_REL|' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%'
   AND has_schema_privilege('supplier_portal', n.oid, 'USAGE')
   AND c.relkind IN ('r', 'v', 'm', 'p', 'f', 'S')
   AND (has_table_privilege('supplier_portal', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
        OR has_any_column_privilege('supplier_portal', c.oid, 'SELECT,INSERT,UPDATE,REFERENCES'));
SELECT 'PORTAL_FN|' || n.nspname || '|' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND has_schema_privilege('supplier_portal', n.oid, 'USAGE')
   AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE') GROUP BY n.nspname ORDER BY 1;
SELECT 'PORTAL_SCHEMAS|' || string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace
 WHERE has_schema_privilege('supplier_portal', oid, 'USAGE');
ROLLBACK;
SELECT 'AFTER_ROLLBACK|role exists=' || EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal');

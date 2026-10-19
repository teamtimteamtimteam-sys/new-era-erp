-- MES-9 Step 0 — what a supplier session would reach today if it were an ordinary `authenticated` user (read-only, as postgres, rolbypassrls = true,
-- catalog + base tables; BEGIN READ ONLY … ROLLBACK). Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/MES-9/live-readings.sql
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- 1 · tables
SELECT 'TABLES|' || count(*) || '|rls_on=' || count(*) FILTER (WHERE c.relrowsecurity) || '|rls_off=' || count(*) FILTER (WHERE NOT c.relrowsecurity)
    || '|auth_select_grant=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'SELECT'))
    || '|auth_select_grant_rls_off=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'SELECT') AND NOT c.relrowsecurity)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'r';
SELECT 'RLS_OFF_READABLE|' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity AND has_table_privilege('authenticated', c.oid, 'SELECT') ORDER BY 1;
-- 2 · policies whose USING is literally true for authenticated (or PUBLIC)
SELECT 'TRUE_POLICIES|' || count(*) || '|tables=' || count(DISTINCT tablename) FROM pg_policies
 WHERE schemaname = 'public' AND cmd IN ('SELECT', 'ALL') AND btrim(qual) = 'true' AND (roles && ARRAY['authenticated', 'public']::name[]);
SELECT 'TRUE_POLICY|' || tablename || '|' || policyname || '|' || cmd || '|' || array_to_string(roles, ',') FROM pg_policies
 WHERE schemaname = 'public' AND cmd IN ('SELECT', 'ALL') AND btrim(qual) = 'true' AND (roles && ARRAY['authenticated', 'public']::name[]) ORDER BY 1;
-- policies that let a reader with NO permission code through on some other condition (auth.uid() / current_user_employee()) — rows of his own
SELECT 'SELF_POLICY|' || tablename || '|' || policyname || '|' || left(regexp_replace(qual, '\s+', ' ', 'g'), 140) FROM pg_policies
 WHERE schemaname = 'public' AND cmd IN ('SELECT', 'ALL') AND (qual ~ 'auth\.uid\(\)' OR qual ~ 'current_user_employee\(\)') ORDER BY 1;
-- 3 · views readable by authenticated, and owner-rights views whose body asks no has_permission
SELECT 'VIEWS|' || count(*) || '|auth_readable=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'SELECT'))
    || '|invoker=' || count(*) FILTER (WHERE COALESCE(c.reloptions::text, '') ~ 'security_invoker=(on|true)')
    || '|owner_rights_readable_no_predicate=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'SELECT')
          AND COALESCE(c.reloptions::text, '') !~ 'security_invoker=(on|true)'
          AND pg_get_viewdef(c.oid) !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|auth\.uid|current_user_employee)')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v';
SELECT 'OWNER_VIEW_NO_PREDICATE|' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind = 'v' AND has_table_privilege('authenticated', c.oid, 'SELECT')
   AND COALESCE(c.reloptions::text, '') !~ 'security_invoker=(on|true)'
   AND pg_get_viewdef(c.oid) !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|auth\.uid|current_user_employee)' ORDER BY 1;
-- 4 · functions
SELECT 'FUNCS|' || count(*) || '|auth_exec=' || count(*) FILTER (WHERE has_function_privilege('authenticated', p.oid, 'EXECUTE'))
    || '|anon_exec=' || count(*) FILTER (WHERE has_function_privilege('anon', p.oid, 'EXECUTE'))
    || '|definer_auth_exec=' || count(*) FILTER (WHERE p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE'))
    || '|definer_auth_exec_no_check=' || count(*) FILTER (WHERE p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
          AND p.prosrc !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|auth\.uid|current_user_employee|require_)')
    || '|invoker_auth_exec=' || count(*) FILTER (WHERE NOT p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE'))
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.prokind = 'f';
SELECT 'DEFINER_NO_CHECK|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || pg_get_function_result(p.oid) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
   AND p.prosrc !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|auth\.uid|current_user_employee|require_)'
   AND pg_get_function_result(p.oid) <> 'trigger' ORDER BY 1;
-- 5 · storage: buckets and the policies on storage.objects
SELECT 'BUCKET|' || id || '|public=' || public || '|objects=' || (SELECT count(*) FROM storage.objects o WHERE o.bucket_id = b.id) FROM storage.buckets b ORDER BY 1;
SELECT 'STORAGE_POLICY|' || policyname || '|' || cmd || '|' || array_to_string(roles, ',') || '|' || left(regexp_replace(COALESCE(qual, with_check), '\s+', ' ', 'g'), 160)
  FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects' ORDER BY 1;
-- 6 · other doors
SELECT 'SCHEMAS_AUTH_USAGE|' || string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE has_schema_privilege('authenticated', oid, 'USAGE') AND nspname NOT LIKE 'pg_%';
SELECT 'REALTIME_PUBLICATION_TABLES|' || count(*) FROM pg_publication_tables WHERE pubname = 'supabase_realtime';
SELECT 'GRAPHQL_EXT|' || COALESCE((SELECT extversion FROM pg_extension WHERE extname = 'pg_graphql'), 'absent');
SELECT 'ROLES_PG|' || string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles WHERE rolname IN ('anon', 'authenticated', 'service_role', 'authenticator', 'supabase_auth_admin');
SELECT 'AUTHENTICATOR_MEMBER_OF|' || string_agg(r.rolname, ',' ORDER BY r.rolname) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member WHERE u.rolname = 'authenticator';
SELECT 'POSTGRES_ROLE|createrole=' || rolcreaterole || '|super=' || rolsuper FROM pg_roles WHERE rolname = current_user;
SELECT 'AUTH_HOOK_FUNCS|' || COALESCE(string_agg(n.nspname || '.' || p.proname, ','), 'none') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.proname ILIKE '%access_token%hook%';
-- 7 · supplier-side data volume (test data) and contacts
SELECT 'SUPPLIERS|' || count(*) || '|approved=' || count(*) FILTER (WHERE status = 'approved') FROM suppliers;
SELECT 'CONTACTS|' || count(*) || '|supplier=' || count(*) FILTER (WHERE supplier_id IS NOT NULL) || '|with_email=' || count(*) FILTER (WHERE supplier_id IS NOT NULL AND email IS NOT NULL) FROM counterparty_contacts;
SELECT 'PER_SUPPLIER|pos=' || (SELECT count(*) FROM purchase_orders) || '|receipts=' || (SELECT count(*) FROM inbound_batches WHERE supplier_id IS NOT NULL)
    || '|cods=' || (SELECT count(*) FROM certificates_of_destruction) || '|statements=' || (SELECT count(*) FROM supplier_statements)
    || '|disputes=' || (SELECT count(*) FROM assay_disputes) || '|tickets=' || (SELECT count(*) FROM weighbridge_tickets)
    || '|compliance=' || (SELECT count(*) FROM supplier_compliance) || '|reviews=' || (SELECT count(*) FROM supplier_scorecard_reviews);
SELECT 'CHANGELOG_EXCLUSIONS|' || (change_log_coverage_gaps() ->> 'excluded');
SELECT 'PENDING_ARMS|' || (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g'));
SELECT 'DOC_TYPES|' || count(*) FROM document_types;
ROLLBACK;
-- 8 · what a NEW Postgres role would inherit through PUBLIC alone (the deciding fact for a separate portal role)
BEGIN READ ONLY;
SELECT 'PUBLIC_FUNC_EXEC|' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE'));
SELECT 'PUBLIC_REL_SELECT|' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname IN ('public', 'storage') AND c.relkind IN ('r', 'v', 'm') AND EXISTS (SELECT 1 FROM aclexplode(c.relacl) a WHERE a.grantee = 0);
SELECT 'PUBLIC_SCHEMA_USAGE|' || string_agg(nspname, ',') FROM pg_namespace n WHERE EXISTS (SELECT 1 FROM aclexplode(n.nspacl) a WHERE a.grantee = 0 AND a.privilege_type = 'USAGE');
SELECT 'DEFAULT_ACL|' || pg_get_userbyid(d.defaclrole) || '|' || n.nspname || '|' || d.defaclobjtype::text || '|' || array_to_string(d.defaclacl, ' ')
  FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace WHERE n.nspname IN ('public', 'storage') OR d.defaclnamespace = 0 ORDER BY 1;
SELECT 'STORAGE_OBJECTS_GRANTS|' || array_to_string(c.relacl, ' ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'storage' AND c.relname = 'objects';
ROLLBACK;

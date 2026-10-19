-- NOROLE-SURFACE Step 0 — what a signed-in session holding NO role reaches today, ENUMERATED (not sampled). Read-only: BEGIN READ ONLY … ROLLBACK.
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/NOROLE-SURFACE/norole-reach-readings.sql 2>&1
-- Part 1 is the catalog (as postgres, rolbypassrls = true). Part 2 reads EVERY relation authenticated may SELECT, twice: as postgres (the total) and as
-- `authenticated` with the JWT of a random uuid that has no auth.users row, no user_roles, no employee (RLS applies), one savepoint per relation.
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
-- 1a · buckets
SELECT 'BUCKET|' || b.id || '|public=' || b.public || '|limit=' || COALESCE(b.file_size_limit::text, '-') || '|mime=' || COALESCE(array_to_string(b.allowed_mime_types, ','), '-')
    || '|objects=' || (SELECT count(*) FROM storage.objects o WHERE o.bucket_id = b.id) FROM storage.buckets b ORDER BY 1;
-- 1b · every storage.objects policy, full text
SELECT 'SPOL|' || policyname || '|' || cmd || '|' || array_to_string(roles, ',') || '|Q=' || COALESCE(regexp_replace(qual, '\s+', ' ', 'g'), '-')
    || '|C=' || COALESCE(regexp_replace(with_check, '\s+', ' ', 'g'), '-') FROM pg_policies WHERE schemaname = 'storage' ORDER BY 1;
SELECT 'STORAGE_GRANTS|' || c.relname || '|' || array_to_string(c.relacl, ' ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'storage' AND c.relname IN ('objects', 'buckets') ORDER BY 1;
-- 1c · tables: write privileges and whether ANY policy for that command lacks a permission predicate (a no-role door)
SELECT 'TBL_WRITE_DOOR|' || p.tablename || '|' || p.policyname || '|' || p.cmd || '|Q=' || COALESCE(regexp_replace(p.qual, '\s+', ' ', 'g'), '-')
    || '|C=' || COALESCE(regexp_replace(p.with_check, '\s+', ' ', 'g'), '-')
  FROM pg_policies p WHERE p.schemaname = 'public' AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL') AND (p.roles && ARRAY['authenticated', 'public']::name[])
   AND (COALESCE(p.qual, '') || COALESCE(p.with_check, '') !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|arm_permission)'
        OR COALESCE(p.qual, '') || COALESCE(p.with_check, '') ~* '\sOR\s') ORDER BY 1;
SELECT 'TBL_RLS_OFF|' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity ORDER BY 1;
SELECT 'TBL_COUNTS|tables=' || count(*) || '|auth_select=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'SELECT'))
    || '|auth_insert=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'INSERT'))
    || '|auth_update=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'UPDATE'))
    || '|auth_delete=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'DELETE'))
    || '|auth_truncate=' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'TRUNCATE'))
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');
-- policies whose permission predicate is OR-ed with something else (a self / relation branch a no-role session may pass)
SELECT 'OR_BRANCH|' || tablename || '|' || policyname || '|' || cmd || '|' || left(regexp_replace(COALESCE(qual, with_check), '\s+', ' ', 'g'), 220)
  FROM pg_policies WHERE schemaname = 'public' AND COALESCE(qual, '') || COALESCE(with_check, '') ~ '(has_permission|has_any_permission)'
   AND COALESCE(qual, '') || COALESCE(with_check, '') ~* '\sOR\s' ORDER BY 1;
-- 1d · sequences
SELECT 'SEQ|auth_usage=' || count(*) FILTER (WHERE has_sequence_privilege('authenticated', c.oid, 'USAGE'))
    || '|auth_update=' || count(*) FILTER (WHERE has_sequence_privilege('authenticated', c.oid, 'UPDATE')) || '|of=' || count(*)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'S';
-- 1e · functions: every non-trigger function authenticated may EXECUTE, classified
SELECT 'FN_CLASS|' || cls || '|' || count(*) FROM (
  SELECT CASE WHEN NOT p.prosecdef THEN 'invoker'
              WHEN p.prosrc ~ '(has_permission|has_any_permission|require_permission|current_user_permissions|require_[a-z_]+\()' THEN 'definer_permission_check'
              WHEN p.prosrc ~ '(auth\.uid|current_user_employee)' THEN 'definer_self_only'
              ELSE 'definer_no_check' END AS cls
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind = 'f' AND pg_get_function_result(p.oid) <> 'trigger'
     AND has_function_privilege('authenticated', p.oid, 'EXECUTE')) x GROUP BY cls ORDER BY 1;
SELECT 'FN_DEFINER_NO_CHECK|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || pg_get_function_result(p.oid) || '|vol=' || p.provolatile::text
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef AND pg_get_function_result(p.oid) <> 'trigger' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
   AND p.prosrc !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|require_[a-z_]+\(|auth\.uid|current_user_employee)' ORDER BY 1;
SELECT 'FN_DEFINER_SELF_ONLY|' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')|' || pg_get_function_result(p.oid)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef AND pg_get_function_result(p.oid) <> 'trigger' AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
   AND p.prosrc !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|require_[a-z_]+\()' AND p.prosrc ~ '(auth\.uid|current_user_employee)' ORDER BY 1;
-- 1f · views readable by authenticated, by class
SELECT 'VIEW_CLASS|' || cls || '|' || count(*) FROM (
  SELECT CASE WHEN COALESCE(c.reloptions::text, '') ~ 'security_invoker=(on|true)' THEN 'invoker'
              WHEN pg_get_viewdef(c.oid) ~ '(has_permission|has_any_permission|require_permission|current_user_permissions)' THEN 'owner_permission_predicate'
              WHEN pg_get_viewdef(c.oid) ~ '(auth\.uid|current_user_employee)' THEN 'owner_self_only'
              ELSE 'owner_no_predicate' END AS cls
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')
     AND has_table_privilege('authenticated', c.oid, 'SELECT')) x GROUP BY cls ORDER BY 1;
SELECT 'VIEW_OWNER_NO_PREDICATE|' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm') AND has_table_privilege('authenticated', c.oid, 'SELECT')
   AND COALESCE(c.reloptions::text, '') !~ 'security_invoker=(on|true)'
   AND pg_get_viewdef(c.oid) !~ '(has_permission|has_any_permission|require_permission|current_user_permissions|auth\.uid|current_user_employee)' ORDER BY 1;
SELECT 'APPROVAL_LOG_READABLE|' || regexp_replace(pg_get_functiondef('public.approval_log_readable(text)'::regprocedure), '\s+', ' ', 'g');
-- 1g · other schemas reachable
SELECT 'SCHEMA_USAGE|' || string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE has_schema_privilege('authenticated', oid, 'USAGE') AND nspname NOT LIKE 'pg_%';
SELECT 'OTHER_SCHEMA_REL|' || n.nspname || '|' || count(*) FILTER (WHERE has_table_privilege('authenticated', c.oid, 'SELECT')) || '|of=' || count(*)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname NOT IN ('public', 'pg_catalog', 'information_schema', 'pg_toast') AND c.relkind IN ('r', 'v', 'm', 'p')
   AND has_schema_privilege('authenticated', n.oid, 'USAGE') GROUP BY n.nspname ORDER BY 1;
SELECT 'OTHER_SCHEMA_FN|' || n.nspname || '|' || count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname NOT IN ('public', 'pg_catalog', 'information_schema') AND has_schema_privilege('authenticated', n.oid, 'USAGE')
   AND has_function_privilege('authenticated', p.oid, 'EXECUTE') GROUP BY n.nspname ORDER BY 1;
ROLLBACK;

-- Part 2 · every readable relation, total vs no-role
BEGIN READ ONLY;
DO $$
DECLARE r record; v_total bigint; v_nr bigint; v_err text; v_n int := 0; v_open int := 0;
BEGIN
  FOR r IN SELECT n.nspname, c.relname, c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('public', 'storage') AND c.relkind IN ('r', 'v', 'm', 'p')
              AND has_table_privilege('authenticated', c.oid, 'SELECT') ORDER BY 1, 2 LOOP
    v_n := v_n + 1; v_err := NULL; v_nr := NULL;
    -- the total: as postgres with NO claims (a view that asks has_permission is empty or raises for it — reported as such, not as a total)
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
      EXECUTE format('SELECT count(*) FROM %I.%I', r.nspname, r.relname) INTO v_total;
    EXCEPTION WHEN OTHERS THEN v_total := NULL;
    END;
    BEGIN
      PERFORM set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c0de","role":"authenticated"}', true);
      EXECUTE 'SET LOCAL ROLE authenticated';
      EXECUTE format('SELECT count(*) FROM %I.%I', r.nspname, r.relname) INTO v_nr;
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLSTATE || ':' || left(SQLERRM, 60); EXECUTE 'RESET ROLE';
    END;
    IF v_nr > 0 THEN v_open := v_open + 1; END IF;
    RAISE NOTICE 'REL|%.%|%|total=%|norole=%|err=%', r.nspname, r.relname, r.relkind, COALESCE(v_total::text, 'raises'), COALESCE(v_nr::text, '-'), COALESCE(v_err, '-');
  END LOOP;
  RAISE NOTICE 'REL_COVERAGE|examined=%|norole_nonzero=%', v_n, v_open;
  IF v_n < 200 THEN RAISE EXCEPTION 'REL_COVERAGE_TOO_LOW %', v_n; END IF;
END $$;
-- storage objects visible to the no-role session, per bucket
SELECT set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-00000000c0de","role":"authenticated"}', true);
SET LOCAL ROLE authenticated;
SELECT 'NOROLE_WHO|' || current_user || '|uid=' || auth.uid() || '|codes=' || COALESCE(array_length(current_user_permissions(), 1), 0) || '|emp=' || COALESCE(current_user_employee()::text, 'null');
SELECT 'NOROLE_OBJ|' || bucket_id || '|' || count(*) FROM storage.objects GROUP BY bucket_id ORDER BY 1;
SELECT 'NOROLE_BUCKETS_VISIBLE|' || count(*) FROM storage.buckets;
RESET ROLE;
ROLLBACK;

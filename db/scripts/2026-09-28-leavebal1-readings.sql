-- db/scripts/2026-09-28-leavebal1-readings.sql
-- LEAVE-BAL-1 · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 OVERTIME-1 那一支同形,换成本刀的对象:
-- 每一张请假单(逐行指纹 + 编号/状态/天数)、请假消耗、员工(除两列新名字之外的整行指纹)、两列新名字、
-- leave_requests 的授权与策略、本刀替换的六支函数的定义 md5 与 ACL、approval_log、分录、在途清单、勾稽、
-- 每个账号自己的码表。迁移之前不存在的列读成 absent,不报错。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】与目录(relkind 第一段自证);
--   第二部分:以 tim@(634c00f9…,cfo)的 JWT、SET LOCAL ROLE authenticated 读两张清单视图与勾稽;
--   第三部分:每一个真账号各自以自己的 JWT 读 current_user_permissions()。
-- 角色持有一律读【未撤销】的授权(ur.revoked_at IS NULL)。
\pset footer off
BEGIN;
SELECT '== part 1 · postgres · base tables' AS section;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('employees','leave_requests','leave_consumption','leave_grants','leave_types','approval_log',
                   'journal_entries','journal_lines','role_permissions','roles','user_roles','finance_settings','employees_masked');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold, locked_before, system_start_date FROM finance_settings;
-- 请假单:逐行指纹(整行,含 updated_at / decided_*)+ 每一张的编号、状态、天数
SELECT count(*) AS leave_requests, md5(string_agg(row(l.*)::text, ',' ORDER BY l.id)) AS leave_requests_md5 FROM leave_requests l;
SELECT code, status, leave_type_code, start_date, days, updated_at FROM leave_requests ORDER BY code;
SELECT count(*) AS leave_consumption, md5(COALESCE(string_agg(row(c.*)::text, ',' ORDER BY c.id), '')) AS consumption_md5
  FROM leave_consumption c;
SELECT count(*) AS leave_grants FROM leave_grants;
SELECT md5(string_agg(row(t.*)::text, ',' ORDER BY t.code)) AS leave_types_md5 FROM leave_types t;
-- 员工:除两列新名字之外的整行指纹(迁移前后可比);两列新名字(迁移前 absent)
SELECT count(*) AS employees, count(*) FILTER (WHERE deleted_at IS NULL) AS employees_live,
       md5(string_agg(((to_jsonb(e) - 'first_name') - 'last_name')::text, ',' ORDER BY e.id)) AS employees_md5_sans_names
  FROM employees e;
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees'::regclass
                          AND attname = 'first_name' AND NOT attisdropped)
            THEN (SELECT count(*)::text FROM employees e WHERE (to_jsonb(e)->>'first_name') IS NOT NULL
                                                         OR (to_jsonb(e)->>'last_name') IS NOT NULL)
            ELSE 'absent' END AS employees_with_first_or_last_name;
-- leave_requests:authenticated 的表权限、策略
SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges
  FROM information_schema.role_table_grants WHERE table_schema = 'public' AND table_name = 'leave_requests'
 GROUP BY grantee ORDER BY grantee;
SELECT string_agg(polname || ':' || polcmd::text, ' | ' ORDER BY polname) AS leave_requests_policies
  FROM pg_policy WHERE polrelid = 'public.leave_requests'::regclass;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM approval_log WHERE subject_type = 'leave_request') AS approval_log_leave,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
-- 本刀替换的函数
SELECT s AS fn, md5(pg_get_functiondef(to_regprocedure(s))) AS def_md5,
       (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(s)) AS secdef,
       has_function_privilege('authenticated', s::regprocedure, 'EXECUTE') AS auth_exec,
       has_function_privilege('anon', s::regprocedure, 'EXECUTE') AS anon_exec
  FROM unnest(ARRAY['public.leave_balance_internal(uuid, text, date)',
                    'public.submit_leave_request(uuid, text, date, date, boolean, boolean, text, text, boolean, numeric, text)',
                    'public.decide_leave_request(uuid, boolean, text)', 'public.annual_leave_available_from(uuid, numeric, date)',
                    'public.export_my_personal_data()', 'public.anonymise_employee(uuid, text)']) s;
SELECT r.code AS role, count(rp.permission_code) AS n,
       md5(COALESCE(string_agg(rp.permission_code, ',' ORDER BY rp.permission_code), '')) AS codes_md5
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT u.email, string_agg(r.code, ' ') AS roles_unrevoked
  FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN auth.users u ON u.id = ur.user_id
 WHERE ur.revoked_at IS NULL GROUP BY 1 ORDER BY 1;
SELECT count(*) AS auth_users FROM auth.users;
-- 在途清单(DEFINER 函数,以 postgres 调;它不问"你是谁")
SELECT subject_type, count(*) AS pending, round(sum(amount_base), 2) AS amount_base,
       count(*) FILTER (WHERE blocks_disable) AS blocks_disable
  FROM approval_pending_documents() GROUP BY 1 ORDER BY 1;
SELECT (SELECT string_agg(code, ' ' ORDER BY code) FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL) AS leave_pending,
       (SELECT string_agg(code, ' ' ORDER BY code) FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL) AS medical_submitted,
       (SELECT string_agg(code, ' ' ORDER BY code) FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL) AS medical_approved_unpaid,
       (SELECT string_agg(code, ' ' ORDER BY code) FROM expense_claims WHERE status = 'submitted') AS expense_submitted,
       (SELECT string_agg(code, ' ' ORDER BY code) FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL) AS stocktakes_open;

SELECT '== part 2 · tim@ (634c00f9…, cfo) · authenticated · views' AS section;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS claims_set;
SET LOCAL ROLE authenticated;
SELECT auth.uid() AS reader, current_user AS db_role;
SELECT count(*) AS ap_rows, sum(open_base) AS ap_open_base FROM ap_open_items;
SELECT count(*) AS ar_rows, sum(open_base) AS ar_open_base FROM ar_open_items;
SELECT side->>'side' AS side, side->>'list_base' AS list, side->>'ledger_base' AS ledger,
       side->>'unexplained_base' AS unexplained, side->>'agrees' AS agrees
  FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') side;
RESET ROLE;

SELECT '== part 3 · per real account, each as itself' AS section;
CREATE FUNCTION pg_temp.codes_of(p_email text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v uuid; v_n int; v_md5 text;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    SELECT count(*), md5(string_agg(c, ',' ORDER BY c)) INTO v_n, v_md5 FROM unnest(current_user_permissions()) c;
    RETURN v_n || ' codes · md5 ' || v_md5;
END $$;
SELECT email, pg_temp.codes_of(email) FROM auth.users
 WHERE email IN ('admin@swm-os.test','tim@evoltrya.test','chooer@evoltrya.test','sandra@evoltrya.test',
                 'phua@evolytra.test','fusheng@evoltrya.test','vince@evoltrya.test') ORDER BY email;
ROLLBACK;

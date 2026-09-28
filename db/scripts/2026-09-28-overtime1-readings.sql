-- db/scripts/2026-09-28-overtime1-readings.sql
-- OVERTIME-1 · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 EMP-SELF-1 那一支同形,换成本刀的对象:
-- 现场员工标记、两张加班表、考勤底稿、approval_log 里的加班一类、两个新码的持有人、本刀替换 / 新增函数的定义 md5 与 ACL,
-- 在途清单、每个账号自己的码表。迁移之前不存在的对象一律读成 NULL / absent,不报错。
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
   AND relname IN ('employees','attendance_periods','attendance_lines','overtime_batches','overtime_lines','approval_log',
                   'journal_entries','journal_lines','accounts','role_permissions','roles','user_roles','finance_settings',
                   'permissions','ap_open_items','ar_open_items','leave_requests','medical_claims','expense_claims');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold, locked_before, system_start_date FROM finance_settings;
-- 现场员工标记(迁移之前列不存在 → absent)
SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees'::regclass
                          AND attname = 'is_site_staff' AND NOT attisdropped)
            THEN (SELECT count(*)::text FROM employees WHERE (to_jsonb(employees)->>'is_site_staff')::boolean)
            ELSE 'absent' END AS employees_flagged_site_staff,
       (SELECT count(*) FROM employees WHERE deleted_at IS NULL) AS employees_live,
       (SELECT md5(string_agg(code || ':' || work_category || ':' || employment_status, ',' ORDER BY code)) FROM employees) AS employees_md5;
-- 两张加班表(迁移之前不存在 → absent)。★ 计数走动态 SQL:规划器会解析 CASE 里【没走到的那一支】
--   的表名,于是一张还不存在的表会让整条语句报错,而不是读成 absent。
CREATE FUNCTION pg_temp.count_or_absent(p_rel text, p_where text DEFAULT 'true') RETURNS text LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
    IF to_regclass(p_rel) IS NULL THEN RETURN 'absent'; END IF;
    EXECUTE format('SELECT count(*) FROM %s WHERE %s', p_rel, p_where) INTO v;
    RETURN v::text;
END $$;
SELECT pg_temp.count_or_absent('public.overtime_batches') AS overtime_batches,
       pg_temp.count_or_absent('public.overtime_batches', 'status = ''submitted''') AS overtime_batches_submitted,
       pg_temp.count_or_absent('public.overtime_lines') AS overtime_lines;
SELECT (SELECT count(*) FROM attendance_periods) AS attendance_periods,
       (SELECT count(*) FROM attendance_lines) AS attendance_lines;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM approval_log WHERE subject_type = 'overtime_batch') AS approval_log_overtime,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
SELECT pg_get_constraintdef(oid) AS approval_log_subject_check FROM pg_constraint
 WHERE conrelid = 'public.approval_log'::regclass AND conname = 'approval_log_subject_type_check';
-- 银行 1000、应收 1100、存货 1200、应付 2000(借减贷,本位币;全部行,不按 posted 过滤 —— AGENTS.md)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1000', '1100', '1200', '1400', '2000', '2100') GROUP BY a.code ORDER BY a.code;
-- 本刀替换 / 新增的函数(新的在迁移之前读成 NULL)
SELECT s AS fn,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE md5(pg_get_functiondef(to_regprocedure(s))) END AS def_md5,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(s)) END AS secdef,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE') END AS auth_exec,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE has_function_privilege('anon', s::regprocedure, 'EXECUTE') END AS anon_exec
  FROM unnest(ARRAY['public.record_attendance(uuid, numeric, numeric, numeric, text)',
                    'public.complete_attendance_period(uuid)', 'public.attendance_period_status_rows()',
                    'public.record_approval_decision(text, uuid, text, smallint, text)', 'public.approval_pending_documents()',
                    'public.overtime_day_kind(date)', 'public.overtime_approved_hours(date)', 'public.overtime_assert_month_open(date)',
                    'public.overtime_other_approver_exists(uuid, uuid[])', 'public.create_overtime_batch(date)',
                    'public.add_overtime_line(uuid, uuid, date, numeric, text)', 'public.delete_overtime_line(uuid)',
                    'public.submit_overtime_batch(uuid)', 'public.withdraw_overtime_batch(uuid)',
                    'public.decide_overtime_batch(uuid, text, text)', 'public.reverse_overtime_batch(uuid, text)',
                    'public.discard_overtime_batch(uuid)', 'public.overtime_month_hours(date)',
                    'public.overtime_batch_lines(uuid)', 'public.overtime_site_staff()', 'public.my_overtime_lines()']) s;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('action.overtime_enter', 'action.overtime_approve', 'module.hr.edit', 'module.hr.view',
                  'action.decide_hr_requests')
 GROUP BY p.code ORDER BY p.code;
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

-- db/scripts/2026-09-27-apr9-readings.sql
-- APR-9 · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 APR-8 那一支同形,换成本刀的对象:
-- salary_change_requests / asset_disposal_requests(迁移之前不存在 —— 读成 NULL)、月薪与履历、评估、
-- 工资期与工资申请、固定资产与折旧、1500 / 1510 / 7200、两支守卫、新门与内层算子对 authenticated 的 EXECUTE。
-- 本刀【不新增任何码】,所以每一个角色的码表与 md5 必须前后逐字相同。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】与目录(relkind 第一段自证);
--   第二部分:以 tim@(634c00f9…,cfo)的 JWT、SET LOCAL ROLE authenticated 读【视图】
--     (ap_open_items / ar_open_items 与 list_ledger_reconciliation() 的谓词问的是"你是谁");
--   第三部分:每一个真账号的 current_user_permissions(),各自以那个账号的 JWT 读。
-- 角色持有一律读【未撤销】的授权(ur.revoked_at IS NULL)。
\pset footer off
BEGIN;
SELECT '== part 1 · postgres · base tables' AS section;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('employees','employment_history','performance_reviews','payroll_periods','payroll_requests',
                   'fixed_assets','fixed_asset_depreciation','fixed_asset_depreciation_anchors','journal_entries',
                   'journal_lines','accounts','approval_log','role_permissions','roles','user_roles','finance_settings',
                   'salary_change_requests','asset_disposal_requests','ap_open_items','ar_open_items','expense_claims');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold, locked_before FROM finance_settings;
-- 两张新表:迁移之前不存在(NULL = 表不在),之后是行数与在等的张数
SELECT t AS request_table,
       CASE WHEN to_regclass('public.' || t) IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.' || t, false, true, '')))[1]::text END AS rows,
       CASE WHEN to_regclass('public.' || t) IS NULL THEN NULL
            ELSE (xpath('/row/n/text()', query_to_xml('SELECT count(*) AS n FROM public.' || t || ' WHERE status = ''submitted''', false, true, '')))[1]::text END AS pending
  FROM unnest(ARRAY['salary_change_requests', 'asset_disposal_requests']) t;
-- 月薪、履历、评估、工资期、工资申请(基表)
SELECT (SELECT count(*) FROM employees WHERE deleted_at IS NULL) AS employees_live,
       (SELECT count(*) FROM employees WHERE monthly_salary IS NOT NULL) AS salaries_set,
       (SELECT md5(COALESCE(string_agg(id::text || ':' || monthly_salary::text, ',' ORDER BY id), ''))
          FROM employees WHERE monthly_salary IS NOT NULL) AS salary_digest,
       (SELECT count(*) FROM employment_history) AS employment_history,
       (SELECT count(*) FROM employment_history WHERE change_type = 'salary_change') AS salary_history,
       (SELECT count(*) FROM performance_reviews) AS reviews,
       (SELECT count(*) FROM performance_reviews WHERE status = 'submitted') AS reviews_submitted;
SELECT (SELECT string_agg(code || ':' || status, ' ' ORDER BY period_month) FROM payroll_periods WHERE deleted_at IS NULL) AS payroll_periods,
       (SELECT count(*) FROM payroll_requests WHERE status IN ('submitted', 'approved')) AS payroll_requests_open;
-- 固定资产、折旧、处置分录(基表)
SELECT code, status, cost_base, in_service_date, disposal_date,
       (SELECT COALESCE(sum(amount_base), 0) FROM fixed_asset_depreciation d WHERE d.asset_id = fa.id) AS accum
  FROM fixed_assets fa ORDER BY code;
SELECT (SELECT count(*) FROM fixed_asset_depreciation) AS depreciation_rows,
       (SELECT count(*) FROM fixed_asset_depreciation_anchors) AS anchors,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'asset_disposal') AS disposal_entries,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'depreciation') AS depreciation_entries;
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1500', '1510', '7200') GROUP BY a.code ORDER BY a.code;
-- 两支守卫;两张申请表上的写策略(迁移之后 0 条)
SELECT count(*) AS apr9_guards FROM pg_trigger WHERE NOT tgisinternal
   AND tgname IN ('trg_performance_reviews_guard_write', 'trg_fixed_assets_disposal_freeze');
SELECT count(*) AS request_write_policies FROM pg_policies
 WHERE schemaname = 'public' AND tablename IN ('salary_change_requests', 'asset_disposal_requests') AND cmd <> 'SELECT';
-- 新门与内层算子对 authenticated 的 EXECUTE(迁移之前不存在的对象读成 NULL)
SELECT s AS fn, CASE WHEN to_regprocedure(s) IS NULL THEN NULL
                     ELSE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE') END AS authenticated_can_execute
  FROM unnest(ARRAY['public.submit_salary_change_request(uuid, numeric, date, text)',
                    'public.decide_salary_change_request(uuid, boolean, text)', 'public.withdraw_salary_change_request(uuid, text)',
                    'public.submit_asset_disposal_request(uuid, numeric, text, text)',
                    'public.decide_asset_disposal_request(uuid, boolean, text)', 'public.withdraw_asset_disposal_request(uuid, text)',
                    'public.dispose_fixed_asset(uuid, date, numeric, text, text)',
                    'public.dispose_fixed_asset_internal(uuid, date, numeric, text, text)',
                    'public.salary_change_execute_internal(uuid)', 'public.asset_disposal_execute_internal(uuid)',
                    'public.pay_decision_code(uuid, uuid)']) s;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
-- 银行 1000、应收 1100、存货 1200、应付 2000(借减贷,本位币;全部行,不按 posted 过滤 —— AGENTS.md)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1000', '1100', '1200', '2000', '1500', '1510', '7200') GROUP BY a.code ORDER BY a.code;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.hr.edit', 'module.hr.view', 'data.view_pay', 'action.approve_review', 'action.hr_reviews',
                  'module.finance.edit', 'module.finance.view', 'data.view_prices')
 GROUP BY p.code ORDER BY p.code;
SELECT r.code AS role, count(rp.permission_code) AS n,
       md5(COALESCE(string_agg(rp.permission_code, ',' ORDER BY rp.permission_code), '')) AS codes_md5
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT r.code AS role, string_agg(rp.permission_code, ' ' ORDER BY rp.permission_code) AS codes
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT u.email, string_agg(r.code, ' ') AS roles_unrevoked
  FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN auth.users u ON u.id = ur.user_id
 WHERE ur.revoked_at IS NULL GROUP BY 1 ORDER BY 1;
-- 在途清单(DEFINER 函数,以 postgres 调;它不问"你是谁")
SELECT subject_type, count(*) AS pending, round(sum(amount_base), 2) AS amount_base,
       count(*) FILTER (WHERE blocks_disable) AS blocks_disable
  FROM approval_pending_documents() GROUP BY 1 ORDER BY 1;

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

SELECT '== part 3 · current_user_permissions() per real account, each as itself' AS section;
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

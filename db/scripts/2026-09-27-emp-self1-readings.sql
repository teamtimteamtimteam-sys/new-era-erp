-- db/scripts/2026-09-27-emp-self1-readings.sql
-- EMP-SELF-1 · 前后读数(只读;整支一笔事务,最后 ROLLBACK)。与 TERMS-EDIT-1 那一支同形,换成本刀的对象:
-- 三种员工单据(请假 · 医疗申报 · 报销)的逐状态行数、医疗申报的两条约束、本刀替换 / 新增的九支函数的定义 md5 与 ACL、
-- 敞口报表的状态、每个账号自己读 my_document_decisions() 的行数(迁移之前不存在 —— 读成 NULL)。
-- 本刀【不加码、不动授权】,所以每一个角色的码表与 md5 前后【应当】逐字相同。
--
-- 身份写在每一段的开头(AGENTS.md「一个 0 行的读数,先问它是谁读的」):
--   第一部分:以 postgres 连接,rolbypassrls = t,读的全部是【基表】与目录(relkind 第一段自证);
--   第二部分:以 tim@(634c00f9…,cfo)的 JWT、SET LOCAL ROLE authenticated 读【视图】与两支按调用者作答的函数;
--   第三部分:每一个真账号各自以自己的 JWT 读 current_user_permissions() 与 my_document_decisions()。
-- 角色持有一律读【未撤销】的授权(ur.revoked_at IS NULL)。
\pset footer off
BEGIN;
SELECT '== part 1 · postgres · base tables' AS section;
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;
SELECT string_agg(relname || '=' || relkind::text, ' ' ORDER BY relname) AS relkinds
  FROM pg_class WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('leave_requests','medical_claims','expense_claims','contracts','contract_pricing_terms','journal_entries',
                   'journal_lines','accounts','approval_log','role_permissions','roles','user_roles','finance_settings',
                   'permissions','ap_open_items','ar_open_items');
SELECT approvals_enabled, approval_level1_role_code AS l1, approval_level2_role_code AS l2,
       approval_threshold_base AS threshold, locked_before FROM finance_settings;
-- 三种员工单据,逐状态(基表)
SELECT 'leave_requests' AS t, status, count(*) FROM leave_requests WHERE deleted_at IS NULL GROUP BY status
UNION ALL SELECT 'medical_claims', status, count(*) FROM medical_claims WHERE deleted_at IS NULL GROUP BY status
UNION ALL SELECT 'expense_claims', status, count(*) FROM expense_claims GROUP BY status
ORDER BY 1, 2;
SELECT conname, pg_get_constraintdef(oid) AS def FROM pg_constraint
 WHERE conrelid = 'public.medical_claims'::regclass AND contype = 'c' ORDER BY conname;
SELECT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.medical_claims'::regclass
                AND attname = 'withdrawn_at' AND NOT attisdropped) AS medical_withdrawn_at_exists;
-- 本刀替换 / 新增的九支函数(迁移之前两支新的不存在 —— 读成 NULL)
SELECT s AS fn,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE md5(pg_get_functiondef(to_regprocedure(s))) END AS def_md5,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(s)) END AS secdef,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE') END AS authenticated_can_execute,
       CASE WHEN to_regprocedure(s) IS NULL THEN NULL ELSE has_function_privilege('anon', s::regprocedure, 'EXECUTE') END AS anon_can_execute
  FROM unnest(ARRAY['public.withdraw_medical_claim(uuid)', 'public.my_document_decisions()',
                    'public.submit_leave_request(uuid, text, date, date, boolean, boolean, text, text, boolean, numeric, text)',
                    'public.submit_medical_claim(uuid, date, numeric, text, text)',
                    'public.submit_expense_claim(uuid, date, numeric, text, text, text)',
                    'public.cancel_leave_request(uuid, text)', 'public.withdraw_expense_claim(uuid)',
                    'public.guard_contract_write()', 'public.price_exposure_report()']) s;
SELECT (SELECT count(*) FROM contracts) AS contracts, (SELECT count(*) FROM contracts WHERE code LIKE 'ZZ-SMOKE%') AS smoke_contracts,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing_terms;
SELECT (SELECT count(*) FROM approval_log) AS approval_log_rows,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
-- 银行 1000、应收 1100、存货 1200、应付 2000(借减贷,本位币;全部行,不按 posted 过滤 —— AGENTS.md)
SELECT a.code, round(COALESCE(sum(l.debit - l.credit), 0), 2) AS balance_debit_positive
  FROM accounts a LEFT JOIN journal_lines l ON l.account_id = a.id
 WHERE a.code IN ('1000', '1100', '1200', '1400', '2000', '2100') GROUP BY a.code ORDER BY a.code;
SELECT (SELECT count(*) FROM permissions) AS catalogue;
SELECT p.code, string_agg(r.code, ' ' ORDER BY r.code) AS holders
  FROM permissions p LEFT JOIN role_permissions rp ON rp.permission_code = p.code LEFT JOIN roles r ON r.id = rp.role_id
 WHERE p.code IN ('module.hr.edit', 'module.hr.view', 'action.decide_hr_requests', 'module.finance.view',
                  'module.finance.edit', 'action.contract_terms')
 GROUP BY p.code ORDER BY p.code;
SELECT r.code AS role, count(rp.permission_code) AS n,
       md5(COALESCE(string_agg(rp.permission_code, ',' ORDER BY rp.permission_code), '')) AS codes_md5
  FROM roles r LEFT JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT r.code AS role, string_agg(rp.permission_code, ' ' ORDER BY rp.permission_code) AS codes
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id GROUP BY r.code ORDER BY r.code;
SELECT u.email, string_agg(r.code, ' ') AS roles_unrevoked
  FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN auth.users u ON u.id = ur.user_id
 WHERE ur.revoked_at IS NULL GROUP BY 1 ORDER BY 1;
-- 在途清单(DEFINER 函数,以 postgres 调;它不问"你是谁")与本刀三种单据的在途
SELECT subject_type, count(*) AS pending, round(sum(amount_base), 2) AS amount_base,
       count(*) FILTER (WHERE blocks_disable) AS blocks_disable
  FROM approval_pending_documents() GROUP BY 1 ORDER BY 1;
SELECT (SELECT string_agg(code, ' ' ORDER BY code) FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL) AS leave_pending,
       (SELECT string_agg(code, ' ' ORDER BY code) FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL) AS medical_submitted,
       (SELECT string_agg(code, ' ' ORDER BY code) FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL) AS medical_approved_unpaid,
       (SELECT string_agg(code, ' ' ORDER BY code) FROM expense_claims WHERE status = 'submitted') AS expense_submitted;

SELECT '== part 2 · tim@ (634c00f9…, cfo) · authenticated · views' AS section;
SELECT set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true) IS NOT NULL AS claims_set;
SET LOCAL ROLE authenticated;
SELECT auth.uid() AS reader, current_user AS db_role;
SELECT count(*) AS ap_rows, sum(open_base) AS ap_open_base FROM ap_open_items;
SELECT count(*) AS ar_rows, sum(open_base) AS ar_open_base FROM ar_open_items;
SELECT side->>'side' AS side, side->>'list_base' AS list, side->>'ledger_base' AS ledger,
       side->>'unexplained_base' AS unexplained, side->>'agrees' AS agrees
  FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') side;
SELECT price_exposure_report()->'sell_side'->>'state' AS exposure_state,
       price_exposure_report()->'coverage' AS exposure_coverage;
RESET ROLE;

SELECT '== part 3 · per real account, each as itself' AS section;
CREATE FUNCTION pg_temp.codes_of(p_email text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v uuid; v_n int; v_md5 text; v_dec text;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    SELECT count(*), md5(string_agg(c, ',' ORDER BY c)) INTO v_n, v_md5 FROM unnest(current_user_permissions()) c;
    IF to_regprocedure('public.my_document_decisions()') IS NULL THEN
        v_dec := 'absent';
    ELSE
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE 'SELECT count(*)::text FROM my_document_decisions()' INTO v_dec;
        EXECUTE 'RESET ROLE';
    END IF;
    RETURN v_n || ' codes · md5 ' || v_md5 || ' · my_document_decisions ' || v_dec;
END $$;
SELECT email, pg_temp.codes_of(email) FROM auth.users
 WHERE email IN ('admin@swm-os.test','tim@evoltrya.test','chooer@evoltrya.test','sandra@evoltrya.test',
                 'phua@evolytra.test','fusheng@evoltrya.test','vince@evoltrya.test') ORDER BY email;
ROLLBACK;

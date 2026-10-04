-- db/scripts/2026-10-05-at1d3-live-readings.sql
-- AUDIT-TRAIL-1d-3 · 活库的"之前 / 之后"读数(形状照 1d-2 的那一份,多一栏工资与评审)—— 只读。live verification 前后各跑一次,两份输出逐字相同 =
--   这一刀的验证什么都没留下、在它之前就在的每一张单据一个字节都没变。以 postgres 跑(rolbypassrls = true,读的是基表的真行数)。
-- 跑法:psql "$DSN" -X -q -f db/scripts/2026-10-05-at1d3-live-readings.sql
DO $read$
DECLARE t record; d text; acc text := ''; n int := 0;
BEGIN
    -- 每一张 public 表(change_log 除外 —— 它由下面单独读)的每一行:按行的 md5 排序后整体再 md5
    FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
              WHERE ns.nspname = 'public' AND c.relkind = 'r' AND c.relname <> 'change_log' ORDER BY 1 LOOP
        EXECUTE format('SELECT md5(COALESCE(string_agg(md5(x::text), '''' ORDER BY md5(x::text)), '''')) FROM public.%I x', t.relname) INTO d;
        acc := acc || t.relname || ':' || d || ';';
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'READING tables % · every-row digest %', n, left(md5(acc), 12);
END;
$read$;
SELECT 'READING' AS reading,
       (SELECT count(*) || ' rows, max seq ' || max(seq) FROM change_log) AS change_log,
       (SELECT count(*) || ' accounts, ' || count(*) FILTER (WHERE banned_until > now()) || ' disabled'
          FROM auth.users WHERE email NOT LIKE '%@test.local') AS accounts,
       (SELECT CASE WHEN approvals_enabled THEN 'ON' ELSE 'OFF' END FROM finance_settings) AS approvals,
       (SELECT count(*) || ' · ' || left(md5(string_agg(k || ':' || id, ',' ORDER BY k, id)), 12) FROM (
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'
       ) p) AS pending_documents,
       (SELECT count(*) || ', last ' || max(code) FROM purchase_orders) AS purchase_orders,
       -- AUDIT-TRAIL-1c-2(沿用):1c-2 在一笔回滚的事务里建销售、运费单、资产、对账单、GST 期间、汇率、管理包、合同 —— 这几张表的行数与
       --   最后一个编号前后必须不动(销售与汇率没有编号:数行数与最新一行)
       (SELECT count(*) || ', last ' || max(code) FROM journal_entries) AS journals,
       (SELECT count(*) || ' · ' || count(*) FILTER (WHERE customer_id IS NULL) || ' unattributed' FROM sales_records) AS sales,
       (SELECT count(*) || ', last ' || max(code) || ' · ' || count(*) FILTER (WHERE status = 'reversed') || ' reversed' FROM freight_documents) AS freight,
       (SELECT count(*) || ', last ' || max(code) || ' · ' || count(*) FILTER (WHERE status = 'disposed') || ' disposed' FROM fixed_assets) AS assets,
       (SELECT count(*) || ', last ' || max(code) || ' · ' || count(*) FILTER (WHERE deleted_at IS NOT NULL) || ' deleted' FROM bank_statements) AS statements,
       (SELECT count(*) || ', last ' || max(code) FROM gst_periods) AS gst_periods,
       (SELECT count(*) || ' · ' || count(*) FILTER (WHERE deleted_at IS NOT NULL) || ' withdrawn · latest ' || COALESCE(max(rate_date)::text, '-') FROM fx_rates) AS fx_rates,
       (SELECT count(*) || ', last ' || COALESCE(max(code), '-') FROM management_packs) AS packs,
       (SELECT count(*) || ', last ' || COALESCE(max(code), '-') FROM contracts) AS contracts,
       (SELECT count(*) FROM fx_rate_history) || ' fx history · ' || (SELECT count(*) FROM fixed_asset_history) || ' asset history · '
           || (SELECT count(*) FROM bank_reconciliations) || ' reconciliations · ' || (SELECT count(*) FROM gst_return_boxes) || ' GST boxes · '
           || (SELECT count(*) FROM terms_requests) || ' terms requests · ' || (SELECT count(*) FROM finance_attachments) || ' finance attachments' AS rows_1c2,
       -- AUDIT-TRAIL-1c-3:本刀在一笔回滚的事务里挪锁、改 GST 注册号、改公司地址,建人工分录申请、报销单、转账、缴纳、预测、常设行、
       --   导入映射、汇率 —— 锁与 GST 两格、公司资料整行、这几张表的行数与最后一个编号前后必须逐字不动
       (SELECT COALESCE(locked_before::text, '-') || ' · GST ' || CASE WHEN gst_registered THEN 'on' ELSE 'off' END || ' ' || COALESCE(gst_registration_no, '-')
               || ' · ' || left(md5(to_jsonb(fs)::text), 12) FROM finance_settings fs) AS settings_row,
       (SELECT left(md5(to_jsonb(cp)::text), 12) FROM company_profile cp) AS company_profile,
       (SELECT count(*) || ' · ' || count(*) FILTER (WHERE reopened_at IS NOT NULL) || ' reopened' FROM period_closes) || ' month closes · '
           || (SELECT count(*) FROM year_closes) || ' year closes' AS closes,
       (SELECT count(*) FROM journal_requests) || ' journal requests · ' || (SELECT count(*) || ', last ' || max(code) FROM expense_claims) || ' claims · '
           || (SELECT count(*) FROM bank_transfers) || ' transfers · ' || (SELECT count(*) FROM wht_remittances) || ' WHT remittances · '
           || (SELECT count(*) || ', last ' || COALESCE(max(code), '-') FROM payment_requests) || ' payment requests' AS rows_1c3_docs,
       (SELECT count(*) FROM cash_forecasts) || ' forecasts · ' || (SELECT count(*) FROM cash_forecast_lines) || ' recurring lines · '
           || (SELECT count(*) FROM bank_import_profiles) || ' import mappings · ' || (SELECT count(*) || ', last ' || max(code) FROM expenses) || ' expenses · '
           || (SELECT count(*) FROM suppliers) || ' suppliers' AS rows_1c3_lists,
       -- AUDIT-TRAIL-1d-1:本刀在一笔回滚的事务里入职一名员工、编辑他、给一个已有的账号授一个角色、在一本字典里加一个值再改它 ——
       --   七个账号与它们的角色(谁持什么,收回的也算)、员工 / 履历 / 部门 / 培训 / 授权 / 附加账号 / 导入批次、六本字典,前后必须逐字不动
       (SELECT count(*) || ' accounts · ' || count(*) FILTER (WHERE banned_until IS NOT NULL AND banned_until > now()) || ' disabled · '
               || left(md5(string_agg(u.id::text || ':' || COALESCE(u.banned_until::text, '-'), ',' ORDER BY u.id)), 12) FROM auth.users u) AS accounts_1d1,
       (SELECT count(*) || ' grants · ' || count(*) FILTER (WHERE revoked_at IS NULL) || ' live · '
               || left(md5(string_agg(ur.user_id || ':' || r.code || ':' || COALESCE(ur.revoked_at::text, '-'), ',' ORDER BY ur.user_id, r.code, ur.granted_at)), 12)
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id) AS roles_held,
       (SELECT count(*) || ', last ' || max(code) FROM employees) || ' employees · ' || (SELECT count(*) FROM employment_history) || ' history · '
           || (SELECT count(*) FROM departments) || ' departments · ' || (SELECT count(*) FROM training_records) || ' training · '
           || (SELECT count(*) FROM employee_accounts) || ' extra logins · ' || (SELECT count(*) FROM import_batches) || ' imports · '
           || (SELECT count(*) FROM salary_change_requests) || ' salary requests' AS rows_1d1,
       (SELECT count(*) FROM substances) || '/' || (SELECT count(*) FROM battery_chemistries) || '/' || (SELECT count(*) FROM material_kinds) || '/'
           || (SELECT count(*) FROM inbound_safety_states) || '/' || (SELECT count(*) FROM laboratories) || '/' || (SELECT count(*) FROM inbound_source_reasons)
           || ' dictionary values' AS dictionaries,
       -- AUDIT-TRAIL-1d-2:本刀在一笔回滚的事务里申请并决定一张请假、建并改一张医疗报销、临时把一名员工标成现场员工、开一张加班批送审再退回、
       --   改一个假别与一个公共假期 —— 这几张表的每一行(行级 md5)、现场员工的人数,前后必须逐字不动
       (SELECT count(*) FILTER (WHERE is_site_staff) || ' site staff' FROM employees) AS site_staff,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM leave_requests x) AS leave_requests,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM leave_consumption x) AS leave_consumption,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM leave_grants x) AS leave_grants,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM leave_types x) AS leave_types,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM public_holidays x) AS public_holidays,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM medical_claims x) AS medical_claims,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM overtime_batches x) AS overtime_batches,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM overtime_lines x) AS overtime_lines,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM attendance_periods x) AS attendance_periods,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM approval_log x) AS approval_log,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM document_types x) AS document_types,
       -- AUDIT-TRAIL-1d-3:本刀在一笔回滚的事务里重导一个工资期的行(一行没变、一行变了)、开一轮评审再关掉、批准一份评审、
       --   改评分刻度的一档 —— 这几张表的每一行(行级 md5)前后必须逐字不动
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM payroll_periods x) AS payroll_periods,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM payroll_lines x) AS payroll_lines,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM payroll_requests x) AS payroll_requests,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM performance_reviews x) AS performance_reviews,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM review_goals x) AS review_goals,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM review_cycles x) AS review_cycles,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM review_rating_scale x) AS rating_scale,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM kpi_entries x) AS kpi_entries,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM kpi_cycles x) AS kpi_cycles,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM attendance_lines x) AS attendance_lines,
       (SELECT count(*) || ' · ' || left(md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '')), 12) FROM employees x) AS employees_rows;

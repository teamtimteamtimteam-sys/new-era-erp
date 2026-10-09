-- MES-5b-2 close-out (step 1 of the MES-5b-2 close-out + MES-5b-3 brief, 2026-10-09) — read-only, BEGIN READ ONLY … ROLLBACK.
-- Identity: postgres (rolbypassrls = true) on base tables and the catalog. Nothing written.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';

-- a · V37 on the operation trail: the live trail_subject_members carries operation_type_output_forms under operation_type
SELECT 'A|trail member operation_type_output_forms on live=' ||
       (pg_get_functiondef('public.trail_subject_members'::regproc) LIKE '%(''operation_type'',     5, ''operation_type_output_forms''%');

-- b · Q28: post_electricity_allocation asks module.finance.view on live
SELECT 'B|post asks finance.view=' || (pg_get_functiondef('public.post_electricity_allocation'::regproc) LIKE '%require_permission(''module.finance.view'')%')
    || '|asks finance.edit=' || (pg_get_functiondef('public.post_electricity_allocation'::regproc) LIKE '%require_permission(''module.finance.edit'')%');

-- c · Q21: the variance view counts posted reliefs only; relieve reads the base currency from data
SELECT 'C|variance filters posted=' || (pg_get_viewdef('public.processing_cost_variance'::regclass) LIKE '%ex.status = ''posted''%')
    || '|relieve has SGD literal=' || (pg_get_functiondef('public.relieve_processing_accruals'::regproc) LIKE '%''SGD''%')
    || '|relieve reads base_currency_code=' || (pg_get_functiondef('public.relieve_processing_accruals'::regproc) LIKE '%base_currency_code()%');

-- d · Q23: run_id unique gone, the one-live guard present
SELECT 'D|unique constraints on run_id=' || count(*) FROM pg_constraint
 WHERE conrelid = 'public.electricity_allocation_lines'::regclass AND contype = 'u'
   AND conkey = ARRAY[(SELECT attnum FROM pg_attribute WHERE attrelid = 'public.electricity_allocation_lines'::regclass AND attname = 'run_id')];
SELECT 'D|one-live guard trigger=' || count(*) FROM pg_trigger
 WHERE tgrelid = 'public.electricity_allocation_lines'::regclass AND NOT tgisinternal AND tgfoid = 'public.guard_electricity_line_one_live_allocation'::regproc;

-- window use: anything of the new kinds since the migration committed (2026-10-09 14:48:26 CST)
SELECT 'W|allocations=' || (SELECT count(*) FROM electricity_allocations)
    || '|reversals=' || (SELECT count(*) FROM electricity_allocation_reversals)
    || '|expenses reversed (all time)=' || (SELECT count(*) FROM expenses WHERE status = 'reversed')
    || '|expenses created since window=' || (SELECT count(*) FROM expenses WHERE created_at >= '2026-10-09 14:48:26+08')
    || '|cost entries stamped since window=' || (SELECT count(*) FROM processing_cost_entries WHERE relieved_at >= '2026-10-09 14:48:26+08' OR remitted_at >= '2026-10-09 14:48:26+08')
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings LIMIT 1), 'NULL');

-- f · ids for the render probe: one ordinary unpaid expense, the relief, one paid-through-payment, any allocation
SELECT 'F|EXP|' || code || '|' || id || '|' || status || '|' || payment_status FROM expenses WHERE code IN ('EXP-2026-0003', 'EXP-2026-0005', 'EXP-2026-0001') ORDER BY code;
SELECT 'F|ALLOC|' || count(*) FROM electricity_allocations;

-- standing state
SELECT 'S|approvals_on=' || approvals_enabled FROM finance_settings;
SELECT 'S|accounts=' || count(*) || '|disabled=' || count(*) FILTER (WHERE banned_until > now()) FROM auth.users WHERE email NOT LIKE '%@test.local';
ROLLBACK;

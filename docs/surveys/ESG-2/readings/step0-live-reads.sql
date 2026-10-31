-- ESG-2 Step 0:以 postgres(rolbypassrls = true)只读;基表行数是真行数(relkind 'r'),不经任何视图谓词
SELECT 'ROLECODES|' || r.code || '|' || string_agg(rp.permission_code, ',' ORDER BY rp.permission_code)
  FROM roles r JOIN role_permissions rp ON rp.role_id = r.id
 WHERE rp.permission_code IN ('module.safety.view','module.safety.edit','data.view_health','module.hr.view','module.hr.edit','module.finance.view','module.processing.view','module.inventory.view','module.suppliers.view','data.view_cod','module.compliance.view','action.manage_signatories','module.settings.edit')
 GROUP BY r.code ORDER BY r.code;
SELECT 'HOLDERS|' || r.code || '|' || count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE ur.revoked_at IS NULL GROUP BY r.code ORDER BY r.code;
SELECT 'ROWS|' || json_build_object(
  'incidents', (SELECT count(*) FROM incidents),
  'incidents_injury', (SELECT count(*) FROM incidents WHERE kind_code='injury'),
  'incidents_days_lost_gt0', (SELECT count(*) FROM incidents WHERE days_lost > 0),
  'incidents_injured_nonemployee', (SELECT count(*) FROM incidents WHERE injured_person_name IS NOT NULL),
  'training_records', (SELECT count(*) FROM training_records WHERE deleted_at IS NULL),
  'training_distinct_names', (SELECT count(DISTINCT lower(btrim(training_name))) FROM training_records WHERE deleted_at IS NULL),
  'training_with_expiry', (SELECT count(*) FROM training_records WHERE deleted_at IS NULL AND expiry_date IS NOT NULL),
  'elec_bills', (SELECT count(*) FROM electricity_allocations),
  'elec_bills_reversed', (SELECT count(*) FROM electricity_allocation_reversals),
  'att_periods', (SELECT count(*) FROM attendance_periods),
  'att_lines', (SELECT count(*) FROM attendance_lines),
  'att_lines_recorded', (SELECT count(*) FROM attendance_lines WHERE recorded_at IS NOT NULL),
  'employees_live', (SELECT count(*) FROM employees WHERE deleted_at IS NULL),
  'positions', (SELECT count(*) FROM positions), 'departments', (SELECT count(*) FROM departments WHERE deleted_at IS NULL),
  'leave_requests', (SELECT count(*) FROM leave_requests))::text;
SELECT 'TRAINING_NAMES|' || string_agg(DISTINCT lower(btrim(training_name)) || '(' || COALESCE(category,'-') || ')', ' · ') FROM training_records WHERE deleted_at IS NULL;
SELECT 'PERMCODES_LIKE|' || string_agg(code, ',' ORDER BY code) FROM permissions WHERE code ~ '(safety|esg|health|policy|whistle|hr\.)';
SELECT 'RELKIND|' || string_agg(relname || '=' || relkind::text, ',') FROM pg_class WHERE relnamespace='public'::regnamespace AND relname IN ('incidents','training_records','attendance_lines','electricity_allocations','leave_requests');

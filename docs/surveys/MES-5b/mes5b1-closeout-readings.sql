-- MES-5b-1 close-out item d: read-only. postgres for ids; then each real account's JWT for what its role reads.
BEGIN READ ONLY;
SELECT 'WHO|' || current_user || '|bypassrls=' || rolbypassrls FROM pg_roles WHERE rolname = current_user;
SELECT 'ACCT|' || u.email || '|' || string_agg(r.code, ',') || '|' || u.id || '|banned=' || (u.banned_until IS NOT NULL AND u.banned_until > now())
  FROM auth.users u JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL JOIN roles r ON r.id = ur.role_id
 WHERE u.email NOT LIKE '%@test.local' GROUP BY u.email, u.id, u.banned_until ORDER BY u.email;
SELECT 'IB|' || code || '|' || id FROM inbound_batches WHERE code = 'IN-2026-0001';
SELECT 'OB|' || ob.code || '|' || ob.id || '|runs_fed=' || count(DISTINCT pi.run_id)
  FROM output_batches ob JOIN processing_outputs po ON po.output_batch_id = ob.id
  LEFT JOIN processing_inputs pi ON pi.output_batch_id = ob.id
 WHERE ob.deleted_at IS NULL GROUP BY ob.code, ob.id ORDER BY count(DISTINCT pi.run_id) DESC, ob.code LIMIT 3;
DO $$
DECLARE a record; v_ib uuid; v_ob uuid; c1 bigint; c2 bigint; c3 bigint; c4 bigint; c5 bigint; c6 bigint; c7 bigint; c8 bigint;
        g_pv boolean; g_iv boolean; g_ov boolean;
BEGIN
  SELECT id INTO v_ib FROM inbound_batches WHERE code = 'IN-2026-0001';
  SELECT ob.id INTO v_ob FROM output_batches ob JOIN processing_outputs po ON po.output_batch_id = ob.id
   WHERE ob.deleted_at IS NULL AND ob.code = COALESCE((SELECT code FROM output_batches WHERE code = 'OUT-2026-0184' AND deleted_at IS NULL), 'OUT-2026-0003');
  RAISE NOTICE 'OBPICK|%', (SELECT code FROM output_batches WHERE id = v_ob);
  FOR a IN SELECT DISTINCT u.id, u.email, r.code AS role FROM auth.users u JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
             JOIN roles r ON r.id = ur.role_id WHERE u.email NOT LIKE '%@test.local' ORDER BY u.email LOOP
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', a.id), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    g_pv := has_permission('module.processing.view'); g_iv := has_permission('module.inbound.view'); g_ov := has_permission('module.output.view');
    SELECT count(*) INTO c1 FROM processing_balance_monthly;
    SELECT count(*) INTO c2 FROM processing_balance_monthly WHERE month = '2026-08-01' AND scope = 'plant' AND line = 'remainder' AND line_key = 'before_closure';
    SELECT count(*) INTO c3 FROM stock_rollforward_monthly;
    SELECT count(*) INTO c4 FROM processing_run_yield;
    SELECT count(*) INTO c5 FROM processing_run_yield WHERE NOT era_mes4a;
    SELECT count(*) INTO c6 FROM processing_yield_summary;
    SELECT count(*) INTO c7 FROM batch_balance_tree WHERE root_id = v_ib;
    SELECT count(*) INTO c8 FROM batch_balance_tree WHERE root_id = v_ob;
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'ROLE|%|%|gate pv=% iv=% ov=%|monthly=% (2026-08 before_closure rows=%)|roll=%|run_yield=% (pre-MES-4a rows=%)|summary=%|tree IN-0001=%|tree OUT-0184=%',
      a.role, a.email, g_pv, g_iv, g_ov, c1, c2, c3, c4, c5, c6, c7, c8;
  END LOOP;
END $$;
SELECT 'PLANT-2026-08|' || line || COALESCE(':' || line_key, '') || '|' || COALESCE(qty::text, '-') || '|runs=' || runs
  FROM processing_balance_monthly_all WHERE month = '2026-08-01' AND scope = 'plant' ORDER BY line, line_key;
ROLLBACK;

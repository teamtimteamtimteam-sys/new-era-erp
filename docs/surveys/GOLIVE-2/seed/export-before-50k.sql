-- GOLIVE-2 · BEFORE (db gl2ref = HEAD rebuild + year seed reshaped like live): reading 50,000 recorded changes the only way today's database offers —
--   change_log_rows, 200 rows a call (the path TABLE-EXPORT-3a measured). As the seed cfo, rolled back. Local only.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"b432a308-6cb1-a8c7-f8d1-72922bdd66cc","role":"authenticated"}', true) \g /dev/null
DO $r$
DECLARE v_before bigint; v_n int; v_tot int := 0; t0 timestamptz := clock_timestamp(); v_min bigint; c bigint;
BEGIN
    SELECT count(*) INTO c FROM change_log_rows(p_from => '2025-01-01', p_to => '2026-01-01', p_limit => 1);
    LOOP
        SELECT count(*), min(x.seq) INTO v_n, v_min FROM change_log_rows(p_from => '2025-01-01', p_to => '2026-01-01', p_before => v_before, p_limit => 200) x;
        v_tot := v_tot + v_n; v_before := v_min;
        EXIT WHEN v_n < 200 OR v_tot >= 50000;
    END LOOP;
    RAISE NOTICE 'EXPORT_BEFORE|read % recorded changes · % ms (no count function exists before)', v_tot, round(extract(epoch FROM clock_timestamp()-t0)*1000);
END $r$;
ROLLBACK;

-- GOLIVE-2 · local year seed (top reshaped like live): the export path as the seed cfo — change_log_count over 366 days, and reading
--   50,000 recorded changes through change_log_page in blocks of 500 operations (the export route's loop). Rolled back. Local only.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"b432a308-6cb1-a8c7-f8d1-72922bdd66cc","role":"authenticated"}', true) \g /dev/null
DO $t$
DECLARE t0 timestamptz; j jsonb; n bigint; tot int := 0; calls int := 0; v_before bigint;
BEGIN
    t0 := clock_timestamp();
    n := change_log_count(p_from => '2025-01-01', p_to => '2026-01-01');
    RAISE NOTICE 'EXPORT|count 366 days = % · % ms', n, round(extract(epoch FROM clock_timestamp()-t0)*1000);
    t0 := clock_timestamp();
    LOOP
        j := change_log_page(p_from => '2025-01-01', p_to => '2026-01-01', p_entries => 500, p_before => v_before);
        calls := calls + 1; tot := tot + jsonb_array_length(j->'rows');
        EXIT WHEN (j->>'exhausted')::boolean OR tot >= 50000;
        v_before := (j->>'next_before')::bigint;
    END LOOP;
    RAISE NOTICE 'EXPORT|read % recorded changes in % calls · % ms', tot, calls, round(extract(epoch FROM clock_timestamp()-t0)*1000);
END $t$;
ROLLBACK;

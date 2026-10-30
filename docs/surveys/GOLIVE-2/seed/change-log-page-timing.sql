-- GOLIVE-2 · local year seed (top reshaped like live): change_log_page timing as the seed cfo, show=20 (21 entries) and show=500 (501 entries), rolled back. Local only.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"b432a308-6cb1-a8c7-f8d1-72922bdd66cc","role":"authenticated"}', true) \g /dev/null
DO $t$
DECLARE t0 timestamptz; j jsonb; n int;
BEGIN
    FOREACH n IN ARRAY ARRAY[21, 501] LOOP
        t0 := clock_timestamp();
        j := change_log_page(p_entries => n);
        RAISE NOTICE 'PAGE|entries=% · % rows · % ms', n, jsonb_array_length(j->'rows'), round(extract(epoch FROM clock_timestamp()-t0)*1000);
    END LOOP;
END $t$;
ROLLBACK;

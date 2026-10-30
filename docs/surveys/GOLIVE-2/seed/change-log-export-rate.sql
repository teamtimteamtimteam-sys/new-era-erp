-- GOLIVE-2 Step 0 · 本地一年种子上:逐页(200 行)读 change_log_rows 的速率 —— 一条导出今天要走的路。以种子 cfo 身份,整笔回滚。只对本地跑。
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"b432a308-6cb1-a8c7-f8d1-72922bdd66cc","role":"authenticated"}', true) \g /dev/null
DO $r$
DECLARE v_before bigint; v_n int; v_tot int := 0; t0 timestamptz := clock_timestamp(); v_min bigint;
BEGIN
    FOR i IN 1..10 LOOP
        SELECT count(*), min(x.seq) INTO v_n, v_min FROM change_log_rows(p_from => '2025-03-01', p_to => '2025-03-07', p_before => v_before, p_limit => 200) x;
        v_tot := v_tot + v_n; v_before := v_min;
        EXIT WHEN v_n < 200;
    END LOOP;
    RAISE NOTICE 'RATE|% rows in % ms (% ms/row)', v_tot, round(extract(epoch FROM clock_timestamp()-t0)*1000),
        round((extract(epoch FROM clock_timestamp()-t0)*1000 / v_tot)::numeric, 2);
END $r$;
ROLLBACK;
SELECT 'COUNT|7 days 2025-03-01..07: ' || count(*) || ' rows · 366 days: ' || (SELECT count(*) FROM change_log WHERE occurred_at >= '2025-01-01' AND occurred_at < '2026-01-02') FROM change_log WHERE occurred_at >= '2025-03-01' AND occurred_at < '2025-03-08';

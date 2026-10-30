-- GOLIVE-2 Step 0 · 本地一年种子(db/seeds/chain-walk-year.sql)上模拟 /settings/change-history 的读法:
--   与 app/settings/change-history/page.tsx:108-141 同一组循环(事务 200 一块、行 100 一页、p_before / p_row_before 键集),
--   以种子里 cfo 的身份(SET LOCAL ROLE authenticated + request.jwt.claims),整笔回滚。:show 取 20 或 500。只对本地跑。
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{"sub":"b432a308-6cb1-a8c7-f8d1-72922bdd66cc","role":"authenticated"}', true) \g /dev/null
SELECT set_config('gl2.show', :'show', true) \g /dev/null
DO $sim$
DECLARE
    v_show int := current_setting('gl2.show')::int;
    v_target int; v_read int := 0; v_before bigint; v_rowbefore bigint; v_want int;
    v_calls int := 0; v_rows int := 0; v_part int; v_min bigint; v_tops int; v_mx bigint;
    t0 timestamptz := clock_timestamp();
BEGIN
    v_target := v_show + 1;
    WHILE v_read < v_target LOOP
        v_want := LEAST(200, v_target - v_read);
        CREATE TEMP TABLE IF NOT EXISTS sim_chunk (seq bigint, txid bigint) ON COMMIT DROP;
        TRUNCATE sim_chunk;
        v_rowbefore := NULL;
        LOOP
            INSERT INTO sim_chunk SELECT x.seq, x.txid FROM change_log_rows(p_by_entry => true, p_before => v_before, p_limit => v_want,
                   p_row_before => v_rowbefore, p_row_limit => 100) x;
            GET DIAGNOSTICS v_part = ROW_COUNT;
            v_calls := v_calls + 1; v_rows := v_rows + v_part;
            EXIT WHEN v_part < 100;
            SELECT min(seq) INTO v_rowbefore FROM (SELECT seq FROM sim_chunk ORDER BY seq LIMIT v_part) s;
        END LOOP;
        SELECT count(*), min(mx) INTO v_tops, v_mx FROM (SELECT txid, max(seq) mx FROM sim_chunk GROUP BY txid) g;
        v_read := v_read + v_tops;
        EXIT WHEN v_tops < v_want;
        v_before := v_mx;
    END LOOP;
    RAISE NOTICE 'SIM|show=% · % calls · % rows · % operations · % ms', v_show, v_calls, v_rows, v_read,
        round(extract(epoch FROM clock_timestamp() - t0) * 1000);
END $sim$;
ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 278 —— 变更记录页读一次几百行的批量操作:每一次调用的行数有上界、远在 8 秒之下,而几次调用合起来交出的行与一次取完【逐行相同】
--   (F19,MES-9c,2026-10-20,Tim;docs/known-issues.md CHANGE-HISTORY-8S-AFTER-BULK-GRANTS)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   BULK     自带一次批量操作:同一笔事务里 520 行被记录的写(520 个角色),再加几笔别的 —— 页面默认那一读(p_by_entry,21 次操作)里有它
--   SAME     页面的读法(app/settings/change-history/page.tsx:p_row_limit = 100,p_row_before = 上一页最小的 seq,直到不满一页):
--            交出的行(每一列,含审计记录的 actor / belongs_to / refs 与遮蔽)与不分页的那一次【逐行相同】—— 不多一行、不少一行、不重一行
--   BOUND    每一次分页调用至多 100 行;每一次都在 4 秒之内(8 秒上限的一半 —— "远在上限之下");调用次数 ≥ 6(520 行 / 100)
--   ROWMODE  不给 p_row_limit 的旧读法逐行不变(p_by_entry 与按行两种)
-- 注入(db/scripts/2026-10-20-mes9c-fixture-injections.py):① 函数无视 p_row_limit(一次交出全部)→ BOUND 红;② 游标写成 <=(重一行)→ SAME 红。
-- 自带数据(README 第 2 条);读者持 data.view_change_log(切成 authenticated + JWT,与页面同一个身份形状)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

DO $f278$
DECLARE
    u uuid := gen_random_uuid(); r uuid; i int;
    v_all jsonb; v_paged jsonb := '[]'::jsonb; v_part jsonb; v_n int; v_calls int := 0; v_before bigint; v_t0 timestamptz; v_ms numeric; v_max_ms numeric := 0;
    v_tx bigint; v_bulk int; v_old_entry jsonb; v_old_rows jsonb;
    c_cols text := 'seq, occurred_at, table_name, row_key, op, actor_account, actor_email, actor_employee, actor_employee_code, actor_employee_name, actor_kind, db_role, changed_columns, old, new, redacted_at, row_restricted, txid, actor, belongs_to, refs';
BEGIN
    -- ── BULK ───────────────────────────────────────────────────────────────
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (u, 'fx278@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx278-reader', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'data.view_change_log');
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    FOR i IN 1..520 LOOP
        INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx278-bulk-' || i, 'fixture 278 bulk ' || i, 'f', false);
    END LOOP;
    v_tx := txid_current();
    SELECT count(*) INTO v_bulk FROM change_log WHERE txid = v_tx;
    IF v_bulk < 500 THEN RAISE EXCEPTION 'FIXTURE 278 BULK: the bulk operation logged only % rows (need ≥ 500)', v_bulk; END IF;

    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    -- the page's default request, read at once (the "before" answer)
    EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.seq DESC), ''[]'') FROM (SELECT %s FROM public.change_log_rows(p_by_entry => true, p_limit => 21)) x', c_cols)
       INTO v_all;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_all) e WHERE (e ->> 'txid')::bigint = v_tx) THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 278 BULK: the bulk operation is not in the page''s default window';
    END IF;

    -- ── SAME + BOUND: the page's way, 100 rows a call ──────────────────────
    LOOP
        v_t0 := clock_timestamp();
        EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.seq DESC), ''[]'') FROM (SELECT %s FROM public.change_log_rows(p_by_entry => true, p_limit => 21, p_row_before => $1, p_row_limit => 100)) x', c_cols)
           INTO v_part USING v_before;
        v_ms := extract(epoch FROM clock_timestamp() - v_t0) * 1000;
        v_max_ms := GREATEST(v_max_ms, v_ms);
        v_calls := v_calls + 1;
        v_n := jsonb_array_length(v_part);
        IF v_n > 100 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION 'FIXTURE 278 BOUND: one paged call returned % rows (the limit is 100)', v_n; END IF;
        IF v_ms > 4000 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION 'FIXTURE 278 BOUND: one paged call took % ms (must stay well under the 8 s cap: ≤ 4,000)', round(v_ms); END IF;
        v_paged := v_paged || v_part;
        EXIT WHEN v_n < 100;
        SELECT min((e ->> 'seq')::bigint) INTO v_before FROM jsonb_array_elements(v_part) e;
        IF v_calls > 100 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION 'FIXTURE 278 BOUND: more than 100 calls — the cursor does not advance'; END IF;
    END LOOP;
    IF v_calls < 6 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION 'FIXTURE 278 BOUND: % call(s) for ≥ % rows — the page was not paged', v_calls, v_bulk; END IF;
    IF v_paged IS DISTINCT FROM v_all THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 278 SAME: paged % rows, at once % rows; first difference at seq %', jsonb_array_length(v_paged), jsonb_array_length(v_all),
            (SELECT min(a.s) FROM (SELECT (e ->> 'seq')::bigint s, e FROM jsonb_array_elements(v_all) e) a
              WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_paged) p WHERE p = a.e));
    END IF;

    -- ── ROWMODE: the old readings, unchanged (no p_row_limit) ──────────────
    EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.seq DESC), ''[]'') FROM (SELECT %s FROM public.change_log_rows(p_by_entry => true, p_limit => 21, p_row_before => NULL)) x', c_cols)
       INTO v_old_entry;
    EXECUTE format('SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.seq DESC), ''[]'') FROM (SELECT %s FROM public.change_log_rows(p_limit => 50)) x', c_cols)
       INTO v_old_rows;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF v_old_entry IS DISTINCT FROM v_all THEN RAISE EXCEPTION 'FIXTURE 278 ROWMODE: by-entry without p_row_limit changed'; END IF;
    IF jsonb_array_length(v_old_rows) <> 50 THEN RAISE EXCEPTION 'FIXTURE 278 ROWMODE: row mode returned % rows (expected 50)', jsonb_array_length(v_old_rows); END IF;
    IF v_old_rows IS DISTINCT FROM (SELECT jsonb_agg(e ORDER BY (e ->> 'seq')::bigint DESC) FROM (SELECT e FROM jsonb_array_elements(v_all) e ORDER BY (e ->> 'seq')::bigint DESC LIMIT 50) z) THEN
        RAISE EXCEPTION 'FIXTURE 278 ROWMODE: row mode does not read the newest 50 rows the by-entry reading reads'; END IF;

    RAISE NOTICE 'FIXTURE 278 全部通过: BULK (% rows in one operation) · SAME (% rows, % calls) · BOUND (slowest call % ms) · ROWMODE',
        v_bulk, jsonb_array_length(v_all), v_calls, round(v_max_ms);
END
$f278$;
ROLLBACK;

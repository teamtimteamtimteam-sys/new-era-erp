-- fixture 305 —— 变更记录的成批读法与字典页的一次计数,对【七个角色】与原来的读法逐行相同(GOLIVE-2 第 13 行,v1.4.84)
-- ═══════════════════════════════════════════════════════════════════════════
-- Tim 2026-10-30 Q2:"every result identical row for row to today's for all seven roles"。
-- 【数据】db/seeds/chain-walk-year.sql(一年的量,与 fixture 297 同一份)+ 七个角色的读码 db/seeds/seven-roles-2026-10-31.sql。整支回滚。
-- 【A】七个角色 × 八种读法(最新 20 次 · 200 次 · 只看关键事件那一圈要读的 100 次 · 一组表 · 一种记录 · 一条记录 · 一个人 · 一段日期):
--      change_log_page(一次调用)交出的行 ≡ 页面原来那一圈 change_log_rows(p_by_entry => true,事务 200 一块、行 100 一页)交出的行
--      (jsonb 逐行,按 seq);两边一起拒(只有持 data.view_change_log 的 admin 与 cfo 读得到)也算相同,拒的码要一样。
-- 【B】change_log_page 往前翻(p_before = next_before)四块 50 次接起来 ≡ 一次读 200 次;每一块的事务集合互不相交(一笔事务不被切开)。
-- 【C】change_log_count ≡ 以 postgres 对基表数同一组筛选的行数(一段日期、一组表)。
-- 【D】七个角色:dictionary_usage_counts(一次调用,页面注册表里那 32 对)≡ 每个字典值 × 每张引用表各数一次(页面原来的读法),按读者自己的权限。
-- 【E】故障注入:在子事务里让 change_log_page 少交最旧的一行 → A 的比对必须变红;让 dictionary_usage_counts 每一组多数一行 → D 必须变红。回滚后核对还原。
-- ★ 种子走 session_replication_role = replica(与 fixture 296 / 297 同一个先例:只在 db/gate.py 的一次性本地库上跑,线上从来不跑)。
BEGIN;
\ir ../seeds/seven-roles-2026-10-31.sql
\ir ../seeds/chain-walk-year.sql
SET LOCAL statement_timeout = '600s';

-- 页面原来的那一圈(app/settings/change-history/page.tsx 在 GOLIVE-2 之前的 108-141 行);两张暂存表建一次(读者也要写得进去)
CREATE TEMP TABLE f305_rows ON COMMIT DROP AS SELECT x.* FROM change_log_rows() x WHERE false;
CREATE TEMP TABLE f305_chunk ON COMMIT DROP AS SELECT x.* FROM change_log_rows() x WHERE false;
GRANT ALL ON f305_rows, f305_chunk TO authenticated;
CREATE FUNCTION pg_temp.f305_before(p_args text, p_target int) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_read int := 0; v_before bigint; v_rowbefore bigint; v_want int; v_part int; v_tops int; v_mx bigint; v text; a text := CASE WHEN p_args = '' THEN '' ELSE p_args || ', ' END;
BEGIN
    TRUNCATE f305_rows;
    WHILE v_read < p_target LOOP
        v_want := LEAST(200, p_target - v_read);
        TRUNCATE f305_chunk;
        v_rowbefore := NULL;
        LOOP
            EXECUTE format('INSERT INTO f305_chunk SELECT * FROM change_log_rows(%s p_by_entry => true, p_before => %L, p_limit => %s, p_row_before => %L, p_row_limit => 100)',
                           a, v_before, v_want, v_rowbefore);
            GET DIAGNOSTICS v_part = ROW_COUNT;
            EXIT WHEN v_part < 100;
            SELECT min(seq) INTO v_rowbefore FROM (SELECT seq FROM f305_chunk ORDER BY seq LIMIT v_part) s;
        END LOOP;
        INSERT INTO f305_rows SELECT * FROM f305_chunk;
        SELECT count(*), min(mx) INTO v_tops, v_mx FROM (SELECT txid, max(seq) mx FROM f305_chunk GROUP BY txid) g;
        v_read := v_read + v_tops;
        EXIT WHEN v_tops < v_want;
        v_before := v_mx;
    END LOOP;
    SELECT count(*) || ' rows ' || md5(COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.seq)::text, '')) INTO v FROM f305_rows r;
    RETURN v;
EXCEPTION WHEN OTHERS THEN RETURN 'refused ' || SQLSTATE || ' ' || split_part(SQLERRM, '|', 1);
END $f$;
CREATE FUNCTION pg_temp.f305_after(p_args text, p_target int) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text; a text := CASE WHEN p_args = '' THEN '' ELSE p_args || ', ' END; j jsonb;
BEGIN
    EXECUTE format('SELECT change_log_page(%s p_entries => %s)', a, p_target) INTO j;
    SELECT count(*) || ' rows ' || md5(COALESCE(jsonb_agg(e ORDER BY (e ->> 'seq')::bigint)::text, '')) INTO v FROM jsonb_array_elements(j -> 'rows') e;
    RETURN v;
EXCEPTION WHEN OTHERS THEN RETURN 'refused ' || SQLSTATE || ' ' || split_part(SQLERRM, '|', 1);
END $f$;
CREATE FUNCTION pg_temp.f305_cnt(t text, c text, v text) RETURNS bigint LANGUAGE plpgsql AS $f$ DECLARE n bigint; BEGIN
  EXECUTE format('SELECT count(*) FROM public.%I WHERE %I = $1', t, c) INTO n USING v; RETURN n; END $f$;
CREATE FUNCTION pg_temp.f305_codes(t text) RETURNS SETOF text LANGUAGE plpgsql AS $f$ BEGIN
  RETURN QUERY EXECUTE format('SELECT code::text FROM public.%I', t); END $f$;
CREATE FUNCTION pg_temp.f305_dict(p_one_call boolean) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text; j jsonb; refs jsonb := '[{"dict": "substances", "ref_table": "assay_result_metals", "ref_column": "metal"}, {"dict": "substances", "ref_table": "blending_plan_targets", "ref_column": "metal"}, {"dict": "substances", "ref_table": "contract_grade_specs", "ref_column": "metal"}, {"dict": "substances", "ref_table": "contract_penalty_elements", "ref_column": "substance"}, {"dict": "substances", "ref_table": "contract_pricing_terms", "ref_column": "metal"}, {"dict": "substances", "ref_table": "contract_refining_charges", "ref_column": "metal"}, {"dict": "substances", "ref_table": "inbound_batch_metals", "ref_column": "metal"}, {"dict": "substances", "ref_table": "material_required_metals", "ref_column": "metal"}, {"dict": "substances", "ref_table": "metal_prices", "ref_column": "metal"}, {"dict": "substances", "ref_table": "output_batch_metals", "ref_column": "metal"}, {"dict": "substances", "ref_table": "pricing_formula_history", "ref_column": "metal"}, {"dict": "substances", "ref_table": "pricing_formula_metals", "ref_column": "metal"}, {"dict": "substances", "ref_table": "pricing_term_commitment_metals", "ref_column": "metal"}, {"dict": "battery_chemistries", "ref_table": "materials", "ref_column": "chemistry"}, {"dict": "material_kinds", "ref_table": "materials", "ref_column": "kind_code"}, {"dict": "inbound_safety_states", "ref_table": "inbound_batch_safety_states", "ref_column": "safety_state_code"}, {"dict": "laboratories", "ref_table": "assay_results", "ref_column": "lab_name"}, {"dict": "inbound_source_reasons", "ref_table": "inbound_batches", "ref_column": "source_reason_code"}, {"dict": "nea_waste_categories", "ref_table": "materials", "ref_column": "nea_waste_category_code"}, {"dict": "nea_waste_categories", "ref_table": "licence_storage_limits", "ref_column": "category_code"}, {"dict": "dangerous_goods_codes", "ref_table": "materials", "ref_column": "dg_code"}, {"dict": "label_templates", "ref_table": "label_prints", "ref_column": "template_code"}, {"dict": "shifts", "ref_table": "processing_runs", "ref_column": "shift_code"}, {"dict": "shifts", "ref_table": "shift_handovers", "ref_column": "shift_code"}, {"dict": "processing_event_types", "ref_table": "processing_run_events", "ref_column": "event_type_code"}, {"dict": "cell_constructions", "ref_table": "inbound_batches", "ref_column": "cell_construction_code"}, {"dict": "cell_constructions", "ref_table": "output_batches", "ref_column": "cell_construction_code"}, {"dict": "contamination_streams", "ref_table": "contamination_checks", "ref_column": "stream_code"}, {"dict": "downtime_causes", "ref_table": "equipment_downtime", "ref_column": "cause_code"}, {"dict": "incident_kinds", "ref_table": "incidents", "ref_column": "kind_code"}, {"dict": "environmental_parameters", "ref_table": "environmental_results", "ref_column": "parameter_code"}, {"dict": "assay_indicators", "ref_table": "assay_result_indicators", "ref_column": "indicator"}]'::jsonb;
BEGIN
    IF p_one_call THEN j := dictionary_usage_counts(refs); END IF;
    SELECT md5(COALESCE(jsonb_agg(jsonb_build_array(d, code, n) ORDER BY d, code)::text, '')) || ' over ' || count(*) INTO v FROM (
      SELECT p.dict AS d, x.code,
             sum(CASE WHEN p_one_call THEN COALESCE((j -> (p.ref_table || '.' || p.ref_column) ->> x.code)::bigint, 0)
                      ELSE pg_temp.f305_cnt(p.ref_table, p.ref_column, x.code) END) AS n
        FROM jsonb_to_recordset(refs) AS p(dict text, ref_table text, ref_column text)
        CROSS JOIN LATERAL pg_temp.f305_codes(p.dict) x(code) GROUP BY 1, 2) s;
    RETURN v;
EXCEPTION WHEN OTHERS THEN RETURN 'refused ' || SQLSTATE || ' ' || split_part(SQLERRM, '|', 1);
END $f$;
-- 以某一位读者的身份跑一句(SET LOCAL ROLE authenticated + 那个账号的 claims),再回到 postgres
CREATE FUNCTION pg_temp.f305_as(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN v;
END $f$;
CREATE FUNCTION pg_temp.f305_compare() RETURNS int LANGUAGE plpgsql AS $f$
DECLARE r record; c record; b text; a text; bad int := 0; v_rec text; v_act text;
BEGIN
    SELECT row_key ->> 'id' INTO v_rec FROM change_log WHERE table_name = 'inbound_batches' ORDER BY seq DESC LIMIT 1;
    SELECT actor_account::text INTO v_act FROM change_log WHERE actor_account IS NOT NULL GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 1;
    FOR r IN SELECT ur.user_id, ro.code FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
              WHERE ur.revoked_at IS NULL AND ro.code IN ('admin','cco','cfo','cto','finance','gm','warehouse') ORDER BY ro.code LOOP
        FOR c IN SELECT * FROM (VALUES
                ('', 21), ('', 201), ('', 100),
                ('p_tables => ARRAY[''journal_entries'',''journal_lines'',''payments'',''payment_allocations'']', 41),
                ('p_table => ''inbound_batches''', 21),
                (format('p_record_ids => ARRAY[%L]', v_rec), 21),
                (format('p_actor => %L::uuid', v_act), 21),
                ('p_from => ''2025-02-01'', p_to => ''2025-02-03''', 21)) AS x(args, target) LOOP
            b := pg_temp.f305_as(r.user_id, format('SELECT pg_temp.f305_before(%L, %s)', c.args, c.target));
            a := pg_temp.f305_as(r.user_id, format('SELECT pg_temp.f305_after(%L, %s)', c.args, c.target));
            IF b IS DISTINCT FROM a THEN
                bad := bad + 1;
                RAISE NOTICE 'f305 DIFF % [%/%]: before % · after %', r.code, c.args, c.target, b, a;
            END IF;
        END LOOP;
        b := pg_temp.f305_as(r.user_id, 'SELECT pg_temp.f305_dict(false)');
        a := pg_temp.f305_as(r.user_id, 'SELECT pg_temp.f305_dict(true)');
        IF b IS DISTINCT FROM a OR b LIKE 'refused%' THEN
            bad := bad + 1;
            RAISE NOTICE 'f305 DIFF % dictionaries: before % · after %', r.code, b, a;
        END IF;
    END LOOP;
    RETURN bad;
END $f$;

DO $f305$
DECLARE v_bad int; v_readers int; v_def text; v_def2 text; v_cfo uuid; j jsonb; j2 jsonb; v_before bigint; v_rows int := 0;
        v_tx bigint[] := ARRAY[]::bigint[]; v_part bigint[]; k int; v_n bigint; v_m bigint;
BEGIN
    -- N · 体量是真的,七位读者都在
    IF (SELECT count(*) FROM change_log) < 100000 THEN RAISE EXCEPTION 'FIXTURE 305 N: the seed did not load (change_log %)', (SELECT count(*) FROM change_log); END IF;
    SELECT count(DISTINCT ro.code) INTO v_readers FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
     WHERE ur.revoked_at IS NULL AND ro.code IN ('admin','cco','cfo','cto','finance','gm','warehouse');
    IF v_readers <> 7 THEN RAISE EXCEPTION 'FIXTURE 305 N: % of seven readers in the seed', v_readers; END IF;
    -- A · D
    v_bad := pg_temp.f305_compare();
    IF v_bad <> 0 THEN RAISE EXCEPTION 'FIXTURE 305 A/D: % comparison(s) differ (see the notices above)', v_bad; END IF;
    -- B · 往前翻
    SELECT ur.user_id INTO v_cfo FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ro.code = 'cfo' AND ur.revoked_at IS NULL LIMIT 1;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_cfo), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    FOR k IN 1 .. 4 LOOP
        j := change_log_page(p_entries => 50, p_before => v_before);
        SELECT array_agg(DISTINCT (e ->> 'txid')::bigint) INTO v_part FROM jsonb_array_elements(j -> 'rows') e;
        IF v_tx && v_part THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION 'FIXTURE 305 B: block % repeats an operation of an earlier block', k; END IF;
        v_tx := v_tx || v_part; v_rows := v_rows + jsonb_array_length(j -> 'rows'); v_before := (j ->> 'next_before')::bigint;
    END LOOP;
    j2 := change_log_page(p_entries => 200);
    -- C · 计数
    v_n := change_log_count(p_from => '2025-02-01', p_to => '2025-02-28');
    v_m := change_log_count(p_tables => ARRAY['journal_entries', 'journal_lines']);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF jsonb_array_length(j2 -> 'rows') <> v_rows OR (SELECT count(DISTINCT (e ->> 'txid')::bigint) FROM jsonb_array_elements(j2 -> 'rows') e) <> cardinality(v_tx) THEN
        RAISE EXCEPTION 'FIXTURE 305 B: four blocks of 50 (% rows, % operations) are not one read of 200 (% rows)', v_rows, cardinality(v_tx), jsonb_array_length(j2 -> 'rows');
    END IF;
    IF v_n <> (SELECT count(*) FROM change_log WHERE occurred_at >= '2025-02-01'::date::timestamptz AND occurred_at < '2025-03-01'::date::timestamptz)
       OR v_m <> (SELECT count(*) FROM change_log WHERE table_name IN ('journal_entries', 'journal_lines')) THEN
        RAISE EXCEPTION 'FIXTURE 305 C: change_log_count disagrees with the base table (% / %)', v_n, v_m;
    END IF;
    -- E · 故障注入
    v_def := pg_get_functiondef('public.change_log_page(date,date,text,text[],text[],uuid,boolean,boolean,integer,bigint)'::regprocedure);
    BEGIN
        IF position(E'ORDER BY c.seq DESC\n    LOOP' IN v_def) = 0 THEN RAISE EXCEPTION 'FIXTURE 305 E: the injection anchor is gone from change_log_page'; END IF;
        EXECUTE replace(v_def, E'ORDER BY c.seq DESC\n    LOOP', E'ORDER BY c.seq DESC OFFSET 1\n    LOOP');
        IF pg_temp.f305_as(v_cfo, 'SELECT pg_temp.f305_before('''', 21)') = pg_temp.f305_as(v_cfo, 'SELECT pg_temp.f305_after('''', 21)') THEN
            RAISE EXCEPTION 'FIXTURE 305 E: with one row dropped the comparison still says same — arm A does not compare rows';
        END IF;
        RAISE EXCEPTION 'f305 injection ok';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'f305 injection ok' THEN RAISE; END IF;
    END;
    v_def2 := pg_get_functiondef('public.dictionary_usage_counts(jsonb)'::regprocedure);
    BEGIN
        IF position('count(*) AS n' IN v_def2) = 0 THEN RAISE EXCEPTION 'FIXTURE 305 E: the injection anchor is gone from dictionary_usage_counts'; END IF;
        EXECUTE replace(v_def2, 'count(*) AS n', 'count(*) + 1 AS n');
        IF pg_temp.f305_as(v_cfo, 'SELECT pg_temp.f305_dict(false)') = pg_temp.f305_as(v_cfo, 'SELECT pg_temp.f305_dict(true)') THEN
            RAISE EXCEPTION 'FIXTURE 305 E: with every count off by one the dictionary comparison still says same';
        END IF;
        RAISE EXCEPTION 'f305 injection ok';
    EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'f305 injection ok' THEN RAISE; END IF;
    END;
    IF pg_get_functiondef('public.change_log_page(date,date,text,text[],text[],uuid,boolean,boolean,integer,bigint)'::regprocedure) <> v_def
       OR pg_get_functiondef('public.dictionary_usage_counts(jsonb)'::regprocedure) <> v_def2 THEN
        RAISE EXCEPTION 'FIXTURE 305 E: an injection did not roll back';
    END IF;
    RAISE NOTICE 'FIXTURE 305 全部通过: 七个角色 × 八种读法,成批读法与原来那一圈逐行相同、字典的一次计数与逐值计数相同(A/D);往前翻接得起来、不切开事务(B);计数与基表一致(C);少交一行、多数一行都被抓住(E)';
END
$f305$;
ROLLBACK;

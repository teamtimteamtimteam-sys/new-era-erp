-- 249 MES-1:车间网关的入口 —— 匿名那一支只追加、什么都不回;一把钥匙是唯一的门(MES-0 Q4–Q9 · Q14;MES-1 Step 0 Q1–Q30;v1.4.37)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一条裁定;每一臂都有故障注入(db/scripts/2026-10-06-mes1-fixture-injections.py)必须让它红在它点名的那一臂。
--   DEV    设备登记只经 save_device(action.manage_devices);编号 DEV-YYYY-NNNN 保存时生成;不持码按名拒
--   GRANT  ingest_submit:anon 调得到,authenticated 与 service_role【都】调不到(Q4);public 里 anon 能执行的【恰好】两支;
--          内层(分派器、转换器)authenticated 与 anon 都调不到;员工那几支 anon 调不到;十二张新表 / 视图 anon 一行都读不到
--   POL    那 44 条对 authenticated USING (true) 的读策略还是 44 条,而且【没有一条】落在 MES-1 的表上(Q27)
--   HASH   钥匙的哈希谁都看不见:列授权里没有、读基表 42501、遮蔽视图恒为空、变更记录 never 规则、审计记录里没有那串字(Q20)
--   APPEND 匿名那一次调用【只】写收件箱、传输日志、网关中断三张表(按事务内的逐表计数 pg_stat_xact_user_tables 证),
--          不删任何东西,唯一的 UPDATE 落在传输日志的桶上(Q7 · Q8)
--   RESP   每一个回答的键 ⊆ {ok, accepted, duplicates, rejected, code};一行表内容都不回
--   AUTH   不认识的网关 · 错的钥匙 · 别的网关的钥匙 · 撤了的钥匙 · 停用的网关 —— 回答【逐字】是 {"ok": false, "code": "refused"}(Q10),
--          确切理由只在日志里
--   SIZE   太大(> 256 KB)· 太多(> 500 条)· 形状不对 —— 认证过的照名回;没认证的照样只得到 refused
--   OWN    一条消息说的是别的网关带着的设备 → DEVICE_NOT_ON_THIS_GATEWAY,不落行(Q6 · Q15)
--   SEQ    同一份再来 = duplicates;同号不同份 = SEQ_REUSED(不落行、日志与异常视图里有);重启后的新流从 1 起照收;
--          缺号按流列出;site_to 超前 5 分钟以上标 clock_ahead(Q13)
--   HB     心跳只让这一小时那一行桶往上长(两次 → 2),不落收件箱;桶只经函数、只增;一次调用那一行一个字不改;删不掉(Q8)
--   STAT   读的时候算:从没听到 → not_yet_heard;间隔没给 → interval_not_set;超过间隔 → silent(上 gateway_silent 那一支);
--          沉默之后回来记一段中断;间隔没给就不记(Q16 · Q17 · MES-0 Q9)
--   PV     pending_values 列 V5(间隔为空的网关)与 V6(起止为空的班次),每一行带它的码;不持码的人一行都看不见(Q2)
--   XF     connection_test:成功 · 失败(看得见、带码)· 待转换 · 重试 · 丢弃(要理由,失败的码留着)· 永远删不掉;
--          处理要 module.processing.view,重试 / 丢弃要 action.manage_devices;状态只经函数改(Q11 · Q12 · Q15)
--   ROT    同一台网关最多两把有效;第二把在旁边照用;撤第一把之后第二把照用;撤了的不能再撤;撤一台的钥匙碰不到另一台(Q5)
--   LIM    同一个报上来的编号 30 次失败之后不再一行一行记(进 10 分钟一行的溢出桶);全部失败 300 次之后同样;
--          回答不变;持有效钥匙的调用永远不被限(Q9)
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS)—— 匿名的调用真的切成 anon,员工的读写真的切成 authenticated + 那个人的 JWT。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f249_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;成功回 'OK',失败回错误原文(SQLSTATE 42501 回 '42501')
CREATE FUNCTION pg_temp.f249_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f249_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN CASE WHEN SQLSTATE = '42501' AND SQLERRM NOT LIKE 'PERMISSION_DENIED%' THEN '42501' ELSE SQLERRM END;
END;
$f$;

-- 以某人的身份读一个 jsonb;读不出来就抛,带着臂名 —— 一次失败不许被读成 0 或 NULL
CREATE FUNCTION pg_temp.f249_read(p_arm text, p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f249_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RAISE EXCEPTION 'FIXTURE 249 %: the read failed: % — %', p_arm, SQLSTATE, SQLERRM;
END;
$f$;

-- 真的以 anon 调一次网关入口(没有 JWT)—— PostgREST 对一个只带公开 apikey 的请求就是这么做的
CREATE FUNCTION pg_temp.f249_gw(p_gw text, p_key text, p_body jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE 'SET LOCAL ROLE anon';
    v := public.ingest_submit(p_gw, p_key, p_body);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RAISE EXCEPTION 'FIXTURE 249 ANON: ingest_submit raised instead of answering: % — %', SQLSTATE, SQLERRM;
END;
$f$;

-- 一条消息
CREATE FUNCTION pg_temp.f249_msg(p_seq bigint, p_dev text, p_class text, p_payload jsonb, p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_strip_nulls(jsonb_build_object('seq', p_seq, 'device', p_dev, 'class', p_class, 'payload', p_payload,
        'site_from', to_jsonb(COALESCE(p_to, now()) - interval '1 minute'), 'site_to', to_jsonb(COALESCE(p_to, now())),
        'dataset_ref', 'fx249/' || p_seq))
$f$;

CREATE TEMP TABLE f249_resp (n integer, label text, body jsonb) ON COMMIT DROP;

DO $$
DECLARE
    u_mgr  uuid := gen_random_uuid();   -- action.manage_devices + module.processing.view(cto / admin 的形状)
    u_view uuid := gen_random_uuid();   -- 只看加工(仓库的形状)
    u_none uuid := gen_random_uuid();   -- 一个码都没有
    u_keep uuid := gen_random_uuid();
    r_mgr uuid; r_view uuid; r_none uuid;
    gA uuid; gB uuid; gC uuid; gD uuid; dA uuid; dA2 uuid; dB uuid; dX uuid;
    cA text; cB text; cC text; cD text; cdA text; cdA2 text; cdB text;
    kA1 text; kA2 text; kB1 text; kC1 text; kA1_id uuid; kA2_id uuid;
    v_j jsonb; v_r jsonb; v_msg text; v_n int; v_m int; v_t text; v_x bigint; v_b bytea;
    v_msgs jsonb; v_big text; i int;
    rel text;
    f text;
BEGIN
    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_mgr, 'fx249-mgr@test.local', now(), now()), (u_view, 'fx249-view@test.local', now(), now()),
        (u_none, 'fx249-none@test.local', now(), now()), (u_keep, 'fx249-keep@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx249-mgr', 'f', 'f', true) RETURNING id INTO r_mgr;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx249-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx249-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_mgr, 'action.manage_devices'), (r_mgr, 'module.processing.view'),
        (r_view, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_mgr, r_mgr), (u_view, r_view), (u_none, r_none);

    -- ══════════════ DEV · 登记只经函数,编号保存时生成 ══════════════
    v_msg := pg_temp.f249_try(u_view, $q$SELECT save_device('{"name":"x","kind":"gateway"}'::jsonb)$q$);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN
        RAISE EXCEPTION 'FIXTURE 249 DEV: a reader without action.manage_devices registered a device: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, $q$INSERT INTO devices (name, kind) VALUES ('direct', 'gateway')$q$);
    IF v_msg IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'FIXTURE 249 DEV: a direct insert into devices was not refused: %', v_msg; END IF;
    gA := (pg_temp.f249_read('DEV', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF249 gateway A","kind":"gateway"}'::jsonb))$q$)) #>> '{}';
    gB := (pg_temp.f249_read('DEV', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF249 gateway B","kind":"gateway","heartbeat_interval_s":60}'::jsonb))$q$)) #>> '{}';
    gC := (pg_temp.f249_read('DEV', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF249 gateway C","kind":"gateway"}'::jsonb))$q$)) #>> '{}';
    gD := (pg_temp.f249_read('DEV', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF249 gateway D","kind":"gateway","heartbeat_interval_s":60}'::jsonb))$q$)) #>> '{}';
    dA := (pg_temp.f249_read('DEV', u_mgr, format($q$SELECT to_jsonb(save_device(jsonb_build_object('name','ZZF249 scale A','kind','scale','gateway_id',%L,'data_class','connection_test')))$q$, gA))) #>> '{}';
    dA2 := (pg_temp.f249_read('DEV', u_mgr, format($q$SELECT to_jsonb(save_device(jsonb_build_object('name','ZZF249 scale A2','kind','scale','gateway_id',%L,'data_class','meter_reading')))$q$, gA))) #>> '{}';
    dB := (pg_temp.f249_read('DEV', u_mgr, format($q$SELECT to_jsonb(save_device(jsonb_build_object('name','ZZF249 scale B','kind','scale','gateway_id',%L,'data_class','connection_test')))$q$, gB))) #>> '{}';
    SELECT code INTO cA FROM devices WHERE id = gA; SELECT code INTO cB FROM devices WHERE id = gB;
    SELECT code INTO cC FROM devices WHERE id = gC; SELECT code INTO cD FROM devices WHERE id = gD;
    SELECT code INTO cdA FROM devices WHERE id = dA; SELECT code INTO cdA2 FROM devices WHERE id = dA2;
    SELECT code INTO cdB FROM devices WHERE id = dB;
    IF cA !~ ('^' || document_type_prefix('device') || '-[0-9]{4}-[0-9]{4}$') THEN
        RAISE EXCEPTION 'FIXTURE 249 DEV: a device code is not DEV-YYYY-NNNN: %', cA; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format($q$SELECT save_device('{"kind":"scale"}'::jsonb, %L)$q$, gA));
    IF v_msg NOT LIKE 'DEVICE_KIND_FIXED|%' THEN RAISE EXCEPTION 'FIXTURE 249 DEV: a gateway became a scale: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format($q$SELECT save_device(jsonb_build_object('name','x','kind','scale','gateway_id',%L))$q$, dA));
    IF v_msg IS DISTINCT FROM 'DEVICE_GATEWAY_INVALID' THEN RAISE EXCEPTION 'FIXTURE 249 DEV: a scale was carried by a scale: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, $q$SELECT save_device('{"name":"x","kind":"scale","colour":"red"}'::jsonb)$q$);
    IF v_msg IS DISTINCT FROM 'DEVICE_FIELD_UNKNOWN|colour' THEN RAISE EXCEPTION 'FIXTURE 249 DEV: an unknown field was accepted: %', v_msg; END IF;

    -- ══════════════ 钥匙 ══════════════
    v_msg := pg_temp.f249_try(u_view, format('SELECT issue_gateway_key(%L)', gA));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN
        RAISE EXCEPTION 'FIXTURE 249 ROT: a reader without action.manage_devices issued a key: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT issue_gateway_key(%L)', dA));
    IF v_msg NOT LIKE 'GATEWAY_KEY_NOT_A_GATEWAY|%' THEN RAISE EXCEPTION 'FIXTURE 249 ROT: a scale got a key: %', v_msg; END IF;
    v_j := pg_temp.f249_read('ROT', u_mgr, format('SELECT issue_gateway_key(%L)', gA)); kA1 := v_j ->> 'secret'; kA1_id := v_j ->> 'key_id';
    v_j := pg_temp.f249_read('ROT', u_mgr, format('SELECT issue_gateway_key(%L)', gB)); kB1 := v_j ->> 'secret';
    v_j := pg_temp.f249_read('ROT', u_mgr, format('SELECT issue_gateway_key(%L)', gC)); kC1 := v_j ->> 'secret';
    IF kA1 !~ '^ngk_[0-9a-f]{64}$' OR (v_j ->> 'prefix') IS DISTINCT FROM substr(kC1, 5, 8) THEN
        RAISE EXCEPTION 'FIXTURE 249 ROT: the secret is not ngk_ + 64 hex, or the prefix is not its first 8: % / %', kA1, v_j; END IF;
    IF EXISTS (SELECT 1 FROM gateway_keys WHERE key_hash IS DISTINCT FROM sha256(convert_to(kA1, 'UTF8')) AND id = kA1_id) THEN
        RAISE EXCEPTION 'FIXTURE 249 ROT: the stored hash is not sha256 of the secret'; END IF;

    -- ══════════════ HASH · 哈希谁都看不见 ══════════════
    IF has_column_privilege('authenticated', 'public.gateway_keys', 'key_hash', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 249 HASH: gateway_keys.key_hash is SELECT-granted to authenticated'; END IF;
    v_msg := pg_temp.f249_try(u_mgr, 'SELECT key_hash FROM gateway_keys LIMIT 1');
    IF v_msg IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'FIXTURE 249 HASH: reading key_hash from the base table was not refused: %', v_msg; END IF;
    v_j := pg_temp.f249_read('HASH', u_mgr, 'SELECT jsonb_build_object(''n'', count(*), ''shown'', count(key_hash)) FROM gateway_keys_masked');
    IF (v_j ->> 'n')::int < 3 OR (v_j ->> 'shown')::int IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 249 HASH: gateway_keys_masked shows a key hash (or reads no keys): %', v_j; END IF;
    PERFORM pg_temp.f249_as(u_mgr);
    IF change_log_rule_visible('never', 'gateway_keys', jsonb_build_object('id', kA1_id), NULL, NULL) THEN
        RAISE EXCEPTION 'FIXTURE 249 HASH: the never rule answered visible'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log_mask_rules() r WHERE r.table_name = 'gateway_keys' AND r.column_name = 'key_hash' AND r.rule = 'never') THEN
        RAISE EXCEPTION 'FIXTURE 249 HASH: the change log has no never rule for gateway_keys.key_hash'; END IF;
    PERFORM pg_temp.f249_as(NULL);
    SELECT key_hash INTO v_b FROM gateway_keys WHERE id = kA1_id;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM pg_temp.f249_as(u_mgr);
    SELECT COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb) INTO v_j FROM record_trail('device', gA::text, 200) r;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f249_as(NULL);
    IF jsonb_array_length(v_j) = 0 THEN RAISE EXCEPTION 'FIXTURE 249 HASH: the device trail is empty — the probe saw nothing'; END IF;
    IF position(encode(v_b, 'hex') IN v_j::text) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 249 HASH: the device trail carries the key hash'; END IF;

    -- ══════════════ GRANT · 谁调得到、谁读得到 ══════════════
    IF NOT has_function_privilege('anon', 'public.ingest_submit(text,text,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 249 GRANT: anon cannot execute ingest_submit'; END IF;
    IF has_function_privilege('authenticated', 'public.ingest_submit(text,text,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 249 GRANT: authenticated can execute ingest_submit (Q4)'; END IF;
    IF has_function_privilege('service_role', 'public.ingest_submit(text,text,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 249 GRANT: service_role can execute ingest_submit (Q4)'; END IF;
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_t
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_t IS DISTINCT FROM 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'FIXTURE 249 GRANT: anon executes more (or less) than the two doors: %', v_t; END IF;
    FOREACH f IN ARRAY ARRAY['public.ingest_transform_row(bigint)', 'public.transform_connection_test_v1(jsonb)'] LOOP
        IF has_function_privilege('authenticated', f, 'EXECUTE') OR has_function_privilege('anon', f, 'EXECUTE') THEN
            RAISE EXCEPTION 'FIXTURE 249 GRANT: the inner function % is callable from outside', f; END IF;
    END LOOP;
    FOREACH f IN ARRAY ARRAY['public.issue_gateway_key(uuid)', 'public.revoke_gateway_key(uuid,text)', 'public.save_device(jsonb,uuid)',
                             'public.retire_device(uuid,text)', 'public.set_ingest_settings(jsonb)', 'public.ingest_process_pending(integer)',
                             'public.retry_inbox_row(bigint)', 'public.discard_inbox_row(bigint,text)'] LOOP
        IF has_function_privilege('anon', f, 'EXECUTE') THEN
            RAISE EXCEPTION 'FIXTURE 249 GRANT: anon can execute %', f; END IF;
        IF NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
            RAISE EXCEPTION 'FIXTURE 249 GRANT: a staff function is not executable by authenticated: %', f; END IF;
    END LOOP;
    v_n := 0;
    FOREACH rel IN ARRAY ARRAY['devices', 'gateway_keys', 'ingest_settings', 'ingest_data_classes', 'ingest_inbox',
                               'ingest_transmissions', 'gateway_outages', 'gateway_keys_masked', 'gateway_health',
                               'ingest_sequence_gaps', 'ingest_transmission_anomalies', 'pending_values'] LOOP
        v_n := v_n + 1;
        IF has_table_privilege('anon', 'public.' || rel, 'SELECT') THEN
            RAISE EXCEPTION 'FIXTURE 249 GRANT: anon holds SELECT on %', rel; END IF;
        BEGIN
            PERFORM set_config('request.jwt.claims', '', true);
            EXECUTE 'SET LOCAL ROLE anon';
            EXECUTE format('SELECT count(*) FROM public.%I', rel) INTO v_m;
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'FIXTURE 249 GRANT: anon read % row(s) of %', v_m, rel;
        EXCEPTION WHEN insufficient_privilege THEN
            EXECUTE 'RESET ROLE';
        END;
    END LOOP;
    IF v_n IS DISTINCT FROM 12 THEN RAISE EXCEPTION 'FIXTURE 249 GRANT: swept % relations, expected 12', v_n; END IF;

    -- ══════════════ POL · 那 44 条没动,也没有一条在 MES-1 的表上 ══════════════
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles) AND cmd IN ('SELECT', 'ALL');
    IF v_n IS DISTINCT FROM 44 THEN RAISE EXCEPTION 'FIXTURE 249 POL: % open read policies for authenticated, expected 44', v_n; END IF;
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND qual = 'true'
       AND tablename IN ('devices', 'gateway_keys', 'ingest_settings', 'ingest_data_classes', 'ingest_inbox',
                         'ingest_transmissions', 'gateway_outages');
    IF v_n IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FIXTURE 249 POL: % USING (true) polic(ies) on a MES-1 table', v_n; END IF;
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND tablename IN ('devices', 'gateway_keys', 'ingest_settings', 'ingest_data_classes',
                                                    'ingest_inbox', 'ingest_transmissions', 'gateway_outages');
    IF v_n IS DISTINCT FROM 7 THEN RAISE EXCEPTION 'FIXTURE 249 POL: the seven MES-1 tables carry % policies, expected one read policy each', v_n; END IF;

    -- ══════════════ STAT(之前)· 从没听到过 ══════════════
    v_t := pg_temp.f249_read('STAT', u_view, format('SELECT to_jsonb(status) FROM gateway_health WHERE gateway_id = %L', gC)) #>> '{}';
    IF v_t IS DISTINCT FROM 'not_yet_heard' THEN RAISE EXCEPTION 'FIXTURE 249 STAT: a gateway never heard from reads %', v_t; END IF;

    -- ══════════════ APPEND · 匿名那一次只写三张日志 ══════════════
    -- B 三小时前心跳过一次(直接插一行桶 —— 守卫只管改,不管插),间隔 60 秒:它下一次回来要记一段中断
    INSERT INTO ingest_transmissions (kind, received_at, gateway_id, bucket_start, bucket_count, bucket_bytes, bucket_first_at, bucket_last_at)
    VALUES ('heartbeat_hour', now() - interval '3 hours', gB, date_trunc('hour', now() - interval '3 hours'), 1, 20,
            now() - interval '3 hours', now() - interval '3 hours');
    CREATE TEMP TABLE f249_before ON COMMIT DROP AS
    SELECT relname, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_xact_user_tables WHERE schemaname = 'public';

    v_msgs := jsonb_build_array(
        pg_temp.f249_msg(1, cdA, 'connection_test', '{"text":"hello"}'),
        pg_temp.f249_msg(2, cdA, 'connection_test', '{}'),
        pg_temp.f249_msg(5, cdA2, 'meter_reading', '{"text":"12.5 kg"}'),  -- MES-2:weighing 接上了转换器,"还没有转换器的类"改用 meter_reading
        pg_temp.f249_msg(6, cdB, 'connection_test', '{"text":"not mine"}'),
        pg_temp.f249_msg(7, cdA, 'no_such_class', '{"text":"?"}'),
        '{"device":"x","class":"connection_test","payload":{}}'::jsonb,
        pg_temp.f249_msg(8, cdA, 'connection_test', '{"text":"from the future"}', now() + interval '10 minutes'));
    INSERT INTO f249_resp VALUES (1, 'data', pg_temp.f249_gw(cA, kA1, jsonb_build_object('stream', 's1', 'messages', v_msgs)));
    INSERT INTO f249_resp VALUES (2, 'duplicate', pg_temp.f249_gw(cA, kA1, jsonb_build_object('stream', 's1',
        'messages', jsonb_build_array(pg_temp.f249_msg(1, cdA, 'connection_test', '{"text":"hello"}')))));
    INSERT INTO f249_resp VALUES (3, 'reused', pg_temp.f249_gw(cA, kA1, jsonb_build_object('stream', 's1',
        'messages', jsonb_build_array(pg_temp.f249_msg(2, cdA, 'connection_test', '{"text":"a different payload"}')))));
    INSERT INTO f249_resp VALUES (4, 'restart', pg_temp.f249_gw(cA, kA1, jsonb_build_object('stream', 's2',
        'messages', jsonb_build_array(pg_temp.f249_msg(1, cdA, 'connection_test', '{"text":"after a restart"}')))));
    INSERT INTO f249_resp VALUES (5, 'heartbeat', pg_temp.f249_gw(cA, kA1, '{"heartbeat":true}'));
    INSERT INTO f249_resp VALUES (6, 'heartbeat', pg_temp.f249_gw(cA, kA1, '{"heartbeat":true}'));
    INSERT INTO f249_resp VALUES (7, 'reconnect', pg_temp.f249_gw(cB, kB1, '{"heartbeat":true}'));
    INSERT INTO f249_resp VALUES (8, 'bad_key', pg_temp.f249_gw(cA, 'ngk_' || repeat('0', 64), '{"heartbeat":true}'));
    INSERT INTO f249_resp VALUES (9, 'unknown_gateway', pg_temp.f249_gw('DEV-0000-0000', kA1, '{"heartbeat":true}'));
    INSERT INTO f249_resp VALUES (10, 'other_key', pg_temp.f249_gw(cA, kB1, '{"heartbeat":true}'));
    v_big := repeat('x', 270000);
    INSERT INTO f249_resp VALUES (11, 'too_large', pg_temp.f249_gw(cA, kA1, jsonb_build_object('stream', 's3',
        'messages', jsonb_build_array(pg_temp.f249_msg(1, cdA, 'connection_test', jsonb_build_object('text', v_big))))));
    SELECT jsonb_agg(pg_temp.f249_msg(g, cdA, 'connection_test', '{"text":"x"}')) INTO v_msgs FROM generate_series(1, 501) g;
    INSERT INTO f249_resp VALUES (12, 'too_many', pg_temp.f249_gw(cA, kA1, jsonb_build_object('stream', 's3', 'messages', v_msgs)));
    INSERT INTO f249_resp VALUES (13, 'malformed', pg_temp.f249_gw(cA, kA1, jsonb_build_object('messages', '[]'::jsonb)));
    INSERT INTO f249_resp VALUES (15, 'starts_at_3', pg_temp.f249_gw(cB, kB1, jsonb_build_object('stream', 'b1',
        'messages', jsonb_build_array(pg_temp.f249_msg(3, cdB, 'connection_test', '{"text":"from B"}')))));
    INSERT INTO f249_resp VALUES (14, 'too_large_unauthenticated', pg_temp.f249_gw(cA, 'wrong', jsonb_build_object('stream', 's3',
        'messages', jsonb_build_array(pg_temp.f249_msg(1, cdA, 'connection_test', jsonb_build_object('text', v_big))))));

    SELECT string_agg(format('%s ins+%s upd+%s del+%s', a.relname, a.n_tup_ins - COALESCE(b.n_tup_ins, 0),
                             a.n_tup_upd - COALESCE(b.n_tup_upd, 0), a.n_tup_del - COALESCE(b.n_tup_del, 0)), '; ')
      INTO v_t
      FROM pg_stat_xact_user_tables a LEFT JOIN f249_before b ON b.relname = a.relname
     WHERE a.schemaname = 'public'
       AND (a.n_tup_ins - COALESCE(b.n_tup_ins, 0) > 0 OR a.n_tup_upd - COALESCE(b.n_tup_upd, 0) > 0
            OR a.n_tup_del - COALESCE(b.n_tup_del, 0) > 0)
       AND (a.relname NOT IN ('ingest_transmissions', 'ingest_inbox', 'gateway_outages')
            OR a.n_tup_del - COALESCE(b.n_tup_del, 0) > 0
            OR (a.relname <> 'ingest_transmissions' AND a.n_tup_upd - COALESCE(b.n_tup_upd, 0) > 0));
    IF v_t IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 249 APPEND: the anonymous calls wrote outside the three ingestion logs (or deleted / updated): %', v_t; END IF;
    SELECT count(*) INTO v_n FROM pg_stat_xact_user_tables a LEFT JOIN f249_before b ON b.relname = a.relname
     WHERE a.schemaname = 'public' AND a.relname IN ('ingest_transmissions', 'ingest_inbox')
       AND a.n_tup_ins - COALESCE(b.n_tup_ins, 0) > 0;
    -- 覆盖:计数器真的看见了收件箱与传输日志被写 —— 否则上面那句"别处一行都没写"可能只是计数器瞎了。
    -- (中断那一张写没写,是 STAT 那一臂的问题,不在这里问。)
    IF v_n IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FIXTURE 249 APPEND: the per-table counters saw % of the inbox and the transmission log written — the probe is blind', v_n; END IF;

    -- ══════════════ RESP · 回答只有固定的几个键 ══════════════
    SELECT string_agg(format('%s:%s', r.label, k), ', ') INTO v_t
      FROM f249_resp r, jsonb_object_keys(r.body) k
     WHERE k NOT IN ('ok', 'accepted', 'duplicates', 'rejected', 'code');
    IF v_t IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 249 RESP: an answer carries more than acknowledgements: %', v_t; END IF;
    IF (SELECT count(*) FROM f249_resp) IS DISTINCT FROM 15 THEN RAISE EXCEPTION 'FIXTURE 249 RESP: % answers recorded, expected 15', (SELECT count(*) FROM f249_resp); END IF;
    SELECT body INTO v_r FROM f249_resp WHERE n = 1;

    -- ══════════════ AUTH · 一句话的拒绝,理由只在日志里 ══════════════
    SELECT string_agg(format('%s → %s', label, body), '; ') INTO v_t FROM f249_resp
     WHERE n IN (8, 9, 10, 14) AND body <> '{"ok": false, "code": "refused"}'::jsonb;
    IF v_t IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 249 AUTH: a refusal said more than "refused": %', v_t; END IF;
    SELECT string_agg(result, ',' ORDER BY id) INTO v_t FROM ingest_transmissions
     WHERE kind = 'call' AND result IN ('bad_key', 'unknown_gateway');
    IF v_t IS DISTINCT FROM 'bad_key,unknown_gateway,bad_key,bad_key' THEN
        RAISE EXCEPTION 'FIXTURE 249 AUTH: the log does not name the exact reasons: %', v_t; END IF;
    IF (SELECT gateway_id FROM ingest_transmissions WHERE kind = 'call' AND result = 'unknown_gateway' LIMIT 1) IS NOT NULL
       OR (SELECT presented_gateway FROM ingest_transmissions WHERE kind = 'call' AND result = 'unknown_gateway' LIMIT 1) IS DISTINCT FROM 'DEV-0000-0000' THEN
        RAISE EXCEPTION 'FIXTURE 249 AUTH: the unknown-gateway row does not keep what was presented'; END IF;

    -- ══════════════ SIZE ══════════════
    IF (SELECT body FROM f249_resp WHERE n = 11) IS DISTINCT FROM '{"ok": false, "code": "too_large"}'::jsonb
       OR (SELECT body FROM f249_resp WHERE n = 12) IS DISTINCT FROM '{"ok": false, "code": "too_many"}'::jsonb
       OR (SELECT body FROM f249_resp WHERE n = 13) IS DISTINCT FROM '{"ok": false, "code": "malformed"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 SIZE: the limits did not hold: %', (SELECT jsonb_agg(body ORDER BY n) FROM f249_resp WHERE n BETWEEN 11 AND 13); END IF;
    IF EXISTS (SELECT 1 FROM ingest_inbox WHERE stream = 's3') THEN
        RAISE EXCEPTION 'FIXTURE 249 SIZE: a refused call left rows in the inbox'; END IF;
    SELECT string_agg(result, ',' ORDER BY id) INTO v_t FROM ingest_transmissions
     WHERE kind = 'call' AND result IN ('too_large', 'too_many', 'malformed');
    IF v_t IS DISTINCT FROM 'too_large,too_many,malformed' THEN RAISE EXCEPTION 'FIXTURE 249 SIZE: the log reads %', v_t; END IF;

    -- ══════════════ OWN · 别的网关带着的设备 ══════════════
    IF NOT (v_r -> 'rejected') @> '[{"seq": 6, "code": "DEVICE_NOT_ON_THIS_GATEWAY"}]'::jsonb
       OR NOT (v_r -> 'rejected') @> '[{"seq": 7, "code": "CLASS_UNKNOWN"}]'::jsonb
       OR NOT (v_r -> 'rejected') @> '[{"index": 5, "code": "ENVELOPE_INVALID"}]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 OWN: the envelope refusals read %', v_r -> 'rejected'; END IF;
    IF EXISTS (SELECT 1 FROM ingest_inbox WHERE seq IN (6, 7) AND stream = 's1') OR EXISTS (SELECT 1 FROM ingest_inbox WHERE device_id = dB AND gateway_id = gA) THEN
        RAISE EXCEPTION 'FIXTURE 249 OWN: an envelope refusal was stored'; END IF;
    IF v_r -> 'accepted' IS DISTINCT FROM '[1, 2, 5, 8]'::jsonb OR v_r -> 'duplicates' IS DISTINCT FROM '[]'::jsonb
       OR jsonb_array_length(v_r -> 'rejected') IS DISTINCT FROM 3 THEN
        RAISE EXCEPTION 'FIXTURE 249 OWN: the first data call answered %', v_r; END IF;

    -- ══════════════ SEQ ══════════════
    IF (SELECT body FROM f249_resp WHERE n = 2) IS DISTINCT FROM '{"ok": true, "accepted": [], "rejected": [], "duplicates": [1]}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 SEQ: the same message again was not a duplicate: %', (SELECT body FROM f249_resp WHERE n = 2); END IF;
    IF (SELECT body -> 'rejected' FROM f249_resp WHERE n = 3) IS DISTINCT FROM '[{"seq": 2, "code": "SEQ_REUSED", "index": 0}]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 SEQ: a reused sequence number was not refused: %', (SELECT body FROM f249_resp WHERE n = 3); END IF;
    IF (SELECT payload FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 2) IS DISTINCT FROM '{}'::jsonb
       OR (SELECT count(*) FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq IN (1, 2)) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 249 SEQ: a duplicate or a reused number changed what was stored'; END IF;
    IF (SELECT body -> 'accepted' FROM f249_resp WHERE n = 4) IS DISTINCT FROM '[1]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 SEQ: a new stream after a restart was not accepted from 1'; END IF;
    v_j := pg_temp.f249_read('SEQ', u_view, format(
        $q$SELECT COALESCE(jsonb_agg(jsonb_build_array(stream, missing_from, missing_to) ORDER BY stream, missing_from), '[]') FROM ingest_sequence_gaps WHERE gateway_id = %L$q$, gA));
    IF v_j IS DISTINCT FROM '[["s1", 3, 4], ["s1", 6, 7]]'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 SEQ: the gaps read %', v_j; END IF;
    v_j := pg_temp.f249_read('SEQ', u_view, format(
        $q$SELECT COALESCE(jsonb_agg(jsonb_build_array(stream, missing_from, missing_to) ORDER BY stream, missing_from), '[]') FROM ingest_sequence_gaps WHERE gateway_id = %L$q$, gB));
    IF v_j IS DISTINCT FROM '[["b1", 1, 2]]'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 SEQ: a stream that starts at 3 shows gaps %', v_j; END IF;
    IF NOT (SELECT clock_ahead FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 8)
       OR (SELECT clock_ahead FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 1) THEN
        RAISE EXCEPTION 'FIXTURE 249 SEQ: clock-ahead was not flagged (or flagged the wrong one)'; END IF;
    v_j := pg_temp.f249_read('SEQ', u_view, format(
        $q$SELECT COALESCE(jsonb_agg(anomaly ORDER BY anomaly), '[]') FROM ingest_transmission_anomalies WHERE gateway_id = %L AND anomaly IN ('seq_reused', 'clock_ahead')$q$, gA));
    IF v_j IS DISTINCT FROM '["clock_ahead", "seq_reused"]'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 SEQ: the anomalies read %', v_j; END IF;

    -- ══════════════ HB · 心跳只让桶往上长 ══════════════
    SELECT bucket_count, id INTO v_n, v_x FROM ingest_transmissions
     WHERE kind = 'heartbeat_hour' AND gateway_id = gA AND bucket_start = date_trunc('hour', clock_timestamp());
    IF v_n IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FIXTURE 249 HB: two heartbeats made a bucket of %', v_n; END IF;
    IF (SELECT count(*) FROM ingest_inbox WHERE gateway_id = gA) IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'FIXTURE 249 HB: a heartbeat left a row in the inbox (A has % rows, expected 5)', (SELECT count(*) FROM ingest_inbox WHERE gateway_id = gA); END IF;
    BEGIN
        UPDATE ingest_transmissions SET bucket_count = bucket_count + 1 WHERE id = v_x;
        RAISE EXCEPTION 'FIXTURE 249 HB: a bucket grew outside the function';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INGEST_BUCKET_THROUGH_FUNCTION_ONLY' THEN RAISE; END IF;
    END;
    PERFORM set_config('evoltrya.ingest_ctx', 'ingest_submit', true);
    BEGIN
        UPDATE ingest_transmissions SET bucket_count = 1 WHERE id = v_x;
        RAISE EXCEPTION 'FIXTURE 249 HB: a bucket shrank';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INGEST_BUCKET_ONLY_GROWS' THEN RAISE; END IF;
    END;
    BEGIN
        UPDATE ingest_transmissions SET gateway_id = gB WHERE id = v_x;
        RAISE EXCEPTION 'FIXTURE 249 HB: a bucket moved to another gateway';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INGEST_BUCKET_ONLY_GROWS' THEN RAISE; END IF;
    END;
    BEGIN
        UPDATE ingest_transmissions SET client_address = 'x' WHERE kind = 'call' AND gateway_id = gA;
        RAISE EXCEPTION 'FIXTURE 249 HB: a call row was changed';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INGEST_LOG_APPEND_ONLY|ingest_transmissions|update' THEN RAISE; END IF;
    END;
    PERFORM set_config('evoltrya.ingest_ctx', '', true);
    BEGIN
        DELETE FROM ingest_transmissions WHERE id = v_x;
        RAISE EXCEPTION 'FIXTURE 249 HB: the owner deleted a transmission row';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INGEST_LOG_APPEND_ONLY|ingest_transmissions|delete' THEN RAISE; END IF;
    END;

    -- ══════════════ STAT · 读的时候算;回来时记中断 ══════════════
    IF (SELECT count(*) FROM gateway_outages WHERE gateway_id = gB AND interval_s = 60 AND silent_to - silent_from > interval '2 hours') IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 249 STAT: B came back after three hours of silence and no outage was recorded'; END IF;
    IF EXISTS (SELECT 1 FROM gateway_outages WHERE gateway_id = gA) THEN
        RAISE EXCEPTION 'FIXTURE 249 STAT: an outage was recorded for a gateway whose interval is not set'; END IF;
    BEGIN
        DELETE FROM gateway_outages WHERE gateway_id = gB;
        RAISE EXCEPTION 'FIXTURE 249 STAT: an outage was deleted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INGEST_LOG_APPEND_ONLY|gateway_outages|delete' THEN RAISE; END IF;
    END;
    -- D:间隔 60 秒,两小时前心跳过一次,之后没有 —— 此刻在沉默
    INSERT INTO ingest_transmissions (kind, received_at, gateway_id, bucket_start, bucket_count, bucket_bytes, bucket_first_at, bucket_last_at)
    VALUES ('heartbeat_hour', now() - interval '2 hours', gD, date_trunc('hour', now() - interval '2 hours'), 1, 20,
            now() - interval '2 hours', now() - interval '2 hours');
    v_j := pg_temp.f249_read('STAT', u_view, format(
        $q$SELECT jsonb_object_agg(code, status) FROM gateway_health WHERE gateway_id IN (%L, %L, %L, %L)$q$, gA, gB, gC, gD));
    IF v_j IS DISTINCT FROM jsonb_build_object(cA, 'interval_not_set', cB, 'ok', cC, 'not_yet_heard', cD, 'silent') THEN
        RAISE EXCEPTION 'FIXTURE 249 STAT: the statuses read %', v_j; END IF;
    v_j := pg_temp.f249_read('STAT', u_view,
        $q$SELECT COALESCE(jsonb_agg(item_code ORDER BY item_code), '[]') FROM operations_now WHERE item_type = 'gateway_silent'$q$);
    IF v_j IS DISTINCT FROM jsonb_build_array(cD) THEN RAISE EXCEPTION 'FIXTURE 249 STAT: the gateway_silent arm lists %', v_j; END IF;
    v_j := pg_temp.f249_read('STAT', u_none,
        $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type IN ('gateway_silent', 'capture_inbox_failed')$q$);
    IF v_j IS DISTINCT FROM '0'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 STAT: a reader without processing view sees % ingestion reminder(s)', v_j; END IF;

    -- ══════════════ PV · 还没给的值 ══════════════
    v_j := pg_temp.f249_read('PV', u_view,
        $q$SELECT jsonb_build_object('v5', COALESCE(jsonb_agg(item_code ORDER BY item_code) FILTER (WHERE value_code = 'V5'), '[]'),
                                     'v6', count(*) FILTER (WHERE value_code = 'V6'),
                                     'perms', COALESCE(jsonb_agg(DISTINCT permission), '[]')) FROM pending_values$q$);
    IF v_j -> 'v5' IS DISTINCT FROM jsonb_build_array(cA, cC) OR (v_j ->> 'v6')::int < 1 OR v_j -> 'perms' IS DISTINCT FROM '["module.processing.view"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 PV: pending values read %', v_j; END IF;
    IF (v_j ->> 'v6')::int IS DISTINCT FROM (SELECT count(*) FROM shifts WHERE is_active AND starts_at IS NULL AND ends_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 249 PV: V6 lists % shift(s), the table has a different number unset', v_j ->> 'v6'; END IF;
    v_j := pg_temp.f249_read('PV', u_none, 'SELECT to_jsonb(count(*)) FROM pending_values');
    IF v_j IS DISTINCT FROM '0'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 PV: a reader without processing view sees % pending value(s)', v_j; END IF;

    -- ══════════════ XF · 转换:成功 · 失败 · 待转换 · 重试 · 丢弃 ══════════════
    v_msg := pg_temp.f249_try(u_none, 'SELECT ingest_process_pending(100)');
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.processing.view%' THEN
        RAISE EXCEPTION 'FIXTURE 249 XF: a reader without processing view processed the inbox: %', v_msg; END IF;
    v_j := pg_temp.f249_read('XF', u_view, 'SELECT ingest_process_pending(100)');
    IF v_j IS DISTINCT FROM '{"failed": 1, "awaiting": 1, "processed": 6, "transformed": 4}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 XF: processing the inbox gave %', v_j; END IF;
    v_j := pg_temp.f249_read('XF', u_view, 'SELECT ingest_process_pending(100)');
    IF (v_j ->> 'processed')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FIXTURE 249 XF: a second pass processed % row(s) again', v_j ->> 'processed'; END IF;
    IF (SELECT status || ':' || error_code FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 2) IS DISTINCT FROM 'failed:CONNECTION_TEST_TEXT_REQUIRED'
       OR (SELECT status FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 5) IS DISTINCT FROM 'awaiting_transform'
       OR (SELECT transform_result FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 1) IS DISTINCT FROM '{"text": "hello"}'::jsonb
       OR (SELECT transformed_with FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 1) IS DISTINCT FROM 'transform_connection_test_v1' THEN
        RAISE EXCEPTION 'FIXTURE 249 XF: the statuses after processing are wrong'; END IF;
    SELECT id INTO v_x FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 2;
    v_msg := pg_temp.f249_try(u_view, format('SELECT retry_inbox_row(%s)', v_x));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN RAISE EXCEPTION 'FIXTURE 249 XF: a reader retried a row: %', v_msg; END IF;
    v_t := pg_temp.f249_read('XF', u_mgr, format('SELECT to_jsonb(retry_inbox_row(%s))', v_x)) #>> '{}';
    IF v_t IS DISTINCT FROM 'failed' OR (SELECT attempts FROM ingest_inbox WHERE id = v_x) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 249 XF: a retry of a bad payload gave % (attempts %)', v_t, (SELECT attempts FROM ingest_inbox WHERE id = v_x); END IF;
    -- 一类刚接上转换器(只经迁移;这里以属主身份改字典,只为证重试那一条路)
    UPDATE ingest_data_classes SET transform_function = 'transform_connection_test_v1' WHERE code = 'meter_reading';
    v_t := pg_temp.f249_read('XF', u_mgr, format('SELECT to_jsonb(retry_inbox_row(%s))',
        (SELECT id FROM ingest_inbox WHERE gateway_id = gA AND stream = 's1' AND seq = 5))) #>> '{}';
    IF v_t IS DISTINCT FROM 'transformed' THEN RAISE EXCEPTION 'FIXTURE 249 XF: an awaiting row did not transform once its class had a transformer: %', v_t; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT discard_inbox_row(%s, %L)', v_x, '  '));
    IF v_msg IS DISTINCT FROM 'INBOX_DISCARD_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 249 XF: a discard without a reason: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT discard_inbox_row(%s, %L)', v_x, 'fx249: the test payload was empty on purpose'));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT status || ':' || error_code FROM ingest_inbox WHERE id = v_x) IS DISTINCT FROM 'discarded:CONNECTION_TEST_TEXT_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 249 XF: discarding gave % / %', v_msg, (SELECT status || ':' || COALESCE(error_code, '-') FROM ingest_inbox WHERE id = v_x); END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT retry_inbox_row(%s)', v_x));
    IF v_msg IS DISTINCT FROM 'INBOX_NOT_RETRIABLE|discarded' THEN RAISE EXCEPTION 'FIXTURE 249 XF: a discarded row was retried: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('DELETE FROM ingest_inbox WHERE id = %s', v_x));
    IF v_msg IS DISTINCT FROM 'INGEST_LOG_APPEND_ONLY|ingest_inbox|delete' THEN RAISE EXCEPTION 'FIXTURE 249 XF: an authenticated delete of an inbox row: %', v_msg; END IF;
    BEGIN
        DELETE FROM ingest_inbox WHERE id = v_x;
        RAISE EXCEPTION 'FIXTURE 249 XF: the owner deleted an inbox row';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INGEST_LOG_APPEND_ONLY|ingest_inbox|delete' THEN RAISE; END IF;
    END;
    -- 状态只经函数改:一行刚收下的,属主直写也被拒
    PERFORM pg_temp.f249_gw(cA, kA1, jsonb_build_object('stream', 's2', 'messages', jsonb_build_array(pg_temp.f249_msg(2, cdA, 'connection_test', '{"text":"later"}'))));
    BEGIN
        UPDATE ingest_inbox SET status = 'transformed', transformed_with = 'x' WHERE gateway_id = gA AND stream = 's2' AND seq = 2;
        RAISE EXCEPTION 'FIXTURE 249 XF: an inbox status was written outside the functions';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'INBOX_THROUGH_FUNCTION_ONLY' THEN RAISE; END IF;
    END;
    v_j := pg_temp.f249_read('XF', u_view,
        $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'capture_inbox_failed'$q$);
    IF v_j IS DISTINCT FROM '0'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 XF: a discarded row still lights capture_inbox_failed (%)', v_j; END IF;

    -- ══════════════ ROT · 两把钥匙,轮换不停线;撤一台碰不到另一台 ══════════════
    v_j := pg_temp.f249_read('ROT', u_mgr, format('SELECT issue_gateway_key(%L)', gA)); kA2 := v_j ->> 'secret'; kA2_id := v_j ->> 'key_id';
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT issue_gateway_key(%L)', gA));
    IF v_msg NOT LIKE 'GATEWAY_KEY_TWO_ACTIVE|%' THEN RAISE EXCEPTION 'FIXTURE 249 ROT: a third active key was issued: %', v_msg; END IF;
    IF (pg_temp.f249_gw(cA, kA2, '{"heartbeat":true}')) IS DISTINCT FROM '{"ok": true}'::jsonb
       OR (pg_temp.f249_gw(cA, kA1, '{"heartbeat":true}')) IS DISTINCT FROM '{"ok": true}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 ROT: two active keys do not both work'; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT revoke_gateway_key(%L, %L)', kA1_id, ''));
    IF v_msg IS DISTINCT FROM 'GATEWAY_KEY_REVOKE_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 249 ROT: a revoke without a reason: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT revoke_gateway_key(%L, %L)', kA1_id, 'fx249: rotated'));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 249 ROT: revoking failed: %', v_msg; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT revoke_gateway_key(%L, %L)', kA1_id, 'again'));
    IF v_msg NOT LIKE 'GATEWAY_KEY_ALREADY_REVOKED|%' THEN RAISE EXCEPTION 'FIXTURE 249 ROT: a key was revoked twice: %', v_msg; END IF;
    IF (pg_temp.f249_gw(cA, kA2, '{"heartbeat":true}')) IS DISTINCT FROM '{"ok": true}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 ROT: the second key stopped working when the first was revoked'; END IF;
    IF (pg_temp.f249_gw(cB, kB1, '{"heartbeat":true}')) IS DISTINCT FROM '{"ok": true}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 ROT: revoking a key of A stopped gateway B'; END IF;

    -- ══════════════ AUTH(续)· 撤了的钥匙 · 停用的网关 ══════════════
    v_r := pg_temp.f249_gw(cA, kA1, '{"heartbeat":true}');
    IF v_r IS DISTINCT FROM '{"ok": false, "code": "refused"}'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 AUTH: a revoked key answered %', v_r; END IF;
    IF (SELECT result FROM ingest_transmissions WHERE kind = 'call' AND gateway_id = gA ORDER BY id DESC LIMIT 1) IS DISTINCT FROM 'revoked_key' THEN
        RAISE EXCEPTION 'FIXTURE 249 AUTH: the log does not say the key was revoked'; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format('SELECT retire_device(%L, %L)', gC, 'fx249: decommissioned'));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 249 AUTH: retiring C failed: %', v_msg; END IF;
    v_r := pg_temp.f249_gw(cC, kC1, '{"heartbeat":true}');
    IF v_r IS DISTINCT FROM '{"ok": false, "code": "refused"}'::jsonb
       OR (SELECT result FROM ingest_transmissions WHERE kind = 'call' AND gateway_id = gC ORDER BY id DESC LIMIT 1) IS DISTINCT FROM 'retired_gateway'
       OR EXISTS (SELECT 1 FROM gateway_keys WHERE gateway_id = gC AND revoked_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 249 AUTH: a retired gateway answered % (or its keys are still active)', v_r; END IF;
    v_msg := pg_temp.f249_try(u_mgr, format($q$SELECT save_device('{"name":"renamed"}'::jsonb, %L)$q$, gC));
    IF v_msg NOT LIKE 'DEVICE_RETIRED|%' THEN RAISE EXCEPTION 'FIXTURE 249 AUTH: a retired device was edited: %', v_msg; END IF;
    BEGIN
        DELETE FROM devices WHERE id = gC;
        RAISE EXCEPTION 'FIXTURE 249 AUTH: a device was deleted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'DEVICE_NEVER_DELETED' THEN RAISE; END IF;
    END;

    -- ══════════════ LIM · 失败预算:按编号 30、全部 300;有效钥匙永不被限 ══════════════
    SELECT count(*) INTO v_m FROM ingest_transmissions WHERE kind = 'rejected_overflow';
    FOR i IN 1 .. 31 LOOP
        v_r := pg_temp.f249_gw('ZZF249-LIM', 'nope', '{"heartbeat":true}');
        IF v_r IS DISTINCT FROM '{"ok": false, "code": "refused"}'::jsonb THEN RAISE EXCEPTION 'FIXTURE 249 LIM: a throttled refusal answered %', v_r; END IF;
    END LOOP;
    IF (SELECT count(*) FROM ingest_transmissions WHERE kind = 'call' AND presented_gateway = 'ZZF249-LIM') IS DISTINCT FROM 30
       OR (SELECT COALESCE(sum(bucket_count), 0) FROM ingest_transmissions WHERE kind = 'rejected_overflow') IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 249 LIM: one code failed 31 times: % rows, % in the overflow bucket',
            (SELECT count(*) FROM ingest_transmissions WHERE kind = 'call' AND presented_gateway = 'ZZF249-LIM'),
            (SELECT COALESCE(sum(bucket_count), 0) FROM ingest_transmissions WHERE kind = 'rejected_overflow'); END IF;
    -- 全部失败数到 300(每一个都是新编号,所以按编号的预算一个都不碰)
    SELECT count(*) INTO v_n FROM ingest_transmissions WHERE kind = 'call' AND result <> 'accepted'
       AND received_at >= clock_timestamp() - interval '600 seconds';
    FOR i IN 1 .. (300 - v_n) LOOP
        PERFORM pg_temp.f249_gw('ZZF249-G' || i, 'nope', '{"heartbeat":true}');
    END LOOP;
    IF (SELECT count(*) FROM ingest_transmissions WHERE kind = 'call' AND result IS DISTINCT FROM 'accepted') IS DISTINCT FROM 300 THEN
        RAISE EXCEPTION 'FIXTURE 249 LIM: the global count did not reach 300'; END IF;
    v_r := pg_temp.f249_gw('ZZF249-FRESH', 'nope', '{"heartbeat":true}');
    IF v_r IS DISTINCT FROM '{"ok": false, "code": "refused"}'::jsonb
       OR EXISTS (SELECT 1 FROM ingest_transmissions WHERE presented_gateway = 'ZZF249-FRESH')
       OR (SELECT COALESCE(sum(bucket_count), 0) FROM ingest_transmissions WHERE kind = 'rejected_overflow') IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'FIXTURE 249 LIM: the 301st failure (a fresh code) was logged on its own row, or answered %', v_r; END IF;
    v_r := pg_temp.f249_gw(cA, kA2, jsonb_build_object('stream', 's9', 'messages',
        jsonb_build_array(pg_temp.f249_msg(1, cdA, 'connection_test', '{"text":"still heard"}'))));
    IF v_r -> 'accepted' IS DISTINCT FROM '[1]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 249 LIM: a valid key was throttled by other callers'' failures: %', v_r; END IF;

    RAISE NOTICE 'FIXTURE 249 全部通过: DEV · GRANT · POL · HASH · APPEND · RESP · AUTH · SIZE · OWN · SEQ · HB · STAT · PV · XF · ROT · LIM';
END;
$$;

ROLLBACK;

-- 250 MES-2:一次读数在有人确认之前只是一张草稿;改过的值留着原值与理由;一张地磅单两磅成一张、分出去的份对着净重显示;
--     一台仪器在不在校准期内是读的时候推的,而开关开着时它决定这一次读数能不能拿去定价、拿去签证书(MES-2 Step 0 Q1–Q35;v1.4.38)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-06-mes2-fixture-injections.py)必须让它红在它点名的那一臂。
--   DRAFT    分派器为 weighing 落草稿(proposed = 转换器输出,pending,工位照抄);connection_test 不落(Q4)
--   AWAIT    一类接上转换器之前送来、停在 awaiting_transform 的行,"Process received" 从此接着处理并落草稿(Q6)
--   CONFIRM  确认要 action.confirm_capture;改量出来的值要理由(CAPTURE_CHANGE_REASON_REQUIRED),原值 · 新值 · 理由落一行;
--            设备等字段改不了(CAPTURE_FIELD_FIXED);改过的值经同一支转换器再验;只确认一次(Q8 · Q9)
--   REJECT   驳回要理由,终局;不落称重;收件箱那一行照旧 transformed(Q10)
--   CORRECT  更正是新的一行(corrects_id + 理由),原行不动;一行只更正一次;值没变按名拒;地磅单读最新的(Q11)
--   MANUAL   手工录入走同一条路、一步确认;仪器可选(没给 → not_recorded 被标出来);转换没过 → 按名拒、【什么都不留】(Q13 · Q14 · Q15)
--   CAP      量程给了:读数超过它按名拒(按设备登记的单位);没给:不判(Q12)
--   TICKET   进厂第一磅毛重、第二磅皮重 → 完成;净重 ≤ 0 按名拒;完成了的不再收第三磅;作废要理由、只在没分出去的时候(Q16)
--   SHARE    只从完成了的单分;方向要对;各份之和对着净重显示 —— 分多了也不拒(Q18 · Q20)
--   RECEIPT  建收货单那一刻挂一份:数量 = 份时不留理由;不同则理由必填并落在份上;没有单却给了份按名拒(Q19)
--   CAL      读的时候推:在期内 · 过期 · 没通过 · 从来没校过 · 补录的证书对它覆盖的时间算数 · 作废的记录不算;两个读法(每次称重 /
--            每台仪器今天)对同一台仪器同一天说同一句话(Q25)
--   GATE     开关空着:定价、试算、签证书【一个都不拒】;开着:三个码各按名拒,在期内的照过,开关之前建的收货单不管(Q26 · Q27)
--   ARMS     capture_draft_pending(只给持确认码的人)· instrument_calibration_due(在用、不在期内)·
--            instrument_calibration_approaching(V8 给了才有)(Q29 · Q32)
--   PV       V8(提前天数没给)· V33(在用的仪器没给量程)各一支,给了就消失;不持加工查看码的人一行都看不见(Q12 · Q30)
--   READ     草稿只给加工查看码;地磅单给收货或物流查看码;称重给三者任一;校准的基视图谁都读不到(Q8 · Q22)
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS)—— 员工的读写真的切成 authenticated + 那个人的 JWT;
-- 网关的调用真的切成 anon。定价引擎 reprice_inbound_batch 的 EXECUTE 从 authenticated 收回,所以它以属主身份 + 那个人的 JWT 调
-- (它问的 data.view_purchase_prices 读的是 JWT 里的那个人)。会改状态的"能不能过"一律放进 f250_dry:跑完就回滚。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f250_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;成功回 'OK'(改动留着),失败回错误原文(42501 回 '42501')
CREATE FUNCTION pg_temp.f250_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f250_as(p_user);
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

-- 以某人的身份跑一句、【无论成败都回滚】;成功回 'OK',失败回错误原文。p_owner = 以属主身份(带那个人的 JWT)跑
CREATE FUNCTION pg_temp.f250_dry(p_user uuid, p_sql text, p_owner boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_back text := current_setting('request.jwt.claims', true); v_msg text;
BEGIN
    BEGIN
        PERFORM pg_temp.f250_as(p_user);
        IF NOT p_owner THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
        EXECUTE p_sql;
        RAISE EXCEPTION 'F250_DRY_OK';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN CASE WHEN v_msg = 'F250_DRY_OK' THEN 'OK' ELSE v_msg END;
END;
$f$;

-- 以某人的身份读一个 jsonb;读不出来就抛,带着臂名 —— 一次失败不许被读成 0 或 NULL
CREATE FUNCTION pg_temp.f250_read(p_arm text, p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f250_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RAISE EXCEPTION 'FIXTURE 250 %: the read failed: % — %', p_arm, SQLSTATE, SQLERRM;
END;
$f$;

-- 真的以 anon 调一次网关入口
CREATE FUNCTION pg_temp.f250_gw(p_gw text, p_key text, p_body jsonb) RETURNS jsonb
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
    RAISE EXCEPTION 'FIXTURE 250 ANON: ingest_submit raised: % — %', SQLSTATE, SQLERRM;
END;
$f$;

-- 一次手工称重(以确认人的身份),回那一次称重的 id;p_dev 为空 = 不选仪器
CREATE FUNCTION pg_temp.f250_mw(p_arm text, p_user uuid, p_dev uuid, p_kg numeric, p_at timestamptz, p_subject jsonb DEFAULT '{}'::jsonb)
RETURNS uuid LANGUAGE plpgsql AS $f$
BEGIN
    RETURN (pg_temp.f250_read(p_arm, p_user, format(
        $q$SELECT submit_manual_capture('weighing', jsonb_build_object('weight_kg', %s::numeric), %L::uuid, %L::timestamptz, %L::timestamptz, %L::jsonb) -> 'weighing_id'$q$,
        p_kg, p_dev, p_at - interval '1 minute', p_at, p_subject))) #>> '{}';
END;
$f$;

-- 同上,回那一次称重挂着的地磅单 id(先拿到称重的 id 再查 —— 把一支会写库的函数放进 WHERE 会被逐行再调)
CREATE FUNCTION pg_temp.f250_mt(p_arm text, p_user uuid, p_dev uuid, p_kg numeric, p_at timestamptz, p_subject jsonb)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_w uuid;
BEGIN
    v_w := pg_temp.f250_mw(p_arm, p_user, p_dev, p_kg, p_at, p_subject);
    RETURN (SELECT ticket_id FROM weighings WHERE id = v_w);
END;
$f$;

DO $$
DECLARE
    u_mgr  uuid := gen_random_uuid();   -- action.manage_devices + module.processing.view(cto 的形状)
    u_conf uuid := gen_random_uuid();   -- action.confirm_capture + 加工 / 收货 / 物流查看 + 收货 / 发货(仓库的形状)
    u_view uuid := gen_random_uuid();   -- 只看加工
    u_inb  uuid := gen_random_uuid();   -- 只看收货
    u_log  uuid := gen_random_uuid();   -- 只看物流
    u_none uuid := gen_random_uuid();   -- 一个码都没有
    u_all  uuid := gen_random_uuid();   -- 全部码(定价、加工、签证书)
    r_mgr uuid; r_conf uuid; r_view uuid; r_inb uuid; r_log uuid; r_none uuid; r_all uuid;
    d date := CURRENT_DATE;
    v_ccy text;
    gw uuid; gw_code text; gw_key text; sc uuid; sc_code text; ct uuid; ct_code text;
    wb_ok uuid; s_exp uuid; s_fail uuid; s_never uuid; s_late uuid; s_cap uuid; s_capt uuid; s_nocap uuid; s_res uuid;
    s_never_code text; c_late bigint;
    mat uuid; sup uuid;
    v_j jsonb; v_msg text; v_n int; v_m int; v_t text; v_x bigint; v_u uuid; v_u2 uuid; v_k numeric;
    dr1 uuid; dr2 uuid; dr3 uuid; w1 uuid; w2 uuid; w3 uuid;
    t_ok uuid; t_bad uuid; t_none uuid; t_late uuid; t_r uuid; t_out uuid; t_void uuid; t_open uuid; t_code text;
    b_ok uuid; b_bad uuid; b_none uuid; b_unl uuid; b_old uuid; b_late uuid; b_r1 uuid; b_r2 uuid; b_extra uuid;
    run uuid; cod_ok uuid; cod_bad uuid; cod_none uuid; cod_unl uuid;
    v_counts int[];
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_mgr, 'fx250-mgr@test.local', now(), now()), (u_conf, 'fx250-conf@test.local', now(), now()),
        (u_view, 'fx250-view@test.local', now(), now()), (u_inb, 'fx250-inb@test.local', now(), now()),
        (u_log, 'fx250-log@test.local', now(), now()), (u_none, 'fx250-none@test.local', now(), now()),
        (u_all, 'fx250-all@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx250-mgr', 'f', 'f', true) RETURNING id INTO r_mgr;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx250-conf', 'f', 'f', true) RETURNING id INTO r_conf;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx250-view', 'f', 'f', true) RETURNING id INTO r_view;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx250-inb', 'f', 'f', true) RETURNING id INTO r_inb;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx250-log', 'f', 'f', true) RETURNING id INTO r_log;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx250-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx250-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_mgr, 'action.manage_devices'), (r_mgr, 'module.processing.view'),
        (r_conf, 'action.confirm_capture'), (r_conf, 'module.processing.view'), (r_conf, 'module.inbound.view'),
        (r_conf, 'module.logistics.view'), (r_conf, 'action.receive_goods'), (r_conf, 'action.ship_goods'),
        (r_view, 'module.processing.view'), (r_inb, 'module.inbound.view'), (r_log, 'module.logistics.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_mgr, r_mgr), (u_conf, r_conf), (u_view, r_view), (u_inb, r_inb), (u_log, r_log), (u_none, r_none), (u_all, r_all);
    -- 本块里直接读带门的属主视图(weighbridge_ticket_weights · instrument_calibration_now)时的身份:持全部码的那个人。
    -- 每一个辅助函数调完都把 JWT 还原成调用之前的样子,所以这一句在整块里一直有效(下面两处显式切换之后再切回来)。
    PERFORM pg_temp.f250_as(u_all);

    -- 仪器:一台网关 + 它带的一台秤(weighing)与一台连通测试设备;手工的地磅与几台秤
    gw := (pg_temp.f250_read('DRAFT', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 gateway","kind":"gateway"}'::jsonb))$q$)) #>> '{}';
    SELECT code INTO gw_code FROM devices WHERE id = gw;
    sc := (pg_temp.f250_read('DRAFT', u_mgr, format($q$SELECT to_jsonb(save_device(jsonb_build_object('name','ZZF250 line scale','kind','scale','gateway_id',%L,'data_class','weighing','station','Line 1','interface_status','connected','capacity',5000)))$q$, gw))) #>> '{}';
    SELECT code INTO sc_code FROM devices WHERE id = sc;
    ct := (pg_temp.f250_read('DRAFT', u_mgr, format($q$SELECT to_jsonb(save_device(jsonb_build_object('name','ZZF250 probe','kind','scale','gateway_id',%L,'data_class','connection_test')))$q$, gw))) #>> '{}';
    SELECT code INTO ct_code FROM devices WHERE id = ct;
    gw_key := pg_temp.f250_read('DRAFT', u_mgr, format('SELECT issue_gateway_key(%L)', gw)) ->> 'secret';
    wb_ok   := (pg_temp.f250_read('CAL', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 weighbridge","kind":"weighbridge","interface_status":"manual_only","capacity":60,"unit":"t"}'::jsonb))$q$)) #>> '{}';
    s_exp   := (pg_temp.f250_read('CAL', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 expired","kind":"scale","interface_status":"manual_only","capacity":20000}'::jsonb))$q$)) #>> '{}';
    s_fail  := (pg_temp.f250_read('CAL', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 failed","kind":"scale","interface_status":"manual_only","capacity":20000}'::jsonb))$q$)) #>> '{}';
    s_never := (pg_temp.f250_read('CAL', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 never","kind":"scale","interface_status":"manual_only","capacity":20000}'::jsonb))$q$)) #>> '{}';
    SELECT code INTO s_never_code FROM devices WHERE id = s_never;
    s_late  := (pg_temp.f250_read('CAL', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 late","kind":"scale","interface_status":"manual_only","capacity":20000}'::jsonb))$q$)) #>> '{}';
    s_cap   := (pg_temp.f250_read('CAP', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 bench 100 kg","kind":"scale","interface_status":"manual_only","capacity":100}'::jsonb))$q$)) #>> '{}';
    s_capt  := (pg_temp.f250_read('CAP', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 floor 1 t","kind":"scale","interface_status":"manual_only","capacity":1,"unit":"t"}'::jsonb))$q$)) #>> '{}';
    s_nocap := (pg_temp.f250_read('CAP', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 no capacity","kind":"scale","interface_status":"manual_only"}'::jsonb))$q$)) #>> '{}';
    s_res   := (pg_temp.f250_read('ARMS', u_mgr, $q$SELECT to_jsonb(save_device('{"name":"ZZF250 reserved","kind":"scale"}'::jsonb))$q$)) #>> '{}';

    -- ══════════════ DRAFT · 分派器落草稿 ══════════════
    v_j := pg_temp.f250_gw(gw_code, gw_key, jsonb_build_object('stream', 'f250', 'messages', jsonb_build_array(
        jsonb_build_object('seq', 1, 'device', sc_code, 'class', 'weighing', 'payload', '{"weight_kg": 1520}'::jsonb,
                           'site_from', now() - interval '2 minutes', 'site_to', now() - interval '1 minute', 'dataset_ref', 'f250/1'),
        jsonb_build_object('seq', 2, 'device', sc_code, 'class', 'weighing', 'payload', '{"weight_kg": 880}'::jsonb),
        jsonb_build_object('seq', 3, 'device', sc_code, 'class', 'weighing', 'payload', '{"weight_kg": 300}'::jsonb),
        jsonb_build_object('seq', 4, 'device', ct_code, 'class', 'connection_test', 'payload', '{"text": "hello"}'::jsonb))));
    IF jsonb_array_length(v_j -> 'accepted') IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'FIXTURE 250 DRAFT: the gateway call was not accepted: %', v_j; END IF;
    v_j := pg_temp.f250_read('DRAFT', u_view, 'SELECT ingest_process_pending(100)');
    IF (v_j ->> 'transformed')::int IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'FIXTURE 250 DRAFT: processing gave %', v_j; END IF;
    SELECT d2.id INTO dr1 FROM capture_drafts d2 JOIN ingest_inbox b ON b.id = d2.inbox_id WHERE b.gateway_id = gw AND b.seq = 1;
    SELECT d2.id INTO dr2 FROM capture_drafts d2 JOIN ingest_inbox b ON b.id = d2.inbox_id WHERE b.gateway_id = gw AND b.seq = 2;
    SELECT d2.id INTO dr3 FROM capture_drafts d2 JOIN ingest_inbox b ON b.id = d2.inbox_id WHERE b.gateway_id = gw AND b.seq = 3;
    IF dr1 IS NULL OR dr2 IS NULL OR dr3 IS NULL THEN RAISE EXCEPTION 'FIXTURE 250 DRAFT: a weighing row was transformed without a draft'; END IF;
    IF (SELECT proposed FROM capture_drafts WHERE id = dr1) IS DISTINCT FROM '{"weight_kg": 1520}'::jsonb
       OR (SELECT status FROM capture_drafts WHERE id = dr1) IS DISTINCT FROM 'pending'
       OR (SELECT station FROM capture_drafts WHERE id = dr1) IS DISTINCT FROM 'Line 1'
       OR (SELECT device_id FROM capture_drafts WHERE id = dr1) IS DISTINCT FROM sc THEN
        RAISE EXCEPTION 'FIXTURE 250 DRAFT: the draft is not the transformer output, pending, with the station'; END IF;
    IF EXISTS (SELECT 1 FROM capture_drafts d2 JOIN ingest_inbox b ON b.id = d2.inbox_id WHERE b.gateway_id = gw AND b.seq = 4) THEN
        RAISE EXCEPTION 'FIXTURE 250 DRAFT: a connection test produced a draft'; END IF;
    v_msg := pg_temp.f250_try(u_conf, 'INSERT INTO capture_drafts (inbox_id, data_class, source, proposed) SELECT id, ''weighing'', ''device'', ''{}''::jsonb FROM ingest_inbox LIMIT 1');
    IF v_msg IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'FIXTURE 250 DRAFT: a direct draft insert was not refused: %', v_msg; END IF;

    -- ══════════════ AWAIT · 停在 awaiting_transform 的行,接上转换器之后由同一个按钮处理 ══════════════
    UPDATE ingest_data_classes SET transform_function = NULL WHERE code = 'weighing';   -- 以属主身份退回"还没有转换器"(只为证这一条路)
    v_j := pg_temp.f250_gw(gw_code, gw_key, jsonb_build_object('stream', 'f250-await', 'messages', jsonb_build_array(
        jsonb_build_object('seq', 1, 'device', sc_code, 'class', 'weighing', 'payload', '{"weight_kg": 42}'::jsonb))));
    v_j := pg_temp.f250_read('AWAIT', u_view, 'SELECT ingest_process_pending(100)');
    SELECT id INTO v_x FROM ingest_inbox WHERE gateway_id = gw AND stream = 'f250-await';
    IF (SELECT status FROM ingest_inbox WHERE id = v_x) IS DISTINCT FROM 'awaiting_transform' THEN
        RAISE EXCEPTION 'FIXTURE 250 AWAIT: the row did not wait (%)', (SELECT status FROM ingest_inbox WHERE id = v_x); END IF;
    v_j := pg_temp.f250_read('AWAIT', u_view, 'SELECT ingest_process_pending(100)');
    IF (v_j ->> 'processed')::int IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 250 AWAIT: a row of a class with no transformer was handed to the dispatcher again: %', v_j; END IF;
    UPDATE ingest_data_classes SET transform_function = 'transform_weighing_v1' WHERE code = 'weighing';
    v_j := pg_temp.f250_read('AWAIT', u_view, 'SELECT ingest_process_pending(100)');
    IF (SELECT status FROM ingest_inbox WHERE id = v_x) IS DISTINCT FROM 'transformed'
       OR NOT EXISTS (SELECT 1 FROM capture_drafts WHERE inbox_id = v_x AND status = 'pending') THEN
        RAISE EXCEPTION 'FIXTURE 250 AWAIT: once the class had a transformer the waiting row was not processed into a draft (%)', v_j; END IF;
    v_u := (SELECT id FROM capture_drafts WHERE inbox_id = v_x);   -- 这一张留着 pending,ARMS 臂用它

    -- ══════════════ CONFIRM · 改过的值:原值 · 新值 · 理由 ══════════════
    v_msg := pg_temp.f250_try(u_view, format('SELECT confirm_capture_draft(%L)', dr1));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: a reader without action.confirm_capture confirmed: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT confirm_capture_draft(%L, '{"weight_kg": 1500}'::jsonb)$q$, dr1));
    IF v_msg IS DISTINCT FROM 'CAPTURE_CHANGE_REASON_REQUIRED|weight_kg' THEN
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: a changed value without a reason: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT confirm_capture_draft(%L, %L::jsonb, '{"device": "x"}'::jsonb)$q$, dr1, jsonb_build_object('device', ct_code)));
    IF v_msg IS DISTINCT FROM 'CAPTURE_FIELD_FIXED|device' THEN RAISE EXCEPTION 'FIXTURE 250 CONFIRM: the device was changeable: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT confirm_capture_draft(%L, '{"weight_kg": -5}'::jsonb, '{"weight_kg": "typo"}'::jsonb)$q$, dr1));
    IF v_msg IS DISTINCT FROM 'WEIGHING_WEIGHT_INVALID' THEN
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: a changed value was not re-validated by the transformer: %', v_msg; END IF;
    w1 := (pg_temp.f250_read('CONFIRM', u_conf, format($q$SELECT to_jsonb(confirm_capture_draft(%L, '{"weight_kg": 1500}'::jsonb, '{"weight_kg": "re-weighed after taring"}'::jsonb))$q$, dr1))) #>> '{}';
    IF (SELECT weight_kg FROM weighings WHERE id = w1) IS DISTINCT FROM 1500
       OR (SELECT role FROM weighings WHERE id = w1) IS DISTINCT FROM 'net'
       OR (SELECT device_id FROM weighings WHERE id = w1) IS DISTINCT FROM sc
       OR (SELECT source FROM weighings WHERE id = w1) IS DISTINCT FROM 'device'
       OR (SELECT confirmed_by FROM weighings WHERE id = w1) IS DISTINCT FROM u_conf
       OR (SELECT site_dataset_ref FROM weighings WHERE id = w1) IS DISTINCT FROM 'f250/1'
       OR (SELECT inbox_id FROM weighings WHERE id = w1) IS DISTINCT FROM (SELECT inbox_id FROM capture_drafts WHERE id = dr1) THEN
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: the confirmed weighing is not what was confirmed'; END IF;
    SELECT count(*) INTO v_n FROM capture_draft_changes c WHERE c.draft_id = dr1 AND c.field = 'weight_kg'
       AND c.original_value = '1520'::jsonb AND c.confirmed_value = '1500'::jsonb AND c.reason = 're-weighed after taring';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 250 CONFIRM: the change row (original 1520, confirmed 1500, reason) is missing'; END IF;
    IF (SELECT status FROM capture_drafts WHERE id = dr1) IS DISTINCT FROM 'confirmed'
       OR (SELECT confirmed_by FROM capture_drafts WHERE id = dr1) IS DISTINCT FROM u_conf THEN
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: the draft was not marked confirmed by its confirmer'; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT confirm_capture_draft(%L)', dr1));
    IF v_msg IS DISTINCT FROM 'CAPTURE_DRAFT_DECIDED|confirmed' THEN RAISE EXCEPTION 'FIXTURE 250 CONFIRM: a draft was confirmed twice: %', v_msg; END IF;
    -- 不改值的确认:不落改值行
    w2 := (pg_temp.f250_read('CONFIRM', u_conf, format('SELECT to_jsonb(confirm_capture_draft(%L))', dr2))) #>> '{}';
    IF EXISTS (SELECT 1 FROM capture_draft_changes WHERE draft_id = dr2) OR (SELECT weight_kg FROM weighings WHERE id = w2) IS DISTINCT FROM 880 THEN
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: an unchanged confirmation wrote a change row or changed the value'; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('UPDATE weighings SET weight_kg = 1 WHERE id = %L', w1));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT weight_kg FROM weighings WHERE id = w1) IS DISTINCT FROM 1500 THEN
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: a staff session changed a confirmed weighing: % / %', v_msg, (SELECT weight_kg FROM weighings WHERE id = w1); END IF;
    BEGIN
        UPDATE weighings SET weight_kg = 1 WHERE id = w1;
        RAISE EXCEPTION 'FIXTURE 250 CONFIRM: the owner changed a confirmed weighing';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM IS DISTINCT FROM 'CAPTURE_RECORD_APPEND_ONLY|weighings|update' THEN RAISE; END IF;
    END;

    -- ══════════════ REJECT · 理由必填,终局 ══════════════
    v_msg := pg_temp.f250_try(u_conf, format('SELECT reject_capture_draft(%L, %L)', dr3, '  '));
    IF v_msg IS DISTINCT FROM 'CAPTURE_REJECT_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 250 REJECT: a rejection without a reason: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT reject_capture_draft(%L, %L)', dr3, 'scale was not tared'));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT status || ':' || reject_reason FROM capture_drafts WHERE id = dr3) IS DISTINCT FROM 'rejected:scale was not tared'
       OR EXISTS (SELECT 1 FROM weighings WHERE draft_id = dr3)
       OR (SELECT b.status FROM ingest_inbox b JOIN capture_drafts c ON c.inbox_id = b.id WHERE c.id = dr3) IS DISTINCT FROM 'transformed' THEN
        RAISE EXCEPTION 'FIXTURE 250 REJECT: rejecting gave % / %', v_msg, (SELECT status FROM capture_drafts WHERE id = dr3); END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT confirm_capture_draft(%L)', dr3));
    IF v_msg IS DISTINCT FROM 'CAPTURE_DRAFT_DECIDED|rejected' THEN RAISE EXCEPTION 'FIXTURE 250 REJECT: a rejected draft was confirmed: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('DELETE FROM capture_drafts WHERE id = %L', dr3));
    IF v_msg IS DISTINCT FROM 'CAPTURE_DRAFT_NEVER_DELETED' THEN RAISE EXCEPTION 'FIXTURE 250 REJECT: a draft could be deleted: %', v_msg; END IF;

    -- ══════════════ CORRECT · 新的一行,原行不动 ══════════════
    v_msg := pg_temp.f250_try(u_conf, format('SELECT correct_weighing(%L, 1490, %L)', w1, ''));
    IF v_msg IS DISTINCT FROM 'WEIGHING_CORRECTION_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 250 CORRECT: a correction without a reason: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT correct_weighing(%L, 1500, %L)', w1, 'same'));
    IF v_msg IS DISTINCT FROM 'WEIGHING_CORRECTION_SAME_VALUE' THEN RAISE EXCEPTION 'FIXTURE 250 CORRECT: a correction to the same value: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_view, format('SELECT correct_weighing(%L, 1490, %L)', w1, 'x'));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN RAISE EXCEPTION 'FIXTURE 250 CORRECT: a reader corrected a weighing: %', v_msg; END IF;
    w3 := (pg_temp.f250_read('CORRECT', u_conf, format('SELECT to_jsonb(correct_weighing(%L, 1490, %L))', w1, 'pallet was on the scale'))) #>> '{}';
    IF (SELECT corrects_id FROM weighings WHERE id = w3) IS DISTINCT FROM w1
       OR (SELECT correction_reason FROM weighings WHERE id = w3) IS DISTINCT FROM 'pallet was on the scale'
       OR (SELECT weight_kg FROM weighings WHERE id = w3) IS DISTINCT FROM 1490
       OR (SELECT weight_kg FROM weighings WHERE id = w1) IS DISTINCT FROM 1500
       OR (SELECT device_id FROM weighings WHERE id = w3) IS DISTINCT FROM sc
       OR (SELECT captured_at FROM weighings WHERE id = w3) IS DISTINCT FROM (SELECT captured_at FROM weighings WHERE id = w1)
       OR (SELECT source FROM weighings WHERE id = w3) IS DISTINCT FROM 'manual' THEN
        RAISE EXCEPTION 'FIXTURE 250 CORRECT: the correction is not a new row keeping the reading''s instrument and time'; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT correct_weighing(%L, 1480, %L)', w1, 'again'));
    IF v_msg IS DISTINCT FROM format('WEIGHING_SUPERSEDED|%s', w1) THEN RAISE EXCEPTION 'FIXTURE 250 CORRECT: a superseded row was corrected again: %', v_msg; END IF;
    IF (SELECT is_current FROM weighing_calibration_all WHERE weighing_id = w1) OR NOT (SELECT is_current FROM weighing_calibration_all WHERE weighing_id = w3) THEN
        RAISE EXCEPTION 'FIXTURE 250 CORRECT: "current" does not follow the correction'; END IF;

    -- ══════════════ MANUAL · 同一条路、一步确认;仪器可选;转换没过 → 什么都不留 ══════════════
    v_counts := ARRAY[(SELECT count(*) FROM ingest_inbox)::int, (SELECT count(*) FROM capture_drafts)::int, (SELECT count(*) FROM weighings)::int];
    v_msg := pg_temp.f250_try(u_conf, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": -1}'::jsonb)$q$);
    IF v_msg IS DISTINCT FROM 'WEIGHING_WEIGHT_INVALID' THEN RAISE EXCEPTION 'FIXTURE 250 MANUAL: a bad manual payload: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": 5, "note": "x"}'::jsonb)$q$);
    IF v_msg IS DISTINCT FROM 'WEIGHING_PAYLOAD_INVALID' THEN RAISE EXCEPTION 'FIXTURE 250 MANUAL: an extra payload key: %', v_msg; END IF;
    IF ARRAY[(SELECT count(*) FROM ingest_inbox)::int, (SELECT count(*) FROM capture_drafts)::int, (SELECT count(*) FROM weighings)::int] IS DISTINCT FROM v_counts THEN
        RAISE EXCEPTION 'FIXTURE 250 MANUAL: a refused manual entry left rows behind'; END IF;
    v_msg := pg_temp.f250_try(u_view, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": 5}'::jsonb)$q$);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN RAISE EXCEPTION 'FIXTURE 250 MANUAL: a reader entered a weighing: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, $q$SELECT submit_manual_capture('connection_test', '{"text": "x"}'::jsonb)$q$);
    IF v_msg IS DISTINCT FROM 'CAPTURE_NO_MANUAL_ENTRY|connection_test' THEN RAISE EXCEPTION 'FIXTURE 250 MANUAL: a class without manual entry: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 5}'::jsonb, %L::uuid)$q$, gw));
    IF v_msg NOT LIKE 'CAPTURE_DEVICE_INVALID|%' THEN RAISE EXCEPTION 'FIXTURE 250 MANUAL: a gateway taken as an instrument: %', v_msg; END IF;
    v_u2 := pg_temp.f250_mw('MANUAL', u_conf, NULL, 12.5, now());
    IF (SELECT source || ':' || role || ':' || COALESCE(device_id::text, 'none') FROM weighings WHERE id = v_u2) IS DISTINCT FROM 'manual:net:none'
       OR (SELECT c.status || ':' || c.confirmed_by FROM capture_drafts c JOIN weighings w ON w.draft_id = c.id WHERE w.id = v_u2) IS DISTINCT FROM 'confirmed:' || u_conf
       OR (SELECT b.source || ':' || b.entered_by || ':' || b.transformed_with FROM ingest_inbox b JOIN weighings w ON w.inbox_id = b.id WHERE w.id = v_u2)
          IS DISTINCT FROM 'manual:' || u_conf || ':transform_weighing_v1'
       OR EXISTS (SELECT 1 FROM capture_draft_changes c JOIN weighings w ON w.draft_id = c.draft_id WHERE w.id = v_u2) THEN
        RAISE EXCEPTION 'FIXTURE 250 MANUAL: a manual weighing did not go through the same path confirmed by its enterer'; END IF;
    IF (SELECT status FROM weighing_calibration_all WHERE weighing_id = v_u2) IS DISTINCT FROM 'not_recorded' THEN
        RAISE EXCEPTION 'FIXTURE 250 MANUAL: a weighing with no instrument is not flagged not_recorded'; END IF;
    v_u2 := pg_temp.f250_mw('MANUAL', u_conf, s_exp, 12.5, now());
    IF (SELECT device_id FROM weighings WHERE id = v_u2) IS DISTINCT FROM s_exp THEN
        RAISE EXCEPTION 'FIXTURE 250 MANUAL: the chosen instrument was not kept'; END IF;

    -- ══════════════ CAP · 量程给了才判,按登记的单位 ══════════════
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 150}'::jsonb, %L::uuid)$q$, s_cap));
    IF v_msg NOT LIKE 'WEIGHING_ABOVE_CAPACITY|%|100' THEN RAISE EXCEPTION 'FIXTURE 250 CAP: 150 kg on a 100 kg scale: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 99}'::jsonb, %L::uuid)$q$, s_cap));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 CAP: 99 kg on a 100 kg scale: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 1500}'::jsonb, %L::uuid)$q$, s_capt));
    IF v_msg NOT LIKE 'WEIGHING_ABOVE_CAPACITY|%|1000' THEN RAISE EXCEPTION 'FIXTURE 250 CAP: 1500 kg on a 1 t scale: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 900}'::jsonb, %L::uuid)$q$, s_capt));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 CAP: 900 kg on a 1 t scale: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 999999}'::jsonb, %L::uuid)$q$, s_nocap));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 CAP: a scale with no capacity judged the reading: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT confirm_capture_draft(%L, '{"weight_kg": 6000}'::jsonb, '{"weight_kg": "x"}'::jsonb)$q$, v_u));
    IF v_msg NOT LIKE 'WEIGHING_ABOVE_CAPACITY|%|5000' THEN RAISE EXCEPTION 'FIXTURE 250 CAP: a changed value above capacity at confirmation: %', v_msg; END IF;

    -- ══════════════ TICKET · 两磅成一张 ══════════════
    t_ok := pg_temp.f250_mt('TICKET', u_conf, wb_ok, 12000, now(),
             '{"new_ticket": {"direction": "inbound", "vehicle_reg": " gba 1234 x "}}'::jsonb);
    IF (SELECT direction || ':' || vehicle_reg FROM weighbridge_tickets WHERE id = t_ok) IS DISTINCT FROM 'inbound:GBA 1234 X'
       OR (SELECT code FROM weighbridge_tickets WHERE id = t_ok) !~ '^WB-[0-9]{4}-[0-9]{4}$'
       OR (SELECT status || ':' || gross_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_ok) IS DISTINCT FROM 'open:12000' THEN
        RAISE EXCEPTION 'FIXTURE 250 TICKET: an inbound ticket did not open on its gross weighing (%)', (SELECT row_to_json(x) FROM weighbridge_ticket_weights x WHERE ticket_id = t_ok); END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT share_weighbridge_ticket(%L, 100, %L::uuid)$q$, t_ok, gen_random_uuid()));
    IF v_msg NOT LIKE 'INBOUND_NOT_FOUND|%' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: sharing to a missing receipt: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 13000}'::jsonb, %L::uuid, NULL, NULL, %L::jsonb)$q$,
                              wb_ok, jsonb_build_object('ticket_id', t_ok)));
    IF v_msg NOT LIKE 'TICKET_NET_NOT_POSITIVE|%|12000|13000' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: a tare above the gross: %', v_msg; END IF;
    PERFORM pg_temp.f250_mw('TICKET', u_conf, wb_ok, 4000, now(), jsonb_build_object('ticket_id', t_ok));
    IF (SELECT status || ':' || net_kg || ':' || tare_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_ok) IS DISTINCT FROM 'complete:8000:4000'
       OR (SELECT completed_at FROM weighbridge_tickets WHERE id = t_ok) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 250 TICKET: the second weighing did not complete the ticket'; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 100}'::jsonb, NULL, NULL, NULL, %L::jsonb)$q$,
                              jsonb_build_object('ticket_id', t_ok)));
    IF v_msg NOT LIKE 'TICKET_ALREADY_COMPLETE|%' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: a third weighing on a complete ticket: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": 100}'::jsonb, NULL, NULL, NULL, '{"new_ticket": {"direction": "inbound"}}'::jsonb)$q$);
    IF v_msg IS DISTINCT FROM 'TICKET_VEHICLE_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: a ticket without a vehicle: %', v_msg; END IF;
    t_out := pg_temp.f250_mt('TICKET', u_conf, wb_ok, 3000, now(),
              '{"new_ticket": {"direction": "outbound", "vehicle_reg": "GBB 77"}}'::jsonb);
    IF (SELECT role FROM weighings WHERE ticket_id = t_out) IS DISTINCT FROM 'tare' THEN
        RAISE EXCEPTION 'FIXTURE 250 TICKET: an outbound ticket did not open on its tare'; END IF;
    PERFORM pg_temp.f250_mw('TICKET', u_conf, wb_ok, 9000, now(), jsonb_build_object('ticket_id', t_out));
    IF (SELECT net_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_out) IS DISTINCT FROM 6000 THEN
        RAISE EXCEPTION 'FIXTURE 250 TICKET: outbound net is not gross − tare'; END IF;
    t_void := pg_temp.f250_mt('TICKET', u_conf, wb_ok, 5000, now(),
               '{"new_ticket": {"direction": "inbound", "vehicle_reg": "GBC 1"}}'::jsonb);
    v_msg := pg_temp.f250_try(u_conf, format('SELECT void_weighbridge_ticket(%L, %L)', t_void, ' '));
    IF v_msg IS DISTINCT FROM 'TICKET_VOID_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: a void without a reason: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT void_weighbridge_ticket(%L, %L)', t_void, 'wrong truck'));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT status FROM weighbridge_ticket_weights WHERE ticket_id = t_void) IS DISTINCT FROM 'voided' THEN
        RAISE EXCEPTION 'FIXTURE 250 TICKET: voiding an unshared ticket: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 100}'::jsonb, NULL, NULL, NULL, %L::jsonb)$q$,
                              jsonb_build_object('ticket_id', t_void)));
    IF v_msg NOT LIKE 'TICKET_VOIDED|%' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: a weighing on a voided ticket: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('DELETE FROM weighbridge_tickets WHERE id = %L', t_void));
    IF v_msg IS DISTINCT FROM 'TICKET_NEVER_DELETED' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: a ticket could be deleted: %', v_msg; END IF;

    -- ══════════════ 收货单与产出的布景(GATE / RECEIPT / SHARE 共用)══════════════
    IF NOT EXISTS (SELECT 1 FROM company_profile) THEN
        INSERT INTO company_profile (legal_name, registration_no, address_lines, city, postal_code, country)
        VALUES ('Fixture 250 Recovery Pte. Ltd.', 'FX250-UEN', '1 Fixture Road', 'Singapore', '000000', 'Singapore');
    ELSIF NOT EXISTS (SELECT 1 FROM company_profile WHERE btrim(COALESCE(legal_name, '')) <> '') THEN
        UPDATE company_profile SET legal_name = 'Fixture 250 Recovery Pte. Ltd.',
               registration_no = COALESCE(registration_no, 'FX250-UEN'), address_lines = COALESCE(address_lines, '1 Fixture Road'),
               city = COALESCE(city, 'Singapore'), country = COALESCE(country, 'Singapore');
    END IF;
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, status, valid_from, valid_until)
    VALUES ('gwdf', 'FX250-GWDF', 'NEA', 'active', d - 400, d + 365);
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX250-M', 'fixture 250 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX250-S', 'Fixture 250 Battery Recycle Co.', 'SG', 'goods_supplier') RETURNING id INTO sup;

    -- ══════════════ SHARE · 只从完成了的单分;方向要对;分多了也不拒 ══════════════
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX250-EXTRA', mat, sup, 300, 'kg', 300, d, 'other', 'fixture 250') RETURNING id INTO b_extra;
    t_open := pg_temp.f250_mt('SHARE', u_conf, wb_ok, 7000, now(),
               '{"new_ticket": {"direction": "inbound", "vehicle_reg": "GBD 2"}}'::jsonb);
    v_msg := pg_temp.f250_try(u_conf, format('SELECT share_weighbridge_ticket(%L, 100, %L)', t_open, b_extra));
    IF v_msg NOT LIKE 'TICKET_NOT_COMPLETE|%' THEN RAISE EXCEPTION 'FIXTURE 250 SHARE: a share from an open ticket: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT share_weighbridge_ticket(%L, 100, %L)', t_out, b_extra));
    IF v_msg NOT LIKE 'TICKET_DIRECTION_MISMATCH|%|inbound' THEN RAISE EXCEPTION 'FIXTURE 250 SHARE: an outbound ticket shared to a receipt: %', v_msg; END IF;
    PERFORM pg_temp.f250_as(u_conf);
    BEGIN
        PERFORM weighbridge_share_internal(t_ok, NULL, gen_random_uuid(), 100, NULL);
        RAISE EXCEPTION 'FIXTURE 250 SHARE: an inbound ticket shared to a shipment line';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE 'TICKET_DIRECTION_MISMATCH|%|outbound' THEN RAISE EXCEPTION 'FIXTURE 250 SHARE: inbound to a shipment line: %', SQLERRM; END IF;
    END;
    PERFORM pg_temp.f250_as(u_all);
    v_msg := pg_temp.f250_try(u_view, format('SELECT share_weighbridge_ticket(%L, 100, %L)', t_ok, b_extra));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.receive_goods%' THEN RAISE EXCEPTION 'FIXTURE 250 SHARE: a reader shared a ticket: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT share_weighbridge_ticket(%L, 0, %L)', t_ok, b_extra));
    IF v_msg IS DISTINCT FROM 'TICKET_SHARE_KG_INVALID' THEN RAISE EXCEPTION 'FIXTURE 250 SHARE: a zero share: %', v_msg; END IF;
    -- 还没分出去的完成单可以作废 —— 用 dry 只证"过得了"(t_ok 后面还要用)
    v_msg := pg_temp.f250_dry(u_conf, format('SELECT void_weighbridge_ticket(%L, %L)', t_ok, 'x'));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: an unshared complete ticket could not be voided: %', v_msg; END IF;

    -- ══════════════ RECEIPT · 建收货单那一刻挂一份 ══════════════
    t_r := pg_temp.f250_mt('RECEIPT', u_conf, wb_ok, 2000, now(),
            '{"new_ticket": {"direction": "inbound", "vehicle_reg": "GBE 3"}}'::jsonb);
    PERFORM pg_temp.f250_mw('RECEIPT', u_conf, wb_ok, 500, now(), jsonb_build_object('ticket_id', t_r));
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT create_inbound_batch(%L, %L, 980, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'fixture 250', p_ticket_id => %L, p_ticket_share_kg => 1000)$q$, mat, sup, d, t_r));
    IF v_msg IS DISTINCT FROM 'RECEIPT_QUANTITY_REASON_REQUIRED|980|1000' THEN RAISE EXCEPTION 'FIXTURE 250 RECEIPT: a different quantity without a reason: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT create_inbound_batch(%L, %L, 980, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'fixture 250', p_ticket_share_kg => 1000)$q$, mat, sup, d));
    IF v_msg IS DISTINCT FROM 'TICKET_SHARE_WITHOUT_TICKET' THEN RAISE EXCEPTION 'FIXTURE 250 RECEIPT: a share without a ticket: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT create_inbound_batch(%L, %L, 980, 't', %L, p_source_reason_code => 'other', p_source_reason_note => 'fixture 250', p_ticket_id => %L, p_ticket_share_kg => 980)$q$, mat, sup, d, t_r));
    IF v_msg IS DISTINCT FROM 'RECEIPT_TICKET_NEEDS_KG|t' THEN RAISE EXCEPTION 'FIXTURE 250 RECEIPT: a ticket share on a non-kg receipt: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT create_inbound_batch(%L, %L, 980, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'fixture 250', p_ticket_id => %L, p_ticket_share_kg => 980)$q$, mat, sup, d, t_out));
    IF v_msg NOT LIKE 'TICKET_DIRECTION_MISMATCH|%|inbound' THEN RAISE EXCEPTION 'FIXTURE 250 RECEIPT: an outbound ticket on a receipt: %', v_msg; END IF;
    b_r1 := (pg_temp.f250_read('RECEIPT', u_conf, format($q$SELECT create_inbound_batch(%L, %L, 980, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'fixture 250', p_ticket_id => %L, p_ticket_share_kg => 1000, p_quantity_reason => 'two bags torn, swept and weighed apart')$q$, mat, sup, d, t_r)) ->> 'batch_id')::uuid;
    b_r2 := (pg_temp.f250_read('RECEIPT', u_conf, format($q$SELECT create_inbound_batch(%L, %L, 500, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'fixture 250', p_ticket_id => %L, p_ticket_share_kg => 500, p_quantity_reason => 'ignored when equal')$q$, mat, sup, d, t_r)) ->> 'batch_id')::uuid;
    IF (SELECT quantity FROM inbound_batches WHERE id = b_r1) IS DISTINCT FROM 980
       OR (SELECT kg || ':' || receipt_quantity_reason FROM weighbridge_ticket_shares WHERE inbound_batch_id = b_r1) IS DISTINCT FROM '1000:two bags torn, swept and weighed apart'
       OR (SELECT kg || ':' || COALESCE(receipt_quantity_reason, '-') FROM weighbridge_ticket_shares WHERE inbound_batch_id = b_r2) IS DISTINCT FROM '500:-' THEN
        RAISE EXCEPTION 'FIXTURE 250 RECEIPT: the receipt does not keep both (the share and its quantity, with the reason only when they differ)'; END IF;
    IF (SELECT shared_kg || ':' || difference_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_r) IS DISTINCT FROM '1500:0' THEN
        RAISE EXCEPTION 'FIXTURE 250 SHARE: the sum is not shown against net (%)', (SELECT shared_kg || ':' || difference_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_r); END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT share_weighbridge_ticket(%L, 300, %L)', t_r, b_extra));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT shared_kg || ':' || difference_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_r) IS DISTINCT FROM '1800:-300' THEN
        RAISE EXCEPTION 'FIXTURE 250 SHARE: sharing more than net was refused or not shown (% / %)', v_msg, (SELECT shared_kg || ':' || difference_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_r); END IF;
    IF (SELECT quantity FROM inbound_batches WHERE id = b_extra) IS DISTINCT FROM 300 THEN
        RAISE EXCEPTION 'FIXTURE 250 SHARE: linking an existing receipt changed its quantity'; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT share_weighbridge_ticket(%L, 300, %L)', t_r, b_extra));
    IF v_msg NOT LIKE 'TICKET_ALREADY_SHARED|%' THEN RAISE EXCEPTION 'FIXTURE 250 SHARE: the same receipt shared twice: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('SELECT void_weighbridge_ticket(%L, %L)', t_r, 'x'));
    IF v_msg NOT LIKE 'TICKET_HAS_SHARES|%' THEN RAISE EXCEPTION 'FIXTURE 250 TICKET: a shared ticket was voided: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_conf, format('UPDATE weighbridge_ticket_shares SET kg = 1 WHERE ticket_id = %L', t_r));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT sum(kg) FROM weighbridge_ticket_shares WHERE ticket_id = t_r) IS DISTINCT FROM 1800 THEN
        RAISE EXCEPTION 'FIXTURE 250 SHARE: a staff session changed a share'; END IF;

    -- ══════════════ CAL · 在不在校准期内,读的时候推 ══════════════
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT record_instrument_calibration(%L, %L, %L, 'passed')$q$, wb_ok, d - 30, d + 30));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN RAISE EXCEPTION 'FIXTURE 250 CAL: a confirmer recorded a calibration: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_mgr, format($q$SELECT record_instrument_calibration(%L, %L, %L, 'passed')$q$, gw, d - 30, d + 30));
    IF v_msg IS DISTINCT FROM 'CALIBRATION_KIND_INVALID|gateway' THEN RAISE EXCEPTION 'FIXTURE 250 CAL: a gateway took a calibration: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_mgr, format($q$SELECT record_instrument_calibration(%L, %L, %L, 'passed')$q$, wb_ok, d - 30, d - 31));
    IF v_msg IS DISTINCT FROM 'CALIBRATION_VALID_UNTIL_BEFORE_CALIBRATED' THEN RAISE EXCEPTION 'FIXTURE 250 CAL: valid-until before the date: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_mgr, format($q$SELECT record_instrument_calibration(%L, %L, NULL, 'passed')$q$, wb_ok, d - 30));
    IF v_msg IS DISTINCT FROM 'CALIBRATION_DATE_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 250 CAL: a calibration without its valid-until: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_mgr, format($q$SELECT record_instrument_calibration(%L, %L, %L, 'passed')$q$, wb_ok, d + 1, d + 30));
    IF v_msg IS DISTINCT FROM 'CALIBRATION_IN_FUTURE' THEN RAISE EXCEPTION 'FIXTURE 250 CAL: a calibration dated in the future: %', v_msg; END IF;
    PERFORM pg_temp.f250_read('CAL', u_mgr, format($q$SELECT to_jsonb(record_instrument_calibration(%L, %L, %L, 'passed', 'CERT-OK', 'Accredited Lab'))$q$, wb_ok, d - 30, d + 30));
    PERFORM pg_temp.f250_read('CAL', u_mgr, format($q$SELECT to_jsonb(record_instrument_calibration(%L, %L, %L, 'passed'))$q$, s_exp, d - 60, d - 10));
    PERFORM pg_temp.f250_read('CAL', u_mgr, format($q$SELECT to_jsonb(record_instrument_calibration(%L, %L, %L, 'failed'))$q$, s_fail, d - 5, d + 300));
    -- 一条作废的"通过"不算:s_never 记一条再作废,它照旧 never_calibrated
    v_x := (pg_temp.f250_read('CAL', u_mgr, format($q$SELECT to_jsonb(record_instrument_calibration(%L, %L, %L, 'passed'))$q$, s_never, d - 5, d + 300))) #>> '{}';
    v_msg := pg_temp.f250_try(u_mgr, format('SELECT void_instrument_calibration(%s, %L)', v_x, ''));
    IF v_msg IS DISTINCT FROM 'CALIBRATION_VOID_REASON_REQUIRED' THEN RAISE EXCEPTION 'FIXTURE 250 CAL: a void without a reason: %', v_msg; END IF;
    PERFORM pg_temp.f250_read('CAL', u_mgr, format('SELECT to_jsonb(void_instrument_calibration(%s, %L))', v_x, 'wrong instrument'));
    v_msg := pg_temp.f250_try(u_mgr, format('UPDATE instrument_calibrations SET valid_until = valid_until + 1 WHERE id = %s', v_x));
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT valid_until FROM instrument_calibrations WHERE id = v_x) IS DISTINCT FROM d + 300 THEN
        RAISE EXCEPTION 'FIXTURE 250 CAL: a staff session changed a calibration record'; END IF;
    -- 今天的每一次称重:四种状态
    w1 := pg_temp.f250_mw('CAL', u_conf, wb_ok, 10, now());
    w2 := pg_temp.f250_mw('CAL', u_conf, s_exp, 10, now());
    w3 := pg_temp.f250_mw('CAL', u_conf, s_fail, 10, now());
    v_u2 := pg_temp.f250_mw('CAL', u_conf, s_never, 10, now());
    IF (SELECT string_agg(status, ',' ORDER BY s) FROM (VALUES (1, w1), (2, w2), (3, w3), (4, v_u2)) v(s, w)
          JOIN weighing_calibration_all c ON c.weighing_id = v.w) IS DISTINCT FROM 'in_calibration,expired,failed,never_calibrated' THEN
        RAISE EXCEPTION 'FIXTURE 250 CAL: the four statuses are wrong: %', (SELECT string_agg(status, ',' ORDER BY s) FROM (VALUES (1, w1), (2, w2), (3, w3), (4, v_u2)) v(s, w)
          JOIN weighing_calibration_all c ON c.weighing_id = v.w); END IF;
    -- 两个读法对同一台仪器同一天说同一句话
    SELECT count(*) INTO v_n FROM (VALUES (wb_ok, w1), (s_exp, w2), (s_fail, w3), (s_never, v_u2)) v(dev, w)
      JOIN weighing_calibration_all c ON c.weighing_id = v.w
      JOIN instrument_calibration_now n ON n.device_id = v.dev
     WHERE c.status = n.status;
    IF v_n <> 4 THEN RAISE EXCEPTION 'FIXTURE 250 CAL: the per-weighing and per-instrument readings disagree (% of 4 agree)', v_n; END IF;
    -- 补录:三天前的一次读数,当时没有记录 → 补录一张覆盖那段时间的证书 → 在期内
    w1 := pg_temp.f250_mw('CAL', u_conf, s_late, 10, now() - interval '3 days');
    IF (SELECT status FROM weighing_calibration_all WHERE weighing_id = w1) IS DISTINCT FROM 'never_calibrated' THEN
        RAISE EXCEPTION 'FIXTURE 250 CAL: a reading with no certificate yet is not never_calibrated'; END IF;
    c_late := (pg_temp.f250_read('CAL', u_mgr, format($q$SELECT to_jsonb(record_instrument_calibration(%L, %L, %L, 'passed', 'CERT-LATE'))$q$, s_late, d - 20, d + 20))) #>> '{}';
    IF (SELECT status FROM weighing_calibration_all WHERE weighing_id = w1) IS DISTINCT FROM 'in_calibration' THEN
        RAISE EXCEPTION 'FIXTURE 250 CAL: a late-entered certificate does not count for the period it covers'; END IF;
    -- 证书比读数晚:不追溯到它之前
    w2 := pg_temp.f250_mw('CAL', u_conf, s_late, 10, now() - interval '30 days');
    IF (SELECT status FROM weighing_calibration_all WHERE weighing_id = w2) IS DISTINCT FROM 'never_calibrated' THEN
        RAISE EXCEPTION 'FIXTURE 250 CAL: a certificate counted for a reading taken before it'; END IF;

    -- ══════════════ GATE · 开关空着什么都不拒;开着三个码各按名拒 ══════════════
    -- 四张地磅单:都在期内 · 毛重来自从没校过的秤 · 毛重没记仪器 · 一张三天前、证书补录过的
    t_bad := pg_temp.f250_mt('GATE', u_conf, s_never, 5000, now(),
              '{"new_ticket": {"direction": "inbound", "vehicle_reg": "GBF 4"}}'::jsonb);
    PERFORM pg_temp.f250_mw('GATE', u_conf, wb_ok, 1000, now(), jsonb_build_object('ticket_id', t_bad));
    t_none := pg_temp.f250_mt('GATE', u_conf, NULL, 3000, now(),
               '{"new_ticket": {"direction": "inbound", "vehicle_reg": "GBG 5"}}'::jsonb);
    PERFORM pg_temp.f250_mw('GATE', u_conf, wb_ok, 1000, now(), jsonb_build_object('ticket_id', t_none));
    t_late := pg_temp.f250_mt('GATE', u_conf, s_late, 2000, now() - interval '3 days',
               '{"new_ticket": {"direction": "inbound", "vehicle_reg": "GBH 6"}}'::jsonb);
    PERFORM pg_temp.f250_mw('GATE', u_conf, s_late, 500, now() - interval '3 days', jsonb_build_object('ticket_id', t_late));
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX250-OK', mat, sup, 8000, 'kg', 8000, d, 'other', 'fixture 250'),
           ('FX250-BAD', mat, sup, 4000, 'kg', 4000, d, 'other', 'fixture 250'),
           ('FX250-NONE', mat, sup, 2000, 'kg', 2000, d, 'other', 'fixture 250'),
           ('FX250-UNL', mat, sup, 100, 'kg', 100, d, 'other', 'fixture 250'),
           ('FX250-LATE', mat, sup, 1500, 'kg', 1500, d, 'other', 'fixture 250');
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, source_reason_code, source_reason_note, created_at)
    VALUES ('FX250-OLD', mat, sup, 100, 'kg', 100, d - 10, 'other', 'fixture 250', now() - interval '10 days');
    SELECT id INTO b_ok FROM inbound_batches WHERE code = 'FX250-OK';
    SELECT id INTO b_bad FROM inbound_batches WHERE code = 'FX250-BAD';
    SELECT id INTO b_none FROM inbound_batches WHERE code = 'FX250-NONE';
    SELECT id INTO b_unl FROM inbound_batches WHERE code = 'FX250-UNL';
    SELECT id INTO b_late FROM inbound_batches WHERE code = 'FX250-LATE';
    SELECT id INTO b_old FROM inbound_batches WHERE code = 'FX250-OLD';
    PERFORM pg_temp.f250_as(u_conf);
    PERFORM weighbridge_share_internal(t_ok, b_ok, NULL, 8000, NULL);
    PERFORM weighbridge_share_internal(t_bad, b_bad, NULL, 4000, NULL);
    PERFORM weighbridge_share_internal(t_bad, b_old, NULL, 100, NULL);
    PERFORM weighbridge_share_internal(t_none, b_none, NULL, 2000, NULL);
    PERFORM weighbridge_share_internal(t_late, b_late, NULL, 1500, NULL);
    -- 四票整批加工掉 → 四张待签的销毁证书
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT id, 'discharged_verified' FROM inbound_batches WHERE code IN ('FX250-OK', 'FX250-BAD', 'FX250-NONE', 'FX250-UNL');
    PERFORM pg_temp.f250_as(u_all);
    run := commit_processing_run(d, 'fixture 250 cod run', 100,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b_ok, 'quantity_consumed', 8000),
                          jsonb_build_object('inbound_batch_id', b_bad, 'quantity_consumed', 4000),
                          jsonb_build_object('inbound_batch_id', b_none, 'quantity_consumed', 2000),
                          jsonb_build_object('inbound_batch_id', b_unl, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', mat, 'quantity', 14000)),
        'weight', NULL, NULL, 'manual_disassembly');
    SELECT id INTO cod_ok FROM certificates_of_destruction WHERE inbound_batch_id = b_ok AND status = 'pending';
    SELECT id INTO cod_bad FROM certificates_of_destruction WHERE inbound_batch_id = b_bad AND status = 'pending';
    SELECT id INTO cod_none FROM certificates_of_destruction WHERE inbound_batch_id = b_none AND status = 'pending';
    SELECT id INTO cod_unl FROM certificates_of_destruction WHERE inbound_batch_id = b_unl AND status = 'pending';
    IF cod_ok IS NULL OR cod_bad IS NULL OR cod_none IS NULL OR cod_unl IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 250 GATE: setup — four fully processed receipts should each have a pending certificate'; END IF;

    -- 开关空着:一个都不拒
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 250 GATE: the switch does not start empty'; END IF;
    FOR v_u IN SELECT unnest(ARRAY[b_ok, b_bad, b_none, b_unl, b_late, b_old]) LOOP
        v_msg := pg_temp.f250_dry(u_all, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', v_u, v_ccy));
        IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: with the switch empty the preview refused: %', v_msg; END IF;
        v_msg := pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', v_u, v_ccy), true);
        IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: with the switch empty pricing refused: %', v_msg; END IF;
    END LOOP;
    FOR v_u IN SELECT unnest(ARRAY[cod_ok, cod_bad, cod_none, cod_unl]) LOOP
        v_msg := pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', v_u));
        IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: with the switch empty a certificate refused: %', v_msg; END IF;
    END LOOP;

    -- 开关:只有 action.manage_devices 改得了;日期要像一个日期
    v_msg := pg_temp.f250_try(u_conf, format($q$SELECT set_ingest_settings(jsonb_build_object('require_calibrated_since', %L))$q$, d));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: a confirmer switched the rule on: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_mgr, $q$SELECT set_ingest_settings('{"require_calibrated_since": "2026-13-40"}'::jsonb)$q$);
    IF v_msg IS DISTINCT FROM 'INGEST_SETTING_INVALID|require_calibrated_since' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: an impossible date: %', v_msg; END IF;
    PERFORM pg_temp.f250_read('GATE', u_mgr, format($q$SELECT to_jsonb(set_ingest_settings(jsonb_build_object('require_calibrated_since', %L)))$q$, d));
    IF (SELECT require_calibrated_since FROM ingest_settings) IS DISTINCT FROM d THEN RAISE EXCEPTION 'FIXTURE 250 GATE: the switch did not turn on'; END IF;

    -- 开着:在期内的照过;三个码各按名拒;开关之前建的收货单不管
    v_msg := pg_temp.f250_dry(u_all, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_ok, v_ccy));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: an in-calibration reading was refused by the preview: %', v_msg; END IF;
    v_msg := pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_ok, v_ccy), true);
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: an in-calibration reading was refused by pricing: %', v_msg; END IF;
    v_msg := pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', cod_ok));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: an in-calibration reading was refused a certificate: %', v_msg; END IF;
    v_t := 'READING_INSTRUMENT_NOT_CALIBRATED|' || s_never_code || '|' || to_char(d, 'YYYY-MM-DD');
    IF pg_temp.f250_dry(u_all, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy)) IS DISTINCT FROM v_t
       OR pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy), true) IS DISTINCT FROM v_t
       OR pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', cod_bad)) IS DISTINCT FROM v_t THEN
        RAISE EXCEPTION 'FIXTURE 250 GATE: a never-calibrated instrument was not refused by name (preview %, pricing %, certificate %)',
            pg_temp.f250_dry(u_all, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy)),
            pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy), true),
            pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', cod_bad)); END IF;
    v_t := 'READING_INSTRUMENT_NOT_RECORDED|' || (SELECT code FROM weighbridge_tickets WHERE id = t_none) || '|gross';
    IF pg_temp.f250_dry(u_all, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_none, v_ccy)) IS DISTINCT FROM v_t
       OR pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_none, v_ccy), true) IS DISTINCT FROM v_t
       OR pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', cod_none)) IS DISTINCT FROM v_t THEN
        RAISE EXCEPTION 'FIXTURE 250 GATE: a reading with no instrument was not refused by name (certificate %)',
            pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', cod_none)); END IF;
    v_t := 'RECEIPT_READING_NOT_RECORDED|FX250-UNL';
    IF pg_temp.f250_dry(u_all, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_unl, v_ccy)) IS DISTINCT FROM v_t
       OR pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_unl, v_ccy), true) IS DISTINCT FROM v_t
       OR pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', cod_unl)) IS DISTINCT FROM v_t THEN
        RAISE EXCEPTION 'FIXTURE 250 GATE: a receipt with no weighing was not refused by name (certificate %)',
            pg_temp.f250_dry(u_all, format('SELECT issue_cod(%L)', cod_unl)); END IF;
    v_msg := pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_old, v_ccy), true);
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: a receipt created before the switch date was refused: %', v_msg; END IF;
    v_msg := pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_late, v_ccy), true);
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: a reading covered by a late-entered certificate was refused: %', v_msg; END IF;
    PERFORM pg_temp.f250_read('GATE', u_mgr, format('SELECT to_jsonb(void_instrument_calibration(%s, %L))', c_late, 'certificate belonged to another scale'));
    v_msg := pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_late, v_ccy), true);
    IF v_msg NOT LIKE 'READING_INSTRUMENT_NOT_CALIBRATED|%' THEN RAISE EXCEPTION 'FIXTURE 250 GATE: a voided certificate still let the reading through: %', v_msg; END IF;
    -- 开关清空:回到什么都不拒
    PERFORM pg_temp.f250_read('GATE', u_mgr, $q$SELECT to_jsonb(set_ingest_settings('{"require_calibrated_since": null}'::jsonb))$q$);
    v_msg := pg_temp.f250_dry(u_all, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy), true);
    IF v_msg IS DISTINCT FROM 'OK' OR (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 250 GATE: clearing the switch did not stop the refusals: %', v_msg; END IF;

    -- ══════════════ ARMS · 三支提醒 ══════════════
    v_n := (pg_temp.f250_read('ARMS', u_conf, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'capture_draft_pending' AND days_waiting = 0$q$))::int;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 250 ARMS: a confirmer sees % pending draft(s), expected the one left pending', v_n; END IF;
    v_n := (pg_temp.f250_read('ARMS', u_view, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'capture_draft_pending'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 250 ARMS: a reader without the confirm code is reminded of % draft(s)', v_n; END IF;
    v_j := pg_temp.f250_read('ARMS', u_view, $q$SELECT COALESCE(jsonb_agg(item_id ORDER BY item_id), '[]') FROM operations_now WHERE item_type = 'instrument_calibration_due'$q$);
    IF NOT (v_j @> to_jsonb(ARRAY[s_exp, s_fail, s_never])) OR v_j @> to_jsonb(ARRAY[wb_ok]) OR v_j @> to_jsonb(ARRAY[s_res]) THEN
        RAISE EXCEPTION 'FIXTURE 250 ARMS: calibration-due should list the expired, failed and never-calibrated instruments in use, not the calibrated one or a reserved one: %', v_j; END IF;
    v_n := (pg_temp.f250_read('ARMS', u_view, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'instrument_calibration_approaching'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 250 ARMS: % approaching reminder(s) with V8 not set', v_n; END IF;
    v_n := (pg_temp.f250_read('PV', u_view, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V8'$q$))::int;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 250 PV: V8 lists % row(s) while the lead days are not set', v_n; END IF;
    -- 不持加工查看码的人:趁 V8 与 V33 都还有行的时候问(之后它们被填上,零行就证不出任何东西)
    v_n := (pg_temp.f250_read('PV', u_none, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V8', 'V33')$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 250 PV: a reader without processing view sees % V8/V33 row(s)', v_n; END IF;
    PERFORM pg_temp.f250_read('ARMS', u_mgr, $q$SELECT to_jsonb(set_ingest_settings('{"calibration_lead_days": 60}'::jsonb))$q$);
    v_j := pg_temp.f250_read('ARMS', u_view, $q$SELECT COALESCE(jsonb_agg(item_id), '[]') FROM operations_now WHERE item_type = 'instrument_calibration_approaching'$q$);
    IF NOT (v_j @> to_jsonb(ARRAY[wb_ok])) OR v_j @> to_jsonb(ARRAY[s_exp]) THEN
        RAISE EXCEPTION 'FIXTURE 250 ARMS: with V8 at 60 days the weighbridge (valid 30 more days) should approach, the expired one not: %', v_j; END IF;
    v_n := (pg_temp.f250_read('PV', u_view, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V8'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 250 PV: V8 still listed after it was set'; END IF;

    -- ══════════════ PV · V33 在用的仪器没给量程 ══════════════
    v_j := pg_temp.f250_read('PV', u_view, $q$SELECT COALESCE(jsonb_agg(item_id), '[]') FROM pending_values WHERE value_code = 'V33'$q$);
    IF NOT (v_j @> to_jsonb(ARRAY[s_nocap])) OR v_j @> to_jsonb(ARRAY[s_cap]) OR v_j @> to_jsonb(ARRAY[s_res]) THEN
        RAISE EXCEPTION 'FIXTURE 250 PV: V33 should list the in-use instrument without a capacity only: %', v_j; END IF;
    PERFORM pg_temp.f250_read('PV', u_mgr, format($q$SELECT to_jsonb(save_device('{"capacity": 500}'::jsonb, %L))$q$, s_nocap));
    v_j := pg_temp.f250_read('PV', u_view, $q$SELECT COALESCE(jsonb_agg(item_id), '[]') FROM pending_values WHERE value_code = 'V33'$q$);
    IF v_j @> to_jsonb(ARRAY[s_nocap]) THEN RAISE EXCEPTION 'FIXTURE 250 PV: V33 still lists an instrument once its capacity was given'; END IF;

    -- ══════════════ READ · 谁读得到什么 ══════════════
    IF (pg_temp.f250_read('READ', u_none, 'SELECT to_jsonb(count(*)) FROM capture_drafts'))::int <> 0
       OR (pg_temp.f250_read('READ', u_inb, 'SELECT to_jsonb(count(*)) FROM capture_drafts'))::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 250 READ: drafts are readable without processing view'; END IF;
    IF (pg_temp.f250_read('READ', u_view, 'SELECT to_jsonb(count(*)) FROM capture_drafts'))::int = 0 THEN
        RAISE EXCEPTION 'FIXTURE 250 READ: a processing reader sees no drafts'; END IF;
    IF (pg_temp.f250_read('READ', u_inb, 'SELECT to_jsonb(count(*)) FROM weighbridge_tickets'))::int = 0
       OR (pg_temp.f250_read('READ', u_log, 'SELECT to_jsonb(count(*)) FROM weighbridge_ticket_weights'))::int = 0
       OR (pg_temp.f250_read('READ', u_inb, 'SELECT to_jsonb(count(*)) FROM weighings'))::int = 0
       OR (pg_temp.f250_read('READ', u_log, 'SELECT to_jsonb(count(*)) FROM weighing_calibration'))::int = 0 THEN
        RAISE EXCEPTION 'FIXTURE 250 READ: an inbound-only or logistics-only reader cannot read tickets or weighings'; END IF;
    IF (pg_temp.f250_read('READ', u_view, 'SELECT to_jsonb(count(*)) FROM weighbridge_tickets'))::int <> 0
       OR (pg_temp.f250_read('READ', u_none, 'SELECT to_jsonb(count(*)) FROM weighings'))::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 250 READ: tickets readable without inbound / logistics view, or weighings with no code'; END IF;
    v_msg := pg_temp.f250_try(u_all, 'SELECT count(*) FROM weighing_calibration_all');
    IF v_msg IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'FIXTURE 250 READ: the calibration base view is readable: %', v_msg; END IF;
    v_msg := pg_temp.f250_try(u_all, $q$SELECT capture_confirm_internal(gen_random_uuid(), '{}', '{}', '{}', NULL, NULL)$q$);
    IF v_msg IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'FIXTURE 250 READ: the inner confirm is callable from outside: %', v_msg; END IF;

    RAISE NOTICE 'FIXTURE 250 全部通过: DRAFT · AWAIT · CONFIRM · REJECT · CORRECT · MANUAL · CAP · TICKET · SHARE · RECEIPT · CAL · GATE · ARMS · PV · READ';
END;
$$;

ROLLBACK;

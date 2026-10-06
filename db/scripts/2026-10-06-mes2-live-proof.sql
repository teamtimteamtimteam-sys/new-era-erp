-- db/scripts/2026-10-06-mes2-live-proof.sql
-- MES-2 · 线上验证 —— 【整支在一笔回滚的事务里】(委托书:"Inside rolled-back transactions only"),一行都不留。
--
-- 【证什么】(委托书 §Live verification 的前四条;照片桶那一条在 2026-10-06-mes2-capture-photos-policy-proof.sql)
--   ① 一台探针网关(本事务里登记、发钥匙)以 anon 送一次称重 → 员工处理 → 草稿 → 确认时改了读数(原值 · 新值 · 理由)→ 更正
--   ② 手工录一次称重(不选仪器 → not_recorded)
--   ③ 开一张进厂地磅单、完成它;建一张收货单挂它的份,数量与份不同、写理由
--   ④ 记一次校准、把校准规则打开(require_calibrated_since = 今天):在期内的读数 → 定价与销毁证书都过;不在期内的读数 → 两者都按名拒
-- 【身份】每一步以一个真账号的身份(SET LOCAL ROLE authenticated + 那个人的 JWT;定价引擎 EXECUTE 不给 authenticated,以属主身份
--   带那个人的 JWT 调;定价见下一段):
--   fusheng@(warehouse:确认、收货、加工、签证书)· phua@(cto:设备与校准)· tim@(cfo:看得见采购价)· admin@(唯一持 action.price_receipts)。
--   【定价走引擎,不走申请】审批开着时定价 = admin@ 提申请 → CFO 批准即过账;而线上 admin@ 与 tim@ 是【同一个人】(account_person 相同),
--   所以 admin@ 的提交在线上一律按名拒 RECEIPT_PRICE_NO_OTHER_DECIDER(ROLE-1 起就如此,docs/handbacks/ROLE-1.md:1130)—— 本脚本把这一格
--   量出来、记下来,然后在两条路【都会调】的那两处上证校准闸:预览 preview_reprice_inbound_batch(tim@,authenticated)与引擎
--   reprice_inbound_batch(EXECUTE 不给 authenticated,以属主身份带 tim@ 的 JWT 调 —— 批准时引擎里看到的就是批的那个人)。
--   申请 → 批准 → 过账那一整条在本地重建上(七个账号按线上的角色重放、审批开着)跑通过一次,交回报告记着。
--   【不碰任何一张既有单据】—— 物料、供应商、收货单、加工单、证书全是本事务里新建的,随 ROLLBACK 消失。
-- 【判据】每一格失败都 RAISE,ON_ERROR_STOP 让 psql 退非零;通过的每一格 RAISE NOTICE 一行读数(交回报告照抄)。
-- 跑法:psql -X -v ON_ERROR_STOP=1 -f db/scripts/2026-10-06-mes2-live-proof.sql
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.lp_uid(p_email text) RETURNS uuid LANGUAGE sql AS $f$ SELECT id FROM auth.users WHERE email = p_email $f$;
CREATE FUNCTION pg_temp.lp_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true) $f$;
-- 以某人的身份(authenticated)跑一句、取一个 jsonb 回来;失败就抛,带着那一格的名字
CREATE FUNCTION pg_temp.lp_run(p_cell text, p_user uuid, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.lp_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'LIVE PROOF %: % — %', p_cell, SQLSTATE, SQLERRM;
END $f$;
-- 同上,但期望被拒:回错误原文;跑通了回 'OK'(改动随之回滚到这一格之前)
CREATE FUNCTION pg_temp.lp_try(p_user uuid, p_sql text, p_owner boolean DEFAULT false) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_msg text;
BEGIN
    BEGIN
        PERFORM pg_temp.lp_as(p_user);
        IF NOT p_owner THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
        EXECUTE p_sql;
        RAISE EXCEPTION 'LP_DRY_OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    RETURN CASE WHEN v_msg = 'LP_DRY_OK' THEN 'OK' ELSE v_msg END;
END $f$;

DO $$
DECLARE
    u_wh uuid := pg_temp.lp_uid('fusheng@evoltrya.test');
    u_cto uuid := pg_temp.lp_uid('phua@evolytra.test');
    u_cfo uuid := pg_temp.lp_uid('tim@evoltrya.test');
    u_adm uuid := pg_temp.lp_uid('admin@swm-os.test');
    d date := CURRENT_DATE;
    v_ccy text;
    gw uuid; gw_code text; key text; sc uuid; sc_code text; wb uuid; s_never uuid; s_never_code text;
    v_j jsonb; v_msg text; dr uuid; w1 uuid; w2 uuid; t_ok uuid; t_bad uuid; mat uuid; sup uuid; b_ok uuid; b_bad uuid;
    run uuid; cod_ok uuid; cod_bad uuid; v_t text;
BEGIN
    IF u_wh IS NULL OR u_cto IS NULL OR u_cfo IS NULL OR u_adm IS NULL THEN RAISE EXCEPTION 'LIVE PROOF setup: a named account is missing'; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'LIVE PROOF setup: the calibration rule is expected OFF on live'; END IF;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    -- ── 本事务里的仪器:一台探针网关 + 它带的一台秤(weighing,量程 20 t)、一台地磅、一台从来没校过的秤 ──────────
    gw := (pg_temp.lp_run('setup', u_cto, $q$SELECT to_jsonb(save_device('{"name":"ZZ-PROBE-GW-MES2-LIVE","kind":"gateway"}'::jsonb))$q$)) #>> '{}';
    SELECT code INTO gw_code FROM devices WHERE id = gw;
    sc := (pg_temp.lp_run('setup', u_cto, format($q$SELECT to_jsonb(save_device(jsonb_build_object('name','ZZ-PROBE-SCALE-MES2-LIVE','kind','scale','gateway_id',%L,'data_class','weighing','station','Probe station','interface_status','connected','capacity',20,'unit','t')))$q$, gw))) #>> '{}';
    SELECT code INTO sc_code FROM devices WHERE id = sc;
    key := pg_temp.lp_run('setup', u_cto, format('SELECT issue_gateway_key(%L)', gw)) ->> 'secret';
    wb := (pg_temp.lp_run('setup', u_cto, $q$SELECT to_jsonb(save_device('{"name":"ZZ-PROBE-WB-MES2-LIVE","kind":"weighbridge","interface_status":"manual_only","capacity":60,"unit":"t"}'::jsonb))$q$)) #>> '{}';
    s_never := (pg_temp.lp_run('setup', u_cto, $q$SELECT to_jsonb(save_device('{"name":"ZZ-PROBE-NEVER-MES2-LIVE","kind":"scale","interface_status":"manual_only","capacity":20,"unit":"t"}'::jsonb))$q$)) #>> '{}';
    SELECT code INTO s_never_code FROM devices WHERE id = s_never;

    -- ── ① 网关送一次称重 → 处理 → 草稿 → 确认时改读数 → 更正 ─────────────────────────────────────────────
    PERFORM set_config('request.jwt.claims', '', true);
    EXECUTE 'SET LOCAL ROLE anon';
    v_j := ingest_submit(gw_code, key, jsonb_build_object('stream', 'mes2-live', 'messages', jsonb_build_array(
        jsonb_build_object('seq', 1, 'device', sc_code, 'class', 'weighing', 'payload', '{"weight_kg": 1520}'::jsonb,
                           'site_from', now() - interval '2 minutes', 'site_to', now() - interval '1 minute', 'dataset_ref', 'live/1'))));
    EXECUTE 'RESET ROLE';
    IF v_j ->> 'ok' IS DISTINCT FROM 'true' OR jsonb_array_length(v_j -> 'accepted') <> 1 THEN RAISE EXCEPTION 'LIVE PROOF ①: the gateway call was not accepted: %', v_j; END IF;
    v_j := pg_temp.lp_run('①', u_wh, 'SELECT ingest_process_pending(50)');
    SELECT c.id INTO dr FROM capture_drafts c JOIN ingest_inbox b ON b.id = c.inbox_id WHERE b.gateway_id = gw;
    IF dr IS NULL OR (SELECT proposed FROM capture_drafts WHERE id = dr) IS DISTINCT FROM '{"weight_kg": 1520}'::jsonb THEN
        RAISE EXCEPTION 'LIVE PROOF ①: processing did not produce the draft (%)', v_j; END IF;
    RAISE NOTICE 'LIVE ① gateway % sent 1520 kg from % → processed % → draft pending', gw_code, sc_code, v_j;
    v_msg := pg_temp.lp_try(u_wh, format($q$SELECT confirm_capture_draft(%L, '{"weight_kg": 1500}'::jsonb)$q$, dr));
    IF v_msg IS DISTINCT FROM 'CAPTURE_CHANGE_REASON_REQUIRED|weight_kg' THEN RAISE EXCEPTION 'LIVE PROOF ①: a change without a reason: %', v_msg; END IF;
    w1 := (pg_temp.lp_run('①', u_wh, format($q$SELECT to_jsonb(confirm_capture_draft(%L, '{"weight_kg": 1500}'::jsonb, '{"weight_kg": "re-weighed after taring"}'::jsonb))$q$, dr))) #>> '{}';
    IF (SELECT original_value::text || '→' || confirmed_value::text || ' · ' || reason FROM capture_draft_changes WHERE draft_id = dr)
       IS DISTINCT FROM '1520→1500 · re-weighed after taring' THEN RAISE EXCEPTION 'LIVE PROOF ①: the change row is not original · new · reason'; END IF;
    RAISE NOTICE 'LIVE ① confirmed by fusheng@ with 1500 kg: change row 1520 → 1500 · "re-weighed after taring"; weighing %', w1;
    w2 := (pg_temp.lp_run('①', u_wh, format('SELECT to_jsonb(correct_weighing(%L, 1490, %L))', w1, 'pallet was on the scale'))) #>> '{}';
    IF (SELECT corrects_id FROM weighings WHERE id = w2) IS DISTINCT FROM w1 OR (SELECT weight_kg FROM weighings WHERE id = w1) <> 1500 THEN
        RAISE EXCEPTION 'LIVE PROOF ①: the correction is not a new row pointing at the original'; END IF;
    RAISE NOTICE 'LIVE ① corrected to 1490 kg: new weighing % corrects % (original still 1500)', w2, w1;

    -- ── ② 手工称重,不选仪器 ────────────────────────────────────────────────────────────────────
    v_j := pg_temp.lp_run('②', u_wh, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": 12.5}'::jsonb)$q$);
    IF (SELECT status FROM weighing_calibration_all WHERE weighing_id = (v_j ->> 'weighing_id')::uuid) IS DISTINCT FROM 'not_recorded'
       OR (SELECT source FROM weighings WHERE id = (v_j ->> 'weighing_id')::uuid) IS DISTINCT FROM 'manual' THEN
        RAISE EXCEPTION 'LIVE PROOF ②: the manual weighing is not manual / not flagged'; END IF;
    v_msg := pg_temp.lp_try(u_wh, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": 0}'::jsonb)$q$);
    IF v_msg IS DISTINCT FROM 'WEIGHING_WEIGHT_INVALID' THEN RAISE EXCEPTION 'LIVE PROOF ②: a zero weighing: %', v_msg; END IF;
    RAISE NOTICE 'LIVE ② manual 12.5 kg by fusheng@: source manual, instrument not recorded; 0 kg refused WEIGHING_WEIGHT_INVALID';

    -- ── ③ 进厂地磅单:开 · 完成 · 挂到一张新收货单,数量与份不同、写理由 ─────────────────────────────────────
    v_j := pg_temp.lp_run('③', u_wh, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 12000}'::jsonb, %L::uuid, NULL, NULL, '{"new_ticket": {"direction": "inbound", "vehicle_reg": "ZZ 1234"}}'::jsonb)$q$, wb));
    t_ok := (SELECT ticket_id FROM weighings WHERE id = (v_j ->> 'weighing_id')::uuid);
    v_j := pg_temp.lp_run('③', u_wh, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 4000}'::jsonb, %L::uuid, NULL, NULL, %L::jsonb)$q$, wb, jsonb_build_object('ticket_id', t_ok)));
    IF (SELECT status || ':' || net_kg FROM weighbridge_ticket_weights WHERE ticket_id = t_ok) IS DISTINCT FROM 'complete:8000' THEN
        PERFORM pg_temp.lp_as(u_wh);
        RAISE EXCEPTION 'LIVE PROOF ③: the ticket did not complete at 8000 kg net'; END IF;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-MES2-LIVE-M', 'MES-2 live proof material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO mat;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ-MES2-LIVE-S', 'MES-2 live proof supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;
    v_msg := pg_temp.lp_try(u_wh, format($q$SELECT create_inbound_batch(%L, %L, 7950, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'MES-2 live proof', p_ticket_id => %L, p_ticket_share_kg => 8000)$q$, mat, sup, d, t_ok));
    IF v_msg IS DISTINCT FROM 'RECEIPT_QUANTITY_REASON_REQUIRED|7950|8000' THEN RAISE EXCEPTION 'LIVE PROOF ③: a different quantity without a reason: %', v_msg; END IF;
    b_ok := (pg_temp.lp_run('③', u_wh, format($q$SELECT create_inbound_batch(%L, %L, 7950, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'MES-2 live proof', p_ticket_id => %L, p_ticket_share_kg => 8000, p_quantity_reason => 'moisture drained before weighing in')$q$, mat, sup, d, t_ok)) ->> 'batch_id')::uuid;
    IF (SELECT quantity FROM inbound_batches WHERE id = b_ok) <> 7950
       OR (SELECT kg || ' · ' || receipt_quantity_reason FROM weighbridge_ticket_shares WHERE inbound_batch_id = b_ok) IS DISTINCT FROM '8000 · moisture drained before weighing in' THEN
        RAISE EXCEPTION 'LIVE PROOF ③: the receipt does not keep both'; END IF;
    RAISE NOTICE 'LIVE ③ ticket % (inbound ZZ 1234): gross 12000 · tare 4000 · net 8000 · complete; receipt % quantity 7950 kg, share 8000 kg, reason kept',
        (SELECT code FROM weighbridge_tickets WHERE id = t_ok), (SELECT code FROM inbound_batches WHERE id = b_ok);

    -- ── ④ 校准:记一次;打开规则;在期内的过、不在期内的拒(定价与销毁证书)─────────────────────────────────────
    v_msg := pg_temp.lp_try(u_wh, format($q$SELECT record_instrument_calibration(%L, %L, %L, 'passed')$q$, wb, d - 30, d + 335));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN RAISE EXCEPTION 'LIVE PROOF ④: warehouse recorded a calibration: %', v_msg; END IF;
    PERFORM pg_temp.lp_run('④', u_cto, format($q$SELECT to_jsonb(record_instrument_calibration(%L, %L, %L, 'passed', 'LIVE-PROOF-CERT', 'Accredited Lab'))$q$, wb, d - 30, d + 335));
    -- 第二张单:毛重来自从来没校过的秤
    v_j := pg_temp.lp_run('④', u_wh, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 5000}'::jsonb, %L::uuid, NULL, NULL, '{"new_ticket": {"direction": "inbound", "vehicle_reg": "ZZ 5678"}}'::jsonb)$q$, s_never));
    t_bad := (SELECT ticket_id FROM weighings WHERE id = (v_j ->> 'weighing_id')::uuid);
    PERFORM pg_temp.lp_run('④', u_wh, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 1000}'::jsonb, %L::uuid, NULL, NULL, %L::jsonb)$q$, wb, jsonb_build_object('ticket_id', t_bad)));
    b_bad := (pg_temp.lp_run('④', u_wh, format($q$SELECT create_inbound_batch(%L, %L, 4000, 'kg', %L, p_source_reason_code => 'other', p_source_reason_note => 'MES-2 live proof', p_ticket_id => %L, p_ticket_share_kg => 4000)$q$, mat, sup, d, t_bad)) ->> 'batch_id')::uuid;
    -- 两票整批加工掉 → 两张待签的销毁证书
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (b_ok, 'discharged_verified'), (b_bad, 'discharged_verified');
    PERFORM pg_temp.lp_as(u_wh);
    run := commit_processing_run(d, 'MES-2 live proof run', 50,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', b_ok, 'quantity_consumed', 7950), jsonb_build_object('inbound_batch_id', b_bad, 'quantity_consumed', 4000)),
        jsonb_build_array(jsonb_build_object('material_id', mat, 'quantity', 11900)), 'weight', NULL, NULL, 'manual_disassembly');
    SELECT id INTO cod_ok FROM certificates_of_destruction WHERE inbound_batch_id = b_ok AND status = 'pending';
    SELECT id INTO cod_bad FROM certificates_of_destruction WHERE inbound_batch_id = b_bad AND status = 'pending';
    IF cod_ok IS NULL OR cod_bad IS NULL THEN RAISE EXCEPTION 'LIVE PROOF ④: the two pending certificates were not created'; END IF;
    -- 线上的定价申请:提交即按名拒(同一个人)—— 本刀之前就如此,与校准闸无关;量出来、记下来
    v_msg := pg_temp.lp_try(u_adm, format('SELECT set_inbound_unit_price(%L, 2, %L)', b_ok, v_ccy));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_NO_OTHER_DECIDER|%' THEN RAISE EXCEPTION 'LIVE PROOF ④: expected the known same-person refusal on submit, got %', v_msg; END IF;
    RAISE NOTICE 'LIVE ④ (pre-existing, not this cut) admin@ submitting a price request: % — admin@ and tim@ are one person', v_msg;
    -- 规则关着:都过
    IF pg_temp.lp_try(u_cfo, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy)) IS DISTINCT FROM 'OK'
       OR pg_temp.lp_try(u_cfo, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy), true) IS DISTINCT FROM 'OK'
       OR pg_temp.lp_try(u_wh, format('SELECT issue_cod(%L)', cod_bad)) IS DISTINCT FROM 'OK' THEN
        RAISE EXCEPTION 'LIVE PROOF ④: with the rule off something refused (preview %, engine %, certificate %)',
            pg_temp.lp_try(u_cfo, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy)),
            pg_temp.lp_try(u_cfo, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy), true),
            pg_temp.lp_try(u_wh, format('SELECT issue_cod(%L)', cod_bad)); END IF;
    RAISE NOTICE 'LIVE ④ rule off: the never-calibrated receipt — preview (tim@) OK, engine (tim@) OK, certificate (fusheng@) OK: nothing refuses';
    -- 打开规则(cto)
    PERFORM pg_temp.lp_run('④', u_cto, format($q$SELECT to_jsonb(set_ingest_settings(jsonb_build_object('require_calibrated_since', %L)))$q$, d));
    IF (SELECT require_calibrated_since FROM ingest_settings) IS DISTINCT FROM d THEN RAISE EXCEPTION 'LIVE PROOF ④: the rule did not turn on'; END IF;
    -- 在期内:预览、引擎、证书都过
    v_msg := pg_temp.lp_try(u_cfo, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_ok, v_ccy));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'LIVE PROOF ④: an in-calibration reading was refused by the preview: %', v_msg; END IF;
    v_msg := pg_temp.lp_try(u_cfo, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_ok, v_ccy), true);
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'LIVE PROOF ④: an in-calibration reading was refused by the engine: %', v_msg; END IF;
    v_msg := pg_temp.lp_try(u_wh, format('SELECT issue_cod(%L)', cod_ok));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'LIVE PROOF ④: an in-calibration reading was refused its certificate: %', v_msg; END IF;
    RAISE NOTICE 'LIVE ④ rule on (since %): in-calibration receipt — preview (tim@) OK, engine (tim@) OK, certificate (fusheng@) OK', d;
    -- 不在期内:预览、引擎、证书都按名拒
    v_t := 'READING_INSTRUMENT_NOT_CALIBRATED|' || s_never_code || '|' || to_char(d, 'YYYY-MM-DD');
    v_msg := pg_temp.lp_try(u_cfo, format('SELECT preview_reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy));
    IF v_msg IS DISTINCT FROM v_t THEN RAISE EXCEPTION 'LIVE PROOF ④: the pricing preview of an out-of-calibration reading: %', v_msg; END IF;
    v_msg := pg_temp.lp_try(u_cfo, format('SELECT reprice_inbound_batch(%L, 2, %L)', b_bad, v_ccy), true);
    IF v_msg IS DISTINCT FROM v_t THEN RAISE EXCEPTION 'LIVE PROOF ④: the pricing engine on an out-of-calibration reading: %', v_msg; END IF;
    v_msg := pg_temp.lp_try(u_wh, format('SELECT issue_cod(%L)', cod_bad));
    IF v_msg IS DISTINCT FROM v_t THEN RAISE EXCEPTION 'LIVE PROOF ④: the certificate of an out-of-calibration reading: %', v_msg; END IF;
    RAISE NOTICE 'LIVE ④ rule on: out-of-calibration receipt — preview (tim@), engine (tim@), certificate (fusheng@) all refused %', v_t;
    -- 收尾自证:规则在本事务里开着,ROLLBACK 之后线上应仍为 NULL(after 读数核对)
    RAISE NOTICE 'LIVE PROOF 全部通过 —— ROLLBACK 之后线上一行都不留';
END $$;

ROLLBACK;

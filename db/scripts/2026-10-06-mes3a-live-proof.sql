-- db/scripts/2026-10-06-mes3a-live-proof.sql
-- MES-3a · 线上验证 —— 【整支在一笔回滚的事务里】(委托书:"Inside rolled-back transactions only"),一行都不留。
--
-- 【证什么】(委托书 §Live verification 的五条)
--   ① 库存上限:建一个 NEA 类别、一个物料归进它、给线上那张【今天本来就在效】的 gwdf 执照(WDL-21-2-5380,2026-07-01 → 2028-09-01)
--      加一条这一类的上限 —— 执照这一行一个字都不改(它是既有单据;它的在效期本来就覆盖今天,所以不必、也不许去设)。
--      上限内的一张收货记 within;超的那一张按名拒 STORAGE_CEILING_EXCEEDED;没归类的物料记 category_not_set。
--   ② 隔离:一个标成隔离的库位、一个普通库位;鼓包或漏液的货收进隔离 → 过;从隔离转去普通库位 → 按名拒;收进普通库位 → 按名拒。
--   ③ 安全状态:加一条、看它的滞留那一行(提醒天数没给 → not_set;本事务里给 1 天 → within,0 天)、不写理由取消 → 按名拒、
--      写理由结束 → 留在历史里(谁结束的、为什么)。
--   ④ 一炉【我自己的】放电:写上"已放电"(归这一炉)、结束"带电"(写着这一炉);回滚(仓库提、CFO 批)→ "已放电"被结束、"带电"重新开出来。
--   ⑤ 定价:finance(chooer@)对我自己的一批提定价申请 → CFO(tim@)批准 → 过账。这一批没挂称重:校准开关空着,所以它【不】因此被拒
--      (裁定 1:开关只管"没记"那两种)。
-- 【身份】每一步以一个真账号的身份(SET LOCAL ROLE authenticated + 那个人的 JWT,PostgREST 对每一次请求做的就是这两件事):
--   fusheng@(warehouse:收货、转移、改状态、加工、提回滚)· chooer@(finance:提定价)· tim@(cfo:批定价、批回滚)·
--   admin@(admin:类别字典、执照上限、库位)。
-- 【不碰任何一张既有单据】—— 类别、上限、物料、供应商、库位、收货单、加工单、申请全是本事务里新建的,随 ROLLBACK 消失;
--   既有的那张执照只被【读】(上限是挂在它下面的一条新行)。提醒天数与隔离标记也只在本事务里给。
-- 【判据】每一格失败都 RAISE,ON_ERROR_STOP 让 psql 退非零;通过的每一格 RAISE NOTICE 一行读数(交回报告照抄)。
-- 跑法:psql -X -v ON_ERROR_STOP=1 -f db/scripts/2026-10-06-mes3a-live-proof.sql
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.lp_uid(p_email text) RETURNS uuid LANGUAGE sql AS $f$ SELECT id FROM auth.users WHERE email = p_email $f$;
CREATE FUNCTION pg_temp.lp_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true) $f$;
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
CREATE FUNCTION pg_temp.lp_try(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_msg text;
BEGIN
    BEGIN
        PERFORM pg_temp.lp_as(p_user);
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        RAISE EXCEPTION 'LP_DRY_OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    RETURN CASE WHEN v_msg = 'LP_DRY_OK' THEN 'OK' ELSE v_msg END;
END $f$;
CREATE FUNCTION pg_temp.lp_rcv(p_cell text, p_user uuid, p_mat uuid, p_sup uuid, p_kg numeric, p_loc uuid, p_states text[]) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT pg_temp.lp_run(p_cell, p_user, format(
        $q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => %s, p_unit => 'kg', p_arrival_date => %L,
              p_location_id => %L, p_safety_states => %L::text[], p_chemistry_certainty => 'single_known',
              p_source_reason_code => 'other', p_source_reason_note => 'MES-3a live proof')$q$,
        p_mat, p_sup, p_kg, CURRENT_DATE, p_loc, p_states))
$f$;
CREATE FUNCTION pg_temp.lp_rcv_try(p_user uuid, p_mat uuid, p_sup uuid, p_kg numeric, p_loc uuid, p_states text[]) RETURNS text
LANGUAGE sql AS $f$
    SELECT pg_temp.lp_try(p_user, format(
        $q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => %s, p_unit => 'kg', p_arrival_date => %L,
              p_location_id => %L, p_safety_states => %L::text[], p_chemistry_certainty => 'single_known',
              p_source_reason_code => 'other', p_source_reason_note => 'MES-3a live proof')$q$,
        p_mat, p_sup, p_kg, CURRENT_DATE, p_loc, p_states))
$f$;

DO $$
DECLARE
    u_wh uuid := pg_temp.lp_uid('fusheng@evoltrya.test');
    u_fin uuid := pg_temp.lp_uid('chooer@evoltrya.test');
    u_cfo uuid := pg_temp.lp_uid('tim@evoltrya.test');
    u_adm uuid := pg_temp.lp_uid('admin@swm-os.test');
    d date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_ccy text; lic uuid; lic_no text; sup uuid; m_cat uuid; m_none uuid; l_q uuid; l_n uuid;
    v_j jsonb; v_msg text; b1 uuid; b2 uuid; b_q uuid; b_r uuid; v_row uuid; v_at timestamptz; run uuid; req uuid; v_t text;
BEGIN
    IF u_wh IS NULL OR u_fin IS NULL OR u_cfo IS NULL OR u_adm IS NULL THEN RAISE EXCEPTION 'LIVE PROOF setup: a named account is missing'; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'LIVE PROOF setup: the calibration switch is expected empty on live'; END IF;
    IF EXISTS (SELECT 1 FROM nea_waste_categories) OR EXISTS (SELECT 1 FROM licence_storage_limits)
       OR EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine) OR EXISTS (SELECT 1 FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL) THEN
        RAISE EXCEPTION 'LIVE PROOF setup: live is expected to have no category, ceiling, quarantine location or dwell period'; END IF;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    lic := storage_licence_in_force(d);
    SELECT cert_no INTO lic_no FROM company_compliance WHERE id = lic;
    IF lic IS NULL THEN RAISE EXCEPTION 'LIVE PROOF setup: no licence in force today (expected WDL-21-2-5380)'; END IF;
    RAISE NOTICE 'SETUP | licence in force on % (read, not edited) | %', d, lic_no;

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES3A-S', 'MES-3a live proof supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;

    -- ══ ① 库存上限 ══
    PERFORM pg_temp.lp_run('①', u_adm, $q$WITH x AS (INSERT INTO nea_waste_categories (code, name_en, name_zh) VALUES ('ZZP3A', 'MES-3a probe category', 'MES-3a 探针类别') RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$);
    PERFORM pg_temp.lp_run('①', u_adm, format($q$WITH x AS (INSERT INTO licence_storage_limits (licence_id, category_code, limit_tonnes) VALUES (%L, 'ZZP3A', 2) RETURNING 1) SELECT to_jsonb(count(*)) FROM x$q$, lic));
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code, nea_waste_category_code)
    VALUES ('ZZ-PROBE-MES3A-CAT', 'MES-3a probe (category set)', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction', 'ZZP3A') RETURNING id INTO m_cat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ-PROBE-MES3A-NONE', 'MES-3a probe (no category)', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO m_none;

    v_j := pg_temp.lp_rcv('①', u_wh, m_cat, sup, 1000, NULL, NULL);
    b1 := (v_j ->> 'batch_id')::uuid;
    IF v_j #>> '{ceiling,outcome}' IS DISTINCT FROM 'within'
       OR (SELECT outcome FROM receipt_ceiling_checks WHERE inbound_batch_id = b1) IS DISTINCT FROM 'within' THEN
        RAISE EXCEPTION 'LIVE PROOF ①: a receipt within the ceiling did not record within: %', v_j -> 'ceiling'; END IF;
    RAISE NOTICE '① | fusheng@ | receive 1000 kg of ZZP3A under % (ceiling 2 t) | outcome % · on site before % t · limit % t · licence total % t',
        lic_no, v_j #>> '{ceiling,outcome}', v_j #>> '{ceiling,on_hand_before_t}', v_j #>> '{ceiling,limit_t}', v_j #>> '{ceiling,total_limit_t}';
    v_msg := pg_temp.lp_rcv_try(u_wh, m_cat, sup, 1500, NULL, NULL);
    IF v_msg IS DISTINCT FROM format('STORAGE_CEILING_EXCEEDED|%s|ZZP3A|1.000|1.500|2', lic_no) THEN
        RAISE EXCEPTION 'LIVE PROOF ①: a receipt over the ceiling was not refused by name: %', v_msg; END IF;
    RAISE NOTICE '① | fusheng@ | receive 1500 kg more (1 t + 1.5 t > 2 t) | %', v_msg;
    v_j := pg_temp.lp_rcv('①', u_wh, m_none, sup, 100, NULL, NULL);
    IF v_j #>> '{ceiling,outcome}' IS DISTINCT FROM 'category_not_set' THEN
        RAISE EXCEPTION 'LIVE PROOF ①: a material with no category did not record category_not_set: %', v_j -> 'ceiling'; END IF;
    RAISE NOTICE '① | fusheng@ | receive 100 kg of a material with no category | outcome %', v_j #>> '{ceiling,outcome}';

    -- ══ ② 隔离 ══
    l_n := (pg_temp.lp_run('②', u_adm, $q$SELECT to_jsonb(save_storage_location('ZZ-PROBE-MES3A-N', 'MES-3a probe rack', ARRAY[]::text[]))$q$)) #>> '{}';
    v_msg := pg_temp.lp_rcv_try(u_wh, m_none, sup, 50, l_n, ARRAY['swollen_leaking']);
    IF v_msg IS DISTINCT FROM 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|ZZ-PROBE-MES3A-N' THEN
        RAISE EXCEPTION 'LIVE PROOF ②: a swollen receipt into a normal location was not refused by name: %', v_msg; END IF;
    RAISE NOTICE '② | fusheng@ | receive swollen/leaking into ZZ-PROBE-MES3A-N (not quarantine) | %', v_msg;
    l_q := (pg_temp.lp_run('②', u_adm, $q$SELECT to_jsonb(save_storage_location('ZZ-PROBE-MES3A-Q', 'MES-3a probe quarantine', ARRAY[]::text[], p_is_quarantine => true))$q$)) #>> '{}';
    v_j := pg_temp.lp_rcv('②', u_wh, m_none, sup, 50, l_q, ARRAY['swollen_leaking']);
    b_q := (v_j ->> 'batch_id')::uuid;
    RAISE NOTICE '② | admin@ marks ZZ-PROBE-MES3A-Q as quarantine; fusheng@ receives 50 kg swollen/leaking into it | received %',
        (SELECT code FROM inbound_batches WHERE id = b_q);
    v_msg := pg_temp.lp_try(u_wh, format($q$SELECT create_stock_transfer(20, %L, %L, NULL, %L)$q$, l_n, b_q, l_q));
    IF v_msg IS DISTINCT FROM 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|ZZ-PROBE-MES3A-N' THEN
        RAISE EXCEPTION 'LIVE PROOF ②: a transfer out of quarantine to a normal location was not refused by name: %', v_msg; END IF;
    RAISE NOTICE '② | fusheng@ | transfer 20 kg of it to ZZ-PROBE-MES3A-N | %', v_msg;

    -- ══ ③ 安全状态:加 · 滞留那一行 · 不写理由取消被拒 · 写理由结束 ══
    PERFORM pg_temp.lp_run('③', u_wh, format($q$SELECT set_inbound_safety_states(%L, ARRAY['water_exposed'])$q$, b1));
    SELECT id, created_at INTO v_row, v_at FROM inbound_batch_safety_states WHERE inbound_batch_id = b1 AND safety_state_code = 'water_exposed' AND ended_at IS NULL;
    IF v_row IS NULL THEN RAISE EXCEPTION 'LIVE PROOF ③: the state was not added'; END IF;
    v_j := pg_temp.lp_run('③', u_wh, format($q$SELECT to_jsonb(x) FROM safety_state_dwell x WHERE state_row_id = %L$q$, v_row));
    IF v_j ->> 'dwell_status' IS DISTINCT FROM 'not_set' OR (v_j ->> 'days_recorded')::int <> 0 THEN
        RAISE EXCEPTION 'LIVE PROOF ③: dwell line with no period should read not_set, 0 days: %', v_j; END IF;
    RAISE NOTICE '③ | fusheng@ | add water_exposed to % | dwell line: % days · period % · %', (SELECT code FROM inbound_batches WHERE id = b1),
        v_j ->> 'days_recorded', COALESCE(v_j ->> 'dwell_warning_days', 'Not yet set'), v_j ->> 'dwell_status';
    UPDATE inbound_safety_states SET dwell_warning_days = 1 WHERE code = 'water_exposed';
    PERFORM pg_temp.lp_run('③', u_wh, format($q$SELECT set_inbound_safety_states(%L, ARRAY['water_exposed'])$q$, b1));
    v_j := pg_temp.lp_run('③', u_wh, format($q$SELECT to_jsonb(x) FROM safety_state_dwell x WHERE state_row_id = %L$q$, v_row));
    IF v_j ->> 'dwell_status' IS DISTINCT FROM 'within' OR (v_j ->> 'dwell_warning_days')::int <> 1
       OR (SELECT created_at FROM inbound_batch_safety_states WHERE id = v_row) <> v_at THEN
        RAISE EXCEPTION 'LIVE PROOF ③: with a 1-day period (and a save in between) the dwell line should read within, clock unchanged: %', v_j; END IF;
    RAISE NOTICE '③ | (period 1 day set in this transaction) save again | same row, recorded at unchanged; dwell line: % days · period % · %',
        v_j ->> 'days_recorded', v_j ->> 'dwell_warning_days', v_j ->> 'dwell_status';
    v_msg := pg_temp.lp_try(u_wh, format($q$SELECT set_inbound_safety_states(%L, ARRAY[]::text[])$q$, b1));
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_END_REASON_REQUIRED|water_exposed' THEN
        RAISE EXCEPTION 'LIVE PROOF ③: un-ticking without a reason was not refused by name: %', v_msg; END IF;
    RAISE NOTICE '③ | fusheng@ | un-tick with no reason | %', v_msg;
    PERFORM pg_temp.lp_run('③', u_wh, format($q$SELECT set_inbound_safety_states(%L, ARRAY[]::text[], 'MES-3a live proof: dried and re-inspected')$q$, b1));
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE id = v_row AND ended_at IS NOT NULL AND ended_by = u_wh
                     AND end_reason = 'MES-3a live proof: dried and re-inspected') THEN
        RAISE EXCEPTION 'LIVE PROOF ③: the state was not ended with who and why'; END IF;
    RAISE NOTICE '③ | fusheng@ | un-tick with a reason | row kept: ended_by fusheng@ · reason "%"', (SELECT end_reason FROM inbound_batch_safety_states WHERE id = v_row);

    -- ══ ⑤ 定价:finance 提、CFO 批(先做,④ 的那一炉要一批定过价的料)══
    v_j := pg_temp.lp_rcv('⑤', u_wh, m_none, sup, 100, NULL, ARRAY['charged_not_discharged']);
    b_r := (v_j ->> 'batch_id')::uuid;
    v_j := pg_temp.lp_run('⑤', u_fin, format($q$SELECT set_inbound_unit_price(%L, 2, %L)$q$, b_r, v_ccy));
    req := (v_j ->> 'request_id')::uuid;
    IF v_j ->> 'status' IS DISTINCT FROM 'submitted' OR req IS NULL THEN RAISE EXCEPTION 'LIVE PROOF ⑤: finance''s price was not filed as a request: %', v_j; END IF;
    RAISE NOTICE '⑤ | chooer@ (finance) | price % at 2 % / kg | request % · status %', (SELECT code FROM inbound_batches WHERE id = b_r), v_ccy,
        (SELECT label FROM receipt_price_requests WHERE id = req), v_j ->> 'status';
    v_j := pg_temp.lp_run('⑤', u_cfo, format($q$SELECT to_jsonb(decide_receipt_price_request(%L, true, 'MES-3a live proof'))$q$, req));
    SELECT status INTO v_t FROM receipt_price_requests WHERE id = req;
    IF v_t IS DISTINCT FROM 'approved' OR (SELECT unit_price FROM inbound_batches WHERE id = b_r) IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'LIVE PROOF ⑤: the CFO''s approval did not post the price (request %)', v_t; END IF;
    RAISE NOTICE '⑤ | tim@ (cfo) | approve | request % · batch unit price % · no weighing on the receipt and the switch empty: not refused',
        v_t, (SELECT unit_price FROM inbound_batches WHERE id = b_r);

    -- ══ ④ 一炉我自己的放电,然后回滚(仓库提,CFO 批)══
    SELECT id, created_at INTO v_row, v_at FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'charged_not_discharged';
    run := (pg_temp.lp_run('④', u_wh, format($q$SELECT to_jsonb(commit_processing_run(%L, 'MES-3a live proof discharge', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 100)), '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge'))$q$,
            d, b_r))) #>> '{}';
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'discharged_verified'
                     AND ended_at IS NULL AND created_by_run_id = run)
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE id = v_row AND ended_by_run_id = run) THEN
        RAISE EXCEPTION 'LIVE PROOF ④: the discharge did not write discharged and end charged'; END IF;
    RAISE NOTICE '④ | fusheng@ | discharge run % on % | discharged_verified open (owned by the run) · charged ended "%"',
        (SELECT code FROM processing_runs WHERE id = run), (SELECT code FROM inbound_batches WHERE id = b_r),
        (SELECT end_reason FROM inbound_batch_safety_states WHERE id = v_row);
    v_j := pg_temp.lp_run('④', u_wh, format($q$SELECT submit_rollback_request(%L, 'MES-3a live proof: wrong batch')$q$, run));
    PERFORM pg_temp.lp_run('④', u_cfo, format($q$SELECT to_jsonb(decide_warehouse_request(%L, true))$q$, (v_j ->> 'request_id')::uuid));
    IF (SELECT status FROM processing_runs WHERE id = run) IS DISTINCT FROM 'reversed' THEN RAISE EXCEPTION 'LIVE PROOF ④: the rollback was not applied'; END IF;
    IF EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'discharged_verified' AND ended_at IS NULL) THEN
        RAISE EXCEPTION 'LIVE PROOF ④: after the rollback the batch still reads discharged'; END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'charged_not_discharged'
                     AND ended_at IS NULL AND reopened_from_id = v_row AND created_at = v_at) THEN
        RAISE EXCEPTION 'LIVE PROOF ④: the rollback did not reopen charged with its original recorded time'; END IF;
    RAISE NOTICE '④ | fusheng@ submits rollback · tim@ approves | run % · discharged ended "%" · charged reopened (recorded at unchanged)',
        (SELECT status FROM processing_runs WHERE id = run),
        (SELECT end_reason FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'discharged_verified');

    RAISE NOTICE 'LIVE PROOF MES-3a: all cells passed — rolling back';
END $$;

ROLLBACK;

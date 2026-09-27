-- db/scripts/2026-09-27-apr10-live-proof.sql
-- APR-10 · 线上走证(整支一笔事务,最后 ROLLBACK —— 线上什么都不留)。
-- 以 postgres 连接;每一格以那一个【真账号】的 JWT、SET LOCAL ROLE authenticated 调门(f10_as / f10_try),
-- 读回以 postgres 读【基表】(rolbypassrls = t)。每一格打一行 NOTICE:格号 · 谁 · 做什么 · 结果。
-- 审批开着(线上);锁期在事务里挪到 2026-10-01 好让 Q3 提得了申请 —— 回滚时一并撤掉。
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.uid(p_email text) RETURNS uuid LANGUAGE sql AS $f$
    SELECT id FROM auth.users WHERE email = p_email
$f$;
CREATE FUNCTION pg_temp.f10_as(p_email text) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
        json_build_object('sub', (SELECT id FROM auth.users WHERE email = p_email), 'role', 'authenticated')::text, true)
$f$;
-- 以 p_email 的身份跑一句,返回 'OK:<结果>' 或拒绝的原文
CREATE FUNCTION pg_temp.f10_try(p_email text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f10_as(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN 'OK:' || COALESCE(v, '');
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN SQLERRM;
END;
$f$;

DO $proof$
DECLARE
    v_base text := base_currency_code();
    v_sup uuid := (SELECT id FROM suppliers WHERE code = 'SUP-2026-0003');
    m_film uuid := (SELECT id FROM materials WHERE code = 'MAT-2026-0076');
    m_foil uuid := (SELECT id FROM materials WHERE code = 'MAT-2026-0001');
    a_mob uuid := (SELECT id FROM fixed_assets WHERE code = 'FA-2026-0002');
    q3 uuid := (SELECT id FROM gst_periods WHERE code = 'GST-2026-Q3');
    q uuid; f7 uuid; qf7 uuid; v_boxes jsonb; v text; v_n int;
    po_c uuid; po_o uuid; po_small uuid;
    lines_film text; lines_foil_big text; lines_asset text;
BEGIN
    RAISE NOTICE 'identity %, bypassrls %, read_at %', current_user,
        (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user), now();
    lines_film := jsonb_build_array(jsonb_build_object('material_id', m_film, 'quantity', 10, 'unit', 'kg',
                                                       'estimated_unit_price', 5, 'tax_code', 'TX'))::text;
    lines_foil_big := jsonb_build_array(jsonb_build_object('material_id', m_foil, 'quantity', 100, 'unit', 'kg',
                                                           'estimated_unit_price', 50, 'tax_code', 'TX'))::text;
    lines_asset := jsonb_build_array(jsonb_build_object('asset_id', a_mob, 'quantity', 1, 'unit', 'unit',
                                                        'estimated_unit_price', 10, 'tax_code', 'TX'))::text;

    -- ══════════ GST ══════════
    -- G0 布景:锁挪到 2026-10-01(Q3 三个月都关上),没有主语
    UPDATE finance_settings SET locked_before = DATE '2026-10-01';
    RAISE NOTICE 'G0 postgres · lock → 2026-10-01 · locked_before=%', (SELECT locked_before FROM finance_settings);

    v := pg_temp.f10_try('admin@swm-os.test', format('SELECT submit_gst_filing_request(%L)::text', q3));
    RAISE NOTICE 'G1 admin@ · submit Q3 · %', v;
    RAISE NOTICE 'G1 read-back · gst_filing_requests rows=%', (SELECT count(*) FROM gst_filing_requests);

    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT submit_gst_filing_request(%L, ''APR-10 proof'')::text', q3));
    q := (substr(v, 4)::jsonb->>'request_id')::uuid;
    RAISE NOTICE 'G2 chooer@ · submit Q3 · % | period status=% · boxes rows=% · frozen boxes=%',
        substr(v, 1, 120), (SELECT status FROM gst_periods WHERE id = q3),
        (SELECT count(*) FROM gst_return_boxes WHERE period_id = q3),
        (SELECT jsonb_array_length(boxes) FROM gst_filing_requests WHERE id = q);
    RAISE NOTICE 'G2 pending row · %', (SELECT row(subject_type, code, amount_base, blocks_disable, fixed_level)::text
        FROM approval_pending_documents() WHERE doc_id = q);
    PERFORM pg_temp.f10_as('tim@evoltrya.test');
    RAISE NOTICE 'G2 dashboard as tim@ · %', (SELECT row(item_type, item_code, permission, item_id = q3)::text FROM operations_now
        WHERE item_type = 'gst_filing_pending');
    PERFORM set_config('request.jwt.claims', '', true);

    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT file_gst_return(%L, DATE ''2026-10-15'', ''X'')::text', q3));
    RAISE NOTICE 'G3 chooer@ · old door file_gst_return · %', v;

    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
        v := 'OK';
    EXCEPTION WHEN OTHERS THEN v := SQLERRM; END;
    RAISE NOTICE 'G4 postgres · switch approvals off while it waits · %', v;

    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT decide_gst_filing_request(%L, true)::text', q));
    RAISE NOTICE 'G5 chooer@ · approve own · %', v;

    v := pg_temp.f10_try('tim@evoltrya.test', 'SELECT reopen_period(DATE ''2026-07-31'', ''APR-10 proof'')::text');
    RAISE NOTICE 'G6 tim@ · reopen July while Q3 waits · %', v;
    BEGIN
        UPDATE finance_settings SET locked_before = DATE '2026-09-15';
        v := 'OK';
    EXCEPTION WHEN OTHERS THEN v := SQLERRM; END;
    RAISE NOTICE 'G6 postgres · move lock back to 2026-09-15 · % · locked_before=%', v, (SELECT locked_before FROM finance_settings);

    SELECT boxes INTO v_boxes FROM gst_filing_requests WHERE id = q;
    UPDATE gst_filing_requests SET boxes = jsonb_set(boxes, '{0,value}', to_jsonb(((boxes->0->>'value')::numeric + 1))) WHERE id = q;
    v := pg_temp.f10_try('tim@evoltrya.test', format('SELECT decide_gst_filing_request(%L, true)::text', q));
    RAISE NOTICE 'G7 tim@ · approve after the figures moved (frozen box1 +1 by postgres) · % · still %', v,
        (SELECT status FROM gst_filing_requests WHERE id = q);
    UPDATE gst_filing_requests SET boxes = v_boxes WHERE id = q;

    v := pg_temp.f10_try('tim@evoltrya.test', format('SELECT decide_gst_filing_request(%L, true, ''APR-10 proof'')::text', q));
    RAISE NOTICE 'G8 tim@ · approve · % | request=% period=% boxes rows=% · box1 %, box6 %, box7 %, box8 % · log %',
        left(v, 60), (SELECT status FROM gst_filing_requests WHERE id = q), (SELECT status FROM gst_periods WHERE id = q3),
        (SELECT count(*) FROM gst_return_boxes WHERE period_id = q3),
        (SELECT value_base FROM gst_return_boxes WHERE period_id = q3 AND box = 'box1'),
        (SELECT value_base FROM gst_return_boxes WHERE period_id = q3 AND box = 'box6'),
        (SELECT value_base FROM gst_return_boxes WHERE period_id = q3 AND box = 'box7'),
        (SELECT value_base FROM gst_return_boxes WHERE period_id = q3 AND box = 'box8'),
        (SELECT string_agg(decision || '/' || COALESCE(level::text, '-'), ' ' ORDER BY seq) FROM approval_log
          WHERE subject_type = 'gst_filing_request' AND subject_id = q);

    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT record_gst_filing(%L, DATE ''2026-10-15'', ''IRAS-PROOF'')::text', q3));
    RAISE NOTICE 'G9 chooer@ · record the IRAS filing · % | period %', left(v, 40),
        (SELECT status || ' ' || filed_on || ' ' || filed_reference FROM gst_periods WHERE id = q3);

    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT correct_gst_return(%L, ''APR-10 proof correction'')::text', q3));
    f7 := (substr(v, 4)::jsonb->>'gst_period_id')::uuid;
    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT submit_gst_filing_request(%L)::text', f7));
    qf7 := (substr(v, 4)::jsonb->>'request_id')::uuid;
    PERFORM pg_temp.f10_as('tim@evoltrya.test');
    RAISE NOTICE 'G10 chooer@ · F7 opened and submitted · % | visible to tim@: original=% original boxes=%',
        (SELECT code FROM gst_periods WHERE id = f7),
        (SELECT original_code FROM gst_filing_requests_visible(f7) WHERE id = qf7),
        (SELECT jsonb_array_length(original_boxes) FROM gst_filing_requests_visible(f7) WHERE id = qf7);
    PERFORM set_config('request.jwt.claims', '', true);
    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT withdraw_gst_filing_request(%L, ''proof'')::text', qf7));
    RAISE NOTICE 'G11 chooer@ · withdraw the F7 request · % | log rows for it=%', left(v, 60),
        (SELECT count(*) FROM approval_log WHERE subject_id = qf7 AND decision <> 'submitted');

    -- ══════════ PO ══════════
    v := pg_temp.f10_try('fusheng@evoltrya.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''consumables'')::text',
        v_sup, v_base, lines_film));
    po_c := CASE WHEN v LIKE 'OK:%' THEN (substr(v, 4)::jsonb->>'purchase_order_id')::uuid END;
    RAISE NOTICE 'P1 fusheng@ · raise consumables (film 10 kg × 5) · % | %', left(v, 60),
        (SELECT code || ' ' || category || ' ' || status || '/' || approval_status FROM purchase_orders WHERE id = po_c);
    v := pg_temp.f10_try('fusheng@evoltrya.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''equipment_goods'')::text',
        v_sup, v_base, lines_film));
    RAISE NOTICE 'P2 fusheng@ · raise equipment_goods · %', v;
    v := pg_temp.f10_try('fusheng@evoltrya.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''consumables'')::text',
        v_sup, v_base, lines_asset));
    RAISE NOTICE 'P3 fusheng@ · consumables PO with a machine line · %', v;
    v := pg_temp.f10_try('phua@evolytra.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''consumables'')::text',
        v_sup, v_base, lines_film));
    RAISE NOTICE 'P4 phua@ (cto, purchasing.edit only) · raise consumables · %', v;
    v := pg_temp.f10_try('sandra@evoltrya.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb)::text',
        v_sup, v_base, lines_film));
    RAISE NOTICE 'P5 sandra@ · raise without a category · %', v;
    v := pg_temp.f10_try('chooer@evoltrya.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''office'')::text',
        v_sup, v_base, lines_film));
    po_o := CASE WHEN v LIKE 'OK:%' THEN (substr(v, 4)::jsonb->>'purchase_order_id')::uuid END;
    RAISE NOTICE 'P6 chooer@ · raise office · % | %', left(v, 60),
        (SELECT code || ' ' || category || ' ' || status || '/' || approval_status FROM purchase_orders WHERE id = po_o);
    SELECT count(*) INTO v_n FROM purchase_orders;
    v := pg_temp.f10_try('admin@swm-os.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''equipment_goods'')::text',
        v_sup, v_base, lines_foil_big));
    RAISE NOTICE 'P7 admin@ · raise equipment_goods 5,000.00 · % · POs % → %', v, v_n, (SELECT count(*) FROM purchase_orders);
    v := pg_temp.f10_try('admin@swm-os.test', format(
        'SELECT create_purchase_order(%L, DATE ''2026-09-27'', NULL, %L, NULL, NULL, NULL, NULL, %L::jsonb, p_category => ''consumables'')::text',
        v_sup, v_base, lines_film));
    po_small := CASE WHEN v LIKE 'OK:%' THEN (substr(v, 4)::jsonb->>'purchase_order_id')::uuid END;
    RAISE NOTICE 'P8 admin@ · raise consumables 50.00 (level 1, chooer@ can decide) · % | %', left(v, 60),
        (SELECT code || ' ' || category || ' ' || status || '/' || approval_status FROM purchase_orders WHERE id = po_small);

    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT approve_purchase_order(%L)::text', po_o));
    RAISE NOTICE 'P9 chooer@ · approve own office PO · %', v;
    v := pg_temp.f10_try('tim@evoltrya.test', format('SELECT approve_purchase_order(%L)::text', po_o));
    RAISE NOTICE 'P10 tim@ · approve office PO (level 1 by level 2) · % | %', left(v, 40),
        (SELECT status || '/' || approval_status FROM purchase_orders WHERE id = po_o);
    v := pg_temp.f10_try('chooer@evoltrya.test', format('SELECT approve_purchase_order(%L)::text', po_c));
    RAISE NOTICE 'P11 chooer@ · approve fusheng''s consumables PO · % | %', left(v, 40),
        (SELECT status || '/' || approval_status FROM purchase_orders WHERE id = po_c);

    v := pg_temp.f10_try('phua@evolytra.test', format('SELECT cancel_purchase_order(%L, ''proof'')::text', po_c));
    RAISE NOTICE 'Q1 phua@ · cancel fusheng''s PO · %', v;
    v := pg_temp.f10_try('sandra@evoltrya.test', format('SELECT amend_purchase_order(%L, ''proof'', ''{"notes":"sandra"}''::jsonb)::text', po_c));
    RAISE NOTICE 'Q2 sandra@ · amend fusheng''s consumables PO · %', v;
    v := pg_temp.f10_try('fusheng@evoltrya.test', format('SELECT amend_purchase_order(%L, ''proof'', ''{"notes":"raiser"}''::jsonb)::text', po_c));
    RAISE NOTICE 'Q3 fusheng@ · amend own PO · % | notes=%', left(v, 60), (SELECT notes FROM purchase_orders WHERE id = po_c);
    v := pg_temp.f10_try('sandra@evoltrya.test', 'SELECT amend_purchase_order((SELECT id FROM purchase_orders WHERE code = ''PO-2026-0003''), ''proof'', ''{"notes":"sandra on an admin@ PO"}''::jsonb)::text');
    RAISE NOTICE 'Q4 sandra@ · amend PO-2026-0003 (raised by admin@, equipment_goods) · %', left(v, 60);
    v := pg_temp.f10_try('phua@evolytra.test', 'SELECT amend_purchase_order((SELECT id FROM purchase_orders WHERE code = ''PO-2026-0003''), ''proof'', ''{"notes":"phua"}''::jsonb)::text');
    RAISE NOTICE 'Q5 phua@ · amend PO-2026-0003 · %', v;
    v := pg_temp.f10_try('admin@swm-os.test', format('SELECT cancel_purchase_order(%L, ''proof: category holder'')::text', po_c));
    RAISE NOTICE 'Q6 admin@ (holds the consumables code, not the raiser) · cancel fusheng''s PO · % | %', left(v, 60),
        (SELECT status FROM purchase_orders WHERE id = po_c);
    v := pg_temp.f10_try('phua@evolytra.test', format(
        'INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, category) VALUES (''PO-PROOF-RAW'', %L, DATE ''2026-09-27'', %L, 1, ''consumables'') RETURNING code',
        v_sup, v_base));
    RAISE NOTICE 'S1 phua@ · direct INSERT into purchase_orders · %', v;
    BEGIN
        UPDATE purchase_orders SET category = 'consumables' WHERE id = po_o;   -- office → consumables: a real change
        v := 'OK';
    EXCEPTION WHEN OTHERS THEN v := SQLERRM; END;
    RAISE NOTICE 'S2 postgres · change a PO''s category · %', v;

    RAISE NOTICE 'END · pending now: %', (SELECT string_agg(subject_type || ':' || code, ' ' ORDER BY subject_type, code)
        FROM approval_pending_documents());
END;
$proof$;

ROLLBACK;
SELECT 'after rollback' AS phase, (SELECT count(*) FROM gst_filing_requests) AS gst_requests,
       (SELECT status FROM gst_periods WHERE code = 'GST-2026-Q3') AS q3, (SELECT count(*) FROM gst_return_boxes) AS boxes,
       (SELECT count(*) FROM purchase_orders) AS pos, (SELECT locked_before FROM finance_settings) AS locked_before,
       (SELECT count(*) FROM journal_entries) AS journal_entries, (SELECT count(*) FROM approval_log) AS approval_log;

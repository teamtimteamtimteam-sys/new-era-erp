-- db/scripts/2026-10-07-mes3b-live-proof.sql
-- MES-3b · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着(finance / cfo / 1,000),一处都不关。
--   每一步都以【真账号】跑:SET LOCAL ROLE authenticated + 那个人的 JWT(PostgREST 每一次请求做的就是这件事)。
--   用的全是【自己造的】东西(ZZ-PROBE-MES3B-* 物料 / 供应商 / 客户 / 两个库位,以及由它们生出来的批次、订单、发票、放行、发货);
--   一张在册的单据都不碰、不决定、不改。
--   ① admin@:造物料(电池整包一种、黑粉一种)、两个库位、一家供应商;给整包那种选 UN3480、填 HS 8549.31.00。
--   ② fusheng@(仓库):收 200 kg 整包进 L1;印标签(第一次)→ 不给理由补印(按名拒)→ 给理由补印;读自己的标签预览(物料名在);
--      直接读物料表(仓库不持 materials.view:读不到 —— 对照)。
--   ③ fusheng@:扫批号与两个库位号 → 用扫出来的 id 转 50 kg L1 → L2(create_stock_transfer)。
--   ④ sandra@(cco)建客户与订单、确认;chooer@(finance)开票;sandra@ 提发货放行;tim@(cfo)批;sandra@ 预留;
--      fusheng@ 带一个【不对的】核对扫码发 → SHIP_SCAN_MISMATCH(一行不发);带对的 → 发出去。
-- 打印的每一行都是 STEP|… ;任何一处与预期不符就 RAISE,整笔回滚。跑法:psql "<pooler dsn>" -X -v ON_ERROR_STOP=1 -f 本文件
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.as_(p_email text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'MES3B_LIVE|no account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
-- 以某人的身份跑一句、只要它的拒绝原文(失败的那一句回到它自己的子事务)
CREATE FUNCTION pg_temp.try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.try_(text) TO authenticated;

DO $live$
DECLARE
    d date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_base text := (SELECT code FROM currencies WHERE is_base);
    m_bat uuid; m_bm uuid; l1 uuid; l2 uuid; sup uuid; cust uuid;
    b uuid; b_code text; ob uuid; ob_code text; so uuid; sol uuid; inv jsonb; rel uuid; res uuid;
    v_j jsonb; v_msg text; v_n int; v_x uuid; v_y uuid;
    u_wh uuid := (SELECT id FROM auth.users WHERE email = 'fusheng@evoltrya.test');   -- 读 auth.users 要在切成 authenticated 之前
BEGIN
    -- ① admin@:自己的物料、库位、供应商;UN 编号与 HS 编码
    PERFORM pg_temp.as_('admin@swm-os.test');
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ-PROBE-MES3B-BAT', 'MES-3b probe battery packs', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO m_bat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES3B-BM', 'MES-3b probe black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg')
    RETURNING id INTO m_bm;
    v_msg := pg_temp.try_(format($q$UPDATE materials SET hs_code = '85493' WHERE id = %L$q$, m_bat));
    RAISE NOTICE 'STEP|1 admin@ sets a five-digit HS code|%', v_msg;
    IF v_msg NOT LIKE '%materials_hs_code_shape%' THEN RAISE EXCEPTION 'MES3B_LIVE|five digits should be refused, got %', v_msg; END IF;
    UPDATE materials SET dg_code = 'UN3480', hs_code = '8549.31.00' WHERE id = m_bat;
    SELECT dg_code || ' · ' || hs_code INTO v_msg FROM materials WHERE id = m_bat;
    RAISE NOTICE 'STEP|1 admin@ set DG and HS on ZZ-PROBE-MES3B-BAT|%', v_msg;
    l1 := save_storage_location('ZZ-PROBE-MES3B-L1', 'MES-3b probe rack one', ARRAY[]::text[]);
    l2 := save_storage_location('ZZ-PROBE-MES3B-L2', 'MES-3b probe rack two', ARRAY[]::text[]);
    -- 供应商是布景,以属主插(与 MES-3a 的证明同法):一个真账号直连插只能是 draft(guard_supplier_direct_write),
    -- 而走送审 + 批准会在线上留一张要人决定的单据 —— 这一刀不许留。
    EXECUTE 'RESET ROLE';
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-PROBE-MES3B-S', 'MES-3b probe supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;

    -- ② fusheng@:收货、印标签、补印、预览
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    b := (create_inbound_batch(p_material_id => m_bat, p_supplier_id => sup, p_quantity => 200, p_unit => 'kg', p_arrival_date => d,
          p_location_id => l1, p_chemistry_certainty => 'single_known', p_source_reason_code => 'other',
          p_source_reason_note => 'MES-3b live proof') ->> 'batch_id')::uuid;
    SELECT code INTO b_code FROM inbound_batches_masked WHERE id = b;
    v_j := record_label_print('inbound_batch', b, NULL, 1, NULL);
    RAISE NOTICE 'STEP|2a fusheng@ first print %|print %, reprint %, template %, material "%"', b_code, v_j ->> 'print_no', v_j ->> 'is_reprint',
        v_j #>> '{template,code}', v_j #>> '{data,material_name}';
    IF (v_j ->> 'is_reprint')::boolean OR v_j #>> '{data,material_name}' IS DISTINCT FROM 'MES-3b probe battery packs'
       OR v_j #>> '{data,dg,code}' IS DISTINCT FROM 'UN3480' THEN
        RAISE EXCEPTION 'MES3B_LIVE|first print: %', v_j; END IF;
    v_msg := pg_temp.try_(format('SELECT record_label_print(%L, %L)', 'inbound_batch', b));
    RAISE NOTICE 'STEP|2b fusheng@ reprint with no reason|%', v_msg;
    IF v_msg IS DISTINCT FROM 'LABEL_REPRINT_REASON_REQUIRED|' || b_code THEN RAISE EXCEPTION 'MES3B_LIVE|reprint without a reason: %', v_msg; END IF;
    v_j := record_label_print('inbound_batch', b, 'inbound_a5', 2, 'MES-3b live proof: label smudged');
    RAISE NOTICE 'STEP|2c fusheng@ reprint with a reason|print %, reprint %, template %, copies %', v_j ->> 'print_no', v_j ->> 'is_reprint',
        v_j #>> '{template,code}', v_j ->> 'copies';
    SELECT count(*), string_agg(template_code || '/' || page_size || '/' || copies || '/' || is_reprint || '/' || COALESCE(reprint_reason, '-'), ' ; ' ORDER BY printed_at, is_reprint)
      INTO v_n, v_msg FROM label_prints WHERE inbound_batch_id = b;
    RAISE NOTICE 'STEP|2d label_prints rows for %|% row(s): %', b_code, v_n, v_msg;
    IF v_n <> 2 THEN RAISE EXCEPTION 'MES3B_LIVE|expected 2 print rows, got %', v_n; END IF;
    SELECT count(*) INTO v_n FROM materials WHERE id = m_bat;
    v_j := label_print_preview('inbound_batch', b);
    RAISE NOTICE 'STEP|2e fusheng@ (no materials.view) reads materials directly: % row(s); label shows material "%" and supplier "%"',
        v_n, v_j #>> '{data,material_name}', v_j #>> '{data,detail_value}';
    IF v_n <> 0 OR v_j #>> '{data,material_name}' IS DISTINCT FROM 'MES-3b probe battery packs' THEN
        RAISE EXCEPTION 'MES3B_LIVE|warehouse label name: % / %', v_n, v_j -> 'data'; END IF;

    -- ③ fusheng@:扫一批、扫两个库位、转移
    v_j := resolve_scan_code(lower(b_code), 'transfer', 'keyboard');
    v_x := (resolve_scan_code('ZZ-PROBE-MES3B-L1', 'transfer', 'keyboard') ->> 'id')::uuid;
    v_y := (resolve_scan_code('/loc/ZZ-PROBE-MES3B-L2', 'transfer', 'camera') ->> 'id')::uuid;
    RAISE NOTICE 'STEP|3a fusheng@ scanned %, L1, L2|% % · L1 % · L2 %', lower(b_code), v_j ->> 'outcome', v_j ->> 'code',
        CASE WHEN v_x = l1 THEN 'found' ELSE 'WRONG' END, CASE WHEN v_y = l2 THEN 'found' ELSE 'WRONG' END;
    IF (v_j ->> 'id')::uuid IS DISTINCT FROM b OR v_x IS DISTINCT FROM l1 OR v_y IS DISTINCT FROM l2 THEN
        RAISE EXCEPTION 'MES3B_LIVE|scan resolution'; END IF;
    PERFORM create_stock_transfer(50, v_y, (v_j ->> 'id')::uuid, NULL, v_x);
    SELECT string_agg(COALESCE(loc.code, '-') || '=' || s.qty, ', ' ORDER BY loc.code) INTO v_msg
      FROM stock_by_status s LEFT JOIN storage_locations loc ON loc.id = s.location_id WHERE s.inbound_batch_id = b AND s.qty <> 0;
    RAISE NOTICE 'STEP|3b fusheng@ moved 50 kg by scan|now %', v_msg;
    SELECT count(*) INTO v_n FROM scan_events WHERE scanned_by = u_wh AND scanned_at >= now() - interval '1 minute';
    RAISE NOTICE 'STEP|3c scan_events rows written by those scans|%', v_n;

    -- ④ 订单、开票、放行(审批开着:cco 提、cfo 批)、预留、发货(扫错 → 拒;扫对 → 发)
    ob := (create_output_batch(m_bm, 100, 'kg', d, '库存中', NULL, NULL, 'MES-3b live proof', l1) ->> 'batch_id')::uuid;
    SELECT code INTO ob_code FROM output_batches WHERE id = ob;
    PERFORM pg_temp.as_('sandra@evoltrya.test');
    -- 默认税码 ZR(出口零税率):开票时 resolve_tax_code 要一个答案(TAX_CODE_REQUIRED),而这家客户只活在这笔回滚里
    INSERT INTO customers (code, legal_name, country, payment_terms_days, address, default_tax_code)
    VALUES ('ZZ-PROBE-MES3B-C', 'MES-3b probe customer', 'SG', 30, '1 Probe Road', 'ZR') RETURNING id INTO cust;
    so := (create_sales_order(cust, d, v_base, 1, jsonb_build_array(jsonb_build_object('material_id', m_bm, 'quantity', 20, 'unit_price', 1))) ->> 'id')::uuid;
    IF so IS NULL THEN RAISE EXCEPTION 'MES3B_LIVE|create_sales_order returned no id'; END IF;
    SELECT id INTO sol FROM sales_order_lines WHERE sales_order_id = so;
    PERFORM set_sales_order_status(so, 'confirmed');
    PERFORM pg_temp.as_('chooer@evoltrya.test');
    inv := create_order_invoice(so, d, NULL, NULL, NULL, ARRAY[sol]);
    PERFORM pg_temp.as_('sandra@evoltrya.test');
    v_j := submit_shipping_release(so);
    rel := (v_j ->> 'release_id')::uuid;
    RAISE NOTICE 'STEP|4a sandra@ (cco) asked for a shipping release|%', v_j ->> 'status';
    PERFORM pg_temp.as_('tim@evoltrya.test');
    v_j := decide_shipping_release(rel, true, 'MES-3b live proof');
    RAISE NOTICE 'STEP|4b tim@ (cfo) decided it|%', (SELECT status FROM shipping_releases WHERE id = rel);
    PERFORM pg_temp.as_('sandra@evoltrya.test');
    res := (reserve_stock(sol, ob, 20, l1) ->> 'reservation_id')::uuid;
    PERFORM pg_temp.as_('fusheng@evoltrya.test');
    v_j := (SELECT to_jsonb(q) FROM shipping_queue_rows() q WHERE q.reservation_id = res);
    RAISE NOTICE 'STEP|4c fusheng@ shipping queue row|batch %, DG %, DG missing %, quarantine %', v_j ->> 'output_batch_code', v_j ->> 'dg_code',
        v_j ->> 'dg_missing', COALESCE(v_j ->> 'quarantine_states', '-');
    v_msg := pg_temp.try_(format($q$SELECT ship_order(%L, %L, jsonb_build_array(jsonb_build_object('reservation_id', %L, 'scanned_code', %L)))$q$,
                                 so, d, res, b_code));
    RAISE NOTICE 'STEP|4d fusheng@ ships with a mismatching scan (%)|%', b_code, v_msg;
    IF v_msg IS DISTINCT FROM 'SHIP_SCAN_MISMATCH|' || b_code || '|' || ob_code THEN RAISE EXCEPTION 'MES3B_LIVE|mismatch: %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM shipments WHERE sales_order_id = so) THEN RAISE EXCEPTION 'MES3B_LIVE|a refused shipment left a shipment'; END IF;
    v_j := ship_order(so, d, jsonb_build_array(jsonb_build_object('reservation_id', res, 'scanned_code', ob_code)));
    RAISE NOTICE 'STEP|4e fusheng@ ships with a matching scan (%)|shipment %, % line(s), order %', ob_code, v_j ->> 'code', v_j ->> 'line_count', v_j ->> 'order_status';
    v_j := shipment_document((v_j ->> 'shipment_id')::uuid) -> 'lines' -> 0;
    RAISE NOTICE 'STEP|4f shipment document line|batch %, DG missing %, HS %', v_j ->> 'batch_code', v_j ->> 'dg_missing', COALESCE(v_j ->> 'hs_code', '-');

    EXECUTE 'RESET ROLE';
END;
$live$;

ROLLBACK;
SELECT 'PROOF_ROLLED_BACK', (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES3B%'), (SELECT count(*) FROM label_prints),
       (SELECT count(*) FROM scan_events);

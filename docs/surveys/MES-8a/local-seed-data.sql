-- MES-8a · LOCAL harness only (never live): data of my own on a fresh rebuild of this cut's mirrors, for the layout survey (desktop + 390px)
-- of every new or changed page. Run AFTER docs/surveys/MES-8a/local-seed-clones.sql (the seven role clones, read from live role_permissions
-- after the migration). Run as postgres on the rebuild:  psql "<local dsn>" -v ON_ERROR_STOP=1 -f local-seed-data.sql
-- States live has none of: a supplier with every measure (short / over / NCR open + decided / dispute / discharge mismatch / a lapsed
-- certificate), V23 + V24 set, a graded review corrected by another, a supplier with a not-graded review, one never reviewed;
-- AP activity on that supplier (an opening bill, a provisional receipt, a PO receipt with its deposit applied, an unpriced receipt,
-- a payment applied, one on account) and two statements over the same period (the first superseded by the second, with a reason).
\set ON_ERROR_STOP 1
DO $d$
DECLARE
    adm uuid := 'a0000000-0000-4000-8000-000000000001';
    v_base text; PS date := CURRENT_DATE - 30; PE date := CURRENT_DATE;
    s1 uuid; s2 uuid; s3 uuid; mat uuid; po_a uuid; po_b uuid; l_a uuid; l_b uuid; ra uuid; rb uuid; rc uuid; rd uuid; a1 uuid; a2 uuid; v_r jsonb; rv uuid;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;
    UPDATE company_profile SET legal_name = 'Local Survey Recovery Pte. Ltd.', address_lines = '1 Survey Road', city = 'Singapore', postal_code = '000001';
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code) VALUES
        ('SURV-S1', 'Survey Cells Supplier (a long legal name, Pte. Ltd.)', 'SG', 'active', 'goods_supplier', 'OP'),
        ('SURV-S2', 'Survey Not Graded Supplier', 'SG', 'approved', 'goods_supplier', 'OP'),
        ('SURV-S3', 'Survey Never Reviewed Supplier', 'SG', 'active', 'goods_supplier', 'OP');
    SELECT id INTO s1 FROM suppliers WHERE code = 'SURV-S1';
    SELECT id INTO s2 FROM suppliers WHERE code = 'SURV-S2';
    SELECT id INTO s3 FROM suppliers WHERE code = 'SURV-S3';
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('SURV-BM', 'Survey black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO mat;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, estimated_total_ccy, status, approval_status, category) VALUES
        ('SURV-POA', s1, PS, v_base, 1, 1000, 'confirmed', 'approved', 'equipment_goods'),
        ('SURV-POB', s1, PS, v_base, 1, 1000, 'confirmed', 'approved', 'equipment_goods');
    SELECT id INTO po_a FROM purchase_orders WHERE code = 'SURV-POA';
    SELECT id INTO po_b FROM purchase_orders WHERE code = 'SURV-POB';
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, estimated_unit_price, deep_discharge_judgement_code)
    VALUES (po_a, 1, mat, 100, 'kg', 10, 'can') RETURNING id INTO l_a;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, estimated_unit_price)
    VALUES (po_b, 1, mat, 40, 'kg', 25) RETURNING id INTO l_b;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), false);
    PERFORM record_expense(p_expense_date := PS - 5, p_account_code := '6400', p_amount := 400, p_currency := v_base,
                           p_payment_status := 'unpaid', p_supplier_id := s1, p_notes := 'survey opening bill');
    ra := (create_inbound_batch(mat, s1, 50, 'kg', PS + 2, '待加工', NULL, 'survey half delivery', po_a, l_a,
                                p_source_reason_code => 'other', p_source_reason_note => 'survey', p_currency => v_base) ->> 'batch_id')::uuid;
    UPDATE inbound_batches SET deep_discharge_actual_code = 'cannot' WHERE id = ra;
    PERFORM close_purchase_order(po_a, 'survey short delivery accepted');
    rb := (create_inbound_batch(mat, s1, 20, 'kg', PS + 3, '待加工', 30, 'survey priced receipt',
                                p_source_reason_code => 'other', p_source_reason_note => 'survey', p_currency => v_base) ->> 'batch_id')::uuid;
    PERFORM record_payment_internal('out', s1, 300, v_base, NULL, NULL, PS + 1, 'survey deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', po_b, 'amount_doc', 300)), 'supplier');
    rc := (create_inbound_batch(mat, s1, 44, 'kg', PS + 4, '待加工', 25, 'survey PO receipt (over)', po_b, l_b,
                                p_source_reason_code => 'other', p_source_reason_note => 'survey', p_currency => v_base) ->> 'batch_id')::uuid;
    PERFORM apply_prepayment(po_b, rc, 300, 'survey', NULL, CURRENT_DATE);
    PERFORM record_payment_internal('out', s1, 250, v_base, NULL, NULL, PS + 7, 'survey pay the priced receipt',
        jsonb_build_array(jsonb_build_object('inbound_batch_id', rb, 'amount_doc', 250)));
    PERFORM record_payment_internal('out', s1, 100, v_base, NULL, NULL, PS + 8, 'survey on account', '[]'::jsonb, 'supplier');
    rd := (create_inbound_batch(mat, s2, 10, 'kg', PS + 6, '待加工', NULL, 'survey other supplier',
                                p_source_reason_code => 'other', p_source_reason_note => 'survey', p_currency => v_base) ->> 'batch_id')::uuid;
    PERFORM open_ncr('manual', 'Survey: wet cells in the half delivery', p_inbound_batch_id => ra);
    PERFORM open_ncr('manual', 'Survey: label missing', p_inbound_batch_id => rc);
    a1 := (record_assay_result(p_assay_date => PS + 5, p_metals => '[{"metal": "ni", "content_pct": 20}]'::jsonb, p_inbound_batch_id => ra,
                               p_weight_basis => 'dry', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    a2 := (record_assay_result(p_assay_date => PS + 5, p_metals => '[{"metal": "ni", "content_pct": 17}]'::jsonb, p_inbound_batch_id => ra,
                               p_weight_basis => 'dry', p_result_party => 'counterparty') ->> 'assay_result_id')::uuid;
    PERFORM open_assay_dispute(a1, a2, 'Survey: nickel differs');
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until) VALUES (s1, 'iso', 'SURV-ISO-1', PS - 60, PS + 9);

    -- V23 + V24,一次评审(B),一次带理由的更正(A);S2 一次 V23 没给时的评审(Not graded)
    PERFORM record_supplier_review(s2, PS, PE, 'Survey: first look before any weights');
    PERFORM set_supplier_score_settings(
        (SELECT jsonb_object_agg(k, CASE k WHEN 'short_lines' THEN 3 WHEN 'over_lines' THEN 1 WHEN 'ncr_open' THEN 2 WHEN 'ncr_reject' THEN 5
                WHEN 'disputes' THEN 2 WHEN 'discharge_mismatches' THEN 1 WHEN 'certificate_lapse_days' THEN 0.1 ELSE 0 END) FROM unnest(supplier_scorecard_measure_keys()) k),
        '[{"grade":"A","max_score":5},{"grade":"B","max_score":20},{"grade":"C","max_score":null}]', 90,
        '{"A":{"prepayment_cap_pct":30,"sampling_level":"Every 10th bag"},"B":{"prepayment_cap_pct":20,"sampling_level":"Every 5th bag, with a second sample from any bag that looks wet"}}');
    v_r := record_supplier_review(s1, PS, PE, 'Survey: monthly review');
    rv := (v_r ->> 'review_id')::uuid;
    PERFORM set_supplier_score_settings((SELECT weights FROM supplier_score_settings),
        '[{"grade":"A","max_score":15},{"grade":"B","max_score":30},{"grade":"C","max_score":null}]', 90,
        '{"A":{"prepayment_cap_pct":30,"sampling_level":"Every 10th bag"},"B":{"prepayment_cap_pct":20,"sampling_level":"Every 5th bag, with a second sample from any bag that looks wet"}}');
    PERFORM record_supplier_review(s1, PS, PE, NULL, rv, 'Survey: grade lines widened after the monthly review');

    -- 两份同一段期间的对账单:第一份被第二份取代(带理由)
    PERFORM issue_supplier_statement(s1, PS, PE);
    PERFORM issue_supplier_statement(s1, PS, PE, 'Survey: reissued after the supplier queried the deposit line');
    RAISE NOTICE 'SURVEY_IDS|s1=%|s2=%|s3=%|ra=%|rb=%|rc=%|st_old=%|st_new=%', s1, s2, s3, ra, rb, rc,
        (SELECT id FROM supplier_statements WHERE superseded_at IS NOT NULL), (SELECT id FROM supplier_statements WHERE superseded_at IS NULL);
END $d$;

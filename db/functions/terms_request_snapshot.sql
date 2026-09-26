-- db/functions/terms_request_snapshot.sql
-- APR-8(2026-09-26,grilling Q8):提交时冻给 CFO 读的那一组。
--   公式:formula_code / formula_name / direction;current(提交时公式上的条款;新公式为 NULL —— 它此前什么都不是);
--        proposed(批准时写进去的那一组);last_approved(这张公式上一次被批准的那一组,从未批过为 NULL);
--        usage —— 哪些单据用它:已抄下承诺的采购行、已承诺的批次(这两类【不受影响】,它们读的是副本),
--        以及挂着这张公式却还没承诺的批次(应用化验时会抄【批准那一刻】活的条款)。计价器、新采购单、销售从批准起读新条款。
--   合同:contract_code / title / side / counterparty_name;current(提交时的表头与七张条款表);
--        last_approved(上一次批准生效时的那一份,从未批过为 NULL);linked_documents(已挂上的单据 —— 各自带着
--        挂上那一刻抄下的 contract_document_terms,不受影响)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_snapshot(p_kind text, p_subject uuid, p_proposed jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_kind = 'contract_activate' THEN (
        SELECT jsonb_build_object(
            'contract_code', c.code, 'title', c.title, 'side', c.side, 'status', c.status,
            'counterparty_name', COALESCE((SELECT COALESCE(s.short_name, s.legal_name) FROM suppliers s WHERE s.id = c.supplier_id),
                                          (SELECT cu.legal_name FROM customers cu WHERE cu.id = c.customer_id)),
            'current', contract_terms_state(c.id),
            'last_approved', (SELECT r.snapshot->'current' FROM terms_requests r
                               WHERE r.contract_id = c.id AND r.status = 'approved'
                               ORDER BY r.executed_at DESC LIMIT 1),
            'linked_documents', (SELECT count(*) FROM contract_document_terms d WHERE d.contract_id = c.id))
          FROM contracts c WHERE c.id = p_subject)
    ELSE (
        SELECT jsonb_build_object(
            'formula_code', f.code, 'formula_name', f.name, 'direction', f.direction, 'is_active', f.is_active,
            'current', CASE WHEN p_kind = 'formula_create' THEN NULL ELSE formula_terms_state(f.id) END,
            'proposed', p_proposed,
            'last_approved', (SELECT r.proposed FROM terms_requests r
                               WHERE r.formula_id = f.id AND r.status = 'approved'
                               ORDER BY r.executed_at DESC LIMIT 1),
            'usage', jsonb_build_object(
                'po_lines_committed', (SELECT count(*) FROM purchase_order_lines l
                                        WHERE l.pricing_formula_id = f.id
                                          AND EXISTS (SELECT 1 FROM pricing_term_commitments ptc
                                                       WHERE ptc.purchase_order_line_id = l.id)),
                'batches_committed', (SELECT count(*) FROM inbound_batches b
                                       WHERE b.pricing_formula_id = f.id AND b.deleted_at IS NULL
                                         AND (EXISTS (SELECT 1 FROM pricing_term_commitments ptc WHERE ptc.inbound_batch_id = b.id)
                                              OR EXISTS (SELECT 1 FROM pricing_term_commitments ptc
                                                          WHERE ptc.purchase_order_line_id = b.purchase_order_line_id))),
                'batches_uncommitted', (SELECT count(*) FROM inbound_batches b
                                         WHERE b.pricing_formula_id = f.id AND b.deleted_at IS NULL
                                           AND NOT EXISTS (SELECT 1 FROM pricing_term_commitments ptc WHERE ptc.inbound_batch_id = b.id)
                                           AND NOT EXISTS (SELECT 1 FROM pricing_term_commitments ptc
                                                            WHERE ptc.purchase_order_line_id = b.purchase_order_line_id))))
          FROM pricing_formulas f WHERE f.id = p_subject)
    END
$function$;

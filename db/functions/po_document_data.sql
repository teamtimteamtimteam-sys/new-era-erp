CREATE OR REPLACE FUNCTION public.po_document_data(p_po_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po   record;
    v_sup  record;
    v_lines jsonb;
    v_terms jsonb;
BEGIN
    PERFORM require_permission('module.purchasing.view');

    SELECT po.id, po.code, po.order_date, po.expected_delivery_date, po.currency,
           po.status, po.approval_status, po.incoterm, po.terms_text, po.notes,
           po.estimated_total_ccy, po.supplier_id
    INTO v_po FROM purchase_orders po
    WHERE po.id = p_po_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;

    SELECT s.legal_name, s.address, s.country, s.tax_id
    INTO v_sup FROM suppliers s WHERE s.id = v_po.supplier_id;

    -- ── 逐行:定价状态在这里裁决,PDF 只负责画(docs/purchase-order-document.md §B)──
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'line_no', l.line_no,
        'material_name', COALESCE(m.name, fa.description),
        'quantity', l.quantity,
        'unit', l.unit,
        'unit_price', l.estimated_unit_price,          -- 单据币种;可空
        'amount_ccy', l.estimated_amount_ccy,
        'expected_assay', l.expected_assay,
        'notes', l.notes,
        -- 【FIN-26 的那次误读,在这里终结】价格是不是手填的【估算】是记录下来的
        -- 事实(price_source),不是从公式在不在推断的
        'price_is_manual_estimate', (l.price_source = 'manual' AND c.id IS NOT NULL),
        'pricing_status', CASE
            WHEN c.id IS NOT NULL                 THEN 'provisional_committed'
            -- 公式挂着、条款没抄下来(FIN-27 之前的旧行):【不印公式今天的条款】——
            -- 那是编造一份承诺,known-wrong 里写明这些行走手工结算
            WHEN l.pricing_formula_id IS NOT NULL THEN 'provisional_uncommitted'
            WHEN l.estimated_unit_price IS NOT NULL THEN 'fixed'
            ELSE 'not_priced'
        END,
        'committed_terms', CASE WHEN c.id IS NOT NULL THEN jsonb_build_object(
            'source_formula_code', c.source_formula_code,
            'source_formula_name', c.source_formula_name,
            'price_basis', c.price_basis,
            'average_days', c.average_days,
            'treatment_charge_usd_per_tonne', c.treatment_charge_usd_per_tonne,
            'flat_discount_pct', c.flat_discount_pct,
            'metals', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                           'metal', cm.metal, 'payable_pct', cm.payable_pct)
                           ORDER BY cm.metal), '[]'::jsonb)
                       FROM pricing_term_commitment_metals cm
                       WHERE cm.commitment_id = c.id)
        ) END
    ) ORDER BY l.line_no), '[]'::jsonb)
    INTO v_lines
    FROM purchase_order_lines l
    -- EQP-1a:【INNER → LEFT】原先是 JOIN materials —— 设备行会从【打印出来的
    -- 采购单】上整行消失,而单据其余部分照常成立:没有错误、没有空行,
    -- 只是那台机器不在发给供应商的纸上。
    LEFT JOIN materials m ON m.id = l.material_id
    LEFT JOIN fixed_assets fa ON fa.id = l.asset_id
    LEFT JOIN pricing_term_commitments c ON c.purchase_order_line_id = l.id
    WHERE l.purchase_order_id = p_po_id;

    -- ── 付款计划(FIN-29 的承诺分期,原样印)────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'seq', t.seq, 'label', t.label, 'percentage', t.percentage,
        'fixed_amount_ccy', t.fixed_amount_ccy,
        'trigger_event', t.trigger_event, 'due_date', t.due_date, 'notes', t.notes
    ) ORDER BY t.seq), '[]'::jsonb)
    INTO v_terms
    FROM purchase_order_payment_terms t WHERE t.purchase_order_id = p_po_id;

    -- 【单据币种,只有单据币种】(§D)—— 这里没有 fx_rate,没有本位币数字。
    -- 本位币是内部口径:它决定审批级别,不该出现在供应商手里的纸上。
    RETURN jsonb_build_object(
        'code', v_po.code,
        'order_date', v_po.order_date,
        'expected_delivery_date', v_po.expected_delivery_date,
        'currency', v_po.currency,
        'status', v_po.status,
        'approval_status', v_po.approval_status,
        'incoterm', v_po.incoterm,
        'terms_text', v_po.terms_text,
        'notes', v_po.notes,
        'estimated_total_ccy', v_po.estimated_total_ccy,
        'supplier', jsonb_build_object(
            'legal_name', v_sup.legal_name, 'address', v_sup.address,
            'country', v_sup.country, 'tax_id', v_sup.tax_id),
        'lines', v_lines,
        'payment_terms', v_terms
    );
END;
$function$


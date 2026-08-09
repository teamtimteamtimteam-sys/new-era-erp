CREATE OR REPLACE FUNCTION public.approve_purchase_order(p_po_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_base  numeric;
    v_level smallint;
BEGIN
    PERFORM require_permission('module.purchasing.view');

    SELECT id, code, created_by, approval_status, status, currency, fx_rate, estimated_total_ccy
    INTO v_po FROM purchase_orders WHERE id = p_po_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_po_id::text, '?');
    END IF;
    IF v_po.approval_status <> 'pending' THEN
        RAISE EXCEPTION 'PO_NOT_PENDING|%|%', v_po.code, v_po.approval_status;
    END IF;

    -- 【四眼】提单的人不能自己批。与 approve_review 的 SELF_APPROVAL_FORBIDDEN 同名同理。
    IF v_po.created_by IS NOT NULL AND v_po.created_by = auth.uid() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN';
    END IF;

    -- 【本位币比,用单据自己存的汇率】(决定 3)。FIN-35 删掉了 fx_rate 的默认值,
    -- 所以一张外币单要么带着真汇率,要么根本不存在 —— 这里不必再防平价。
    v_base  := round(v_po.estimated_total_ccy * v_po.fx_rate, 2);
    v_level := approval_level_for(v_base);
    PERFORM require_approver_for(v_level);

    UPDATE purchase_orders
    SET approval_status = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        -- 批准把单据从 draft 推到 confirmed;advance_po_on_receipt 仍按 confirmed 走
        status = CASE WHEN status = 'draft' THEN 'confirmed' ELSE status END,
        updated_by = auth.uid()
    WHERE id = p_po_id;

    PERFORM record_approval_decision('purchase_order', p_po_id, 'approved', v_level, p_note);

    RETURN jsonb_build_object('purchase_order_id', p_po_id, 'code', v_po.code,
                              'level', v_level, 'amount_base', v_base);
END;
$function$;
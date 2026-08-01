CREATE OR REPLACE FUNCTION public.apply_payment_term_template(p_purchase_order_id uuid, p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_tpl   record;
    v_count integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    SELECT id, code, order_date, status INTO v_po
    FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT id, name INTO v_tpl
    FROM payment_term_templates
    WHERE id = p_template_id AND deleted_at IS NULL AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEMPLATE_NOT_FOUND|%', COALESCE(p_template_id::text, '?');
    END IF;

    -- 【替换】而不是追加:套模板的语义是"这张 PO 的计划就是模板说的那样"
    DELETE FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              fixed_amount_usd, trigger_event, due_date, notes)
    SELECT p_purchase_order_id, l.seq, l.label, l.percentage, l.fixed_amount_usd, l.trigger_event,
           -- 模板存的是相对下单日的天数偏移(模板不可能知道具体日期)
           CASE WHEN l.trigger_event = 'fixed_date'
                THEN v_po.order_date + COALESCE(l.days_offset, 0)
                ELSE NULL END,
           l.notes
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id
    ORDER BY l.seq;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object('purchase_order_id', p_purchase_order_id, 'term_count', v_count);
END;
$function$;
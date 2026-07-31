CREATE OR REPLACE FUNCTION public.reopen_purchase_order(p_purchase_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_po     record;
    v_status text;
BEGIN
    SELECT id, code, status INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status <> 'closed' THEN
        RAISE EXCEPTION 'PO_NOT_CLOSED|%', v_po.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 已经收过货的回到 'receiving',一车没收过的回到 'confirmed'
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM inbound_batches ib
        WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL
    ) THEN 'receiving' ELSE 'confirmed' END INTO v_status;

    UPDATE purchase_orders
    SET status = v_status,
        closed_at = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' reopened] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_purchase_order_id;

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', v_status
    );
END;
$function$


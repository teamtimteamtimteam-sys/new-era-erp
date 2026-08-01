CREATE OR REPLACE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INVOICE_ALREADY_VOID|%', v_inv.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 明细行保留供审计;作废标记由 trg_invoices_propagate_void 同步到明细行,
    -- 这些销售随之重新可开票。
    UPDATE invoices
    SET status = 'void',
        void_reason = btrim(p_reason),
        voided_at = now(),
        voided_by = auth.uid()
    WHERE id = p_invoice_id;

    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'status', 'void'
    );
END;
$function$;
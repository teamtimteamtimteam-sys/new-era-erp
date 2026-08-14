CREATE OR REPLACE FUNCTION public.guard_invoice_line_kind()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind text;
BEGIN
    SELECT kind INTO v_kind FROM invoices WHERE id = NEW.invoice_id;
    IF v_kind = 'order' AND NEW.sales_order_line_id IS NULL THEN
        RAISE EXCEPTION 'INVOICE_LINE_KIND_MISMATCH|%', v_kind;
    ELSIF v_kind = 'sale' AND NEW.sales_record_id IS NULL THEN
        RAISE EXCEPTION 'INVOICE_LINE_KIND_MISMATCH|%', COALESCE(v_kind, '?');
    END IF;
    RETURN NEW;
END;
$function$

;

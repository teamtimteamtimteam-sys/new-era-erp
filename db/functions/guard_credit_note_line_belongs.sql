CREATE OR REPLACE FUNCTION public.guard_credit_note_line_belongs()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_note_invoice uuid;
    v_line_invoice uuid;
BEGIN
    SELECT invoice_id INTO v_note_invoice FROM credit_notes WHERE id = NEW.credit_note_id;
    SELECT invoice_id INTO v_line_invoice FROM invoice_lines WHERE id = NEW.invoice_line_id;
    IF v_note_invoice IS DISTINCT FROM v_line_invoice THEN
        RAISE EXCEPTION 'CN_LINE_WRONG_INVOICE|%', COALESCE(NEW.invoice_line_id::text, '?');
    END IF;
    RETURN NEW;
END;
$function$

;

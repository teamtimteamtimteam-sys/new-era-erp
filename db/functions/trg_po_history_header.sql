CREATE OR REPLACE FUNCTION public.trg_po_history_header()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 只记【商业字段】的改动:updated_at/updated_by 的变化不是编辑史。
    -- 状态转换(cancel/close/reopen)也不记 —— 它们有自己的记录路径,
    -- 记进来会让编辑史被状态噪音淹掉。
    IF NEW.order_date IS NOT DISTINCT FROM OLD.order_date
       AND NEW.expected_delivery_date IS NOT DISTINCT FROM OLD.expected_delivery_date
       AND NEW.fx_rate IS NOT DISTINCT FROM OLD.fx_rate
       AND NEW.estimated_total_ccy IS NOT DISTINCT FROM OLD.estimated_total_ccy
       AND NEW.incoterm IS NOT DISTINCT FROM OLD.incoterm
       AND NEW.terms_text IS NOT DISTINCT FROM OLD.terms_text
       AND NEW.notes IS NOT DISTINCT FROM OLD.notes THEN
        RETURN NEW;
    END IF;

    INSERT INTO purchase_order_history (
        purchase_order_id, change_type,
        old_order_date, new_order_date,
        old_expected_delivery_date, new_expected_delivery_date,
        old_fx_rate, new_fx_rate,
        old_estimated_total_ccy, new_estimated_total_ccy,
        old_incoterm, new_incoterm, old_terms_text, new_terms_text,
        old_notes, new_notes, amend_reason)
    VALUES (NEW.id, 'header_update',
        OLD.order_date, NEW.order_date,
        OLD.expected_delivery_date, NEW.expected_delivery_date,
        OLD.fx_rate, NEW.fx_rate,
        OLD.estimated_total_ccy, NEW.estimated_total_ccy,
        OLD.incoterm, NEW.incoterm, OLD.terms_text, NEW.terms_text,
        OLD.notes, NEW.notes,
        NULLIF(current_setting('evoltrya.amend_reason', true), ''));
    RETURN NEW;
END;
$function$;
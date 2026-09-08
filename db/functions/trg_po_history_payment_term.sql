CREATE OR REPLACE FUNCTION public.trg_po_history_payment_term()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_reason text := NULLIF(current_setting('evoltrya.amend_reason', true), '');
    v_old jsonb;
    v_new jsonb;
BEGIN
    -- 【建单时的那一批期数不记】与 trg_po_history_line 逐字同一条:否则每张新单
    -- 都会先长出一份"全是新增"的历史,把真正的修改埋掉。
    IF TG_OP = 'INSERT'
       AND current_setting('evoltrya.po_amend_ctx', true) IS DISTINCT FROM '1' THEN
        RETURN NEW;
    END IF;

    IF TG_OP <> 'INSERT' THEN
        v_old := jsonb_build_object(
            'seq', OLD.seq, 'label', OLD.label, 'percentage', OLD.percentage,
            'fixed_amount_ccy', OLD.fixed_amount_ccy, 'trigger_event', OLD.trigger_event,
            'due_date', OLD.due_date, 'notes', OLD.notes);
    END IF;
    IF TG_OP <> 'DELETE' THEN
        v_new := jsonb_build_object(
            'seq', NEW.seq, 'label', NEW.label, 'percentage', NEW.percentage,
            'fixed_amount_ccy', NEW.fixed_amount_ccy, 'trigger_event', NEW.trigger_event,
            'due_date', NEW.due_date, 'notes', NEW.notes);
    END IF;

    -- 一次没有改动的 UPDATE 不记 —— 与表头、明细两支同一条。
    IF TG_OP = 'UPDATE' AND v_old = v_new THEN
        RETURN NEW;
    END IF;

    INSERT INTO purchase_order_history (
        purchase_order_id, change_type, payment_term_seq,
        old_payment_term, new_payment_term, amend_reason)
    VALUES (
        CASE WHEN TG_OP = 'DELETE' THEN OLD.purchase_order_id ELSE NEW.purchase_order_id END,
        CASE TG_OP WHEN 'INSERT' THEN 'payment_term_add'
                   WHEN 'UPDATE' THEN 'payment_term_update'
                   ELSE 'payment_term_remove' END,
        CASE WHEN TG_OP = 'DELETE' THEN OLD.seq ELSE NEW.seq END,
        v_old, v_new, v_reason);

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$

CREATE OR REPLACE FUNCTION public.log_cost_entry_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_type text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO processing_cost_entry_history (
            entry_id, run_id, change_type, new_amount_base, new_cost_type, new_is_estimate, changed_by)
        VALUES (NEW.id, NEW.run_id, 'create', NEW.amount_base, NEW.cost_type, NEW.is_estimate,
                COALESCE(NEW.created_by, auth.uid()));
        RETURN NULL;
    END IF;

    IF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        v_type := 'delete';
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
        v_type := 'restore';
    ELSIF NEW.amount_base IS DISTINCT FROM OLD.amount_base
       OR NEW.cost_type   IS DISTINCT FROM OLD.cost_type
       OR NEW.is_estimate IS DISTINCT FROM OLD.is_estimate THEN
        v_type := 'update';
    ELSE
        RETURN NULL;  -- 只动了备注之类,不留痕
    END IF;

    INSERT INTO processing_cost_entry_history (
        entry_id, run_id, change_type,
        old_amount_base, new_amount_base, old_cost_type, new_cost_type,
        old_is_estimate, new_is_estimate, changed_by)
    VALUES (NEW.id, NEW.run_id, v_type,
            OLD.amount_base, NEW.amount_base, OLD.cost_type, NEW.cost_type,
            OLD.is_estimate, NEW.is_estimate, COALESCE(NEW.updated_by, auth.uid()));
    RETURN NULL;
END;
$function$

CREATE OR REPLACE FUNCTION public.trg_task_nodes_touch()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at := now();
        NEW.updated_by := current_user_employee();
        IF OLD.done IS DISTINCT FROM NEW.done THEN
            NEW.done_at := CASE WHEN NEW.done THEN now() END;
            NEW.done_by := CASE WHEN NEW.done THEN current_user_employee() END;
        END IF;
    ELSE
        NEW.created_by := COALESCE(NEW.created_by, current_user_employee());
        NEW.updated_by := COALESCE(NEW.updated_by, current_user_employee());
        IF NEW.done THEN
            NEW.done_at := COALESCE(NEW.done_at, now());
            NEW.done_by := COALESCE(NEW.done_by, current_user_employee());
        END IF;
    END IF;
    RETURN NEW;
END;
$function$


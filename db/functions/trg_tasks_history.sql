CREATE OR REPLACE FUNCTION public.trg_tasks_history()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.task_type <> 'team' THEN RETURN NEW; END IF;   -- 私人任务不记
    IF (OLD.title, OLD.description, OLD.status, OLD.priority,
        OLD.due_date, OLD.reminder_at, OLD.tags)
       IS NOT DISTINCT FROM
       (NEW.title, NEW.description, NEW.status, NEW.priority,
        NEW.due_date, NEW.reminder_at, NEW.tags) THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.task_history (
        task_id, change_type, changed_by,
        old_title, new_title, old_description, new_description,
        old_status, new_status, old_priority, new_priority,
        old_due_date, new_due_date, old_reminder_at, new_reminder_at,
        old_tags, new_tags)
    VALUES (
        NEW.id, 'header_update', current_user_employee(),
        NULLIF(OLD.title, NEW.title),             NULLIF(NEW.title, OLD.title),
        NULLIF(OLD.description, NEW.description), NULLIF(NEW.description, OLD.description),
        NULLIF(OLD.status, NEW.status),           NULLIF(NEW.status, OLD.status),
        NULLIF(OLD.priority, NEW.priority),       NULLIF(NEW.priority, OLD.priority),
        NULLIF(OLD.due_date, NEW.due_date),       NULLIF(NEW.due_date, OLD.due_date),
        NULLIF(OLD.reminder_at, NEW.reminder_at), NULLIF(NEW.reminder_at, OLD.reminder_at),
        CASE WHEN OLD.tags IS DISTINCT FROM NEW.tags THEN OLD.tags END,
        CASE WHEN OLD.tags IS DISTINCT FROM NEW.tags THEN NEW.tags END);
    RETURN NEW;
END;
$function$


CREATE OR REPLACE FUNCTION public.trg_tasks_team_owner_participant()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.task_type = 'team' AND NEW.owner_id IS NOT NULL THEN
        PERFORM public.ensure_task_owner_participant(NEW.id, NEW.owner_id, NEW.owner_id);
    END IF;
    RETURN NULL;
END;
$function$


CREATE OR REPLACE FUNCTION public.promote_task_to_team(p_task_id uuid)
 RETURNS void
 LANGUAGE sql
AS $function$
    UPDATE public.tasks SET task_type = 'team' WHERE id = p_task_id;
$function$


CREATE OR REPLACE FUNCTION public.correct_task_type(p_task_id uuid)
 RETURNS void
 LANGUAGE sql
AS $function$
    UPDATE public.tasks SET task_type = 'personal' WHERE id = p_task_id;
$function$


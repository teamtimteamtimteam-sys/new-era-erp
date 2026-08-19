CREATE OR REPLACE FUNCTION public.can_view_task(p_task_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT has_permission('module.tasks.view')
       AND EXISTS (
           SELECT 1 FROM public.tasks t
            WHERE t.id = p_task_id
              AND (
                    t.task_type = 'team'
                 OR t.owner_id = current_user_employee()   -- ← 1c-a:已在员工空间
                 OR has_permission('module.tasks.view_all')
              )
       );
$function$


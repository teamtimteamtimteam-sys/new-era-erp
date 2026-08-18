CREATE OR REPLACE FUNCTION public.can_edit_task(p_task_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT has_permission('module.tasks.edit')
       AND EXISTS (
           SELECT 1 FROM public.tasks t
            WHERE t.id = p_task_id
              AND t.deleted_at IS NULL
              AND CASE
                    WHEN t.task_type = 'team' THEN EXISTS (
                        SELECT 1 FROM public.task_participants p
                         WHERE p.task_id = t.id
                           AND p.employee_id = current_user_employee()
                           AND p.removed_at IS NULL)
                    ELSE t.owner_id = auth.uid()      -- ← 1c 搬 owner_id 时改这里
                  END
       );
$function$


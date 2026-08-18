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
                    -- 团队(以及【曾经是】团队):大家看得见。
                    t.task_type = 'team'
                    -- 私人:只有本人,外加一把点名的钥匙(默认没有任何角色持有)
                 OR t.owner_id = auth.uid()          -- ← 1c 搬 owner_id 时改这里
                 OR has_permission('module.tasks.view_all')
              )
       );
$function$


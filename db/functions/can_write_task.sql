CREATE OR REPLACE FUNCTION public.can_write_task(p_task_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT public.can_edit_task(p_task_id)
        OR (has_permission('module.tasks.view')
            AND EXISTS (
                SELECT 1 FROM public.tasks t
                 WHERE t.id = p_task_id
                   AND t.deleted_at IS NULL
                   AND public.task_is_own(t.task_type, t.owner_id)));
$function$;

COMMENT ON FUNCTION public.can_write_task(uuid) IS
'APR-4(Tim 的 Q4/Q5):这个人能不能改这张任务的【内容】—— 表头、状态、步骤、软删。
= can_edit_task(持 module.tasks.edit 的完整编辑人:团队任务要是活跃参与者,私人任务要是归属人)
  OR 自己的任务例外(持 module.tasks.view,且 task_is_own)。
★ 它【不】管升级为团队任务、加参与者、改归属人 —— 那些仍然只有 can_edit_task 开得了(升级与参与者),或者谁都开不了(归属人,trg_tasks_guard_write 按名拒)。
★ 读它的:tasks 的 WITH CHECK、task_nodes 的写策略与守卫、task_board_rows.may_write(屏幕上那一个"能不能改"的判据就是它,lib/taskAccess.ts 只是把它读出来)。';

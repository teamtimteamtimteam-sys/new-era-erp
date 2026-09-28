-- db/functions/change_log_task_visible.sql
-- HISTORY-1(Tim 的 Q6):任务四张表(tasks · task_nodes · task_participants · task_history)的记录,
-- 按 can_view_task 判【整行】看不看得见。个人任务是私的 —— admin 与 cfo 都不持 module.tasks.view_all,
-- 只遮列会把任务屏幕刻意不给的标题与描述整段交给他们。
-- 任务还在 → 直接问 can_view_task;任务已经不在了 → 用它最后一份记录里的 task_type / owner_id,
-- 按 can_view_task 同一个判据答;连任务 id 都找不到 → 只有 view_all 看得见。
CREATE OR REPLACE FUNCTION public.change_log_task_visible(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_task text := CASE WHEN p_table = 'tasks' THEN p_key ->> 'id'
                        ELSE change_log_field(p_table, p_key, p_old, p_new, 'task_id') END;
    v_k    jsonb;
BEGIN
    IF v_task IS NULL THEN
        RETURN has_permission('module.tasks.view_all');
    END IF;
    IF EXISTS (SELECT 1 FROM tasks t WHERE t.id = v_task::uuid) THEN
        RETURN can_view_task(v_task::uuid);
    END IF;
    v_k := jsonb_build_object('id', v_task);
    RETURN has_permission('module.tasks.view')
       AND (   has_permission('module.tasks.view_all')
            OR change_log_field('tasks', v_k, NULL, NULL, 'task_type') = 'team'
            OR COALESCE(change_log_field('tasks', v_k, NULL, NULL, 'owner_id') = current_user_employee()::text, false));
END;
$function$;

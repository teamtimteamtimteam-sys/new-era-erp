-- db/functions/waiting_mine.sql
-- SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9),grilling 接受):在等【我自己】动手的、不是审批的那几件 ——
--   task          我的任务:我是主人,或我是在册的参与者(task_participants,removed_at 为空);todo / in_progress,没删。
--                 ★ 不是"我看得见的任务":team 任务对每一个持 module.tasks.view 的人都看得见,那不叫"在等我"。
--                 门与任务页同一支:can_view_task()(持 module.tasks.view 且这张任务对我可见)。
--   review_write  一份考核在 draft,而我是考核人(reviewer_employee_id = 我)—— /my-reviews 那一格"在我桌上"。
--   self_review   一份考核在 self_review,而被考核的人是我 —— /me 上的自评(save_self_assessment 的门:员工 = 我)。
--   考核的第三条腿(submitted → 批准)是一个审批,住在 waiting_decisions。
-- 列与 waiting_decisions 同形,多一列 due_date(任务的到期日;别的为空)。
-- 【为什么 SECURITY DEFINER】考核表对被考核的人只放 approved 之后的行;"我"由 current_user_employee() 按调用者裁。没有会话 → 零行。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.waiting_mine()
 RETURNS TABLE(item_type text, item_id uuid, parent_id uuid, doc_kind text, code text, subject text, raised_by jsonb, waiting_since timestamp with time zone, due_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH me AS (SELECT current_user_employee() AS emp)
    SELECT 'task'::text, t.id, NULL::uuid, t.task_type, t.code, t.title,
           trail_actor('prelog', t.created_by, NULL::uuid), t.created_at, t.due_date
      FROM tasks t CROSS JOIN me
     WHERE me.emp IS NOT NULL AND t.deleted_at IS NULL AND t.status IN ('todo', 'in_progress')
       AND (t.owner_id = me.emp
            OR EXISTS (SELECT 1 FROM task_participants tp
                        WHERE tp.task_id = t.id AND tp.employee_id = me.emp AND tp.removed_at IS NULL))
       AND can_view_task(t.id)
    UNION ALL
    SELECT 'review_write', r.id, NULL, NULL, e.code, e.legal_name,
           trail_actor('prelog', r.created_by, NULL::uuid), r.created_at, NULL::date
      FROM performance_reviews r CROSS JOIN me
      JOIN employees e ON e.id = r.employee_id
     WHERE me.emp IS NOT NULL AND r.status = 'draft' AND r.reviewer_employee_id = me.emp
    UNION ALL
    SELECT 'self_review', r.id, NULL, NULL, e.code, rv.legal_name,
           trail_actor('prelog', r.created_by, NULL::uuid), COALESCE(r.updated_at, r.created_at), NULL::date
      FROM performance_reviews r CROSS JOIN me
      JOIN employees e ON e.id = r.employee_id
      LEFT JOIN employees rv ON rv.id = r.reviewer_employee_id
     WHERE me.emp IS NOT NULL AND r.status = 'self_review' AND r.employee_id = me.emp
$function$;

COMMENT ON FUNCTION public.waiting_mine() IS
'SYSTEM-MAP-2:在等调用者自己动手、而不是审批的事 —— 我的任务(主人或在册参与者,todo / in_progress,can_view_task)· 我是考核人的 draft 考核 · 我是被考核人的 self_review 考核。考核的批准那一条腿在 waiting_decisions。没有会话 → 零行。';

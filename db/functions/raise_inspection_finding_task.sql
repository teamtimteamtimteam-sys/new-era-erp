-- db/functions/raise_inspection_finding_task.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q14,Tim):【"建一张任务"】—— 给【按下它的那个人】建一张私人任务,这条发现的 task_id 指着它。
--   ★ 任务模块一行不改(Q14):这一支走的就是任务模块自己那条"自己的私人任务"的路 —— 归属人是调用者本人(current_user_employee),
--     类型 personal;能建的人与任务表的插入策略说的是同一句话(持 module.tasks.edit,或持 module.tasks.view 建自己的私人任务)。
--     任务的标题是巡检编号 · 那一项的字,说明是纠正措施,到期日是这条发现的到期日(可空)。
--   ★【关掉那张任务不关闭这条发现】—— 发现只经 close_inspection_finding 关(两件事,两个出口)。
--   读这条发现要 module.safety.view;调用者不是一名员工 → INSPECTION_TASK_NEEDS_EMPLOYEE(任务属于一名员工);
--   建不了任务 → PERMISSION_DENIED|module.tasks.view;找不到 → INSPECTION_FINDING_NOT_FOUND|<id>;已经关了 → INSPECTION_FINDING_ALREADY_CLOSED;
--   已经建过 → INSPECTION_TASK_ALREADY_RAISED|<任务编号>(task_id 只写一次)。返回 {task_id, task_code}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.raise_inspection_finding_task(p_finding_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp  uuid := current_user_employee();
    v_f    record;
    v_task uuid;
    v_code text;
BEGIN
    PERFORM require_permission('module.safety.view');
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'INSPECTION_TASK_NEEDS_EMPLOYEE'
          USING HINT = '一张任务属于一名员工 —— 这个账号没有关联的员工档案。';
    END IF;
    IF NOT (has_permission('module.tasks.edit') OR has_permission('module.tasks.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.view';
    END IF;

    SELECT f.id, f.task_id, f.corrective_action, f.due_date, r.code AS run_code, s.position, s.item_text,
           EXISTS (SELECT 1 FROM inspection_finding_closures c WHERE c.finding_id = f.id) AS closed
      INTO v_f
      FROM inspection_findings f
      JOIN inspection_runs r ON r.id = f.run_id
      JOIN inspection_results s ON s.id = f.result_id
     WHERE f.id = p_finding_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_NOT_FOUND|%', COALESCE(p_finding_id::text, '?');
    END IF;
    IF v_f.closed THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_ALREADY_CLOSED';
    END IF;
    IF v_f.task_id IS NOT NULL THEN
        RAISE EXCEPTION 'INSPECTION_TASK_ALREADY_RAISED|%', (SELECT code FROM tasks WHERE id = v_f.task_id);
    END IF;

    INSERT INTO tasks (title, description, due_date, task_type, owner_id)
    VALUES (left(v_f.run_code || ' · ' || v_f.position || '. ' || v_f.item_text, 200), v_f.corrective_action, v_f.due_date, 'personal', v_emp)
    RETURNING id, code INTO v_task, v_code;
    UPDATE inspection_findings SET task_id = v_task WHERE id = p_finding_id;
    RETURN jsonb_build_object('task_id', v_task, 'task_code', v_code);
END;
$function$;

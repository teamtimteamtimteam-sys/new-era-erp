-- db/views/task_participant_directory.sql
-- TASK-1b-fu1。**属主权限视图(security_invoker 缺省 = off)—— 这是关键的一句。**
-- invoker 的话 employees 的 RLS(要 module.hr.view)会把行吃掉,
-- 一个仓库用户打开自己在上面的团队任务就会看到一排空白的名字 ——
-- 而空名字读起来像【数据缺失】,不像一个权限答复(OPS-14 那五处缺陷的形状)。
-- 属主权限替得了表的权限,替不了函数的 EXECUTE:视图体调 can_view_task /
-- has_permission,读者必须调得动它们(zzz_function_grants 授给了 authenticated)。

CREATE OR REPLACE VIEW public.task_participant_directory AS
SELECT
    p.id            AS participant_id,
    p.task_id,
    p.employee_id,
    COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name) AS display_name,
    p.added_at,
    p.added_by,
    COALESCE(NULLIF(btrim(ab.preferred_name), ''), ab.legal_name) AS added_by_name,
    p.removed_at,
    p.removed_by,
    (p.removed_by IS NOT NULL AND p.removed_by = p.employee_id) AS left_voluntarily
FROM public.task_participants p
JOIN public.employees e  ON e.id = p.employee_id
LEFT JOIN public.employees ab ON ab.id = p.added_by
WHERE can_view_task(p.task_id);

COMMENT ON VIEW public.task_participant_directory IS
'一张任务上的参与者,带【显示名】。属主权限:employees 的 SELECT 要 module.hr.view,而看得见这张任务的人就该看得见谁在上面 —— 名字是单据的属性,不是另一份秘密(AGENTS.md 常设决定 3)。
【只吐名字】。部门、职位、薪资都不在这里,也不要加进来:那条决定的边界就是"只有显示用的标签跟着单据走"。
left_voluntarily 把【自己退出】与【被移出】分开 —— 屏幕上写「已退出 / 已移出」,而不是「移除」:后者承诺了一件这个系统做不到的事(前参与者仍然读得到这张任务)。';

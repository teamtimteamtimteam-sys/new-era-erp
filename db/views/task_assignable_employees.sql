-- db/views/task_assignable_employees.sql
-- TASK-1b-fu1。**属主权限视图(security_invoker 缺省 = off)—— 这是关键的一句。**
-- invoker 的话 employees 的 RLS(要 module.hr.view)会把行吃掉,
-- 一个仓库用户打开自己在上面的团队任务就会看到一排空白的名字 ——
-- 而空名字读起来像【数据缺失】,不像一个权限答复(OPS-14 那五处缺陷的形状)。
-- 属主权限替得了表的权限,替不了函数的 EXECUTE:视图体调 can_view_task /
-- has_permission,读者必须调得动它们(zzz_function_grants 授给了 authenticated)。

CREATE OR REPLACE VIEW public.task_assignable_employees AS
SELECT
    e.id AS employee_id,
    e.code,
    COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name) AS display_name
FROM public.employees e
WHERE e.deleted_at IS NULL
  AND e.user_id IS NOT NULL          -- 没有登录账号的加进来会被按名拒绝
  AND e.employment_status <> 'separated'
  AND has_permission('module.tasks.edit');

COMMENT ON VIEW public.task_assignable_employees IS
'可以被加成参与者的在册员工:id + 显示名,没有别的。
【只列有登录账号的】—— 没有账号的员工会被 TASK_PARTICIPANT_NO_LOGIN 拒掉,把他放进选择框等于请人去撞一堵墙(而"他在名单里却加不进来"比"他不在名单里"更难懂)。
【这是一次明写的最小扩大】:持 module.tasks.edit 的人因此看得到在册员工的姓名清单。要的是让协作这件事能做,而不是把 HR 打开 —— 所以这里只有名字。';

-- TASK-1b-fu1:参与者的【名字】跟着任务走 —— 两张属主权限视图
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么需要它:实测,不是推断】
-- employees 的 SELECT 策略是 has_permission('module.hr.view')。任务模块的
-- 参与者是员工,而参与者面板要显示名字 —— 于是一个仓库/生产的用户打开一张
-- 他自己在上面的团队任务,看到的会是一排【空白的名字】。
-- 那正是 AGENTS.md 三条常设决定里第 3 条点名的失败:空名字读起来像【数据缺失】,
-- 不像一个权限答复;而 OPS-14 更狠的一版是整行消失(10 行读成 0 行)。
--
-- 【边界照抄那条决定,不扩大】
-- 「只有显示用的【名字】跟着单据走。」所以这两张视图只吐 id 与一个显示名,
-- 不吐部门、职位、薪资、工号以外的任何东西。要更多的,回 HR 模块去拿。
--
-- 【属主权限(security_invoker 缺省 = off),不是 invoker】
-- invoker 的话 employees 的 RLS 会照样把行吃掉 —— 那就是 OPS-14 那五处缺陷。
-- 属主权限替得了【表】的权限,替不了【函数的 EXECUTE】:视图体里调用
-- can_view_task / has_permission,读者必须调得动它们。两个都由
-- zzz_function_grants 授给 authenticated,所以成立(RPT-1 那次 500 就是漏了这一步)。
--
-- 【谁看得见】
-- * task_participant_directory:门槛就是 can_view_task —— 看得见这张任务的人,
--   就看得见谁在上面。这正是"名字跟着单据走"。
-- * task_assignable_employees:门槛是 module.tasks.edit,而且【只列有登录账号的】——
--   没有账号的员工加进来会被 TASK_PARTICIPANT_NO_LOGIN 拒掉,把他列进选择框
--   等于请人去撞一堵墙。这是一次【明写的、最小的】扩大:任务模块的编辑者
--   因此看得到在册员工的【姓名清单】。记在这里,不是顺手做掉的。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

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

COMMIT;

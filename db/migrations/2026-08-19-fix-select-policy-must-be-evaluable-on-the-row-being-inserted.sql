-- FIX:新建任务被 RLS 拒绝 —— 拒的不是 INSERT,是 RETURNING
--
-- 【现象】"+ 新建任务" 保存失败,屏幕上是一句原始的
--     new row violates row-level security policy for table "tasks"
-- 整个模块因此不能用。
--
-- 【实测把它钉死了(同一个账号、同一条 JWT)】
--     has_permission('module.tasks.view')      -> true
--     has_permission('module.tasks.edit')      -> true
--     插入行的 owner_id == 该账号的员工 id      -> true
--     can_view_task(<该行>)                     -> true   ← 提交之后是过的
--     裸 INSERT(不回读)                        -> 201    ← 成功
--     INSERT + Prefer: return=representation    -> 403 42501 ← 失败
--
-- 【一句话】被拒的不是 INSERT 策略,而是 **SELECT 策略** ——
-- PostgreSQL 会把 SELECT 策略同样施加在 `INSERT ... RETURNING` 上,
-- 而 can_view_task(id) 是【回头去 tasks 里查一行】来回答的;
-- 那一行此刻还不在自己这条命令的快照里,于是谓词为假,
-- 报出来的却是 "new row violates row-level security policy"。
-- 应用侧 createTask 发的正是 .insert(...).select(...).single(),即 representation。
--
-- 【这是 1c-a 里已经写下过的同一个陷阱,只是当时只想到了一半】
-- 那支迁移的 (f) 段解释过:INSERT 策略不能用 can_edit_task,因为新行对
-- WITH CHECK 的快照不可见。**漏掉的是:SELECT 策略也会在 RETURNING 上求值**,
-- 于是同一个陷阱从另一扇门进来了。
--
-- 【最小的修法:让谓词在【手里这一行】上就能算出来,不要回头查表】
-- 下面这段就是 can_view_task 的函数体去掉那个自查子查询 —— 对已提交的行语义
-- 完全一致(fixture 95 的 A/B/C/E 四臂逐条对过),而在 RETURNING 上它读的是
-- 新行自己的列,所以算得出来。
--
-- 【为什么不顺手把 can_view_task 也改掉】它对【子表】仍然是对的:
-- task_nodes / task_participants / task_history 的策略传进来的是【别的表】的
-- task_id,那时必须回头查 tasks。谓词在这里出现两次是【有代价的】,
-- 所以代价写在这:tasks 自己手里有行,子表手里没有 —— 两处问的是同一句话,
-- 但能拿到的东西不同。改动任一处,另一处要一起看。
BEGIN;

DROP POLICY "tasks select by predicate" ON public.tasks;

CREATE POLICY "tasks select by predicate"
    ON public.tasks
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (
        has_permission('module.tasks.view'::text)
        AND (
            task_type = 'team'::text
            OR owner_id = current_user_employee()
            OR has_permission('module.tasks.view_all'::text)
        )
    );

COMMIT;

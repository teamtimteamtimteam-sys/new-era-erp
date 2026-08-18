-- db/tables/task_participants.sql
-- TASK-1a:团队任务的参与者。首建脚本(列序即活库序)。
-- 触发器函数在 db/functions/ 里(重放顺序 functions → tables → views)。

CREATE TABLE public.task_participants (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     uuid NOT NULL REFERENCES public.tasks (id),
    employee_id uuid NOT NULL REFERENCES public.employees (id),
    added_by    uuid NOT NULL REFERENCES public.employees (id),
    added_at    timestamptz NOT NULL DEFAULT now(),
    removed_at  timestamptz,
    removed_by  uuid REFERENCES public.employees (id),
    CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);

-- 同一个人可以【离开后再回来】,所以不是 (task_id, employee_id) 全局唯一 ——
-- 那样"重新加入"只能靠清掉 removed_at,而那会抹掉他离开过这件事。
-- 唯一性只管【同时在场】:一个人在一张任务上最多一条活跃行。
CREATE UNIQUE INDEX uq_task_participants_active
    ON public.task_participants (task_id, employee_id) WHERE removed_at IS NULL;

COMMENT ON TABLE public.task_participants IS
'团队任务的参与者。【行,不是数组】:参与者集合会变,而变化本身正是 task_history 要记的东西 —— 数组记得住一个集合,记不住对它的一次改动。两端都有外键:一个打错的 uuid 与"这个人没有登录账号"在屏幕上一模一样(employees.user_id 那条外键买的是同一件事)。
【没有 DELETE 策略,也不该有】:退出是 UPDATE removed_at,不是删行。留下来的那一行是【证据】—— TASK-1c 的降级判据靠它,而不是靠 task_history 还在不在。';

COMMENT ON COLUMN public.task_participants.removed_at IS
'退出/移出的时刻。【软的,永不硬删】。注意:退出【不是取消分享】—— 前参与者仍然读得到这张任务(他的编辑在记录里,把他贡献过的东西藏起来读起来像抹掉)。所以屏幕上说「已退出 / 已移出」,绝不说「移除」:一个承诺了系统做不到的事的词,是本仓库反复点名的那种缺陷。';

ALTER TABLE public.task_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "task_participants select" ON public.task_participants
    FOR SELECT TO authenticated USING (can_view_task(task_id));
CREATE POLICY "task_participants insert" ON public.task_participants
    FOR INSERT TO authenticated WITH CHECK (can_edit_task(task_id));
CREATE POLICY "task_participants update" ON public.task_participants
    FOR UPDATE TO authenticated USING (can_edit_task(task_id)) WITH CHECK (can_edit_task(task_id));
-- 【没有 DELETE 策略】:退出是软的(置 removed_at),那一行是证据 ——
-- TASK-1c 的降级判据靠它,而不是靠 task_history 还在不在。

CREATE TRIGGER trg_task_participants_guard
    BEFORE INSERT OR UPDATE ON public.task_participants
    FOR EACH ROW EXECUTE FUNCTION trg_task_participants_guard();

CREATE TRIGGER trg_task_participants_history
    AFTER INSERT OR UPDATE ON public.task_participants
    FOR EACH ROW EXECUTE FUNCTION trg_task_participants_history();

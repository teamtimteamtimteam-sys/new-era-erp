-- db/tables/container_milestones.sql
-- LOG-2a。只增不改;守卫函数在 db/functions/guard_container_milestone_append_only.sql。

CREATE TABLE public.container_milestones (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    container_id uuid NOT NULL REFERENCES public.containers (id) ON DELETE RESTRICT,
    milestone    text NOT NULL CHECK (milestone IN
                     ('booked','gated_in','loaded','departed','arrived',
                      'customs_cleared','delivered','other')),
    event_date   date NOT NULL,
    note         text,
    recorded_by  uuid DEFAULT auth.uid(),
    recorded_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE public.container_milestones IS
'LOG-2a:箱子走到哪一步了。**只增不改** —— 记错了就再记一条并在 note 里说清楚,
绝不回头改一行。一条被改过的里程碑,读起来与一条本来就对的一模一样,而那正是这类记录要防的事。
【milestone 是一个小枚举 + 自由文本 note】:枚举给可比性,note 给现实。other 是留给现实的那一格,不是兜底的垃圾桶。
【跟踪只有手工录入】—— 没有对接、没有轮询、没有自动状态机。所以这里的每一行都有一个人。';

COMMENT ON COLUMN public.container_milestones.event_date IS
'LOG-2a:这一步是哪天发生的。**NOT NULL,且没有默认值 —— 调用方必须自己给。**
【要把两种日期分清楚,否则这条规矩会被读成教条】:
  * 世界那一侧的事件(departed / arrived / customs_cleared)系统【无从知道】,
    必须有人录;给它一个 CURRENT_DATE 默认值,会让"没填"比"填对"更容易通过。
  * 系统自己见证的事件(例如拆箱时追加的那条 other)日期是【已知的】,
    由那个调用方显式传今天 —— 那不是"系统替人猜",是"系统记下自己做过的事"。
区别在于【谁知道这件事】,不在于用了哪个函数。';

CREATE INDEX idx_container_milestones_container
    ON public.container_milestones (container_id, event_date DESC);

CREATE TRIGGER trg_container_milestones_append_only
    BEFORE UPDATE OR DELETE ON public.container_milestones
    FOR EACH ROW EXECUTE FUNCTION guard_container_milestone_append_only();

ALTER TABLE public.container_milestones ENABLE ROW LEVEL SECURITY;
CREATE POLICY "container_milestones select" ON public.container_milestones
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.purchasing.view'::text));
CREATE POLICY "container_milestones insert" ON public.container_milestones
    AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (has_permission('module.purchasing.edit'::text));

COMMENT ON COLUMN public.container_milestones.recorded_at IS
    'LOG-5d:这一行是【什么时候被录进来的】——【不是】事情发生的时间(那是 event_date)。
同一种里程碑之内,算数的是 recorded_at 最晚的那一条:更正的唯一写法是再记一条,
所以最后写下的那条就是算数的那条。默认值是 clock_timestamp() 而不是 now() ——
now() 是事务时刻,同一事务里插两条会拿到同一个值,那时"哪一条算数"就变成随意的了。';

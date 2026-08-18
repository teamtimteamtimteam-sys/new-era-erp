-- db/views/task_board_rows.sql
-- TASK-1a:看板与详情页共用的派生值(步骤数 / 已完成数 / 步骤是否排到截止日之后)。
--
-- 【这份镜像不是从 pg_get_viewdef() 抄来的,也不能那样抄】:pg_get_viewdef 只吐
-- SELECT,不吐 reloptions,照它重建会把下面那句 WITH (security_invoker = on)
-- 悄悄丢掉(AGENTS.md 里 PAYEE-1a 记过同一件事,方向相反)。而在这张视图上
-- 丢掉它【会真的改变行为】:行过滤就是 RLS 本身,变成属主权限之后每一张任务
-- 对每一个持 module.tasks.view 的人都可见,而且不报任何错。

CREATE OR REPLACE VIEW public.task_board_rows
WITH (security_invoker = on) AS
SELECT
    t.id, t.code, t.title, t.status, t.priority, t.task_type,
    t.due_date, t.reminder_at, t.tags, t.owner_id,
    n.node_count,
    n.done_count,
    -- 【步骤排到了截止日之后】—— 是一句陈述,不是一个警告色。
    -- 没有截止日、或者没有带日期的步骤时,它是 NULL(什么都不说),
    -- 不是 false(那会读成"一切正常")。
    CASE WHEN t.due_date IS NULL OR n.max_node_date IS NULL THEN NULL
         ELSE n.max_node_date > t.due_date END AS steps_overrun_due_date
FROM public.tasks t
LEFT JOIN LATERAL (
    SELECT count(*)::int AS node_count,
           count(*) FILTER (WHERE d.done)::int AS done_count,
           max(d.target_date) FILTER (WHERE NOT d.done) AS max_node_date
      FROM public.task_nodes d WHERE d.task_id = t.id) n ON true
WHERE t.deleted_at IS NULL;

COMMENT ON VIEW public.task_board_rows IS
'看板与详情页共用的派生值:步骤数、已完成数、以及【步骤是否排到了截止日之后】。
【一处实现,两个调用者】—— 把 3/5 算在 TaskBoard.tsx 里,详情页就会算第二遍,然后两份实现从写下的第二天开始漂移(这个仓库为这件事付过四次学费:化验预览、GrantRunner、重估预览、/finance/payments)。
【security_invoker = on 是【有意】的,而它的 61 个邻居都是 off】:这张视图的行过滤【就是】RLS 本身。把它改成 off,视图对读者依旧工作得完美无缺 —— 只是每一张任务对每一个持 module.tasks.view 的人都可见了,而且不报任何错。绿的,却对某一类读者是错的:这正是 OPS-14 那五处 xmodule 缺陷的签名。要改它之前,先想清楚谁来做行过滤。
注意 reloptions 里 security_invoker 可能写成 on 也可能写成 true —— 任何用 grep 找它的检查两种都要认(processing_metal_recovery 是本仓库唯一的 true)。';

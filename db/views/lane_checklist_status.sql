-- db/views/lane_checklist_status.sql
-- LOG-1a。镜像与 db/migrations/2026-08-19-log1a-*.sql 同源。

CREATE VIEW public.lane_checklist_status
WITH (security_invoker = on) AS
SELECT
    l.id AS lane_id,
    l.checklist_reviewed_at,
    count(r.id) FILTER (WHERE r.deleted_at IS NULL)::integer AS requirement_count,
    CASE
        WHEN l.checklist_reviewed_at IS NULL THEN 'not_defined'
        WHEN count(r.id) FILTER (WHERE r.deleted_at IS NULL) = 0 THEN 'defined_empty'
        ELSE 'defined'
    END AS checklist_state
FROM public.lanes l
LEFT JOIN public.lane_document_requirements r ON r.lane_id = l.id
WHERE l.deleted_at IS NULL
GROUP BY l.id, l.checklist_reviewed_at;

COMMENT ON VIEW public.lane_checklist_status IS
'LOG-1a:一条航段的单据清单处于哪一种状态 —— **三种,不是两种**:
not_defined  = 从来没人定过(checklist_reviewed_at 为 NULL)。**这不是"不需要单据"**,是"没人看过"。
defined_empty = 有人确认过,而且确实什么都不要。
defined      = 有人定过,并且列了要求。
把前两者混成"零条要求",就是把一次未完成的工作显示成一次完成的结论 —— 本仓库对空集当答案点过很多次名。
security_invoker = on:行过滤就是 RLS 本身。';

GRANT SELECT ON public.lane_checklist_status TO anon, authenticated, service_role;

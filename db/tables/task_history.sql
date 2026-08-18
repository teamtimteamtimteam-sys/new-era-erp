-- db/tables/task_history.sql
-- TASK-1a:团队任务的变更记录(采购单历史那一套:成对的、带类型的列)。
-- 首建脚本(列序即活库序)。

CREATE TABLE public.task_history (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id      uuid NOT NULL REFERENCES public.tasks (id),
    change_type  text NOT NULL CHECK (change_type IN (
                     'promoted_from_personal',
                     'header_update',
                     'node_added', 'node_removed', 'node_renamed',
                     'node_redated', 'node_done', 'node_undone', 'node_reordered',
                     'participant_added', 'participant_removed', 'participant_left',
                     'owner_transferred', 'task_deleted')),

    -- 【故意没有外键】:说"这个步骤被删了"的那条记录,必须比那个步骤活得久。
    -- 与 purchase_order_history.purchase_order_line_id 同一条理由,同一个写法。
    node_id      uuid,
    employee_id  uuid REFERENCES public.employees (id),   -- 成员变动 / 转移归属

    -- ═══ 表头七对 ═══
    old_title       text,        new_title       text,
    old_description text,        new_description text,
    old_status      text,        new_status      text,
    old_priority    text,        new_priority    text,
    old_due_date    date,        new_due_date    date,
    old_reminder_at timestamptz, new_reminder_at timestamptz,
    old_tags        text[],      new_tags        text[],

    -- ═══ 步骤四对 ═══
    old_node_title       text,    new_node_title       text,
    old_node_target_date date,     new_node_target_date date,
    old_node_done        boolean,  new_node_done        boolean,
    old_sort_order       integer,  new_sort_order       integer,

    changed_at   timestamptz NOT NULL DEFAULT now(),
    changed_by   uuid REFERENCES public.employees (id)
);

CREATE INDEX idx_task_history_task ON public.task_history (task_id, changed_at DESC);

COMMENT ON TABLE public.task_history IS
'团队任务的变更记录。**私人任务不写这里** —— 一个人不需要一份关于自己的审计。
【为什么是成对的、带类型的列,而不是 (字段名, 旧值, 新值) 三元组,更不是 jsonb 或一句人话】:与 sales_order_history 同一条 —— 机器读得懂的历史才查得了、比得了。而在这张表上还多一层:old_done / new_done 是真的 boolean,所以「哪些步骤被取消勾选、谁干的」是一次查询,不是一次阅读。
【没有理由列,两种形式都没有】。勾掉一个步骤不是修改一份对交易对手的承诺(采购单历史的 amend_reason 是为那件事存在的)。一个可填可不填的理由列在 95% 的行上是空的,而那份空白读起来像疏忽,不像设计。
【这个模块没有"保密的团队任务"这种形状】:私人 = 只有我看得见;团队 = 大家看得见、参与者能改。处分、薪酬、纠纷不该放在这个模块里。不要为此把 visibility 列加回来 —— 它在 TASK-1c 退役,两个功能之后又长回来,正是这次设计要避免的重新扯皮。';

COMMENT ON COLUMN public.task_history.node_id IS
'【没有外键,是故意的】。步骤是硬删的(它不软删,见 task_nodes),而 node_removed 这条记录连同 old_node_title / old_node_target_date / old_node_done 必须留下来。AUDEL-1a 堵的那个洞是"证据跟着一起没了";这里证据是特意设计成活得更久的。';

ALTER TABLE public.task_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY "task_history select" ON public.task_history
    FOR SELECT TO authenticated USING (can_view_task(task_id));
-- 【只有 SELECT】:变更记录由触发器写,不由任何调用者写。

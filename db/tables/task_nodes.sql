-- db/tables/task_nodes.sql
-- TASK-1a:任务里的有序步骤,一层嵌套。首建脚本(列序即活库序)。
-- 一层嵌套、以及【父子同属一张任务】,都由复合外键 + 生成列做成结构上不可能,
-- 不是靠触发器拒绝 —— 理由见表注释与 parent_depth 的列注释。

CREATE TABLE public.task_nodes (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id      uuid NOT NULL REFERENCES public.tasks (id),
    parent_id    uuid,
    depth        smallint NOT NULL DEFAULT 0 CHECK (depth IN (0, 1)),
    parent_depth smallint GENERATED ALWAYS AS
                 (CASE WHEN parent_id IS NULL THEN NULL ELSE 0 END) STORED,
    title        text NOT NULL CHECK (btrim(title) <> ''),
    target_date  date,
    done         boolean NOT NULL DEFAULT false,
    done_at      timestamptz,
    done_by      uuid REFERENCES public.employees (id),
    sort_order   integer NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid REFERENCES public.employees (id),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid REFERENCES public.employees (id),

    CHECK ((parent_id IS NULL) = (depth = 0)),
    CHECK ((done = false) = (done_at IS NULL)),

    -- 【这条 UNIQUE 不是第二条唯一性规则】,它是下面那条复合外键的靶子。
    UNIQUE (id, task_id, depth),

    -- 【一层嵌套 + 父子同属一张任务,两条都做成结构上不可能】
    -- parent_depth 恒等于 0(有父时),所以"孙子"引用不到任何东西:
    -- 它需要一个 depth=1 的父,而 FK 只认 depth=0。
    -- task_id 走同一条外键,所以跨任务认父也表达不出来。
    -- 为什么不是触发器:一条【跑起来才生效】的规则弱于一条【写不出来】的规则,
    -- 而"父子同属一张任务"恰恰是写触发器的人最容易漏掉的那一半。
    FOREIGN KEY (parent_id, task_id, parent_depth)
        REFERENCES public.task_nodes (id, task_id, depth)
);

CREATE INDEX idx_task_nodes_task ON public.task_nodes (task_id, parent_id, sort_order);

COMMENT ON TABLE public.task_nodes IS
'任务里的【有序步骤】。一层嵌套(步骤可以有子步骤,不能更深),由复合外键 + 生成列做成结构上不可能,不是靠触发器拒绝。
【本模块只拒绝两种东西:结构上不可能的,和会毁掉别人记录的。凡是一个人可能真心想表达的,一律接受,把矛盾显示出来。】
所以:任务已 done 而步骤还开着 —— 允许,卡片上显示 3/5;步骤的日期排到任务截止日之后 —— 允许,而且那正是最该被看见的事;子步骤的日期不受父步骤约束(父步骤本来就在最后一个子步骤之后才完成)。
一条挡住它们的规则不会让计划变得可行,只会让人填一个自己都不信的日期、或者去勾一个没做过的步骤 —— 那正好毁掉这张表存在的理由。';

COMMENT ON COLUMN public.task_nodes.sort_order IS
'稀疏序号,步长 1024,插入取中点,作用域是 (task_id, parent_id)。
【故意没有唯一约束】:并列是可能的、也是无害的,显示时按 created_at、再按 id 稳定断开。不要"顺手补上"这条约束 —— 它会把一次拖动变成整段重排,还得为此买 DEFERRABLE 或者偏移量的把戏。
【为什么不跟 quote_lines / invoice_lines 的 line_no 走】:发票行号印在客户拿到的单据上,必须密集、唯一、不跳号;一个步骤的位置不是关于世界的事实。
【一次拖动只写一行】,这是全部的用意:变更记录里那一条因此陈述的是【一个动作】,而不是一串被顺带挤动的副作用。';

COMMENT ON COLUMN public.task_nodes.parent_depth IS
'生成列,恒为 0(有父)或 NULL(无父)。它唯一的作用是当复合外键的一列,把"父节点必须是顶层"变成一件表达不出来的事。不要手工写它,也不要删 —— 删掉它,一层嵌套的保证就只剩下注释了。';

ALTER TABLE public.task_nodes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "task_nodes select" ON public.task_nodes
    FOR SELECT TO authenticated USING (can_view_task(task_id));
CREATE POLICY "task_nodes insert" ON public.task_nodes
    FOR INSERT TO authenticated WITH CHECK (can_edit_task(task_id));
CREATE POLICY "task_nodes update" ON public.task_nodes
    FOR UPDATE TO authenticated USING (can_edit_task(task_id)) WITH CHECK (can_edit_task(task_id));
CREATE POLICY "task_nodes delete" ON public.task_nodes
    FOR DELETE TO authenticated USING (can_edit_task(task_id));

CREATE TRIGGER trg_task_nodes_touch
    BEFORE INSERT OR UPDATE ON public.task_nodes
    FOR EACH ROW EXECUTE FUNCTION trg_task_nodes_touch();

CREATE TRIGGER trg_task_nodes_no_orphan
    BEFORE DELETE ON public.task_nodes
    FOR EACH ROW EXECUTE FUNCTION trg_task_nodes_no_orphan();

CREATE TRIGGER trg_task_nodes_history
    AFTER INSERT OR UPDATE OR DELETE ON public.task_nodes
    FOR EACH ROW EXECUTE FUNCTION trg_task_nodes_history();

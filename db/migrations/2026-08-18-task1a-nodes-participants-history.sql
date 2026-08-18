-- TASK-1a:步骤、参与者、变更记录 —— 全部【新增】,不动任何既有形状
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么这一刀只做加法】
-- 破窗期里生产跑的是【旧代码 + 新库】。旧的 app 今天直接往 tasks 写
-- (PostgREST,没有 RPC),它读写的列一列都没有搬家,所以这一刀的窗口里
-- 旧代码【不可能坏】。退役那六列、把 owner_id 搬进员工空间,留给 TASK-1c ——
-- 那时 1b 已经让部署中的代码不再碰它们,窗口是空的而不是危险的。
--
-- 【一处必须在 1c 复查的东西:owner_id 现在还是账号空间】
-- 本刀的 can_view_task / can_edit_task 里,私人任务那一支写的是
--     t.owner_id = auth.uid()
-- 因为这一刀【没有】搬 owner_id。TASK-1c 搬它的时候,**必须在同一支迁移里**
-- 把这两个函数改成员工空间。只搬列不改函数 —— 或只改函数不搬列 ——
-- 私人任务会当场变成"谁都看不见"或"谁都看得见",而且不报错。
-- 这正是本次设计里拒绝 was_ever_team 的那条理由:一个事实两处陈述,必然漂移。
--
-- 【类型迁移的触发器【不在这一刀】,它去了 1b —— 原因值得写下来】
-- 本刀第一版带着 trg_tasks_type_transition。它会让【部署中的旧界面】上那个
-- 「私人 ↔ 团队」下拉当场变味:旧的 TaskModal 每次保存都把 task_type 一起发过来,
-- 值没变时触发器早退(无妨),但一旦有人在旧界面上把私人改成团队,
-- 它就会撞上新规则 —— 而线上 6 行里有 4 行 owner_id 是空的,于是那一步会
-- 抛 TASK_OWNER_NOT_AN_EMPLOYEE,旧页面把它原样印成一串机器码。
-- **那正是 IOD-2 的签名:旧代码 + 新库。** 而这次分刀的全部价值就是那句
-- 「旧代码不可能坏」;一个让那句话变成假的 1a 不值得要。
-- 所以触发器、promote_task_to_team / correct_task_type、以及 tasks.task_type
-- 上那条讲【出身不变式】的列注释,一起挪到 1b(fixture 5 与 6 同行)。
-- **注释一并挪走,不是遗漏**:一条描述"由触发器保证"的注释,在触发器还不存在时
-- 是一句假话,与"描述一个已经不存在的隐患"是同一种缺陷。
-- task_history 的 CHECK 里保留 'promoted_from_personal' 这个取值 ——
-- 它只是一个允许值,留着可以让 1b 只加触发器,不必再 ALTER 一次约束。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 0. 谁是当前这个人 —— 账号 → 员工,一处解析
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.current_employee_id()
RETURNS uuid
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT e.id FROM public.employees e
     WHERE e.user_id = auth.uid() AND e.deleted_at IS NULL
     LIMIT 1;
$$;

COMMENT ON FUNCTION public.current_employee_id() IS
'当前登录账号对应的员工 id;没有对应员工时返回 NULL。SECURITY DEFINER —— 它要读 employees,而调用者未必持 module.hr.view。任务模块的一切都说【员工空间】,auth.uid() 只在这里出现一次。';

-- ───────────────────────────────────────────────────────────────────────────
-- 1. task_participants —— 参与者是【行】,不是数组
-- ───────────────────────────────────────────────────────────────────────────
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

-- ───────────────────────────────────────────────────────────────────────────
-- 2. task_nodes —— 一层嵌套,做成【表达不出来】而不是【拒绝掉】
-- ───────────────────────────────────────────────────────────────────────────
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

-- ───────────────────────────────────────────────────────────────────────────
-- 3. task_history —— 采购单历史那一套,整套拿过来
-- ───────────────────────────────────────────────────────────────────────────
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

-- ───────────────────────────────────────────────────────────────────────────
-- 4. 两个谓词 —— 一处陈述,四张表引用
-- ───────────────────────────────────────────────────────────────────────────
-- 【为什么是 SECURITY DEFINER,而不是让策略自己写 EXISTS】
-- tasks 的策略要问 task_participants,task_participants 的策略要问 tasks ——
-- 两条策略互相引用就是 42P17 infinite recursion,而它【迁移时不报错、第一次
-- 读的时候才炸】。属主权限让函数体内的读不受这两条策略管辖,环就断了。
-- 【为什么是两个函数,不是一个带 mode 参数的】:一个用布尔量切换的安全谓词,
-- 没有人能一眼读懂它此刻在判什么。

CREATE OR REPLACE FUNCTION public.can_view_task(p_task_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT has_permission('module.tasks.view')
       AND EXISTS (
           SELECT 1 FROM public.tasks t
            WHERE t.id = p_task_id
              AND (
                    -- 团队(以及【曾经是】团队):大家看得见。
                    t.task_type = 'team'
                    -- 私人:只有本人,外加一把点名的钥匙(默认没有任何角色持有)
                 OR t.owner_id = auth.uid()          -- ← 1c 搬 owner_id 时改这里
                 OR has_permission('module.tasks.view_all')
              )
       );
$$;

COMMENT ON FUNCTION public.can_view_task(uuid) IS
'谁读得到这张任务。私人 = 本人(或持 module.tasks.view_all 的人);团队 = 任何持 module.tasks.view 的人。
【私人 = 只有我看得见;团队 = 大家看得见、参与者能改】—— 一个操作员一句话就能记住的模型,胜过一个更细、但要教的模型。
【前参与者照样读得到】,因为团队任务本来就是公开读的;这一条写在这里是为了说明意图 —— 有人换了角色、丢了 module.tasks,他就什么都读不到了,那是权限在起作用,不是这条规则变了。
【owner_id 此刻是账号空间】(TASK-1a)。TASK-1c 把它搬进员工空间时,必须在同一支迁移里改这一行。';

CREATE OR REPLACE FUNCTION public.can_edit_task(p_task_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
    SELECT has_permission('module.tasks.edit')
       AND EXISTS (
           SELECT 1 FROM public.tasks t
            WHERE t.id = p_task_id
              AND t.deleted_at IS NULL
              AND CASE
                    WHEN t.task_type = 'team' THEN EXISTS (
                        SELECT 1 FROM public.task_participants p
                         WHERE p.task_id = t.id
                           AND p.employee_id = current_employee_id()
                           AND p.removed_at IS NULL)
                    ELSE t.owner_id = auth.uid()      -- ← 1c 搬 owner_id 时改这里
                  END
       );
$$;

COMMENT ON FUNCTION public.can_edit_task(uuid) IS
'谁改得了这张任务。私人 = 只有本人(view_all 是一把【读】的钥匙,不是写的);团队 = 【当前】参与者。前参与者读得到、改不了 —— 他们的编辑留在记录里,但他们已经不在这件事上了。
【owner_id 此刻是账号空间】(TASK-1a),1c 搬列时必须同刀改这一行。';

-- ───────────────────────────────────────────────────────────────────────────
-- 6. 删除:硬删按名拒绝(策略【保留】,好让人真的看得见那句拒绝)
-- ───────────────────────────────────────────────────────────────────────────
-- AUDEL-1a 的两层:策略 + 守卫。那一刀把盘点两张表的 DELETE 策略拿掉了,
-- 代价写在它自己的抬头里:**普通用户看到的是 0 行,不是具名拒绝**。
-- 任务是一块人天天点的屏幕,静默的 0 行会被读成"删掉了",所以这里
-- 【保留 DELETE 策略】(与 inbound_batches / purchase_orders 同一处理),
-- 让触发器有机会说话。

CREATE OR REPLACE FUNCTION public.trg_tasks_no_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'TASK_HARD_DELETE_REFUSED|%', OLD.code
      USING HINT = '任务不硬删:置 deleted_at(软删)。硬删会孤立 task_history 里的记录';
END;
$$;

CREATE TRIGGER trg_tasks_no_hard_delete
    BEFORE DELETE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION trg_tasks_no_hard_delete();

-- 步骤【是】硬删的,而且这不是 AUDEL-1a 的例外,是同一条推理走到了另一个答案:
-- AUDEL-1a 堵的洞是"证据跟着没了";这里 node_id 特意不加外键,
-- node_removed 那条记录连同标题、日期、完成状态都活得比步骤久。
-- 但【有子步骤的父步骤按名拒绝,绝不 CASCADE】—— 那正是 AUDEL-1a 的洞②
-- (CASCADE 顺手带走化验结果)原样重演。
CREATE OR REPLACE FUNCTION public.trg_task_nodes_no_orphan()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE v_children integer;
BEGIN
    SELECT count(*) INTO v_children FROM public.task_nodes WHERE parent_id = OLD.id;
    IF v_children > 0 THEN
        RAISE EXCEPTION 'TASK_NODE_HAS_CHILDREN|%|%', OLD.title, v_children
          USING HINT = '这个步骤下面还有子步骤;先删子步骤,不会连带删除';
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_task_nodes_no_orphan
    BEFORE DELETE ON public.task_nodes
    FOR EACH ROW EXECUTE FUNCTION trg_task_nodes_no_orphan();

-- ───────────────────────────────────────────────────────────────────────────
-- 7. 成员变动的守卫 + 留痕
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_task_participants_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_me        uuid := current_employee_id();
    v_user_id   uuid;
    v_owner_emp uuid;
    v_first     boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- 参与者必须【有登录账号】,否则他在屏幕上在这件事上,却打不开它。
        SELECT e.user_id INTO v_user_id FROM public.employees e WHERE e.id = NEW.employee_id;
        IF v_user_id IS NULL THEN
            RAISE EXCEPTION 'TASK_PARTICIPANT_NO_LOGIN|%', NEW.employee_id
              USING HINT = '这名员工还没有登录账号;先在 HR 里关联账号,再把他加进来';
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE:只管"从在场变成离场"这一次
    IF OLD.removed_at IS NULL AND NEW.removed_at IS NOT NULL THEN
        SELECT e.id INTO v_owner_emp FROM public.employees e
          JOIN public.tasks t ON t.owner_id = e.user_id       -- ← 1c 改这里
         WHERE t.id = NEW.task_id LIMIT 1;

        IF NEW.employee_id = v_owner_emp THEN
            RAISE EXCEPTION 'TASK_OWNER_CANNOT_LEAVE|%', NEW.task_id
              USING HINT = '归属人不能退出自己的任务 —— 那是一次【转移归属】';
        END IF;

        -- 谁能把别人移出:归属人,或者【当初把他加进来的那个人】,
        -- 而且移出者本人此刻仍在场。没有时限 —— 一个没人量过的整数不配当判据,
        -- 而"是谁加的"是一个已经记下来的事实。
        IF NEW.employee_id IS DISTINCT FROM v_me THEN
            IF v_me IS DISTINCT FROM v_owner_emp AND v_me IS DISTINCT FROM OLD.added_by THEN
                RAISE EXCEPTION 'TASK_PARTICIPANT_REMOVE_DENIED|%', NEW.task_id
                  USING HINT = '只有归属人、或者当初加他进来的那个人,才能把他移出';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM public.task_participants p
                            WHERE p.task_id = NEW.task_id AND p.employee_id = v_me
                              AND p.removed_at IS NULL) THEN
                RAISE EXCEPTION 'TASK_PARTICIPANT_REMOVER_NOT_ON_TASK|%', NEW.task_id
                  USING HINT = '已经退出这张任务的人,不能再把别人移出';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_task_participants_guard
    BEFORE INSERT OR UPDATE ON public.task_participants
    FOR EACH ROW EXECUTE FUNCTION trg_task_participants_guard();

CREATE OR REPLACE FUNCTION public.trg_task_participants_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE v_others integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- 【归属人的头一行不写历史】:变更记录记的是【改动】,不是初始状态。
        -- 判据是事实,不是标志位:这是本任务的第一条参与者行,且加的就是自己。
        SELECT count(*) INTO v_others FROM public.task_participants
         WHERE task_id = NEW.task_id AND id <> NEW.id;
        IF v_others = 0 AND NEW.added_by = NEW.employee_id THEN
            RETURN NEW;
        END IF;
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.task_id, 'participant_added', NEW.employee_id, NEW.added_by);
        RETURN NEW;
    END IF;

    IF OLD.removed_at IS NULL AND NEW.removed_at IS NOT NULL THEN
        -- 【自己走】与【被移出】是两个 change_type,因为"她是自己退出的
        -- 还是被拿掉的"正是这份记录该回答的问题,一个码答不了。
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.task_id,
                CASE WHEN NEW.removed_by = NEW.employee_id
                     THEN 'participant_left' ELSE 'participant_removed' END,
                NEW.employee_id, NEW.removed_by);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_task_participants_history
    AFTER INSERT OR UPDATE ON public.task_participants
    FOR EACH ROW EXECUTE FUNCTION trg_task_participants_history();

-- ───────────────────────────────────────────────────────────────────────────
-- 8. 表头与步骤的留痕(【只给团队任务】)
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_tasks_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.task_type <> 'team' THEN RETURN NEW; END IF;   -- 私人任务不记
    IF (OLD.title, OLD.description, OLD.status, OLD.priority,
        OLD.due_date, OLD.reminder_at, OLD.tags)
       IS NOT DISTINCT FROM
       (NEW.title, NEW.description, NEW.status, NEW.priority,
        NEW.due_date, NEW.reminder_at, NEW.tags) THEN
        RETURN NEW;
    END IF;

    INSERT INTO public.task_history (
        task_id, change_type, changed_by,
        old_title, new_title, old_description, new_description,
        old_status, new_status, old_priority, new_priority,
        old_due_date, new_due_date, old_reminder_at, new_reminder_at,
        old_tags, new_tags)
    VALUES (
        NEW.id, 'header_update', current_employee_id(),
        NULLIF(OLD.title, NEW.title),             NULLIF(NEW.title, OLD.title),
        NULLIF(OLD.description, NEW.description), NULLIF(NEW.description, OLD.description),
        NULLIF(OLD.status, NEW.status),           NULLIF(NEW.status, OLD.status),
        NULLIF(OLD.priority, NEW.priority),       NULLIF(NEW.priority, OLD.priority),
        NULLIF(OLD.due_date, NEW.due_date),       NULLIF(NEW.due_date, OLD.due_date),
        NULLIF(OLD.reminder_at, NEW.reminder_at), NULLIF(NEW.reminder_at, OLD.reminder_at),
        CASE WHEN OLD.tags IS DISTINCT FROM NEW.tags THEN OLD.tags END,
        CASE WHEN OLD.tags IS DISTINCT FROM NEW.tags THEN NEW.tags END);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tasks_history
    AFTER UPDATE ON public.tasks
    FOR EACH ROW EXECUTE FUNCTION trg_tasks_history();

CREATE OR REPLACE FUNCTION public.trg_task_nodes_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_type text := NULL;
    v_task uuid := COALESCE(NEW.task_id, OLD.task_id);
    v_is_team boolean;
BEGIN
    SELECT t.task_type = 'team' INTO v_is_team FROM public.tasks t WHERE t.id = v_task;
    IF NOT COALESCE(v_is_team, false) THEN RETURN COALESCE(NEW, OLD); END IF;

    IF TG_OP = 'INSERT' THEN
        INSERT INTO public.task_history (task_id, change_type, node_id, changed_by,
                                         new_node_title, new_node_target_date, new_sort_order)
        VALUES (NEW.task_id, 'node_added', NEW.id, current_employee_id(),
                NEW.title, NEW.target_date, NEW.sort_order);
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.task_history (task_id, change_type, node_id, changed_by,
                                         old_node_title, old_node_target_date, old_node_done)
        VALUES (OLD.task_id, 'node_removed', OLD.id, current_employee_id(),
                OLD.title, OLD.target_date, OLD.done);
        RETURN OLD;
    END IF;

    -- UPDATE：一次改动写一条,按最有意义的那一项定 change_type
    IF OLD.done IS DISTINCT FROM NEW.done THEN
        v_type := CASE WHEN NEW.done THEN 'node_done' ELSE 'node_undone' END;
    ELSIF OLD.title IS DISTINCT FROM NEW.title THEN
        v_type := 'node_renamed';
    ELSIF OLD.target_date IS DISTINCT FROM NEW.target_date THEN
        v_type := 'node_redated';
    ELSIF OLD.sort_order IS DISTINCT FROM NEW.sort_order THEN
        -- 【重排只在带日期的步骤上记】:有日期,顺序表达的是一个计划,
        -- 「谁把安全检查挪到最后」是个真问题;没有日期,顺序只是显示偏好,
        -- 记下来会把这份记录淹掉。判据是一个可核对的事实,不是一次判断。
        -- 【整段重排(rebalance)一条都不写】:把兄弟节点按 1024 重新编号
        -- 不是对计划的改动,记下来会淹掉它本该保护的东西。
        IF COALESCE(NEW.target_date, OLD.target_date) IS NOT NULL
           AND current_setting('app.task_rebalance', true) IS DISTINCT FROM 'on' THEN
            v_type := 'node_reordered';
        END IF;
    END IF;

    IF v_type IS NULL THEN RETURN NEW; END IF;

    INSERT INTO public.task_history (task_id, change_type, node_id, changed_by,
        old_node_title, new_node_title,
        old_node_target_date, new_node_target_date,
        old_node_done, new_node_done,
        old_sort_order, new_sort_order)
    VALUES (NEW.task_id, v_type, NEW.id, current_employee_id(),
        NULLIF(OLD.title, NEW.title), NULLIF(NEW.title, OLD.title),
        CASE WHEN OLD.target_date IS DISTINCT FROM NEW.target_date THEN OLD.target_date END,
        CASE WHEN OLD.target_date IS DISTINCT FROM NEW.target_date THEN NEW.target_date END,
        CASE WHEN OLD.done IS DISTINCT FROM NEW.done THEN OLD.done END,
        CASE WHEN OLD.done IS DISTINCT FROM NEW.done THEN NEW.done END,
        CASE WHEN OLD.sort_order IS DISTINCT FROM NEW.sort_order THEN OLD.sort_order END,
        CASE WHEN OLD.sort_order IS DISTINCT FROM NEW.sort_order THEN NEW.sort_order END);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_task_nodes_history
    AFTER INSERT OR UPDATE OR DELETE ON public.task_nodes
    FOR EACH ROW EXECUTE FUNCTION trg_task_nodes_history();

-- done_at / updated_at 跟着 done 走,免得两处陈述同一个事实
CREATE OR REPLACE FUNCTION public.trg_task_nodes_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at := now();
        NEW.updated_by := current_employee_id();
        IF OLD.done IS DISTINCT FROM NEW.done THEN
            NEW.done_at := CASE WHEN NEW.done THEN now() END;
            NEW.done_by := CASE WHEN NEW.done THEN current_employee_id() END;
        END IF;
    ELSE
        NEW.created_by := COALESCE(NEW.created_by, current_employee_id());
        NEW.updated_by := COALESCE(NEW.updated_by, current_employee_id());
        IF NEW.done THEN
            NEW.done_at := COALESCE(NEW.done_at, now());
            NEW.done_by := COALESCE(NEW.done_by, current_employee_id());
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_task_nodes_touch
    BEFORE INSERT OR UPDATE ON public.task_nodes
    FOR EACH ROW EXECUTE FUNCTION trg_task_nodes_touch();

-- 稀疏序号用完了才重排;它【一条历史都不写】,理由见上面的注释。
CREATE OR REPLACE FUNCTION public.rebalance_task_nodes(p_task_id uuid, p_parent_id uuid)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE v_n integer;
BEGIN
    PERFORM set_config('app.task_rebalance', 'on', true);
    WITH ordered AS (
        SELECT id, row_number() OVER (ORDER BY sort_order, created_at, id) AS rn
          FROM public.task_nodes
         WHERE task_id = p_task_id AND parent_id IS NOT DISTINCT FROM p_parent_id)
    UPDATE public.task_nodes n SET sort_order = o.rn * 1024
      FROM ordered o WHERE n.id = o.id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM set_config('app.task_rebalance', 'off', true);
    RETURN v_n;
END;
$$;

COMMENT ON FUNCTION public.rebalance_task_nodes(uuid, uuid) IS
'把一组同级步骤按 1024 重新编号(中点插入把间隙用光时才需要)。
【它一条历史都不写,这是有意的】:重编号不是对计划的改动。下一个读到"重排却没有记录"的人不要去"补上"那些行 —— 补上就等于把这份记录淹回噪声里,而它正是为了避免噪声才这么写的。';

-- ───────────────────────────────────────────────────────────────────────────
-- 9. 三张新表的策略
-- ───────────────────────────────────────────────────────────────────────────
ALTER TABLE public.task_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_nodes        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_history      ENABLE ROW LEVEL SECURITY;

CREATE POLICY "task_participants select" ON public.task_participants
    FOR SELECT TO authenticated USING (can_view_task(task_id));
CREATE POLICY "task_participants insert" ON public.task_participants
    FOR INSERT TO authenticated WITH CHECK (can_edit_task(task_id));
CREATE POLICY "task_participants update" ON public.task_participants
    FOR UPDATE TO authenticated USING (can_edit_task(task_id)) WITH CHECK (can_edit_task(task_id));
-- 【没有 DELETE 策略】:退出是软的,那一行是证据。

CREATE POLICY "task_nodes select" ON public.task_nodes
    FOR SELECT TO authenticated USING (can_view_task(task_id));
CREATE POLICY "task_nodes insert" ON public.task_nodes
    FOR INSERT TO authenticated WITH CHECK (can_edit_task(task_id));
CREATE POLICY "task_nodes update" ON public.task_nodes
    FOR UPDATE TO authenticated USING (can_edit_task(task_id)) WITH CHECK (can_edit_task(task_id));
CREATE POLICY "task_nodes delete" ON public.task_nodes
    FOR DELETE TO authenticated USING (can_edit_task(task_id));

CREATE POLICY "task_history select" ON public.task_history
    FOR SELECT TO authenticated USING (can_view_task(task_id));
-- 【只有 SELECT】:变更记录由触发器写,不由任何调用者写。

-- ───────────────────────────────────────────────────────────────────────────
-- 10. 新权限码:一把点名的钥匙,默认【没有任何角色持有】
-- ───────────────────────────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order)
VALUES ('module.tasks.view_all', 'module', 'Tasks (read others'' personal)', '任务(查看他人私人任务)',
        'Reads OTHER PEOPLE''S PERSONAL tasks. Not general admin access.',
        '读【别人的私人任务】。这不是"任务模块的管理权限",就是这一件事。', 132)
ON CONFLICT (code) DO NOTHING;

-- ───────────────────────────────────────────────────────────────────────────
-- 11. 看板要的派生值 —— 一处 SQL,两个调用者
-- ───────────────────────────────────────────────────────────────────────────
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

COMMIT;

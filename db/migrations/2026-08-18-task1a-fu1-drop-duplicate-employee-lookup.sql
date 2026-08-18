-- TASK-1a-fu1:把 current_employee_id() 去掉 —— 它是 current_user_employee() 的重复
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这正是本次设计里反复拒绝的那件事,而我自己犯了它】
-- TASK-1a 新建了 current_employee_id():SQL、STABLE SECURITY DEFINER、
-- search_path 一样,函数体一个字都不差 —— 而 current_user_employee() 早就在,
-- 已经有十个函数在调它,而且已经在 gate 的 B2 白名单里。
-- **一个事实两处陈述,必然漂移**:哪天"当前员工"的判据要变(比如离职者
-- 不再算数),改了一处、漏了另一处,任务模块与 HR 模块会对同一个人给出
-- 不同的答案,而且不报错。
--
-- 【是 gate 抓到的,不是人看出来的,值得写下来】
--     B2 VIOLATION [live] current_employee_id: SECURITY DEFINER, no caller check,
--                          and executable
-- B2 拦的是"属主权限 + 没有调用者检查 + 调得到"。而白名单里那一行
-- current_user_employee 恰好把原件的名字摆在了旁边 —— 于是这条判词回答的
-- 虽然是"权限",顺手答出来的却是"你写了个重复的"。
--
-- 【为什么不是把 current_employee_id 加进白名单了事】
-- 那样两个函数都会留下来,而白名单会为这次重复背书。B2 说的三条出路
-- (加检查 / 收权 / 白名单)都假设这个函数【应该存在】,而它不该存在。
--
-- ── 给下一个读到 current_user_employee() 的人 ──────────────────────────────
-- **这个仓库里"当前登录的人是哪名员工"只有一处实现,而那不是巧合,是被纠正
-- 过一次的结果。**
--
-- TASK-1 的设计过程里,有整整一轮在论证为什么【不】给 tasks 加一列
-- was_ever_team:出身已经由 task_type 蕴含了,再存一遍就是一个事实两处陈述,
-- 而两处陈述必然漂移 —— 有人改了其中一处,另一处不报错地留在旧答案上。
-- 那一轮论证被接受之后【不到一小时】,同一支迁移就用 SQL 又犯了一遍同样的错:
-- 新写了一个 current_employee_id(),与早已存在、已有十个调用者的
-- current_user_employee() 一字不差。
--
-- 记在这里不是为了自责,是因为这条教训的用处全在【下一次】:
-- **论证过的原则不会自动作用到你正在写的那一行上。** 加一个"取当前员工"
-- 的小工具函数感觉不像"存了两遍同一个事实",但它就是 —— 哪天判据要变
-- (比如离职者不再算数),改一处漏一处,任务模块与 HR 模块会对同一个人
-- 给出不同的答案,而且什么都不会报错。
--
-- 抓到它的是 db/gate.py 的 B2,不是人。这也是这条规矩的另一半:
-- **靠记性执行的原则,要有一道机器来兜底。**
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

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
                           AND p.employee_id = current_user_employee()
                           AND p.removed_at IS NULL)
                    ELSE t.owner_id = auth.uid()      -- ← 1c 搬 owner_id 时改这里
                  END
       );
$$;

CREATE OR REPLACE FUNCTION public.trg_task_participants_guard()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_me        uuid := current_user_employee();
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
        NEW.id, 'header_update', current_user_employee(),
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
        VALUES (NEW.task_id, 'node_added', NEW.id, current_user_employee(),
                NEW.title, NEW.target_date, NEW.sort_order);
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        INSERT INTO public.task_history (task_id, change_type, node_id, changed_by,
                                         old_node_title, old_node_target_date, old_node_done)
        VALUES (OLD.task_id, 'node_removed', OLD.id, current_user_employee(),
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
    VALUES (NEW.task_id, v_type, NEW.id, current_user_employee(),
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

CREATE OR REPLACE FUNCTION public.trg_task_nodes_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at := now();
        NEW.updated_by := current_user_employee();
        IF OLD.done IS DISTINCT FROM NEW.done THEN
            NEW.done_at := CASE WHEN NEW.done THEN now() END;
            NEW.done_by := CASE WHEN NEW.done THEN current_user_employee() END;
        END IF;
    ELSE
        NEW.created_by := COALESCE(NEW.created_by, current_user_employee());
        NEW.updated_by := COALESCE(NEW.updated_by, current_user_employee());
        IF NEW.done THEN
            NEW.done_at := COALESCE(NEW.done_at, now());
            NEW.done_by := COALESCE(NEW.done_by, current_user_employee());
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- 现在没有任何东西引用它了(上面五个是活库里仅有的引用者,psql 查过)。
DROP FUNCTION public.current_employee_id();

COMMIT;

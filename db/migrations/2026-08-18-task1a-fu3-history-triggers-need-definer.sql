-- TASK-1a-fu3:留痕与守卫的触发器函数改成 SECURITY DEFINER —— 否则团队任务【改不动】
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【是 fixture 抓到的,而且是它第二次抓到东西 —— 这就是写它的理由】
-- fixture 92 让一个【参与者】以 authenticated 身份改一个步骤,当场:
--     ERROR: new row violates row-level security policy for table "task_history"
-- 触发器函数默认以【调用者】身份执行,而 task_history 【只有 SELECT 策略】——
-- 那是有意的(变更记录由触发器写,不由任何调用者写)。两件事各自都对,
-- 合起来的结果是:**任何普通用户对团队任务的任何一次编辑都会失败。**
--
-- 今天线上没有人撞得上它:界面还不写 task_nodes(那是 TASK-1b)。
-- 但 1b 上线第一天就会撞上,而那时它看起来会像"1b 写错了"。
--
-- 【为什么不是给 task_history 加一条 INSERT 策略】
-- 那等于让任何参与者【伪造】一行留痕,而留痕正是"不可伪造"才有意义的东西。
-- 这条推理仓库里已经写过一遍:APR-1 把 record_approval_decision 从
-- authenticated 手里收回,理由一字不差。
--
-- 【一并改的还有两个守卫,理由不同但同样是"它不该受读者权限影响"】
-- * trg_task_participants_guard 要读 employees.user_id 判断这个人有没有登录账号。
--   不是 definer 的话,一个没有 module.hr.view 的仓库用户读不到那一行,
--   会得到一次【假的】TASK_PARTICIPANT_NO_LOGIN —— 拒绝的理由是编的。
-- * trg_task_nodes_no_orphan 要数子步骤。它必须数【全部】子步骤,
--   而不是"这个读者看得见的那些" —— 一个数不全的守卫会放过真正的孤儿。
--
-- 本仓库已有 40 个 SECURITY DEFINER 触发器函数,这是既定写法,不是新花样。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.trg_task_participants_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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

CREATE OR REPLACE FUNCTION public.trg_task_participants_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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

CREATE OR REPLACE FUNCTION public.trg_tasks_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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

CREATE OR REPLACE FUNCTION public.trg_task_nodes_no_orphan()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
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

COMMIT;

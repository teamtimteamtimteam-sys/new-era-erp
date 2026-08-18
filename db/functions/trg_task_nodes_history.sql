CREATE OR REPLACE FUNCTION public.trg_task_nodes_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$


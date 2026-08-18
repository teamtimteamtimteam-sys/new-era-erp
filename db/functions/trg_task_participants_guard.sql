CREATE OR REPLACE FUNCTION public.trg_task_participants_guard()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$


CREATE OR REPLACE FUNCTION public.trg_task_participants_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_me        uuid := current_user_employee();
    v_user_id   uuid;
    v_owner_emp uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT e.user_id INTO v_user_id FROM public.employees e WHERE e.id = NEW.employee_id;
        IF v_user_id IS NULL THEN
            RAISE EXCEPTION 'TASK_PARTICIPANT_NO_LOGIN|%', NEW.employee_id
              USING HINT = '这名员工还没有登录账号;先在 HR 里关联账号,再把他加进来';
        END IF;
        RETURN NEW;
    END IF;

    IF OLD.removed_at IS NULL AND NEW.removed_at IS NOT NULL THEN
        -- 【已搬】owner_id 就是员工 id,直接读,不再绕 employees.user_id。
        SELECT t.owner_id INTO v_owner_emp FROM public.tasks t WHERE t.id = NEW.task_id;

        IF NEW.employee_id = v_owner_emp THEN
            RAISE EXCEPTION 'TASK_OWNER_CANNOT_LEAVE|%', NEW.task_id
              USING HINT = '归属人不能退出自己的任务 —— 那是一次【转移归属】';
        END IF;

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


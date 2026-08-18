CREATE OR REPLACE FUNCTION public.trg_tasks_type_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_owner_emp uuid;
    v_others    integer;
BEGIN
    IF NEW.task_type IS NOT DISTINCT FROM OLD.task_type THEN
        RETURN NEW;
    END IF;

    -- ── 升级:私人 → 团队。总是允许。
    IF OLD.task_type = 'personal' AND NEW.task_type = 'team' THEN
        SELECT e.id INTO v_owner_emp FROM public.employees e
         WHERE e.user_id = NEW.owner_id AND e.deleted_at IS NULL LIMIT 1;   -- ← 1c 改这里

        IF v_owner_emp IS NULL THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_AN_EMPLOYEE|%', NEW.code
              USING HINT = '这张任务的归属人没有对应的在册员工(或者没有登录账号);升级之后将没有任何人改得动它';
        END IF;

        -- 【同一个事务里】把归属人写成参与者。少了这一步,刚升级的任务参与者为零,
        -- 按 can_edit_task 那就是一张【谁都改不了】的行 —— 空集那个老毛病。
        INSERT INTO public.task_participants (task_id, employee_id, added_by)
        VALUES (NEW.id, v_owner_emp, v_owner_emp);

        -- 历史从升级这一刻开一条,让【之前的沉默】读得懂:
        -- 不是"没记",是"那时还不需要记"。
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.id, 'promoted_from_personal', v_owner_emp, current_user_employee());

        RETURN NEW;
    END IF;

    -- ── 降级:团队 → 私人。只在【可证明无损】的窗口内允许。
    IF OLD.task_type = 'team' AND NEW.task_type = 'personal' THEN
        SELECT count(*) INTO v_others
          FROM public.task_participants p
          JOIN public.employees e ON e.id = p.employee_id
         WHERE p.task_id = NEW.id
           AND e.user_id IS DISTINCT FROM NEW.owner_id;                     -- ← 1c 改这里

        IF v_others > 0 THEN
            -- 【说的是不一致,不是政策】:不说"不许改类型",说的是
            -- "还有 N 个人在这件事上,他们的记录会被孤立"。
            RAISE EXCEPTION 'TASK_TYPE_LOCKED_PARTICIPANTS|%|%', NEW.code, v_others
              USING HINT = '这张任务上有别人参与过;改成私人会让他们读不到自己参与过的东西';
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'TASK_TYPE_TRANSITION_UNKNOWN|%|%', OLD.task_type, NEW.task_type;
END;
$function$


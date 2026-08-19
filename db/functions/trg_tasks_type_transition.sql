CREATE OR REPLACE FUNCTION public.trg_tasks_type_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_owner_emp uuid;
    v_others    integer;
    v_what      text;
BEGIN
    IF NEW.task_type IS NOT DISTINCT FROM OLD.task_type THEN
        RETURN NEW;
    END IF;

    -- ── 升级:私人 → 团队。总是允许。
    IF OLD.task_type = 'personal' AND NEW.task_type = 'team' THEN
        -- 【Site A,已搬】owner_id 现在【就是】员工 id,不再需要经 user_id 绕一圈。
        SELECT e.id INTO v_owner_emp FROM public.employees e
         WHERE e.id = NEW.owner_id AND e.deleted_at IS NULL LIMIT 1;

        IF v_owner_emp IS NULL THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_AN_EMPLOYEE|%', NEW.code
              USING HINT = '这张任务的归属人没有对应的在册员工;升级之后将没有任何人改得动它';
        END IF;

        -- 【(d2) 可重入】。原来这里是一条无条件 INSERT —— 只在【第一次】升级时对。
        -- 降级不动参与者行(见抬头 (d3) 那一段),所以再升级时那一行仍然活跃,
        -- 无条件 INSERT 会撞 uq_task_participants_active,把一串重复键印上屏幕。
        -- 三种情形由 ensure_task_owner_participant 一处判定,创建门调的是同一个。
        v_what := public.ensure_task_owner_participant(NEW.id, v_owner_emp, current_user_employee());

        -- 出身那一行历史只在【真的发生了一次升级】时写。复活的那一行由
        -- ensure_task_owner_participant 自己写 participant_added,两者不重复。
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.id, 'promoted_from_personal', v_owner_emp, current_user_employee());

        RETURN NEW;
    END IF;

    -- ── 降级:团队 → 私人。只在【可证明无损】的窗口内允许。
    IF OLD.task_type = 'team' AND NEW.task_type = 'personal' THEN
        -- 【Site B,已搬】owner_id 是员工 id,于是这里不再需要 JOIN employees ——
        -- 参与者行上的 employee_id 可以直接比。**这不是一次"顺手整理"**:
        -- 抬头里点名的 Site A/Site B 的 deleted_at 不对称,是被这次空间变更
        -- 【消解】掉的(Site B 从此根本不碰 employees),不是被我改掉的。
        -- 【removed_at 仍然【故意】不过滤】——(计划明写:不要动它)。
        -- 后果照实说:一个真实的第二个人加入后又退出,会让这张任务【永远】降不回私人。
        SELECT count(*) INTO v_others
          FROM public.task_participants p
         WHERE p.task_id = NEW.id
           AND p.employee_id IS DISTINCT FROM NEW.owner_id;

        IF v_others > 0 THEN
            RAISE EXCEPTION 'TASK_TYPE_LOCKED_PARTICIPANTS|%|%', NEW.code, v_others
              USING HINT = '这张任务上有别人参与过;改成私人会让他们读不到自己参与过的东西';
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'TASK_TYPE_TRANSITION_UNKNOWN|%|%', OLD.task_type, NEW.task_type;
END;
$function$


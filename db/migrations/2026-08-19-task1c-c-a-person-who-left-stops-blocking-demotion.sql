-- TASK-1c-c:已经退出的人,不该再挡着降级
--
-- 【实况】Tim 把 Chooer 加进一张团队任务,又把他移出,然后降级这条路就没了。
-- 库这一侧的原因是降级分支数参与者时【不过滤 removed_at】:一行软移除的记录
-- 仍然被数成"还有别人在这件事上"。于是**任何曾经有过第二个人的团队任务,
-- 永远回不到私人** —— 而退出是软的(行留着),所以这个状态是不可逆的。
--
-- 【这一条是 1c-a 明写着"不要动"的那一处,现在动它,理由要说清楚】
-- 1c-a 的抬头写着:removed_at 故意不过滤,后果是"一个真实的第二个人加入后又退出,
-- 会让这张任务永远降不回私人"。那句话【描述得完全正确】,当时也确实不该顺手改 ——
-- 它是一次行为变更,要有自己的断言。现在它不是一个理论后果了,是 Tim 撞上的一件事,
-- 所以本刀带着 fixture 来改它。
--
-- 【判据仍然取自 task_participants,不取自 task_history】——这一点没有变。
-- 变的只是"在场"的定义:从【这一行存在过】改成【这一行此刻还活跃】。
-- 退出依然是软的:行留着,历史留着,前参与者依然读得到自己参与过的东西;
-- 它只是不再挡着降级。
--
-- 【为什么这仍然是"可证明无损"的】原来那句不变式要保的是:降级不会把
-- 【正在这件事上的人】的记录孤立掉。一个已经退出的人不在这件事上了 ——
-- 他的历史行不受降级影响(task_history 不按类型过滤),而他本来就不再有编辑权。
BEGIN;

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
        -- 【Site A】owner_id 就是员工 id(1c-a 之后)。
        SELECT e.id INTO v_owner_emp FROM public.employees e
         WHERE e.id = NEW.owner_id AND e.deleted_at IS NULL LIMIT 1;

        IF v_owner_emp IS NULL THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_AN_EMPLOYEE|%', NEW.code
              USING HINT = '这张任务的归属人没有对应的在册员工;升级之后将没有任何人改得动它';
        END IF;

        -- 【可重入】三种情形由 ensure_task_owner_participant 一处判定;创建门调同一个。
        v_what := public.ensure_task_owner_participant(NEW.id, v_owner_emp, current_user_employee());

        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.id, 'promoted_from_personal', v_owner_emp, current_user_employee());

        RETURN NEW;
    END IF;

    -- ── 降级:团队 → 私人。只在【可证明无损】的窗口内允许。
    IF OLD.task_type = 'team' AND NEW.task_type = 'personal' THEN
        -- 【TASK-1c-c:只数【此刻还活跃】的其他人】。
        -- 退出是软的,行留着 —— 但一个已经退出的人不在这件事上了,
        -- 再让他挡着降级,等于把"曾经来过"读成"正在这里",而那让退出变得没有意义:
        -- 任何来过第二个人的任务都永久锁死,且没有任何一条路解得开。
        SELECT count(*) INTO v_others
          FROM public.task_participants p
         WHERE p.task_id = NEW.id
           AND p.removed_at IS NULL
           AND p.employee_id IS DISTINCT FROM NEW.owner_id;

        IF v_others > 0 THEN
            RAISE EXCEPTION 'TASK_TYPE_LOCKED_PARTICIPANTS|%|%', NEW.code, v_others
              USING HINT = '这张任务上还有别人在;把他们移出之后才能改回私人';
        END IF;
        RETURN NEW;
    END IF;

    RAISE EXCEPTION 'TASK_TYPE_TRANSITION_UNKNOWN|%|%', OLD.task_type, NEW.task_type;
END;
$function$;

COMMIT;

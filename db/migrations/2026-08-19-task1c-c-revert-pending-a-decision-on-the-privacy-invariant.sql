-- TASK-1c-c 撤回:removed_at 那个过滤【删掉的是一条隐私规则】,不是一个 bug
--
-- 本刀原本要把降级判据改成"只数还活跃的人",理由是:人加进来又移出之后,
-- 降级就永远不可能了。那个现象是真的,Tim 撞上了它。
--
-- 【但那不是一处疏漏,它是一条被写下来、被断言、并且被明确警告过的不变式】:
--   * db/fixtures/94 的抬头写着「D 是这份 fixture 存在的理由」——
--     C(建错类型、从来没有别人来过)与 D(有人来过又退出)的【当前现场一模一样】,
--     分得开它们的只有 task_participants 里那一行软删记录;
--   * tasks.task_type 的列注释写着:「谁加了第二条降级路径,谁就悄悄毁掉了隐私规则」,
--     并且把后果写得很具体 —— 一张有过五个人的团队任务变回私人之后,
--     那五个人从此读不到自己参与过的记录。
--
-- 加上过滤之后,gate 的行为断言当场红了,红在 fixture 94D —— 也就是说
-- 【这条规矩是有人守着的】,而不是没人注意到的老代码。
--
-- 所以本刀撤回,把判据恢复原样,等一个【产品裁定】:
--   (甲) 隐私优先(现状):来过的人留下痕迹,任务从此不能变回私人。
--        代价是 Tim 撞上的那个死结 —— 而且它没有任何解法。
--   (乙) 可逆优先:活跃的人才挡着降级。代价是前参与者会失去读权,
--        而 task_type='personal' 不再蕴含"这张任务从来不曾是团队任务"。
--        选它就必须同时改 fixture 94D 与 task_type 的列注释,并想清楚
--        前参与者的读权由什么承接(例如按 task_history 另开一条读路径)。
-- 裁定之前不动它 —— 一条隐私规则不该在一支"修控件"的迁移里被顺手删掉。
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

    IF OLD.task_type = 'personal' AND NEW.task_type = 'team' THEN
        SELECT e.id INTO v_owner_emp FROM public.employees e
         WHERE e.id = NEW.owner_id AND e.deleted_at IS NULL LIMIT 1;

        IF v_owner_emp IS NULL THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_AN_EMPLOYEE|%', NEW.code
              USING HINT = '这张任务的归属人没有对应的在册员工;升级之后将没有任何人改得动它';
        END IF;

        v_what := public.ensure_task_owner_participant(NEW.id, v_owner_emp, current_user_employee());

        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.id, 'promoted_from_personal', v_owner_emp, current_user_employee());

        RETURN NEW;
    END IF;

    IF OLD.task_type = 'team' AND NEW.task_type = 'personal' THEN
        -- 【removed_at 故意不过滤 —— 见本文件抬头,以及 tasks.task_type 的列注释】
        -- 判据是"有没有别人【来过】",不是"此刻还在不在"。退出是软的,行留着,
        -- 所以来过这件事无法被抹掉 —— 那正是 task_type='personal' 能够蕴含
        -- "这张任务从来不曾真正是团队任务"的唯一原因。
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
$function$;

COMMIT;

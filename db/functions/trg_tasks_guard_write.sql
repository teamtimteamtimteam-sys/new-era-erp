CREATE OR REPLACE FUNCTION public.trg_tasks_guard_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 属主 / SECURITY DEFINER / 迁移 / fixture 的 postgres:RLS 不生效,放行 ——
    -- 与 enforce_write_permission 同一格,理由见它的抬头。
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- 归属人解析不出(没有关联员工的账号):让 trg_tasks_owner_required 说那句话。
        IF NEW.owner_id IS NULL THEN
            RETURN NEW;
        END IF;
        -- Q6(i):对【每一个人】—— 新建的任务只能归自己。
        IF NEW.owner_id IS DISTINCT FROM current_user_employee() THEN
            RAISE EXCEPTION 'TASK_OWNER_NOT_SELF';
        END IF;
        IF public.has_permission('module.tasks.edit') THEN
            RETURN NEW;
        END IF;
        IF public.has_permission('module.tasks.view')
           AND public.task_is_own(NEW.task_type, NEW.owner_id) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
    END IF;

    -- UPDATE
    -- Q6(ii):对【每一个人】—— 归属人不许改。没有任何功能转移归属。
    IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
        RAISE EXCEPTION 'TASK_OWNER_IMMUTABLE|%', OLD.code;
    END IF;
    IF public.can_edit_task(OLD.id) THEN
        RETURN NEW;
    END IF;
    -- 自己的任务例外:内容可以改,类型不许改(升级为团队任务要 module.tasks.edit)。
    IF public.has_permission('module.tasks.view')
       AND public.task_is_own(OLD.task_type, OLD.owner_id)
       AND NEW.task_type IS NOT DISTINCT FROM OLD.task_type THEN
        RETURN NEW;
    END IF;
    -- 持码却不在这张任务上:那不是一个管理员勾得出来的码,说成缺码就是说错原因。
    IF public.has_permission('module.tasks.edit') THEN
        RAISE EXCEPTION 'TASK_NOT_EDITABLE|%', OLD.code;
    END IF;
    RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
END;
$function$;

COMMENT ON FUNCTION public.trg_tasks_guard_write() IS
'APR-4(Tim 的 Q6/Q7):tasks 的逐行写闸。插入:归属人必须是自己(对每一个人);没有 module.tasks.edit 的人只能建自己的私人任务。更新:归属人冻结(对每一个人,TASK_OWNER_IMMUTABLE);完整编辑人(can_edit_task)放行;自己的任务例外放行但类型不许变;其余按名拒 —— 持码而不在任务上抛 TASK_NOT_EDITABLE,不持码抛 PERMISSION_DENIED|module.tasks.edit。
★ 它【不能】单独替掉语句级的 enforce_write_permission:行级触发器在零行时根本不触发。所以 tasks 的 UPDATE 策略的 USING 放宽到"你看得见的行",让被拒的那一行真的进到这里、被按名拒;语句级那一支仍在(fixture 198 按名字要求每张带写策略的表都有它),只是多认一个 module.tasks.view。
★ 名字以 trg_tasks_guard 开头是【承重】的:同一时点的 BEFORE 触发器按名字字母序触发,它必须排在 trg_tasks_owner_required 与 trg_tasks_type_transition 之前 —— 否则一次被拒的升级会先让类型迁移那一支跑起来。';

CREATE OR REPLACE FUNCTION public.trg_task_nodes_guard_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;

    IF (TG_OP IN ('UPDATE', 'DELETE') AND NOT public.can_write_task(OLD.task_id))
       OR (TG_OP IN ('INSERT', 'UPDATE') AND NOT public.can_write_task(NEW.task_id)) THEN
        IF public.has_permission('module.tasks.edit') THEN
            RAISE EXCEPTION 'TASK_NOT_EDITABLE|';
        END IF;
        RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
    END IF;

    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

COMMENT ON FUNCTION public.trg_task_nodes_guard_write() IS
'APR-4(Tim 的 Q5/Q7):task_nodes 的逐行写闸 —— 步骤跟着它那张任务走,判据就是 can_write_task(任务)。自己的私人任务上的步骤,没有 module.tasks.edit 也加得、改得、勾得、删得。
★ 同 trg_tasks_guard_write:写策略的 USING 放宽到 can_view_task,让被拒的行进到这里按名拒;语句级 enforce_write_permission 仍在,多认一个 module.tasks.view。名字排在 trg_task_nodes_no_orphan / _touch 之前。';

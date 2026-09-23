CREATE OR REPLACE FUNCTION public.trg_task_participants_guard_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;

    IF NOT public.can_edit_task(NEW.task_id) THEN
        IF public.has_permission('module.tasks.edit') THEN
            RAISE EXCEPTION 'TASK_NOT_EDITABLE|';
        END IF;
        RAISE EXCEPTION 'PERMISSION_DENIED|module.tasks.edit';
    END IF;

    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.trg_task_participants_guard_write() IS
'APR-4(Tim 的 Q5/Q7):参与者【不在】自己的任务例外里 —— 加人、移人一律要 can_edit_task(module.tasks.edit + 在任务上)。此前一个没有码的人插参与者撞的是一句无名的 "new row violates row-level security policy";现在按名拒。
写策略与语句级 enforce_write_permission 一字未改:对一个不持码的人,更新本来就被语句级那一支按名拒了。
★ 属主路径(升级时 ensure_task_owner_participant 以 SECURITY DEFINER 插归属人那一行)由 row_security_active 放行。';

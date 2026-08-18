CREATE OR REPLACE FUNCTION public.trg_task_participants_history()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_others integer;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- 【归属人的头一行不写历史】:变更记录记的是【改动】,不是初始状态。
        -- 判据是事实,不是标志位:这是本任务的第一条参与者行,且加的就是自己。
        SELECT count(*) INTO v_others FROM public.task_participants
         WHERE task_id = NEW.task_id AND id <> NEW.id;
        IF v_others = 0 AND NEW.added_by = NEW.employee_id THEN
            RETURN NEW;
        END IF;
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.task_id, 'participant_added', NEW.employee_id, NEW.added_by);
        RETURN NEW;
    END IF;

    IF OLD.removed_at IS NULL AND NEW.removed_at IS NOT NULL THEN
        -- 【自己走】与【被移出】是两个 change_type,因为"她是自己退出的
        -- 还是被拿掉的"正是这份记录该回答的问题,一个码答不了。
        INSERT INTO public.task_history (task_id, change_type, employee_id, changed_by)
        VALUES (NEW.task_id,
                CASE WHEN NEW.removed_by = NEW.employee_id
                     THEN 'participant_left' ELSE 'participant_removed' END,
                NEW.employee_id, NEW.removed_by);
    END IF;
    RETURN NEW;
END;
$function$


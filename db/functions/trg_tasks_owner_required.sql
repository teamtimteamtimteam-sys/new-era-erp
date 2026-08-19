CREATE OR REPLACE FUNCTION public.trg_tasks_owner_required()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.owner_id IS NULL THEN
        RAISE EXCEPTION 'TASK_CREATOR_NOT_AN_EMPLOYEE|%', COALESCE(NEW.code, NEW.title)
          USING HINT = '你的登录账号还没有关联在册员工档案,所以这张任务没有归属人;请先在 HR 里关联账号';
    END IF;
    RETURN NEW;
END;
$function$


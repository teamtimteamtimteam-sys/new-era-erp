CREATE OR REPLACE FUNCTION public.trg_tasks_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'TASK_HARD_DELETE_REFUSED|%', OLD.code
      USING HINT = '任务不硬删:置 deleted_at(软删)。硬删会孤立 task_history 里的记录';
END;
$function$


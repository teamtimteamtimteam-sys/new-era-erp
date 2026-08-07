CREATE OR REPLACE FUNCTION public.guard_cost_entry_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 软删(UPDATE deleted_at)才是这张表的删除语义:它过冲销分录、留历史行、
    -- 并把 updated_at 顶上去让分摊标记过期。硬删三件全不做。
    RAISE EXCEPTION 'COST_ENTRY_HARD_DELETE|%', OLD.cost_type;
END;
$function$;
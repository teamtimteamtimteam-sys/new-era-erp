CREATE OR REPLACE FUNCTION public.guard_batch_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 撤销一个录错的批次走【软删】(置 deleted_at)—— 它会写一条 writeoff 流水,
    -- 于是"这批料曾经在册、后来被注销"仍然读得出来。硬删不是撤销:
    -- 它让这件事从来没发生过,并且带走化验含量。
    RAISE EXCEPTION 'BATCH_NO_HARD_DELETE|%', OLD.code;
END;
$function$;

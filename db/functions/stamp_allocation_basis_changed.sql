CREATE OR REPLACE FUNCTION public.stamp_allocation_basis_changed()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 跟着重分摊一起改的基准不是漂移 —— allocate_processing_costs 会挂上这个标记。
    IF current_setting('evoltrya.alloc_ctx', true) = '1' THEN
        RETURN NEW;
    END IF;
    -- 单独改的才是。clock_timestamp() 而不是 now():事务内也要走得动,否则
    -- "分摊完之后又改了基准"与"分摊时顺手改的"分不开(fixture 32 的 seq 同一课)。
    NEW.allocation_basis_changed_at := clock_timestamp();
    RETURN NEW;
END;
$function$;
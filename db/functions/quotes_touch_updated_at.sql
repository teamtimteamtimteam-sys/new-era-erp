CREATE OR REPLACE FUNCTION public.quotes_touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 【clock_timestamp(),不是 now()】见本迁移抬头:这一列是
    -- amended_since_issue 那个比较式的一边,而不是一条普通的审计痕迹。
    -- 共用的 update_updated_at 仍然服务着其余十几张表 —— 那些列没有人拿去
    -- 比先后,事务时刻对它们完全够用。
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$function$

;

CREATE OR REPLACE FUNCTION public.guard_asset_acceptance_not_future()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.acceptance_date IS NOT NULL AND NEW.acceptance_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSET_ACCEPTANCE_IN_FUTURE|%|%', NEW.code, NEW.acceptance_date
          USING HINT = '验收合格是一件发生过的事 —— 未来的日期填不进来。质保期从它起算,一个未来的锚会让到期日也是假的';
    END IF;
    RETURN NEW;
END;
$function$
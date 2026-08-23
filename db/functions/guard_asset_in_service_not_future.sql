CREATE OR REPLACE FUNCTION public.guard_asset_in_service_not_future()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 与停机那一条【同一句话】:投用是一件发生过的事。
    -- 【只看 in_service_date,绝不看 planned_in_service_date】——
    -- 后者可以在未来,那正是它存在的全部理由。
    IF NEW.in_service_date IS NOT NULL AND NEW.in_service_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSET_IN_SERVICE_IN_FUTURE|%', NEW.in_service_date;
    END IF;
    RETURN NEW;
END;
$fn$;

;

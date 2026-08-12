CREATE OR REPLACE FUNCTION public.guard_storage_location_code_unique()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 只在【别的行】已经占了这个号时拒绝 —— 改名(code 不变)不该撞自己。
    IF EXISTS (
        SELECT 1 FROM public.storage_locations
        WHERE code = NEW.code AND id <> NEW.id
    ) THEN
        RAISE EXCEPTION 'LOC_CODE_EXISTS|%', NEW.code;
    END IF;
    RETURN NEW;
END;
$function$

;

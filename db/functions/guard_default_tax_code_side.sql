CREATE OR REPLACE FUNCTION public.guard_default_tax_code_side()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_side text; v_want text;
BEGIN
    IF NEW.default_tax_code IS NULL THEN RETURN NEW; END IF;
    v_want := CASE TG_TABLE_NAME WHEN 'customers' THEN 'output' ELSE 'input' END;
    SELECT side INTO v_side FROM tax_codes WHERE code = NEW.default_tax_code;
    IF v_side IS DISTINCT FROM v_want THEN
        RAISE EXCEPTION 'TAX_CODE_WRONG_SIDE|%|%', NEW.default_tax_code, v_want;
    END IF;
    RETURN NEW;
END;
$function$
;
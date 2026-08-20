CREATE OR REPLACE FUNCTION public.guard_container_document_na_reason()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.status = 'not_applicable' AND (NEW.na_reason IS NULL OR btrim(NEW.na_reason) = '') THEN
        RAISE EXCEPTION 'CONTAINER_DOC_NA_REASON_REQUIRED|%', NEW.document_type
          USING HINT = '判一份单据"不适用"要写明为什么 —— 没有理由的不适用与漏掉长得一样';
    END IF;
    RETURN NEW;
END;
$function$


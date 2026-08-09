CREATE OR REPLACE FUNCTION public.guard_po_issues_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 签发档被改写过,就不再证明供应商手里那份是什么了。自己报名(FIN-31)。
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'PO_ISSUE_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'PO_ISSUE_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;
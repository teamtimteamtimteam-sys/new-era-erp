CREATE OR REPLACE FUNCTION public.guard_so_issues_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'SO_ISSUE_IMMUTABLE';
END;
$function$

;

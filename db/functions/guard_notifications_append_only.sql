CREATE OR REPLACE FUNCTION public.guard_notifications_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'NOTIFICATION_IMMUTABLE';
END;
$function$

;

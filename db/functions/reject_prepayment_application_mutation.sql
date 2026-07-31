CREATE OR REPLACE FUNCTION public.reject_prepayment_application_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'PREPAYMENT_APPLICATION_IMMUTABLE';
END;
$function$


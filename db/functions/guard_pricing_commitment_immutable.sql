CREATE OR REPLACE FUNCTION public.guard_pricing_commitment_immutable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'PRICING_COMMITMENT_IMMUTABLE';
END;
$function$;
CREATE OR REPLACE FUNCTION public.trg_notify_location_classes_written()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locs uuid[];
BEGIN
    SELECT array_agg(DISTINCT location_id) INTO v_locs FROM new_rows;
    IF v_locs IS NOT NULL THEN
        PERFORM notify_class_violations('location_configured', NULL, v_locs);
    END IF;
    RETURN NULL;
END;
$function$

;

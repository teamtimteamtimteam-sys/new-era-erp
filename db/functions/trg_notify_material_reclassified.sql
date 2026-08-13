CREATE OR REPLACE FUNCTION public.trg_notify_material_reclassified()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM notify_class_violations('material_reclassified', ARRAY[NEW.id], NULL);
    RETURN NULL;
END;
$function$

;

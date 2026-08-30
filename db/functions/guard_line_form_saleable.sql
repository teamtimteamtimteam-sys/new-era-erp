CREATE OR REPLACE FUNCTION public.guard_line_form_saleable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.assert_material_form_saleable(NEW.material_id);
    RETURN NEW;
END;
$function$

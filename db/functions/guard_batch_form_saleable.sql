CREATE OR REPLACE FUNCTION public.guard_batch_form_saleable()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.assert_output_batch_saleable(NEW.output_batch_id);
    RETURN NEW;
END;
$function$

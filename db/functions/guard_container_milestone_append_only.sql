CREATE OR REPLACE FUNCTION public.guard_container_milestone_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'CONTAINER_MILESTONE_IMMUTABLE|%', TG_OP
      USING HINT = '里程碑只增不改:记错了就再记一条,并在 note 里说明';
END;
$function$


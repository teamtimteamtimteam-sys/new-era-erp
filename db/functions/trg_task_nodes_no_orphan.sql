CREATE OR REPLACE FUNCTION public.trg_task_nodes_no_orphan()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_children integer;
BEGIN
    SELECT count(*) INTO v_children FROM public.task_nodes WHERE parent_id = OLD.id;
    IF v_children > 0 THEN
        RAISE EXCEPTION 'TASK_NODE_HAS_CHILDREN|%|%', OLD.title, v_children
          USING HINT = '这个步骤下面还有子步骤;先删子步骤,不会连带删除';
    END IF;
    RETURN OLD;
END;
$function$


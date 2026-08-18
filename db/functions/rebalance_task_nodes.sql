CREATE OR REPLACE FUNCTION public.rebalance_task_nodes(p_task_id uuid, p_parent_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE v_n integer;
BEGIN
    PERFORM set_config('app.task_rebalance', 'on', true);
    WITH ordered AS (
        SELECT id, row_number() OVER (ORDER BY sort_order, created_at, id) AS rn
          FROM public.task_nodes
         WHERE task_id = p_task_id AND parent_id IS NOT DISTINCT FROM p_parent_id)
    UPDATE public.task_nodes n SET sort_order = o.rn * 1024
      FROM ordered o WHERE n.id = o.id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM set_config('app.task_rebalance', 'off', true);
    RETURN v_n;
END;
$function$


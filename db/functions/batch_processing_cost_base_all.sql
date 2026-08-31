CREATE OR REPLACE FUNCTION public.batch_processing_cost_base_all(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【计值读取器】同 batch_freight_base_all —— 理由见那一支的抬头。
    -- 【冲销即解除】回滚把加工单软删(deleted_at),这里就不再计它 ——
    -- 与只认 status = 'posted' 的运费单是同一条。
    -- 【实测确认(PROC-COST-2 步骤 2d)】回滚之后载体行【仍然物理存在】,
    -- 排除靠的是这里的 deleted_at / status,不是删行。
    SELECT COALESCE(SUM(a.amount_base), 0)
    FROM batch_processing_cost_allocations a
    JOIN processing_runs r ON r.id = a.run_id
    WHERE a.inbound_batch_id = p_inbound_batch_id
      AND r.deleted_at IS NULL AND r.status = 'committed';
$function$;
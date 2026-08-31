CREATE OR REPLACE FUNCTION public.batch_processing_cost_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price
    --                              + batch_freight_base + 本函数。
    -- 【冲销即解除】回滚把加工单软删(deleted_at),这里就不再计它 ——
    -- 与 batch_freight_base 只认 status = 'posted' 的运费单是同一条。
    -- 【属主权限 + 体内判据】见 fu2 迁移抬头:JOIN processing_runs 会把行丢给
    -- 一个只有 inbound.view 的读者,而丢行是【无声】的。0.00 与「受限」不是
    -- 同一件事,所以无权时返回 NULL。
    SELECT CASE
        WHEN has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          -- 【edit 也在列】allocate_processing_costs 的调用者必然持有它,
          -- 于是那条材料成本表达式里这一支【按构造】不可能是 NULL。
          OR has_permission('module.processing.edit')
        THEN (
            SELECT COALESCE(SUM(a.amount_base), 0)
            FROM batch_processing_cost_allocations a
            JOIN processing_runs r ON r.id = a.run_id
            WHERE a.inbound_batch_id = p_inbound_batch_id
              AND r.deleted_at IS NULL AND r.status = 'committed'
        )
        ELSE NULL
    END;
$function$

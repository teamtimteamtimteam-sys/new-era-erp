CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【屏幕读取器】0.00 与「受限」不是同一件事:第一个是谎话。
    -- 白名单与 batch_processing_cost_base 逐字相同,理由也逐字相同 ——
    -- 【edit 也在列】allocate_processing_costs 的调用者必然持有它,于是
    -- 材料成本表达式里这一支【按构造】不可能是 NULL。一个 NULL 加数会让
    -- SUM 跳过整条投料腿(连 unit_price 一起),那比读到 0 更坏。
    SELECT CASE
        WHEN has_permission('module.inbound.view')
          OR has_permission('module.finance.view')
          OR has_permission('module.processing.view')
          OR has_permission('module.processing.edit')
        THEN batch_freight_base_all(p_inbound_batch_id)
        ELSE NULL
    END;
$function$;
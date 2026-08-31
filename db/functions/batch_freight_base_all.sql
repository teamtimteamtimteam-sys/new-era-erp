CREATE OR REPLACE FUNCTION public.batch_freight_base_all(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【计值读取器 —— 不问调用者是谁】过账用的数不许取决于谁按的按钮。
    -- 屏幕读取器是 batch_freight_base(),它加判据、无权给 NULL。
    -- 【对 authenticated 不可执行】见 db/views/zzz_function_grants.sql —— 它没有
    -- 调用者检查,靠的就是调不到(gate 的 B2 认这条出路)。
    --
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price
    --                              + 本函数 + batch_processing_cost_base_all。
    -- 冲销掉的运费单不计(status = 'reversed')。
    SELECT COALESCE(SUM(fa.amount_base), 0)
    FROM freight_allocations fa
    JOIN freight_documents fd ON fd.id = fa.freight_document_id
    WHERE fa.inbound_batch_id = p_inbound_batch_id
      AND fd.deleted_at IS NULL AND fd.status = 'posted';
$function$;
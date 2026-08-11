CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price + 本函数。
    -- 冲销掉的运费单不计(status = 'reversed')。
    SELECT COALESCE(SUM(fa.amount_base), 0)
    FROM freight_allocations fa
    JOIN freight_documents fd ON fd.id = fa.freight_document_id
    WHERE fa.inbound_batch_id = p_inbound_batch_id
      AND fd.deleted_at IS NULL AND fd.status = 'posted';
$function$;
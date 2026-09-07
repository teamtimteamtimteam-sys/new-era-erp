CREATE OR REPLACE FUNCTION public.void_cod_internal(p_cod_id uuid, p_reason text, p_replaced_by uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【作废【不动】字节档案与快照一个字】—— 供应商手里那张纸仍然查得到、
    -- 仍然对得上哈希。与 invoice_issues 在作废后原样保留同一条。
    UPDATE certificates_of_destruction
       SET status = 'void', void_reason = p_reason,
           voided_at = clock_timestamp(), voided_by = auth.uid(),
           replaced_by_cod_id = p_replaced_by
     WHERE id = p_cod_id AND status = 'issued';
END;
$function$;

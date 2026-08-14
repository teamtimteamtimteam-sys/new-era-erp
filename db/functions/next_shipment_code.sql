CREATE OR REPLACE FUNCTION public.next_shipment_code(p_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer;
    v_seq  integer;
BEGIN
    -- 【无缝编号,自己的那把锁】互斥点是 advisory key 这个字符串 ——
    -- 'shipment_code_<year>',与发票('invoice_code_')、销售订单各自一把。
    -- MAX+1 只是推导;两个并发调用靠这把锁串行,回滚即释放号码。
    v_year := EXTRACT(YEAR FROM p_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('shipment_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM shipments WHERE code LIKE 'SHP-' || v_year::text || '-%';
    RETURN 'SHP-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;

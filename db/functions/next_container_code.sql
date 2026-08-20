CREATE OR REPLACE FUNCTION public.next_container_code(p_date date)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_year integer; v_seq integer;
BEGIN
    -- 与 next_shipment_code 一字不差的形状:互斥点是 advisory key 这个字符串,
    -- MAX+1 只是推导;两个并发调用靠这把锁串行,回滚即释放号码。
    v_year := EXTRACT(YEAR FROM p_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('container_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1 INTO v_seq
    FROM containers WHERE code LIKE 'CTR-' || v_year::text || '-%';
    RETURN 'CTR-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$


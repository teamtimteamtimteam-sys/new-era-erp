CREATE OR REPLACE FUNCTION public.next_sales_order_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('sales_order_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM sales_orders
    WHERE code LIKE 'SO-' || v_year::text || '-%';
    RETURN 'SO-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$

;

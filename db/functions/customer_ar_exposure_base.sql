CREATE OR REPLACE FUNCTION public.customer_ar_exposure_base(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(sum(open_base), 0) FROM (
        SELECT round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base
        FROM sales_records sr
        LEFT JOIN LATERAL (
            SELECT sum(pa.allocated_ccy) AS settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.sales_record_id = sr.id
        ) s ON true
        WHERE sr.customer_id = p_customer_id
          AND round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) > 0
    ) x;
$function$;
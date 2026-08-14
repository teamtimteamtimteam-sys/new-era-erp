CREATE OR REPLACE FUNCTION public.customer_ar_exposure_base(p_customer_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- SO-3a:敞口 = 未结清销售 + 【已过账未结清的订单流发票】。第二项读
    -- order_invoice_open_all —— ar_open_items 的第二支读的也是它:面板显示的
    -- 余额与拒绝的那道闸必须是同一个数(fixture 67 的目录断言钉住两个消费者)。
    -- 两项按构造不相交:发货(3b)产生的销售记录不带应收,第一项看不见它们。
    SELECT COALESCE((
        SELECT sum(open_base) FROM (
            SELECT round((sr.quantity * sr.unit_price - COALESCE(s.settled, 0)) * sr.fx_rate, 2) AS open_base
            FROM sales_records sr
            LEFT JOIN LATERAL (
                SELECT sum(pa.allocated_ccy) AS settled
                FROM payment_allocations pa
                JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                WHERE pa.sales_record_id = sr.id
            ) s ON true
            WHERE sr.customer_id = p_customer_id
              -- SO-3b:发货产生的销售记录【不带应收】—— 那笔债在开票当刻已经
              -- 记过(借 1100 / 贷 2500)。与 ar_open_items 第一支逐字同一条谓词:
              -- 少了它,同一笔钱会在敞口里被数两遍。
              AND sr.sales_order_line_id IS NULL
              AND round(sr.quantity * sr.unit_price - COALESCE(s.settled, 0), 2) > 0
        ) x), 0)
    + COALESCE((
        SELECT sum(o.open_base) FROM order_invoice_open_all o
        WHERE o.customer_id = p_customer_id), 0);
$function$

;

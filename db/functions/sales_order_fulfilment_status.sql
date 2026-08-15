CREATE OR REPLACE FUNCTION public.sales_order_fulfilment_status(p_sales_order_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- SO-1b:【已发 vs 已订】—— 这张单是发完了,还是发了一部分。
    --
    -- 【为什么是一个函数】此前它写在 ship_order 的函数体里。改单需要同一个判断
    -- (加一行会让一张发完的单退回 partially_shipped;把一行改到正好等于已发会让
    -- 一张短装的单变成 shipped),抄一份过去,两边会在写下的那天一致、此后各自
    -- 漂移 —— 这个仓库为这条形状付过四次账(验资影响预览、GrantRunner、重估预览、
    -- /finance/payments),SO-3b fu5 的 line_spoken_for 是第五次。
    --
    -- 【只回答这两个值】confirmed(一件没发)不在此列:调用方自己知道该不该问。
    -- 一个"没发货就返回 confirmed"的版本会让改单顺手把状态往回推,而那是一次
    -- 【状态转换】,要走 set_sales_order_status。
    SELECT CASE
        WHEN COALESCE((SELECT sum(sl.qty)
                         FROM shipment_lines sl
                         JOIN shipments s ON s.id = sl.shipment_id
                        WHERE s.sales_order_id = p_sales_order_id), 0)
             >= COALESCE((SELECT sum(l.quantity)
                            FROM sales_order_lines l
                           WHERE l.sales_order_id = p_sales_order_id), 0)
        THEN 'shipped' ELSE 'partially_shipped' END;
$function$

;

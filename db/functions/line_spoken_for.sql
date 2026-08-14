CREATE OR REPLACE FUNCTION public.line_spoken_for(p_sales_order_line_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- SO-3b fu5:【这一行已经许出去多少】= 已发 + 活预留。
    --
    -- 【这是唯一一处推导】两个消费方:
    --   ① reserve_stock 的行天花板(许出去的 + 本次 ≤ 行数量);
    --   ② SO-1b 改单的【下限】—— 一条已经许出去 N 的行改不到 N 以下,
    --      读的是【同一个函数】,不另写一遍。
    -- 两份推导会在写下的那天一致,此后各自漂移;这条缺陷本身就是"活预留"这
    -- 一个口径被当成两个意思用出来的。
    --
    -- 【已发读 shipment_lines,不读"已消耗的预留"】两者恒等
    -- (shipment_lines.reservation_id 是 NOT NULL UNIQUE,ship_order 同一个事务里
    -- 写发货行并把预留标成 consumed),取前者是因为它是【货真的离开了】的记录。
    -- 也因此不会重复计数:一条预留要么还活着,要么已经变成一条发货行。
    --
    -- 【释放了的不算】释放把货放回 available,那一份没有再许给任何人。
    SELECT COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                      WHERE sl.sales_order_line_id = p_sales_order_line_id), 0)
         + COALESCE((SELECT sum(r.qty) FROM sales_order_reservations r
                      WHERE r.sales_order_line_id = p_sales_order_line_id
                        AND r.released_at IS NULL
                        AND r.consumed_at IS NULL), 0);
$function$

;

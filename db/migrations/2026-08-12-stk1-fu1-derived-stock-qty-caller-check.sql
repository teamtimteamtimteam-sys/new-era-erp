-- db/migrations/2026-08-12-stk1-fu1-derived-stock-qty-caller-check.sql
-- STK-1 续:derived_stock_qty 补上调用者检查 —— gate 的 definer 判词点名了它
--
-- 它是 SECURITY DEFINER(要绕过 RLS 才能替 hold_stock / release_stock 算出
-- 【真实】仓位),但没有任何调用者检查:任何登录用户都能直接调它,读出任意
-- 批次 × 库位 × 状态的数量。gate 的 definer 那条判词就是为这个形状建的。
--
-- 【为什么不改成 SECURITY INVOKER 了事】那样 RLS 会把没有 module.inventory.view
-- 的人过滤成【零行】,而这个函数返回的是 sum() —— 零行的 sum 是 0。
-- 于是"你不该看见"会伪装成"这里没有货",而那正是 restricted-is-not-zero
-- 反复付过账的那种谎。保持 DEFINER + 显式点名拒绝,才能把两者分开。
--
-- 语言从 sql 改成 plpgsql:只为了能 PERFORM require_permission。算术一字未动。
--
-- 镜像:db/functions/derived_stock_qty.sql。

BEGIN;

DROP FUNCTION public.derived_stock_qty(uuid, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.derived_stock_qty(
    p_inbound_batch_id uuid, p_output_batch_id uuid,
    p_location_id uuid, p_stock_status text)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_qty numeric;
BEGIN
    -- 看得见库存分布 = 看得见库存模块。拒绝【点名】,不伪装成 0。
    PERFORM require_permission('module.inventory.view');

    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_qty
    FROM inventory_movements m
    WHERE m.stock_status = p_stock_status
      AND m.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
      AND m.output_batch_id  IS NOT DISTINCT FROM p_output_batch_id
      AND m.location_id      IS NOT DISTINCT FROM p_location_id;

    RETURN v_qty;
END;
$function$;

COMMIT;

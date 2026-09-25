-- db/functions/receipt_price_open.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5):这张收货此刻挂着的那张在等的定价申请的 label
-- (例:IN-2026-0153 · price #1),没有就 NULL。
--
-- 【它为什么必须是 DEFINER】两支守卫(guard_inbound_batch_price_request ·
-- guard_inbound_batch_metals_price_request)是 INVOKER。receipt_price_requests 的读策略要
-- module.inbound.view + data.view_purchase_prices;一个持 inbound.edit 却不持采购价码的写入者
-- (operations)在 INVOKER 里读它会拿到【零行】,守卫就会把"看不见"读成"没有申请"而静默放行 ——
-- AGENTS.md 那条「守卫对主语缺席这一格是瞎的」(payroll_period_frozen 逐字同一条)。
-- 【它为什么不能收回 EXECUTE,也不能加调用者检查】调它的是 INVOKER 触发器,EXECUTE 按当前用户判。
-- 它吐出的只有一个 label(收货编号 · 第几次),不带任何价格。
-- 两处 allowlist 同改:db/check_mirrors.py 的 DEFINER_NO_CHECK_ALLOWED 与
-- db/verify_rebuild.py 的 DEFINER_UNCHECKED_EXEC_ALLOWED。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_open(p_inbound_batch_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.label FROM receipt_price_requests r
     WHERE r.inbound_batch_id = p_inbound_batch_id AND r.status = 'submitted'
     LIMIT 1
$function$
;

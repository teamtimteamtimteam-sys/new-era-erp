-- PO-GST-1-fu1(2026-09-03)· 把 tax_total_ccy 的表级列授权收回来
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这是主迁移里我自己开的一个洞,记下来而不是悄悄补上】
-- 主迁移写了:
--     GRANT SELECT (tax_total_ccy) ON public.purchase_orders TO authenticated;
-- 那是【错的】。purchase_orders 是遮蔽表,而它的两列钱 —— estimated_total_ccy
-- 与 fx_rate —— 【刻意都不在列清单授权里】(见该表 GRANT 那一行:从 id 一路列到
-- contract_id,那两列不在其中)。它们只经 purchase_orders_masked 读,
-- 而视图里那个 CASE 才是 data.view_prices 那道门。
--
-- 我给 tax_total_ccy 发了表级授权,等于让任何持 module.purchasing.view 的人
-- 【绕过 data.view_prices 直接读到这张单的税额】—— 而税额是从净额推出来的钱:
-- 知道税额与税率,净额就是 tax / rate × 100。**遮蔽就是这样被绕开的。**
--
-- 【为什么它没有被任何一道闸拦住】colgrant 那道闸问的是"遮蔽表的每一列要么被
-- 列授权、要么在 _masked 里"—— 它防的是【读不出来】,不是【读得太多】。
-- 一个多发的授权对它来说是合法的。**这一条记进 docs/purchase-order-gst.md:
-- 那道闸的方向是单向的。**
--
-- 【为什么是一支独立的迁移而不是改主迁移】主迁移已经提交到线上了(15:36:06)。
-- 改一支已经应用过的迁移文件,会让仓库里那一份与线上真正跑过的那一份不是同一个
-- 东西 —— 本仓库对"迁移是一份账,不是一份意图"这件事的既有立场。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

REVOKE SELECT (tax_total_ccy) ON public.purchase_orders FROM authenticated;

COMMIT;

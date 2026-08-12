-- db/migrations/2026-08-12-iod1-fu2-revoke-inner-helpers.sql
-- IOD-1 续:drain_stock / mirror_consume_restore 收回 authenticated 的 EXECUTE
--
-- gate 的 B2 判词点名了它们:SECURITY DEFINER、没有调用者检查、而且可执行。
-- 三条出路(加检查 / 收权 / 具名豁免)里,这两个该走【收权】——
--
-- 【为什么不是"加一条 require_permission"】它们是内层算子,调用方各自属于
-- 不同模块:drain_stock 被销售(module.output.edit)、投料(module.processing.edit)
-- 与注销触发器(进料或产出的 edit)三处调用。要给它挑一个权限码,只能挑一个
-- 比三者都松的 —— 那不是把关,那是把关的样子。而三个调用方【各自已经把过关了】。
--
-- 【为什么收权比加检查更强】收回之后,它们只能从别的 definer 函数体内以属主
-- 身份被调用 —— 也就是"调不到"本身就是保证,不依赖任何人记得写检查。
-- 与 calculate_metal_price_internal / record_approval_decision / 
-- customer_ar_exposure_base 同一条(见 db/views/zzz_function_grants.sql)。
--
-- 【为什么必须写进 zzz_function_grants.sql 而不是只在这里 REVOKE 一次】
-- 那个文件是【重建时唯一会重放的权限记录】,live 不会自己跑它。只在迁移里
-- 收一次,线上是干净的、重建出来的库却是敞开的 —— OPS-3/OPS-7 踩过的正是这个。
-- 所以这里 REVOKE 一次(让 live 立刻正确),同时把两行写进那个文件(让重建也正确);
-- apply_migration.sh 每次都会重放它,两边因此不会分家。
--
-- 镜像:db/views/zzz_function_grants.sql。

BEGIN;

REVOKE EXECUTE ON FUNCTION public.drain_stock(numeric, text, date, uuid, uuid, text[], uuid, text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.mirror_consume_restore(uuid, uuid, uuid, numeric, date, uuid) FROM authenticated;

COMMIT;

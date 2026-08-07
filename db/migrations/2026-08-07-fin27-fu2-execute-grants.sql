-- FIN-27-fu2(2026-08-07):新函数的 EXECUTE 权限 —— 让线上与重建一致。
--
-- 【为什么需要这一支】PostgreSQL 给新建函数【默认把 EXECUTE 授给 PUBLIC】,而
-- anon 从 PUBLIC 继承。重建那一侧没事:db/views/zzz_function_grants.sql 最后一步
-- 整架构 REVOKE ... FROM PUBLIC, anon 再授回 authenticated/service_role。线上没有
-- 人跑那一步,于是 FIN-27 新加的七个函数在线上对 anon 敞开 —— anon 就是互联网。
--
-- db/gate.py 当场点名(B1,live 7 / rebuild 0),这正是 OPS-4/OPS-5 立那条不变式的
-- 理由:两侧都要跑,而只有重建那一侧曾经看得见差异。这次是反过来的方向 ——
-- 差异只在线上,只有 live 那一侧看得见。
--
-- 【口径与 zzz_function_grants.sql 逐字一致】先对 PUBLIC/anon 收回,再授回
-- authenticated 与 service_role;内层算子(没有调用者检查、靠调不到的那几个)
-- 已在主迁移里对 authenticated 收回,此处不再授回。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin27-fu2-execute-grants.sql

BEGIN;

-- 触发器函数:闸门是触发它的那次基表写入,谁也不该直接调
REVOKE EXECUTE ON FUNCTION public.guard_pricing_commitment_immutable() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.guard_pricing_commitment_immutable() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_pricing_formula_history_append_only() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.guard_pricing_formula_history_append_only() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.log_pricing_formula_change() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.log_pricing_formula_change() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.log_pricing_formula_metal_change() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.log_pricing_formula_metal_change() TO authenticated, service_role;

-- 界面调得到的 RPC:自己查调用者(require_permission),但仍不给 anon
REVOKE EXECUTE ON FUNCTION public.preview_assay_price(uuid, jsonb, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.preview_assay_price(uuid, jsonb, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.preview_reprice_from_committed_terms(uuid, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.preview_reprice_from_committed_terms(uuid, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reprice_from_committed_terms(uuid, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.reprice_from_committed_terms(uuid, date) TO authenticated, service_role;

COMMIT;

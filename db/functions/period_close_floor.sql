-- db/functions/period_close_floor.sql
-- ROLE-1(2026-09-23):【最早一个还在生效的关账之后的第一天】—— 锁定日往回搬时
-- 不能越过的那条线。没有生效中的关账 → NULL(没有线)。
--
-- 为什么单独一支、为什么 SECURITY DEFINER:读它的是 guard_lock_reopen_path,
-- 一支 INVOKER 触发器(它必须是 INVOKER,才能用 row_security_active 分出"直连写"与
-- "reopen_period 这类属主路径")。INVOKER 里直接读 period_closes 会受调用者的 RLS 约束 ——
-- 一个读不到 period_closes 的写入者会读到 0 行、线变成 NULL、闸空转。
-- **空集不是"没有关账"**(与 guard_finance_settings_sod 头上那句同一条)。
-- 所以这一次读以属主身份做。
-- ★ EXECUTE【不】从 authenticated 收回 —— 这是故意的:调它的是一支 INVOKER 触发器,
--   而 EXECUTE 按【当前用户】判(AGENTS.md「属主权限视图替得了表,替不了函数的 EXECUTE」)。
--   收回它,每一次手动锁都会撞上 42501。它只返回一个日期,那个日期在关账页上本来就看得见。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.period_close_floor()
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT MAX(period_end) + 1
      FROM period_closes
     WHERE reopened_at IS NULL;
$function$;

COMMENT ON FUNCTION public.period_close_floor() IS
'ROLE-1:最新一个仍生效的关账之后的第一天(没有 → NULL)。guard_lock_reopen_path 的判据:一次直连写把 locked_before 搬到它之前(或清空),就等于重开了一个已关的月。以属主身份读 period_closes。EXECUTE 故意【不】收回:调用它的是一支 INVOKER 触发器。';

-- db/functions/payroll_period_frozen.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q4 · Q5):这个工资期的数【此刻能不能被直接改】——
-- 返回 'posted'(已过账)、'requested'(挂着一张未了结的申请)或 'open'。永不返回 NULL:
-- 期间不存在也答 'open'(那是插入一行新期间时的情形,守卫另有判据)。
--
-- 【它为什么必须是 DEFINER】两支守卫(guard_payroll_period_direct_write ·
-- guard_payroll_line_direct_write)是 INVOKER —— 它们要用 row_security_active 分出
-- 直连写与属主路径。可 payroll_requests 的读策略要 module.hr.view,一个持 hr.edit 却不持
-- hr.view 的写入者在 INVOKER 里读它会拿到【零行】,守卫就会把"看不见"读成"没有申请"而
-- 静默放行 —— 正是 AGENTS.md 那条「守卫对主语缺席这一格是瞎的」。
--
-- 【它为什么不能收回 EXECUTE,也不能加调用者检查】调它的是 INVOKER 触发器,EXECUTE 按
-- 当前用户判 —— 收回它,每一次直连写都 42501;加 has_permission 门,持 hr.edit 的写入者照样过、
-- 不持的人本来就被 RLS 挡在写外,门什么都不守(period_close_floor 逐字同一条理由)。
-- 它吐出的只有一个状态词,而那个状态在工资期页上本来就看得见。
-- 两处 allowlist 同改:db/check_mirrors.py 的 DEFINER_NO_CHECK_ALLOWED 与
-- db/verify_rebuild.py 的 DEFINER_UNCHECKED_EXEC_ALLOWED。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.payroll_period_frozen(p_period_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
               WHEN EXISTS (SELECT 1 FROM payroll_periods p WHERE p.id = p_period_id AND p.status = 'posted')
                   THEN 'posted'
               WHEN EXISTS (SELECT 1 FROM payroll_requests r WHERE r.payroll_period_id = p_period_id
                                AND r.status IN ('submitted', 'approved'))
                   THEN 'requested'
               ELSE 'open'
           END
$function$
;

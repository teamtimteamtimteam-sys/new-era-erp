-- db/functions/fiscal_year_end_setting.sql
-- TABLE-FEATURES-2(Tim 2026-10-26 Q5):日期快捷区间「今年」要读【配置的财年年末】,而 11 张带起止日期的列表里有 7 张不在财务模块里
--   (采购单 · 进料 · 产出 · 加工 · 请假 · 库存流水 · 已删除),它们的读者读不到 finance_settings(SELECT 策略只认 module.finance.view)。
--   Tim 的裁定:一支小函数,只回 fy_end_month 与 fy_end_day 两个数,给任何登录用户。
-- 【必须是 definer,且必须留给 authenticated】—— 与 approvals_enabled 同一个形状(读 finance_settings 一列给财务以外的屏幕);
--   吐露的只有财年年末的月与日,那是每一张财务报表抬头上本来就印着的东西。没有可要求的权限码 —— 挂 module.finance.view 就是今天这条路。
--   check_mirrors.py 的 DEFINER_NO_CHECK_ALLOWED 与 verify_rebuild.py 的 DEFINER_UNCHECKED_EXEC_ALLOWED 同改,理由同此。anon 照 zzz_function_grants.sql 收回。
-- 【first_fy_end 不在这里】裁定只给两个数;live first_fy_end 为 NULL(2026-10-26 以 postgres 读),于是今天没有可见的差别 —— 登记见 docs/known-issues.md。
CREATE OR REPLACE FUNCTION public.fiscal_year_end_setting()
 RETURNS TABLE(fy_end_month integer, fy_end_day integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT fs.fy_end_month, fs.fy_end_day FROM finance_settings fs LIMIT 1;
$function$;
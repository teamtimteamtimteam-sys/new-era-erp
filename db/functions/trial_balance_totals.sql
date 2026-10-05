-- db/functions/trial_balance_totals.sql
-- U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):试算平衡表的【按科目合计】—— /finance/trial-balance 从此问这里,不再经 PostgREST 把每一行拉回来自己加。
-- 【为什么必须搬】journal_lines 上那条 restrictive 策略("amounts: …")让不持 data.view_pay 的财务读者(cto · gm)经 API 读不到工资分录的行;
--   页面若照旧逐行求和,那几行会【悄悄】从合计里消失,而试算表仍然"平"(工资分录自己借贷相等)—— 一个不报错、只是小一点的数,
--   正是 AGENTS.md 那一族(xmodule:0.00 与「受限」不是一回事)。属主身份在这里绕过那条策略,于是每一个读者拿到的是同一组合计。
-- 【口径与原来逐字相同】全部行、不按 status 过滤(冲销件与原件一起数,净额才对)—— 页面原来就是 select account_id, debit, credit 全表。
-- 【门】require_permission('module.finance.view') —— 与页面守卫、与 journal_lines 的 permissive 策略同一个码;无权限按名拒,不是 0 行。
CREATE OR REPLACE FUNCTION public.trial_balance_totals()
 RETURNS TABLE(account_id uuid, debits numeric, credits numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT l.account_id, sum(l.debit), sum(l.credit)
      FROM journal_lines l
     GROUP BY l.account_id;
END;
$function$

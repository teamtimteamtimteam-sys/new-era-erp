-- db/functions/bank_book_balance_asof.sql
-- CLEANUP-A(2026-08-31):自带 module.finance.view 判据,无权限返回 NULL 而不是 0.00。
-- 实测 finance −29,753.70 / operations 从前 0.00。判据放在最外层 CASE 而不是 WHERE ——
-- 塞进 WHERE 会让"无权限"重新变成"零行",于是又被 COALESCE(…,0) 变回 0.00。

-- ★ U1-A(Tim 的 UNBLOCK-1 Q2,2026-10-05):改成 SECURITY DEFINER。journal_lines 上那条 restrictive 策略("amounts: …")
--   让不持 data.view_pay 的财务读者(cto · gm)经 RLS 读不到工资分录的行;invoker 时,他在对账页与现金预测上看到的银行账面余额
--   会【悄悄】少掉发薪那几笔 —— 一个不报错、只是不一样的余额。属主身份绕过那条策略;判据仍是外层 CASE 那一句。
CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【判据在最外层,而不是塞进 WHERE】塞进 WHERE 会让"无权限"重新变成
    -- "零行",于是又是 COALESCE(…, 0) → 0.00,原样复发。
    -- 外层 CASE 没有 ELSE:不满足判据时整支函数是 NULL,而不是一个数。
    SELECT CASE WHEN has_permission('module.finance.view'::text) THEN (
        SELECT round(COALESCE(sum(
                   CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END
               ), 0), 2)
        FROM journal_activity_lines(NULL, p_as_of, true) act
        JOIN journal_lines jl ON jl.id = act.line_id
        WHERE act.account_code = p_account_code
          AND jl.currency = bank_native_currency(p_account_code)
    ) END;
$function$;

COMMENT ON FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date) IS
    'CLEANUP-A:某银行科目截至某日的账面原币净额。【自带 module.finance.view 判据,无权限返回 NULL 而不是 0.00】实测:finance 读者得 −29,753.70,operations 读者从前得 0.00 —— 一个不报错、只是更小的数字。NULL 在本支没有主(从前 COALESCE 兜底,产生不出 NULL),所以 NULL 可以用来表达"受限"。★ U1-A(UNBLOCK-1 Q2,2026-10-05)起是 SECURITY DEFINER:journal_lines 上那条 restrictive 策略让不持 data.view_pay 的财务读者经 RLS 读不到工资分录的行,invoker 时他的银行账面余额会悄悄少掉发薪那几笔;属主身份绕过它,每一个读者拿到同一个余额。判据仍是外层那句 module.finance.view(无权限 NULL,不是 0.00)。';

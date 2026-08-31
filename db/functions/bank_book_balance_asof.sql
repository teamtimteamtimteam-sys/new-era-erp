-- db/functions/bank_book_balance_asof.sql
-- CLEANUP-A(2026-08-31):自带 module.finance.view 判据,无权限返回 NULL 而不是 0.00。
-- 实测 finance −29,753.70 / operations 从前 0.00。判据放在最外层 CASE 而不是 WHERE ——
-- 塞进 WHERE 会让"无权限"重新变成"零行",于是又被 COALESCE(…,0) 变回 0.00。

CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
 RETURNS numeric
 LANGUAGE sql
 STABLE
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
    'CLEANUP-A:某银行科目截至某日的账面原币净额。【自带 module.finance.view 判据,无权限返回 NULL 而不是 0.00】实测:finance 读者得 −29,753.70,operations 读者从前得 0.00 —— 一个不报错、只是更小的数字。NULL 在本支没有主(从前 COALESCE 兜底,产生不出 NULL),所以 NULL 可以用来表达"受限"。保持 SECURITY INVOKER:判据与 journal_lines / journal_entries 的 RLS 策略逐字相同,不需要属主权限。';

-- db/functions/bank_account_for_currency.sql
-- 币种 → 该币种的银行科目。【bank_native_currency 的逆,而且是从它推出来的】——
-- 1000/1010 与币种的对应关系仍然只有一份,这里不重抄。
--
-- 【为什么需要它 / OPS-8】这个 CASE 原先在四个地方各抄了一份:
-- record_payment(两处)、record_expense、pay_payroll_lines。lib/currencyMap.ts
-- 的抬头写着"银行账户映射只住在一个文件里",DB 侧本来只有 bank_native_currency
-- 一个方向,于是反方向就被就地重写了四遍 —— 而 check-currency-literals 看不见
-- 单个 SQL 的 =,四份都没人拦。
--
-- 落到未知币种给 '1010',与替换前那句 CASE ... ELSE '1010' 的行为逐字一致。
-- 那个兜底本身是否妥当是另一个问题(一个没有账户的新币种会静静走美元户),
-- OPS-8 只搬家不改行为 —— 要改就单独一切,并且要有 fixture。
--
-- 加银行账户时:本文件、bank_native_currency、lib/currencyMap.ts 三处同改。
--
-- NOTE: introduced by db/migrations/2026-08-07-ops8-currency-is-base.sql.

CREATE OR REPLACE FUNCTION public.bank_account_for_currency(p_currency text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT COALESCE(
        (SELECT a FROM unnest(ARRAY['1000','1010']) a
          WHERE bank_native_currency(a) = p_currency LIMIT 1),
        '1010');
$function$;
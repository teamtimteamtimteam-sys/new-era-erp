-- db/functions/list_totals_bank_transfers.sql
-- TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):/finance/bank 行内转账表的表尾合计 —— 形状与契约见 lib/listTotals.ts 抬头。
-- 【筛选】这张表没有筛选(app/finance/bank/transferRows.ts:31-35 只有排序)。页面只画前 50 笔(TRANSFERS_SHOWN),
--   ★ 合计覆盖【所有】转账,不是那 50 笔(裁定:所有符合筛选的行)。
-- 【两个合计】measure 'out' = amount_out,币种 = bank_native_currency(from_account);'in' = amount_in,币种 = bank_native_currency(to_account)。
--   页面行上的币种取自 bank_reconciliation_status(transferRows.ts:73-87),两者对 1000/1010 是同一个码。
-- 【净额】(Q2)冲销的转账只打 reversed_at 标记,没有镜像行 → 已冲销的【排除】(加 0)。
-- 【门】require_permission('module.finance.view') —— 页面守卫 requireModule(MOD.finance)(bank/page.tsx:44),
--   与 bank_transfers 的 SELECT 策略(bank_transfers.sql:40-42)同一个码。invoker;没有金额被遮,restricted 恒为 false。
CREATE OR REPLACE FUNCTION public.list_totals_bank_transfers()
 RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN QUERY
    SELECT ''::text, x.ccy, x.m, round(sum(x.amt), 2), false
      FROM (SELECT bank_native_currency(b.from_account) AS ccy, 'out'::text AS m, b.amount_out AS amt
              FROM bank_transfers b WHERE b.reversed_at IS NULL
            UNION ALL
            SELECT bank_native_currency(b.to_account), 'in'::text, b.amount_in
              FROM bank_transfers b WHERE b.reversed_at IS NULL) x
     GROUP BY x.ccy, x.m
     ORDER BY x.ccy, x.m DESC;
END;
$function$;
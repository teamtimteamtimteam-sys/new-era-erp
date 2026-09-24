-- db/functions/tax_included_in.sql
-- CLAIM-GST-1(2026-09-24):一笔【已含税】的总额里,税是多少 —— 从总额里【拆出来】,不是加上去。
--
-- 【为什么需要它】员工报销单与医疗申报上的金额是【收据上的总额】,已经含 GST。
-- record_expense 此前把它当【净额】、再在上面加 9%:报 100 的出租车记成欠员工 109
-- (EXP-2026-0007;AP-RECON-1 grilling Q3,Tim CLAIM-GST-1 Q2 裁定)。
--
-- 【取整口径 = IRAS 的税分数】税 = round(总额 × 税率 / (100 + 税率), 2),四舍五入(half up);
-- 净额 = 总额 − 税。于是【净额 + 税 恒等于 总额】,一分不差 —— 员工拿回的就是收据上的数。
-- 9% 时税分数就是 9/109。PostgreSQL 的 numeric round 对正数是 half up。
--
-- 【为什么不是反过来"净 = round(总 / 1.09),税 = tax_amount_for(净)"】那样算,
-- 约 8.3% 的总额【凑不回来】:10.11 → 净 9.28,而 tax_amount_for(9.28) = 0.84,合计 10.12。
-- (实测:0.01 … 2,000.00 之间 9% 有 16,514 个总额写不成 净 + round(净 × 9%)。)
-- 所以这里先定税、净额取差;而读者读的是落库的 expenses.tax_ccy,不再重算
-- (见 db/tables/expenses.sql 的 tax_ccy 列注释)。
--
-- 税率为 0(ZP / EP / OP)时税 = 0、净额 = 总额。
--
-- NOTE: introduced by db/migrations/2026-09-24-claimgst1-a-claim-amount-includes-its-gst.sql.

CREATE OR REPLACE FUNCTION public.tax_included_in(p_gross numeric, p_rate_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT round(p_gross * p_rate_pct / (100.0 + p_rate_pct), 2)
$function$;

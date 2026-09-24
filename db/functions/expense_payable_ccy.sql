-- db/functions/expense_payable_ccy.sql
-- AP-RECON-1(2026-09-24):一张费用单【欠多少】,以单据币种计 = 净额 + 进项税。
--
-- 【为什么需要它】record_expense 挂账时贷 2000【两条腿】:净额 amount_ccy 与
-- 'GST on EXP-…' 那一条税。而未结清单、账龄、付款上限、预付冲抵上限、报销与医疗的
-- "付清了没有"此前全都只认 amount_ccy —— 于是一张带税的账单只能付到净额,那一笔税
-- 在 2000 上永远挂着、没有任何单据看得见它(AP-RECON-0 类别 C,线上 20.70)。
-- Tim AP-RECON-0 Q1:应付额 = 总账 2000 上为这张单记下的全部。
--
-- 【为什么可以精确地【算回来】,而不是存一列】record_expense 的税就是
-- tax_amount_for(p_amount, v_tax_rate),而 amount_ccy = p_amount、tax_rate_pct = v_tax_rate
-- 都原样落库。可抵与否只改借方科目,不改税额。于是这里与过账时是【同一个表达式】,
-- 不是第二份算术。tax_base / fx_rate 反推是有损的,所以不用它。
-- 未注册期与 GST 之前的行 tax_rate_pct 为 NULL → 税为 0 → 净额,与既有口径恒等。
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1a-the-list-carries-what-the-ledger-posted.sql.
CREATE OR REPLACE FUNCTION public.expense_payable_ccy(p_amount_ccy numeric, p_tax_rate_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT round(p_amount_ccy + COALESCE(tax_amount_for(p_amount_ccy, p_tax_rate_pct), 0), 2)
$function$;

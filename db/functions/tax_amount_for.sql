-- db/functions/tax_amount_for.sql
-- PO-GST-1(2026-09-03):一笔金额按一个税率算出税额,并按【两位小数】取整。
--
-- 【它是提取出来的,不是新写的】表达式从 record_expense 逐字符搬来
-- (`round(p_amount * v_tax_rate / 100.0, 2)`),同一行此前还在 create_invoice 与
-- create_order_invoice 里各有一份 —— 三份逐字相同,而它决定钱。
-- 与 TOOLS-1 提取 convert_weight_basis 用的是同一条判据(AGENTS.md 记着本仓库
-- 为"两份实现"付过四次账)。
--
-- 【取整口径,以及它的出处】逐【行】算、逐【行】取整;单据头的税 = Σ 行税,
-- **不是** round(Σ 净额 × 税率)。两种算法差几分,而【对方手里那张纸上印的是行】。
-- 原话在 create_order_invoice.sql:154(「客户手里那张纸上印的是行」),
-- 本函数不改变那条口径,只是把它收成一处 —— 采购单那一侧,那张纸在供应商手里。
--
-- 【为什么取整在这里,而不是留给调用方】"税额怎么取整"就是这个原语要回答的全部
-- 问题。把 round 留在外面,它就退化成一次乘法,而调用方仍然各自决定取整 ——
-- 那正是提取之前的样子。
--
-- NOTE: introduced by db/migrations/2026-09-03-pogst1-a-purchase-order-carries-tax.sql.

CREATE OR REPLACE FUNCTION public.tax_amount_for(p_amount numeric, p_rate_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【与 record_expense:256 / create_order_invoice:161 逐字相同】
    SELECT round(p_amount * p_rate_pct / 100.0, 2)
$function$;

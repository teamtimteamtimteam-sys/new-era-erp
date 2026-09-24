-- db/functions/list_open_base.sql
-- AP-RECON-1 Batch B(2026-09-24):一张单据还开着 p_open(单据币种)时,清单上它显示的本位币。
--
-- 【它就是清单的那个式子,抽出来给【解除】那一侧用】ap_open_items / ar_open_items /
-- order_invoice_balance_all 对一张开着的单据显示的 open_base,逐支都是同一个形状:
--   · 一分都还没结 → 过账时存下的本位币(expenses 的两腿之和、freight / sales 的 amount_base、
--     订单发票净额那一腿)—— 这就是总账为它记下的数;
--   · 结了一部分 → round(剩余 × 入账汇率, 2);
--   · 结清 → 0(它离开清单)。
--
-- 【为什么解除要用它】此前一笔核销解除的本位币是 round(核销额 × 入账汇率, 2)。而清单
-- 显示的是 round(剩余 × 汇率, 2)。round(a×f) + round((G−a)×f) 与 round(G×f) 可以差一分 ——
-- 于是一张外币单据部分结清之后,清单与总账差一分;付清时 2000 / 1100 上留一分
-- (APRECON1-FOREIGN-TAXED-EXPENSE-CENT;fixture 213 B 的那组数:2.47 + 11.04 ≠ 13.50)。
-- 现在:解除额 = list_open_base(之前) − list_open_base(之后)。逐笔相减、逐笔相加,
-- 总账为这张单剩下的,【按构造】就等于清单此刻显示的那个数;付清时恰好归零。
-- 这不是第二份算术:清单与解除读的是同一个式子,这支函数就是它唯一写下来的地方。
--
-- 本位币单据(汇率 1)上三支给出的都是 p_open 本身 —— 老路径逐字节不变。
--
-- NOTE: introduced by db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql.
CREATE OR REPLACE FUNCTION public.list_open_base(p_open numeric, p_value numeric, p_birth_base numeric, p_fx numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_open <= 0 THEN 0::numeric
                WHEN p_open >= p_value THEN p_birth_base
                ELSE round(p_open * p_fx, 2) END
$function$;
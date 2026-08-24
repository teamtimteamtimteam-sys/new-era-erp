-- GST-2 fu:遮蔽伴生视图要把新加的三列一起带上
--
-- 【为什么这是一条规矩,不是一次补丁】invoice_lines_masked 的抬头写着
-- "invoice_lines 的【每一列】都在,敏感列按 has_permission() 置空"。
-- GST-2 给基表加了三列,视图没跟上 —— 于是 GST 页面那句"还没有任何一张单据
-- 带税码"的【测量】压根查不到 tax_code 这一列。而 check-masked-reads 会正确地
-- 要求这类读取走遮蔽视图,两件事一撞,那个测量就只能改成直连基表(绕过遮蔽)
-- 或者干脆不做。**两条都是错的出路** —— 对的出路是让视图跟上基表。
--
-- 【只遮 tax_base 一列】它是钱,与 amount_base / unit_price 同一类。
-- tax_code 不是钱,是这一行【在 GST 上是什么性质】—— 一个分类;
-- tax_rate_pct 是【法定税率】,IRAS 公布在网上,遮它没有任何意义,
-- 而遮掉之后没有 data.view_prices 的人会看到一张"有税码、没税率"的发票,
-- 那比看不到更容易被误读成"这一行没有税"。
--
-- 【必须 CREATE OR REPLACE 且【只在末尾追加】】ar_open_items 与 invoice_status
-- 建在本视图上,DROP 会连它们一起带走(抬头原话)。CREATE OR REPLACE 不允许
-- 改动已有列的名字、类型与顺序,只允许在末尾追加 —— 所以三列排在最后。

BEGIN;

CREATE OR REPLACE VIEW public.invoice_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    invoice_id,
    sales_record_id,
    line_no,
    description,
    quantity,
    unit,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    invoice_voided,
    created_at,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN amount_ccy
            ELSE NULL::numeric
        END AS amount_ccy,
    sales_order_line_id,
    -- ── GST-2 追加的三列(只能追加在末尾,见抬头)──────────────────────────
    tax_code,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_base
            ELSE NULL::numeric
        END AS tax_base
   FROM invoice_lines
  WHERE has_permission('module.finance.view'::text);

COMMIT;

-- INV-1b:amount_ccy 进遮蔽视图 —— 遮蔽表加列必须同时办两件事之一(AGENTS.md)。
-- 它是钱,所以【不进列授权清单】,只经 invoice_lines_masked 读;gate 的 colgrant
-- 行两侧都会盯着。遮蔽条件与 amount_base 完全一致:data.view_prices。
--
-- 【列摆在末尾,不挨着 amount_base】:CREATE OR REPLACE VIEW 只能在末尾追加列;
-- 要插在中间就得 DROP,而 ar_open_items 与 invoice_status 都建在这张视图上,
-- DROP 会连它们一起带走。视图的列序是观感,那两张视图是账 —— 观感让路。
-- NOTE: apply with ./db/apply_migration.sh
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
        END AS amount_ccy
   FROM invoice_lines
  WHERE has_permission('module.finance.view'::text);

COMMIT;

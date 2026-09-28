-- db/views/purchase_order_history_masked.sql
-- HISTORY-1(Tim 的 Q20,2026-09-28):purchase_order_history 的遮蔽伴生视图。
--   每一列都在;采购价格那几列按 data.view_purchase_prices 置空 —— 与 purchase_order_lines_masked /
--   purchase_orders_masked / purchase_order_payment_terms_masked 同一个码、同一个形状。
--   整期付款快照(old/new_payment_term)整份遮:里面有 fixed_amount_ccy。
-- 【属主权限,不是 SECURITY INVOKER】理由与其余 _masked 视图逐字相同(见 purchase_order_payment_terms_masked
--   的抬头):基表的敏感列已收回,invoker 视图会 42501。行谓词原样写回视图体:
--     WHERE has_permission('module.purchasing.view')  —— 与基表那条 SELECT 策略是同一个布尔量。
-- /purchasing/orders/[id] 的编辑史读这张视图。
--
-- NOTE: introduced by db/migrations/2026-09-28-history1-change-log.sql.

CREATE VIEW public.purchase_order_history_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    purchase_order_line_id,
    line_no,
    change_type,
    old_order_date,
    new_order_date,
    old_expected_delivery_date,
    new_expected_delivery_date,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_fx_rate
            ELSE NULL::numeric
        END AS old_fx_rate,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_fx_rate
            ELSE NULL::numeric
        END AS new_fx_rate,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_estimated_total_ccy
            ELSE NULL::numeric
        END AS old_estimated_total_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_estimated_total_ccy
            ELSE NULL::numeric
        END AS new_estimated_total_ccy,
    old_incoterm,
    new_incoterm,
    old_terms_text,
    new_terms_text,
    old_notes,
    new_notes,
    old_quantity,
    new_quantity,
    old_unit,
    new_unit,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_estimated_unit_price
            ELSE NULL::numeric
        END AS old_estimated_unit_price,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_estimated_unit_price
            ELSE NULL::numeric
        END AS new_estimated_unit_price,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_estimated_amount_ccy
            ELSE NULL::numeric
        END AS old_estimated_amount_ccy,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_estimated_amount_ccy
            ELSE NULL::numeric
        END AS new_estimated_amount_ccy,
    amend_reason,
    changed_at,
    changed_by,
    old_delivery_location,
    new_delivery_location,
    old_price_status,
    new_price_status,
    payment_term_seq,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN old_payment_term
            ELSE NULL::jsonb
        END AS old_payment_term,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN new_payment_term
            ELSE NULL::jsonb
        END AS new_payment_term
   FROM purchase_order_history
  WHERE has_permission('module.purchasing.view'::text);

GRANT SELECT ON public.purchase_order_history_masked TO authenticated;

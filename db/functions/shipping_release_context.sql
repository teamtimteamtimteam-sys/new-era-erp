-- db/functions/shipping_release_context.sql
-- APR-5b(2026-09-25,APR-5 grilling Q5 · 5b grilling Q10):CFO 决定一张发货放行时看得见的东西,一次读出。
--
--   · 客户:信用额度、冻结、敞口(customer_ar_exposure_base —— 与开票、直接销售的信用闸同一个数)、余量;
--   · 放行点名的发票:开放余额(order_invoice_open_all.open_base,本位币)与收齐了没有;
--   · 逐行毛利:开票额(发票行 amount_base,本位币)− 这一行预留过的批次的成本
--     (活预留 + 已发货消耗的预留,Σ qty × processing_outputs.unit_cost_base)。
--     ★ 任何一个批次没有成本 → 成本与毛利都是 NULL(屏幕写「未计成本」),【永不】当 0 ——
--       一个 0 成本的毛利是一句关于利润的假话(batch_margin 的同一条理由)。没有预留的行同样 NULL。
--
-- 【门】与 decide_shipping_release 同一对码:module.sales.view + data.view_prices。持这一对码的人
-- (tim@ · Sandra · Choo Er · Phua · Vince · auditor · admin)今天在订单页上本来就看得见这些价格。
-- 属主权限读全量(敞口与开放余额的算子对调用者已收权),在函数体里先按调用者的码把关。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipping_release_context(p_release_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     shipping_releases%ROWTYPE;
    v_order record;
    v_cust  record;
    v_exp   numeric;
BEGIN
    PERFORM require_permission('module.sales.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM shipping_releases WHERE id = p_release_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_FOUND|%', COALESCE(p_release_id::text, '?');
    END IF;
    SELECT id, code, currency, customer_id INTO v_order FROM sales_orders WHERE id = v_r.sales_order_id;
    SELECT id, code, legal_name, credit_limit_base, credit_hold INTO v_cust
      FROM customers WHERE id = v_order.customer_id;
    v_exp := customer_ar_exposure_base(v_cust.id);

    RETURN jsonb_build_object(
        'release_id', v_r.id,
        'label', v_r.label,
        'status', v_r.status,
        'amount_base', v_r.amount_base,
        'order_code', v_order.code,
        'currency', v_order.currency,
        'customer', jsonb_build_object(
            'code', v_cust.code,
            'legal_name', v_cust.legal_name,
            'credit_limit_base', v_cust.credit_limit_base,
            'credit_hold', v_cust.credit_hold,
            'exposure_base', v_exp,
            'headroom_base', CASE WHEN v_cust.credit_limit_base IS NOT NULL
                                  THEN v_cust.credit_limit_base - v_exp END),
        'invoices', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'code', i.code,
                       'status', i.status,
                       'total_base', i.total_base,
                       'open_base', o.open_base,
                       'paid', COALESCE(o.open_base, 0) <= 0) ORDER BY i.code)
              FROM invoices i
              LEFT JOIN order_invoice_open_all o ON o.invoice_id = i.id
             WHERE i.id IN (SELECT il.invoice_id FROM shipping_release_lines rl
                              JOIN invoice_lines il ON il.id = rl.invoice_line_id
                             WHERE rl.release_id = v_r.id)), '[]'::jsonb),
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'line_no', x.line_no,
                       'material_code', x.material_code,
                       'material_name', x.material_name,
                       'quantity', x.quantity,
                       'unit_price', x.unit_price,
                       'invoice_voided', x.invoice_voided,
                       'invoiced_base', x.invoiced_base,
                       'costed', x.costed,
                       'cost_base', CASE WHEN x.costed THEN x.cost_base END,
                       'margin_base', CASE WHEN x.costed THEN x.invoiced_base - x.cost_base END,
                       'margin_pct', CASE WHEN x.costed AND x.invoiced_base <> 0
                                          THEN round((x.invoiced_base - x.cost_base) / x.invoiced_base * 100, 1) END)
                     ORDER BY x.line_no)
              FROM (SELECT sol.line_no, m.code AS material_code, m.name AS material_name,
                           il.quantity, il.unit_price, il.invoice_voided, il.amount_base AS invoiced_base,
                           c.n_res > 0 AND c.n_uncosted = 0 AS costed,
                           c.cost_base
                      FROM shipping_release_lines rl
                      JOIN invoice_lines il ON il.id = rl.invoice_line_id
                      JOIN sales_order_lines sol ON sol.id = rl.sales_order_line_id
                      LEFT JOIN materials m ON m.id = sol.material_id
                      CROSS JOIN LATERAL (
                          SELECT count(*) AS n_res,
                                 count(*) FILTER (WHERE pc.unit_cost_base IS NULL) AS n_uncosted,
                                 round(sum(r.qty * pc.unit_cost_base), 2) AS cost_base
                            FROM sales_order_reservations r
                            LEFT JOIN LATERAL (SELECT po.unit_cost_base FROM processing_outputs po
                                                WHERE po.output_batch_id = r.output_batch_id LIMIT 1) pc ON true
                           WHERE r.sales_order_line_id = sol.id
                             AND r.released_at IS NULL) c
                     WHERE rl.release_id = v_r.id) x), '[]'::jsonb));
END;
$function$
;

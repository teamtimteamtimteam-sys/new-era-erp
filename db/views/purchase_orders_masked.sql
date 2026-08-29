-- db/views/purchase_orders_masked.sql
-- 遮蔽伴生视图:purchase_orders 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:estimated_total_ccy → data.view_prices, fx_rate → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.purchasing.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

CREATE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_by,
    delete_reason,
    cancelled_by,
    -- CONTRACT-1:这张单据挂在哪一份合同之下。**新列加在末尾** ——
    -- CREATE OR REPLACE VIEW 只许末尾追加,中间插一列要 DROP + 重建。
    -- 【它必须出现在这张视图里】purchase_orders 是遮蔽表,而 colgrant 那道闸要求
    -- 它的每一列要么被列授权、要么在 _masked 里(WO-1a 那一课:ADD/GRANT/_masked
    -- 三件事要在同一次迁移里做完 —— KPI-1 为漏掉后两件付过一次账)。
    -- 【条款不从这一列读】它只是导航;条款读 contract_document_terms 那份副本。
    contract_id
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

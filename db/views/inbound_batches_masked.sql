-- db/views/inbound_batches_masked.sql
-- 【PROC-2:多一列 chemistry_certainty_code】遮蔽表加一列是三件事,这是第三件 ——
-- gate 的 colgrant 判据是「一张表一旦有 _masked 伴生,每一列都必须在那张视图里,
-- 授权与否都一样」,所以这一列即便是非敏感的、已经列级授权了,也必须在这里出现。
-- 遮蔽伴生视图:inbound_batches 的每一列都在,敏感列按 has_permission() 置空。
--   遮蔽的列:unit_price → data.view_prices
--
-- 【属主权限,不是 SECURITY INVOKER】。invoker 视图以调用者身份读基表,于是任何
-- 强到能挡住原始列的机制(收紧行策略、或收回列权限)同样会挡住视图本身 —— 实测
-- 分别得到 0 行与 42501。因此这里用属主权限,并【把模块谓词原样加回视图体】:
--     WHERE has_permission('module.inbound.view')
-- cut 2a 的 SELECT 策略恰好就是这同一个布尔量(与行内容无关,整表要么全可见要么
-- 全不可见),所以这与调用者的 RLS 逐行等价 —— 视图【不放宽任何行访问】。
--
-- GRN-1a:declared_qty 追加在末尾。它【不遮蔽】—— 它是一个量,不是价;而它必须
-- 出现在本视图里,因为 colgrant 的规矩是"一张表有了 _masked,它的每一列都得在里面"
-- (WO-1a)。
--
-- NOTE: introduced by db/migrations/2026-08-01-perm2b-field-masking.sql.

-- CMPL-1(2026-08-30)追加四列(imported / import_permit_ref /
-- import_permit_verified_by / import_permit_verified_at)。
-- 【它们是【不敏感】的,所以走列清单 GRANT + 出现在本视图里,不做遮蔽】——
-- 真正敏感的仍然只有 unit_price,按 data.view_prices 透出。
-- 【给遮蔽表加列是三件事一起做】ADD COLUMN + 列清单 GRANT + 本视图;
-- 少任何一件,应用都会"写得进、读不出"(FIN-6 的原样重演),而 gate 的
-- colgrant 判词会在 live 与 rebuild 两侧同时点名。
CREATE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code,
    imported,
    import_permit_ref,
    import_permit_verified_by,
    import_permit_verified_at,
    -- PROC-1B-iii fu1:遮蔽表加一列 = 三件事(列 + 列级授权 + 本视图)。
    -- 【不遮蔽,原样透出】它是工艺路由要用的事实,不是钱、不是个人信息。
    deep_discharge_actual_code
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);;

GRANT SELECT ON public.inbound_batches_masked TO authenticated;

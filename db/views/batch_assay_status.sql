-- db/views/batch_assay_status.sql
-- 每个在册进料批次一行:定价状态、公式、化验汇总(份数、最新一份及其执行状态、
-- 是否有未执行的化验)、关联采购单。驱动批次页化验面板与未来的"待化验"工作清单。
-- 最新一份按 assay_date DESC, created_at DESC, code DESC —— code 作平局裁决
-- (同一事务里 created_at 会相同,编号无缝单调,排序必须确定)。【属主权限】—— 见 OPS-14 note。
-- NOTE: introduced by db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql.

-- cut 2b:本视图改读遮蔽伴生视图(<表>_masked)而非基表 —— 敏感列的遮蔽
-- 因此是继承来的。【OPS-14 起本视图是属主权限,不再是 invoker】,但这一段的结论
-- 未变:遮蔽视图的把关是 has_permission() 谓词,而 has_permission() 按 auth.uid()
-- 解析【调用者】,与谁拥有外层视图无关 —— 所以模块与数据类边界一字未动。
-- 见 db/migrations/2026-08-01-perm2b-field-masking.sql.

-- OPS-14(2026-08-08):改为【属主权限】+ module.inbound.view。
-- 原先 INNER JOIN suppliers / materials:admin 读 10 行,operations 与 warehouse
-- 读【0 行】—— 而他们看得见全部 10 个进料批。/inbound 用本视图渲染"有未执行化验"
-- 的角标,于是这两个角色永远不会被告知。
-- 借来的只有 sup.legal_name 与 m.name 两个【标签】。主数据标签跟着单据走 ——
-- 裁定与边界见迁移文件头。

CREATE VIEW public.batch_assay_status WITH (security_invoker = off) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    sup.legal_name AS supplier_name,
    m.name AS material_name,
    ib.quantity,
    ib.unit,
    ib.unit_price,
    ib.pricing_status,
    ib.pricing_formula_id,
    pf.code AS formula_code,
    COALESCE(a.assay_count, 0::bigint) AS assay_count,
    a.latest_assay_id,
    a.latest_assay_code,
    a.latest_assay_date,
    COALESCE(a.latest_assay_applied, false) AS latest_assay_applied,
    COALESCE(a.has_unapplied_assay, false) AS has_unapplied_assay,
    ib.purchase_order_id,
    po.code AS po_code
   FROM inbound_batches_masked ib
     JOIN suppliers sup ON sup.id = ib.supplier_id
     JOIN materials m ON m.id = ib.material_id
     LEFT JOIN pricing_formulas_masked pf ON pf.id = ib.pricing_formula_id
     LEFT JOIN purchase_orders_masked po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT count(*) AS assay_count,
            bool_or(ar.applied_at IS NULL) AS has_unapplied_assay,
            (array_agg(ar.id ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_id,
            (array_agg(ar.code ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_code,
            (array_agg(ar.assay_date ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_date,
            (array_agg(ar.applied_at IS NOT NULL ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_applied
           FROM assay_results ar
          WHERE ar.inbound_batch_id = ib.id AND ar.deleted_at IS NULL) a ON true
  WHERE ib.deleted_at IS NULL AND has_permission('module.inbound.view'::text);

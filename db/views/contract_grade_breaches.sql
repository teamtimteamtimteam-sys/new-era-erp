-- db/views/contract_grade_breaches.sql
-- CONTRACT-1:哪一批货没达到它那份合同要求的品位 —— **一个发现,不是一道闸**。
--
-- ★★【为什么是报告而不是拒绝,而理由是具体的】★★(Tim 2026-08-29 裁定 A2)
--   化验结果回来的时候,**货已经在场上了**。而这套系统里
--   **没有"质量暂扣"这个状态**(全库 0 张相关表;那是阶段 6 的 G29)。
--   **拒绝一样自己没有地方安放的东西,不是一道控制** ——
--   它只会把一批物理上已经躺在仓库里的货的单据流程堵住,
--   而货还在那儿,只是没人再说得清它的状态。
--   **升成闸的触发条件已经排队:G29 的质量暂扣落地那一天。**
--
-- ★【它比的是【单据当时抄下的那份规格】,不是合同今天的规格】★
--   来源是 contract_document_terms.grade_specs 那个快照 ——
--   一批 8 月收的货,该按 8 月那份合同判,不该按今天改过之后的合同判。
--   这与 FIN-27 的已承诺条款、GST-2 的开票冻结税率是同一条。
--
-- 【非空由构造保证:它只在【三样都在】时才出行】
--   一张挂了合同的采购单、一批挂在那张单上的入库、一份化验。
--   缺任何一样都不出行 —— 而那不是"没有违反",是"没有可比的东西"。
--   **屏幕上那句具名缺席说的就是这件事**(见 /contracts 那一页)。
--
-- 【属主权限】它 join 合同、单据、入库与化验四族,分属不同模块;
-- 谓词写进视图体(OPS-14 的补救 (a))—— 一个 invoker 视图在这里会静静少行。

CREATE VIEW public.contract_grade_breaches WITH (security_invoker = off) AS
 SELECT po.id AS purchase_order_id,
    po.code AS purchase_order_code,
    t.contract_id,
    t.contract_code,
    ib.id AS inbound_batch_id,
    ib.code AS inbound_batch_code,
    a.id AS assay_result_id,
    a.assay_date,
    m.metal,
    m.content_pct,
    (spec.value ->> 'min_pct')::numeric AS min_pct,
    (spec.value ->> 'max_pct')::numeric AS max_pct,
    -- 违反的是哪一边,说出来 —— "低于下限"与"高于上限"的下一步不同
    CASE WHEN (spec.value ->> 'min_pct') IS NOT NULL
              AND m.content_pct < (spec.value ->> 'min_pct')::numeric THEN 'below_min'
         ELSE 'above_max' END AS breach_side
   FROM contract_document_terms t
     JOIN purchase_orders po ON po.id = t.purchase_order_id
     JOIN LATERAL jsonb_array_elements(t.grade_specs) spec ON true
     JOIN inbound_batches ib ON ib.purchase_order_id = po.id AND ib.deleted_at IS NULL
     JOIN assay_results a ON a.inbound_batch_id = ib.id AND a.deleted_at IS NULL
                         AND a.superseded_by IS NULL
     JOIN assay_result_metals m ON m.assay_result_id = a.id
                               AND m.metal = spec.value ->> 'metal'
  WHERE has_permission('module.suppliers.view'::text)
    AND (((spec.value ->> 'min_pct') IS NOT NULL
          AND m.content_pct < (spec.value ->> 'min_pct')::numeric)
      OR ((spec.value ->> 'max_pct') IS NOT NULL
          AND m.content_pct > (spec.value ->> 'max_pct')::numeric));

COMMENT ON VIEW public.contract_grade_breaches IS
    'CONTRACT-1:哪一批货没达到它那份合同要求的品位 —— **一个发现,不是一道闸**(Tim 2026-08-29)。化验回来时**货已经在场上**,而这套系统里没有"质量暂扣"这个状态(阶段 6 的 G29)—— **拒绝一样自己没有地方安放的东西不是控制**,只会把物理上已在仓库的货的单据流程堵住;升成闸的触发条件是 G29 落地。★**它比的是单据当时抄下的那份规格,不是合同今天的规格**★:来源是 contract_document_terms.grade_specs 快照 —— 一批 8 月收的货该按 8 月那份合同判(与 FIN-27、GST-2 同一条)。**非空由构造保证**:只有在「挂了合同的采购单 + 挂在它上面的入库 + 一份未被取代的化验」三样都在时才出行,缺任何一样都不出行 —— 而那不是"没有违反",是"没有可比的东西",屏幕上那句具名缺席说的就是这件事。';

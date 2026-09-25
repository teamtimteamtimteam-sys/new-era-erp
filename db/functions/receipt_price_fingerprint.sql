-- db/functions/receipt_price_fingerprint.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5):一张收货的定价申请【批的是哪一组事实】——
-- 提交时冻结进 receipt_price_requests.snapshot,批准时再算一次比对;不同就按名拒
-- RECEIPT_PRICE_CHANGED_SINCE_REQUEST。
--
-- 里面有:数量、供应商、采购单、采购行、当前单价(本位币)、含量(逐金属:含量、来源、出自哪份化验)、
-- 解析出的承诺副本、最近一份已应用的化验(对化验来源的申请,这就是"它的化验仍是最近一份已应用的")。
-- 【牌价不在里面】(Tim 的 Q4):批准按批准日牌价过账,是裁定,不是"变了"。
-- 【供应商的审批状态不在里面】(Tim 的 Q5)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_fingerprint(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
        'quantity', b.quantity,
        'supplier_id', b.supplier_id,
        'purchase_order_id', b.purchase_order_id,
        'purchase_order_line_id', b.purchase_order_line_id,
        'unit_price', b.unit_price,
        'metals', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                'metal', m.metal, 'content_pct', m.content_pct,
                                'source', m.content_source, 'assay', m.source_assay_id)
                                ORDER BY m.metal)
                              FROM inbound_batch_metals m WHERE m.inbound_batch_id = b.id), '[]'::jsonb),
        'commitment_id', resolve_pricing_commitment(b.id),
        'latest_applied_assay_id', (SELECT a.id FROM assay_results a
                                     WHERE a.inbound_batch_id = b.id AND a.applied_at IS NOT NULL
                                       AND a.deleted_at IS NULL
                                     ORDER BY a.applied_at DESC, a.code DESC LIMIT 1))
      FROM inbound_batches b
     WHERE b.id = p_inbound_batch_id
$function$
;

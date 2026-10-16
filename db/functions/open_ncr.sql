-- db/functions/open_ncr.sql
-- MES-6b-1(2026-10-15,MES-0 Q65 · Q66;MES-6b Step 0 Q2 · Q7 · Q9,Tim):【开一张不合格报告】—— 人开的那一种(manual · customer_complaint);
--   开下来这一批就在质量暂扣里(batch_quality_hold),直到另一个人决定它。module.quality.edit(取样、立争议的同一个码;admin · cco · cto)。
--
--   判的顺序就是人下一步该改什么的顺序:
--     ① 恰好一批(NCR_ONE_BATCH),存在、没删(INBOUND_NOT_FOUND / OUTPUT_NOT_FOUND)。
--     ② 来源:manual · customer_complaint · incident(MES-7b-1,见下)· inspection(MES-7b-2,见下);quality_limit 只由系统开(NCR_SOURCE_SYSTEM_ONLY ——
--        一次 V17 越限由判定当场开,人不替它开);别的 NCR_SOURCE_INVALID|<值>。
--     ③ 描述必填(NCR_DESCRIPTION_REQUIRED)。
--     ④ 可选的指向都必须是同一批的:化验、争议、判定(NCR_LINK_NOT_FOR_BATCH|<种类>|<编号或 id>);销售单只有产出批有
--        (NCR_SALES_ORDER_OUTPUT_ONLY),而且必须是这一批预留过或发过的那几张之一(NCR_LINK_NOT_FOR_BATCH|sales_order|<单号>)。
--     ⑤ ★ 除了开单人这个【人】之外,没有一个真持有人持 action.ncr_decide → 不让它生下来(NCR_NO_OTHER_DECIDER)—— 开单人永远不能决定
--        自己开的那一张,于是没有别人的时候它会是一张永远决定不了、却一直扣着货的报告(配料计划 BLEND_NO_OTHER_RELEASER 同一句判据:
--        real_role_grants · self_leg 按人认,跨账号;不看审批开关)。
--   一批可以同时有几张开着的(Q7)—— 本支不拒"已经有一张开着"。返回 {ncr_id, code, status}。
--   ★ MES-7b-1(2026-10-16,MES-7b Step 0 Q8,Tim):第三种人开的来源 incident —— 事故页上,持 module.quality.edit 的人对一批【链在那件事故上】
--     的货开一张(p_incident_id,末尾带默认的新参数;签名变了,迁移先 DROP 旧的再建,既有的具名调用照旧走得通):
--     来源 incident 而没给事故 → NCR_INCIDENT_REQUIRED;给了事故而来源不是 incident → NCR_INCIDENT_ONLY_WITH_SOURCE;
--     找不到那件事故 → INCIDENT_NOT_FOUND|<id>;那一批此刻没有一条有效链接挂在那件事故上 → NCR_INCIDENT_BATCH_NOT_LINKED|<事故编号>。
--     事故自己从不扣货 —— 扣货的是这一张报告,照既有的质量暂扣,由持 action.ncr_decide 的另一个人决定。
--   ★ MES-7b-2(2026-10-16,MES-7b Step 0 Q15,Tim):来源 inspection 不再保留 —— 它用于【一条说的是一批货的巡检发现】:持 module.quality.edit 的人
--     对那一批开一张,并且必须引用那条发现(末尾带默认的新参数 p_inspection_finding_id;签名又变了,迁移先 DROP 旧的再建):
--     来源 inspection 而没给发现 → NCR_INSPECTION_FINDING_REQUIRED;给了发现而来源不是 inspection → NCR_INSPECTION_FINDING_ONLY_WITH_SOURCE;
--     找不到那条发现 → INSPECTION_FINDING_NOT_FOUND|<id>。质量暂扣照旧,由持 action.ncr_decide 的另一个人决定。
--     收货时的【来料检验】仍然没有建(MES7B1-INCOMING-INSPECTION-UNBUILT)—— 它要自己的记录与入口,不借这个来源。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.open_ncr(p_source text, p_description text, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_assay_result_id uuid DEFAULT NULL::uuid, p_assay_dispute_id uuid DEFAULT NULL::uuid, p_sales_order_id uuid DEFAULT NULL::uuid, p_judgement_id bigint DEFAULT NULL::bigint, p_incident_id uuid DEFAULT NULL::uuid, p_inspection_finding_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_r    jsonb;
BEGIN
    PERFORM require_permission('module.quality.edit');

    -- ① 恰好一批,存在、没删
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'NCR_ONE_BATCH';
    END IF;
    IF p_inbound_batch_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_inbound_batch_id;
    END IF;
    IF p_output_batch_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;

    -- ② 来源
    IF p_source = 'quality_limit' THEN
        RAISE EXCEPTION 'NCR_SOURCE_SYSTEM_ONLY'
          USING HINT = '一次质量验收限的越限由系统在判定那一刻自己开报告 —— 人开的报告选"手动"或"客户投诉"。';
    ELSIF p_source IS NULL OR p_source NOT IN ('manual', 'customer_complaint', 'incident', 'inspection') THEN
        RAISE EXCEPTION 'NCR_SOURCE_INVALID|%', COALESCE(p_source, '?');
    END IF;
    -- ②b 来源 incident ⇔ 指着一件事故,而且那一批链在它上面(MES-7b-1 Q8)
    IF p_source = 'incident' AND p_incident_id IS NULL THEN
        RAISE EXCEPTION 'NCR_INCIDENT_REQUIRED';
    END IF;
    IF p_source <> 'incident' AND p_incident_id IS NOT NULL THEN
        RAISE EXCEPTION 'NCR_INCIDENT_ONLY_WITH_SOURCE';
    END IF;
    IF p_incident_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM incidents WHERE id = p_incident_id) THEN
            RAISE EXCEPTION 'INCIDENT_NOT_FOUND|%', p_incident_id;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM incident_batches b
                        WHERE b.incident_id = p_incident_id AND b.unlinked_at IS NULL
                          AND b.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
                          AND b.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
            RAISE EXCEPTION 'NCR_INCIDENT_BATCH_NOT_LINKED|%', (SELECT code FROM incidents WHERE id = p_incident_id);
        END IF;
    END IF;

    -- ②c 来源 inspection ⇔ 引用一条巡检发现(MES-7b-2 Q15)
    IF p_source = 'inspection' AND p_inspection_finding_id IS NULL THEN
        RAISE EXCEPTION 'NCR_INSPECTION_FINDING_REQUIRED'
          USING HINT = '来源"巡检"的报告必须引用那条巡检发现 —— 从巡检页上那条发现开它。';
    END IF;
    IF p_source <> 'inspection' AND p_inspection_finding_id IS NOT NULL THEN
        RAISE EXCEPTION 'NCR_INSPECTION_FINDING_ONLY_WITH_SOURCE';
    END IF;
    IF p_inspection_finding_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM inspection_findings WHERE id = p_inspection_finding_id) THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_NOT_FOUND|%', p_inspection_finding_id;
    END IF;

    -- ③ 描述必填
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        RAISE EXCEPTION 'NCR_DESCRIPTION_REQUIRED';
    END IF;

    -- ④ 指向都必须是同一批的
    IF p_assay_result_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM assay_results a WHERE a.id = p_assay_result_id AND a.deleted_at IS NULL
           AND a.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
           AND a.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
        RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|assay|%',
            COALESCE((SELECT code FROM assay_results WHERE id = p_assay_result_id), p_assay_result_id::text);
    END IF;
    IF p_assay_dispute_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM assay_disputes d WHERE d.id = p_assay_dispute_id
           AND d.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
           AND d.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
        RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|dispute|%', p_assay_dispute_id;
    END IF;
    IF p_sales_order_id IS NOT NULL THEN
        IF p_output_batch_id IS NULL THEN
            RAISE EXCEPTION 'NCR_SALES_ORDER_OUTPUT_ONLY';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_order_reservations r JOIN sales_order_lines l ON l.id = r.sales_order_line_id
                        WHERE l.sales_order_id = p_sales_order_id AND r.output_batch_id = p_output_batch_id)
           AND NOT EXISTS (SELECT 1 FROM shipment_lines sl JOIN sales_order_lines l ON l.id = sl.sales_order_line_id
                            WHERE l.sales_order_id = p_sales_order_id AND sl.output_batch_id = p_output_batch_id) THEN
            RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|sales_order|%',
                COALESCE((SELECT code FROM sales_orders WHERE id = p_sales_order_id), p_sales_order_id::text);
        END IF;
    END IF;
    IF p_judgement_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM quality_limit_judgements j WHERE j.id = p_judgement_id AND j.output_batch_id = p_output_batch_id) THEN
        RAISE EXCEPTION 'NCR_LINK_NOT_FOR_BATCH|judgement|%', p_judgement_id;
    END IF;

    -- ⑤ 除了开单人之外,要有一个真持有人决定得了它
    IF NOT EXISTS (SELECT 1
                     FROM role_permissions rp
                     JOIN roles r ON r.id = rp.role_id
                    CROSS JOIN LATERAL real_role_grants(r.code) g
                    WHERE rp.permission_code = 'action.ncr_decide'
                      AND self_leg(v_user, NULL::uuid, g.user_id) = 'none') THEN
        RAISE EXCEPTION 'NCR_NO_OTHER_DECIDER'
          USING HINT = '开单人永远不能决定自己开的不合格报告,而此刻除你之外没有人持决定的码(action.ncr_decide)。请管理员先把这个码给另一个人。';
    END IF;

    v_r := ncr_open_internal(p_inbound_batch_id, p_output_batch_id, p_source, p_description,
                             p_assay_result_id, p_assay_dispute_id, p_sales_order_id, p_judgement_id, v_user, p_incident_id,
                             p_inspection_finding_id);
    RETURN v_r || jsonb_build_object('status', 'open');
END;
$function$

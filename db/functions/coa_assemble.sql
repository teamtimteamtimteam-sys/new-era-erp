-- db/functions/coa_assemble.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q10–Q12 · Q31,Tim):【组装一张分析证书纸上的每一个值】—— 签发时冻进快照的就是它(issue_coa 再补上
--   号、签发时刻与签发人);预览读同一份(coa_certificate_data)。PDF 只从这一份渲染,所以纸与档案按构造一致。
--   company       纸头:公司法定名、注册号、地址(company_profile)
--   batch         批号、物料、数量与单位、产出日
--   assay         说话的那一份化验(coa_governing_assay):编号、化验日、实验室、证书号、样品号、出具方、重量基、水分、是否最终、
--                 怎么选出来的(dispute / settling_party / ours)
--   composition   【那一份化验自己的行】(assay_result_metals),按物质字典排序,带物质的角色(惩罚元素在纸上旁边印 ppm)——
--                 ★ 从不读 output_batch_metals(Q11:批次含量是"最后一次应用的那一份",不是说话的那一份)
--   indicators    那一份化验的指标值(assay_result_indicators),带名字与单位;没报的不印
--   chemistry     N38:来料化学确定度(output_batch_chemistry_certainty_all —— 基视图,理由见它的抬头)与它的字典名
--   sales_order   点名了单才有:单号、客户法定名(标签跟着单据走)、合同号与标题、质量验收限的口径、
--                 适用于这批物料的验收限(挂接那一刻抄下的副本 —— 与 judge_quality_limits 同一份、同一个"指名物料的优先")、
--                 这一批对这张单每个参数最近的那一行判定(值、抄下的限、结果、判的是哪一份化验)
--   内层算子:不问码(签发与预览各自问);EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_assemble(p_output_batch_id uuid, p_sales_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch   record;
    v_gov     jsonb;
    v_assay   jsonb;
    v_aid     uuid;
    v_so      jsonb := NULL;
    v_t       record;
BEGIN
    SELECT ob.id, ob.code, ob.quantity, ob.unit, ob.output_date, ob.material_id, m.code AS material_code, m.name AS material_name
      INTO v_batch
      FROM output_batches ob LEFT JOIN materials m ON m.id = ob.material_id
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    v_gov := coa_governing_assay(p_output_batch_id, p_sales_order_id);
    v_aid := (v_gov ->> 'assay_id')::uuid;
    IF v_aid IS NOT NULL THEN
        SELECT jsonb_build_object(
                   'id', a.id, 'code', a.code, 'assay_date', a.assay_date,
                   'lab_code', a.lab_name, 'lab_name', COALESCE(lab.name_en, a.lab_name),
                   'certificate_ref', a.certificate_ref, 'sample_ref', a.sample_ref,
                   'result_party', a.result_party, 'weight_basis', a.weight_basis, 'moisture_pct', a.moisture_pct,
                   'is_final', a.is_final, 'basis', v_gov ->> 'basis', 'dispute_id', v_gov -> 'dispute_id')
          INTO v_assay
          FROM assay_results a LEFT JOIN laboratories lab ON lab.code = a.lab_name
         WHERE a.id = v_aid;
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        SELECT so.code, COALESCE(cu.legal_name, cu.short_name) AS customer_name, t.contract_code, t.contract_title,
               t.settlement_terms
          INTO v_t
          FROM sales_orders so
          LEFT JOIN customers cu ON cu.id = so.customer_id
          LEFT JOIN contract_document_terms t ON t.sales_order_id = so.id
         WHERE so.id = p_sales_order_id;
        v_so := jsonb_build_object(
            'id', p_sales_order_id, 'code', v_t.code, 'customer_name', v_t.customer_name,
            'contract_code', v_t.contract_code, 'contract_title', v_t.contract_title,
            'quality_limit_basis', v_t.settlement_terms ->> 'quality_limit_basis',
            'limits', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'parameter', l.parameter,
                           'name', CASE WHEN l.parameter = 'moisture_pct' THEN 'Moisture' ELSE COALESCE(ai.name_en, l.parameter) END,
                           'unit', CASE WHEN l.parameter = 'moisture_pct' THEN '%' ELSE ai.unit END,
                           'min_value', l.min_value, 'max_value', l.max_value)
                         ORDER BY CASE WHEN l.parameter = 'moisture_pct' THEN 0 ELSE 1 END, ai.sort_order, l.parameter)
                  FROM (SELECT DISTINCT ON (e ->> 'parameter')
                               e ->> 'parameter' AS parameter,
                               (e ->> 'min_value')::numeric AS min_value,
                               (e ->> 'max_value')::numeric AS max_value
                          FROM jsonb_array_elements(COALESCE(v_t.settlement_terms -> 'quality_limits', '[]'::jsonb)) e
                         WHERE (e ->> 'material_id') IS NULL OR (e ->> 'material_id')::uuid = v_batch.material_id
                         ORDER BY e ->> 'parameter', ((e ->> 'material_id') IS NULL)) l
                  LEFT JOIN assay_indicators ai ON ai.code = l.parameter), '[]'::jsonb),
            'judgements', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                           'parameter', j.parameter,
                           'name', CASE WHEN j.parameter = 'moisture_pct' THEN 'Moisture' ELSE COALESCE(ai.name_en, j.parameter) END,
                           'unit', CASE WHEN j.parameter = 'moisture_pct' THEN '%' ELSE ai.unit END,
                           'value', j.value, 'limit_min', j.limit_min_at, 'limit_max', j.limit_max_at, 'result', j.result,
                           'assay_code', a.code, 'judged_at', j.judged_at)
                         ORDER BY CASE WHEN j.parameter = 'moisture_pct' THEN 0 ELSE 1 END, ai.sort_order, j.parameter)
                  FROM (SELECT DISTINCT ON (x.parameter) x.* FROM quality_limit_judgements x
                         WHERE x.output_batch_id = p_output_batch_id AND x.sales_order_id = p_sales_order_id
                         ORDER BY x.parameter, x.id DESC) j
                  JOIN assay_results a ON a.id = j.assay_result_id
                  LEFT JOIN assay_indicators ai ON ai.code = j.parameter), '[]'::jsonb));
    END IF;

    RETURN jsonb_build_object(
        'company', (SELECT jsonb_build_object('legal_name', cp.legal_name, 'registration_no', cp.registration_no,
                                              'address_lines', cp.address_lines, 'city', cp.city, 'postal_code', cp.postal_code,
                                              'country', cp.country)
                      FROM company_profile cp LIMIT 1),
        'batch', jsonb_build_object('id', v_batch.id, 'code', v_batch.code, 'material_code', v_batch.material_code,
                                    'material_name', v_batch.material_name, 'quantity', v_batch.quantity, 'unit', v_batch.unit,
                                    'output_date', v_batch.output_date),
        'assay', v_assay,
        'composition', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('substance', m.metal, 'name', COALESCE(s.name_en, m.metal), 'symbol', s.symbol,
                                                'role', s.role, 'content_pct', m.content_pct)
                             ORDER BY s.sort_order NULLS LAST, m.metal)
              FROM assay_result_metals m LEFT JOIN substances s ON s.code = m.metal
             WHERE m.assay_result_id = v_aid), '[]'::jsonb),
        'indicators', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('code', i.indicator, 'name', COALESCE(ai.name_en, i.indicator), 'unit', ai.unit,
                                                'value', i.value)
                             ORDER BY ai.sort_order NULLS LAST, i.indicator)
              FROM assay_result_indicators i LEFT JOIN assay_indicators ai ON ai.code = i.indicator
             WHERE i.assay_result_id = v_aid), '[]'::jsonb),
        'chemistry', (SELECT jsonb_build_object('certainty', c.certainty,
                                                'certainty_name', CASE WHEN c.certainty = 'not_recorded' THEN 'Not recorded'
                                                                       ELSE COALESCE(d.name_en, c.certainty) END,
                                                'inbound_leaves', c.inbound_leaves, 'leaves_single_known', c.leaves_single_known,
                                                'leaves_mixed', c.leaves_mixed, 'leaves_not_recorded', c.leaves_not_recorded,
                                                'leaves_unknown_pending', c.leaves_unknown_pending)
                        FROM output_batch_chemistry_certainty_all c
                        LEFT JOIN inbound_chemistry_certainties d ON d.code = c.certainty
                       WHERE c.output_batch_id = p_output_batch_id),
        'sales_order', v_so);
END;
$function$

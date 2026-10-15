-- db/functions/judge_quality_limits.sql
-- MES-6b-1(2026-10-15,V17;MES-6b Step 0 Q8 · Q26 · Q27,Tim):【判一批产出批对一张销售单的质量验收限】—— 判出来越限,同一笔事务里开一张
--   来源 quality_limit 的不合格报告(→ 质量暂扣)。【只有这一种事件会自动开报告】(Q6)。
--   两个调用方,都在 DEFINER 里:record_assay_result(记下一份产出化验,而这一批正预留给这张单 —— trigger_event 'assay_recorded')与
--   reserve_stock_internal(把一批已有化验的产出批预留给这张单 —— 'reserved')。
--
--   ① 依据是这张销售单【挂接那一刻抄下的】合同副本(contract_document_terms.settlement_terms):quality_limit_basis 不是 per_parameter
--      (none_agreed、没声明、或这张单没挂合同)→ 什么都不判。合同以后改了不回头判(Q26)。
--   ② 判哪一份化验(与结算选化验同一条规矩):这一批有一件已结案的争议点名了说了算的那一份 → 它(最近结案的那一件);否则合同约定那一方
--      (settling_party)最新的一份没删的结果(化验日、编号)。一份都没有 → 什么都不判。
--   ③ 判哪几个参数:副本里 quality_limits 适用于这批物料的每一个(物料为空的,或就是这种物料的;同一个参数两条都有时取指名物料的那一条)。
--   ④ 每个参数一行判定,限抄进去;同一份化验对同一张单的同一个参数已经判过就跳过(只判一次 —— 部分发货就地重新预留不会再判)。
--      值:水分取化验的 moisture_pct,指标取 assay_result_indicators;没报 → not_measured(不是"在限内",也不开报告)。
--   ⑤ below_min / above_max → ncr_open_internal(系统开的:opened_by 为空,指回化验、销售单与这一行判定)。预留照留(Q27)。
--   ★ 内层算子:不问码;EXECUTE 已从 authenticated 收回。返回 {judged, breaches, ncrs: [编号…]}。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.judge_quality_limits(p_output_batch_id uuid, p_sales_order_id uuid, p_trigger_event text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t        record;
    v_batch    record;
    v_assay    record;
    v_lim      record;
    v_so_code  text;
    v_val      numeric;
    v_res      text;
    v_jid      bigint;
    v_judged   integer := 0;
    v_breaches integer := 0;
    v_ncrs     jsonb := '[]'::jsonb;
    v_ncr      jsonb;
BEGIN
    -- ① 依据:挂接那一刻抄下的副本
    SELECT t.contract_id, t.contract_code, t.settlement_terms INTO v_t
      FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
    IF NOT FOUND OR (v_t.settlement_terms ->> 'quality_limit_basis') IS DISTINCT FROM 'per_parameter' THEN
        RETURN jsonb_build_object('judged', 0, 'breaches', 0, 'ncrs', '[]'::jsonb);
    END IF;
    SELECT ob.id, ob.code, ob.material_id INTO v_batch
      FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('judged', 0, 'breaches', 0, 'ncrs', '[]'::jsonb);
    END IF;

    -- ② 判哪一份化验:已结案争议点名的那一份,否则约定那一方最新的一份
    SELECT a.id, a.code, a.moisture_pct INTO v_assay
      FROM assay_disputes d
      JOIN assay_results a ON a.id = d.governing_assay_id AND a.deleted_at IS NULL
     WHERE d.output_batch_id = p_output_batch_id AND d.status = 'resolved'
     ORDER BY d.resolved_at DESC
     LIMIT 1;
    IF NOT FOUND THEN
        SELECT a.id, a.code, a.moisture_pct INTO v_assay
          FROM assay_results a
         WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL
           AND a.result_party = (v_t.settlement_terms ->> 'settling_party')
         ORDER BY a.assay_date DESC, a.code DESC
         LIMIT 1;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('judged', 0, 'breaches', 0, 'ncrs', '[]'::jsonb);
        END IF;
    END IF;
    SELECT so.code INTO v_so_code FROM sales_orders so WHERE so.id = p_sales_order_id;

    -- ③ ④ ⑤ 每一个适用的参数一行
    FOR v_lim IN
        SELECT DISTINCT ON (e ->> 'parameter')
               e ->> 'parameter' AS parameter,
               (e ->> 'min_value')::numeric AS min_value,
               (e ->> 'max_value')::numeric AS max_value
          FROM jsonb_array_elements(COALESCE(v_t.settlement_terms -> 'quality_limits', '[]'::jsonb)) e
         WHERE (e ->> 'material_id') IS NULL OR (e ->> 'material_id')::uuid = v_batch.material_id
         ORDER BY e ->> 'parameter', ((e ->> 'material_id') IS NULL)
    LOOP
        IF EXISTS (SELECT 1 FROM quality_limit_judgements j
                    WHERE j.output_batch_id = p_output_batch_id AND j.sales_order_id = p_sales_order_id
                      AND j.assay_result_id = v_assay.id AND j.parameter = v_lim.parameter) THEN
            CONTINUE;
        END IF;
        v_val := CASE WHEN v_lim.parameter = 'moisture_pct' THEN v_assay.moisture_pct
                      ELSE (SELECT i.value FROM assay_result_indicators i
                             WHERE i.assay_result_id = v_assay.id AND i.indicator = v_lim.parameter) END;
        v_res := CASE WHEN v_val IS NULL THEN 'not_measured'
                      WHEN v_lim.min_value IS NOT NULL AND v_val < v_lim.min_value THEN 'below_min'
                      WHEN v_lim.max_value IS NOT NULL AND v_val > v_lim.max_value THEN 'above_max'
                      ELSE 'within' END;
        INSERT INTO quality_limit_judgements (output_batch_id, sales_order_id, contract_id, assay_result_id, parameter,
                                              value, limit_min_at, limit_max_at, result, trigger_event)
        VALUES (p_output_batch_id, p_sales_order_id, v_t.contract_id, v_assay.id, v_lim.parameter,
                v_val, v_lim.min_value, v_lim.max_value, v_res, p_trigger_event)
        RETURNING id INTO v_jid;
        v_judged := v_judged + 1;

        IF v_res IN ('below_min', 'above_max') THEN
            v_breaches := v_breaches + 1;
            v_ncr := ncr_open_internal(
                NULL::uuid, p_output_batch_id, 'quality_limit',
                format('Quality limit breached: %s %s is %s (limit min %s, max %s) under contract %s, sales order %s, assay %s.',
                       v_batch.code,
                       CASE WHEN v_lim.parameter = 'moisture_pct' THEN 'moisture (%)'
                            ELSE COALESCE((SELECT ai.name_en || ' (' || ai.unit || ')' FROM assay_indicators ai WHERE ai.code = v_lim.parameter), v_lim.parameter) END,
                       v_val,
                       COALESCE(v_lim.min_value::text, '-'), COALESCE(v_lim.max_value::text, '-'),
                       v_t.contract_code, COALESCE(v_so_code, '?'), v_assay.code),
                v_assay.id, NULL::uuid, p_sales_order_id, v_jid, NULL::uuid);
            v_ncrs := v_ncrs || jsonb_build_array(v_ncr ->> 'code');
        END IF;
    END LOOP;

    RETURN jsonb_build_object('judged', v_judged, 'breaches', v_breaches, 'ncrs', v_ncrs);
END;
$function$

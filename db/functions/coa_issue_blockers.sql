-- db/functions/coa_issue_blockers.sql
-- MES-6b-2(2026-10-15,MES-0 Q68 · MES-6b Step 0 Q10 · Q29,Tim):【这一批(× 这张单)此刻为什么签发不了一张分析证书】—— 一份判据,两个读它的:
--   issue_coa 拒第一句;批次页的证书一块把每一句都摆出来(经 coa_certificate_data)。按次序,每一句都是一句具名的拒绝:
--     COA_SALES_ORDER_NOT_FOR_BATCH|<单号>|<批号>   点名的单不是预留过或发过这一批的那几张之一(与 open_ncr 同一个判法)
--     COA_ALREADY_ISSUED|<号>                       这一批 × 这张单(或不点名)已经有一张活的证书 —— 先经 CFO 作废它
--     QUALITY_HOLD_OPEN|<批号>|<报告>               这一批在质量暂扣里(判据 batch_quality_hold 一支)
--     ASSAY_DISPUTE_OPEN|<批号>|<争议>              这一批挂着一件开着的化验争议
--     COA_NO_FINAL_ASSAY|<批号>|<化验号或 ->        没有说话的那一份化验,或它不是最终结果(coa_governing_assay)
--     READING_INSTRUMENT_NOT_CALIBRATED|…  /  COA_OUTPUT_WEIGHING_NOT_RECORDED|…  /  COA_OUTPUT_READING_NOT_RECORDED|…
--                                                   一条产出腿的称重不在校准期内(缺席由 require_calibrated_since 管)
--     COA_LIMIT_BREACHED|<批号>|<单号>|<参数>       点名的单:这一批对那张单的 V17 判定(每个参数最近的那一行)越限,
--                                                   而为那一行开的报告没有以 accept / accept_with_penalty 决定
--     COMPANY_LEGAL_NAME_MISSING|/finance/company   纸头上的公司名还没录
--   签发人那两句(不是员工、没有职位)不在这里 —— 它们说的是按按钮的那个人,不是这一批;由 issue_coa 自己问。
--   内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_issue_blockers(p_output_batch_id uuid, p_sales_order_id uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_out   text[] := '{}'::text[];
    v_code  text;
    v_so    text;
    v_live  text;
    v_hold  record;
    v_disp  uuid;
    v_gov   jsonb;
    v_final boolean;
    v_acode text;
    v_cal   text;
    v_j     record;
BEGIN
    SELECT b.code INTO v_code FROM output_batches b WHERE b.id = p_output_batch_id AND b.deleted_at IS NULL;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        SELECT so.code INTO v_so FROM sales_orders so WHERE so.id = p_sales_order_id;
        IF NOT EXISTS (SELECT 1 FROM sales_order_reservations r JOIN sales_order_lines l ON l.id = r.sales_order_line_id
                        WHERE l.sales_order_id = p_sales_order_id AND r.output_batch_id = p_output_batch_id)
           AND NOT EXISTS (SELECT 1 FROM shipment_lines sl JOIN sales_order_lines l ON l.id = sl.sales_order_line_id
                            WHERE l.sales_order_id = p_sales_order_id AND sl.output_batch_id = p_output_batch_id) THEN
            v_out := v_out || format('COA_SALES_ORDER_NOT_FOR_BATCH|%s|%s', COALESCE(v_so, p_sales_order_id::text), v_code);
        END IF;
    END IF;

    SELECT c.code INTO v_live FROM certificates_of_analysis c
     WHERE c.output_batch_id = p_output_batch_id AND c.sales_order_id IS NOT DISTINCT FROM p_sales_order_id
       AND c.status <> 'void';
    IF v_live IS NOT NULL THEN
        v_out := v_out || format('COA_ALREADY_ISSUED|%s', v_live);
    END IF;

    SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(NULL::uuid, p_output_batch_id) h;
    IF FOUND THEN
        v_out := v_out || format('QUALITY_HOLD_OPEN|%s|%s', v_code, v_hold.ncr_code);
    END IF;

    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.output_batch_id = p_output_batch_id AND d.status = 'open' LIMIT 1;
    IF v_disp IS NOT NULL THEN
        v_out := v_out || format('ASSAY_DISPUTE_OPEN|%s|%s', v_code, v_disp);
    END IF;

    v_gov := coa_governing_assay(p_output_batch_id, p_sales_order_id);
    SELECT a.is_final, a.code INTO v_final, v_acode FROM assay_results a WHERE a.id = (v_gov ->> 'assay_id')::uuid;
    IF v_acode IS NULL OR NOT v_final THEN
        v_out := v_out || format('COA_NO_FINAL_ASSAY|%s|%s', v_code, COALESCE(v_acode, '-'));
    END IF;

    v_cal := coa_output_calibration_problem(p_output_batch_id);
    IF v_cal IS NOT NULL THEN
        v_out := v_out || v_cal;
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        FOR v_j IN SELECT DISTINCT ON (j.parameter) j.id, j.parameter, j.result
                     FROM quality_limit_judgements j
                    WHERE j.output_batch_id = p_output_batch_id AND j.sales_order_id = p_sales_order_id
                    ORDER BY j.parameter, j.id DESC LOOP
            IF v_j.result IN ('below_min', 'above_max')
               AND NOT EXISTS (SELECT 1 FROM nonconformance_reports n
                                WHERE n.judgement_id = v_j.id AND n.status = 'decided'
                                  AND n.disposition IN ('accept', 'accept_with_penalty')) THEN
                v_out := v_out || format('COA_LIMIT_BREACHED|%s|%s|%s', v_code, COALESCE(v_so, p_sales_order_id::text), v_j.parameter);
            END IF;
        END LOOP;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM company_profile cp WHERE btrim(COALESCE(cp.legal_name, '')) <> '') THEN
        v_out := v_out || 'COMPANY_LEGAL_NAME_MISSING|/finance/company'::text;
    END IF;

    RETURN v_out;
END;
$function$

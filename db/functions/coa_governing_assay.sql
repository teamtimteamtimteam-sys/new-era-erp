-- db/functions/coa_governing_assay.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q11,Tim):【一张分析证书说话的那一份化验】—— 一份判据,三个读它的:签发(issue_coa)、
--   预览(coa_certificate_data)、拒绝清单(coa_issue_blockers)。返回 {assay_id, basis, dispute_id};一份都没有 → assay_id 为空。
--   ① 这一批有一件已结案的争议 → 它点名的那一份(最近结案的那一件;与 judge_quality_limits、结算同一个选法)—— basis 'dispute';
--   ② 否则点名了销售单 → 那张单挂接那一刻抄下的合同副本里约定那一方(settling_party)最新一份没删的结果 —— basis 'settling_party';
--      单没挂合同、或副本里没说哪一方 → 落到 ③;
--   ③ 否则我们(ours)最新一份没删的结果 —— basis 'ours'。
--   "最新"= 化验日、再按编号(与 judge_quality_limits 同一个排序)。【它不看 is_final】—— 那是拒绝清单的事(COA_NO_FINAL_ASSAY):
--   说话的那一份必须是最终结果,而不是"最新的一份最终结果"(一份更新的初步结果在场时,证书不越过它去说一份旧的)。
--   【从不读 output_batch_metals】—— 选的是一份化验,纸上的成分读它自己的行。
--   内层算子:不问码;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_governing_assay(p_output_batch_id uuid, p_sales_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id    uuid;
    v_disp  uuid;
    v_party text;
    v_basis text;
BEGIN
    SELECT a.id, d.id INTO v_id, v_disp
      FROM assay_disputes d
      JOIN assay_results a ON a.id = d.governing_assay_id AND a.deleted_at IS NULL
     WHERE d.output_batch_id = p_output_batch_id AND d.status = 'resolved'
     ORDER BY d.resolved_at DESC
     LIMIT 1;
    IF v_id IS NOT NULL THEN
        RETURN jsonb_build_object('assay_id', v_id, 'basis', 'dispute', 'dispute_id', v_disp);
    END IF;

    IF p_sales_order_id IS NOT NULL THEN
        SELECT NULLIF(t.settlement_terms ->> 'settling_party', '') INTO v_party
          FROM contract_document_terms t WHERE t.sales_order_id = p_sales_order_id;
    END IF;
    v_basis := CASE WHEN v_party IS NOT NULL THEN 'settling_party' ELSE 'ours' END;
    v_party := COALESCE(v_party, 'ours');

    SELECT a.id INTO v_id
      FROM assay_results a
     WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL AND a.result_party = v_party
     ORDER BY a.assay_date DESC, a.code DESC
     LIMIT 1;
    RETURN jsonb_build_object('assay_id', v_id, 'basis', v_basis, 'party', v_party, 'dispute_id', NULL);
END;
$function$

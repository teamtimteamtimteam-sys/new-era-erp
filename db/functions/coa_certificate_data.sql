-- db/functions/coa_certificate_data.sql
-- MES-6b-2(2026-10-15,MES-6b Step 0 Q10 · Q11 · Q29,Tim):【一张分析证书此刻会是什么样子,以及为什么还签发不了】—— 批次页的证书一块与
--   PDF 路由的预览读它。返回 coa_assemble 的那一份(与签发时冻进快照的同一支组装)外加 blockers(coa_issue_blockers 的每一句,按次序;
--   空数组 = 这一批此刻签发得了)。它【不铸号、不落库、不留任何东西】。
--   门:module.output.view —— 与证书表与产出批的读策略同一个码(看证书跟着那一批的查看码,Q30)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_certificate_data(p_output_batch_id uuid, p_sales_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.output.view');
    RETURN coa_assemble(p_output_batch_id, p_sales_order_id)
        || jsonb_build_object('blockers', to_jsonb(coa_issue_blockers(p_output_batch_id, p_sales_order_id)),
                              'certificate', NULL::jsonb, 'issuer', NULL::jsonb);
END;
$function$

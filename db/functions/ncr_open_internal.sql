-- db/functions/ncr_open_internal.sql
-- MES-6b-1(2026-10-15,MES-6b Step 0 Q7):落一张不合格报告 —— 取号、写一行 open。两个调用方各自先把关:
--   open_ncr(人开的:module.quality.edit、来源、描述、指向是不是同一批、除了开单人还有没有人能决定)与
--   judge_quality_limits(系统开的:一次 V17 越限,opened_by 为空)。
--   ★ 内层算子:不问码、不判来源;EXECUTE 已从 authenticated 收回(zzz_function_grants)。返回 {ncr_id, code}。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.ncr_open_internal(p_inbound_batch_id uuid, p_output_batch_id uuid, p_source text, p_description text, p_assay_result_id uuid, p_assay_dispute_id uuid, p_sales_order_id uuid, p_judgement_id bigint, p_opened_by uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid := gen_random_uuid();
    v_code text;
BEGIN
    v_code := next_ncr_code(CURRENT_DATE);
    INSERT INTO nonconformance_reports (id, code, inbound_batch_id, output_batch_id, source, description,
                                        assay_result_id, assay_dispute_id, sales_order_id, judgement_id, opened_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_source, btrim(p_description),
            p_assay_result_id, p_assay_dispute_id, p_sales_order_id, p_judgement_id, p_opened_by);
    RETURN jsonb_build_object('ncr_id', v_id, 'code', v_code);
END;
$function$

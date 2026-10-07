-- db/functions/correct_contamination_check.sql
-- MES-4b(2026-10-07,规格 §4.2;MES-4b Step 0 Q21,Tim):【更正一次交叉污染抽检】—— 不改原行,落一条新的指回它,理由必填。
--   码:action.processing_aftercare。加工单与流照抄原行;种类可以改(抽了 ↔ 没抽);判据与记一条新的完全同一份(contamination_check_internal)。
--   拒:找不到(CONTAMINATION_CHECK_NOT_FOUND)· 已被更正过(CONTAMINATION_CHECK_SUPERSEDED|<id> —— 只能更正链的末端)·
--   理由空(CONTAMINATION_CORRECTION_REASON_REQUIRED)。警戒线照【此刻】的值抄下。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.correct_contamination_check(p_check_id bigint, p_kind text, p_output_batch_id uuid, p_sample_mass_g numeric, p_foreign_mass_g numeric, p_sampled_at timestamp with time zone, p_method text, p_not_sampled_reason text, p_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig contamination_checks%ROWTYPE;
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    SELECT * INTO v_orig FROM contamination_checks WHERE id = p_check_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTAMINATION_CHECK_NOT_FOUND|%', p_check_id;
    END IF;
    IF EXISTS (SELECT 1 FROM contamination_checks x WHERE x.corrects_id = v_orig.id) THEN
        RAISE EXCEPTION 'CONTAMINATION_CHECK_SUPERSEDED|%', v_orig.id;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CONTAMINATION_CORRECTION_REASON_REQUIRED';
    END IF;
    RETURN contamination_check_internal(v_orig.run_id, v_orig.stream_code, p_kind, p_output_batch_id, p_sample_mass_g, p_foreign_mass_g,
                                        p_sampled_at, p_method, p_not_sampled_reason, v_orig.id, p_reason);
END;
$function$
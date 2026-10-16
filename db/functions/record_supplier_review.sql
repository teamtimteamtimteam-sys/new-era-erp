-- db/functions/record_supplier_review.sql
-- MES-8a(2026-10-16,MES-0 Q77 · Q78 · MES-8 Step 0 Q2 · Q4 · Q6,Tim):【记一次供应商评审】—— 门 action.supplier_review(cco · admin)。
--   窗口由评审人输入(必填,SCORECARD_WINDOW_* 由计数那一支按名拒);这一刻的计数、V23 权重与等级线、V24 上限与抽样【整份抄进评审】,
--   连同由它们算出的分与等级(supplier_scorecard_preview —— 与评审表单显示的是同一份)。V23 没给 → 等级空,not_graded_reason V23_NOT_SET。
--   更正(Q2):p_corrects_review_id 指一次【同一家】的评审(SUPPLIER_REVIEW_NOT_FOUND|<id> · SUPPLIER_REVIEW_OTHER_SUPPLIER),
--   必须写理由(SUPPLIER_REVIEW_CORRECTION_REASON_REQUIRED);一次评审只更正一次(SUPPLIER_REVIEW_ALREADY_CORRECTED|<id> —— 要再改,
--   更正那一次更正);有理由没引用按名拒(SUPPLIER_REVIEW_REASON_WITHOUT_CORRECTION)。被更正的那一次一个字不动。
--   任何一家没删的供应商都可以评(不只是批准过 / 在用的 —— 一家被暂停的更该被评);提醒 supplier_review_due 只列批准过 / 在用的进货供应商。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.record_supplier_review(p_supplier_id uuid, p_from date, p_to date, p_note text DEFAULT NULL::text, p_corrects_review_id uuid DEFAULT NULL::uuid, p_correction_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p      jsonb;
    v_old    supplier_scorecard_reviews%ROWTYPE;
    v_reason text := NULLIF(btrim(COALESCE(p_correction_reason, '')), '');
    v_id     uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('action.supplier_review');

    IF p_corrects_review_id IS NOT NULL THEN
        SELECT * INTO v_old FROM supplier_scorecard_reviews WHERE id = p_corrects_review_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SUPPLIER_REVIEW_NOT_FOUND|%', p_corrects_review_id;
        END IF;
        IF v_old.supplier_id IS DISTINCT FROM p_supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_REVIEW_OTHER_SUPPLIER';
        END IF;
        IF EXISTS (SELECT 1 FROM supplier_scorecard_reviews c WHERE c.corrects_review_id = p_corrects_review_id) THEN
            RAISE EXCEPTION 'SUPPLIER_REVIEW_ALREADY_CORRECTED|%', p_corrects_review_id;
        END IF;
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'SUPPLIER_REVIEW_CORRECTION_REASON_REQUIRED';
        END IF;
    ELSIF v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REVIEW_REASON_WITHOUT_CORRECTION';
    END IF;

    v_p := supplier_scorecard_preview(p_supplier_id, p_from, p_to);

    INSERT INTO supplier_scorecard_reviews
        (id, supplier_id, window_from, window_to, measures, weights, grade_lines, grade_caps, score, grade, not_graded_reason,
         note, corrects_review_id, correction_reason, recorded_by)
    VALUES (v_id, p_supplier_id, p_from, p_to, v_p -> 'measures',
            CASE WHEN v_p ->> 'grade' IS NOT NULL THEN v_p -> 'weights' END,
            CASE WHEN v_p ->> 'grade' IS NOT NULL THEN v_p -> 'grade_lines' END,
            NULLIF(v_p -> 'grade_caps', 'null'::jsonb),
            (v_p ->> 'score')::numeric, v_p ->> 'grade', v_p ->> 'not_graded_reason',
            NULLIF(btrim(COALESCE(p_note, '')), ''), p_corrects_review_id, v_reason, auth.uid());

    RETURN jsonb_build_object('review_id', v_id, 'grade', v_p -> 'grade', 'score', v_p -> 'score',
                              'not_graded_reason', v_p -> 'not_graded_reason', 'corrects_review_id', p_corrects_review_id);
END;
$function$

-- db/functions/contamination_check_internal.sql
-- MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q23,Tim):【一次交叉污染抽检的判据与落库】—— 记与更正共用这一份,判据只写一遍。
--   内层:不是 DEFINER,authenticated 调不到(只经 record_contamination_check / correct_contamination_check)。
--   拒(按这个先后):
--     RUN_NOT_COMMITTED|<单>                          加工单没提交或已回滚
--     CONTAMINATION_RUN_PREDATES_RECORD|<单>          MES-4a 之前记的单 —— 没有班次,抽检挂不上一个班
--     CONTAMINATION_STREAM_UNKNOWN|<流>               不认识或已停用的流
--     CONTAMINATION_RUN_HAS_NO_SHEET|<单>|<流>        这一炉没有产出这条流的极片(没抽、没抽都无从谈起)
--     CONTAMINATION_KIND_UNKNOWN|<种类>
--     CONTAMINATION_FIELDS_MIXED|<种类>               抽了却带着"没抽的理由",或没抽却带着质量 / 批次 / 时刻
--     抽了:CONTAMINATION_BATCH_NOT_SHEET_OF_RUN|<批>(抽的那一批不是这一炉这条流的一条极片产出腿)·
--           CONTAMINATION_MASS_INVALID|<样品>|<外来物>(样品 > 0、0 ≤ 外来物 ≤ 样品,克)· CONTAMINATION_SAMPLED_AT_REQUIRED
--     没抽:CONTAMINATION_REASON_REQUIRED
--   警戒线(V11)此刻的值抄进 warning_pct_at;超过只标出来(生成列 above_warning),从不拒。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4b-fields-and-products.sql.

CREATE OR REPLACE FUNCTION public.contamination_check_internal(p_run_id uuid, p_stream_code text, p_kind text, p_output_batch_id uuid, p_sample_mass_g numeric, p_foreign_mass_g numeric, p_sampled_at timestamp with time zone, p_method text, p_not_sampled_reason text, p_corrects_id bigint, p_correction_reason text)
 RETURNS bigint
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_run    processing_runs%ROWTYPE;
    v_stream contamination_streams%ROWTYPE;
    v_batch  text;
    v_id     bigint;
BEGIN
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id;
    IF NOT FOUND OR v_run.status <> 'committed' OR v_run.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', COALESCE(v_run.code, p_run_id::text);
    END IF;
    IF v_run.started_at IS NULL OR v_run.shift_code IS NULL THEN
        RAISE EXCEPTION 'CONTAMINATION_RUN_PREDATES_RECORD|%', v_run.code
          USING HINT = '这一张是 MES-4a 之前记的,没有班次 —— 抽检按班挂,挂不上。';
    END IF;
    SELECT * INTO v_stream FROM contamination_streams WHERE code = p_stream_code AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTAMINATION_STREAM_UNKNOWN|%', COALESCE(p_stream_code, '?');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
                     JOIN materials m ON m.id = ob.material_id
                    WHERE po.run_id = p_run_id AND m.form_code = v_stream.sheet_form_code) THEN
        RAISE EXCEPTION 'CONTAMINATION_RUN_HAS_NO_SHEET|%|%', v_run.code, v_stream.code;
    END IF;

    IF p_kind = 'sampled' THEN
        IF NULLIF(btrim(COALESCE(p_not_sampled_reason, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_FIELDS_MIXED|sampled';
        END IF;
        SELECT ob.code INTO v_batch
          FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id
          JOIN materials m ON m.id = ob.material_id
         WHERE po.run_id = p_run_id AND po.output_batch_id = p_output_batch_id AND m.form_code = v_stream.sheet_form_code;
        IF v_batch IS NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_BATCH_NOT_SHEET_OF_RUN|%',
                COALESCE((SELECT ob.code FROM output_batches ob WHERE ob.id = p_output_batch_id), COALESCE(p_output_batch_id::text, '?'));
        END IF;
        IF p_sample_mass_g IS NULL OR p_sample_mass_g <= 0 OR p_foreign_mass_g IS NULL OR p_foreign_mass_g < 0
           OR p_foreign_mass_g > p_sample_mass_g THEN
            RAISE EXCEPTION 'CONTAMINATION_MASS_INVALID|%|%', COALESCE(p_sample_mass_g::text, '?'), COALESCE(p_foreign_mass_g::text, '?');
        END IF;
        IF p_sampled_at IS NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_SAMPLED_AT_REQUIRED';
        END IF;
    ELSIF p_kind = 'not_sampled' THEN
        IF p_output_batch_id IS NOT NULL OR p_sample_mass_g IS NOT NULL OR p_foreign_mass_g IS NOT NULL OR p_sampled_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_FIELDS_MIXED|not_sampled';
        END IF;
        IF NULLIF(btrim(COALESCE(p_not_sampled_reason, '')), '') IS NULL THEN
            RAISE EXCEPTION 'CONTAMINATION_REASON_REQUIRED';
        END IF;
    ELSE
        RAISE EXCEPTION 'CONTAMINATION_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    INSERT INTO contamination_checks (run_id, stream_code, kind, output_batch_id, sample_mass_g, foreign_mass_g, warning_pct_at,
                                      sampled_at, method, not_sampled_reason, corrects_id, correction_reason)
    VALUES (p_run_id, v_stream.code, p_kind,
            CASE WHEN p_kind = 'sampled' THEN p_output_batch_id END,
            CASE WHEN p_kind = 'sampled' THEN p_sample_mass_g END,
            CASE WHEN p_kind = 'sampled' THEN p_foreign_mass_g END,
            v_stream.warning_pct,
            CASE WHEN p_kind = 'sampled' THEN p_sampled_at END,
            NULLIF(btrim(COALESCE(p_method, '')), ''),
            CASE WHEN p_kind = 'not_sampled' THEN btrim(p_not_sampled_reason) END,
            p_corrects_id, NULLIF(btrim(COALESCE(p_correction_reason, '')), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$
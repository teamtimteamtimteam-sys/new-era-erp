-- db/functions/coa_output_calibration_problem.sql
-- MES-6b-2(2026-10-15,MES-0 Q68 · MES-6b Step 0 Q29,Tim):【一批产出批的称重有没有不在校准期内的】—— 分析证书说的数量是这批产出的过磅数,
--   所以它的读数要过 MES-2 的同一支判据(weighing_calibration_all,与加工提交、收货证书同一份)。返回第一句拒绝;没有问题 → NULL。
--   · 一条产出腿(processing_outputs,所在的加工单没被冲销)挂着的那一次称重,仪器在读数那一天【已知】不在校准期内 → 永远拒
--     READING_INSTRUMENT_NOT_CALIBRATED|<仪器>|<日期>(与 commit_processing_run 逐字同一句);
--   · 缺席由 require_calibrated_since 管(线上今天是空):称重没有记仪器 → COA_OUTPUT_WEIGHING_NOT_RECORDED|<加工单>|<批号>;
--     这一批一条称过的产出腿都没有(MES-4a 之前的单、手工建的产出批)→ COA_OUTPUT_READING_NOT_RECORDED|<批号>。
--     开关给了、而且那一炉的加工日(没有腿时:产出日)在它之后才拒 —— 开关空着时只有"已知不在校准期内"会拒。
--   内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.coa_output_calibration_problem(p_output_batch_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_since date;
    v_code  text;
    v_date  date;
    v_n     integer := 0;
    r       record;
BEGIN
    SELECT s.require_calibrated_since INTO v_since FROM ingest_settings s WHERE s.id;
    SELECT b.code, b.output_date INTO v_code, v_date FROM output_batches b WHERE b.id = p_output_batch_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    FOR r IN SELECT pr.code AS run_code, pr.process_date, wc.device_code, wc.captured_on, wc.status
               FROM processing_outputs po
               JOIN processing_runs pr ON pr.id = po.run_id AND pr.deleted_at IS NULL
               JOIN weighing_calibration_all wc ON wc.weighing_id = po.weighing_id
              WHERE po.output_batch_id = p_output_batch_id
              ORDER BY pr.code LOOP
        v_n := v_n + 1;
        IF r.status = 'not_recorded' THEN
            IF v_since IS NOT NULL AND r.process_date >= v_since THEN
                RETURN format('COA_OUTPUT_WEIGHING_NOT_RECORDED|%s|%s', r.run_code, v_code);
            END IF;
        ELSIF r.status <> 'in_calibration' THEN
            RETURN format('READING_INSTRUMENT_NOT_CALIBRATED|%s|%s', r.device_code, to_char(r.captured_on, 'YYYY-MM-DD'));
        END IF;
    END LOOP;
    IF v_n = 0 AND v_since IS NOT NULL AND v_date >= v_since THEN
        RETURN format('COA_OUTPUT_READING_NOT_RECORDED|%s', v_code);
    END IF;
    RETURN NULL;
END;
$function$

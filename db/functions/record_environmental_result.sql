-- db/functions/record_environmental_result.sql
-- MES-7b-2(2026-10-16,MES-0 Q75;MES-7b Step 0 Q16,Tim):【记一条环境监测结果】—— 一家实验室出的一个参数的读数。module.safety.edit。
--   判的顺序就是人下一步该改什么的顺序:
--     ① 参数(ENV_PARAMETER_REQUIRED)· 采样点(ENV_SAMPLE_POINT_REQUIRED)· 采样日(ENV_SAMPLED_ON_REQUIRED —— 世界那一侧的事实,不给默认值)·
--        实验室(ENV_LABORATORY_REQUIRED)· 报告编号(ENV_REPORT_REFERENCE_REQUIRED)· 数值(ENV_VALUE_REQUIRED)。
--     ② 参数在字典里(ENV_PARAMETER_UNKNOWN|<代号>)、启用着(ENV_PARAMETER_INACTIVE|<代号>)· 实验室在字典里(ENV_LABORATORY_UNKNOWN|<代号>)、
--        启用着(ENV_LABORATORY_INACTIVE|<代号>)· 采样日不在未来(ENV_SAMPLED_IN_FUTURE|<日>,表上的守卫也判)。
--     ③ 更正(只追加,Q16):给了理由没给被更正的那一条 → ENV_CORRECTION_NEEDS_RESULT;给了那一条没给理由 → ENV_CORRECTION_REASON_REQUIRED;
--        找不到 → ENV_RESULT_NOT_FOUND|<id>;它已经被更正过 → ENV_RESULT_ALREADY_CORRECTED。
--   【抄下来】那一刻的单位与限值从字典抄进这一行;判定 = 有限值时那一次比较(max:高于 · min:低于),没有限值时为空("不判定")。
--   【超标开一件事故】(Q16 · MES-0 Q75)在同一笔事务里经 record_incident 开一件 emission_exceedance —— 发生了什么由这一条结果的事实写成
--     (参数、采样点、数值对限值、日期、实验室、报告编号);时刻 = 采样日(新加坡)的零点;负责的人 = 记录的人(他的员工档案;没有就写他的账号)。
--     要不要通报 NEA 由记录的人回答(超标而 p_nea_reportable 为空 → ENV_EXCEEDANCE_NEA_ANSWER_REQUIRED|<值>|<口径>|<限值>|<单位>),
--     当场做了什么也由他写(ENV_EXCEEDANCE_ACTION_REQUIRED)—— 没有一句替他编的话。
--     一条更正若仍超标、而它更正的那一条已经开过一件,就指着同一件(一件事不开两件事故),那两样不必再答。
--   返回 {result_id, exceeds, incident_id, incident_code}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.record_environmental_result(p_parameter_code text, p_sample_point text, p_sampled_on date, p_laboratory_code text, p_report_reference text, p_value numeric, p_nea_reportable boolean DEFAULT NULL::boolean, p_immediate_action text DEFAULT NULL::text, p_corrects_result_id uuid DEFAULT NULL::uuid, p_correction_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_id       uuid := gen_random_uuid();
    v_par      record;
    v_lab      record;
    v_reason   text := NULLIF(btrim(COALESCE(p_correction_reason, '')), '');
    v_action   text := NULLIF(btrim(COALESCE(p_immediate_action, '')), '');
    v_exceeds  boolean;
    v_incident uuid;
    v_inc_code text;
    v_emp      uuid;
    v_j        jsonb;
BEGIN
    PERFORM require_permission('module.safety.edit');

    -- ① 必填
    IF p_parameter_code IS NULL OR btrim(p_parameter_code) = '' THEN
        RAISE EXCEPTION 'ENV_PARAMETER_REQUIRED';
    END IF;
    IF p_sample_point IS NULL OR btrim(p_sample_point) = '' THEN
        RAISE EXCEPTION 'ENV_SAMPLE_POINT_REQUIRED';
    END IF;
    IF p_sampled_on IS NULL THEN
        RAISE EXCEPTION 'ENV_SAMPLED_ON_REQUIRED';
    END IF;
    IF p_laboratory_code IS NULL OR btrim(p_laboratory_code) = '' THEN
        RAISE EXCEPTION 'ENV_LABORATORY_REQUIRED';
    END IF;
    IF p_report_reference IS NULL OR btrim(p_report_reference) = '' THEN
        RAISE EXCEPTION 'ENV_REPORT_REFERENCE_REQUIRED';
    END IF;
    IF p_value IS NULL THEN
        RAISE EXCEPTION 'ENV_VALUE_REQUIRED';
    END IF;

    -- ② 字典与日子
    SELECT p.code, p.name_en, p.unit, p.limit_value, p.limit_basis, p.is_active INTO v_par
      FROM environmental_parameters p WHERE p.code = btrim(p_parameter_code);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ENV_PARAMETER_UNKNOWN|%', btrim(p_parameter_code);
    END IF;
    IF NOT v_par.is_active THEN
        RAISE EXCEPTION 'ENV_PARAMETER_INACTIVE|%', v_par.code;
    END IF;
    SELECT l.code, l.name_en, l.is_active INTO v_lab FROM laboratories l WHERE l.code = btrim(p_laboratory_code);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ENV_LABORATORY_UNKNOWN|%', btrim(p_laboratory_code);
    END IF;
    IF NOT v_lab.is_active THEN
        RAISE EXCEPTION 'ENV_LABORATORY_INACTIVE|%', v_lab.code;
    END IF;
    IF p_sampled_on > (now() AT TIME ZONE 'Asia/Singapore')::date THEN
        RAISE EXCEPTION 'ENV_SAMPLED_IN_FUTURE|%', p_sampled_on;
    END IF;

    -- ③ 更正
    IF p_corrects_result_id IS NULL AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'ENV_CORRECTION_NEEDS_RESULT';
    END IF;
    IF p_corrects_result_id IS NOT NULL THEN
        IF v_reason IS NULL THEN
            RAISE EXCEPTION 'ENV_CORRECTION_REASON_REQUIRED';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM environmental_results WHERE id = p_corrects_result_id) THEN
            RAISE EXCEPTION 'ENV_RESULT_NOT_FOUND|%', p_corrects_result_id;
        END IF;
        IF EXISTS (SELECT 1 FROM environmental_results WHERE corrects_result_id = p_corrects_result_id) THEN
            RAISE EXCEPTION 'ENV_RESULT_ALREADY_CORRECTED';
        END IF;
    END IF;

    -- 判定(一份:表上的 CHECK 说的是同一次比较)
    v_exceeds := CASE WHEN v_par.limit_value IS NULL THEN NULL
                      WHEN v_par.limit_basis = 'max' THEN p_value > v_par.limit_value
                      ELSE p_value < v_par.limit_value END;

    IF v_exceeds THEN
        IF p_corrects_result_id IS NOT NULL THEN
            SELECT r.incident_id INTO v_incident FROM environmental_results r WHERE r.id = p_corrects_result_id;
        END IF;
        IF v_incident IS NULL THEN
            IF p_nea_reportable IS NULL THEN
                RAISE EXCEPTION 'ENV_EXCEEDANCE_NEA_ANSWER_REQUIRED|%|%|%|%', p_value, v_par.limit_basis, v_par.limit_value, v_par.unit
                  USING HINT = '这一条结果超标,会开一件排放超标的事故 —— 要不要通报 NEA,由你回答。';
            END IF;
            IF v_action IS NULL THEN
                RAISE EXCEPTION 'ENV_EXCEEDANCE_ACTION_REQUIRED'
                  USING HINT = '这一条结果超标,会开一件排放超标的事故 —— 写下当场做了什么。';
            END IF;
            v_emp := current_user_employee();
            v_j := record_incident(
                'emission_exceedance',
                (p_sampled_on::timestamp AT TIME ZONE 'Asia/Singapore'),
                format('%s at %s: %s %s against a %s limit of %s %s (sampled %s; %s, report %s).',
                       v_par.name_en, btrim(p_sample_point), p_value, v_par.unit,
                       CASE v_par.limit_basis WHEN 'max' THEN 'maximum' ELSE 'minimum' END, v_par.limit_value, v_par.unit,
                       to_char(p_sampled_on, 'YYYY-MM-DD'), v_lab.name_en, btrim(p_report_reference)),
                v_action,
                p_nea_reportable,
                p_responsible_employee_id => v_emp,
                p_responsible_name => CASE WHEN v_emp IS NULL THEN COALESCE((SELECT u.email::text FROM auth.users u WHERE u.id = v_user), 'unknown account') END);
            v_incident := (v_j ->> 'incident_id')::uuid;
        END IF;
        v_inc_code := (SELECT code FROM incidents WHERE id = v_incident);
    END IF;

    INSERT INTO environmental_results (id, parameter_code, sample_point, sampled_on, laboratory_code, report_reference, value, unit,
                                       limit_value, limit_basis, exceeds, incident_id, corrects_result_id, correction_reason, recorded_by)
    VALUES (v_id, v_par.code, btrim(p_sample_point), p_sampled_on, v_lab.code, btrim(p_report_reference), p_value, v_par.unit,
            v_par.limit_value, v_par.limit_basis, v_exceeds, v_incident, p_corrects_result_id, v_reason, v_user);
    RETURN jsonb_build_object('result_id', v_id, 'exceeds', v_exceeds, 'incident_id', v_incident, 'incident_code', v_inc_code);
END;
$function$;

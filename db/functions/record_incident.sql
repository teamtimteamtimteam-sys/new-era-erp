-- db/functions/record_incident.sql
-- MES-7b-1(2026-10-16,MES-0 Q73 · Q76;MES-7b Step 0 Q3 · Q5 · Q6 · Q9 · Q10 · Q28,Tim):【记一件事故】—— module.safety.edit(Q28:今天
--   admin · cto · warehouse;放宽到每一个查看码的持有人是 Tim 以后的一句授权)。没有审批(Q18:一件事故是一件发生过的事的记录)。
--
--   判的顺序就是人下一步该改什么的顺序:
--     ① 种类必填(INCIDENT_KIND_REQUIRED)· 发生时刻必填(INCIDENT_TIME_REQUIRED —— 世界那一侧的事实,不给默认值)·
--        发生了什么(INCIDENT_WHAT_REQUIRED)· 当场做了什么(INCIDENT_ACTION_REQUIRED)· 负责的人(一名员工或一个名字,INCIDENT_RESPONSIBLE_REQUIRED)·
--        要不要通报 NEA(是 / 否必须回答,INCIDENT_NEA_REPORTABLE_REQUIRED —— Q10:没有规矩替人判,也没有默认)。
--     ② 来源:manual;device 保留(INCIDENT_SOURCE_RESERVED|device,Q5)。
--     ③ 可选项:库位存在(LOCATION_NOT_FOUND|<id>)· 机器是一台在册的设备(equipment_record_target:EQUIPMENT_NOT_FOUND /
--        EQUIPMENT_NOT_A_MACHINE)· 时长 ≥ 0(INCIDENT_DURATION_INVALID)· 引用停机就要先说出机器(INCIDENT_DOWNTIME_NEEDS_MACHINE)·
--        负责的员工存在(EMPLOYEE_NOT_FOUND)。
--     ④ 受伤的细节(Q6):受伤的人最多一个 —— 一名员工或一个名字(INCIDENT_INJURED_ONE_PERSON);伤情 / 处理 / 误工天数要说的是某一个人
--        (INCIDENT_INJURY_NEEDS_PERSON);误工天数 ≥ 0(INCIDENT_DAYS_LOST_INVALID)。任何持 module.safety.edit 的人都记得进去 ——
--        记下之后读它要 data.view_health(或就是受伤的那名员工本人),记录人自己看见的可能是「受限」。
--     ⑤ 表上的守卫(guard_incident_write)再判【行】:时刻不在未来(INCIDENT_TIME_IN_FUTURE)· 种类在清单里、启用着 ·
--        停机是同一台机器的、没作废 · 异常事件存在、没撤回 —— 对每一个写入者都成立,这里不写第二份。
--   编号 INC-YYYY-NNNN(next_incident_code,记录那一天的年)。返回 {incident_id, code}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.record_incident(p_kind_code text, p_occurred_at timestamp with time zone, p_what_happened text, p_immediate_action text, p_nea_reportable boolean, p_responsible_employee_id uuid DEFAULT NULL::uuid, p_responsible_name text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_duration_min numeric DEFAULT NULL::numeric, p_downtime_id uuid DEFAULT NULL::uuid, p_run_event_id bigint DEFAULT NULL::bigint, p_injured_employee_id uuid DEFAULT NULL::uuid, p_injured_person_name text DEFAULT NULL::text, p_injury_nature text DEFAULT NULL::text, p_injury_treatment text DEFAULT NULL::text, p_days_lost numeric DEFAULT NULL::numeric, p_source text DEFAULT 'manual'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_id            uuid := gen_random_uuid();
    v_code          text;
    v_resp_name     text := NULLIF(btrim(COALESCE(p_responsible_name, '')), '');
    v_injured_name  text := NULLIF(btrim(COALESCE(p_injured_person_name, '')), '');
    v_nature        text := NULLIF(btrim(COALESCE(p_injury_nature, '')), '');
    v_treatment     text := NULLIF(btrim(COALESCE(p_injury_treatment, '')), '');
BEGIN
    PERFORM require_permission('module.safety.edit');

    -- ① 必填
    IF p_kind_code IS NULL OR btrim(p_kind_code) = '' THEN
        RAISE EXCEPTION 'INCIDENT_KIND_REQUIRED';
    END IF;
    IF p_occurred_at IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_TIME_REQUIRED';
    END IF;
    IF p_what_happened IS NULL OR btrim(p_what_happened) = '' THEN
        RAISE EXCEPTION 'INCIDENT_WHAT_REQUIRED';
    END IF;
    IF p_immediate_action IS NULL OR btrim(p_immediate_action) = '' THEN
        RAISE EXCEPTION 'INCIDENT_ACTION_REQUIRED';
    END IF;
    IF p_responsible_employee_id IS NULL AND v_resp_name IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_RESPONSIBLE_REQUIRED';
    END IF;
    IF p_nea_reportable IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_NEA_REPORTABLE_REQUIRED'
          USING HINT = '工伤或火灾事故须立即通报 NEA,并在规定的工作日内提交书面报告 —— 这一件要不要通报,由记录的人回答。';
    END IF;

    -- ② 来源
    IF p_source IS DISTINCT FROM 'manual' THEN
        RAISE EXCEPTION 'INCIDENT_SOURCE_RESERVED|%', COALESCE(p_source, '?');
    END IF;

    -- ③ 可选项
    IF p_location_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_location_id) THEN
        RAISE EXCEPTION 'LOCATION_NOT_FOUND|%', p_location_id;
    END IF;
    IF p_equipment_id IS NOT NULL THEN
        PERFORM equipment_record_target(p_equipment_id);
    END IF;
    IF p_duration_min IS NOT NULL AND p_duration_min < 0 THEN
        RAISE EXCEPTION 'INCIDENT_DURATION_INVALID';
    END IF;
    IF p_downtime_id IS NOT NULL AND p_equipment_id IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_DOWNTIME_NEEDS_MACHINE';
    END IF;
    IF p_responsible_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_responsible_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_responsible_employee_id;
    END IF;

    -- ④ 受伤的细节
    IF p_injured_employee_id IS NOT NULL AND v_injured_name IS NOT NULL THEN
        RAISE EXCEPTION 'INCIDENT_INJURED_ONE_PERSON';
    END IF;
    IF (v_nature IS NOT NULL OR v_treatment IS NOT NULL OR p_days_lost IS NOT NULL)
       AND p_injured_employee_id IS NULL AND v_injured_name IS NULL THEN
        RAISE EXCEPTION 'INCIDENT_INJURY_NEEDS_PERSON';
    END IF;
    IF p_days_lost IS NOT NULL AND p_days_lost < 0 THEN
        RAISE EXCEPTION 'INCIDENT_DAYS_LOST_INVALID';
    END IF;
    IF p_injured_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_injured_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_injured_employee_id;
    END IF;

    v_code := next_incident_code(CURRENT_DATE);
    INSERT INTO incidents (id, code, kind_code, occurred_at, location_id, equipment_id, duration_min, what_happened, immediate_action,
                           responsible_employee_id, responsible_name, nea_reportable, source, downtime_id, run_event_id,
                           injured_employee_id, injured_person_name, injury_nature, injury_treatment, days_lost, recorded_by)
    VALUES (v_id, v_code, btrim(p_kind_code), p_occurred_at, p_location_id, p_equipment_id, p_duration_min, btrim(p_what_happened),
            btrim(p_immediate_action), p_responsible_employee_id, v_resp_name, p_nea_reportable, 'manual', p_downtime_id, p_run_event_id,
            p_injured_employee_id, v_injured_name, v_nature, v_treatment, p_days_lost, v_user);
    RETURN jsonb_build_object('incident_id', v_id, 'code', v_code);
END;
$function$;

-- db/functions/record_inspection_finding.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q14,Tim):【记一条巡检发现】—— 一次巡检里第 p_position 项【不合格】之后要做的事:
--   纠正措施(INSPECTION_FINDING_ACTION_REQUIRED)、负责的人(一名员工,INSPECTION_FINDING_OWNER_REQUIRED / EMPLOYEE_NOT_FOUND)、
--   一个人自己选的到期日(可空 —— 没有默认,Q14)。module.safety.edit。
--   巡检找不到 → INSPECTION_RUN_NOT_FOUND|<id>;那一项不在这次巡检里 → INSPECTION_RESULT_UNKNOWN_ITEM|<项>。
--   表上的守卫再判【行】(对每一个写入者都成立,这里不写第二份):那一项是不合格(INSPECTION_FINDING_NOT_A_FAIL|<项>)、
--   那一次巡检没有被更正过(INSPECTION_RUN_SUPERSEDED|<编号>)。
--   record_inspection_run 交巡检时带着的发现也走这一支 —— 一份实现。返回 {finding_id}。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.record_inspection_finding(p_run_id uuid, p_position integer, p_corrective_action text, p_owner_employee_id uuid, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id     uuid := gen_random_uuid();
    v_result bigint;
BEGIN
    PERFORM require_permission('module.safety.edit');

    IF p_run_id IS NULL OR NOT EXISTS (SELECT 1 FROM inspection_runs WHERE id = p_run_id) THEN
        RAISE EXCEPTION 'INSPECTION_RUN_NOT_FOUND|%', COALESCE(p_run_id::text, '?');
    END IF;
    SELECT r.id INTO v_result FROM inspection_results r WHERE r.run_id = p_run_id AND r.position = p_position;
    IF v_result IS NULL THEN
        RAISE EXCEPTION 'INSPECTION_RESULT_UNKNOWN_ITEM|%', COALESCE(p_position::text, '?');
    END IF;
    IF p_corrective_action IS NULL OR btrim(p_corrective_action) = '' THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_ACTION_REQUIRED';
    END IF;
    IF p_owner_employee_id IS NULL THEN
        RAISE EXCEPTION 'INSPECTION_FINDING_OWNER_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM employees WHERE id = p_owner_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_owner_employee_id;
    END IF;

    INSERT INTO inspection_findings (id, run_id, result_id, corrective_action, owner_employee_id, due_date, recorded_by)
    VALUES (v_id, p_run_id, v_result, btrim(p_corrective_action), p_owner_employee_id, p_due_date, auth.uid());
    RETURN jsonb_build_object('finding_id', v_id);
END;
$function$;

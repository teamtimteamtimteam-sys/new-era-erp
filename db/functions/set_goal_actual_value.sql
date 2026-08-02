-- db/functions/set_goal_actual_value.sql
-- 评估人或 HR 在 draft / submitted 阶段填目标的实际值。
-- 【自评阶段不走这里】那时 actual_value 归本人写(save_self_assessment)——
-- 两条路各管一段状态,不会互相覆盖。只写 actual_value,碰不到 target_value 与 unit。
-- 【一条没有单位的目标接不住数字】review_goals_unit_required 会挡下来,那是设计不是 bug。
--
-- NOTE: introduced/updated by db/migrations/2026-08-09-hr3c-quantified-goals-and-self-assessment-read.sql.

CREATE OR REPLACE FUNCTION public.set_goal_actual_value(p_goal_id uuid, p_actual_value numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_g review_goals%ROWTYPE;
    v_r performance_reviews%ROWTYPE;
BEGIN
    SELECT * INTO v_g FROM review_goals WHERE id = p_goal_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GOAL_NOT_FOUND|%', COALESCE(p_goal_id::text,'?'); END IF;
    SELECT * INTO v_r FROM performance_reviews WHERE id = v_g.review_id;

    IF NOT (has_permission('module.hr.edit')
            OR v_r.reviewer_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    IF v_r.status NOT IN ('draft','submitted') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    UPDATE review_goals SET actual_value = p_actual_value WHERE id = p_goal_id;

    RETURN jsonb_build_object('goal_id', p_goal_id, 'actual_value', p_actual_value,
                              'review_id', v_g.review_id, 'status', v_r.status);
END;
$function$
;
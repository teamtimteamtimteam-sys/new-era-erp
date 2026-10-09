-- db/functions/cancel_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19,Tim):【取消一份配料计划】—— action.wo_create(建与改的码;取消一份计划是改它)。
--   草稿或已放行的都可以取消(BLEND_PLAN_NOT_CANCELLABLE|<编号>|<状态>:已执行的不行 —— 那一炉要走回滚申请);理由必填(BLEND_CANCEL_REASON_REQUIRED)。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.cancel_blending_plan(p_plan_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_plan blending_plans%ROWTYPE;
BEGIN
    PERFORM require_permission('action.wo_create');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status NOT IN ('draft', 'released') THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_CANCELLABLE|%|%', v_plan.code, v_plan.status
          USING HINT = '已执行的计划取消不了 —— 混出来的那一炉要撤,走回滚申请。';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'BLEND_CANCEL_REASON_REQUIRED';
    END IF;

    UPDATE blending_plans
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user, cancel_reason = btrim(p_reason),
           updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'status', 'cancelled');
END;
$function$

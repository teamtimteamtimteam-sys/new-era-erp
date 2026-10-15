-- db/functions/release_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q19,Tim):【放行一份配料计划】—— action.wo_release(下达工单的同一个码);
--   【建单人永远不能放行】(forbid_self_approval,按人认 —— 与 release_work_order 同一句;只有 raiser 那一条腿,计划没有"说的是谁")。
--   只放行草稿(BLEND_PLAN_NOT_DRAFT);至少一条目标(BLEND_PLAN_NO_TARGETS)与一行批次(BLEND_NO_LINES)。
--   ★ MES-6b-1(MES-6b Step 0 Q24):一行的批次在质量暂扣里 → QUALITY_HOLD_OPEN|<批号>|<报告>。
--   预测出界【不挡】放行(Q20:标出来,不拒)。不是一张审批单据(Q32:没有新审批)—— 四眼是工单那一种,不进审批引擎。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.release_blending_plan(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_plan blending_plans%ROWTYPE;
    v_hold record;
BEGIN
    PERFORM require_permission('action.wo_release');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status <> 'draft' THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_DRAFT|%|%', v_plan.code, v_plan.status;
    END IF;
    PERFORM forbid_self_approval(v_plan.created_by, NULL::uuid, 'blending_plan');
    IF NOT EXISTS (SELECT 1 FROM blending_plan_targets t WHERE t.plan_id = p_plan_id) THEN
        RAISE EXCEPTION 'BLEND_PLAN_NO_TARGETS|%', v_plan.code
          USING HINT = '一份没有目标品位的配料计划没有东西可对 —— 先给至少一种金属一个界。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM blending_plan_lines l WHERE l.plan_id = p_plan_id) THEN
        RAISE EXCEPTION 'BLEND_NO_LINES';
    END IF;
    -- ★ MES-6b-1(MES-6b Step 0 Q24,Tim):一行的批次在草稿之后进了质量暂扣 → 不放行(建 / 改那一步已经拒过;这里是它在草稿里等着的那段时间)。
    --   执行一份已经放行的计划,由流水守卫挡在投料那一条腿上(guard_quality_hold)。
    SELECT h.ncr_code, h.batch_code INTO v_hold
      FROM blending_plan_lines l
      CROSS JOIN LATERAL batch_quality_hold(l.inbound_batch_id, l.output_batch_id) h
     WHERE l.plan_id = p_plan_id
     ORDER BY h.batch_code
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'QUALITY_HOLD_OPEN|%|%', v_hold.batch_code, v_hold.ncr_code
          USING HINT = '这份计划的一行批次在质量暂扣里 —— 先让另一个人在不合格报告上做出放行的处置,或把那一行从计划里拿掉。';
    END IF;

    UPDATE blending_plans
       SET status = 'released', released_at = now(), released_by = v_user, updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'status', 'released');
END;
$function$

-- db/functions/decide_overtime_batch.sql
-- OVERTIME-1(2026-09-28):仓库一次批完或驳回一整批(action.overtime_approve)。
--
-- 【审批开关不管它】(Tim Q5)开着关着,都要仓库这个人按一次;关着时留痕多写一句说明,
--   而决定值照样是 approved / rejected —— 从不 auto_approved(与工单下达、HR 三条链同一条裁定)。
-- 【四眼,两条腿,按人认】提交人不能批(|raiser);批里【任何一个】员工不能批(|subject)。
--   判据只有 forbid_self_approval 一份:按员工逐个问一次,每一次都先判提交人那条腿 ——
--   所以提交人撞上的永远是 |raiser。R2 的例外只认三类单据,永远不覆盖加班。
--   没有 CFO 越级(Tim Q5):门只有 action.overtime_approve。
-- 【驳回要备注】整批驳回(没有逐行批),批退回财务手里,改完再提(Tim Q10)。
-- 【批准时再判】那个月考勤没完成、每个员工仍是现场员工;day_kind 在这一刻按假期表重算并冻住。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.decide_overtime_batch(p_batch_id uuid, p_decision text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b     overtime_batches%ROWTYPE;
    v_emp   uuid;
    v_bad   text;
    v_note  text := NULLIF(btrim(COALESCE(p_note, '')), '');
    v_log   text;
BEGIN
    PERFORM require_permission('action.overtime_approve');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status <> 'submitted' THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_SUBMITTED|%|%', v_b.label, v_b.status;
    END IF;
    IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_DECISION_INVALID|%', COALESCE(p_decision, '?');
    END IF;

    -- 四眼:提交人那条腿先判,然后批里的每一个员工(编号顺序,拒绝可复现)
    PERFORM forbid_self_approval(v_b.submitted_by, NULL::uuid, 'overtime_batch');
    FOR v_emp IN SELECT l.employee_id FROM overtime_lines l JOIN employees e ON e.id = l.employee_id
                  WHERE l.batch_id = p_batch_id GROUP BY l.employee_id, e.code ORDER BY e.code LOOP
        PERFORM forbid_self_approval(v_b.submitted_by, v_emp, 'overtime_batch');
    END LOOP;

    IF p_decision = 'rejected' AND v_note IS NULL THEN
        RAISE EXCEPTION 'OVERTIME_REJECT_NOTE_REQUIRED|%', v_b.label;
    END IF;

    IF p_decision = 'approved' THEN
        PERFORM overtime_assert_month_open(v_b.period_month);
        SELECT e.code INTO v_bad
          FROM overtime_lines l JOIN employees e ON e.id = l.employee_id
         WHERE l.batch_id = p_batch_id AND (NOT e.is_site_staff OR e.deleted_at IS NOT NULL)
         ORDER BY e.code LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'OVERTIME_NOT_SITE_STAFF|%', v_bad;
        END IF;
        UPDATE overtime_lines SET day_kind = overtime_day_kind(work_date) WHERE batch_id = p_batch_id;
    END IF;

    UPDATE overtime_batches
       SET status = p_decision, decided_at = now(), decided_by = auth.uid(), decision_notes = v_note
     WHERE id = p_batch_id;

    v_log := CASE WHEN approvals_enabled() THEN v_note
                  ELSE concat_ws(' · ', v_note,
                       '审批流未启用(finance_settings.approvals_enabled = false)—— 加班不受审批开关管,决定仍是仓库这个人按下去的') END;
    PERFORM record_approval_decision('overtime_batch', p_batch_id, p_decision, NULL::smallint, v_log);

    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', p_decision,
                              'approvals_enabled', approvals_enabled());
END;
$function$;

COMMENT ON FUNCTION public.decide_overtime_batch(uuid, text, text) IS
'OVERTIME-1:仓库整批批准或驳回(action.overtime_approve;没有 CFO 越级)。审批开关不管它:开着关着都要人按,关着时留痕多一句说明,从不 auto_approved。四眼按人认:SELF_APPROVAL_FORBIDDEN|raiser(提交人)、|subject(批里任何一个员工);R2 不覆盖加班。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_SUBMITTED · OVERTIME_DECISION_INVALID · OVERTIME_REJECT_NOTE_REQUIRED · OVERTIME_MONTH_COMPLETE · OVERTIME_NOT_SITE_STAFF(批准时再判)。批准时 day_kind 按此刻的假期表冻住。';

-- db/functions/submit_overtime_batch.sql
-- OVERTIME-1(2026-09-28):财务把一张批(draft / rejected)交给仓库批。
--
-- 【标记再判一次】批里每一个员工此刻仍是现场员工 —— 录的时候是,不等于现在还是。
-- 【桶再算一次】day_kind 按此刻的假期表重算(批准时还会再算一次,那一次才是冻结的)。
-- 【别人批得动】除了提交人与批里的每一个员工(按人认),还要有一个真持有人持
--   action.overtime_approve;没有 → OVERTIME_NO_OTHER_APPROVER。不看审批开关(Tim Q5)。
-- 【留痕】approval_log 写一行 submitted。被驳回过的批再提交时,上一次的驳回备注仍在留痕里,
--   批次行上的决定三列清空(它们说的是【这一轮】的决定)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.submit_overtime_batch(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b     overtime_batches%ROWTYPE;
    v_bad   text;
    v_emps  uuid[];
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status NOT IN ('draft', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_EDITABLE|%|%', v_b.label, v_b.status;
    END IF;
    PERFORM overtime_assert_month_open(v_b.period_month);

    IF NOT EXISTS (SELECT 1 FROM overtime_lines WHERE batch_id = p_batch_id) THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_EMPTY|%', v_b.label;
    END IF;

    SELECT e.code INTO v_bad
      FROM overtime_lines l JOIN employees e ON e.id = l.employee_id
     WHERE l.batch_id = p_batch_id AND (NOT e.is_site_staff OR e.deleted_at IS NOT NULL)
     ORDER BY e.code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_NOT_SITE_STAFF|%', v_bad;
    END IF;

    SELECT array_agg(DISTINCT l.employee_id) INTO v_emps FROM overtime_lines l WHERE l.batch_id = p_batch_id;
    IF NOT overtime_other_approver_exists(auth.uid(), v_emps) THEN
        RAISE EXCEPTION 'OVERTIME_NO_OTHER_APPROVER|%', v_b.label;
    END IF;

    UPDATE overtime_lines SET day_kind = overtime_day_kind(work_date) WHERE batch_id = p_batch_id;
    UPDATE overtime_batches
       SET status = 'submitted', submitted_at = now(), submitted_by = auth.uid(),
           decided_at = NULL, decided_by = NULL, decision_notes = NULL
     WHERE id = p_batch_id;

    PERFORM record_approval_decision('overtime_batch', p_batch_id, 'submitted', NULL::smallint, NULL::text);
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'submitted');
END;
$function$;

COMMENT ON FUNCTION public.submit_overtime_batch(uuid) IS
'OVERTIME-1:把 draft / rejected 的加班批交给仓库批(action.overtime_enter)。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE · OVERTIME_MONTH_COMPLETE · OVERTIME_BATCH_EMPTY · OVERTIME_NOT_SITE_STAFF(标记再判一次)· OVERTIME_NO_OTHER_APPROVER(除了提交人与批里的员工,没人持 action.overtime_approve)。写一行 approval_log submitted。';

-- db/functions/decide_payroll_request.sql
-- PAYROLL-APR-1(2026-09-24):CFO 批准或驳回一张工资申请(过账或撤销过账)。
--
-- 【门】module.hr.view + data.view_pay(grilling Q8)—— 工资期页的门,加上看得见工资数的那个码
-- (docs/approvals.md §5:批的人必须看得见他批的那个数)。【不是】module.hr.edit:
-- 那是提单的码,一个提得了申请的审批人不是一道控制。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】require_approver_for(2)—— CFO 批每一张、不分档,从不经 approval_level_for:
-- 路由的定义仍然只有一份(approval_level2_role_code)。一级持有人批不了(R1 只往下)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ 四眼:提单人那条腿按人判;主角那条腿对谁都不成立(Tim 的 Q1 (A))★★
-- ════════════════════════════════════════════════════════════════════════════
--   forbid_self_approval(created_by, NULL, 'payroll_request') —— 工资期是公司的单据。
--   Tim 的理由:CFO 在这一步改不了他自己的月薪(月薪只经绩效评估或调薪申请改动),
--   要紧的那道控制是"做的人不是批的人"。从 admin@ 提的申请 tim@ 批不了(同一个人,
--   Step 0 实测 SELF_APPROVAL_FORBIDDEN|raiser)。self_approval_exception 不认
--   payroll_request,所以 R2 永远帮不上这里。
--   ☞ 当审批人自己在这一期里有工资行,决定照常,并在 approval_log 的备注里记下
--   (「本期含审批人自己的工资行」+ 员工编号)。**不**标 self_decided —— record_approval_decision
--   只在"是提单人或主角"时标它,这里主角是 NULL,所以它是 false;approval_log_self_decided_scope
--   也不许 payroll_request 为 true。屏幕上同一句话由工资期页说出。
--
-- 【批准之前】冻结的那一组数与此刻再比一次(PAYROLL_CHANGED_SINCE_REQUEST),再按执行那一刻的
-- 同一支引擎试跑(payroll_request_dry_run)—— 审批人看见的拒绝是引擎的原话。
-- 驳回从不检查这些:驳回一张坏掉的申请,正是出路。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.decide_payroll_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     payroll_requests%ROWTYPE;
    v_own   text;
    v_note  text;
BEGIN
    PERFORM require_permission('module.hr.view');
    PERFORM require_permission('data.view_pay');

    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'payroll_request');
    PERFORM require_approver_for(2::smallint);

    -- 审批人自己在这一期里有没有工资行(按人认:account_person)
    SELECT e.code INTO v_own
      FROM payroll_lines l JOIN employees e ON e.id = l.employee_id
     WHERE l.payroll_period_id = v_r.payroll_period_id
       AND l.employee_id = account_person(auth.uid());
    v_note := NULLIF(btrim(COALESCE(p_notes, '')), '');
    IF v_own IS NOT NULL THEN
        v_note := concat_ws(E'\n', v_note,
            '本期含审批人自己的工资行 · this period includes the approver''s own pay line: ' || v_own);
    END IF;

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'PAYROLL_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE payroll_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('payroll_request', p_request_id, 'rejected', 2::smallint, v_note);
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    IF payroll_period_fingerprint(v_r.payroll_period_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;
    PERFORM payroll_request_dry_run(p_request_id);

    UPDATE payroll_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('payroll_request', p_request_id, 'approved', 2::smallint, v_note);
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'includes_own_line', v_own IS NOT NULL);
END;
$function$
;

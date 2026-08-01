-- db/functions/submit_leave_request.sql
-- 提交请假申请。例外路径:days 由 HR 手填,必须给理由 —— 服务六天制/轮班与逐案审批两种情形。
-- 【例外可以越过 default_days_per_year 这条政策线,但越不过累积型假别的余额】。
--
-- NOTE: updated by db/migrations/2026-08-02-hr2b-leave-exceptions-and-claims.sql.

CREATE OR REPLACE FUNCTION public.submit_leave_request(p_employee_id uuid, p_leave_type_code text, p_start date, p_end date, p_start_half boolean DEFAULT false, p_end_half boolean DEFAULT false, p_reason text DEFAULT NULL::text, p_certificate_ref text DEFAULT NULL::text, p_is_exception boolean DEFAULT false, p_exception_days numeric DEFAULT NULL::numeric, p_exception_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_type   record;
    v_days   numeric;
    v_taken  numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_code   text;
    v_req    record;
    v_clash  text;
BEGIN
    -- 本人或 HR。自助提交由员工自己发起时,p_employee_id 就是他自己的档案。
    IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    -- 【例外是 HR 的口子,不是员工自助的口子】
    IF p_is_exception AND NOT has_permission('module.hr.edit') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    SELECT id, code, employment_status INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'LEAVE_TYPE_NOT_FOUND|%', p_leave_type_code; END IF;
    IF NOT v_type.is_active THEN RAISE EXCEPTION 'LEAVE_TYPE_INACTIVE|%', p_leave_type_code; END IF;

    IF v_type.is_accrued AND v_emp.employment_status = 'probation' THEN
        RAISE EXCEPTION 'PROBATION_NO_ANNUAL_LEAVE';
    END IF;

    -- ── 天数:例外用手填的,常规用算的 ──────────────────────────────────────
    IF p_is_exception THEN
        IF p_exception_reason IS NULL OR btrim(p_exception_reason) = '' THEN
            RAISE EXCEPTION 'EXCEPTION_REASON_REQUIRED';
        END IF;
        IF p_exception_days IS NULL OR p_exception_days <= 0 THEN
            RAISE EXCEPTION 'EXCEPTION_DAYS_INVALID';
        END IF;
        v_days := p_exception_days;
    ELSE
        v_days := calculate_leave_days(p_start, p_end, p_start_half, p_end_half);
        IF v_days <= 0 THEN RAISE EXCEPTION 'NO_WORKING_DAYS|%|%', p_start, p_end; END IF;
    END IF;

    SELECT code INTO v_clash FROM leave_requests
    WHERE employee_id = p_employee_id AND deleted_at IS NULL
      AND status IN ('pending','approved')
      AND daterange(start_date, end_date, '[]') && daterange(p_start, p_end, '[]')
    LIMIT 1;
    IF v_clash IS NOT NULL THEN RAISE EXCEPTION 'OVERLAPPING_REQUEST|%', v_clash; END IF;

    -- 医生证明门槛照旧适用(例外也不例外 —— 那是医疗证据,不是政策口径)
    IF v_type.requires_certificate_after_days IS NOT NULL
       AND (p_certificate_ref IS NULL OR btrim(p_certificate_ref) = '') THEN
        SELECT COALESCE(SUM(r.days), 0) INTO v_taken
        FROM leave_requests r
        WHERE r.employee_id = p_employee_id AND r.leave_type_code = p_leave_type_code
          AND r.deleted_at IS NULL AND r.status IN ('pending','approved')
          AND EXTRACT(YEAR FROM r.start_date) = EXTRACT(YEAR FROM p_start);
        IF v_taken + v_days > v_type.requires_certificate_after_days THEN
            RAISE EXCEPTION 'CERTIFICATE_REQUIRED|%|%', v_taken, v_type.requires_certificate_after_days;
        END IF;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 【余额检查:例外【不能】越过】。
    -- default_days_per_year 是政策,逐案可以变通;年假余额是账上的存量,不能变通。
    -- 批一天不存在的年假不是"通融",是让账不平 —— 而这笔账最后要变成离职补偿的钱。
    -- ══════════════════════════════════════════════════════════════════════
    IF v_type.is_accrued THEN
        v_bal := leave_balance(p_employee_id, p_leave_type_code, p_start);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_days THEN
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%', v_avail, v_days;
        END IF;
    END IF;
    -- 非累积型(恩恤/婚假/考试等):default_days_per_year 只是【标准】,
    -- 例外路径正是为了超过它而存在的,所以这里不设上限。

    v_code := next_leave_request_code(p_start);
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date,
                                start_half_day, end_half_day, days, reason, certificate_ref,
                                is_exception, exception_reason)
    VALUES (v_code, p_employee_id, p_leave_type_code, p_start, p_end,
            p_start_half, p_end_half, v_days, p_reason, p_certificate_ref,
            p_is_exception, CASE WHEN p_is_exception THEN p_exception_reason ELSE NULL END)
    RETURNING * INTO v_req;

    RETURN jsonb_build_object('request_id', v_req.id, 'code', v_req.code,
                              'employee_code', v_emp.code, 'leave_type_code', p_leave_type_code,
                              'days', v_days, 'status', v_req.status,
                              'is_exception', v_req.is_exception);
END;
$function$;

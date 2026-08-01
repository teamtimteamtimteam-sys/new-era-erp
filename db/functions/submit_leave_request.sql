-- db/functions/submit_leave_request.sql
-- 提交申请。天数由 calculate_leave_days 算;查重叠、查医生证明门槛、查余额、试用期不得请年假。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.submit_leave_request(p_employee_id uuid, p_leave_type_code text, p_start date, p_end date, p_start_half boolean DEFAULT false, p_end_half boolean DEFAULT false, p_reason text DEFAULT NULL::text, p_certificate_ref text DEFAULT NULL::text)
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
    -- 【本人或 HR】。自助提交的界面是下一切的事,但函数现在就允许 ——
    -- 表达方式:要么持有 module.hr.edit,要么 p_employee_id 就是调用者自己的员工档案。
    IF NOT (has_permission('module.hr.edit') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    SELECT id, code, employment_status INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'LEAVE_TYPE_NOT_FOUND|%', p_leave_type_code; END IF;
    IF NOT v_type.is_active THEN RAISE EXCEPTION 'LEAVE_TYPE_INACTIVE|%', p_leave_type_code; END IF;

    -- 【试用期不得请年假】—— 但假期照常累积(授予在 grant_annual_leave 里已经发生),
    -- 转正之后整笔余额自然就可用了,不需要任何补授动作。
    IF v_type.is_accrued AND v_emp.employment_status = 'probation' THEN
        RAISE EXCEPTION 'PROBATION_NO_ANNUAL_LEAVE';
    END IF;

    -- 【性别限制记录了但无法强制】:employees 没有性别列,见文件末尾的缺口说明。
    -- 这里【不猜】—— 产假/陪产假的适用性由 HR 在审批时判断。

    v_days := calculate_leave_days(p_start, p_end, p_start_half, p_end_half);
    IF v_days <= 0 THEN RAISE EXCEPTION 'NO_WORKING_DAYS|%|%', p_start, p_end; END IF;

    SELECT code INTO v_clash FROM leave_requests
    WHERE employee_id = p_employee_id AND deleted_at IS NULL
      AND status IN ('pending','approved')
      AND daterange(start_date, end_date, '[]') && daterange(p_start, p_end, '[]')
    LIMIT 1;
    IF v_clash IS NOT NULL THEN RAISE EXCEPTION 'OVERLAPPING_REQUEST|%', v_clash; END IF;

    -- 医生证明:本年度【已请】的该类假天数 + 本次 > 门槛 时必须给证明。
    -- 语义说明:门槛是"免证明的额度",所以 taken=3、门槛=3、再请 1 天就要证明。
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

    -- 累积型:先看余额够不够(真正的扣减在审批时发生)
    IF v_type.is_accrued THEN
        v_bal := leave_balance(p_employee_id, p_leave_type_code, p_start);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_days THEN
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%', v_avail, v_days;
        END IF;
    END IF;

    v_code := next_leave_request_code(p_start);
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date,
                                start_half_day, end_half_day, days, reason, certificate_ref)
    VALUES (v_code, p_employee_id, p_leave_type_code, p_start, p_end,
            p_start_half, p_end_half, v_days, p_reason, p_certificate_ref)
    RETURNING * INTO v_req;

    RETURN jsonb_build_object('request_id', v_req.id, 'code', v_req.code,
                              'employee_code', v_emp.code, 'leave_type_code', p_leave_type_code,
                              'days', v_days, 'status', v_req.status);
END;
$function$;

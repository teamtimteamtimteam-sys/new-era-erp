-- db/functions/add_overtime_line.sql
-- OVERTIME-1(2026-09-28):在一张还能改的批(draft / rejected)上加一行:员工 + 日期 + 小时 + 可选备注。
--
-- 【只录得进现场员工】employees.is_site_staff(Tim 的裁定:只有现场员工有加班)。
--   这一条在提交与批准时【再判一次】—— 标记可能在两次之间被拿掉。
-- 【日期】在批次那个月里、不在未来、那一天这个人在职(入职日 ≤ 日期 ≤ 离职日)。
-- 【小时】> 0、≤ 24、至多两位小数。多出来的位数按名拒,不悄悄四舍五入 —— numeric(4,2)
--   会替人舍掉,而被舍掉的那一点没人看见过。
-- 【同一个员工同一天】已有一行活着的(任何一批,开着的或批过的)→ 按名拒并点出那一批。
-- 要改一行:删掉再加(delete_overtime_line)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.add_overtime_line(p_batch_id uuid, p_employee_id uuid, p_work_date date, p_hours numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b    overtime_batches%ROWTYPE;
    v_e    employees%ROWTYPE;
    v_dup  text;
    v_id   uuid;
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

    SELECT * INTO v_e FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF NOT v_e.is_site_staff THEN
        RAISE EXCEPTION 'OVERTIME_NOT_SITE_STAFF|%', v_e.code;
    END IF;

    IF p_work_date IS NULL THEN
        RAISE EXCEPTION 'OVERTIME_DATE_REQUIRED';
    END IF;
    IF date_trunc('month', p_work_date)::date <> v_b.period_month THEN
        RAISE EXCEPTION 'OVERTIME_DATE_OUTSIDE_MONTH|%|%', p_work_date::text, to_char(v_b.period_month, 'YYYY-MM');
    END IF;
    IF p_work_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'OVERTIME_DATE_FUTURE|%', p_work_date::text;
    END IF;
    IF v_e.hire_date > p_work_date
       OR (v_e.separation_date IS NOT NULL AND v_e.separation_date < p_work_date) THEN
        RAISE EXCEPTION 'OVERTIME_EMPLOYEE_NOT_ACTIVE|%|%', v_e.code, p_work_date::text;
    END IF;

    IF p_hours IS NULL OR p_hours <= 0 OR p_hours > 24 OR round(p_hours, 2) <> p_hours THEN
        RAISE EXCEPTION 'OVERTIME_HOURS_INVALID|%', COALESCE(p_hours::text, '?');
    END IF;

    SELECT b.label INTO v_dup
      FROM overtime_lines l JOIN overtime_batches b ON b.id = l.batch_id
     WHERE l.employee_id = p_employee_id AND l.work_date = p_work_date AND l.voided_at IS NULL
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_DUPLICATE_DAY|%|%|%', v_e.code, p_work_date::text, v_dup;
    END IF;

    INSERT INTO overtime_lines (batch_id, employee_id, work_date, hours, day_kind, note, created_by)
    VALUES (p_batch_id, p_employee_id, p_work_date, p_hours, overtime_day_kind(p_work_date),
            NULLIF(btrim(COALESCE(p_note, '')), ''), auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('line_id', v_id, 'batch_id', p_batch_id);
END;
$function$;

COMMENT ON FUNCTION public.add_overtime_line(uuid, uuid, date, numeric, text) IS
'OVERTIME-1:在 draft / rejected 的加班批上加一行(action.overtime_enter)。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE · OVERTIME_MONTH_COMPLETE · OVERTIME_EMPLOYEE_NOT_FOUND · OVERTIME_NOT_SITE_STAFF · OVERTIME_DATE_REQUIRED · OVERTIME_DATE_OUTSIDE_MONTH · OVERTIME_DATE_FUTURE · OVERTIME_EMPLOYEE_NOT_ACTIVE · OVERTIME_HOURS_INVALID(> 0、≤ 24、至多两位小数)· OVERTIME_DUPLICATE_DAY(同一个员工同一天已有一行活着的,点出那一批)。';

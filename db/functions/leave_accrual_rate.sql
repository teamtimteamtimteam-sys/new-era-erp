-- db/functions/leave_accrual_rate.sql
-- 【全库唯一】的费率解析器:某人某月适用哪个【年额】。
-- 顺序:员工 override(该月及以前最新的一条,值非空)→ 类别费率(同口径)→ 0。
-- override 写 NULL 的含义是「从这天起回到类别费率」,所以「取到了但值为空」要继续往下找。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE FUNCTION public.leave_accrual_rate(p_employee_id uuid, p_work_category text, p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_days numeric;
    v_from date;
BEGIN
    SELECT r.days_per_year, r.effective_from INTO v_days, v_from
    FROM leave_accrual_rates r
    WHERE r.employee_id = p_employee_id AND r.effective_from <= p_month
    ORDER BY r.effective_from DESC
    LIMIT 1;

    IF v_days IS NOT NULL THEN
        RETURN jsonb_build_object('days_per_year', v_days, 'source', 'override',
                                  'effective_from', v_from);
    END IF;

    SELECT r.days_per_year, r.effective_from INTO v_days, v_from
    FROM leave_accrual_rates r
    WHERE r.work_category = p_work_category AND r.effective_from <= p_month
    ORDER BY r.effective_from DESC
    LIMIT 1;

    IF v_days IS NULL THEN
        RETURN jsonb_build_object('days_per_year', 0, 'source', 'none', 'effective_from', NULL);
    END IF;
    RETURN jsonb_build_object('days_per_year', v_days, 'source', 'category',
                              'effective_from', v_from);
END;
$function$
;
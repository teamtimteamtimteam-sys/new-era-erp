-- db/functions/employee_work_category_at.sql
-- 某人某月当时的工种类别。走 employment_history,两层回落:
-- 该月之前没有记录 → 用最早一条有记录的;一条都没有 → 用档案上的当前值(既有数据的情形)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.employee_work_category_at(p_employee_id uuid, p_month date)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_cat text;
BEGIN
    SELECT h.work_category INTO v_cat
    FROM employment_history h
    WHERE h.employee_id = p_employee_id AND h.work_category IS NOT NULL
      AND h.effective_date <= p_month
    ORDER BY h.effective_date DESC, h.created_at DESC
    LIMIT 1;
    IF v_cat IS NOT NULL THEN RETURN v_cat; END IF;

    -- 该月之前没有记录:用【最早一条】有记录的类别(入职时那条),
    -- 再不行才用档案上的当前值 —— 那是既有数据的情形,当时没有变更过。
    SELECT h.work_category INTO v_cat
    FROM employment_history h
    WHERE h.employee_id = p_employee_id AND h.work_category IS NOT NULL
    ORDER BY h.effective_date, h.created_at
    LIMIT 1;
    IF v_cat IS NOT NULL THEN RETURN v_cat; END IF;

    SELECT e.work_category INTO v_cat FROM employees e WHERE e.id = p_employee_id;
    RETURN v_cat;
END;
$function$
;
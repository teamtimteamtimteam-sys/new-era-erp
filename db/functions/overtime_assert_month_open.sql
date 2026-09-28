-- db/functions/overtime_assert_month_open.sql
-- OVERTIME-1(Tim Q8):那个月的考勤已经完成 → 建、提交、批、冲销一律按名拒。
--   OVERTIME_MONTH_COMPLETE|<考勤编号>|<YYYY-MM>
-- 【没有补发到后一个月】要改一个已完成的月:先重开考勤(工资过账之前才准),
--   过账之后要走 CFO 批的工资撤销申请 —— 那两条路本来就在。
-- 【不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回】调用者全是 DEFINER。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_assert_month_open(p_month date)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    SELECT ap.code INTO v_code FROM attendance_periods ap
     WHERE ap.period_month = date_trunc('month', p_month)::date AND ap.status = 'complete';
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_COMPLETE|%|%', v_code, to_char(p_month, 'YYYY-MM');
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.overtime_assert_month_open(date) IS
'OVERTIME-1(Tim Q8):那个月的考勤已完成 → RAISE OVERTIME_MONTH_COMPLETE|<考勤编号>|<YYYY-MM>。建、提交、批、冲销一个加班批之前都问它。EXECUTE 已从 authenticated 收回。';

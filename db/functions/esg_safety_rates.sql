-- db/functions/esg_safety_rates.sql
-- ESG-2(Tim 2026-10-31 Q4 · Q5 · Q6 · Q7):某一年每个月的误工事故、误工天数与误工事故频率(LTIFR),外加一行【年初至今】(month 为空)。
--   【误工事故】(Q5)种类(更正过的)是 injury、受伤的是一名【员工】、误工天数(最后一次更正,没有更正就是原来那个数 —— Q7)> 0;
--     按事故的新加坡日期归月。受伤的不是员工(只写了名字)的另数(nonemployee_injuries,同样要误工天数 > 0),不进率。
--   【工时】(Q4)那个月的考勤期(attendance_periods)里每一行员工:
--     (在职期间的工作日 − 那个月批准的请假天数,各种假都算)× esg_settings.standard_hours_per_day + 三列加班工时。
--     在职期间 = GREATEST(入职日, 月初) .. LEAST(离职日或月末, 月末)(与 complete_attendance_period 填 active_from / active_to 同一个式子);
--     工作日与请假天数都用 calculate_leave_days(周一至周五、扣新加坡公共假期、半天 0.5 —— 与请假模块同一支)。
--   【一个月什么时候算得出】hours_state:no_period(那个月没有考勤期)· incomplete(考勤期里不是每一行都记过 —— lines_recorded / lines_total)·
--     hours_not_set(标准日工时没设)· complete。只有 complete 的月份有工时与率;年初至今那一行只有每一个月都 complete 才有(Q4)。
--   【率】LTIFR = 误工事故 × 1,000,000 ÷ 工时(新加坡 MOM 的口径,Q5)。
--   【遮蔽】(Q6)误工事故、误工天数、非员工受伤与率要 data.view_health;不持的人这几列为空、injury_visible 为假(页面画「受限」)。
--     工时是一个合计,持 module.safety.view 的人都读得到。【门】module.safety.view,不持 → 按名拒。
--   【哪几个月】过去的年份 12 个月;今年到新加坡的这个月为止;将来的年份零行。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.esg_safety_rates(p_year integer)
 RETURNS TABLE(month date, hours_state text, lines_recorded integer, lines_total integer, hours_worked numeric, injury_visible boolean, lti integer, days_lost numeric, nonemployee_injuries integer, ltifr numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
    v_today   date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_std     numeric;
    v_health  boolean;
    v_last    integer;
    v_all_ok  boolean := true;
    v_rec     integer := 0;
    v_tot     integer := 0;
    v_hours   numeric := 0;
    v_lti     integer := 0;
    v_days    numeric := 0;
    v_non     integer := 0;
    r         record;
BEGIN
    PERFORM require_permission('module.safety.view');
    IF p_year IS NULL OR p_year > EXTRACT(year FROM v_today)::integer THEN
        RETURN;
    END IF;
    v_last := CASE WHEN p_year = EXTRACT(year FROM v_today)::integer THEN EXTRACT(month FROM v_today)::integer ELSE 12 END;
    SELECT s.standard_hours_per_day INTO v_std FROM esg_settings s WHERE s.id;
    v_health := has_permission('data.view_health');

    FOR r IN
        WITH mm AS (
            SELECT make_date(p_year, k, 1) AS m_from, (make_date(p_year, k, 1) + interval '1 month - 1 day')::date AS m_to
              FROM generate_series(1, v_last) k
        ), lines AS (
            SELECT mm.m_from, l.recorded_at, e.hire_date, e.separation_date,
                   l.ot_normal_hours + l.ot_rest_day_hours + l.ot_public_holiday_hours AS ot,
                   GREATEST(e.hire_date, mm.m_from) AS a_from,
                   LEAST(COALESCE(e.separation_date, mm.m_to), mm.m_to) AS a_to,
                   l.employee_id, mm.m_to
              FROM mm
              JOIN attendance_periods p ON p.period_month = mm.m_from
              JOIN attendance_lines l ON l.period_id = p.id
              JOIN employees e ON e.id = l.employee_id
        ), per_line AS (
            SELECT ln.m_from, ln.recorded_at, ln.ot,
                   GREATEST(
                       CASE WHEN ln.a_from > ln.a_to THEN 0 ELSE calculate_leave_days(ln.a_from, ln.a_to) END
                       - COALESCE((SELECT sum(calculate_leave_days(
                                        GREATEST(lr.start_date, ln.m_from), LEAST(lr.end_date, ln.m_to),
                                        lr.start_half_day AND lr.start_date >= ln.m_from,
                                        lr.end_half_day AND lr.end_date <= ln.m_to))
                                     FROM leave_requests lr
                                    WHERE lr.employee_id = ln.employee_id AND lr.status = 'approved' AND lr.deleted_at IS NULL
                                      AND lr.start_date <= ln.m_to AND lr.end_date >= ln.m_from), 0),
                       0) AS work_days
              FROM lines ln
        ), hours AS (
            SELECT pl.m_from, count(*)::integer AS tot, count(pl.recorded_at)::integer AS rec,
                   sum(pl.work_days * COALESCE(v_std, 0) + pl.ot) AS h
              FROM per_line pl GROUP BY pl.m_from
        ), inj AS (
            SELECT date_trunc('month', c.occurred_on)::date AS m_from, i.injured_employee_id,
                   COALESCE((SELECT d.days_lost FROM incident_days_lost_corrections d WHERE d.incident_id = i.id ORDER BY d.id DESC LIMIT 1),
                            i.days_lost) AS dl
              FROM incident_current_all c
              JOIN incidents i ON i.id = c.id
             WHERE c.kind_code = 'injury'
               AND c.occurred_on BETWEEN make_date(p_year, 1, 1) AND make_date(p_year, v_last, 1) + interval '1 month - 1 day'
        )
        SELECT mm.m_from,
               EXISTS (SELECT 1 FROM attendance_periods p WHERE p.period_month = mm.m_from) AS has_period,
               COALESCE(h.rec, 0) AS rec, COALESCE(h.tot, 0) AS tot, h.h,
               (SELECT count(*) FROM inj WHERE inj.m_from = mm.m_from AND inj.injured_employee_id IS NOT NULL AND inj.dl > 0)::integer AS lti,
               COALESCE((SELECT sum(inj.dl) FROM inj WHERE inj.m_from = mm.m_from AND inj.injured_employee_id IS NOT NULL AND inj.dl > 0), 0) AS dl,
               (SELECT count(*) FROM inj WHERE inj.m_from = mm.m_from AND inj.injured_employee_id IS NULL AND inj.dl > 0)::integer AS non
          FROM mm LEFT JOIN hours h ON h.m_from = mm.m_from
         ORDER BY mm.m_from
    LOOP
        month := r.m_from;
        lines_recorded := r.rec;
        lines_total := r.tot;
        hours_state := CASE WHEN NOT r.has_period THEN 'no_period'
                            WHEN r.tot = 0 OR r.rec < r.tot THEN 'incomplete'
                            WHEN v_std IS NULL THEN 'hours_not_set'
                            ELSE 'complete' END;
        hours_worked := CASE WHEN hours_state = 'complete' THEN round(r.h, 2) END;
        injury_visible := v_health;
        lti := CASE WHEN v_health THEN r.lti END;
        days_lost := CASE WHEN v_health THEN r.dl END;
        nonemployee_injuries := CASE WHEN v_health THEN r.non END;
        ltifr := CASE WHEN v_health AND hours_state = 'complete' AND r.h > 0 THEN round(r.lti * 1000000 / r.h, 2) END;
        v_all_ok := v_all_ok AND hours_state = 'complete';
        v_rec := v_rec + r.rec; v_tot := v_tot + r.tot;
        v_hours := v_hours + COALESCE(r.h, 0);
        v_lti := v_lti + r.lti; v_days := v_days + r.dl; v_non := v_non + r.non;
        RETURN NEXT;
    END LOOP;

    -- 年初至今:每一个月都 complete 才有工时与率(Q4)
    month := NULL;
    lines_recorded := v_rec;
    lines_total := v_tot;
    hours_state := CASE WHEN v_all_ok THEN 'complete' ELSE 'incomplete' END;
    hours_worked := CASE WHEN v_all_ok THEN round(v_hours, 2) END;
    injury_visible := v_health;
    lti := CASE WHEN v_health THEN v_lti END;
    days_lost := CASE WHEN v_health THEN v_days END;
    nonemployee_injuries := CASE WHEN v_health THEN v_non END;
    ltifr := CASE WHEN v_health AND v_all_ok AND v_hours > 0 THEN round(v_lti * 1000000 / v_hours, 2) END;
    RETURN NEXT;
END;
$function$;

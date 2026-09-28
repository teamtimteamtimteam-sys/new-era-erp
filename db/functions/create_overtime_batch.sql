-- db/functions/create_overtime_batch.sql
-- OVERTIME-1(2026-09-28):财务开一个月的加班批(action.overtime_enter)。
--
-- 【拒绝的顺序 = 人下一步该改什么的顺序】月份没给 → 月份在未来 → 月份早于系统起点 →
--   那个月考勤已完成 → 那个月已有一张开着的批 → 一个现场员工都没有 → 没有别人批得动。
-- 【"没有现场员工"是一句具名的拒绝,不是一张空批】页面在这种时候本来就把钮画成按不动并说出
--   去哪里标;这里是同一件事在库里的那一半(Tim Q17)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.create_overtime_batch(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_m      date;
    v_start  date;
    v_open   text;
    v_seq    integer;
    v_label  text;
    v_id     uuid;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_REQUIRED';
    END IF;
    v_m := date_trunc('month', p_month)::date;
    IF v_m > date_trunc('month', CURRENT_DATE)::date THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_FUTURE|%', to_char(v_m, 'YYYY-MM');
    END IF;
    SELECT system_start_date INTO v_start FROM finance_settings LIMIT 1;
    IF v_start IS NOT NULL AND v_m < date_trunc('month', v_start)::date THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_BEFORE_START|%|%', to_char(v_m, 'YYYY-MM'), v_start::text;
    END IF;
    PERFORM overtime_assert_month_open(v_m);

    SELECT b.label INTO v_open FROM overtime_batches b
     WHERE b.period_month = v_m AND b.status IN ('draft', 'submitted', 'rejected') LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_EXISTS|%', v_open;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM employees e
                    WHERE e.is_site_staff AND e.deleted_at IS NULL
                      AND e.hire_date <= (v_m + interval '1 month - 1 day')::date
                      AND (e.separation_date IS NULL OR e.separation_date >= v_m)) THEN
        RAISE EXCEPTION 'OVERTIME_NO_SITE_STAFF|%', to_char(v_m, 'YYYY-MM');
    END IF;

    IF NOT overtime_other_approver_exists(auth.uid(), '{}'::uuid[]) THEN
        RAISE EXCEPTION 'OVERTIME_NO_OTHER_APPROVER|%', to_char(v_m, 'YYYY-MM');
    END IF;

    SELECT COALESCE(max(b.seq), 0) + 1 INTO v_seq FROM overtime_batches b WHERE b.period_month = v_m;
    v_label := 'OT ' || to_char(v_m, 'YYYY-MM') || ' #' || v_seq::text;
    INSERT INTO overtime_batches (label, period_month, seq, created_by)
    VALUES (v_label, v_m, v_seq, auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('batch_id', v_id, 'label', v_label, 'period_month', v_m);
END;
$function$;

COMMENT ON FUNCTION public.create_overtime_batch(date) IS
'OVERTIME-1:开一个月的加班批(action.overtime_enter)。拒:OVERTIME_MONTH_REQUIRED · OVERTIME_MONTH_FUTURE · OVERTIME_MONTH_BEFORE_START(早于 system_start_date 那个月)· OVERTIME_MONTH_COMPLETE(那个月考勤已完成)· OVERTIME_BATCH_OPEN_EXISTS(已有 draft / submitted / rejected 的批)· OVERTIME_NO_SITE_STAFF(那个月一个在职的现场员工都没有)· OVERTIME_NO_OTHER_APPROVER(除了你没有真持有人持 action.overtime_approve)。';

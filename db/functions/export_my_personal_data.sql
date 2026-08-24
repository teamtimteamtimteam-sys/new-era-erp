-- db/functions/export_my_personal_data.sql
-- PDPA 的当事人查阅:把【关于调用者自己】的个人数据导成一份 jsonb。
-- **没有参数** —— 它拿不到别人的。SECURITY DEFINER 只用来越过列级遮蔽,
-- 不用来放宽主语(遮蔽保护的是"别人看不到",不是"他自己看不到")。
--
-- 【不含绩效评估的正文】PDPA 对评价性用途(evaluative purpose)有豁免,而它怎么
-- 适用是一个【法律判断】。所以只给存在性与时间,并在返回的 note 里【对当事人说出来】——
-- 一次沉默的省略与一次说明了的排除不是一回事。
-- 【范围只到员工】往来户联系人的个人数据在库里,而这条路不通向它们。两条都记在
-- docs/pdpa.md,本文件不复述。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql.

CREATE OR REPLACE FUNCTION public.export_my_personal_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_emp employees%ROWTYPE;
BEGIN
    -- 【它只导出【调用者自己】的数据】—— 没有参数,拿不到别人的。
    SELECT * INTO v_emp FROM employees WHERE user_id = auth.uid() AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_NO_EMPLOYEE_RECORD';
    END IF;

    RETURN jsonb_build_object(
        'generated_at', now(),
        'about', jsonb_build_object(
            'employee_code', v_emp.code, 'legal_name', v_emp.legal_name,
            'preferred_name', v_emp.preferred_name, 'identity_no', v_emp.identity_no,
            'work_email', v_emp.work_email, 'work_phone', v_emp.work_phone,
            'residency_status', v_emp.residency_status,
            'work_pass', jsonb_build_object('type', v_emp.work_pass_type, 'number', v_emp.work_pass_no,
                'issued', v_emp.work_pass_issue_date, 'expires', v_emp.work_pass_expiry_date),
            'employment', jsonb_build_object('type', v_emp.employment_type,
                'category', v_emp.work_category, 'status', v_emp.employment_status,
                'job_title', v_emp.job_title, 'hire_date', v_emp.hire_date,
                'confirmation_date', v_emp.confirmation_date,
                'separation_date', v_emp.separation_date, 'separation_type', v_emp.separation_type),
            'monthly_salary', v_emp.monthly_salary),
        'employment_history', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.effective_date)
            FROM employment_history h WHERE h.employee_id = v_emp.id), '[]'::jsonb),
        'leave_requests', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.created_at)
            FROM leave_requests l WHERE l.employee_id = v_emp.id), '[]'::jsonb),
        'medical_claims', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.created_at)
            FROM medical_claims m WHERE m.employee_id = v_emp.id), '[]'::jsonb),
        'payroll_lines', COALESCE((SELECT jsonb_agg(to_jsonb(pl) ORDER BY pl.created_at)
            FROM payroll_lines pl WHERE pl.employee_id = v_emp.id), '[]'::jsonb),
        -- 【绩效评估的【正文】刻意不在这里,而这是一个【法律】问题不是设计问题】
        -- PDPA 对"评价性用途"(evaluative purpose)有豁免,而这一份导出要不要
        -- 包含评估的书面结论,取决于那条豁免怎么适用 —— 那不是我能裁的。
        -- 所以这里只给【存在性与时间】,正文留白,并在 docs/pdpa.md 里点名为待决。
        'performance_reviews_metadata_only', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'review_type', r.review_type, 'period_start', r.period_start,
                'period_end', r.period_end, 'status', r.status) ORDER BY r.period_start)
            FROM performance_reviews r WHERE r.employee_id = v_emp.id), '[]'::jsonb),
        'note', 'Performance review content is deliberately excluded pending a legal view on the PDPA evaluative-purpose exemption. See docs/pdpa.md.');
END;
$function$;

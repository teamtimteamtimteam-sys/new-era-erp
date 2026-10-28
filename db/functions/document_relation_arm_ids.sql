-- db/functions/document_relation_arm_ids.sql
-- SYSTEM-MAP-3(Tim 2026-10-27):一条【声明的】关联(document_relation_arms 的一行)从一张单据走到哪几张。
--   search_related() / search_related_rows() 的 'arm' 分支调它;document_chain_walk() 经 search_related_rows() 间接调它。
--
-- ★ INVOKER,与那两支同一条理由:「你看得见哪几张」由 RLS 自己回答。这里一条权限判据都不写。
-- ★ 认不出的 arm 名【响】(RAISE),不是空集 —— 一个拼错的名字与一张真的没有关联的单据,在屏幕上分不开。
-- ★ 每一支只读它那一条路上的表;日期与状态的判据写在 document_relation_arms 那一行的 reason 里,两边说同一句话。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_relation_arm_ids(p_arm text, p_id uuid)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_arm = 'payment_request_to_inbound_batch' THEN
        RETURN QUERY
        SELECT DISTINCT (a->>'inbound_batch_id')::uuid
          FROM public.payment_requests r
          CROSS JOIN LATERAL jsonb_array_elements(r.allocations) a
         WHERE r.id = p_id AND COALESCE(a->>'inbound_batch_id', '') <> '';
    ELSIF p_arm = 'inbound_batch_to_payment_request' THEN
        RETURN QUERY
        SELECT r.id
          FROM public.payment_requests r
         WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(r.allocations) a
                        WHERE a->>'inbound_batch_id' = p_id::text);
    ELSIF p_arm = 'payment_to_bank_statement' THEN
        RETURN QUERY
        SELECT DISTINCT bl.statement_id
          FROM public.payments p
          JOIN public.journal_lines jl ON jl.entry_id = p.journal_entry_id
          JOIN public.bank_line_matches m ON m.journal_line_id = jl.id
          JOIN public.bank_statement_lines bl ON bl.id = m.statement_line_id
         WHERE p.id = p_id;
    ELSIF p_arm = 'bank_statement_to_payment' THEN
        RETURN QUERY
        SELECT DISTINCT p.id
          FROM public.bank_statement_lines bl
          JOIN public.bank_line_matches m ON m.statement_line_id = bl.id
          JOIN public.journal_lines jl ON jl.id = m.journal_line_id
          JOIN public.payments p ON p.journal_entry_id = jl.entry_id
         WHERE bl.statement_id = p_id;
    ELSIF p_arm = 'attendance_period_to_payroll_period' THEN
        RETURN QUERY
        SELECT pp.id
          FROM public.attendance_periods ap
          JOIN public.payroll_periods pp ON pp.period_month = ap.period_month AND pp.deleted_at IS NULL
         WHERE ap.id = p_id;
    ELSIF p_arm = 'payroll_period_to_attendance_period' THEN
        RETURN QUERY
        SELECT ap.id
          FROM public.payroll_periods pp
          JOIN public.attendance_periods ap ON ap.period_month = pp.period_month
         WHERE pp.id = p_id;
    ELSIF p_arm = 'overtime_batch_to_payroll_period' THEN
        RETURN QUERY
        SELECT pp.id
          FROM public.overtime_batches ob
          JOIN public.payroll_periods pp ON pp.period_month = ob.period_month AND pp.deleted_at IS NULL
         WHERE ob.id = p_id AND ob.status = 'approved';
    ELSIF p_arm = 'payroll_period_to_overtime_batch' THEN
        RETURN QUERY
        SELECT ob.id
          FROM public.payroll_periods pp
          JOIN public.overtime_batches ob ON ob.period_month = pp.period_month AND ob.status = 'approved'
         WHERE pp.id = p_id;
    ELSIF p_arm = 'leave_request_to_payroll_period' THEN
        RETURN QUERY
        SELECT pp.id
          FROM public.leave_requests lr
          JOIN public.payroll_periods pp
            ON pp.period_month BETWEEN date_trunc('month', lr.start_date)::date
                                   AND date_trunc('month', lr.end_date)::date
           AND pp.deleted_at IS NULL
         WHERE lr.id = p_id AND lr.status = 'approved' AND lr.deleted_at IS NULL;
    ELSIF p_arm = 'payroll_period_to_leave_request' THEN
        RETURN QUERY
        SELECT lr.id
          FROM public.payroll_periods pp
          JOIN public.leave_requests lr
            ON pp.period_month BETWEEN date_trunc('month', lr.start_date)::date
                                   AND date_trunc('month', lr.end_date)::date
           AND lr.status = 'approved' AND lr.deleted_at IS NULL
         WHERE pp.id = p_id;
    ELSE
        RAISE EXCEPTION 'DOCUMENT_RELATION_UNKNOWN_ARM|% —— 它不在 document_relation_arms 里,'
                        '而一个拼错的名字与一张真的没有关联的单据在屏幕上分不开', coalesce(p_arm, '(null)');
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.document_relation_arm_ids(text, uuid) IS
    'SYSTEM-MAP-3:一条声明的关联(document_relation_arms)从一张单据走到哪几张。INVOKER —— RLS 回答你看得见哪几张;'
    '认不出的 arm 名按名拒(DOCUMENT_RELATION_UNKNOWN_ARM)。';

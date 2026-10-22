-- db/functions/payroll_payment_entries.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q1 · Q6 · Q8):付薪页(/finance/payroll-payments)上每一期的【每一次付款】一行 ——
--   冲销申请就从这一行提,通用日记账冲销按名拒时指的也是这一页(JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL)。
--   每一行:分录 id / 编号 / 日期 / 状态 · 种类(salary · cpf · deductions,payroll_payment_entry_kind)· 金额(贷方银行合计,本位币;
--   不持 data.view_pay → NULL,屏幕印「受限」)· 银行行有没有配上对账单行、配在哪一张、那一张对完账没有(Q6:钮看得见、按不动、说出先做什么)·
--   这一期挂着的那一张未了结申请(任何一种;一期同时只挂一张)。
--   只列【还盖着戳】的付款 —— 冲掉之后戳清了,它就从这里消失;历史在页底的审计记录与那张已冲销的分录上。
-- 【门】module.finance.view 或 module.hr.view(付薪页的门是前者;工资期页的门是后者)—— 不持任何一个按名拒,不回零行。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.payroll_payment_entries(p_period_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pay boolean := has_permission('data.view_pay');
BEGIN
    IF NOT (has_permission('module.finance.view') OR has_permission('module.hr.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'entry_id', je.id, 'code', je.code, 'entry_date', je.entry_date, 'status', je.status,
                   'payroll_period_id', je.source_id, 'kind', k.kind,
                   'amount', CASE WHEN v_pay THEN (SELECT round(sum(jl.credit), 2) FROM journal_lines jl
                                                    JOIN accounts a ON a.id = jl.account_id
                                                   WHERE jl.entry_id = je.id AND a.code IN ('1000', '1010')) END,
                   'lines_paid', CASE WHEN k.kind = 'salary'
                                      THEN (SELECT count(*) FROM payroll_lines pl WHERE pl.paid_journal_entry_id = je.id) END,
                   'bank_statement', m.stmt, 'bank_statement_status', m.st,
                   'open_request', (SELECT jsonb_build_object('id', r.id, 'label', r.label, 'kind', r.kind, 'status', r.status,
                                                              'target_entry_id', r.target_entry_id)
                                      FROM payroll_requests r
                                     WHERE r.payroll_period_id = je.source_id AND r.status IN ('submitted', 'approved')
                                     LIMIT 1))
                   ORDER BY je.entry_date, je.code)
          FROM journal_entries je
          CROSS JOIN LATERAL (SELECT payroll_payment_entry_kind(je.id) AS kind) k
          LEFT JOIN LATERAL (SELECT s.code AS stmt, s.status AS st
                               FROM journal_lines jl
                               JOIN bank_line_matches bm ON bm.journal_line_id = jl.id
                               JOIN bank_statement_lines bl ON bl.id = bm.statement_line_id
                               JOIN bank_statements s ON s.id = bl.statement_id
                              WHERE jl.entry_id = je.id
                              ORDER BY s.code LIMIT 1) m ON true
         WHERE je.source_type = 'payroll' AND je.source_id = ANY (p_period_ids) AND k.kind IS NOT NULL), '[]'::jsonb);
END;
$function$;

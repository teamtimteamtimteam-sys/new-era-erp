-- db/functions/change_log_mask_rules.sql
-- HISTORY-1(Tim 的 Q10 · Q7 · Q20):change_log_rows() 的遮蔽规则 —— 【一份】名单,一列一行。
--
-- 【来源】逐条抄自每一张 <表>_masked 视图里那句 CASE WHEN … THEN <列> ELSE NULL END(以 postgres
--   读 pg_get_viewdef,2026-09-28),外加本刀新建的 purchase_order_history_masked。
--   "源屏幕怎么遮,记录就怎么遮" —— 屏幕读的就是这些视图。
-- 【规则的写法】
--   code:<码>                    持这个码才看得见
--   code_or_self:<码>:<列>       持码,或那一行的 <列> 就是读者自己的员工 id(视图里的 OR id = current_user_employee())
--   pft:direction                pricing_formula_terms_visible(这一行的 direction)
--   pft:formula_id               pricing_formula_terms_visible(这一行所属公式的 direction)
--   pft3                         pricing_formula_history_masked 那三段:公式当前方向 ∧ old_direction ∧ new_direction
--   pay_journal:<码>             持码,或这一行所在分录不是工资分录(journal_lines_masked;U1-A,UNBLOCK-1 Q1)
--   apr_amount                   approval_log_amount_visible(subject_type, subject_id)(approval_log_masked;U1-A,Q8 · Q10)
--   apr_note                     approval_log_note_visible(subject_type, subject_id)(approval_log_masked;U1-B)
--   jr_amount                    journal_request_amount_visible(id)(journal_requests_masked;U1-B)
--   never                        谁都看不见(gateway_keys_masked 里 CASE WHEN false;MES-1 Q20:网关钥匙的哈希)
-- ★ MES-5a-2(2026-10-08)加了 6 行(105 → 111):电费分摊的五列金额与分给一炉的金额 —— 加工成本那条规矩(data.view_prices,Q30),
--   每一行抄自 electricity_allocations_masked / electricity_allocation_lines_masked 里那句 CASE。
--   MES-5b-2:+3 行(electricity_allocation_reversals 的三列金额),抄自 electricity_allocation_reversals_masked 里那句 CASE。111 → 114。
-- ★ MES-1(2026-10-06)加了 1 行(104 → 105):网关钥匙的哈希 —— never(Q20:任何读者、任何一份记录都不给)。
-- ★ U1-B(2026-10-05)加了 3 行(101 → 104):工资分录冲销申请的金额 · 医疗报销的批准 / 驳回理由(在报销单上与在审批留痕上)。
-- ★ U1-A(UNBLOCK-1,2026-10-05)加了 20 行(81 → 101):工资分录的金额(Q1)· 审批留痕上的金额(Q8 · Q10)· 人事备注(Q6)·
--   健康数据(Q8)· 工资期的合计与工资申请的快照和金额(Q9 · Q10)。每一行都抄自它那张 _masked 视图里的 CASE。
-- 【它会不会和视图漂开】会 —— 所以有一道闸:change_log_mask_gaps() 拿目录里【真的被遮的列】
--   (_masked 视图里 CASE … END AS <基表的列>)与本名单逐列对,缺一条或多一条都报;
--   gate 的 changemask 那一行在线上与重建两侧各问一次,fixture 234 里注入"删掉一条"必须变红。
CREATE OR REPLACE FUNCTION public.change_log_mask_rules()
 RETURNS TABLE(table_name text, column_name text, rule text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('approval_log'::text, 'amount_ccy'::text, 'apr_amount'::text),
        ('gateway_keys', 'key_hash', 'never'),
        ('approval_log', 'amount_base', 'apr_amount'),
        ('approval_log', 'note', 'apr_note'),
        ('company_profile', 'bank_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_name', 'code:data.view_banking'),
        ('company_profile', 'bank_account_no', 'code:data.view_banking'),
        ('company_profile', 'bank_swift', 'code:data.view_banking'),
        ('company_profile', 'bank_address', 'code:data.view_banking'),
        ('employees', 'work_email', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_phone', 'code_or_self:data.view_identity:id'),
        ('employees', 'identity_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'work_pass_no', 'code_or_self:data.view_identity:id'),
        ('employees', 'monthly_salary', 'code_or_self:data.view_pay:id'),
        ('employees', 'notes', 'code:module.hr.view'),
        ('employees', 'separation_notes', 'code:module.hr.view'),
        ('employment_history', 'old_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('employment_history', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('inbound_batches', 'unit_price', 'code:data.view_purchase_prices'),
        ('invoice_lines', 'unit_price', 'code:data.view_prices'),
        ('invoice_lines', 'amount_base', 'code:data.view_prices'),
        ('invoice_lines', 'amount_ccy', 'code:data.view_prices'),
        ('invoice_lines', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'subtotal_base', 'code:data.view_prices'),
        ('invoices', 'tax_base', 'code:data.view_prices'),
        ('invoices', 'total_base', 'code:data.view_prices'),
        ('invoices', 'fx_rate', 'code:data.view_prices'),
        ('journal_lines', 'debit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'credit', 'pay_journal:data.view_pay'),
        ('journal_lines', 'amount_ccy', 'pay_journal:data.view_pay'),
        ('journal_requests', 'amount_base', 'jr_amount'),
        ('leave_requests', 'reason', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'certificate_ref', 'code_or_self:data.view_health:employee_id'),
        ('leave_requests', 'exception_reason', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'amount_sgd', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'description', 'code_or_self:data.view_health:employee_id'),
        ('medical_claims', 'decision_notes', 'code_or_self:data.view_health:employee_id'),
        ('payment_term_template_lines', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('payroll_lines', 'gross_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employer_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'employee_cpf', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'other_deductions', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_lines', 'net_pay', 'code_or_self:data.view_pay:employee_id'),
        ('payroll_periods', 'gross_total', 'code:data.view_pay'),
        ('payroll_periods', 'employer_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'employee_cpf_total', 'code:data.view_pay'),
        ('payroll_periods', 'other_deductions_total', 'code:data.view_pay'),
        ('payroll_periods', 'net_pay_total', 'code:data.view_pay'),
        ('payroll_requests', 'snapshot', 'code:data.view_pay'),
        ('payroll_requests', 'gross_total', 'code:data.view_pay'),
        ('payroll_requests', 'amount_base', 'code:data.view_pay'),
        ('performance_reviews', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),
        ('prepayment_applications', 'amount_base', 'code:data.view_purchase_prices'),
        ('prepayment_applications', 'amount_ccy', 'code:data.view_purchase_prices'),
        ('price_history', 'old_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'new_unit_price', 'code:data.view_purchase_prices'),
        ('price_history', 'original_price', 'code:data.view_purchase_prices'),
        ('price_history', 'fx_rate', 'code:data.view_purchase_prices'),
        ('pricing_formula_history', 'old_payable_pct', 'pft3'),
        ('pricing_formula_history', 'new_payable_pct', 'pft3'),
        ('pricing_formula_history', 'old_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'new_treatment_charge_usd_per_tonne', 'pft3'),
        ('pricing_formula_history', 'old_flat_discount_pct', 'pft3'),
        ('pricing_formula_history', 'new_flat_discount_pct', 'pft3'),
        ('pricing_formula_metals', 'payable_pct', 'pft:formula_id'),
        ('pricing_formulas', 'treatment_charge_usd_per_tonne', 'pft:direction'),
        ('pricing_formulas', 'flat_discount_pct', 'pft:direction'),
        ('pricing_term_commitment_metals', 'payable_pct', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'treatment_charge_usd_per_tonne', 'code:data.view_purchase_prices'),
        ('pricing_term_commitments', 'flat_discount_pct', 'code:data.view_purchase_prices'),
        ('processing_cost_entries', 'amount_base', 'code:data.view_prices'),
        ('electricity_allocations', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'price_per_kwh', 'code:data.view_prices'),
        ('electricity_allocations', 'allocated_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'overhead_amount', 'code:data.view_prices'),
        ('electricity_allocations', 'relieved_estimate_amount', 'code:data.view_prices'),
        ('electricity_allocation_lines', 'amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'bill_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'actual_line_amount', 'code:data.view_prices'),
        ('electricity_allocation_reversals', 'restored_estimate_amount', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'old_amount_base', 'code:data.view_prices'),
        ('processing_cost_entry_history', 'new_amount_base', 'code:data.view_prices'),
        ('processing_outputs', 'allocated_cost_base', 'code:data.view_prices'),
        ('processing_outputs', 'unit_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'material_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'process_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'total_cost_base', 'code:data.view_prices'),
        ('processing_runs', 'capitalized_cost_base', 'code:data.view_prices'),
        ('warehouse_requests', 'amount_base', 'code:data.view_prices'),
        ('purchase_order_history', 'old_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'old_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_history', 'new_payment_term', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'released_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_line_retentions', 'withheld_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_unit_price', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'estimated_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'price_provenance', 'code:data.view_purchase_prices'),
        ('purchase_order_lines', 'tax_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_order_payment_terms', 'fixed_amount_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'fx_rate', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'estimated_total_ccy', 'code:data.view_purchase_prices'),
        ('purchase_orders', 'tax_total_ccy', 'code:data.view_purchase_prices'),
        ('sales_records', 'unit_price', 'code:data.view_prices'),
        ('sales_records', 'fx_rate', 'code:data.view_prices'),
        ('sales_records', 'amount_base', 'code:data.view_prices'),
        ('sales_records', 'price_provenance', 'code:data.view_prices');
$function$;

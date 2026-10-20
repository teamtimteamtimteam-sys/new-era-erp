CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text, p_maintenance_id uuid DEFAULT NULL::uuid, p_amount_includes_tax boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- ════════════════════════════════════════════════════════════════════════════
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q11):record_expense 是 record_expense_document 的【单行包装】。
--   签名一个字不变 —— 三个库内调用者(decide_expense_claim_items 之外的报销 / 医疗 / 资产页那几条路)、两个应用调用者
--   (费用表单之外:资产页追加成本 · 设备页资本化)与 140 处 fixture 调用照旧。它只做一件事:把 (科目, 金额, 税码) 包成一行,
--   交给那一支唯一的写入者 —— 一份实现,两个入口。原来这里的每一段(采购单行 · 预提税 · 资本化 · 分录形状)
--   原样搬进了 record_expense_document,读那一支。
--   p_notes 记在【表头】;单行单据的那一行不另带备注(与此前一模一样:一张单只有一句备注)。
-- 【汇率不由调用方递入】FX_RATE_NOT_ACCEPTED 留在包装里:牌价属于 fx_rates,不属于表单(FIN-0)。新的那一支干脆没有这个参数。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    RETURN record_expense_document(
        p_expense_date        := p_expense_date,
        p_currency            := p_currency,
        p_lines               := jsonb_build_array(jsonb_build_object(
                                     'account_code', p_account_code, 'amount', p_amount, 'tax_code', p_tax_code)),
        p_payment_status      := p_payment_status,
        p_bank_account        := p_bank_account,
        p_supplier_id         := p_supplier_id,
        p_payee_name          := p_payee_name,
        p_notes               := p_notes,
        p_asset               := p_asset,
        p_employee_id         := p_employee_id,
        p_purchase_order_line := p_purchase_order_line,
        p_wht_nature          := p_wht_nature,
        p_wht_rate_pct        := p_wht_rate_pct,
        p_wht_treaty_ref      := p_wht_treaty_ref,
        p_maintenance_id      := p_maintenance_id,
        p_amount_includes_tax := p_amount_includes_tax);
END;
$function$
;

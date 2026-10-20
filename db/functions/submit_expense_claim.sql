-- db/functions/submit_expense_claim.sql
-- CLAIM-1:提交一张报销单(旧签名)。
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0b Q8):这一支现在是 submit_expense_claim_items 的【单笔包装】——
--   签名一个字不变(/me 的旧表单之外,12 份 fixture 里 19 处调用照旧)。一句说明同时是整张单的用途与那一笔的说明;
--   无收据理由落在那一笔上。门、日期、金额、四眼预检的全部说明在 submit_expense_claim_items.sql。
--   【包装是 INVOKER】它自己不读不写任何表,门在它调的那一支(SECURITY DEFINER,开头就问调用者是谁)——
--   一支没有自己的调用者检查的属主权限函数是 B2 要拒的形状,而这里本来就不需要属主权限。
CREATE OR REPLACE FUNCTION public.submit_expense_claim(p_employee_id uuid, p_spend_date date, p_amount numeric, p_currency text, p_description text, p_no_receipt_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN submit_expense_claim_items(
        p_employee_id := p_employee_id,
        p_currency    := p_currency,
        p_purpose     := p_description,
        p_items       := jsonb_build_array(jsonb_build_object(
                             'spend_date', p_spend_date, 'amount', p_amount, 'description', p_description,
                             'no_receipt_reason', p_no_receipt_reason)));
END;
$function$
;

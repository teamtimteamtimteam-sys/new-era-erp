-- db/functions/document_chain_step_admits.sql
-- SYSTEM-MAP-3(Tim 2026-10-27,grilling 第 7 条):单据链条上【没有自己页面的那几步】住在别的单据里 ——
--   这一支答「这张宿主单据上,这一步存在吗」:
--     payable          一批货有没有应付 —— 它的计价分录在不在(journal_entries.source_type = 'purchase', source_id = 这一批);
--     reservation      一张销售订单有没有预留(sales_order_reservations 经 sales_order_lines);
--     cost_allocation  一次加工有没有成本分摊行(batch_processing_cost_allocations.run_id);
--     payroll_payment  一张分录是不是付薪分录(工资行的 paid_journal_entry_id,或期间的公积金 / 扣款付款分录 ——
--                      与 payroll_payment_entry_kind() 同一组判据;那一支收回了 authenticated 的 EXECUTE,所以这里照它写一份
--                      只答"是不是"的读法,按读者自己的身份读)。
--   定价(pricing)不需要判据:每一批货的页面上都有定价那一块。
-- ★ NULL 的判据 = 这一步没有判据 → true。认不出的判据名【响】。p_id 为 NULL 时只校验名字(document_chain_walk 开头用它)。
-- ★ INVOKER:读者读不到那张表 → false(那一步对他就是"找不到";单据链条上那一步本来就按权限画「受限」)。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-3-chain-bar.sql.

CREATE OR REPLACE FUNCTION public.document_chain_step_admits(p_filter text, p_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_filter IS NULL THEN
        RETURN true;
    END IF;
    IF p_filter NOT IN ('payable', 'reservation', 'cost_allocation', 'payroll_payment') THEN
        RAISE EXCEPTION 'DOCUMENT_CHAIN_UNKNOWN_FILTER|% —— 单据链条认得的判据只有 payable · reservation · '
                        'cost_allocation · payroll_payment', p_filter;
    END IF;
    IF p_id IS NULL THEN
        RETURN true;
    END IF;
    IF p_filter = 'payable' THEN
        RETURN EXISTS (SELECT 1 FROM public.journal_entries e
                        WHERE e.source_type = 'purchase' AND e.source_id = p_id);
    ELSIF p_filter = 'reservation' THEN
        RETURN EXISTS (SELECT 1 FROM public.sales_order_reservations r
                         JOIN public.sales_order_lines l ON l.id = r.sales_order_line_id
                        WHERE l.sales_order_id = p_id);
    ELSIF p_filter = 'cost_allocation' THEN
        RETURN EXISTS (SELECT 1 FROM public.batch_processing_cost_allocations a WHERE a.run_id = p_id);
    END IF;
    RETURN EXISTS (SELECT 1 FROM public.payroll_lines pl WHERE pl.paid_journal_entry_id = p_id)
        OR EXISTS (SELECT 1 FROM public.payroll_periods pp
                    WHERE pp.cpf_journal_entry_id = p_id OR pp.deductions_journal_entry_id = p_id);
END;
$function$;

COMMENT ON FUNCTION public.document_chain_step_admits(text, uuid) IS
    'SYSTEM-MAP-3:单据链条上一个住在宿主单据里的步骤,在这张宿主单据上存不存在(payable · reservation · '
    'cost_allocation · payroll_payment;NULL = 没有判据)。INVOKER。';

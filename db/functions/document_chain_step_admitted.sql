-- db/functions/document_chain_step_admitted.sql
-- CHAIN-WALK-COST(v1.4.80,Tim 2026-10-28):document_chain_step_admits 的【一组】写法 —— 这几张宿主单据里,哪几张上这一步存在。
--   四个判据只写在这里一份;document_chain_step_admits(filter, id) 现在是它的单张写法。单据链条一跳拿一整组候选进来问一次:
--   以前每一张候选各问一次(一年体量的一张月结对账单,200 批货各一句,连同各自那一次读规则判断约 80 ms)。
--     payable          一批货有没有应付 —— 它的计价分录在不在(journal_entries.source_type = 'purchase', source_id = 这一批);
--     reservation      一张销售订单有没有预留(sales_order_reservations 经 sales_order_lines);
--     cost_allocation  一次加工有没有成本分摊行(batch_processing_cost_allocations.run_id);
--     payroll_payment  一张分录是不是付薪分录(工资行的 paid_journal_entry_id,或期间的公积金 / 扣款付款分录)。
-- ★ NULL 的判据 = 这一步没有判据 → 全部都算。认不出的判据名【响】。
-- ★ INVOKER:读者读不到那张表 → 一张都不算(那一步对他就是"找不到";单据链条上那一步本来就按权限画「受限」)。
--
-- NOTE: introduced by db/migrations/2026-10-28-chain-walk-cost.sql.

CREATE OR REPLACE FUNCTION public.document_chain_step_admitted(p_filter text, p_ids uuid[])
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF p_filter IS NOT NULL AND p_filter NOT IN ('payable', 'reservation', 'cost_allocation', 'payroll_payment') THEN
        RAISE EXCEPTION 'DOCUMENT_CHAIN_UNKNOWN_FILTER|% —— 单据链条认得的判据只有 payable · reservation · '
                        'cost_allocation · payroll_payment', p_filter;
    END IF;
    IF p_filter IS NULL THEN
        RETURN QUERY SELECT DISTINCT x FROM unnest(p_ids) x WHERE x IS NOT NULL;
    ELSIF p_filter = 'payable' THEN
        RETURN QUERY SELECT DISTINCT e.source_id FROM public.journal_entries e
                      WHERE e.source_type = 'purchase' AND e.source_id = ANY (p_ids);
    ELSIF p_filter = 'reservation' THEN
        RETURN QUERY SELECT DISTINCT l.sales_order_id FROM public.sales_order_reservations r
                       JOIN public.sales_order_lines l ON l.id = r.sales_order_line_id
                      WHERE l.sales_order_id = ANY (p_ids);
    ELSIF p_filter = 'cost_allocation' THEN
        RETURN QUERY SELECT DISTINCT a.run_id FROM public.batch_processing_cost_allocations a WHERE a.run_id = ANY (p_ids);
    ELSE
        RETURN QUERY SELECT pl.paid_journal_entry_id FROM public.payroll_lines pl WHERE pl.paid_journal_entry_id = ANY (p_ids)
                     UNION
                     SELECT x FROM public.payroll_periods pp, unnest(ARRAY[pp.cpf_journal_entry_id, pp.deductions_journal_entry_id]) x
                      WHERE x = ANY (p_ids);
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.document_chain_step_admitted(text, uuid[]) IS
    'CHAIN-WALK-COST:一组宿主单据里,单据链条上住在宿主里的那一步(payable · reservation · cost_allocation · payroll_payment;NULL = 没有判据)'
    '在哪几张上存在。INVOKER。document_chain_step_admits 是它的单张写法。';

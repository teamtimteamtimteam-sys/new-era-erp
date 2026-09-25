-- db/functions/reverse_journal_entry.sql
-- 手工冲销一张分录(module.finance.edit)。付款、转账、代扣税缴纳的分录按名拒,走各自的申请。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q5):工资期的过账分录与它的冲销也按名拒 —— 撤销走撤销申请。
-- ★ APR-5a(2026-09-25,grilling Q11 ④):发票与贷项通知的分录(以及它们的冲销)也按名拒 —— 走作废 / 贷项申请。

CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_src text;
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- ★ PAY-REQ-1(Tim 的 Q2(b)):付款与银行转账的分录【不许】从这里冲 ——
    --   这里冲掉一笔付款的分录,钱在总账上回来了,而付款行仍是 posted、核销仍然
    --   算数(结算按 payments.status 求和),而且绕过了冲销申请与 CFO 的批准。
    --   付款走冲销申请(reverse_payment 那一条);转账走转账冲销申请。
    --   ★ PAY-REQ-1 Batch B(Tim 的 Q3):代扣税缴纳也关在这里 —— 它的更正从此走
    --   wht_remittance_reversal 申请(reverse_wht_remittance_internal),经 CFO 批准。
    SELECT source_type, code INTO v_src, v_code FROM journal_entries WHERE id = p_entry_id;
    -- ★ ROLE-1 Batch 4a(侧门 (b)):收货定价的 purchase 分录也关在这里 —— 从这里冲掉它,2000 回来了,
    --   收货单的单价与改价历史却不动,ap_open_items 照样说欠着,清单与总账从此各说各话。
    --   更正走改价(定价面板;Batch 4b 起经 CFO 批准的定价申请)。
    -- ★ APR-5a(grilling Q11 ④):发票(订单流开票分录、sale 型发票的税分录 —— 都是 'invoice')与贷项通知
    --   ('credit_note')的分录也关在这里 —— 从这里冲掉开票那一张,就是一次不经 CFO 的作废(发票却仍是 issued、
    --   仍可发货);冲掉一张贷项,就是一次不经 CFO 的"撤销贷项"。作废走作废申请,贷项走贷项申请。
    --   冲销分录抄原分录的 source_type,所以作废留下的那张冲销分录同样按名拒(否则冲掉它 = 不经批准地复活发票)。
    IF v_src IN ('payment', 'transfer', 'wht_remittance', 'purchase', 'invoice', 'credit_note') THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    -- ★ PAYROLL-APR-1(Tim 的 Q5):工资期的【过账】分录也关在这里 —— 从这里冲掉它,总账回来了,
    --   期间却仍是 posted、付款照样付得出去,而且绕过了撤销申请与 CFO 的批准。撤销走撤销申请。
    --   ☞ 【过账那一张,以及它的冲销】—— 冲掉一张撤销分录,等于不经申请把工资重新过了一遍账,
    --   而期间仍是 draft。判法反过来写:source_type 'payroll' 里,只有【付款】分录(以及它们的冲销)
    --   放行 —— 它们被 payroll_lines.paid_journal_entry_id / cpf_journal_entry_id /
    --   deductions_journal_entry_id 指着。付款分录根本没有正经的冲销路径(已登记
    --   PAYROLL-PAYMENT-NO-REVERSAL-PATH);在这里关掉它们,等于把唯一的(错的)出路也关了
    --   而不给一条对的 —— 那是另一刀的事。
    IF v_src = 'payroll' AND NOT EXISTS (
           SELECT 1 FROM journal_entries j
            WHERE j.id = p_entry_id
              AND (EXISTS (SELECT 1 FROM payroll_lines pl
                            WHERE pl.paid_journal_entry_id IN (j.id, j.source_id))
                   OR EXISTS (SELECT 1 FROM payroll_periods pp
                               WHERE pp.cpf_journal_entry_id IN (j.id, j.source_id)
                                  OR pp.deductions_journal_entry_id IN (j.id, j.source_id)))) THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    RETURN reverse_journal_entry_internal(p_entry_id, p_reversal_date, p_memo);
END;
$function$;
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
    IF v_src IN ('payment', 'transfer', 'wht_remittance') THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    RETURN reverse_journal_entry_internal(p_entry_id, p_reversal_date, p_memo);
END;
$function$;
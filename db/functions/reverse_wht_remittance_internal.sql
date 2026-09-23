-- db/functions/reverse_wht_remittance_internal.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q3):更正一笔代扣税缴纳。
--
-- 此前它的更正是在通用冲销口冲它的分录(Batch A 故意留着那扇门,因为没有别的路)。
-- 现在它走一张 wht_remittance_reversal 申请:财务提、CFO 批、财务执行,执行时调这里。
-- 那扇门(reverse_journal_entry 对 source_type = 'wht_remittance')同一刀关上。
--
-- 【它做的事与通用冲销口逐字相同】冲掉缴纳那张分录(reverse_journal_entry_internal,
-- 镜像反向行,source_type 照抄 'wht_remittance')。wht_remittances 那一行【不动】——
-- 它是只可追加的(WHT_REMITTANCE_IMMUTABLE)。它从"已汇"里掉出来,靠的是
-- wht_liability_by_month 只认分录仍是 posted 的缴纳:于是这个月的欠款原样回来。
-- fixture 142 G 臂断言的正是这一句。
--
-- 日期必填(FIN-10:不默认今天);已冲过的缴纳按名拒。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.reverse_wht_remittance_internal(p_remittance_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_w  wht_remittances%ROWTYPE;
    v_st text;
    v_je jsonb;
BEGIN
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;
    SELECT * INTO v_w FROM wht_remittances WHERE id = p_remittance_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_NOT_FOUND|%', COALESCE(p_remittance_id::text, '?');
    END IF;
    SELECT status INTO v_st FROM journal_entries WHERE id = v_w.journal_entry_id;
    IF v_st IS DISTINCT FROM 'posted' THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REVERSED|%', v_w.code;
    END IF;

    v_je := reverse_journal_entry_internal(v_w.journal_entry_id, p_reversal_date,
                COALESCE(p_memo, 'Reverse withholding tax remittance ' || v_w.code));

    RETURN jsonb_build_object('remittance_id', p_remittance_id, 'code', v_w.code,
                              'reversal_journal_code', v_je->>'code',
                              'reversal_entry_id', v_je->>'reversal_id');
END;
$function$
;

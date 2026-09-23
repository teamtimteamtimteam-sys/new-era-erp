-- db/functions/reverse_bank_transfer_internal.sql
-- PAY-REQ-1 · Batch B(2026-09-23):reverse_bank_transfer 的函数体搬到这里,拿掉了权限检查。
-- 原来的抬头照录:冲销一笔行内转账(FIN-1b B5:更正靠冲销,不靠改)。
-- 分录走 reverse_journal_entry_internal(镜像反向行,两边账户如数还原);
-- 转账行打上 reversed_* 标记,不许二次冲销。日期必填(FIN-10:不默认今天)。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.reverse_bank_transfer_internal(p_transfer_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t  bank_transfers%ROWTYPE;
    v_je jsonb;
BEGIN
    -- ★ PAY-REQ-1 Batch B:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回;
    --   唯一的外门是 pay_payment_request(一张已批准的 bank_transfer_reversal 申请)。
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_t FROM bank_transfers WHERE id = p_transfer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_NOT_FOUND|%', COALESCE(p_transfer_id::text, '?');
    END IF;
    IF v_t.reversed_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_REVERSED|%', p_transfer_id;
    END IF;

    v_je := reverse_journal_entry_internal(v_t.journal_entry_id,
                p_reversal_date,
                COALESCE(p_memo, 'Reverse bank transfer'));

    UPDATE bank_transfers
    SET reversed_at = now(), reversed_by = auth.uid(),
        reversal_entry_id = (v_je->>'reversal_id')::uuid
    WHERE id = p_transfer_id;

    RETURN jsonb_build_object('transfer_id', p_transfer_id,
                              'reversal_journal_code', v_je->>'code',
                              'reversal_entry_id', v_je->>'reversal_id');
END;
$function$;

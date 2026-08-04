-- db/functions/reverse_bank_transfer.sql
-- 冲销一笔行内转账(FIN-1b B5:更正靠冲销,不靠改)。
-- 分录走 reverse_journal_entry_internal(镜像反向行,两边账户如数还原);
-- 转账行打上 reversed_* 标记,不许二次冲销。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin1b-bank-transfers.sql.

CREATE OR REPLACE FUNCTION public.reverse_bank_transfer(p_transfer_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t  bank_transfers%ROWTYPE;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_t FROM bank_transfers WHERE id = p_transfer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_NOT_FOUND|%', COALESCE(p_transfer_id::text, '?');
    END IF;
    IF v_t.reversed_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_REVERSED|%', p_transfer_id;
    END IF;

    v_je := reverse_journal_entry_internal(v_t.journal_entry_id,
                COALESCE(p_reversal_date, CURRENT_DATE),
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

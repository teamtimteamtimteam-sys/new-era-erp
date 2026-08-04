-- db/migrations/2026-08-04-fin1b-bank-transfers.sql
-- FIN-1b(B 部分):行内转账。两边金额照银行水单(C4);分录两条银行线各记本币,
-- 两边对账单各自认领(B3)。跨币种不出汇兑损益行 —— 已实现差异的归属
-- (转账时点认列 vs 期末重估)是 Part C 的会计政策,待 Tim 与会计确认后另切。
-- Part D(按单据币种结算 + 汇兑损益科目)同样另切 —— 见提交说明。
BEGIN;

ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake','writeoff','payment','fx','expense','prepayment','payroll','transfer'));

CREATE TABLE public.bank_transfers (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_date    date NOT NULL,
    from_account     text NOT NULL CHECK (from_account IN ('1000','1010')),
    to_account       text NOT NULL CHECK (to_account IN ('1000','1010')),
    amount_out       numeric NOT NULL CHECK (amount_out > 0),   -- 源账户本币,照水单
    amount_in        numeric NOT NULL CHECK (amount_in > 0),    -- 目标账户本币,照水单
    bank_reference   text,
    notes            text,
    journal_entry_id uuid NOT NULL REFERENCES public.journal_entries (id),
    reversed_at      timestamptz,
    reversed_by      uuid,
    reversal_entry_id uuid REFERENCES public.journal_entries (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    CONSTRAINT bank_transfers_not_self CHECK (from_account <> to_account)
);

CREATE INDEX idx_bank_transfers_date ON public.bank_transfers (transfer_date);

ALTER TABLE public.bank_transfers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "bank_transfers select by permission"
    ON public.bank_transfers AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
CREATE POLICY "bank_transfers insert by permission"
    ON public.bank_transfers AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));
CREATE POLICY "bank_transfers update by permission"
    ON public.bank_transfers AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

COMMENT ON TABLE public.bank_transfers IS
    '行内转账。两边金额照银行实际;分录两条银行线各记本币,供两边对账单各自认领。更正靠 reverse_bank_transfer。';


CREATE OR REPLACE FUNCTION public.record_bank_transfer(p_transfer_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_from_ccy text;
    v_to_ccy   text;
    v_fx_out   numeric;
    v_fx_in    numeric;
    v_je       jsonb;
    v_id       uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    IF p_from_account IS NULL OR p_from_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_from_account, '?');
    END IF;
    IF p_to_account IS NULL OR p_to_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_to_account, '?');
    END IF;
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'TRANSFER_SAME_ACCOUNT|%', p_from_account;
    END IF;
    IF p_amount_out IS NULL OR p_amount_out <= 0 OR p_amount_in IS NULL OR p_amount_in <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_transfer_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    v_from_ccy := bank_native_currency(p_from_account);
    v_to_ccy   := bank_native_currency(p_to_account);

    -- 同币种:没有 FX 这回事,两边必须相等
    IF v_from_ccy = v_to_ccy AND p_amount_out <> p_amount_in THEN
        RAISE EXCEPTION 'TRANSFER_AMOUNTS_UNEQUAL|%|%', p_amount_out, p_amount_in;
    END IF;

    -- 本位币侧 fx=1;外币侧 fx=本笔实际隐含汇率(两边都是实际数,分录恰好配平)
    v_fx_out := CASE WHEN v_from_ccy = 'SGD' THEN 1 ELSE p_amount_in / p_amount_out END;
    v_fx_in  := CASE WHEN v_to_ccy   = 'SGD' THEN 1 ELSE p_amount_out / p_amount_in END;

    v_je := post_journal_entry(
        p_transfer_date,
        format('Transfer %s -> %s%s', p_from_account, p_to_account,
               CASE WHEN p_bank_reference IS NULL THEN '' ELSE ' (' || p_bank_reference || ')' END),
        'transfer',
        NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', p_to_account,   'side', 'debit',
                               'currency', v_to_ccy,   'amount_ccy', p_amount_in,  'fx_rate', v_fx_in),
            jsonb_build_object('account_code', p_from_account, 'side', 'credit',
                               'currency', v_from_ccy, 'amount_ccy', p_amount_out, 'fx_rate', v_fx_out)));

    INSERT INTO bank_transfers (transfer_date, from_account, to_account, amount_out, amount_in,
                                bank_reference, notes, journal_entry_id)
    VALUES (p_transfer_date, p_from_account, p_to_account, p_amount_out, p_amount_in,
            p_bank_reference, p_notes, (v_je->>'entry_id')::uuid)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('transfer_id', v_id, 'journal_code', v_je->>'code',
                              'entry_id', v_je->>'entry_id');
END;
$function$;

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

-- 新函数默认对 PUBLIC(含 anon)可执行 —— B1 断言抓的就是这个,当场收回
REVOKE EXECUTE ON FUNCTION public.record_bank_transfer(date, text, text, numeric, numeric, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reverse_bank_transfer(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_bank_transfer(date, text, text, numeric, numeric, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reverse_bank_transfer(uuid, date, text) TO authenticated, service_role;

COMMIT;

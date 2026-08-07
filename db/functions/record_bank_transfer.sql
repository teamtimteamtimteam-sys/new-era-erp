-- db/functions/record_bank_transfer.sql
-- 行内转账(FIN-1b)。两边金额照银行水单;分录两条银行线,各记各的本币 ——
-- 两个账户各自的对账单都要能认领自己那条(B3,本切的全部要点)。
-- 跨币种:外币线 fx = 实际隐含汇率(对方金额 ÷ 本方金额),分录恰好配平,
-- 【不出汇兑损益行】—— 已实现差异的归属是 Part C 待定的会计政策,这里不预设。
-- 同币种:两边必须相等(不然配不平;手续费另有各自的记法),fx 恒 1,零汇率依赖。
-- 期间锁由 post_journal_entry 统一把守(PERIOD_LOCKED)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin1b-bank-transfers.sql.

CREATE OR REPLACE FUNCTION public.record_bank_transfer(p_transfer_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base     text;   -- OPS-8:本位币从 currencies.is_base 读
    v_from_ccy text;
    v_to_ccy   text;
    v_fx_out   numeric;
    v_fx_in    numeric;
    v_je       jsonb;
    v_id       uuid;
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
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
    v_fx_out := CASE WHEN v_from_ccy = v_base THEN 1 ELSE p_amount_in / p_amount_out END;
    v_fx_in  := CASE WHEN v_to_ccy   = v_base THEN 1 ELSE p_amount_out / p_amount_in END;

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
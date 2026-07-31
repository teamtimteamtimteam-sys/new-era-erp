CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_batch     record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_available numeric;
    v_value     numeric;
    v_settled   numeric;
    v_open      numeric;
    v_app_id    uuid := gen_random_uuid();
    v_je        jsonb;
BEGIN
    SELECT po.id, po.code, po.supplier_id, po.status
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT ib.id, ib.code, ib.supplier_id, ib.quantity, ib.unit_price
    INTO v_batch
    FROM inbound_batches ib
    WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF v_batch.unit_price IS NULL THEN
        RAISE EXCEPTION 'INBOUND_UNPRICED|%', v_batch.code;
    END IF;
    IF v_batch.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
        RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_batch.code;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- 可用预付 = 已付到该 PO 的预付(仅 posted 收付款) − 已冲抵的部分
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    SELECT COALESCE(SUM(ppa.amount_usd), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF p_amount > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, p_amount;
    END IF;

    -- 批次敞口 = 当前批次价值 − 收付款核销 − 已冲抵的预付
    v_value := round(v_batch.quantity * v_batch.unit_price, 2);
    SELECT COALESCE(SUM(pa.allocated_usd), 0) INTO v_settled
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.inbound_batch_id = p_inbound_batch_id;
    v_settled := v_settled + COALESCE(
        (SELECT SUM(ppa.amount_usd) FROM prepayment_applications ppa
          WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
    v_open := round(v_value - v_settled, 2);
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- 分录:预付转为对该批次应付的清偿(钱早就出去了,这里只是科目之间的搬运)
    v_je := post_journal_entry(
        CURRENT_DATE,
        'Prepayment applied ' || v_po.code || ' → ' || v_batch.code,
        'prepayment', v_app_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2000', 'side', 'debit',  'currency', 'USD', 'amount_ccy', p_amount, 'fx_rate', 1),
            jsonb_build_object('account_code', '1300', 'side', 'credit', 'currency', 'USD', 'amount_ccy', p_amount, 'fx_rate', 1)));

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, amount_usd,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'amount_usd', p_amount,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - p_amount, 2)
    );
END;
$function$

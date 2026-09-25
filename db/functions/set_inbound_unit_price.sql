CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ★ ROLE-1 Batch 4a:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');
    -- ★ ROLE-1 Batch 4b(Tim 的 Q8):定价面板从此【提一张申请】,不再直接过账 —— CFO 批了才进账。
    --   审批关着时申请生下来就是 approved 并当场过账(receipt_price_submit_internal)。
    --   汇率仍不由调用方递入(引擎的 FX_RATE_NOT_ACCEPTED,这里在写入之前就说)。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    RETURN receipt_price_submit_internal(p_inbound_batch_id, p_unit_price, p_currency, 'manual',
                                         NULL, NULL, p_notes);
END;
$function$;
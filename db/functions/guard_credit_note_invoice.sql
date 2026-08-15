CREATE OR REPLACE FUNCTION public.guard_credit_note_invoice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
BEGIN
    SELECT * INTO v_inv FROM invoices WHERE id = NEW.invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_FOUND|%', COALESCE(NEW.invoice_id::text, '?');
    END IF;
    -- 【只对订单流发票】sale 型什么都不过账,它的应收长在 sales_records 上 ——
    -- 给它开一张贷项凭证会得到一笔冲着【不存在的分录】的分录。
    IF v_inv.kind <> 'order' THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_ORDER_KIND|%|%', v_inv.code, v_inv.kind;
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'CN_INVOICE_VOID|%', v_inv.code;
    END IF;
    -- 【抄过来的必须真的是抄的】见抬头:换个汇率冲会在本位币上留下一截
    -- 与真实已实现汇兑长得一模一样、却没有任何钱动过的残渣。
    IF NEW.currency IS DISTINCT FROM v_inv.currency THEN
        RAISE EXCEPTION 'CN_BASIS_MISMATCH|currency|%|%', v_inv.currency, NEW.currency;
    END IF;
    IF NEW.fx_rate IS DISTINCT FROM v_inv.fx_rate THEN
        RAISE EXCEPTION 'CN_BASIS_MISMATCH|fx_rate|%|%', v_inv.fx_rate, NEW.fx_rate;
    END IF;
    RETURN NEW;
END;
$function$

;

CREATE OR REPLACE FUNCTION public.guard_po_vendor_not_forwarder()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
    v_name text;
BEGIN
    SELECT counterparty_type, code, legal_name INTO v_type, v_code, v_name
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type = 'forwarder' THEN
        RAISE EXCEPTION 'PO_VENDOR_IS_A_FORWARDER|%|%', COALESCE(v_code, ''), COALESCE(v_name, '')
          USING HINT = '货代不能当采购单的供应商 —— 运费走运费凭证,不走采购单';
    END IF;
    RETURN NEW;
END;
$function$


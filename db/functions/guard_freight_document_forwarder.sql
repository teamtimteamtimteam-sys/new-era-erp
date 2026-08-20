CREATE OR REPLACE FUNCTION public.guard_freight_document_forwarder()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_type text; v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'FREIGHT_SUPPLIER_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.supplier_id::text)
          USING HINT = '运费的对手方只能是货代 —— 记到材料供应商名下,分录照样是平的,而钱记在了错的人头上';
    END IF;
    RETURN NEW;
END;
$function$


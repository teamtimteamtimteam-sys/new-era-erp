CREATE OR REPLACE FUNCTION public.guard_forwarder_details_is_forwarder()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.supplier_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'FORWARDER_DETAILS_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.supplier_id::text)
          USING HINT = '这一家不是货代,给它挂物流属性没有意义 —— 先把 counterparty_type 改成 forwarder';
    END IF;
    RETURN NEW;
END;
$function$


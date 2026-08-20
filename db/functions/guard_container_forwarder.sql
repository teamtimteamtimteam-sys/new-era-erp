CREATE OR REPLACE FUNCTION public.guard_container_forwarder()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_type text; v_code text;
BEGIN
    IF NEW.forwarder_id IS NULL THEN RETURN NEW; END IF;
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.forwarder_id;
    IF v_type IS DISTINCT FROM 'forwarder' THEN
        RAISE EXCEPTION 'CONTAINER_FORWARDER_NOT_A_FORWARDER|%', COALESCE(v_code, NEW.forwarder_id::text)
          USING HINT = '这一家不是货代;箱子的承运方只能挂在货代身上';
    END IF;
    RETURN NEW;
END;
$function$


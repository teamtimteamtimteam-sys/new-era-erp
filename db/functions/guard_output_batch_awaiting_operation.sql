CREATE OR REPLACE FUNCTION public.guard_output_batch_awaiting_operation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_saleable boolean;
BEGIN
    IF NEW.awaiting_operation_type_code IS NULL THEN
        RETURN NEW;   -- 【空永远合法】它的意思是"还没决定等哪道"。
    END IF;

    SELECT p.is_saleable_stock INTO v_saleable
      FROM public.output_batch_purposes p WHERE p.code = NEW.purpose_code;

    IF v_saleable IS NOT FALSE THEN
        RAISE EXCEPTION 'WIP_AWAITING_ON_SALEABLE_BATCH|%|%',
            NEW.code, NEW.purpose_code
          USING HINT = '一批【可售库存】不会在等任何工序 —— 要让它等一道工序,先把它的用途改成【下游工序投料】。留着这一列指向一道工序,会造出一个"既可售、又在排队"的自相矛盾行。';
    END IF;
    RETURN NEW;
END;
$function$

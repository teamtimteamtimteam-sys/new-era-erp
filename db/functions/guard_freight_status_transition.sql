CREATE OR REPLACE FUNCTION public.guard_freight_status_transition()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
        RETURN NEW;
    END IF;
    IF COALESCE(current_setting('evoltrya.freight_reverse_ctx', true), '') <> '1' THEN
        RAISE EXCEPTION 'FREIGHT_STATUS_NO_DIRECT_UPDATE|%|%->%',
            COALESCE(NEW.code, OLD.code, '?'), OLD.status, NEW.status
          USING HINT = '运费单的状态只能由 reverse_freight_document 改 —— 它会记下理由、经手人,并冲掉那张分录';
    END IF;
    RETURN NEW;
END;
$function$


CREATE OR REPLACE FUNCTION public.guard_stocktake_no_hard_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 【消息里点名的是那份【单据】】—— 明细行没有自己的号,它报父单的号,
    -- 因为读到这句话的人要去找的是那张盘点单,不是一个行 id。
    IF TG_TABLE_NAME = 'stocktakes' THEN
        v_code := OLD.code;
    ELSE
        SELECT s.code INTO v_code FROM stocktakes s WHERE s.id = OLD.stocktake_id;
    END IF;
    RAISE EXCEPTION 'STOCKTAKE_NO_HARD_DELETE|%', COALESCE(v_code, '?');
END;
$function$;

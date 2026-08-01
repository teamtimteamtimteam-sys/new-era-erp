CREATE OR REPLACE FUNCTION public.cancel_stocktake(p_stocktake_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_status  text;
    v_deleted timestamptz;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT status, deleted_at INTO v_status, v_deleted
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_status;
    END IF;

    UPDATE stocktakes
    SET status = 'cancelled', updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;
END;
$function$;
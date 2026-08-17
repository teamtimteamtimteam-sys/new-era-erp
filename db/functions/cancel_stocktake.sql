CREATE OR REPLACE FUNCTION public.cancel_stocktake(p_stocktake_id uuid, p_reason text)
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

    -- AUDEL-1b:【理由必填】此前这个函数一个 why 都不记 —— 只把 status 改成
    -- cancelled。一次作废掉的盘点是"我们数过、然后决定不算数"的记录,
    -- 而"为什么不算数"正是审计要问的那一句。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'STOCKTAKE_CANCEL_REASON_REQUIRED|%',
            (SELECT code FROM stocktakes WHERE id = p_stocktake_id);
    END IF;

    UPDATE stocktakes
    SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
        cancel_reason = btrim(p_reason), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;
END;
$function$;

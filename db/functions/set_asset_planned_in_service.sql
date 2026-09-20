CREATE OR REPLACE FUNCTION public.set_asset_planned_in_service(p_asset_id uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_a fixed_assets%ROWTYPE;
BEGIN
    -- 【按名拒】这张表从来没有过的那一半:RLS 的零行是静默的,这一句不是。
    PERFORM require_permission('module.finance.edit');

    -- p_date 允许为 NULL(= 撤掉计划)—— 见抬头。这里【故意】没有 DATE_REQUIRED。
    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;

    -- ⚠ 只写这一列。in_service_date 是另一件事,见抬头那一节。
    UPDATE fixed_assets SET planned_in_service_date = p_date WHERE id = p_asset_id;

    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_a.code,
                              'planned_in_service_date', p_date);
END;
$function$;

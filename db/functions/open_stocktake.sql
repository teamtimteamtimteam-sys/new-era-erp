-- db/functions/open_stocktake.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q3 · Q4):开一张盘点单。
-- 开单是录数的第一步,所以门是 action.stocktake_count(仓库与 admin)。
-- 开单人由 auth.uid() 写 —— 此前 createStocktake 直连 INSERT、created_by 由客户端送,
-- 而 post_stocktake 四眼的那条腿认的正是它。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.open_stocktake(p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
BEGIN
    PERFORM require_permission('action.stocktake_count');

    INSERT INTO stocktakes (notes, created_by, updated_by)
    VALUES (NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user, v_user)
    RETURNING id, code INTO v_id, v_code;

    RETURN jsonb_build_object('stocktake_id', v_id, 'code', v_code);
END;
$function$;

COMMENT ON FUNCTION public.open_stocktake(text) IS
'ROLE-1 Batch 3a:开一张盘点单(action.stocktake_count)。开单人由 auth.uid() 写,不经客户端;开单人永远不能过账这一张(post_stocktake)。';

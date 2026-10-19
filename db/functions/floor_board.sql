-- db/functions/floor_board.sql
-- MES-8b-2(2026-10-17,MES-0 Q83 · MES-8 Step 0 Q19 · Q20,Tim):【车间大屏读的那一支】—— 每一支车间支此刻有几件事在等人,只有数。
--   门 data.view_floor_board(floor_display 与 admin、cfo 持)。SECURITY DEFINER:读 operations_arms_all(基视图,不给人读)按支计数 ——
--   不能读 operations_now,那张视图按【调用者】的码逐支裁决,一块只持大屏码的屏读它是零行。
--   ★【只吐计数】:每一块牌子 {section, item_type, count};不吐 subject、item_code、item_id、日子、名字、钱或健康信息(fixture 273 COUNTS
--     逐键核对返回的形状 —— 多一个键就红)。
--   ★ V28(floor_board_settings):没给时画 floor_board_arms() 的全部二十三支,按分节的顺序,refresh_seconds 为空 —— 页面不自动刷新;
--     给了之后只画 tiles 里那几支、按 tiles 的顺序,并带回 refresh_seconds。
--   as_of = 这一次数的时刻(页面据此写「refreshed at hh:mm」,新加坡时间)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.floor_board()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_refresh integer;
    v_tiles   text[];
    v_board   jsonb;
BEGIN
    PERFORM require_permission('data.view_floor_board');
    SELECT s.refresh_seconds, s.tiles INTO v_refresh, v_tiles FROM floor_board_settings s WHERE s.id;

    WITH counts AS (
        SELECT a.item_type, count(*) AS n
          FROM operations_arms_all a
         WHERE a.item_type IN (SELECT f.item_type FROM floor_board_arms() f)
         GROUP BY a.item_type
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object('section', f.section, 'item_type', f.item_type, 'count', COALESCE(c.n, 0))
                              ORDER BY CASE WHEN v_tiles IS NULL THEN f.sort_order ELSE array_position(v_tiles, f.item_type) END), '[]'::jsonb)
      INTO v_board
      FROM floor_board_arms() f
      LEFT JOIN counts c ON c.item_type = f.item_type
     WHERE v_tiles IS NULL OR f.item_type = ANY (v_tiles);

    RETURN jsonb_build_object(
        'as_of', now(),
        'tiles', v_board,
        'refresh_seconds', v_refresh,
        'settings_set', v_tiles IS NOT NULL AND v_refresh IS NOT NULL);
END;
$function$;

-- db/functions/set_floor_board_settings.sql
-- MES-8b-2(2026-10-17,MES-0 §5.1 V28 · MES-8 Step 0 Q20,Tim):【给 / 清 V28】—— 大屏自己刷新的间隔(秒)与画哪几块牌子(按顺序)。
--   门 action.manage_permissions(建大屏账号的人 —— 本刀不加新码,Q29)。两样【一起给、一起清】:只给一半按名拒
--   (FLOOR_BOARD_SETTINGS_PAIR_INCOMPLETE —— 一个只有牌子没有间隔的大屏,读起来像设好了而它不会自己刷新)。
--   牌子只能是 floor_board_arms() 里的支(FLOOR_BOARD_TILE_UNKNOWN|<支>),不许重复(FLOOR_BOARD_TILE_DUPLICATE|<支>),不许空(FLOOR_BOARD_TILES_EMPTY);
--   间隔必须是正数(FLOOR_BOARD_REFRESH_INVALID)—— 只是形状,不是一个替人挑的数。返回改后的那一行。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.set_floor_board_settings(p_refresh_seconds integer, p_tiles text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_bad text;
    r     floor_board_settings%ROWTYPE;
BEGIN
    PERFORM require_permission('action.manage_permissions');
    IF (p_refresh_seconds IS NULL) <> (p_tiles IS NULL) THEN
        RAISE EXCEPTION 'FLOOR_BOARD_SETTINGS_PAIR_INCOMPLETE';
    END IF;
    IF p_refresh_seconds IS NOT NULL THEN
        IF p_refresh_seconds <= 0 THEN
            RAISE EXCEPTION 'FLOOR_BOARD_REFRESH_INVALID';
        END IF;
        IF cardinality(p_tiles) IS NULL OR cardinality(p_tiles) = 0 THEN
            RAISE EXCEPTION 'FLOOR_BOARD_TILES_EMPTY';
        END IF;
        SELECT t INTO v_bad FROM unnest(p_tiles) t
         WHERE t IS NULL OR NOT EXISTS (SELECT 1 FROM floor_board_arms() f WHERE f.item_type = t) LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'FLOOR_BOARD_TILE_UNKNOWN|%', COALESCE(v_bad, '');
        END IF;
        SELECT t INTO v_bad FROM unnest(p_tiles) t GROUP BY t HAVING count(*) > 1 LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'FLOOR_BOARD_TILE_DUPLICATE|%', v_bad;
        END IF;
    END IF;
    UPDATE floor_board_settings SET refresh_seconds = p_refresh_seconds, tiles = p_tiles, updated_by = auth.uid()
     WHERE id RETURNING * INTO r;
    RETURN to_jsonb(r);
END;
$function$;

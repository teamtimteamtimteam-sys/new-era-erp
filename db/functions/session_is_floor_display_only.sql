-- db/functions/session_is_floor_display_only.sql
-- MES-8b-2(2026-10-17,MES-0 Q83 · MES-8 Step 0 Q19,Tim):【这个会话是不是一块大屏】—— 空闲登出的唯一一处豁免,与「别的页一律拒」,判据都只在这里。
--   真 ⇔ 会话的角色【恰好】是 {floor_display} 且码【恰好】是 {data.view_floor_board}。
--   角色一侧与 current_user_permissions() 用同一组条件(授权没撤 · 角色在用 · 角色没删),所以"有哪些角色"与"有哪些码"不会各说各话。
--   多一个角色(哪怕那个角色一个码都没有)或 floor_display 多一个码 → 假:这个账号照常空闲登出、照常按码进页面。
--   ★ IDLE-DRAFT 那条「一个值,不分角色」只在这一种情形下被 Q83 取代(Tim 2026-10-17 的 Q19),别的一律照旧。
--   ★ 判据在【服务端】:由会话自己的 auth.uid() 求值,浏览器送来的任何东西都不参与(中间件只在一次请求已经判成空闲过期时才问它,
--     页面只在会话的码恰好是那一个时才问它 —— 别的会话一次都不多问)。
--   没有会话 → 假。读的只是调用者自己的授权,所以对 authenticated 开放。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.session_is_floor_display_only()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT auth.uid() IS NOT NULL
       AND COALESCE((SELECT array_agg(DISTINCT r.code ORDER BY r.code)
                       FROM user_roles ur
                       JOIN roles r ON r.id = ur.role_id
                      WHERE ur.user_id = auth.uid()
                        AND ur.revoked_at IS NULL
                        AND r.is_active
                        AND r.deleted_at IS NULL), ARRAY[]::text[]) = ARRAY['floor_display']::text[]
       AND current_user_permissions() = ARRAY['data.view_floor_board']::text[];
$function$;

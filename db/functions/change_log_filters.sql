-- db/functions/change_log_filters.sql
-- HISTORY-1:/settings/change-history 下拉的选项。门与 change_log_rows 相同。
--   tables —— 挂着记录触发器的表 + 'auth.users'(账号事件)。AUDIT-TRAIL-1a 起界面不再印它们,而是按
--             lib/trail/tables.ts 翻成英文的"Area"与"Record type";这里仍给出那张闭合的名单,界面拿它对账。
--   actors —— 记录里出现过的每一个账号(HISTORY-1 的形状,旧页面在破窗期间还读它)。
--   people —— AUDIT-TRAIL-1a(Tim 的 Q14 · Q30):"Who"下拉按【人】列,名字是称呼名、没有就法定名;
--             外加两项:有没有无会话的写("System (automatic)")、有没有账号与人都已不在的写("Removed account")。
CREATE OR REPLACE FUNCTION public.change_log_filters()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_change_log');
    RETURN jsonb_build_object(
        'tables', (SELECT COALESCE(jsonb_agg(x.t ORDER BY x.t), '[]'::jsonb) FROM (
                      SELECT c.relname::text AS t
                        FROM pg_trigger tg
                        JOIN pg_class c ON c.oid = tg.tgrelid
                        JOIN pg_namespace n ON n.oid = c.relnamespace
                       WHERE n.nspname = 'public' AND tg.tgname = 'zzz_change_log'
                      UNION SELECT 'auth.users') x),
        'actors', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                          'account', a.actor_account, 'email', u.email::text,
                          'employee_code', e.code, 'employee_name', COALESCE(e.preferred_name, e.legal_name))
                        ORDER BY u.email::text NULLS LAST, a.actor_account), '[]'::jsonb)
                     FROM (SELECT DISTINCT ON (cl.actor_account) cl.actor_account, cl.actor_employee
                             FROM change_log cl
                            WHERE cl.actor_account IS NOT NULL
                            ORDER BY cl.actor_account, cl.seq DESC) a
                     LEFT JOIN auth.users u ON u.id = a.actor_account
                     LEFT JOIN employees e ON e.id = a.actor_employee),
        'people', (SELECT COALESCE(jsonb_agg(jsonb_build_object('employee', p.actor_employee, 'actor', p.who)
                        ORDER BY p.who ->> 'name' NULLS LAST, p.actor_employee), '[]'::jsonb)
                     FROM (SELECT DISTINCT cl.actor_employee,
                                  trail_actor('user', NULL, cl.actor_employee) AS who
                             FROM change_log cl WHERE cl.actor_employee IS NOT NULL) p),
        'has_system', EXISTS (SELECT 1 FROM change_log cl WHERE cl.actor_kind = 'no_session'),
        'has_removed', EXISTS (SELECT 1 FROM change_log cl
                                WHERE cl.actor_kind = 'user' AND cl.actor_employee IS NULL
                                  AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = cl.actor_account)));
END;
$function$;

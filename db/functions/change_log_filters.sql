-- db/functions/change_log_filters.sql
-- HISTORY-1:/settings/change-history 两个下拉的选项 —— 表(挂着记录触发器的表 + 'auth.users' 账号事件)
-- 与人(记录里出现过的每一个账号,带邮箱与它最近一次记下的员工)。门与 change_log_rows 相同。
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
                     LEFT JOIN employees e ON e.id = a.actor_employee));
END;
$function$;

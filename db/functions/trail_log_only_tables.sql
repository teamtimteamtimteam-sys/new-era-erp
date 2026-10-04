-- db/functions/trail_log_only_tables.sql
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 的 Q2 —— M9):【只在变更记录里出现】的表 —— 它不在 public 里,
--   读法(record_trail)平常够不到它,而它的事件(账号建立、停用、恢复……)只写在 change_log 里(record_account_event)。
--   第一个、也是唯一一个:auth.users,每个账号的审计记录(/settings/accounts,AT-0 的 Q24)。
--   每一行说三件事:
--     schema_name · rel_name  它真正住在哪里(trail_current_image 照这个名字去读今天那一份);
--     image_columns           【只许读这几列】—— 一份固定的安全投影。整行 to_jsonb(auth 那一行)会把 encrypted_password
--                             与六支令牌列带进审计记录的上下文(Step 0 C §A3 实测),所以这里逐列点名,别的一列都不碰;
--     read_code               谁读得到这种行:一个【声明出来的】码,代替那张表的读策略(它不在 public 里,
--                             trail_row_visible 读不到它的策略)—— 与 user_directory 的谓词同一个码。
-- 【读它的人】trail_current_image · trail_row_visible · record_trail(都是属主身份)· scripts/check-trail-wording.mjs(解析投影,
--   当作这张表的"列")。加一行之前先问:那张表有没有一列不该进审计记录?有,就不要放进 image_columns。
CREATE OR REPLACE FUNCTION public.trail_log_only_tables()
 RETURNS TABLE(table_name text, schema_name text, rel_name text, image_columns text[], read_code text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('auth.users', 'auth', 'users', ARRAY['id', 'email', 'created_at', 'banned_until'], 'action.manage_permissions')
    ) AS l(table_name, schema_name, rel_name, image_columns, read_code);
$function$;

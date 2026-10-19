-- db/functions/set_account_setting.sql
-- MES-9a(2026-10-19,MES-9 Step 0 §9 · Q24 · Q26,Tim):【给 / 清 V38 与 V40】—— 两个账号那一侧的待补的值,一次一个。
--   V38 initial_password_valid_days  一个当面交出去的初始密码,在第一次登录之前有效几天(正整数)。
--   V40 password_min_length          项目的密码最短长度(Supabase 的项目设置,今天是 6)—— Tim 在 Supabase 改了之后,在这里记下他定的那个数(≥ 6)。
--   门 action.manage_permissions(建账号、管账号的那个人)。键不认识 → ACCOUNT_SETTING_UNKNOWN|<键>;值不合形状 → ACCOUNT_SETTING_INVALID|<键>
--   (只是形状,不是一个替人挑的数)。p_value 为空 = 清掉。返回改后的那一行。
--   ★ 两个值【今天都不被执行】:V38 给了之后,屏幕照直说它是多少天、而系统还不按它拒绝登录(MES9A-V38-NOT-ENFORCED);
--     V40 是 Supabase 那一侧的设置,这里记的是 Tim 定的数,不改 Supabase(MES9A-V40-IS-A-RECORD)。见 docs/known-issues.md。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.set_account_setting(p_key text, p_value integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r account_settings%ROWTYPE;
BEGIN
    PERFORM require_permission('action.manage_permissions');
    IF p_key = 'initial_password_valid_days' THEN
        IF p_value IS NOT NULL AND p_value <= 0 THEN
            RAISE EXCEPTION 'ACCOUNT_SETTING_INVALID|%', p_key;
        END IF;
        UPDATE account_settings SET initial_password_valid_days = p_value, updated_by = auth.uid() WHERE id RETURNING * INTO r;
    ELSIF p_key = 'password_min_length' THEN
        IF p_value IS NOT NULL AND p_value < 6 THEN
            RAISE EXCEPTION 'ACCOUNT_SETTING_INVALID|%', p_key;
        END IF;
        UPDATE account_settings SET password_min_length = p_value, updated_by = auth.uid() WHERE id RETURNING * INTO r;
    ELSE
        RAISE EXCEPTION 'ACCOUNT_SETTING_UNKNOWN|%', COALESCE(p_key, '');
    END IF;
    RETURN to_jsonb(r);
END;
$function$;

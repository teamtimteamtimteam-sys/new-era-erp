-- NOROLE-SURFACE Step 0, step 1 — sign-up closed: who exists in auth.users (read-only; as postgres, rolbypassrls = true, base tables).
-- Run: psql "<pooler dsn>" -X -At -v ON_ERROR_STOP=1 -f docs/surveys/NOROLE-SURFACE/signup-readings.sql
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'WHO|' || current_user || '|bypassrls=' || (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user);
SELECT 'ACCOUNTS|' || count(*) || '|banned=' || count(*) FILTER (WHERE banned_until > now()) || '|deleted=' || count(*) FILTER (WHERE deleted_at IS NOT NULL)
    || '|anonymous=' || count(*) FILTER (WHERE is_anonymous) || '|max_created=' || to_char(max(created_at) AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS')
  FROM auth.users;
SELECT 'ACCOUNT|' || u.email || '|' || u.id || '|created=' || to_char(u.created_at AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD')
    || '|banned=' || COALESCE(u.banned_until > now(), false)
    || '|roles=' || COALESCE((SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                              WHERE ur.user_id = u.id AND ur.revoked_at IS NULL), '-')
  FROM auth.users u ORDER BY u.email;
SELECT 'IDENTITIES|' || provider || '|' || count(*) FROM auth.identities GROUP BY provider ORDER BY 1;
SELECT 'USERS_SINCE_STEP0|' || count(*) FROM auth.users WHERE created_at > '2026-10-19 02:21:00+00';
ROLLBACK;

-- MES-8b-2 close-out — residue reading after the probes (read-only, as postgres, rolbypassrls = true, base tables + storage + auth)
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'THROWAWAY_ACCOUNTS|' || count(*) FROM auth.users WHERE email LIKE '%@test.local';
SELECT 'ACCOUNTS|' || count(*) || '|banned=' || count(*) FILTER (WHERE banned_until IS NOT NULL AND banned_until > now()) FROM auth.users;
SELECT 'PROBE_ROLES|' || count(*) FROM roles WHERE code LIKE 'probe-%';
SELECT 'FLOOR_HOLDERS|' || count(*) FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = 'floor_display';
SELECT 'ORPHAN_GRANTS|' || count(*) FROM user_roles ur WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id);
SELECT 'AVATAR_OBJECTS_OF_NONEXISTENT_USERS|' || count(*) FROM storage.objects o WHERE o.bucket_id = 'avatars'
   AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE o.name = u.id::text || '.webp');
SELECT 'LOCATIONS|' || count(*) || '|zz=' || count(*) FILTER (WHERE code LIKE 'ZZ%' OR name LIKE 'ZZ close-out%') FROM storage_locations;
SELECT 'CL_SINCE_SESSION_BY|' || table_name || '|' || op || '|' || count(*) FROM change_log WHERE occurred_at >= '2026-10-19 09:59:02+08' GROUP BY table_name, op ORDER BY 1;
SELECT 'CL_MAX|' || count(*) || '|max_seq=' || max(seq) FROM change_log;
SELECT 'APPROVALS|enabled=' || approvals_enabled || '|l1=' || approval_level1_role_code || '|l2=' || approval_level2_role_code || '|threshold=' || approval_threshold_base FROM finance_settings;
SELECT 'CALIB|' || COALESCE(require_calibrated_since::text, 'NULL') FROM ingest_settings;
SELECT 'COD_OBJECTS|' || (o.metadata ->> 'size') || '|' || (o.metadata ->> 'eTag') FROM storage.objects o WHERE o.bucket_id = 'cod-documents' ORDER BY o.name;
SELECT 'PENDING|' || COALESCE(string_agg(d.code, ','), '-') FROM approval_pending_documents() d;
ROLLBACK;

-- SYSTEM-MAP-2 Step 0.2 · 只读勘察:以 postgres(rolbypassrls)读基表与目录;不写任何东西
SELECT 'PROOF|notif_writer|' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prosrc ~* 'insert\s+into\s+(public\.)?notifications' ORDER BY 1;
SELECT 'PROOF|notif_cols|' || string_agg(attname || ':' || format_type(atttypid, atttypmod), ', ' ORDER BY attnum)
  FROM pg_attribute WHERE attrelid='public.notifications'::regclass AND attnum>0 AND NOT attisdropped;
SELECT 'PROOF|notif_rows|' || event_type || '=' || count(*) FROM notifications GROUP BY event_type;
SELECT 'PROOF|notif_reads|' || count(*) FROM notification_reads;
SELECT 'PROOF|role_codes|' || r.code || '|' || string_agg(rp.permission_code, ',' ORDER BY rp.permission_code)
  FROM roles r JOIN role_permissions rp ON rp.role_id=r.id GROUP BY r.code ORDER BY r.code;
SELECT 'PROOF|holders|' || r.code || '=' || count(*) FROM user_roles ur JOIN roles r ON r.id=ur.role_id WHERE ur.revoked_at IS NULL GROUP BY r.code ORDER BY 1;

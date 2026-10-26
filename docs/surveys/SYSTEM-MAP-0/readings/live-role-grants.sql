-- SYSTEM-MAP-0 Part 3.2 · 线上角色授权,只读(postgres,rolbypassrls,基表 roles / role_permissions / user_roles)
-- 输出:每个有在册持有人(user_roles.revoked_at IS NULL)的角色 × 它持的每一个权限码,一行一对。
SELECT 'HOLDERS|' || r.code || '|' || count(DISTINCT ur.user_id)
  FROM roles r JOIN user_roles ur ON ur.role_id = r.id AND ur.revoked_at IS NULL
 GROUP BY r.code ORDER BY r.code;
SELECT 'GRANT|' || r.code || '|' || rp.permission_code
  FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
 WHERE r.code IN ('admin','cfo','cco','cto','finance','gm','warehouse')
 ORDER BY r.code, rp.permission_code;

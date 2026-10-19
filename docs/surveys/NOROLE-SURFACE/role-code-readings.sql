-- NOROLE-SURFACE Step 0 — which code each live role holds, and who holds each role (read-only; as postgres, rolbypassrls = true, base tables).
BEGIN READ ONLY;
SELECT 'NOW|' || to_char(now() AT TIME ZONE 'Asia/Singapore', 'YYYY-MM-DD HH24:MI:SS') || ' CST';
SELECT 'ROLE|' || r.code || '|active=' || r.is_active || '|deleted=' || (r.deleted_at IS NOT NULL) || '|holders='
    || (SELECT count(*) FROM user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL)
    || '|codes=' || (SELECT count(*) FROM role_permissions rp WHERE rp.role_id = r.id) FROM roles r ORDER BY r.code;
SELECT 'HOLDS|' || r.code || '|' || string_agg(p.code, ',' ORDER BY p.code) FROM roles r JOIN role_permissions rp ON rp.role_id = r.id
  JOIN permissions p ON p.code = rp.permission_code
 WHERE EXISTS (SELECT 1 FROM user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL) GROUP BY r.code ORDER BY r.code;
SELECT 'VIEWCODE|' || p.code || '|' || COALESCE((SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
    WHERE rp.permission_code = p.code AND EXISTS (SELECT 1 FROM user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL)), '-')
  FROM permissions p WHERE p.code LIKE 'module.%.view' OR p.code IN ('action.manage_permissions', 'action.metal_prices', 'data.view_prices',
       'data.view_purchase_prices', 'action.finance_settings', 'module.finance.edit', 'module.suppliers.edit', 'module.customers.edit',
       'module.materials.edit', 'module.purchasing.edit', 'module.sales.edit', 'action.ship_goods') ORDER BY p.code;
SELECT 'PERM_COLS|' || string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'permissions';
SELECT 'FN_HAS_PERMISSION|' || regexp_replace(pg_get_functiondef('public.has_permission(text)'::regprocedure), '\s+', ' ', 'g');
SELECT 'FN_CURRENT_USER_PERMISSIONS|' || regexp_replace(pg_get_functiondef('public.current_user_permissions()'::regprocedure), '\s+', ' ', 'g');
ROLLBACK;

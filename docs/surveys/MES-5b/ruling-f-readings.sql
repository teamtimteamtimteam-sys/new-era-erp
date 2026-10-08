-- MES-5a-2 close-out ruling f (option A) · read-only check on live (2026-10-08). Run as postgres (rolbypassrls = true) over direct psql
-- to the pooler; base tables only; BEGIN READ ONLY … ROLLBACK.
-- For every role with a live (non-revoked) holder: each action / edit code used on a MES-5a-2 page, and whether the role also holds the
-- view code of that page's gate. Pages and gates (lib/modules.ts): /operation/devices[/id] = module.processing.view (FN.devices);
-- /operation/processing/[id] = module.processing.view (MOD.processing); /finance/electricity[/new,/id] = module.finance.view (MOD.finance).
BEGIN READ ONLY;
WITH pairs(action_code, view_code, page) AS (VALUES
    ('action.manage_devices',      'module.processing.view', '/operation/devices/[id]'),
    ('action.confirm_capture',     'module.processing.view', '/operation/devices/[id]'),
    ('action.processing_commit',   'module.processing.view', '/operation/processing/[id]'),
    ('action.processing_rollback', 'module.processing.view', '/operation/processing/[id]'),
    ('action.processing_aftercare','module.processing.view', '/operation/processing/[id]'),
    ('module.processing.edit',     'module.processing.view', '/operation/processing/[id]'),
    ('module.finance.edit',        'module.finance.view',    '/finance/electricity')),
live_roles AS (
    SELECT r.id, r.code, string_agg(u.email, ' ' ORDER BY u.email) AS holders
      FROM roles r JOIN user_roles ur ON ur.role_id = r.id AND ur.revoked_at IS NULL JOIN auth.users u ON u.id = ur.user_id
     WHERE r.is_active AND r.deleted_at IS NULL
     GROUP BY r.id, r.code)
SELECT lr.code AS role, lr.holders, p.action_code, p.page, p.view_code,
       EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = lr.id AND rp.permission_code = p.view_code) AS holds_view
  FROM live_roles lr CROSS JOIN pairs p
 WHERE EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = lr.id AND rp.permission_code = p.action_code)
 ORDER BY lr.code, p.action_code;
SELECT r.code AS role, count(*) FILTER (WHERE rp.permission_code IN ('action.manage_devices','action.confirm_capture','action.processing_commit',
         'action.processing_rollback','action.processing_aftercare','module.processing.edit','module.finance.edit')) AS action_codes_held
  FROM roles r JOIN user_roles ur ON ur.role_id = r.id AND ur.revoked_at IS NULL LEFT JOIN role_permissions rp ON rp.role_id = r.id
 WHERE r.is_active AND r.deleted_at IS NULL GROUP BY r.code ORDER BY r.code;
ROLLBACK;

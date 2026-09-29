-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- view_code 与页面守卫逐字同一个码:
--   purchase_order → /purchasing/orders/[id] 的 requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id] 的 requireModule(MOD.processing) = module.processing.view
--   role           → /settings/roles/[id] 的 requireManagePermissions() = action.manage_permissions
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_code text, root_table text, root_key text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order', 'module.purchasing.view',    'purchase_orders', 'id'),
        ('processing_run', 'module.processing.view',    'processing_runs', 'id'),
        ('role',           'action.manage_permissions', 'roles',           'id')
    ) AS s(subject, view_code, root_table, root_key);
$function$;

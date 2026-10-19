-- NOROLE-SURFACE Step 0 — who reads the objects proposed for a predicate, inside the database (read-only; as postgres, catalog only).
-- A caller-rights reader (invoker view, invoker function, another table's policy) is the one a new predicate could break; a definer reader is not.
BEGIN READ ONLY;
WITH t(name) AS (VALUES ('user_roles'),('roles'),('role_permissions'),('permissions'),('metal_prices'),('metal_price_indices'),('pricing_settings'),
                        ('accounts'),('collection_promises'),('collection_chases'),('company_profile'),('hr_settings'),('public_holidays'),('leave_types'),('laboratories'))
SELECT 'DEP_VIEW|' || t.name || '|' || v.relname || '|invoker=' || (COALESCE(v.reloptions::text, '') ~ 'security_invoker=(on|true)')
  FROM t JOIN pg_class c ON c.relname = t.name AND c.relnamespace = 'public'::regnamespace
  JOIN pg_depend d ON d.refobjid = c.oid JOIN pg_rewrite rw ON rw.oid = d.objid JOIN pg_class v ON v.oid = rw.ev_class
 WHERE v.oid <> c.oid GROUP BY t.name, v.relname, v.reloptions ORDER BY 1;
WITH t(name) AS (VALUES ('user_roles'),('roles'),('role_permissions'),('permissions'),('metal_prices'),('metal_price_indices'),('pricing_settings'),
                        ('accounts'),('company_profile'),('hr_settings'),('public_holidays'),('leave_types'),('laboratories'))
SELECT 'DEP_FN|' || t.name || '|' || p.proname || '|definer=' || p.prosecdef || '|auth_exec=' || has_function_privilege('authenticated', p.oid, 'EXECUTE')
  FROM t JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND p.prosrc ~ ('\m' || t.name || '\M')
 WHERE NOT p.prosecdef ORDER BY 1;
WITH t(name) AS (VALUES ('user_roles'),('roles'),('role_permissions'),('permissions'),('metal_prices'),('metal_price_indices'),('pricing_settings'),
                        ('accounts'),('company_profile'),('hr_settings'),('public_holidays'),('leave_types'),('laboratories'))
SELECT 'DEP_POLICY|' || t.name || '|' || p.schemaname || '.' || p.tablename || '|' || p.policyname
  FROM t JOIN pg_policies p ON COALESCE(p.qual, '') || COALESCE(p.with_check, '') ~ ('\m' || t.name || '\M') AND p.tablename <> t.name ORDER BY 1;
WITH t(name) AS (VALUES ('user_roles'),('roles'),('role_permissions'),('permissions'),('metal_prices'),('accounts'),('pricing_settings'))
SELECT 'DEP_DEFINER_FN_COUNT|' || t.name || '|' || count(p.oid) FROM t LEFT JOIN pg_proc p ON p.pronamespace = 'public'::regnamespace AND p.prosecdef AND p.prosrc ~ ('\m' || t.name || '\M')
 GROUP BY t.name ORDER BY 1;
ROLLBACK;

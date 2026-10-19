-- db/functions/guard_portal_account_separation.sql
-- MES-9a(2026-10-19,MES-9 Step 0 Q5,Tim):【一个门户账号永远不是员工、永远不持角色 —— 反过来也一样】。
--   一个触发器函数,挂在四张表上,按 TG_TABLE_NAME 分支:
--     supplier_portal_users  INSERT / 改 user_id:这个账号持着一条没撤销的角色 → PORTAL_ACCOUNT_HAS_ROLE;
--                            挂着一份员工档案(主账号或额外账号)→ PORTAL_ACCOUNT_IS_EMPLOYEE
--     user_roles             INSERT / 改 user_id / 把撤销撤回:这个账号是一个门户账号(有过一条链接,撤销了也算)→ PORTAL_ACCOUNT_NO_ROLES
--     employees              INSERT / 改 user_id:同上 → PORTAL_ACCOUNT_NO_EMPLOYEE
--     employee_accounts      INSERT / 改 user_id:同上 → PORTAL_ACCOUNT_NO_EMPLOYEE
--   【撤销了的门户账号也不许拿角色】一个撤销了的门户账号仍然是一个外部人的登录;给它一个角色 = 把一个外部人变成员工,
--     那必须是一个新账号,不是一次改授权。
-- 【SECURITY DEFINER】它读 supplier_portal_users / user_roles / employees,而做这些写的人(授角色的 admin、建档的人事)
--   不一定读得到它们(supplier_portal_users 的读是 module.suppliers.view)—— 调用者权限会读到零行、放行一次本该拒的写。
--   触发器函数不在 gate 的 B2 之内(返回 trigger)。
-- NOTE: introduced by db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql.
CREATE OR REPLACE FUNCTION public.guard_portal_account_separation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.user_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'supplier_portal_users' THEN
        IF EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id = NEW.user_id AND ur.revoked_at IS NULL) THEN
            RAISE EXCEPTION 'PORTAL_ACCOUNT_HAS_ROLE';
        END IF;
        IF EXISTS (SELECT 1 FROM employees e WHERE e.user_id = NEW.user_id)
           OR EXISTS (SELECT 1 FROM employee_accounts ea WHERE ea.user_id = NEW.user_id) THEN
            RAISE EXCEPTION 'PORTAL_ACCOUNT_IS_EMPLOYEE';
        END IF;
        RETURN NEW;
    END IF;
    IF TG_TABLE_NAME = 'user_roles' THEN
        IF NEW.revoked_at IS NULL AND EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.user_id = NEW.user_id) THEN
            RAISE EXCEPTION 'PORTAL_ACCOUNT_NO_ROLES';
        END IF;
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users p WHERE p.user_id = NEW.user_id) THEN
        RAISE EXCEPTION 'PORTAL_ACCOUNT_NO_EMPLOYEE';
    END IF;
    RETURN NEW;
END;
$function$;

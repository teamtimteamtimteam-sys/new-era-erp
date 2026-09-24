-- db/functions/guard_customer_credit_write.sql
-- ROLE-1 · Batch 2a(Tim 的矩阵 §10,Batch 2 grilling Q11):**客户信用限额与冻结只归 CFO**。
--
-- 【形状】与 guard_employee_salary_write(ROLE-1 Batch 1)同一个:customers 这张表别的列
-- 仍归 module.customers.edit(cco / cto / finance),只有 credit_limit_base 与 credit_hold
-- 换主人。一张表两个主人,所以不换写策略,而是一支列守卫:
--   · 直连 INSERT 带着一个限额(非 NULL)或 credit_hold = true → 拒;
--   · 直连 UPDATE 改动两列之一(IS DISTINCT FROM)→ 拒;
--   · 原样写回(客户编辑表单保存时两列没动)→ 放行 —— 拒绝的是【改动】,不是【提到】。
-- 两列都只走 set_customer_credit(SECURITY DEFINER,要 action.customer_credit)。
--
-- 【批量导入不在这里挡】master_import_apply 是属主路径,row_security_active = false,
-- 这支守卫看不见它 —— 所以两列加进了 master_import_forbidden_columns(与月薪同一个理由)。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_customer_credit_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.credit_limit_base IS NOT NULL OR NEW.credit_hold THEN
            RAISE EXCEPTION 'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.credit_limit_base IS DISTINCT FROM OLD.credit_limit_base
       OR NEW.credit_hold IS DISTINCT FROM OLD.credit_hold THEN
        RAISE EXCEPTION 'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_customer_credit_write() IS
'ROLE-1 Batch 2a:直连写(row_security_active)改动 customers.credit_limit_base / credit_hold,或直连 INSERT 带着限额或冻结,按名拒 CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY —— 两列只走 set_customer_credit(action.customer_credit,CFO)。原样写回放行。INVOKER,以分出直连写与属主路径。';

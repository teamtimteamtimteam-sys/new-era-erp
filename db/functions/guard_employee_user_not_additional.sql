-- db/functions/guard_employee_user_not_additional.sql
-- APR-ROUTE-1 Batch B(Tim 的 Q6):【一个账号不许既是某人的主账号、又是额外账号】—— employees 这一侧。
--
-- 另一侧是 guard_employee_account_not_primary(挂在 employee_accounts 上)。
-- 理由见那一支的抬头:只守一侧,account_person() 会把一个两处都登记的账号
-- 静默地认成主账号那个人。
--
-- 【为什么 SECURITY DEFINER】它要读 employee_accounts(有 RLS)。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1b-one-person-several-accounts-and-gm-reads.sql.

CREATE OR REPLACE FUNCTION public.guard_employee_user_not_additional()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    IF NEW.user_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id THEN
        RETURN NEW;
    END IF;
    SELECT e.code INTO v_code
      FROM employee_accounts ea JOIN employees e ON e.id = ea.employee_id
     WHERE ea.user_id = NEW.user_id;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_IS_ADDITIONAL|%', v_code;
    END IF;
    RETURN NEW;
END;
$function$;

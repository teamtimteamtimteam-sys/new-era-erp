-- db/functions/guard_employee_account_not_primary.sql
-- APR-ROUTE-1 Batch B(Tim 的 Q6):【一个账号不许既是某人的主账号、又是额外账号】—— 本表这一侧。
--
-- 另一侧是 guard_employee_user_not_additional(挂在 employees.user_id 上)。
-- 两侧都要:只守一侧,另一侧的写入会绕过去,而 account_person() 先查主账号 ——
-- 于是一个两处都登记了的账号会被静默地认成主账号那个人,额外那一条从此不起作用。
--
-- 【为什么 SECURITY DEFINER】它要读 employees(有 RLS)才判得出"是不是某人的主账号";
-- 以调用者身份读,一个看不见那一行的调用者会拿到"不是",守卫就会静默放行。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1b-one-person-several-accounts-and-gm-reads.sql.

CREATE OR REPLACE FUNCTION public.guard_employee_account_not_primary()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    SELECT e.code INTO v_code FROM employees e WHERE e.user_id = NEW.user_id LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ACCOUNT_IS_PRIMARY|%', v_code;
    END IF;
    RETURN NEW;
END;
$function$;

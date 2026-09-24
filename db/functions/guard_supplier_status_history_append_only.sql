-- db/functions/guard_supplier_status_history_append_only.sql
-- ROLE-1 · Batch 2a:供应商状态变动史只增不改。自己报名(FIN-31)—— 与
-- guard_customer_credit_history_append_only 同一个形状。
--
-- NOTE: introduced by db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_supplier_status_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'SUPPLIER_STATUS_HISTORY_APPEND_ONLY|update|%', OLD.id;
    ELSE
        RAISE EXCEPTION 'SUPPLIER_STATUS_HISTORY_APPEND_ONLY|delete|%', OLD.id;
    END IF;
END;
$function$;

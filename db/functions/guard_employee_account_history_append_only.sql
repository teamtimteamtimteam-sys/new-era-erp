-- db/functions/guard_employee_account_history_append_only.sql
-- APR-ROUTE-1 Batch B(Q2):额外账号的链接史只增不改 —— 与 finance_settings_history 同形。
--
-- NOTE: introduced by db/migrations/2026-09-23-aproute1b-one-person-several-accounts-and-gm-reads.sql.

CREATE OR REPLACE FUNCTION public.guard_employee_account_history_append_only()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'HISTORY_APPEND_ONLY';
END;
$function$;

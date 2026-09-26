-- db/functions/terms_request_dry_run.sql
-- APR-8(2026-09-26):提交时按批准那一刻的同一条路试跑一遍(terms_request_execute_internal),然后整段退回
-- (SQLSTATE PQ006 —— 只在这里抛、只在这里接)。条款违反公式表上的任何一条 CHECK、金属不在字典里、同一个金属
-- 写了两遍 —— 全在提交时按原话拒,不等到 CFO 按下批准才发现。只从提交里调用;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := terms_request_execute_internal(p_request_id);
        RAISE EXCEPTION USING ERRCODE = 'PQ006', MESSAGE = 'TERMS_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ006' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$;

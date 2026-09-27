-- db/functions/asset_disposal_dry_run.sql
-- APR-9(2026-09-27):提交时,按批准那一刻会走的同一支(asset_disposal_execute_internal)试跑一遍,然后整段回滚
-- (PQ007;journal_request_dry_run / warehouse_request_dry_run 同一个手法)。分录平衡那支延迟约束在试跑里提前到
-- IMMEDIATE 结一次账 —— 否则它要到提交才开口,试跑就说了一句假"可以"。
-- 拒绝原话原样冒出去(ASSET_HAS_NO_COST · BANK_INVALID · PERIOD_LOCKED …);成功返回那一组估算
-- (entry_id 在回滚之后不存在,调用方不存它)。内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := asset_disposal_execute_internal(p_request_id);
        SET CONSTRAINTS trg_journal_lines_balance IMMEDIATE;
        SET CONSTRAINTS trg_journal_lines_balance DEFERRED;
        RAISE EXCEPTION USING ERRCODE = 'PQ007', MESSAGE = 'ASSET_DISPOSAL_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ007' THEN
        NULL;
    END;
    RETURN v_res - 'entry_id' - 'journal_code';
END;
$function$;

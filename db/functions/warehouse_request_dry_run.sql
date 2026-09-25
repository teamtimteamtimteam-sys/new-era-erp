-- db/functions/warehouse_request_dry_run.sql
-- APR-7(2026-09-25):提交时,按批准那一刻会走的同一支(warehouse_request_execute_internal)试跑一遍,
-- 然后整段回滚(PQ005,journal_request_dry_run 同一个手法)。延迟的约束触发器(台账恒等式、桶不许为负、
-- 分录平衡)在试跑里提前到 IMMEDIATE 结一次账 —— 否则它们要到提交才开口,试跑就说了一句假"可以"。
-- 拒绝原话原样冒出去;成功返回 amount_base 与 entry_ids(entry_ids 在回滚之后不存在,只用它的个数)。
-- 内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := warehouse_request_execute_internal(p_request_id);
        SET CONSTRAINTS trg_inventory_movements_invariant, trg_inventory_movements_no_negative_bucket,
                        trg_inbound_batches_invariant, trg_output_batches_invariant,
                        trg_journal_lines_balance IMMEDIATE;
        SET CONSTRAINTS trg_inventory_movements_invariant, trg_inventory_movements_no_negative_bucket,
                        trg_inbound_batches_invariant, trg_output_batches_invariant,
                        trg_journal_lines_balance DEFERRED;
        RAISE EXCEPTION USING ERRCODE = 'PQ005', MESSAGE = 'WAREHOUSE_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ005' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$;

-- db/functions/warehouse_request_execute_internal.sql
-- APR-7(2026-09-25):让一张仓库申请【生效】—— 批准、审批关着时的提交、提交时的试跑,三处都走这一支,
-- 所以试跑拒的与批准拒的是同一句话。
--   write_off_inbound → soft_delete_inbound_batch_internal(欠款检查在那里,Q4:提交时一遍、批准时再一遍)
--   write_off_output  → soft_delete_output_batch_internal(订单预留在注销触发器里拒)
--   rollback          → rollback_processing_run_internal(OUTPUT_CONSUMED 在那里)
--   cod_void          → 只有已签发的作废得掉(COD_NOT_ISSUED),void_cod_internal,没有替代品
-- 每一种的 deleted_by / voided_by = 提单人(grilling Q6)。
-- 【冻结放行】evoltrya.warehouse_request_ctx = 本申请 id,guard_warehouse_request_freeze 只放它自己写的流水。
-- 返回 amount_base(本次过出来那几张分录的借方合计,本位币)与 entry_ids。"本次过出来的"= 本事务里
-- 执行之前不存在、之后存在的分录(created_at 默认 now(),即事务时间)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      warehouse_requests%ROWTYPE;
    v_before uuid[];
    v_ids    uuid[];
    v_amt    numeric;
    v_cod    record;
BEGIN
    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    v_before := ARRAY(SELECT je.id FROM journal_entries je WHERE je.created_at = now());
    PERFORM set_config('evoltrya.warehouse_request_ctx', v_r.id::text, true);

    IF v_r.kind = 'write_off_inbound' THEN
        PERFORM soft_delete_inbound_batch_internal(v_r.inbound_batch_id, v_r.reason, v_r.created_by);
    ELSIF v_r.kind = 'write_off_output' THEN
        PERFORM soft_delete_output_batch_internal(v_r.output_batch_id, v_r.reason, v_r.created_by);
    ELSIF v_r.kind = 'rollback' THEN
        PERFORM rollback_processing_run_internal(v_r.run_id, v_r.reason, v_r.created_by);
    ELSE
        SELECT c.id, c.code, c.status INTO v_cod
          FROM certificates_of_destruction c WHERE c.id = v_r.cod_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(v_r.cod_id::text, '?');
        END IF;
        IF v_cod.status <> 'issued' THEN
            RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', COALESCE(v_cod.code, v_cod.id::text), v_cod.status;
        END IF;
        PERFORM void_cod_internal(v_cod.id, v_r.reason, NULL, v_r.created_by);
    END IF;

    PERFORM set_config('evoltrya.warehouse_request_ctx', '', true);

    v_ids := ARRAY(SELECT je.id FROM journal_entries je
                    WHERE je.created_at = now() AND je.id <> ALL (v_before) ORDER BY je.code);
    SELECT COALESCE(round(sum(l.debit), 2), 0) INTO v_amt
      FROM journal_lines l WHERE l.entry_id = ANY (v_ids);

    RETURN jsonb_build_object('amount_base', v_amt, 'entry_ids', to_jsonb(v_ids));
END;
$function$;

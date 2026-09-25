-- db/functions/guard_warehouse_request_freeze.sql
-- APR-7(2026-09-25,grilling Q3):一张在等 CFO 的注销 / 回滚申请,把它的批次【冻住】。
--
--   · inventory_movements BEFORE INSERT(行级):写向一张被冻结批次的任何流水 —— 加工投料、销售、预留、
--     释放、转移、暂扣、盘点调整 —— 按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH|批号|申请。
--     【为什么挂在流水上,不挂在每一支函数上】动库存的函数有几十支,流水只有一张表;漏掉一支就是一扇侧门。
--   · receipt_price_requests BEFORE INSERT:被冻结的进料批上不许再开定价申请(改价会改注销的价值)。
--
-- 【只有执行那张申请的那一次放行】warehouse_request_execute_internal 把 evoltrya.warehouse_request_ctx
-- 设成申请 id;冻结它的正是这一张时,注销 / 回滚自己写的流水放行。别的申请冻着的批次,照拒。
-- SECURITY DEFINER 的调用者(加工提交、发货……)一样被拒 —— 冻结不分是谁写的。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_warehouse_request_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := COALESCE(current_setting('evoltrya.warehouse_request_ctx', true), '');
    v_in    uuid;
    v_out   uuid;
    v_req   record;
BEGIN
    IF TG_TABLE_NAME = 'inventory_movements' THEN
        v_in := NEW.inbound_batch_id;
        v_out := NEW.output_batch_id;
    ELSE
        v_in := NEW.inbound_batch_id;
    END IF;

    SELECT f.request_id, f.label INTO v_req
      FROM warehouse_request_freezing(v_in, v_out) f
     WHERE f.request_id::text <> v_ctx
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_FREEZES_BATCH|%|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = v_in),
                     (SELECT code FROM output_batches WHERE id = v_out), '?'),
            v_req.label;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_warehouse_request_freeze() IS
'APR-7(grilling Q3):在等 CFO 的注销 / 回滚申请冻住它的批次 —— 写向那一批的任何库存流水、进料批上新开的定价申请,按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH|批号|申请。只有执行那张申请本身(evoltrya.warehouse_request_ctx = 申请 id)放行。';

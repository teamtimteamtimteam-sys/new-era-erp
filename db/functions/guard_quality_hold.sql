-- db/functions/guard_quality_hold.sql
-- MES-6b-1(2026-10-15,MES-0 Q66 · G29;MES-6b Step 0 Q3 · Q21 · Q23 · Q24,Tim):【质量暂扣守在流水上】——
--   inventory_movements BEFORE INSERT(行级),与 APR-7 的注销 / 回滚冻结(guard_warehouse_request_freeze)并排:动库存的函数有几十支,
--   流水只有一张表,挂在这里就没有侧门(DEFINER 的调用者 —— 加工提交、发货、直接销售、预留 —— 一样被拒)。
--
--   一批在暂扣里(batch_quality_hold)时,写向它的这几种流水按名拒 QUALITY_HOLD_OPEN|<批号>|<不合格报告编号>:
--     processing_consume                  投料(含配料计划的执行 —— 它是一张 blending 加工单)
--     sale                                直接销售,以及发货那一条腿(ship_order 从 committed 桶里出)
--     status_change_in 进 committed        预留(available → committed 那一对的"进"腿;另一条腿与它同一句 INSERT,一起回滚)
--     writeoff,却不在一张仓库申请的执行里  注销只经 CFO 批的那张申请(warehouse_request_execute_internal 设 evoltrya.warehouse_request_ctx)
--     maintenance_issue                   备件出给一条保养记录(MES-7a-2,MES-7a Step 0 Q15:一件开着不合格报告的备件不装上机器)
--   放行(Q3 · Q21 · Q23):收货、加工产出、转移(两条腿 —— 想把它搬进隔离库位就搬)、盘点调整、available ↔ on_hold、committed → available
--   (释放一个预留 —— 已有的预留照留,只是发不出去)、CFO 批过的注销、回滚的冲销两腿(reversal_restore / reversal_void)、
--   备件退回(maintenance_return —— 从机器上拆回来的件回到库里;它在不在暂扣里,下一次出库时再问,MES-7a Step 0 Q15)。
--   ★ 守卫只认【流水的种类与桶】,不认是谁写的:一张已经预留了的货,暂扣落下之后预留照旧在(Q23),发货那一条 sale 腿在这里被拒。
--   SECURITY DEFINER:暂扣的判据要读全部不合格报告(读策略认码),守卫不能因为写流水的人读不到那一张报告就放过去。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.guard_quality_hold()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_hold record;
BEGIN
    IF NOT (NEW.movement_type IN ('processing_consume', 'sale', 'maintenance_issue')
            OR (NEW.movement_type = 'status_change_in' AND NEW.stock_status = 'committed')
            OR (NEW.movement_type = 'writeoff'
                AND COALESCE(current_setting('evoltrya.warehouse_request_ctx', true), '') = '')) THEN
        RETURN NEW;
    END IF;
    SELECT h.ncr_code, h.batch_code INTO v_hold
      FROM batch_quality_hold(NEW.inbound_batch_id, NEW.output_batch_id) h;
    IF FOUND THEN
        RAISE EXCEPTION 'QUALITY_HOLD_OPEN|%|%', v_hold.batch_code, v_hold.ncr_code
          USING HINT = '这一批在质量暂扣里(一张开着的不合格报告,或一张决定为拒收而货还在的)—— 先让另一个人在报告上做出放行的处置;拒收的货走 CFO 注销申请。';
    END IF;
    RETURN NEW;
END;
$function$

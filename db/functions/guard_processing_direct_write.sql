-- db/functions/guard_processing_direct_write.sql
-- ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q7;Batch 3b grilling Q1):**加工的三张表不许绕过函数写**。
--
-- 【Step 0 量出来的侧门】processing_runs / processing_outputs 的 INSERT 策略、以及三张表(再加
-- processing_inputs)的 DELETE 策略都开在 module.processing.edit 上:任何持它的人不经
-- commit_processing_run 就能直连插一张 status = 'committed' 的加工单(库存与总账一行没动),
-- 不经 rollback_processing_run 就能把一张已提交的单改成 reversed、改挂到另一张工单上,或者整行硬删。
-- 提交归仓库(action.processing_commit)、回滚归仓库(action.processing_rollback)都是空话,
-- 除非这几扇门关上。Step 0 实测:app/、lib/、scripts/ 里【没有一处】直连写这三张表(全是读)。
--
-- 【怎么关】INSERT 策略(runs · outputs)与 DELETE 策略(runs · outputs · inputs)拿掉;
-- UPDATE 策略留着(登记 ROLE1B3B-PROCESSING-UPDATE-POLICIES),但 processing_runs 上改 status 或
-- work_order_id 按名拒。本守卫挂成:
--   · processing_runs    —— 行级 BEFORE INSERT OR UPDATE(UPDATE 只在 status / work_order_id 变了时拒)
--                           + 语句级 BEFORE DELETE
--   · processing_outputs —— 行级 BEFORE INSERT + 语句级 BEFORE DELETE
--   · processing_inputs  —— 语句级 BEFORE DELETE(直连 INSERT 早由 guard_processing_input 按名拒)
-- 语句级那一支零行也照样触发(没有 DELETE 策略时直连 DELETE 是零行、不报错 —— SILENT-1 那一族)。
-- 按名拒 PROCESSING_THROUGH_FUNCTION_ONLY|表|动作。属主路径(row_security_active = false:
-- SECURITY DEFINER 的提交 / 回滚、迁移、种子)一律放行。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径;理由见 guard_lock_reopen_path 的抬头。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3b-the-warehouse-makes-finance-releases.sql.

CREATE OR REPLACE FUNCTION public.guard_processing_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        IF TG_LEVEL = 'ROW' THEN
            RETURN NEW;
        END IF;
        RETURN NULL;
    END IF;
    -- 只挂在 processing_runs 的行级 UPDATE 上:别的列照旧走 UPDATE 策略。
    IF TG_OP = 'UPDATE' THEN
        IF NEW.status IS NOT DISTINCT FROM OLD.status
           AND NEW.work_order_id IS NOT DISTINCT FROM OLD.work_order_id THEN
            RETURN NEW;
        END IF;
    END IF;
    RAISE EXCEPTION 'PROCESSING_THROUGH_FUNCTION_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;

COMMENT ON FUNCTION public.guard_processing_direct_write() IS
'ROLE-1 Batch 3b:processing_runs / processing_outputs 的直连 INSERT、三张加工表(再加 processing_inputs)的直连 DELETE、以及 processing_runs 上直连改 status 或 work_order_id,按名拒 PROCESSING_THROUGH_FUNCTION_ONLY|表|动作。提交走 commit_processing_run(action.processing_commit),回滚走 rollback_processing_run(action.processing_rollback),两支都是 SECURITY DEFINER。属主路径放行。';

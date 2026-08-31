-- db/functions/guard_receipt_date_not_cleared.sql
-- INV-VAL-1 R9:到货日 / 产出日的【转移守卫】。
--
-- 【建的时候必填,四条路径早就各自拒了】(IOD-2-fu1)—— create_inbound_batch、
--   receive_inbound_batch_against_po、create_output_batch 各自 RAISE,
--   加工单那条走 commit_processing_run 的 PROCESS_DATE_REQUIRED。
--   本守卫补的是它们拦不住的另一半:**直接 UPDATE 把已有的日期改回 NULL**
--   (app/inbound/[id]/edit/actions.ts 就是这么写的,空串 → null)。
--
-- ★【为什么不是 NOT NULL】★ 线上 7 张进料批没有到货日,全部早于 IOD-2-fu1,
--   而 R9 明写【不许回填】。NOT NULL 会把那 7 张行锁死 —— 连改个备注都提交不了。
--   所以只拒【由有变无】;让 NULL 保持 NULL 的更新照过。
--   fixture 172 E 臂【同时】钉这两件事,正是因为只钉前一件的话 NOT NULL 也能通过。
--
-- NOTE: introduced by db/migrations/2026-08-31-invval1-the-valuation-report-the-close-gate-and-the-fields-already-mandatory.sql.

CREATE OR REPLACE FUNCTION public.guard_receipt_date_not_cleared()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_TABLE_NAME = 'inbound_batches' THEN
        IF NEW.arrival_date IS NULL THEN
            IF TG_OP = 'INSERT' THEN
                RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED'
                  USING HINT = '到货日在收货时必填(IOD-2-fu1);不给默认值,'
                            || 'CURRENT_DATE 会让留空比填对更容易通过。';
            ELSIF OLD.arrival_date IS NOT NULL THEN
                RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED|%', OLD.code
                  USING HINT = '这批货已经有到货日了,不能改回空 —— '
                            || '历史上缺失的那些留着,新的缺失不许再产生。';
            END IF;
        END IF;
    ELSE  -- output_batches
        IF NEW.output_date IS NULL THEN
            IF TG_OP = 'INSERT' THEN
                RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED'
                  USING HINT = '产出日在建批时必填(IOD-2-fu1);加工单那条路从 '
                            || 'commit_processing_run 的 p_process_date 取。';
            ELSIF OLD.output_date IS NOT NULL THEN
                RAISE EXCEPTION 'OUTPUT_DATE_REQUIRED|%', OLD.code
                  USING HINT = '这批产出已经有产出日了,不能改回空。';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$
;

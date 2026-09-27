-- db/functions/guard_gst_filing_lock.sql
-- APR-10(2026-09-27,grilling Q3):一张 GST 申报申请在等的时候,那一季的数字靠期间锁冻结。
-- 把 locked_before 挪回到【这一季的期末或更早】—— 无论是 reopen_period(重开一个月)、重开年度,还是手动锁的
-- 直连写 —— 都会让那一季的某个月重新开放,于是按名拒 GST_FILING_WAITING_BLOCKS_REOPEN|<那一张>。
-- ☞ 重开这一季【之前】的一个月同样被拒:锁只有一个日期,重开六月就把七到九月一并打开了。
-- 挂在 finance_settings 上(BEFORE UPDATE OF locked_before),所以每一条挪锁的路都经过它。
-- 撤回或驳回那张申请,冻结随之解开;批准之后快照已写,此后的差异照 GST-1 的规矩走更正件。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.guard_gst_filing_lock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_label text;
BEGIN
    IF NEW.locked_before IS NOT DISTINCT FROM OLD.locked_before THEN
        RETURN NEW;
    END IF;
    IF NEW.locked_before IS NOT NULL AND OLD.locked_before IS NOT NULL
       AND NEW.locked_before > OLD.locked_before THEN
        RETURN NEW;
    END IF;
    SELECT q.label INTO v_label
      FROM gst_filing_requests q JOIN gst_periods p ON p.id = q.period_id
     WHERE q.status = 'submitted'
       AND (NEW.locked_before IS NULL OR NEW.locked_before <= p.period_end)
     ORDER BY p.period_end LIMIT 1;
    IF v_label IS NOT NULL THEN
        RAISE EXCEPTION 'GST_FILING_WAITING_BLOCKS_REOPEN|%', v_label;
    END IF;
    RETURN NEW;
END;
$function$;

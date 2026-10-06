-- db/functions/processing_runs_blocking_close.sql
-- U1-B(2026-10-05,UNBLOCK-1 Step 0 §3 5.1):挡住某一个月末关账的加工单 —— 已提交、从未分摊成本、日期不晚于那个月末。
--
-- 【为什么抽出来】close_period 按这一句拒(PROCESSING_COSTS_UNALLOCATED),而月结清单此前自己数另一样东西
--   (processing_run_allocation_status 的"过期,或未分摊且有过成本改动")—— 一张从没有成本条目的已提交单,清单说"做完了",
--   关账却拒;而一张过期的单清单说"挡着",关账却放行。两份判据各说各的。现在【一份】:close_period 与月结清单调同一支。
-- 【SECURITY DEFINER + 调用者检查】月结清单的读者持 module.finance.view;processing_runs 的读策略是加工那一侧的码 ——
--   不持加工码的财务读者经基表读会【静默地少掉】那几张单(xmodule 那一族),清单于是又说"做完了"。
--   属主身份数,门是 module.finance.view(与 /finance/month-end 同一扇)。
--
-- NOTE: introduced by db/migrations/2026-10-05-u1b-workflow-fixes.sql.

CREATE OR REPLACE FUNCTION public.processing_runs_blocking_close(p_period_end date)
 RETURNS TABLE(run_count integer, run_codes text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'PERIOD_END_REQUIRED';
    END IF;
    RETURN QUERY
    SELECT count(*)::integer, string_agg(r.code, ', ' ORDER BY r.process_date, r.code)
      FROM processing_runs r
     WHERE r.deleted_at IS NULL
       AND r.status = 'committed'
       AND r.allocated_at IS NULL
       AND r.process_date <= p_period_end;
END;
$function$;

COMMENT ON FUNCTION public.processing_runs_blocking_close(date) IS
'U1-B:挡住 p_period_end 关账的加工单(已提交、从未分摊、日期不晚于月末)的张数与编号。close_period 与月结清单读同一支 —— 一份判据。属主身份数(财务读者不持加工码时基表会静默少行),门 module.finance.view。';

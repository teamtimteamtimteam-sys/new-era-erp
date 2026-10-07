-- db/functions/processing_runs_unclosed_balance.sql
-- MES-4a(2026-10-07,MES-0 Q48;MES-4a Step 0 Q22,Tim):【一个月末之前,物料平衡还没结的加工单】—— 月结清单的那一行警告。
--   数的是 processing_run_balance_all 里 balance_state = 'open' 的单(MES-4a 起记的、转化型的、已提交没回滚的、最新结平不当前的),
--   日期不晚于那个月末。【只是警告,不挡关账】—— close_period 一个字没动(它只挡没分摊成本的单,processing_runs_blocking_close):
--   把生产的结平绑到财务的关账上,是 Q48 不要的。MES-4a 之前的单(before_closure)不在这里 —— 它们结不了,列出来只会永远挂着。
--   【SECURITY DEFINER + 调用者检查】与 processing_runs_blocking_close 同一扇门(module.finance.view)、同一个理由:月结的读者
--   不一定持加工的码,经基表读会静默地少掉那几张单。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.processing_runs_unclosed_balance(p_period_end date)
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
    SELECT count(*)::integer, string_agg(b.run_code, ', ' ORDER BY b.process_date, b.run_code)
      FROM processing_run_balance_all b
     WHERE b.balance_state = 'open'
       AND b.process_date <= p_period_end;
END;
$function$

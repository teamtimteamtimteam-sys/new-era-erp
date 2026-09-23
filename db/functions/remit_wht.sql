-- db/functions/remit_wht.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q15):每一笔代扣税缴纳都要先提一张缴纳申请,
-- 经 CFO 批准,再由财务执行(pay_payment_request)。函数体搬进了 remit_wht_internal
-- (EXECUTE 已从 authenticated 收回);这里只剩按名拒绝并指路 —— 理由见 record_bank_transfer 外壳。
-- 两道权限检查照旧在前面(fixture 142 I 臂:没有权限的人先听到 PERMISSION_DENIED)。
--
-- NOTE: shell introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.remit_wht(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');
    RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|wht_remittance'
      USING HINT = '代扣税缴纳要先提缴纳申请、经 CFO 批准,再执行(PAY-REQ-1 Batch B)';
END;
$function$;

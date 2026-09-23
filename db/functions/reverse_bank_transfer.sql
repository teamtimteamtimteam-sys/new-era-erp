-- db/functions/reverse_bank_transfer.sql
-- PAY-REQ-1 · Batch B(2026-09-23):冲销一笔行内转账要先提一张冲销申请,经 CFO 批准,
-- 再由财务执行(pay_payment_request)。函数体搬进了 reverse_bank_transfer_internal
-- (EXECUTE 已从 authenticated 收回);这里只剩按名拒绝并指路 —— 理由见 record_bank_transfer 外壳。
--
-- NOTE: shell introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.reverse_bank_transfer(p_transfer_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|bank_transfer_reversal'
      USING HINT = '冲销行内转账要先提冲销申请、经 CFO 批准,再执行(PAY-REQ-1 Batch B)';
END;
$function$;

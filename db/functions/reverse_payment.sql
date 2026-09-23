-- db/functions/reverse_payment.sql
-- PAY-REQ-1(2026-09-23,Tim 的 Q6):每一次冲销付款 —— 不论收款还是出款 ——
-- 都要走一张冲销申请,经 CFO 批准,再由财务执行(pay_payment_request)。
--
-- 这支函数因此只剩一件事:按名拒绝,并指出走法。函数体搬进了
-- reverse_payment_internal(EXECUTE 已从 authenticated 收回)。
--
-- 【为什么不干脆删掉它】删掉之后,旧页面(破窗期间线上跑的那一版)按下"冲销"
-- 会撞 42883 function does not exist —— 一句不指路的报错。留一个按名拒绝的外壳,
-- 旧页面拿到的就是一句能照着做的话。签名不变,所以 CREATE OR REPLACE 即可。
--
-- NOTE: shell introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.reverse_payment(p_payment_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|payment_reversal'
      USING HINT = '冲销付款要先提冲销申请、经 CFO 批准,再执行(PAY-REQ-1)';
END;
$function$;

-- db/functions/record_bank_transfer.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q15):每一笔行内转账都要先提一张转账申请,
-- 经 CFO 批准,再由财务执行(pay_payment_request)。
--
-- 这支函数因此只剩一件事:按名拒绝,并指出走法。函数体搬进了
-- record_bank_transfer_internal(EXECUTE 已从 authenticated 收回)。
--
-- 【为什么不干脆删掉它】与 reverse_payment 外壳同一条:破窗期间线上跑的旧页面按下
-- "转账"会撞 42883 function does not exist —— 一句不指路的报错。留一个按名拒绝的
-- 外壳,旧页面拿到的就是一句能照着做的话。签名不变,所以 CREATE OR REPLACE 即可。
-- 权限检查仍在前面:没有权限的人先听到的是"你没有这个权限"(fixture 142 I 臂同形)。
--
-- NOTE: shell introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.record_bank_transfer(p_transfer_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|bank_transfer'
      USING HINT = '行内转账要先提转账申请、经 CFO 批准,再执行(PAY-REQ-1 Batch B)';
END;
$function$;

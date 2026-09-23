-- db/functions/payment_request_payee_check.sql
-- PAY-REQ-1(2026-09-23,Tim 的 Q4):一张出款申请的收款人若是【被拉黑 / 暂停】的
-- 供应商,批准与付款都按名拒。提交也拒 —— 一张注定批不了的申请不该进 CFO 的队列。
--
-- 【为什么只拦这两种】supplier_status 里 blacklisted 与 suspended 是"不许再跟他做生意"
-- 的两个决定;draft / pending_review / approved / active 是建档流程里的位置,今天线上
-- 已记账的供应商付款就付给过 draft 状态的供应商(测试数据)。把它们也拦下来是一条
-- 新规矩,不是这一条。archived 同理不拦:归档不等于不许结清旧账。
-- record_payment 自己只认 deleted_at(已删 → COUNTERPARTY_NOT_FOUND),照旧。
--
-- 冲销申请不查:冲销是把钱【收回来】,拦住它只会把一笔记错的付款锁死在账上。
--
-- 内层算子,无调用者检查;只从 SECURITY DEFINER 的申请函数体内调用。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.payment_request_payee_check(p_kind text, p_supplier_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code   text;
    v_status text;
BEGIN
    IF p_kind <> 'payment_out' OR p_supplier_id IS NULL THEN
        RETURN;
    END IF;
    SELECT s.code, s.status::text INTO v_code, v_status FROM suppliers s WHERE s.id = p_supplier_id;
    IF v_status IN ('blacklisted', 'suspended') THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|%|%', v_code, v_status;
    END IF;
END;
$function$
;

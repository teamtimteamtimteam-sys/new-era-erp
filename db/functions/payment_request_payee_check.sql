-- db/functions/payment_request_payee_check.sql
-- PAY-REQ-1(2026-09-23,Tim 的 Q4):一张出款申请的收款人若是【被拉黑 / 暂停】的
-- 供应商,批准与付款都按名拒。提交也拒 —— 一张注定批不了的申请不该进 CFO 的队列。
--
-- ★ ROLE-1 · Batch 2a(Tim 2026-09-23,Batch B grilling Q5):**一家【未批准】的供应商,
--   付款申请提不了、批不了、付不了。** "可付"的定义收成一句话:
--       状态是 approved 或 active,并且没被删。
--   其余每一种状态(draft / pending_review / rejected / suspended / blacklisted / archived)
--   都按名拒,状态原样写进拒绝里:PAYMENT_REQUEST_SUPPLIER_BLOCKED|<编号>|<状态>;
--   已删的供应商读作 PAYMENT_REQUEST_SUPPLIER_BLOCKED|<编号>|deleted。
--   此前这里只拦 blacklisted 与 suspended,并且写着"draft / pending / archived 不拦,
--   线上的供应商付款就付给过 draft 的供应商" —— 那一段说的是 PAY-REQ-1 当时的规矩,
--   本刀把它换掉了。线上此刻 377,673.50 的应付因此付不出去,直到 CFO 批准那三家
--   (docs/handbacks/ROLE-1.md § Batch 2a)。
--
-- 三个调用点不变:submit_payment_request(提交)、decide_payment_request(批准那一支;
-- 驳回不查 —— 驳回一张付不出去的申请正是该做的事)、pay_payment_request(付款)。
--
-- 冲销申请不查(Q5 豁免):冲销是把钱【收回来】,拦住它只会把一笔记错的付款锁死在账上。
-- 本函数只对 payment_out 起作用,冲销(payment_reversal)从第一行就返回。
--
-- 内层算子,无调用者检查;只从 SECURITY DEFINER 的申请函数体内调用。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.
-- ROLE-1 Batch 2a: db/migrations/2026-09-24-role1b2a-cfo-settings-credit-and-supplier-approval.sql.

CREATE OR REPLACE FUNCTION public.payment_request_payee_check(p_kind text, p_supplier_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code    text;
    v_status  text;
    v_deleted boolean;
BEGIN
    IF p_kind <> 'payment_out' OR p_supplier_id IS NULL THEN
        RETURN;
    END IF;
    SELECT s.code, s.status::text, s.deleted_at IS NOT NULL INTO v_code, v_status, v_deleted
      FROM suppliers s WHERE s.id = p_supplier_id;
    IF NOT FOUND THEN
        RETURN;  -- record_payment_internal 按它自己的名字拒(COUNTERPARTY_NOT_FOUND)
    END IF;
    IF v_deleted THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|%|deleted', v_code;
    END IF;
    IF v_status NOT IN ('approved', 'active') THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|%|%', v_code, v_status;
    END IF;
END;
$function$
;

-- db/functions/record_payment.sql
-- PAY-REQ-1(2026-09-23):record_payment 从此是一个【外壳】,函数体在
-- record_payment_internal 里,一字未改。
--
-- ★★ Tim 的裁定:钱离开之前要先批 —— 付款申请 → CFO 批准 → 付款。
--   APR-3 当时把付款从审批里拿掉的理由,原话是「记一笔付款【就是】付款」:
--   在这里加一道批准,要么批准人就是记的人(自批拒绝永远不会触发),
--   要么钱已经走了才批。PAY-REQ-1 给了它一个真的在途态(payment_requests)。
--
-- 于是这支函数只剩两种合法用途:
--   ① 收款('in')—— 钱进来,不批(Tim);
--   ② 豁免的出款 —— payment_request_required() 说 false 的那一种(Q1):
--      整笔付给员工、全部核销到已批准的报销单 / 医疗申报生成的费用上,
--      币种与费用同币种、金额恰好等于核销合计。那张单【已经被一个人批过这个数】。
-- 其余出款按名拒:PAYMENT_REQUEST_REQUIRED|payment_out —— 去提一张付款申请。
--
-- 【为什么判据在另一支函数里】屏幕要在提交之前知道"这一笔会直接记账,还是会变成
-- 一张申请"—— 屏幕问的与这里拦的必须是【同一个】判断(预览规则:问数据库)。
--
-- NOTE: shell introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb, p_counterparty_kind text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF payment_request_required(p_direction, p_counterparty_kind, p_counterparty_id,
                                p_amount, p_currency, p_allocations) THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_REQUIRED|payment_out'
          USING HINT = '出款要先提付款申请、经 CFO 批准,再付款(PAY-REQ-1)';
    END IF;
    RETURN record_payment_internal(p_direction, p_counterparty_id, p_amount, p_currency,
                                   p_fx_rate, p_bank_account, p_payment_date, p_notes,
                                   p_allocations, p_counterparty_kind);
END;
$function$
;

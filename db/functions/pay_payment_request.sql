-- db/functions/pay_payment_request.sql
-- PAY-REQ-1(2026-09-23):执行一张【已批准】的申请 —— 钱在这一刻离开,分录在这一刻过账。
--
-- ★ 这是出款与冲销付款【唯一】的一扇门(Tim 的 Q9:不加旁路参数)。
--   它把申请上冻结的那组参数原样递给引擎(record_payment_internal /
--   reverse_payment_internal),付款人只给两样:
--     · 实际付款日(必填;它决定牌价与期间 —— 不默认今天,FIN-10);
--     · 跨币种时银行水单上的实际成交价(可以与申请时那一个不同;同币种给了会被引擎拒)。
--   金额、币种、收款人、银行、核销行一个字都改不了 —— 批的就是它们。
--   冲销申请不收日期:冲销日照 reverse_payment 一贯的规矩是今天。
--
-- ★ 付款人可以就是提单人(Tim 的 Q3)。付款之前再核一遍收款人没被拉黑/暂停(Q4);
--   其余一切由引擎自己在这一刻按原话拒。guard_payment_sod 在引擎里照跑(付款人不能是
--   建这家供应商的人)—— SOD_PAYEE_AND_PAY 不变。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.pay_payment_request(p_request_id uuid, p_payment_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   payment_requests%ROWTYPE;
    v_res jsonb;
    v_pid uuid;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_r FROM payment_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'approved' THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_APPROVED|%|%', v_r.code, v_r.status;
    END IF;

    IF v_r.kind = 'payment_out' THEN
        IF p_payment_date IS NULL THEN
            RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
        END IF;
        PERFORM payment_request_payee_check(v_r.kind, v_r.supplier_id);
        v_res := record_payment_internal(
            'out',
            COALESCE(v_r.supplier_id, v_r.employee_id),
            v_r.amount_ccy, v_r.currency,
            COALESCE(p_fx_rate, v_r.fx_rate),
            v_r.bank_account_code,
            p_payment_date,
            COALESCE(v_r.notes || ' · ', '') || v_r.code,
            v_r.allocations, v_r.counterparty_type);
        v_pid := (v_res->>'payment_id')::uuid;
    ELSE
        IF p_payment_date IS NOT NULL OR p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'PAYMENT_REVERSAL_TAKES_NO_DATE|%', v_r.code;
        END IF;
        v_res := reverse_payment_internal(v_r.payment_id, v_r.notes || ' · ' || v_r.code);
        v_pid := (v_res->>'reversal_payment_id')::uuid;
    END IF;

    UPDATE payment_requests
       SET status = 'paid', paid_at = now(), paid_by = auth.uid(), result_payment_id = v_pid
     WHERE id = p_request_id;

    RETURN v_res || jsonb_build_object('request_id', p_request_id, 'request_code', v_r.code,
                                       'result_payment_id', v_pid);
END;
$function$
;

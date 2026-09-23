-- db/functions/payment_request_dry_run.sql
-- PAY-REQ-1(2026-09-23):按【付款那一刻会用的同一支引擎】把一张申请试跑一遍,
-- 然后整个回滚 —— 分录、编号、付款行、核销行一样都不留。返回引擎的返回值。
--
-- 【为什么不写一份"校验函数"】那会是第二份判据:record_payment_internal 里有
-- 敞口、归属、期间锁、牌价、代扣、GST、预付上限十几条规矩,抄一份出来,它们在
-- 写下来那天一致、之后悄悄分开(本仓库为预览付过四次这个账)。试跑【就是】那一份。
--
-- 【怎么做到"整个回滚"】一个带 EXCEPTION 子句的块就是一个子事务。引擎跑完之后
-- 抛一个专用 SQLSTATE(PQ001),只接这一个 —— 引擎自己的任何拒绝(ALLOC_EXCEEDS、
-- PERIOD_LOCKED、FX_RATE_MISSING……)照常往外抛,调用方看见的就是那句原话。
-- 块里赋给变量的值在回滚之后仍然保留(PL/pgSQL 的语义),所以返回值拿得出来。
--
-- 【守卫照跑】guard_payment_sod 在试跑里照样以 auth.uid() 判 —— 提交时判的是提单人,
-- 批准时判的是审批人(批一笔付给自己建的供应商的钱,同样是一次职责冲突)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.payment_request_dry_run(p_request_id uuid, p_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   record;
    v_res jsonb;
BEGIN
    SELECT * INTO v_r FROM payment_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    BEGIN
        IF v_r.kind = 'payment_out' THEN
            v_res := record_payment_internal(
                'out',
                COALESCE(v_r.supplier_id, v_r.employee_id),
                v_r.amount_ccy, v_r.currency,
                COALESCE(p_fx_rate, v_r.fx_rate),
                v_r.bank_account_code,
                COALESCE(p_date, v_r.planned_date),
                v_r.notes, v_r.allocations, v_r.counterparty_type);
        ELSE
            v_res := reverse_payment_internal(v_r.payment_id, v_r.notes);
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'PQ001', MESSAGE = 'PAYMENT_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ001' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;

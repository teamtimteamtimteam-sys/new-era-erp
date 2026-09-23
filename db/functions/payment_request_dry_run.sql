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
-- ★ PAY-REQ-1 Batch B(2026-09-23):六种申请各一支,不认识的种类按名拒(PAYMENT_REQUEST_KIND_UNKNOWN)。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql;
--       per-kind branches by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.payment_request_dry_run(p_request_id uuid, p_date date DEFAULT NULL::date, p_fx_rate numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     record;
    v_res   jsonb;
    v_entry uuid;
    v_base  numeric;
BEGIN
    SELECT * INTO v_r FROM payment_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    BEGIN
        -- ★ Batch B:每一种都写出来,不认识的按名拒 —— 此前的 ELSE 会把任何新种类
        --   当成付款冲销,悄悄去冲一笔 payment_id 为 NULL 的付款。
        CASE v_r.kind
        WHEN 'payment_out' THEN
            v_res := record_payment_internal(
                'out',
                COALESCE(v_r.supplier_id, v_r.employee_id),
                v_r.amount_ccy, v_r.currency,
                COALESCE(p_fx_rate, v_r.fx_rate),
                v_r.bank_account_code,
                COALESCE(p_date, v_r.planned_date),
                v_r.notes, v_r.allocations, v_r.counterparty_type);
        WHEN 'payment_reversal' THEN
            v_res := reverse_payment_internal(v_r.payment_id, v_r.notes);
        WHEN 'bank_transfer' THEN
            v_res := record_bank_transfer_internal(
                COALESCE(p_date, v_r.planned_date), v_r.bank_account_code, v_r.to_account_code,
                v_r.amount_ccy, v_r.amount_in, v_r.bank_reference, v_r.notes);
            v_entry := (v_res->>'entry_id')::uuid;
        WHEN 'bank_transfer_reversal' THEN
            v_res := reverse_bank_transfer_internal(v_r.transfer_id, COALESCE(p_date, CURRENT_DATE), v_r.notes);
            v_entry := (v_res->>'reversal_entry_id')::uuid;
        WHEN 'wht_remittance' THEN
            v_res := remit_wht_internal(
                v_r.period_month, COALESCE(p_date, v_r.planned_date), v_r.filed_reference,
                v_r.bank_account_code, v_r.notes, v_r.amount_ccy);
            v_entry := (v_res->>'entry_id')::uuid;
        WHEN 'wht_remittance_reversal' THEN
            v_res := reverse_wht_remittance_internal(v_r.wht_remittance_id, COALESCE(p_date, CURRENT_DATE), v_r.notes);
            v_entry := (v_res->>'reversal_entry_id')::uuid;
        ELSE
            RAISE EXCEPTION 'PAYMENT_REQUEST_KIND_UNKNOWN|%|%', v_r.code, v_r.kind;
        END CASE;
        -- 付款两种的本位币额由引擎自己返回;另外四种没有,就读【这次会过账的那张分录】
        -- 的借方合计 —— 同一支引擎的产物,不在这里另算一份。
        IF v_entry IS NOT NULL THEN
            SELECT sum(l.debit) INTO v_base FROM journal_lines l WHERE l.entry_id = v_entry;
            v_res := v_res || jsonb_build_object('amount_base', v_base);
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'PQ001', MESSAGE = 'PAYMENT_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ001' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;

-- db/functions/receipt_price_request_dry_run.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q2):按【批准那一刻会用的同一支过账】把一张定价申请试跑一遍,
-- 然后整个回滚 —— 单价、price_history、分录、编号一样都不留。提交与批准各跑一次。
--
-- 【为什么不写一份"校验函数"】与 payroll_request_dry_run、payment_request_dry_run 逐字同一条:
-- 非正价格、币种、缺牌价、期间锁,抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份,
-- 提单人与审批人看见的拒绝是引擎自己的原话。
-- 返回引擎的分解(旧价、新价、价差、在库比例、两份份额)—— 变量的赋值不随子事务回滚,
-- 所以 |Δ 应付| 与"低于已付"都从这一份算,不另算一遍。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。过账跑完抛专用 SQLSTATE PQ003,
-- 只接这一个 —— 引擎自己的任何拒绝照常往外抛。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := receipt_price_post_internal(p_request_id);
        RAISE EXCEPTION USING ERRCODE = 'PQ003', MESSAGE = 'RECEIPT_PRICE_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ003' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;

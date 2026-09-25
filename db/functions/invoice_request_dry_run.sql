-- db/functions/invoice_request_dry_run.sql
-- APR-5a(2026-09-25):按【批准那一刻会用的同一支过账】把一张贷项 / 作废申请试跑一遍,然后整个回滚 ——
-- 贷项通知、分录、编号、作废标记一样都不留。提交时跑一次(提单人当场听见引擎的原话)。
--
-- 【为什么不写一份"校验函数"】与 payment_request_dry_run、payroll_request_dry_run、
-- receipt_price_request_dry_run 逐字同一条:开放余额、逐行天花板、已结清、已发货、有核销、期间锁、
-- 冲销日早于原单,抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份。
-- 返回 invoice_request_post_internal 的返回值(变量的赋值不随子事务回滚),所以 amount_base 从这里来。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。过账跑完抛专用 SQLSTATE PQ004,
-- 只接这一个 —— 引擎自己的任何拒绝照常往外抛。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.invoice_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := invoice_request_post_internal(p_request_id);
        RAISE EXCEPTION USING ERRCODE = 'PQ004', MESSAGE = 'INVOICE_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ004' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;
-- db/functions/payment_request_conflict.sql
-- PAY-REQ-1(2026-09-23):这组核销行里,有没有哪一张单据【已经挂在另一张未了结的
-- 出款申请上】—— 有就返回那张申请的编号,没有返回 NULL。
--
-- 【为什么需要它】dry-run 只看已经过账的付款(payment_allocations × payments posted)。
-- 两张各欠 1,000 的申请分别核销同一张 1,000 的单,各自都校验得过,合起来超付 ——
-- 第二张要到【付款】那一刻才会撞 ALLOC_EXCEEDS,而那时它已经被 CFO 批过了。
-- 规矩写得最简单的那一版:**一张单据同时只挂在一张未了结的申请上**(submitted /
-- approved)。部分付款照样可以,一张付完再提下一张。
--
-- 【怎么认"同一张单据"】每条核销行除了 amount_doc 只有一个非空的去处键
-- (record_payment 的规矩:num_nonnulls(...) = 1),键与值都相同就是同一张。
--
-- 内层算子,无调用者检查;只从 SECURITY DEFINER 的申请函数体内调用。
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.payment_request_conflict(p_allocations jsonb, p_self uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.code
      FROM payment_requests r
      CROSS JOIN LATERAL jsonb_array_elements(r.allocations) o
      CROSS JOIN LATERAL jsonb_array_elements(COALESCE(p_allocations, '[]'::jsonb)) n
     WHERE r.kind = 'payment_out'
       AND r.status IN ('submitted', 'approved')
       AND r.id IS DISTINCT FROM p_self
       AND EXISTS (SELECT 1 FROM jsonb_each_text(n) kv
                    WHERE kv.key <> 'amount_doc' AND kv.value IS NOT NULL
                      AND o->>kv.key = kv.value)
     ORDER BY r.code
     LIMIT 1
$function$
;

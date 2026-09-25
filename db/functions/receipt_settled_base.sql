-- db/functions/receipt_settled_base.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q6 · Q12):一张收货【已经付了多少】(本位币)——
-- 已过账付款的核销 + 预付冲抵。与 ap_open_items 进料支、soft_delete_inbound_batch 同一条算术;
-- 在等的付款申请【不算】(Q12)。读基表:ap_open_items 对没有 finance.view 的人是 0 行,
-- 读它会让一个 cto 账号的"已付为 0"成为一句假话。
-- 定价申请在提交与批准两处都拿它比:新价 × 数量 < 它 → RECEIPT_PRICE_BELOW_SETTLED。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_settled_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT round(COALESCE((SELECT sum(pa.allocated_ccy)
                             FROM payment_allocations pa
                             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                            WHERE pa.inbound_batch_id = p_inbound_batch_id), 0)
               + COALESCE((SELECT sum(ppa.amount_base)
                             FROM prepayment_applications ppa
                            WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0), 2)
$function$
;

-- db/functions/guard_inbound_batch_metals_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5):一张收货挂着在等的定价申请时,它的含量不许改。
--
-- 含量是价格的输入:按已承诺条款改价(committed_terms_price)与化验算价都读 inbound_batch_metals。
-- Step 0 实测:手工含量的写策略开在 module.inbound.edit 上(INSERT / UPDATE / DELETE 都放),
-- 于是一张等着 CFO 批的价,它脚下的含量可以被悄悄换掉。本守卫:INSERT / UPDATE / DELETE,
-- 行所在的收货(UPDATE 两边都判)有在等的申请 → RECEIPT_PRICE_REQUEST_OPEN|收货|那一张申请。
-- ★ 【不分直连写与属主路径】:唯一改含量的属主函数是 apply_assay_result,它在改含量之前
--   就先按名拒(手工来源的申请)或先撤回(化验来源的申请,Tim 的 Q5)—— 走到这里时已经没有在等的申请。
--
-- 【为什么是 INVOKER】与 guard_inbound_batch_price_request 同一条:在不在等由
-- receipt_price_open(DEFINER)问。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_inbound_batch_metals_price_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_bid  uuid;
    v_open text;
BEGIN
    FOREACH v_bid IN ARRAY (CASE TG_OP
                                WHEN 'INSERT' THEN ARRAY[NEW.inbound_batch_id]
                                WHEN 'DELETE' THEN ARRAY[OLD.inbound_batch_id]
                                ELSE ARRAY[OLD.inbound_batch_id, NEW.inbound_batch_id] END) LOOP
        v_open := receipt_price_open(v_bid);
        IF v_open IS NOT NULL THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', split_part(v_open, ' · ', 1), v_open;
        END IF;
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

COMMENT ON FUNCTION public.guard_inbound_batch_metals_price_request() IS
'ROLE-1 Batch 4b(Tim 的 Q5):收货挂着在等的定价申请时,它的 inbound_batch_metals 行 INSERT / UPDATE / DELETE 一律按名拒 RECEIPT_PRICE_REQUEST_OPEN|收货|申请(不分直连与属主路径;apply_assay_result 在改含量之前先拒或先撤回)。INVOKER;在不在等经 receipt_price_open(DEFINER)问。';

-- db/functions/guard_inbound_batch_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5 · Q3):收货表头上两道闸。
--
-- ① 【一张定价申请在等的时候,它批的那几样东西不许动】(Q5)
--    供应商、采购单、采购行被改,或收货被注销(deleted_at 由空变有)→
--    RECEIPT_PRICE_REQUEST_OPEN|收货|那一张申请。
--    ★ 这一道【不分直连写与属主路径】:注销走的是 soft_delete_inbound_batch(SECURITY DEFINER),
--      它自己也按名拒一次;这里是第二道 —— 将来哪一支属主函数改了供应商,照样撞上。
--    数量与含量由指纹在批准时再比(RECEIPT_PRICE_CHANGED_SINCE_REQUEST);含量的直连写另由
--    guard_inbound_batch_metals_price_request 当场拒。
-- ② 【pricing_status 只经函数写】(Q3)
--    直连写(row_security_active)改 pricing_status → PRICING_STATUS_VIA_FUNCTION|收货。
--    Step 0 实测:任何持 module.inbound.edit 的人都能直接把一张收货写成 final,而 Q3 的
--    「final 只在 CFO 批准时置」没有这一道就只是一句话。属主路径(批准那一支)看不见本守卫。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径(②);在不在等由 receipt_price_open(DEFINER)问
-- —— 不持采购价码的写入者在 INVOKER 里读不到申请表,会把"看不见"读成"没有申请"。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_inbound_batch_price_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_open text;
BEGIN
    IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
       OR NEW.purchase_order_id IS DISTINCT FROM OLD.purchase_order_id
       OR NEW.purchase_order_line_id IS DISTINCT FROM OLD.purchase_order_line_id
       OR (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL) THEN
        v_open := receipt_price_open(OLD.id);
        IF v_open IS NOT NULL THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', OLD.code, v_open;
        END IF;
    END IF;
    IF NEW.pricing_status IS DISTINCT FROM OLD.pricing_status AND row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'PRICING_STATUS_VIA_FUNCTION|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_inbound_batch_price_request() IS
'ROLE-1 Batch 4b:① 一张收货挂着在等的定价申请时,改供应商 / 采购单 / 采购行或注销它,按名拒 RECEIPT_PRICE_REQUEST_OPEN|收货|申请(不分直连与属主路径);② 直连写(row_security_active)改 pricing_status,按名拒 PRICING_STATUS_VIA_FUNCTION|收货 —— final 只在 CFO 批准化验来源的申请时置(Tim 的 Q3)。INVOKER;在不在等经 receipt_price_open(DEFINER)问。';

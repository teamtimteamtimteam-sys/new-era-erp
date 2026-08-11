-- FRT-1 fu2(2026-08-11):batch_freight_base 改回 SECURITY INVOKER
--
-- 【gate 的 B2 抓到的,第二次了(METAL-2 fu1 是同一条)】属主权限 + 不查调用者 +
-- 对 authenticated 可执行 —— 那就是 B2 的定义。
--
-- 修法仍然是【去掉 DEFINER】,不是加一句检查、更不是进 allowlist:它只读
-- freight_allocations / freight_documents,而这两张表自己的 RLS 就写着
-- module.inbound.view OR module.finance.view。守卫跟着数据自己的 RLS 走(OPS-15)。
--
-- 【两个内部调用方不受影响,而这一点值得写下来】
--   * allocate_processing_costs 是 SECURITY DEFINER:在它体内调用时,
--     当前有效用户已经是属主,INVOKER 函数照样读得到全量;
--   * processing_run_allocation_status 是属主权限视图,同理。
-- 于是"内部算得到、外部按调用者裁决"两件事同时成立,不需要 DEFINER。

BEGIN;

CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price + 本函数。
    -- 冲销掉的运费单不计(status = 'reversed')。
    SELECT COALESCE(SUM(fa.amount_base), 0)
    FROM freight_allocations fa
    JOIN freight_documents fd ON fd.id = fa.freight_document_id
    WHERE fa.inbound_batch_id = p_inbound_batch_id
      AND fd.deleted_at IS NULL AND fd.status = 'posted';
$function$;

COMMIT;

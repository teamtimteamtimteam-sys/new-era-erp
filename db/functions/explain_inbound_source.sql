-- db/functions/explain_inbound_source.sql
-- RECV-SOURCE-1(3e):事后给一张无单收货补理由的【门】。
-- 事后补的理由是对过去的一个新断言,必须带自己的出处 —— 本函数盖章
-- (recorded_by = auth.uid()、recorded_at = now());直连 UPDATE 不盖章会被
-- guard_receipt_source_stated 按名拒(SOURCE_PROVENANCE_REQUIRED)。
-- auth.uid() 为空时 inbound_source_recorded_pair 拒 —— 没有人,就没有"谁补的"。
-- RETURNS void,所以每个失败分支都 RAISE —— 只返回 NULL 的断言等于没断言。
--
-- NOTE: introduced by db/migrations/2026-09-01-recvsource1-a-receipt-must-say-where-it-came-from.sql.

CREATE OR REPLACE FUNCTION public.explain_inbound_source(p_batch_id uuid, p_reason_code text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
        -- 这扇门只做一件事:给理由。不给理由就没有可盖章的东西。
        RAISE EXCEPTION 'RECEIPT_SOURCE_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = p_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_batch_id;
    END IF;
    -- 说明本身与它的出处【一笔写完】。R3 的句子检查、外键的查无此码,
    -- 都由表上的守卫与约束抛 —— 这里一个字不重复。
    -- 【auth.uid() 为空时 recorded_pair 会拒】—— 没有人,就没有"谁补的",
    -- 这扇门便不该开(出处不能是 NULL 冒充的)。
    UPDATE inbound_batches SET
        source_reason_code        = p_reason_code,
        source_reason_note        = NULLIF(btrim(COALESCE(p_note, '')), ''),
        source_reason_recorded_by = auth.uid(),
        source_reason_recorded_at = now(),
        updated_by                = auth.uid()
    WHERE id = p_batch_id;
END;
$function$

;

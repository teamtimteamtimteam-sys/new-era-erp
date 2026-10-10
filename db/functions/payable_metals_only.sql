-- db/functions/payable_metals_only.sql
-- MES-6a-2(2026-10-10,MES-6a Step 0 Q28,Tim):一张 [{metal, content_pct}, …] 的清单里,把【字典里登记为不计价】的物质拿掉 ——
--   惩罚元素(氟、氯)与 other。按含量计价的那几条读者(按化验应用 · 按化验试算 · 按已承诺条款计价 · 产出的销售报价)把一份化验
--   或一批的含量交给计价引擎之前过这一道:引擎(calculate_metal_price_from_terms)对一个不计价的码【按名拒】SUBSTANCE_NOT_PAYABLE,
--   而一份同时测了氟的化验不该因此算不出镍钴的钱(Q28:氟落在化验或产出批上,什么都不坏)。
--   【不认识的码原样留着】—— 那是引擎的 METAL_INVALID 要说的话,这里不替它吞掉。NULL 进 NULL 出;顺序不变。
--   INVOKER、只读;从 authenticated 收回(只给那几支 DEFINER 读者在体内用)。
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
CREATE OR REPLACE FUNCTION public.payable_metals_only(p_metals jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' THEN p_metals
        ELSE (SELECT COALESCE(jsonb_agg(e.v ORDER BY e.n), '[]'::jsonb)
                FROM jsonb_array_elements(p_metals) WITH ORDINALITY AS e(v, n)
               WHERE NOT EXISTS (SELECT 1 FROM substances s
                                  WHERE s.code = e.v ->> 'metal' AND s.role <> 'payable_metal'))
    END
$function$

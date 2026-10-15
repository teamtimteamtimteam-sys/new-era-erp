-- db/functions/assay_is_supplement.sql
-- MES-6b-1(2026-10-15,F5;MES-6b Step 0 Q16 · Q36,Tim):【这份化验是不是一份"补充"】—— 它一种可计价的金属都没测(只测了氟、氯这类惩罚元素,
--   或者干脆只报了水分与指标)。补充在两侧(进料、产出)都这样应用:
--     · 只换掉【它测了的】那几种物质的含量行(行带 content_source = 'assay' 与它自己的 source_assay_id),别的含量一行不动;
--     · 不计价(进料不提定价申请);
--     · 不取代任何一份,也不被任何一份取代(superseded_by 两个方向都不碰);
--     · 撤销它只删它自己写下的那几行。
--   一份测了可计价金属的化验仍是"一份完整的陈述"—— 应用它就换掉整批含量(fixture 54E 一字未改)。
--   判"补充"只有这一支(应用、试算、撤销,进料与产出都读它)。INVOKER:读化验的含量行(跟着批次的读策略)与物质字典(对每个人开着)。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.assay_is_supplement(p_assay_result_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT NOT EXISTS (SELECT 1 FROM assay_result_metals m
                         JOIN substances s ON s.code = m.metal AND s.role = 'payable_metal'
                        WHERE m.assay_result_id = p_assay_result_id)
$function$

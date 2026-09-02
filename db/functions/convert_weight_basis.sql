-- db/functions/convert_weight_basis.sql
-- TOOLS-1 ④(2026-09-03):湿基/干基之间换算一个【重量】。
--
-- 【它是提取出来的,不是新写的】表达式从 sale_settlement_compute 里逐字符搬来,
-- 于是结算与 /tools/converter 是【一份实现,两个调用方】(reprice_split 那个先例)。
-- AGENTS.md 那条预览规则记着这个仓库为"两份实现"付过四次账,而这一段决定钱。
--
-- 【刻意保留的两处旧行为 —— 改掉任何一处都是"改变输出"】
--   · 同基准时原值不动,**不 round**;
--   · 目标是 dry 时 COALESCE(m, 0) —— 结算在基准相同时允许 moisture 为 NULL。
--   · 水分 = 100% 会抛除零。守卫加在换算器那一侧(app/tools/converter/actions.ts),
--     不加在这里:结算路径不该因为一个新页面而改变失败模式。
-- db/fixtures/187 把新旧逐点比对了一遍(重量 60 个输入、含量 120 个)。
--
-- NOTE: introduced by db/migrations/2026-09-03-tools1-weight-basis-primitive-and-bilingual-pricing-notes.sql.

CREATE OR REPLACE FUNCTION public.convert_weight_basis(p_weight numeric, p_from_basis text, p_to_basis text, p_moisture_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【与 sale_settlement_compute 原处逐字相同】
    --   目标是 as_received:原值不动(原式是 CASE 的 THEN 分支,不 round)
    --   目标是 dry        :round(w * (1 - COALESCE(m,0)/100.0), 4)
    -- COALESCE 留在原处:结算那一侧在基准相同时允许 moisture 为 NULL,
    -- 而基准不同时上游已经按名拒过(SETTLEMENT_MOISTURE_NOT_STATED)。
    SELECT CASE
        WHEN p_to_basis = p_from_basis THEN p_weight
        WHEN p_to_basis = 'as_received'
            THEN round(p_weight / (1 - p_moisture_pct / 100.0), 4)
        ELSE round(p_weight * (1 - COALESCE(p_moisture_pct, 0) / 100.0), 4)
    END
$function$;

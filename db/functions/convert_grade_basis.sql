-- db/functions/convert_grade_basis.sql
-- TOOLS-1 ④(2026-09-03):湿基/干基之间换算一个【含量百分比】。
--
-- 【含金属是不变量】重量与含量必须换到【同一个基准】上,两者相乘才守恒 ——
-- 这正是 db/fixtures/149 A 臂断言"湿基与干基算出不同的钱,而含金属两边一模一样"
-- 的那条不变量,也是 fixture 187 C 臂在【新增的那个方向】上再钉一次的东西。
--
-- 【这里没有 COALESCE,提取前也没有】基准不同而 moisture 为 NULL 时结果是 NULL,
-- 而上游(sale_settlement_compute)已经按名拒过那种输入
-- (SETTLEMENT_MOISTURE_NOT_STATED)。原样保留。
--
-- NOTE: introduced by db/migrations/2026-09-03-tools1-weight-basis-primitive-and-bilingual-pricing-notes.sql.

CREATE OR REPLACE FUNCTION public.convert_grade_basis(p_content_pct numeric, p_from_basis text, p_to_basis text, p_moisture_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【与 sale_settlement_compute 原处逐字相同】
    --   同基准        → 原值不动
    --   dry → as_received → content * (1 - m/100)
    --   否则(as_received → dry) → content / (1 - m/100)
    -- 【这里没有 COALESCE,原处也没有】:基准不同而 moisture 为 NULL 时,
    -- 结果是 NULL —— 而上游已经按名拒过那种输入。原样保留。
    SELECT CASE
        WHEN p_from_basis = p_to_basis THEN p_content_pct
        WHEN p_from_basis = 'dry' AND p_to_basis = 'as_received'
            THEN p_content_pct * (1 - p_moisture_pct / 100.0)
        ELSE p_content_pct / (1 - p_moisture_pct / 100.0)
    END
$function$;

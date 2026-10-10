-- db/functions/guard_substance_role.sql
-- MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q27,Tim):一张只收【某一种】物质的表上,写进来的那个码必须是那一种。
--   TG_ARGV[0] = 要的 role(payable_metal / penalty_element),TG_ARGV[1] = 存码的那一列(metal / substance)。
--   定价那几张表要 payable_metal → 拒 SUBSTANCE_NOT_PAYABLE|<码>;合同的惩罚条款要 penalty_element → 拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>。
--   写入函数(upsert_metal_prices、calculate_metal_price_from_terms)在自己那一步先按名说一遍;这一道守着【每一条】写路 ——
--   直连写的合同条款(action.contract_terms 的写策略)、公式的提交与它的试跑、承诺副本的复制。
--   不在字典里的码不归它管:外键在它之后照旧按 foreign_key_violation 拒(两件不同的事,两句不同的话)。
--   INVOKER:substances 的读策略对每一个登录的人都是 USING (true),没有什么要借属主的眼睛去看。
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
CREATE OR REPLACE FUNCTION public.guard_substance_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text := to_jsonb(NEW) ->> TG_ARGV[1];
    v_role text;
BEGIN
    IF v_code IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.role INTO v_role FROM substances s WHERE s.code = v_code;
    IF NOT FOUND THEN
        RETURN NEW;   -- 外键会说"不在字典里",那不是这一道的话
    END IF;
    IF v_role IS DISTINCT FROM TG_ARGV[0] THEN
        IF TG_ARGV[0] = 'payable_metal' THEN
            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_code
              USING HINT = '这种物质不是按含量计价的金属(substances.role ≠ payable_metal)—— 它不进行情、公式、承诺、合同计价与精炼费';
        END IF;
        RAISE EXCEPTION 'SUBSTANCE_NOT_PENALTY_ELEMENT|%', v_code
          USING HINT = '合同的惩罚条款只收惩罚元素(substances.role = penalty_element)';
    END IF;
    RETURN NEW;
END;
$function$

-- db/functions/guard_substance_role.sql
-- MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q27,Tim):一张只收【某一种】物质的表上,写进来的那个码必须是那一种。
--   TG_ARGV[0] = 要的 role(payable_metal / penalty_element),TG_ARGV[1] = 存码的那一列(metal / substance)。
--   定价那几张表要 payable_metal → 拒 SUBSTANCE_NOT_PAYABLE|<码>;合同的惩罚条款要 penalty_element → 拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>。
--   写入函数(upsert_metal_prices、calculate_metal_price_from_terms)在自己那一步先按名说一遍;这一道守着【每一条】写路 ——
--   直连写的合同条款(action.contract_terms 的写策略)、公式的提交与它的试跑、承诺副本的复制。
--   不在字典里的码不归它管:外键在它之后照旧按 foreign_key_violation 拒(两件不同的事,两句不同的话)。
--   INVOKER:substances 的读策略对每一个登录的人都是 USING (true),没有什么要借属主的眼睛去看。
--   ★ MES-6b-1(2026-10-15,F4;MES-6b Step 0 Q15,Tim):第一个参数从【一种】角色变成【一组】(逗号分隔)—— 合同的惩罚条款从此收
--     payable_metal 或 penalty_element(铜、铝在镍黑粉里是杂质,一份合同可以罚它们);other 照拒。定价那几张表仍只收 payable_metal,
--     拒的那句话不变(SUBSTANCE_NOT_PAYABLE);惩罚条款拒 other 仍说 SUBSTANCE_NOT_PENALTY_ELEMENT。【每一条计价路仍只认可计价金属】——
--     一种既计价又罚的物质在同一份合同里由 guard_substance_priced_and_penalised 按名拒(Q33)。
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql;
--       replaced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql (a set of roles).
CREATE OR REPLACE FUNCTION public.guard_substance_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text := to_jsonb(NEW) ->> TG_ARGV[1];
    v_roles text[] := string_to_array(TG_ARGV[0], ',');
    v_role  text;
BEGIN
    IF v_code IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.role INTO v_role FROM substances s WHERE s.code = v_code;
    IF NOT FOUND THEN
        RETURN NEW;   -- 外键会说"不在字典里",那不是这一道的话
    END IF;
    IF v_role IS NULL OR NOT (v_role = ANY (v_roles)) THEN
        IF v_roles = ARRAY['payable_metal'] THEN
            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_code
              USING HINT = '这种物质不是按含量计价的金属(substances.role ≠ payable_metal)—— 它不进行情、公式、承诺、合同计价与精炼费';
        END IF;
        RAISE EXCEPTION 'SUBSTANCE_NOT_PENALTY_ELEMENT|%', v_code
          USING HINT = '合同的惩罚条款只收惩罚元素或可计价的金属(substances.role = penalty_element / payable_metal)';
    END IF;
    RETURN NEW;
END;
$function$

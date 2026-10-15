-- db/functions/guard_substance_priced_and_penalised.sql
-- MES-6b-1(2026-10-15,F4;MES-6b Step 0 Q33,Tim):【一种物质在一份合同里要么计价、要么罚,不两者都是】。
--   此前两条都成立时结算两样都做:按含量付钱、扣精炼费,再按超阈值罚(sale_settlement_compute 的两圈互不相看)—— 没有任何东西挡着。
--   从 F4 起惩罚条款也收可计价的金属(铜作为镍黑粉里的杂质),于是这一条必须在【条款】这一层就拒:
--     contract_pricing_terms   BEFORE INSERT OR UPDATE OF metal, contract_id     —— 同一份合同的惩罚条款里已经有它
--     contract_penalty_elements BEFORE INSERT OR UPDATE OF substance, contract_id —— 同一份合同的计价条款里已经有它
--   → SUBSTANCE_PRICED_AND_PENALISED|<码>。申请生效时 contract_activation_missing 再问一次(条款表之外的写路、或这一道之前写下的行)。
--   【属主路径同样受它管】它守的是条款的一致性,不是权限(与 guard_substance_role 同一个立场)。
--   SECURITY DEFINER:对面那张表的读策略认码(客户 / 供应商查看),一个只持 action.contract_terms 的写者读不到它也不能因此放过去 ——
--   void 断言读不到就是放行(INVOKER-JOIN 那一族),所以这里借属主的眼睛。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
CREATE OR REPLACE FUNCTION public.guard_substance_priced_and_penalised()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_TABLE_NAME = 'contract_pricing_terms' THEN
        IF EXISTS (SELECT 1 FROM contract_penalty_elements pe
                    WHERE pe.contract_id = NEW.contract_id AND pe.substance = NEW.metal) THEN
            RAISE EXCEPTION 'SUBSTANCE_PRICED_AND_PENALISED|%', NEW.metal
              USING HINT = '这份合同的惩罚条款里已经有这种物质 —— 一种物质在一份合同里要么计价、要么罚。';
        END IF;
    ELSE
        IF EXISTS (SELECT 1 FROM contract_pricing_terms pt
                    WHERE pt.contract_id = NEW.contract_id AND pt.metal = NEW.substance) THEN
            RAISE EXCEPTION 'SUBSTANCE_PRICED_AND_PENALISED|%', NEW.substance
              USING HINT = '这份合同的计价条款里已经有这种物质 —— 一种物质在一份合同里要么计价、要么罚。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$

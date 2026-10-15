-- db/functions/contract_activation_missing.sql
-- TERMS-EDIT-1(Tim 2026-09-27,grilling Q3):一份合同【申请生效之前】还缺哪几条条款 —— 空数组 = 不缺。
--   只对卖方合同(side = 'sell')有要求;买方合同什么都不要求(采购侧的指数计价是 index-pricing-spec §9,仍在 Tim 那里)。
--   卖方合同缺的,按这个顺序逐条说出来:
--     'settlement_terms'           没有结算口径那一行(一份合同恰好一行;唯一约束管"不多于一行")
--     'pricing_terms'              一条计价条款都没有
--     'refining_charge:<metal>'    精炼费口径声明为 per_metal,而这个计价金属没有精炼费那一行
--     'penalty_elements'           惩罚口径声明为 per_element,而一条惩罚元素都没有
--   ★ 这四条正是 sale_settlement_compute 在结算那一刻会按名拒的四件事(SETTLEMENT_TERMS_NOT_SET ·
--     SETTLEMENT_PAYABLE_NOT_STATED · REFINING_CHARGE_NOT_FILED · PENALTY_ELEMENTS_NOT_FILED)。它们读的是挂接那一刻
--     抄下的副本(contract_document_terms),所以一份缺条款的合同一旦生效,挂在它下面的销售单到结算时才响 ——
--     而那时合同已经冻结了。所以在申请生效时就拒(terms_request_submit_internal → CONTRACT_TERMS_INCOMPLETE)。
--   ★ MES-6b-1(2026-10-15,V17 · F4;MES-6b Step 0 Q25 · Q33,Tim)多三条,同样只对卖方合同:
--     'quality_limit_basis'               结算口径里质量验收限的口径没声明(V17 Not yet set —— 没声明不是"没有限")
--     'quality_limits'                    声明了 per_parameter,而 contract_quality_limits 一行都没有
--     'priced_and_penalised:<码>'          同一种物质既在计价条款里、又在惩罚条款里(条款表上的守卫先拒,这里是第二道)
--     提交那一支把后两条说成它们自己的名字(QUALITY_LIMITS_NOT_FILED · SUBSTANCE_PRICED_AND_PENALISED),其余照旧 CONTRACT_TERMS_INCOMPLETE。
--   两处读它:提交那一支(属主身份,读全部)与合同详情页那张清单(以调用者身份,受 RLS —— 看不见这份合同的人读到空)。
--   SECURITY INVOKER:它不替任何人打开任何一行。
-- NOTE: introduced by db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql.

CREATE OR REPLACE FUNCTION public.contract_activation_missing(p_contract_id uuid)
 RETURNS text[]
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(array_agg(m.item ORDER BY m.ord, m.item), ARRAY[]::text[])
      FROM contracts c
      LEFT JOIN contract_settlement_terms st ON st.contract_id = c.id
      CROSS JOIN LATERAL (
          SELECT 1 AS ord, 'settlement_terms'::text AS item WHERE st.id IS NULL
          UNION ALL
          SELECT 2, 'pricing_terms'
           WHERE NOT EXISTS (SELECT 1 FROM contract_pricing_terms pt WHERE pt.contract_id = c.id)
          UNION ALL
          SELECT 3, 'refining_charge:' || pt.metal
            FROM contract_pricing_terms pt
           WHERE pt.contract_id = c.id AND st.refining_charge_basis = 'per_metal'
             AND NOT EXISTS (SELECT 1 FROM contract_refining_charges rc
                              WHERE rc.contract_id = c.id AND rc.metal = pt.metal)
          UNION ALL
          SELECT 4, 'penalty_elements'
           WHERE st.penalty_basis = 'per_element'
             AND NOT EXISTS (SELECT 1 FROM contract_penalty_elements pe WHERE pe.contract_id = c.id)
          UNION ALL
          SELECT 5, 'quality_limit_basis'
           WHERE st.id IS NOT NULL AND st.quality_limit_basis IS NULL
          UNION ALL
          SELECT 6, 'quality_limits'
           WHERE st.quality_limit_basis = 'per_parameter'
             AND NOT EXISTS (SELECT 1 FROM contract_quality_limits ql WHERE ql.contract_id = c.id)
          UNION ALL
          SELECT 7, 'priced_and_penalised:' || pt.metal
            FROM contract_pricing_terms pt
           WHERE pt.contract_id = c.id
             AND EXISTS (SELECT 1 FROM contract_penalty_elements pe
                          WHERE pe.contract_id = c.id AND pe.substance = pt.metal)
      ) m
     WHERE c.id = p_contract_id AND c.side = 'sell'
$function$;

-- db/functions/contract_terms_state.sql
-- APR-8(2026-09-26):一份合同此刻的样子 —— 表头(去掉 id、编号与创建 / 修改人时刻)与七张条款表的每一行
-- (去掉 id、contract_id 与创建 / 修改人时刻,按行文排序,于是同一组条款读出同一串字)。
-- 三个读它的人:CFO 的 snapshot(current;上一次批准时的那一份也是它)、fingerprint、屏幕上的差别。
-- 不存在的合同 → NULL。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.contract_terms_state(p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'header', to_jsonb(c) - 'id' - 'code' - 'status' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by',
               'grade_specs', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_grade_specs t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'insurance_obligations', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_insurance_obligations t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'volume_commitments', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_volume_commitments t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'pricing_terms', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_pricing_terms t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'settlement_terms', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_settlement_terms t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'refining_charges', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_refining_charges t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'penalty_elements', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_penalty_elements t WHERE t.contract_id = c.id) x), '[]'::jsonb))
      FROM contracts c
     WHERE c.id = p_contract_id
$function$;

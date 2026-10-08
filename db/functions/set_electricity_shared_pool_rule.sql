-- db/functions/set_electricity_shared_pool_rule.sql
-- MES-5a-2(2026-10-08,MES-0 §5.1 V25;MES-5a Step 0 Q25 · Q32,Tim):【写下(或清空)V25 —— 共用池的电怎么摊】。
--   module.finance.edit。空串 = 清空(回到 Not yet set)。只记下规则;本刀的分摊【不】按它摊(electricity_settings 的抬头)。
--   改动进变更记录(主语 electricity_settings,画在 /finance/electricity)。返回 {shared_pool_rule}。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.set_electricity_shared_pool_rule(p_rule text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rule text := NULLIF(btrim(COALESCE(p_rule, '')), '');
BEGIN
    PERFORM require_permission('module.finance.edit');
    UPDATE electricity_settings SET shared_pool_rule = v_rule, updated_by = auth.uid() WHERE id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ELECTRICITY_SETTINGS_MISSING';
    END IF;
    RETURN jsonb_build_object('shared_pool_rule', v_rule);
END;
$function$

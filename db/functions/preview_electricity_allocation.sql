-- db/functions/preview_electricity_allocation.sql
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q24,Tim):【过账之前先看一眼】—— 原样返回 electricity_allocation_compute 算出来的东西:
--   每一台电表量到多少、每一台机器按什么分、每一炉分到多少 kWh 与多少钱、要冲掉哪几条估计、那张分录。过账调的是【同一支】,
--   所以预览上的每一个数就是过账会写下的数(fixture 256 ALLOC 逐键比对)。它什么都不写。
--   门:module.finance.view(看一眼不是动账;动账要 module.finance.edit,见 post_electricity_allocation)。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.preview_electricity_allocation(p_period_from date, p_period_to date, p_bill_amount numeric, p_bill_kwh numeric, p_currency text, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.view');
    RETURN electricity_allocation_compute(p_period_from, p_period_to, p_bill_amount, p_bill_kwh, p_currency, p_payment_status, p_bank_account);
END;
$function$

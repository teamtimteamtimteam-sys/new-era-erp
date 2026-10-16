-- db/functions/supplier_scorecard_measure_keys.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q3):评分卡里【计分的那几项】的名字 —— 一处定义。supplier_scorecard_measures 的 scored 吐的正是这几个键;
--   V23 的权重(supplier_score_settings.weights)必须正好给这几个键(set_supplier_score_settings 按名拒多与少);评级按它们求和。
--   等级超标不在这里(只显示,CONTRACT-1)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
CREATE OR REPLACE FUNCTION public.supplier_scorecard_measure_keys()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT ARRAY['short_lines', 'over_lines', 'ncr_open', 'ncr_accept', 'ncr_accept_with_penalty', 'ncr_reject', 'ncr_rework',
                 'ncr_downgrade', 'disputes', 'discharge_mismatches', 'certificate_lapse_days']::text[]
$function$

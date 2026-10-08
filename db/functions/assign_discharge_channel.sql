-- db/functions/assign_discharge_channel.sql
-- MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q9,Tim):【记下一炉放电里一个通道接的是哪个模组】—— 装机时记;手工录入可以不记。
--   码:action.processing_aftercare(提交之后记的事,MES-4a 的码)。拒:
--     RUN_NOT_COMMITTED|<单> · DISCHARGE_RUN_NOT_BY_UNIT|<单>|<工序> · BATCH_KIND_UNKNOWN · DISCHARGE_BATCH_NOT_INPUT|<单>
--     DISCHARGE_VALUE_INVALID|channel_no · DISCHARGE_MODULE_REF_REQUIRED
--     DISCHARGE_CHANNEL_TAKEN|<通道>|<当前记着的模组>   这一炉这个通道当前已经记着一个模组(要换就更正那一条)
--     DISCHARGE_MODULE_ALREADY_ON_CHANNEL|<模组>|<通道>  这一炉这一批的这个模组当前已经记在另一个通道上
--   内层共用:discharge_channel_internal(更正也走它)。返回新行 id。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a1-discharge-by-module.sql.

CREATE OR REPLACE FUNCTION public.assign_discharge_channel(p_run_id uuid, p_kind text, p_batch_id uuid, p_channel_no integer, p_module_ref text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_aftercare');
    RETURN discharge_channel_internal(p_run_id, p_kind, p_batch_id, p_channel_no, p_module_ref, false, NULL, NULL);
END;
$function$

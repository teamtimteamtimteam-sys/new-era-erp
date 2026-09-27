-- db/functions/asset_disposal_fingerprint.sql
-- APR-9(2026-09-27,grilling Q8):一张处置申请批的是【哪一张卡】—— 成本(原币、币种、汇率、本位币)、残值、年限、
-- 购置日、投用日、折旧科目、状态,以及折旧锚点(张数与最后一张的生效月)。提交时存进 snapshot,批准时再算一遍比;
-- 不一样 → ASSET_CHANGED_SINCE_REQUEST,申请仍在等。【不含已提折旧】—— 折旧在等待中照常跑(Q8:关账要它),
-- 批准时按那一刻的累计折旧算损益,那正是 Q7 说的"按批准那一刻的活数"。
-- 资产不存在 → NULL。EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_fingerprint(p_asset_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'cost_ccy', a.cost_ccy, 'currency', a.currency, 'fx_rate', a.fx_rate, 'cost_base', a.cost_base,
               'residual_base', a.residual_base, 'useful_life_months', a.useful_life_months,
               'acquisition_date', a.acquisition_date, 'in_service_date', a.in_service_date,
               'depreciation_account_code', a.depreciation_account_code, 'status', a.status,
               'anchors', (SELECT count(*) FROM fixed_asset_depreciation_anchors an WHERE an.asset_id = a.id),
               'last_anchor', (SELECT max(an.effective_from) FROM fixed_asset_depreciation_anchors an
                                WHERE an.asset_id = a.id))
      FROM fixed_assets a
     WHERE a.id = p_asset_id;
$function$;

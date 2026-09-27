-- db/functions/dispose_fixed_asset.sql
-- 处置:出售或报废(FIN-22)。
-- ★ APR-9(2026-09-27,Tim 的矩阵 §4「处置 | 财务 | CFO」):**这扇门只会按名拒了。** 一台资产的处置从此是一张申请 ——
--   submit_asset_disposal_request(财务提)→ decide_asset_disposal_request(CFO 批)→ 批准当场处置,处置日 = 批准日。
--   原函数体原样搬进 dispose_fixed_asset_internal(authenticated 调不到)。签名与门(module.finance.edit)不变:
--   没有码的人读到的仍是缺的那个码,有码的人读到 ASSET_DISPOSAL_NEEDS_REQUEST|<资产编号> —— 旧屏幕在部署之前按下去
--   也只会得到这一句,什么都不过账(APR-7 的 WAREHOUSE_NEEDS_APPROVED_REQUEST 同形)。
-- NOTE: introduced by db/migrations/2026-08-06-fin22-fixed-assets-and-depreciation.sql;
--       reduced to a refusal by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.dispose_fixed_asset(p_asset_id uuid, p_disposal_date date, p_proceeds numeric DEFAULT 0, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM fixed_assets WHERE id = p_asset_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    RAISE EXCEPTION 'ASSET_DISPOSAL_NEEDS_REQUEST|%', v_code;
END;
$function$;

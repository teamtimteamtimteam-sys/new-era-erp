-- db/functions/compliance_pack_month_status.sql
-- MES-8b-1(2026-10-17,MES-8 Step 0 Q15,Tim):【这个月的合规包冻了没有】—— 月结那一步的一行警告读它(从不挡关账,MES-0 Q48 的形状)。
--   返回 {month, locked, pack_code}:月份锁上了而没有一份在册的包 → 页面说「Compliance pack for <月>: not frozen」并指向合规包页。
--   一个"有没有"的事实,不是一份包的内容,所以门是 module.finance.view【或】module.compliance.view(月结页的读者是财务,
--   而财务不持合规的码 —— OPS-14 的 (a):借来的派生事实,属主权限 + 读者自己的模块码)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.compliance_pack_month_status(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start  date;
    v_end    date;
    v_locked date;
BEGIN
    IF NOT (has_permission('module.finance.view') OR has_permission('module.compliance.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view · module.compliance.view';
    END IF;
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    SELECT locked_before INTO v_locked FROM finance_settings;
    RETURN jsonb_build_object(
        'month', to_char(v_start, 'YYYY-MM'),
        'locked', v_locked IS NOT NULL AND v_locked > v_end,
        'pack_code', (SELECT p.code FROM compliance_packs p WHERE p.period_month = v_start AND p.superseded_at IS NULL));
END;
$function$

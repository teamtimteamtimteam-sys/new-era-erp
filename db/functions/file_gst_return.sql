-- db/functions/file_gst_return.sql
-- GST-1:记录一次申报。
-- ★ APR-10(2026-09-27,Tim 的矩阵 §2「GST 申报与更正 | 财务 | CFO」):**这扇门只会按名拒了。** 申报从此是一张申请 ——
--   submit_gst_filing_request(财务提,冻结 F5 每一格)→ decide_gst_filing_request(CFO 批,再算一遍、相等才写快照,
--   期间 → approved)→ 财务去 IRAS 报 → record_gst_filing(一步记下申报日与参考号,期间 → filed)。
--   签名与门(module.finance.edit)不变:没有码的人读到的仍是缺的那个码,有码的人读到
--   GST_FILING_NEEDS_APPROVED_REQUEST|<期间编号> —— 旧屏幕在部署之前按下去也只会得到这一句,什么都不写
--   (APR-9 的 ASSET_DISPOSAL_NEEDS_REQUEST 同形)。原来那一句"申报要求那一季每个月都已关账"搬进了提交与批准。
-- NOTE: introduced by db/migrations/2026-08-24-gst1-tax-codes-f5-and-filing-periods.sql;
--       reduced to a refusal by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.file_gst_return(p_period_id uuid, p_filed_on date DEFAULT NULL::date, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM gst_periods WHERE id = p_period_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_period_id; END IF;
    RAISE EXCEPTION 'GST_FILING_NEEDS_APPROVED_REQUEST|%', v_code;
END;
$function$;

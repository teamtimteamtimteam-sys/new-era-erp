-- db/functions/record_gst_filing.sql
-- APR-10(2026-09-27,grilling Q1 第三步):财务去 IRAS 报了之后,回来一步记下【申报日】与【参考号】。
-- 不经批准:数字在 CFO 批准那一刻已经抄进 gst_return_boxes、锁死了,这一步只记"什么时候报的、回执是什么"。
-- 只收 approved 的期间(GST_FILING_NOT_APPROVED|<code>);申报日必填(GST_FILED_DATE_REQUIRED —— file_gst_return 当年
-- 那一条具名拒绝,参数照旧 DEFAULT NULL:页面没有办法把"没填"送进一个必填的 date 参数,见 GST-1-fu2)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.record_gst_filing(p_period_id uuid, p_filed_on date DEFAULT NULL::date, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p gst_periods%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_p FROM gst_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_period_id; END IF;
    IF v_p.status = 'filed' THEN
        RAISE EXCEPTION 'GST_PERIOD_ALREADY_FILED|%|%', v_p.code, v_p.filed_on;
    END IF;
    IF v_p.status <> 'approved' THEN
        RAISE EXCEPTION 'GST_FILING_NOT_APPROVED|%', v_p.code;
    END IF;
    IF p_filed_on IS NULL THEN RAISE EXCEPTION 'GST_FILED_DATE_REQUIRED|%', v_p.code; END IF;

    UPDATE gst_periods
       SET status = 'filed', filed_at = now(), filed_by = auth.uid(),
           filed_on = p_filed_on, filed_reference = NULLIF(btrim(COALESCE(p_reference, '')), '')
     WHERE id = p_period_id;

    RETURN jsonb_build_object('gst_period_id', p_period_id, 'code', v_p.code,
                              'filed_on', p_filed_on,
                              'reference', NULLIF(btrim(COALESCE(p_reference, '')), ''));
END;
$function$;

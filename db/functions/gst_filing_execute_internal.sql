-- db/functions/gst_filing_execute_internal.sql
-- APR-10(2026-09-27):一张 GST 申报申请【生效】的那一步 —— 批准(或审批关着时的提交)当场调它。
--   ① 前置条件再判一次:那一季每个月都已关账(GST_PERIOD_NOT_LOCKED,file_gst_return 当年那一句原话);
--   ② 再算一遍 F5,与提交时冻结的 boxes 逐字相等才往下(GST_RETURN_CHANGED_SINCE_REQUEST|<label>)——
--      锁里仍然许可的路若动了数字,批准就拒、整笔回滚、申请仍在等(grilling Q3);
--   ③ 把冻结的那一组抄进 gst_return_boxes(不可改、不可删的快照),期间 open → approved。
-- 申报日与参考号【不在这里】:那是财务去 IRAS 报了之后的事(record_gst_filing)。
-- EXECUTE 已从 authenticated 收回 —— 它不查调用者,靠的就是调不到。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.gst_filing_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      gst_filing_requests%ROWTYPE;
    v_p      gst_periods%ROWTYPE;
    v_locked date;
    v_now    jsonb;
    v_box    jsonb;
BEGIN
    SELECT * INTO v_r FROM gst_filing_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GST_FILING_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    SELECT * INTO v_p FROM gst_periods WHERE id = v_r.period_id FOR UPDATE;
    IF v_p.status = 'filed' THEN
        RAISE EXCEPTION 'GST_PERIOD_ALREADY_FILED|%|%', v_p.code, v_p.filed_on;
    END IF;
    IF v_p.status = 'approved' THEN
        RAISE EXCEPTION 'GST_PERIOD_ALREADY_APPROVED|%', v_p.code;
    END IF;

    SELECT locked_before INTO v_locked FROM finance_settings LIMIT 1;
    IF v_locked IS NULL OR v_locked <= v_p.period_end THEN
        RAISE EXCEPTION 'GST_PERIOD_NOT_LOCKED|%|%|%',
            v_p.code, v_p.period_end, COALESCE(v_locked::text,'(未设)');
    END IF;

    v_now := f5_return(v_p.period_start, v_p.period_end)->'boxes';
    IF v_now IS DISTINCT FROM v_r.boxes THEN
        RAISE EXCEPTION 'GST_RETURN_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    FOR v_box IN SELECT * FROM jsonb_array_elements(v_r.boxes) LOOP
        INSERT INTO gst_return_boxes (period_id, box, label_en, label_zh, value_base)
        VALUES (v_p.id, v_box->>'box', v_box->>'label_en', v_box->>'label_zh',
                (v_box->>'value')::numeric);
    END LOOP;

    UPDATE gst_periods SET status = 'approved' WHERE id = v_p.id;

    RETURN jsonb_build_object('gst_period_id', v_p.id, 'code', v_p.code, 'boxes', v_r.boxes);
END;
$function$;

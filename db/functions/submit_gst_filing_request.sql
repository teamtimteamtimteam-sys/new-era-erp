-- db/functions/submit_gst_filing_request.sql
-- APR-10(2026-09-27):财务提一张 GST 申报申请 —— 冻结那一季 F5 的每一格,等 CFO 批(Tim 的矩阵 §2,不分档;
-- grilling Q1 · Q2 · Q4)。一张原件与一张更正件(F7)走同一扇门:F7 就是另一个期间行。
--
-- 【门】module.finance.edit(申报原来的门)。
-- 【拒绝,按这个顺序】
--   GST_PERIOD_NOT_FOUND · GST_PERIOD_ALREADY_FILED|<code>|<申报日> · GST_PERIOD_ALREADY_APPROVED|<code>
--                                                                        只有 open 的期间提得了
--   GST_PERIOD_NOT_LOCKED|<code>|<期末>|<锁>                            那一季每个月都已关账(file_gst_return 当年那一句)
--   GST_FILING_OPEN|<code>|<那一张>                                     一个期间同一时刻只挂一张(唯一索引是第二道)
--   GST_FILING_NO_OTHER_DECIDER|<label>                                 审批开着、提单人这个人之外二级没人批得动
--                                                                        (assert_other_decider;线上是 admin@:它与 tim@ 是同一个人)
-- 审批开着:留痕 submitted,二级。关着:当场生效(写快照,期间 → approved),状态 approved,留痕 auto_approved(Q4)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.submit_gst_filing_request(p_period_id uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on     boolean := approvals_enabled();
    v_id     uuid := gen_random_uuid();
    v_p      gst_periods%ROWTYPE;
    v_locked date;
    v_open   text;
    v_n      integer;
    v_label  text;
    v_boxes  jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_p FROM gst_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
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

    SELECT q.label INTO v_open FROM gst_filing_requests q
     WHERE q.period_id = v_p.id AND q.status = 'submitted' LIMIT 1;
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'GST_FILING_OPEN|%|%', v_p.code, v_open;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM gst_filing_requests q WHERE q.period_id = v_p.id;
    v_label := v_p.code || ' · filing #' || v_n::text;

    PERFORM assert_other_decider('gst_filing_request', 'decide_gst_filing_request', 2::smallint,
                                 'GST_FILING_NO_OTHER_DECIDER|' || v_label);

    v_boxes := f5_return(v_p.period_start, v_p.period_end)->'boxes';

    INSERT INTO gst_filing_requests (id, status, label, period_id, boxes, note, created_by)
    VALUES (v_id, 'submitted', v_label, v_p.id, v_boxes, NULLIF(btrim(COALESCE(p_note, '')), ''), auth.uid());

    IF v_on THEN
        PERFORM record_approval_decision('gst_filing_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM gst_filing_execute_internal(v_id);
        UPDATE gst_filing_requests SET status = 'approved', executed_at = now() WHERE id = v_id;
        PERFORM record_approval_decision('gst_filing_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场写快照,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'boxes', v_boxes);
END;
$function$;

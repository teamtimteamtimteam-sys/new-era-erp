-- db/functions/cancel_leave_request.sql
-- 取消。对每条 draw 追加等额 release,【不删行】,于是"批了又撤"在账上看得见。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.cancel_leave_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req  record;
    c      record;
    v_rel  jsonb := '[]'::jsonb;
BEGIN
    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;

    IF NOT (has_permission('module.hr.edit') OR v_req.employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    IF v_req.status = 'cancelled' THEN RAISE EXCEPTION 'ALREADY_CANCELLED|%', v_req.code; END IF;
    IF v_req.status = 'rejected' THEN RAISE EXCEPTION 'REQUEST_REJECTED|%', v_req.code; END IF;

    -- 【释放不是删除】:对每一条 draw 追加一条等额的 release。
    -- 于是"批了 3 天,后来撤了"在账上是两行,而不是一行都没有 —— 余额算得对,也说得清。
    FOR c IN
        SELECT leave_grant_id,
               SUM(CASE WHEN entry_type='draw' THEN days ELSE -days END) AS net
        FROM leave_consumption WHERE leave_request_id = p_request_id
        GROUP BY leave_grant_id HAVING SUM(CASE WHEN entry_type='draw' THEN days ELSE -days END) > 0
    LOOP
        INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days, notes)
        VALUES (p_request_id, c.leave_grant_id, 'release', c.net,
                COALESCE(p_reason, 'Request cancelled'));
        v_rel := v_rel || jsonb_build_object('grant_id', c.leave_grant_id, 'days_released', c.net);
    END LOOP;

    UPDATE leave_requests SET status='cancelled', decided_at=now(), decided_by=auth.uid(),
           decision_notes=COALESCE(p_reason, decision_notes), updated_by=auth.uid()
    WHERE id = p_request_id;

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code,
                              'status','cancelled', 'released', v_rel);
END;
$function$;

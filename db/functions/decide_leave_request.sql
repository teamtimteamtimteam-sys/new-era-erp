-- db/functions/decide_leave_request.sql
-- 审批并扣账。【先用旧的】:结转行(有失效日)先吃,吃完再从当年度的派生累积里扣。
-- 反过来的话结转天数会先烂掉,对员工是净损失。
-- 派生累积没有授予行可挂,所以那笔消耗记 accrual_year、leave_grant_id 留空。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.decide_leave_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req    record;
    v_type   record;
    v_need   numeric;
    v_take   numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_accrual numeric;
    g        record;
    v_used   jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
    IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING|%', v_req.status; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = v_req.leave_type_code;

    IF NOT p_approve THEN
        UPDATE leave_requests SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid()
        WHERE id = p_request_id;
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','rejected');
    END IF;

    IF v_type.is_accrued THEN
        v_bal := leave_balance(v_req.employee_id, v_req.leave_type_code, v_req.start_date);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_req.days THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_avail), trim_scale(v_req.days);
        END IF;

        v_need := v_req.days;
        -- ══════════════════════════════════════════════════════════════════
        -- 【先用旧的】:按 expires_on 从早到晚扣。
        -- 结转来的行有失效日,当年累积没有 —— 所以结转天数天然排在前面被先吃掉,
        -- 反过来的话它们会先烂掉,对员工是净损失。
        -- ══════════════════════════════════════════════════════════════════
        FOR g IN
            SELECT gr.id, gr.days, gr.expires_on, gr.leave_year, gr.grant_type,
                   gr.days
                   - COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                               FROM leave_consumption c WHERE c.leave_grant_id = gr.id), 0)
                   - COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                               WHERE cf.source_grant_id = gr.id AND cf.grant_type = 'carry_forward'
                                 AND cf.deleted_at IS NULL), 0) AS remaining
            FROM leave_grants gr
            WHERE gr.employee_id = v_req.employee_id AND gr.leave_type_code = v_req.leave_type_code
              AND gr.deleted_at IS NULL AND gr.granted_on <= v_req.start_date
              AND (gr.expires_on IS NULL OR gr.expires_on >= v_req.start_date)
            ORDER BY gr.expires_on NULLS LAST, gr.granted_on
        LOOP
            EXIT WHEN v_need <= 0;
            IF g.remaining <= 0 THEN CONTINUE; END IF;
            v_take := LEAST(g.remaining, v_need);
            INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days)
            VALUES (p_request_id, g.id, 'draw', v_take);
            v_need := v_need - v_take;
            v_used := v_used || jsonb_build_object('source', 'grant', 'grant_id', g.id,
                                                   'leave_year', g.leave_year,
                                                   'grant_type', g.grant_type,
                                                   'expires_on', g.expires_on, 'days', v_take);
        END LOOP;

        -- 结转吃完了还不够 → 从当年度的派生累积里扣(记 accrual_year,不挂授予行)
        IF v_need > 0 AND v_type.is_accrued THEN
            v_accrual := available_annual_accrual(v_req.employee_id, v_req.start_date);
            v_take := LEAST(v_accrual, v_need);
            IF v_take > 0 THEN
                INSERT INTO leave_consumption (leave_request_id, leave_grant_id, entry_type, days, accrual_year)
                VALUES (p_request_id, NULL, 'draw', v_take,
                        EXTRACT(YEAR FROM v_req.start_date)::integer);
                v_need := v_need - v_take;
                v_used := v_used || jsonb_build_object('source', 'accrual',
                                                       'leave_year', EXTRACT(YEAR FROM v_req.start_date)::integer,
                                                       'grant_type', 'monthly_accrual',
                                                       'expires_on', NULL, 'days', v_take);
            END IF;
        END IF;

        IF v_need > 0 THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_req.days - v_need), trim_scale(v_req.days);
        END IF;
    END IF;

    UPDATE leave_requests SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid()
    WHERE id = p_request_id;

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$
;
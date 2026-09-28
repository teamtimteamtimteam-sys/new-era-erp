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
    PERFORM require_permission('action.decide_hr_requests');

    SELECT * INTO v_req FROM leave_requests WHERE id = p_request_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'REQUEST_NOT_FOUND'; END IF;
    IF v_req.status <> 'pending' THEN RAISE EXCEPTION 'REQUEST_NOT_PENDING|%', v_req.status; END IF;

    -- ★ APR-2:四眼。此前这条链【一条自批判据都没有】——
    -- 一个持 module.hr.edit 的人批得了自己的假(APR-0 §1.5 实测)。
    -- 两条腿,判据只有一份定义(见 forbid_self_approval 的抬头):
    --   ① 提这张单的人;② 这张单【说的是谁】。
    -- ★ 第二条在这里是承重的:HR 可以【代人】提单,那时 created_by 是 HR、
    --   employee_id 是员工本人 —— 只判第一条的话,那位员工(若他持
    --   module.hr.edit)照样批得了自己的假。
    PERFORM forbid_self_approval(v_req.created_by, v_req.employee_id, 'leave_request');

    -- ★ LEAVE-BAL-1(Q13):锁住这名员工的行 —— 与 submit_leave_request 同一把锁,
    --   同一个人的两张单不会同时穿过余额检查。先锁单、再锁人,各条路径同一个次序。
    PERFORM 1 FROM employees WHERE id = v_req.employee_id FOR UPDATE;

    SELECT * INTO v_type FROM leave_types WHERE code = v_req.leave_type_code;

    IF NOT p_approve THEN
        UPDATE leave_requests SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid()
        WHERE id = p_request_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('leave_request', p_request_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','rejected');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- ★ LEAVE-BAL-1:审批时再查一次 —— 【每一个有额度的假别】,不只是年假。
    --   比的是 'available' = 额度 − 已批,【不扣别人还在等的单】(Tim Q10 Option A):
    --   待批不是承诺,而只按已批判,批准就不可能让已批超过额度;
    --   扣待批的话,两张各自够、合起来不够的旧单会互相卡死,谁都批不了。
    --   于是先批的那张过,后一张被拒并说出"可用 0 天"。
    -- ══════════════════════════════════════════════════════════════════════
    v_bal := leave_balance(v_req.employee_id, v_req.leave_type_code, v_req.start_date);
    IF (v_bal->>'balance_checked')::boolean THEN
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_req.days THEN
            IF v_type.is_accrued THEN
                RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                    trim_scale(GREATEST(v_avail, 0)), trim_scale(v_req.days);
            END IF;
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%',
                trim_scale(GREATEST(v_avail, 0)), trim_scale(v_req.days);
        END IF;
    END IF;

    IF v_type.is_accrued THEN
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

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('leave_request', p_request_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$;
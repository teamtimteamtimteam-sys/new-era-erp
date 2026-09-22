-- db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql
-- APR-2 —— 两件事,而第二件是在闸轮里【量出来的】,不在委托书上。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ① 自批统一拒(Tim 的 APR-0 Q6),而"自己"是【两个人】(Tim 的 Q8,2026-09-22)
-- ════════════════════════════════════════════════════════════════════════════
--   提单的人(raiser)+ 单据说的是谁(subject)。判据只有一份定义:
--   forbid_self_approval(uuid, uuid)。补到请假 / 医疗申报 / 工单放行三条链上,
--   并【补上 approve_review 缺的那条腿】—— 它此前只拒 submitted_by,于是
--   "别人提交、被评的那位自己批准"一直是通的,而那条路会写调薪。
--   ★ approve_purchase_order / reject_purchase_order 【不动】(Tim 的委托书:
--     "leave them"),它们仍然抛裸的 SELF_APPROVAL_FORBIDDEN;采购单没有
--     "这张单说的是谁"这条腿,所以那里没有缺口,只有码的形状不同 ——
--     两支映射器同时认裸码与带后缀的码。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ② ★★★ 一把【当时就锁在线上】的锁,以及不让它再发生的那道闸 ★★★
-- ════════════════════════════════════════════════════════════════════════════
--   `require_approver_for(N)` 问"你在不在第 N 级那个角色里";每一支决定函数
--   【另外】问"你持不持有本模块那个权限码"。**没有任何东西断言两者有交集。**
--   实测 2026-09-22(postgres 读基表 + require_approver_for 自己的答案):
--       一级 finance = chooer;module.processing.edit = admin·phua·sandra·vince
--       ★ 交集 = 空  →  审批一开,**线上谁都放行不了一张工单**
--   而 WO-1b 写下那一行时三道闸全绿。今天 work_orders.draft = 0,所以没有单据
--   卡住;下一张就再也放行不了。
--
--   ★ Tim 的 Q1 裁定(2026-09-22)——【修订】了他自己早前那条"没有金额的单据
--     一律走一级":**按角色分级只管带钱的单据。** 不带钱的单据,谁能批仍由它
--     自己的模块权限说了算。于是 release_work_order 摘掉 require_approver_for(1)。
--   ★ 并且加一道闸,让这件事下次不靠人看出来:
--       approval_chain_gates()          —— 哪些链接上了引擎,各自的门是什么
--       approval_gate_intersections()   —— 逐条求交,给出"有几个人批得动"
--       guard_approvals_switch          —— 开的时候 0 就按名拒
--       approvals_readiness             —— 屏幕读同一份判据
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★ 本刀【不碰】审批开关,一刻也没有。approvals_enabled 在本刀之前之后都是 true。
--   迁移末尾的自证第 ① 条就是这件事。
-- ★ 本刀【不留下任何 pending 单据】,也不写一行 approval_log ——
--   自证第 ②③ 条钉住"数一个都没变"。
-- ════════════════════════════════════════════════════════════════════════════
--
-- 一个事务,全有或全无。

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- ⓪ 先把【本刀之前】的读数钉在事务里 —— 末尾的自证要拿它比
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是临时表,不是硬编码的数字】硬编码会在 Tim 今晚多走一张单据之后
-- 让这支迁移为一个无害的理由拒绝掉;而"跑之前是多少、跑之后还是多少"这句话
-- 不需要知道那个数是几。★ 本刀一条 DML 都没有,所以这几格【必然】相等 ——
-- 它们防的是【将来有人往这个文件里加一句 DML 而没有人发现】。
CREATE TEMP TABLE apr2_before ON COMMIT DROP AS
SELECT (SELECT approvals_enabled FROM finance_settings LIMIT 1)                        AS enabled,
       (SELECT count(*) FROM approval_log)                                             AS approval_log_rows,
       (SELECT count(*) FROM leave_requests    WHERE status='pending'   AND deleted_at IS NULL) AS leave_pending,
       (SELECT count(*) FROM medical_claims    WHERE status='submitted' AND deleted_at IS NULL) AS claims_pending,
       (SELECT count(*) FROM performance_reviews WHERE status='submitted')             AS reviews_pending,
       (SELECT count(*) FROM purchase_orders   WHERE approval_status='pending' AND deleted_at IS NULL) AS po_pending,
       (SELECT count(*) FROM work_orders       WHERE status='draft')                   AS wo_draft;

DO $prologue$
DECLARE b record;
BEGIN
    SELECT * INTO b FROM apr2_before;
    RAISE NOTICE 'APR2_BEFORE enabled=% approval_log=% leave_pending=% claims=% reviews=% po_pending=% wo_draft=%',
        b.enabled, b.approval_log_rows, b.leave_pending, b.claims_pending,
        b.reviews_pending, b.po_pending, b.wo_draft;
    -- 开工闸:审批必须【已经是开的】。本刀是在一个开着的系统上动手,
    -- 而下面每一条推理都建立在这一点上 —— 不成立就当场停,不要 COMMIT。
    IF b.enabled IS NOT TRUE THEN
        RAISE EXCEPTION 'APR2_PRECONDITION|approvals_enabled is % — APR-2 假设审批是开着的', b.enabled;
    END IF;
END
$prologue$;



-- ════════════════════════════════════════════════════════════════════════
-- ① 新:四眼原则的唯一一份定义
-- 镜像:db/functions/forbid_self_approval.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.forbid_self_approval(p_raiser_user uuid, p_subject_employee uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ① 提单的人。与 approve_purchase_order 的那一句同源(它保留裸码,见 APR-2 §3)。
    IF p_raiser_user IS NOT NULL AND p_raiser_user = auth.uid() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN|raiser';
    END IF;

    -- ② 单据说的是谁。★ 这一条是 APR-2 新加的,而它此前全库都没有。
    IF p_subject_employee IS NOT NULL
       AND p_subject_employee = current_user_employee() THEN
        RAISE EXCEPTION 'SELF_APPROVAL_FORBIDDEN|subject';
    END IF;
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- ② 新:接上引擎的链,与各自的门
-- 镜像:db/functions/approval_chain_gates.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.approval_chain_gates()
 RETURNS TABLE(subject_type text, action_function text, level smallint, gate_permissions text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT v.subject_type, v.action_function, v.level, v.gate_permissions
      FROM (VALUES
        ('purchase_order'::text, 'approve_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view', 'data.view_prices']::text[]),
        ('purchase_order'::text, 'approve_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view', 'data.view_prices']::text[]),
        -- 驳回【不】要 data.view_prices —— 它仍然按金额分级(所以两级都在),
        -- 而它不显示那个金额。门窄一格,所以它自己一行。
        ('purchase_order'::text, 'reject_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view']::text[]),
        ('purchase_order'::text, 'reject_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2:接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。';


-- ════════════════════════════════════════════════════════════════════════
-- ③ 新:逐条求交 —— 这条链有几个人批得动
-- 镜像:db/functions/approval_gate_intersections.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.approval_gate_intersections(p_level1_role text DEFAULT NULL::text, p_level2_role text DEFAULT NULL::text)
 RETURNS TABLE(subject_type text, action_function text, level smallint, role_code text, gate_permissions text[], approvers integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH s AS (
        SELECT COALESCE(p_level1_role, fs.approval_level1_role_code) AS l1,
               COALESCE(p_level2_role, fs.approval_level2_role_code) AS l2
          FROM finance_settings fs
         LIMIT 1
    ),
    -- 「谁【真的】持有权限 P」—— 四条判据借自 real_role_grants,不另写一份。
    real_perm AS (
        SELECT DISTINCT rp.permission_code, rg.user_id
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
          CROSS JOIN LATERAL real_role_grants(r.code) rg
    ),
    g AS (
        SELECT cg.subject_type, cg.action_function, cg.level, cg.gate_permissions,
               CASE cg.level WHEN 1 THEN s.l1 ELSE s.l2 END AS role_code
          FROM approval_chain_gates() cg
         CROSS JOIN s
    )
    SELECT g.subject_type, g.action_function, g.level, g.role_code, g.gate_permissions,
           (SELECT count(*)::integer
              FROM real_role_holders(g.role_code) h
             -- 门是【合取】:少一个码就不算 —— 所以是"不存在一个他没有的码"
             WHERE NOT EXISTS (
                     SELECT 1 FROM unnest(g.gate_permissions) AS need(code)
                      WHERE NOT EXISTS (
                            SELECT 1 FROM real_perm pp
                             WHERE pp.permission_code = need.code
                               AND pp.user_id = h.user_id)))
      FROM g
     ORDER BY g.subject_type, g.action_function, g.level
$function$;

COMMENT ON FUNCTION public.approval_gate_intersections(text, text) IS
'APR-2:逐条给出「这条链的模块门 ∩ 这一级的角色持有人」有几个人 —— 0 就是一条谁都批不动的链。★ 两个参数存在的理由:guard_approvals_switch 是 BEFORE UPDATE,从 finance_settings 读到的是 OLD 那一行,而策略四列是一起写的;不传 NEW 的角色码,那道闸判的就是上一版策略并且全绿。不传参时读已落库的值(approvals_readiness 的用法)。「真的持有人」与「真的持有权限」两侧都从 real_role_grants 长出来,所以全库仍然只有一份"真人"的判据。EXECUTE 已从 authenticated 收回 —— 它读 auth.users 与整张权限矩阵。';


-- ════════════════════════════════════════════════════════════════════════
-- ④ 请假:补四眼(两条腿)
-- 镜像:db/functions/decide_leave_request.sql
-- ════════════════════════════════════════════════════════════════════════

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

    -- ★ APR-2:四眼。此前这条链【一条自批判据都没有】——
    -- 一个持 module.hr.edit 的人批得了自己的假(APR-0 §1.5 实测)。
    -- 两条腿,判据只有一份定义(见 forbid_self_approval 的抬头):
    --   ① 提这张单的人;② 这张单【说的是谁】。
    -- ★ 第二条在这里是承重的:HR 可以【代人】提单,那时 created_by 是 HR、
    --   employee_id 是员工本人 —— 只判第一条的话,那位员工(若他持
    --   module.hr.edit)照样批得了自己的假。
    PERFORM forbid_self_approval(v_req.created_by, v_req.employee_id);

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

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('leave_request', p_request_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('request_id', p_request_id, 'code', v_req.code, 'status','approved',
                              'days', v_req.days, 'consumed_from', v_used);
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- ⑤ 医疗申报:补四眼(两条腿)
-- 镜像:db/functions/decide_medical_claim.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.decide_medical_claim(p_claim_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_claim record; v_bal jsonb; v_remaining numeric;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;
    IF v_claim.status <> 'submitted' THEN RAISE EXCEPTION 'CLAIM_NOT_SUBMITTED|%', v_claim.status; END IF;

    -- ★ APR-2:四眼,与 decide_leave_request 逐字同一支判据、同样两条腿。
    -- 这条链此前也一条都没有 —— 而它【是真的在批钱】(amount_sgd)。
    PERFORM forbid_self_approval(v_claim.created_by, v_claim.employee_id);

    IF NOT p_approve THEN
        UPDATE medical_claims SET status='rejected', decided_at=now(), decided_by=auth.uid(),
               decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

        -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
        -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
        PERFORM record_approval_decision('medical_claim', p_claim_id, 'rejected', NULL, p_notes);
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','rejected');
    END IF;

    v_bal := medical_claim_balance(v_claim.employee_id, v_claim.claim_year);
    v_remaining := (v_bal->>'remaining_sgd')::numeric;
    IF v_claim.amount_sgd > v_remaining THEN
        RAISE EXCEPTION 'CLAIM_EXCEEDS_LIMIT|%|%', v_remaining, v_claim.amount_sgd;
    END IF;

    UPDATE medical_claims SET status='approved', decided_at=now(), decided_by=auth.uid(),
           decision_notes=p_notes, updated_by=auth.uid() WHERE id = p_claim_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('medical_claim', p_claim_id, 'approved', NULL, p_notes);

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_claim.code, 'status','approved',
                              'amount_sgd', v_claim.amount_sgd,
                              'remaining_after', v_remaining - v_claim.amount_sgd,
                              -- 与补偿一样,把"没有入账"写进返回值,免得调用方以为记过账了
                              'expense_posted', false,
                              'note', 'No expense is posted. Reimbursement route (payroll vs separate payment) is an operational decision; link it via medical_claims.expense_id once chosen.');
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- ⑥ 绩效:补【subject】那条腿 —— 此前可以批自己的加薪
-- 镜像:db/functions/approve_review.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.approve_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r        performance_reviews%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_period   text;
    v_old_sal  numeric;
    v_conf     date;
    v_confirmed boolean := false;
    v_salaried  boolean := false;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    -- 【四眼原则】与"评估人不能是本人"是两条不同的规则:一条防自我评价
    -- (表上的 CHECK:reviewer_employee_id IS DISTINCT FROM employee_id),
    -- 这一条防自我批准。
    --
    -- ★★ APR-2 把它换成了全库唯一的那支判据,而这【不是】重构 ——
    -- 它补上了本函数缺的那条腿。此前只拒 submitted_by,于是这条路一直是通的:
    --   【别人提交、被评的那位自己批准】。
    -- 而本函数会写 employees.monthly_salary 与一行 employment_history 调薪记录,
    -- 也就是说 **一个人批得了自己的加薪**。线上三个持 module.hr.edit 的人
    -- 全部是在册员工(实测 2026-09-22),所以它不是理论上的。
    PERFORM forbid_self_approval(v_r.submitted_by, v_r.employee_id);

    SELECT * INTO v_emp FROM employees WHERE id = v_r.employee_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    UPDATE performance_reviews
    SET status = 'approved', approved_at = now(), approved_by = auth.uid()
    WHERE id = p_review_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'approved', NULL, NULL);

    -- ── 试用期转正 ────────────────────────────────────────────────────────
    IF v_r.review_type = 'probation' AND v_r.probation_outcome = 'confirm' THEN
        IF v_emp.employment_status = 'separated' THEN
            RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
        END IF;
        v_conf := COALESCE(v_emp.probation_end_date, CURRENT_DATE);

        UPDATE employees
        SET employment_status = 'active',      -- 【没有 'confirmed' 这个状态,见文件头 (2)】
            confirmation_date = v_conf
        WHERE id = v_emp.id;

        -- 【恰好一行】履历。
        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, notes)
        VALUES (v_emp.id, v_conf, 'confirmed',
                -- KPI-1:履历存的是【当时那个职位的名称文本】,不是指针
                (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id),
                v_emp.department_id,
                v_emp.employment_type, 'active',
                format('Probation confirmed by performance review %s', p_review_id));

        -- 【假期台账一个字都不写】年假的解锁是读时按 employment_status 派生的
        -- (submit_leave_request 的 PROBATION_NO_ANNUAL_LEAVE)。在这里补一笔授予
        -- 就是 HR-2a 结转重复计数的翻版。见文件头 (1)。
        v_confirmed := true;
    END IF;

    -- ── 不予转正:【什么都不改】 ──────────────────────────────────────────
    -- 决定记在评估单据上,提醒由 hr_alerts 的 probation_not_confirmed 一支发出。
    -- 【绝不把在职状态改成 separated,也绝不触发任何离职逻辑】——
    -- 离职是手工流程:人一旦 separated 就掉出工资表,而最后一个月的工资还没录。
    -- 先掉出去,那笔钱就再也发不出来了。

    -- ── 调薪 ──────────────────────────────────────────────────────────────
    IF v_r.new_monthly_salary IS NOT NULL THEN
        -- payroll_periods 没有起止两列:周期就是 period_month 那个整月(见文件头 (4))
        SELECT p.code INTO v_period
        FROM payroll_periods p
        WHERE p.deleted_at IS NULL AND p.status = 'posted'
          AND v_r.salary_effective_date >= p.period_month
          AND v_r.salary_effective_date < (p.period_month + interval '1 month')::date
        ORDER BY p.period_month
        LIMIT 1;

        IF v_period IS NOT NULL THEN
            -- 【连同上面的转正一起回滚】总账已经认了那个月的工资,
            -- 追改一个已过账周期里的薪酬会让账实不符。
            RAISE EXCEPTION 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|%', v_period;
        END IF;

        v_old_sal := v_emp.monthly_salary;

        UPDATE employees SET monthly_salary = v_r.new_monthly_salary WHERE id = v_emp.id;

        INSERT INTO employment_history
            (employee_id, effective_date, change_type, job_title, department_id,
             employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes)
        SELECT e.id, v_r.salary_effective_date, 'salary_change',
               (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
               e.employment_type, e.employment_status, v_old_sal, v_r.new_monthly_salary,
               format('Salary change approved with performance review %s', p_review_id)
        FROM employees e WHERE e.id = v_emp.id;

        v_salaried := true;
    END IF;

    RETURN jsonb_build_object(
        'review_id', p_review_id, 'status', 'approved',
        'employee_code', v_emp.code,
        'review_type', v_r.review_type,
        'probation_outcome', v_r.probation_outcome,
        'confirmed', v_confirmed,
        'confirmation_date', v_conf,
        'salary_changed', v_salaried,
        'old_monthly_salary', v_old_sal,
        'new_monthly_salary', v_r.new_monthly_salary,
        'salary_effective_date', v_r.salary_effective_date);
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════
-- ⑦ 工单:摘掉按级别授权那一句,层级改 NULL,补四眼
-- 镜像:db/functions/release_work_order.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.release_work_order(p_work_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_wo      work_orders%ROWTYPE;
    v_appr_on boolean := approvals_enabled();
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'draft' THEN
        RAISE EXCEPTION 'WO_NOT_DRAFT|%|%', v_wo.code, v_wo.status;
    END IF;

    -- ★ APR-2:四眼。判据只有一份定义(forbid_self_approval)。
    -- 【只有一条腿】—— 工单没有"这张单说的是谁"(它说的是一批料,不是一个人),
    -- 所以第二个参数是 NULL,而 NULL 一律不匹配。不硬塞一个主语进去。
    PERFORM forbid_self_approval(v_wo.created_by, NULL::uuid);

    -- 【放行是那个要有人负责的动作】(WO-1b)Doc 2 点名要"who approved the work
    -- order"。可审批的是放行 —— 不是新建(草稿谁都可以写),也不是收工(事后记录)。
    --
    -- ★ APR-2:谁能放行,由 module.processing.edit 说了算 —— 本函数【不】按角色
    --   分级。工单没有金额,而按角色分级只管带钱的单据(Tim 的 Q1 裁定)。
    --   ☞ 这里原先有一句按级别授权的检查,而它在线上是一把【谁都过不去】的锁。
    --     整段来龙去脉写在本文件的抬头 —— **刻意写在函数体外面**,
    --     见抬头最后一段说明为什么。

    UPDATE work_orders
       SET status = 'released', updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, changed_by)
    VALUES (p_work_order_id, 'released', v_user);

    -- 【关着的时候也要留痕,而且要说实话】—— 与 create_purchase_order 逐字同一句:
    -- 记录真实发生的事,不要把"系统直接盖章"伪装成一次人的决定。
    IF v_appr_on THEN
        -- ★ APR-2:层级写 NULL,不写 1。此前写的是 1,而那是一句【假记录】——
        -- 今天这条路上【没有跑过任何一级授权检查】(上面那一段说明了为什么),
        -- 于是"level = 1"会让留痕声称发生过一件没有发生的事。
        -- 与 HR 三条链同形:它们也一律 NULL(approval_log 的 level 列注释)。
        PERFORM record_approval_decision('work_order', p_work_order_id, 'approved', NULL::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('work_order', p_work_order_id, 'auto_approved', NULL,
            '审批流未启用(finance_settings.approvals_enabled = false)—— 系统直接盖章,没有人做过这个决定');
    END IF;

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'released', 'approvals_enabled', v_appr_on);
END;
$function$

;


-- ════════════════════════════════════════════════════════════════════════
-- ⑧ 就绪面板:屏幕读同一份判据
-- 镜像:db/functions/approvals_readiness.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.approvals_readiness()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s          record;
    v_blocking   text[] := '{}';
    v_l1_total   integer := 0;  v_l1_real integer := 0;
    v_l2_total   integer := 0;  v_l2_real integer := 0;
    v_l1_norais  integer := 0;
    v_l1_sees    boolean := false;
    v_l2_sees    boolean := false;
    v_pending    integer := 0;
    v_chains     jsonb   := '[]'::jsonb;
    v_deadchains integer := 0;
BEGIN
    -- ★ APR-1(N6):此前这里要求 module.finance.view,而 /settings/approvals
    --   那一页的闸是 action.manage_permissions —— **两个码守同一块屏幕**。
    --   今天 admin 与 cco 两个码都持有,所以看不出问题;哪一天有人持前者而不持
    --   后者,那一页会渲染成 readError,而那读起来像"读不到",不像"你没权限"。
    --   这支函数的抬头自己就写着"屏幕与闸读同一份判据"。
    PERFORM require_permission('action.manage_permissions');

    SELECT approvals_enabled, approval_level1_role_code, approval_threshold_base,
           approval_level2_role_code
      INTO v_s FROM finance_settings LIMIT 1;

    -- ── 一级 ──
    IF v_s.approval_level1_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level1_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l1_real FROM real_role_holders(v_s.approval_level1_role_code);
        SELECT count(*) INTO v_l1_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level1_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l1_sees := role_can_see_amounts(v_s.approval_level1_role_code);

        IF v_l1_real = 0 AND v_l1_total > 0 THEN
            v_blocking := v_blocking || 'approval_level1_holder_cannot_sign_in'::text;
        ELSIF v_l1_real = 0 THEN
            v_blocking := v_blocking || 'approval_level1_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l1_sees THEN
            v_blocking := v_blocking || 'approval_level1_role_cannot_see_amounts'::text;
        END IF;

        -- 【报告,不拦】这个角色的持有人里,有几个是【提不了采购单】的(SOD-1 fu2)。
        SELECT count(*) INTO v_l1_norais
          FROM real_role_holders(v_s.approval_level1_role_code) h
         WHERE NOT EXISTS (
            SELECT 1 FROM user_roles ur2
              JOIN roles r2 ON r2.id = ur2.role_id
              JOIN role_permissions rp ON rp.role_id = r2.id
             WHERE ur2.user_id = h.user_id AND r2.is_active AND ur2.revoked_at IS NULL
               AND rp.permission_code = 'module.purchasing.edit');
    END IF;

    IF v_s.approval_threshold_base IS NULL THEN
        v_blocking := v_blocking || 'approval_threshold_base'::text;
    END IF;

    -- ── 二级:与一级【同等对待】,这正是本刀要的 ──
    IF v_s.approval_level2_role_code IS NULL THEN
        v_blocking := v_blocking || 'approval_level2_role_code'::text;
    ELSE
        SELECT count(*) INTO v_l2_real FROM real_role_holders(v_s.approval_level2_role_code);
        SELECT count(*) INTO v_l2_total
          FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE r.code = v_s.approval_level2_role_code AND r.is_active AND ur.revoked_at IS NULL;
        v_l2_sees := role_can_see_amounts(v_s.approval_level2_role_code);

        IF v_l2_real = 0 AND v_l2_total > 0 THEN
            v_blocking := v_blocking || 'approval_level2_holder_cannot_sign_in'::text;
        ELSIF v_l2_real = 0 THEN
            v_blocking := v_blocking || 'approval_level2_role_has_no_real_holder'::text;
        END IF;
        IF NOT v_l2_sees THEN
            v_blocking := v_blocking || 'approval_level2_role_cannot_see_amounts'::text;
        END IF;
    END IF;

    SELECT count(*) INTO v_pending
      FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-2:屏幕上也要看得见「这条链真的有人批得动吗」 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 本函数的抬头写着"屏幕与闸读同一份判据"。APR-2 给 guard_approvals_switch
    -- 加了一道新闸(链的模块门 ∩ 那一级的角色持有人 = 空 → 按名拒),
    -- ★ 所以那道闸【必须】同时出现在这里 —— 否则就又是一块说"可以开"、
    --   而闸会拒绝的屏幕,也就是本函数存在的全部理由的反面。
    --
    -- ⚠ 这里【不】传参,读的是已经落库的那两个角色码 —— 面板说的是
    --   "以现在这条策略,能不能开"。闸那一侧传的是 NEW(它判的是正要写下去的
    --   那条策略),两者的差别写在 approval_gate_intersections 的抬头。
    -- ★★ 只在【两级角色都已经设好】时才问这个问题 —— 而这不是为了少说一句话,
    --    是为了与闸【同序】:guard_approvals_switch 先抛 APPROVALS_POLICY_INCOMPLETE,
    --    根本走不到这道新闸。策略整个没设时,role_code 是 NULL,求交必然全 0,
    --    于是 blocking 会多出第四条 —— 一句【真的、但重复的】话,
    --    它说的还是上面那三条已经说过的事,而它会把"策略没设"与
    --    "策略设好了却没有人批得动"这两种完全不同的状态搅在一起。
    IF v_s.approval_level1_role_code IS NOT NULL
       AND v_s.approval_level2_role_code IS NOT NULL THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_type',     i.subject_type,
                   'action_function',  i.action_function,
                   'level',            i.level,
                   'role_code',        i.role_code,
                   'gate_permissions', to_jsonb(i.gate_permissions),
                   'approvers',        i.approvers)
                   ORDER BY i.subject_type, i.action_function, i.level), '[]'::jsonb),
               count(*) FILTER (WHERE i.approvers = 0)
          INTO v_chains, v_deadchains
          FROM approval_gate_intersections() i;

        IF v_deadchains > 0 THEN
            v_blocking := v_blocking || 'approval_chain_has_no_approver'::text;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_holders_total',    v_l1_total,
        'level1_real_holders',     v_l1_real,
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
        'level2_can_see_amounts',  v_l2_sees,
        'pending_purchase_orders', v_pending,
        -- ★ APR-2:逐条给出"这条链有几个人批得动",而不是一个布尔 ——
        --   与两级持有人给两个数、不给一个布尔是同一条理由:
        --   要分开的是"哪一条链死了、死在哪一级、缺的是哪个码"。
        'chain_gates',             v_chains,
        'chains_without_approver', v_deadchains,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        'can_disable',             (v_s.approvals_enabled AND v_pending = 0),
        -- 跟着数字走的那句话,不只躺在文档里(与 PARTY-1 的处置同形)
        'no_deputy_by_decision',   true);
END;
$function$;

COMMENT ON FUNCTION public.approvals_readiness() IS
'SOD-1,CHAIN-BUILD-1 改写(2026-08-30):审批开关能不能开,以及开不了缺哪几样 —— 屏幕与闸读同一份判据。★两级【同等对待】★:各返回 holders_total(未撤销的授权数)与 real_holders(真的登录得了的),**两个数而不是一个数加一个布尔**,因为要分开的是三种状态:没人持有 / 有人持有但登录不了 / 有能干活的人 —— 中间那一种若报成"没有持有人",操作的人会去再授一次权,而那个角色已经授过了。持有人判据只有一处定义(real_role_holders)。另报每一级的 can_see_amounts(R4)。**没有代理人、没有升级**:某一级没人就停在那一级,这是裁定,不是遗漏(no_deputy_by_decision 跟着返回值走)。';


-- ════════════════════════════════════════════════════════════════════════
-- ⑨ 开关的闸:一条没有人批得动的链 → 按名拒
-- 镜像:db/functions/guard_approvals_switch.sql
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.guard_approvals_switch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[] := '{}';
    v_pending integer;
    v_codes   text;
    v_lvl     integer;
    v_role    text;
    v_total   integer;
    v_real    integer;
    v_gap     record;
BEGIN
    -- ── 开:策略必须齐,两级都必须【有人批】而且【看得见金额】 ──
    IF NEW.approvals_enabled AND NOT OLD.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level1_role_code'::text;
        END IF;
        IF NEW.approval_threshold_base IS NULL THEN
            v_missing := v_missing || 'approval_threshold_base'::text;
        END IF;
        IF NEW.approval_level2_role_code IS NULL THEN
            v_missing := v_missing || 'approval_level2_role_code'::text;
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_INCOMPLETE|%', array_to_string(v_missing, ', ');
        END IF;

        -- 两级走【同一段】判断 —— 两级不同形正是上一版留下的问题。
        FOR v_lvl IN 1..2 LOOP
            v_role := CASE v_lvl WHEN 1 THEN NEW.approval_level1_role_code
                                 ELSE NEW.approval_level2_role_code END;

            SELECT count(*) INTO v_real FROM real_role_holders(v_role);

            IF v_real = 0 THEN
                -- 【分辨两种零】总数是从 user_roles 上数的(未撤销的授权),
                -- 与 real 的差,正好就是"有人持有,但他登录不了"。
                SELECT count(*) INTO v_total
                  FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                 WHERE r.code = v_role AND r.is_active AND ur.revoked_at IS NULL;

                IF v_total > 0 THEN
                    -- ★ 3c 的中间态:角色【有人】,但那个人【登录不了】。
                    --   报成"没有持有人"会把人送去再授一次权,而那不会改变任何事。
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_HOLDER_CANNOT_SIGN_IN|%|%', v_lvl, v_role, v_total;
                ELSE
                    RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_UNHELD|%', v_lvl, v_role;
                END IF;
            END IF;

            -- R4/4b:看不见金额的角色批不了它该批的东西 —— 同一时刻、同一理由。
            IF NOT role_can_see_amounts(v_role) THEN
                RAISE EXCEPTION 'APPROVALS_LEVEL%_ROLE_CANNOT_SEE_AMOUNTS|%', v_lvl, v_role;
            END IF;
        END LOOP;

        -- ════════════════════════════════════════════════════════════════════
        -- ★★★ APR-2:每一条接上引擎的链,都必须【真的有人批得动】 ★★★
        -- ════════════════════════════════════════════════════════════════════
        -- 上面那一段问的是"这一级的角色有没有真人、看不看得见金额" ——
        -- 两个都是【关于角色的】问题。而它们全部为真时,这条链仍然可以是死的:
        -- 一个持有那个角色的人,可能根本进不了那张单据所在的模块。
        -- ★ 这不是假设:WO-1b 就是这么在线上造出一把锁的,而当时三道闸全绿
        --   (逐项实测写在 db/functions/approval_chain_gates.sql 的抬头)。
        --
        -- ★★ 传的是 NEW 的两个角色码,【不能】让它自己去读表:本触发器是
        --    BEFORE UPDATE,而策略四列是一起写的 —— 读表读到的是 OLD,
        --    于是这道闸会去判上一版策略,并且全绿。
        --
        -- 【为什么是拒绝,不是忠告】与本函数抬头那句话同一条:把"开着但没人批"
        -- 做成一个【到不了】的状态,而不是【到了才发现】。后者的代价是一批
        -- 永远停在 pending 的单据,而开关此时已经关不掉了(下面那道闸)。
        FOR v_gap IN
            SELECT i.action_function, i.level, i.role_code,
                   array_to_string(i.gate_permissions, '+') AS perms
              FROM approval_gate_intersections(NEW.approval_level1_role_code,
                                               NEW.approval_level2_role_code) i
             WHERE i.approvers = 0
             ORDER BY i.action_function, i.level
             LIMIT 1
        LOOP
            RAISE EXCEPTION 'APPROVALS_CHAIN_HAS_NO_APPROVER|%|%|%|%',
                v_gap.action_function, v_gap.level, v_gap.role_code, v_gap.perms;
        END LOOP;
    END IF;

    -- ── 关:在途的 pending 单会被永远搁死,所以先点名(原样保留)──
    IF OLD.approvals_enabled AND NOT NEW.approvals_enabled THEN
        SELECT count(*), string_agg(code, ', ' ORDER BY code)
          INTO v_pending, v_codes
          FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL;
        IF COALESCE(v_pending, 0) > 0 THEN
            RAISE EXCEPTION 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%|%', v_pending, v_codes;
        END IF;
    END IF;

    -- ── 开着的时候不许把策略值抽走 ──
    IF NEW.approvals_enabled THEN
        IF NEW.approval_level1_role_code IS NULL AND OLD.approval_level1_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level1_role_code';
        END IF;
        IF NEW.approval_threshold_base IS NULL AND OLD.approval_threshold_base IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_threshold_base';
        END IF;
        IF NEW.approval_level2_role_code IS NULL AND OLD.approval_level2_role_code IS NOT NULL THEN
            RAISE EXCEPTION 'APPROVALS_POLICY_LOCKED_WHILE_ON|approval_level2_role_code';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;


-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ 自证 —— 每一条都是【这支迁移自己】跑出来的,不是事后另一个会话读的 ★★★
-- ════════════════════════════════════════════════════════════════════════════
DO $proof$
DECLARE
    b            record;
    v_enabled    boolean;
    v_log        bigint;
    v_leave      bigint;
    v_claims     bigint;
    v_reviews    bigint;
    v_po         bigint;
    v_wo         bigint;
    v_registry   text[];
    v_catalog    text[];
    v_rows       integer;
    v_dead       integer;
    v_secdef     boolean;
    v_src        text;
BEGIN
    SELECT * INTO b FROM apr2_before;

    -- ① 审批开关一刻也没有被碰过 ------------------------------------------
    SELECT approvals_enabled INTO v_enabled FROM finance_settings LIMIT 1;
    IF v_enabled IS DISTINCT FROM b.enabled THEN
        RAISE EXCEPTION 'APR2_PROOF_1|approvals_enabled 变了:% -> %', b.enabled, v_enabled;
    END IF;

    -- ② 一行留痕都没有写 ---------------------------------------------------
    SELECT count(*) INTO v_log FROM approval_log;
    IF v_log <> b.approval_log_rows THEN
        RAISE EXCEPTION 'APR2_PROOF_2|approval_log 行数变了:% -> %', b.approval_log_rows, v_log;
    END IF;

    -- ③ 每一条链的在途张数都没有变 ------------------------------------------
    SELECT count(*) INTO v_leave   FROM leave_requests      WHERE status='pending'   AND deleted_at IS NULL;
    SELECT count(*) INTO v_claims  FROM medical_claims      WHERE status='submitted' AND deleted_at IS NULL;
    SELECT count(*) INTO v_reviews FROM performance_reviews WHERE status='submitted';
    SELECT count(*) INTO v_po      FROM purchase_orders     WHERE approval_status='pending' AND deleted_at IS NULL;
    SELECT count(*) INTO v_wo      FROM work_orders         WHERE status='draft';
    IF (v_leave, v_claims, v_reviews, v_po, v_wo)
       IS DISTINCT FROM (b.leave_pending, b.claims_pending, b.reviews_pending, b.po_pending, b.wo_draft) THEN
        RAISE EXCEPTION 'APR2_PROOF_3|在途张数变了:leave %->% claims %->% reviews %->% po %->% wo %->%',
            b.leave_pending, v_leave, b.claims_pending, v_claims, b.reviews_pending, v_reviews,
            b.po_pending, v_po, b.wo_draft, v_wo;
    END IF;

    -- ④ ★ 名册 vs 目录:approval_chain_gates() 列的那组函数,必须【逐字等于】
    --    pg_proc 里真正调用 require_approver_for 的那组。
    --    ☞ 这一条是本刀最耐用的一件:它让"下一刀接了一条链却忘了登记"变红。
    SELECT array_agg(DISTINCT action_function ORDER BY action_function)
      INTO v_registry FROM approval_chain_gates();
    SELECT array_agg(DISTINCT p.proname::text ORDER BY p.proname::text)
      INTO v_catalog
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prosrc LIKE '%require_approver_for%'
       AND p.proname <> 'require_approver_for';
    IF v_registry IS DISTINCT FROM v_catalog THEN
        RAISE EXCEPTION 'APR2_PROOF_4|名册与目录对不上:名册=% 目录=%', v_registry, v_catalog;
    END IF;
    -- 【零必须是一次测量,不是一次缺席】—— 空名册也会让上面那一条通过
    IF coalesce(cardinality(v_registry), 0) = 0 THEN
        RAISE EXCEPTION 'APR2_PROOF_4|名册是空的 —— 一条都没有接上引擎,这不对';
    END IF;

    -- ⑤ 每一条接上引擎的链,都真的有人批得动 --------------------------------
    SELECT count(*)::integer, count(*) FILTER (WHERE approvers = 0)::integer
      INTO v_rows, v_dead FROM approval_gate_intersections();
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'APR2_PROOF_5|求交一行都没有 —— 一个瞎掉的判据与一棵干净的树都打印 0';
    END IF;
    IF v_dead > 0 THEN
        RAISE EXCEPTION 'APR2_PROOF_5|还有 % 条链没有人批得动', v_dead;
    END IF;

    -- ⑥ ★ 工单那一行真的摘掉了 —— 读的是【目录】,不是这个文件
    SELECT p.prosrc INTO v_src
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname='public' AND p.proname='release_work_order';
    IF v_src LIKE '%require_approver_for%' THEN
        RAISE EXCEPTION 'APR2_PROOF_6|release_work_order 里还有 require_approver_for';
    END IF;
    IF v_src NOT LIKE '%forbid_self_approval%' THEN
        RAISE EXCEPTION 'APR2_PROOF_6|release_work_order 里没有 forbid_self_approval';
    END IF;

    -- ⑦ 四支决定函数都接上了那支唯一的判据 ----------------------------------
    FOR v_src IN
        SELECT p.proname::text FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public'
           AND p.proname IN ('decide_leave_request','decide_medical_claim',
                             'approve_review','release_work_order')
           AND p.prosrc NOT LIKE '%forbid_self_approval%'
    LOOP
        RAISE EXCEPTION 'APR2_PROOF_7|% 没有调 forbid_self_approval', v_src;
    END LOOP;

    -- ⑧ ★ forbid_self_approval 【不是】SECURITY DEFINER —— 它不需要,
    --    而一支 DEFINER 且无调用者检查的函数会被 gate 的 B2 点名。
    SELECT p.prosecdef INTO v_secdef
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname='forbid_self_approval';
    IF v_secdef IS NOT FALSE THEN
        RAISE EXCEPTION 'APR2_PROOF_8|forbid_self_approval 的 prosecdef = %(应为 false)', v_secdef;
    END IF;

    RAISE NOTICE 'APR2_AFTER  enabled=% approval_log=% leave_pending=% claims=% reviews=% po_pending=% wo_draft=% chains=% dead=%',
        v_enabled, v_log, v_leave, v_claims, v_reviews, v_po, v_wo, v_rows, v_dead;
    RAISE NOTICE 'APR2 自证八条全过。';
END
$proof$;

COMMIT;

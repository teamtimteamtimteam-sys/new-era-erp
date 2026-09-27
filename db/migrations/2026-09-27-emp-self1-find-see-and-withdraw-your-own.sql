-- db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql
-- EMP-SELF-1(余下部分)—— 员工看得见自己的请假与报销是谁决定的、为什么;撤得掉自己还在等的;没有员工档案的账号什么都动不了;
-- 外加两件折进来的:结束了的合同表头冻结、敞口报表只算生效中的合同。
-- 由 db/scripts/build_emp_self1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(EMP-SELF-1 grilling Q1–Q8,Tim 2026-09-27 全部接受)
--   ① 表:medical_claims 多一个状态 'withdrawn' 与一列 withdrawn_at(末尾),形状约束 medical_claims_withdraw_shape
--      (withdrawn ⇔ withdrawn_at 有值,与 expense_claims 同一条)。
--   ② 新:withdraw_medical_claim(uuid) —— 本人或 module.hr.edit;只撤 submitted(G3b · Q8)。
--   ③ 新:my_document_decisions() —— 属主权限,只给调用者自己的单据,决定人显示成人(Q4 · Q5)。
--   ④ 替换:五支 NULL-blind 的写 —— submit_leave_request · submit_medical_claim · submit_expense_claim ·
--      cancel_leave_request · withdraw_expense_claim 的门改成 COALESCE(…, false)(Q9 · Q2)。
--      cancel_leave_request 另加:本人那一支只撤 pending(LEAVE_OWN_CANCEL_PENDING_ONLY,Q1)。
--   ⑤ 替换:guard_contract_write —— 到期 / 终止的合同表头任何改动按名拒 CONTRACT_TERMS_FROZEN(Q7)。
--   ⑥ 替换:price_exposure_report —— 头寸只算生效中的合同,多一种具名的零 no_active_contracts(Q6)。
--
-- 【不做什么】不加新码 —— 所以"每一个新码同一迁移里授给 admin"这条常设裁定这里没有东西可授;不碰审批开关、名册、策略;
-- 不碰 user_roles / role_permissions;不写任何业务行;两张报销视图不变(Q5)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
-- 留痕、分录、合同、三种单据一行没变;新旧函数的形状对;每一张在途单据都还有一个【不是它自己当事人】的决定人。
-- 断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ES1_PRE|approvals are expected ON';
    END IF;
    IF to_regprocedure('public.withdraw_medical_claim(uuid)') IS NOT NULL
       OR to_regprocedure('public.my_document_decisions()') IS NOT NULL THEN
        RAISE EXCEPTION 'ES1_PRE|withdraw_medical_claim or my_document_decisions already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.medical_claims'::regclass
                AND attname = 'withdrawn_at' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'ES1_PRE|medical_claims.withdrawn_at already exists';
    END IF;
    IF position('no_active_contracts' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.price_exposure_report()'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'ES1_PRE|price_exposure_report already reads contract status';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE es1_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE es1_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || updated_at::text, ',' ORDER BY code), ''))
          FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT locked_before FROM finance_settings) AS locked_before;
CREATE TEMP TABLE es1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 表:医疗申报可以被撤回(镜像 db/tables/medical_claims.sql 同改;列加在末尾)──────────────
ALTER TABLE public.medical_claims DROP CONSTRAINT medical_claims_status_check;
ALTER TABLE public.medical_claims ADD CONSTRAINT medical_claims_status_check
    CHECK (status IN ('submitted','approved','rejected','paid','withdrawn'));
ALTER TABLE public.medical_claims ADD COLUMN withdrawn_at timestamptz;
ALTER TABLE public.medical_claims ADD CONSTRAINT medical_claims_withdraw_shape
    CHECK ((status = 'withdrawn') = (withdrawn_at IS NOT NULL));

-- ── 2 · 新:撤回自己的医疗申报(镜像原样)────────────────────────────────────

-- db/functions/withdraw_medical_claim.sql
-- EMP-SELF-1(G3b,Tim 2026-09-27):员工撤回自己【还没被决定】的医疗申报。
-- 形状照 withdraw_expense_claim:本人,或者持本链的编辑码(医疗是 module.hr.edit,Tim 的 Q8);只撤 submitted。
-- 已批 / 已拒 / 已付的一律按名拒 —— 撤回不碰任何已经决定了的东西。
-- 【不写 decided_*】撤回不是一次决定;状态与 withdrawn_at 说清楚发生了什么(与报销单同一条表约束)。
-- 【生下来就是 COALESCE】没有员工档案的账号 current_user_employee() 是 NULL,裸的 NOT (… OR …) 会放它过去(EMP-SELF-1 Q2)。
--
-- NOTE: introduced by db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql.

CREATE OR REPLACE FUNCTION public.withdraw_medical_claim(p_claim_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_c record;
BEGIN
    SELECT * INTO v_c FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MEDICAL_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF NOT COALESCE(has_permission('module.hr.edit') OR v_c.employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'MEDICAL_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;

    UPDATE medical_claims
       SET status = 'withdrawn', withdrawn_at = now(), updated_by = auth.uid()
     WHERE id = p_claim_id;
    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'withdrawn');
END;
$function$;

-- ── 3 · 新:我的单据是谁决定的、为什么(镜像原样)──────────────────────────────

-- db/functions/my_document_decisions.sql
-- EMP-SELF-1(G2,Tim 的 Q4 · Q5,2026-09-27):员工在 /me 上看见自己的请假、医疗申报、报销【是谁决定的、为什么】。
--
-- 【读单据本身】decided_by · decided_at · decision_notes —— 不读 approval_log(它仍按权限开放,Tim 的 Q4 at EMP-SELF-0)。
-- 【为什么是属主权限】决定人是【另一个】员工:employees 的 RLS 只给非 HR 读者他自己那一行,
--   所以 INVOKER 下名字永远是空的。本函数只替调用者打开一件事 —— 他【自己的】单据上那位决定人的显示名。
-- 【只给自己的】employee_id = current_user_employee();没有员工档案的调用者(NULL)→ 0 行,不是全部。
-- 【显示的是人,不是账号】account_person(decided_by) → preferred_name,否则 legal_name(与 ActorName.tsx 同一条)。
--   于是 tim@ 这个附加账号做的决定显示成它主人的名字(APR-ROUTE-1 Batch B)。
-- 【self_decided】决定人这个人就是单据的主角 —— R2 那张被标记的自批,或员工自己撤掉的假;由单据推出,不读留痕。
-- 【已取消的假】cancel_leave_request 把取消人与理由写进同样三列(Tim 的 Q3:按状态标注,不改表)。
--   撤回的报销 / 医疗申报没有 decided_by,所以不出现在这里。
--
-- NOTE: introduced by db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql.

CREATE OR REPLACE FUNCTION public.my_document_decisions()
 RETURNS TABLE(kind text, doc_id uuid, decider text, decided_at timestamp with time zone, decision_notes text, self_decided boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH me AS (SELECT current_user_employee() AS eid),
    docs AS (
        SELECT 'leave_request'::text AS kind, l.id, l.employee_id, l.decided_by, l.decided_at, l.decision_notes
          FROM leave_requests l, me
         WHERE l.employee_id = me.eid AND l.deleted_at IS NULL AND l.decided_by IS NOT NULL
        UNION ALL
        SELECT 'medical_claim', m.id, m.employee_id, m.decided_by, m.decided_at, m.decision_notes
          FROM medical_claims m, me
         WHERE m.employee_id = me.eid AND m.deleted_at IS NULL AND m.decided_by IS NOT NULL
        UNION ALL
        SELECT 'expense_claim', c.id, c.employee_id, c.decided_by, c.decided_at, c.decision_notes
          FROM expense_claims c, me
         WHERE c.employee_id = me.eid AND c.decided_by IS NOT NULL
    )
    SELECT d.kind, d.id,
           (SELECT COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name)
              FROM employees e WHERE e.id = account_person(d.decided_by)),
           d.decided_at, d.decision_notes,
           COALESCE(account_person(d.decided_by) = d.employee_id, false)
      FROM docs d
$function$;

-- ── 4 · 替换:五支 NULL-blind 的写(镜像原样)────────────────────────────────

-- db/functions/submit_leave_request.sql
-- 提交请假。【按休假开始日那天的累积量校验】,不是按提交日 ——
-- 一月里订十二月的假可以,订「到那天也挣不到」的天数则当场被拒。
-- 于是「请了却没挣到」不存在,不需要扣款规则(HR-2c C3)。
-- 试用期照常累积、照常不能请:PROBATION_NO_ANNUAL_LEAVE 一个字没改。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql.

CREATE OR REPLACE FUNCTION public.submit_leave_request(p_employee_id uuid, p_leave_type_code text, p_start date, p_end date, p_start_half boolean DEFAULT false, p_end_half boolean DEFAULT false, p_reason text DEFAULT NULL::text, p_certificate_ref text DEFAULT NULL::text, p_is_exception boolean DEFAULT false, p_exception_days numeric DEFAULT NULL::numeric, p_exception_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    record;
    v_type   record;
    v_days   numeric;
    v_taken  numeric;
    v_bal    jsonb;
    v_avail  numeric;
    v_code   text;
    v_req    record;
    v_clash  text;
BEGIN
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.hr.edit') OR p_employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    IF p_is_exception AND NOT has_permission('module.hr.edit') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;

    SELECT id, code, employment_status INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;

    SELECT * INTO v_type FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND THEN RAISE EXCEPTION 'LEAVE_TYPE_NOT_FOUND|%', p_leave_type_code; END IF;
    IF NOT v_type.is_active THEN RAISE EXCEPTION 'LEAVE_TYPE_INACTIVE|%', p_leave_type_code; END IF;

    -- 【一个字都没改】试用期照常累积,照常不能请。
    IF v_type.is_accrued AND v_emp.employment_status = 'probation' THEN
        RAISE EXCEPTION 'PROBATION_NO_ANNUAL_LEAVE';
    END IF;

    IF p_is_exception THEN
        IF p_exception_reason IS NULL OR btrim(p_exception_reason) = '' THEN
            RAISE EXCEPTION 'EXCEPTION_REASON_REQUIRED';
        END IF;
        IF p_exception_days IS NULL OR p_exception_days <= 0 THEN
            RAISE EXCEPTION 'EXCEPTION_DAYS_INVALID';
        END IF;
        v_days := p_exception_days;
    ELSE
        v_days := calculate_leave_days(p_start, p_end, p_start_half, p_end_half);
        IF v_days <= 0 THEN RAISE EXCEPTION 'NO_WORKING_DAYS|%|%', p_start, p_end; END IF;
    END IF;

    SELECT code INTO v_clash FROM leave_requests
    WHERE employee_id = p_employee_id AND deleted_at IS NULL
      AND status IN ('pending','approved')
      AND daterange(start_date, end_date, '[]') && daterange(p_start, p_end, '[]')
    LIMIT 1;
    IF v_clash IS NOT NULL THEN RAISE EXCEPTION 'OVERLAPPING_REQUEST|%', v_clash; END IF;

    IF v_type.requires_certificate_after_days IS NOT NULL
       AND (p_certificate_ref IS NULL OR btrim(p_certificate_ref) = '') THEN
        SELECT COALESCE(SUM(r.days), 0) INTO v_taken
        FROM leave_requests r
        WHERE r.employee_id = p_employee_id AND r.leave_type_code = p_leave_type_code
          AND r.deleted_at IS NULL AND r.status IN ('pending','approved')
          AND EXTRACT(YEAR FROM r.start_date) = EXTRACT(YEAR FROM p_start);
        IF v_taken + v_days > v_type.requires_certificate_after_days THEN
            RAISE EXCEPTION 'CERTIFICATE_REQUIRED|%|%', v_taken, v_type.requires_certificate_after_days;
        END IF;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- 【按休假开始日那天的累积量校验】,不是按提交日。
    -- 一月里订十二月的假是可以的 —— 到十二月那些天已经挣到了;
    -- 订"到那天也挣不到"的天数则当场被拒。于是"请了却没挣到"这个状态不存在,
    -- 不需要任何扣款规则,也不需要合同里加一条(C3,fixture 6 证明)。
    -- ══════════════════════════════════════════════════════════════════════
    IF v_type.is_accrued THEN
        v_bal := leave_balance(p_employee_id, p_leave_type_code, p_start);
        v_avail := (v_bal->>'available')::numeric;
        IF v_avail < v_days THEN
            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                trim_scale(v_avail), trim_scale(v_days);
        END IF;
    END IF;

    v_code := next_leave_request_code(p_start);
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date,
                                start_half_day, end_half_day, days, reason, certificate_ref,
                                is_exception, exception_reason)
    VALUES (v_code, p_employee_id, p_leave_type_code, p_start, p_end,
            p_start_half, p_end_half, v_days, p_reason, p_certificate_ref,
            p_is_exception, CASE WHEN p_is_exception THEN p_exception_reason ELSE NULL END)
    RETURNING * INTO v_req;

    RETURN jsonb_build_object('request_id', v_req.id, 'code', v_req.code,
                              'employee_code', v_emp.code, 'leave_type_code', p_leave_type_code,
                              'days', v_days, 'status', v_req.status,
                              'is_exception', v_req.is_exception);
END;
$function$
;

-- db/functions/submit_medical_claim.sql
-- 提交报销。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.

CREATE OR REPLACE FUNCTION public.submit_medical_claim(p_employee_id uuid, p_claim_date date, p_amount_sgd numeric, p_description text DEFAULT NULL::text, p_receipt_ref text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_emp record; v_code text; v_claim record; v_year integer;
BEGIN
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.hr.edit') OR p_employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    SELECT id, code INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF p_amount_sgd IS NULL OR p_amount_sgd <= 0 THEN RAISE EXCEPTION 'AMOUNT_INVALID'; END IF;

    v_year := EXTRACT(YEAR FROM p_claim_date)::integer;
    v_code := next_medical_claim_code(p_claim_date);
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd,
                                description, receipt_ref)
    VALUES (v_code, p_employee_id, p_claim_date, v_year, p_amount_sgd, p_description, p_receipt_ref)
    RETURNING * INTO v_claim;

    RETURN jsonb_build_object('claim_id', v_claim.id, 'code', v_claim.code,
                              'employee_code', v_emp.code, 'amount_sgd', p_amount_sgd,
                              'claim_year', v_year, 'status', v_claim.status);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_expense_claim(p_employee_id uuid, p_spend_date date, p_amount numeric, p_currency text, p_description text, p_no_receipt_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_emp employees%ROWTYPE; v_code text; v_id uuid;
BEGIN
    -- 【自助:本人,或者持财务读权限的人代录】与 submit_medical_claim 同一条谓词
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.finance.view') OR p_employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF p_spend_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_REQUIRED';
    END IF;
    IF p_spend_date > CURRENT_DATE THEN
        -- 一笔"将来才会花的钱"不是报销,那是备用金 —— 而备用金被否决了(§0)
        RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_FUTURE|%|%', p_spend_date::text, CURRENT_DATE::text;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_INVALID|%', COALESCE(p_amount::text, '?');
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_CURRENCY_UNKNOWN|%', COALESCE(p_currency, '?');
    END IF;
    IF p_description IS NULL OR btrim(p_description) = '' THEN
        -- 「买了什么」是审批人唯一能据以判断的东西
        RAISE EXCEPTION 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED';
    END IF;

    v_code := next_expense_claim_code(p_spend_date);
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, created_by)
    VALUES (v_code, p_employee_id, p_spend_date, p_amount, p_currency,
            btrim(p_description),
            NULLIF(btrim(COALESCE(p_no_receipt_reason, '')), ''), auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('claim_id', v_id, 'code', v_code, 'status', 'submitted');
END;
$function$

;

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

    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.hr.edit') OR v_req.employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
    END IF;
    IF v_req.status = 'cancelled' THEN RAISE EXCEPTION 'ALREADY_CANCELLED|%', v_req.code; END IF;
    IF v_req.status = 'rejected' THEN RAISE EXCEPTION 'REQUEST_REJECTED|%', v_req.code; END IF;
    -- ★ EMP-SELF-1(Tim 的 Q1):本人那一支只撤【还在等】的假。已批的假(哪怕已经休过)只由 HR
    --   (module.hr.edit)取消 —— 此前本人经 API 撤得掉自己已批、已休的假,余额随之被放回。
    IF v_req.status <> 'pending' AND NOT has_permission('module.hr.edit') THEN
        RAISE EXCEPTION 'LEAVE_OWN_CANCEL_PENDING_ONLY|%|%', v_req.code, v_req.status;
    END IF;

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

CREATE OR REPLACE FUNCTION public.withdraw_expense_claim(p_claim_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_c expense_claims%ROWTYPE;
BEGIN
    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.finance.edit') OR v_c.employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;

    UPDATE expense_claims
       SET status = 'withdrawn', withdrawn_at = now()
     WHERE id = p_claim_id;
    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'withdrawn');
END;
$function$

;

-- ── 5 · 替换:结束了的合同表头冻结(镜像原样)────────────────────────────────

-- db/functions/guard_contract_write.sql
-- APR-8(2026-09-26,grilling Q2 · Q6):合同只有 active 有效力,所以【进入 active 的每一条路都经 CFO】。
--   INSERT:只许建草稿 —— 别的状态 → CONTRACT_ACTIVATES_THROUGH_REQUEST|编号
--     (旧的 /contracts/new 能选"生效",破窗里它会按名拒;新表单只剩草稿)。
--   UPDATE:
--     · 挂着一张在等的生效申请 → TERMS_REQUEST_FREEZES_CONTRACT|编号|那一张(先撤回)
--     · 到期 / 终止的合同 → CONTRACT_TERMS_FROZEN|编号|expired / terminated,任何一列、包括状态
--       (EMP-SELF-1,Tim 的 Q7:表头与条款只在草稿或暂停、且没有在等的申请时可改)
--     · 改成 active → CONTRACT_ACTIVATES_THROUGH_REQUEST|编号(submit_contract_activation_request)
--     · 一份生效中的合同:只许把状态改成 suspended / expired / terminated(一步 —— 只会让效力变少),
--       其余任何一列变了 → CONTRACT_ACTIVE_IS_FROZEN|编号。改条款 = 暂停、编辑、申请重新生效。
--       ★ side 是生成列:BEFORE 触发器里 NEW.side 还是 NULL(生成列在触发器之后才算),比它会把每一次暂停
--         都读成"改了一列" —— fixture 227 H8 第一次就是这么红的。它由对手方那两列推出,那两列在比。
-- 行级,BEFORE INSERT OR UPDATE。属主路径(row_security_active = false)一律放行 —— 批准时那一次 UPDATE、迁移、
-- fixture 布景走的就是它。没有码的人在这之前已被写策略与 enforce_write_permission 拒掉。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_contract_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_lock text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'CONTRACT_ACTIVATES_THROUGH_REQUEST|%', COALESCE(NEW.code, NEW.title);
        END IF;
        RETURN NEW;
    END IF;
    v_lock := contract_terms_lock_reason(OLD.id);
    IF v_lock LIKE 'request:%' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_FREEZES_CONTRACT|%|%', OLD.code, substr(v_lock, 9);
    END IF;
    -- ★ EMP-SELF-1(Tim 的 Q7,关 TERMSEDIT1-ENDED-HEADER-WRITABLE):到期 / 终止的合同,表头的【每一次】改动都拒 ——
    --   标题、期限、币种、软删,以及状态本身(改不回 draft,也不在到期与终止之间来回)。与七张条款表同一句拒绝。
    --   草稿直接置成 expired / terminated 仍然可以(OLD 是 draft,不在这里)。
    IF OLD.status IN ('expired', 'terminated') THEN
        RAISE EXCEPTION 'CONTRACT_TERMS_FROZEN|%|%', OLD.code, OLD.status;
    END IF;
    IF NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'CONTRACT_ACTIVATES_THROUGH_REQUEST|%', OLD.code;
    END IF;
    IF OLD.status = 'active'
       AND (NEW.status NOT IN ('suspended', 'expired', 'terminated')
            OR (to_jsonb(NEW) - 'status' - 'side' - 'updated_at' - 'updated_by')
               IS DISTINCT FROM (to_jsonb(OLD) - 'status' - 'side' - 'updated_at' - 'updated_by')) THEN
        RAISE EXCEPTION 'CONTRACT_ACTIVE_IS_FROZEN|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 6 · 替换:敞口报表只算生效中的合同(镜像原样)────────────────────────────

-- db/functions/price_exposure_report.sql
-- COMM-1:价格敞口 —— 一份【说得出自己看不见什么】的报告。
--
-- ★★【先例:PARTY-1 的 counterparty_overlap_report()】★★
--   它带【分母】,因为线上 customers 一个 tax_id 都没有 ——
--   「0 条重叠」与「没有可比的东西」长得一模一样,正是本仓库反复付账的那种沉默。
--   **为什么是函数不是视图:一个视图给不出分母(0 行就是 0 行)。**
--
-- ★★【本报告要分开【三种】本来都会印成 0 的零】★★
--   (i)   一份合同都没有                 → 分母是 0,问题还没有主语
--   (ii)  有合同,但没有一份写了计价条款   → 有主语,没有指数挂钩的敞口
--   (iii) ★【采购侧【没有被建模】】★ —— 一句关于【表结构】的话,不是关于数据的。
--         PRICE-1 只做了卖方向,而 §9「采购侧要不要也用指数联动」Tim 没有回答,
--         那一刀因此刻意不去扩 pricing_term_commitments。
--         于是队列那句「浮动价买进的吨数 vs 固定价卖出的吨数」——
--         **买进那一半今天在结构上就说不出来**,
--         它必须印成一句具名的话,**永远不能印成 0 吨**:
--         0 吨的意思是"我们没有浮动价买进",而真相是"这个系统还不会记这件事"。
--
-- ★ EMP-SELF-1(Tim 裁定 2026-09-27,关 TERMSEDIT1-EXPOSURE-IGNORES-STATUS):【头寸只算生效中的合同】——
--   草稿、暂停、到期、终止都不是头寸。于是卖方向多了一种具名的零 no_active_contracts
--   (有合同,但一份都没生效);contracts_with_pricing_terms / pricing_terms_total 只数生效中的合同,
--   coverage 多一个 contracts_active。contracts_total / _sell_side / _buy_side 仍数全部未删除的合同 —— 那是分母。
--
-- 【单独一行报出:index_market_calendar 是空的】于是任何计价期均价都会按名拒。
--   它与"没有合同"是**两个不同的原因** —— 屏幕上长得一样的话,
--   读的人会以为只有一件事要修(PRICE-1 为日历与报价那两句留过同样的处置)。
--
-- ★【本刀的取舍规则,写在这里因为读到这份报告的人才需要它】★
--   同一刀里 RFQ 被【拒了】而这份报告【建了】,两者不矛盾:
--   **一个半成品的 RFQ 会【冒充】另一个问题的答案;
--     一个半成品的敞口报表【自己说出】它答不了的那一半。**
--   **一个会自报家门的缺口可以上线;一个要靠人记住的缺口不可以。**

CREATE OR REPLACE FUNCTION public.price_exposure_report()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_contracts_total       int;
    v_contracts_sell        int;
    v_contracts_buy         int;
    v_contracts_active      int;
    v_contracts_with_terms  int;
    v_terms_total           int;
    v_docs_linked           int;
    v_calendar_days         int;
    v_calendar_trading      int;
    v_quotes_total          int;
    v_quotes_indexed        int;
    v_sell_state            text;
    v_sell_rows             jsonb := '[]'::jsonb;
BEGIN
    -- 【SECURITY DEFINER 必须自己查权限】属主权限绕过 RLS,所以这一句不是礼节。
    -- 【为什么是 finance.view 这一个码】价格敞口是一个【钱的头寸】;
    --   而 AGENTS.md 的第 1 条常设裁定说得很死:module.finance.view 蕴含看得见价格
    --   (总账本身就是价格数据,对能读每一条分录的人遮价格是做样子)。
    PERFORM require_permission('module.finance.view');

    -- ── 分母:让每一个 0 说得出它是哪一种 0 ────────────────────────────────
    SELECT count(*),
           count(*) FILTER (WHERE side = 'sell'),
           count(*) FILTER (WHERE side = 'buy'),
           count(*) FILTER (WHERE status = 'active')
      INTO v_contracts_total, v_contracts_sell, v_contracts_buy, v_contracts_active
      FROM contracts WHERE deleted_at IS NULL;

    -- EMP-SELF-1:只数【生效中】合同的计价条款 —— 草稿上写好的条款不是头寸
    SELECT count(*), count(DISTINCT t.contract_id)
      INTO v_terms_total, v_contracts_with_terms
      FROM contract_pricing_terms t
      JOIN contracts c ON c.id = t.contract_id AND c.deleted_at IS NULL AND c.status = 'active';

    SELECT (SELECT count(*) FROM sales_orders    WHERE contract_id IS NOT NULL AND deleted_at IS NULL)
         + (SELECT count(*) FROM purchase_orders WHERE contract_id IS NOT NULL AND deleted_at IS NULL)
      INTO v_docs_linked;

    SELECT count(*), count(*) FILTER (WHERE is_trading_day)
      INTO v_calendar_days, v_calendar_trading
      FROM index_market_calendar;

    -- 【metal_prices 有 deleted_at,所以这里要滤】一条软删的报价不该进分母:
    -- 分母的全部用处是让"0 条挂了指数"说得出它是哪一种 0,
    -- 而把删掉的行算进去,会让"有 12 条报价、0 条挂指数"这句话本身失真。
    SELECT count(*), count(*) FILTER (WHERE price_index IS NOT NULL)
      INTO v_quotes_total, v_quotes_indexed
      FROM metal_prices WHERE deleted_at IS NULL;

    -- ── 卖方向:三种零里的前两种,由分母自己分辨 ────────────────────────────
    IF v_contracts_total = 0 THEN
        -- (i) 连主语都没有。**不是"敞口为零"。**
        v_sell_state := 'no_contracts';
    ELSIF v_contracts_active = 0 THEN
        -- (i′) EMP-SELF-1:有合同,但一份都没生效。草稿 / 暂停 / 到期 / 终止都不是头寸。
        v_sell_state := 'no_active_contracts';
    ELSIF v_contracts_with_terms = 0 THEN
        -- (ii) 有合同,但没有一份写了计价条款。
        -- 【为什么这一句这样措辞】contract_pricing_terms 的 index_code 是 NOT NULL,
        --   也就是说【这张表里的每一行按构造都是指数挂钩的】。
        --   所以"有条款但都不挂指数"在今天的表结构下【不存在】,
        --   它的真身是"没有一份合同写了计价条款"。照实说,不发明一个中间态。
        v_sell_state := 'no_pricing_terms';
    ELSE
        v_sell_state := 'open_positions_listed';
        -- 真的有条款时才算头寸:按合同 × 元素,把挂在该合同下的销售订单吨数摊出来。
        -- 【今天必然是空的,而这段代码【不是】装饰】—— 它是这份报告在数据到场那天
        --   会走的那一条路;先写好,才不会在有数据的那一天才发现它没写。
        SELECT COALESCE(jsonb_agg(x ORDER BY x->>'contract_code', x->>'metal'), '[]'::jsonb)
          INTO v_sell_rows
          FROM (
            SELECT jsonb_build_object(
                       'contract_id',   c.id,
                       'contract_code', c.code,
                       'metal',         t.metal,
                       'index_code',    t.index_code,
                       'base_event',    t.base_event,
                       'qp_months',     t.qp_months,
                       'payable_pct',   t.payable_pct,
                       -- 挂在这份合同下的销售订单吨数(未删除的单据)
                       'ordered_quantity', COALESCE(q.qty, 0)) AS x
              FROM contract_pricing_terms t
              JOIN contracts c ON c.id = t.contract_id AND c.deleted_at IS NULL AND c.status = 'active'
              LEFT JOIN LATERAL (
                    SELECT SUM(l.quantity) qty
                      FROM sales_orders so
                      JOIN sales_order_lines l ON l.sales_order_id = so.id
                     WHERE so.contract_id = c.id AND so.deleted_at IS NULL
              ) q ON true
          ) s;
    END IF;

    RETURN jsonb_build_object(
        -- ── 卖方向 ──────────────────────────────────────────────────────────
        'sell_side', jsonb_build_object(
            'state',     v_sell_state,
            'positions', v_sell_rows),

        -- ── ★ 买方向:一句关于【结构】的话,永远不是一个 0 吨 ★ ────────────
        'purchase_side', jsonb_build_object(
            'modelled', false,
            'why',
                'The purchase side of this question is NOT MODELLED — this is a statement '
                'about the schema, not about the data. PRICE-1 built index-linked pricing '
                'for the sell side only: contract_pricing_terms hangs off a contract and is '
                'read by sales documents. Whether purchasing uses index linkage at all is '
                'section 9 of docs/index-pricing-spec.md, which is recorded there as an open '
                'question awaiting Tim and which PRICE-1 deliberately did not answer (it '
                'refused to extend pricing_term_commitments, because an implied ruling is '
                'worse than an open question). So "floating-price tonnes bought" cannot be '
                'reported as 0 — 0 would mean we bought nothing on a floating price, whereas '
                'the truth is that this system does not yet record that fact at all.'),

        -- ── 均价能不能算:独立的一条,与"没有合同"不是同一件事 ────────────
        'quotational_period', jsonb_build_object(
            'calendar_days_loaded',  v_calendar_days,
            'calendar_trading_days', v_calendar_trading,
            'average_available',     (v_calendar_trading > 0),
            'why',
                CASE WHEN v_calendar_days = 0 THEN
                    'index_market_calendar is EMPTY, so every quotational-period average '
                    'refuses by name (index_period_average() requires a trading day for each '
                    'day of the period). This is a DATA gap, not a code gap, and it is a '
                    'DIFFERENT reason from having no contracts — a reader who sees only one '
                    'of the two will think there is only one thing to fix.'
                ELSE
                    'A market calendar is loaded; a quotational-period average can be '
                    'computed for the days it covers.'
                END),

        -- ── 分母 ────────────────────────────────────────────────────────────
        'coverage', jsonb_build_object(
            'contracts_total',            v_contracts_total,
            'contracts_sell_side',        v_contracts_sell,
            'contracts_buy_side',         v_contracts_buy,
            'contracts_active',           v_contracts_active,
            'contracts_with_pricing_terms', v_contracts_with_terms,
            'pricing_terms_total',        v_terms_total,
            'documents_linked_to_contract', v_docs_linked,
            'metal_quotes_total',         v_quotes_total,
            'metal_quotes_carrying_index', v_quotes_indexed),

        -- 跟着数字走的那句话,不只躺在文档里(同 PARTY-1 的处置)
        'zero_is_not_the_same_as_unknown', true);
END;
$function$;

COMMENT ON FUNCTION public.price_exposure_report() IS
'COMM-1:价格敞口 —— 一份【说得出自己看不见什么】的报告,先例是 PARTY-1 的 counterparty_overlap_report(带分母;为什么是函数不是视图:一个视图给不出分母,0 行就是 0 行)。**它分开三种本来都会印成 0 的零**:(i) 一份合同都没有(分母 0,问题还没有主语);(ii) 有合同但没有一份写了计价条款(注:contract_pricing_terms.index_code 是 NOT NULL,所以"有条款但不挂指数"在今天的结构下不存在,照实说成"没有合同写了计价条款");(iii) ★采购侧【没有被建模】★ —— 一句关于表结构的话,不是关于数据的:PRICE-1 只做卖方向,§9 采购侧是敞着的问题,所以「浮动价买进的吨数」永远不印成 0 吨,而是印成一句具名的话。另外单独一行报出 index_market_calendar 是空的(均价会按名拒)—— 那与"没有合同"是两个不同的原因,长得一样会让人以为只有一件事要修。**它不把两侧轧成一个净敞口**:卖方向有结构、买方向没有,相减得到的数字看起来确定,而两个加数不是同一种东西。';

-- ── 7 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.es1_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE es1_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一行没变(本刀没有新码,所以也没有东西要授给 admin)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM es1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM es1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ES1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ES1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、合同、三种单据一行没变
    IF EXISTS ((SELECT b.k, b.id FROM es1_pending_before b EXCEPT SELECT a.k, a.id FROM es1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM es1_pending_after a EXCEPT SELECT b.k, b.id FROM es1_pending_before b)) THEN
        RAISE EXCEPTION 'ES1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM es1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || updated_at::text, ',' ORDER BY code), ''))
          FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT locked_before FROM finance_settings) AS locked_before) n) THEN
        RAISE EXCEPTION 'ES1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM es1_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || updated_at::text, ',' ORDER BY code), ''))
          FROM contracts) AS contracts,
       (SELECT count(*) FROM contract_pricing_terms) AS pricing,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT locked_before FROM finance_settings) AS locked_before) n);
    END IF;

    -- ④ 形状:两支新函数是 DEFINER、authenticated 调得到;五支写都带 COALESCE;本人撤假只撤 pending
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.withdraw_medical_claim(uuid)'::regprocedure)
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.my_document_decisions()'::regprocedure) THEN
        RAISE EXCEPTION 'ES1_PROOF|the two new functions must be SECURITY DEFINER';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.withdraw_medical_claim(uuid)'::regprocedure, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.my_document_decisions()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'ES1_PROOF|authenticated cannot execute a new function';
    END IF;
    IF position('COALESCE(' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.submit_leave_request(uuid, text, date, date, boolean, boolean, text, text, boolean, numeric, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|submit_leave_request gate is not COALESCE-hardened';
    END IF;
    IF position('COALESCE(' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.submit_medical_claim(uuid, date, numeric, text, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|submit_medical_claim gate is not COALESCE-hardened';
    END IF;
    IF position('COALESCE(' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.submit_expense_claim(uuid, date, numeric, text, text, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|submit_expense_claim gate is not COALESCE-hardened';
    END IF;
    IF position('COALESCE(' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.cancel_leave_request(uuid, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|cancel_leave_request gate is not COALESCE-hardened';
    END IF;
    IF position('COALESCE(' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.withdraw_expense_claim(uuid)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|withdraw_expense_claim gate is not COALESCE-hardened';
    END IF;
    IF position('LEAVE_OWN_CANCEL_PENDING_ONLY' IN (SELECT prosrc FROM pg_proc WHERE oid = 'public.cancel_leave_request(uuid, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|cancel_leave_request does not limit the own arm to pending';
    END IF;
    -- 没有 JWT 的读者(本迁移自己,postgres)读 my_document_decisions():0 行 —— 没有员工档案 = 什么都不给
    SELECT count(*) INTO v_n FROM my_document_decisions();
    IF v_n <> 0 THEN RAISE EXCEPTION 'ES1_PROOF|my_document_decisions gave % row(s) to a caller with no employee record', v_n; END IF;
    -- 敞口报表:线上 0 份合同 → 状态仍是 no_contracts(这支迁移没有改变线上任何一个读者此刻看到的东西)
    IF (SELECT count(*) FROM contracts WHERE deleted_at IS NULL) = 0 THEN
        PERFORM set_config('request.jwt.claims', json_build_object('sub',
            (SELECT ur.user_id FROM user_roles ur JOIN roles r ON r.id = ur.role_id
              WHERE r.code = 'cfo' AND ur.revoked_at IS NULL LIMIT 1), 'role', 'authenticated')::text, true);
        IF (price_exposure_report()->'sell_side'->>'state') <> 'no_contracts' THEN
            RAISE EXCEPTION 'ES1_PROOF|price_exposure_report state moved with 0 contracts';
        END IF;
        PERFORM set_config('request.jwt.claims', '', true);
    END IF;
    SELECT count(*) INTO v_n FROM pg_constraint WHERE conrelid = 'public.medical_claims'::regclass
       AND conname IN ('medical_claims_status_check', 'medical_claims_withdraw_shape');
    IF v_n <> 2 THEN RAISE EXCEPTION 'ES1_PROOF|medical_claims constraints: expected 2, got %', v_n; END IF;

    -- ⑤ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.es1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ES1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.es1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ES1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.es1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.es1_pending_decider_check(boolean);

COMMIT;

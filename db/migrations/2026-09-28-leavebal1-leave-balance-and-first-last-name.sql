-- db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql
-- LEAVE-BAL-1 + NAME-1(v1.4.31)—— 请假不能超过余额;员工有了名字与姓氏。
-- 由 db/scripts/build_leavebal1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(LEAVE-BAL-1 grilling Q1–Q22,Tim 2026-09-28 全部接受)
--   ① leave_balance_internal:第三个来源「按年额度」(年假以外、default_days_per_year 不为空的假别);
--      新增 'pending'(待批)· 'bookable'(= available − pending)· 'balance_checked'(有没有额度)。
--      'available' 的含义一个字没改(额度 − 已批),employees_masked 与三个页面照旧读它。
--   ② submit_leave_request:每一个有额度的假别都查(只有 unpaid 不查),比 bookable(扣待批);
--      HR 例外一样查;先锁员工行。拒绝码不变(年假 INSUFFICIENT_ACCRUED_LEAVE,其余 INSUFFICIENT_BALANCE)。
--   ③ decide_leave_request:审批时再查一次,每一个有额度的假别;比 available(只扣已批,Q10 Option A);锁员工行。
--   ④ annual_leave_available_from:比 bookable —— "哪天起提交得动"。
--   ⑤ leave_requests:收回 authenticated 的写权限,删掉三条写策略(先例 import_batches)——
--      写只走三支 SECURITY DEFINER 函数。is_exception 的列注释改成"例外不能多给"。
--   ⑥ employees:first_name / last_name(text,可空,末尾)—— 列授权 + employees_masked + 列注释,一支迁移;
--      22 行全部留空。export_my_personal_data 带上两列;anonymise_employee 把两列清成 NULL。
--
-- 【不做什么】不碰审批开关与策略;不写任何业务行;不碰任何一张已有的请假单(LV-2026-0004/0005/0006 原样);
-- 不改 leave_types 的任何值(compassionate 3 · marriage 3 · examination 2 照现值生效,Tim Q2)。
-- ★ RUNTIME CONFIG 声明(AGENTS.md):leave_types.default_days_per_year 的【含义】变了 —— 从说明性的数变成
--   一道硬额度。镜像里的种子值(db/tables/leave_types.sql)在新含义下【仍然是 Tim 要的数】(Q2 · Q3 裁定照现值),
--   所以引导默认值不改;三个日历周假别的单位问题登记在 docs/known-issues.md(Q3)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
-- 留痕、分录、请假单、员工一行没变;新列两列全空;leave_requests 登录用户只剩读;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'LB1_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees'::regclass
                AND attname IN ('first_name', 'last_name') AND NOT attisdropped) THEN
        RAISE EXCEPTION 'LB1_PRE|employees.first_name / last_name already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.leave_requests'::regclass
         AND polname IN ('leave_requests insert by permission', 'leave_requests update by permission',
                         'leave_requests delete by permission')) <> 3 THEN
        RAISE EXCEPTION 'LB1_PRE|the three leave_requests write policies are not all present';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE lb1_pending_before ON COMMIT DROP AS
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
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'
UNION ALL SELECT 'overtime_batch', id FROM overtime_batches WHERE status = 'submitted';
CREATE TEMP TABLE lb1_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM attendance_periods) AS attendance_periods,
       (SELECT count(*) FROM attendance_lines) AS attendance_lines,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT md5(COALESCE(string_agg(code || ':' || work_category || ':' || employment_status, ',' ORDER BY code), ''))
          FROM employees) AS employees,
       (SELECT locked_before FROM finance_settings) AS locked_before;
CREATE TEMP TABLE lb1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE lb1_leave_before ON COMMIT DROP AS
SELECT md5(string_agg(row(l.*)::text, ',' ORDER BY l.id)) AS h, count(*) AS n FROM leave_requests l;

-- ── 1 · 员工:名字与姓氏(镜像 db/tables/employees.sql 同改;列加在末尾)───────────────
-- 遮蔽表加列 = 三件事,一支迁移:ADD COLUMN · 列授权 · employees_masked(AGENTS.md)。
ALTER TABLE public.employees ADD COLUMN first_name text, ADD COLUMN last_name text;
GRANT SELECT (first_name, last_name) ON public.employees TO authenticated;
COMMENT ON COLUMN public.employees.first_name IS
    'NAME-1:名字(First name)。【建档与保存员工表单时必填】—— 由 app/hr/employees/actions.ts 的 createEmployee / updateEmployee 与表单的 required 把关,【库里没有约束】(Tim Q17):53 支 fixture 直接插员工、anonymise_employee 要能把它清空、而工资与账号那些写员工的函数不该因为一行旧档案没填名字就失败。迁移时 22 行全部留空,下一次保存时补。可见性与 legal_name 相同,不是受限字段。空白存 NULL。';
COMMENT ON COLUMN public.employees.last_name IS
    'NAME-1:姓氏(Last name),可空。可见性与 legal_name 相同,不是受限字段。空白存 NULL。显示照旧用 legal_name —— 这两列只出现在员工表单与个人数据导出里。';

CREATE OR REPLACE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- **列名保持 job_title**,是为了不惊动这张视图的下游读者 ——
    -- 它回答的仍然是同一个问题(这个人的头衔是什么),只是真源换了。
    (SELECT p.title FROM positions p WHERE p.id = employees.position_id) AS job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
    separation_notes,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set,
    review_exempt,
        CASE
            WHEN deleted_at IS NULL THEN annual_leave_rate_per_year(id)
            ELSE NULL::numeric
        END AS annual_leave_rate_days,
        CASE
            WHEN deleted_at IS NULL THEN accrued_annual_leave(id)
            ELSE NULL::numeric
        END AS annual_leave_accrued_days,
        CASE
            WHEN deleted_at IS NULL THEN (leave_balance_internal(id, 'annual'::text) ->> 'available'::text)::numeric
            ELSE NULL::numeric
        END AS annual_leave_available_days,
    anonymised_at,
    anonymised_by,
    -- KPI-1:新列加在【末尾】—— CREATE OR REPLACE VIEW 只允许末尾追加列。
    -- 【它必须出现在这张视图里】employees 是遮蔽表,而 colgrant 那道闸要求它的
    -- 每一列要么被列授权、要么出现在 _masked 里(WO-1a 那一课)。
    position_id,
    -- UI-1b:同 position_id —— employees 是遮蔽表,colgrant 要求每一列要么被列授权、
    -- 要么出现在这张视图里(WO-1a 那一课)。greeting_name 两样都做了:它不敏感。
    greeting_name,
    -- OVERTIME-1:同上 —— employees 是遮蔽表,新列要么被列授权、要么出现在这里;is_site_staff 两样都做了。
    is_site_staff,
    -- NAME-1:同上 —— 与 legal_name 同一个可见性,不遮蔽。
    first_name,
    last_name
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

-- ── 2 · leave_requests:写只走函数(Q12,镜像 db/tables/leave_requests.sql 同改)────────────
REVOKE ALL ON public.leave_requests FROM authenticated;
GRANT SELECT ON public.leave_requests TO authenticated;
DROP POLICY "leave_requests insert by permission" ON public.leave_requests;
DROP POLICY "leave_requests update by permission" ON public.leave_requests;
DROP POLICY "leave_requests delete by permission" ON public.leave_requests;
COMMENT ON COLUMN public.leave_requests.is_exception IS
    'True when days were entered by hand rather than computed from calculate_leave_days — for a six-day or shift schedule where Mon-Fri counting is wrong. Since LEAVE-BAL-1 (2026-09-28) an exception is balance-checked like any other request and cannot grant more than the entitlement: days beyond it are recorded as a separate unpaid-leave request.';

-- ── 3 · 函数(镜像原样;签名一个都没变)──────────────────────────────────────

-- db/functions/leave_balance_internal.sql
-- 余额的算式(不查权限)。三个来源:授予行 + 当年度的派生累积(年假)+ 按年额度(其余有额度的假别)。
-- 【HR-2a 那个重复计数的坑】carried_out 扣减照旧:结转是把剩余搬走,不是复制一份。
-- 当年累积没有 expires_on,所以「先用旧的」天然把它排在结转之后,失效逻辑也碰不到它。
--
-- ★ LEAVE-BAL-1(2026-09-28,Tim Q1–Q22):
--   · 'available' 的含义【一个字没改】= 额度 − 已批(employees_masked 与三个页面照旧读它)。
--   · 新增 'pending'(同一人、同一假别、开始日在同一年、还在等批的天数)与
--     'bookable' = available − pending —— 【提交】看 bookable,【审批】看 available(Q10 Option A:
--     别人还在等的单不算,批准不可能让已批超过额度)。
--   · 'balance_checked':这个假别【有没有额度】—— 年假(is_accrued)或 default_days_per_year 不为空。
--     只有 unpaid 没有(Q1)。没有额度的假别 available/bookable 照算(= 0 或授予),但【没有人拿它拒】。
--   · 按年额度:default_days_per_year 整年给足,按【开始日】所在公历年扣已批(Q5 · Q7);
--     不按入职折算(Q6,已登记 known-issues)。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       LEAVE-BAL-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

CREATE OR REPLACE FUNCTION public.leave_balance_internal(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_break   jsonb := '[]'::jsonb;
    v_granted numeric := 0;
    v_used    numeric := 0;
    v_expired numeric := 0;
    v_avail   numeric := 0;
    v_accrued numeric := 0;
    v_acc_used numeric := 0;
    v_year    integer := EXTRACT(YEAR FROM p_as_of)::integer;
    v_type    record;
    v_yearly  numeric := 0;
    v_yr_used numeric := 0;
    v_pending numeric := 0;
    v_checked boolean;
    r         record;
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    FOR r IN
        SELECT g.id, g.leave_year, g.days, g.granted_on, g.expires_on, g.grant_type,
               COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                         FROM leave_consumption c WHERE c.leave_grant_id = g.id), 0) AS consumed,
               -- 【已被结转走的部分】。结转是把剩余【搬到】下一年的一笔新授予里,
               -- 不是复制一份 —— 若不在这里扣掉,同样的天数会在来源授予和结转授予里
               -- 【各算一次】,余额凭空翻倍。这一条是本切最容易做错的地方之一。
               COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                         WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                           AND cf.deleted_at IS NULL), 0) AS carried_out
        FROM leave_grants g
        WHERE g.employee_id = p_employee_id AND g.leave_type_code = p_leave_type_code
          AND g.deleted_at IS NULL AND g.granted_on <= p_as_of
        ORDER BY g.expires_on NULLS LAST, g.granted_on
    LOOP
        v_granted := v_granted + r.days;
        v_used := v_used + r.consumed;
        IF r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0 THEN
            NULL;
        ELSIF r.expires_on IS NOT NULL AND r.expires_on < p_as_of THEN
            v_expired := v_expired + (r.days - r.consumed - r.carried_out);
        ELSE
            v_avail := v_avail + (r.days - r.consumed - r.carried_out);
        END IF;
        v_break := v_break || jsonb_build_object(
            'source', 'grant',
            'grant_id', r.id, 'leave_year', r.leave_year, 'grant_type', r.grant_type,
            'days', r.days, 'consumed', r.consumed, 'carried_forward_out', r.carried_out,
            'remaining', r.days - r.consumed - r.carried_out,
            'expires_on', r.expires_on,
            'status', CASE WHEN r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0
                                THEN 'carried_forward'
                           WHEN r.expires_on IS NOT NULL AND r.expires_on < p_as_of
                                THEN 'expired' ELSE 'active' END);
    END LOOP;

    -- ── 第二个来源:当年度的派生累积(只有年假) ─────────────────────────────
    -- 【它没有 expires_on】—— 于是"先用旧的"天然把它排在结转行之后,
    -- 也于是失效逻辑【碰不到它】:没有可比的日期,当年挣的天数无从作废(D4)。
    IF p_leave_type_code = 'annual' THEN
        v_accrued  := accrued_annual_leave(p_employee_id, p_as_of);
        v_acc_used := consumed_from_accrual(p_employee_id, v_year);
        v_granted := v_granted + v_accrued;
        v_used    := v_used + v_acc_used;
        v_avail   := v_avail + (v_accrued - v_acc_used);
        v_break := v_break || jsonb_build_object(
            'source', 'accrual',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'monthly_accrual',
            'days', v_accrued, 'consumed', v_acc_used, 'carried_forward_out', 0,
            'remaining', v_accrued - v_acc_used,
            'expires_on', NULL, 'status', 'active');
    END IF;

    -- ── 第三个来源(LEAVE-BAL-1):按年额度 —— 年假以外、default_days_per_year 不为空的假别 ──────
    -- 【不写 leave_consumption】这些假别批准时从来不记消耗行;"已用"就是开始日落在这一年的【已批】单。
    -- 跨年的单整张算在开始日那一年(Q7)—— 与年假的 accrual_year、证明规则的年份同一个口径。
    SELECT lt.is_accrued, lt.default_days_per_year INTO v_type
      FROM leave_types lt WHERE lt.code = p_leave_type_code;
    v_checked := COALESCE(v_type.is_accrued, false) OR v_type.default_days_per_year IS NOT NULL;
    IF NOT COALESCE(v_type.is_accrued, false) AND v_type.default_days_per_year IS NOT NULL THEN
        v_yearly := v_type.default_days_per_year;
        SELECT COALESCE(SUM(lr.days), 0) INTO v_yr_used
          FROM leave_requests lr
         WHERE lr.employee_id = p_employee_id AND lr.leave_type_code = p_leave_type_code
           AND lr.deleted_at IS NULL AND lr.status = 'approved'
           AND EXTRACT(YEAR FROM lr.start_date)::integer = v_year;
        v_granted := v_granted + v_yearly;
        v_used    := v_used + v_yr_used;
        v_avail   := v_avail + (v_yearly - v_yr_used);
        v_break := v_break || jsonb_build_object(
            'source', 'yearly',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'yearly_entitlement',
            'days', v_yearly, 'consumed', v_yr_used, 'carried_forward_out', 0,
            'remaining', v_yearly - v_yr_used,
            'expires_on', NULL, 'status', 'active');
    END IF;

    -- ── 还在等批的(LEAVE-BAL-1):只有【提交】扣它;审批不扣(Q10 Option A)──────────────
    -- 口径与已批同一个:同一人、同一假别、开始日在同一年,不论先后(Q9)。
    SELECT COALESCE(SUM(lr.days), 0) INTO v_pending
      FROM leave_requests lr
     WHERE lr.employee_id = p_employee_id AND lr.leave_type_code = p_leave_type_code
       AND lr.deleted_at IS NULL AND lr.status = 'pending'
       AND EXTRACT(YEAR FROM lr.start_date)::integer = v_year;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'leave_type_code', p_leave_type_code, 'as_of', p_as_of,
        'granted', v_granted, 'consumed', v_used, 'expired', v_expired,
        'accrued_this_year', v_accrued, 'consumed_from_accrual', v_acc_used,
        -- 【向下取到 0.5】—— 结转与消耗本就是 0.5 的整数倍,这里是防御性的一层
        'available', trim_scale(floor(v_avail * 2) / 2),
        'pending', trim_scale(v_pending),
        'bookable', trim_scale(floor(v_avail * 2) / 2 - v_pending),
        'balance_checked', v_checked,
        'breakdown', v_break);
END;
$function$
;

-- db/functions/submit_leave_request.sql
-- 提交请假。【按休假开始日那天的累积量校验】,不是按提交日 ——
-- 一月里订十二月的假可以,订「到那天也挣不到」的天数则当场被拒。
-- 于是「请了却没挣到」不存在,不需要扣款规则(HR-2c C3)。
-- 试用期照常累积、照常不能请:PROBATION_NO_ANNUAL_LEAVE 一个字没改。
--
-- ★ LEAVE-BAL-1(2026-09-28,Tim Q1–Q22):
--   · 【每一个有额度的假别】都查余额(年假 + default_days_per_year 不为空的;只有 unpaid 不查)。
--   · 提交时扣【还在等批的】:可请 = 额度 − 已批 − 待批(leave_balance 的 'bookable')。
--   · HR 的例外一样查,没有口子(Q11):超出额度的部分另开一张无薪假。
--   · 先锁住这名员工的行(Q13)—— 同一人同时提交两张时,第二张看得见第一张。
--   · 拒绝码不变:年假 INSUFFICIENT_ACCRUED_LEAVE(界面再问"哪天够"),其余 INSUFFICIENT_BALANCE。
--     两个码旧界面都认得,所以破窗里不会冒出一串生码。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       LEAVE-BAL-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

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

    -- ★ LEAVE-BAL-1(Q13):FOR UPDATE —— 同一名员工的提交与审批排队,
    --   否则两张同时提交的单各自看不见对方,一起穿过余额检查。
    SELECT id, code, employment_status INTO v_emp
    FROM employees WHERE id = p_employee_id AND deleted_at IS NULL
    FOR UPDATE;
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
    -- ★ LEAVE-BAL-1:判据从"是不是累积型"换成"有没有额度"(balance_checked),
    --   比的数从 available 换成 bookable(再扣掉还在等批的)。例外单(v_days 是 HR 手填的)一样过这里。
    v_bal := leave_balance(p_employee_id, p_leave_type_code, p_start);
    IF (v_bal->>'balance_checked')::boolean THEN
        v_avail := (v_bal->>'bookable')::numeric;
        IF v_avail < v_days THEN
            IF v_type.is_accrued THEN
                RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE|%|%',
                    trim_scale(GREATEST(v_avail, 0)), trim_scale(v_days);
            END IF;
            RAISE EXCEPTION 'INSUFFICIENT_BALANCE|%|%',
                trim_scale(GREATEST(v_avail, 0)), trim_scale(v_days);
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

-- db/functions/annual_leave_available_from.sql
-- 最早哪一天累积够 p_days 天可请。按月末逐个往前推(累积在月末落账);
-- 本假期年度内攒不够则返回 NULL —— 界面据此说另一句话,而不是编一个日期出来。
--
-- 【为什么在数据库里】"什么时候够"要靠累积规则算,而累积规则只有一份实现。
-- 放到 TypeScript 里就是第二份 —— GrantRunner 那份重复的折算公式刚被删掉,不该再种一棵。
-- 错误码本身不变(INSUFFICIENT_ACCRUED_LEAVE|accrued|requested),界面拿到错误后再问一次这里。
--
-- ★ LEAVE-BAL-1(2026-09-28):比的是 'bookable'(再扣掉还在等批的),不是 'available' ——
--   它回答的是"哪天起【提交】得动",而提交扣待批(Tim Q10)。比 available 会报一个
--   【提交时照样被拒】的日期。
--
-- NOTE: introduced by db/migrations/2026-08-08-hr2c-fu2-when-enough-accrues.sql;
--       LEAVE-BAL-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

CREATE OR REPLACE FUNCTION public.annual_leave_available_from(p_employee_id uuid, p_days numeric, p_from date DEFAULT CURRENT_DATE)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_from)::integer;
    v_m    date := date_trunc('month', p_from)::date;
    v_end  date;
BEGIN
    -- 【本人或 HR】—— 与 leave_balance 同一道口径。界面在 INSUFFICIENT_ACCRUED_LEAVE
    -- 之后调它,那时调用者要么是本人、要么持 module.hr.edit,两种都过得去。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    -- 逐个月末往前推:哪一个月末的可用余额够了,那天起就订得动。
    -- 累积在月末落账,所以「够了的那天」就是那个月末本身。
    WHILE v_m <= make_date(v_year, 12, 1) LOOP
        v_end := (v_m + interval '1 month' - interval '1 day')::date;
        IF v_end >= p_from
           AND (leave_balance_internal(p_employee_id, 'annual', v_end)->>'bookable')::numeric >= p_days THEN
            RETURN v_end;
        END IF;
        v_m := (v_m + interval '1 month')::date;
    END LOOP;
    -- 本假期年度内都攒不够 —— 返回 NULL,界面据此说另一句话,而不是编一个日期出来。
    RETURN NULL;
END;
$function$
;

-- db/functions/export_my_personal_data.sql
-- PDPA 的当事人查阅:把【关于调用者自己】的个人数据导成一份 jsonb。
-- **没有参数** —— 它拿不到别人的。SECURITY DEFINER 只用来越过列级遮蔽,
-- 不用来放宽主语(遮蔽保护的是"别人看不到",不是"他自己看不到")。
--
-- 【不含绩效评估的正文】PDPA 对评价性用途(evaluative purpose)有豁免,而它怎么
-- 适用是一个【法律判断】。所以只给存在性与时间,并在返回的 note 里【对当事人说出来】——
-- 一次沉默的省略与一次说明了的排除不是一回事。
-- 【范围只到员工】往来户联系人的个人数据在库里,而这条路不通向它们。两条都记在
-- docs/pdpa.md,本文件不复述。
--
-- ★ NAME-1(2026-09-28):first_name / last_name 跟着 legal_name 一起导出 —— 它们同样是关于这个人的个人数据。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql;
--       NAME-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

CREATE OR REPLACE FUNCTION public.export_my_personal_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_emp employees%ROWTYPE;
BEGIN
    -- 【它只导出【调用者自己】的数据】—— 没有参数,拿不到别人的。
    -- ★ APR-ROUTE-1 Batch B(R3):经 current_user_employee() 认人 —— 一个人的
    --   第二个账号导出的也是【他自己】的数据,而不是一句"没有员工档案"。
    SELECT * INTO v_emp FROM employees WHERE id = current_user_employee() AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_NO_EMPLOYEE_RECORD';
    END IF;

    RETURN jsonb_build_object(
        'generated_at', now(),
        'about', jsonb_build_object(
            'employee_code', v_emp.code, 'legal_name', v_emp.legal_name,
            'first_name', v_emp.first_name, 'last_name', v_emp.last_name,
            'preferred_name', v_emp.preferred_name, 'identity_no', v_emp.identity_no,
            'work_email', v_emp.work_email, 'work_phone', v_emp.work_phone,
            'residency_status', v_emp.residency_status,
            'work_pass', jsonb_build_object('type', v_emp.work_pass_type, 'number', v_emp.work_pass_no,
                'issued', v_emp.work_pass_issue_date, 'expires', v_emp.work_pass_expiry_date),
            'employment', jsonb_build_object('type', v_emp.employment_type,
                'category', v_emp.work_category, 'status', v_emp.employment_status,
                'job_title', (SELECT p.title FROM positions p WHERE p.id = v_emp.position_id), 'hire_date', v_emp.hire_date,
                'confirmation_date', v_emp.confirmation_date,
                'separation_date', v_emp.separation_date, 'separation_type', v_emp.separation_type),
            'monthly_salary', v_emp.monthly_salary),
        'employment_history', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.effective_date)
            FROM employment_history h WHERE h.employee_id = v_emp.id), '[]'::jsonb),
        'leave_requests', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.created_at)
            FROM leave_requests l WHERE l.employee_id = v_emp.id), '[]'::jsonb),
        'medical_claims', COALESCE((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.created_at)
            FROM medical_claims m WHERE m.employee_id = v_emp.id), '[]'::jsonb),
        'payroll_lines', COALESCE((SELECT jsonb_agg(to_jsonb(pl) ORDER BY pl.created_at)
            FROM payroll_lines pl WHERE pl.employee_id = v_emp.id), '[]'::jsonb),
        -- 【绩效评估的【正文】刻意不在这里,而这是一个【法律】问题不是设计问题】
        -- PDPA 对"评价性用途"(evaluative purpose)有豁免,而这一份导出要不要
        -- 包含评估的书面结论,取决于那条豁免怎么适用 —— 那不是我能裁的。
        -- 所以这里只给【存在性与时间】,正文留白,并在 docs/pdpa.md 里点名为待决。
        'performance_reviews_metadata_only', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'review_type', r.review_type, 'period_start', r.period_start,
                'period_end', r.period_end, 'status', r.status) ORDER BY r.period_start)
            FROM performance_reviews r WHERE r.employee_id = v_emp.id), '[]'::jsonb),
        'note', 'Performance review content is deliberately excluded pending a legal view on the PDPA evaluative-purpose exemption. See docs/pdpa.md.');
END;
$function$;

-- db/functions/anonymise_employee.sql
-- PDPA 的"目的结束后不再保留":把一名【已离职且保留期已满】的员工就地匿名化 ——
-- 覆盖身份列,行留着。与 Doc 2 原则 7 的调和见 docs/as-built-divergences.md 第 2 条;
-- 范围、待决项与那条法律问题见 docs/pdpa.md。
--
-- 【四条按名拒绝】PDPA_RETENTION_PERIOD_NOT_SET(最要紧的一条:保留期是法律问题,
-- 这支函数不用默认值替人回答;而 2026-08-24 的裁定让它成为【今天唯一走得到】的
-- 那一条 —— 其余三条在这条裁定之下永远到不了)· PDPA_EMPLOYEE_NOT_SEPARATED
-- · PDPA_RETENTION_NOT_ELAPSED · PDPA_ALREADY_ANONYMISED。证据在 db/fixtures/126。
--
-- ★★ 【这支函数将不会被使用 —— 而这是一个决定,不是一件没做完的活】(Tim,2026-08-24)★★
-- 本函数存在、正确、有 fixture 覆盖,而在 Tim 2026-08-24 的裁定之下【将不会被使用】:
--   **员工个人数据无限期保留。没有保留期,而且不会有。**
-- 它因 hr_settings.personal_data_retention_months 为 NULL 而按名拒绝
-- (PDPA_RETENTION_PERIOD_NOT_SET),而在这条裁定之下那一列【保持 NULL】。
-- 它是一件【建好了、刻意休眠】的机制,不是没做完的活。
--
-- 【不要删掉它,不要放宽这条拒绝,不要设一个期限。】那句拒绝正是这次休眠诚实的地方 ——
-- 路是关着的,而且它说得出自己为什么关着。裁定哪天改口,把那一列设上就是全部的改动。
-- 裁定本身、它没有 settle 掉的东西(保留限制仍是 PDPA 的义务,无限期保留是公司
-- 采取的立场,不是本系统给出的豁免)、以及待决清单里它从 OPEN 变成 DECIDED 的那一行,
-- 都在 docs/pdpa.md 第二节与第五节。
--
-- 【它动两张表】employees 的身份列,与 employment_history 的薪资两列 + 备注。
-- 后者是【不可变】的表 —— 匿名化是它唯一的 UPDATE 例外,而那条例外由行的形状定义
-- (见 db/tables/employment_history.sql 里的 reject_employment_history_mutation)。
--
-- NOTE: introduced by db/migrations/2026-08-24-pdpa1-anonymise-and-subject-access.sql;
--       fixed by db/migrations/2026-08-24-pdpa1-fu-the-immutable-log-gets-one-named-exception.sql
--       (第一版在真实数据上必崩:履历不可变,而它有一句 UPDATE)。
-- ★ NAME-1(2026-09-28,db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql):
--   first_name / last_name 与 preferred_name 一起清成 NULL —— 它们就是身份列。

CREATE OR REPLACE FUNCTION public.anonymise_employee(p_employee_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    v_months int;
    v_emp    employees%ROWTYPE;
    v_due    date;
BEGIN
    PERFORM require_permission('action.anonymise_employee');

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PDPA_REASON_REQUIRED';
    END IF;

    -- 【没有保留期就【拒绝】,不走任何默认】默认值 = 一次法律表态。
    SELECT personal_data_retention_months INTO v_months FROM hr_settings LIMIT 1;
    IF v_months IS NULL THEN
        RAISE EXCEPTION 'PDPA_RETENTION_PERIOD_NOT_SET';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_FOUND';
    END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    -- 【在职的人不许匿名化】目的还没有结束 —— 那不是合规,那是把在用的数据毁掉。
    IF v_emp.separation_date IS NULL THEN
        RAISE EXCEPTION 'PDPA_EMPLOYEE_NOT_SEPARATED|%', v_emp.code;
    END IF;
    v_due := (v_emp.separation_date + make_interval(months => v_months))::date;
    IF v_due > CURRENT_DATE THEN
        RAISE EXCEPTION 'PDPA_RETENTION_NOT_ELAPSED|%|%', v_emp.code, v_due;
    END IF;

    -- 【覆盖身份列;结构性的列留着】
    -- 留下的那些(编号、雇佣类型、工种、入离职日、部门)**不指向一个人** ——
    -- 它们是让总账、历史与统计还读得懂所必需的,而原则 7 要的正是这个。
    UPDATE employees SET
        legal_name           = 'ANONYMISED ' || code,
        preferred_name       = NULL,
        first_name           = NULL,
        last_name            = NULL,
        identity_no          = NULL,
        work_email           = NULL,
        work_phone           = NULL,
        work_pass_no         = NULL,
        work_pass_type       = NULL,
        work_pass_issue_date = NULL,
        work_pass_expiry_date= NULL,
        residency_status     = NULL,
        monthly_salary       = NULL,
        notes                = NULL,
        separation_notes     = NULL,
        -- KPI-1:employees.job_title 已删,清的是【职位指针】。
        -- 【为什么职位也要清】职位本身是主数据、不是个人数据,但"这一行的人
        -- 曾经担任 CFO"仍然是一条关于那个人的事实 —— 匿名化要断掉的正是这种关联。
        -- **employment_history 上那一行不动**(那是不可变的履历,见 fixture 126)。
        position_id          = NULL,
        user_id              = NULL,          -- 与登录账号解绑
        anonymised_at        = now(),
        anonymised_by        = auth.uid()
    WHERE id = p_employee_id;

    -- 薪资历史也是个人数据。**其余每一张表都只按 employee_id 引用他**,
    -- 身份列一旦从这一行拿掉,那些行就不再指向一个可识别的人(化名化)。
    -- 【anonymised_at 必须一起写】—— 它是不可变守卫认得出这个形状的凭据,
    -- 也是 salary_change 行有权不说新薪资的凭据。少了它,这句 UPDATE 会被守卫
    -- 拒掉,而那正是 fixture 126 抓到的那一幕。
    UPDATE employment_history
       SET old_monthly_salary = NULL,
           new_monthly_salary = NULL,
           notes              = NULL,
           anonymised_at      = now()
     WHERE employee_id = p_employee_id
       AND anonymised_at IS NULL;

    RETURN jsonb_build_object(
        'employee_code', v_emp.code, 'anonymised_at', now(),
        'retention_months', v_months, 'due_since', v_due, 'reason', p_reason);
END;
$function$;

-- ── 4 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.lb1_pending_decider_check(p_after boolean DEFAULT true)
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
    UNION ALL
    -- ★ OVERTIME-1:加班批 —— 门 action.overtime_approve;提交人不算,批里任何一个员工也不算(按人认)
    SELECT 'overtime_batch', b.label, b.submitted_by, NULL, h.user_id
      FROM public.overtime_batches b
      LEFT JOIN holds h ON 'action.overtime_approve' = ANY (h.codes)
                       AND public.self_leg(b.submitted_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.overtime_lines l
                                        WHERE l.batch_id = b.id AND l.voided_at IS NULL
                                          AND public.self_leg(NULL, l.employee_id, h.user_id) <> 'none')
     WHERE b.status = 'submitted'
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

CREATE TEMP TABLE lb1_pending_after ON COMMIT DROP AS
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
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'
UNION ALL SELECT 'overtime_batch', id FROM overtime_batches WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM lb1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM lb1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'LB1_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'LB1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、请假单、员工一行没变
    IF EXISTS ((SELECT b.k, b.id FROM lb1_pending_before b EXCEPT SELECT a.k, a.id FROM lb1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM lb1_pending_after a EXCEPT SELECT b.k, b.id FROM lb1_pending_before b)) THEN
        RAISE EXCEPTION 'LB1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM lb1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM attendance_periods) AS attendance_periods,
       (SELECT count(*) FROM attendance_lines) AS attendance_lines,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT md5(COALESCE(string_agg(code || ':' || work_category || ':' || employment_status, ',' ORDER BY code), ''))
          FROM employees) AS employees,
       (SELECT locked_before FROM finance_settings) AS locked_before) n) THEN
        RAISE EXCEPTION 'LB1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM lb1_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM attendance_periods) AS attendance_periods,
       (SELECT count(*) FROM attendance_lines) AS attendance_lines,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT md5(COALESCE(string_agg(code || ':' || work_category || ':' || employment_status, ',' ORDER BY code), ''))
          FROM employees) AS employees,
       (SELECT locked_before FROM finance_settings) AS locked_before) n);
    END IF;
    IF (SELECT h FROM lb1_leave_before) IS DISTINCT FROM
       (SELECT md5(string_agg(row(l.*)::text, ',' ORDER BY l.id)) FROM leave_requests l) THEN
        RAISE EXCEPTION 'LB1_PROOF|a leave request row changed';
    END IF;

    -- ④ 两列新名字:全空(Tim:22 行留空,下一次保存时补);列授权 + employees_masked(colgrant 的两半)
    SELECT count(*) INTO v_n FROM employees WHERE first_name IS NOT NULL OR last_name IS NOT NULL;
    IF v_n <> 0 THEN RAISE EXCEPTION 'LB1_PROOF|% employee(s) got a first/last name', v_n; END IF;
    IF NOT has_column_privilege('authenticated', 'public.employees', 'first_name', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.employees', 'last_name', 'SELECT') THEN
        RAISE EXCEPTION 'LB1_PROOF|employees.first_name / last_name are not SELECT-granted';
    END IF;
    IF (SELECT count(*) FROM pg_attribute WHERE attrelid = 'public.employees_masked'::regclass
         AND attname IN ('first_name', 'last_name') AND NOT attisdropped) <> 2 THEN
        RAISE EXCEPTION 'LB1_PROOF|employees_masked lacks first_name / last_name';
    END IF;

    -- ⑤ leave_requests:登录用户只剩读;三条写策略没了;读策略两条还在
    IF has_table_privilege('authenticated', 'public.leave_requests', 'INSERT')
       OR has_table_privilege('authenticated', 'public.leave_requests', 'UPDATE')
       OR has_table_privilege('authenticated', 'public.leave_requests', 'DELETE')
       OR NOT has_table_privilege('authenticated', 'public.leave_requests', 'SELECT') THEN
        RAISE EXCEPTION 'LB1_PROOF|authenticated should hold SELECT only on leave_requests';
    END IF;
    IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.leave_requests'::regclass) <> 2
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.leave_requests'::regclass AND polcmd <> 'r') THEN
        RAISE EXCEPTION 'LB1_PROOF|leave_requests should keep exactly its two read policies';
    END IF;

    -- ⑥ 签名一个都没变(破窗里旧界面照旧调得通)
    IF to_regprocedure('public.leave_balance_internal(uuid, text, date)') IS NULL THEN
        RAISE EXCEPTION 'LB1_PROOF|leave_balance_internal: signature changed';
    END IF;
    IF to_regprocedure('public.submit_leave_request(uuid, text, date, date, boolean, boolean, text, text, boolean, numeric, text)') IS NULL THEN
        RAISE EXCEPTION 'LB1_PROOF|submit_leave_request: signature changed';
    END IF;
    IF to_regprocedure('public.decide_leave_request(uuid, boolean, text)') IS NULL THEN
        RAISE EXCEPTION 'LB1_PROOF|decide_leave_request: signature changed';
    END IF;
    IF to_regprocedure('public.annual_leave_available_from(uuid, numeric, date)') IS NULL THEN
        RAISE EXCEPTION 'LB1_PROOF|annual_leave_available_from: signature changed';
    END IF;
    IF to_regprocedure('public.export_my_personal_data()') IS NULL THEN
        RAISE EXCEPTION 'LB1_PROOF|export_my_personal_data: signature changed';
    END IF;
    IF to_regprocedure('public.anonymise_employee(uuid, text)') IS NULL THEN
        RAISE EXCEPTION 'LB1_PROOF|anonymise_employee: signature changed';
    END IF;

    -- ⑦ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.lb1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'LB1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.lb1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'LB1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.lb1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.lb1_pending_decider_check(boolean);

COMMIT;

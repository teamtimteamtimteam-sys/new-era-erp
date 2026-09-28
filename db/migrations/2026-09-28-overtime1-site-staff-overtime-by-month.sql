-- db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql
-- OVERTIME-1(v1.4.30)—— 现场员工的加班:财务按月录,仓库整批批;批过的小时在那个月考勤完成时冻进底稿。
-- 由 db/scripts/build_overtime1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(OVERTIME-1 grilling Q1–Q23,Tim 2026-09-28 全部接受)
--   ① 员工:employees.is_site_staff boolean NOT NULL DEFAULT false(末尾)—— 迁移【一个人都不标】;
--      同一支迁移里补列授权与 employees_masked(遮蔽表加列的三件事,AGENTS.md)。
--   ② 两个码:action.overtime_enter → finance + admin;action.overtime_approve → warehouse + admin
--      (admin 拿到每一个新码 —— 常设裁定 2026-09-24,role-matrix 第 149 行;第 147 行那句"只做系统管理"已被它取代)。
--   ③ 两张新表:overtime_batches(月批次)· overtime_lines(一个员工一天一行)。只有读策略;写只经函数。
--   ④ 新函数:overtime_day_kind · overtime_approved_hours · overtime_assert_month_open · overtime_other_approver_exists
--      (三支内层,EXECUTE 从 authenticated 收回)· create_overtime_batch · add_overtime_line · delete_overtime_line ·
--      submit_overtime_batch · withdraw_overtime_batch · decide_overtime_batch · reverse_overtime_batch ·
--      discard_overtime_batch · overtime_month_hours · overtime_batch_lines · overtime_site_staff · my_overtime_lines。
--   ⑤ 替换:record_attendance(签名不变;非零加班按名拒 ATTENDANCE_OT_THROUGH_OVERTIME)·
--      complete_attendance_period(开着的加班批挡住完成;批过的小时冻进三个桶;冻进的总和必须等于批过的总和)·
--      attendance_period_status_rows(还开着的月读此刻批过的小时)· record_approval_decision(overtime_batch 一支)·
--      approval_pending_documents(overtime_batch 一支,blocks_disable = false)。
--   ⑥ approval_log:主体类型加 overtime_batch;读策略加同名一支。
--
-- 【不做什么】不碰审批开关与策略;不写任何业务行;不标任何员工;线上 attendance_periods / attendance_lines 0 行,
-- 所以没有任何已有底稿的三个桶被改写。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权只多了那四行;在途单据一张不少、一张不多;
-- 留痕、分录、三种自助单据一行没变;没有一个员工被标;两张新表是空的;新函数形状对;每一张在途单据都还有一个
-- 【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'OT1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.overtime_batches') IS NOT NULL OR to_regclass('public.overtime_lines') IS NOT NULL THEN
        RAISE EXCEPTION 'OT1_PRE|overtime tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees'::regclass
                AND attname = 'is_site_staff' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'OT1_PRE|employees.is_site_staff already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.overtime_enter', 'action.overtime_approve')) THEN
        RAISE EXCEPTION 'OT1_PRE|overtime codes already exist';
    END IF;
    -- Tim 2026-09-20 实测 0 行;这支迁移改写 complete_attendance_period 的冻结逻辑,前提是没有已冻的底稿
    IF EXISTS (SELECT 1 FROM attendance_periods WHERE status = 'complete') THEN
        RAISE EXCEPTION 'OT1_PRE|a completed attendance period exists — re-read the Q3 assumption';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE ot1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE ot1_counts_before ON COMMIT DROP AS
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
CREATE TEMP TABLE ot1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 两个码(镜像原样)与授权 —— 每一个新码也给 admin(常设裁定,2026-09-24)。幂等。──────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.overtime_enter', 'action', 'Enter site-staff overtime', '录入现场员工加班', 'Enter overtime for site staff in monthly batches — one line per employee per day, with the hours to be paid and an optional note — then submit the batch for approval, withdraw it while it waits, discard an unwanted one, or reverse an approved one while the month''s attendance is still open. Only employees marked as site staff can be entered.', '按月录入现场员工的加班 —— 一个员工一天一行,写要付的小时与可选备注 —— 然后把整批交去批准;在等的时候可以撤回,不要的可以丢弃,批过的在那个月考勤还开着时可以整批冲销。只录得进标为现场员工的人。', 1200),
    ('action.overtime_approve', 'action', 'Approve site-staff overtime', '批准现场员工加班', 'Approve or reject a submitted overtime batch in one action; a rejection needs a note. Nobody approves a batch they submitted or one that includes their own overtime (judged per person). The approvals switch does not affect this.', '一次批准或驳回一整批交上来的加班;驳回要写备注。没有人能批自己交的批,或者里面有自己加班的批(按人认)。审批开关不影响这件事。', 1210);

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('finance', 'action.overtime_enter'), ('admin', 'action.overtime_enter'), ('warehouse', 'action.overtime_approve'), ('admin', 'action.overtime_approve')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 2 · 员工:现场员工标记(镜像 db/tables/employees.sql 同改;列加在末尾)───────────────
-- 遮蔽表加列 = 三件事,一支迁移:ADD COLUMN · 列授权 · employees_masked(AGENTS.md)。
ALTER TABLE public.employees ADD COLUMN is_site_staff boolean NOT NULL DEFAULT false;
GRANT SELECT (is_site_staff) ON public.employees TO authenticated;
COMMENT ON COLUMN public.employees.is_site_staff IS
    'OVERTIME-1:现场员工 —— 只有现场员工有加班,加班录入页只列他们。默认 false,迁移时没有标任何一个人;由持 module.hr.edit 的人(财务)在建档与编辑员工的表单上勾。★ 不是 work_category:work_category 决定年假累积费率,而 shopfloor 的 Fu Sheng 不是现场员工、没有加班(Tim 2026-09-28)。加班批在提交与批准时再判一次这一列。';

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
    is_site_staff
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

-- ── 3 · 两张新表(镜像原样)──────────────────────────────────────────────────
-- db/tables/overtime_batches.sql
-- OVERTIME-1(2026-09-28):加班的月批次 —— 财务按月录、仓库一次批完。
--
-- 【一批 = 一个月】period_month 是当月 1 号;批里每一行的日期都落在这个月里(没有补发到后一个月,Tim Q8)。
-- 【状态】draft → submitted → approved · rejected(要备注,整批退回、改完再提)→ submitted …;
--   submitted → draft(财务撤回);approved → reversed(整批冲销,要理由,只在那个月考勤还开着时);
--   draft / rejected → discarded(不要了 —— 否则一张没人要的草稿会永远挡住那个月的考勤完成)。
-- 【"开着"的批】draft · submitted · rejected。一个月同一时刻只许一张开着的(部分唯一索引);
--   批过之后可以再开一张补充批(Tim Q6)。
-- 【审批开关不管它】(Tim Q5)仓库的人永远要按一次;approval_log 在开关关着时写一句说明。
-- 【没有 code 列】人读的名字是 label(OT 2026-10 #1),与各张申请表同形,不进 document_types。
-- 【没有写策略】只有 SELECT 策略:一切写都经 SECURITY DEFINER 函数(create / submit / withdraw /
--   decide / reverse / discard_overtime_batch)。直连 INSERT 被 RLS 拒;直连 UPDATE / DELETE 碰不到任何行。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE TABLE public.overtime_batches (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    label           text NOT NULL UNIQUE,
    period_month    date NOT NULL,
    seq             integer NOT NULL CHECK (seq > 0),
    status          text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'reversed', 'discarded')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    submitted_at    timestamptz,
    submitted_by    uuid,
    decided_at      timestamptz,
    decided_by      uuid,
    decision_notes  text,
    reversed_at     timestamptz,
    reversed_by     uuid,
    reverse_reason  text,
    discarded_at    timestamptz,
    discarded_by    uuid,
    UNIQUE (period_month, seq),
    CONSTRAINT overtime_batches_month_shape
        CHECK (period_month = date_trunc('month', period_month)::date),
    -- 交过的批一定有提交时刻(驳回的批也保留它那一次提交的时刻,所以这里是蕴含,不是等价)
    CONSTRAINT overtime_batches_submitted_shape
        CHECK (status NOT IN ('submitted', 'approved', 'reversed') OR submitted_at IS NOT NULL),
    CONSTRAINT overtime_batches_decided_shape
        CHECK ((status IN ('approved', 'rejected', 'reversed')) = (decided_at IS NOT NULL)),
    -- 驳回必须有备注(Tim Q10)
    CONSTRAINT overtime_batches_reject_note
        CHECK (status <> 'rejected' OR btrim(COALESCE(decision_notes, '')) <> ''),
    CONSTRAINT overtime_batches_reversed_shape
        CHECK ((status = 'reversed') = (reversed_at IS NOT NULL)
               AND (reversed_at IS NULL OR btrim(COALESCE(reverse_reason, '')) <> '')),
    CONSTRAINT overtime_batches_discarded_shape
        CHECK ((status = 'discarded') = (discarded_at IS NOT NULL))
);

COMMENT ON TABLE public.overtime_batches IS
    'OVERTIME-1:现场员工加班的月批次。财务(action.overtime_enter)按月录,仓库(action.overtime_approve)整批一次批或驳回(驳回要备注)。审批开关不管它;四眼:提交人不能批,批里任何一个员工(按人认)也不能批;R2 永远不覆盖加班。一个月同一时刻只许一张开着的批(draft / submitted / rejected),批过之后可以开补充批。批过的小时数在那个月考勤完成时冻进 attendance_lines 的三个桶,只算一次。那个月考勤完成之后,建、提交、批、冲销一律拒。OS 只报【小时】,不报钱(政策 7.1)。';

-- 一个月同一时刻只许一张开着的批 —— 函数先按名拒(OVERTIME_BATCH_OPEN_EXISTS),这里兜底。
CREATE UNIQUE INDEX overtime_batches_one_open_per_month
    ON public.overtime_batches (period_month) WHERE status IN ('draft', 'submitted', 'rejected');

ALTER TABLE public.overtime_batches ENABLE ROW LEVEL SECURITY;

-- 读:人力、录的人、批的人。仓库不持 module.hr.view,所以批的人要靠自己的码读得到。
CREATE POLICY "overtime_batches select by permission" ON public.overtime_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
        OR has_permission('action.overtime_enter'::text)
        OR has_permission('action.overtime_approve'::text));

REVOKE ALL ON public.overtime_batches FROM anon;

-- db/tables/overtime_lines.sql
-- OVERTIME-1(2026-09-28):一行 = 一个员工一天的加班 —— 日期 + 小时 + 可选备注(Tim 的裁定)。
--
-- 【小时是批准的那个数】不从打卡推(系统里没有打卡:Tim 裁定打卡在另一个 App 里)。
-- 【day_kind】那一天是哪一类:public_holidays 里有的 → public_holiday;星期日 → rest_day(对所有人);
--   其余 → weekday(Tim Q4)。录的时候算一次,提交与批准时再算一次 —— 批准那一刻的答案就是冻进
--   考勤的那个桶。按人的休息日是以后的事(docs/known-issues.md C-2-OT)。
-- 【同一个员工同一天只许一行活着的】(Tim Q15)部分唯一索引兜底,函数先按名拒 OVERTIME_DUPLICATE_DAY。
--   "活着" = voided_at IS NULL。整批冲销或丢弃时,那一批的行一起作废,日期随之腾出来。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE TABLE public.overtime_lines (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id    uuid NOT NULL REFERENCES public.overtime_batches (id) ON DELETE CASCADE,
    employee_id uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    work_date   date NOT NULL,
    hours       numeric(4,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
    day_kind    text NOT NULL CHECK (day_kind IN ('weekday', 'rest_day', 'public_holiday')),
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    voided_at   timestamptz
);

COMMENT ON TABLE public.overtime_lines IS
    'OVERTIME-1:一个员工一天的加班小时(批准的数,不是从打卡推出来的)。只经 add_overtime_line 写入(只录得进标为现场员工的人,日期在批次那个月里、不在未来、在职);同一个员工同一天只许一行活着的(voided_at IS NULL)。day_kind 按 overtime_day_kind 判:公共假期 → public_holiday,星期日 → rest_day,其余 → weekday。';

CREATE UNIQUE INDEX overtime_lines_one_per_employee_day
    ON public.overtime_lines (employee_id, work_date) WHERE voided_at IS NULL;
CREATE INDEX overtime_lines_employee_id_rel ON public.overtime_lines (employee_id);
CREATE INDEX overtime_lines_batch_id_rel ON public.overtime_lines (batch_id);

ALTER TABLE public.overtime_lines ENABLE ROW LEVEL SECURITY;

-- 读:与批次同一组码。
-- ★【本人那一半【不】写成一条策略】/me 上员工读自己【已批准、没作废】的行(Tim Q14)。
--   写成策略要问"那一批批准了没有",而那一问读 overtime_batches —— 策略里的子查询照样受
--   overtime_batches 自己的 RLS 约束,一个普通员工读不到批次,于是 EXISTS 恒假、他一行都看不见,
--   而且不报错。所以本人那一半走属主权限的 my_overtime_lines()(与 my_document_decisions 同形)。
CREATE POLICY "overtime_lines select by permission" ON public.overtime_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
        OR has_permission('action.overtime_enter'::text)
        OR has_permission('action.overtime_approve'::text));

REVOKE ALL ON public.overtime_lines FROM anon;

-- ── 4 · approval_log:主体类型加 overtime_batch;读策略加同名一支(镜像原样)──────────────
ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check
    CHECK (subject_type IN (
                            'leave_request', 'medical_claim', 'performance_review',
                            'purchase_order', 'payment', 'expense',
                            'pricing_formula', 'stocktake',
                            -- ★ APR-3:报销单。它是【唯一一个形状就是审批、却漏在
                            -- 这份枚举外】的单据(APR-0 §3.1 量出来的),而它自己的
                            -- status 就是审批态(submitted/withdrawn/approved/rejected)。
                            -- 加一个取值要动四处,而其中只有【读策略那一支】漏掉了
                            -- 不会有任何东西变红 —— 见本文件末尾那条策略里的同名分支。
                            'expense_claim',
                            -- WO-1b:工单。可审批的动作是【放行】—— 不是新建
                            -- (草稿谁都可以写),也不是收工(那是事后记录)。
                            'work_order',
                            -- PAY-REQ-1:付款申请(出款与冲销付款)—— CFO 批每一张。
                            -- 'payment' 那一格是 APR-1 预留的,从来没有路径写它;
                            -- 被批的是【申请】,不是付款行(付款行生下来就已经过账)。
                            'payment_request',
                            -- ROLE-1 Batch 2a(Q3 / Q9):供应商的送审、批准、驳回 —— CFO 批。
                            -- 【不是审批引擎的一条链】:没有金额、没有档位,审批开关不关它。
                            'supplier',
                            -- PAYROLL-APR-1:工资过账与撤销的申请 —— CFO 批每一张。
                            -- 被批的是【申请】(payroll_requests),不是工资期本身。
                            'payroll_request',
                            -- ROLE-1 Batch 4b:收货定价申请 —— CFO 批每一张,批准当场过账。
                            -- 被批的是【申请】(receipt_price_requests),不是收货本身。
                            'receipt_price_request',
                            -- APR-5a:贷项通知与作废发票的申请 —— CFO 批每一张,批准当场过账。
                            -- 被批的是【申请】(invoice_requests),不是发票或贷项本身。
                            'invoice_request',
                            -- APR-5b:发货放行 —— CFO 批每一张,批准就是放行。
                            -- 被批的是【放行】(shipping_releases),不是订单或发货本身。
                            'shipping_release',
                            -- APR-6:手工凭证与冲销的申请 —— CFO 批每一张,批准当场过账。
                            -- 被批的是【申请】(journal_requests),不是分录本身。
                            'journal_request',
                            -- APR-7:仓库申请(注销批次 · 加工回滚 · 作废销毁证书)—— CFO 批每一张,批准当场生效。
                            -- 被批的是【申请】(warehouse_requests),不是批次、加工单或证书本身。
                            'warehouse_request',
                            -- APR-8:条款申请(定价公式新建 / 修改 / 重新启用 · 合同生效)—— CFO 批每一张,批准当场生效。
                            -- 被批的是【申请】(terms_requests),不是公式或合同本身(上面那个 pricing_formula 从来没人写过)。
                            'terms_request',
                            -- APR-9:调薪申请 —— CFO 批(CFO 是当事人时 cco 批),批准当场改月薪。
                            -- 被批的是【申请】(salary_change_requests),不是员工档案本身。
                            'salary_change_request',
                            -- APR-9:固定资产处置申请 —— CFO 批每一张,批准当场处置。
                            -- 被批的是【申请】(asset_disposal_requests),不是资产卡本身。
                            'asset_disposal_request',
                            -- APR-10:GST 申报申请 —— CFO 批每一张,批准当场写快照(期间 → approved)。
                            -- 被批的是【申请】(gst_filing_requests),不是期间本身。
                            'gst_filing_request',
                            -- OVERTIME-1:加班月批次 —— 仓库整批批或驳回。审批开关不管它;没有金额。
                            'overtime_batch'));

DROP POLICY "approval_log select by permission" ON public.approval_log;
CREATE POLICY "approval_log select by permission"
    ON public.approval_log
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (
        CASE subject_type
            WHEN 'leave_request'      THEN has_permission('module.hr.view'::text)
            WHEN 'medical_claim'      THEN has_permission('module.hr.view'::text)
            WHEN 'performance_review' THEN has_permission('module.hr.view'::text)
            WHEN 'purchase_order'     THEN has_permission('module.purchasing.view'::text)
            WHEN 'payment'            THEN has_permission('module.finance.view'::text)
            WHEN 'expense'            THEN has_permission('module.finance.view'::text)
            -- ★★ APR-3:报销单那一支 —— 这是 APR-0 §3.2 点名的第 ④ 格,
            --   也是四格里【唯一一个漏掉也不会有任何东西变红】的那一格:
            --   写得进、读不出,对每一个人都是 0 行,而且不报错。
            --   WO-1b 正是在这一格上漏了一次(APR0-WORK-ORDER-APPROVALS-INVISIBLE)。
            --   取的码与 expense_claims 自己的读策略同源(module.finance.view)——
            --   ⚠ 照直说:那张表的策略还有【或者这张单说的就是你】那一条腿,
            --   而留痕这一支【没有】给员工本人开口子。理由:一行留痕会说出
            --   "谁批的、什么级别",那是内控记录,不是自助查询;员工在 /me 上
            --   看得见自己那张单的状态,那条路没有变。
            WHEN 'expense_claim'      THEN has_permission('module.finance.view'::text)
            WHEN 'pricing_formula'    THEN has_permission('module.pricing.view'::text)
            WHEN 'stocktake'          THEN has_permission('module.stocktakes.view'::text)
            -- ★ APR-1:WO-1b 漏掉的那一支(APR0-WORK-ORDER-APPROVALS-INVISIBLE)。
            --   它写得进、读不出:线上有 1 行 work_order 留痕,而任何 authenticated
            --   身份读到的都是 0 行【而且不报错】—— 一片正确的空白,与"这张工单
            --   还没有被放行过"在屏幕上逐字相同。
            --   取的码与 work_orders 自己的读策略【同一个】:读工单的判据只该有一份定义。
            --   ⚠ 照直说:cfo 不持 module.processing.view,所以二级审批人仍然读不到它。
            WHEN 'work_order'         THEN has_permission('module.processing.view'::text)
            -- ★ PAY-REQ-1:付款申请那一支 —— 与 payment_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 在报销单上记过的那一格)。
            WHEN 'payment_request'    THEN has_permission('module.finance.view'::text)
            -- ★ ROLE-1 Batch 2a:供应商那一支 —— 与 suppliers 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'supplier'           THEN has_permission('module.suppliers.view'::text)
            -- ★ PAYROLL-APR-1:工资申请那一支 —— 与 payroll_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'payroll_request'    THEN has_permission('module.hr.view'::text)
            -- ★ ROLE-1 Batch 4b:收货定价申请那一支 —— 与 receipt_price_requests 自己的读策略同一对码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'receipt_price_request' THEN has_permission('module.inbound.view'::text)
                                          AND has_permission('data.view_purchase_prices'::text)
            -- ★ APR-5a:贷项 / 作废申请那一支 —— 与 invoice_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'invoice_request'    THEN has_permission('module.finance.view'::text)
            -- ★ APR-5b:发货放行那一支 —— 与 shipping_releases 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'shipping_release'   THEN has_permission('module.sales.view'::text)
            -- ★ APR-6:手工凭证 / 冲销申请那一支 —— 与 journal_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'journal_request'    THEN has_permission('module.finance.view'::text)
            -- ★ APR-7:仓库申请那一支 —— 与 warehouse_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'warehouse_request'  THEN has_permission('module.finance.view'::text)
            -- ★ APR-8:条款申请那一支 —— 公式那一页的门。留痕里只有编号与决定,没有条款本身。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'terms_request'      THEN has_permission('module.pricing.view'::text)
            -- ★ APR-9:调薪申请那一支 —— 与 salary_change_requests 自己的读策略同一对码。留痕里没有月薪数
            --   (performance_review 同形),但"谁的调薪、谁批的"本身就是人事记录。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'salary_change_request'  THEN has_permission('module.hr.view'::text)
                                          AND has_permission('data.view_pay'::text)
            -- ★ APR-9:处置申请那一支 —— 与 asset_disposal_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'asset_disposal_request' THEN has_permission('module.finance.view'::text)
            -- ★ APR-10:GST 申报申请那一支 —— 与 gst_filing_requests 自己的读策略同一个码。
            --   漏掉它,写得进、读不出、不报错(APR-3 记过的那一格)。
            WHEN 'gst_filing_request'     THEN has_permission('module.finance.view'::text)
            -- OVERTIME-1:与两张加班表同一组码 —— 批的人(仓库)不持 module.hr.view。
            WHEN 'overtime_batch'         THEN (has_permission('module.hr.view'::text)
                                                OR has_permission('action.overtime_enter'::text)
                                                OR has_permission('action.overtime_approve'::text))
            ELSE false
        END
    );

-- ── 5 · 内层判据(镜像原样)──────────────────────────────────────────────────

-- db/functions/overtime_day_kind.sql
-- OVERTIME-1(Tim Q4,2026-09-28):一天加班落进哪一个桶。
--   public_holidays 里有这一天(新加坡、启用中)→ public_holiday;
--   星期日 → rest_day(对所有人 —— 按人的休息日推后,见 docs/known-issues.md C-2-OT);
--   其余 → weekday。
-- 【公共假期先判】一个落在星期日的公共假期算 public_holiday。
-- 【不是 SECURITY DEFINER】它只读 public_holidays(任何登录用户都读得到),与 is_business_day 同形。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_day_kind(p_date date)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_date IS NULL THEN NULL
        WHEN EXISTS (SELECT 1 FROM public_holidays h
                      WHERE h.holiday_date = p_date AND h.country = 'SG' AND h.is_active)
            THEN 'public_holiday'
        WHEN EXTRACT(ISODOW FROM p_date) = 7 THEN 'rest_day'
        ELSE 'weekday'
    END;
$function$;

COMMENT ON FUNCTION public.overtime_day_kind(date) IS
'OVERTIME-1(Tim Q4):一天加班落进哪一个桶 —— 公共假期(public_holidays,SG,启用中)→ public_holiday;星期日 → rest_day(对所有人);其余 → weekday。公共假期先判。';

-- db/functions/overtime_approved_hours.sql
-- OVERTIME-1(Tim Q1 · Q3):某个月里每个员工【已批准、没作废】的加班小时,按三个桶分。
--
-- 【"只算一次"住在这里】一行只属于一个批次,一个批次只属于一个月;只数 status = 'approved'
--   的批里 voided_at IS NULL 的行。冲销与丢弃的批,它们的行已经作废,所以不进来。
-- 【桶是行上存的 day_kind】批准那一刻定下来的那个,不是今天再算一遍 —— 假期表事后改了,
--   已经批过的小时不会悄悄换桶。
-- 【两个读者,一份定义】complete_attendance_period(冻进 attendance_lines)与
--   overtime_month_hours(屏幕在考勤还开着时读此刻的数)。
-- 【不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回】两个调用者都是 DEFINER,在属主身份下调它。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_approved_hours(p_month date)
 RETURNS TABLE(employee_id uuid, weekday_hours numeric, rest_day_hours numeric, public_holiday_hours numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT l.employee_id,
           COALESCE(sum(l.hours) FILTER (WHERE l.day_kind = 'weekday'), 0),
           COALESCE(sum(l.hours) FILTER (WHERE l.day_kind = 'rest_day'), 0),
           COALESCE(sum(l.hours) FILTER (WHERE l.day_kind = 'public_holiday'), 0)
      FROM overtime_lines l
      JOIN overtime_batches b ON b.id = l.batch_id
     WHERE b.period_month = date_trunc('month', p_month)::date
       AND b.status = 'approved'
       AND l.voided_at IS NULL
     GROUP BY l.employee_id;
$function$;

COMMENT ON FUNCTION public.overtime_approved_hours(date) IS
'OVERTIME-1:某个月每个员工已批准、没作废的加班小时,按行上存的 day_kind 分三个桶。只数 approved 批里 voided_at IS NULL 的行 —— 每一行只属于一个批、一个月,所以只算一次。读者:complete_attendance_period(冻进 attendance_lines)与 overtime_month_hours。EXECUTE 已从 authenticated 收回。';

-- db/functions/overtime_assert_month_open.sql
-- OVERTIME-1(Tim Q8):那个月的考勤已经完成 → 建、提交、批、冲销一律按名拒。
--   OVERTIME_MONTH_COMPLETE|<考勤编号>|<YYYY-MM>
-- 【没有补发到后一个月】要改一个已完成的月:先重开考勤(工资过账之前才准),
--   过账之后要走 CFO 批的工资撤销申请 —— 那两条路本来就在。
-- 【不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回】调用者全是 DEFINER。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_assert_month_open(p_month date)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    SELECT ap.code INTO v_code FROM attendance_periods ap
     WHERE ap.period_month = date_trunc('month', p_month)::date AND ap.status = 'complete';
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_COMPLETE|%|%', v_code, to_char(p_month, 'YYYY-MM');
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.overtime_assert_month_open(date) IS
'OVERTIME-1(Tim Q8):那个月的考勤已完成 → RAISE OVERTIME_MONTH_COMPLETE|<考勤编号>|<YYYY-MM>。建、提交、批、冲销一个加班批之前都问它。EXECUTE 已从 authenticated 收回。';

-- db/functions/overtime_other_approver_exists.sql
-- OVERTIME-1(Tim Q12):除了提单人与批里的每一个员工(都按人认),还有没有一个【真持有人】持
-- action.overtime_approve。没有 → 建批与提交按名拒 OVERTIME_NO_OTHER_APPROVER,
-- 否则那一批生下来就没人批得动。
--   "真持有人" = real_role_grants(未撤销 / 已确认 / 未封禁 / 未删除),与 create_work_order 的
--   WO_NO_OTHER_RELEASER 同一句判据;"不是同一个人" = self_leg(…) = 'none'(跨账号)。
-- 【不看审批开关】加班永远等人批(Tim Q5)。
-- 【不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回】它读 real_role_grants(已收回),
--   调用者全是 DEFINER。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_other_approver_exists(p_raiser uuid, p_subjects uuid[])
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
         CROSS JOIN LATERAL real_role_grants(r.code) g
         WHERE rp.permission_code = 'action.overtime_approve'
           AND self_leg(p_raiser, NULL::uuid, g.user_id) = 'none'
           AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p_subjects, '{}'::uuid[])) s(emp)
                            WHERE self_leg(NULL::uuid, s.emp, g.user_id) <> 'none'));
$function$;

COMMENT ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) IS
'OVERTIME-1(Tim Q12):除了提单人与批里的每一个员工(按人认,跨账号),还有没有一个真持有人(real_role_grants)持 action.overtime_approve。不看审批开关。EXECUTE 已从 authenticated 收回。';

-- ── 6 · 新:加班批的写与读(镜像原样)────────────────────────────────────────

-- db/functions/create_overtime_batch.sql
-- OVERTIME-1(2026-09-28):财务开一个月的加班批(action.overtime_enter)。
--
-- 【拒绝的顺序 = 人下一步该改什么的顺序】月份没给 → 月份在未来 → 月份早于系统起点 →
--   那个月考勤已完成 → 那个月已有一张开着的批 → 一个现场员工都没有 → 没有别人批得动。
-- 【"没有现场员工"是一句具名的拒绝,不是一张空批】页面在这种时候本来就把钮画成按不动并说出
--   去哪里标;这里是同一件事在库里的那一半(Tim Q17)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.create_overtime_batch(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_m      date;
    v_start  date;
    v_open   text;
    v_seq    integer;
    v_label  text;
    v_id     uuid;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_REQUIRED';
    END IF;
    v_m := date_trunc('month', p_month)::date;
    IF v_m > date_trunc('month', CURRENT_DATE)::date THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_FUTURE|%', to_char(v_m, 'YYYY-MM');
    END IF;
    SELECT system_start_date INTO v_start FROM finance_settings LIMIT 1;
    IF v_start IS NOT NULL AND v_m < date_trunc('month', v_start)::date THEN
        RAISE EXCEPTION 'OVERTIME_MONTH_BEFORE_START|%|%', to_char(v_m, 'YYYY-MM'), v_start::text;
    END IF;
    PERFORM overtime_assert_month_open(v_m);

    SELECT b.label INTO v_open FROM overtime_batches b
     WHERE b.period_month = v_m AND b.status IN ('draft', 'submitted', 'rejected') LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_EXISTS|%', v_open;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM employees e
                    WHERE e.is_site_staff AND e.deleted_at IS NULL
                      AND e.hire_date <= (v_m + interval '1 month - 1 day')::date
                      AND (e.separation_date IS NULL OR e.separation_date >= v_m)) THEN
        RAISE EXCEPTION 'OVERTIME_NO_SITE_STAFF|%', to_char(v_m, 'YYYY-MM');
    END IF;

    IF NOT overtime_other_approver_exists(auth.uid(), '{}'::uuid[]) THEN
        RAISE EXCEPTION 'OVERTIME_NO_OTHER_APPROVER|%', to_char(v_m, 'YYYY-MM');
    END IF;

    SELECT COALESCE(max(b.seq), 0) + 1 INTO v_seq FROM overtime_batches b WHERE b.period_month = v_m;
    v_label := 'OT ' || to_char(v_m, 'YYYY-MM') || ' #' || v_seq::text;
    INSERT INTO overtime_batches (label, period_month, seq, created_by)
    VALUES (v_label, v_m, v_seq, auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('batch_id', v_id, 'label', v_label, 'period_month', v_m);
END;
$function$;

COMMENT ON FUNCTION public.create_overtime_batch(date) IS
'OVERTIME-1:开一个月的加班批(action.overtime_enter)。拒:OVERTIME_MONTH_REQUIRED · OVERTIME_MONTH_FUTURE · OVERTIME_MONTH_BEFORE_START(早于 system_start_date 那个月)· OVERTIME_MONTH_COMPLETE(那个月考勤已完成)· OVERTIME_BATCH_OPEN_EXISTS(已有 draft / submitted / rejected 的批)· OVERTIME_NO_SITE_STAFF(那个月一个在职的现场员工都没有)· OVERTIME_NO_OTHER_APPROVER(除了你没有真持有人持 action.overtime_approve)。';

-- db/functions/add_overtime_line.sql
-- OVERTIME-1(2026-09-28):在一张还能改的批(draft / rejected)上加一行:员工 + 日期 + 小时 + 可选备注。
--
-- 【只录得进现场员工】employees.is_site_staff(Tim 的裁定:只有现场员工有加班)。
--   这一条在提交与批准时【再判一次】—— 标记可能在两次之间被拿掉。
-- 【日期】在批次那个月里、不在未来、那一天这个人在职(入职日 ≤ 日期 ≤ 离职日)。
-- 【小时】> 0、≤ 24、至多两位小数。多出来的位数按名拒,不悄悄四舍五入 —— numeric(4,2)
--   会替人舍掉,而被舍掉的那一点没人看见过。
-- 【同一个员工同一天】已有一行活着的(任何一批,开着的或批过的)→ 按名拒并点出那一批。
-- 要改一行:删掉再加(delete_overtime_line)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.add_overtime_line(p_batch_id uuid, p_employee_id uuid, p_work_date date, p_hours numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b    overtime_batches%ROWTYPE;
    v_e    employees%ROWTYPE;
    v_dup  text;
    v_id   uuid;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status NOT IN ('draft', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_EDITABLE|%|%', v_b.label, v_b.status;
    END IF;
    PERFORM overtime_assert_month_open(v_b.period_month);

    SELECT * INTO v_e FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF NOT v_e.is_site_staff THEN
        RAISE EXCEPTION 'OVERTIME_NOT_SITE_STAFF|%', v_e.code;
    END IF;

    IF p_work_date IS NULL THEN
        RAISE EXCEPTION 'OVERTIME_DATE_REQUIRED';
    END IF;
    IF date_trunc('month', p_work_date)::date <> v_b.period_month THEN
        RAISE EXCEPTION 'OVERTIME_DATE_OUTSIDE_MONTH|%|%', p_work_date::text, to_char(v_b.period_month, 'YYYY-MM');
    END IF;
    IF p_work_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'OVERTIME_DATE_FUTURE|%', p_work_date::text;
    END IF;
    IF v_e.hire_date > p_work_date
       OR (v_e.separation_date IS NOT NULL AND v_e.separation_date < p_work_date) THEN
        RAISE EXCEPTION 'OVERTIME_EMPLOYEE_NOT_ACTIVE|%|%', v_e.code, p_work_date::text;
    END IF;

    IF p_hours IS NULL OR p_hours <= 0 OR p_hours > 24 OR round(p_hours, 2) <> p_hours THEN
        RAISE EXCEPTION 'OVERTIME_HOURS_INVALID|%', COALESCE(p_hours::text, '?');
    END IF;

    SELECT b.label INTO v_dup
      FROM overtime_lines l JOIN overtime_batches b ON b.id = l.batch_id
     WHERE l.employee_id = p_employee_id AND l.work_date = p_work_date AND l.voided_at IS NULL
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_DUPLICATE_DAY|%|%|%', v_e.code, p_work_date::text, v_dup;
    END IF;

    INSERT INTO overtime_lines (batch_id, employee_id, work_date, hours, day_kind, note, created_by)
    VALUES (p_batch_id, p_employee_id, p_work_date, p_hours, overtime_day_kind(p_work_date),
            NULLIF(btrim(COALESCE(p_note, '')), ''), auth.uid())
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('line_id', v_id, 'batch_id', p_batch_id);
END;
$function$;

COMMENT ON FUNCTION public.add_overtime_line(uuid, uuid, date, numeric, text) IS
'OVERTIME-1:在 draft / rejected 的加班批上加一行(action.overtime_enter)。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE · OVERTIME_MONTH_COMPLETE · OVERTIME_EMPLOYEE_NOT_FOUND · OVERTIME_NOT_SITE_STAFF · OVERTIME_DATE_REQUIRED · OVERTIME_DATE_OUTSIDE_MONTH · OVERTIME_DATE_FUTURE · OVERTIME_EMPLOYEE_NOT_ACTIVE · OVERTIME_HOURS_INVALID(> 0、≤ 24、至多两位小数)· OVERTIME_DUPLICATE_DAY(同一个员工同一天已有一行活着的,点出那一批)。';

-- db/functions/delete_overtime_line.sql
-- OVERTIME-1(2026-09-28):从一张还能改的批(draft / rejected)上删一行。改一行 = 删掉再加。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.delete_overtime_line(p_line_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_l  overtime_lines%ROWTYPE;
    v_b  overtime_batches%ROWTYPE;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_l FROM overtime_lines WHERE id = p_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    SELECT * INTO v_b FROM overtime_batches WHERE id = v_l.batch_id FOR UPDATE;
    IF v_b.status NOT IN ('draft', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_EDITABLE|%|%', v_b.label, v_b.status;
    END IF;
    PERFORM overtime_assert_month_open(v_b.period_month);

    DELETE FROM overtime_lines WHERE id = p_line_id;
    RETURN jsonb_build_object('line_id', p_line_id, 'batch_id', v_b.id);
END;
$function$;

COMMENT ON FUNCTION public.delete_overtime_line(uuid) IS
'OVERTIME-1:从 draft / rejected 的加班批上删一行(action.overtime_enter)。拒:OVERTIME_LINE_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE · OVERTIME_MONTH_COMPLETE。';

-- db/functions/submit_overtime_batch.sql
-- OVERTIME-1(2026-09-28):财务把一张批(draft / rejected)交给仓库批。
--
-- 【标记再判一次】批里每一个员工此刻仍是现场员工 —— 录的时候是,不等于现在还是。
-- 【桶再算一次】day_kind 按此刻的假期表重算(批准时还会再算一次,那一次才是冻结的)。
-- 【别人批得动】除了提交人与批里的每一个员工(按人认),还要有一个真持有人持
--   action.overtime_approve;没有 → OVERTIME_NO_OTHER_APPROVER。不看审批开关(Tim Q5)。
-- 【留痕】approval_log 写一行 submitted。被驳回过的批再提交时,上一次的驳回备注仍在留痕里,
--   批次行上的决定三列清空(它们说的是【这一轮】的决定)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.submit_overtime_batch(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b     overtime_batches%ROWTYPE;
    v_bad   text;
    v_emps  uuid[];
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status NOT IN ('draft', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_EDITABLE|%|%', v_b.label, v_b.status;
    END IF;
    PERFORM overtime_assert_month_open(v_b.period_month);

    IF NOT EXISTS (SELECT 1 FROM overtime_lines WHERE batch_id = p_batch_id) THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_EMPTY|%', v_b.label;
    END IF;

    SELECT e.code INTO v_bad
      FROM overtime_lines l JOIN employees e ON e.id = l.employee_id
     WHERE l.batch_id = p_batch_id AND (NOT e.is_site_staff OR e.deleted_at IS NOT NULL)
     ORDER BY e.code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_NOT_SITE_STAFF|%', v_bad;
    END IF;

    SELECT array_agg(DISTINCT l.employee_id) INTO v_emps FROM overtime_lines l WHERE l.batch_id = p_batch_id;
    IF NOT overtime_other_approver_exists(auth.uid(), v_emps) THEN
        RAISE EXCEPTION 'OVERTIME_NO_OTHER_APPROVER|%', v_b.label;
    END IF;

    UPDATE overtime_lines SET day_kind = overtime_day_kind(work_date) WHERE batch_id = p_batch_id;
    UPDATE overtime_batches
       SET status = 'submitted', submitted_at = now(), submitted_by = auth.uid(),
           decided_at = NULL, decided_by = NULL, decision_notes = NULL
     WHERE id = p_batch_id;

    PERFORM record_approval_decision('overtime_batch', p_batch_id, 'submitted', NULL::smallint, NULL::text);
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'submitted');
END;
$function$;

COMMENT ON FUNCTION public.submit_overtime_batch(uuid) IS
'OVERTIME-1:把 draft / rejected 的加班批交给仓库批(action.overtime_enter)。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE · OVERTIME_MONTH_COMPLETE · OVERTIME_BATCH_EMPTY · OVERTIME_NOT_SITE_STAFF(标记再判一次)· OVERTIME_NO_OTHER_APPROVER(除了提交人与批里的员工,没人持 action.overtime_approve)。写一行 approval_log submitted。';

-- db/functions/withdraw_overtime_batch.sql
-- OVERTIME-1(Tim Q10):财务撤回一张还在等仓库批的批 —— 它回到 draft,可以改、再提。
-- 【不写 approval_log】撤回不是一次决定(与 salary_change / journal 申请的撤回同形)。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.withdraw_overtime_batch(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b  overtime_batches%ROWTYPE;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status <> 'submitted' THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_SUBMITTED|%|%', v_b.label, v_b.status;
    END IF;

    UPDATE overtime_batches
       SET status = 'draft', submitted_at = NULL, submitted_by = NULL
     WHERE id = p_batch_id;
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'draft');
END;
$function$;

COMMENT ON FUNCTION public.withdraw_overtime_batch(uuid) IS
'OVERTIME-1(Tim Q10):撤回一张 submitted 的加班批(action.overtime_enter),它回到 draft。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_SUBMITTED。不写 approval_log。';

-- db/functions/decide_overtime_batch.sql
-- OVERTIME-1(2026-09-28):仓库一次批完或驳回一整批(action.overtime_approve)。
--
-- 【审批开关不管它】(Tim Q5)开着关着,都要仓库这个人按一次;关着时留痕多写一句说明,
--   而决定值照样是 approved / rejected —— 从不 auto_approved(与工单下达、HR 三条链同一条裁定)。
-- 【四眼,两条腿,按人认】提交人不能批(|raiser);批里【任何一个】员工不能批(|subject)。
--   判据只有 forbid_self_approval 一份:按员工逐个问一次,每一次都先判提交人那条腿 ——
--   所以提交人撞上的永远是 |raiser。R2 的例外只认三类单据,永远不覆盖加班。
--   没有 CFO 越级(Tim Q5):门只有 action.overtime_approve。
-- 【驳回要备注】整批驳回(没有逐行批),批退回财务手里,改完再提(Tim Q10)。
-- 【批准时再判】那个月考勤没完成、每个员工仍是现场员工;day_kind 在这一刻按假期表重算并冻住。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.decide_overtime_batch(p_batch_id uuid, p_decision text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b     overtime_batches%ROWTYPE;
    v_emp   uuid;
    v_bad   text;
    v_note  text := NULLIF(btrim(COALESCE(p_note, '')), '');
    v_log   text;
BEGIN
    PERFORM require_permission('action.overtime_approve');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status <> 'submitted' THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_SUBMITTED|%|%', v_b.label, v_b.status;
    END IF;
    IF p_decision IS NULL OR p_decision NOT IN ('approved', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_DECISION_INVALID|%', COALESCE(p_decision, '?');
    END IF;

    -- 四眼:提交人那条腿先判,然后批里的每一个员工(编号顺序,拒绝可复现)
    PERFORM forbid_self_approval(v_b.submitted_by, NULL::uuid, 'overtime_batch');
    FOR v_emp IN SELECT l.employee_id FROM overtime_lines l JOIN employees e ON e.id = l.employee_id
                  WHERE l.batch_id = p_batch_id GROUP BY l.employee_id, e.code ORDER BY e.code LOOP
        PERFORM forbid_self_approval(v_b.submitted_by, v_emp, 'overtime_batch');
    END LOOP;

    IF p_decision = 'rejected' AND v_note IS NULL THEN
        RAISE EXCEPTION 'OVERTIME_REJECT_NOTE_REQUIRED|%', v_b.label;
    END IF;

    IF p_decision = 'approved' THEN
        PERFORM overtime_assert_month_open(v_b.period_month);
        SELECT e.code INTO v_bad
          FROM overtime_lines l JOIN employees e ON e.id = l.employee_id
         WHERE l.batch_id = p_batch_id AND (NOT e.is_site_staff OR e.deleted_at IS NOT NULL)
         ORDER BY e.code LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'OVERTIME_NOT_SITE_STAFF|%', v_bad;
        END IF;
        UPDATE overtime_lines SET day_kind = overtime_day_kind(work_date) WHERE batch_id = p_batch_id;
    END IF;

    UPDATE overtime_batches
       SET status = p_decision, decided_at = now(), decided_by = auth.uid(), decision_notes = v_note
     WHERE id = p_batch_id;

    v_log := CASE WHEN approvals_enabled() THEN v_note
                  ELSE concat_ws(' · ', v_note,
                       '审批流未启用(finance_settings.approvals_enabled = false)—— 加班不受审批开关管,决定仍是仓库这个人按下去的') END;
    PERFORM record_approval_decision('overtime_batch', p_batch_id, p_decision, NULL::smallint, v_log);

    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', p_decision,
                              'approvals_enabled', approvals_enabled());
END;
$function$;

COMMENT ON FUNCTION public.decide_overtime_batch(uuid, text, text) IS
'OVERTIME-1:仓库整批批准或驳回(action.overtime_approve;没有 CFO 越级)。审批开关不管它:开着关着都要人按,关着时留痕多一句说明,从不 auto_approved。四眼按人认:SELF_APPROVAL_FORBIDDEN|raiser(提交人)、|subject(批里任何一个员工);R2 不覆盖加班。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_SUBMITTED · OVERTIME_DECISION_INVALID · OVERTIME_REJECT_NOTE_REQUIRED · OVERTIME_MONTH_COMPLETE · OVERTIME_NOT_SITE_STAFF(批准时再判)。批准时 day_kind 按此刻的假期表冻住。';

-- db/functions/reverse_overtime_batch.sql
-- OVERTIME-1(Tim Q10):一张批过的批错了 → 财务整批冲销(要理由),那一批的行全部作废、日期腾出来,
-- 然后录一张改对的批,重新走一遍审批。没有逐行改。
-- 【只在那个月考勤还开着时】完成之后按名拒 OVERTIME_MONTH_COMPLETE —— 那些小时已经冻进底稿了。
-- 【不写 approval_log】冲销不是一次审批决定;它记在批次行上(reversed_at / reversed_by / reverse_reason)。
--   批准那一行留痕原样留着 —— 它说的是当时真实发生过的事。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.reverse_overtime_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b  overtime_batches%ROWTYPE;
    v_n  integer;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status <> 'approved' THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_APPROVED|%|%', v_b.label, v_b.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'OVERTIME_REVERSE_REASON_REQUIRED|%', v_b.label;
    END IF;
    PERFORM overtime_assert_month_open(v_b.period_month);

    UPDATE overtime_lines SET voided_at = now() WHERE batch_id = p_batch_id AND voided_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    UPDATE overtime_batches
       SET status = 'reversed', reversed_at = now(), reversed_by = auth.uid(), reverse_reason = btrim(p_reason)
     WHERE id = p_batch_id;
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'reversed', 'lines_voided', v_n);
END;
$function$;

COMMENT ON FUNCTION public.reverse_overtime_batch(uuid, text) IS
'OVERTIME-1(Tim Q10):整批冲销一张 approved 的加班批(action.overtime_enter,要理由),它的行全部作废、日期腾出来。只在那个月考勤还开着时。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_APPROVED · OVERTIME_REVERSE_REASON_REQUIRED · OVERTIME_MONTH_COMPLETE。不写 approval_log。';

-- db/functions/discard_overtime_batch.sql
-- OVERTIME-1(2026-09-28,本刀的构建决定,交回里点名):一张不要了的批(draft / rejected)→ discarded,
-- 它的行全部作废。
-- 【为什么需要它】Tim Q8:那个月还有 draft 或 submitted(以及被驳回、等着改的)批时,考勤不许完成。
--   没有这一步,一张没人要的草稿会【永远】挡住那个月的考勤完成,进而挡住工资过账。
-- 【不删行】批次与行都留着(已作废),日期随之腾出来;approval_log 里那一批以前的提交 / 驳回照样指得到它。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.discard_overtime_batch(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b  overtime_batches%ROWTYPE;
BEGIN
    PERFORM require_permission('action.overtime_enter');
    SELECT * INTO v_b FROM overtime_batches WHERE id = p_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF v_b.status NOT IN ('draft', 'rejected') THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_NOT_EDITABLE|%|%', v_b.label, v_b.status;
    END IF;

    UPDATE overtime_lines SET voided_at = now() WHERE batch_id = p_batch_id AND voided_at IS NULL;
    UPDATE overtime_batches
       SET status = 'discarded', discarded_at = now(), discarded_by = auth.uid(),
           decided_at = NULL, decided_by = NULL
     WHERE id = p_batch_id;
    RETURN jsonb_build_object('batch_id', p_batch_id, 'label', v_b.label, 'status', 'discarded');
END;
$function$;

COMMENT ON FUNCTION public.discard_overtime_batch(uuid) IS
'OVERTIME-1:丢弃一张 draft / rejected 的加班批(action.overtime_enter),它的行全部作废。存在的理由:开着的批挡住那个月的考勤完成,一张没人要的草稿不能永远挡着。拒:OVERTIME_BATCH_NOT_FOUND · OVERTIME_BATCH_NOT_EDITABLE。';

-- db/functions/overtime_month_hours.sql
-- OVERTIME-1(Tim Q1 · Q3):屏幕上"这个月批过的加班小时"—— 考勤页的三列与工资期详情的那一列都读它。
--
-- ★【已完成的读冻下来的,还开着的读此刻的】★ 与 attendance_period_status 同一条:
--   那个月的考勤已完成 → 读 attendance_lines 上冻住的三个桶(fixed = true):我们报给服务商的就是它;
--   还开着(或还没开)→ 读 overtime_approved_hours 此刻的数(fixed = false)。
-- 【门】module.hr.view —— 读它的两页(考勤、工资)都在人力模块里。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_month_hours(p_month date)
 RETURNS TABLE(employee_id uuid, weekday_hours numeric, rest_day_hours numeric, public_holiday_hours numeric, total_hours numeric, fixed boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_m  date := date_trunc('month', p_month)::date;
BEGIN
    PERFORM require_permission('module.hr.view');
    IF EXISTS (SELECT 1 FROM attendance_periods ap WHERE ap.period_month = v_m AND ap.status = 'complete') THEN
        RETURN QUERY
        SELECT al.employee_id, al.ot_normal_hours, al.ot_rest_day_hours, al.ot_public_holiday_hours,
               al.ot_normal_hours + al.ot_rest_day_hours + al.ot_public_holiday_hours, true
          FROM attendance_lines al
          JOIN attendance_periods ap ON ap.id = al.period_id
         WHERE ap.period_month = v_m;
    ELSE
        RETURN QUERY
        SELECT o.employee_id, o.weekday_hours, o.rest_day_hours, o.public_holiday_hours,
               o.weekday_hours + o.rest_day_hours + o.public_holiday_hours, false
          FROM overtime_approved_hours(v_m) o;
    END IF;
END;
$function$;

COMMENT ON FUNCTION public.overtime_month_hours(date) IS
'OVERTIME-1:某个月每个员工批过的加班小时(三个桶 + 合计)。那个月考勤已完成 → 读 attendance_lines 冻住的数(fixed = true);否则读此刻已批准的(fixed = false)。门 module.hr.view。读者:/hr/attendance/[id] 与 /hr/payroll/[id]。';

-- db/functions/overtime_batch_lines.sql
-- OVERTIME-1(2026-09-28):一张加班批的行,带员工编号与名字。
-- 【为什么是属主权限】仓库(批的人)不持 module.hr.view,employees 的 RLS 只给他自己那一行,
--   所以 INVOKER 下名字永远是空的 —— 而他要批的正是"谁、哪天、几个小时"。本函数只替他打开
--   【这一批里那几个人的编号与显示名】,不带任何薪酬或身份信息(Tim Q13:名字、日期、小时,永不带钱)。
-- 【门】module.hr.view、action.overtime_enter、action.overtime_approve 任一 —— 与两张表的读策略同一组码。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_batch_lines(p_batch_id uuid)
 RETURNS TABLE(line_id uuid, employee_id uuid, employee_code text, employee_name text, work_date date, day_kind text, hours numeric, note text, voided boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.hr.view') OR has_permission('action.overtime_enter')
            OR has_permission('action.overtime_approve')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', 'action.overtime_approve';
    END IF;
    RETURN QUERY
    SELECT l.id, l.employee_id, e.code,
           COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name),
           l.work_date, l.day_kind, l.hours, l.note, l.voided_at IS NOT NULL
      FROM overtime_lines l
      JOIN employees e ON e.id = l.employee_id
     WHERE l.batch_id = p_batch_id
     ORDER BY l.work_date, e.code;
END;
$function$;

COMMENT ON FUNCTION public.overtime_batch_lines(uuid) IS
'OVERTIME-1:一张加班批的行(员工编号、显示名、日期、桶、小时、备注、作废否)。属主权限,因为批的人(仓库)读不到别人的员工行;只带编号与显示名,不带薪酬或身份信息。门:module.hr.view / action.overtime_enter / action.overtime_approve 任一,否则 PERMISSION_DENIED。';

-- db/functions/overtime_site_staff.sql
-- OVERTIME-1(Tim Q11 · Q17):今天标为现场员工的人(没删的)—— 录入页的员工下拉只列他们,
-- 而【一个都没有】正是录入页那个空态:建批钮按不动,旁边一行说没有人被标为现场员工、去哪里标。
-- 【属主权限】录的人(财务)本来就读得到员工;但页面的空态判断对仓库也要成立,而仓库读不到员工行。
--   只带编号、显示名、入离职日(录入页用它们挡住不在职的日期),不带任何别的。
-- 【门】与两张加班表同一组码。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.overtime_site_staff()
 RETURNS TABLE(employee_id uuid, employee_code text, employee_name text, hire_date date, separation_date date)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.hr.view') OR has_permission('action.overtime_enter')
            OR has_permission('action.overtime_approve')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', 'action.overtime_enter';
    END IF;
    RETURN QUERY
    SELECT e.id, e.code, COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name),
           e.hire_date, e.separation_date
      FROM employees e
     WHERE e.is_site_staff AND e.deleted_at IS NULL
     ORDER BY e.code;
END;
$function$;

COMMENT ON FUNCTION public.overtime_site_staff() IS
'OVERTIME-1:标为现场员工的人(employees.is_site_staff,未删)—— 录入页的下拉与它的空态都读它。属主权限,只带编号、显示名、入离职日。门:module.hr.view / action.overtime_enter / action.overtime_approve 任一,否则 PERMISSION_DENIED。';

-- db/functions/my_overtime_lines.sql
-- OVERTIME-1(Tim Q14):/me 上现场员工看见自己【已批准、没作废】的加班 —— 日期、小时、桶、备注、
-- 哪一批、谁什么时候批的。
-- 【为什么是属主权限】员工读不到批次(没有任何加班码),而"这一行批准了没有"住在批次上;
--   批的人是另一个员工,他的名字 employees 的 RLS 也不给。与 my_document_decisions 同形:
--   只替调用者打开他【自己的】那几行。没有员工档案的调用者(current_user_employee() 为 NULL)→ 0 行。
-- 【批的人显示成人】account_person(decided_by) → preferred_name,否则 legal_name。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE OR REPLACE FUNCTION public.my_overtime_lines()
 RETURNS TABLE(line_id uuid, work_date date, hours numeric, day_kind text, note text, batch_label text, approved_at timestamp with time zone, approver text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT l.id, l.work_date, l.hours, l.day_kind, l.note, b.label, b.decided_at,
           (SELECT COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name)
              FROM employees e WHERE e.id = account_person(b.decided_by))
      FROM overtime_lines l
      JOIN overtime_batches b ON b.id = l.batch_id
     WHERE l.employee_id = current_user_employee()
       AND l.voided_at IS NULL
       AND b.status = 'approved'
     ORDER BY l.work_date DESC
$function$;

COMMENT ON FUNCTION public.my_overtime_lines() IS
'OVERTIME-1(Tim Q14):调用者自己已批准、没作废的加班行(日期、小时、桶、备注、批次、批准时刻、批的人显示成人)。属主权限,只给调用者自己的;没有员工档案 → 0 行。';

-- ── 7 · 替换:考勤、留痕、在途清单(镜像原样)──────────────────────────────────

-- db/functions/record_attendance.sql
-- ATTEND-1:记一行考勤底稿(module.hr.edit)—— "这一行有人看过了" + 一句备注。
--
-- ★ OVERTIME-1(Tim Q3,2026-09-28):加班小时【不再从这里打字进来】。
--   它们只有一个来源:仓库批过的加班批(overtime_batches / overtime_lines),在那个月考勤完成时
--   由 complete_attendance_period 冻进三个桶。这里再收小时就是同一个事实的第二个入口。
--   ☞ 签名【一个字没改】—— 破窗里旧界面照旧调这支函数,传三个 0 就照旧成功;
--     传任何一个非零的小时 → 按名拒 ATTENDANCE_OT_THROUGH_OVERTIME|<员工编号>。
--   ☞ 三个桶这里【不写】:它们由完成那一步写,还开着的月份屏幕读此刻批过的数(overtime_month_hours)。

CREATE OR REPLACE FUNCTION public.record_attendance(p_line_id uuid, p_normal numeric DEFAULT 0, p_rest_day numeric DEFAULT 0, p_holiday numeric DEFAULT 0, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_l attendance_lines%ROWTYPE; v_p attendance_periods%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_l FROM attendance_lines WHERE id = p_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_LINE_NOT_FOUND|%', COALESCE(p_line_id::text, '?');
    END IF;
    SELECT * INTO v_p FROM attendance_periods WHERE id = v_l.period_id;
    IF v_p.status <> 'open' THEN
        -- 完成之后不许再改:那份底稿【就是】我们报出去的东西
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    -- ★ OVERTIME-1(Tim Q3):加班小时只经加班批进来,这里一个都不收。
    IF COALESCE(p_normal, 0) <> 0 OR COALESCE(p_rest_day, 0) <> 0 OR COALESCE(p_holiday, 0) <> 0 THEN
        RAISE EXCEPTION 'ATTENDANCE_OT_THROUGH_OVERTIME|%',
            (SELECT e.code FROM employees e WHERE e.id = v_l.employee_id);
    END IF;

    UPDATE attendance_lines
       SET note = NULLIF(btrim(COALESCE(p_note, '')), ''),
           recorded_at = now(), recorded_by = auth.uid()
     WHERE id = p_line_id;

    RETURN jsonb_build_object('line_id', p_line_id, 'recorded', true);
END;
$function$

;

-- db/functions/complete_attendance_period.sql
-- ATTEND-1:把一个月的考勤底稿标记为完成 —— 工资过账那道拒绝(PAYROLL_ATTENDANCE_NOT_COMPLETE)整个压在这句断言上。
--
-- ★ OVERTIME-1(Tim Q1 · Q3 · Q8,2026-09-28):
--   ① 那个月还有【开着的】加班批(draft / submitted / rejected)→ 按名拒 OVERTIME_BATCH_OPEN_FOR_MONTH。
--      否则一批还没批完的小时会被一份"完整"的底稿漏掉。
--   ② 三个加班桶在这一刻从【已批准、没作废】的加班行冻进来(overtime_approved_hours)——
--      这是批过的小时进工资的【唯一一次】:之后那个月的加班批建、提交、批、冲销一律拒。
--      重开再完成,会按那时批过的数重新冻一次(不是叠加)。

CREATE OR REPLACE FUNCTION public.complete_attendance_period(p_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_added int; v_missing int; v_end date; v_ot text;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'open' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_OPEN|%|%', v_p.code, v_p.status;
    END IF;
    v_end := (v_p.period_month + interval '1 month - 1 day')::date;

    -- ★ OVERTIME-1(Tim Q8):那个月还有开着的加班批 → 不许完成
    SELECT b.label || '|' || b.status INTO v_ot FROM overtime_batches b
     WHERE b.period_month = v_p.period_month AND b.status IN ('draft', 'submitted', 'rejected')
     ORDER BY b.seq LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_FOR_MONTH|%|%', v_p.code, v_ot;
    END IF;

    -- ① 【先补名单,再谈完整 —— 这是安全网,不是操作路径】月中入职的人在
    --    开期间时还不在册;不补就会出现"一份声称完整的底稿里少了一个人",
    --    而那句断言恰恰在这种时候才要紧。
    --    【但它到不了操作员手上】补完若仍有没记的行,下面那句 RAISE 会把
    --    同一条语句里刚补出来的行一起回滚掉 —— 所以能被【看见和记录】的
    --    那条路是 sync_attendance_period(页面每次打开调一次)。两者同一句
    --    SQL,故意重复:少了这里就漏得掉人,少了那里就补不进去。
    INSERT INTO attendance_lines (period_id, employee_id)
    SELECT v_p.id, e.id FROM employees e
     WHERE e.deleted_at IS NULL
       AND e.hire_date <= v_end
       AND (e.separation_date IS NULL OR e.separation_date >= v_p.period_month)
       AND NOT EXISTS (SELECT 1 FROM attendance_lines al
                        WHERE al.period_id = v_p.id AND al.employee_id = e.id);
    GET DIAGNOSTICS v_added = ROW_COUNT;

    -- ② 【还有没记的就拒,并说出还差几行】一个容得下空白的"完成"是一个勾选框,
    --    不是一句断言 —— 而工资过账那道拒绝【整个】压在这句断言上。
    SELECT count(*) INTO v_missing FROM attendance_lines
     WHERE period_id = v_p.id AND recorded_at IS NULL;
    IF v_missing > 0 THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_INCOMPLETE|%|%', v_p.code, v_missing::text;
    END IF;

    -- ③ 【冻推导值】此后请假单再被取消,这份底稿仍然说得出当时报了什么
    UPDATE attendance_lines al
       SET unpaid_days = attendance_unpaid_days(al.employee_id, v_p.period_month),
           active_from = GREATEST(e.hire_date, v_p.period_month),
           active_to   = LEAST(COALESCE(e.separation_date, v_end), v_end),
           frozen_at   = now()
      FROM employees e
     WHERE e.id = al.employee_id AND al.period_id = v_p.id;

    -- ★ OVERTIME-1(Tim Q1 · Q3):批过的加班小时冻进三个桶 —— 这是它们进工资的唯一一次。
    --   每一行都写(没有批过加班的人写 0),所以重开再完成是【重算】,不是叠加。
    UPDATE attendance_lines al
       SET ot_normal_hours         = COALESCE(o.weekday_hours, 0),
           ot_rest_day_hours       = COALESCE(o.rest_day_hours, 0),
           ot_public_holiday_hours = COALESCE(o.public_holiday_hours, 0)
      FROM attendance_lines al2
      LEFT JOIN overtime_approved_hours(v_p.period_month) o ON o.employee_id = al2.employee_id
     WHERE al2.id = al.id AND al.period_id = v_p.id;
    -- 【冻进来的总和必须等于批过的总和】一个批过加班、却不在这份底稿名单上的人(例如事后被软删)
    --   会让他的小时悄悄掉出工资 —— 那种时候按名拒,不许"完成"。
    IF (SELECT COALESCE(sum(ot_normal_hours + ot_rest_day_hours + ot_public_holiday_hours), 0)
          FROM attendance_lines WHERE period_id = v_p.id)
       <> (SELECT COALESCE(sum(weekday_hours + rest_day_hours + public_holiday_hours), 0)
             FROM overtime_approved_hours(v_p.period_month)) THEN
        RAISE EXCEPTION 'OVERTIME_HOURS_OFF_ROSTER|%', v_p.code;
    END IF;

    UPDATE attendance_periods
       SET status = 'complete', completed_at = now(), completed_by = auth.uid()
     WHERE id = p_period_id;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code,
                              'status', 'complete', 'lines_added', v_added);
END;
$function$

;

-- db/functions/attendance_period_status_rows.sql
-- CLEANUP-A(2026-08-31):attendance_period_status 的取数体,判据 module.hr.view。
-- 两个理由:① 它是 attendance_unpaid_days 的算术调用方,而 sum() 会跳过 NULL;
-- ② 视图是 security_invoker = off 且 GRANT 给 authenticated,此前这一层没有人问权限。

CREATE OR REPLACE FUNCTION public.attendance_period_status_rows()
 RETURNS TABLE(period_id uuid, code text, period_month date, status text, opened_at timestamp with time zone, completed_at timestamp with time zone, reopened_at timestamp with time zone, reopen_reason text, line_count integer, unrecorded_count integer, ot_normal_hours numeric, ot_rest_day_hours numeric, ot_public_holiday_hours numeric, unpaid_days numeric, payroll_posted boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【这一层此前【没有人】问权限,而视图注释把这件事记在"调用方"头上】
    PERFORM require_permission('module.hr.view');

    RETURN QUERY
    SELECT ap.id, ap.code, ap.period_month, ap.status,
        ap.opened_at, ap.completed_at, ap.reopened_at, ap.reopen_reason,
        count(al.id)::integer,
        count(al.id) FILTER (WHERE al.recorded_at IS NULL)::integer,
        -- ★ OVERTIME-1(Tim Q3):三个加班桶与无薪天数同一条 —— 已完成的读冻下来的,
        --   还开着的读此刻【批过】的(overtime_approved_hours;考勤底稿自己不再收小时)。
        round(COALESCE(CASE WHEN ap.status = 'complete'::text THEN sum(al.ot_normal_hours)
            ELSE (SELECT sum(o.weekday_hours) FROM overtime_approved_hours(ap.period_month) o) END, 0::numeric), 2),
        round(COALESCE(CASE WHEN ap.status = 'complete'::text THEN sum(al.ot_rest_day_hours)
            ELSE (SELECT sum(o.rest_day_hours) FROM overtime_approved_hours(ap.period_month) o) END, 0::numeric), 2),
        round(COALESCE(CASE WHEN ap.status = 'complete'::text THEN sum(al.ot_public_holiday_hours)
            ELSE (SELECT sum(o.public_holiday_hours) FROM overtime_approved_hours(ap.period_month) o) END, 0::numeric), 2),
        -- ★【已完成的读冻下来的,还开着的读此刻的】★ 两者是不同的问题,没动。
        -- 【sum() 跳过 NULL】—— 走到这里的人一定持 module.hr.view(上面那道闸),
        -- 所以 attendance_unpaid_days 不会返回 NULL,合计不会被悄悄抽走。
        round(COALESCE(sum(
            CASE
                WHEN ap.status = 'complete'::text THEN al.unpaid_days
                ELSE attendance_unpaid_days(al.employee_id, ap.period_month)
            END), 0::numeric), 2),
        (EXISTS ( SELECT 1
               FROM payroll_periods pp
              WHERE pp.deleted_at IS NULL AND pp.status = 'posted'::text
                AND date_trunc('month'::text, pp.period_month::timestamp with time zone)::date = ap.period_month))
       FROM attendance_periods ap
         LEFT JOIN attendance_lines al ON al.period_id = ap.id
      GROUP BY ap.id;
END;
$function$;

COMMENT ON FUNCTION public.attendance_period_status_rows() IS
    'CLEANUP-A:attendance_period_status 的取数体,判据 module.hr.view。两个理由,都要紧:① 它是 attendance_unpaid_days 的【算术调用方】,而 sum() 会跳过 NULL —— 没有这道闸,第三节的修复会让无权限读者的月合计把那些员工悄悄抽走(R2 点名的 PROC-COST-2 形状);② 视图是 security_invoker = off(以属主身份读、RLS 不生效)且 GRANT 给 authenticated,实测任何登录用户都读得到全公司考勤 —— 视图注释把把关记在"调用方"头上,而那是"调用方不是控制"。invoker = off 当初是对的(OPS-14 修法 (a)),错的是没有人在这一层问权限。';

CREATE OR REPLACE FUNCTION public.record_approval_decision(p_subject_type text, p_subject_id uuid, p_decision text, p_level smallint DEFAULT NULL::smallint, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_ccy  text;
    v_amt  numeric;
    v_rate numeric;
    v_base numeric;
    v_ok   boolean := false;
    v_id   uuid;
    v_base_ccy text;
    -- APR-ROUTE-1(R2):这一张单据的提单人与主角,为了 self_decided
    v_raiser   uuid;
    v_subject  uuid;
    v_self     boolean := false;
BEGIN
    SELECT code INTO v_base_ccy FROM currencies WHERE is_base;

    -- 【外键没了,这一段就是它的替代】主体必须真的存在,并且顺手把编号与金额
    -- 冻结下来。不存在 → 点名拒绝,而不是插一行指向空气的留痕。
    CASE p_subject_type
        WHEN 'leave_request' THEN
            -- 请假没有金额:天数不是钱,不塞进币种列
            SELECT true, r.code, r.created_by, r.employee_id INTO v_ok, v_code, v_raiser, v_subject
              FROM leave_requests r WHERE r.id = p_subject_id;
        WHEN 'medical_claim' THEN
            -- amount_sgd 已经是本位币口径(列名是 FIN-0 之前留下的字面量,不是新的判断)
            SELECT true, c.code, c.amount_sgd, v_base_ccy, 1, c.amount_sgd, c.created_by, c.employee_id
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser, v_subject
              FROM medical_claims c WHERE c.id = p_subject_id;
        WHEN 'performance_review' THEN
            SELECT true, e.code, r.submitted_by, r.employee_id INTO v_ok, v_code, v_raiser, v_subject
              FROM performance_reviews r JOIN employees e ON e.id = r.employee_id
             WHERE r.id = p_subject_id;
        WHEN 'purchase_order' THEN
            -- 【用单据自己存的汇率】(决定 3)—— 审批档次因此不会随行情事后漂移
            SELECT true, po.code, po.estimated_total_ccy, po.currency, po.fx_rate,
                   round(po.estimated_total_ccy * po.fx_rate, 2), po.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM purchase_orders po WHERE po.id = p_subject_id;
        WHEN 'payment' THEN
            SELECT true, p.code, p.amount_ccy, p.currency, p.fx_rate, p.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM payments p WHERE p.id = p_subject_id;
        -- ★ PAY-REQ-1:付款申请。提单人 = created_by;主角 = 收款员工(付给供应商时 NULL)。
        --   金额冻结的是【申请上】那一组(审批人批的就是它);本位币额是提交时的试算值。
        WHEN 'payment_request' THEN
            SELECT true, r.code, r.amount_ccy, r.currency,
                   CASE WHEN r.amount_ccy > 0 THEN r.amount_base / r.amount_ccy END,
                   r.amount_base, r.created_by, r.employee_id
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser, v_subject
              FROM payment_requests r WHERE r.id = p_subject_id;
        -- ★ PAYROLL-APR-1:工资过账 / 撤销申请。提单人 = created_by;主角 = NULL ——
        --   工资期是公司的单据(Tim 的 Q1 (A)),主角那条腿对谁都不成立,所以 self_decided
        --   只会因为"提单人按下去"而为 true,而那条路 forbid_self_approval 已经拒了。
        --   金额冻结的是申请上那一组:gross_total、期间币种、期间汇率、折本位币(N4)。
        --   编号:申请没有自己的单据编号,记它的 label(期间编号 · 种类 · 第几次)。
        WHEN 'payroll_request' THEN
            SELECT true, r.label, r.gross_total, r.currency, r.fx_rate, r.amount_base, r.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM payroll_requests r WHERE r.id = p_subject_id;
        -- ★ ROLE-1 Batch 4b:收货定价申请。提单人 = created_by;主角 = NULL(收货不是谁"自己的单据")。
        --   金额 = |Δ 应付| 本位币(Tim 的 Q8),所以币种 = 本位币、汇率 = 1(medical_claim 同形)。
        --   amount_base 是【最近一次估算】:submitted 那一行按提交日的牌价,approved 那一行按
        --   批准日的牌价 = 实际过账额(Tim 的 Q4:每一行留痕按它自己那天的牌价)。
        --   编号:申请没有自己的单据编号,记它的 label(收货编号 · price #n)。
        WHEN 'receipt_price_request' THEN
            SELECT true, r.label, r.amount_base, v_base_ccy, 1, r.amount_base, r.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM receipt_price_requests r WHERE r.id = p_subject_id;
        -- ★ APR-5a:贷项 / 作废申请。提单人 = created_by;主角 = NULL(发票不是谁"自己的单据")。
        --   金额 = 本位币(贷项 = 分录借方合计;作废 = 发票 total_base),币种 = 本位币、汇率 = 1
        --   (receipt_price_request 同形)。submitted 那一行是提交时的试跑额,approved 那一行 = 实际过账额。
        --   编号:申请没有自己的单据编号,记它的 label(发票编号 · credit note #n / void #n)。
        WHEN 'invoice_request' THEN
            SELECT true, r.label, r.amount_base, v_base_ccy, 1, r.amount_base, r.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM invoice_requests r WHERE r.id = p_subject_id;
        -- ★ APR-5b:发货放行。提单人 = created_by;主角 = NULL(订单不是谁"自己的单据")。
        --   金额 = 点名发票行 amount_base 之和(本位币),币种 = 本位币、汇率 = 1(invoice_request 同形)。
        --   编号:放行没有自己的单据编号,记它的 label(订单编号 · release #n)。
        WHEN 'shipping_release' THEN
            SELECT true, r.label, r.amount_base, v_base_ccy, 1, r.amount_base, r.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM shipping_releases r WHERE r.id = p_subject_id;
        -- ★ APR-6:手工凭证 / 冲销申请。提单人 = created_by;主角 = NULL(一张手工凭证不是谁"自己的单据")。
        --   金额 = 过出来那张分录的借方合计(本位币),币种 = 本位币、汇率 = 1(invoice_request 同形)。
        --   submitted 那一行是提交时的试跑额,approved 那一行 = 实际过账额(N1 对 journal_entries 退休,Q2)。
        --   编号:申请没有自己的单据编号,记它的 label(manual journal #n / 分录编号 · reversal #n)。
        WHEN 'journal_request' THEN
            SELECT true, r.label, r.amount_base, v_base_ccy, 1, r.amount_base, r.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM journal_requests r WHERE r.id = p_subject_id;
        -- ★ APR-7:仓库申请(注销 · 回滚 · 证书作废)。提单人 = created_by;主角 = NULL(批次不是谁"自己的单据")。
        --   金额 = 生效时过出来那几张分录的借方合计(本位币),币种 = 本位币、汇率 = 1(journal_request 同形);
        --   没有计价的注销与证书作废是 0。submitted 那一行是提交时的试跑额,approved 那一行 = 实际过账额。
        --   编号:申请没有自己的单据编号,记它的 label(批号 / 单号 / 证书号 · write-off / rollback / void #n)。
        WHEN 'warehouse_request' THEN
            SELECT true, r.label, r.amount_base, v_base_ccy, 1, r.amount_base, r.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM warehouse_requests r WHERE r.id = p_subject_id;
        -- ★ APR-8:条款申请(公式新建 / 修改 / 重新启用 · 合同生效)。提单人 = created_by;主角 = NULL。
        --   【没有金额】—— 批的是条款,不是一笔钱(work_order 同形:只冻结编号,四列留空,不塞 0)。
        --   编号:申请没有自己的单据编号,记它的 label(公式 / 合同编号 · new / change / reactivate / activate #n)。
        WHEN 'terms_request' THEN
            SELECT true, r.label, r.created_by INTO v_ok, v_code, v_raiser
              FROM terms_requests r WHERE r.id = p_subject_id;
        -- ★ APR-9:调薪申请。提单人 = created_by;主角 = 被调薪的员工(self_decided 要问这两条腿)。
        --   【没有金额】—— 月薪是 PDPA 受限的个人数据,留痕的读者不一定看得见工资(performance_review 同形:
        --   只冻结编号,四列留空)。编号:申请的 label(员工编号 · salary change #n)。
        WHEN 'salary_change_request' THEN
            SELECT true, r.label, r.created_by, r.employee_id INTO v_ok, v_code, v_raiser, v_subject
              FROM salary_change_requests r WHERE r.id = p_subject_id;
        -- ★ APR-9:处置申请。提单人 = created_by;主角 = NULL(资产是公司的)。
        --   金额 = 处置分录的借方合计(本位币),币种 = 本位币、汇率 = 1(warehouse_request 同形);
        --   submitted 那一行是提交时的试跑额,approved 那一行 = 实际过账额。编号:label(资产编号 · disposal #n)。
        WHEN 'asset_disposal_request' THEN
            SELECT true, r.label, r.amount_base, v_base_ccy, 1, r.amount_base, r.created_by
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser
              FROM asset_disposal_requests r WHERE r.id = p_subject_id;
        -- ★ APR-10:GST 申报申请。提单人 = created_by;主角 = NULL(申报是公司的)。
        --   【没有金额】—— 批的是一组申报数,不是一笔钱(terms_request 同形:只冻结编号,四列留空,不塞 0)。
        --   编号:申请的 label(期间编号 · filing #n)。
        WHEN 'gst_filing_request' THEN
            SELECT true, r.label, r.created_by INTO v_ok, v_code, v_raiser
              FROM gst_filing_requests r WHERE r.id = p_subject_id;
        WHEN 'expense' THEN
            SELECT true, e.code, e.amount_ccy, e.currency, e.fx_rate, e.amount_base
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base
              FROM expenses e WHERE e.id = p_subject_id;
        WHEN 'expense_claim' THEN
            -- ★ APR-3:报销单。expense_claims 上【没有 fx_rate,也没有 amount_base】,
            -- 所以这四列要算 —— 而算它的判据只有一份(expense_claim_amount_base),
            -- 与 decide_expense_claim 分档、approval_pending_documents 列在途读的是
            -- 同一支。三处各算一遍就是三份会漂开的数,而"屏幕上说的档次"与"真正
            -- 拦人的那一档"漂开,是一句关于内控的假话。
            -- 【牌价查不到时四列一起留空,而不是塞一个数进去】approval_log 的
            -- amount_shape 约束要的就是"全有或全无";留空的意思是【这一张当时
            -- 分不了档】,而那是真的。要按名拒的那一支是 decide_expense_claim。
            SELECT true, c.code, b.amount_ccy, b.currency, b.fx_rate, b.amount_base,
                   c.created_by, c.employee_id
              INTO v_ok, v_code, v_amt, v_ccy, v_rate, v_base, v_raiser, v_subject
              FROM expense_claims c
              LEFT JOIN LATERAL expense_claim_amount_base(c.id) b ON true
             WHERE c.id = p_subject_id;
            IF v_rate IS NULL THEN
                v_amt := NULL; v_ccy := NULL; v_base := NULL;
            END IF;
        WHEN 'pricing_formula' THEN
            SELECT true, f.code INTO v_ok, v_code
              FROM pricing_formulas f WHERE f.id = p_subject_id;
        WHEN 'stocktake' THEN
            SELECT true, s.code, s.created_by INTO v_ok, v_code, v_raiser
              FROM stocktakes s WHERE s.id = p_subject_id;
        WHEN 'work_order' THEN
            -- WO-1b:工单【没有金额】—— 它是一份要做什么的计划,不是一笔钱。
            -- 与 leave_request / performance_review / stocktake 同一类:
            -- 只冻结编号,金额那四列留空,而不是塞一个 0 进去
            -- (0 会让它在按金额筛的报表里排到最前面,那是一句假话)。
            SELECT true, w.code, w.created_by INTO v_ok, v_code, v_raiser
              FROM work_orders w WHERE w.id = p_subject_id;
        -- ★ OVERTIME-1:加班月批次。提单人 = submitted_by(交的人,不是开的人 —— 驳回后可能换人再交);
        --   主角 = NULL:一批说的是好几个员工,那条腿在 decide_overtime_batch 里逐个员工问过了。
        --   【没有金额】—— OS 只报小时,不报钱(政策 7.1);只冻结 label,四列留空。
        WHEN 'overtime_batch' THEN
            SELECT true, b.label, b.submitted_by INTO v_ok, v_code, v_raiser
              FROM overtime_batches b WHERE b.id = p_subject_id;
        WHEN 'supplier' THEN
            -- ROLE-1 Batch 2a(Q3 / Q9):供应商的送审、批准、驳回。没有金额 —— 批的是
            -- "可以跟这一家做生意",不是一笔钱;提单人 = 建档人(created_by)。
            SELECT true, s.code, s.created_by INTO v_ok, v_code, v_raiser
              FROM suppliers s WHERE s.id = p_subject_id;
        ELSE
            RAISE EXCEPTION 'APPROVAL_SUBJECT_TYPE_UNKNOWN|%', p_subject_type;
    END CASE;

    IF NOT COALESCE(v_ok, false) THEN
        RAISE EXCEPTION 'APPROVAL_SUBJECT_NOT_FOUND|%|%', p_subject_type, p_subject_id;
    END IF;

    -- ════════════════════════════════════════════════════════════════════
    -- ★★ APR-ROUTE-1(Tim 的 R2 · Q2):self_decided 记的是【事实】,不是【规则】 ★★
    -- ════════════════════════════════════════════════════════════════════
    -- 它问的是"按下去的这个人,是不是这张单的提单人或主角(按人认)",
    -- 而【不】问"例外成不成立"。两者今天算出同一个答案 —— 因为 forbid_self_approval
    -- 只在例外成立时才让"自己"走到这里。
    -- ★ 分开写的理由:哪一天另一条路径让一次自批漏了过来,这一格照样是 true,
    --   而 approval_log_self_decided_scope 那条 CHECK 会在【这一行 INSERT】上
    --   当场拒绝 —— 漏洞变成一次响亮的失败,而不是一行看起来正常的留痕。
    -- 【只看 approved / rejected】auto_approved 是"没有人按过任何东西"
    --   (create_purchase_order 在审批关着时由提单人自己的会话写),
    --   approval_voided 是系统作废 —— 两者都不是一次决定,不该被问"是不是自批"。
    IF p_decision IN ('approved', 'rejected') THEN
        v_self := self_leg(v_raiser, v_subject, auth.uid()) <> 'none';
    END IF;

    INSERT INTO approval_log (subject_type, subject_id, subject_code, decision, level,
                              actor_user_id, note, amount_ccy, currency, fx_rate, amount_base,
                              self_decided)
    VALUES (p_subject_type, p_subject_id, v_code, p_decision, p_level,
            auth.uid(), p_note, v_amt, v_ccy, v_rate, v_base,
            v_self)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$function$

;

-- db/functions/approval_pending_documents.sql
-- APR-3(2026-09-22):★【哪些单据正在等人批】—— 一份判据,三个读它的人★
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【Tim 的 Q6 裁定,以及它为什么不是"把那个数放宽一点"】
-- ════════════════════════════════════════════════════════════════════════════
-- APR-2 之前,"在途张数"这个数【只数采购单】,而且它同时干两件事:
--   (a) 印在 /settings/approvals 上给人看;
--   (b) 喂 can_disable,并由 guard_approvals_switch 另外数【一遍】来按名拒。
-- APR-3 要把 (a) 放宽到每一条接上引擎的链。★ 而把 (b) 一起放宽会当场出事:
-- 线上今天有一张 submitted 的报销单(CLM-2026-0004),于是审批【一提交就再也
-- 关不掉】—— 一个没有人要求过的、永久的新约束。
--
-- ★★ 两个数长得一样,问的不是同一件事:
--     (a) 问「有多少单据在等人批」        —— 每一条链都该被数进去
--     (b) 问「关掉审批会让哪些单据批不动」 —— 只有一部分链会
--   ☞ 判别的那一句话,写下来给下一刀用:
--     **这条链的决定函数,在审批【关着】的时候还跑不跑得动?**
--       · 跑不动 → 这条链的在途单据 blocks_disable = true
--         (采购单:approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED,
--          而那张单是审批开着时才会生成 pending 的 —— 关掉就没人能推动它)
--       · 跑得动 → false
--         (报销单:submitted 是【员工交了一张单】,与审批开关无关;
--          decide_expense_claim 开着关着都做得了决定,只有【分档】那一步是
--          条件性的。所以关掉审批不会搁死它,只会让它不再分档。)
--
-- ★【盘点【不在】本表里】Tim 的 Q4 裁定:open 的意思是"正在点",不是"在等人批"。
--   盘点没有 open 与 posted 之间那一格。把 5 张 open 数成在途,会让屏幕说出
--   一句假话,并且(如果 (b) 也数它)把审批锁死在开着的状态。
-- ★【工单也不在】它没有"等人批"的队列:draft 是还没写完,release 就是决定本身。
--
-- 【为什么返回逐行,而不是几个计数】三个调用方要的东西不一样:
--   · approvals_readiness  要逐链的计数(屏幕上分开显示)
--   · guard_approvals_switch 的关闭那一支 要单据【编号】(拒绝要点名)
--   · APPROVALS_POLICY_WOULD_STRAND 要每一张单的【金额】(它要拿新门槛重新分档)
--   返回计数就答不了后两个,于是又会多出两份判据 —— 这正是 real_role_holders
--   当年返回集合而不是计数的同一条理由,逐字。
--
-- 【amount_base 可以是 NULL,而 NULL 不读成零】报销单的本位币金额要查牌价
--   (expense_claim_amount_base),查不到就是 NULL = 【这一张分不了档】。
--   ☞ 读到 NULL 的人该怎么办,由读它的人裁:APPROVALS_POLICY_WOULD_STRAND
--     按 Tim 的 N4(「不明金额的安全方向是往上」)把它当二级判。
--
-- 【为什么是 SECURITY DEFINER】它横跨采购与财务两个模块的表,而它的三个调用方
--   里两个是【属主身份跑的触发器】(属主没有 claims,加一道门会在每一次写策略的
--   路上抛权限错),第三个 approvals_readiness 自己开头就查 action.manage_permissions。
--   EXECUTE 已从 authenticated 收回(db/views/zzz_function_grants.sql)——
--   与 real_role_holders / approval_gate_intersections 逐字同源同理由。
--
-- ★ APR-ROUTE-1(2026-09-23,R4):多了两列 raiser_user_id / subject_employee_id。
--   APPROVALS_POLICY_WOULD_STRAND 从此问的是"【这一张】除了它自己的提单人与主角,
--   还有没有人批得动"(approval_deciders),所以它要知道每一张的双方是谁 ——
--   而"在途单据是哪些"仍然只有这一份定义,不另起一支去查双方。
--   ☞ 返回类型变了,所以迁移里是 DROP + CREATE(两个调用方都是 plpgsql,按名调用)。
--   采购单没有"主角"(它不说任何一名员工),那一列是 NULL,不是"不知道"。
-- ★ PAY-REQ-1(2026-09-23):多了一列 fixed_level —— 一条【不按金额分档】的链在这里说出
--   它的那一级(付款申请恒为 2),其余链为 NULL(照旧按金额分)。返回类型又变了,
--   迁移里仍是 DROP + CREATE;两个 plpgsql 调用方按列名读,不受影响。
-- NOTE: introduced by db/migrations/2026-09-22-apr3-the-claim-the-count-and-the-edit-that-strands.sql.

CREATE OR REPLACE FUNCTION public.approval_pending_documents()
 RETURNS TABLE(subject_type text, doc_id uuid, code text, amount_base numeric, blocks_disable boolean, raiser_user_id uuid, subject_employee_id uuid, fixed_level smallint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 采购单:审批开着时才生成 pending,而 approve_purchase_order 在审批关着时
    -- 按名拒(APPROVALS_NOT_ENABLED)—— 关掉审批,这些单据就没有人推得动。
    SELECT 'purchase_order'::text, po.id, po.code,
           round(po.estimated_total_ccy * po.fx_rate, 2),
           true,
           po.created_by, NULL::uuid, NULL::smallint
      FROM purchase_orders po
     WHERE po.approval_status = 'pending' AND po.deleted_at IS NULL
    UNION ALL
    -- 报销单:submitted 是员工交了一张单,与审批开关无关;decide_expense_claim
    -- 开着关着都做得了决定(只有分档那一步是条件性的)。所以它【不】挡关闭。
    SELECT 'expense_claim'::text, c.id, c.code, b.amount_base, false,
           c.created_by, c.employee_id, NULL::smallint
      FROM expense_claims c
      LEFT JOIN LATERAL expense_claim_amount_base(c.id) b ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- ★ PAY-REQ-1:付款申请。blocks_disable = true —— decide_payment_request 在审批
    --   关着时按名拒(APPROVALS_NOT_ENABLED),与采购单同一个答案(Tim 的 Q7)。
    --   fixed_level = 2:这条链不按金额分档,CFO 批每一张。WOULD_STRAND 读它,
    --   而不是拿金额去重新分档 —— 否则一张小额申请会被分到一级,一级没有这条链的
    --   名册行,于是那一格什么都不判就放过去。
    --   主角 = 收款员工(付给员工时);付给供应商时为 NULL。
    SELECT 'payment_request'::text, r.id, r.code, r.amount_base, true,
           r.created_by, r.employee_id, 2::smallint
      FROM payment_requests r
     WHERE r.status = 'submitted'
    UNION ALL
    -- ★ PAYROLL-APR-1:工资过账 / 撤销申请。blocks_disable = true —— decide_payroll_request 在
    --   审批关着时按名拒(APPROVALS_NOT_ENABLED),关掉审批就搁死它们(Tim 的 Q8)。
    --   fixed_level = 2:CFO 批每一张、不分档,WOULD_STRAND 读它而不按金额重分。
    --   主角 = NULL:工资期是公司的单据(Tim 的 Q1 (A))。金额 = gross 折本位币(N4)。
    SELECT 'payroll_request'::text, q.id, q.label, q.amount_base, true,
           q.created_by, NULL::uuid, 2::smallint
      FROM payroll_requests q
     WHERE q.status = 'submitted'
    UNION ALL
    -- ★ ROLE-1 Batch 4b:收货定价申请。blocks_disable = true —— 批准它的那一支在审批关着时按名拒
    --   (APPROVALS_NOT_ENABLED),关掉审批就搁死它们(Tim 的 Q8)。fixed_level = 2:CFO 批每一张、
    --   不分档。主角 = NULL:收货不是谁"自己的单据"。金额 = |Δ 应付| 本位币,最近一次估算(Q4)。
    SELECT 'receipt_price_request'::text, rq.id, rq.label, rq.amount_base, true,
           rq.created_by, NULL::uuid, 2::smallint
      FROM receipt_price_requests rq
     WHERE rq.status = 'submitted'
    UNION ALL
    -- ★ APR-5a:贷项 / 作废申请。blocks_disable = true —— 批准它的那一支在审批关着时按名拒
    --   (APPROVALS_NOT_ENABLED),关掉审批就搁死它们。fixed_level = 2:CFO 批每一张、不分档。
    --   主角 = NULL:发票不是谁"自己的单据"。金额 = 本位币,提交时的试跑额。
    SELECT 'invoice_request'::text, iq.id, iq.label, iq.amount_base, true,
           iq.created_by, NULL::uuid, 2::smallint
      FROM invoice_requests iq
     WHERE iq.status = 'submitted'
    UNION ALL
    -- ★ APR-5b:发货放行。blocks_disable = true —— decide_shipping_release 在审批关着时按名拒
    --   (APPROVALS_NOT_ENABLED),关掉审批就搁死它们(Q13)。fixed_level = 2:CFO 批每一张、不分档。
    --   主角 = NULL:订单不是谁"自己的单据"。金额 = 点名发票行 amount_base 之和(本位币)。
    SELECT 'shipping_release'::text, sr.id, sr.label, sr.amount_base, true,
           sr.created_by, NULL::uuid, 2::smallint
      FROM shipping_releases sr
     WHERE sr.status = 'submitted'
    UNION ALL
    -- ★ APR-6:手工凭证 / 冲销申请。blocks_disable = true —— decide_journal_request 在审批关着时按名拒
    --   (APPROVALS_NOT_ENABLED),关掉审批就搁死它们(grilling Q8)。fixed_level = 2:CFO 批每一张、不分档。
    --   主角 = NULL:一张手工凭证不是谁"自己的单据"。金额 = 借方合计(本位币),提交时的试跑额。
    SELECT 'journal_request'::text, jq.id, jq.label, jq.amount_base, true,
           jq.created_by, NULL::uuid, 2::smallint
      FROM journal_requests jq
     WHERE jq.status = 'submitted'
    UNION ALL
    -- ★ APR-7:仓库申请(注销 · 回滚 · 证书作废)。blocks_disable = true —— decide_warehouse_request 在
    --   审批关着时按名拒(APPROVALS_NOT_ENABLED),关掉审批就搁死它们(grilling Q8)。fixed_level = 2:CFO 批
    --   每一张、不分档。主角 = NULL:批次不是谁"自己的单据"。金额 = 生效时过账额(本位币),提交时的试跑额。
    SELECT 'warehouse_request'::text, wq.id, wq.label, wq.amount_base, true,
           wq.created_by, NULL::uuid, 2::smallint
      FROM warehouse_requests wq
     WHERE wq.status = 'submitted'
    UNION ALL
    -- ★ APR-8:条款申请(公式新建 / 修改 / 重新启用 · 合同生效)。blocks_disable = true —— decide_terms_request 在
    --   审批关着时按名拒(APPROVALS_NOT_ENABLED),关掉审批就搁死它们(grilling Q9)。fixed_level = 2:CFO 批
    --   每一张、不分档。主角 = NULL:公式与合同不是谁"自己的单据"。金额 = NULL —— 批的是条款,不是一笔钱。
    SELECT 'terms_request'::text, tq.id, tq.label, NULL::numeric, true,
           tq.created_by, NULL::uuid, 2::smallint
      FROM terms_requests tq
     WHERE tq.status = 'submitted'
    UNION ALL
    -- ★ APR-9:处置申请。blocks_disable = true —— decide_asset_disposal_request 在审批关着时按名拒
    --   (APPROVALS_NOT_ENABLED),关掉审批就搁死它们(grilling Q10,APR-7 同形)。fixed_level = 2:CFO 批每一张、
    --   不分档。主角 = NULL:资产是公司的。金额 = 处置分录借方合计(本位币),提交时的试跑额。
    SELECT 'asset_disposal_request'::text, dq.id, dq.label, dq.amount_base, true,
           dq.created_by, NULL::uuid, 2::smallint
      FROM asset_disposal_requests dq
     WHERE dq.status = 'submitted'
    UNION ALL
    -- ★ APR-10:GST 申报申请。blocks_disable = true —— decide_gst_filing_request 在审批关着时按名拒
    --   (APPROVALS_NOT_ENABLED),关掉审批就搁死它们(grilling Q4,APR-9 处置同形)。fixed_level = 2:CFO 批
    --   每一张、不分档。主角 = NULL:申报是公司的。金额 = NULL —— 批的是一组申报数,不是一笔钱(box 8 可以是负的)。
    SELECT 'gst_filing_request'::text, gq.id, gq.label, NULL::numeric, true,
           gq.created_by, NULL::uuid, 2::smallint
      FROM gst_filing_requests gq
     WHERE gq.status = 'submitted'
    UNION ALL
    -- ★ APR-9:调薪申请。blocks_disable = **false** —— decide_salary_change_request 在审批关着时【照样】批得了
    --   (grilling Q3:这条链不看开关,永远等人批),所以它不挡关闭,与报销单同一个答案。
    --   fixed_level = NULL、金额 = NULL:它不按级、也不按金额路由 —— 按【人】(pay_decision_code),不在
    --   approval_chain_gates 里(Q2)。WOULD_STRAND 在名册里找不到它的行,于是不判它;"谁批得动"由
    --   salary_change_deciders 答(提交时与迁移自证)。月薪数是 PDPA 受限的个人数据,不进这张列表。
    --   主角 = 被调薪的员工。
    SELECT 'salary_change_request'::text, sq.id, sq.label, NULL::numeric, false,
           sq.created_by, sq.employee_id, NULL::smallint
      FROM salary_change_requests sq
     WHERE sq.status = 'submitted'
    UNION ALL
    SELECT 'overtime_batch'::text, ob.id, ob.label, NULL::numeric, false,
           ob.submitted_by, NULL::uuid, NULL::smallint
      FROM overtime_batches ob
     WHERE ob.status = 'submitted'
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废 · 手工凭证 · 仓库(注销 / 回滚 / 证书作废)· 条款(公式 / 合同生效)· 资产处置 · GST 申报九种申请与发货放行 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ APR-9 的调薪申请 false、fixed_level NULL、金额 NULL:它不看审批开关,按人路由(pay_decision_code),不在 approval_chain_gates 里。★ OVERTIME-1 的加班批 false、fixed_level NULL、金额 NULL、主角 NULL:它不看审批开关(仓库永远要人按),门是它自己的 action.overtime_approve,不在 approval_chain_gates 里;一批说的是好几个员工,主角那条腿由 decide_overtime_batch 逐个问。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

-- ── 7b · 新函数的权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──
REVOKE EXECUTE ON FUNCTION public.create_overtime_batch(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_overtime_batch(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.add_overtime_line(uuid, uuid, date, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_overtime_line(uuid, uuid, date, numeric, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.delete_overtime_line(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_overtime_line(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.submit_overtime_batch(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_overtime_batch(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.withdraw_overtime_batch(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_overtime_batch(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.decide_overtime_batch(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_overtime_batch(uuid, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reverse_overtime_batch(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_overtime_batch(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.discard_overtime_batch(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.discard_overtime_batch(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_month_hours(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overtime_month_hours(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_batch_lines(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overtime_batch_lines(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_site_staff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overtime_site_staff() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.my_overtime_lines() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_overtime_lines() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_approved_hours(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overtime_approved_hours(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_assert_month_open(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overtime_assert_month_open(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_day_kind(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.overtime_day_kind(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.overtime_approved_hours(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_assert_month_open(date) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.overtime_other_approver_exists(uuid, uuid[]) FROM authenticated;

-- ── 8 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.ot1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE ot1_pending_after ON COMMIT DROP AS
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
    -- ① 授权只多了那四行(两个码 × 各自的角色 + admin),一行没少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM ot1_grants_before
         EXCEPT SELECT role_code || ':' || c FROM (SELECT 'finance'::text, 'action.overtime_enter'::text UNION ALL SELECT 'admin'::text, 'action.overtime_enter'::text UNION ALL SELECT 'warehouse'::text, 'action.overtime_approve'::text UNION ALL SELECT 'admin'::text, 'action.overtime_approve'::text) e(role_code, c))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM ot1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'OT1_PROOF|unexpected grant change: %', v_bad; END IF;
    SELECT string_agg(role_code || ':' || c, ', ') INTO v_bad FROM (SELECT 'finance'::text, 'action.overtime_enter'::text UNION ALL SELECT 'admin'::text, 'action.overtime_enter'::text UNION ALL SELECT 'warehouse'::text, 'action.overtime_approve'::text UNION ALL SELECT 'admin'::text, 'action.overtime_approve'::text) e(role_code, c)
     WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                        WHERE r.code = e.role_code AND rp.permission_code = e.c);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'OT1_PROOF|missing grant: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'OT1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、考勤、自助单据、员工一行没变
    IF EXISTS ((SELECT b.k, b.id FROM ot1_pending_before b EXCEPT SELECT a.k, a.id FROM ot1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM ot1_pending_after a EXCEPT SELECT b.k, b.id FROM ot1_pending_before b)) THEN
        RAISE EXCEPTION 'OT1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM ot1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
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
        RAISE EXCEPTION 'OT1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM ot1_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
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

    -- ④ 没有一个员工被标(Tim:迁移一个人都不标);两张新表是空的
    SELECT count(*) INTO v_n FROM employees WHERE is_site_staff;
    IF v_n <> 0 THEN RAISE EXCEPTION 'OT1_PROOF|% employee(s) flagged as site staff', v_n; END IF;
    IF EXISTS (SELECT 1 FROM overtime_batches) OR EXISTS (SELECT 1 FROM overtime_lines) THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime tables are not empty';
    END IF;

    -- ⑤ 形状:新函数 DEFINER、authenticated 调得到、anon 调不到;三支内层 authenticated 调不到
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.create_overtime_batch(date)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.create_overtime_batch(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.create_overtime_batch(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|create_overtime_batch: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.add_overtime_line(uuid, uuid, date, numeric, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.add_overtime_line(uuid, uuid, date, numeric, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.add_overtime_line(uuid, uuid, date, numeric, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|add_overtime_line: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.delete_overtime_line(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.delete_overtime_line(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.delete_overtime_line(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|delete_overtime_line: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.submit_overtime_batch(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.submit_overtime_batch(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.submit_overtime_batch(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|submit_overtime_batch: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.withdraw_overtime_batch(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.withdraw_overtime_batch(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.withdraw_overtime_batch(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|withdraw_overtime_batch: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.decide_overtime_batch(uuid, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.decide_overtime_batch(uuid, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.decide_overtime_batch(uuid, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|decide_overtime_batch: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.reverse_overtime_batch(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.reverse_overtime_batch(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.reverse_overtime_batch(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|reverse_overtime_batch: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.discard_overtime_batch(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.discard_overtime_batch(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.discard_overtime_batch(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|discard_overtime_batch: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.overtime_month_hours(date)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.overtime_month_hours(date)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.overtime_month_hours(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime_month_hours: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.overtime_batch_lines(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.overtime_batch_lines(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.overtime_batch_lines(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime_batch_lines: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.overtime_site_staff()'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.overtime_site_staff()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.overtime_site_staff()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime_site_staff: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.my_overtime_lines()'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.my_overtime_lines()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.my_overtime_lines()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|my_overtime_lines: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.overtime_approved_hours(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime_approved_hours must not be executable by authenticated';
    END IF;
    IF has_function_privilege('authenticated', 'public.overtime_assert_month_open(date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime_assert_month_open must not be executable by authenticated';
    END IF;
    IF has_function_privilege('authenticated', 'public.overtime_other_approver_exists(uuid, uuid[])'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime_other_approver_exists must not be executable by authenticated';
    END IF;
    -- 遮蔽表加列的两半:列授权 + employees_masked(colgrant 的判据)
    IF NOT has_column_privilege('authenticated', 'public.employees', 'is_site_staff', 'SELECT') THEN
        RAISE EXCEPTION 'OT1_PROOF|employees.is_site_staff is not SELECT-granted';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees_masked'::regclass
                    AND attname = 'is_site_staff' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'OT1_PROOF|employees_masked lacks is_site_staff';
    END IF;
    -- record_attendance 签名没变(破窗里旧界面照旧调得通)
    IF to_regprocedure('public.record_attendance(uuid, numeric, numeric, numeric, text)') IS NULL THEN
        RAISE EXCEPTION 'OT1_PROOF|record_attendance signature changed';
    END IF;
    -- 没有 JWT 的读者(本迁移自己,postgres)读 my_overtime_lines():0 行
    SELECT count(*) INTO v_n FROM my_overtime_lines();
    IF v_n <> 0 THEN RAISE EXCEPTION 'OT1_PROOF|my_overtime_lines gave % row(s) to a caller with no employee record', v_n; END IF;

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.ot1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'OT1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.ot1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'OT1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.ot1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.ot1_pending_decider_check(boolean);

COMMIT;

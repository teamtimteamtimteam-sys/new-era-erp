-- db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql
-- APR-9 —— 调薪与固定资产处置:批准之前什么都不生效
-- (docs/role-matrix.md「调薪 | 只经绩效评估或调薪申请 | CFO」·「处置 | 财务 | CFO」)。
-- 由 db/scripts/build_apr9_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-9 grilling Q1–Q10,Tim 2026-09-27 全部接受)
--   ① 绩效评估的侧门(Q1):Step 0 以 sandra@ 在回滚的事务里实测 —— cco 直连插一张 submitted_by = CFO 的已提交评估、
--      自己批掉,别人的月薪就改了。守卫 guard_performance_review_write:直连只许建草稿;生命周期列只经函数;
--      提交之后调薪两列、转正结论、被评估人冻结。评估只改已有的月薪(SALARY_NOT_SET_USE_INITIAL)。
--   ② 调薪申请(Q2–Q6):salary_change_requests。财务提(module.hr.edit + data.view_pay,不许给自己提);
--      CFO 批,CFO 这个人是当事人时 cco 批 —— pay_decision_code 一份判据,review_approval_code 委托给它;
--      不看审批开关,永远等人批;生效日提交与批准各判一次;一个人一次在途调薪(跨评估);fingerprint 再比。
--      不进 approval_chain_gates(按人路由);进 approval_pending_documents(blocks_disable = false)。
--   ③ 处置申请(Q7–Q10):asset_disposal_requests,APR-7 的形状。财务提,CFO 批每一张;处置日 = 批准日,
--      按那一刻的活数过账;收款与银行科目提交时冻结;在等的时候卡上的价值列冻结(guard_asset_disposal_freeze);
--      dispose_fixed_asset 只会按名拒(ASSET_DISPOSAL_NEEDS_REQUEST),原函数体搬进 dispose_fixed_asset_internal。
--   ④ 处置分录挪进"走源路径"(Q9):journal_entry_reversal_route 认 asset_disposal 为 source_path。
--   ⑤ 引擎:approval_chain_gates 一行(处置,二级);approval_pending_documents 两支;approval_log 两个主体类型与
--      读策略两支;record_approval_decision 两支;operations_now 两支。
--
-- 【不做什么】不新增任何权限码 —— "新码同时授给 admin"那条常设裁定这一刀无码可授;不碰 role_permissions、user_roles、
-- 审批开关与策略;不写任何业务行。第一份月薪(set_initial_salary)照 ROLE-1 Batch 1 留下的样子不动。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一条没变;在途单据一张不少、一张不多;
-- 留痕、分录、资产、月薪、履历、评估一行没变;两张申请表是空的、没有写策略;两支守卫挂上;内层算子 authenticated 调不到;
-- 处置链二级有人批;调薪链对每一名在职员工、由每一个真能提单的人提,都还有一个不是当事人的决定人;
-- review_approval_code 与 pay_decision_code 逐对相等;每一张在途单据都还有一个【不是它自己当事人】的决定人。
-- 断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR9_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.salary_change_requests') IS NOT NULL OR to_regclass('public.asset_disposal_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR9_PRE|a request table already exists';
    END IF;
    -- 处置的决定人要持两个门码;调薪的两条路(cfo / cco)各要自己的决定码 + 人事模块 + 看得见工资
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices',
               'action.approve_review', 'module.hr.view', 'data.view_pay')) <> 5 THEN
        RAISE EXCEPTION 'APR9_PRE|cfo does not hold the five codes this cut routes to it';
    END IF;
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cco' AND rp.permission_code IN ('action.hr_reviews', 'module.hr.view', 'data.view_pay')) <> 3 THEN
        RAISE EXCEPTION 'APR9_PRE|cco does not hold the three codes this cut routes to it';
    END IF;
    -- 处置从来没有发生过(APR-4 实测 0;Step 0 再读一遍 0)
    IF EXISTS (SELECT 1 FROM fixed_assets WHERE status = 'disposed')
       OR EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'asset_disposal') THEN
        RAISE EXCEPTION 'APR9_PRE|a disposal already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a9_pending_before ON COMMIT DROP AS
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
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted';
CREATE TEMP TABLE a9_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM fixed_assets) AS assets,
       (SELECT count(*) FROM fixed_assets WHERE status = 'disposed') AS assets_disposed,
       (SELECT round(sum(cost_base), 2) FROM fixed_assets) AS asset_cost,
       (SELECT count(*) FROM fixed_asset_depreciation) AS depreciation_rows,
       (SELECT count(*) FROM employees WHERE monthly_salary IS NOT NULL) AS salaries_set,
       (SELECT md5(COALESCE(string_agg(id::text || ':' || monthly_salary::text, ',' ORDER BY id), ''))
          FROM employees WHERE monthly_salary IS NOT NULL) AS salary_digest,
       (SELECT count(*) FROM employment_history) AS employment_history,
       (SELECT count(*) FROM performance_reviews) AS reviews;
CREATE TEMP TABLE a9_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · salary_change_requests(镜像原样)────────────────────────────────────────────
CREATE TABLE public.salary_change_requests (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status              text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label               text NOT NULL,
    employee_id         uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组(RESTRICTED:两个月薪数)────────────────────────────────
    old_monthly_salary  numeric NOT NULL CHECK (old_monthly_salary >= 0),
    new_monthly_salary  numeric NOT NULL CHECK (new_monthly_salary >= 0),
    effective_date      date NOT NULL,
    reason              text NOT NULL CHECK (btrim(reason) <> ''),
    -- fingerprint:{monthly_salary, employment_status} —— 批准时与活数再比
    snapshot            jsonb NOT NULL,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at          timestamptz,
    decided_by          uuid,
    -- 按哪一个码批的(action.approve_review = CFO;action.hr_reviews = CFO 是当事人时的 cco)
    decided_via         text,
    decision_notes      text,
    executed_at         timestamptz,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at        timestamptz,
    withdrawn_by        uuid,
    withdraw_reason     text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid NOT NULL,
    CONSTRAINT salary_change_requests_changes_something CHECK (new_monthly_salary <> old_monthly_salary),
    CONSTRAINT salary_change_requests_decision_shape CHECK (
        (decided_at IS NULL) = (decided_by IS NULL) AND (decided_at IS NULL) = (decided_via IS NULL)),
    CONSTRAINT salary_change_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT salary_change_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT salary_change_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.salary_change_requests IS
    'APR-9:调薪申请 —— 财务提(module.hr.edit + data.view_pay,不许给自己提),CFO 批(CFO 是提单人或主角时 cco 批;pay_decision_code 一份判据,与绩效评估同一份),批准当场写 employees.monthly_salary 与一行带生效日的履历。submitted → approved · rejected(要理由)· withdrawn。不看审批开关:永远等人批,从不 auto_approved,不挡关审批。生效日落在已过账或挂着在途工资申请的工资期里按名拒(提交与批准各判一次)。一个人同一时刻只有一次在途调薪(跨绩效评估)。只改已有的月薪;第一份月薪只经 set_initial_salary。';

COMMENT ON COLUMN public.salary_change_requests.snapshot IS
    'APR-9(grilling Q6):提交那一刻的 {monthly_salary, employment_status}。批准时与活数再比,不一样 → SALARY_CHANGED_SINCE_REQUEST,申请仍在等。';

COMMENT ON COLUMN public.salary_change_requests.decided_via IS
    'APR-9:批(或驳回)这一张时用的那个码 —— action.approve_review(CFO)或 action.hr_reviews(CFO 这个人是提单人或主角时的 cco)。由 pay_decision_code 在决定那一刻算出。';

CREATE UNIQUE INDEX salary_change_requests_one_open
    ON public.salary_change_requests (employee_id) WHERE status = 'submitted';
CREATE INDEX salary_change_requests_employee_id_rel ON public.salary_change_requests (employee_id);

ALTER TABLE public.salary_change_requests ENABLE ROW LEVEL SECURITY;

-- 读:两个码同时成立(人事模块 + 看得见工资)。写:一条策略都不给 —— 只经 submit / decide / withdraw
-- (全是 SECURITY DEFINER)。屏幕读 salary_change_requests_visible()(带提单人 / 决定人邮箱与"我能不能批")。
CREATE POLICY "salary_change_requests select by permission" ON public.salary_change_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text) AND has_permission('data.view_pay'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.salary_change_requests FROM anon;

-- ── 1 · asset_disposal_requests(镜像原样)────────────────────────────────────────────
CREATE TABLE public.asset_disposal_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    asset_id           uuid NOT NULL REFERENCES public.fixed_assets (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- 收款(本位币;报废为 0)与收进哪个银行科目(收款 > 0 时必填 1000 / 1010)
    proceeds_base      numeric NOT NULL CHECK (proceeds_base >= 0),
    bank_account       text,
    -- 提单人的理由:原样成为处置分录的摘要尾巴
    reason             text NOT NULL CHECK (btrim(reason) <> ''),
    -- fingerprint(asset_disposal_fingerprint):成本、残值、年限、投用日、折旧科目、状态、折旧锚点
    snapshot           jsonb NOT NULL,
    -- 提交时试跑出来的那一组(处置日 = 提交日;成本、累计折旧、收款、损益)
    estimate           jsonb NOT NULL,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base        numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    -- 批准当场处置:生效的时刻、处置日(= 批准日)、处置分录、真的过出来的那一组
    executed_at        timestamptz,
    disposal_date      date,
    result_entry_id    uuid REFERENCES public.journal_entries (id),
    result             jsonb,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT asset_disposal_requests_bank_shape CHECK (
        (proceeds_base > 0) = (bank_account IS NOT NULL)
        AND (bank_account IS NULL OR bank_account IN ('1000', '1010'))),
    CONSTRAINT asset_disposal_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT asset_disposal_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT asset_disposal_requests_approved_shape CHECK (
        (status = 'approved') = (executed_at IS NOT NULL)
        AND (executed_at IS NULL) = (disposal_date IS NULL)
        AND (executed_at IS NULL) = (result_entry_id IS NULL)
        AND (executed_at IS NULL) = (result IS NULL)),
    CONSTRAINT asset_disposal_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.asset_disposal_requests IS
    'APR-9:固定资产处置申请 —— 财务提(module.finance.edit),CFO 批每一张,不分档,批准当场处置:处置日 = 批准日,按批准那一刻的累计折旧与损益过账;收款与银行科目提交时冻结。submitted → approved · rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。审批关着时生下来就是 approved 并当场处置(auto_approved)。在等的时候资产卡上改成本 / 投用 / 状态按名拒 ASSET_DISPOSAL_REQUESTED;折旧照常。一台资产同一时刻只挂一张在等的申请。dispose_fixed_asset 只会按名拒 ASSET_DISPOSAL_NEEDS_REQUEST。';

COMMENT ON COLUMN public.asset_disposal_requests.estimate IS
    'APR-9(grilling Q7):提交时按同一条路试跑出来的那一组 —— disposal_date(= 提交日)、cost_relieved、accum_relieved、proceeds、gain_loss。CFO 在屏幕上看见它与批准时真的过出来的 result 并排。';

COMMENT ON COLUMN public.asset_disposal_requests.amount_base IS
    'APR-9:本位币 = 处置分录的借方合计(APR-7 同口径)。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账额(写进 approved 留痕)。';

CREATE UNIQUE INDEX asset_disposal_requests_one_open
    ON public.asset_disposal_requests (asset_id) WHERE status = 'submitted';
CREATE INDEX asset_disposal_requests_asset_id_rel ON public.asset_disposal_requests (asset_id);
CREATE INDEX asset_disposal_requests_result_entry_id_rel ON public.asset_disposal_requests (result_entry_id);

ALTER TABLE public.asset_disposal_requests ENABLE ROW LEVEL SECURITY;

-- 读:资产页那一个码(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。写:一条策略都不给 ——
-- 只经 submit / decide / withdraw(全是 SECURITY DEFINER)。屏幕读 asset_disposal_requests_visible()。
CREATE POLICY "asset_disposal_requests select by permission" ON public.asset_disposal_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.asset_disposal_requests FROM anon;

-- ── 2 · approval_log:主体类型加两种;读策略加同名两支 ─────────────────────────
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
                            'asset_disposal_request'));
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
            ELSE false
        END
    );

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/pay_decision_code.sql
-- APR-9(2026-09-27,grilling Q2):**一次改月薪的决定,要哪一个码才批得了** —— 唯一的定义。
-- 两个读者的规则原来只写在 review_approval_code 里;调薪申请落地,它搬到这里,review_approval_code 委托过来
-- (APR-3 把分档那一个 >= 搬进 approval_level_at 的同一个手法:一份判据,旧入口原样保留)。
--
-- 【规则,原样】(ROLE-1 Tim 的 Q5;APR-9 确认对调薪申请同样成立)
--   · 一般情形                       → 'action.approve_review'(cfo 持有)
--   · CFO 这个【人】是提单人或主角    → 'action.hr_reviews'   (cco 持有)
-- "CFO" = finance_settings.approval_level2_role_code 那个角色的【真持有人】,按【人】认(account_person ——
-- Tim 的两个账号 tim@ / admin@ 是同一个人)。二级角色没设 → 一般情形。
-- 提单人 = 评估的 submitted_by / 调薪申请的 created_by;主角 = 被评估 / 被调薪的员工。
--
-- 【读者】review_approval_code(→ approve_review 与评估详情页)· decide_salary_change_request(门)·
-- salary_change_deciders(提交时"别人批得动吗"与迁移自证)· salary_change_requests_visible(按钮灰不灰)。
-- 【永不返回 NULL】返回值直接喂给 require_permission。
-- 【为什么 DEFINER 且收权】它读 real_role_holders / account_person(账号 ↔ 员工的对照);EXECUTE 从
-- authenticated 收回,屏幕经 review_approval_code(本来就给)或 salary_change_requests_visible 问它。
--
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.pay_decision_code(p_raiser uuid, p_employee_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN EXISTS (
                SELECT 1
                  FROM finance_settings fs
                 CROSS JOIN LATERAL real_role_holders(fs.approval_level2_role_code) h
                 WHERE fs.approval_level2_role_code IS NOT NULL
                   AND account_person(h.user_id) IS NOT NULL
                   AND (account_person(h.user_id) = p_employee_id
                        OR account_person(h.user_id) = account_person(p_raiser)))
           THEN 'action.hr_reviews'
           ELSE 'action.approve_review'
           END;
$function$;

COMMENT ON FUNCTION public.pay_decision_code(uuid, uuid) IS
'APR-9(grilling Q2):一次改月薪的决定(绩效评估的批准、调薪申请的决定)要哪一个码 —— CFO(二级审批角色的真持有人,按人认)是提单人或主角时 action.hr_reviews(cco),否则 action.approve_review(cfo)。唯一的定义;review_approval_code 委托给它。永不返回 NULL。EXECUTE 已从 authenticated 收回。';

-- db/functions/review_approval_code.sql
-- ROLE-1(Tim 的矩阵,2026-09-23):一张绩效评估【要哪一个码才批得了】—— 唯一的定义。
--
-- 【规则,原样】绩效评估由 cco 做、CFO 批;Tim 自己的评估由 cco 批。
-- Step 0 的 grilling 量出来还有第二种情形:Choo Er 的上级(manager_id)是 Tim,
-- 所以她的评估是 Tim 以评估人身份【提交】的 —— 那时 CFO 是提交人,自批拒绝会挡住他。
-- 于是 Tim 的 Q5 裁定:**CFO 批;CFO 是提交人【或】主角时,cco 批。**
--
--   · 一般情形            → 'action.approve_review'(cfo 持有)
--   · CFO 是提交人或主角  → 'action.hr_reviews'   (cco 持有 —— 做评估的那个码)
--
-- "CFO" = finance_settings.approval_level2_role_code 那个角色的【真持有人】,按【人】认
-- (account_person —— Tim 的两个账号是一个人)。与 R2 的 self_approval_exception
-- 用同一个判据,不另写一份"谁是 CFO"。二级角色没设 → 一般情形。
--
-- 【两个读者】approve_review(门)与评估详情页(按钮可不可按、为什么)。
-- 一份定义两个读者 —— 页面【不】在 TypeScript 里重算这条规矩(AGENTS.md 的预览规则)。
--
-- 【永不返回 NULL】它的返回值直接喂给 require_permission;NULL 会变成一次
-- "谁都没有的码"的拒绝,读起来像权限问题,其实是这里写错了。
--
-- ★ APR-9(2026-09-27,grilling Q2):**规则搬进了 pay_decision_code,这里只委托。** 调薪申请要问的是同一句话
--   (CFO 是当事人 → cco),两份实现就是两份会漂开的"谁批得了加薪"。本函数的签名、返回值、两个读者一个字没变。
--
-- NOTE: introduced by db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql.

CREATE OR REPLACE FUNCTION public.review_approval_code(p_submitted_by uuid, p_employee_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT pay_decision_code(p_submitted_by, p_employee_id);
$function$;

COMMENT ON FUNCTION public.review_approval_code(uuid, uuid) IS
'ROLE-1(Tim 的矩阵 · Q5):批一张绩效评估要哪一个码 —— CFO(二级审批角色的真持有人,按人认)是提交人或主角时 action.hr_reviews(cco),否则 action.approve_review(cfo)。两个读者:approve_review 的门与评估详情页。永不返回 NULL。★ APR-9:规则本身住在 pay_decision_code(调薪申请问同一句话),本函数只委托。';

-- db/functions/salary_effective_period_block.sql
-- APR-9(2026-09-27,grilling Q5):一个调薪生效日【落不落得下】—— 一份判据,调薪申请的提交与批准各问一次。
--   落在一个已过账的工资期里        → 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|<期>'(与 approve_review / set_initial_salary
--                                      同一句话:总账已经认了那个月的工资)
--   落在一个挂着在途工资申请的期里  → 'SALARY_EFFECTIVE_IN_REQUESTED_PERIOD|<期>|<申请>'(那一期正等 CFO 批过账或撤销,
--                                      它批的那一组数字不该在等待中被一次调薪说成过时的)
--   都不是                          → NULL
-- 工资期没有起止两列:周期就是 period_month 那个整月(approve_review 抬头 (4))。"在途" = submitted 或 approved
-- (approved 是已批未执行,PAYROLL-APR-1 的生命周期)。
-- 【为什么 approve_review 与 set_initial_salary 没有改成问它】Tim 的 Q5 说的是调薪申请;那两支的日期判据
-- ROLE-1 定下之后原样不动(第一份月薪"照 ROLE-1 Batch 1 留下的样子")。它们多问一句在途申请,是另一刀的决定。
-- 返回一句拒绝文本,不 RAISE:调用方(提交、批准)各自 RAISE,屏幕不调用它。EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_effective_period_block(p_effective_date date)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT 'SALARY_EFFECTIVE_IN_POSTED_PERIOD|' || p.code
           FROM payroll_periods p
          WHERE p.deleted_at IS NULL AND p.status = 'posted'
            AND p_effective_date >= p.period_month
            AND p_effective_date < (p.period_month + interval '1 month')::date
          ORDER BY p.period_month
          LIMIT 1),
        (SELECT 'SALARY_EFFECTIVE_IN_REQUESTED_PERIOD|' || p.code || '|' || q.label
           FROM payroll_periods p
           JOIN payroll_requests q ON q.payroll_period_id = p.id AND q.status IN ('submitted', 'approved')
          WHERE p.deleted_at IS NULL
            AND p_effective_date >= p.period_month
            AND p_effective_date < (p.period_month + interval '1 month')::date
          ORDER BY p.period_month, q.created_at
          LIMIT 1));
$function$;

-- db/functions/salary_change_fingerprint.sql
-- APR-9(2026-09-27,grilling Q6):一张调薪申请批的是【哪一个起点】—— 提交那一刻的月薪与在职状态。
-- 提交时存进 salary_change_requests.snapshot,批准时再算一遍比:不一样(中间批了一张绩效评估、人离职了、
-- 依法清空了)→ SALARY_CHANGED_SINCE_REQUEST,申请仍在等。员工不存在 → NULL(调用方先查过存在)。
-- 它交出月薪:EXECUTE 已从 authenticated 收回(没有调用者检查,靠的就是调不到)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_fingerprint(p_employee_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object('monthly_salary', e.monthly_salary,
                              'employment_status', e.employment_status,
                              'anonymised', e.anonymised_at IS NOT NULL,
                              'deleted', e.deleted_at IS NOT NULL)
      FROM employees e
     WHERE e.id = p_employee_id;
$function$;

-- db/functions/salary_change_open.sql
-- APR-9(2026-09-27,grilling Q6):**一个人同一时刻只有一次在途调薪,跨两条路** —— 一份判据。
--   一张 submitted 的调薪申请                                → 它的 label
--   一张 submitted、带 new_monthly_salary 的绩效评估          → 'review:' || 评估 id
--   都没有                                                   → NULL
-- 读者:submit_salary_change_request(SALARY_CHANGE_OPEN)· submit_review(同一句拒绝,带调薪的评估才问)。
-- 唯一索引 salary_change_requests_one_open 是申请那一侧的第二道;评估那一侧没有索引能跨表,所以这里是唯一的一道,
-- 两扇提交的门都锁员工行(FOR UPDATE)再问它。EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_open(p_employee_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT q.label FROM salary_change_requests q
          WHERE q.employee_id = p_employee_id AND q.status = 'submitted'
          LIMIT 1),
        (SELECT 'review:' || r.id::text FROM performance_reviews r
          WHERE r.employee_id = p_employee_id AND r.status = 'submitted'
            AND r.new_monthly_salary IS NOT NULL
          ORDER BY r.submitted_at
          LIMIT 1));
$function$;

-- db/functions/salary_change_deciders.sql
-- APR-9(2026-09-27,grilling Q2 · Q4):一张【提单人为 p_raiser、主角为 p_employee_id】的调薪申请,谁批得动。
--   = 真持有(real_role_grants:未撤销 · 已确认 · 未封 · 未删)pay_decision_code(提单人, 员工) 那个码
--     且 module.hr.view 且 data.view_pay 的账号,减去提单人与主角(self_leg,按人认)。
-- 它与 approval_deciders 同一个形状,只是【码】由 pay_decision_code 按人给出,而不是按级从 approval_chain_gates 取 ——
-- 这条链不在那本名册里(Q2),所以不能借 approval_deciders;"谁批得了加薪"仍只有 pay_decision_code 一份定义。
-- R2 的自批例外永远不覆盖调薪(self_approval_exception 不认 salary_change_request),所以这里没有那一支。
-- 读者:submit_salary_change_request(提单人之外没人 → SALARY_CHANGE_NO_OTHER_DECIDER)· 迁移自证 ·
-- salary_change_requests_visible 不读它(它只答"我"能不能批)。person_key 按人认,同一个人的两个账号只算一个。
-- EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_deciders(p_raiser uuid, p_employee_id uuid)
 RETURNS TABLE(user_id uuid, person_key text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH need AS (
        SELECT unnest(ARRAY[pay_decision_code(p_raiser, p_employee_id), 'module.hr.view', 'data.view_pay']) AS code
    ),
    real_perm AS (
        SELECT DISTINCT rp.permission_code, rg.user_id
          FROM role_permissions rp
          JOIN roles r ON r.id = rp.role_id
         CROSS JOIN LATERAL real_role_grants(r.code) rg
    ),
    cand AS (
        SELECT DISTINCT pp.user_id FROM real_perm pp
         WHERE NOT EXISTS (
                 SELECT 1 FROM need n
                  WHERE NOT EXISTS (SELECT 1 FROM real_perm q
                                     WHERE q.user_id = pp.user_id AND q.permission_code = n.code))
    )
    SELECT c.user_id, COALESCE(account_person(c.user_id)::text, 'account:' || c.user_id::text)
      FROM cand c
     WHERE self_leg(p_raiser, p_employee_id, c.user_id) = 'none'
$function$;

-- db/functions/salary_change_execute_internal.sql
-- APR-9(2026-09-27):让一张调薪申请【生效】—— 只从 decide_salary_change_request 的批准那一支调用。
--   1. 员工行上锁;fingerprint 再比(Q6)—— 月薪、在职状态、清空、删除有一样变了 → SALARY_CHANGED_SINCE_REQUEST|label,
--      整笔回滚,申请仍在等(CFO 驳回,或财务撤回再提)。
--   2. 生效日再判一次(Q5):提交之后那一期可能已经过账,或挂上了一张在途工资申请。
--   3. 写 employees.monthly_salary 与一行 employment_history salary_change(effective_date = 申请上的生效日;
--      old / new 两个数;created_by = 提单人 —— 说"这个人要调薪"的那个人,APR-7 Q6 同一条;批的人在申请行与留痕上)。
-- 它是属主路径:两支"直连写薪资"守卫(row_security_active = false)放它过去。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     salary_change_requests%ROWTYPE;
    v_emp   employees%ROWTYPE;
    v_block text;
BEGIN
    SELECT * INTO v_r FROM salary_change_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_r.employee_id FOR UPDATE;

    IF salary_change_fingerprint(v_r.employee_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'SALARY_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;
    v_block := salary_effective_period_block(v_r.effective_date);
    IF v_block IS NOT NULL THEN
        RAISE EXCEPTION '%', v_block;
    END IF;

    UPDATE employees SET monthly_salary = v_r.new_monthly_salary WHERE id = v_emp.id;

    INSERT INTO employment_history
        (employee_id, effective_date, change_type, job_title, department_id,
         employment_type, employment_status, old_monthly_salary, new_monthly_salary, notes, created_by)
    SELECT e.id, v_r.effective_date, 'salary_change',
           (SELECT p.title FROM positions p WHERE p.id = e.position_id), e.department_id,
           e.employment_type, e.employment_status, v_r.old_monthly_salary, v_r.new_monthly_salary,
           format('Salary change approved with request %s', v_r.label),
           v_r.created_by
      FROM employees e WHERE e.id = v_emp.id;

    RETURN jsonb_build_object('employee_code', v_emp.code,
                              'old_monthly_salary', v_r.old_monthly_salary,
                              'new_monthly_salary', v_r.new_monthly_salary,
                              'effective_date', v_r.effective_date);
END;
$function$;

-- db/functions/submit_salary_change_request.sql
-- APR-9(2026-09-27):财务提一张调薪申请。批准之前月薪一分不动(Tim 的矩阵 §5;grilling Q1–Q6)。
--
-- 【门】module.hr.edit + data.view_pay(Q4 —— 第一份月薪那扇门的同一对码:看不见工资的人不写工资)。
-- 【拒绝,按这个顺序】
--   EMPLOYEE_NOT_FOUND · PDPA_ALREADY_ANONYMISED|<日> · EMPLOYEE_SEPARATED|<code>
--   SALARY_CHANGE_OWN_REFUSED|<code>             给自己提(按人认:tim@ 与 admin@ 是同一个人)
--   SALARY_NOT_SET_USE_INITIAL|<code>            月薪还是 NULL —— 第一份月薪只经 set_initial_salary
--   SALARY_AMOUNT_INVALID                        NULL 或负数
--   SALARY_CHANGE_NO_CHANGE|<code>               与现在的月薪一样
--   SALARY_EFFECTIVE_DATE_REQUIRED               生效日必填,不给默认
--   SALARY_EFFECTIVE_IN_POSTED_PERIOD|<期> / SALARY_EFFECTIVE_IN_REQUESTED_PERIOD|<期>|<申请>
--   SALARY_CHANGE_REASON_REQUIRED|<code>
--   SALARY_CHANGE_OPEN|<code>|<那一张>           已有一张在途的调薪(申请,或带调薪的已提交评估)
--   SALARY_CHANGE_NO_OTHER_DECIDER|<label>       提单人之外没人批得动(pay_decision_code 路由之后)
-- 【不看审批开关】(Q3)生下来永远是 submitted;"没人批得动"也照样判(开关关着时 CFO 仍要批)。
-- 留痕:submitted,level NULL(不在按级的名册里,performance_review 同形)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_salary_change_request(p_employee_id uuid, p_new_monthly_salary numeric, p_effective_date date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    employees%ROWTYPE;
    v_block  text;
    v_open   text;
    v_n      integer;
    v_label  text;
    v_id     uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.hr.edit');
    PERFORM require_permission('data.view_pay');

    SELECT * INTO v_emp FROM employees
     WHERE id = p_employee_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
    IF v_emp.anonymised_at IS NOT NULL THEN
        RAISE EXCEPTION 'PDPA_ALREADY_ANONYMISED|%', v_emp.anonymised_at::date;
    END IF;
    IF v_emp.employment_status = 'separated' THEN
        RAISE EXCEPTION 'EMPLOYEE_SEPARATED|%', v_emp.code;
    END IF;
    IF self_leg(NULL, v_emp.id, auth.uid()) = 'subject' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_OWN_REFUSED|%', v_emp.code;
    END IF;
    IF v_emp.monthly_salary IS NULL THEN
        RAISE EXCEPTION 'SALARY_NOT_SET_USE_INITIAL|%', v_emp.code;
    END IF;
    IF p_new_monthly_salary IS NULL OR p_new_monthly_salary < 0 THEN
        RAISE EXCEPTION 'SALARY_AMOUNT_INVALID';
    END IF;
    IF p_new_monthly_salary = v_emp.monthly_salary THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NO_CHANGE|%', v_emp.code;
    END IF;
    IF p_effective_date IS NULL THEN
        RAISE EXCEPTION 'SALARY_EFFECTIVE_DATE_REQUIRED';
    END IF;
    v_block := salary_effective_period_block(p_effective_date);
    IF v_block IS NOT NULL THEN
        RAISE EXCEPTION '%', v_block;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_REASON_REQUIRED|%', v_emp.code;
    END IF;
    v_open := salary_change_open(v_emp.id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'SALARY_CHANGE_OPEN|%|%', v_emp.code, v_open;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM salary_change_requests q WHERE q.employee_id = v_emp.id;
    v_label := v_emp.code || ' · salary change #' || v_n::text;

    IF NOT EXISTS (SELECT 1 FROM salary_change_deciders(auth.uid(), v_emp.id)) THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NO_OTHER_DECIDER|%', v_label;
    END IF;

    INSERT INTO salary_change_requests (id, status, label, employee_id, old_monthly_salary, new_monthly_salary,
                                        effective_date, reason, snapshot, created_by)
    VALUES (v_id, 'submitted', v_label, v_emp.id, v_emp.monthly_salary, p_new_monthly_salary,
            p_effective_date, btrim(p_reason), salary_change_fingerprint(v_emp.id), auth.uid());

    PERFORM record_approval_decision('salary_change_request', v_id, 'submitted', NULL, NULL);

    RETURN jsonb_build_object('request_id', v_id, 'label', v_label, 'status', 'submitted',
                              'decided_via', pay_decision_code(auth.uid(), v_emp.id));
END;
$function$;

-- db/functions/decide_salary_change_request.sql
-- APR-9(2026-09-27):批准或驳回一张调薪申请。批准【当场生效】(salary_change_execute_internal)。
--
-- 【门】module.hr.view + data.view_pay(批的人看得见他批的那个数,§5),再加 pay_decision_code(提单人, 员工):
--   CFO → action.approve_review;CFO 这个人是提单人或主角 → action.hr_reviews(cco)。与绩效评估同一份判据(Q2)。
--   【不是】module.hr.edit —— 那是提单的码。
-- 【四眼】forbid_self_approval(提单人, 员工, 'salary_change_request'):提单人与主角都不能批,按人认;
--   R2 的自批例外不认这个类型,所以永远没有"自批加薪"。
-- 【不看审批开关】(Q3)开着关着都批得了 —— 所以它在 approval_pending_documents 里 blocks_disable = false,
--   也【不】调用 require_approver_for(那一支属于按级的名册,db/fixtures/203 E 按调用者数它)。
-- 驳回要理由,从不检查 fingerprint 与生效日。留痕:approved / rejected,level NULL。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.decide_salary_change_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    salary_change_requests%ROWTYPE;
    v_code text;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.hr.view');
    PERFORM require_permission('data.view_pay');

    SELECT * INTO v_r FROM salary_change_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    -- 谁批得了要先读到这一行才答得出(approve_review 同序)
    v_code := pay_decision_code(v_r.created_by, v_r.employee_id);
    PERFORM require_permission(v_code);
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    PERFORM forbid_self_approval(v_r.created_by, v_r.employee_id, 'salary_change_request');

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'SALARY_CHANGE_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE salary_change_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(), decided_via = v_code,
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('salary_change_request', p_request_id, 'rejected', NULL, btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := salary_change_execute_internal(p_request_id);

    UPDATE salary_change_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), decided_via = v_code,
           executed_at = now(), decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('salary_change_request', p_request_id, 'approved', NULL,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'decided_via', v_code, 'effective_date', v_r.effective_date,
                              'employee_code', v_exec->>'employee_code');
END;
$function$;

-- db/functions/withdraw_salary_change_request.sql
-- APR-9(2026-09-27):撤回一张在等的调薪申请。谁能撤:提单人本人(按人认),或持提单那一对码的人
-- (module.hr.edit + data.view_pay —— 财务;提单人休假时同事能收回它)。只撤 submitted。
-- 撤回什么都不生效;记在本行上,【不】写 approval_log(撤回不是一次决定 —— ROLE-1 Batch 3a 的记录裁定)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.withdraw_salary_change_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r salary_change_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM salary_change_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.hr.edit');
        PERFORM require_permission('data.view_pay');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SALARY_CHANGE_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE salary_change_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;

-- db/functions/salary_change_requests_visible.sql
-- APR-9(2026-09-27):员工页上"调薪申请"那一块读的就是这里。
--   谁读得到:module.hr.view 且 data.view_pay(与表的读策略同一对码)。其余 → 零行 —— 主角在等待中读不到自己的
--   调薪申请(绩效评估"本人只在批准之后看得见"同一条);批准之后他从自己的档案与履历上看得见新月薪。
--   p_employee_id 给了就只给那个人的;只给在等的全部 + 最近决定 / 撤回的 p_recent 张。
--   current_matches = 活数与提交时的 fingerprint 一样(不一样,CFO 批准会被 SALARY_CHANGED_SINCE_REQUEST 拒,
--   屏幕先说出来)。decide_code = pay_decision_code 给出的那个码;decide_block = 读者此刻为什么批不了:
--   NULL(批得了)· 'NEEDS_CODE|<码>' · 'SELF|raiser' / 'SELF|subject'。屏幕不在 TypeScript 里重算这条规矩。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.salary_change_requests_visible(p_employee_id uuid DEFAULT NULL::uuid, p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, status text, label text, employee_id uuid, employee_code text, employee_name text, old_monthly_salary numeric, new_monthly_salary numeric, effective_date date, reason text, current_matches boolean, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decided_via text, decision_notes text, withdrawn_at timestamptz, withdraw_reason text, decide_code text, decide_block text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM salary_change_requests q
         WHERE has_permission('module.hr.view') AND has_permission('data.view_pay')
           AND (p_employee_id IS NULL OR q.employee_id = p_employee_id)),
    d AS (
        SELECT r.*, pay_decision_code(r.created_by, r.employee_id) AS code,
               self_leg(r.created_by, r.employee_id, auth.uid()) AS leg
          FROM r)
    SELECT d.id, d.status, d.label, d.employee_id, e.code, e.legal_name,
           d.old_monthly_salary, d.new_monthly_salary, d.effective_date, d.reason,
           salary_change_fingerprint(d.employee_id) IS NOT DISTINCT FROM d.snapshot,
           d.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = d.created_by),
           d.leg = 'raiser',
           d.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = d.decided_by),
           d.decided_via, d.decision_notes, d.withdrawn_at, d.withdraw_reason,
           d.code,
           CASE WHEN NOT has_permission(d.code) THEN 'NEEDS_CODE|' || d.code
                WHEN d.leg <> 'none' THEN 'SELF|' || d.leg
           END
      FROM d
      JOIN employees e ON e.id = d.employee_id
     WHERE d.is_open OR d.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY d.is_open DESC, COALESCE(d.decided_at, d.withdrawn_at, d.created_at) DESC
$function$;

-- db/functions/guard_performance_review_write.sql
-- APR-9(2026-09-27,grilling Q1):**绩效评估的生命周期列只经函数写;提交之后,调薪与转正结论冻结。**
--
-- 【洞 —— Step 0 以 sandra@(cco)在一笔回滚的事务里实测】performance_reviews 的写策略只问 action.hr_reviews,
-- 列上没有任何守卫:cco 直连 INSERT 一张 status = 'submitted'、submitted_by = tim@、new_monthly_salary = 9999 的
-- 评估,再以自己调 approve_review —— review_approval_code 读的 submitted_by 说"CFO 是提交人",于是路由给 cco;
-- 四眼那一腿查的也是这个伪造的 submitted_by。批准成功,employees.monthly_salary 变成 9999,**没有 CFO**。
-- 同一条路还能在评估等 CFO 的时候改掉 new_monthly_salary,CFO 批的就不是他看见的那个数。
--
-- 【规则】一次【直连】写(row_security_active = true —— 属主路径 / SECURITY DEFINER 那些函数一律放行):
--   · INSERT 只许建草稿:status = 'draft',且生命周期列(submitted_* · approved_* · acknowledged_at · void_* ·
--     voided_*)全空 → 否则 REVIEW_DIRECT_INSERT_DRAFT_ONLY。
--   · UPDATE 不许动生命周期列(status、submitted_at / submitted_by、approved_at / approved_by、acknowledged_at、
--     void_reason / voided_at / voided_by)—— 任何状态下都不许:从草稿直接改成 submitted 就是那次伪造本身
--     → REVIEW_STATUS_THROUGH_FUNCTION_ONLY|<列>。它们只经 submit_review / approve_review / acknowledge_review /
--     void_review 写。
--   · 提交之后(OLD.status 不是 draft / self_review):调薪两列、转正结论、被评估人 → REVIEW_FROZEN_AFTER_SUBMIT|<列>。
--     被评估人不在 Tim 的原话里,是 Step 1 加的:一张已提交、带调薪的评估换一个被评估人,就是把加薪挪给另一个人。
-- 评分、总结、自评文字这些不动钱的列照旧由评估的写策略管。
-- 【INVOKER,故意的】row_security_active 要反映【调用者】—— guard_employee_salary_write 同形。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_performance_review_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft'
           OR num_nonnulls(NEW.submitted_at, NEW.submitted_by, NEW.approved_at, NEW.approved_by,
                           NEW.acknowledged_at, NEW.void_reason, NEW.voided_at, NEW.voided_by) > 0 THEN
            RAISE EXCEPTION 'REVIEW_DIRECT_INSERT_DRAFT_ONLY';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|status';
    ELSIF NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|submitted_at';
    ELSIF NEW.submitted_by IS DISTINCT FROM OLD.submitted_by THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|submitted_by';
    ELSIF NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|approved_at';
    ELSIF NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|approved_by';
    ELSIF NEW.acknowledged_at IS DISTINCT FROM OLD.acknowledged_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|acknowledged_at';
    ELSIF NEW.void_reason IS DISTINCT FROM OLD.void_reason THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|void_reason';
    ELSIF NEW.voided_at IS DISTINCT FROM OLD.voided_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|voided_at';
    ELSIF NEW.voided_by IS DISTINCT FROM OLD.voided_by THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|voided_by';
    END IF;

    IF OLD.status NOT IN ('draft', 'self_review') THEN
        IF NEW.new_monthly_salary IS DISTINCT FROM OLD.new_monthly_salary THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|new_monthly_salary';
        ELSIF NEW.salary_effective_date IS DISTINCT FROM OLD.salary_effective_date THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|salary_effective_date';
        ELSIF NEW.probation_outcome IS DISTINCT FROM OLD.probation_outcome THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|probation_outcome';
        ELSIF NEW.employee_id IS DISTINCT FROM OLD.employee_id THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|employee_id';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_performance_review_write() IS
'APR-9(Q1):绩效评估的直连写 —— INSERT 只许建草稿(REVIEW_DIRECT_INSERT_DRAFT_ONLY);生命周期列(status · submitted_* · approved_* · acknowledged_at · void_* · voided_*)任何时候只经函数写(REVIEW_STATUS_THROUGH_FUNCTION_ONLY|列);提交之后调薪两列、转正结论、被评估人冻结(REVIEW_FROZEN_AFTER_SUBMIT|列)。INVOKER + row_security_active:属主路径放行。关的是 Step 0 实测的那条路 —— cco 直连插一张 submitted_by = CFO 的已提交评估、自己批掉、改了别人的月薪。';

-- ─── submit_review
CREATE OR REPLACE FUNCTION public.submit_review(p_review_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      performance_reviews%ROWTYPE;
    v_goals  integer;
    v_emp_code   text;
    v_emp_salary numeric;
    v_open       text;
BEGIN
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    IF NOT (has_permission('action.hr_reviews')
            OR is_reviewer_of(v_r.reviewer_employee_id)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.hr_reviews';
    END IF;

    -- self_review 是可选的一步,所以两个入口状态都收
    IF v_r.status NOT IN ('draft','self_review') THEN
        RAISE EXCEPTION 'REVIEW_BAD_STATUS|%', v_r.status;
    END IF;

    IF v_r.reviewer_employee_id IS NULL THEN
        RAISE EXCEPTION 'REVIEWER_REQUIRED';
    END IF;
    IF v_r.rating_code IS NULL THEN
        RAISE EXCEPTION 'RATING_REQUIRED';
    END IF;
    IF v_r.summary_text IS NULL OR btrim(v_r.summary_text) = '' THEN
        RAISE EXCEPTION 'SUMMARY_REQUIRED';
    END IF;
    IF v_r.review_type = 'probation' AND v_r.probation_outcome IS NULL THEN
        RAISE EXCEPTION 'PROBATION_OUTCOME_REQUIRED';
    END IF;

    SELECT count(*) INTO v_goals FROM review_goals WHERE review_id = p_review_id;
    IF v_goals = 0 THEN
        RAISE EXCEPTION 'GOALS_REQUIRED';
    END IF;

    -- ★ APR-9(grilling Q5 · Q6):一张带调薪的评估 —— 只改【已有的】月薪(第一份月薪只经 set_initial_salary),
    --   而且一个人同一时刻只有一次在途调薪(跨调薪申请,salary_change_open 一份判据)。员工行上锁再问,
    --   与 submit_salary_change_request 同一把锁。提交之后调薪两列冻结(guard_performance_review_write)。
    IF v_r.new_monthly_salary IS NOT NULL THEN
        SELECT code, monthly_salary INTO v_emp_code, v_emp_salary
          FROM employees WHERE id = v_r.employee_id FOR UPDATE;
        IF v_emp_salary IS NULL THEN
            RAISE EXCEPTION 'SALARY_NOT_SET_USE_INITIAL|%', v_emp_code;
        END IF;
        v_open := salary_change_open(v_r.employee_id);
        IF v_open IS NOT NULL THEN
            RAISE EXCEPTION 'SALARY_CHANGE_OPEN|%|%', v_emp_code, v_open;
        END IF;
    END IF;

    UPDATE performance_reviews
    SET status = 'submitted', submitted_at = now(), submitted_by = auth.uid()
    WHERE id = p_review_id;

    -- APR-1:留痕。【纯追加,不改变本函数任何既有行为】——
    -- 写在状态落定【之后】、返回之前;写失败就整笔回滚(漏记的留痕比出错的留痕更难查)。
    PERFORM record_approval_decision('performance_review', p_review_id, 'submitted', NULL, NULL);

    RETURN jsonb_build_object('review_id', p_review_id, 'status', 'submitted',
                              'rating_code', v_r.rating_code, 'goals', v_goals);
END;
$function$;

-- ─── approve_review
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
    SELECT * INTO v_r FROM performance_reviews WHERE id = p_review_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'REVIEW_NOT_FOUND|%', COALESCE(p_review_id::text, '?');
    END IF;

    -- ★ ROLE-1(Tim 的矩阵,2026-09-23):批评估的是 CFO;CFO 是这张评估的
    --   提交人或主角时,改由 cco 批。【谁批】只有一份定义:review_approval_code。
    --   它要先读到这一行才答得出,所以门排在 SELECT 之后。
    PERFORM require_permission(review_approval_code(v_r.submitted_by, v_r.employee_id));
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
    PERFORM forbid_self_approval(v_r.submitted_by, v_r.employee_id, 'performance_review');

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
        -- ★ APR-9(grilling Q5):评估只改【已有的】月薪。Step 0 量出来:线上六个人的月薪全是 NULL,而本函数
        --   此前会照写 —— 一张评估就能录下第一份月薪,绕过"第一份月薪由财务录一次"(set_initial_salary)。
        IF v_emp.monthly_salary IS NULL THEN
            RAISE EXCEPTION 'SALARY_NOT_SET_USE_INITIAL|%', v_emp.code;
        END IF;
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

-- db/functions/asset_disposal_fingerprint.sql
-- APR-9(2026-09-27,grilling Q8):一张处置申请批的是【哪一张卡】—— 成本(原币、币种、汇率、本位币)、残值、年限、
-- 购置日、投用日、折旧科目、状态,以及折旧锚点(张数与最后一张的生效月)。提交时存进 snapshot,批准时再算一遍比;
-- 不一样 → ASSET_CHANGED_SINCE_REQUEST,申请仍在等。【不含已提折旧】—— 折旧在等待中照常跑(Q8:关账要它),
-- 批准时按那一刻的累计折旧算损益,那正是 Q7 说的"按批准那一刻的活数"。
-- 资产不存在 → NULL。EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_fingerprint(p_asset_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'cost_ccy', a.cost_ccy, 'currency', a.currency, 'fx_rate', a.fx_rate, 'cost_base', a.cost_base,
               'residual_base', a.residual_base, 'useful_life_months', a.useful_life_months,
               'acquisition_date', a.acquisition_date, 'in_service_date', a.in_service_date,
               'depreciation_account_code', a.depreciation_account_code, 'status', a.status,
               'anchors', (SELECT count(*) FROM fixed_asset_depreciation_anchors an WHERE an.asset_id = a.id),
               'last_anchor', (SELECT max(an.effective_from) FROM fixed_asset_depreciation_anchors an
                                WHERE an.asset_id = a.id))
      FROM fixed_assets a
     WHERE a.id = p_asset_id;
$function$;

-- db/functions/dispose_fixed_asset_internal.sql
-- APR-9(2026-09-27):处置的【引擎】—— 原 dispose_fixed_asset 的函数体,一个字没改,只拿掉了门(FIN-22 的全部规矩照旧:
-- 1500 按成本解除、1510 按累计折旧解除,差额对净收款进 7200;收款 > 0 必须给银行科目;零成本的卡按名拒;
-- 【不自动补提】处置月折旧)。只从 asset_disposal_execute_internal 调用(批准、审批关着时的提交、提交时的试跑)。
-- 分录的 created_by 是调用那一刻的 auth.uid() —— 批准时就是批的 CFO(过账发生在批准那一刻,APR-7 Q6 同一条)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.dispose_fixed_asset_internal(p_asset_id uuid, p_disposal_date date, p_proceeds numeric DEFAULT 0, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_a      record;
    v_accum  numeric;
    v_gain   numeric;
    v_bank   text;
    v_lines  jsonb := '[]'::jsonb;
    v_je     jsonb;
BEGIN
    IF p_disposal_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', p_asset_id;
    END IF;
    IF v_a.status <> 'active' THEN
        RAISE EXCEPTION 'ASSET_ALREADY_DISPOSED|%', v_a.code;
    END IF;
    -- EQP-1c-a:【零成本的卡处置不了 —— 而这一条是本刀自己造出来的路,所以本刀关它】
    -- 下面那条 1500 贷方是【无条件】发出的,金额就是 cost_base;而
    -- journal_lines_amount_ccy_check 是 CHECK (amount_ccy > 0)。于是处置一张
    -- 零成本卡会撞出一条【裸的 23514】,而不是一句人话。
    -- 【为什么不改成"金额为 0 就不发那条行"】那会让处置【悄悄成功】,
    -- 把一张"还没买成的机器"变成一张"已处置"的资产 —— 而这两件事在账上
    -- 完全不是一回事。一张还没有成本的卡要退场,那是【取消一次采购承诺】,
    -- 不是【处置一台资产】,而那条路今天不存在(docs/known-issues.md 有记录)。
    -- 与 set_asset_in_service 用同一个码:同一句话 —— 这张卡还不是一台资产。
    IF v_a.cost_base = 0 THEN
        RAISE EXCEPTION 'ASSET_HAS_NO_COST|%', v_a.code
          USING HINT = '这张卡还没有任何成本,不构成一次处置 —— 它要退场是另一件事,今天没有那条路';
    END IF;
    IF p_disposal_date < v_a.acquisition_date THEN
        RAISE EXCEPTION 'DISPOSAL_BEFORE_ACQUISITION|%|%', p_disposal_date, v_a.acquisition_date;
    END IF;
    IF p_proceeds IS NULL OR p_proceeds < 0 THEN
        RAISE EXCEPTION 'PROCEEDS_INVALID';
    END IF;
    IF p_proceeds > 0 THEN
        IF p_bank_account IS NULL OR p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
        END IF;
        v_bank := p_bank_account;
    END IF;

    SELECT COALESCE(SUM(amount_base), 0) INTO v_accum
    FROM fixed_asset_depreciation WHERE asset_id = p_asset_id;

    -- 损益 = 净收款 + 累计折旧 − 成本(>0 益,<0 损)
    v_gain := round(p_proceeds + v_accum - v_a.cost_base, 2);

    IF p_proceeds > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', p_proceeds, 'line_memo', 'disposal proceeds');
    END IF;
    IF v_accum > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1510', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', v_accum, 'line_memo', 'accumulated depreciation relieved');
    END IF;
    v_lines := v_lines || jsonb_build_object('account_code', '1500', 'side', 'credit',
        'currency', base_currency_code(), 'amount_ccy', v_a.cost_base, 'line_memo', 'cost relieved');
    IF v_gain > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'credit',
            'currency', base_currency_code(), 'amount_ccy', v_gain);
    ELSIF v_gain < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', -v_gain);
    END IF;

    v_je := post_journal_entry(p_disposal_date,
        'Disposal ' || v_a.code || COALESCE(' — ' || p_notes, ''),
        'asset_disposal', p_asset_id, v_lines);

    UPDATE fixed_assets
    SET status = 'disposed', disposal_date = p_disposal_date,
        disposal_proceeds_base = p_proceeds, disposal_journal_id = (v_je->>'entry_id')::uuid
    WHERE id = p_asset_id;

    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_a.code,
        'cost_relieved', v_a.cost_base, 'accum_relieved', v_accum,
        'proceeds', p_proceeds, 'gain_loss', v_gain, 'journal_code', v_je->>'code');
END;
$function$;

-- db/functions/dispose_fixed_asset.sql
-- 处置:出售或报废(FIN-22)。
-- ★ APR-9(2026-09-27,Tim 的矩阵 §4「处置 | 财务 | CFO」):**这扇门只会按名拒了。** 一台资产的处置从此是一张申请 ——
--   submit_asset_disposal_request(财务提)→ decide_asset_disposal_request(CFO 批)→ 批准当场处置,处置日 = 批准日。
--   原函数体原样搬进 dispose_fixed_asset_internal(authenticated 调不到)。签名与门(module.finance.edit)不变:
--   没有码的人读到的仍是缺的那个码,有码的人读到 ASSET_DISPOSAL_NEEDS_REQUEST|<资产编号> —— 旧屏幕在部署之前按下去
--   也只会得到这一句,什么都不过账(APR-7 的 WAREHOUSE_NEEDS_APPROVED_REQUEST 同形)。
-- NOTE: introduced by db/migrations/2026-08-06-fin22-fixed-assets-and-depreciation.sql;
--       reduced to a refusal by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.dispose_fixed_asset(p_asset_id uuid, p_disposal_date date, p_proceeds numeric DEFAULT 0, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM fixed_assets WHERE id = p_asset_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    RAISE EXCEPTION 'ASSET_DISPOSAL_NEEDS_REQUEST|%', v_code;
END;
$function$;

-- db/functions/asset_disposal_execute_internal.sql
-- APR-9(2026-09-27):让一张处置申请【生效】—— 批准、审批关着时的提交、提交时的试跑,三处都走这一支,
-- 所以试跑拒的与批准拒的是同一句话。
--   1. 资产行上锁;fingerprint 再比(Q8)—— 变了 → ASSET_CHANGED_SINCE_REQUEST|label。
--   2. 处置日 = 今天(Q7:批准那一天;试跑时是提交那一天),收款与银行科目取申请上冻结的那一组,
--      摘要尾巴 = 提单人的理由。dispose_fixed_asset_internal 过账并把卡置为 disposed。
-- 【冻结放行】evoltrya.asset_disposal_ctx = 本申请 id,guard_asset_disposal_freeze 只放这一张申请自己的写。
-- 返回 dispose 的结果(成本、累计折旧、收款、损益、分录编号),外加 disposal_date、entry_id 与 amount_base
-- (处置分录的借方合计,本位币)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     asset_disposal_requests%ROWTYPE;
    v_res   jsonb;
    v_entry uuid;
    v_amt   numeric;
BEGIN
    SELECT * INTO v_r FROM asset_disposal_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    PERFORM 1 FROM fixed_assets WHERE id = v_r.asset_id FOR UPDATE;
    IF asset_disposal_fingerprint(v_r.asset_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'ASSET_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    PERFORM set_config('evoltrya.asset_disposal_ctx', v_r.id::text, true);
    v_res := dispose_fixed_asset_internal(v_r.asset_id, CURRENT_DATE, v_r.proceeds_base, v_r.bank_account, v_r.reason);
    PERFORM set_config('evoltrya.asset_disposal_ctx', '', true);

    SELECT a.disposal_journal_id INTO v_entry FROM fixed_assets a WHERE a.id = v_r.asset_id;
    SELECT COALESCE(round(sum(l.debit), 2), 0) INTO v_amt FROM journal_lines l WHERE l.entry_id = v_entry;

    RETURN v_res || jsonb_build_object('disposal_date', CURRENT_DATE, 'entry_id', v_entry, 'amount_base', v_amt);
END;
$function$;

-- db/functions/asset_disposal_dry_run.sql
-- APR-9(2026-09-27):提交时,按批准那一刻会走的同一支(asset_disposal_execute_internal)试跑一遍,然后整段回滚
-- (PQ007;journal_request_dry_run / warehouse_request_dry_run 同一个手法)。分录平衡那支延迟约束在试跑里提前到
-- IMMEDIATE 结一次账 —— 否则它要到提交才开口,试跑就说了一句假"可以"。
-- 拒绝原话原样冒出去(ASSET_HAS_NO_COST · BANK_INVALID · PERIOD_LOCKED …);成功返回那一组估算
-- (entry_id 在回滚之后不存在,调用方不存它)。内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := asset_disposal_execute_internal(p_request_id);
        SET CONSTRAINTS trg_journal_lines_balance IMMEDIATE;
        SET CONSTRAINTS trg_journal_lines_balance DEFERRED;
        RAISE EXCEPTION USING ERRCODE = 'PQ007', MESSAGE = 'ASSET_DISPOSAL_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ007' THEN
        NULL;
    END;
    RETURN v_res - 'entry_id' - 'journal_code';
END;
$function$;

-- db/functions/submit_asset_disposal_request.sql
-- APR-9(2026-09-27):财务提一张固定资产处置申请。CFO 批准才处置(Tim 的矩阵 §4,不分档;grilling Q7 · Q8 · Q10)。
--
-- 【门】module.finance.edit(处置原来的门)。
-- 【拒绝,按这个顺序】
--   ASSET_NOT_FOUND · ASSET_ALREADY_DISPOSED|<code>
--   ASSET_DISPOSAL_REASON_REQUIRED|<code>
--   PROCEEDS_INVALID · BANK_INVALID|<科目>            收款与银行科目提交时冻结(dispose 的同一句话)
--   ASSET_DISPOSAL_OPEN|<code>|<那一张>               一台资产同一时刻只挂一张在等的申请(唯一索引是第二道)
--   ASSET_DISPOSAL_NO_OTHER_DECIDER|<label>           审批开着、提单人这个人之外二级没人批得动(assert_other_decider;
--                                                     线上是 admin@:它与 tim@ 是同一个人)
--   …以及试跑按原话冒出来的一切(ASSET_HAS_NO_COST · PERIOD_LOCKED …)
-- 【试跑】落一行 submitted,按批准那一刻的同一支试跑(处置日 = 今天),estimate 与 amount_base 取试跑的结果。
-- 审批开着:留痕 submitted,二级。关着:当场处置,状态 approved,留痕 auto_approved(APR-7 同形,Q10)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_asset_disposal_request(p_asset_id uuid, p_proceeds numeric, p_bank_account text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_a     fixed_assets%ROWTYPE;
    v_bank  text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_exec  jsonb := NULL;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    IF v_a.status <> 'active' THEN
        RAISE EXCEPTION 'ASSET_ALREADY_DISPOSED|%', v_a.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_REASON_REQUIRED|%', v_a.code;
    END IF;
    IF p_proceeds IS NULL OR p_proceeds < 0 THEN
        RAISE EXCEPTION 'PROCEEDS_INVALID';
    END IF;
    IF p_proceeds > 0 THEN
        IF p_bank_account IS NULL OR p_bank_account NOT IN ('1000', '1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
        END IF;
        v_bank := p_bank_account;
    END IF;

    SELECT q.label INTO v_open FROM asset_disposal_requests q
     WHERE q.asset_id = v_a.id AND q.status = 'submitted' LIMIT 1;
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_OPEN|%|%', v_a.code, v_open;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM asset_disposal_requests q WHERE q.asset_id = v_a.id;
    v_label := v_a.code || ' · disposal #' || v_n::text;

    PERFORM assert_other_decider('asset_disposal_request', 'decide_asset_disposal_request', 2::smallint,
                                 'ASSET_DISPOSAL_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO asset_disposal_requests (id, status, label, asset_id, proceeds_base, bank_account, reason,
                                         snapshot, estimate, amount_base, created_by)
    VALUES (v_id, 'submitted', v_label, v_a.id, p_proceeds, v_bank, btrim(p_reason),
            asset_disposal_fingerprint(v_a.id), '{}'::jsonb, 0, auth.uid());

    v_dry := asset_disposal_dry_run(v_id);
    UPDATE asset_disposal_requests
       SET estimate = v_dry, amount_base = (v_dry->>'amount_base')::numeric
     WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('asset_disposal_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_exec := asset_disposal_execute_internal(v_id);
        UPDATE asset_disposal_requests
           SET status = 'approved', executed_at = now(), disposal_date = (v_exec->>'disposal_date')::date,
               result_entry_id = (v_exec->>'entry_id')::uuid, result = v_exec,
               amount_base = (v_exec->>'amount_base')::numeric
         WHERE id = v_id;
        PERFORM record_approval_decision('asset_disposal_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场处置,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'estimate', v_dry,
        'amount_base', COALESCE(v_exec->'amount_base', v_dry->'amount_base'));
END;
$function$;

-- db/functions/decide_asset_disposal_request.sql
-- APR-9(2026-09-27):CFO 批准或驳回一张固定资产处置申请。批准【当场处置】,处置日 = 批准那一天,
-- 累计折旧与损益按那一刻的活数(grilling Q7)。
--
-- 【门】module.finance.view + data.view_prices(Q10:APR-7 同一对码)—— 【不是】module.finance.edit:那是提单的码。
-- 【谁能批】二级审批人,每一张、不分档(require_approver_for(2))。【四眼】forbid_self_approval(提单人, NULL, …)
-- 按人认 —— 一台资产是公司的,主角那条腿对谁都不成立(工单同形);admin@ 提的 tim@ 批不了,所以提交时就按名拒
-- ASSET_DISPOSAL_NO_OTHER_DECIDER。
-- 【批准之前不另查】批准就是那一次真的处置:卡变了(ASSET_CHANGED_SINCE_REQUEST)、期间锁(PERIOD_LOCKED)——
-- 全按原话拒,整笔回滚,申请仍在等。驳回要理由,从不检查这些。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.decide_asset_disposal_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    asset_disposal_requests%ROWTYPE;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM asset_disposal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'asset_disposal_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'ASSET_DISPOSAL_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE asset_disposal_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('asset_disposal_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := asset_disposal_execute_internal(p_request_id);

    UPDATE asset_disposal_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), executed_at = now(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           disposal_date = (v_exec->>'disposal_date')::date,
           result_entry_id = (v_exec->>'entry_id')::uuid, result = v_exec,
           amount_base = (v_exec->>'amount_base')::numeric
     WHERE id = p_request_id;
    PERFORM record_approval_decision('asset_disposal_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'result', v_exec);
END;
$function$;

-- db/functions/withdraw_asset_disposal_request.sql
-- APR-9(2026-09-27):撤回一张在等的处置申请。谁能撤:提单人本人(按人认),或持 module.finance.edit 的人
-- (提单的那个码)。只撤 submitted。撤回什么都不处置、冻结随之解开;记在本行上,【不】写 approval_log。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.withdraw_asset_disposal_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r asset_disposal_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM asset_disposal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.finance.edit');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE asset_disposal_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;

-- db/functions/asset_disposal_requests_visible.sql
-- APR-9(2026-09-27):资产页上"处置申请"那一块读的就是这里 —— 财务看得见自己提的,CFO 看得见要他批的。
--   谁读得到:module.finance.view(资产页的门;AGENTS.md 常设决定 1:它蕴含看得见价格)。其余 → 零行。
--   p_asset_id 给了就只给那一台的;只给在等的全部 + 最近决定 / 撤回的 p_recent 张。
--   estimate(提交时试跑)与 result(批准时真的过出来的)并排给出(Q7);current_matches = 卡此刻与提交时的
--   fingerprint 一样(不一样,批准会被 ASSET_CHANGED_SINCE_REQUEST 拒,屏幕先说出来)。
--   raised_by_me = 提单人就是读者这个人(按人认);result_entry_code 给屏幕画到凭证的链接。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_requests_visible(p_asset_id uuid DEFAULT NULL::uuid, p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, status text, label text, asset_id uuid, asset_code text, asset_description text, proceeds_base numeric, bank_account text, reason text, estimate jsonb, amount_base numeric, current_matches boolean, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decision_notes text, disposal_date date, result jsonb, result_entry_id uuid, result_entry_code text, withdrawn_at timestamptz, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM asset_disposal_requests q
         WHERE has_permission('module.finance.view')
           AND (p_asset_id IS NULL OR q.asset_id = p_asset_id))
    SELECT r.id, r.status, r.label, r.asset_id, a.code, a.description, r.proceeds_base, r.bank_account, r.reason,
           r.estimate, r.amount_base,
           asset_disposal_fingerprint(r.asset_id) IS NOT DISTINCT FROM r.snapshot,
           r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.disposal_date, r.result, r.result_entry_id,
           (SELECT je.code FROM journal_entries je WHERE je.id = r.result_entry_id),
           r.withdrawn_at, r.withdraw_reason
      FROM r
      JOIN fixed_assets a ON a.id = r.asset_id
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;

-- db/functions/guard_asset_disposal_freeze.sql
-- APR-9(2026-09-27,grilling Q8):**一台资产的处置在等 CFO 的时候,卡上改得动价值的列冻结。**
-- 挂在 fixed_assets 上(BEFORE UPDATE,逐行)。成本(原币 / 币种 / 汇率 / 本位币)、残值、年限、购置日、投用日、
-- 折旧科目、状态与三支处置列,任何一样要变,而这台资产挂着一张 submitted 的处置申请 → ASSET_DISPOSAL_REQUESTED|<code>|<label>。
-- 于是:记支出往这台资产上追加成本(record_expense)、冲销它的成本明细(reverse_expense)、投用它
-- (set_asset_in_service)—— 三条路都要改这张卡,一支守卫全部拦住,没有侧门。
-- 【照常】折旧(写 fixed_asset_depreciation,不改这张卡 —— 关账要它,close_period 的 DEPRECIATION_OUTSTANDING)、
-- 保养、计划投用日、验收日、描述、类别、备注。
-- 【放行】只有那一张申请自己的执行:evoltrya.asset_disposal_ctx = 它的 id(asset_disposal_execute_internal 设)。
-- 【为什么不是 row_security_active 那一种】fixed_assets 没有写策略,每一个写它的都是属主路径;
-- 要拦的正是属主路径里的那几支函数。INVOKER:在属主路径里跑就是属主,读得到申请表。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_asset_disposal_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_req record;
BEGIN
    IF (NEW.cost_ccy, NEW.currency, NEW.fx_rate, NEW.cost_base, NEW.residual_base, NEW.useful_life_months,
        NEW.acquisition_date, NEW.in_service_date, NEW.depreciation_account_code, NEW.status,
        NEW.disposal_date, NEW.disposal_proceeds_base, NEW.disposal_journal_id)
       IS NOT DISTINCT FROM
       (OLD.cost_ccy, OLD.currency, OLD.fx_rate, OLD.cost_base, OLD.residual_base, OLD.useful_life_months,
        OLD.acquisition_date, OLD.in_service_date, OLD.depreciation_account_code, OLD.status,
        OLD.disposal_date, OLD.disposal_proceeds_base, OLD.disposal_journal_id) THEN
        RETURN NEW;
    END IF;
    SELECT q.id, q.label INTO v_req FROM asset_disposal_requests q
     WHERE q.asset_id = OLD.id AND q.status = 'submitted'
     LIMIT 1;
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;
    IF v_req.id::text = COALESCE(current_setting('evoltrya.asset_disposal_ctx', true), '') THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'ASSET_DISPOSAL_REQUESTED|%|%', OLD.code, v_req.label;
END;
$function$;

COMMENT ON FUNCTION public.guard_asset_disposal_freeze() IS
'APR-9(Q8):一台资产挂着一张在等的处置申请时,卡上的成本、残值、年限、购置日、投用日、折旧科目、状态与处置列不许变 —— ASSET_DISPOSAL_REQUESTED|资产|申请。追加成本、冲销成本明细、投用三条路因此全部按名拒;折旧、保养、计划与验收日照常。只放那一张申请自己的执行(evoltrya.asset_disposal_ctx)。';

-- db/functions/journal_entry_reversal_route.sql
-- APR-6(2026-09-25,grilling Q6):一张分录【从凭证页】怎么冲 —— 一份判据,三个读它的人
-- (reverse_journal_entry 那扇只会拒的门 · 冲销申请的提交与过账 · 凭证页上那颗钮灰不灰、说什么)。
--
--   'reversed'     已经冲过(status <> posted 或 reversed_by 已挂上)—— 不能再冲。
--   'source_path'  有自己冲销路径的:付款 · 转账 · 代扣税缴纳(各自的冲销申请)、purchase(改价申请)、
--                  invoice / credit_note(作废 / 贷项申请)、expense(reverse_expense)、freight
--                  (reverse_freight_document)、allocation / processing_cost(重分摊 / 加工回滚)、year_close
--                  (reopen_financial_year)、工资期的【过账】分录与它的冲销(撤销申请)。凭证页按名拒
--                  JE_REVERSE_USE_SOURCE_PATH —— 从这里冲掉,总账回来了,那张单据却不知道。
--   'request'      其余一切:手工凭证,以及没有自己路径的系统分录(sale · stocktake · writeoff · prepayment ·
--                  revaluation · depreciation · shipment · fx · 工资的【付款】分录)。
--   ★ APR-9(grilling Q9):asset_disposal 从 'request' 挪进 'source_path'。处置从此经 CFO 批的申请过账,
--     而冲掉它的分录只会把总账拿回来、资产卡照旧是 disposed(APR4-DISPOSAL-REVERSAL-LEAVES-ASSET-DISPOSED)——
--     总账与卡不许说两句话。处置【还没有】自己的撤销路径(known-issues:APR9-NO-DISPOSAL-REVERSAL-YET);
--     在它之前,这张分录从凭证页冲不掉。
--                  从凭证页冲它们是一个人的裁量,走同一张 CFO 冲销申请(Q6 (i)(iii))。
--   NULL           没有这张分录。
--
-- 【冲销分录抄原分录的 source_type】所以一张冲销分录落在与原分录同一格 —— 冲掉一张作废留下的冲销,
-- 同样是 source_path(否则 = 不经批准地复活发票),与 reverse_journal_entry 一直以来的判法一致。
-- 工资那一段原样搬自 reverse_journal_entry(PAYROLL-APR-1 Q5):只有被 payroll_lines.paid_journal_entry_id /
-- payroll_periods.cpf_journal_entry_id / deductions_journal_entry_id 指着的【付款】分录(以及它们的冲销)不算
-- source_path —— 它们没有正经的冲销路径(PAYROLL-PAYMENT-NO-REVERSAL-PATH),APR-6 起走冲销申请。
--
-- DEFINER:它读工资表(一个持 finance.view 却读不到 payroll_lines 的人,INVOKER 下会把一张工资过账分录
-- 错读成 'request' —— xmodule 那一族)。本体【不问码】:它也在批准与试跑的内层被调用(那里的主语未必持
-- 凭证页的码,以 postgres 跑的 fixture 根本没有主语);而它只回一个词,不回任何金额、任何行
-- (db/check_mirrors.py DEFINER_NO_CHECK_ALLOWED 记着这条理由)。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_entry_reversal_route(p_entry_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_je journal_entries%ROWTYPE;
BEGIN
    SELECT * INTO v_je FROM journal_entries WHERE id = p_entry_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    IF v_je.status <> 'posted' OR v_je.reversed_by IS NOT NULL THEN
        RETURN 'reversed';
    END IF;
    IF v_je.source_type IN ('payment', 'transfer', 'wht_remittance', 'purchase', 'invoice', 'credit_note',
                            'expense', 'freight', 'allocation', 'processing_cost', 'year_close',
                            'asset_disposal') THEN
        RETURN 'source_path';
    END IF;
    IF v_je.source_type = 'payroll' AND NOT (
           EXISTS (SELECT 1 FROM payroll_lines pl
                    WHERE pl.paid_journal_entry_id IN (v_je.id, v_je.source_id))
           OR EXISTS (SELECT 1 FROM payroll_periods pp
                       WHERE pp.cpf_journal_entry_id IN (v_je.id, v_je.source_id)
                          OR pp.deductions_journal_entry_id IN (v_je.id, v_je.source_id))) THEN
        RETURN 'source_path';
    END IF;
    RETURN 'request';
END;
$function$;

-- ─── record_approval_decision
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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废 · 手工凭证 · 仓库(注销 / 回滚 / 证书作废)· 条款(公式 / 合同生效)· 资产处置八种申请与发货放行 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ APR-9 的调薪申请 false、fixed_level NULL、金额 NULL:它不看审批开关,按人路由(pay_decision_code),不在 approval_chain_gates 里。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

-- db/functions/approval_chain_gates.sql
-- APR-2:【哪些链接上了 require_approver_for,以及那条链自己的门是什么】
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ 它存在的理由,是一个【实测出来的、当时活在线上的】死锁 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- `require_approver_for(N)` 问的是「你在不在第 N 级那个【角色】里」。
-- 而每一支决定函数【另外】问一句「你持不持有本模块的那个【权限码】」。
-- ★ 在 APR-2 之前,【没有任何东西断言这两个集合有交集】。
--
-- 实测(2026-09-22,以 postgres 读 user_roles / role_permissions / auth.users 基表,
-- 以及 require_approver_for 自己的答案):
--
--   一级 = finance = chooer@evoltrya.test  —— 他【不】持 module.processing.edit
--   二级 = cfo     = admin@swm-os.test
--
--   | 链           | 模块门                              | 持有人                  | ∩ 一级 |
--   |--------------|-------------------------------------|-------------------------|--------|
--   | 采购单       | purchasing.view + data.view_prices  | admin chooer phua sandra vince | chooer ✓ |
--   | ★ 工单       | processing.edit                     | admin phua sandra vince | ★ 空   |
--
-- ☞ 也就是说:**审批一打开,线上就没有任何人放行得了一张工单** ——
--   而 WO-1b 把那一行 require_approver_for(1) 写下去的时候,三道闸全绿。
--   今天 work_orders 里 draft = 0,所以没有单据卡住;下一张就再也放行不了。
--   ★ APR-2 的处置是把工单从这台引擎的【路由】那一半摘下来(Tim 的 Q1 裁定:
--     按角色分级只管【带钱的单据】),于是 APR-2 结束时本表只剩采购单两支。
-- ★ APR-3(2026-09-22)加进报销单两行 —— 本仓库第二条接上按角色分级的链。
-- ★ PAY-REQ-1(2026-09-23)加进付款申请【一行】(只有二级:CFO 批每一张)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这是一张手写的名册,所以它必须被核对,不能被相信】
-- ════════════════════════════════════════════════════════════════════════════
-- 一张与代码分开维护的清单,迟早与代码漂开,而漂开的那一刻它仍然全绿。
-- 所以 db/fixtures/203 有一条【目录派生】的断言:
--     SELECT proname FROM pg_proc WHERE prosrc LIKE '%require_approver_for%'
-- 那个集合必须与本函数的 action_function 列【逐字相等】。
-- ☞ 加一条链接上 require_approver_for,就要在这里加一行,否则 fixture 当场变红。
--
-- 【为什么门是一个数组,不是一个码】approve_purchase_order 要【两个】:
-- module.purchasing.view(进得了模块)+ data.view_prices(看得见他要批的那个数,
-- R4)。而 reject_purchase_order 只要前一个 —— 驳回不需要看见金额。
-- **两支函数的门不一样,所以它们各占一行,不合并。**
--
-- 【为什么不是 SECURITY DEFINER】它是一张常量表,不读任何东西。
--
-- NOTE: introduced by db/migrations/2026-09-22-apr2-self-approval-and-the-approver-that-nobody-is.sql.

CREATE OR REPLACE FUNCTION public.approval_chain_gates()
 RETURNS TABLE(subject_type text, action_function text, level smallint, gate_permissions text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT v.subject_type, v.action_function, v.level, v.gate_permissions
      FROM (VALUES
        ('purchase_order'::text, 'approve_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view', 'data.view_purchase_prices']::text[]),
        ('purchase_order'::text, 'approve_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view', 'data.view_purchase_prices']::text[]),
        -- ★ ROLE-1 Batch 4a(2026-09-25):采购单的金额是【采购那一侧】的价格 —— 批准的门换成
        --   data.view_purchase_prices(今天持 view_prices 的每一个角色一并拿到它)。报销单与付款申请不动。
        -- 驳回【不】要 data.view_prices —— 它仍然按金额分级(所以两级都在),
        -- 而它不显示那个金额。门窄一格,所以它自己一行。
        ('purchase_order'::text, 'reject_purchase_order'::text, 1::smallint,
            ARRAY['module.purchasing.view']::text[]),
        ('purchase_order'::text, 'reject_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view']::text[]),
        -- ★★ APR-3(Tim 的 Q1):报销单。门是【module.finance.view + data.view_prices】,
        --    【不是】module.finance.edit —— 采购单那条链的形状,原样照搬。
        --    两条理由,都在 docs/approvals.md §0 与 §5 里已经成立:
        --    ① 批的人不该是提得了这张单的人(edit 就是提单的那个码);
        --    ② R4:批的人必须看得见他批的那个数,而这条链【按金额分档】。
        --    ★ 实测的第三条,也是决定性的那条:cfo 持 module.finance.view 与
        --      data.view_prices,【不持】module.finance.edit。写成 edit 的话,
        --      今天二级之所以还有一个人,靠的只是 cfo 的唯一真持有人就是 admin
        --      账号(§0b 记着的那次撞车)—— Tim 一拿到独立的 CFO 账号、把 cfo
        --      从 admin 上收回,二级当场归零,而那一天没有任何东西会说是这一刀
        --      造成的。写成 view + prices,那一天它仍然是 1。
        --    【approve 与 reject 不分两行】与采购单不同:本链两支分支【都】分档
        --    (驳回也落一行带 level 的留痕),所以两边都要看得见金额,门一样宽。
        ('expense_claim'::text, 'decide_expense_claim'::text, 1::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        ('expense_claim'::text, 'decide_expense_claim'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        -- ★★ PAY-REQ-1(Tim 的矩阵:付款与冲销付款,CFO 批每一张,不分档):
        --    【只有二级这一行】。decide_payment_request 直接要二级审批人(不按金额分档),
        --    (★ 这句注释【不写】那支函数的名字:203E 按 prosrc 数它的调用方,注释也算。)
        --    从不经 approval_level_for —— 所以一级那一行不存在,而不是"门一样宽所以省了"。
        --    门与报销单同一对码,理由同上(提单的码是 edit;R4 要看得见金额)。
        ('payment_request'::text, 'decide_payment_request'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        -- ★★ PAYROLL-APR-1(Tim 的矩阵:工资过账与撤销,CFO 批每一张,不分档):同样【只有二级
        --    这一行】,理由与付款申请逐字同一条。门是 module.hr.view + data.view_pay(Tim 的 Q8)——
        --    工资期页的门,加上看得见工资数的那个码(§5:批的人必须看得见他批的那个数);
        --    【不是】module.hr.edit:那是提单的码。
        ('payroll_request'::text, 'decide_payroll_request'::text, 2::smallint,
            ARRAY['module.hr.view', 'data.view_pay']::text[]),
        -- ★★ ROLE-1 Batch 4b(Tim 的矩阵:收货定价与改价,CFO 批每一张,不分档;批准当场过账):
        --    同样【只有二级这一行】,理由与付款申请逐字同一条。门是 module.inbound.view +
        --    data.view_purchase_prices(Tim 的 Q2)—— 收货页的门,加上看得见采购价的那个码;
        --    【不是】action.price_receipts:那是提单的码。
        ('receipt_price_request'::text, 'decide_receipt_price_request'::text, 2::smallint,
            ARRAY['module.inbound.view', 'data.view_purchase_prices']::text[]),
        -- ★★ APR-5a(Tim 的矩阵:贷项通知、作废发票,CFO 批每一张,不分档;批准当场过账):
        --    同样【只有二级这一行】,理由与付款申请逐字同一条。门与付款申请同一对码 ——
        --    module.finance.view + data.view_prices(发票页的门,加上看得见金额的那个码);
        --    【不是】module.finance.edit:那是提单的码。
        ('invoice_request'::text, 'decide_invoice_request'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        -- ★★ APR-5b(Tim 的矩阵:发货在 CFO 放行之后;APR-5 grilling Q13):同样【只有二级这一行】。
        --    门 module.sales.view + data.view_prices —— 订单页的门,加上看得见金额的那个码;
        --    【不是】action.request_shipping_release:那是提单的码。
        ('shipping_release'::text, 'decide_shipping_release'::text, 2::smallint,
            ARRAY['module.sales.view', 'data.view_prices']::text[]),
        -- ★★ APR-6(Tim 的矩阵:手工凭证与冲销,CFO 批每一张,不分档;批准当场过账;N1 对 journal_entries 退休):
        --    同样【只有二级这一行】。门与付款、贷项申请同一对码 —— module.finance.view + data.view_prices
        --    (凭证页的门,加上看得见金额的那个码);【不是】module.finance.edit:那是提单的码。
        ('journal_request'::text, 'decide_journal_request'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        -- ★★ APR-7(Tim 的矩阵:注销批次、加工回滚、作废销毁证书 —— 仓库提,CFO 批每一张,不分档;批准当场生效):
        --    同样【只有二级这一行】。门与付款、贷项、手工凭证申请同一对码 —— module.finance.view + data.view_prices
        --    (grilling Q8,四种一个门);【不是】action.batch_write_off / processing_rollback / issue_cod:那是提单的码。
        ('warehouse_request'::text, 'decide_warehouse_request'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        -- ★★ APR-8(Tim 的矩阵:合同条款与定价公式 —— cco 提,CFO 批每一张,不分档;批准当场生效):
        --    同样【只有二级这一行】。门 = 看得见公式(module.pricing.view)与它两个方向的价格(data.view_prices ·
        --    data.view_purchase_prices),看得见两侧的合同(module.suppliers.view · module.customers.view)——
        --    grilling Q4,四种一个门,cfo 五个都持;【不是】module.pricing.edit / action.contract_terms:那是提单的码。
        ('terms_request'::text, 'decide_terms_request'::text, 2::smallint,
            ARRAY['module.pricing.view', 'data.view_prices', 'data.view_purchase_prices',
                  'module.suppliers.view', 'module.customers.view']::text[]),
        -- ★★ APR-9(Tim 的矩阵:固定资产处置 —— 财务提,CFO 批每一张,不分档;批准当场处置,处置日 = 批准日):
        --    同样【只有二级这一行】。门与 APR-7 同一对码 —— module.finance.view + data.view_prices(资产页的门,
        --    加上看得见金额的那个码);【不是】module.finance.edit:那是提单的码。
        --    ☞ 同一刀的调薪申请【不在】这本名册里(APR-9 grilling Q2):它按【人】路由(CFO 是当事人 → cco,
        --      pay_decision_code),而这本名册按【级】找人;决定它的那一支也不调用按级要审批人的那一支
        --      (★ 这句注释【不写】那支函数的名字:203E 按 prosrc 数它的调用方,注释也算 —— PAY-REQ-1 那一行的教训)。
        ('asset_disposal_request'::text, 'decide_asset_disposal_request'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- ── 4 · 两支守卫(Q1 · Q8)────────────────────────────────────────────────
CREATE TRIGGER trg_performance_reviews_guard_write
    BEFORE INSERT OR UPDATE ON public.performance_reviews
    FOR EACH ROW EXECUTE FUNCTION public.guard_performance_review_write();
CREATE TRIGGER trg_fixed_assets_disposal_freeze
    BEFORE UPDATE ON public.fixed_assets
    FOR EACH ROW EXECUTE FUNCTION public.guard_asset_disposal_freeze();

-- ── 5 · EXECUTE:内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)────────
REVOKE EXECUTE ON FUNCTION public.salary_change_execute_internal(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_fingerprint(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_open(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_change_deciders(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.salary_effective_period_block(date) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.pay_decision_code(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_execute_internal(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_dry_run(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_fingerprint(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.dispose_fixed_asset_internal(uuid, date, numeric, text, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_salary_change_request(uuid, numeric, date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.decide_salary_change_request(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.withdraw_salary_change_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.salary_change_requests_visible(uuid, integer) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_asset_disposal_request(uuid, numeric, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.decide_asset_disposal_request(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.withdraw_asset_disposal_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.asset_disposal_requests_visible(uuid, integer) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.guard_performance_review_write() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.guard_asset_disposal_freeze() FROM PUBLIC, anon;

-- ── 6 · operations_now:加两支 asset_disposal_pending · salary_change_pending(镜像原样)──────
CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
        UNION ALL
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text AND w.scheduled_date IS NOT NULL AND w.scheduled_date < CURRENT_DATE
        UNION ALL
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
                CASE
                    WHEN f.side = 'input'::text THEN (((('input overrun · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                    ELSE (((('output shortfall · '::text || COALESCE(f.material_code, '?'::text)) || ' · '::text) || trim_scale(f.actual_qty)::text) || ' / '::text) || trim_scale(f.planned_or_expected_qty)::text
                END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan AND f.planned_or_expected_qty > 0::numeric AND (f.side = 'input'::text AND (w2.status = ANY (ARRAY['released'::text, 'closed'::text])) AND f.actual_qty > (f.planned_or_expected_qty * (1::numeric + (( SELECT ps.wo_input_overrun_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)) OR f.side = 'output'::text AND w2.status = 'closed'::text AND f.actual_qty < (f.planned_or_expected_qty * (1::numeric - (( SELECT ps.wo_output_shortfall_pct
                   FROM processing_settings ps
                 LIMIT 1)) / 100::numeric)))
        UNION ALL
         SELECT 'free_time_expiring'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((((q.free_days - (CURRENT_DATE - arr.event_date))::text) || ' left of '::text) || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id AND q.deleted_at IS NULL AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL AND q.free_days IS NOT NULL AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
         SELECT 'container_no_arrival'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL AND (CURRENT_DATE - dep.event_date) >= 14 AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m2
                  WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL AND c.expected_arrival_date IS NOT NULL AND c.expected_arrival_date < CURRENT_DATE AND NOT (EXISTS ( SELECT 1
                   FROM container_milestones m3
                  WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
         SELECT 'container_documents_late'::text AS item_type,
            'module.logistics.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL AND p.n > 0 AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
        UNION ALL
         SELECT 'promise_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            ps.promise_id AS item_id,
            NULL::text AS doc_kind,
            ps.chase_code AS item_code,
            ps.customer_name AS subject,
            ps.promised_date AS item_date
           FROM collection_promise_status ps
          WHERE ps.is_overdue
        UNION ALL
         SELECT 'wht_due'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            to_char(w.period_month::timestamp without time zone, 'YYYY-MM'::text) AS item_code,
            (to_char(w.unremitted_base, 'FM999G999G990D00'::text) || ' '::text) || (( SELECT c.code
                   FROM currencies c
                  WHERE c.is_base)) AS subject,
            w.due_date AS item_date
           FROM wht_liability_by_month w
          WHERE w.unremitted_base > 0::numeric AND (w.due_date - CURRENT_DATE) <= 7
        UNION ALL
         SELECT 'company_licence_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            NULL::text AS doc_kind,
            COALESCE(cc.cert_no, ct.code) AS item_code,
            ct.name_en AS subject,
            cc.valid_until AS item_date
           FROM company_compliance cc
             JOIN certificate_types ct ON ct.code = cc.cert_type_code
          WHERE cc.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND cc.valid_until IS NOT NULL AND cc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'import_permit_unverified'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            ib.code AS item_code,
            s.legal_name AS subject,
            ib.arrival_date AS item_date
           FROM inbound_batches ib
             JOIN suppliers s ON s.id = ib.supplier_id
          WHERE ib.deleted_at IS NULL AND ib.imported IS TRUE AND ib.import_permit_verified_at IS NULL
        UNION ALL
         SELECT 'payment_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            pr.id AS item_id,
            NULL::text AS doc_kind,
            pr.code AS item_code,
            COALESCE(s.legal_name, e.legal_name, c.legal_name) AS subject,
            pr.created_at::date AS item_date
           FROM payment_requests pr
             LEFT JOIN suppliers s ON s.id = pr.supplier_id
             LEFT JOIN employees e ON e.id = pr.employee_id
             LEFT JOIN customers c ON c.id = pr.customer_id
          WHERE pr.status = 'submitted'::text
        UNION ALL
         SELECT 'supplier_pending_approval'::text AS item_type,
            'action.supplier_approve'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            s.legal_name AS subject,
            COALESCE(( SELECT max(h.changed_at) AS max
                   FROM supplier_status_history h
                  WHERE h.supplier_id = s.id AND h.to_status = 'pending_review'::text), s.updated_at)::date AS item_date
           FROM suppliers s
          WHERE s.status = 'pending_review'::supplier_status AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'payroll_request_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            q.payroll_period_id AS item_id,
            NULL::text AS doc_kind,
            q.label AS item_code,
            pp.code AS subject,
            q.created_at::date AS item_date
           FROM payroll_requests q
             JOIN payroll_periods pp ON pp.id = q.payroll_period_id
          WHERE q.status = 'submitted'::text
        UNION ALL
         SELECT 'receipt_price_request_pending'::text AS item_type,
            'data.view_purchase_prices'::text AS permission,
            rq.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            rq.label AS item_code,
            ib.code AS subject,
            rq.created_at::date AS item_date
           FROM receipt_price_requests rq
             JOIN inbound_batches ib ON ib.id = rq.inbound_batch_id
          WHERE rq.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            iq.invoice_id AS item_id,
            NULL::text AS doc_kind,
            iq.label AS item_code,
            c.legal_name AS subject,
            iq.created_at::date AS item_date
           FROM invoice_requests iq
             JOIN invoices i ON i.id = iq.invoice_id
             JOIN customers c ON c.id = i.customer_id
          WHERE iq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_pending'::text AS item_type,
            'module.sales.view'::text AS permission,
            sr.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            sr.label AS item_code,
            c.legal_name AS subject,
            sr.created_at::date AS item_date
           FROM shipping_releases sr
             JOIN sales_orders so ON so.id = sr.sales_order_id
             JOIN customers c ON c.id = so.customer_id
          WHERE sr.status = 'submitted'::text
        UNION ALL
         SELECT 'journal_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            jq.id AS item_id,
            NULL::text AS doc_kind,
            jq.label AS item_code,
            jq.memo AS subject,
            jq.created_at::date AS item_date
           FROM journal_requests jq
          WHERE jq.status = 'submitted'::text
        UNION ALL
         SELECT 'warehouse_request_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            wq.id AS item_id,
            NULL::text AS doc_kind,
            wq.label AS item_code,
            wq.reason AS subject,
            wq.created_at::date AS item_date
           FROM warehouse_requests wq
          WHERE wq.status = 'submitted'::text
        UNION ALL
         SELECT 'terms_request_pending'::text AS item_type,
            'module.pricing.view'::text AS permission,
            tq.id AS item_id,
                CASE
                    WHEN tq.contract_id IS NOT NULL THEN 'contract'::text
                    ELSE 'formula'::text
                END AS doc_kind,
            tq.label AS item_code,
            tq.reason AS subject,
            tq.created_at::date AS item_date
           FROM terms_requests tq
          WHERE tq.status = 'submitted'::text
        UNION ALL
         SELECT 'asset_disposal_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            dq.id AS item_id,
            NULL::text AS doc_kind,
            dq.label AS item_code,
            dq.reason AS subject,
            dq.created_at::date AS item_date
           FROM asset_disposal_requests dq
          WHERE dq.status = 'submitted'::text
        UNION ALL
         SELECT 'salary_change_pending'::text AS item_type,
            'data.view_pay'::text AS permission,
            sq.employee_id AS item_id,
            NULL::text AS doc_kind,
            sq.label AS item_code,
            sq.reason AS subject,
            sq.created_at::date AS item_date
           FROM salary_change_requests sq
          WHERE sq.status = 'submitted'::text
        UNION ALL
         SELECT 'shipping_release_ready'::text AS item_type,
            'action.ship_goods'::text AS permission,
            q.sales_order_id AS item_id,
            NULL::text AS doc_kind,
            q.order_code AS item_code,
            q.customer_name AS subject,
            q.released_on AS item_date
           FROM ( SELECT so.id AS sales_order_id,
                    so.code AS order_code,
                    c.legal_name AS customer_name,
                    max(r.decided_at)::date AS released_on
                   FROM shipping_releases r
                     JOIN shipping_release_lines rl ON rl.release_id = r.id
                     JOIN invoice_lines il ON il.id = rl.invoice_line_id
                     JOIN sales_orders so ON so.id = r.sales_order_id
                     JOIN customers c ON c.id = so.customer_id
                  WHERE r.status = 'approved'::text AND NOT il.invoice_voided
                    AND so.deleted_at IS NULL
                    AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))
                    AND (( SELECT ra.releasable_qty
                           FROM sales_order_line_releasable_all ra
                          WHERE ra.invoice_line_id = il.id)) > COALESCE(( SELECT sum(sl.qty) AS sum
                           FROM shipment_lines sl
                          WHERE sl.sales_order_line_id = rl.sales_order_line_id), 0::numeric)
                  GROUP BY so.id, so.code, c.legal_name) q) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

-- ── 7 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.a9_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE a9_pending_after ON COMMIT DROP AS
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
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a9_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a9_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR9_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR9_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、资产、折旧、月薪、履历、评估一行没变;两张申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a9_pending_before b EXCEPT SELECT a.k, a.id FROM a9_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a9_pending_after a EXCEPT SELECT b.k, b.id FROM a9_pending_before b)) THEN
        RAISE EXCEPTION 'APR9_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a9_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM fixed_assets) AS assets,
       (SELECT count(*) FROM fixed_assets WHERE status = 'disposed') AS assets_disposed,
       (SELECT round(sum(cost_base), 2) FROM fixed_assets) AS asset_cost,
       (SELECT count(*) FROM fixed_asset_depreciation) AS depreciation_rows,
       (SELECT count(*) FROM employees WHERE monthly_salary IS NOT NULL) AS salaries_set,
       (SELECT md5(COALESCE(string_agg(id::text || ':' || monthly_salary::text, ',' ORDER BY id), ''))
          FROM employees WHERE monthly_salary IS NOT NULL) AS salary_digest,
       (SELECT count(*) FROM employment_history) AS employment_history,
       (SELECT count(*) FROM performance_reviews) AS reviews) n) THEN
        RAISE EXCEPTION 'APR9_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a9_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM fixed_assets) AS assets,
       (SELECT count(*) FROM fixed_assets WHERE status = 'disposed') AS assets_disposed,
       (SELECT round(sum(cost_base), 2) FROM fixed_assets) AS asset_cost,
       (SELECT count(*) FROM fixed_asset_depreciation) AS depreciation_rows,
       (SELECT count(*) FROM employees WHERE monthly_salary IS NOT NULL) AS salaries_set,
       (SELECT md5(COALESCE(string_agg(id::text || ':' || monthly_salary::text, ',' ORDER BY id), ''))
          FROM employees WHERE monthly_salary IS NOT NULL) AS salary_digest,
       (SELECT count(*) FROM employment_history) AS employment_history,
       (SELECT count(*) FROM performance_reviews) AS reviews) n);
    END IF;
    IF EXISTS (SELECT 1 FROM salary_change_requests) OR EXISTS (SELECT 1 FROM asset_disposal_requests) THEN
        RAISE EXCEPTION 'APR9_PROOF|a request table is not empty';
    END IF;

    -- ④ 结构:两张申请表没有写策略;两支守卫挂上;内层算子 authenticated 调不到;
    --    名册里处置一行、只有二级;调薪【不在】名册里
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('salary_change_requests', 'asset_disposal_requests') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR9_PROOF|a request table has a write policy';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_performance_reviews_guard_write', 'trg_fixed_assets_disposal_freeze');
    IF v_n <> 2 THEN RAISE EXCEPTION 'APR9_PROOF|expected 2 guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY['public.salary_change_execute_internal(uuid)', 'public.salary_change_fingerprint(uuid)', 'public.salary_change_open(uuid)', 'public.salary_change_deciders(uuid, uuid)', 'public.salary_effective_period_block(date)', 'public.pay_decision_code(uuid, uuid)', 'public.asset_disposal_execute_internal(uuid)', 'public.asset_disposal_dry_run(uuid)', 'public.asset_disposal_fingerprint(uuid)', 'public.dispose_fixed_asset_internal(uuid, date, numeric, text, text)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR9_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'asset_disposal_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR9_PROOF|asset_disposal_request chain row';
    END IF;
    IF EXISTS (SELECT 1 FROM approval_chain_gates() WHERE subject_type = 'salary_change_request') THEN
        RAISE EXCEPTION 'APR9_PROOF|salary_change_request must not be in approval_chain_gates (Q2)';
    END IF;
    IF journal_entry_reversal_route(NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'APR9_PROOF|reversal route of nothing';
    END IF;

    -- ⑤ 一份判据:review_approval_code 与 pay_decision_code 对每一对(账号 × 员工)逐字相等
    SELECT count(*) INTO v_n
      FROM auth.users u CROSS JOIN employees e
     WHERE e.deleted_at IS NULL
       AND review_approval_code(u.id, e.id) IS DISTINCT FROM pay_decision_code(u.id, e.id);
    IF v_n > 0 THEN RAISE EXCEPTION 'APR9_PROOF|review_approval_code and pay_decision_code disagree on % pairs', v_n; END IF;

    -- ⑥ 处置链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('asset_disposal_request', 'decide_asset_disposal_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR9_PROOF|nobody can decide an asset disposal'; END IF;
    RAISE NOTICE 'APR9 deciders for asset_disposal_request: %', v_n;

    -- ⑦ 调薪:每一个真能提单的人(module.hr.edit + data.view_pay)替每一名在职员工(不是他自己)提,
    --    都还有一个不是当事人的决定人 —— 除非落进 Step 0 量过的那一格(提单人与主角把两条路都占了)。
    --    这里只数、只报,不拒:那一格由提交时的 SALARY_CHANGE_NO_OTHER_DECIDER 按名拒(Q4 的一部分)。
    FOR k, v_bad IN
        SELECT (SELECT email::text FROM auth.users WHERE id = r.user_id) || ' → ' || e.code,
               COALESCE((SELECT string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = d.user_id), ' ')
                           FROM salary_change_deciders(r.user_id, e.id) d), '(nobody — refused at submit)')
          FROM (SELECT DISTINCT rg.user_id FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id
                 CROSS JOIN LATERAL real_role_grants(ro.code) rg
                 WHERE rp.permission_code = 'module.hr.edit'
                   AND rg.user_id IN (SELECT rg2.user_id FROM role_permissions rp2 JOIN roles ro2 ON ro2.id = rp2.role_id
                                       CROSS JOIN LATERAL real_role_grants(ro2.code) rg2
                                       WHERE rp2.permission_code = 'data.view_pay')) r
         CROSS JOIN employees e
         WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'
           AND self_leg(NULL, e.id, r.user_id) = 'none'
         ORDER BY 1
    LOOP
        RAISE NOTICE 'APR9 salary route % : %', k, v_bad;
    END LOOP;

    -- ⑧ 每一张在途单据 —— 连同每一条申请链与调薪 —— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a9_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR9 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a9_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR9_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a9_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a9_pending_decider_check(boolean);

COMMIT;

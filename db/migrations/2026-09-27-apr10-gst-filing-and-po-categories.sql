-- db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql
-- APR-10 —— GST 申报等 CFO 批数字;采购单按品类开、按开单人或这一类的码改
-- (docs/role-matrix.md §2「GST 申报与更正 | 财务 | CFO」·§6「开采购单,按品类」「修改、取消、关闭采购单」)。
-- 由 db/scripts/build_apr10_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-10 grilling Q1–Q9,Tim 2026-09-27:Q1–Q6、Q8、Q9 照建议,Q7 另裁)
--   ① GST 申报申请(Q1–Q4):gst_filing_requests。财务提(module.finance.edit),冻结那一季 F5 每一格;CFO 批
--      (二级,不分档)—— 再判锁、再算一遍,逐字相等才把那一组抄进 gst_return_boxes,期间 open → approved;
--      财务去 IRAS 报之后用 record_gst_filing 一步记下申报日与参考号(approved → filed)。file_gst_return 只会按名拒
--      GST_FILING_NEEDS_APPROVED_REQUEST。开更正件(F7)仍是一步;报 F7 走同一张申请。在等的时候把锁挪回那一季
--      按名拒(guard_gst_filing_lock,挂在 finance_settings 上)。APR-9 处置的形状:名册二级一行、blocks_disable、
--      审批关着时生下来就批准;提单人之外没人批得动 → 提交就拒。
--   ② 采购单品类(Q5 · Q6 · Q8 · Q9):purchase_orders.category(consumables / equipment_goods / office),
--      线上 11 张全部回填 equipment_goods(Step 0 量过:每一张买的都是电池原料或设备);生下来就定死;
--      资产行与电池料行只能在 equipment_goods 里。三个开单码(新码同一迁移里也授给 admin —— 常设裁定):
--      action.raise_po_consumables → warehouse · action.raise_po_equipment → cco · action.raise_po_office → finance;
--      warehouse 另拿 module.purchasing.view。module.purchasing.edit 从此不开单。
--   ③ 谁能改 / 取消 / 关闭 / 重开(Q7,Tim 另裁):开单人本人,或此刻持这张单那一类开单码的人 —— 其余按名拒
--      PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager / po_may_manage)。批准照旧。
--   ④ 提单人之外没人批得动时,开单就拒 PO_NO_OTHER_DECIDER(关掉 ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的采购单那一半)。
--   ⑤ 采购单四张表没有直连写:12 条写策略拿掉,guard_po_direct_write 按名拒 PO_THROUGH_FUNCTION_ONLY。
--
-- 【不做什么】不碰审批开关与策略;不碰 user_roles;不写任何业务行(回填那一列除外);不给 cto 收回任何码
-- (它仍持 module.purchasing.edit —— 只是那个码不再开单、不再改单)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 恰好裁定的那些行;在途单据一张不少、一张不多;
-- 留痕、分录、GST 期间与快照、采购单(除新列外)一行没变;申请表是空的、没有写策略;五张表没有写策略;守卫挂上;
-- 内层算子 authenticated 调不到;GST 链二级有人批;每一张在途单据都还有一个【不是它自己当事人】的决定人。
-- 断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR10_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.gst_filing_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR10_PRE|gst_filing_requests already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'purchase_orders' AND column_name = 'category') THEN
        RAISE EXCEPTION 'APR10_PRE|purchase_orders.category already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'action.raise_po_%') THEN
        RAISE EXCEPTION 'APR10_PRE|a raise code already exists';
    END IF;
    -- GST 的决定人要持两个门码(cfo 持;Step 0 读过)
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR10_PRE|cfo does not hold the two codes the GST chain routes to it';
    END IF;
    -- Step 0 的读数:没有一张在途的采购单;没有一期批准过或申报过的 GST
    IF EXISTS (SELECT 1 FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'APR10_PRE|a purchase order is pending';
    END IF;
    IF EXISTS (SELECT 1 FROM gst_periods WHERE status <> 'open') OR EXISTS (SELECT 1 FROM gst_return_boxes) THEN
        RAISE EXCEPTION 'APR10_PRE|a GST period is already filed';
    END IF;
    -- 回填的依据(Q5):没有一张单带着「不该是 equipment_goods」的行 —— 这里没有办公用品与耗材的行可言,
    -- 只核对每一张都是资产行或物料行(买的是电池原料或设备)
    IF EXISTS (SELECT 1 FROM purchase_orders po
                WHERE NOT EXISTS (SELECT 1 FROM purchase_order_lines l WHERE l.purchase_order_id = po.id)) THEN
        RAISE EXCEPTION 'APR10_PRE|a purchase order without lines';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a10_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE a10_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(filed_on::text, '-'), ',' ORDER BY code), ''))
          FROM gst_periods) AS gst_periods,
       (SELECT count(*) FROM gst_return_boxes) AS gst_return_boxes,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || approval_status || ':' || estimated_total_ccy::text
                                       || ':' || COALESCE(updated_at::text, '-'), ',' ORDER BY code), ''))
          FROM purchase_orders) AS purchase_orders,
       (SELECT count(*) FROM purchase_order_lines) AS po_lines,
       (SELECT count(*) FROM purchase_order_payment_terms) AS po_terms,
       (SELECT count(*) FROM purchase_order_history) AS po_history,
       (SELECT locked_before FROM finance_settings) AS locked_before;
CREATE TEMP TABLE a10_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 三个开单码(镜像原样)与 module.purchasing.edit 的说明(它不再开单)──────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.raise_po_consumables', 'action', 'Raise factory-consumables POs', '开工厂耗材采购单', 'Raise a purchase order in the factory-consumables category. Whoever raised a PO, or anyone who holds its category''s raise code, may amend, cancel, close or reopen it. Approval tiers are unchanged.', '开一张「工厂耗材」类的采购单。一张单的开单人,或持这一类开单码的人,能改、取消、关闭、重开它。分级审批不变。', 1170),
    ('action.raise_po_equipment', 'action', 'Raise equipment-and-goods POs', '开设备与货物采购单', 'Raise a purchase order in the equipment-and-goods category — equipment, and the battery material the company buys to process. Whoever raised a PO, or anyone who holds its category''s raise code, may amend, cancel, close or reopen it. Approval tiers are unchanged.', '开一张「设备与货物」类的采购单 —— 设备,以及公司买来加工的电池料。一张单的开单人,或持这一类开单码的人,能改、取消、关闭、重开它。分级审批不变。', 1180),
    ('action.raise_po_office', 'action', 'Raise office-supplies POs', '开办公用品采购单', 'Raise a purchase order in the office-supplies category. Whoever raised a PO, or anyone who holds its category''s raise code, may amend, cancel, close or reopen it. Approval tiers are unchanged.', '开一张「办公用品」类的采购单。一张单的开单人,或持这一类开单码的人,能改、取消、关闭、重开它。分级审批不变。', 1190);
UPDATE public.permissions SET description_en = 'Record supplier issues against purchase orders and set expected payment dates. Raising a PO needs its category''s raise code; amending, cancelling, closing and reopening one belong to its raiser or a holder of that code.', description_zh = '在采购单上记供应商问题、设付款预计日期。开单要这一类的开单码;改、取消、关闭、重开归开单人或持这一类码的人。'
 WHERE code = 'module.purchasing.edit';

-- 授权(在函数之前:下面的自证要问到它们)。Tim 的 Q6;每一个新码也给 admin(常设裁定)。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('warehouse', 'action.raise_po_consumables'), ('warehouse', 'module.purchasing.view'), ('cco', 'action.raise_po_equipment'), ('finance', 'action.raise_po_office'), ('admin', 'action.raise_po_consumables'), ('admin', 'action.raise_po_equipment'), ('admin', 'action.raise_po_office')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 2 · gst_periods:状态多一个 approved(CFO 批了数字、还没去 IRAS 报)─────────────────
ALTER TABLE public.gst_periods DROP CONSTRAINT gst_periods_status_check;
ALTER TABLE public.gst_periods ADD CONSTRAINT gst_periods_status_check
    CHECK (status IN ('open', 'approved', 'filed'));
ALTER TABLE public.gst_periods DROP CONSTRAINT gst_periods_filed_shape;
ALTER TABLE public.gst_periods ADD CONSTRAINT gst_periods_filed_shape CHECK (
        (status IN ('open', 'approved') AND filed_at IS NULL AND filed_on IS NULL AND filed_reference IS NULL)
     OR (status = 'filed' AND filed_at IS NOT NULL AND filed_on IS NOT NULL)
    );

-- ── 3 · gst_filing_requests(镜像原样)────────────────────────────────────────────
CREATE TABLE public.gst_filing_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    period_id          uuid NOT NULL REFERENCES public.gst_periods (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- 提交那一刻 f5_return(period_start, period_end)->'boxes' 原样:每一格 {box, label_en, label_zh, value}。
    -- 它同时是 fingerprint:批准时再算一遍,逐字相等才批。
    boxes              jsonb NOT NULL,
    -- 提单人的附言(可空)
    note               text,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    -- 批准当场写快照的时刻
    executed_at        timestamptz,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT gst_filing_requests_boxes_shape CHECK (jsonb_typeof(boxes) = 'array'),
    CONSTRAINT gst_filing_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT gst_filing_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT gst_filing_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT gst_filing_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.gst_filing_requests IS
    'APR-10:GST 申报申请 —— 财务提(module.finance.edit),CFO 批每一张,不分档。批的是【报出去之前的那一组数】:提交冻结 F5 每一格(boxes,同时是 fingerprint);批准时再算一遍、逐字相等才把它抄进 gst_return_boxes,期间 open → approved;之后财务去 IRAS 报、用 record_gst_filing 一步记下申报日与参考号(approved → filed)。submitted → approved · rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。审批关着时生下来就是 approved(auto_approved)。在等的时候把锁挪回这一季按名拒 GST_FILING_WAITING_BLOCKS_REOPEN。一个期间同一时刻只挂一张在等的申请。file_gst_return 只会按名拒 GST_FILING_NEEDS_APPROVED_REQUEST。';

COMMENT ON COLUMN public.gst_filing_requests.boxes IS
    'APR-10(grilling Q1):提交那一刻 f5_return(那一季)->''boxes'' 原样。批准时再算一遍、与它逐字相等才批(GST_RETURN_CHANGED_SINCE_REQUEST);批准把它抄进 gst_return_boxes。';

CREATE UNIQUE INDEX gst_filing_requests_one_open
    ON public.gst_filing_requests (period_id) WHERE status = 'submitted';
CREATE INDEX gst_filing_requests_period_id_rel ON public.gst_filing_requests (period_id);

ALTER TABLE public.gst_filing_requests ENABLE ROW LEVEL SECURITY;

-- 读:GST 页那一个码(module.finance.view)。写:一条策略都不给 —— 只经 submit / decide / withdraw
-- (全是 SECURITY DEFINER)。屏幕读 gst_filing_requests_visible()。
CREATE POLICY "gst_filing_requests select by permission" ON public.gst_filing_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.gst_filing_requests FROM anon;

-- ── 4 · approval_log:主体类型加一种;读策略加同名一支 ─────────────────────────
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
                            'gst_filing_request'));
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
            ELSE false
        END
    );

-- ── 5 · purchase_orders.category ────────────────────────────────────────────────
-- 回填(Q5):线上 11 张全部 equipment_goods。用一个【随即删掉】的默认值一次填满 —— 不触发任何行触发器
-- (不留一行历史、不动 updated_at:回填是一次结构改动,不是一次修改)。镜像里这一列没有默认值:
-- 开单的门(create_purchase_order)永远显式写它。
ALTER TABLE public.purchase_orders ADD COLUMN category text NOT NULL DEFAULT 'equipment_goods'
    CONSTRAINT purchase_orders_category_check CHECK (category IN ('consumables', 'equipment_goods', 'office'));
ALTER TABLE public.purchase_orders ALTER COLUMN category DROP DEFAULT;
COMMENT ON COLUMN public.purchase_orders.category IS
    'APR-10:品类 —— consumables(工厂耗材,仓库开)· equipment_goods(设备与货物,cco 开)· office(办公用品,财务开)。决定谁开(po_category_raise_code)与谁能改 / 取消 / 关闭 / 重开(开单人本人,或持这一类开单码的人:po_may_manage);【不改谁批】。生下来就定死(PO_FIELD_IMMUTABLE|category)。资产行与电池料行只能在 equipment_goods 里(PO_CATEGORY_LINE_MISMATCH)。';
-- 列授权:品类不敏感(AGENTS.md「给遮蔽表加列:三件事一个迁移」—— ADD COLUMN · 列授权 · _masked 视图)
GRANT SELECT (category) ON public.purchase_orders TO authenticated;
CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_by,
    delete_reason,
    cancelled_by,
    -- CONTRACT-1:这张单据挂在哪一份合同之下。**新列加在末尾** ——
    -- CREATE OR REPLACE VIEW 只许末尾追加,中间插一列要 DROP + 重建。
    -- 【它必须出现在这张视图里】purchase_orders 是遮蔽表,而 colgrant 那道闸要求
    -- 它的每一列要么被列授权、要么在 _masked 里(WO-1a 那一课:ADD/GRANT/_masked
    -- 三件事要在同一次迁移里做完 —— KPI-1 为漏掉后两件付过一次账)。
    -- 【条款不从这一列读】它只是导航;条款读 contract_document_terms 那份副本。
    contract_id,
    -- PO-GST-1(2026-09-03):这张单的税额合计。**是钱** —— 与 estimated_total_ccy
    -- 同一扇门。净额那一列一个字节没动,含税额在读的那一侧相加(见列注释)。
        CASE
            WHEN has_permission('data.view_purchase_prices'::text) THEN tax_total_ccy
            ELSE NULL::numeric
        END AS tax_total_ccy,
    -- PO-GST-1-fu2:含税额 —— **屏幕读这一列,自己不做加法**。
    -- 委托 ①d 的那条要求:屏幕与 PDF 必须读同一个来源。net 与 tax 本来就是同两列,
    -- 而 gross = net + tax 这次加法若两边各写一遍,就是第二份实现。
    -- 【不落库成第三列】导出量不存;存了就会有"净额改了而它没跟上"的错数。
    -- 遮蔽自然传导:分量为 NULL 时整个表达式就是 NULL。
        CASE WHEN has_permission('data.view_purchase_prices'::text)
             THEN estimated_total_ccy + COALESCE(tax_total_ccy, 0)
             ELSE NULL::numeric END AS gross_total_ccy,
    -- 这张单【算过税吗】—— NULL 的税额合计【不是】零税:它是"开在 PO-GST-1 之前,
    -- 或开在 GST 未注册的时候"。屏幕靠它决定说哪一句话,而不是印一个 0.00。
    (tax_total_ccy IS NOT NULL) AS carries_tax,
    -- PUR-1(2026-09-08):交货地点。**新列加在末尾** —— CREATE OR REPLACE VIEW
    -- 只许末尾追加,中间插一列要 DROP + 重建(与上面 contract_id 那一条同一课)。
    -- 【不遮蔽】它是一个地址,不是钱。
    delivery_location,
    -- APR-10(2026-09-27):品类(工厂耗材 / 设备与货物 / 办公用品)。末尾追加;【不遮蔽】它是一个分类,不是钱。
    category
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

-- 12 条写策略拿掉(guard_po_direct_write 按名拒 —— 见它的抬头)
DROP POLICY "purchase_orders insert by permission" ON public.purchase_orders;
DROP POLICY "purchase_orders update by permission" ON public.purchase_orders;
DROP POLICY "purchase_orders delete by permission" ON public.purchase_orders;
DROP POLICY "purchase_order_lines insert by permission" ON public.purchase_order_lines;
DROP POLICY "purchase_order_lines update by permission" ON public.purchase_order_lines;
DROP POLICY "purchase_order_lines delete by permission" ON public.purchase_order_lines;
DROP POLICY "purchase_order_payment_terms insert by permission" ON public.purchase_order_payment_terms;
DROP POLICY "purchase_order_payment_terms update by permission" ON public.purchase_order_payment_terms;
DROP POLICY "purchase_order_payment_terms delete by permission" ON public.purchase_order_payment_terms;
DROP POLICY "purchase_order_line_retentions insert by permission" ON public.purchase_order_line_retentions;
DROP POLICY "purchase_order_line_retentions update by permission" ON public.purchase_order_line_retentions;
DROP POLICY "purchase_order_line_retentions delete by permission" ON public.purchase_order_line_retentions;

-- ── 6 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/po_category_raise_code.sql
-- APR-10(2026-09-27,Tim 的矩阵 §6「开采购单,按品类」· grilling Q6):一个品类 → 开这一类单的那一个码。
-- 【一份定义】create_purchase_order(开单的门)、po_may_manage(改 / 取消 / 关闭 / 重开的门)、屏幕上每一个
-- 品类选项的禁用理由,都读这里。不认识的品类 → NULL(调用方按名拒 PO_CATEGORY_INVALID)。
--   consumables     工厂耗材   action.raise_po_consumables   仓库
--   equipment_goods 设备与货物 action.raise_po_equipment     cco
--   office          办公用品   action.raise_po_office        财务
-- (admin 三个都持 —— Tim 的常设裁定:每一个新码同一迁移里也授给 admin。)
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.po_category_raise_code(p_category text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_category
        WHEN 'consumables'     THEN 'action.raise_po_consumables'
        WHEN 'equipment_goods' THEN 'action.raise_po_equipment'
        WHEN 'office'          THEN 'action.raise_po_office'
    END
$function$;

-- db/functions/po_may_manage.sql
-- APR-10(2026-09-27,Tim 的 grilling Q7):读者这个人能不能改 / 取消 / 关闭 / 重开这张采购单。
--   能 = 开单人本人(按人认:self_leg 的 raiser 腿 —— 同一个人的另一个账号也算)
--     或 此刻持这张单那一类的开单码(po_category_raise_code)。
--   单不存在 / 已删 → false。
-- 屏幕用它画"按不动 + 理由";门用 assert_po_manager(同一份判据,按名拒)。
-- 只回答读者自己的一个布尔,所以 authenticated 调得到。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.po_may_manage(p_purchase_order_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE((
        SELECT self_leg(po.created_by, NULL::uuid, auth.uid()) = 'raiser'
            OR has_permission(po_category_raise_code(po.category))
          FROM purchase_orders po
         WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL), false)
$function$;

-- db/functions/assert_po_manager.sql
-- APR-10(2026-09-27,Tim 的 grilling Q7):改 / 取消 / 关闭 / 重开一张采购单(以及给它套付款条款模板)的门。
--   PO_NOT_FOUND|<id>                                   单不存在或已删
--   PO_NOT_RAISER_OR_CATEGORY_HOLDER|<单号>|<那一类的码>  读者既不是开单人本人,也不持这一类的开单码
-- 判据只有一份:po_may_manage。批准 / 驳回【不走这里】—— 它们的门不变(Q7 最后一句)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.assert_po_manager(p_purchase_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code     text;
    v_category text;
BEGIN
    SELECT code, category INTO v_code, v_category
      FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF NOT po_may_manage(p_purchase_order_id) THEN
        RAISE EXCEPTION 'PO_NOT_RAISER_OR_CATEGORY_HOLDER|%|%', v_code, po_category_raise_code(v_category);
    END IF;
END;
$function$;

-- db/functions/guard_po_line_category.sql
-- APR-10(2026-09-27,Tim 的 grilling Q5):一张单的品类由开单人选,但有两种行只能出现在「设备与货物」里 ——
--   · 资产行(asset_id 不空):那是设备;
--   · 电池料行(materials.kind_code = 'battery_material'):那是货物 —— 公司买来加工的原料。
--   其余的行,开单人选哪一类就是哪一类。违反 → PO_CATEGORY_LINE_MISMATCH|<单号>|<行号>|<品类>。
-- 挂在 purchase_order_lines 上(INSERT 与 UPDATE),所以开单与改单两条路都经过它。
-- ☞ 它认的是物料【目录上】的 kind_code:一个没填 kind_code 的物料它看不见(APR-10 交回时量过线上有这样的物料)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.guard_po_line_category()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code     text;
    v_category text;
BEGIN
    SELECT code, category INTO v_code, v_category FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF v_category IS DISTINCT FROM 'equipment_goods'
       AND (NEW.asset_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM materials m
                        WHERE m.id = NEW.material_id AND m.kind_code = 'battery_material')) THEN
        RAISE EXCEPTION 'PO_CATEGORY_LINE_MISMATCH|%|%|%', v_code, NEW.line_no, v_category;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_po_direct_write.sql
-- APR-10(2026-09-27):**采购单的四张表没有直连写**(purchase_orders · purchase_order_lines ·
-- purchase_order_payment_terms · purchase_order_line_retentions)。
--
-- 【量过的】APR-10 以 postgres 读 pg_proc:写这四张表的 15 支函数(开 / 改 / 批 / 驳 / 取消 / 关闭 / 重开 / 付款条款 /
-- 质保金释放 / 挂合同 / 收货推进 / 三支留痕)在线上全是 SECURITY DEFINER、属主 postgres;app/ 里对它们只有读。
-- 而 12 条写策略(都开在 module.purchasing.edit 上)放行过的路:
--   · 直连 INSERT 一张采购单 —— approval_status 的默认值是 'approved',于是一张没经过任何人批的单直接生效,
--     品类随便填、开单码不问(Tim 的 Q6 就成了一句空话);
--   · 直连改别人开的单的行、付款条款、质保金 —— 绕过 Q7 的"开单人或这一类的开单码"。
-- 于是 12 条写策略一并拿掉,本守卫按名拒 PO_THROUGH_FUNCTION_ONLY(语句级,零行也触发)。
-- 属主路径(row_security_active = false)一律放行。形状照 guard_journal_direct_write(APR-6)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.guard_po_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'PO_THROUGH_FUNCTION_ONLY';
END;
$function$;

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

-- db/functions/decide_gst_filing_request.sql
-- APR-10(2026-09-27):CFO 批准或驳回一张 GST 申报申请。批准【当场】把冻结的那一组抄进 gst_return_boxes,
-- 期间 open → approved;之后财务去 IRAS 报(record_gst_filing)。
--
-- 【门】module.finance.view + data.view_prices(APR-7 / APR-9 同一对码)—— 【不是】module.finance.edit:那是提单的码。
-- 【谁能批】二级审批人,每一张、不分档(require_approver_for(2))。【四眼】forbid_self_approval(提单人, NULL, …)
-- 按人认 —— 申报是公司的,主角那条腿对谁都不成立;admin@ 提的 tim@ 批不了,所以提交时就按名拒
-- GST_FILING_NO_OTHER_DECIDER。
-- 【批准之前不另查】批准就是那一次真的生效:锁被挪回(GST_PERIOD_NOT_LOCKED)、数字变了
-- (GST_RETURN_CHANGED_SINCE_REQUEST)—— 全按原话拒,整笔回滚,申请仍在等。驳回要理由,从不检查这些。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.decide_gst_filing_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    gst_filing_requests%ROWTYPE;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM gst_filing_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GST_FILING_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'GST_FILING_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'gst_filing_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'GST_FILING_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE gst_filing_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('gst_filing_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := gst_filing_execute_internal(p_request_id);

    UPDATE gst_filing_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), executed_at = now(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('gst_filing_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'result', v_exec);
END;
$function$;

-- db/functions/withdraw_gst_filing_request.sql
-- APR-10(2026-09-27):撤回一张在等的 GST 申报申请。谁能撤:提单人本人(按人认),或持 module.finance.edit 的人
-- (提单的那个码)。只撤 submitted。撤回什么都不写、锁的冻结随之解开;记在本行上,【不】写 approval_log。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.withdraw_gst_filing_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r gst_filing_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM gst_filing_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'GST_FILING_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.finance.edit');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'GST_FILING_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE gst_filing_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;

-- db/functions/record_gst_filing.sql
-- APR-10(2026-09-27,grilling Q1 第三步):财务去 IRAS 报了之后,回来一步记下【申报日】与【参考号】。
-- 不经批准:数字在 CFO 批准那一刻已经抄进 gst_return_boxes、锁死了,这一步只记"什么时候报的、回执是什么"。
-- 只收 approved 的期间(GST_FILING_NOT_APPROVED|<code>);申报日必填(GST_FILED_DATE_REQUIRED —— file_gst_return 当年
-- 那一条具名拒绝,参数照旧 DEFAULT NULL:页面没有办法把"没填"送进一个必填的 date 参数,见 GST-1-fu2)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.record_gst_filing(p_period_id uuid, p_filed_on date DEFAULT NULL::date, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p gst_periods%ROWTYPE;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_p FROM gst_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_period_id; END IF;
    IF v_p.status = 'filed' THEN
        RAISE EXCEPTION 'GST_PERIOD_ALREADY_FILED|%|%', v_p.code, v_p.filed_on;
    END IF;
    IF v_p.status <> 'approved' THEN
        RAISE EXCEPTION 'GST_FILING_NOT_APPROVED|%', v_p.code;
    END IF;
    IF p_filed_on IS NULL THEN RAISE EXCEPTION 'GST_FILED_DATE_REQUIRED|%', v_p.code; END IF;

    UPDATE gst_periods
       SET status = 'filed', filed_at = now(), filed_by = auth.uid(),
           filed_on = p_filed_on, filed_reference = NULLIF(btrim(COALESCE(p_reference, '')), '')
     WHERE id = p_period_id;

    RETURN jsonb_build_object('gst_period_id', p_period_id, 'code', v_p.code,
                              'filed_on', p_filed_on,
                              'reference', NULLIF(btrim(COALESCE(p_reference, '')), ''));
END;
$function$;

-- db/functions/gst_filing_requests_visible.sql
-- APR-10(2026-09-27):GST 期间页上"申报申请"那一块读的就是这里 —— 财务看得见自己提的,CFO 看得见要他批的。
--   谁读得到:module.finance.view(GST 页的门)。其余 → 零行。
--   p_period_id 给了就只给那一期的;只给在等的全部 + 最近决定 / 撤回的 p_recent 张。
--   boxes = 提交时冻结的那一组;current_boxes = 此刻再算一遍(只对在等的算 —— 决定了的不必);
--   current_matches = 两者逐字相等(不相等,批准会被 GST_RETURN_CHANGED_SINCE_REQUEST 拒,屏幕先说出来)。
--   original_code / original_boxes:这一期是一份更正件(F7)时,被更正的那一份与它【报出去的】快照 ——
--   CFO 逐格看见差(grilling Q2)。raised_by_me = 提单人就是读者这个人(按人认)。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.gst_filing_requests_visible(p_period_id uuid DEFAULT NULL::uuid, p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, status text, label text, period_id uuid, period_code text, period_start date, period_end date, boxes jsonb, current_boxes jsonb, current_matches boolean, original_code text, original_boxes jsonb, note text, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decision_notes text, withdrawn_at timestamptz, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM gst_filing_requests q
         WHERE has_permission('module.finance.view')
           AND (p_period_id IS NULL OR q.period_id = p_period_id)),
    c AS (
        SELECT r.id, CASE WHEN r.is_open THEN f5_return(p.period_start, p.period_end)->'boxes' END AS now_boxes
          FROM r JOIN gst_periods p ON p.id = r.period_id)
    SELECT r.id, r.status, r.label, r.period_id, p.code, p.period_start, p.period_end,
           r.boxes, c.now_boxes,
           CASE WHEN r.is_open THEN c.now_boxes IS NOT DISTINCT FROM r.boxes END,
           o.code,
           (SELECT jsonb_agg(jsonb_build_object('box', b.box, 'value', b.value_base) ORDER BY b.box)
              FROM gst_return_boxes b WHERE b.period_id = o.id),
           r.note, r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.withdrawn_at, r.withdraw_reason
      FROM r
      JOIN c ON c.id = r.id
      JOIN gst_periods p ON p.id = r.period_id
      LEFT JOIN gst_periods o ON o.id = p.corrects_period_id
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;

-- db/functions/guard_gst_filing_lock.sql
-- APR-10(2026-09-27,grilling Q3):一张 GST 申报申请在等的时候,那一季的数字靠期间锁冻结。
-- 把 locked_before 挪回到【这一季的期末或更早】—— 无论是 reopen_period(重开一个月)、重开年度,还是手动锁的
-- 直连写 —— 都会让那一季的某个月重新开放,于是按名拒 GST_FILING_WAITING_BLOCKS_REOPEN|<那一张>。
-- ☞ 重开这一季【之前】的一个月同样被拒:锁只有一个日期,重开六月就把七到九月一并打开了。
-- 挂在 finance_settings 上(BEFORE UPDATE OF locked_before),所以每一条挪锁的路都经过它。
-- 撤回或驳回那张申请,冻结随之解开;批准之后快照已写,此后的差异照 GST-1 的规矩走更正件。
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.guard_gst_filing_lock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_label text;
BEGIN
    IF NEW.locked_before IS NOT DISTINCT FROM OLD.locked_before THEN
        RETURN NEW;
    END IF;
    IF NEW.locked_before IS NOT NULL AND OLD.locked_before IS NOT NULL
       AND NEW.locked_before > OLD.locked_before THEN
        RETURN NEW;
    END IF;
    SELECT q.label INTO v_label
      FROM gst_filing_requests q JOIN gst_periods p ON p.id = q.period_id
     WHERE q.status = 'submitted'
       AND (NEW.locked_before IS NULL OR NEW.locked_before <= p.period_end)
     ORDER BY p.period_end LIMIT 1;
    IF v_label IS NOT NULL THEN
        RAISE EXCEPTION 'GST_FILING_WAITING_BLOCKS_REOPEN|%', v_label;
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/file_gst_return.sql
-- GST-1:记录一次申报。
-- ★ APR-10(2026-09-27,Tim 的矩阵 §2「GST 申报与更正 | 财务 | CFO」):**这扇门只会按名拒了。** 申报从此是一张申请 ——
--   submit_gst_filing_request(财务提,冻结 F5 每一格)→ decide_gst_filing_request(CFO 批,再算一遍、相等才写快照,
--   期间 → approved)→ 财务去 IRAS 报 → record_gst_filing(一步记下申报日与参考号,期间 → filed)。
--   签名与门(module.finance.edit)不变:没有码的人读到的仍是缺的那个码,有码的人读到
--   GST_FILING_NEEDS_APPROVED_REQUEST|<期间编号> —— 旧屏幕在部署之前按下去也只会得到这一句,什么都不写
--   (APR-9 的 ASSET_DISPOSAL_NEEDS_REQUEST 同形)。原来那一句"申报要求那一季每个月都已关账"搬进了提交与批准。
-- NOTE: introduced by db/migrations/2026-08-24-gst1-tax-codes-f5-and-filing-periods.sql;
--       reduced to a refusal by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE OR REPLACE FUNCTION public.file_gst_return(p_period_id uuid, p_filed_on date DEFAULT NULL::date, p_reference text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM gst_periods WHERE id = p_period_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'GST_PERIOD_NOT_FOUND|%', p_period_id; END IF;
    RAISE EXCEPTION 'GST_FILING_NEEDS_APPROVED_REQUEST|%', v_code;
END;
$function$;

-- ─── guard_po_amendable
CREATE OR REPLACE FUNCTION public.guard_po_amendable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【改了就是另一笔交易 —— 重开一张,不是改这一张】
    -- 供应商:应付、预付、签发档全挂在这笔交易上,换人等于把它们悄悄重指。
    -- 币种:fx_rate 锚在 order_date 的 tt_sell 上,而付款计划的定额腿是按【那个】
    --       币种谈的(FIN-29 明确拒绝换币种的单)—— 换币种把整个金额框架作废。
    IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|supplier_id|%', OLD.code;
    END IF;
    IF NEW.currency IS DISTINCT FROM OLD.currency THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|currency|%', OLD.code;
    END IF;
    IF NEW.code IS DISTINCT FROM OLD.code THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|code|%', OLD.code;
    END IF;
    -- APR-10(grilling Q8):品类生下来就定死 —— 它决定谁开、谁能改、谁能取消。要换品类:取消,重开一张。
    IF NEW.category IS DISTINCT FROM OLD.category THEN
        RAISE EXCEPTION 'PO_FIELD_IMMUTABLE|category|%', OLD.code;
    END IF;

    -- 【状态与审批状态不走"修改"这条路】它们各有自己的转换
    -- (cancel/close/reopen、审批函数)。一个能把 approval_status 设成 approved 的
    -- 编辑表单,就是一条不经审批的审批路径。
    -- 【但要放行那三个转换本身】—— 它们改的正是这两列,靠上下文标记区分,
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法。
    IF current_setting('evoltrya.po_status_ctx', true) IS DISTINCT FROM '1' THEN
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            RAISE EXCEPTION 'PO_STATUS_NOT_AMENDABLE|status|%|%', OLD.status, NEW.status;
        END IF;
        -- APR-2 的作废触发器【也】改 approval_status。它是 BEFORE UPDATE、
        -- 与本守卫同级,执行顺序按名字排:guard_(g) 在 trg_(t) 之前,
        -- 于是本守卫看到的是【还没被作废触发器改过的】值 —— 放行的判据因此是
        -- "调用方有没有自己动它",而不是"最终值是不是变了"。
        IF NEW.approval_status IS DISTINCT FROM OLD.approval_status THEN
            RAISE EXCEPTION 'PO_STATUS_NOT_AMENDABLE|approval_status|%|%',
                OLD.approval_status, NEW.approval_status;
        END IF;
    END IF;

    RETURN NEW;
END;
$function$;

-- ─── amend_purchase_order
CREATE OR REPLACE FUNCTION public.amend_purchase_order(p_purchase_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb, p_payment_terms jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_po       record;
    v_el       jsonb;
    v_line_id  uuid;
    v_qty      numeric;
    v_price    numeric;
    v_price_status text;      -- PUR-1:这一行的定价状态选择
    -- ── PUR-1:付款条款 ─────────────────────────────────────────────────────
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer;
    v_pct_total  numeric;
    v_new_date date;
    v_fx       numeric;
    v_total    numeric;
    v_plan_fixed numeric;
    v_plan_pct   numeric;
    v_changed  integer := 0;
    -- ── PO-GST-1:改单之后,存下来的税要跟着改过的行走 ────────────────────────
    v_gst        boolean := gst_registered();
    v_sup_tax_default text;
    v_tax_code   text;
    v_tax_rate   numeric;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填】一次改动没有理由,历史上就是一行"数字变了"而没有"为什么"。
        RAISE EXCEPTION 'PO_AMEND_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_po FROM purchase_orders
     WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;

    -- 【已结束 / 已作废的单不能改】先 reopen,让状态变化成为一次有记录的动作,
    -- 而不是修改的副作用。
    IF v_po.status IN ('closed','cancelled') THEN
        RAISE EXCEPTION 'PO_NOT_AMENDABLE|%|%', v_po.code, v_po.status;
    END IF;

    -- PO-GST-1:新增行要用到供应商的默认进项税码(与建单同一条播种规则)。
    SELECT default_tax_code INTO v_sup_tax_default FROM suppliers WHERE id = v_po.supplier_id;

    -- 理由传给留痕触发器(触发器读不到函数参数)
    PERFORM set_config('evoltrya.amend_reason', btrim(p_reason), true);
    PERFORM set_config('evoltrya.po_amend_ctx', '1', true);

    -- ── 表头 ────────────────────────────────────────────────────────────────
    IF p_header IS NOT NULL AND jsonb_typeof(p_header) = 'object' THEN
        v_new_date := COALESCE((p_header->>'order_date')::date, v_po.order_date);
        -- 【汇率从不由调用方递入】改单据日就要重取牌价:缺牌价即拒绝、绝不编一个。
        -- 采购是我们买外币 → tt_sell。本位币恒 1(定义,不是兜底)。
        IF v_new_date IS DISTINCT FROM v_po.order_date THEN
            IF v_po.currency = base_currency_code() THEN
                v_fx := 1;
            ELSE
                v_fx := fx_rate_for(v_po.currency, v_new_date, 'tt_sell');
            END IF;
        ELSE
            v_fx := v_po.fx_rate;
        END IF;

        UPDATE purchase_orders SET
            order_date = v_new_date,
            expected_delivery_date = CASE WHEN p_header ? 'expected_delivery_date'
                THEN (p_header->>'expected_delivery_date')::date ELSE expected_delivery_date END,
            incoterm = CASE WHEN p_header ? 'incoterm' THEN p_header->>'incoterm' ELSE incoterm END,
            terms_text = CASE WHEN p_header ? 'terms_text' THEN p_header->>'terms_text' ELSE terms_text END,
            notes = CASE WHEN p_header ? 'notes' THEN p_header->>'notes' ELSE notes END,
            -- PUR-1:交货地点。【键在不在,与值是不是空,是两件事】——
            -- 不传这个键 = 不动它;传一个空串 = 把它清掉(收成 NULL,于是纸上不印)。
            delivery_location = CASE WHEN p_header ? 'delivery_location'
                THEN NULLIF(btrim(COALESCE(p_header->>'delivery_location', '')), '')
                ELSE delivery_location END,
            fx_rate = v_fx,
            updated_by = v_user
        WHERE id = p_purchase_order_id;
    END IF;

    -- ── 明细 ────────────────────────────────────────────────────────────────
    IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
        LOOP
            v_line_id := NULLIF(v_el->>'id', '')::uuid;

            IF COALESCE((v_el->>'remove')::boolean, false) THEN
                IF v_line_id IS NULL THEN
                    RAISE EXCEPTION 'PO_LINE_REMOVE_NEEDS_ID';
                END IF;
                -- 收过货的行删不掉 —— 守卫触发器点名拒(货真的到了,单据上却没有出处)
                DELETE FROM purchase_order_lines
                 WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                v_changed := v_changed + 1;
                CONTINUE;
            END IF;

            v_qty := (v_el->>'quantity')::numeric;
            -- EQP-1a-TAIL:设备行同一条规矩 —— 省略即给默认,给错则按名拒。
            IF (v_el->>'asset_id') IS NOT NULL THEN
                IF v_qty IS NULL THEN v_qty := 1; END IF;
                IF v_qty <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_QTY|%|%', COALESCE(v_el->>'line_no','?'), v_qty
                      USING HINT = '一条设备行订的是【一台】机器 —— 四台是四条行';
                END IF;
                IF COALESCE(v_el->>'unit', 'unit') <> 'unit' THEN
                    RAISE EXCEPTION 'PO_LINE_EQUIPMENT_UNIT|%|%', COALESCE(v_el->>'line_no','?'), v_el->>'unit'
                      USING HINT = '设备行的计量单位恒为 unit —— 留空即取它';
                END IF;
            END IF;
            IF v_qty IS NULL OR v_qty <= 0 THEN
                RAISE EXCEPTION 'PO_LINE_QUANTITY_INVALID|%', COALESCE(v_el->>'line_no', '?');
            END IF;
            v_price := NULLIF(v_el->>'estimated_unit_price', '')::numeric;
            -- PUR-1:定价状态 —— 与建单同一条校验,同一个码。
            v_price_status := NULLIF(btrim(COALESCE(v_el->>'price_status', '')), '');
            IF v_price_status IS NOT NULL AND v_price_status NOT IN ('fixed', 'provisional') THEN
                RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_INVALID|%|%',
                    COALESCE(v_el->>'line_no', '?'), v_price_status
                  USING HINT = '定价状态只有两个取值:fixed(定价)与 provisional(暂定价)。留空表示按事实推导';
            END IF;

            IF v_line_id IS NULL THEN
                -- 新增行:与建单同口径(金额 = 数量 × 单价,无价则 0)
                -- EQP-1a:改单也能加设备行 —— 恰一非空,与建单同一句话
                IF num_nonnulls((v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid) <> 1 THEN
                    RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', COALESCE(v_el->>'line_no', '?')
                      USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
                END IF;
                IF (v_el->>'asset_id') IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM fixed_assets WHERE id = (v_el->>'asset_id')::uuid
                ) THEN
                    RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_el->>'asset_id';
                END IF;
                -- ── PO-GST-1:改单加进来的【新行】与建单同口径 ──────────────
                -- ★ 税率按【这张单的下单日】解析,不是按今天 ★ 一张单上所有的行
                -- 共用同一个日期的税率;拿今天的税率去补一条 2023 年的单上的新行,
                -- 会让同一张纸上出现两个不同的税率。
                IF v_gst THEN
                    v_tax_code := resolve_tax_code(v_el->>'tax_code', v_sup_tax_default, 'input', 'supplier');
                    v_tax_rate := tax_rate_for(v_tax_code, v_po.order_date);
                ELSE
                    IF NULLIF(btrim(COALESCE(v_el->>'tax_code', '')), '') IS NOT NULL THEN
                        RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_el->>'tax_code';
                    END IF;
                    v_tax_code := NULL; v_tax_rate := NULL;
                END IF;
                INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id,
                    quantity, unit, estimated_unit_price, estimated_amount_ccy, notes, created_by,
                    tax_code, tax_rate_pct, tax_amount_ccy, price_status)
                VALUES (p_purchase_order_id,
                    COALESCE((v_el->>'line_no')::integer,
                        (SELECT COALESCE(MAX(line_no), 0) + 1 FROM purchase_order_lines
                          WHERE purchase_order_id = p_purchase_order_id)),
                    (v_el->>'material_id')::uuid, (v_el->>'asset_id')::uuid,
                    v_qty, COALESCE(v_el->>'unit', CASE WHEN (v_el->>'asset_id') IS NOT NULL THEN 'unit' ELSE 'kg' END),
                    v_price, round(v_qty * COALESCE(v_price, 0), 2), v_el->>'notes', v_user,
                    v_tax_code, v_tax_rate,
                    CASE WHEN v_tax_rate IS NULL THEN NULL
                         ELSE tax_amount_for(round(v_qty * COALESCE(v_price, 0), 2), v_tax_rate) END,
                    v_price_status);
            ELSE
                -- 【已收下限由触发器把关】砍到已收之下 → PO_LINE_BELOW_RECEIVED
                UPDATE purchase_order_lines SET
                    quantity = v_qty,
                    -- PUR-1:键在不在,与值是不是空,是两件事(与表头那一条同形)。
                    -- 传 '' 把它清回 NULL —— 也就是"别再替我选了,按事实推导"。
                    price_status = CASE WHEN v_el ? 'price_status'
                        THEN v_price_status ELSE price_status END,
                    unit = COALESCE(v_el->>'unit', unit),
                    estimated_unit_price = CASE WHEN v_el ? 'estimated_unit_price'
                        THEN v_price ELSE estimated_unit_price END,
                    estimated_amount_ccy = round(v_qty * COALESCE(
                        CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                             ELSE estimated_unit_price END, 0), 2),
                    -- ★★【PO-GST-1:改过的行,税跟着【新的净额】重算 —— 但税【率】
                    --     不重解析】★★ 改单改的是数量或单价,不是这一行的税务性质,
                    --     也不是这张单的日期。用行上冻着的那个 tax_rate_pct 重算,
                    --     于是 ①c 那条"存下来的税不随今天的税率漂移"在改单之后仍然成立。
                    --     【历史行(tax_rate_pct 为 NULL)保持 NULL】—— 改一改数量,
                    --     不该让一张 PO-GST-1 之前的单凭空长出一个它当时没有的税额。
                    tax_amount_ccy = CASE WHEN tax_rate_pct IS NULL THEN NULL
                        ELSE tax_amount_for(round(v_qty * COALESCE(
                            CASE WHEN v_el ? 'estimated_unit_price' THEN v_price
                                 ELSE estimated_unit_price END, 0), 2), tax_rate_pct) END
                WHERE id = v_line_id AND purchase_order_id = p_purchase_order_id;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', v_line_id;
                END IF;
            END IF;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 总额:与明细【同一条语句】算完 ───────────────────────────────────────
    -- 【顺序就是要点】这一列是 APR-2 作废触发器盯着的东西。若先改行、再另起一条
    -- 语句写总额,触发器判断时依据的总额与产生它的那批行已经不是一回事 ——
    -- 那会产生一个看起来完全正常、却基于陈旧数字的审批决定。
    -- PO-GST-1:税额合计与净额【在同一条语句里】算完 —— 理由与上面那段逐字相同
    -- (作废触发器盯着的是净额那一列,而两个数必须来自同一批行)。
    -- 【SUM 而不是 COALESCE(...,0)】全是 NULL(历史单/未注册)时合计就是 NULL,
    -- 那正是"这张单没有税"与"这张单的税是零"的区别。
    UPDATE purchase_orders po SET
        estimated_total_ccy = COALESCE(s.total, 0),
        tax_total_ccy = s.tax_total,
        updated_by = v_user
    FROM (SELECT COALESCE(SUM(estimated_amount_ccy), 0) AS total,
                 SUM(tax_amount_ccy) AS tax_total
            FROM purchase_order_lines WHERE purchase_order_id = p_purchase_order_id) s
    WHERE po.id = p_purchase_order_id;

    SELECT estimated_total_ccy INTO v_total FROM purchase_orders WHERE id = p_purchase_order_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★【PUR-1:改单可以改付款条款 —— 而档案接得住,那才是本段的重点】★★
    -- ════════════════════════════════════════════════════════════════════════
    --   【此前改不了,而那【不是】一道锁】(2026-09-08 实测):没有参数、没有
    --   表单字段,而 purchase_order_payment_terms 的 INSERT/UPDATE/DELETE 策略
    --   对持 module.purchasing.edit 的人【全开】—— 也就是说这条路今天就通,
    --   通的是一条直连改库、且在档案里【完全沉默】的路。
    --   留痕在触发器上(trg_po_history_payment_term),不在这里 —— 与 PUR-2 同一条:
    --   触发器接得住每一条路径,包括上面那一条。
    --
    --   ★【为什么是【按期落位】而不是整表删了重灌】★
    --     删了重灌在档案里读起来是"整份计划被换掉了",而真相常常是"第二期
    --     从 40% 改成了 30%"。按 seq 落位之后,没动过的那几期【一条历史都不长】
    --     (触发器对无改动的 UPDATE 直接返回),读的人一眼看得出改的是哪一期。
    --
    --   ★【NULL 与 [] 是两件事】★ 不传这个参数 = 不动付款计划(既有调用方
    --     一个字不用改);传一个空数组 = 把整份计划清掉,那是一次明说的动作。
    --
    --   【适用性不在这里判】trg_po_payment_terms_event_applicable 已经在表上按名拒
    --   (PO_TERM_EVENT_NOT_APPLICABLE)—— 在这里再抄一遍就是同一条规矩的第二份实现。
    IF p_payment_terms IS NOT NULL THEN
        IF jsonb_typeof(p_payment_terms) <> 'array' THEN
            RAISE EXCEPTION 'PO_PAYMENT_TERMS_INVALID|%', jsonb_typeof(p_payment_terms)
              USING HINT = '付款计划要么不传(不动它),要么传一个数组(整份计划按期落位)';
        END IF;

        -- 【先整份验完,再动一个字】—— 验到一半才拒,会留下一份改了一半的计划。
        v_expect := 0; v_pct_total := 0;
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            -- 与建单【同一个码】:一条规矩只能有一个码,否则屏幕上会有一半的
            -- 拒绝印出裸码(EQP-PAY-1 A2 那一课)。
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);
        END LOOP;
        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;

        -- 多出来的期数先删(触发器记 payment_term_remove)
        DELETE FROM purchase_order_payment_terms
         WHERE purchase_order_id = p_purchase_order_id AND seq > v_expect;

        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label,
                percentage, fixed_amount_ccy, trigger_event, due_date, notes)
            VALUES (p_purchase_order_id, (v_term->>'seq')::integer, v_term->>'label',
                (v_term->>'percentage')::numeric, (v_term->>'fixed_amount_ccy')::numeric,
                v_term->>'trigger_event', (v_term->>'due_date')::date, v_term->>'notes')
            ON CONFLICT (purchase_order_id, seq) DO UPDATE SET
                label            = EXCLUDED.label,
                percentage       = EXCLUDED.percentage,
                fixed_amount_ccy = EXCLUDED.fixed_amount_ccy,
                trigger_event    = EXCLUDED.trigger_event,
                due_date         = EXCLUDED.due_date,
                notes            = EXCLUDED.notes;
            v_changed := v_changed + 1;
        END LOOP;
    END IF;

    -- ── 付款计划:定额腿必须仍然加得上 ───────────────────────────────────────
    -- 【PUR-1:这道闸现在【也】管新传进来的那份计划】—— 顺序没有变,
    -- 它读的仍然是库里此刻的计划,而上面那一段已经把新计划落位了。
    SELECT COALESCE(SUM(fixed_amount_ccy), 0), COALESCE(SUM(percentage), 0)
      INTO v_plan_fixed, v_plan_pct
      FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    IF v_plan_fixed > 0 THEN
        -- 【定额腿在场:拒绝,不缩放】一条定额腿之所以是定额,正因为有人谈的是一个
        -- 数字而不是一个比例。替它按比例缩放,就是系统替操作员重新谈了一次条款,
        -- 而没有任何人被告知(与调高信用额度让告警安静同族)。
        -- 报出三个数:订单额、计划额、差额 —— 补救归操作员,而两条路都是有记录的动作。
        DECLARE
            v_plan_total numeric :=
                v_plan_fixed + round(v_total * v_plan_pct / 100.0, 2);
        BEGIN
            IF round(v_plan_total, 2) <> round(v_total, 2) THEN
                RAISE EXCEPTION 'PO_PLAN_FIXED_MISMATCH|%|%|%',
                    round(v_total, 2), round(v_plan_total, 2),
                    round(v_plan_total - v_total, 2);
            END IF;
        END;
    END IF;
    -- 【比例计划不在此列,而且这不是遗漏】百分比的意思就是"订单的这一份",
    -- 它按构造跟着总额走;定额的意思是"这么多钱",只有它需要被拦住。

    PERFORM set_config('evoltrya.po_amend_ctx', '', true);
    PERFORM set_config('evoltrya.amend_reason', '', true);

    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'lines_changed', v_changed,
        'estimated_total_ccy', v_total,
        'approval_status', (SELECT approval_status FROM purchase_orders WHERE id = p_purchase_order_id));
END;
$function$;

-- ─── cancel_purchase_order
CREATE OR REPLACE FUNCTION public.cancel_purchase_order(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_po      record;
    v_batches integer;
    v_applied numeric;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_id);
    SELECT id, code, status INTO v_po
    FROM purchase_orders WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    -- AUDEL-1b:【理由必填】此前是 DEFAULT NULL —— 取消一张采购单可以什么都不说,
    -- 而另外四个族(发票 / 工单 / 销售订单 / 报价)全都要求理由。这是第五份复制,
    -- 不是第六种变体:形状照抄 set_sales_order_status 的那一句。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'PO_CANCEL_REASON_REQUIRED|%', v_po.code;
    END IF;

    SELECT count(*) INTO v_batches
    FROM inbound_batches WHERE purchase_order_id = p_id AND deleted_at IS NULL;
    IF v_batches > 0 THEN
        RAISE EXCEPTION 'PO_HAS_RECEIPTS|%', v_batches;
    END IF;

    SELECT COALESCE(SUM(amount_base), 0) INTO v_applied
    FROM prepayment_applications WHERE purchase_order_id = p_id;
    IF v_applied > 0 THEN
        RAISE EXCEPTION 'PO_HAS_APPLIED_PREPAYMENTS|%', v_applied;
    END IF;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET status = 'cancelled', cancelled_at = now(), cancel_reason = btrim(p_reason),
        cancelled_by = v_user, updated_by = v_user
    WHERE id = p_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    -- AUDEL-1b:写一行历史 —— 取消此前【不写】,而另外四个族都写。
    -- change_type 'cancelled' 是本刀加进 CHECK 的;changed_by 走列默认 auth.uid()。
    INSERT INTO purchase_order_history (purchase_order_id, change_type, amend_reason, changed_by)
    VALUES (p_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('purchase_order_id', p_id, 'code', v_po.code, 'status', 'cancelled');
END;
$function$;

-- ─── close_purchase_order
CREATE OR REPLACE FUNCTION public.close_purchase_order(p_purchase_order_id uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_po        record;
    v_prepaid   numeric;
    v_applied   numeric;
    v_unapplied numeric;
    v_received  numeric;
    v_ordered   numeric;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);
    SELECT id, code, status, notes INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    IF v_po.status = 'closed' THEN
        RAISE EXCEPTION 'PO_ALREADY_CLOSED|%', v_po.code;
    END IF;

    -- 未抵扣预付 = 已付到该单的预付(posted 收付款)− 已抵扣到批次的部分。
    -- 大于 0 时必须写说明:这是【真金白银】躺在 1300 预付款项里,而这张单永远不会
    -- 再吸收它了 —— 退款、转到别的单、核销,系统今天都还没建模,所以允许关单,
    -- 但必须留下一句写下来的解释,不许无声搁浅。
    SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_prepaid
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;
    v_unapplied := round(v_prepaid - v_applied, 2);

    IF v_unapplied > 0 AND (p_notes IS NULL OR btrim(p_notes) = '') THEN
        RAISE EXCEPTION 'CLOSE_NOTES_REQUIRED|%', v_unapplied;
    END IF;

    SELECT COALESCE(SUM(ib.quantity), 0) INTO v_received
    FROM inbound_batches ib
    WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL;
    SELECT COALESCE(SUM(pol.quantity), 0) INTO v_ordered
    FROM purchase_order_lines pol
    WHERE pol.purchase_order_id = p_purchase_order_id;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET status = 'closed',
        closed_at = now(),
        -- 追加而不覆盖:关单说明带时间戳进 notes,原有内容原样保留
        notes = CASE
            WHEN p_notes IS NULL OR btrim(p_notes) = '' THEN notes
            ELSE COALESCE(notes || E'\n', '')
                 || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' closed] ' || btrim(p_notes)
        END,
        updated_by = v_user
    WHERE id = p_purchase_order_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);


    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', 'closed',
        'unapplied_prepayment_usd', v_unapplied,
        'received_qty', v_received,
        'ordered_qty', v_ordered,
        'receipt_pct', CASE WHEN v_ordered = 0 THEN NULL
                            ELSE round(v_received / v_ordered * 100, 2) END
    );
END;
$function$;

-- ─── reopen_purchase_order
CREATE OR REPLACE FUNCTION public.reopen_purchase_order(p_purchase_order_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_po     record;
    v_status text;
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);
    SELECT id, code, status INTO v_po
    FROM purchase_orders
    WHERE id = p_purchase_order_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status <> 'closed' THEN
        RAISE EXCEPTION 'PO_NOT_CLOSED|%', v_po.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 已经收过货的回到 'receiving',一车没收过的回到 'confirmed'
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM inbound_batches ib
        WHERE ib.purchase_order_id = p_purchase_order_id AND ib.deleted_at IS NULL
    ) THEN 'receiving' ELSE 'confirmed' END INTO v_status;

    -- PUR-2:告诉 guard_po_amendable 这是一次【状态转换】,不是一次修改。
    -- 与 FIN-36c 的 alloc_ctx、年结的 close_ctx 同一个惯用法:显式声明,
    -- 而不是让守卫去猜调用方是谁。
    -- 【用完立刻清掉 —— 这一句是 fu2 的全部内容】set_config(..., true) 是
    -- 【事务】局部,不是语句局部。只在函数开头设一次,守卫就会在这次调用之后、
    -- 整个事务余下的时间里【一直是关着的】:跑过一次 close_purchase_order 之后,
    -- 同一事务里一条直连的 UPDATE ... SET status 就畅通无阻(实测过)。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders
    SET status = v_status,
        closed_at = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' reopened] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_purchase_order_id;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);


    RETURN jsonb_build_object(
        'purchase_order_id', p_purchase_order_id,
        'code', v_po.code,
        'status', v_status
    );
END;
$function$;

-- ─── apply_payment_term_template
CREATE OR REPLACE FUNCTION public.apply_payment_term_template(p_purchase_order_id uuid, p_template_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po    record;
    v_tpl   record;
    v_count integer := 0;
    v_fixed integer := 0;   -- FIN-29:本模板有几条定额腿
BEGIN
    -- ★ APR-10(Tim 的 grilling Q7):开单人本人(按人认),或此刻持这张单那一类开单码的人 —— 其余按名拒
    --   PO_NOT_RAISER_OR_CATEGORY_HOLDER(assert_po_manager,一份判据;屏幕读同一份 po_may_manage)。
    --   从前的门 module.purchasing.edit 不再够。
    PERFORM assert_po_manager(p_purchase_order_id);
    SELECT id, code, order_date, status, currency INTO v_po
    FROM purchase_orders WHERE id = p_purchase_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;

    SELECT id, name, currency INTO v_tpl
    FROM payment_term_templates
    WHERE id = p_template_id AND deleted_at IS NULL AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TEMPLATE_NOT_FOUND|%', COALESCE(p_template_id::text, '?');
    END IF;

    -- ── FIN-29:定额腿的币种必须与本单相同,否则点名拒 ──────────────────────
    -- 【全部校验都在 DELETE 之前】拒绝必须是真的什么都没做:这个函数的语义是
    -- "替换整份计划",若先删后拒,靠的就只是事务回滚。把判断提到前面,
    -- 于是"被拒时原计划一行未动"是【结构上】成立的,不是靠回滚兜的。
    SELECT count(*) INTO v_fixed
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id AND l.fixed_amount_ccy IS NOT NULL;

    IF v_fixed > 0 THEN
        IF v_tpl.currency IS NULL THEN
            -- 守卫(guard_template_fixed_needs_currency)之前建出来的行。不猜、不照抄:
            -- 照抄等于替双方认下一个没人谈过的币种(同 FIN-26 / FIN-27 的规矩)。
            RAISE EXCEPTION 'TEMPLATE_CURRENCY_UNDECLARED|%', v_tpl.name;
        END IF;
        IF v_tpl.currency <> v_po.currency THEN
            -- 【不换算】付款条款是谈定的承诺,不是算出来的量。按牌价折过去,
            -- 记下的就不再是双方谈的那个数。
            RAISE EXCEPTION 'TEMPLATE_CURRENCY_MISMATCH|%|%|%',
                v_tpl.name, v_tpl.currency, v_po.currency;
        END IF;
    END IF;

    -- 【替换】而不是追加:套模板的语义是"这张 PO 的计划就是模板说的那样"
    DELETE FROM purchase_order_payment_terms WHERE purchase_order_id = p_purchase_order_id;

    INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                              fixed_amount_ccy, trigger_event, due_date, notes)
    SELECT p_purchase_order_id, l.seq, l.label, l.percentage, l.fixed_amount_ccy, l.trigger_event,
           -- 模板存的是相对下单日的天数偏移(模板不可能知道具体日期)
           CASE WHEN l.trigger_event = 'fixed_date'
                THEN v_po.order_date + COALESCE(l.days_offset, 0)
                ELSE NULL END,
           l.notes
    FROM payment_term_template_lines l
    WHERE l.template_id = p_template_id
    ORDER BY l.seq;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    RETURN jsonb_build_object('purchase_order_id', p_purchase_order_id, 'term_count', v_count,
                              'currency', v_po.currency, 'fixed_leg_count', v_fixed);
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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废 · 手工凭证 · 仓库(注销 / 回滚 / 证书作废)· 条款(公式 / 合同生效)· 资产处置 · GST 申报九种申请与发货放行 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ APR-9 的调薪申请 false、fixed_level NULL、金额 NULL:它不看审批开关,按人路由(pay_decision_code),不在 approval_chain_gates 里。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

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
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        ('gst_filing_request'::text, 'decide_gst_filing_request'::text, 2::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- db/functions/approvals_readiness.sql
-- SOD-1:审批开关【能不能开】,以及开不了的话缺哪几样 —— 屏幕与闸读同一份判据。
-- 一个屏幕上说"可以开"、闸却拒绝的系统,比两者都拒绝更坏(fixture 127 C8 钉这一条)。
--
-- 【数的是【真的登录得了的】持有人】线上有 66 条 user_roles 的 user_id 在
-- auth.users 里根本不存在(docs/known-issues.md 的 ACCOUNTS-STALE 条)。
-- 一个只由幽灵持有的角色,是一个永远不会有人来批的队列。
--
-- 【它答不了的那一件,不假装答得了】"是否存在第二个真人",本函数【不判】——
-- 线上五个 test.local 走查账号都持 admin,任何按账号数的判据都会因为它们而通过,
-- 也就是为了错的理由通过。那一条留在 docs/fresh-install-checklist.md 里由人判断。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql;
-- 内检的权限码由 db/migrations/2026-09-22-apr1-the-approvals-switch-gets-a-door.sql
-- 从 module.finance.view 换成 action.manage_permissions(APR-0 的 N6)。
--
-- 【fu2:一个【非阻塞】的忠告字段 level1_holders_who_cannot_raise】
-- 独立复测量到:`finance` 角色自己就持 module.purchasing.edit,于是被裁定的
-- 一级审批角色里,"结构上提不了单"的持有人是 **0** 个。
-- **它报告,不拦** —— 做成拒绝会让 Tim 自己裁定的策略开不起来,
-- 而一道拦住既定决定的闸是一道会被绕过去的闸。留给 Tim 的三选一写在
-- db/migrations/2026-08-24-sod1-fu2-*.sql 的抬头。
--
-- 【fu2 同时补上了调用者检查】gate 的 B2 抓到它是 SECURITY DEFINER 且无检查而可调用。
-- 它【要】被 /finance/settings 调用,所以走的是"加检查"这一半,不是"收权限"那一半
-- (另外三支内层函数走的是后者,见 db/views/zzz_function_grants.sql)。

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
    -- APR-ROUTE-1 Batch B(Tim 的 Q3):每一级的【人】数,与账号数并排
    v_l1_people  integer := 0;  v_l2_people integer := 0;
    v_l1_norais  integer := 0;
    v_l1_sees    boolean := false;
    v_l2_sees    boolean := false;
    v_pending    integer := 0;
    v_blocking_p integer := 0;
    v_pendchains jsonb   := '[]'::jsonb;
    v_chains     jsonb   := '[]'::jsonb;
    v_deadchains integer := 0;
    v_owngaps    jsonb   := '[]'::jsonb;
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
        -- ★ Batch B(Q3):同一个人的两个账号只算一个人 —— 经 account_person 认人。
        SELECT count(DISTINCT COALESCE(account_person(h.user_id)::text, 'account:' || h.user_id::text))
          INTO v_l1_people FROM real_role_holders(v_s.approval_level1_role_code) h;
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
        SELECT count(DISTINCT COALESCE(account_person(h.user_id)::text, 'account:' || h.user_id::text))
          INTO v_l2_people FROM real_role_holders(v_s.approval_level2_role_code) h;
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

    -- ════════════════════════════════════════════════════════════════════════
    -- ★★ APR-3(Tim 的 Q6):在途张数放宽到【每一条接上引擎的链】,
    --    而 can_disable 仍然只看【关掉之后会批不动的那些】 ★★
    -- ════════════════════════════════════════════════════════════════════════
    -- 两个数长得一样,问的不是同一件事,所以它们是两个字段 ——
    -- 而【两个都出自同一支函数】(approval_pending_documents),于是屏幕与闸
    -- 不可能各读一份判据。那一句判别写在那个函数的抬头,下一刀照它回答一次:
    --   **这条链的决定函数,在审批关着的时候还跑不跑得动?**
    --
    -- ★【为什么不把 can_disable 一起放宽】线上今天有一张 submitted 的报销单,
    --   而报销在审批关着时照常批得了 —— 把它算进去会让审批从此【关不掉】,
    --   一个没有人要求过的新约束,而且它看起来会像一个 bug。
    --
    -- ⚠【pending_purchase_orders 这个字段名保留】它喂的是屏幕上那一句
    --   「关掉会怎样」,而那句话说的正是采购单。改名要连着文案一起改,
    --   而本刀没有理由动它 —— 它今天仍然逐字等于 blocks_disable 的那个数,
    --   因为今天只有采购单 blocks_disable。
    SELECT count(*) FILTER (WHERE d.subject_type = 'purchase_order'),
           count(*) FILTER (WHERE d.blocks_disable)
      INTO v_pending, v_blocking_p
      FROM approval_pending_documents() d;

    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'subject_type'), '[]'::jsonb)
      INTO v_pendchains
      FROM (
        SELECT jsonb_build_object(
                   'subject_type',    d.subject_type,
                   'pending',         count(*),
                   'blocks_disable',  bool_or(d.blocks_disable),
                   -- 分不出档的那些单独报出来,不混进计数里读成零。
                   -- ★ APR-10(Tim 2026-09-27):【只数按金额分档的那些】—— 没有固定档位、而且在名册里的链
                   --   (采购单、报销单)。固定档位的链(条款 · 处置 · GST 申报 · 各种申请)本来就不按金额分档,
                   --   金额为 NULL 不是"折不出来";调薪按【人】路由(pay_decision_code),也不是。此前这里把它们
                   --   一并数进来,于是屏幕说调薪申请"折不出本位币金额,于是分不了档" —— 一句假话。
                   'amount_unknown',  count(*) FILTER (WHERE d.amount_base IS NULL AND d.fixed_level IS NULL
                                                         AND d.subject_type IN (SELECT g.subject_type
                                                                                  FROM approval_chain_gates() g)),
                   -- ★ APR-10:按人路由的链(不在按级的名册里,也没有固定档位)—— 屏幕为它说一句自己的话
                   'routed_by_person', bool_and(d.fixed_level IS NULL
                                                AND d.subject_type NOT IN (SELECT g.subject_type
                                                                             FROM approval_chain_gates() g))) AS x
          FROM approval_pending_documents() d
         GROUP BY d.subject_type
      ) g;

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

        -- ════════════════════════════════════════════════════════════════════
        -- ★★ APR-ROUTE-1(Tim 的 R4 · Q10):【他自己的单,谁来批】—— 忠告,不拦 ★★
        -- ════════════════════════════════════════════════════════════════════
        -- 上面那一段问"这一级有没有任何人"。它答"有"的时候,那个人自己提的、
        -- 或者说的就是他自己的单据,仍然可以没有人批:提单人那条腿拦他,
        -- 而这一级只有他一个人(EMP-SELF-0 的 F2;线上 admin 的大额采购单正是这样)。
        -- 所以这里把每一个【批得动这一级的人】逐个代入成"提单人兼主角",
        -- 再问一次 approval_deciders:除了他自己,还有没有人?
        --   · 没有,而 R2 的例外也不覆盖他  → self_exception = false(他的单会搁死)
        --   · 没有,但 R2 的例外让他自己批  → self_exception = true(只能自批,并被标记)
        -- ★【为什么是忠告】(Tim 的 Q10)线上今天就有这样的格子,而把它做成拦
        --   会让一条 Tim 自己裁定的策略开不起来。★ 等独立 CFO 账号落地、二级有了
        --   第二个人,Tim 会再看一次要不要把它改成拦 —— docs/approvals.md 记着这句。
        -- 【判据只有一份】approval_deciders;这里只是换了一组参数去问它。
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_type',    x.subject_type,
                   'action_function', x.action_function,
                   'level',           x.level,
                   'role_code',       x.role_code,
                   'user_id',         x.user_id,
                   'who',             x.who,
                   'self_exception',  x.self_only)
                   ORDER BY x.subject_type, x.action_function, x.level, x.who), '[]'::jsonb)
          INTO v_owngaps
          FROM (
            SELECT i.subject_type, i.action_function, i.level, i.role_code, p.user_id,
                   COALESCE(e.legal_name, u.email, p.user_id::text) AS who,
                   EXISTS (SELECT 1 FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                             p.user_id, account_person(p.user_id),
                                             v_s.approval_level1_role_code, v_s.approval_level2_role_code) d
                            WHERE d.via_self_exception) AS self_only
              FROM approval_gate_intersections() i
              -- 每一个批得动这一级的【人】,取他的一个账号代入
              CROSS JOIN LATERAL (
                  SELECT DISTINCT ON (d0.person_key) d0.user_id
                    FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                           NULL::uuid, NULL::uuid,
                                           v_s.approval_level1_role_code, v_s.approval_level2_role_code) d0
                   ORDER BY d0.person_key, d0.user_id) p
              LEFT JOIN auth.users u ON u.id = p.user_id
              LEFT JOIN employees e ON e.id = account_person(p.user_id)
             WHERE NOT EXISTS (
                     SELECT 1 FROM approval_deciders(i.subject_type, i.action_function, i.level,
                                        p.user_id, account_person(p.user_id),
                                        v_s.approval_level1_role_code, v_s.approval_level2_role_code) d
                      WHERE NOT d.via_self_exception)
          ) x;
    END IF;

    RETURN jsonb_build_object(
        'enabled',                 v_s.approvals_enabled,
        'level1_role_code',        v_s.approval_level1_role_code,
        'level1_holders_total',    v_l1_total,
        'level1_real_holders',     v_l1_real,
        -- ★ APR-ROUTE-1 Batch B(Q3):账号数与人数并排。独立 CFO 账号落地之后,
        --   二级会是【2 个账号、1 个人】—— 前者说"那个账号是真的",后者说"二级仍然只有一个人"。
        'level1_people',           v_l1_people,
        'level1_can_see_amounts',  v_l1_sees,
        'level1_holders_who_cannot_raise', v_l1_norais,
        'threshold_base',          v_s.approval_threshold_base,
        'level2_role_code',        v_s.approval_level2_role_code,
        'level2_holders_total',    v_l2_total,
        'level2_real_holders',     v_l2_real,
        'level2_people',           v_l2_people,
        'level2_can_see_amounts',  v_l2_sees,
        'pending_purchase_orders', v_pending,
        -- ★ APR-3:逐链的在途张数(屏幕用),与【会挡住关闭的】那个数(闸用)。
        --   两个都从 approval_pending_documents() 来 —— 一份判据,两个问题。
        'pending_by_chain',        v_pendchains,
        'pending_blocking_disable', v_blocking_p,
        -- ★ APR-2:逐条给出"这条链有几个人批得动",而不是一个布尔 ——
        --   与两级持有人给两个数、不给一个布尔是同一条理由:
        --   要分开的是"哪一条链死了、死在哪一级、缺的是哪个码"。
        'chain_gates',             v_chains,
        'chains_without_approver', v_deadchains,
        -- ★ APR-ROUTE-1(R4):一个人自己的单,除了他自己没有人批得动 —— 逐格点名。
        --   忠告,不进 blocking(Tim 的 Q10);own_document_gaps_block = false 跟着返回值走,
        --   与 no_deputy_by_decision 同形:一句只躺在文档里的"这是裁定"会被当成遗漏。
        'own_document_gaps',       v_owngaps,
        'own_document_gaps_block', false,
        'blocking',                to_jsonb(v_blocking),
        'can_enable',              (NOT v_s.approvals_enabled AND cardinality(v_blocking) = 0),
        -- ★ APR-3:判据换成【会被搁死的那些】,与 guard_approvals_switch 的
        --   关闭那一支逐字同源(它读的是同一支函数的同一个过滤条件)。
        'can_disable',             (v_s.approvals_enabled AND v_blocking_p = 0),
        -- 跟着数字走的那句话,不只躺在文档里(与 PARTY-1 的处置同形)
        'no_deputy_by_decision',   true);
END;
$function$;

COMMENT ON FUNCTION public.approvals_readiness() IS
'SOD-1,CHAIN-BUILD-1 改写(2026-08-30):审批开关能不能开,以及开不了缺哪几样 —— 屏幕与闸读同一份判据。★两级【同等对待】★:各返回 holders_total(未撤销的授权数)与 real_holders(真的登录得了的),**两个数而不是一个数加一个布尔**,因为要分开的是三种状态:没人持有 / 有人持有但登录不了 / 有能干活的人 —— 中间那一种若报成"没有持有人",操作的人会去再授一次权,而那个角色已经授过了。持有人判据只有一处定义(real_role_holders)。另报每一级的 can_see_amounts(R4)。**没有代理人、没有升级**:某一级没人就停在那一级,这是裁定,不是遗漏(no_deputy_by_decision 跟着返回值走)。';

-- create_purchase_order:签名多了 p_category(DEFAULT NULL —— 旧表单不送它,读到的是 PO_CATEGORY_REQUIRED,Q9)。
-- 旧签名先 DROP:CREATE OR REPLACE 换不了参数表,留着就是一个重载(FIN-21 那一类漂移)。
DROP FUNCTION public.create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb, text);

-- ─── create_purchase_order
CREATE OR REPLACE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_order_date date, p_expected_delivery date, p_currency text, p_fx_rate numeric, p_incoterm text, p_terms_text text, p_notes text, p_lines jsonb, p_payment_terms jsonb DEFAULT '[]'::jsonb, p_delivery_location text DEFAULT NULL::text, p_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- APR-2c:审批生效与否决定这张单生为什么状态。三态见迁移文件头。
    v_appr_on    boolean := approvals_enabled();
    v_user       uuid := auth.uid();
    v_date       date;
    v_fx         numeric;
    v_po_id      uuid := gen_random_uuid();
    v_code       text;
    v_line       jsonb;
    v_line_no    integer;
    v_line_id    uuid;      -- FIN-27:承诺挂在行上,需要它的 id
    v_qty        numeric;
    v_price      numeric;
    v_price_status text;      -- PUR-1:这一行的定价状态选择(可空 = 按事实推导)
    v_src          text;      -- FIN-26:computed / manual / NULL(旧调用方)
    v_prov         jsonb;     -- FIN-26:computed 行的重导出依据
    v_amount     numeric;
    v_material   uuid;
    v_asset       uuid;
    v_formula    uuid;
    v_f          record;
    v_total      numeric := 0;
    -- ── PO-GST-1:税 ─────────────────────────────────────────────────────────
    v_sup_tax_default text;     -- 供应商的默认进项税码(播种用)
    v_gst        boolean := gst_registered();
    v_tax_code   text;
    v_tax_rate   numeric;
    v_line_tax   numeric;
    v_tax_total  numeric := 0;
    v_count      integer := 0;
    v_committed  integer := 0;  -- FIN-27:抄下条款的行数
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer := 0;
    v_pct_total  numeric := 0;
    v_term_count integer := 0;
    v_retentions integer := 0;
    -- ── EQP-PAY-1 ──────────────────────────────────────────────────────────
    -- A2:混装单在门上【先】拒一次。计数而不是布尔,好让参数形状与既有那道
    -- guard_po_lines_single_kind 逐字相同(|单号|材料行数|设备行数)。
    v_n_material integer := 0;
    v_n_asset    integer := 0;
    v_kind       text;              -- 'equipment' / 'material'
    v_applicable boolean;           -- R5:这一期的里程碑用不用得上
    v_ret        jsonb;              -- R6:这条设备行的质保金(可选 —— 没有就【没有这一行】)
    -- ── APR-10 ─────────────────────────────────────────────────────────────
    v_raise_code text;              -- 这一类的开单码(po_category_raise_code —— 一份定义)
    v_level      smallint;          -- 提交时的档位,只用来问"提单人之外有没有人批得动"
BEGIN
    -- ★ APR-10(Tim 的矩阵 §6「开采购单,按品类」· grilling Q5 · Q6 · Q9):开单的门从 module.purchasing.edit
    --   换成【这一类的开单码】—— 工厂耗材 action.raise_po_consumables(仓库)· 设备与货物 action.raise_po_equipment
    --   (cco)· 办公用品 action.raise_po_office(财务)。品类必填、生下来就定死(Q8)。
    --   p_category 有 DEFAULT NULL,不是因为它可选:部署之前的旧表单不送它,于是读到的是一句有名字的
    --   PO_CATEGORY_REQUIRED(Q9),而不是一句"函数不存在"。
    IF p_category IS NULL OR btrim(p_category) = '' THEN
        RAISE EXCEPTION 'PO_CATEGORY_REQUIRED';
    END IF;
    v_raise_code := po_category_raise_code(p_category);
    IF v_raise_code IS NULL THEN
        RAISE EXCEPTION 'PO_CATEGORY_INVALID|%', p_category;
    END IF;
    PERFORM require_permission(v_raise_code);
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'ORDER_DATE_REQUIRED';
    END IF;
    v_date := p_order_date;
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【下单日】的行方卖出价(tt_sell)估值。
    -- 当日无牌价即拒 —— 这也逼着牌价当天录入(隔天可能就查不到了)。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_order_date, 'tt_sell');

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ── PO-GST-1:供应商的默认进项税码 —— 【行上的税码由它播种】────────────
    -- Tim 的裁定:供应商记录上那个「默认税码」字段【就是】判据。不看国别、
    -- 不看 tax_residence、不新增字段:海外供应商由 Tim 在供应商记录上设成 OP,
    -- 本地设成 TX,而这张单只是【服从供应商记录上写着的那个】。
    SELECT default_tax_code INTO v_sup_tax_default FROM suppliers WHERE id = p_supplier_id;

    v_code := next_purchase_order_code(v_date);

    INSERT INTO purchase_orders (id, code, supplier_id, order_date, expected_delivery_date,
                                 currency, fx_rate, estimated_total_ccy, status,
                                 approval_status, approved_at, approved_by,
                                 incoterm, terms_text, notes, created_by, updated_by,
                                 delivery_location, category)
    VALUES (v_po_id, v_code, p_supplier_id, v_date, p_expected_delivery,
            -- APR-2:新单【生为 draft/pending】—— 此前是 confirmed/approved,
            -- 于是"提单人发起"根本无处可放。批准把它推到 confirmed。
            p_currency, v_fx, 0,
            -- APR-2c:审批生效 → draft/pending,等人批;审批未生效 → 直接 confirmed/approved,
            -- 而【界面会明说审批未生效】,不是悄悄放行。两者都不是默认值,是一个被声明的状态。
            CASE WHEN v_appr_on THEN 'draft'   ELSE 'confirmed' END,
            CASE WHEN v_appr_on THEN 'pending' ELSE 'approved'  END,
            CASE WHEN v_appr_on THEN NULL ELSE now() END,
            CASE WHEN v_appr_on THEN NULL ELSE v_user END,
            p_incoterm, p_terms_text, p_notes, v_user, v_user,
            -- PUR-1:自由文本。空串与只有空白的输入一律收成 NULL ——
            -- 一个空串会让 PDF 那一侧画出一个空的标签,而"没填"该是【不印】。
            NULLIF(btrim(COALESCE(p_delivery_location, '')), ''),
            btrim(p_category));

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;
        v_line_no := COALESCE((v_line->>'line_no')::integer, v_count);
        v_material := (v_line->>'material_id')::uuid;
        -- EQP-1a:设备行 —— 引用一张【已经存在】的资产卡,行不创建资产
        v_asset := (v_line->>'asset_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_price := (v_line->>'estimated_unit_price')::numeric;
        v_formula := (v_line->>'pricing_formula_id')::uuid;
        -- ── PUR-1:这一行的定价状态 ──────────────────────────────────────
        -- 【省略 = NULL = 按事实推导】不是"默认定价"。既有调用方一个字不改,
        -- 而它们开出来的单在纸上印的状态与本刀之前【逐字相同】。
        v_price_status := NULLIF(btrim(COALESCE(v_line->>'price_status', '')), '');
        IF v_price_status IS NOT NULL AND v_price_status NOT IN ('fixed', 'provisional') THEN
            -- 【按名拒,不让表上那条 CHECK 去炸】屏幕上拿到一条裸约束原文,
            -- 读的人无从知道可选值是哪两个(与本函数其余具名拒绝同一条)。
            RAISE EXCEPTION 'PO_LINE_PRICE_STATUS_INVALID|%|%', v_line_no, v_price_status
              USING HINT = '定价状态只有两个取值:fixed(定价)与 provisional(暂定价)。留空表示按事实推导 —— 挂了公式就是暂定价,有单价就是定价';
        END IF;

        -- EQP-1a:恰一非空 —— 与表上那条 CHECK 同一句话,在这里【先】说一遍,
        -- 好让走门的人拿到一个具名拒绝而不是一条约束原文。
        IF num_nonnulls(v_material, v_asset) <> 1 THEN
            RAISE EXCEPTION 'PO_LINE_KIND_INVALID|%', v_line_no
              USING HINT = '一行要么订材料、要么订一台已建卡的设备,不能都给、也不能都不给';
        END IF;

        -- ── EQP-PAY-1(A2):混装单,在门上先拒一次 ────────────────────────
        -- 【这不是第二份实现】表上那道 trg_po_lines_single_kind(EQP-1a)是
        -- DEFERRABLE INITIALLY DEFERRED —— 它在 COMMIT 那一刻才炸,那时整张单
        -- 已经建完了。这里在插入第二种行的【那一刻】就拒,并且说得出该怎么办。
        -- 错误码与参数形状与那一道【逐字相同】:一条规矩只能有一个码,
        -- 否则屏幕上会有一半的拒绝印出裸码。
        IF v_material IS NOT NULL THEN v_n_material := v_n_material + 1; END IF;
        IF v_asset    IS NOT NULL THEN v_n_asset    := v_n_asset    + 1; END IF;
        IF v_n_material > 0 AND v_n_asset > 0 THEN
            RAISE EXCEPTION 'PO_LINES_MIXED_KINDS|%|%|%', v_code, v_n_material, v_n_asset
              USING HINT = '一张采购单要么全是材料行、要么全是设备行 —— 请开两张单:一张订料,一张订机器。两者的收货路径、成本处理与付款里程碑都不同';
        END IF;

        IF v_material IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_material AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(v_material::text, '?');
        END IF;
        IF v_asset IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM fixed_assets WHERE id = v_asset
        ) THEN
            RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(v_asset::text, '?');
        END IF;
        -- EQP-1a-TAIL:设备行的 quantity 与 unit 【省略即给默认,给错则按名拒】。
        -- 只给默认不够 —— 一个明确传了 quantity = 5 的调用方会通过下面那条
        -- "> 0" 的校验,然后撞上一条【裸的约束违例】,而屏幕上永不出现裸码。
        IF v_asset IS NOT NULL THEN
            IF v_qty IS NULL THEN v_qty := 1; END IF;
            IF v_qty <> 1 THEN
                RAISE EXCEPTION 'PO_LINE_EQUIPMENT_QTY|%|%', v_line_no, v_qty
                  USING HINT = '一条设备行订的是【一台】机器 —— 四台是四条行,它们各有各的资产卡与投用日';
            END IF;
            IF COALESCE(v_line->>'unit', 'unit') <> 'unit' THEN
                RAISE EXCEPTION 'PO_LINE_EQUIPMENT_UNIT|%|%', v_line_no, v_line->>'unit'
                  USING HINT = '设备行的计量单位恒为 unit —— 留空即取它;填 kg 会让这台机器被加进公斤里';
            END IF;
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_INVALID|%', v_line_no;
        END IF;
        IF v_formula IS NOT NULL THEN
            SELECT id, code, is_active, deleted_at INTO v_f
            FROM pricing_formulas WHERE id = v_formula;
            IF NOT FOUND OR v_f.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_formula;
            END IF;
            IF NOT v_f.is_active THEN
                RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
            END IF;
        END IF;

        -- 没给估价就是 0:PO 是承诺,估算金额可以留白(公式定价的料常常如此)
        v_amount := CASE WHEN v_price IS NULL THEN 0 ELSE round(v_qty * v_price, 2) END;
        v_total := v_total + v_amount;

        -- ── FIN-26:价格出处 ─────────────────────────────────────────────────
        -- computed / manual 是【记录】,不是从 expected_assay 是否为空【推断】——
        -- 推断在谁改了一个字段没改另一个的那一刻就失真。computed 必带 provenance
        -- (够重新导出这个数:化验、逐金属行情与日期、汇率与取自哪天、公式当时的
        -- 参数快照 —— 公式是可编辑的,行上引用的 id 指不住当时的样子)。
        v_src  := v_line->>'price_source';
        v_prov := v_line->'price_provenance';
        IF v_src IS NOT NULL AND v_src NOT IN ('computed', 'manual') THEN
            RAISE EXCEPTION 'PRICE_SOURCE_INVALID|%|%', v_line_no, v_src;
        END IF;
        IF v_src = 'computed' AND (v_prov IS NULL OR jsonb_typeof(v_prov) <> 'object') THEN
            RAISE EXCEPTION 'PROVENANCE_REQUIRED|%', v_line_no;
        END IF;
        IF v_src IS DISTINCT FROM 'computed' THEN
            v_prov := NULL;   -- 手填/未声明的行不留出处 —— 空白好过编造(B3)
        END IF;
        IF v_price IS NULL THEN
            v_src := NULL; v_prov := NULL;   -- 没有价就没有出处
        END IF;

        -- ── PO-GST-1:这一行的税 ─────────────────────────────────────────────
        -- 【税码在行上】一张单可以混税率:标准税率的货,旁边一条零税率或不在
        -- 范围内的行 —— 表头一个码说不出这件事。本行可以覆盖供应商的默认。
        --
        -- ★【没有税码就按名拒,不当成零】★ resolve_tax_code 已经替我们守着这一条
        -- (TAX_CODE_REQUIRED|supplier),而它正是【费用那一层用的同一支函数】——
        -- 采购单在这件事上与费用【逐字同一条规矩】。一个悄悄的 0 会印在一张
        -- 要发给供应商的纸上,那是一个错的数,不是一个空白。
        --
        -- 【GST 未注册时:与建 GST 之前一模一样】不解析、不盖码、不算税,
        -- 三列留 NULL —— 与 create_invoice / create_order_invoice 逐字同一个形状。
        IF v_gst THEN
            v_tax_code := resolve_tax_code(v_line->>'tax_code', v_sup_tax_default, 'input', 'supplier');
            v_tax_rate := tax_rate_for(v_tax_code, v_date);
            -- 【逐行取整】口径与出处见 tax_amount_for 的抬头。
            -- v_amount 为 NULL(公式定价、下单时还没有价)时税也是 NULL ——
            -- 没有净额就没有税额,而不是零。
            v_line_tax := CASE WHEN v_amount IS NULL THEN NULL
                               ELSE tax_amount_for(v_amount, v_tax_rate) END;
            v_tax_total := v_tax_total + COALESCE(v_line_tax, 0);
        ELSE
            IF NULLIF(btrim(COALESCE(v_line->>'tax_code', '')), '') IS NOT NULL THEN
                RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_line->>'tax_code';
            END IF;
            v_tax_code := NULL; v_tax_rate := NULL; v_line_tax := NULL;
        END IF;

        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, asset_id, quantity,
                                          unit, pricing_formula_id, estimated_unit_price,
                                          estimated_amount_ccy, expected_assay, notes, created_by,
                                          price_source, price_provenance,
                                          tax_code, tax_rate_pct, tax_amount_ccy,
                                          price_status)
        VALUES (v_po_id, v_line_no, v_material, v_asset, v_qty,
                COALESCE(v_line->>'unit', CASE WHEN v_asset IS NOT NULL THEN 'unit' ELSE 'kg' END), v_formula, v_price,
                v_amount, v_line->'expected_assay', v_line->>'notes', v_user,
                v_src, v_prov,
                v_tax_code, v_tax_rate, v_line_tax,
                -- PUR-1:标成 fixed 而这一行挂着公式,由 guard_po_line_price_status
                -- 按名拒(PO_LINE_PRICE_STATUS_CONFLICT)—— 那一行真的按公式结算,
                -- 而这张纸是发给供应商的。
                v_price_status)
        RETURNING id INTO v_line_id;

        -- ── FIN-27:承诺时抄下结算条款 ───────────────────────────────────────
        -- 【与估价无关】公式定价的行下单时常常没有单价,而条款照样是谈定的 ——
        -- 有公式就抄,不看 estimated_unit_price。抄下之后,公式此后怎么改、
        -- 被停用还是被软删,都碰不到这一行的结算。
        IF v_formula IS NOT NULL THEN
            PERFORM commit_pricing_terms(v_formula, v_line_id, NULL);
            v_committed := v_committed + 1;
        END IF;

        -- ── EQP-PAY-1(R6):这条设备行的质保金 ────────────────────────────────
        -- ★【可选,而"没有"是【结构性】的】★ 负载里没有 retention 这一键,就【不建行】。
        -- 系统里因此不存在"0% 的质保金"这种东西 —— 表上那条 CHECK 是 percentage > 0,
        -- 一行 0% 存不进去。"没有质保金"与"0% 质保金"是两个不同的事实,
        -- 而这里保证它们连长得一样的机会都没有。
        --
        -- 【为什么在这支函数里,而不是建完单之后再补一刀】质保金是条款的一部分。
        -- 分成两次调用,第二次失败就会留下一张【条款不全】的单,而它看起来完全正常。
        v_ret := v_line->'retention';
        IF v_ret IS NOT NULL AND jsonb_typeof(v_ret) = 'object' THEN
            IF v_asset IS NULL THEN
                RAISE EXCEPTION 'RETENTION_NOT_AN_EQUIPMENT_LINE|%', v_line_no
                  USING HINT = '质保金是设备的事 —— 一条材料行没有验收,也就没有可以起算的锚';
            END IF;
            INSERT INTO purchase_order_line_retentions
                (purchase_order_line_id, percentage, fixed_amount_ccy, retention_months,
                 anchor_event, notes)
            VALUES (v_line_id,
                    (v_ret->>'percentage')::numeric,
                    (v_ret->>'fixed_amount_ccy')::numeric,
                    COALESCE((v_ret->>'retention_months')::integer, 12),
                    COALESCE(v_ret->>'anchor_event', 'acceptance_complete'),
                    v_ret->>'notes');
            v_retentions := v_retentions + 1;
        END IF;
    END LOOP;

    -- 【净额那一列的含义没有变】estimated_total_ccy 仍然是净额 —— 审批级别、
    -- 付款里程碑的百分比、现金预测三样都挂在它上面(见该列注释)。税另立一列。
    UPDATE purchase_orders SET estimated_total_ccy = v_total,
                               tax_total_ccy = CASE WHEN v_gst THEN v_tax_total ELSE NULL END,
                               updated_by = v_user
    WHERE id = v_po_id;

    -- EQP-PAY-1:行落完了,所以这张单的种类【现在】问得出来。混装已在上面拒掉,
    -- 所以这两种情形互斥。
    v_kind := CASE WHEN v_n_asset > 0 THEN 'equipment' ELSE 'material' END;

    -- 付款计划是【可选的】:有些采购就是到货即付,没有分期可言。
    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array'
       AND jsonb_array_length(p_payment_terms) > 0 THEN
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);

            -- ── EQP-PAY-1(R5):这一期的里程碑,在这一类单上用得上吗 ────────
            -- 【此前这里一个字都不校验】—— 直接 INSERT,让表上的 CHECK 去炸,
            -- 于是屏幕上拿到的是一条裸约束原文。现在先按名拒。
            SELECT CASE WHEN v_kind = 'equipment' THEN applies_to_equipment
                        ELSE applies_to_material END
            INTO v_applicable
            FROM payment_trigger_events WHERE code = v_term->>'trigger_event';

            IF v_applicable IS NULL THEN
                RAISE EXCEPTION 'TERMS_EVENT_UNKNOWN|%|%', v_seq, COALESCE(v_term->>'trigger_event', '?')
                  USING HINT = '不认识这一种付款里程碑 —— 可选的种类是 payment_trigger_events 里的行';
            END IF;
            IF NOT v_applicable THEN
                RAISE EXCEPTION 'PO_TERM_EVENT_NOT_APPLICABLE|%|%|%|%',
                    v_code, v_seq, v_term->>'trigger_event', v_kind
                  USING HINT = '这一种里程碑在这一类采购单上用不上 —— 一台机器永远不会被化验(post_assay)。可选的种类见 payment_trigger_events 的适用性两列';
            END IF;

            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                                      fixed_amount_ccy, trigger_event, due_date, notes)
            VALUES (v_po_id, v_seq, v_term->>'label',
                    (v_term->>'percentage')::numeric,
                    (v_term->>'fixed_amount_ccy')::numeric,
                    v_term->>'trigger_event',
                    (v_term->>'due_date')::date,
                    v_term->>'notes');
            v_term_count := v_term_count + 1;
        END LOOP;

        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;
    END IF;

    -- APR-2:提单即留痕。级别留空 —— 级别是【审批当时】按金额算出来的,
    -- 提单时算出来存下就是一个会过期的副本。
    -- 审批生效时这是一次【提交】;未生效时没有人做过决定,记 auto_approved ——
    -- 与 APR-1 回填那三张旧单同一个词,理由也同一个:记录真实发生的事,不要把
    -- "系统直接盖章"伪装成一次人的决定。
    -- ★ APR-10(Tim 的裁定:提单人之外没人批得动时提交就拒;关掉 ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的采购单那一半):
    --   按这张单此刻的档位问 approval_deciders(与 approve_purchase_order 同一份判据)。线上:admin@ 开 ≥ 1,000 的单,
    --   二级只有 tim@ —— 同一个人 —— 于是拒 PO_NO_OTHER_DECIDER|<单号>。审批关着时不拒(assert_other_decider 自己判)。
    IF v_appr_on THEN
        v_level := approval_level_for(round(v_total * v_fx, 2));
        PERFORM assert_other_decider('purchase_order', 'approve_purchase_order', v_level,
                                     'PO_NO_OTHER_DECIDER|' || v_code);
    END IF;

    IF v_appr_on THEN
        PERFORM record_approval_decision('purchase_order', v_po_id, 'submitted', NULL, NULL);
    ELSE
        PERFORM record_approval_decision('purchase_order', v_po_id, 'auto_approved', NULL,
            '审批流未启用(finance_settings.approvals_enabled = false)—— 系统直接盖章,没有人做过这个决定');
    END IF;

    RETURN jsonb_build_object(
        'purchase_order_id', v_po_id,
        'code', v_code,
        'estimated_total_ccy', v_total,
        'tax_total_ccy', CASE WHEN v_gst THEN v_tax_total ELSE NULL END,
        'gross_total_ccy', CASE WHEN v_gst THEN v_total + v_tax_total ELSE NULL END,
        'line_count', v_count,
        'committed_line_count', v_committed,
        'term_count', v_term_count,
        'retention_count', v_retentions,
        'order_kind', v_kind,
        'category', btrim(p_category)
    );
END;
$function$;

-- ── 7 · 守卫(锁 · 四张表没有直连写 · 行品类)───────────────────────────────────
CREATE TRIGGER trg_gst_filing_lock
    BEFORE UPDATE OF locked_before ON public.finance_settings
    FOR EACH ROW EXECUTE FUNCTION public.guard_gst_filing_lock();
CREATE TRIGGER trg_purchase_orders_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_orders
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_po_direct_write();
CREATE TRIGGER trg_purchase_order_lines_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_order_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_po_direct_write();
CREATE TRIGGER trg_purchase_order_payment_terms_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_order_payment_terms
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_po_direct_write();
CREATE TRIGGER trg_purchase_order_line_retentions_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.purchase_order_line_retentions
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_po_direct_write();
CREATE TRIGGER trg_purchase_order_lines_category
    BEFORE INSERT OR UPDATE OF asset_id, material_id ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_line_category();

-- ── 8 · EXECUTE:内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)────────
REVOKE EXECUTE ON FUNCTION public.gst_filing_execute_internal(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_po_manager(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_gst_filing_request(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_gst_filing_request(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.decide_gst_filing_request(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_gst_filing_request(uuid, boolean, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.withdraw_gst_filing_request(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.withdraw_gst_filing_request(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_gst_filing(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_gst_filing(uuid, date, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.gst_filing_requests_visible(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gst_filing_requests_visible(uuid, integer) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.po_may_manage(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.po_may_manage(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.po_category_raise_code(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.po_category_raise_code(text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_purchase_order(uuid, date, date, text, numeric, text, text, text, jsonb, jsonb, text, text) TO authenticated, service_role;

-- ── 9 · operations_now:加一支 gst_filing_pending(镜像原样)──────────────────────────
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
         SELECT 'gst_filing_pending'::text AS item_type,
            'module.finance.view'::text AS permission,
            gq.period_id AS item_id,
            NULL::text AS doc_kind,
            gq.label AS item_code,
            gq.note AS subject,
            gq.created_at::date AS item_date
           FROM gst_filing_requests gq
          WHERE gq.status = 'submitted'::text
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

-- ── 10 · 自证 ─────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.a10_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE a10_pending_after ON COMMIT DROP AS
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
    -- ① 授权 = 之前 + 恰好裁定的那几行(不收回任何一条)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM a10_grants_before
                 UNION SELECT unnest(ARRAY['warehouse:action.raise_po_consumables', 'warehouse:module.purchasing.view', 'cco:action.raise_po_equipment', 'finance:action.raise_po_office', 'admin:action.raise_po_consumables', 'admin:action.raise_po_equipment', 'admin:action.raise_po_office'])))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a10_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|grants differ from before + ruled: %', v_bad; END IF;
    SELECT string_agg(x, ', ') INTO v_bad FROM unnest(ARRAY['warehouse:action.raise_po_consumables', 'warehouse:module.purchasing.view', 'cco:action.raise_po_equipment', 'finance:action.raise_po_office', 'admin:action.raise_po_consumables', 'admin:action.raise_po_equipment', 'admin:action.raise_po_office']) x
     WHERE x NOT IN (SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|ruled grants missing: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR10_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、GST 期间与快照、采购单(除新列)一行没变;申请表是空的;
    --    11 张单全部 equipment_goods
    IF EXISTS ((SELECT b.k, b.id FROM a10_pending_before b EXCEPT SELECT a.k, a.id FROM a10_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a10_pending_after a EXCEPT SELECT b.k, b.id FROM a10_pending_before b)) THEN
        RAISE EXCEPTION 'APR10_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a10_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(filed_on::text, '-'), ',' ORDER BY code), ''))
          FROM gst_periods) AS gst_periods,
       (SELECT count(*) FROM gst_return_boxes) AS gst_return_boxes,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || approval_status || ':' || estimated_total_ccy::text
                                       || ':' || COALESCE(updated_at::text, '-'), ',' ORDER BY code), ''))
          FROM purchase_orders) AS purchase_orders,
       (SELECT count(*) FROM purchase_order_lines) AS po_lines,
       (SELECT count(*) FROM purchase_order_payment_terms) AS po_terms,
       (SELECT count(*) FROM purchase_order_history) AS po_history,
       (SELECT locked_before FROM finance_settings) AS locked_before) n) THEN
        RAISE EXCEPTION 'APR10_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a10_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(filed_on::text, '-'), ',' ORDER BY code), ''))
          FROM gst_periods) AS gst_periods,
       (SELECT count(*) FROM gst_return_boxes) AS gst_return_boxes,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || approval_status || ':' || estimated_total_ccy::text
                                       || ':' || COALESCE(updated_at::text, '-'), ',' ORDER BY code), ''))
          FROM purchase_orders) AS purchase_orders,
       (SELECT count(*) FROM purchase_order_lines) AS po_lines,
       (SELECT count(*) FROM purchase_order_payment_terms) AS po_terms,
       (SELECT count(*) FROM purchase_order_history) AS po_history,
       (SELECT locked_before FROM finance_settings) AS locked_before) n);
    END IF;
    IF EXISTS (SELECT 1 FROM gst_filing_requests) THEN
        RAISE EXCEPTION 'APR10_PROOF|gst_filing_requests is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM purchase_orders WHERE category IS DISTINCT FROM 'equipment_goods') THEN
        RAISE EXCEPTION 'APR10_PROOF|a purchase order was not backfilled to equipment_goods';
    END IF;
    RAISE NOTICE 'APR10 backfilled % purchase orders to equipment_goods', (SELECT count(*) FROM purchase_orders);

    -- ④ 结构:申请表与采购单四张表没有写策略;守卫挂上;内层算子 authenticated 调不到;
    --    名册里 GST 一行、只有二级;create_purchase_order 只剩一个签名
    SELECT string_agg(tablename || ':' || cmd, ', ') INTO v_bad FROM pg_policies
     WHERE schemaname = 'public' AND cmd <> 'SELECT' AND tablename IN ('gst_filing_requests', 'purchase_orders', 'purchase_order_lines', 'purchase_order_payment_terms', 'purchase_order_line_retentions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|write policies left: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_gst_filing_lock', 'trg_purchase_orders_direct_write', 'trg_purchase_order_lines_direct_write', 'trg_purchase_order_payment_terms_direct_write', 'trg_purchase_order_line_retentions_direct_write', 'trg_purchase_order_lines_category');
    IF v_n <> 6 THEN RAISE EXCEPTION 'APR10_PROOF|expected 6 guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY['public.gst_filing_execute_internal(uuid)', 'public.assert_po_manager(uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR10_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'gst_filing_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR10_PROOF|gst_filing_request chain row';
    END IF;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'create_purchase_order') <> 1 THEN
        RAISE EXCEPTION 'APR10_PROOF|create_purchase_order has more than one signature';
    END IF;

    -- ⑤ GST 链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('gst_filing_request', 'decide_gst_filing_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR10_PROOF|nobody can decide a GST filing'; END IF;
    RAISE NOTICE 'APR10 deciders for gst_filing_request: %', v_n;

    -- ⑥ 三类的开单码各有真持有人(admin 以外至少一个);每一类的开单人 × 每一级,提单人之外还有没有人批 —— 只报
    FOR k, v_bad IN
        SELECT c.code, string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = rg.user_id), ' ')
          FROM unnest(ARRAY['action.raise_po_consumables', 'action.raise_po_equipment', 'action.raise_po_office']::text[]) c(code)
          JOIN role_permissions rp ON rp.permission_code = c.code
          JOIN roles ro ON ro.id = rp.role_id
          CROSS JOIN LATERAL real_role_grants(ro.code) rg
         GROUP BY c.code ORDER BY 1
    LOOP
        RAISE NOTICE 'APR10 raisers %: %', k, v_bad;
    END LOOP;

    -- ⑦ 每一张在途单据 —— 连同每一条申请链 —— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a10_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR10 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a10_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR10_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a10_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a10_pending_decider_check(boolean);

COMMIT;

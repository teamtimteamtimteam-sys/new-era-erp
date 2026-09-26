-- db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql
-- APR-8 —— 合同条款与定价公式:cco 提,CFO 批每一张,批准之前什么都不生效
-- (docs/role-matrix.md「合同条款 · 定价公式 | cco | CFO」)。
-- 由 db/scripts/build_apr8_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-8 grilling Q1–Q11,Tim 2026-09-26 全部接受)
--   ① 公式(Q1):新公式生下来停用、挂一张 formula_create;改在用的公式 = 一张带完整拟议条款的 formula_change,
--      批准时就地替换(pricing_formula_history 照记);等待期间旧条款照旧生效;重新启用 = formula_reactivate;
--      停用、删除仍是 cco 一步(deactivate_pricing_formula · delete_pricing_formula)。不加状态列。
--   ② 合同(Q2):只有 active 有效力,进入 active 的每一条路都经 CFO(contract_activate);生效中的合同表头与七张
--      条款表冻结;改 = 暂停、编辑、再申请,CFO 看见与上一次批准时那一份的差别;暂停 / 到期 / 终止仍是一步。
--   ③ 一张表 terms_requests,四种(Q4);submitted → approved(当场生效)· rejected(要理由)· withdrawn。
--      提交按同一条路试跑(PQ006);审批关着时生下来就批准并生效(auto_approved)。
--   ④ 冻结(Q5):一个主体只挂一张在等的(TERMS_REQUEST_OPEN);合同等待中表头 TERMS_REQUEST_FREEZES_CONTRACT、
--      条款 CONTRACT_TERMS_FROZEN;批准时 fingerprint 再比(TERMS_CHANGED_SINCE_REQUEST)。
--   ⑤ 关门(Q6):公式两张表的六条写策略拿掉,直连写按名拒 PRICING_FORMULA_THROUGH_REQUEST_ONLY(语句级,零行也拒);
--      合同直连只许建草稿(CONTRACT_ACTIVATES_THROUGH_REQUEST)、生效中表头 CONTRACT_ACTIVE_IS_FROZEN。
--   ⑥ 引擎登记(Q9):approval_chain_gates 一行(二级,五个门码);approval_pending_documents 一支(blocks_disable、
--      fixed_level = 2、金额 NULL);approval_log 的主体类型与读策略;record_approval_decision 一支;
--      operations_now 一支 terms_request_pending。
--
-- 【不做什么】不新增任何权限码(Q6),所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行 —— 线上那张 PF-2026-0001 照旧在用(Q7)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一条没变;在途单据一张不少、一张不多;
-- approval_log、分录、公式、比例、公式历史、合同、条款、承诺一行没变;申请表是空的;公式两张表与申请表没有写策略;
-- 十支守卫挂上;内层算子 authenticated 调不到;新链有人批得了;每一张在途单据(连同每一条申请链)都还有一个
-- 【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR8_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.terms_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR8_PRE|terms_requests already exists';
    END IF;
    -- 批的人要持五个门码:cfo 今天五个都持(APR-8 Step 0 以 postgres 读 role_permissions 量过)
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.pricing.view', 'data.view_prices',
               'data.view_purchase_prices', 'module.suppliers.view', 'module.customers.view')) <> 5 THEN
        RAISE EXCEPTION 'APR8_PRE|cfo does not hold all five gate codes';
    END IF;
    -- 六条要拿掉的写策略此刻都在
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND tablename IN ('pricing_formulas', 'pricing_formula_metals') AND cmd <> 'SELECT') <> 6 THEN
        RAISE EXCEPTION 'APR8_PRE|expected exactly six formula write policies';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a8_pending_before ON COMMIT DROP AS
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
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted';
CREATE TEMP TABLE a8_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM pricing_formulas) AS formulas,
       (SELECT count(*) FROM pricing_formulas WHERE is_active AND deleted_at IS NULL) AS formulas_live,
       (SELECT count(*) FROM pricing_formula_metals) AS formula_metals,
       (SELECT count(*) FROM pricing_formula_history) AS formula_history,
       (SELECT count(*) FROM pricing_term_commitments) AS commitments,
       (SELECT count(*) FROM contracts) AS contracts,
       (SELECT (SELECT count(*) FROM contract_grade_specs) + (SELECT count(*) FROM contract_insurance_obligations)
             + (SELECT count(*) FROM contract_volume_commitments) + (SELECT count(*) FROM contract_pricing_terms)
             + (SELECT count(*) FROM contract_settlement_terms) + (SELECT count(*) FROM contract_refining_charges)
             + (SELECT count(*) FROM contract_penalty_elements)) AS contract_terms,
       (SELECT count(*) FROM contract_document_terms) AS contract_links;
CREATE TEMP TABLE a8_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · terms_requests(镜像原样)────────────────────────────────────────────
CREATE TABLE public.terms_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind               text NOT NULL
        CHECK (kind IN ('formula_create', 'formula_change', 'formula_reactivate', 'contract_activate')),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    -- ── 主体:恰好一列 ─────────────────────────────────────────────────────
    formula_id         uuid REFERENCES public.pricing_formulas (id) ON DELETE RESTRICT,
    contract_id        uuid REFERENCES public.contracts (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    reason             text NOT NULL CHECK (btrim(reason) <> ''),
    -- 公式三种:批准时就地写进公式的那一组条款(规范形,见 formula_terms_normalize);合同:NULL
    proposed           jsonb,
    snapshot           jsonb NOT NULL,
    -- 提交时主体的样子(md5);批准时再算一遍
    fingerprint        text NOT NULL,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    executed_at        timestamptz,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT terms_requests_kind_shape CHECK (
        (kind IN ('formula_create', 'formula_change', 'formula_reactivate')) = (formula_id IS NOT NULL)
        AND (kind = 'contract_activate') = (contract_id IS NOT NULL)
        AND (kind IN ('formula_create', 'formula_change', 'formula_reactivate')) = (proposed IS NOT NULL)),
    -- 恰好一个主体 —— 与 kind_shape 同一件事的另一种写法,留着它是给关系图读的(warehouse_requests 同一条理由)
    CONSTRAINT terms_requests_one_subject CHECK (num_nonnulls(formula_id, contract_id) = 1),
    CONSTRAINT terms_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT terms_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT terms_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT terms_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.terms_requests IS
    'APR-8:定价公式(formula_create / formula_change / formula_reactivate)与合同生效(contract_activate)的申请 —— cco 提,CFO 批每一张,不分档,批准当场生效。submitted → approved(CFO)· rejected(要理由)· withdrawn(提单人本人或该种类的码)。审批关着时生下来就是 approved 并当场生效(auto_approved)。在等的时候:一个主体只挂一张(TERMS_REQUEST_OPEN);合同表头与条款冻结;公式本来就没有直连写;批准时 fingerprint 再比一遍(TERMS_CHANGED_SINCE_REQUEST)。';

COMMENT ON COLUMN public.terms_requests.proposed IS
    'APR-8(grilling Q1):公式三种申请批准时就地写进公式的那一组完整条款(规范形:表头各列 + metals 按金属排序)。等待期间公式上仍是旧条款、旧条款照旧生效。合同申请为 NULL —— 合同的条款就在七张条款表里,提交时冻结。';

COMMENT ON COLUMN public.terms_requests.snapshot IS
    'APR-8(grilling Q8):提交时冻下来给 CFO 读的那一组 —— 主体编号与名称、current(提交时的条款)、proposed、last_approved(上一次批准时那一份)、usage(哪些单据会用它)。含价格条款 —— 屏幕经 terms_requests_visible() 读,按 pricing_formula_terms_visible 与合同那一侧的码遮蔽。';

CREATE UNIQUE INDEX terms_requests_one_open_formula
    ON public.terms_requests (formula_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX terms_requests_one_open_contract
    ON public.terms_requests (contract_id) WHERE status = 'submitted';
CREATE INDEX terms_requests_open ON public.terms_requests (kind) WHERE status = 'submitted';
CREATE INDEX terms_requests_formula_id_rel ON public.terms_requests (formula_id);
CREATE INDEX terms_requests_contract_id_rel ON public.terms_requests (contract_id);

ALTER TABLE public.terms_requests ENABLE ROW LEVEL SECURITY;

-- 读:公式申请要看得见公式与它的价格(module.pricing.view + 两个价格码);合同申请跟着合同那一侧走
-- (contracts 自己的读策略同一条)。屏幕不直接读本表,读 terms_requests_visible()。写:一条策略都不给 ——
-- 只经 submit_* · decide_terms_request · withdraw_terms_request(全是 SECURITY DEFINER)。
CREATE POLICY "terms_requests select by permission" ON public.terms_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((formula_id IS NOT NULL AND has_permission('module.pricing.view'::text)
                AND has_permission('data.view_prices'::text) AND has_permission('data.view_purchase_prices'::text))
        OR (contract_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM contracts c WHERE c.id = terms_requests.contract_id
                   AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                     OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text))))));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.terms_requests FROM anon;

-- ── 2 · approval_log:主体类型加 terms_request;读策略加同名一支 ────────────────
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
                            'terms_request'));
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
            ELSE false
        END
    );

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/formula_terms_state.sql
-- APR-8(2026-09-26):一张公式此刻的条款,规范形 —— 表头各列 + metals(按金属排序)。不含 is_active / deleted_at。
-- 三个读它的人:提交时的 current 与"没有改动"那一判(与 formula_terms_normalize 出来的拟议条款逐项比 jsonb,
-- 数值按值比,70 与 70.00 相等)、fingerprint、CFO 的 snapshot。不存在的公式 → NULL。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.formula_terms_state(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'name', f.name, 'direction', f.direction, 'price_basis', f.price_basis,
               'average_days', f.average_days,
               'treatment_charge_usd_per_tonne', f.treatment_charge_usd_per_tonne,
               'flat_discount_pct', f.flat_discount_pct,
               'supplier_id', f.supplier_id, 'customer_id', f.customer_id,
               'price_index', f.price_index, 'notes', f.notes,
               'metals', COALESCE((SELECT jsonb_agg(jsonb_build_object('metal', m.metal, 'payable_pct', m.payable_pct)
                                                    ORDER BY m.metal)
                                     FROM pricing_formula_metals m WHERE m.formula_id = f.id), '[]'::jsonb))
      FROM pricing_formulas f
     WHERE f.id = p_formula_id
$function$;

-- db/functions/contract_terms_state.sql
-- APR-8(2026-09-26):一份合同此刻的样子 —— 表头(去掉 id、编号与创建 / 修改人时刻)与七张条款表的每一行
-- (去掉 id、contract_id 与创建 / 修改人时刻,按行文排序,于是同一组条款读出同一串字)。
-- 三个读它的人:CFO 的 snapshot(current;上一次批准时的那一份也是它)、fingerprint、屏幕上的差别。
-- 不存在的合同 → NULL。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.contract_terms_state(p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'header', to_jsonb(c) - 'id' - 'code' - 'status' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by',
               'grade_specs', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_grade_specs t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'insurance_obligations', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_insurance_obligations t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'volume_commitments', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_volume_commitments t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'pricing_terms', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_pricing_terms t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'settlement_terms', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_settlement_terms t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'refining_charges', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_refining_charges t WHERE t.contract_id = c.id) x), '[]'::jsonb),
               'penalty_elements', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (
                   SELECT to_jsonb(t) - 'id' - 'contract_id' - 'created_at' - 'created_by' - 'updated_at' - 'updated_by' AS j
                     FROM contract_penalty_elements t WHERE t.contract_id = c.id) x), '[]'::jsonb))
      FROM contracts c
     WHERE c.id = p_contract_id
$function$;

-- db/functions/formula_terms_normalize.sql
-- APR-8(2026-09-26):把屏幕送来的一组公式条款变成规范形(与 formula_terms_state 同一个形状)。
-- 缺省与表的 DEFAULT 一致(direction both · price_basis spot · 两项费用 0);空白的 price_index / notes 读成 NULL。
-- 读不懂 → TERMS_FORMULA_INVALID|哪一项 —— 【不】当成"没有这一项":一组读不懂的金属当空集,等于"所有金属都不计价"
-- (FormulaForm 那座 JSON 桥记过同一条)。值是否在范围内由表上的 CHECK 在试跑时按原话回答。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.formula_terms_normalize(p_terms jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_name   text;
    v_metals jsonb;
    v_field  text := 'terms';
BEGIN
    IF p_terms IS NULL OR jsonb_typeof(p_terms) <> 'object' THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|terms';
    END IF;
    v_name := btrim(COALESCE(p_terms->>'name', ''));
    IF v_name = '' THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|name';
    END IF;
    IF jsonb_typeof(COALESCE(p_terms->'metals', '[]'::jsonb)) <> 'array' THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|metals';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(p_terms->'metals', '[]'::jsonb)) e
                WHERE jsonb_typeof(e) <> 'object' OR COALESCE(btrim(e->>'metal'), '') = ''
                   OR COALESCE(jsonb_typeof(e->'payable_pct'), 'null') = 'null') THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|metals';
    END IF;
    BEGIN
        v_field := 'metals';
        SELECT COALESCE(jsonb_agg(jsonb_build_object('metal', m.metal, 'payable_pct', m.pct) ORDER BY m.metal), '[]'::jsonb)
          INTO v_metals
          FROM (SELECT btrim(e->>'metal') AS metal, (e->>'payable_pct')::numeric AS pct
                  FROM jsonb_array_elements(COALESCE(p_terms->'metals', '[]'::jsonb)) e) m;
        v_field := 'average_days';
        PERFORM (p_terms->>'average_days')::integer;
        v_field := 'treatment_charge_usd_per_tonne';
        PERFORM (p_terms->>'treatment_charge_usd_per_tonne')::numeric;
        v_field := 'flat_discount_pct';
        PERFORM (p_terms->>'flat_discount_pct')::numeric;
        v_field := 'supplier_id';
        PERFORM (NULLIF(p_terms->>'supplier_id', ''))::uuid;
        v_field := 'customer_id';
        PERFORM (NULLIF(p_terms->>'customer_id', ''))::uuid;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|%', v_field;
    END;
    RETURN jsonb_build_object(
        'name', v_name,
        'direction', COALESCE(NULLIF(p_terms->>'direction', ''), 'both'),
        'price_basis', COALESCE(NULLIF(p_terms->>'price_basis', ''), 'spot'),
        'average_days', (p_terms->>'average_days')::integer,
        'treatment_charge_usd_per_tonne', COALESCE((p_terms->>'treatment_charge_usd_per_tonne')::numeric, 0),
        'flat_discount_pct', COALESCE((p_terms->>'flat_discount_pct')::numeric, 0),
        'supplier_id', (NULLIF(p_terms->>'supplier_id', ''))::uuid,
        'customer_id', (NULLIF(p_terms->>'customer_id', ''))::uuid,
        'price_index', NULLIF(btrim(COALESCE(p_terms->>'price_index', '')), ''),
        'notes', NULLIF(btrim(COALESCE(p_terms->>'notes', '')), ''),
        'metals', v_metals);
END;
$function$;

-- db/functions/terms_request_fingerprint.sql
-- APR-8(2026-09-26,grilling Q5):主体此刻的样子 —— 提交时算一遍存进申请,批准时(terms_request_execute_internal)
-- 再算一遍,不一样 → TERMS_CHANGED_SINCE_REQUEST。公式:条款 + is_active + deleted_at;合同:表头 + 七张条款表 +
-- status + deleted_at。冻结让它在等待中几乎不会变 —— 这一道是给属主路径(迁移、修数)走过去的那一次留的。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_fingerprint(p_kind text, p_subject uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT md5(CASE WHEN p_kind = 'contract_activate' THEN
                   (SELECT jsonb_build_object('terms', contract_terms_state(c.id), 'status', c.status,
                                              'deleted_at', c.deleted_at)::text
                      FROM contracts c WHERE c.id = p_subject)
               ELSE
                   (SELECT jsonb_build_object('terms', formula_terms_state(f.id), 'is_active', f.is_active,
                                              'deleted_at', f.deleted_at)::text
                      FROM pricing_formulas f WHERE f.id = p_subject)
               END)
$function$;

-- db/functions/terms_request_snapshot.sql
-- APR-8(2026-09-26,grilling Q8):提交时冻给 CFO 读的那一组。
--   公式:formula_code / formula_name / direction;current(提交时公式上的条款;新公式为 NULL —— 它此前什么都不是);
--        proposed(批准时写进去的那一组);last_approved(这张公式上一次被批准的那一组,从未批过为 NULL);
--        usage —— 哪些单据用它:已抄下承诺的采购行、已承诺的批次(这两类【不受影响】,它们读的是副本),
--        以及挂着这张公式却还没承诺的批次(应用化验时会抄【批准那一刻】活的条款)。计价器、新采购单、销售从批准起读新条款。
--   合同:contract_code / title / side / counterparty_name;current(提交时的表头与七张条款表);
--        last_approved(上一次批准生效时的那一份,从未批过为 NULL);linked_documents(已挂上的单据 —— 各自带着
--        挂上那一刻抄下的 contract_document_terms,不受影响)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_snapshot(p_kind text, p_subject uuid, p_proposed jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN p_kind = 'contract_activate' THEN (
        SELECT jsonb_build_object(
            'contract_code', c.code, 'title', c.title, 'side', c.side, 'status', c.status,
            'counterparty_name', COALESCE((SELECT COALESCE(s.short_name, s.legal_name) FROM suppliers s WHERE s.id = c.supplier_id),
                                          (SELECT cu.legal_name FROM customers cu WHERE cu.id = c.customer_id)),
            'current', contract_terms_state(c.id),
            'last_approved', (SELECT r.snapshot->'current' FROM terms_requests r
                               WHERE r.contract_id = c.id AND r.status = 'approved'
                               ORDER BY r.executed_at DESC LIMIT 1),
            'linked_documents', (SELECT count(*) FROM contract_document_terms d WHERE d.contract_id = c.id))
          FROM contracts c WHERE c.id = p_subject)
    ELSE (
        SELECT jsonb_build_object(
            'formula_code', f.code, 'formula_name', f.name, 'direction', f.direction, 'is_active', f.is_active,
            'current', CASE WHEN p_kind = 'formula_create' THEN NULL ELSE formula_terms_state(f.id) END,
            'proposed', p_proposed,
            'last_approved', (SELECT r.proposed FROM terms_requests r
                               WHERE r.formula_id = f.id AND r.status = 'approved'
                               ORDER BY r.executed_at DESC LIMIT 1),
            'usage', jsonb_build_object(
                'po_lines_committed', (SELECT count(*) FROM purchase_order_lines l
                                        WHERE l.pricing_formula_id = f.id
                                          AND EXISTS (SELECT 1 FROM pricing_term_commitments ptc
                                                       WHERE ptc.purchase_order_line_id = l.id)),
                'batches_committed', (SELECT count(*) FROM inbound_batches b
                                       WHERE b.pricing_formula_id = f.id AND b.deleted_at IS NULL
                                         AND (EXISTS (SELECT 1 FROM pricing_term_commitments ptc WHERE ptc.inbound_batch_id = b.id)
                                              OR EXISTS (SELECT 1 FROM pricing_term_commitments ptc
                                                          WHERE ptc.purchase_order_line_id = b.purchase_order_line_id))),
                'batches_uncommitted', (SELECT count(*) FROM inbound_batches b
                                         WHERE b.pricing_formula_id = f.id AND b.deleted_at IS NULL
                                           AND NOT EXISTS (SELECT 1 FROM pricing_term_commitments ptc WHERE ptc.inbound_batch_id = b.id)
                                           AND NOT EXISTS (SELECT 1 FROM pricing_term_commitments ptc
                                                            WHERE ptc.purchase_order_line_id = b.purchase_order_line_id))))
          FROM pricing_formulas f WHERE f.id = p_subject)
    END
$function$;

-- db/functions/contract_terms_lock_reason.sql
-- APR-8(2026-09-26,grilling Q2 · Q5):一份合同此刻为什么不许直连改 —— 两支守卫(合同表头、七张条款表)的一份判据。
--   'request:<label>'  有一张在等的生效申请(TERMS_REQUEST_FREEZES_CONTRACT / CONTRACT_TERMS_FROZEN)
--   'active'           合同在生效中:条款冻结;表头只许把状态改成暂停 / 到期 / 终止
--   NULL               草稿、暂停、到期、终止,或不存在:照改
-- SECURITY DEFINER:守卫以调用者身份跑,而调用者未必读得到申请表(它只给 CFO 那一组码)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.contract_terms_lock_reason(p_contract_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(
        (SELECT 'request:' || r.label FROM terms_requests r
          WHERE r.contract_id = p_contract_id AND r.status = 'submitted' LIMIT 1),
        (SELECT 'active' FROM contracts c WHERE c.id = p_contract_id AND c.status = 'active'))
$function$;

-- db/functions/terms_request_execute_internal.sql
-- APR-8(2026-09-26):一张条款申请的【生效本身】—— 只从批准、审批关着时的提交与试跑里调用。
--   0. fingerprint 再算一遍,与提交时不一样 → TERMS_CHANGED_SINCE_REQUEST|label(grilling Q5)。
--   公式三种:主体要在(FORMULA_NOT_FOUND);修改时仍要在用(FORMULA_NOT_ACTIVE);proposed 就地写进表头与
--     逐金属比例(不在 proposed 里的金属删掉 = 不计价;没变的比例不写,于是 pricing_formula_history 只记真的变动),
--     is_active = true。
--   合同:仍是 draft 或 suspended(CONTRACT_NOT_ACTIVATABLE)→ status = active。条款在七张表里,提交时已冻结。
-- 属主路径写(本支 SECURITY DEFINER):两支直连写守卫看不见它,那正是它们该有的样子。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      terms_requests%ROWTYPE;
    v_code   text;
    v_active boolean;
    v_status text;
    v_t      jsonb;
BEGIN
    SELECT * INTO v_r FROM terms_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF terms_request_fingerprint(v_r.kind, COALESCE(v_r.formula_id, v_r.contract_id)) IS DISTINCT FROM v_r.fingerprint THEN
        RAISE EXCEPTION 'TERMS_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    IF v_r.kind = 'contract_activate' THEN
        SELECT code, status INTO v_code, v_status FROM contracts
         WHERE id = v_r.contract_id AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', v_r.contract_id;
        END IF;
        IF v_status NOT IN ('draft', 'suspended') THEN
            RAISE EXCEPTION 'CONTRACT_NOT_ACTIVATABLE|%|%', v_code, v_status;
        END IF;
        UPDATE contracts SET status = 'active' WHERE id = v_r.contract_id;
        RETURN jsonb_build_object('contract_id', v_r.contract_id, 'code', v_code, 'status', 'active');
    END IF;

    SELECT code, is_active INTO v_code, v_active FROM pricing_formulas
     WHERE id = v_r.formula_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_r.formula_id;
    END IF;
    IF v_r.kind = 'formula_change' AND NOT v_active THEN
        RAISE EXCEPTION 'FORMULA_NOT_ACTIVE|%', v_code;
    END IF;
    v_t := v_r.proposed;
    UPDATE pricing_formulas
       SET name = v_t->>'name',
           direction = v_t->>'direction',
           price_basis = v_t->>'price_basis',
           average_days = (v_t->>'average_days')::integer,
           treatment_charge_usd_per_tonne = (v_t->>'treatment_charge_usd_per_tonne')::numeric,
           flat_discount_pct = (v_t->>'flat_discount_pct')::numeric,
           supplier_id = (v_t->>'supplier_id')::uuid,
           customer_id = (v_t->>'customer_id')::uuid,
           price_index = v_t->>'price_index',
           notes = v_t->>'notes',
           is_active = true
     WHERE id = v_r.formula_id;
    DELETE FROM pricing_formula_metals m
     WHERE m.formula_id = v_r.formula_id
       AND m.metal NOT IN (SELECT e->>'metal' FROM jsonb_array_elements(v_t->'metals') e);
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    SELECT v_r.formula_id, e->>'metal', (e->>'payable_pct')::numeric
      FROM jsonb_array_elements(v_t->'metals') e
    ON CONFLICT (formula_id, metal) DO UPDATE SET payable_pct = EXCLUDED.payable_pct
     WHERE pricing_formula_metals.payable_pct IS DISTINCT FROM EXCLUDED.payable_pct;
    RETURN jsonb_build_object('formula_id', v_r.formula_id, 'code', v_code, 'is_active', true);
END;
$function$;

-- db/functions/terms_request_dry_run.sql
-- APR-8(2026-09-26):提交时按批准那一刻的同一条路试跑一遍(terms_request_execute_internal),然后整段退回
-- (SQLSTATE PQ006 —— 只在这里抛、只在这里接)。条款违反公式表上的任何一条 CHECK、金属不在字典里、同一个金属
-- 写了两遍 —— 全在提交时按原话拒,不等到 CFO 按下批准才发现。只从提交里调用;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := terms_request_execute_internal(p_request_id);
        RAISE EXCEPTION USING ERRCODE = 'PQ006', MESSAGE = 'TERMS_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ006' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$;

-- db/functions/terms_request_submit_internal.sql
-- APR-8(2026-09-26):提一张条款申请 —— 四扇提交的门各问完自己的码,落进这一支。本支不问码。
--
--   1. 主体要在、这一种要成立:
--        公式:没删(FORMULA_NOT_FOUND);修改要在用(FORMULA_NOT_ACTIVE);新建 / 重新启用要停用着(FORMULA_ALREADY_ACTIVE);
--              拟议条款规范化(formula_terms_normalize);修改而条款与此刻一模一样 → TERMS_REQUEST_NO_CHANGE|编号。
--        合同:没删(CONTRACT_NOT_FOUND);是 draft 或 suspended(CONTRACT_NOT_ACTIVATABLE|编号|状态);
--              合同期已经结束 → CONTRACT_PERIOD_ENDED|编号|截止日。
--   2. 理由必填(TERMS_REQUEST_REASON_REQUIRED|种类|编号)。
--   3. 同一个主体上已有一张在等 → TERMS_REQUEST_OPEN|编号|那一张(grilling Q5;唯一索引是第二道)。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动 → TERMS_REQUEST_NO_OTHER_DECIDER|label
--      (assert_other_decider,按人认)。线上 admin@ 与 tim@ 是同一个人,而二级只有 tim@ —— admin@ 提的一律按名拒。
--   5. 落一行 submitted:snapshot 与 fingerprint 冻结;按批准那一刻的同一支试跑(terms_request_dry_run)。
--   6. 审批开着:留痕 submitted,二级。关着:当场生效,状态 approved,留痕 auto_approved。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_submit_internal(p_kind text, p_subject uuid, p_proposed jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on     boolean := approvals_enabled();
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_active boolean;
    v_status text;
    v_to     date;
    v_prop   jsonb := NULL;
    v_open   text;
    v_n      integer;
    v_label  text;
BEGIN
    IF p_kind IN ('formula_create', 'formula_change', 'formula_reactivate') THEN
        SELECT code, is_active INTO v_code, v_active FROM pricing_formulas
         WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF p_kind = 'formula_change' AND NOT v_active THEN
            RAISE EXCEPTION 'FORMULA_NOT_ACTIVE|%', v_code;
        END IF;
        IF p_kind IN ('formula_create', 'formula_reactivate') AND v_active THEN
            RAISE EXCEPTION 'FORMULA_ALREADY_ACTIVE|%', v_code;
        END IF;
        v_prop := formula_terms_normalize(COALESCE(p_proposed, formula_terms_state(p_subject)));
        IF p_kind = 'formula_change' AND v_prop = formula_terms_state(p_subject) THEN
            RAISE EXCEPTION 'TERMS_REQUEST_NO_CHANGE|%', v_code;
        END IF;
    ELSIF p_kind = 'contract_activate' THEN
        SELECT code, status, effective_to INTO v_code, v_status, v_to FROM contracts
         WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_status NOT IN ('draft', 'suspended') THEN
            RAISE EXCEPTION 'CONTRACT_NOT_ACTIVATABLE|%|%', v_code, v_status;
        END IF;
        IF v_to IS NOT NULL AND v_to < CURRENT_DATE THEN
            RAISE EXCEPTION 'CONTRACT_PERIOD_ENDED|%|%', v_code, v_to;
        END IF;
    ELSE
        RAISE EXCEPTION 'TERMS_REQUEST_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_REASON_REQUIRED|%|%', p_kind, v_code;
    END IF;

    SELECT r.label INTO v_open FROM terms_requests r
     WHERE r.status = 'submitted' AND (r.formula_id = p_subject OR r.contract_id = p_subject)
     LIMIT 1;
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'TERMS_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;

    -- label:同一个主体上第几张。咨询锁串行化"数一遍 + 1"。
    PERFORM pg_advisory_xact_lock(hashtext('terms_request_label')::bigint);
    SELECT count(*) + 1 INTO v_n FROM terms_requests r
     WHERE COALESCE(r.formula_id, r.contract_id) = p_subject;
    v_label := v_code || ' · ' || CASE p_kind WHEN 'formula_create' THEN 'new'
                                               WHEN 'formula_change' THEN 'change'
                                               WHEN 'formula_reactivate' THEN 'reactivate'
                                               ELSE 'activate' END || ' #' || v_n::text;

    PERFORM assert_other_decider('terms_request', 'decide_terms_request', 2::smallint,
                                 'TERMS_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO terms_requests (id, kind, status, label, formula_id, contract_id, reason, proposed,
                                snapshot, fingerprint, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label,
            CASE WHEN p_kind <> 'contract_activate' THEN p_subject END,
            CASE WHEN p_kind = 'contract_activate' THEN p_subject END,
            btrim(p_reason), v_prop, terms_request_snapshot(p_kind, p_subject, v_prop),
            terms_request_fingerprint(p_kind, p_subject), auth.uid());

    PERFORM terms_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('terms_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM terms_request_execute_internal(v_id);
        UPDATE terms_requests SET status = 'approved', executed_at = now() WHERE id = v_id;
        PERFORM record_approval_decision('terms_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场生效,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'subject_code', v_code,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$;

-- db/functions/submit_formula_create_request.sql
-- APR-8(2026-09-26,grilling Q1):新建一张定价公式 = 建一张【停用着】的公式 + 一张 formula_create 申请。
-- 门 module.pricing.edit(cco)。公式在 CFO 批准之前不能用(pricing_terms_of_formula 按名拒 FORMULA_INACTIVE);
-- 驳回或撤回后它停用着留下,cco 改了条款再提 formula_reactivate。提交里任何一处按名拒 = 整笔回滚,公式也不留。
-- 审批关着时生下来就批准并生效。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_formula_create_request(p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t  jsonb;
    v_id uuid;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    v_t := formula_terms_normalize(p_terms);
    INSERT INTO pricing_formulas (code, name, direction, price_basis, average_days, treatment_charge_usd_per_tonne,
                                  flat_discount_pct, supplier_id, customer_id, price_index, notes, is_active)
    VALUES ('', v_t->>'name', v_t->>'direction', v_t->>'price_basis', (v_t->>'average_days')::integer,
            (v_t->>'treatment_charge_usd_per_tonne')::numeric, (v_t->>'flat_discount_pct')::numeric,
            (v_t->>'supplier_id')::uuid, (v_t->>'customer_id')::uuid, v_t->>'price_index', v_t->>'notes', false)
    RETURNING id INTO v_id;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    SELECT v_id, e->>'metal', (e->>'payable_pct')::numeric FROM jsonb_array_elements(v_t->'metals') e;
    RETURN terms_request_submit_internal('formula_create', v_id, v_t, p_reason) || jsonb_build_object('formula_id', v_id);
END;
$function$;

-- db/functions/submit_formula_change_request.sql
-- APR-8(2026-09-26,grilling Q1):改一张在用的公式 = 一张带着【完整拟议条款】的申请;批准时就地替换。
-- 等待期间公式上仍是旧条款、旧条款照旧生效。门 module.pricing.edit(cco)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_formula_change_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.pricing.edit');
    IF p_terms IS NULL THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|terms';
    END IF;
    RETURN terms_request_submit_internal('formula_change', p_formula_id, p_terms, p_reason);
END;
$function$;

-- db/functions/submit_formula_reactivate_request.sql
-- APR-8(2026-09-26,grilling Q1):让一张停用的公式重新生效(停用过的,或新建时被驳回 / 撤回的)。
-- p_terms 给了就是拟议条款(批准时写进去);NULL = 按公式上此刻的条款。门 module.pricing.edit(cco)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_formula_reactivate_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.pricing.edit');
    RETURN terms_request_submit_internal('formula_reactivate', p_formula_id, p_terms, p_reason);
END;
$function$;

-- db/functions/submit_contract_activation_request.sql
-- APR-8(2026-09-26,grilling Q2):一份草稿或暂停的合同申请生效。门 action.contract_terms(cco)。
-- 等待期间合同表头与七张条款表冻结;CFO 看见此刻的条款与上一次批准时那一份的差别。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_contract_activation_request(p_contract_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.contract_terms');
    RETURN terms_request_submit_internal('contract_activate', p_contract_id, NULL, p_reason);
END;
$function$;

-- db/functions/decide_terms_request.sql
-- APR-8(2026-09-26):CFO 批准或驳回一张条款申请(公式新建 / 修改 / 重新启用 · 合同生效)。批准【当场生效】。
--
-- 【门】module.pricing.view + data.view_prices + data.view_purchase_prices + module.suppliers.view +
-- module.customers.view(grilling Q4,四种一个门)—— 看得见公式与它两个方向的价格、两侧的合同;【不是】
-- module.pricing.edit / action.contract_terms:那是提单的码。cfo 五个都持。
-- 【谁能批】二级审批人,每一张、不分档。【四眼】forbid_self_approval(提单人, NULL, …)按人认。
-- 【批准之前不另查】批准就是那一次真的生效:fingerprint 变了(TERMS_CHANGED_SINCE_REQUEST)、公式被删、合同不再是
-- 草稿 / 暂停 —— 全按原话拒,整笔回滚,申请仍在等;CFO 驳回,或 cco 撤回。驳回要理由,从不检查这些。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_terms_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    terms_requests%ROWTYPE;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.pricing.view');
    PERFORM require_permission('data.view_prices');
    PERFORM require_permission('data.view_purchase_prices');
    PERFORM require_permission('module.suppliers.view');
    PERFORM require_permission('module.customers.view');

    SELECT * INTO v_r FROM terms_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'terms_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'TERMS_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE terms_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('terms_request', p_request_id, 'rejected', 2::smallint, btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := terms_request_execute_internal(p_request_id);

    UPDATE terms_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), executed_at = now(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('terms_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind, 'result', v_exec);
END;
$function$;

-- db/functions/withdraw_terms_request.sql
-- APR-8(2026-09-26):撤回一张在等的条款申请。谁能撤:提单人本人(按人认),或持这一种那个码的人
-- (公式 module.pricing.edit · 合同 action.contract_terms)。只撤 submitted。撤回什么都不生效、冻结随之解开;
-- 新建公式的申请撤回后,那张公式停用着留下。记在本行上,【不】写 approval_log(撤回不是一次决定)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_terms_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r terms_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM terms_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission(CASE WHEN v_r.kind = 'contract_activate' THEN 'action.contract_terms'
                                        ELSE 'module.pricing.edit' END);
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE terms_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;

-- db/functions/terms_requests_visible.sql
-- APR-8(2026-09-26,grilling Q8):公式页与合同页上那一块读的就是这里 —— cco 看得见自己提的申请,CFO 看得见要他批的。
--   公式申请:持 module.pricing.view 的人;snapshot / proposed 按 pricing_formula_terms_visible(那张公式的方向)给,
--     没有那个价格码的读者读 NULL(与 pricing_formulas_masked 同一条)。
--   合同申请:跟着合同那一侧走(module.suppliers.view / module.customers.view,contracts 自己的读策略同一条)。
--   只给在等的全部 + 最近决定 / 撤回的 p_recent 张;raised_by_me = 提单人就是读者这个人(按人认)。
--   p_formula_id / p_contract_id 给了就只给那一个主体的。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_requests_visible(p_recent integer DEFAULT 10, p_formula_id uuid DEFAULT NULL::uuid, p_contract_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, kind text, status text, label text, formula_id uuid, contract_id uuid, subject_code text, reason text, proposed jsonb, snapshot jsonb, created_at timestamp with time zone, created_by_email text, raised_by_me boolean, decided_at timestamp with time zone, decided_by_email text, decision_notes text, withdrawn_at timestamp with time zone, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               COALESCE(f.code, c.code) AS subject_code,
               CASE WHEN q.formula_id IS NOT NULL THEN pricing_formula_terms_visible(f.direction) ELSE true END AS terms_ok,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM terms_requests q
          LEFT JOIN pricing_formulas f ON f.id = q.formula_id
          LEFT JOIN contracts c ON c.id = q.contract_id
         WHERE (p_formula_id IS NULL OR q.formula_id = p_formula_id)
           AND (p_contract_id IS NULL OR q.contract_id = p_contract_id)
           AND ((q.formula_id IS NOT NULL AND has_permission('module.pricing.view'))
             OR (q.contract_id IS NOT NULL
                 AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'))
                   OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'))))))
    SELECT r.id, r.kind, r.status, r.label, r.formula_id, r.contract_id, r.subject_code, r.reason,
           CASE WHEN r.terms_ok THEN r.proposed END,
           CASE WHEN r.terms_ok THEN r.snapshot END,
           r.created_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.created_by),
           self_leg(r.created_by, NULL, auth.uid()) = 'raiser',
           r.decided_at,
           (SELECT u.email::text FROM auth.users u WHERE u.id = r.decided_by),
           r.decision_notes, r.withdrawn_at, r.withdraw_reason
      FROM r
     WHERE r.is_open OR r.rn <= GREATEST(COALESCE(p_recent, 10), 0)
     ORDER BY r.is_open DESC, COALESCE(r.decided_at, r.withdrawn_at, r.created_at) DESC
$function$;

-- db/functions/deactivate_pricing_formula.sql
-- APR-8(2026-09-26,grilling Q1):停用一张公式仍是 cco 一步 —— 它只会让能用的公式变少(此后计价器、建采购单、
-- 应用化验按名拒 FORMULA_INACTIVE;已抄下的承诺不受影响)。门 module.pricing.edit。等待中的申请挂在它上面 →
-- TERMS_REQUEST_OPEN(先撤回)。重新启用要经 CFO(submit_formula_reactivate_request)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.deactivate_pricing_formula(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code   text;
    v_active boolean;
    v_open   text;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    SELECT code, is_active INTO v_code, v_active FROM pricing_formulas
     WHERE id = p_formula_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    SELECT label INTO v_open FROM terms_requests WHERE formula_id = p_formula_id AND status = 'submitted';
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'TERMS_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    IF NOT v_active THEN
        RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_code;
    END IF;
    UPDATE pricing_formulas SET is_active = false WHERE id = p_formula_id;
    RETURN jsonb_build_object('formula_id', p_formula_id, 'code', v_code, 'is_active', false);
END;
$function$;

-- db/functions/delete_pricing_formula.sql
-- APR-8(2026-09-26,grilling Q1):删除(软删)一张公式仍是 cco 一步 —— 只会让能用的变少。门 module.pricing.edit。
-- 等待中的申请挂在它上面 → TERMS_REQUEST_OPEN(先撤回)。原来这一步是屏幕直连 UPDATE deleted_at;公式表从此
-- 没有直连写(guard_pricing_formula_direct_write),于是它有了自己的门。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.delete_pricing_formula(p_formula_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_open text;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    SELECT code INTO v_code FROM pricing_formulas WHERE id = p_formula_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    SELECT label INTO v_open FROM terms_requests WHERE formula_id = p_formula_id AND status = 'submitted';
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'TERMS_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    UPDATE pricing_formulas SET deleted_at = now() WHERE id = p_formula_id;
    RETURN jsonb_build_object('formula_id', p_formula_id, 'code', v_code, 'deleted', true);
END;
$function$;

-- db/functions/guard_pricing_formula_direct_write.sql
-- APR-8(2026-09-26,grilling Q6):**pricing_formulas 与 pricing_formula_metals 没有直连写**。
--
-- 此前写它们的是屏幕上的直连 INSERT / UPDATE / DELETE(app/tools/pricing/formulas/actions.ts),三条写策略开在
-- module.pricing.edit 上 —— 于是 cco 一次保存就改掉了此后每一次报价、每一张新采购单抄下的承诺,没有任何人批过。
-- 三条写策略一并拿掉;公式只经函数写:submit_formula_create_request(建一张停用的)、terms_request_execute_internal
-- (CFO 批准时写进条款、启用)、deactivate_pricing_formula、delete_pricing_formula。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 INSERT 报的是一句 RLS 原文,UPDATE / DELETE 则是【零行、不报错】
-- (SILENT-1 那一族)—— 旧的编辑页在破窗里会把一次被挡下的保存报告成成功。本守卫零行也照样触发,按名拒
-- PRICING_FORMULA_THROUGH_REQUEST_ONLY。属主路径(row_security_active = false)一律放行 —— 上面那几支 DEFINER
-- 函数与迁移、fixture 布景走的就是它。形状照 guard_journal_direct_write。
-- 两张表上原有的 enforce_write_permission('module.pricing.edit') 留着、排在本守卫之前:不持码的人仍读到
-- PERMISSION_DENIED|module.pricing.edit(他缺的是码),持码的人读到本守卫(他缺的是 CFO)。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_pricing_formula_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'PRICING_FORMULA_THROUGH_REQUEST_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_pricing_formula_direct_write() IS
'APR-8:pricing_formulas 与 pricing_formula_metals 的任何直连写(row_security_active,语句级,零行也触发)按名拒 PRICING_FORMULA_THROUGH_REQUEST_ONLY。公式只经 submit_formula_create_request / submit_formula_change_request / submit_formula_reactivate_request → CFO 批准(terms_request_execute_internal),以及 cco 一步的 deactivate_pricing_formula / delete_pricing_formula。';

-- db/functions/guard_contract_write.sql
-- APR-8(2026-09-26,grilling Q2 · Q6):合同只有 active 有效力,所以【进入 active 的每一条路都经 CFO】。
--   INSERT:只许建草稿 —— 别的状态 → CONTRACT_ACTIVATES_THROUGH_REQUEST|编号
--     (旧的 /contracts/new 能选"生效",破窗里它会按名拒;新表单只剩草稿)。
--   UPDATE:
--     · 挂着一张在等的生效申请 → TERMS_REQUEST_FREEZES_CONTRACT|编号|那一张(先撤回)
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

-- db/functions/guard_contract_terms_frozen.sql
-- APR-8(2026-09-26,grilling Q2 · Q5):七张条款表(品位 · 保险 · 数量 · 计价 · 结算 · 精炼费 · 罚则)在合同
-- 生效中、或挂着一张在等的生效申请时,任何直连写按名拒 CONTRACT_TERMS_FROZEN|合同编号|active 或那一张申请。
-- 改条款 = 暂停合同、编辑、申请重新生效(CFO 看见与上一次批准时那一份的差别)。
-- 行级,BEFORE INSERT OR UPDATE OR DELETE;UPDATE 把一行挪到别的合同上时两份都问。属主路径一律放行。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_contract_terms_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid;
    v_lock text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    FOR v_id IN SELECT DISTINCT x FROM unnest(ARRAY[
                    CASE WHEN TG_OP <> 'INSERT' THEN OLD.contract_id END,
                    CASE WHEN TG_OP <> 'DELETE' THEN NEW.contract_id END]) x WHERE x IS NOT NULL LOOP
        v_lock := contract_terms_lock_reason(v_id);
        IF v_lock IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_TERMS_FROZEN|%|%',
                (SELECT c.code FROM contracts c WHERE c.id = v_id),
                CASE WHEN v_lock LIKE 'request:%' THEN substr(v_lock, 9) ELSE v_lock END;
        END IF;
    END LOOP;
    RETURN COALESCE(NEW, OLD);
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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废 · 手工凭证 · 仓库(注销 / 回滚 / 证书作废)· 条款(公式 / 合同生效)七种申请与发货放行 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

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
                  'module.suppliers.view', 'module.customers.view']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- ── 4 · 关门(Q6):公式两张表的写策略拿掉;十支守卫挂上 ─────────────────────────
DROP POLICY "pricing_formulas insert by permission" ON public.pricing_formulas;
DROP POLICY "pricing_formulas update by permission" ON public.pricing_formulas;
DROP POLICY "pricing_formulas delete by permission" ON public.pricing_formulas;
DROP POLICY "pricing_formula_metals insert by permission" ON public.pricing_formula_metals;
DROP POLICY "pricing_formula_metals update by permission" ON public.pricing_formula_metals;
DROP POLICY "pricing_formula_metals delete by permission" ON public.pricing_formula_metals;
CREATE TRIGGER trg_pricing_formulas_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.pricing_formulas
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_pricing_formula_direct_write();
CREATE TRIGGER trg_pricing_formula_metals_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.pricing_formula_metals
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_pricing_formula_direct_write();
CREATE TRIGGER trg_contracts_guard_write
    BEFORE INSERT OR UPDATE ON public.contracts
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_write();
CREATE TRIGGER trg_contract_grade_specs_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_grade_specs
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();
CREATE TRIGGER trg_contract_insurance_obligations_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_insurance_obligations
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();
CREATE TRIGGER trg_contract_volume_commitments_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_volume_commitments
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();
CREATE TRIGGER trg_contract_pricing_terms_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_pricing_terms
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();
CREATE TRIGGER trg_contract_settlement_terms_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_settlement_terms
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();
CREATE TRIGGER trg_contract_refining_charges_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_refining_charges
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();
CREATE TRIGGER trg_contract_penalty_elements_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();

-- ── 5 · EXECUTE:内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)────────
REVOKE EXECUTE ON FUNCTION public.terms_request_submit_internal(text, uuid, jsonb, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_execute_internal(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_dry_run(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_snapshot(text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.terms_request_fingerprint(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.formula_terms_state(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.contract_terms_state(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_formula_create_request(jsonb, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_formula_change_request(uuid, jsonb, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_formula_reactivate_request(uuid, jsonb, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_contract_activation_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.decide_terms_request(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.withdraw_terms_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.terms_requests_visible(integer, uuid, uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.deactivate_pricing_formula(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_pricing_formula(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.formula_terms_normalize(jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.contract_terms_lock_reason(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.guard_pricing_formula_direct_write() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.guard_contract_write() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.guard_contract_terms_frozen() FROM PUBLIC, anon;

-- ── 6 · operations_now:加一支 terms_request_pending(镜像原样)──────────────────
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
CREATE FUNCTION pg_temp.a8_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE a8_pending_after ON COMMIT DROP AS
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

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码,Q6)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a8_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a8_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR8_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR8_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、公式、比例、历史、承诺、合同、条款、挂接一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a8_pending_before b EXCEPT SELECT a.k, a.id FROM a8_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a8_pending_after a EXCEPT SELECT b.k, b.id FROM a8_pending_before b)) THEN
        RAISE EXCEPTION 'APR8_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a8_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM pricing_formulas) AS formulas,
       (SELECT count(*) FROM pricing_formulas WHERE is_active AND deleted_at IS NULL) AS formulas_live,
       (SELECT count(*) FROM pricing_formula_metals) AS formula_metals,
       (SELECT count(*) FROM pricing_formula_history) AS formula_history,
       (SELECT count(*) FROM pricing_term_commitments) AS commitments,
       (SELECT count(*) FROM contracts) AS contracts,
       (SELECT (SELECT count(*) FROM contract_grade_specs) + (SELECT count(*) FROM contract_insurance_obligations)
             + (SELECT count(*) FROM contract_volume_commitments) + (SELECT count(*) FROM contract_pricing_terms)
             + (SELECT count(*) FROM contract_settlement_terms) + (SELECT count(*) FROM contract_refining_charges)
             + (SELECT count(*) FROM contract_penalty_elements)) AS contract_terms,
       (SELECT count(*) FROM contract_document_terms) AS contract_links) n) THEN
        RAISE EXCEPTION 'APR8_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a8_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM pricing_formulas) AS formulas,
       (SELECT count(*) FROM pricing_formulas WHERE is_active AND deleted_at IS NULL) AS formulas_live,
       (SELECT count(*) FROM pricing_formula_metals) AS formula_metals,
       (SELECT count(*) FROM pricing_formula_history) AS formula_history,
       (SELECT count(*) FROM pricing_term_commitments) AS commitments,
       (SELECT count(*) FROM contracts) AS contracts,
       (SELECT (SELECT count(*) FROM contract_grade_specs) + (SELECT count(*) FROM contract_insurance_obligations)
             + (SELECT count(*) FROM contract_volume_commitments) + (SELECT count(*) FROM contract_pricing_terms)
             + (SELECT count(*) FROM contract_settlement_terms) + (SELECT count(*) FROM contract_refining_charges)
             + (SELECT count(*) FROM contract_penalty_elements)) AS contract_terms,
       (SELECT count(*) FROM contract_document_terms) AS contract_links) n);
    END IF;
    IF EXISTS (SELECT 1 FROM terms_requests) THEN
        RAISE EXCEPTION 'APR8_PROOF|terms_requests is not empty';
    END IF;

    -- ④ 结构:公式两张表与申请表上没有写策略;十支守卫挂上;内层算子 authenticated 调不到;名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('pricing_formulas', 'pricing_formula_metals', 'terms_requests') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR8_PROOF|a formula / terms_requests write policy exists';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_pricing_formulas_direct_write', 'trg_pricing_formula_metals_direct_write', 'trg_contracts_guard_write', 'trg_contract_grade_specs_frozen', 'trg_contract_insurance_obligations_frozen', 'trg_contract_volume_commitments_frozen', 'trg_contract_pricing_terms_frozen', 'trg_contract_settlement_terms_frozen', 'trg_contract_refining_charges_frozen', 'trg_contract_penalty_elements_frozen');
    IF v_n <> 10 THEN RAISE EXCEPTION 'APR8_PROOF|expected 10 guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY['public.terms_request_submit_internal(text, uuid, jsonb, text)', 'public.terms_request_execute_internal(uuid)', 'public.terms_request_dry_run(uuid)', 'public.terms_request_snapshot(text, uuid, jsonb)', 'public.terms_request_fingerprint(text, uuid)', 'public.formula_terms_state(uuid)', 'public.contract_terms_state(uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR8_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'terms_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR8_PROOF|terms_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('terms_request', 'decide_terms_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR8_PROOF|nobody can decide a terms request'; END IF;
    RAISE NOTICE 'APR8 deciders for terms_request: %', v_n;

    -- ⑥ 每一张在途单据 —— 连同每一条申请链 —— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a8_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR8 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a8_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR8_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a8_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a8_pending_decider_check(boolean);

COMMIT;

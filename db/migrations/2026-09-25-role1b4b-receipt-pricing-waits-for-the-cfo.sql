-- db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql
-- ROLE-1 Batch 4b —— 收货定价要 CFO 批准:一个价格只有 CFO 批了才进账(docs/role-matrix.md「收货定价与改价」)。
-- 由 db/scripts/build_role1b4b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(ROLE-1 Batch 4 grilling Q2–Q8 + Batch 4b grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   ① receipt_price_requests:收货定价申请。submitted → approved(CFO 批准【当场过账】,记在批准日、
--      按那天的 tt_sell)· rejected(要理由)· withdrawn。冻结原币单价;提交与批准各按同一支过账试跑。
--      审批关着时生下来就是 approved 并当场过账(auto_approved)。
--   ② 四扇门变成提交:定价面板(set_inbound_unit_price)· 按已承诺条款改价(reprice_from_committed_terms)·
--      收货台带价建单(create_inbound_batch,同一事务)· 应用化验(apply_assay_result,含量等照旧全部
--      落地,同一事务提一张来源 assay 的申请;pricing_status 的 final 只在批准时置)。
--   ③ 等待期间冻住(Q5):改供应商 / 采购单 / 采购行 / 含量、注销、第二张申请 → RECEIPT_PRICE_REQUEST_OPEN;
--      批准时指纹再比 → RECEIPT_PRICE_CHANGED_SINCE_REQUEST。手工申请在等时应用化验按名拒;化验申请在等时,
--      新化验取代它(撤回并记下理由)。撤销应用化验撤回它那一张。
--   ④ 低于已付(Q6):提交与批准各按当天的牌价比 → RECEIPT_PRICE_BELOW_SETTLED。
--   ⑤ 提单人之外没人批得动(4b Q1):审批开着时提交按名拒 RECEIPT_PRICE_NO_OTHER_DECIDER。
--   ⑥ pricing_status 只经函数写(4b Q3):直连写 → PRICING_STATUS_VIA_FUNCTION。
--   ⑦ 引擎登记(Q8):approval_chain_gates 一行(二级,module.inbound.view + data.view_purchase_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 receipt_price_request;record_approval_decision 一支(金额 = |Δ 应付| 本位币);
--      operations_now 一支 receipt_price_request_pending(data.view_purchase_prices)。
--
-- 【不做什么】不新增任何权限码,所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行;引擎 reprice_inbound_batch 一个字不改。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;
-- approval_log、journal_entries、price_history、收货(已定价 / 全部 / 各定价状态)、含量行、已应用化验一行没变;
-- 授权一条没变;申请表是空的;新链有人批得了;每一张在途单据都还有一个【不是它自己当事人】的决定人。
-- 断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.receipt_price_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|receipt_price_requests already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('trg_inbound_batches_price_request',
                                                        'trg_inbound_batch_metals_price_request')) THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|a ROLE-1 Batch 4b trigger already exists';
    END IF;
    IF has_function_privilege('authenticated', 'public.reprice_inbound_batch(uuid, numeric, text, numeric, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|the engine is expected closed to authenticated (Batch 4a)';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b4b_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE b4b_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM price_history) AS price_history,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE pricing_status = 'final') AS receipts_final,
       (SELECT count(*) FROM inbound_batch_metals) AS metal_rows,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied;
CREATE TEMP TABLE b4b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · receipt_price_requests(镜像原样)────────────────────────────────────
CREATE TABLE public.receipt_price_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id        uuid NOT NULL REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    source                  text NOT NULL CHECK (source IN ('manual', 'committed_terms', 'desk', 'assay')),
    -- 来源是化验时,是哪一份;承诺条款(committed_terms / assay)是哪一份副本
    assay_result_id         uuid REFERENCES public.assay_results (id) ON DELETE RESTRICT,
    commitment_id           uuid REFERENCES public.pricing_term_commitments (id) ON DELETE RESTRICT,
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label                   text NOT NULL,
    -- ── 冻结的那个价(原币)与那一组事实 ──────────────────────────────────────
    unit_price_ccy          numeric NOT NULL CHECK (unit_price_ccy > 0),
    currency                text NOT NULL REFERENCES public.currencies (code),
    snapshot                jsonb NOT NULL,
    -- 提交时的旧本位币单价(首次定价为 NULL)
    old_unit_price          numeric,
    -- |Δ 应付| 本位币,最近一次估算(提交日;批准后 = 实际过账的那一个)
    amount_base             numeric NOT NULL CHECK (amount_base >= 0),
    notes                   text,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    -- 批准当场过账:过账后的本位币单价与那一笔分录(价差为 0 时没有分录)
    posted_unit_price       numeric,
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    withdraw_reason         text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT receipt_price_requests_assay_shape CHECK (
        (source = 'assay') = (assay_result_id IS NOT NULL)),
    CONSTRAINT receipt_price_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT receipt_price_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT receipt_price_requests_approved_shape CHECK (
        (status = 'approved') = (posted_unit_price IS NOT NULL)
        AND (result_journal_entry_id IS NULL OR status = 'approved')),
    CONSTRAINT receipt_price_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.receipt_price_requests IS
    'ROLE-1 Batch 4b:收货定价的申请(Tim 的矩阵:财务提,CFO 批每一张,不分档;批准当场过账)。submitted → approved(CFO,当场按批准日牌价过账)· rejected(要理由)· withdrawn(提单人本人或 action.price_receipts;撤销应用化验、新化验取代时由系统撤回)。来源 manual / committed_terms / desk / assay。冻结原币单价与 snapshot(receipt_price_fingerprint),批准时再比(RECEIPT_PRICE_CHANGED_SINCE_REQUEST)。审批关着时生下来就是 approved 并当场过账(auto_approved)。一张收货同时只挂一张在等的申请。';

COMMENT ON COLUMN public.receipt_price_requests.amount_base IS
    'ROLE-1 Batch 4b(Tim 的 Q4):|Δ 应付| 本位币 = |round(数量 × (新本位币单价 − 旧), 2)|,由引擎试跑算出。提交时按提交日牌价(写进 submitted 留痕);批准时按批准日牌价重算并写回(= 实际过账额,写进 approved 留痕)。';

CREATE UNIQUE INDEX receipt_price_requests_one_open_per_receipt
    ON public.receipt_price_requests (inbound_batch_id)
    WHERE status = 'submitted';
CREATE INDEX receipt_price_requests_inbound_batch_id_rel ON public.receipt_price_requests (inbound_batch_id);
CREATE INDEX receipt_price_requests_assay_result_id_rel ON public.receipt_price_requests (assay_result_id);
CREATE INDEX receipt_price_requests_commitment_id_rel ON public.receipt_price_requests (commitment_id);
CREATE INDEX receipt_price_requests_result_journal_entry_id_rel ON public.receipt_price_requests (result_journal_entry_id);

ALTER TABLE public.receipt_price_requests ENABLE ROW LEVEL SECURITY;

-- 读:收货页的门 + 看得见采购价(申请上全是采购价)。写:一条策略都不给 —— 只经
-- 提交(四扇门)、decide / withdraw 与应用 / 撤销化验(全是 SECURITY DEFINER)。
CREATE POLICY "receipt_price_requests select by permission" ON public.receipt_price_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text) AND has_permission('data.view_purchase_prices'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.receipt_price_requests FROM anon;

-- ── 2 · approval_log:主体类型加 receipt_price_request;读策略加同名一支 ──────
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
                            'receipt_price_request'));
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
            ELSE false
        END
    );

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/receipt_price_fingerprint.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5):一张收货的定价申请【批的是哪一组事实】——
-- 提交时冻结进 receipt_price_requests.snapshot,批准时再算一次比对;不同就按名拒
-- RECEIPT_PRICE_CHANGED_SINCE_REQUEST。
--
-- 里面有:数量、供应商、采购单、采购行、当前单价(本位币)、含量(逐金属:含量、来源、出自哪份化验)、
-- 解析出的承诺副本、最近一份已应用的化验(对化验来源的申请,这就是"它的化验仍是最近一份已应用的")。
-- 【牌价不在里面】(Tim 的 Q4):批准按批准日牌价过账,是裁定,不是"变了"。
-- 【供应商的审批状态不在里面】(Tim 的 Q5)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_fingerprint(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
        'quantity', b.quantity,
        'supplier_id', b.supplier_id,
        'purchase_order_id', b.purchase_order_id,
        'purchase_order_line_id', b.purchase_order_line_id,
        'unit_price', b.unit_price,
        'metals', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                'metal', m.metal, 'content_pct', m.content_pct,
                                'source', m.content_source, 'assay', m.source_assay_id)
                                ORDER BY m.metal)
                              FROM inbound_batch_metals m WHERE m.inbound_batch_id = b.id), '[]'::jsonb),
        'commitment_id', resolve_pricing_commitment(b.id),
        'latest_applied_assay_id', (SELECT a.id FROM assay_results a
                                     WHERE a.inbound_batch_id = b.id AND a.applied_at IS NOT NULL
                                       AND a.deleted_at IS NULL
                                     ORDER BY a.applied_at DESC, a.code DESC LIMIT 1))
      FROM inbound_batches b
     WHERE b.id = p_inbound_batch_id
$function$
;

-- db/functions/receipt_price_open.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5):这张收货此刻挂着的那张在等的定价申请的 label
-- (例:IN-2026-0153 · price #1),没有就 NULL。
--
-- 【它为什么必须是 DEFINER】两支守卫(guard_inbound_batch_price_request ·
-- guard_inbound_batch_metals_price_request)是 INVOKER。receipt_price_requests 的读策略要
-- module.inbound.view + data.view_purchase_prices;一个持 inbound.edit 却不持采购价码的写入者
-- (operations)在 INVOKER 里读它会拿到【零行】,守卫就会把"看不见"读成"没有申请"而静默放行 ——
-- AGENTS.md 那条「守卫对主语缺席这一格是瞎的」(payroll_period_frozen 逐字同一条)。
-- 【它为什么不能收回 EXECUTE,也不能加调用者检查】调它的是 INVOKER 触发器,EXECUTE 按当前用户判。
-- 它吐出的只有一个 label(收货编号 · 第几次),不带任何价格。
-- 两处 allowlist 同改:db/check_mirrors.py 的 DEFINER_NO_CHECK_ALLOWED 与
-- db/verify_rebuild.py 的 DEFINER_UNCHECKED_EXEC_ALLOWED。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_open(p_inbound_batch_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.label FROM receipt_price_requests r
     WHERE r.inbound_batch_id = p_inbound_batch_id AND r.status = 'submitted'
     LIMIT 1
$function$
;

-- db/functions/receipt_settled_base.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q6 · Q12):一张收货【已经付了多少】(本位币)——
-- 已过账付款的核销 + 预付冲抵。与 ap_open_items 进料支、soft_delete_inbound_batch 同一条算术;
-- 在等的付款申请【不算】(Q12)。读基表:ap_open_items 对没有 finance.view 的人是 0 行,
-- 读它会让一个 cto 账号的"已付为 0"成为一句假话。
-- 定价申请在提交与批准两处都拿它比:新价 × 数量 < 它 → RECEIPT_PRICE_BELOW_SETTLED。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_settled_base(p_inbound_batch_id uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT round(COALESCE((SELECT sum(pa.allocated_ccy)
                             FROM payment_allocations pa
                             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                            WHERE pa.inbound_batch_id = p_inbound_batch_id), 0)
               + COALESCE((SELECT sum(ppa.amount_base)
                             FROM prepayment_applications ppa
                            WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0), 2)
$function$
;

-- db/functions/receipt_price_post_internal.sql
-- ROLE-1 Batch 4b(2026-09-25):把一张定价申请【过账】—— 批准那一刻(或审批关着时提交那一刻)跑的
-- 那一支,也是试跑(receipt_price_request_dry_run)跑的同一支。
--
--   1. 引擎 reprice_inbound_batch:原币单价 × 【今天】的 tt_sell(Tim 的 Q2:过账记在批准日、按那天的
--      牌价)→ unit_price、price_history、purchase 分录(1200 / 5000 / Cr 2000)。引擎自己再问一次
--      data.view_purchase_prices —— 问的是按下去的那个人(批准时是 CFO)。
--   2. 化验来源、而且那份化验是 is_final → 收货的 pricing_status 升为 final(Tim 的 Q3:只在批准时)。
--      pricing_status 的直连写由 guard_inbound_batch_price_request 拒;本支是属主路径。
--   3. 按已承诺条款改价 → 收货还没挂公式时,记下承诺副本的来源公式(原 reprice_from_committed_terms
--      落账后做的那一步,挪到真正落账的这一刻)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_post_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       receipt_price_requests%ROWTYPE;
    v_rep     jsonb;
    v_formula uuid;
BEGIN
    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    v_rep := reprice_inbound_batch(v_r.inbound_batch_id, v_r.unit_price_ccy, v_r.currency, NULL,
                                   concat_ws(' · ', 'Price request ' || v_r.label, v_r.notes));

    IF v_r.source = 'assay'
       AND (SELECT a.is_final FROM assay_results a WHERE a.id = v_r.assay_result_id) THEN
        UPDATE inbound_batches SET pricing_status = 'final', updated_by = auth.uid()
         WHERE id = v_r.inbound_batch_id AND pricing_status <> 'final';
    END IF;

    IF v_r.source = 'committed_terms' AND v_r.commitment_id IS NOT NULL THEN
        SELECT c.source_formula_id INTO v_formula
          FROM pricing_term_commitments c WHERE c.id = v_r.commitment_id;
        IF v_formula IS NOT NULL THEN
            UPDATE inbound_batches SET pricing_formula_id = v_formula, updated_by = auth.uid()
             WHERE id = v_r.inbound_batch_id AND pricing_formula_id IS NULL;
        END IF;
    END IF;

    RETURN v_rep;
END;
$function$
;

-- db/functions/receipt_price_request_dry_run.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q2):按【批准那一刻会用的同一支过账】把一张定价申请试跑一遍,
-- 然后整个回滚 —— 单价、price_history、分录、编号一样都不留。提交与批准各跑一次。
--
-- 【为什么不写一份"校验函数"】与 payroll_request_dry_run、payment_request_dry_run 逐字同一条:
-- 非正价格、币种、缺牌价、期间锁,抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份,
-- 提单人与审批人看见的拒绝是引擎自己的原话。
-- 返回引擎的分解(旧价、新价、价差、在库比例、两份份额)—— 变量的赋值不随子事务回滚,
-- 所以 |Δ 应付| 与"低于已付"都从这一份算,不另算一遍。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。过账跑完抛专用 SQLSTATE PQ003,
-- 只接这一个 —— 引擎自己的任何拒绝照常往外抛。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := receipt_price_post_internal(p_request_id);
        RAISE EXCEPTION USING ERRCODE = 'PQ003', MESSAGE = 'RECEIPT_PRICE_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ003' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;

-- db/functions/receipt_price_withdraw_internal.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q3 · Q5 · Q7):撤回一张在等的定价申请,记下谁、何时,以及(有的话)为什么。
-- 三个调用者:withdraw_receipt_price_request(人按的)· unapply_assay_result(撤销应用化验撤回它那张)·
-- apply_assay_result(一份新化验取代在等的那张化验申请)。系统撤回的理由由调用者写明
-- 是哪一份化验、为什么;人按的撤回理由可空(工资申请的撤回连理由都不收)。只撤 submitted;不写 approval_log(撤回不是一次决定)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_withdraw_internal(p_request_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r receipt_price_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE receipt_price_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$
;

-- db/functions/receipt_price_submit_internal.sql
-- ROLE-1 Batch 4b(2026-09-25):提一张收货定价申请 —— 四扇门(定价面板 · 按已承诺条款改价 ·
-- 收货台带价建单 · 应用化验)都落进来的那一支。每扇门自己先问自己的码;本支不问码。
--
--   1. 收货锁住、未注销;价格 > 0、币种存在(引擎还会再说一次,这里在写入之前就按名拒)。
--   2. 这张收货已经挂着一张在等的申请 → RECEIPT_PRICE_REQUEST_OPEN|收货|那一张(Tim 的 Q5;
--      唯一索引是第二道)。
--   3. ★ 审批开着时:除了提单人这个【人】之外,二级还有没有人批得动(approval_deciders,按人认)。
--      没有 → RECEIPT_PRICE_NO_OTHER_DECIDER|收货(Tim 的 Q1)。admin@ 与 tim@ 是同一个人,
--      而二级今天只有 tim@ —— 不拦的话,admin@ 提的申请会挂在那里没人批得了,还挡住关审批。
--      审批关着时不拦:申请生下来就是 approved,没有人要去批它。
--   4. 落一行 submitted,snapshot = receipt_price_fingerprint(Tim 的 Q5)。
--   5. 按批准那一刻会用的同一支过账试跑(receipt_price_request_dry_run,Tim 的 Q2)——
--      缺牌价、非法币种、期间锁,这里按引擎的原话拒。
--   6. ★ 低于已付 → RECEIPT_PRICE_BELOW_SETTLED|收货|新货值|已付(Tim 的 Q6 · Q12):
--      新货值 = round(数量 × 试跑出的新本位币单价, 2),按【今天】的牌价(Q4)。
--   7. amount_base = |试跑出的价差|(Q4:提交那一行留痕按提交日的牌价)。
--   8. 审批开着:留痕 submitted,二级。关着:当场过账(receipt_price_post_internal),状态 approved,
--      留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.receipt_price_submit_internal(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text, p_source text, p_assay_result_id uuid, p_commitment_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_b       record;
    v_on      boolean := approvals_enabled();
    v_id      uuid := gen_random_uuid();
    v_open    text;
    v_l1      text;
    v_l2      text;
    v_n       integer;
    v_label   text;
    v_dry     jsonb;
    v_value   numeric;
    v_settled numeric;
    v_amount  numeric;
    v_post    jsonb := NULL;
    v_je      uuid := NULL;
BEGIN
    SELECT id, code, quantity, unit_price INTO v_b
      FROM inbound_batches
     WHERE id = p_inbound_batch_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    v_open := receipt_price_open(v_b.id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_b.code, v_open;
    END IF;

    IF v_on THEN
        SELECT approval_level1_role_code, approval_level2_role_code
          INTO v_l1, v_l2 FROM finance_settings LIMIT 1;
        IF NOT EXISTS (SELECT 1 FROM approval_deciders('receipt_price_request',
                                                       'decide_receipt_price_request',
                                                       2::smallint, auth.uid(), NULL, v_l1, v_l2)) THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_NO_OTHER_DECIDER|%', v_b.code;
        END IF;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM receipt_price_requests WHERE inbound_batch_id = v_b.id;
    v_label := v_b.code || ' · price #' || v_n::text;

    INSERT INTO receipt_price_requests (id, inbound_batch_id, source, assay_result_id, commitment_id,
                                        status, label, unit_price_ccy, currency, snapshot,
                                        old_unit_price, amount_base, notes, created_by)
    VALUES (v_id, v_b.id, p_source, p_assay_result_id, p_commitment_id,
            'submitted', v_label, p_unit_price, p_currency, receipt_price_fingerprint(v_b.id),
            v_b.unit_price, 0, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    v_dry := receipt_price_request_dry_run(v_id);
    v_value   := round(v_b.quantity * (v_dry->>'new_unit_price')::numeric, 2);
    v_settled := receipt_settled_base(v_b.id);
    IF v_value < v_settled THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_BELOW_SETTLED|%|%|%', v_b.code, v_value, v_settled;
    END IF;
    v_amount := abs(COALESCE((v_dry->>'price_delta_usd')::numeric, 0));
    UPDATE receipt_price_requests SET amount_base = v_amount WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('receipt_price_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_post := receipt_price_post_internal(v_id);
        SELECT je.id INTO v_je FROM journal_entries je WHERE je.code = v_post->>'journal_code';
        v_amount := abs(COALESCE((v_post->>'price_delta_usd')::numeric, 0));
        UPDATE receipt_price_requests
           SET status = 'approved', posted_unit_price = (v_post->>'new_unit_price')::numeric,
               result_journal_entry_id = v_je, amount_base = v_amount
         WHERE id = v_id;
        PERFORM record_approval_decision('receipt_price_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场过账,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'batch_code', v_b.code,
        'unit_price_ccy', p_unit_price,
        'currency', p_currency,
        'old_unit_price', v_b.unit_price,
        'new_unit_price', v_dry->'new_unit_price',
        'price_delta_usd', v_dry->'price_delta_usd',
        'amount_base', v_amount,
        'journal_code', v_post->>'journal_code');
END;
$function$
;

-- db/functions/decide_receipt_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25):CFO 批准或驳回一张收货定价申请。批准【当场过账】(Tim 的 Q2 (A))。
--
-- 【门】module.inbound.view + data.view_purchase_prices(Tim 的 Q2)—— 收货页的门,加上看得见采购价
-- 的那个码(docs/approvals.md §5:批的人必须看得见他批的那个数)。【不是】action.price_receipts:
-- 那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】require_approver_for(2)—— CFO 批每一张、不分档,从不经 approval_level_for。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 收货不是谁的"自己的单据",主角那条腿对谁都不成立;
-- 提单人那条腿按人认:admin@ 提的,tim@ 批不了(同一个人)—— 所以提交时就按名拒
-- RECEIPT_PRICE_NO_OTHER_DECIDER,不让它挂到这里。
--
-- 【批准之前】(Tim 的 Q5 · Q6 · Q4)
--   · 指纹再比一次(receipt_price_fingerprint:数量、供应商、采购单与采购行、单价、含量、承诺、
--     最近一份已应用的化验)→ 不同就 RECEIPT_PRICE_CHANGED_SINCE_REQUEST|申请;
--   · 按批准日的牌价试跑,新货值 < 已付 → RECEIPT_PRICE_BELOW_SETTLED(Q6,按【这一天】的牌价);
--   · 然后真的过账(receipt_price_post_internal):价、price_history、purchase 分录记在今天;
--     化验来源且那份化验 is_final → pricing_status 升为 final(Q3)。
--   · amount_base 改写成实际过账的 |Δ|,approved 那一行留痕记的就是它(Q4)。
-- 驳回从不检查这些:驳回一张坏掉的申请,正是出路。驳回要理由。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_receipt_price_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r       receipt_price_requests%ROWTYPE;
    v_b       record;
    v_dry     jsonb;
    v_value   numeric;
    v_settled numeric;
    v_post    jsonb;
    v_je      uuid := NULL;
    v_amount  numeric;
BEGIN
    PERFORM require_permission('module.inbound.view');
    PERFORM require_permission('data.view_purchase_prices');

    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'receipt_price_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE receipt_price_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('receipt_price_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    SELECT id, code, quantity INTO v_b
      FROM inbound_batches WHERE id = v_r.inbound_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_r.inbound_batch_id;
    END IF;
    IF receipt_price_fingerprint(v_b.id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_dry := receipt_price_request_dry_run(p_request_id);
    v_value   := round(v_b.quantity * (v_dry->>'new_unit_price')::numeric, 2);
    v_settled := receipt_settled_base(v_b.id);
    IF v_value < v_settled THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_BELOW_SETTLED|%|%|%', v_b.code, v_value, v_settled;
    END IF;

    v_post := receipt_price_post_internal(p_request_id);
    SELECT je.id INTO v_je FROM journal_entries je WHERE je.code = v_post->>'journal_code';
    v_amount := abs(COALESCE((v_post->>'price_delta_usd')::numeric, 0));

    UPDATE receipt_price_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           posted_unit_price = (v_post->>'new_unit_price')::numeric,
           result_journal_entry_id = v_je, amount_base = v_amount
     WHERE id = p_request_id;
    PERFORM record_approval_decision('receipt_price_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'journal_code', v_post->>'journal_code',
                              'new_unit_price', v_post->'new_unit_price',
                              'price_delta_usd', v_post->'price_delta_usd');
END;
$function$
;

-- db/functions/withdraw_receipt_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q7):撤回一张在等的收货定价申请。
-- 谁能撤:提单人本人(按人认 —— self_leg 说这个账号就是提单人那个人),或任何持 action.price_receipts
-- 的人(财务)。化验来源的申请,提单的 cto 自己撤得了;撤销应用那份化验也会撤回它
-- (unapply_assay_result)。撤回不过账,只是放弃;不写 approval_log(撤回不是一次决定)。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_receipt_price_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r receipt_price_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM receipt_price_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('action.price_receipts');
    END IF;
    RETURN receipt_price_withdraw_internal(p_request_id, p_reason);
END;
$function$
;

-- ─── set_inbound_unit_price
CREATE OR REPLACE FUNCTION public.set_inbound_unit_price(p_inbound_batch_id uuid, p_unit_price numeric, p_currency text DEFAULT 'USD'::text, p_fx_rate numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ★ ROLE-1 Batch 4a:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');
    -- ★ ROLE-1 Batch 4b(Tim 的 Q8):定价面板从此【提一张申请】,不再直接过账 —— CFO 批了才进账。
    --   审批关着时申请生下来就是 approved 并当场过账(receipt_price_submit_internal)。
    --   汇率仍不由调用方递入(引擎的 FX_RATE_NOT_ACCEPTED,这里在写入之前就说)。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    RETURN receipt_price_submit_internal(p_inbound_batch_id, p_unit_price, p_currency, 'manual',
                                         NULL, NULL, p_notes);
END;
$function$;

-- ─── reprice_from_committed_terms
CREATE OR REPLACE FUNCTION public.reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch   record;
    v_commit  uuid;
    v_calc    jsonb;
    v_unit    numeric;
    v_rep     jsonb;
BEGIN
    -- ★ ROLE-1 Batch 4a:定价归财务(action.price_receipts),而且看不见采购价的人不能定价 ——
    --   两个码都在库里问(grilling Q1)。引擎 reprice_inbound_batch 自己再问一次后者。
    PERFORM require_permission('action.price_receipts');
    PERFORM require_permission('data.view_purchase_prices');

    SELECT id, code, pricing_formula_id INTO v_batch
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    -- 【与试算同一份算术】committed_terms_price 里做承诺解析、含量读取与算价;
    -- 这里只负责落账。两条路不可能各算各的。
    v_calc   := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_commit := (v_calc->>'commitment_id')::uuid;
    v_unit   := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_unit IS NULL OR v_unit <= 0 THEN
        -- 净值 ≤ 0 的料不进价格机器(与 apply_assay_result 同一判断),但这里是人
        -- 主动按的按钮,所以点名说清楚,而不是默默什么都不做。
        RAISE EXCEPTION 'PRICE_NOT_POSITIVE|%', COALESCE(v_unit::text, '?');
    END IF;

    -- ★ ROLE-1 Batch 4b(Tim 的 Q8):按已承诺条款改价从此【提一张申请】(来源 committed_terms),
    --   CFO 批了才过账;批准那一刻按批准日的牌价过账,并在收货还没挂公式时记下承诺副本的来源公式
    --   (receipt_price_post_internal —— 原来落账后紧接着做的那一步,挪到真正落账的那一刻)。
    v_rep := receipt_price_submit_internal(v_batch.id, v_unit, 'USD', 'committed_terms', NULL, v_commit,
                                           'Repriced from committed terms');

    RETURN jsonb_build_object(
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'commitment_id', v_commit,
        'unit_price_usd_per_kg', v_unit,
        'calc', v_calc,
        'request_id', v_rep->'request_id',
        'label', v_rep->'label',
        'status', v_rep->'status',
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'journal_code', v_rep->'journal_code'
    );
END;
$function$;

-- ─── create_inbound_batch
CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_id      uuid;
    v_warn    text[];
    v_pricing jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    -- ★ ROLE-1 Batch 4a(grilling Q4):建单【带价】就是定价 —— 要 action.price_receipts 与
    --   data.view_purchase_prices,在【写入之前】按名拒,整笔建单回滚;绝不悄悄丢掉那个价。
    --   不带价的建单只要 module.inbound.edit(仓库照建)。
    IF p_unit_price IS NOT NULL THEN
        PERFORM require_permission('action.price_receipts');
        PERFORM require_permission('data.view_purchase_prices');
    END IF;

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    -- PROC-2c:确定度随表头一起落 —— 适用性由 trg_inbound_batches_condition_applicable
    -- 判(它在库里,所以这条路、批次页面、直连 SQL 三条一起盖住)。
    -- RECV-SOURCE-1:理由原样落库,拒绝(RECEIPT_SOURCE_REQUIRED /
    -- SOURCE_REASON_EXPLANATION_REQUIRED)由 guard_receipt_source_stated 抛 ——
    -- 本函数一个字都不重复它们,重复一遍就是第二份会漂开的判断。
    -- INB-PAY-1:unit_price 【不在这里落】—— 见下面定价那一段。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:安全状态【只在给了参数时才碰】。
    -- 【NULL 与 '{}' 在这里是两件事】NULL = "这条路没提这件事"(既有调用点),
    -- '{}' = "明说了:一个状态都没有"。两者结果相同(零行),但只有前者
    -- 保证【一个字节都不动】—— F1 钉的正是这个。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- INB-PAY-1:建单带价 = 建单 + 定价,【同一事务】。
    -- ★ ROLE-1 Batch 4b(Tim 的 Q4):建单带价从此是【建单(不带价)+ 同一事务里提一张定价申请】
    --   (来源 desk)—— CFO 批了才进账;收货页上看得见它在等 CFO。提交时照批准那一刻的同一支过账
    --   试跑,所以非正价格、非法币种、缺牌价照旧按名拒,任何一条拒绝都让整笔建单回滚。
    --   审批关着时申请生下来就是 approved 并当场过账(与从前一样一步到位)。
    IF p_unit_price IS NOT NULL THEN
        v_pricing := receipt_price_submit_internal(v_id, p_unit_price, p_currency, 'desk', NULL, NULL, NULL);
    END IF;

    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    -- INB-PAY-1:定价的分解随之返回;不带价时为 null。ROLE-1 Batch 4b 起它是那张申请
    -- (request_id / label / status;审批关着时还有 journal_code)。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn),
                              'pricing', v_pricing);
END;
$function$

;

-- ─── apply_assay_result
CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_commit   uuid;
    v_csrc     uuid;
    v_ccode    text;
    v_live     uuid;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
    v_open     receipt_price_requests%ROWTYPE;
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- PROC-1:产出化验不走这条路 —— 这里的第 2-5 步全是围着应付转的,
    -- 而产出批没有应付。拆函数,不在函数里藏 IF。
    IF v_assay.output_batch_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_OUTPUT|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 0. ★ ROLE-1 Batch 4b(Tim 的 Q3 · Q5 · Q6):这张收货挂着一张在等 CFO 的定价申请时 ——
    --    · 来源不是化验(手工 / 按承诺条款 / 收货台):应用按名拒 RECEIPT_PRICE_REQUEST_OPEN,
    --      一个等着批的手工价不许被一份化验从脚下换掉含量;
    --    · 来源是化验:本次取代它 —— 先撤回那一张(理由写明被哪一份取代),本次再提自己的。
    --    放在改含量【之前】:含量守卫(guard_inbound_batch_metals_price_request)在有在等的申请时拒一切写。
    SELECT * INTO v_open FROM receipt_price_requests
     WHERE inbound_batch_id = v_batch.id AND status = 'submitted';
    IF FOUND THEN
        IF v_open.source <> 'assay' THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_batch.code, v_open.label;
        END IF;
        PERFORM receipt_price_withdraw_internal(v_open.id,
            'Superseded by assay ' || v_assay.code || ' applied');
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    --    PROC-1:抄进的行带出处 —— content_source='assay',指回这份单据。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct,
                                      content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 【结算条款 = 承诺时抄下的副本】(FIN-27)。解析次序与从前解析公式同构:
    --    批次自己的承诺 → 它那条采购行的承诺。活公式在这里【一次都不读】。
    v_commit := resolve_pricing_commitment(v_batch.id);

    IF p_pricing_formula_id IS NOT NULL THEN
        -- 结算时才指名公式(无采购单的现场收货):那一刻【就是】承诺时刻,现在抄。
        -- 已经有副本了就不许被顶掉 —— 副本一旦落下,它就是记录。
        IF v_commit IS NULL THEN
            v_commit := commit_pricing_terms(p_pricing_formula_id, NULL, v_batch.id);
        ELSE
            SELECT c.source_formula_id, c.source_formula_code INTO v_csrc, v_ccode
            FROM pricing_term_commitments c WHERE c.id = v_commit;
            IF v_csrc IS DISTINCT FROM p_pricing_formula_id THEN
                RAISE EXCEPTION 'PRICING_TERMS_ALREADY_COMMITTED|%|%', v_batch.code, v_ccode;
            END IF;
        END IF;
    END IF;

    IF v_commit IS NOT NULL THEN
        -- 3. 与计价器同一份算术(calculate_metal_price_from_terms),条款来自副本;
        --    再走与手工计价【同一条】重计价路径(reprice_inbound_batch)—— 价差分录、
        --    price_history、1200/5000 拆账三件事只存在一份实现。
        --    参考日默认化验日:结算价随行情,行情看化验那天。
        SELECT c.source_formula_id, c.source_formula_code INTO v_formula, v_fcode
        FROM pricing_term_commitments c WHERE c.id = v_commit;

        v_calc := calculate_metal_price_from_terms(
            pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity,
            COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;

        IF v_unit > 0 THEN
            -- ★ ROLE-1 Batch 4b:算出来的价不再当场过账 —— 在第 7 步提一张申请(来源 assay),
            --   等本次的含量、取代链与 applied_at 都落定之后(指纹要看见"它就是最近一份已应用的化验")。
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 没有副本。有活公式引用【却没有副本】= FIN-27 之前留下的承诺,当时没记
        --    条款 —— 点名拒。悄悄退回去读活公式正是本切要拆掉的行为,而把今天的
        --    公式当成当时谈定的条款,是编造一份承诺(D:不回填)。
        --    完全没有公式引用的批次照旧:手工定价的采购本来就由人定价,不是错误。
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次挂上这张公式。★ ROLE-1 Batch 4b(Tim 的 Q3):pricing_status 【不在这里】升 final ——
    --    只在 CFO 批准本次提的那张申请时(receipt_price_post_internal),而且只当这份化验 is_final。
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 7. ★ ROLE-1 Batch 4b(Tim 的 Q3):同一事务里提一张定价申请,来源 assay,提单人 = 按应用的这个人。
    --    提交时照批准那一刻的同一支过账试跑;二级除了提单人再没有别人批得动 → 整次应用按名拒
    --    (RECEIPT_PRICE_NO_OTHER_DECIDER,Tim 的 Q1)。审批关着时当场过账,is_final 时同时升 final。
    IF v_priced THEN
        v_rep := receipt_price_submit_internal(v_batch.id, v_unit, 'USD', 'assay', p_assay_result_id,
                                               v_commit, 'Assay ' || v_assay.code || ' applied');
    END IF;
    SELECT pricing_status INTO v_status FROM inbound_batches WHERE id = v_batch.id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        -- ★ ROLE-1 Batch 4b:priced = 这一次【已经过了账】(只在审批关着时);
        --   price_requested = 提了一张定价申请,它的编号与状态在 price_request 里。
        'priced', COALESCE(v_rep->>'status' = 'approved', false),
        'price_requested', v_priced,
        'price_request', v_rep,
        'superseded_request_id', v_open.id,
        'formula_code', v_fcode,
        -- FIN-27:结算按【哪一份承诺】算的 —— 供应商问起来要指得出那份副本
        'commitment_id', v_commit,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'note', v_note
    );
END;
$function$
;

-- ─── unapply_assay_result
CREATE OR REPLACE FUNCTION public.unapply_assay_result(p_assay_result_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_assay  record;
    v_latest uuid;
    v_req    uuid;
BEGIN
    -- PROC-1:先读单据才知道父是谁,权限判在任何改动之前(定义者身份读,不漏行)
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND OR v_assay.applied_at IS NULL THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    PERFORM require_permission('action.apply_assay');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    -- 只许撤最近一次:链条中间抽走一环,superseded_by 的叙事就断了。
    -- 链按【父】各自成链 —— 同一张表里进料链与产出链互不相扰。
    -- code 作平局裁决(applied_at 同事务内可能相同,编号无缝单调)。
    SELECT id INTO v_latest FROM assay_results
    WHERE (CASE WHEN v_assay.inbound_batch_id IS NOT NULL
                THEN inbound_batch_id = v_assay.inbound_batch_id
                ELSE output_batch_id = v_assay.output_batch_id END)
      AND applied_at IS NOT NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_latest IS DISTINCT FROM p_assay_result_id THEN
        RAISE EXCEPTION 'NOT_LATEST_ASSAY|%', v_assay.code;
    END IF;

    UPDATE assay_results
    SET applied_at = NULL, applied_by = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unapplied] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 被本次取代的上一份化验,链解开
    UPDATE assay_results SET superseded_by = NULL, updated_by = v_user
    WHERE superseded_by = p_assay_result_id;

    -- ★ ROLE-1 Batch 4b(Tim 的 Q3):这份化验还挂着一张在等 CFO 的定价申请 → 撤回它,理由写明是
    --   哪一份化验、为什么撤。已经批过的价【不动】(下面那段刻意不回价的理由原样成立)。
    SELECT id INTO v_req FROM receipt_price_requests
     WHERE assay_result_id = p_assay_result_id AND status = 'submitted';
    IF v_req IS NOT NULL THEN
        PERFORM receipt_price_withdraw_internal(v_req,
            'Assay ' || v_assay.code || ' unapplied: ' || btrim(p_reason));
    END IF;

    -- 【刻意不回价、不回含量】撤销"已执行"标记只是承认这份结果不再作数;
    -- 价格与含量退回到哪一版,是新化验或手工计价的显式动作 —— 静默回滚一个
    -- 已经过完账、可能已被分摊读走的状态,比留着它更危险。
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_assay.inbound_batch_id,
        'output_batch_id', v_assay.output_batch_id,
        'reverted_price', false,
        'withdrawn_price_request_id', v_req
    );
END;
$function$
;

-- ─── soft_delete_inbound_batch
CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_code text;
    v_open numeric;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        -- 【理由必填,而且拒绝要按名】注销一批料是一次真实的物理事件
        -- (它会写一条 writeoff 流水)。没有理由的注销,事后没有人答得出为什么。
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|inbound_batches|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM inbound_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    -- ★ ROLE-1 Batch 4b(Tim 的 Q5):挂着一张在等 CFO 的定价申请时不许注销 —— 先撤回或等它被决定。
    --   guard_inbound_batch_price_request 在 UPDATE 上还有第二道。
    IF receipt_price_open(p_batch_id) IS NOT NULL THEN
        RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_code, receipt_price_open(p_batch_id);
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1(Tim AP-RECON-0 Q2):【还欠着供应商钱的已计价批次,不许注销】
    --   注销只写一条 writeoff 流水(借 5200 / 贷 1200)—— 存货拿走了,那笔计价分录记下的
    --   【应付】却原样留在 2000 上。而每一个应付读者(ap_open_items、ap_aging_asof、
    --   record_payment_internal)都过滤 deleted_at IS NULL:于是那笔债从清单上消失、
    --   付款也核销不进去,只剩手工分录一条路。IN-2026-0154 的 4,032.00 就是这样来的
    --   (测试数据,不修,记在 known-wrong-until-cutover)。
    --   欠款 = 数量×单价 − 已过账付款的核销 − 预付冲抵 —— 与 ap_open_items 进料支同一条算术。
    --   【读基表,不读 ap_open_items】本函数的门是 module.inbound.edit;那张视图对没有
    --   finance.view 的读者是 0 行,读它会让一个仓库账号的"欠款为 0"成为一句假话,于是放行。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT round(round(ib.quantity * ib.unit_price, 2)
                 - COALESCE((SELECT sum(pa.allocated_ccy)
                               FROM payment_allocations pa
                               JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
                              WHERE pa.inbound_batch_id = ib.id), 0)
                 - COALESCE((SELECT sum(ppa.amount_base)
                               FROM prepayment_applications ppa
                              WHERE ppa.inbound_batch_id = ib.id), 0), 2)
      INTO v_open
      FROM inbound_batches ib
     WHERE ib.id = p_batch_id AND ib.unit_price IS NOT NULL;
    IF COALESCE(v_open, 0) > 0 THEN
        RAISE EXCEPTION 'INBOUND_HAS_OPEN_PAYABLE|%|%', v_code, v_open
          USING HINT = '这批货的计价还欠着供应商这笔钱(它在应付 2000 上)—— 注销会让它从应付清单上消失、再也付不进来。先付清,或先把价格更正过来;实物损失不是注销单据的理由';
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE inbound_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    -- ── COD-1:注销掉的料【不是被处理掉的】────────────────────────────────
    -- 实测:线上 11 张 remaining_qty = 0 的进料批里 8 张是这一类。
    -- 一张已签发的证书在这里作废 —— 它说的是"我们处理了你的料",而这票货被报废了。
    PERFORM refresh_cod_for_batch(p_batch_id);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。今天只有采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

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
            ARRAY['module.inbound.view', 'data.view_purchase_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- db/functions/guard_inbound_batch_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5 · Q3):收货表头上两道闸。
--
-- ① 【一张定价申请在等的时候,它批的那几样东西不许动】(Q5)
--    供应商、采购单、采购行被改,或收货被注销(deleted_at 由空变有)→
--    RECEIPT_PRICE_REQUEST_OPEN|收货|那一张申请。
--    ★ 这一道【不分直连写与属主路径】:注销走的是 soft_delete_inbound_batch(SECURITY DEFINER),
--      它自己也按名拒一次;这里是第二道 —— 将来哪一支属主函数改了供应商,照样撞上。
--    数量与含量由指纹在批准时再比(RECEIPT_PRICE_CHANGED_SINCE_REQUEST);含量的直连写另由
--    guard_inbound_batch_metals_price_request 当场拒。
-- ② 【pricing_status 只经函数写】(Q3)
--    直连写(row_security_active)改 pricing_status → PRICING_STATUS_VIA_FUNCTION|收货。
--    Step 0 实测:任何持 module.inbound.edit 的人都能直接把一张收货写成 final,而 Q3 的
--    「final 只在 CFO 批准时置」没有这一道就只是一句话。属主路径(批准那一支)看不见本守卫。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径(②);在不在等由 receipt_price_open(DEFINER)问
-- —— 不持采购价码的写入者在 INVOKER 里读不到申请表,会把"看不见"读成"没有申请"。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_inbound_batch_price_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_open text;
BEGIN
    IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id
       OR NEW.purchase_order_id IS DISTINCT FROM OLD.purchase_order_id
       OR NEW.purchase_order_line_id IS DISTINCT FROM OLD.purchase_order_line_id
       OR (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL) THEN
        v_open := receipt_price_open(OLD.id);
        IF v_open IS NOT NULL THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', OLD.code, v_open;
        END IF;
    END IF;
    IF NEW.pricing_status IS DISTINCT FROM OLD.pricing_status AND row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'PRICING_STATUS_VIA_FUNCTION|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_inbound_batch_price_request() IS
'ROLE-1 Batch 4b:① 一张收货挂着在等的定价申请时,改供应商 / 采购单 / 采购行或注销它,按名拒 RECEIPT_PRICE_REQUEST_OPEN|收货|申请(不分直连与属主路径);② 直连写(row_security_active)改 pricing_status,按名拒 PRICING_STATUS_VIA_FUNCTION|收货 —— final 只在 CFO 批准化验来源的申请时置(Tim 的 Q3)。INVOKER;在不在等经 receipt_price_open(DEFINER)问。';

-- db/functions/guard_inbound_batch_metals_price_request.sql
-- ROLE-1 Batch 4b(2026-09-25,Tim 的 Q5):一张收货挂着在等的定价申请时,它的含量不许改。
--
-- 含量是价格的输入:按已承诺条款改价(committed_terms_price)与化验算价都读 inbound_batch_metals。
-- Step 0 实测:手工含量的写策略开在 module.inbound.edit 上(INSERT / UPDATE / DELETE 都放),
-- 于是一张等着 CFO 批的价,它脚下的含量可以被悄悄换掉。本守卫:INSERT / UPDATE / DELETE,
-- 行所在的收货(UPDATE 两边都判)有在等的申请 → RECEIPT_PRICE_REQUEST_OPEN|收货|那一张申请。
-- ★ 【不分直连写与属主路径】:唯一改含量的属主函数是 apply_assay_result,它在改含量之前
--   就先按名拒(手工来源的申请)或先撤回(化验来源的申请,Tim 的 Q5)—— 走到这里时已经没有在等的申请。
--
-- 【为什么是 INVOKER】与 guard_inbound_batch_price_request 同一条:在不在等由
-- receipt_price_open(DEFINER)问。
-- NOTE: introduced by db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_inbound_batch_metals_price_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_bid  uuid;
    v_open text;
BEGIN
    FOREACH v_bid IN ARRAY (CASE TG_OP
                                WHEN 'INSERT' THEN ARRAY[NEW.inbound_batch_id]
                                WHEN 'DELETE' THEN ARRAY[OLD.inbound_batch_id]
                                ELSE ARRAY[OLD.inbound_batch_id, NEW.inbound_batch_id] END) LOOP
        v_open := receipt_price_open(v_bid);
        IF v_open IS NOT NULL THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', split_part(v_open, ' · ', 1), v_open;
        END IF;
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

COMMENT ON FUNCTION public.guard_inbound_batch_metals_price_request() IS
'ROLE-1 Batch 4b(Tim 的 Q5):收货挂着在等的定价申请时,它的 inbound_batch_metals 行 INSERT / UPDATE / DELETE 一律按名拒 RECEIPT_PRICE_REQUEST_OPEN|收货|申请(不分直连与属主路径;apply_assay_result 在改含量之前先拒或先撤回)。INVOKER;在不在等经 receipt_price_open(DEFINER)问。';

-- ── 4 · 守卫(Q5 · 4b Q3):两张表各一支 BEFORE 行级守卫 ─────────────────────────
CREATE TRIGGER trg_inbound_batches_price_request
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_batch_price_request();
CREATE TRIGGER trg_inbound_batch_metals_price_request
    BEFORE INSERT OR UPDATE OR DELETE ON public.inbound_batch_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_batch_metals_price_request();

-- ── 5 · operations_now:加一支 receipt_price_request_pending(镜像原样)──────────
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
          WHERE rq.status = 'submitted'::text) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

-- ── 6 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.b4b_pending_decider_check(p_after boolean DEFAULT true)
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
      LEFT JOIN holds h ON 'module.processing.edit' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      LEFT JOIN holds h ON 'module.stocktakes.edit' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
     WHERE s.status = 'open' AND s.deleted_at IS NULL
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

CREATE TEMP TABLE b4b_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved');

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM b4b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM b4b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4B_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM b4b_pending_before b EXCEPT SELECT a.k, a.id FROM b4b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b4b_pending_after a EXCEPT SELECT b.k, b.id FROM b4b_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM b4b_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM price_history) AS price_history,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE pricing_status = 'final') AS receipts_final,
       (SELECT count(*) FROM inbound_batch_metals) AS metal_rows,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied) n) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM b4b_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM price_history) AS price_history,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE pricing_status = 'final') AS receipts_final,
       (SELECT count(*) FROM inbound_batch_metals) AS metal_rows,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied) n);
    END IF;
    IF EXISTS (SELECT 1 FROM receipt_price_requests) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|receipt_price_requests is not empty';
    END IF;

    -- ④ 结构:两支守卫挂上;链的名册一行、只有二级;内层算子 authenticated 调不到(zzz 重放之前,
    --    这里先看函数本身 —— 重放在本文件之后由 apply_migration.sh 做,自证只断言守卫与名册)
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_inbound_batches_price_request',
                                                             'trg_inbound_batch_metals_price_request');
    IF v_n <> 2 THEN RAISE EXCEPTION 'ROLE1B4B_PROOF|expected 2 guard triggers, got %', v_n; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'receipt_price_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|receipt_price_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('receipt_price_request', 'decide_receipt_price_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'ROLE1B4B_PROOF|nobody can decide a receipt price request'; END IF;
    RAISE NOTICE 'ROLE1B4B deciders for receipt_price_request: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b4b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B4B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b4b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b4b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b4b_pending_decider_check(boolean);

COMMIT;

-- db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql
-- APR-5a —— 贷项通知与作废发票要 CFO 批准;绕过它的五条直连路关掉(docs/role-matrix.md「贷项通知、作废发票」)。
-- 由 db/scripts/build_apr5a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-5 grilling Q9–Q11 · Q13 的 invoice_request 那一半,Tim 2026-09-25 全部接受)
--   ① invoice_requests:贷项 / 作废申请。财务提(module.finance.edit),CFO 批每一张、不分档,批准【当场过账】,
--      按提交时冻下来的日期;rejected(要理由)· withdrawn(提单人或 module.finance.edit)。一张发票同时只挂一张。
--      提交按同一支过账试跑(PQ004)。审批关着时生下来就是 approved 并当场过账(auto_approved)。
--      提单人之外没人批得动 → INVOICE_REQUEST_NO_OTHER_DECIDER(assert_other_decider)。
--   ② create_credit_note / void_invoice 变成只会按名拒的门(INVOICE_NEEDS_APPROVED_REQUEST);函数体搬进
--      create_credit_note_internal / void_invoice_internal(EXECUTE 从 authenticated 收回)。
--   ③ 五条直连路(Q11):invoices 与 invoice_lines 的 INSERT / UPDATE 写策略拿掉,直连写按名拒
--      INVOICE_THROUGH_FUNCTION_ONLY;invoice_voided 只许由作废传播写;reverse_journal_entry 拒 invoice /
--      credit_note 分录(JE_REVERSE_USE_SOURCE_PATH);挂着贷项通知的发票不作废(INVOICE_HAS_CREDIT_NOTES)。
--   ④ 发货(Q10):一张在等的作废申请 → INVOICE_VOID_REQUESTED;一条挂在在等的 unshipped_cancel 贷项申请里
--      的发票行 → INVOICE_CREDIT_REQUESTED。收款从不被挡。
--   ⑤ 引擎登记(Q13):approval_chain_gates 一行(二级,module.finance.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 invoice_request;record_approval_decision 一支(本位币);operations_now 一支 invoice_request_pending。
--
-- 【不做什么】不新增任何权限码,所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行;不动发货的权限(APR-5b)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;approval_log、
-- journal_entries、发票(全部 / 作废)、发票行、贷项通知与行、发货、销售记录一行没变;授权一条没变;申请表是空的;
-- 四条写策略没了、两支守卫挂上、两支旧 enforce_write_permission 没了;两扇门只会拒;新链有人批得了;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.invoice_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR5A_PRE|invoice_requests already exists';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND policyname IN ('invoices insert by permission', 'invoices update by permission', 'invoice_lines insert by permission', 'invoice_lines update by permission')) <> 4 THEN
        RAISE EXCEPTION 'APR5A_PRE|the four invoice write policies are not all there to drop';
    END IF;
    IF (SELECT count(*) FROM pg_trigger WHERE tgname = 'enforce_write_permission'
         AND tgrelid IN ('public.invoices'::regclass, 'public.invoice_lines'::regclass)) <> 2 THEN
        RAISE EXCEPTION 'APR5A_PRE|the two enforce_write_permission triggers are not both there to replace';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.finance.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR5A_PRE|cfo does not hold both gate codes';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a5a_pending_before ON COMMIT DROP AS
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
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted';
CREATE TEMP TABLE a5a_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM invoices) AS invoices_all,
       (SELECT count(*) FROM invoices WHERE status = 'void') AS invoices_void,
       (SELECT count(*) FROM invoice_lines) AS invoice_lines,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM credit_note_lines) AS credit_note_lines,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM sales_records) AS sales_records;
CREATE TEMP TABLE a5a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · invoice_requests(镜像原样)──────────────────────────────────────────
CREATE TABLE public.invoice_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    invoice_id              uuid NOT NULL REFERENCES public.invoices (id) ON DELETE RESTRICT,
    kind                    text NOT NULL CHECK (kind IN ('credit_note', 'void')),
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label                   text NOT NULL,
    -- ── 冻结的那一组参数 ─────────────────────────────────────────────────────
    -- 贷项:凭证日(必填);作废:冲销日(不带税的 sale 型发票没有分录可冲,为 NULL)
    doc_date                date,
    reason                  text NOT NULL CHECK (btrim(reason) <> ''),
    -- 贷项的行,原样(create_credit_note 的 p_lines);作废为 NULL
    lines                   jsonb,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base             numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    -- 批准当场过账:生出来的贷项通知,与那一张分录(贷项分录 / 作废的冲销分录;
    -- 不带税的 sale 型发票作废没有分录)
    result_credit_note_id   uuid REFERENCES public.credit_notes (id) ON DELETE RESTRICT,
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    withdraw_reason         text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT invoice_requests_kind_shape CHECK (
        (kind = 'credit_note') = (lines IS NOT NULL)
        AND (kind <> 'credit_note' OR doc_date IS NOT NULL)),
    CONSTRAINT invoice_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT invoice_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT invoice_requests_approved_shape CHECK (
        (status = 'approved' AND kind = 'credit_note') = (result_credit_note_id IS NOT NULL)
        AND (result_journal_entry_id IS NULL OR status = 'approved')),
    CONSTRAINT invoice_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.invoice_requests IS
    'APR-5a:贷项通知与作废发票的申请(Tim 的矩阵:财务提,CFO 批每一张,不分档;批准当场过账)。submitted → approved(CFO,当场按冻结的日期过账)· rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。冻结提交时的参数(doc_date · reason · lines)。审批关着时生下来就是 approved 并当场过账(auto_approved)。一张发票同时只挂一张在等的申请。';

COMMENT ON COLUMN public.invoice_requests.amount_base IS
    'APR-5a:本位币。贷项 = 贷项分录的借方合计(净额 + 退回的税);作废 = 发票 total_base。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账的那一个(写进 approved 留痕)。';

CREATE UNIQUE INDEX invoice_requests_one_open_per_invoice
    ON public.invoice_requests (invoice_id)
    WHERE status = 'submitted';
CREATE INDEX invoice_requests_invoice_id_rel ON public.invoice_requests (invoice_id);
CREATE INDEX invoice_requests_result_credit_note_id_rel ON public.invoice_requests (result_credit_note_id);
CREATE INDEX invoice_requests_result_journal_entry_id_rel ON public.invoice_requests (result_journal_entry_id);

ALTER TABLE public.invoice_requests ENABLE ROW LEVEL SECURITY;

-- 读:发票的门(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。写:一条策略都不给 ——
-- 只经 submit_credit_note_request · submit_invoice_void_request · decide_invoice_request ·
-- withdraw_invoice_request(全是 SECURITY DEFINER)。
CREATE POLICY "invoice_requests select by permission" ON public.invoice_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.invoice_requests FROM anon;

-- ── 2 · approval_log:主体类型加 invoice_request;读策略加同名一支 ──────────────
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
                            'invoice_request'));
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
            ELSE false
        END
    );

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/guard_invoice_direct_write.sql
-- APR-5a(2026-09-25,grilling Q11 ① ②):**invoices 与 invoice_lines 没有直连写**。
--
-- 【量过的】写这两张表的函数 —— create_invoice · create_order_invoice · void_invoice_internal(以及
-- invoices 上 propagate_invoice_void 那支触发器,它在属主身份下触发)—— 全是 SECURITY DEFINER;
-- 没有一个屏幕直连写它们(app/ 里对这两张表只有读)。record_invoice_issue 写的是 invoice_issues,不是它们。
-- 于是四条写策略(两张表各 INSERT、UPDATE,都开在 module.finance.edit 上)一并拿掉。它们放行过的三条路:
--   · UPDATE invoices SET status = 'void':守卫恰好放行 issued → void,绕过 void_invoice 的核销、
--     已发货两条检查与它的冲销分录 —— 应收、合同负债、销项税全留在账上,发票却作废了,
--     行被释放、可以再开一遍;
--   · UPDATE invoice_lines SET invoice_voided = true:一张在册发票的行被释放,同一条销售 / 订单行可以再开票;
--   · INSERT 一张手写的 kind = 'order' 发票:ship_order 的 SO_SHIP_NOT_INVOICED 认它,货发得出去,
--     背后却没有 1100 / 2500 的那一笔。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 UPDATE / DELETE 是【零行、不报错】(SILENT-1 那一族);
-- 本守卫零行也照样触发,按名拒 INVOICE_THROUGH_FUNCTION_ONLY。它取代原来两支
-- enforce_write_permission('module.finance.edit') —— 那两支会让财务过关,再被 RLS 静默吞掉。
-- 属主路径(row_security_active = false)一律放行。形状照 guard_sales_record_direct_write。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_invoice_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'INVOICE_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_invoice_direct_write() IS
'APR-5a:invoices 与 invoice_lines 的任何直连写(row_security_active,语句级,零行也触发)按名拒 INVOICE_THROUGH_FUNCTION_ONLY。写它们的函数都是 SECURITY DEFINER;作废与贷项走 submit_invoice_void_request / submit_credit_note_request → CFO 批准。';

-- db/functions/void_invoice_internal.sql
-- APR-5a(2026-09-25):作废一张发票的【引擎】—— 原 void_invoice 的函数体,原样搬来,去掉门,
-- 加一条:挂着贷项通知的发票不作废(INVOICE_HAS_CREDIT_NOTES,grilling Q11 ⑤)。
-- 调用者:invoice_request_post_internal(CFO 批准一张作废申请的那一刻;审批关着时提交的那一刻;
-- 以及试跑)。void_invoice 本身从此是一扇只会按名拒的门(INVOICE_NEEDS_APPROVED_REQUEST)。
-- voided_by = auth.uid() = 按下批准的那个人(审批关着时是提单人)—— 作废真正发生在那一刻。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.void_invoice_internal(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
    v_n   int;
    v_rev jsonb;
BEGIN
    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INVOICE_ALREADY_VOID|%', v_inv.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    IF v_inv.kind = 'order' THEN
        -- 【冲销日必填,永不默认】它决定冲销分录的期间;期间锁/年结闸由
        -- post_journal_entry 对它统一执行(锁住的月份按名拒,不是悄悄挪到今天)。
        IF p_reversal_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        -- 【有活核销就不作废】核销行不可变、只随收款的冲销失效 —— 先冲收款
        -- (reverse_payment,先例),再作废发票。顺序反过来会留下一堆指着
        -- 已作废单据的活核销。
        SELECT count(*) INTO v_n
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.invoice_id = p_invoice_id;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_HAS_SETTLEMENTS|%|%', v_inv.code, v_n;
        END IF;
        -- 【SO-3b:停放的那条检查在这里落地】发货一旦释放过这张票的负债
        -- (部分或全部),冲销就没有足额的 2500 可借 —— 按名拒,更正走
        -- 【贷项凭证】(credit note,sales_records 表头停放的未来概念)。
        -- 判据是【派生】的:这张发票的行上,有没有发出去过的货。不设状态位 ——
        -- 状态位会与真相漂开,而这个问题每次都问得起(与 ship_order 的
        -- SO_SHIP_NOT_INVOICED 同一条)。
        SELECT count(*) INTO v_n
        FROM shipment_lines sl
        JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
        WHERE il.invoice_id = p_invoice_id AND NOT il.invoice_voided;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_SHIPPED_NOT_VOIDABLE|%', v_inv.code;
        END IF;
        -- ★ APR-5a(grilling Q11 ⑤):【挂着贷项通知的发票不作废】冲销冲的是开票那一整张分录
        --   (借 1100 / 贷 2500 / 贷 2100),而贷项那一张的贷 1100 还留着 —— 应收被解除两次。
        --   先前一张都不查。更正走另一张贷项通知(它按开放余额封顶)。
        SELECT count(*) INTO v_n FROM credit_notes cn WHERE cn.invoice_id = p_invoice_id;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_HAS_CREDIT_NOTES|%|%', v_inv.code, v_n;
        END IF;
        v_rev := reverse_journal_entry_internal(v_inv.entry_id, p_reversal_date, 'Void ' || v_inv.code);
    ELSIF v_inv.entry_id IS NOT NULL THEN
        -- ════════════════════════════════════════════════════════════════════
        -- 【GST-2:带税的 sale 型发票【有一张分录】—— 那张只过税的分录】
        -- GST-2 之前 sale 型什么都不过账,所以这一支从来不需要冲销。现在它需要:
        -- 不冲掉那张 借 1100 / 贷 2100,一张作废的发票会把销项税永远留在
        -- 2100 里,而 F5 的文档侧已经把这张票排除掉了 —— 于是勾稽的两边
        -- 会分开,而分开的原因是【作废没做完】,不是过账算错了税。
        -- 【日期必填,与 order 支逐字同一条理由】它决定冲销落进哪个期间。
        -- ════════════════════════════════════════════════════════════════════
        IF p_reversal_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        -- AP-RECON-1:sale 型发票的销项税现在【可以被核销】(record_payment_internal 的
        -- 发票支)。于是这一支也要 order 支那条规矩:有活核销就不作废 —— 否则冲回了税,
        -- 收进来的那笔钱却还核销在一张已作废的发票上。先冲收款,再作废。
        SELECT count(*) INTO v_n
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.invoice_id = p_invoice_id;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_HAS_SETTLEMENTS|%|%', v_inv.code, v_n;
        END IF;
        v_rev := reverse_journal_entry_internal(v_inv.entry_id, p_reversal_date, 'Void ' || v_inv.code);
    ELSE
        -- 不带税的 sale 头没有分录可冲 —— 收下一个日期再忽略它,是在骗调用方
        -- (record_output_sale 拒 p_fx_rate 的同一条)。
        IF p_reversal_date IS NOT NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_NOT_ACCEPTED|%', v_inv.code;
        END IF;
    END IF;

    -- 明细行保留供审计;作废标记由 trg_invoices_propagate_void 同步到明细行,
    -- 行(销售或订单行)随之重新可开票。
    UPDATE invoices
    SET status = 'void',
        void_reason = btrim(p_reason),
        voided_at = now(),
        voided_by = auth.uid()
    WHERE id = p_invoice_id;

    IF v_inv.kind = 'order' THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'invoice_voided',
                v_inv.code || ' · ' || btrim(p_reason), auth.uid());
    END IF;

    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'status', 'void',
        'reversal_code', v_rev->>'code');
END;
$function$
;

-- db/functions/create_credit_note_internal.sql
-- APR-5a(2026-09-25):开一张贷项通知的【引擎】—— 原 create_credit_note 的函数体,原样搬来,去掉门。
-- 调用者:invoice_request_post_internal(CFO 批准一张贷项申请的那一刻;审批关着时提交的那一刻;
-- 以及试跑)。create_credit_note 本身从此是一扇只会按名拒的门(INVOICE_NEEDS_APPROVED_REQUEST)。
-- credit_notes.created_by = auth.uid() = 按下批准的那个人(审批关着时是提单人)—— 凭证在那一刻生成;
-- 提单人记在申请上(invoice_requests.created_by),贷项通知指回申请由 result_credit_note_id 连着。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.create_credit_note_internal(p_invoice_id uuid, p_note_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_inv      invoices%ROWTYPE;
    v_cn_id    uuid := gen_random_uuid();
    v_code     text;
    v_open     numeric;
    v_amt      numeric;   -- AP-RECON-1 Batch B:发票净额(单据币种),清单的分母
    v_relief   numeric;   -- AP-RECON-1 Batch B:1100 净额腿解除的本位币
    v_a_base   numeric;
    v_birth    numeric;   -- AP-RECON-1 Batch B:这张发票过账时 1100 上的本位币(净额腿 + 税腿)
    v_el       jsonb;
    v_line_id  uuid;
    v_kind     text;
    v_amount   numeric;
    v_total    numeric := 0;
    v_a_total  numeric := 0;
    v_b_total  numeric := 0;
    v_grp      record;
    v_shipped  numeric;
    v_released numeric;
    v_ceiling  numeric;
    v_prior    numeric;
    v_je       jsonb;
    v_jlines   jsonb;
    v_n        int;
    -- ── GST-2 ────────────────────────────────────────────────────────────
    v_tax_total numeric := 0;   -- 本凭证退回的销项税,单据币种
    v_tax_base_total numeric := 0;   -- 同上,本位币 —— 逐行取整再相加(= F5 读的那个数)
    v_ln_code  text;            -- 被冲那一行【冻住的】税码
    v_ln_rate  numeric;         -- 同上,冻住的税率
    v_ln_tax   numeric;
BEGIN
    -- 【没有门】APR-5a:门搬到了提交(submit_credit_note_request,module.finance.edit)与
    -- 批准(decide_invoice_request,CFO)上;本支只在批准那一刻(或审批关着时提交那一刻、试跑)跑。

    -- 【单据日必填,永不默认】它决定冲销落进哪个期间。补一个 CURRENT_DATE
    -- 会让留空比填对更容易通过:今天的日期永远撞不上 PERIOD_LOCKED。
    IF p_note_date IS NULL THEN
        RAISE EXCEPTION 'CN_NOTE_DATE_REQUIRED';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'CN_REASON_REQUIRED';
    END IF;

    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    -- 【这两条守卫【也】在触发器上】这里再问一遍,是为了在算任何天花板之前
    -- 就给出正确的名字 —— 触发器要到 INSERT 那一刻才说话,而那时人已经
    -- 填完整张表单了(CMP-2:禁用与说明要在动作之前)。
    IF v_inv.kind <> 'order' THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_ORDER_KIND|%|%', v_inv.code, v_inv.kind;
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'CN_INVOICE_VOID|%', v_inv.code;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'CN_NO_LINES|%', v_inv.code;
    END IF;

    -- ── 天花板 ①:整张凭证 ≤ 这张发票【当下的】开放余额 ─────────────────────
    -- 读的是那一处不带过滤的算术(order_invoice_balance_all)。带过滤的那张
    -- 在 open = 0 时【没有行】,而把"没有行"读成 0 正是本仓库反复修的毛病 ——
    -- 这里要的恰恰是那个 0,并且要为它给出一个【专门的名字】。
    SELECT open_ccy, amount_ccy, birth_base INTO v_open, v_amt, v_birth FROM order_invoice_balance_all WHERE invoice_id = p_invoice_id;
    IF v_open IS NULL THEN
        -- issued + order 型必有一行(上面两条已经排除了别的情形)。走到这里
        -- 说明视图的前提变了 —— 当场炸,不要把它当成 0(那会让天花板消失)。
        RAISE EXCEPTION 'CN_BALANCE_MISSING|%', v_inv.code;
    END IF;
    IF v_open <= 0 THEN
        -- 【已经结清的发票不能再贷记】要还的是【现金】,那是一张付款单加一个
        -- 客户贷余概念,而这个系统今天没有客户贷余的落脚点。按名拒,
        -- 而不是让应收变成负数(那会在账龄上凭空消失、在敞口里悄悄抵扣)。
        RAISE EXCEPTION 'CN_INVOICE_FULLY_SETTLED|%', v_inv.code;
    END IF;

    -- ── 逐行校验 ────────────────────────────────────────────────────────────
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_line_id := NULLIF(v_el->>'invoice_line_id', '')::uuid;
        v_kind    := v_el->>'kind';
        v_amount  := NULLIF(v_el->>'amount', '')::numeric;

        IF v_line_id IS NULL THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'invoice_line_id';
        END IF;
        IF v_kind IS NULL OR v_kind NOT IN ('unshipped_cancel','revenue_reduction') THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'kind';
        END IF;
        IF v_amount IS NULL OR v_amount <= 0 THEN
            RAISE EXCEPTION 'CN_LINE_INVALID|%|%', COALESCE(v_el->>'line_no', '?'), 'amount';
        END IF;
        SELECT tax_code, tax_rate_pct INTO v_ln_code, v_ln_rate
          FROM invoice_lines WHERE id = v_line_id AND invoice_id = p_invoice_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CN_LINE_WRONG_INVOICE|%', v_line_id;
        END IF;

        -- 【GST-2:税码与税率【从被冲的那一行抄来】,不重新解析】
        -- 冲的是哪一笔供应,就退哪一笔供应的税 —— 连它当时那个税率一起,
        -- 即便法定税率此后变过。按 note_date 重新解析会用今天的税率去退
        -- 一笔按去年税率收过的税,差额无声地留在 2100 里。
        v_ln_tax := CASE WHEN v_ln_code IS NULL THEN 0
                         ELSE round(v_amount * v_ln_rate / 100.0, 2) END;
        v_tax_total := v_tax_total + v_ln_tax;
        -- 【本位币侧逐行取整再相加】F5 的 box6 读的就是 credit_note_lines.tax_base,
        -- 而那一列存的正是这个逐行 round 的值 —— 两处必须同式,否则勾稽会误报。
        v_tax_base_total := v_tax_base_total + round(v_ln_tax * v_inv.fx_rate, 2);

        v_total := v_total + v_amount;
        IF v_kind = 'unshipped_cancel' THEN v_a_total := v_a_total + v_amount;
        ELSE                                v_b_total := v_b_total + v_amount; END IF;
    END LOOP;

    -- 【与开放余额比的是【含税】总额】开票额从 GST-2 起是净额 + 销项税,
    -- 而这张凭证退的也是净额 + 税。只拿净额去比,天花板会松掉一截税。
    IF round(v_total + v_tax_total, 2) > round(v_open, 2) THEN
        RAISE EXCEPTION 'CN_EXCEEDS_OPEN|%|%', round(v_total + v_tax_total, 2), round(v_open, 2);
    END IF;

    -- ── 天花板 ② / ③:逐【发票行 × 类型】────────────────────────────────────
    -- 【按分组算,不是逐条算】一张凭证可以在同一发票行上放两条同类型的行,
    -- 逐条检查会让两条各自"没超"、合起来超掉。分组之后再与【历史】相加。
    FOR v_grp IN
        SELECT (e->>'invoice_line_id')::uuid AS line_id,
               e->>'kind' AS kind,
               sum((e->>'amount')::numeric) AS want
        FROM jsonb_array_elements(p_lines) e
        GROUP BY 1, 2
    LOOP
        -- 这一行【已发】多少 —— 读 shipment_lines(货真的离开台账的记录,
        -- 与 line_spoken_for 同一个理由)。
        -- 【为什么可以拿发票行的单价去乘】SO-1b 起,坐在在册发票上的订单行
        -- 数量与单价【整个冻住】(SO_AMEND_LINE_INVOICED),所以发票行的单价
        -- 与发货当时用的那个是同一个数。这一条是本段算术的前提,不是巧合。
        SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
          FROM shipment_lines sl
          JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
         WHERE il.id = v_grp.line_id;
        SELECT round(v_shipped * il.unit_price, 2) INTO v_released
          FROM invoice_lines il WHERE il.id = v_grp.line_id;

        -- 这一行同类型的【历史】贷记额
        SELECT COALESCE(sum(cl.amount), 0) INTO v_prior
          FROM credit_note_lines cl
         WHERE cl.invoice_line_id = v_grp.line_id AND cl.kind = v_grp.kind;

        IF v_grp.kind = 'unshipped_cancel' THEN
            -- 未释放的负债 = 这一行开票额 − 已释放进收入的部分
            SELECT round(il.amount_ccy - v_released, 2) INTO v_ceiling
              FROM invoice_lines il WHERE il.id = v_grp.line_id;
            v_ceiling := round(v_ceiling - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_UNRELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        ELSE
            v_ceiling := round(v_released - v_prior, 2);
            IF round(v_grp.want, 2) > v_ceiling THEN
                RAISE EXCEPTION 'CN_EXCEEDS_RELEASED|%|%|%',
                    (SELECT line_no FROM invoice_lines WHERE id = v_grp.line_id),
                    round(v_grp.want, 2), v_ceiling;
            END IF;
        END IF;
    END LOOP;

    -- ── 过账:一张分录 ──────────────────────────────────────────────────────
    -- 【借 2500 未释放的那部分 / 借 4000 已释放的那部分 / 贷 1100 合计】
    -- 单据币种,按【发票存下来的】汇率 —— 见迁移抬头:换个汇率会凭空造出
    -- 一笔看起来完全正常的已实现汇兑,而没有任何钱动过。
    -- 【0 金额的腿一条都不发】post_journal_entry 的 amount_ccy > 0 会拒,
    -- 而且一条 0 的腿在分录上读起来像"这一段发生了但金额为零"。
    v_code := next_credit_note_code(p_note_date);
    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1 Batch B:1100 解除的本位币 = 清单在这张凭证【之前】与【之后】
    -- 显示的差(list_open_base,与 record_payment_internal 的解除同一个式子);
    -- 税那条腿按它自己逐行取整的数,净额腿(v_relief)取其余。
    -- 此前是 round(合计 × 汇率):外币发票部分收过款之后再贷记,清单(round(剩余 × 汇率))
    -- 与总账差一分(fixture 213 C9)。借方跟着它走:有两条借方腿时,已释放那条
    -- (4000)取 解除额 − 未释放那条,于是分录按构造平衡;本位币(汇率 1)逐字节不变。
    -- 腿的 fx 写成 目标基准额 ÷ 原币额 —— 除后反乘取整恰好还原(record_payment 同一手)。
    -- ════════════════════════════════════════════════════════════════════════
    -- 带税时这张凭证解除的是 净额 + 税;税那条腿照旧逐行取整(F5 读它),净额腿取余下的。
    v_relief := list_open_base(v_open, v_amt, v_birth, v_inv.fx_rate)
              - list_open_base(round(v_open - v_total - v_tax_total, 2), v_amt, v_birth, v_inv.fx_rate)
              - round(v_tax_base_total, 2);
    v_a_base := CASE WHEN v_b_total > 0 THEN round(round(v_a_total, 2) * v_inv.fx_rate, 2) ELSE v_relief END;
    v_jlines := '[]'::jsonb;
    IF v_a_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '2500', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_a_total, 2),
            'fx_rate', v_a_base / round(v_a_total, 2),
            'line_memo', 'unshipped cancelled');
    END IF;
    IF v_b_total > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '4000', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_b_total, 2),
            'fx_rate', (v_relief - CASE WHEN v_a_total > 0 THEN v_a_base ELSE 0 END) / round(v_b_total, 2),
            'line_memo', 'revenue reduction');
    END IF;
    -- 【GST-2:退回去的税借 2100】—— 一张贷项凭证在 F5 上是一笔【负的供应】,
    -- 它的税也要从销项税里减回去。1100 那条腿因此贷【含税】总额:
    -- 客户少欠的钱就是净额 + 那笔税。
    IF round(v_tax_total, 2) > 0 THEN
        -- 【fx 用 v_tax_base_total / v_tax_total —— 与 create_order_invoice 同一手】
        -- 逐行取整的合计与 round(合计 × 汇率) 在外币下可以差一分,而 F5 读的是
        -- 前者、总账记的是后者 —— 差那一分,勾稽就会在一张正确的凭证上报 false。
        v_jlines := v_jlines || jsonb_build_object('account_code', '2100', 'side', 'debit',
            'currency', v_inv.currency, 'amount_ccy', round(v_tax_total, 2),
            'fx_rate', round(v_tax_base_total, 2) / round(v_tax_total, 2),
            'line_memo', 'output tax reversed');
    END IF;
    -- 【净额与税分成两条贷方腿】逐行 round(原币 × 汇率) 之下,一条合并腿会与
    -- 借方两条差一分钱 —— 与 record_expense / create_order_invoice 同一条理由。
    v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
        'currency', v_inv.currency, 'amount_ccy', round(v_total, 2), 'fx_rate', v_relief / round(v_total, 2));
    IF round(v_tax_total, 2) > 0 THEN
        v_jlines := v_jlines || jsonb_build_object('account_code', '1100', 'side', 'credit',
            'currency', v_inv.currency, 'amount_ccy', round(v_tax_total, 2),
            'fx_rate', round(v_tax_base_total, 2) / round(v_tax_total, 2),
            'line_memo', 'GST on ' || v_code);
    END IF;

    v_je := post_journal_entry(
        p_note_date,
        'Credit note ' || v_code || ' · ' || v_inv.code,
        'credit_note', v_cn_id,
        v_jlines);

    -- 【先过账再写单头】entry_id 因此可以是 NOT NULL,不需要"先写空、再回填"
    -- 那种单向放宽(与 create_order_invoice 逐字同一个顺序)。
    INSERT INTO credit_notes (id, code, invoice_id, reason, note_date, entry_id,
                              currency, fx_rate, created_by)
    VALUES (v_cn_id, v_code, p_invoice_id, btrim(p_reason), p_note_date,
            (v_je->>'entry_id')::uuid, v_inv.currency, v_inv.fx_rate, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        SELECT tax_code, tax_rate_pct INTO v_ln_code, v_ln_rate
          FROM invoice_lines WHERE id = (v_el->>'invoice_line_id')::uuid;
        INSERT INTO credit_note_lines (credit_note_id, invoice_line_id, kind, qty, amount,
                                       tax_code, tax_rate_pct, tax_base)
        VALUES (v_cn_id,
                (v_el->>'invoice_line_id')::uuid,
                v_el->>'kind',
                NULLIF(v_el->>'qty', '')::numeric,
                (v_el->>'amount')::numeric,
                v_ln_code,
                v_ln_rate,
                CASE WHEN v_ln_code IS NULL THEN 0
                     ELSE round(round((v_el->>'amount')::numeric * v_ln_rate / 100.0, 2)
                                * v_inv.fx_rate, 2) END);
    END LOOP;

    -- 【断言,不是假设】行的条数必须等于递进来的条数。将来有人给上面那个循环
    -- 加一个提前 CONTINUE,这里当场炸,而不是留下一张【分录按全部行算过、
    -- 明细却少了几条】的凭证 —— 那种凭证的总额与它自己的行对不上。
    SELECT count(*) INTO v_n FROM credit_note_lines WHERE credit_note_id = v_cn_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'CN_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    -- 【订单历史也记一笔】看订单的人问"这张单后来减过账没有",那个问题的答案
    -- 不该要求他先去翻发票列表(与 'invoiced' / 'invoice_voided' 同一条)。
    IF v_inv.sales_order_id IS NOT NULL THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'credit_noted',
                v_code || ' · ' || v_inv.currency || ' ' || trim_scale(round(v_total, 2))::text
                || ' · ' || btrim(p_reason), v_user);
    END IF;

    RETURN jsonb_build_object(
        'credit_note_id', v_cn_id,
        'code', v_code,
        'invoice_code', v_inv.code,
        'note_date', p_note_date,
        'currency', v_inv.currency,
        'fx_rate', v_inv.fx_rate,
        'total_ccy', round(v_total, 2),
        'total_base', round(round(v_total, 2) * v_inv.fx_rate, 2),
        'unshipped_cancel_ccy', round(v_a_total, 2),
        'revenue_reduction_ccy', round(v_b_total, 2),
        'line_count', v_n,
        'open_ccy_after', round(v_open - v_total, 2),
        'journal_code', v_je->>'code');
END;
$function$
;

-- db/functions/void_invoice.sql
-- APR-5a(2026-09-25):【一扇只会按名拒的门】作废一张发票要 CFO 批准(Tim 的矩阵「贷项通知、作废发票 |
-- 财务 | CFO」)。路径是 submit_invoice_void_request → decide_invoice_request,批准那一刻当场作废
-- (void_invoice_internal)。批准就是执行,所以这里永远没有一张"批了还没做"的申请 —— 本支对任何人
-- 都按名拒 INVOICE_NEEDS_APPROVED_REQUEST|发票(grilling Q9)。签名原样保留:旧页面、直连调用都听得见
-- 一个名字,而不是一次"找不到函数"。
-- NOTE: gate moved by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    RAISE EXCEPTION 'INVOICE_NEEDS_APPROVED_REQUEST|%', v_code;
END;
$function$
;

-- db/functions/create_credit_note.sql
-- APR-5a(2026-09-25):【一扇只会按名拒的门】开贷项通知要 CFO 批准(Tim 的矩阵「贷项通知、作废发票 |
-- 财务 | CFO」)。路径是 submit_credit_note_request → decide_invoice_request,批准那一刻当场过账
-- (create_credit_note_internal)。批准就是执行,所以这里永远没有一张"批了还没做"的申请 —— 本支对任何人
-- 都按名拒 INVOICE_NEEDS_APPROVED_REQUEST|发票(grilling Q9)。签名原样保留。
-- NOTE: gate moved by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.create_credit_note(p_invoice_id uuid, p_note_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CN_INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    RAISE EXCEPTION 'INVOICE_NEEDS_APPROVED_REQUEST|%', v_code;
END;
$function$
;

-- db/functions/invoice_request_post_internal.sql
-- APR-5a(2026-09-25):把一张贷项 / 作废申请【过账】—— 批准那一刻(或审批关着时提交那一刻)跑的那一支,
-- 也是试跑(invoice_request_dry_run)跑的同一支。参数全从申请行上读,就是提交时冻下来的那一组
-- (日期、理由、贷项的行 —— grilling Q9「on the frozen date」)。
--
--   credit_note → create_credit_note_internal(发票, doc_date, reason, lines)
--   void        → void_invoice_internal(发票, reason, doc_date)
--   其它种类    → INVOICE_REQUEST_KIND_UNKNOWN(PAY-REQ-1 Batch B 那一条:不认识的种类按名拒,
--                 不许落进一个 ELSE 去做别的事)
--
-- 返回引擎的返回值,再加三样:entry_id(这次过账的分录;不带税的 sale 型发票作废没有)、
-- credit_note_id(贷项才有)、amount_base(贷项 = 那张分录的借方合计;作废 = 发票的 total_base)。
-- 【为什么读分录而不是另算】与 payment_request_dry_run 读它自己那张分录同一条:同一支引擎的产物,
-- 不在这里另算一份会漂开的数。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.invoice_request_post_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     invoice_requests%ROWTYPE;
    v_res   jsonb;
    v_entry uuid;
    v_cn    uuid := NULL;
    v_base  numeric;
BEGIN
    SELECT * INTO v_r FROM invoice_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    CASE v_r.kind
    WHEN 'credit_note' THEN
        v_res := create_credit_note_internal(v_r.invoice_id, v_r.doc_date, v_r.reason, v_r.lines);
        v_cn := (v_res->>'credit_note_id')::uuid;
        SELECT je.id INTO v_entry FROM journal_entries je WHERE je.code = v_res->>'journal_code';
        SELECT sum(l.debit) INTO v_base FROM journal_lines l WHERE l.entry_id = v_entry;
    WHEN 'void' THEN
        v_res := void_invoice_internal(v_r.invoice_id, v_r.reason, v_r.doc_date);
        IF v_res->>'reversal_code' IS NOT NULL THEN
            SELECT je.id INTO v_entry FROM journal_entries je WHERE je.code = v_res->>'reversal_code';
        END IF;
        SELECT i.total_base INTO v_base FROM invoices i WHERE i.id = v_r.invoice_id;
    ELSE
        RAISE EXCEPTION 'INVOICE_REQUEST_KIND_UNKNOWN|%|%', v_r.label, v_r.kind;
    END CASE;

    RETURN v_res || jsonb_build_object('entry_id', v_entry, 'credit_note_id', v_cn,
                                       'amount_base', round(COALESCE(v_base, 0), 2));
END;
$function$
;

-- db/functions/invoice_request_dry_run.sql
-- APR-5a(2026-09-25):按【批准那一刻会用的同一支过账】把一张贷项 / 作废申请试跑一遍,然后整个回滚 ——
-- 贷项通知、分录、编号、作废标记一样都不留。提交时跑一次(提单人当场听见引擎的原话)。
--
-- 【为什么不写一份"校验函数"】与 payment_request_dry_run、payroll_request_dry_run、
-- receipt_price_request_dry_run 逐字同一条:开放余额、逐行天花板、已结清、已发货、有核销、期间锁、
-- 冲销日早于原单,抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份。
-- 返回 invoice_request_post_internal 的返回值(变量的赋值不随子事务回滚),所以 amount_base 从这里来。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。过账跑完抛专用 SQLSTATE PQ004,
-- 只接这一个 —— 引擎自己的任何拒绝照常往外抛。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.invoice_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := invoice_request_post_internal(p_request_id);
        RAISE EXCEPTION USING ERRCODE = 'PQ004', MESSAGE = 'INVOICE_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ004' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;

-- db/functions/invoice_request_submit_internal.sql
-- APR-5a(2026-09-25):提一张贷项 / 作废申请 —— submit_credit_note_request 与 submit_invoice_void_request
-- 都落进来的那一支。两扇门各自先问 module.finance.edit;本支不问码。
--
--   1. 发票锁住。理由、贷项的凭证日与行在写入之前就按引擎的原名拒(REASON_REQUIRED ·
--      CN_REASON_REQUIRED · CN_NOTE_DATE_REQUIRED · CN_NO_LINES)—— 否则撞上的是表上的 CHECK,
--      屏幕只能说"意外错误"。
--   2. 这张发票已经挂着一张在等的申请 → INVOICE_REQUEST_OPEN|发票|那一张(唯一索引是第二道)。
--   3. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动(assert_other_decider,按人认)。
--      没有 → INVOICE_REQUEST_NO_OTHER_DECIDER|发票(APR-5 brief:「no other decider」对每一种新申请都成立)。
--      线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。审批关着时不拦。
--   4. 落一行 submitted;参数原样冻结。
--   5. 按批准那一刻会用的同一支过账试跑(invoice_request_dry_run)—— 超出开放余额、超出逐行天花板、
--      已结清、已发货、有核销、有贷项、期间锁,这里按引擎的原话拒。amount_base 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场过账(invoice_request_post_internal),状态 approved,
--      留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.invoice_request_submit_internal(p_invoice_id uuid, p_kind text, p_doc_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv   record;
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_post  jsonb := NULL;
BEGIN
    SELECT id, code INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF p_kind = 'credit_note' THEN
        IF p_doc_date IS NULL THEN
            RAISE EXCEPTION 'CN_NOTE_DATE_REQUIRED';
        END IF;
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'CN_REASON_REQUIRED';
        END IF;
        IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
            RAISE EXCEPTION 'CN_NO_LINES|%', v_inv.code;
        END IF;
    ELSIF p_kind = 'void' THEN
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'REASON_REQUIRED';
        END IF;
    ELSE
        RAISE EXCEPTION 'INVOICE_REQUEST_KIND_UNKNOWN|%|%', v_inv.code, COALESCE(p_kind, '?');
    END IF;

    SELECT q.label INTO v_open FROM invoice_requests q
     WHERE q.invoice_id = v_inv.id AND q.status = 'submitted';
    IF FOUND THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_OPEN|%|%', v_inv.code, v_open;
    END IF;

    PERFORM assert_other_decider('invoice_request', 'decide_invoice_request', 2::smallint,
                                 'INVOICE_REQUEST_NO_OTHER_DECIDER|' || v_inv.code);

    SELECT count(*) + 1 INTO v_n FROM invoice_requests WHERE invoice_id = v_inv.id AND kind = p_kind;
    v_label := v_inv.code || ' · ' || CASE p_kind WHEN 'credit_note' THEN 'credit note' ELSE 'void' END
               || ' #' || v_n::text;

    INSERT INTO invoice_requests (id, invoice_id, kind, status, label, doc_date, reason, lines,
                                  amount_base, created_by)
    VALUES (v_id, v_inv.id, p_kind, 'submitted', v_label, p_doc_date, btrim(p_reason),
            CASE WHEN p_kind = 'credit_note' THEN p_lines END, 0, auth.uid());

    v_dry := invoice_request_dry_run(v_id);
    UPDATE invoice_requests SET amount_base = (v_dry->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('invoice_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_post := invoice_request_post_internal(v_id);
        UPDATE invoice_requests
           SET status = 'approved', amount_base = (v_post->>'amount_base')::numeric,
               result_credit_note_id = (v_post->>'credit_note_id')::uuid,
               result_journal_entry_id = (v_post->>'entry_id')::uuid
         WHERE id = v_id;
        PERFORM record_approval_decision('invoice_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场过账,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'invoice_code', v_inv.code,
        'amount_base', COALESCE(v_post->'amount_base', v_dry->'amount_base'),
        'credit_note_code', CASE WHEN p_kind = 'credit_note' THEN v_post->>'code' END,
        'credit_note_id', v_post->>'credit_note_id',
        'journal_code', COALESCE(v_post->>'journal_code', v_post->>'reversal_code'));
END;
$function$
;

-- db/functions/submit_credit_note_request.sql
-- APR-5a(2026-09-25):财务提一张贷项通知的申请 —— 参数与 create_credit_note 一字不差(发票、凭证日、
-- 理由、行),CFO 批准那一刻按这一组过账(Tim 的矩阵「贷项通知、作废发票 | 财务 | CFO」,grilling Q9)。
-- 门 module.finance.edit(原 create_credit_note 的门);其余全在 invoice_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_credit_note_request(p_invoice_id uuid, p_note_date date, p_reason text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN invoice_request_submit_internal(p_invoice_id, 'credit_note', p_note_date, p_reason, p_lines);
END;
$function$
;

-- db/functions/submit_invoice_void_request.sql
-- APR-5a(2026-09-25):财务提一张作废发票的申请 —— 参数与 void_invoice 一字不差(发票、理由、冲销日),
-- CFO 批准那一刻按这一组作废并冲销(Tim 的矩阵「贷项通知、作废发票 | 财务 | CFO」,grilling Q9)。
-- 门 module.finance.edit(原 void_invoice 的门);其余全在 invoice_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_invoice_void_request(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN invoice_request_submit_internal(p_invoice_id, 'void', p_reversal_date, p_reason, NULL::jsonb);
END;
$function$
;

-- db/functions/decide_invoice_request.sql
-- APR-5a(2026-09-25):CFO 批准或驳回一张贷项 / 作废申请。批准【当场过账】(grilling Q9),按提交时冻下来的
-- 那一组参数 —— 日期就是提单人填的那一天。
--
-- 【门】module.finance.view + data.view_prices —— 与付款申请同一对码(发票页的门,加上看得见金额的那个码;
-- docs/approvals.md §5)。【不是】module.finance.edit:那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】二级审批人,每一张、不分档,从不经按金额分档的那一支。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 发票不是谁的"自己的单据",主角那条腿对谁都不成立;
-- 提单人那条腿按人认:admin@ 提的,tim@ 批不了(同一个人)—— 所以提交时就按名拒
-- INVOICE_REQUEST_NO_OTHER_DECIDER,不让它挂到这里。self_approval_exception 不认本类型,R2 不适用。
--
-- 【批准之前不另查】等待期间发票能变的只有收款(Q10:收款从不被挡)。批准就是那一次真的过账:
-- 超出开放余额、已结清、有核销、已发货、有贷项、期间锁 —— 全按引擎原话拒,整笔回滚,申请仍在等;
-- CFO 驳回,或财务撤回再提。驳回从不检查这些:驳回一张坏掉的申请,正是出路。驳回要理由。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_invoice_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    invoice_requests%ROWTYPE;
    v_post jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM invoice_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'invoice_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'INVOICE_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE invoice_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('invoice_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_post := invoice_request_post_internal(p_request_id);

    UPDATE invoice_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           amount_base = (v_post->>'amount_base')::numeric,
           result_credit_note_id = (v_post->>'credit_note_id')::uuid,
           result_journal_entry_id = (v_post->>'entry_id')::uuid
     WHERE id = p_request_id;
    PERFORM record_approval_decision('invoice_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind,
                              'credit_note_code', CASE WHEN v_r.kind = 'credit_note' THEN v_post->>'code' END,
                              'journal_code', COALESCE(v_post->>'journal_code', v_post->>'reversal_code'),
                              'amount_base', v_post->'amount_base');
END;
$function$
;

-- db/functions/withdraw_invoice_request.sql
-- APR-5a(2026-09-25,grilling Q9):撤回一张在等的贷项 / 作废申请。
-- 谁能撤:提单人本人(按人认 —— self_leg 说这个账号就是提单人那个人),或任何持 module.finance.edit 的人。
-- 只撤 submitted。撤回不过账,只是放弃;记在本行上(谁、何时、为什么),【不】写 approval_log ——
-- 撤回不是一次决定(付款、工资、收货定价申请同一条)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_invoice_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r invoice_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM invoice_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.finance.edit');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'INVOICE_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE invoice_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$
;

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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废四种申请 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

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
            ARRAY['module.finance.view', 'data.view_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- db/functions/reverse_journal_entry.sql
-- 手工冲销一张分录(module.finance.edit)。付款、转账、代扣税缴纳的分录按名拒,走各自的申请。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q5):工资期的过账分录与它的冲销也按名拒 —— 撤销走撤销申请。
-- ★ APR-5a(2026-09-25,grilling Q11 ④):发票与贷项通知的分录(以及它们的冲销)也按名拒 —— 走作废 / 贷项申请。

CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_src text;
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- ★ PAY-REQ-1(Tim 的 Q2(b)):付款与银行转账的分录【不许】从这里冲 ——
    --   这里冲掉一笔付款的分录,钱在总账上回来了,而付款行仍是 posted、核销仍然
    --   算数(结算按 payments.status 求和),而且绕过了冲销申请与 CFO 的批准。
    --   付款走冲销申请(reverse_payment 那一条);转账走转账冲销申请。
    --   ★ PAY-REQ-1 Batch B(Tim 的 Q3):代扣税缴纳也关在这里 —— 它的更正从此走
    --   wht_remittance_reversal 申请(reverse_wht_remittance_internal),经 CFO 批准。
    SELECT source_type, code INTO v_src, v_code FROM journal_entries WHERE id = p_entry_id;
    -- ★ ROLE-1 Batch 4a(侧门 (b)):收货定价的 purchase 分录也关在这里 —— 从这里冲掉它,2000 回来了,
    --   收货单的单价与改价历史却不动,ap_open_items 照样说欠着,清单与总账从此各说各话。
    --   更正走改价(定价面板;Batch 4b 起经 CFO 批准的定价申请)。
    -- ★ APR-5a(grilling Q11 ④):发票(订单流开票分录、sale 型发票的税分录 —— 都是 'invoice')与贷项通知
    --   ('credit_note')的分录也关在这里 —— 从这里冲掉开票那一张,就是一次不经 CFO 的作废(发票却仍是 issued、
    --   仍可发货);冲掉一张贷项,就是一次不经 CFO 的"撤销贷项"。作废走作废申请,贷项走贷项申请。
    --   冲销分录抄原分录的 source_type,所以作废留下的那张冲销分录同样按名拒(否则冲掉它 = 不经批准地复活发票)。
    IF v_src IN ('payment', 'transfer', 'wht_remittance', 'purchase', 'invoice', 'credit_note') THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    -- ★ PAYROLL-APR-1(Tim 的 Q5):工资期的【过账】分录也关在这里 —— 从这里冲掉它,总账回来了,
    --   期间却仍是 posted、付款照样付得出去,而且绕过了撤销申请与 CFO 的批准。撤销走撤销申请。
    --   ☞ 【过账那一张,以及它的冲销】—— 冲掉一张撤销分录,等于不经申请把工资重新过了一遍账,
    --   而期间仍是 draft。判法反过来写:source_type 'payroll' 里,只有【付款】分录(以及它们的冲销)
    --   放行 —— 它们被 payroll_lines.paid_journal_entry_id / cpf_journal_entry_id /
    --   deductions_journal_entry_id 指着。付款分录根本没有正经的冲销路径(已登记
    --   PAYROLL-PAYMENT-NO-REVERSAL-PATH);在这里关掉它们,等于把唯一的(错的)出路也关了
    --   而不给一条对的 —— 那是另一刀的事。
    IF v_src = 'payroll' AND NOT EXISTS (
           SELECT 1 FROM journal_entries j
            WHERE j.id = p_entry_id
              AND (EXISTS (SELECT 1 FROM payroll_lines pl
                            WHERE pl.paid_journal_entry_id IN (j.id, j.source_id))
                   OR EXISTS (SELECT 1 FROM payroll_periods pp
                               WHERE pp.cpf_journal_entry_id IN (j.id, j.source_id)
                                  OR pp.deductions_journal_entry_id IN (j.id, j.source_id)))) THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    RETURN reverse_journal_entry_internal(p_entry_id, p_reversal_date, p_memo);
END;
$function$;

-- ─── ship_order
CREATE OR REPLACE FUNCTION public.ship_order(p_sales_order_id uuid, p_ship_date date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_order    sales_orders%ROWTYPE;
    v_ship_id  uuid := gen_random_uuid();
    v_code     text;
    v_item     jsonb;
    v_res      record;
    v_res_id   uuid;
    v_split    jsonb;
    v_inv      record;
    v_line_ids uuid[] := ARRAY[]::uuid[];
    v_mv       uuid;
    v_sl_id    uuid;
    v_sale_id  uuid;
    v_rev_ccy  numeric := 0;
    v_rev_base numeric := 0;
    v_fx       numeric;
    v_unit     numeric;
    v_cogs     numeric;
    v_je1      jsonb;
    v_je2      jsonb;
    v_rem      numeric;
    v_state    text;
    v_ordered  numeric;
    v_shipped  numeric;
    v_status   text;
    v_n        int;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 与 reserve_stock 逐字同一条:发货【就是】一次销售行为,做它的人是销售。
    -- 给它挑一个"销售与库存都满足"的权限码,只能挑一个比两者都松的 ——
    -- 那不是把关、是把关的样子(zzz_function_grants 给 drain_stock 写的理由)。
    -- 台账的不变量不依赖调用者是谁:check_no_negative_bucket 是约束触发器,
    -- check_ledger_invariant 也是,对任何身份一视同仁。
    --
    -- 【收入与 COGS 的过账也在这里,而它们是财务的事】—— 但把这一步拆成
    -- "销售发货 + 财务过账"两次调用,就等于允许一个【发了货却没记收入】的
    -- 中间态存在。选项 C 的整条链是一个事务,所以它是一个函数。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM require_permission('module.sales.edit');

    -- 【发货日必填,永不默认】物理事件日,而且它决定收入落进哪个会计期间。
    IF p_ship_date IS NULL THEN
        RAISE EXCEPTION 'SHIP_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_order FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_SHIP_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SO_SHIP_NO_LINES|%', v_order.code;
    END IF;

    v_code := next_shipment_code(p_ship_date);
    INSERT INTO shipments (id, code, sales_order_id, ship_date, notes, created_by)
    VALUES (v_ship_id, v_code, p_sales_order_id, p_ship_date, NULL, v_user);

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_res_id := NULLIF(v_item->>'reservation_id', '')::uuid;

        SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
               r.released_at, r.consumed_at,
               l.line_no, l.unit_price, l.sales_order_id,
               l.price_source, l.price_provenance
          INTO v_res
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE r.id = v_res_id
         FOR UPDATE OF r;
        -- 【不是这张单的预留 / 不存在 / 已释放 / 已发过 —— 都是"没有这条预留"】
        IF NOT FOUND OR v_res.sales_order_id <> p_sales_order_id
           OR v_res.released_at IS NOT NULL OR v_res.consumed_at IS NOT NULL THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_RESERVED|%', COALESCE(v_res_id::text, '?');
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【先开票后发货 —— 而判据是【派生】的,不是订单上的一个状态位】
        -- 这一行必须坐在一张【在册且已过账】的订单流发票上。状态位会与真相
        -- 漂开(作废一张票之后那个位还亮着),而这个问题每次都问得起。
        -- 顺带把那张票的【存下来的汇率】取出来:释放负债要按它,不按今天的行情
        -- —— 2500 里躺着的就是按它记进去的那个数(FIN-27 一族)。
        -- ════════════════════════════════════════════════════════════════════
        SELECT i.id, i.code, i.fx_rate, i.currency
          INTO v_inv
          FROM invoice_lines il
          JOIN invoices i ON i.id = il.invoice_id
         WHERE il.sales_order_line_id = v_res.sales_order_line_id
           AND NOT il.invoice_voided
           AND i.kind = 'order' AND i.status = 'issued'
         LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_INVOICED|%|%', v_order.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★ APR-5a(grilling Q10):【一张在等 CFO 的申请,把它要改的那一截货按住】
        -- 收款从不被挡(批准时的过账会按引擎原话拒);发货要挡 —— 否则等待期间发出去的一批货,
        -- 会把一张作废申请变成 INVOICE_SHIPPED_NOT_VOIDABLE,把一张"未发货取消"的贷项
        -- 变成对已经离场的货的取消。
        --   ① 这张发票挂着一张在等的【作废】申请 → INVOICE_VOID_REQUESTED|发票
        --   ② 这一条发票行挂在一张在等的【贷项】申请里、类型是 unshipped_cancel
        --      → INVOICE_CREDIT_REQUESTED|发票|行号
        -- ════════════════════════════════════════════════════════════════════
        IF EXISTS (SELECT 1 FROM invoice_requests q
                    WHERE q.invoice_id = v_inv.id AND q.status = 'submitted' AND q.kind = 'void') THEN
            RAISE EXCEPTION 'INVOICE_VOID_REQUESTED|%', v_inv.code;
        END IF;
        IF EXISTS (SELECT 1
                     FROM invoice_requests q
                     CROSS JOIN LATERAL jsonb_array_elements(q.lines) e
                     JOIN invoice_lines il ON il.id = NULLIF(e->>'invoice_line_id', '')::uuid
                    WHERE q.invoice_id = v_inv.id AND q.status = 'submitted' AND q.kind = 'credit_note'
                      AND e->>'kind' = 'unshipped_cancel'
                      AND il.sales_order_line_id = v_res.sales_order_line_id) THEN
            RAISE EXCEPTION 'INVOICE_CREDIT_REQUESTED|%|%', v_inv.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【部分发货:先把预留拆开,再整条消耗】(SO-2 的形状,一处实现)
        -- release_reservation(id, 要放回的数量, 理由) = 整笔释放 + 就地重新
        -- 预留剩余。所以要发 q(< 预留量 r)时,先把 (r − q) 放回 available,
        -- 剩下的那条新预留就正好是 q,然后【整条】消耗它。
        -- 【为什么不直接从这条预留里取走 q】那会让"committed 桶 = Σ 活预留"
        -- 不再成立:剩余的 (r − q) 还在桶里,却没有任何一行说它属于谁 ——
        -- 而 create_stock_transfer 的整桶搬正是靠那条不变量。
        -- 【也不在这里抄一份拆分逻辑】拆分只有一处实现,就是 release_reservation。
        -- ════════════════════════════════════════════════════════════════════
        IF (v_item->>'qty') IS NOT NULL AND (v_item->>'qty')::numeric <> v_res.qty THEN
            IF (v_item->>'qty')::numeric <= 0 OR (v_item->>'qty')::numeric > v_res.qty THEN
                RAISE EXCEPTION 'SO_SHIP_EXCEEDS_RESERVATION|%|%', v_item->>'qty', v_res.qty;
            END IF;
            v_split := release_reservation(v_res.id, v_res.qty - (v_item->>'qty')::numeric,
                                           'partial shipment ' || v_code);
            v_res_id := (v_split->'rereserved'->>'reservation_id')::uuid;
            SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
                   l.line_no, l.unit_price, l.price_source, l.price_provenance
              INTO v_res
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE r.id = v_res_id;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【出库:直接写,不走 drain_stock】—— 预留【就是地址】(哪一批、哪个
        -- 库位、多少),所以这是一次【定址消耗】。drain_stock 是给【没有地址】
        -- 的消耗用的策略排空器(销售直接卖、投料、注销):它按 NULL 桶优先、
        -- 再按库位 code 升序去猜该动哪一份。这里没有可猜的 —— 猜反而会取错桶。
        -- 两个函数的函数头互相指着对方,免得下一个人以为这里漏用了它。
        -- ════════════════════════════════════════════════════════════════════
        INSERT INTO inventory_movements
            (output_batch_id, location_id, movement_type, qty_delta, stock_status,
             business_date, notes, created_by)
        VALUES (v_res.output_batch_id, v_res.location_id, 'sale', -v_res.qty, 'committed',
                p_ship_date, 'shipped ' || v_code, v_user)
        RETURNING id INTO v_mv;

        -- 销售记录:一条腿一行。价格与币种取【订单】的,汇率取【发票存下来的】。
        -- 出处从订单行原样抄过来(FIN-26:记录,不推断)。
        -- sales_order_line_id 就是那个标记 —— 它让这一行【不产生应收】
        -- (ar_open_items 第一支与 customer_ar_exposure_base 第一项都排除它)。
        INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                                   currency, fx_rate, amount_base, sale_date, notes,
                                   created_by, price_source, price_provenance,
                                   sales_order_line_id)
        VALUES (v_res.output_batch_id, v_order.customer_id, v_res.qty, v_res.unit_price,
                v_order.currency, v_inv.fx_rate,
                round(v_res.qty * v_res.unit_price * v_inv.fx_rate, 2),
                p_ship_date, 'shipped ' || v_code || ' · ' || v_order.code,
                v_user, v_res.price_source, v_res.price_provenance,
                v_res.sales_order_line_id)
        RETURNING id INTO v_sale_id;

        -- SO-2b:腿表 —— 一条出库腿一行(这里恰好一条,因为消耗是定址的)
        INSERT INTO sales_record_movements (sales_record_id, movement_id)
        VALUES (v_sale_id, v_mv);

        INSERT INTO shipment_lines (shipment_id, sales_order_line_id, reservation_id,
                                    output_batch_id, location_id, qty, sales_record_id)
        VALUES (v_ship_id, v_res.sales_order_line_id, v_res.id,
                v_res.output_batch_id, v_res.location_id, v_res.qty, v_sale_id)
        RETURNING id INTO v_sl_id;

        -- 预留的第二种终局:【消耗】。没有反向流水 —— 货离开了台账。
        -- 【不回写 shipment_line_id】那一列不存在:shipment_lines.reservation_id
        -- 已经是 UNIQUE,反向指针是冗余的,而两表互指会让镜像循环依赖、
        -- 重建排不出建表顺序(verify_rebuild 当场抓到过)。
        UPDATE sales_order_reservations
           SET consumed_at = now(), consumed_by = v_user
         WHERE id = v_res.id;

        -- 库存缓存:与 record_output_sale 逐字同一套(remaining_qty 与 state)
        SELECT remaining_qty INTO v_rem FROM output_batches WHERE id = v_res.output_batch_id FOR UPDATE;
        v_rem := v_rem - v_res.qty;
        v_state := CASE WHEN v_rem = 0 THEN '已售罄' ELSE '部分售出' END;
        UPDATE output_batches
           SET remaining_qty = v_rem, state = v_state, updated_by = v_user, updated_at = now()
         WHERE id = v_res.output_batch_id;

        -- COGS:与 record_output_sale 逐字同形 —— 有产出腿单位成本才挂,
        -- 没有就等 allocate_processing_costs 补挂(它读 sales_records,
        -- 而这一行就是一条普通的 sales_records,所以它自然看得见)。
        SELECT po.unit_cost_base INTO v_unit
        FROM processing_outputs po WHERE po.output_batch_id = v_res.output_batch_id LIMIT 1;
        IF v_unit IS NOT NULL THEN
            v_cogs := round(v_res.qty * v_unit, 2);
            IF v_cogs <> 0 THEN
                v_je2 := post_journal_entry(
                    p_ship_date,
                    'COGS ' || (SELECT code FROM output_batches WHERE id = v_res.output_batch_id),
                    'shipment', v_sale_id,
                    jsonb_build_array(
                        jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                        jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
                UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
            END IF;
        END IF;

        -- 收入侧按【发票存下来的汇率】累计(一张发货单属于一张订单,所以一个汇率)
        v_fx := v_inv.fx_rate;
        v_rev_ccy := v_rev_ccy + round(v_res.qty * v_res.unit_price, 2);
        v_line_ids := v_line_ids || v_res.sales_order_line_id;
    END LOOP;

    v_rev_base := round(v_rev_ccy * v_fx, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 【过账:借 2500 释放合同负债 / 贷 4000 收入】单据币种,按发票存下来的汇率。
    -- 这就是选项 C 的第二步 —— 开票认了债(借 1100 / 贷 2500),发货把那笔
    -- 负债换成收入。2500 因此在一张单全部发完之后精确归零(fixture 68 钉住)。
    -- ════════════════════════════════════════════════════════════════════════
    v_je1 := post_journal_entry(
        p_ship_date,
        'Shipment ' || v_code || ' · ' || v_order.code,
        'shipment', v_ship_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2500', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx)));

    -- ════════════════════════════════════════════════════════════════════════
    -- 【订单状态是【现算】出来的,不是人点的】已发 vs 已订,逐行比。
    -- 经 so_status_ctx 写入 —— 冻结守卫据此知道是"函数在动状态列"。
    -- 【SO-1b:这段推导搬进了 sales_order_fulfilment_status,两个消费方读同一份】
    -- 改单也要问同一个问题(加一行 / 把一行改到正好等于已发),抄一份过去,
    -- 两边会在写下的那天一致、此后各自漂移。v_ordered / v_shipped 仍然算,
    -- 因为下面那行历史要把 "已发/已订" 印出来 —— 那是【展示】,不是判据。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(sum(l.quantity), 0) INTO v_ordered
      FROM sales_order_lines l WHERE l.sales_order_id = p_sales_order_id;
    SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
      FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id
     WHERE s.sales_order_id = p_sales_order_id;
    v_status := sales_order_fulfilment_status(p_sales_order_id);

    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status = v_status, updated_at = now(), updated_by = v_user
     WHERE id = p_sales_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (p_sales_order_id, 'shipped',
            v_code || ' · ' || trim_scale(v_shipped)::text || '/' || trim_scale(v_ordered)::text,
            v_user);

    -- 【断言,不是假设】发货行的条数必须等于递进来的条数。将来有人给上面任何
    -- 一段加一个提前 CONTINUE,这里当场炸,而不是留下一张少了几行的发货单
    -- (而那张单的收入分录已经按【全部】行算过了)。
    SELECT count(*) INTO v_n FROM shipment_lines WHERE shipment_id = v_ship_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'SO_SHIP_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    RETURN jsonb_build_object(
        'shipment_id', v_ship_id,
        'code', v_code,
        'ship_date', p_ship_date,
        'line_count', v_n,
        'revenue_ccy', v_rev_ccy,
        'revenue_base', v_rev_base,
        'currency', v_order.currency,
        'fx_rate', v_fx,
        'order_status', v_status,
        'revenue_journal', v_je1->>'code');
END;
$function$

;

-- ── 4 · invoices / invoice_lines:四条写策略拿掉;两支守卫取代 enforce_write_permission ──
DROP POLICY "invoices insert by permission" ON public.invoices;
DROP POLICY "invoices update by permission" ON public.invoices;
DROP POLICY "invoice_lines insert by permission" ON public.invoice_lines;
DROP POLICY "invoice_lines update by permission" ON public.invoice_lines;
DROP TRIGGER enforce_write_permission ON public.invoices;
DROP TRIGGER enforce_write_permission ON public.invoice_lines;
CREATE TRIGGER trg_invoices_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.invoices
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_invoice_direct_write();
CREATE TRIGGER trg_invoice_lines_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.invoice_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_invoice_direct_write();

-- invoice_voided 只许由作废传播写(Q11 ③)—— 行守卫从表镜像原样抽出
CREATE OR REPLACE FUNCTION public.guard_invoice_line_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    IF NEW.id              IS DISTINCT FROM OLD.id
       OR NEW.invoice_id      IS DISTINCT FROM OLD.invoice_id
       OR NEW.sales_record_id IS DISTINCT FROM OLD.sales_record_id
       OR NEW.line_no         IS DISTINCT FROM OLD.line_no
       OR NEW.description     IS DISTINCT FROM OLD.description
       OR NEW.quantity        IS DISTINCT FROM OLD.quantity
       OR NEW.unit            IS DISTINCT FROM OLD.unit
       OR NEW.unit_price      IS DISTINCT FROM OLD.unit_price
       OR NEW.amount_base      IS DISTINCT FROM OLD.amount_base
       OR NEW.sales_order_line_id IS DISTINCT FROM OLD.sales_order_line_id
       OR NEW.created_at      IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    -- ★ APR-5a(grilling Q11 ③):invoice_voided 只许由作废传播写,而且只许 false → true ——
    --   也就是它的发票【已经】是 void(propagate_invoice_void 是 AFTER UPDATE,那时头上已是 void)。
    --   此前这一列不在冻结清单里:一次直连翻转就把一张在册发票的行释放出来,同一条销售 / 订单行可以再开一遍票。
    IF NEW.invoice_voided IS DISTINCT FROM OLD.invoice_voided
       AND NOT (NEW.invoice_voided
                AND (SELECT i.status FROM invoices i WHERE i.id = NEW.invoice_id) = 'void') THEN
        RAISE EXCEPTION 'INVOICE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$fn$;

-- ── 5 · operations_now:加一支 invoice_request_pending(镜像原样)────────────────
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
          WHERE iq.status = 'submitted'::text) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

-- ── 6 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.a5a_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE a5a_pending_after ON COMMIT DROP AS
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
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a5a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a5a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR5A_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5A_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a5a_pending_before b EXCEPT SELECT a.k, a.id FROM a5a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a5a_pending_after a EXCEPT SELECT b.k, b.id FROM a5a_pending_before b)) THEN
        RAISE EXCEPTION 'APR5A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a5a_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM invoices) AS invoices_all,
       (SELECT count(*) FROM invoices WHERE status = 'void') AS invoices_void,
       (SELECT count(*) FROM invoice_lines) AS invoice_lines,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM credit_note_lines) AS credit_note_lines,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM sales_records) AS sales_records) n) THEN
        RAISE EXCEPTION 'APR5A_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM a5a_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM invoices) AS invoices_all,
       (SELECT count(*) FROM invoices WHERE status = 'void') AS invoices_void,
       (SELECT count(*) FROM invoice_lines) AS invoice_lines,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM credit_note_lines) AS credit_note_lines,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM sales_records) AS sales_records) n);
    END IF;
    IF EXISTS (SELECT 1 FROM invoice_requests) THEN
        RAISE EXCEPTION 'APR5A_PROOF|invoice_requests is not empty';
    END IF;

    -- ④ 结构:四条写策略没了、两张表上没有任何写策略;两支守卫挂上、两支旧 enforce_write_permission 没了;
    --    两扇门只会拒;名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('invoices', 'invoice_lines') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR5A_PROOF|an invoice write policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_invoices_direct_write', 'trg_invoice_lines_direct_write');
    IF v_n <> 2 THEN RAISE EXCEPTION 'APR5A_PROOF|expected 2 invoice guard triggers, got %', v_n; END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'enforce_write_permission'
                AND tgrelid IN ('public.invoices'::regclass, 'public.invoice_lines'::regclass)) THEN
        RAISE EXCEPTION 'APR5A_PROOF|an old enforce_write_permission trigger is still on an invoice table';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('void_invoice', 'create_credit_note')
                AND (prosrc NOT LIKE '%INVOICE_NEEDS_APPROVED_REQUEST%' OR prosrc LIKE '%post_journal_entry%'
                     OR prosrc LIKE '%reverse_journal_entry_internal%')) THEN
        RAISE EXCEPTION 'APR5A_PROOF|a door still does the work itself';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.reverse_journal_entry(uuid, date, text)'::regprocedure)
       NOT LIKE '%''invoice'', ''credit_note''%' THEN
        RAISE EXCEPTION 'APR5A_PROOF|reverse_journal_entry does not refuse invoice / credit_note entries';
    END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'invoice_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR5A_PROOF|invoice_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('invoice_request', 'decide_invoice_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR5A_PROOF|nobody can decide an invoice request'; END IF;
    RAISE NOTICE 'APR5A deciders for invoice_request: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a5a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR5A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a5a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR5A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a5a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a5a_pending_decider_check(boolean);

COMMIT;

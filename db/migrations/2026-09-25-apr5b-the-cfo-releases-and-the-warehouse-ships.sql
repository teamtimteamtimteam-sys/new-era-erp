-- db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql
-- APR-5b —— 发货前 CFO 放行;仓库照放行、在一页不带价格的队列里发货(docs/role-matrix.md §10「发货」)。
-- 由 db/scripts/build_apr5b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-5 grilling Q2–Q8 · Q13;5b grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   ① 两个新码,都一并授给 admin(Tim 的常设裁定):
--      action.request_shipping_release → cco(提放行)· action.ship_goods → warehouse(发货、开发货单)。
--      cco 从此不发货(ship_order / record_shipment_issue 的门换成 action.ship_goods);仓库【不】拿 module.sales.view。
--   ② shipping_releases + shipping_release_lines:submitted → approved(CFO,批准就是放行)· rejected(要理由)·
--      withdrawn(提单人或持提单码的人)。点名已开票的发票行;覆盖 = approved 且发票行未作废(作废自动失效)。
--      一张订单同时只挂一张 submitted;已覆盖的行不许再点名。审批关着时生下来就是 approved(auto_approved)。
--      提单人之外没人批得动 → SHIPPING_RELEASE_NO_OTHER_DECIDER。
--   ③ ship_order:门 action.ship_goods;发货那一刻客户冻结 → SO_SHIP_CUSTOMER_ON_HOLD(Q6);没有放行覆盖 →
--      SO_SHIP_NOT_RELEASED(Q3);超过 开票 − 未发货取消的数量 − 已发 → SO_SHIP_EXCEEDS_RELEASABLE(Q8);
--      部分发货改调 release_reservation_internal;返回值里没有任何金额(5b Q5)。
--      release_reservation / reserve_stock 的函数体搬进 *_internal(对 authenticated 收权,apply_migration.sh
--      重放 zzz_function_grants)。天花板的唯一推导:sales_order_line_releasable_all(基视图,收权)。
--   ④ 贷项申请:未发货取消提交时必带数量(CN_UNSHIPPED_CANCEL_QTY_REQUIRED · …_EXCEEDS,5b Q1)。
--   ⑤ 读者:shipping_release_context(CFO,门 module.sales.view + data.view_prices)· shipping_queue_rows
--      (仓库,门 action.ship_goods,没有价格,带送货地址 —— Tim 5b Q6)· shipment_document(发货单,
--      module.sales.view 或 action.ship_goods)。三张发货表的读策略放宽到 module.sales.view 或 action.ship_goods(Q7)。
--   ⑥ 引擎登记(Q13):approval_chain_gates 一行(二级,module.sales.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 shipping_release;record_approval_decision 一支;operations_now 两支
--      (shipping_release_pending · shipping_release_ready)。forbid_self_approval 按人认;self_approval_exception 不动。
--
-- 【不做什么】不碰审批开关与策略、user_roles、任何业务行;不改集装箱挂发货单的门(5b Q9,登记);
-- 不改 APR5-PARTIALLY-SHIPPED-HAS-NO-EXIT(登记着)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 裁定的那四行;两个新码的持有人
-- 正好是裁定的角色;在途单据一张不少、一张不多;approval_log、journal_entries、发货、发货行、预留、销售记录、
-- 发票、贷项一行没变;两张新表是空的;三条发货读策略放宽了;两扇门换了码;新链有人批得了;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.shipping_releases') IS NOT NULL OR to_regclass('public.shipping_release_lines') IS NOT NULL
       OR to_regclass('public.sales_order_line_releasable_all') IS NOT NULL THEN
        RAISE EXCEPTION 'APR5B_PRE|a 5b relation already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.request_shipping_release', 'action.ship_goods')) THEN
        RAISE EXCEPTION 'APR5B_PRE|new codes already exist';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.sales.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.sales.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR5B_PRE|cfo does not hold both gate codes';
    END IF;
    -- Q7:仓库【不】拿 module.sales.view —— 今天它就不持
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'module.sales.view') THEN
        RAISE EXCEPTION 'APR5B_PRE|warehouse unexpectedly holds module.sales.view';
    END IF;
    -- 发货读策略今天是 module.sales.view 一个码(Step 0 读过)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND tablename IN ('shipments', 'shipment_lines', 'shipment_issues') AND cmd = 'SELECT'
         AND qual = 'has_permission(''module.sales.view''::text)') <> 3 THEN
        RAISE EXCEPTION 'APR5B_PRE|the three shipment read policies are not what Step 0 read';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a5b_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE a5b_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM shipment_lines) AS shipment_lines,
       (SELECT count(*) FROM shipment_issues) AS shipment_issues,
       (SELECT count(*) FROM sales_order_reservations) AS reservations,
       (SELECT count(*) FROM sales_order_reservations WHERE released_at IS NULL AND consumed_at IS NULL) AS reservations_live,
       (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM sales_orders) AS sales_orders,
       (SELECT count(*) FROM invoices) AS invoices,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM invoice_requests) AS invoice_requests;
CREATE TEMP TABLE a5b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:两个新码 ─────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('action.request_shipping_release', 'action', 'Request shipping releases', '提发货放行', 'Ask the CFO to release an order''s invoiced lines for shipping. Approval is the release; the warehouse then ships against it. Nobody decides a release they raised.', '请 CFO 放行一张订单已开票的行。批准就是放行,之后仓库照它发货。没有人能批自己提的放行。', 1150),
    ('action.ship_goods', 'action', 'Ship goods', '发货', 'Ship released order lines from the warehouse shipping queue, and issue the delivery note. Shipping shows no prices; the revenue is posted by the system.', '在仓库发货队列里发出已放行的订单行,并开具发货单。发货看不见价格;收入由系统过账。', 1160);

-- ── 2 · 授权(在函数之前:下面的自证要问到它们)────────────────────────────────
-- cco 提放行、仓库发货;admin 两个都拿(Tim 的常设裁定)。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('cco', 'action.request_shipping_release'),
               ('admin', 'action.request_shipping_release'),
               ('warehouse', 'action.ship_goods'),
               ('admin', 'action.ship_goods')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 3 · shipping_releases(镜像原样)──────────────────────────────────────────
CREATE TABLE public.shipping_releases (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_order_id  uuid NOT NULL REFERENCES public.sales_orders (id) ON DELETE RESTRICT,
    status          text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label           text NOT NULL,
    -- 本位币:点名的发票行 amount_base 之和(提交时算,冻结)
    amount_base     numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at      timestamptz,
    decided_by      uuid,
    decision_notes  text,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at    timestamptz,
    withdrawn_by    uuid,
    withdraw_reason text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid NOT NULL,
    CONSTRAINT shipping_releases_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT shipping_releases_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT shipping_releases_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.shipping_releases IS
    'APR-5b:发货前放行(Tim 的矩阵:发货 = 仓库执行,在 CFO 放行之后)。cco 提(action.request_shipping_release),CFO 批 —— 批准就是放行,没有执行那一步。submitted → approved · rejected(要理由)· withdrawn(提单人本人或 action.request_shipping_release)。点名的是已开票的发票行(shipping_release_lines);覆盖现算 = approved 且发票行未作废。审批关着时生下来就是 approved(auto_approved)。一张订单同时只挂一张 submitted。';

COMMENT ON COLUMN public.shipping_releases.amount_base IS
    'APR-5b:本位币,点名的发票行 amount_base 之和,提交时算、冻结。只给留痕与 CFO 读;放行不过账。';

CREATE UNIQUE INDEX shipping_releases_one_open_per_order
    ON public.shipping_releases (sales_order_id)
    WHERE status = 'submitted';
CREATE INDEX shipping_releases_sales_order_id_rel ON public.shipping_releases (sales_order_id);

ALTER TABLE public.shipping_releases ENABLE ROW LEVEL SECURITY;

-- 读:订单页的门(module.sales.view)。写:一条策略都不给 —— 只经 submit_shipping_release ·
-- decide_shipping_release · withdraw_shipping_release(全是 SECURITY DEFINER)。
CREATE POLICY "shipping_releases select by permission" ON public.shipping_releases
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.shipping_releases FROM anon;

-- ── 3 · shipping_release_lines(镜像原样)──────────────────────────────────────────
CREATE TABLE public.shipping_release_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    release_id          uuid NOT NULL REFERENCES public.shipping_releases (id) ON DELETE RESTRICT,
    invoice_line_id     uuid NOT NULL REFERENCES public.invoice_lines (id) ON DELETE RESTRICT,
    sales_order_line_id uuid NOT NULL REFERENCES public.sales_order_lines (id) ON DELETE RESTRICT,
    created_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT shipping_release_lines_once UNIQUE (release_id, invoice_line_id)
);

COMMENT ON TABLE public.shipping_release_lines IS
    'APR-5b:放行点名的发票行,一行一条。覆盖 = 所属放行 approved 且这条发票行 NOT invoice_voided(现算;作废自动失效)。只经 submit_shipping_release 写。';

CREATE INDEX shipping_release_lines_invoice_line_id_rel ON public.shipping_release_lines (invoice_line_id);
CREATE INDEX shipping_release_lines_sales_order_line_id_rel ON public.shipping_release_lines (sales_order_line_id);

ALTER TABLE public.shipping_release_lines ENABLE ROW LEVEL SECURITY;

-- 读:与 shipping_releases 同一个码。写:一条策略都不给(只经 submit_shipping_release)。
CREATE POLICY "shipping_release_lines select by permission" ON public.shipping_release_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.sales.view'::text));

REVOKE ALL ON public.shipping_release_lines FROM anon;

-- ── 4 · approval_log:主体类型加 shipping_release;读策略加同名一支 ──────────────
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
                            'shipping_release'));
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
            ELSE false
        END
    );

-- ── 5 · sales_order_line_releasable_all(镜像原样)──────────────────────────
CREATE VIEW public.sales_order_line_releasable_all WITH (security_invoker = off) AS
 SELECT il.sales_order_line_id,
    il.id AS invoice_line_id,
    il.quantity AS invoiced_qty,
    COALESCE(( SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(il.unit_price, 0::numeric))) AS sum
           FROM credit_note_lines cl
          WHERE cl.invoice_line_id = il.id AND cl.kind = 'unshipped_cancel'::text), 0::numeric) AS cancelled_qty,
    il.quantity - COALESCE(( SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(il.unit_price, 0::numeric))) AS sum
           FROM credit_note_lines cl
          WHERE cl.invoice_line_id = il.id AND cl.kind = 'unshipped_cancel'::text), 0::numeric) AS releasable_qty
   FROM invoice_lines il
     JOIN invoices i ON i.id = il.invoice_id
  WHERE il.sales_order_line_id IS NOT NULL AND NOT il.invoice_voided AND i.kind = 'order'::text AND i.status = 'issued'::text;

COMMENT ON VIEW public.sales_order_line_releasable_all IS
    'APR-5b:一条订单行最多能发多少 = 在册订单流发票行的开票数量 − 未发货取消贷项的数量(无数量的旧行按 金额 ÷ 单价 折回)。唯一一处推导;消费方 ship_order · shipping_queue_rows · operations_now(shipping_release_ready)。已发不在这里减。客户端读不到:REVOKE SELECT。';

REVOKE SELECT ON public.sales_order_line_releasable_all FROM authenticated, anon;

-- ── 6 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/reserve_stock_internal.sql
-- APR-5b(2026-09-25,grilling Q7):reserve_stock 的函数体搬到这里,不问码 —— 仓库发货时部分发货要就地
-- 重新预留剩余(release_reservation_internal → 本支),而仓库不持 module.sales.edit。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.reserve_stock_internal(p_sales_order_line_id uuid, p_output_batch_id uuid, p_qty numeric, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_today    date := CURRENT_DATE;
    v_line     record;
    v_batch    record;
    v_avail    numeric;
    v_already  numeric;
    v_res_id   uuid;
BEGIN
    -- ★ APR-5b(2026-09-25):本支是 reserve_stock 的函数体,【不问调用者的码】。两个调用方各自先问:
    --   reserve_stock(module.sales.edit —— 预留是销售行为)· release_reservation_internal(部分释放就地
    --   重新预留剩余;它的调用方 release_reservation 问 module.sales.edit,ship_order 问 action.ship_goods)。
    --   EXECUTE 已从 authenticated 收回(zzz_function_grants)。

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'SO_RESERVE_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;

    SELECT l.id, l.quantity, l.material_id, l.line_no,
           o.id AS order_id, o.code AS order_code, o.status, o.deleted_at
      INTO v_line
      FROM sales_order_lines l
      JOIN sales_orders o ON o.id = l.sales_order_id
     WHERE l.id = p_sales_order_line_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_line_id::text, '?');
    END IF;

    -- 【只有确认了的订单才预留】草稿是还没答应的事,给它扣住货,等于让一张
    -- 随手建的单据把库存冻起来,而没有任何人做过那个承诺。
    -- 【SO-3b:partially_shipped 同样算数】一张发了一部分的单【仍然是活的】——
    -- 剩下的行还要预留、还要发。只认 confirmed 会让任何多行订单在第一次发货
    -- 之后就再也走不下去(fixture 68 第一次跑就撞上了这个)。
    IF v_line.deleted_at IS NOT NULL OR v_line.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_RESERVE_ORDER_NOT_CONFIRMED|%|%',
            v_line.order_code, COALESCE(v_line.status, '?');
    END IF;

    -- 【产出批次,且还在】—— 见本表注释:预留一个进料批次会造出永远消耗不掉的
    -- 承诺库存(movement_type='sale' 被 inventory_movements_side 钉在产出侧)。
    SELECT ob.id, ob.code, ob.material_id, ob.unit
      INTO v_batch
      FROM output_batches ob
     WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVE_OUTPUT_ONLY|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    IF v_batch.material_id IS DISTINCT FROM v_line.material_id THEN
        RAISE EXCEPTION 'SO_RESERVE_MATERIAL_MISMATCH|%|%|%',
            v_batch.code,
            (SELECT code FROM materials WHERE id = v_batch.material_id),
            (SELECT code FROM materials WHERE id = v_line.material_id);
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【行的天花板 —— 判据是"这一行已经许出去多少"】一行订单最多只能许出它
    -- 自己的数量。超过就是把同一行答应了两遍 —— 屏幕上看不出来,发货那天才炸。
    --
    -- 【SO-3b fu5:此前这里只数【活预留】,而发货会把预留移出那个集合】
    -- 于是一条发满的行,天花板重新变回满额:实测 12 kg 的行发掉 12 之后又预留
    -- 了 12、又发了一次,24 kg 出库、2500 落成净借方、收入是发票的两倍。
    -- 判据换成 line_spoken_for()(已发 + 活预留),而那是【唯一一处推导】——
    -- SO-1b 改单的下限读同一个函数,不另写一遍。
    -- 第三个数的含义随之变了:它现在是"已许出去",不是"已预留"(两种语言的
    -- 句子同步改过)。
    -- ════════════════════════════════════════════════════════════════════════
    v_already := line_spoken_for(p_sales_order_line_id);
    IF v_already + p_qty > v_line.quantity THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_LINE|%|%|%', p_qty, v_line.quantity, v_already;
    END IF;

    -- 【就地求和,不调 derived_stock_qty】那个函数体里有
    -- require_permission('module.inventory.view'),而 has_permission 解析的是
    -- 【调用者】的 JWT —— DEFINER 换得了行的可见性,换不了函数体内那句对调用者
    -- 的判断。销售的人没有库存的码,调过去当场 PERMISSION_DENIED。
    -- record_output_sale 就地求和,同一个理由。
    SELECT COALESCE(sum(m.qty_delta), 0) INTO v_avail
      FROM inventory_movements m
     WHERE m.output_batch_id = p_output_batch_id
       AND m.inbound_batch_id IS NULL
       AND m.location_id IS NOT DISTINCT FROM p_location_id
       AND m.stock_status = 'available';
    IF p_qty > v_avail THEN
        RAISE EXCEPTION 'SO_RESERVE_EXCEEDS_AVAILABLE|%|%', p_qty, v_avail;
    END IF;

    -- 成对:出 available、进 committed。同批次、同库位。物理总量按构造不动,
    -- remaining_qty 一个字不变,批次的 state 也不变(承诺不是销售)。
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_output_batch_id, p_location_id, 'status_change_out',
         -p_qty, 'available', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user),
        (p_output_batch_id, p_location_id, 'status_change_in',
          p_qty, 'committed', v_pair, v_today,
         'reserved for ' || v_line.order_code || ' line ' || v_line.line_no, v_user);

    INSERT INTO sales_order_reservations
        (sales_order_line_id, output_batch_id, location_id, qty, pair_id, created_by)
    VALUES (p_sales_order_line_id, p_output_batch_id, p_location_id, p_qty, v_pair, v_user)
    RETURNING id INTO v_res_id;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_line.order_id, 'reserved',
            format('line %s · %s %s %s', v_line.line_no, v_batch.code, p_qty, v_batch.unit));

    RETURN jsonb_build_object(
        'reservation_id', v_res_id, 'pair_id', v_pair, 'qty', p_qty,
        'output_batch_id', p_output_batch_id, 'location_id', p_location_id,
        'available_after', v_avail - p_qty,
        -- 【改名,因为含义改了】此前叫 line_reserved_after,而它现在含【已发】。
        -- 一个名字说着旧含义、值是新含义,比改名更贵(今天没有任何消费方读它,
        -- 现在改是最便宜的时刻)。
        'line_spoken_for_after', v_already + p_qty,
        'line_quantity', v_line.quantity);
END;
$function$

;

-- db/functions/release_reservation_internal.sql
-- APR-5b(2026-09-25,grilling Q7):release_reservation 的函数体搬到这里,不问码 —— ship_order 部分发货时调它,
-- 而发货归仓库(action.ship_goods),仓库不持 module.sales.edit。剩余就地重新预留走 reserve_stock_internal。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.release_reservation_internal(p_reservation_id uuid, p_qty numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_pair   uuid := gen_random_uuid();
    v_today  date := CURRENT_DATE;
    v_res    record;
    v_order  record;
    v_want   numeric;
    v_rest   numeric;
    v_new    jsonb := NULL;
BEGIN
    -- ★ APR-5b(2026-09-25,grilling Q7):本支是 release_reservation 的函数体,【不问调用者的码】。
    --   两个调用方各自先问:release_reservation(module.sales.edit)· ship_order(action.ship_goods,
    --   部分发货先把多出来的那一截放回)。EXECUTE 已从 authenticated 收回。

    SELECT r.*, l.line_no, l.sales_order_id
      INTO v_res
      FROM sales_order_reservations r
      JOIN sales_order_lines l ON l.id = r.sales_order_line_id
     WHERE r.id = p_reservation_id
     FOR UPDATE OF r;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_RESERVATION_NOT_FOUND|%', COALESCE(p_reservation_id::text, '?');
    END IF;
    IF v_res.released_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_RESERVATION_ALREADY_RELEASED|%', p_reservation_id;
    END IF;
    -- SO-3b:已经发出去的货放不回来 —— 更正走贷项凭证,不是"再释放一次"。
    IF v_res.consumed_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_RESERVATION_ALREADY_SHIPPED|%', p_reservation_id;
    END IF;

    -- 【释放要留下为什么,与暂扣同一条】一次没有理由的释放,过两天没人说得清
    -- 那批货为什么不再属于那张订单了。(hold_stock 的理由必填 / release_stock 的
    -- 备注可选,那处不对称是因为放开暂扣是"回到常态";这里不是 —— 撤回一个
    -- 已经做出的承诺【本身】就是一个需要解释的动作。)
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'SO_RELEASE_REASON_REQUIRED|%', p_reservation_id;
    END IF;

    v_want := COALESCE(p_qty, v_res.qty);
    IF v_want <= 0 OR v_want > v_res.qty THEN
        RAISE EXCEPTION 'SO_RELEASE_EXCEEDS|%|%', v_want, v_res.qty;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【部分释放 = 整行释放 + 就地重新预留剩余】
    -- 不是"把 qty 改小"。一行预留是一个发生过的事实(某日许了 40),把它改成
    -- 25 是在改写历史。整行释放之后再预留 15,留下的是两条都为真的事实,
    -- 合起来正好是发生过的经过 —— 而且流水侧一样对得上:先整笔 40 回到
    -- available,再 15 进 committed,净效果就是放回 25。
    -- 【重新预留走的是 reserve_stock 本身】,不是一段抄过来的插入:它会重新
    -- 走一遍订单状态、行天花板、桶余量三道检查。同一条规则,一个实现。
    -- ════════════════════════════════════════════════════════════════════════
    INSERT INTO inventory_movements
        (output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (v_res.output_batch_id, v_res.location_id, 'status_change_out',
         -v_res.qty, 'committed', v_pair, v_today, btrim(p_reason), v_user),
        (v_res.output_batch_id, v_res.location_id, 'status_change_in',
          v_res.qty, 'available', v_pair, v_today, btrim(p_reason), v_user);

    UPDATE sales_order_reservations
       SET released_at     = now(),
           released_by     = v_user,
           release_reason  = btrim(p_reason),
           release_pair_id = v_pair
     WHERE id = p_reservation_id;

    v_rest := v_res.qty - v_want;
    IF v_rest > 0 THEN
        v_new := reserve_stock_internal(v_res.sales_order_line_id, v_res.output_batch_id,
                               v_rest, v_res.location_id);
    END IF;

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (v_res.sales_order_id, 'released',
            format('line %s · %s · %s', v_res.line_no, v_want, btrim(p_reason)));

    RETURN jsonb_build_object(
        'reservation_id', p_reservation_id,
        'released_qty', v_want,
        'release_pair_id', v_pair,
        'rereserved_qty', v_rest,
        'rereserved', v_new);
END;
$function$

;

-- ─── reserve_stock
CREATE OR REPLACE FUNCTION public.reserve_stock(p_sales_order_line_id uuid, p_output_batch_id uuid, p_qty numeric, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【为什么是 module.sales.edit,而不是 module.inventory.edit】
    -- 预留就是一次销售行为 —— 做它的人是销售。给它挑一个"销售与库存都满足"的
    -- 权限码,只能挑一个比两者都松的,那不是把关、是把关的样子(与
    -- zzz_function_grants 给 drain_stock 写的那条理由同形)。而台账的不变量
    -- 不依赖调用者是谁:成对写入让物理总量按构造不动,check_no_negative_bucket
    -- 是约束触发器,对任何身份一视同仁。
    PERFORM require_permission('module.sales.edit');
    -- ★ APR-5b:函数体搬进 reserve_stock_internal(部分发货就地重新预留要用它,而发货归仓库)。
    RETURN reserve_stock_internal(p_sales_order_line_id, p_output_batch_id, p_qty, p_location_id);
END;
$function$

;

-- ─── release_reservation
CREATE OR REPLACE FUNCTION public.release_reservation(p_reservation_id uuid, p_qty numeric DEFAULT NULL::numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 释放一条预留是销售行为(撤回一个已经做出的承诺)—— module.sales.edit。
    -- ★ APR-5b:函数体搬进 release_reservation_internal(ship_order 部分发货要用它,而发货归仓库)。
    PERFORM require_permission('module.sales.edit');
    RETURN release_reservation_internal(p_reservation_id, p_qty, p_reason);
END;
$function$

;

-- db/functions/submit_shipping_release.sql
-- APR-5b(2026-09-25):cco 请 CFO 放行一张订单已开票的行(APR-5 grilling Q2–Q4 · 5b grilling Q2–Q3)。
--
--   门 action.request_shipping_release(cco · admin)。
--   1. 订单锁住;必须 confirmed / partially_shipped(SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE)。
--   2. 这张订单已经挂着一张 submitted → SHIPPING_RELEASE_OPEN|订单|那一张(唯一索引是第二道)。
--   3. 点名的行:p_invoice_line_ids 为 NULL = 每一条【在册】(订单流、issued、NOT invoice_voided)、
--      还没被覆盖的发票行(5b Q2 的默认);给了就逐条判 ——
--        不是这张订单的在册发票行 → SHIPPING_RELEASE_LINE_NOT_INVOICED|订单|那一条
--        已经被一张 approved 的放行覆盖 → SHIPPING_RELEASE_LINE_ALREADY_RELEASED|订单|行号(5b Q3)
--      一条都没有 → SHIPPING_RELEASE_NO_LINES|订单。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动(assert_other_decider,按人认)。
--      没有 → SHIPPING_RELEASE_NO_OTHER_DECIDER|订单。线上是 admin@:它与 tim@ 是同一个人。
--   5. 落一行 + 点名的行;amount_base = 点名发票行 amount_base 之和(本位币)。
--   6. 审批开着:留痕 submitted,二级。关着:生下来就是 approved,留痕 auto_approved —— 没有人按过批准,
--      留痕就不许说有人按过(PAY-REQ-1 Q8 同形)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.submit_shipping_release(p_sales_order_id uuid, p_invoice_line_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order  record;
    v_on     boolean := approvals_enabled();
    v_id     uuid := gen_random_uuid();
    v_open   text;
    v_bad    uuid;
    v_line   integer;
    v_n      integer;
    v_label  text;
    v_amount numeric;
    v_ids    uuid[];
BEGIN
    PERFORM require_permission('action.request_shipping_release');

    SELECT id, code, status, deleted_at INTO v_order FROM sales_orders WHERE id = p_sales_order_id FOR UPDATE;
    IF NOT FOUND OR v_order.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    SELECT r.label INTO v_open FROM shipping_releases r
     WHERE r.sales_order_id = v_order.id AND r.status = 'submitted';
    IF FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_OPEN|%|%', v_order.code, v_open;
    END IF;

    -- 这张订单的在册发票行(订单流、issued、未作废),与"已被一张 approved 放行覆盖"这一问 ——
    IF p_invoice_line_ids IS NULL THEN
        SELECT array_agg(c.invoice_line_id ORDER BY c.line_no) INTO v_ids
          FROM (SELECT il.id AS invoice_line_id, sol.line_no,
                       EXISTS (SELECT 1 FROM shipping_release_lines rl
                                 JOIN shipping_releases r ON r.id = rl.release_id
                                WHERE rl.invoice_line_id = il.id AND r.status = 'approved') AS covered
                  FROM invoice_lines il
                  JOIN invoices i ON i.id = il.invoice_id
                  JOIN sales_order_lines sol ON sol.id = il.sales_order_line_id
                 WHERE sol.sales_order_id = v_order.id
                   AND i.kind = 'order' AND i.status = 'issued' AND NOT il.invoice_voided) c
         WHERE NOT c.covered;
    ELSE
        SELECT x INTO v_bad FROM unnest(p_invoice_line_ids) x
         WHERE x IS NULL OR NOT EXISTS (
               SELECT 1 FROM invoice_lines il
                 JOIN invoices i ON i.id = il.invoice_id
                 JOIN sales_order_lines sol ON sol.id = il.sales_order_line_id
                WHERE il.id = x AND sol.sales_order_id = v_order.id
                  AND i.kind = 'order' AND i.status = 'issued' AND NOT il.invoice_voided)
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SHIPPING_RELEASE_LINE_NOT_INVOICED|%|%', v_order.code, COALESCE(v_bad::text, '?');
        END IF;
        SELECT min(sol.line_no) INTO v_line
          FROM invoice_lines il
          JOIN sales_order_lines sol ON sol.id = il.sales_order_line_id
         WHERE il.id = ANY (p_invoice_line_ids)
           AND EXISTS (SELECT 1 FROM shipping_release_lines rl
                         JOIN shipping_releases r ON r.id = rl.release_id
                        WHERE rl.invoice_line_id = il.id AND r.status = 'approved');
        IF v_line IS NOT NULL THEN
            RAISE EXCEPTION 'SHIPPING_RELEASE_LINE_ALREADY_RELEASED|%|%', v_order.code, v_line;
        END IF;
        SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_invoice_line_ids) x;
    END IF;
    IF v_ids IS NULL OR cardinality(v_ids) = 0 THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NO_LINES|%', v_order.code;
    END IF;

    PERFORM assert_other_decider('shipping_release', 'decide_shipping_release', 2::smallint,
                                 'SHIPPING_RELEASE_NO_OTHER_DECIDER|' || v_order.code);

    SELECT count(*) + 1 INTO v_n FROM shipping_releases WHERE sales_order_id = v_order.id;
    v_label := v_order.code || ' · release #' || v_n::text;
    SELECT COALESCE(sum(amount_base), 0) INTO v_amount FROM invoice_lines WHERE id = ANY (v_ids);

    INSERT INTO shipping_releases (id, sales_order_id, status, label, amount_base, created_by)
    VALUES (v_id, v_order.id, CASE WHEN v_on THEN 'submitted' ELSE 'approved' END, v_label, v_amount,
            auth.uid());
    INSERT INTO shipping_release_lines (release_id, invoice_line_id, sales_order_line_id)
    SELECT v_id, il.id, il.sales_order_line_id FROM invoice_lines il WHERE il.id = ANY (v_ids);

    IF v_on THEN
        PERFORM record_approval_decision('shipping_release', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('shipping_release', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:放行生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'release_id', v_id,
        'label', v_label,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'order_code', v_order.code,
        'line_count', cardinality(v_ids));
END;
$function$
;

-- db/functions/decide_shipping_release.sql
-- APR-5b(2026-09-25):CFO 批准或驳回一张发货放行。【批准就是放行】—— 没有执行那一步(APR-5 grilling Q2):
-- 批准之后仓库就能照它发货(ship_order 问覆盖),可以分好几次发。
--
-- 【门】module.sales.view + data.view_prices(Q13)—— 订单页的门,加上看得见金额的那个码(CFO 决定时看得见
-- 敞口、额度、冻结、收了多少、逐行毛利:shipping_release_context);【不是】action.request_shipping_release:
-- 那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】二级审批人,每一张、不分档。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 订单不是谁"自己的单据";提单人那条腿按人认:admin@ 提的,
-- tim@ 批不了(同一个人)—— 所以提交时就按名拒 SHIPPING_RELEASE_NO_OTHER_DECIDER。self_approval_exception
-- 不认本类型,R2 不适用。
-- 【批准时再看一眼订单】订单已经取消 / 关闭(等待期间)→ SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE,申请仍在等,
-- CFO 驳回或 cco 撤回。驳回从不检查这些 —— 驳回一张坏掉的申请正是出路。驳回要理由。
-- 点名的发票行在等待期间被作废了,批准照样成立:覆盖是现算的,作废那一条自己不被覆盖(Q3)。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.decide_shipping_release(p_release_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     shipping_releases%ROWTYPE;
    v_order record;
BEGIN
    PERFORM require_permission('module.sales.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM shipping_releases WHERE id = p_release_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_FOUND|%', COALESCE(p_release_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'shipping_release');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'SHIPPING_RELEASE_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE shipping_releases
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_release_id;
        PERFORM record_approval_decision('shipping_release', p_release_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('release_id', p_release_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    SELECT code, status, deleted_at INTO v_order FROM sales_orders WHERE id = v_r.sales_order_id;
    IF v_order.deleted_at IS NOT NULL OR v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    UPDATE shipping_releases
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_release_id;
    PERFORM record_approval_decision('shipping_release', p_release_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('release_id', p_release_id, 'label', v_r.label, 'status', 'approved');
END;
$function$
;

-- db/functions/withdraw_shipping_release.sql
-- APR-5b(2026-09-25,grilling Q4):撤回一张在等的发货放行。
-- 谁能撤:提单人本人(按人认 —— self_leg 说这个账号就是提单人那个人),或任何持 action.request_shipping_release
-- 的人。只撤 submitted。撤回记在本行上(谁、何时、为什么),【不】写 approval_log —— 撤回不是一次决定
-- (付款、工资、收货定价、贷项 / 作废申请同一条)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.withdraw_shipping_release(p_release_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r shipping_releases%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM shipping_releases WHERE id = p_release_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_FOUND|%', COALESCE(p_release_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('action.request_shipping_release');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE shipping_releases
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_release_id;
    RETURN jsonb_build_object('release_id', p_release_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$
;

-- db/functions/shipping_release_context.sql
-- APR-5b(2026-09-25,APR-5 grilling Q5 · 5b grilling Q10):CFO 决定一张发货放行时看得见的东西,一次读出。
--
--   · 客户:信用额度、冻结、敞口(customer_ar_exposure_base —— 与开票、直接销售的信用闸同一个数)、余量;
--   · 放行点名的发票:开放余额(order_invoice_open_all.open_base,本位币)与收齐了没有;
--   · 逐行毛利:开票额(发票行 amount_base,本位币)− 这一行预留过的批次的成本
--     (活预留 + 已发货消耗的预留,Σ qty × processing_outputs.unit_cost_base)。
--     ★ 任何一个批次没有成本 → 成本与毛利都是 NULL(屏幕写「未计成本」),【永不】当 0 ——
--       一个 0 成本的毛利是一句关于利润的假话(batch_margin 的同一条理由)。没有预留的行同样 NULL。
--
-- 【门】与 decide_shipping_release 同一对码:module.sales.view + data.view_prices。持这一对码的人
-- (tim@ · Sandra · Choo Er · Phua · Vince · auditor · admin)今天在订单页上本来就看得见这些价格。
-- 属主权限读全量(敞口与开放余额的算子对调用者已收权),在函数体里先按调用者的码把关。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipping_release_context(p_release_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     shipping_releases%ROWTYPE;
    v_order record;
    v_cust  record;
    v_exp   numeric;
BEGIN
    PERFORM require_permission('module.sales.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM shipping_releases WHERE id = p_release_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPPING_RELEASE_NOT_FOUND|%', COALESCE(p_release_id::text, '?');
    END IF;
    SELECT id, code, currency, customer_id INTO v_order FROM sales_orders WHERE id = v_r.sales_order_id;
    SELECT id, code, legal_name, credit_limit_base, credit_hold INTO v_cust
      FROM customers WHERE id = v_order.customer_id;
    v_exp := customer_ar_exposure_base(v_cust.id);

    RETURN jsonb_build_object(
        'release_id', v_r.id,
        'label', v_r.label,
        'status', v_r.status,
        'amount_base', v_r.amount_base,
        'order_code', v_order.code,
        'currency', v_order.currency,
        'customer', jsonb_build_object(
            'code', v_cust.code,
            'legal_name', v_cust.legal_name,
            'credit_limit_base', v_cust.credit_limit_base,
            'credit_hold', v_cust.credit_hold,
            'exposure_base', v_exp,
            'headroom_base', CASE WHEN v_cust.credit_limit_base IS NOT NULL
                                  THEN v_cust.credit_limit_base - v_exp END),
        'invoices', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'code', i.code,
                       'status', i.status,
                       'total_base', i.total_base,
                       'open_base', o.open_base,
                       'paid', COALESCE(o.open_base, 0) <= 0) ORDER BY i.code)
              FROM invoices i
              LEFT JOIN order_invoice_open_all o ON o.invoice_id = i.id
             WHERE i.id IN (SELECT il.invoice_id FROM shipping_release_lines rl
                              JOIN invoice_lines il ON il.id = rl.invoice_line_id
                             WHERE rl.release_id = v_r.id)), '[]'::jsonb),
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'line_no', x.line_no,
                       'material_code', x.material_code,
                       'material_name', x.material_name,
                       'quantity', x.quantity,
                       'unit_price', x.unit_price,
                       'invoice_voided', x.invoice_voided,
                       'invoiced_base', x.invoiced_base,
                       'costed', x.costed,
                       'cost_base', CASE WHEN x.costed THEN x.cost_base END,
                       'margin_base', CASE WHEN x.costed THEN x.invoiced_base - x.cost_base END,
                       'margin_pct', CASE WHEN x.costed AND x.invoiced_base <> 0
                                          THEN round((x.invoiced_base - x.cost_base) / x.invoiced_base * 100, 1) END)
                     ORDER BY x.line_no)
              FROM (SELECT sol.line_no, m.code AS material_code, m.name AS material_name,
                           il.quantity, il.unit_price, il.invoice_voided, il.amount_base AS invoiced_base,
                           c.n_res > 0 AND c.n_uncosted = 0 AS costed,
                           c.cost_base
                      FROM shipping_release_lines rl
                      JOIN invoice_lines il ON il.id = rl.invoice_line_id
                      JOIN sales_order_lines sol ON sol.id = rl.sales_order_line_id
                      LEFT JOIN materials m ON m.id = sol.material_id
                      CROSS JOIN LATERAL (
                          SELECT count(*) AS n_res,
                                 count(*) FILTER (WHERE pc.unit_cost_base IS NULL) AS n_uncosted,
                                 round(sum(r.qty * pc.unit_cost_base), 2) AS cost_base
                            FROM sales_order_reservations r
                            LEFT JOIN LATERAL (SELECT po.unit_cost_base FROM processing_outputs po
                                                WHERE po.output_batch_id = r.output_batch_id LIMIT 1) pc ON true
                           WHERE r.sales_order_line_id = sol.id
                             AND r.released_at IS NULL) c
                     WHERE rl.release_id = v_r.id) x), '[]'::jsonb));
END;
$function$
;

-- db/functions/shipping_queue_rows.sql
-- APR-5b(2026-09-25,APR-5 grilling Q7 · 5b grilling Q6):仓库的发货队列 —— 放行过的、还没发完的订单行,
-- 连同能发的预留。【一个价格都没有】。
--
-- 【列,逐列就是 Tim 的裁定】订单编号与日期 · 客户的法定名称(常设决定 3:展示标签随单据走)·
--   ★ 送货地址(Tim 2026-09-25,5b Q6:仓库要它才发得了货 —— 常设决定 3 之下的一条【点名的例外】,
--   除此之外【不带任何别的客户属性】)· 放行时刻 · 行号、物料、单位 · 放行数量、已发、剩余 ·
--   活预留:批次、库位、数量。
--   ★ 没有:单价、币种、汇率、金额、毛利、发票编号、余额、信用额度或冻结(冻结由 ship_order 在发货时
--   按名拒 SO_SHIP_CUSTOMER_ON_HOLD —— 那是一次拒绝,不是一个读得到的属性)。
--   fixture 224 逐字钉住本函数的返回列清单。
--
-- 【哪些行】订单 confirmed / partially_shipped、未删除;这一行坐在一条被 approved 放行点名的在册发票行上
--   (覆盖,与 ship_order 同一句);剩余 = sales_order_line_releasable_all.releasable_qty − 已发 > 0。
--   一行没有活预留时照样出现(预留那几列为 NULL):仓库看得见"放行了但还没备货"。
--
-- 【门】action.ship_goods(warehouse · admin)。仓库不持 module.sales.view(Q7):属主权限读订单、客户与
--   放行,在函数体里先按调用者的码把关 —— 零行永远是"没有要发的",不会是"你看不见"。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipping_queue_rows()
 RETURNS TABLE(sales_order_id uuid, order_code text, order_date date, customer_name text, delivery_address text, released_at timestamp with time zone, sales_order_line_id uuid, line_no integer, material_code text, material_name text, unit text, released_qty numeric, shipped_qty numeric, remaining_qty numeric, reservation_id uuid, output_batch_code text, location_code text, location_name text, reserved_qty numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    PERFORM require_permission('action.ship_goods');

    RETURN QUERY
    WITH lines AS (
        SELECT so.id AS so_id, so.code AS so_code, so.order_date AS so_date,
               c.legal_name AS cust_name, c.address AS cust_address,
               (SELECT max(r.decided_at) FROM shipping_release_lines rl
                  JOIN shipping_releases r ON r.id = rl.release_id
                 WHERE rl.sales_order_line_id = sol.id AND r.status = 'approved') AS rel_at,
               sol.id AS sol_id, sol.line_no AS sol_no, m.code AS m_code, m.name AS m_name, m.unit AS m_unit,
               (SELECT ra.releasable_qty FROM sales_order_line_releasable_all ra
                 WHERE ra.sales_order_line_id = sol.id LIMIT 1) AS rel_qty,
               COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl WHERE sl.sales_order_line_id = sol.id), 0) AS shp_qty
          FROM sales_order_lines sol
          JOIN sales_orders so ON so.id = sol.sales_order_id
          JOIN customers c ON c.id = so.customer_id
          JOIN materials m ON m.id = sol.material_id
         WHERE so.deleted_at IS NULL
           AND so.status IN ('confirmed', 'partially_shipped')
           AND EXISTS (SELECT 1 FROM shipping_release_lines rl
                         JOIN shipping_releases r ON r.id = rl.release_id
                         JOIN invoice_lines il ON il.id = rl.invoice_line_id
                         JOIN invoices i ON i.id = il.invoice_id
                        WHERE rl.sales_order_line_id = sol.id AND r.status = 'approved'
                          AND NOT il.invoice_voided AND i.kind = 'order' AND i.status = 'issued')
    )
    SELECT l.so_id, l.so_code, l.so_date, l.cust_name, l.cust_address, l.rel_at,
           l.sol_id, l.sol_no, l.m_code, l.m_name, l.m_unit,
           l.rel_qty, l.shp_qty, l.rel_qty - l.shp_qty,
           res.id, ob.code, loc.code, loc.name, res.qty
      FROM lines l
      LEFT JOIN sales_order_reservations res
             ON res.sales_order_line_id = l.sol_id AND res.released_at IS NULL AND res.consumed_at IS NULL
      LEFT JOIN output_batches ob ON ob.id = res.output_batch_id
      LEFT JOIN storage_locations loc ON loc.id = res.location_id
     WHERE l.rel_qty - l.shp_qty > 0
     ORDER BY l.rel_at, l.so_code, l.sol_no, ob.code;
END;
$function$
;

-- db/functions/shipment_document.sql
-- APR-5b(2026-09-25,5b grilling Q7):一张发货单要印的东西 —— 表头(发货单号、日期、订单编号、客户编号与
-- 法定名称)与行(数量、批次、单位、物料、废物分类、发货时的库位)。发货单页与发货单 PDF 都读它。
--
-- 【为什么是一支属主权限的读者】发货单此前经内嵌读 sales_orders 与 customers(RLS:module.sales.view /
-- module.customers.view)与 materials(module.materials.view);仓库三个都不持(Q7:不给仓库 sales.view),
-- 于是它发得了货、印不出它刚发的那张单。这里读全量,先按调用者的码把关。
-- 【没有价格】发货单本来就不带价(发货单行没有价格列);客户只给编号与法定名称(常设决定 3 的展示标签)。
-- 【门】module.sales.view 或 action.ship_goods —— 与三张发货表的读策略同一对码。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipment_document(p_shipment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s record;
BEGIN
    IF NOT has_any_permission(ARRAY['module.sales.view', 'action.ship_goods']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.ship_goods';
    END IF;

    SELECT s.id, s.code, s.ship_date, s.created_at, so.id AS order_id, so.code AS order_code,
           c.code AS customer_code, c.legal_name AS customer_name
      INTO v_s
      FROM shipments s
      JOIN sales_orders so ON so.id = s.sales_order_id
      LEFT JOIN customers c ON c.id = so.customer_id
     WHERE s.id = p_shipment_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
        'id', v_s.id,
        'code', v_s.code,
        'ship_date', v_s.ship_date,
        'created_at', v_s.created_at,
        'order_id', v_s.order_id,
        'order_code', v_s.order_code,
        'customer_code', v_s.customer_code,
        'customer_name', v_s.customer_name,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', sl.id,
                       'qty', sl.qty,
                       'line_no', sol.line_no,
                       'batch_code', ob.code,
                       'unit', ob.unit,
                       'material_code', m.code,
                       'material_name', m.name,
                       'waste_classification_code', m.waste_classification_code,
                       'location_code', loc.code,
                       'location_name', loc.name) ORDER BY sl.created_at, sol.line_no)
              FROM shipment_lines sl
              JOIN sales_order_lines sol ON sol.id = sl.sales_order_line_id
              JOIN output_batches ob ON ob.id = sl.output_batch_id
              LEFT JOIN materials m ON m.id = ob.material_id
              LEFT JOIN storage_locations loc ON loc.id = sl.location_id
             WHERE sl.shipment_id = v_s.id), '[]'::jsonb));
END;
$function$
;

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
    v_cust     record;
    v_ceiling  numeric;
    v_taken    jsonb := '{}'::jsonb;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ APR-5b(Tim 2026-09-25,APR-5 grilling Q7):【发货归仓库,在 CFO 放行之后】
    -- 门从 module.sales.edit 换成 action.ship_goods(warehouse · admin);cco 从此不发货。
    -- 此前这里写着"发货就是一次销售行为,做它的人是销售" —— Tim 的矩阵把它劈成两半:
    -- 【答应卖】(订单、预留、提放行)仍是销售的;【把货交出去】是仓库的,而且要 CFO 先放行。
    -- 部分发货的拆分改调 release_reservation_internal(不问码)—— 仓库不持 module.sales.edit。
    -- 台账的不变量仍不依赖调用者是谁:check_no_negative_bucket 与 check_ledger_invariant
    -- 都是约束触发器,对任何身份一视同仁。
    --
    -- 【收入与 COGS 的过账也在这里,而它们是财务的事】—— 但把这一步拆成
    -- "发货 + 财务过账"两次调用,就等于允许一个【发了货却没记收入】的
    -- 中间态存在。选项 C 的整条链是一个事务,所以它是一个函数。
    -- ★ APR-5b(5b grilling Q5):所以按发货的人【看不见】他触发的那笔收入 —— 返回值里不再有
    --   任何金额、币种或汇率(只剩发货单号、日期、行数、订单状态与收入分录的编号)。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM require_permission('action.ship_goods');

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

    -- ★ APR-5 grilling Q6:【发货那一刻】客户在冻结上 → 按名拒。放行时不冻结不算数 ——
    --   CFO 放行之后客户被冻结,货就不该再离场。放行本身不失效(5b Q4:只有作废让放行失效),
    --   解冻之后照原放行发。
    SELECT c.code, c.credit_hold INTO v_cust FROM customers c WHERE c.id = v_order.customer_id;
    IF v_cust.credit_hold THEN
        RAISE EXCEPTION 'SO_SHIP_CUSTOMER_ON_HOLD|%|%', v_order.code, v_cust.code;
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
        SELECT i.id, i.code, i.fx_rate, i.currency, il.id AS invoice_line_id
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
        -- ★ APR-5b(APR-5 grilling Q3 · 5b Q2):【这条发票行被一张 approved 的放行点了名】
        -- 覆盖是现算的:上面那一句已经要求发票行 NOT invoice_voided,所以作废过的发票
        -- 自己就不再被覆盖 —— 没有任何东西要去改放行。放行之后加的行要它自己的放行。
        -- ════════════════════════════════════════════════════════════════════
        IF NOT EXISTS (SELECT 1 FROM shipping_release_lines rl
                         JOIN shipping_releases r ON r.id = rl.release_id
                        WHERE rl.invoice_line_id = v_inv.invoice_line_id AND r.status = 'approved') THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_RELEASED|%|%', v_order.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★ APR-5 grilling Q8 · 5b Q1:【天花板 = 开票数量 − Σ 未发货取消贷项的数量 − 已发】
        -- 取消掉的那一截已经从应收里拿走了(贷项借 2500),再把它发出去就是白送。
        -- 开票 − 取消的那一半只有一处推导:sales_order_line_releasable_all(发货队列与仪表盘读同一张)。
        -- 同一次调用里发过的同一行累计进去(v_taken)。
        -- 超出的那一截预留【不】自动释放:按名拒,由销售释放(5b Q1)。
        -- ════════════════════════════════════════════════════════════════════
        IF (v_item->>'qty') IS NOT NULL
           AND ((v_item->>'qty')::numeric <= 0 OR (v_item->>'qty')::numeric > v_res.qty) THEN
            RAISE EXCEPTION 'SO_SHIP_EXCEEDS_RESERVATION|%|%', v_item->>'qty', v_res.qty;
        END IF;
        v_ceiling := (SELECT ra.releasable_qty FROM sales_order_line_releasable_all ra
                       WHERE ra.invoice_line_id = v_inv.invoice_line_id)
                   - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                                WHERE sl.sales_order_line_id = v_res.sales_order_line_id), 0)
                   - COALESCE((v_taken->>(v_res.sales_order_line_id::text))::numeric, 0);
        IF COALESCE((v_item->>'qty')::numeric, v_res.qty) > v_ceiling THEN
            RAISE EXCEPTION 'SO_SHIP_EXCEEDS_RELEASABLE|%|%|%|%', v_order.code, v_res.line_no,
                trim_scale(COALESCE((v_item->>'qty')::numeric, v_res.qty)), trim_scale(GREATEST(v_ceiling, 0));
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
            v_split := release_reservation_internal(v_res.id, v_res.qty - (v_item->>'qty')::numeric,
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
        v_taken := jsonb_set(v_taken, ARRAY[v_res.sales_order_line_id::text],
            to_jsonb(COALESCE((v_taken->>(v_res.sales_order_line_id::text))::numeric, 0) + v_res.qty));
    END LOOP;

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

    -- ★ APR-5b(5b grilling Q5):发货的人是仓库,仓库看不见销售金额 —— 返回值里没有钱。
    --   收入分录的【编号】留着(它是一个编号,不是一个数;fixture 68 照它找分录)。
    RETURN jsonb_build_object(
        'shipment_id', v_ship_id,
        'code', v_code,
        'ship_date', p_ship_date,
        'line_count', v_n,
        'order_status', v_status,
        'revenue_journal', v_je1->>'code');
END;
$function$

;

-- ─── record_shipment_issue
CREATE OR REPLACE FUNCTION public.record_shipment_issue(p_shipment_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ship shipments%ROWTYPE;
    v_next integer;
BEGIN
    -- ★ APR-5b(Tim 2026-09-25,APR-5 grilling Q7):开具发货单归发货的人 —— action.ship_goods
    --   (warehouse · admin);cco 从此不发货,也不开发货单。
    PERFORM require_permission('action.ship_goods');

    SELECT * INTO v_ship FROM shipments WHERE id = p_shipment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SHIPMENT_NOT_FOUND|%', COALESCE(p_shipment_id::text, '?');
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('shipment_issue_' || p_shipment_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM shipment_issues WHERE shipment_id = p_shipment_id;

    INSERT INTO shipment_issues (shipment_id, version, file_path, sha256, issued_by)
    VALUES (p_shipment_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('version', v_next);
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
    v_uc    record;
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
        -- ★ APR-5b(grilling Q1):【未发货取消要说出取消了多少数量】—— 发货的天花板是
        --   开票数量 − Σ 取消的数量 − 已发(ship_order,SO_SHIP_EXCEEDS_RELEASABLE),
        --   而贷项此前只按金额记、数量可空。所以提交时:每一条 unshipped_cancel 必须带 qty > 0,
        --   按发票行合计不许超过 开票数量 − 已发 − 以前取消过的数量(以前没带数量的按 金额 ÷ 单价 折算)。
        --   不属于这张发票的行不在这里判 —— 试跑会按引擎原话拒。
        FOR v_uc IN
            SELECT il.id, il.line_no, il.quantity, il.unit_price, il.sales_order_line_id,
                   bool_or(NULLIF(e->>'qty', '') IS NULL OR (e->>'qty')::numeric <= 0) AS missing,
                   sum(NULLIF(e->>'qty', '')::numeric) AS want
              FROM jsonb_array_elements(p_lines) e
              JOIN invoice_lines il ON il.id = NULLIF(e->>'invoice_line_id', '')::uuid
                                   AND il.invoice_id = v_inv.id
             WHERE e->>'kind' = 'unshipped_cancel'
             GROUP BY il.id, il.line_no, il.quantity, il.unit_price, il.sales_order_line_id
        LOOP
            IF v_uc.missing THEN
                RAISE EXCEPTION 'CN_UNSHIPPED_CANCEL_QTY_REQUIRED|%|%', v_inv.code, v_uc.line_no;
            END IF;
            IF v_uc.want > v_uc.quantity
                 - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                              WHERE sl.sales_order_line_id = v_uc.sales_order_line_id), 0)
                 - COALESCE((SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(v_uc.unit_price, 0)))
                               FROM credit_note_lines cl
                              WHERE cl.invoice_line_id = v_uc.id AND cl.kind = 'unshipped_cancel'), 0) THEN
                RAISE EXCEPTION 'CN_UNSHIPPED_CANCEL_QTY_EXCEEDS|%|%|%|%', v_inv.code, v_uc.line_no,
                    trim_scale(v_uc.want),
                    trim_scale(GREATEST(v_uc.quantity
                        - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                                     WHERE sl.sales_order_line_id = v_uc.sales_order_line_id), 0)
                        - COALESCE((SELECT sum(COALESCE(cl.qty, cl.amount / NULLIF(v_uc.unit_price, 0)))
                                      FROM credit_note_lines cl
                                     WHERE cl.invoice_line_id = v_uc.id AND cl.kind = 'unshipped_cancel'), 0), 0));
            END IF;
        END LOOP;
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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废四种申请与发货放行 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

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
            ARRAY['module.sales.view', 'data.view_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- ── 7 · 发货三张表:读策略放宽到 module.sales.view 或 action.ship_goods(5b Q7)──────
DROP POLICY "shipments select by permission" ON public.shipments;
CREATE POLICY "shipments select by permission" ON public.shipments
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.sales.view'::text) OR has_permission('action.ship_goods'::text)));
DROP POLICY "shipment_lines select by permission" ON public.shipment_lines;
CREATE POLICY "shipment_lines select by permission" ON public.shipment_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.sales.view'::text) OR has_permission('action.ship_goods'::text)));
DROP POLICY "shipment_issues select by permission" ON public.shipment_issues;
CREATE POLICY "shipment_issues select by permission" ON public.shipment_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.sales.view'::text) OR has_permission('action.ship_goods'::text)));

-- ── 8 · operations_now:加两支 shipping_release_pending · shipping_release_ready(镜像原样)──
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

-- ── 9 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.a5b_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE a5b_pending_after ON COMMIT DROP AS
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
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 裁定的那四行(不多、不少、不收回任何一行)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM a5b_grants_before
                 UNION SELECT unnest(ARRAY['cco:action.request_shipping_release', 'admin:action.request_shipping_release', 'warehouse:action.ship_goods', 'admin:action.ship_goods'])))
        UNION ALL
        ((SELECT role_code || ':' || permission_code FROM a5b_grants_before
          UNION SELECT unnest(ARRAY['cco:action.request_shipping_release', 'admin:action.request_shipping_release', 'warehouse:action.ship_goods', 'admin:action.ship_goods']))
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR5B_PROOF|grants differ from before + ruled: %', v_bad; END IF;
    IF (SELECT string_agg(r.code, ' ' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.request_shipping_release') IS DISTINCT FROM 'admin cco'
       OR (SELECT string_agg(r.code, ' ' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.ship_goods') IS DISTINCT FROM 'admin warehouse' THEN
        RAISE EXCEPTION 'APR5B_PROOF|new code holders are not exactly the ruled roles';
    END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5B_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;两张新表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a5b_pending_before b EXCEPT SELECT a.k, a.id FROM a5b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a5b_pending_after a EXCEPT SELECT b.k, b.id FROM a5b_pending_before b)) THEN
        RAISE EXCEPTION 'APR5B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a5b_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM shipment_lines) AS shipment_lines,
       (SELECT count(*) FROM shipment_issues) AS shipment_issues,
       (SELECT count(*) FROM sales_order_reservations) AS reservations,
       (SELECT count(*) FROM sales_order_reservations WHERE released_at IS NULL AND consumed_at IS NULL) AS reservations_live,
       (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM sales_orders) AS sales_orders,
       (SELECT count(*) FROM invoices) AS invoices,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM invoice_requests) AS invoice_requests) n) THEN
        RAISE EXCEPTION 'APR5B_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM a5b_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM shipment_lines) AS shipment_lines,
       (SELECT count(*) FROM shipment_issues) AS shipment_issues,
       (SELECT count(*) FROM sales_order_reservations) AS reservations,
       (SELECT count(*) FROM sales_order_reservations WHERE released_at IS NULL AND consumed_at IS NULL) AS reservations_live,
       (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM sales_orders) AS sales_orders,
       (SELECT count(*) FROM invoices) AS invoices,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM invoice_requests) AS invoice_requests) n);
    END IF;
    IF EXISTS (SELECT 1 FROM shipping_releases) OR EXISTS (SELECT 1 FROM shipping_release_lines) THEN
        RAISE EXCEPTION 'APR5B_PROOF|the release tables are not empty';
    END IF;

    -- ④ 结构:两扇门换了码;三条发货读策略放宽;名册一行、只有二级
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.ship_order(uuid, date, jsonb)'::regprocedure)
         NOT LIKE '%require_permission(''action.ship_goods'')%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.ship_order(uuid, date, jsonb)'::regprocedure)
         LIKE '%require_permission(''module.sales.edit'')%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.record_shipment_issue(uuid, text, text)'::regprocedure)
         NOT LIKE '%require_permission(''action.ship_goods'')%' THEN
        RAISE EXCEPTION 'APR5B_PROOF|ship_order / record_shipment_issue are not gated on action.ship_goods alone';
    END IF;
    SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'public'
       AND tablename IN ('shipments', 'shipment_lines', 'shipment_issues') AND cmd = 'SELECT'
       AND qual LIKE '%module.sales.view%' AND qual LIKE '%action.ship_goods%';
    IF v_n <> 3 THEN RAISE EXCEPTION 'APR5B_PROOF|expected 3 widened shipment read policies, got %', v_n; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'shipping_release')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR5B_PROOF|shipping_release chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('shipping_release', 'decide_shipping_release', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR5B_PROOF|nobody can decide a shipping release'; END IF;
    RAISE NOTICE 'APR5B deciders for shipping_release: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a5b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR5B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a5b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR5B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a5b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a5b_pending_decider_check(boolean);

COMMIT;

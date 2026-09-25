-- db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql
-- APR-7 —— 注销批次、加工回滚、作废销毁证书:仓库提,CFO 批每一张,批准之前什么都不发生
-- (docs/role-matrix.md「删除批次 · 加工回滚 · 作废销毁证书 | 仓库提 | CFO」)。
-- 由 db/scripts/build_apr7_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-7 grilling Q1–Q9,Tim 2026-09-25 全部接受)
--   ① 哪些注销要经 CFO(Q1):还有料(计价与否)、或进料批挂着已签发的销毁证书。空批照旧由仓库一步删
--      (batch_write_off_needs_request 一份判据)。
--   ② 一张表 warehouse_requests,四种(Q2):write_off_inbound · write_off_output · rollback · cod_void;
--      submitted → approved(当场生效)· rejected(要理由)· withdrawn。提交按同一条路试跑。
--      审批关着时生下来就是 approved 并当场生效(auto_approved)。
--   ③ 冻结(Q3):注销的那一批、回滚那张单的产出批上任何库存流水按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH;
--      进料批上不许新开定价申请;一个批次、它的证书、消耗它的加工单同一时刻只挂一张在等的申请。
--   ④ 批准那一天生效、按那一刻的活数计价;欠款在提交时与批准时各查一遍(Q4)。
--   ⑤ 已锁期间里的加工单照旧可以回滚;CFO 那一块先说出来(Q5,snapshot.locked_period · cods_voided)。
--   ⑥ deleted_by / voided_by = 提单人(Q6);void_cod_internal 加一个参数 p_voided_by。
--   ⑦ 旧门(Q7):rollback_processing_run 与 void_cod 一张都不做,按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST;
--      soft_delete_inbound_batch / soft_delete_output_batch 只剩空批。函数体搬进 *_internal(收回 EXECUTE)。
--   ⑧ 引擎登记(Q8):approval_chain_gates 一行(二级,module.finance.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2);approval_log 的主体类型与读策略;
--      record_approval_decision 一支;operations_now 一支 warehouse_request_pending。
--   ⑨ 自证里"每一张在途单据都有一个不是它自己当事人的决定人"扩到每一条申请链(Q9)。
--
-- 【不做什么】不新增任何权限码(Q8),所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一条没变;在途单据一张不少、一张不多;
-- approval_log、分录、流水、被删批次、回滚过的加工单、证书状态一行没变;申请表是空的;申请表没有写策略;
-- 内层算子 authenticated 调不到;旧的回滚 / 作废门只会拒;两支冻结守卫挂上;新链有人批得了;
-- 每一张在途单据(连同每一条申请链)都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR7_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.warehouse_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR7_PRE|warehouse_requests already exists';
    END IF;
    IF to_regprocedure('public.void_cod_internal(uuid, text, uuid)') IS NULL THEN
        RAISE EXCEPTION 'APR7_PRE|void_cod_internal(uuid, text, uuid) is not there to replace';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.finance.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR7_PRE|cfo does not hold both gate codes';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a7_pending_before ON COMMIT DROP AS
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
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted';
CREATE TEMP TABLE a7_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM inventory_movements) AS movements,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS inbound_deleted,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS output_deleted,
       (SELECT count(*) FROM processing_runs WHERE deleted_at IS NOT NULL) AS runs_deleted,
       (SELECT string_agg(status || ':' || n, ' ' ORDER BY status)
          FROM (SELECT status, count(*) AS n FROM certificates_of_destruction GROUP BY status) c) AS cods;
CREATE TEMP TABLE a7_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · warehouse_requests(镜像原样)────────────────────────────────────────
CREATE TABLE public.warehouse_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind               text NOT NULL
        CHECK (kind IN ('write_off_inbound', 'write_off_output', 'rollback', 'cod_void')),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    -- ── 主体:恰好一列 ─────────────────────────────────────────────────────
    inbound_batch_id   uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id    uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    run_id             uuid REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    cod_id             uuid REFERENCES public.certificates_of_destruction (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- 提单人的理由:原样成为 delete_reason / 回滚理由 / void_reason
    reason             text NOT NULL CHECK (btrim(reason) <> ''),
    snapshot           jsonb NOT NULL,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base        numeric NOT NULL CHECK (amount_base >= 0),
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    -- 批准当场生效:生效的时刻,与过出来的分录(没有计价的注销、证书作废:空数组)
    executed_at        timestamptz,
    result_entry_ids   uuid[] NOT NULL DEFAULT '{}'::uuid[],
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT warehouse_requests_kind_shape CHECK (
        (kind = 'write_off_inbound') = (inbound_batch_id IS NOT NULL)
        AND (kind = 'write_off_output') = (output_batch_id IS NOT NULL)
        AND (kind = 'rollback') = (run_id IS NOT NULL)
        AND (kind = 'cod_void') = (cod_id IS NOT NULL)),
    -- 恰好一个主体 —— 与 kind_shape 同一件事的另一种写法,留着它是给关系图读的:document_relations 按
    -- num_nonnulls(...) = 1 认出"这四列同一行上只有一列",于是不会把本表读成批次 ↔ 加工单 ↔ 证书之间的桥
    -- (fixture 103 A 臂)。
    CONSTRAINT warehouse_requests_one_subject CHECK (num_nonnulls(inbound_batch_id, output_batch_id, run_id, cod_id) = 1),
    CONSTRAINT warehouse_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT warehouse_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT warehouse_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT warehouse_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.warehouse_requests IS
    'APR-7:注销批次(write_off_inbound / write_off_output)、加工回滚(rollback)、作废销毁证书(cod_void)的申请 —— 仓库提,CFO 批每一张,不分档,批准当场生效。submitted → approved(CFO)· rejected(要理由)· withdrawn(提单人本人或该种类的码)。审批关着时生下来就是 approved 并当场生效(auto_approved)。在等的时候:主体批次上的任何库存流水按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH;一个批次、它的证书、消耗它的加工单同一时刻只挂一张在等的申请(WAREHOUSE_REQUEST_OPEN)。空批(没有料也没有已签发证书)不经这里。';

COMMENT ON COLUMN public.warehouse_requests.amount_base IS
    'APR-7:本位币 = 生效时过出来那几张分录的借方合计。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账额(写进 approved 留痕)。没有计价的注销与证书作废是 0 —— 它们不动价值。';

COMMENT ON COLUMN public.warehouse_requests.snapshot IS
    'APR-7(grilling Q8):提交时冻下来给 CFO 读的那一组 —— 批号、物料、供应商、数量、加工日、是否落在已锁期间、会被一并作废的证书号。CFO 读不到证书表(它的读策略是 action.issue_cod),所以要在这里。【不含金额】—— 金额在 amount_base,经 warehouse_requests_visible() 对没有 data.view_prices 的读者给 NULL。';

CREATE UNIQUE INDEX warehouse_requests_one_open_inbound
    ON public.warehouse_requests (inbound_batch_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX warehouse_requests_one_open_output
    ON public.warehouse_requests (output_batch_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX warehouse_requests_one_open_run
    ON public.warehouse_requests (run_id) WHERE status = 'submitted';
CREATE UNIQUE INDEX warehouse_requests_one_open_cod
    ON public.warehouse_requests (cod_id) WHERE status = 'submitted';
CREATE INDEX warehouse_requests_open ON public.warehouse_requests (kind) WHERE status = 'submitted';
CREATE INDEX warehouse_requests_inbound_batch_id_rel ON public.warehouse_requests (inbound_batch_id);
CREATE INDEX warehouse_requests_output_batch_id_rel ON public.warehouse_requests (output_batch_id);
CREATE INDEX warehouse_requests_run_id_rel ON public.warehouse_requests (run_id);
CREATE INDEX warehouse_requests_cod_id_rel ON public.warehouse_requests (cod_id);

ALTER TABLE public.warehouse_requests ENABLE ROW LEVEL SECURITY;

-- 读:凭证页那一个码(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。屏幕不直接读本表,
-- 读 warehouse_requests_visible()(仓库看得见自己的申请,金额按 data.view_prices 给)。写:一条策略都不给 ——
-- 只经 submit_* · decide_warehouse_request · withdraw_warehouse_request(全是 SECURITY DEFINER)。
CREATE POLICY "warehouse_requests select by permission" ON public.warehouse_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.warehouse_requests FROM anon;

-- ── 2 · approval_log:主体类型加 warehouse_request;读策略加同名一支 ────────────
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
                            'warehouse_request'));
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
            ELSE false
        END
    );

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────
-- void_cod_internal 多了一个参数 p_voided_by(Q6):换签名,旧的那一支先拿掉
DROP FUNCTION public.void_cod_internal(uuid, text, uuid);

-- ─── void_cod_internal
CREATE OR REPLACE FUNCTION public.void_cod_internal(p_cod_id uuid, p_reason text, p_replaced_by uuid DEFAULT NULL::uuid, p_voided_by uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- ★ APR-7:p_voided_by —— CFO 批准的作废申请记【提单人】(grilling Q6);不给 = 调用者本人
    --   (refresh_cod_for_batch 的自动作废:批准那张注销 / 回滚的人)。
    -- 【作废【不动】字节档案与快照一个字】—— 供应商手里那张纸仍然查得到、
    -- 仍然对得上哈希。与 invoice_issues 在作废后原样保留同一条。
    UPDATE certificates_of_destruction
       SET status = 'void', void_reason = p_reason,
           voided_at = clock_timestamp(), voided_by = COALESCE(p_voided_by, auth.uid()),
           replaced_by_cod_id = p_replaced_by
     WHERE id = p_cod_id AND status = 'issued';
END;
$function$;

-- db/functions/soft_delete_inbound_batch_internal.sql
-- APR-7(2026-09-25):注销一张进料批 —— ROLE-1 Batch 3b 的 soft_delete_inbound_batch 的函数体原样搬进来,
-- 只拿掉了码的检查、加了 p_deleted_by(grilling Q6:deleted_by = 提单人;不给 = 调用者本人)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch_internal(p_batch_id uuid, p_reason text, p_deleted_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := COALESCE(p_deleted_by, auth.uid());
    v_code text;
    v_open numeric;
BEGIN
    -- ★ APR-7:本支是注销那一步【本身】,不问码 —— EXECUTE 已从 authenticated 收回。两个调用者:
    --   soft_delete_inbound_batch(空批一步删,门 action.batch_write_off)与
    --   warehouse_request_execute_internal(CFO 批准的注销申请,deleted_by = 提单人,grilling Q6)。
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
    --   【读基表,不读 ap_open_items】本函数的调用者是仓库一侧(action.batch_write_off,ROLE-1 Batch 3b 之前是 inbound.edit);那张视图对没有
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

-- db/functions/soft_delete_output_batch_internal.sql
-- APR-7(2026-09-25):注销一张产出批 —— ROLE-1 Batch 3b 的 soft_delete_output_batch 的函数体原样搬进来,
-- 只拿掉了码的检查、加了 p_deleted_by(grilling Q6:deleted_by = 提单人;不给 = 调用者本人)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.soft_delete_output_batch_internal(p_batch_id uuid, p_reason text, p_deleted_by uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := COALESCE(p_deleted_by, auth.uid());
    v_code text;
BEGIN
    -- ★ APR-7:本支是注销那一步【本身】,不问码 —— 调用者见 soft_delete_inbound_batch_internal 同一句。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|output_batches|%',
            COALESCE((SELECT code FROM output_batches WHERE id = p_batch_id), '?');
    END IF;

    SELECT code INTO v_code FROM output_batches
     WHERE id = p_batch_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;

    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
       SET deleted_at = now(), deleted_by = v_user, delete_reason = btrim(p_reason),
           updated_by = v_user, updated_at = now()
     WHERE id = p_batch_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);

    RETURN jsonb_build_object('id', p_batch_id, 'code', v_code, 'deleted_by', v_user);
END;
$function$;

-- db/functions/rollback_processing_run_internal.sql
-- APR-7(2026-09-25):回滚一张加工单 —— ROLE-1 Batch 3b 的 rollback_processing_run 的函数体原样搬进来,
-- 只拿掉了码的检查、加了 p_deleted_by(grilling Q6:产出批与加工单的 deleted_by、还原流水的 created_by =
-- 提单人;不给 = 调用者本人)。冲销分录的 created_by 是调用者(批准的 CFO)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.rollback_processing_run_internal(p_run_id uuid, p_reason text, p_deleted_by uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := COALESCE(p_deleted_by, auth.uid());
    v_run_deleted_at timestamptz;
    v_process_date date;     -- FIN-32:还原流水的业务日 = 原加工单的加工日
    v_bad_output record;
    v_input record;
    v_old_remaining numeric;
    v_new_remaining numeric;
    v_quantity numeric;
    v_cap uuid;             -- 首挂的资本化分录
    v_delta_id uuid;        -- PROC-COST-2:重分摊的差额分录,逐张
    v_code text;
BEGIN
    -- ★ APR-7:本支是回滚那一步【本身】,不问码 —— EXECUTE 已从 authenticated 收回。唯一的调用者是
    --   warehouse_request_execute_internal(CFO 批准的回滚申请;deleted_by = 提单人,grilling Q6)。
    -- AUDEL-1b:【理由必填】回滚一张加工单是一次很大的操作动作 —— 它软删产出批、
    -- 还原投入、写一整串冲销流水 —— 而此前它【一个 why 都不记】。
    -- 校验放在任何写之前:被拒 = 什么都没发生。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ROLLBACK_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
    END IF;
    -- 1. 锁定加工单，校验存在且未删除
    SELECT process_date INTO v_process_date FROM processing_runs WHERE id = p_run_id;
    SELECT deleted_at INTO v_run_deleted_at
    FROM processing_runs
    WHERE id = p_run_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;

    IF v_run_deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'RUN_ALREADY_DELETED';
    END IF;

    -- 标记本次为回滚上下文,供产出批次软删触发器发出 reversal_void。
    PERFORM set_config('evoltrya.movement_ctx', 'reversal:' || p_run_id::text, true);

    -- 2. 安全检查：任何一个产出批次动过就拒绝
    SELECT ob.code, ob.state, ob.quantity, ob.remaining_qty
    INTO v_bad_output
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id
      AND ob.deleted_at IS NULL
      AND (ob.state <> '库存中' OR ob.remaining_qty <> ob.quantity)
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'OUTPUT_CONSUMED|%|%|%|%',
            v_bad_output.code, v_bad_output.state, v_bad_output.remaining_qty, v_bad_output.quantity;
    END IF;

    -- 3. 还原进料：加回 remaining_qty，重判 stage，记 reversal_restore 流水。
    --    FIN-25:产出批投料同样还原(不碰 state —— 那是销售状态)。
    FOR v_input IN
        SELECT pi.inbound_batch_id, pi.output_batch_id, pi.quantity_consumed
        FROM processing_inputs pi
        WHERE pi.run_id = p_run_id
    LOOP
        IF v_input.inbound_batch_id IS NOT NULL THEN
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM inbound_batches
            WHERE id = v_input.inbound_batch_id
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 进料批次已被删，跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE inbound_batches
            SET remaining_qty = v_new_remaining,
                stage = CASE WHEN v_new_remaining >= v_quantity THEN '待加工' ELSE '加工中' END,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.inbound_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:还原不是物理事件,是在更正一次记错的加工单 —— 业务日取
                -- 【原加工单的 process_date】,于是消耗与还原在同一天对消,
                -- 中间那几天的库存历史不会凭空少掉一批实际还在的货。
                --
                -- 【IOD-1:逐行镜像原始流水,不按规则重新分配】投料现在可能跨几个
                -- 库位桶写出多行;还原必须把货放回【它原来所在的那些桶】,而不是
                -- 按 drain 的顺序倒着来一遍 —— 那两者在一般情形下并不相等,
                -- 差额会安静地把库存挪到别的库位上。所以这里读原始的
                -- processing_consume 行,逐行取反。
                PERFORM mirror_consume_restore(p_run_id, v_input.inbound_batch_id, NULL,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        ELSE
            SELECT quantity, remaining_qty INTO v_quantity, v_old_remaining
            FROM output_batches
            WHERE id = v_input.output_batch_id AND deleted_at IS NULL
            FOR UPDATE;

            IF NOT FOUND THEN
                CONTINUE;  -- 上游产出批已被删（如其自身加工单已冲销），跳过
            END IF;

            v_new_remaining := LEAST(
                COALESCE(v_old_remaining, 0) + v_input.quantity_consumed,
                v_quantity
            );

            UPDATE output_batches
            SET remaining_qty = v_new_remaining,
                updated_by = v_user_id,
                updated_at = now()
            WHERE id = v_input.output_batch_id;

            IF v_new_remaining - COALESCE(v_old_remaining, 0) > 0 THEN
                -- FIN-32:同上 —— 产出批投料的还原(FIN-25 那条边)业务日一样取原加工日
                PERFORM mirror_consume_restore(p_run_id, NULL, v_input.output_batch_id,
                                                 v_new_remaining - COALESCE(v_old_remaining, 0),
                                                 v_process_date, v_user_id);
            END IF;
        END IF;
    END LOOP;

    -- 4. 软删这张单生成的产出批次(void 流水 + 归零由 BEFORE UPDATE 触发器处理)
    -- AUDEL-1b:软删要走门 —— 标记 + deleted_by + delete_reason,否则
    -- guard_soft_delete_provenance 会按名拒。产出批的删除理由【就是这次回滚的
    -- 理由】:它们不是被单独注销的,是被这次回滚带走的。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE output_batches
    SET deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id IN (
        SELECT output_batch_id FROM processing_outputs WHERE run_id = p_run_id
    )
    AND deleted_at IS NULL;

    -- 5. 软删加工单本身（腿表保留作审计）
    UPDATE processing_runs
    SET status = 'reversed',
        deleted_at = now(),
        deleted_by = v_user_id,
        delete_reason = btrim(p_reason),
        updated_by = v_user_id,
        updated_at = now()
    WHERE id = p_run_id;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);   -- 用毕即清(同 movement_ctx)

    -- ════════════════════════════════════════════════════════════════════════
    -- 【解除资本化 —— 台账与分录在同一个地方一起解除】(PROC-COST-1 立,
    --   PROC-COST-2 把工序种类的判断【拿掉】)
    --
    -- 台账那一半由基函数按本单的 deleted_at 自动排除(形状免费提供的);
    -- 分录那一半必须显式冲销 —— 两半都在这里发生,所以它们永远不会各说各话。
    -- 少做任何一半:要么成本留在存货上而单已经没了(账挂在一张不存在的单上),
    -- 要么台账清了而存货虚高。
    --
    -- ★【PROC-COST-2:这里原来有一句 `IF v_sc_kind`,只管状态改变型】★
    -- 于是**转化型加工单回滚之后,它的资本化分录(借 1220 / 贷 1200 / 贷 5xxx)
    -- 原样立着** —— 产出批已经被软删,1220 上却还挂着它的成本。
    -- 那个判断本刀【拿掉】:两种工序共用同一段代码,不是照着它再写一份。
    --   * 状态改变型:冲销 借 1200 / 贷 5xxx,成本从原料批上退回费用;
    --   * 转化型:    冲销 借 1220 / 贷 1200 / 贷 5xxx —— 1220 上的产出成本
    --     被拿掉,而投料的 1200 同时被还回来,与第 3 步还原 remaining_qty 同向。
    --
    -- 【产出批软删【不再】另外入账,这两件事必须一起读】注销触发器在
    -- reversal 上下文里不写分录 —— 因为解除 1220 的是这里冲销的这张分录。
    -- 两处都做就是重复计数。
    --
    -- ★【差额分录也要冲 —— 只补首挂的话,一张被重分摊过的单仍然错】★
    -- 转化型重分摊走的是差额路径:capitalization_entry_id 仍指首挂,新的差额
    -- 分录记在 allocation_snapshot->'delta_entry_ids' 里。只冲首挂,差额留在
    -- 1220 上,而这张单看起来已经修好了 —— 那是最坏的一种半修。
    -- (状态改变型不会有差额分录:它走的是冲旧挂新,capitalization_entry_id
    --  永远指着唯一活着的那一张。这个循环对它自然空转,不需要分支。)
    --
    -- 【第四个候选:sales_records 上的 COGS 分录 —— 不需要任何处置】
    -- 第 2 步的 OUTPUT_CONSUMED 闸在任何产出动过之后就拒绝回滚,而一次销售
    -- 必然动 remaining_qty。**够不到的东西不需要修,但需要被点名**,
    -- 否则下一个读到这里的人会把这条推理重做一遍。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT code, capitalization_entry_id INTO v_code, v_cap
      FROM processing_runs WHERE id = p_run_id;

    IF v_cap IS NOT NULL
       AND (SELECT status FROM journal_entries WHERE id = v_cap) = 'posted' THEN
        PERFORM reverse_journal_entry_internal(v_cap, reversal_date_for(v_cap),  -- AP-RECON-1 Batch B
            'Rollback ' || COALESCE(v_code, '?'));
    END IF;

    FOR v_delta_id IN
        SELECT (jsonb_array_elements_text(
                    COALESCE(pr.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)))::uuid
          FROM processing_runs pr WHERE pr.id = p_run_id
    LOOP
        IF (SELECT status FROM journal_entries WHERE id = v_delta_id) = 'posted' THEN
            PERFORM reverse_journal_entry_internal(v_delta_id, reversal_date_for(v_delta_id),  -- AP-RECON-1 Batch B
                'Rollback ' || COALESCE(v_code, '?'));
        END IF;
    END LOOP;

    UPDATE processing_runs
       SET capitalization_entry_id = NULL, capitalized_cost_base = 0
     WHERE id = p_run_id;

    PERFORM set_config('evoltrya.movement_ctx', '', true);   -- 用毕即清(同 commit)

    -- ── COD-1:冲销之后,这几票货不再是"加工完"的 ────────────────────────
    -- 【已签发的证书在这里作废,而且没有替代品】—— 冲销说的是那次加工没发生。
    -- 不做这一步,供应商手里那张纸就还在说着一件系统已经不再相信的事,
    -- 而没有任何东西会提醒任何人。将来重新加工到完,那时会成立一张新的证书。
    FOR v_input IN
        SELECT DISTINCT pi.inbound_batch_id FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
    LOOP
        PERFORM refresh_cod_for_batch(v_input.inbound_batch_id);
    END LOOP;
END;
$function$;

-- db/functions/batch_write_off_needs_request.sql
-- APR-7(2026-09-25,grilling Q1):注销这一批要不要经 CFO —— 一份判据,三个读它的人
-- (一步删的那扇门 · 提注销申请 · 两张表上的注销按钮)。
--   进料批:还有料(remaining_qty > 0,计价与否都算 —— 库存要动),或者挂着一张【已签发】的销毁证书
--           (注销会把它作废,而那张纸在供应商手里)。
--   产出批:还有料。
--   其余(空批、没有已签发证书)→ false:仓库一步删,它既不动库存也不动价值。
-- 找不到 / 已删 → NULL(调用者按自己的原话拒)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.batch_write_off_needs_request(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_inbound_batch_id IS NOT NULL THEN
            (SELECT ib.remaining_qty > 0
                    OR EXISTS (SELECT 1 FROM certificates_of_destruction c
                                WHERE c.inbound_batch_id = ib.id AND c.status = 'issued')
               FROM inbound_batches ib WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL)
        ELSE
            (SELECT ob.remaining_qty > 0
               FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL)
    END
$function$;

-- db/functions/warehouse_request_touches.sql
-- APR-7(2026-09-25,grilling Q3):一张仓库申请【碰到】哪些东西 —— 一份判据,三个读它的人:
--   提交时的"同一时刻只挂一张"(warehouse_request_conflict)· 一步删空批的那扇门 · 屏幕上"为什么灰掉"。
--   write_off_inbound  那一批('in')+ 它的活证书('cod')
--   write_off_output   那一批('out')
--   rollback           那张单('run')+ 它的产出批('out')+ 它的投料 —— 进料批('in')与产出批投料('out')
--                      + 投料进料批上的活证书('cod')
--   cod_void           那张证书('cod')+ 它的进料批('in')
-- 【现读,不冻结】碰到什么是此刻的事实;冻结(guard_warehouse_request_freeze)保证它在等的时候不变。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_touches(p_kind text, p_subject uuid)
 RETURNS TABLE(t text, id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT 'in'::text, p_subject WHERE p_kind = 'write_off_inbound'
    UNION
    SELECT 'cod', c.id FROM certificates_of_destruction c
     WHERE p_kind = 'write_off_inbound' AND c.inbound_batch_id = p_subject AND c.status <> 'void'
    UNION
    SELECT 'out', p_subject WHERE p_kind = 'write_off_output'
    UNION
    SELECT 'run', p_subject WHERE p_kind = 'rollback'
    UNION
    SELECT 'out', po.output_batch_id FROM processing_outputs po
     WHERE p_kind = 'rollback' AND po.run_id = p_subject
    UNION
    SELECT CASE WHEN pi.inbound_batch_id IS NOT NULL THEN 'in' ELSE 'out' END,
           COALESCE(pi.inbound_batch_id, pi.output_batch_id)
      FROM processing_inputs pi
     WHERE p_kind = 'rollback' AND pi.run_id = p_subject
    UNION
    SELECT 'cod', c.id FROM processing_inputs pi
      JOIN certificates_of_destruction c ON c.inbound_batch_id = pi.inbound_batch_id AND c.status <> 'void'
     WHERE p_kind = 'rollback' AND pi.run_id = p_subject
    UNION
    SELECT 'cod', p_subject WHERE p_kind = 'cod_void'
    UNION
    SELECT 'in', c.inbound_batch_id FROM certificates_of_destruction c
     WHERE p_kind = 'cod_void' AND c.id = p_subject
$function$;

COMMENT ON FUNCTION public.warehouse_request_touches(text, uuid) IS
'APR-7(grilling Q3):一张仓库申请碰到的批次(in / out)、加工单(run)与证书(cod)。一个批次、它的证书、消耗它的加工单同一时刻只许挂一张在等的申请 —— 那条规矩就是"两张申请的这个集合不许相交"。';

-- db/functions/warehouse_request_conflict.sql
-- APR-7(2026-09-25,grilling Q3):与 (p_kind, p_subject) 碰到同一样东西的、在等的那一张仓库申请的 label;
-- 没有 → NULL。提交时按名拒 WAREHOUSE_REQUEST_OPEN,一步删空批的那扇门也问它。
-- 【为什么要跨种类】一张在等的证书作废申请,遇上同一批货的注销或回滚被批准 —— 那一刻证书被自动作废,
-- 作废申请就再也批不出来,挂在那里挡住审批关闭。所以不让它们同时存在。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_conflict(p_kind text, p_subject uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.label
      FROM warehouse_requests r
     WHERE r.status = 'submitted'
       AND EXISTS (
           SELECT 1
             FROM warehouse_request_touches(r.kind, COALESCE(r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id)) a
             JOIN warehouse_request_touches(p_kind, p_subject) b ON b.t = a.t AND b.id = a.id)
     ORDER BY r.created_at
     LIMIT 1
$function$;

-- db/functions/warehouse_request_freezing.sql
-- APR-7(2026-09-25,grilling Q3):此刻冻结着这一批的那一张在等的仓库申请(id 与 label);没有 → 零行。
--   · 进料批:它自己是一张在等的注销申请的主体;
--   · 产出批:它自己是一张在等的注销申请的主体,或者它是一张在等回滚的加工单的产出。
-- 回滚的投料【不】冻结流水(还原是按消耗量加回去的,投料在等待中再被用掉不影响它);投料批不许被删,
-- 由 warehouse_request_conflict 管。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_freezing(p_inbound_batch_id uuid, p_output_batch_id uuid)
 RETURNS TABLE(request_id uuid, label text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT r.id, r.label FROM warehouse_requests r
     WHERE r.status = 'submitted' AND p_inbound_batch_id IS NOT NULL
       AND r.kind = 'write_off_inbound' AND r.inbound_batch_id = p_inbound_batch_id
    UNION ALL
    SELECT r.id, r.label FROM warehouse_requests r
     WHERE r.status = 'submitted' AND p_output_batch_id IS NOT NULL
       AND r.kind = 'write_off_output' AND r.output_batch_id = p_output_batch_id
    UNION ALL
    SELECT r.id, r.label FROM warehouse_requests r
      JOIN processing_outputs po ON po.run_id = r.run_id
     WHERE r.status = 'submitted' AND p_output_batch_id IS NOT NULL
       AND r.kind = 'rollback' AND po.output_batch_id = p_output_batch_id
$function$;

-- db/functions/guard_warehouse_request_freeze.sql
-- APR-7(2026-09-25,grilling Q3):一张在等 CFO 的注销 / 回滚申请,把它的批次【冻住】。
--
--   · inventory_movements BEFORE INSERT(行级):写向一张被冻结批次的任何流水 —— 加工投料、销售、预留、
--     释放、转移、暂扣、盘点调整 —— 按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH|批号|申请。
--     【为什么挂在流水上,不挂在每一支函数上】动库存的函数有几十支,流水只有一张表;漏掉一支就是一扇侧门。
--   · receipt_price_requests BEFORE INSERT:被冻结的进料批上不许再开定价申请(改价会改注销的价值)。
--
-- 【只有执行那张申请的那一次放行】warehouse_request_execute_internal 把 evoltrya.warehouse_request_ctx
-- 设成申请 id;冻结它的正是这一张时,注销 / 回滚自己写的流水放行。别的申请冻着的批次,照拒。
-- SECURITY DEFINER 的调用者(加工提交、发货……)一样被拒 —— 冻结不分是谁写的。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_warehouse_request_freeze()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx   text := COALESCE(current_setting('evoltrya.warehouse_request_ctx', true), '');
    v_in    uuid;
    v_out   uuid;
    v_req   record;
BEGIN
    IF TG_TABLE_NAME = 'inventory_movements' THEN
        v_in := NEW.inbound_batch_id;
        v_out := NEW.output_batch_id;
    ELSE
        v_in := NEW.inbound_batch_id;
    END IF;

    SELECT f.request_id, f.label INTO v_req
      FROM warehouse_request_freezing(v_in, v_out) f
     WHERE f.request_id::text <> v_ctx
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_FREEZES_BATCH|%|%',
            COALESCE((SELECT code FROM inbound_batches WHERE id = v_in),
                     (SELECT code FROM output_batches WHERE id = v_out), '?'),
            v_req.label;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_warehouse_request_freeze() IS
'APR-7(grilling Q3):在等 CFO 的注销 / 回滚申请冻住它的批次 —— 写向那一批的任何库存流水、进料批上新开的定价申请,按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH|批号|申请。只有执行那张申请本身(evoltrya.warehouse_request_ctx = 申请 id)放行。';

-- db/functions/warehouse_request_snapshot.sql
-- APR-7(2026-09-25,grilling Q5 · Q8):提交时冻给 CFO 读的那一组。CFO 不持 action.issue_cod,读不到证书表 ——
-- 所以"这会作废哪一张证书"要在这里说出来;回滚的加工日是否落在已锁期间(finance_settings.locked_before)
-- 也在这里说出来(Q5:准许,但批之前要看得见)。【不含金额】—— 金额在 amount_base,按 data.view_prices 给。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_snapshot(p_kind text, p_subject uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE p_kind
    WHEN 'write_off_inbound' THEN (
        SELECT jsonb_build_object(
            'batch_code', ib.code, 'material_code', m.code, 'material_name', m.name,
            'supplier_name', COALESCE(s.short_name, s.legal_name), 'remaining_qty', ib.remaining_qty,
            'quantity', ib.quantity, 'unit', ib.unit, 'priced', ib.unit_price IS NOT NULL,
            'cods_voided', COALESCE((SELECT jsonb_agg(c.code ORDER BY c.code) FROM certificates_of_destruction c
                                      WHERE c.inbound_batch_id = ib.id AND c.status = 'issued'), '[]'::jsonb))
          FROM inbound_batches ib
          LEFT JOIN materials m ON m.id = ib.material_id
          LEFT JOIN suppliers s ON s.id = ib.supplier_id
         WHERE ib.id = p_subject)
    WHEN 'write_off_output' THEN (
        SELECT jsonb_build_object(
            'batch_code', ob.code, 'material_code', m.code, 'material_name', m.name,
            'remaining_qty', ob.remaining_qty, 'quantity', ob.quantity, 'unit', ob.unit, 'state', ob.state,
            'run_code', (SELECT pr.code FROM processing_outputs po JOIN processing_runs pr ON pr.id = po.run_id
                          WHERE po.output_batch_id = ob.id LIMIT 1),
            'cods_voided', '[]'::jsonb)
          FROM output_batches ob
          LEFT JOIN materials m ON m.id = ob.material_id
         WHERE ob.id = p_subject)
    WHEN 'rollback' THEN (
        SELECT jsonb_build_object(
            'run_code', pr.code, 'process_date', pr.process_date,
            'locked_period', pr.process_date < (SELECT fs.locked_before FROM finance_settings fs),
            'locked_before', (SELECT fs.locked_before FROM finance_settings fs),
            'outputs', COALESCE((SELECT jsonb_agg(ob.code ORDER BY ob.code) FROM processing_outputs po
                                   JOIN output_batches ob ON ob.id = po.output_batch_id
                                  WHERE po.run_id = pr.id AND ob.deleted_at IS NULL), '[]'::jsonb),
            'inputs', COALESCE((SELECT jsonb_agg(DISTINCT COALESCE(ib.code, ob.code)) FROM processing_inputs pi
                                  LEFT JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
                                  LEFT JOIN output_batches ob ON ob.id = pi.output_batch_id
                                 WHERE pi.run_id = pr.id), '[]'::jsonb),
            'cods_voided', COALESCE((SELECT jsonb_agg(DISTINCT c.code) FROM processing_inputs pi
                                       JOIN certificates_of_destruction c
                                         ON c.inbound_batch_id = pi.inbound_batch_id AND c.status = 'issued'
                                      WHERE pi.run_id = pr.id), '[]'::jsonb))
          FROM processing_runs pr
         WHERE pr.id = p_subject)
    WHEN 'cod_void' THEN (
        SELECT jsonb_build_object(
            'cod_code', c.code, 'batch_code', ib.code, 'supplier_name', COALESCE(s.short_name, s.legal_name),
            'material_name', m.name, 'issued_at', c.issued_at, 'completed_on', c.completed_on,
            'cods_voided', jsonb_build_array(c.code))
          FROM certificates_of_destruction c
          JOIN inbound_batches ib ON ib.id = c.inbound_batch_id
          LEFT JOIN materials m ON m.id = ib.material_id
          LEFT JOIN suppliers s ON s.id = ib.supplier_id
         WHERE c.id = p_subject)
    END
$function$;

-- db/functions/warehouse_request_execute_internal.sql
-- APR-7(2026-09-25):让一张仓库申请【生效】—— 批准、审批关着时的提交、提交时的试跑,三处都走这一支,
-- 所以试跑拒的与批准拒的是同一句话。
--   write_off_inbound → soft_delete_inbound_batch_internal(欠款检查在那里,Q4:提交时一遍、批准时再一遍)
--   write_off_output  → soft_delete_output_batch_internal(订单预留在注销触发器里拒)
--   rollback          → rollback_processing_run_internal(OUTPUT_CONSUMED 在那里)
--   cod_void          → 只有已签发的作废得掉(COD_NOT_ISSUED),void_cod_internal,没有替代品
-- 每一种的 deleted_by / voided_by = 提单人(grilling Q6)。
-- 【冻结放行】evoltrya.warehouse_request_ctx = 本申请 id,guard_warehouse_request_freeze 只放它自己写的流水。
-- 返回 amount_base(本次过出来那几张分录的借方合计,本位币)与 entry_ids。"本次过出来的"= 本事务里
-- 执行之前不存在、之后存在的分录(created_at 默认 now(),即事务时间)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      warehouse_requests%ROWTYPE;
    v_before uuid[];
    v_ids    uuid[];
    v_amt    numeric;
    v_cod    record;
BEGIN
    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    v_before := ARRAY(SELECT je.id FROM journal_entries je WHERE je.created_at = now());
    PERFORM set_config('evoltrya.warehouse_request_ctx', v_r.id::text, true);

    IF v_r.kind = 'write_off_inbound' THEN
        PERFORM soft_delete_inbound_batch_internal(v_r.inbound_batch_id, v_r.reason, v_r.created_by);
    ELSIF v_r.kind = 'write_off_output' THEN
        PERFORM soft_delete_output_batch_internal(v_r.output_batch_id, v_r.reason, v_r.created_by);
    ELSIF v_r.kind = 'rollback' THEN
        PERFORM rollback_processing_run_internal(v_r.run_id, v_r.reason, v_r.created_by);
    ELSE
        SELECT c.id, c.code, c.status INTO v_cod
          FROM certificates_of_destruction c WHERE c.id = v_r.cod_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(v_r.cod_id::text, '?');
        END IF;
        IF v_cod.status <> 'issued' THEN
            RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', COALESCE(v_cod.code, v_cod.id::text), v_cod.status;
        END IF;
        PERFORM void_cod_internal(v_cod.id, v_r.reason, NULL, v_r.created_by);
    END IF;

    PERFORM set_config('evoltrya.warehouse_request_ctx', '', true);

    v_ids := ARRAY(SELECT je.id FROM journal_entries je
                    WHERE je.created_at = now() AND je.id <> ALL (v_before) ORDER BY je.code);
    SELECT COALESCE(round(sum(l.debit), 2), 0) INTO v_amt
      FROM journal_lines l WHERE l.entry_id = ANY (v_ids);

    RETURN jsonb_build_object('amount_base', v_amt, 'entry_ids', to_jsonb(v_ids));
END;
$function$;

-- db/functions/warehouse_request_dry_run.sql
-- APR-7(2026-09-25):提交时,按批准那一刻会走的同一支(warehouse_request_execute_internal)试跑一遍,
-- 然后整段回滚(PQ005,journal_request_dry_run 同一个手法)。延迟的约束触发器(台账恒等式、桶不许为负、
-- 分录平衡)在试跑里提前到 IMMEDIATE 结一次账 —— 否则它们要到提交才开口,试跑就说了一句假"可以"。
-- 拒绝原话原样冒出去;成功返回 amount_base 与 entry_ids(entry_ids 在回滚之后不存在,只用它的个数)。
-- 内层算子;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := warehouse_request_execute_internal(p_request_id);
        SET CONSTRAINTS trg_inventory_movements_invariant, trg_inventory_movements_no_negative_bucket,
                        trg_inbound_batches_invariant, trg_output_batches_invariant,
                        trg_journal_lines_balance IMMEDIATE;
        SET CONSTRAINTS trg_inventory_movements_invariant, trg_inventory_movements_no_negative_bucket,
                        trg_inbound_batches_invariant, trg_output_batches_invariant,
                        trg_journal_lines_balance DEFERRED;
        RAISE EXCEPTION USING ERRCODE = 'PQ005', MESSAGE = 'WAREHOUSE_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ005' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$;

-- db/functions/warehouse_request_submit_internal.sql
-- APR-7(2026-09-25):提一张仓库申请 —— 四扇提交的门各问完自己的码,落进这一支。本支不问码。
--
--   1. 理由必填(WAREHOUSE_REQUEST_REASON_REQUIRED|种类|编号)—— 它原样成为 delete_reason / 回滚理由 / void_reason。
--   2. 主体要在、没被删、这一种要成立:
--        注销:batch_write_off_needs_request 为真,否则 WAREHOUSE_REQUEST_NOT_NEEDED|批号(空批一步删,Q1);
--        回滚:加工单在且未回滚(RUN_NOT_FOUND · RUN_ALREADY_DELETED);
--        作废:证书在且已签发(COD_NOT_FOUND · COD_NOT_ISSUED)。
--   3. 碰到同一样东西的在等申请 → WAREHOUSE_REQUEST_OPEN|编号|那一张(Q3,跨种类;唯一索引是同种类的第二道)。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动 → WAREHOUSE_REQUEST_NO_OTHER_DECIDER|label
--      (assert_other_decider,按人认)。线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。
--   5. 落一行 submitted,snapshot 冻结;按批准那一刻的同一支试跑(warehouse_request_dry_run)——
--      欠款、订单预留、产出动过、期间锁,全按原话拒。amount_base 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场生效,状态 approved,留痕 auto_approved。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_request_submit_internal(p_kind text, p_subject uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_del   timestamptz;
    v_stat  text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_exec  jsonb := NULL;
BEGIN
    IF p_kind = 'write_off_inbound' THEN
        SELECT code INTO v_code FROM inbound_batches WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
    ELSIF p_kind = 'write_off_output' THEN
        SELECT code INTO v_code FROM output_batches WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
    ELSIF p_kind = 'rollback' THEN
        SELECT code, deleted_at INTO v_code, v_del FROM processing_runs WHERE id = p_subject FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'RUN_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_del IS NOT NULL THEN
            RAISE EXCEPTION 'RUN_ALREADY_DELETED';
        END IF;
    ELSIF p_kind = 'cod_void' THEN
        SELECT COALESCE(code, id::text), status INTO v_code, v_stat
          FROM certificates_of_destruction WHERE id = p_subject FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_stat <> 'issued' THEN
            RAISE EXCEPTION 'COD_NOT_ISSUED|%|%', v_code, v_stat;
        END IF;
    ELSE
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_REASON_REQUIRED|%|%', p_kind, v_code;
    END IF;

    IF p_kind IN ('write_off_inbound', 'write_off_output')
       AND NOT batch_write_off_needs_request(
               CASE WHEN p_kind = 'write_off_inbound' THEN p_subject END,
               CASE WHEN p_kind = 'write_off_output' THEN p_subject END) THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_NEEDED|%', v_code;
    END IF;

    v_open := warehouse_request_conflict(p_kind, p_subject);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;

    -- label:同一个主体上第几张。咨询锁串行化"数一遍 + 1"。
    PERFORM pg_advisory_xact_lock(hashtext('warehouse_request_label')::bigint);
    SELECT count(*) + 1 INTO v_n FROM warehouse_requests r
     WHERE r.kind = p_kind
       AND COALESCE(r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id) = p_subject;
    v_label := v_code || ' · ' || CASE p_kind WHEN 'rollback' THEN 'rollback'
                                               WHEN 'cod_void' THEN 'void'
                                               ELSE 'write-off' END || ' #' || v_n::text;

    PERFORM assert_other_decider('warehouse_request', 'decide_warehouse_request', 2::smallint,
                                 'WAREHOUSE_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO warehouse_requests (id, kind, status, label, inbound_batch_id, output_batch_id, run_id, cod_id,
                                    reason, snapshot, amount_base, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label,
            CASE WHEN p_kind = 'write_off_inbound' THEN p_subject END,
            CASE WHEN p_kind = 'write_off_output' THEN p_subject END,
            CASE WHEN p_kind = 'rollback' THEN p_subject END,
            CASE WHEN p_kind = 'cod_void' THEN p_subject END,
            btrim(p_reason), warehouse_request_snapshot(p_kind, p_subject), 0, auth.uid());

    v_dry := warehouse_request_dry_run(v_id);
    UPDATE warehouse_requests SET amount_base = (v_dry->>'amount_base')::numeric WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('warehouse_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_exec := warehouse_request_execute_internal(v_id);
        UPDATE warehouse_requests
           SET status = 'approved', executed_at = now(),
               amount_base = (v_exec->>'amount_base')::numeric,
               result_entry_ids = ARRAY(SELECT jsonb_array_elements_text(v_exec->'entry_ids')::uuid)
         WHERE id = v_id;
        PERFORM record_approval_decision('warehouse_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场生效,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'amount_base', COALESCE(v_exec->'amount_base', v_dry->'amount_base'));
END;
$function$;

-- db/functions/submit_inbound_write_off_request.sql
-- APR-7(2026-09-25):仓库提一张申请 —— 注销一张进料批(还有料,或挂着已签发的销毁证书)。CFO 批准才生效(Tim 的矩阵,不分档)。
-- 门 action.batch_write_off(ROLE-1 Batch 3b 的持有人:warehouse · admin);其余全在 warehouse_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_inbound_write_off_request(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.batch_write_off');
    RETURN warehouse_request_submit_internal('write_off_inbound', p_batch_id, p_reason);
END;
$function$;

-- db/functions/submit_output_write_off_request.sql
-- APR-7(2026-09-25):仓库提一张申请 —— 注销一张还有料的产出批。CFO 批准才生效(Tim 的矩阵,不分档)。
-- 门 action.batch_write_off(ROLE-1 Batch 3b 的持有人:warehouse · admin);其余全在 warehouse_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_output_write_off_request(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.batch_write_off');
    RETURN warehouse_request_submit_internal('write_off_output', p_batch_id, p_reason);
END;
$function$;

-- db/functions/submit_rollback_request.sql
-- APR-7(2026-09-25):仓库提一张申请 —— 回滚一张加工单。CFO 批准才生效(Tim 的矩阵,不分档)。
-- 门 action.processing_rollback(ROLE-1 Batch 3b 的持有人:warehouse · admin);其余全在 warehouse_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_rollback_request(p_run_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_rollback');
    RETURN warehouse_request_submit_internal('rollback', p_run_id, p_reason);
END;
$function$;

-- db/functions/submit_cod_void_request.sql
-- APR-7(2026-09-25):仓库提一张申请 —— 作废一张已签发的销毁证书。CFO 批准才生效(Tim 的矩阵,不分档)。
-- 门 action.issue_cod(ROLE-1 Batch 3b 的持有人:warehouse · admin);其余全在 warehouse_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_cod_void_request(p_cod_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.issue_cod');
    RETURN warehouse_request_submit_internal('cod_void', p_cod_id, p_reason);
END;
$function$;

-- db/functions/decide_warehouse_request.sql
-- APR-7(2026-09-25):CFO 批准或驳回一张仓库申请(注销 · 回滚 · 证书作废)。批准【当场生效】,按批准那一天
-- (grilling Q4:流水与分录落在批准日;价值按批准那一刻的活数)。
--
-- 【门】module.finance.view + data.view_prices(grilling Q8)—— 与付款、贷项、手工凭证申请同一对码;
-- 【不是】提单的那三个 action 码。cfo 两个都持。四种一个门:证书作废不动钱,但它是同一张表、同一个决定人。
-- 【谁能批】二级审批人,每一张、不分档。【四眼】forbid_self_approval(提单人, NULL, …)按人认 ——
-- admin@ 提的 tim@ 批不了(同一个人),所以提交时就按名拒 WAREHOUSE_REQUEST_NO_OTHER_DECIDER。
--
-- 【批准之前不另查】批准就是那一次真的生效:欠款(INBOUND_HAS_OPEN_PAYABLE,Q4 的第二遍)、订单预留、
-- 产出动过、证书不再是已签发 —— 全按原话拒,整笔回滚,申请仍在等;CFO 驳回,或仓库撤回。冻结
-- (guard_warehouse_request_freeze)让这些在等待中几乎不会发生。驳回要理由,从不检查这些。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_warehouse_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    warehouse_requests%ROWTYPE;
    v_exec jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'warehouse_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE warehouse_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('warehouse_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_exec := warehouse_request_execute_internal(p_request_id);

    UPDATE warehouse_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(), executed_at = now(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           amount_base = (v_exec->>'amount_base')::numeric,
           result_entry_ids = ARRAY(SELECT jsonb_array_elements_text(v_exec->'entry_ids')::uuid)
     WHERE id = p_request_id;
    PERFORM record_approval_decision('warehouse_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind, 'amount_base', v_exec->'amount_base',
                              'entry_ids', v_exec->'entry_ids');
END;
$function$;

-- db/functions/withdraw_warehouse_request.sql
-- APR-7(2026-09-25):撤回一张在等的仓库申请。谁能撤:提单人本人(按人认),或持这一种那个码的人
-- (注销 action.batch_write_off · 回滚 action.processing_rollback · 作废 action.issue_cod)。
-- 只撤 submitted。撤回什么都不生效、冻结随之解开;记在本行上,【不】写 approval_log(撤回不是一次决定)。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_warehouse_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r warehouse_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM warehouse_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission(CASE v_r.kind WHEN 'rollback' THEN 'action.processing_rollback'
                                                 WHEN 'cod_void' THEN 'action.issue_cod'
                                                 ELSE 'action.batch_write_off' END);
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE warehouse_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;

-- db/functions/warehouse_requests_visible.sql
-- APR-7(2026-09-25,grilling Q8):库存页上那一块读的就是这里 —— 仓库看得见自己提的申请,CFO 看得见要他批的。
--   谁读得到:持 module.inventory.view 的人(库存页的门;cfo 与 warehouse 都持)。其余 → 零行。
--   【金额按 data.view_prices 给】没有它的读者(仓库)amount_base 是 NULL —— 注销的价值是一个价格。
--   只给在等的全部 + 最近决定 / 撤回的 p_recent 张;raised_by_me = 提单人就是读者这个人(按人认)。
--   提单人 / 决定人的邮箱给屏幕读"谁提的、谁批的"。
-- NOTE: introduced by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.warehouse_requests_visible(p_recent integer DEFAULT 10)
 RETURNS TABLE(id uuid, kind text, status text, label text, inbound_batch_id uuid, output_batch_id uuid, run_id uuid, cod_id uuid, reason text, snapshot jsonb, amount_base numeric, created_at timestamptz, created_by_email text, raised_by_me boolean, decided_at timestamptz, decided_by_email text, decision_notes text, withdrawn_at timestamptz, withdraw_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    WITH r AS (
        SELECT q.*, (q.status = 'submitted') AS is_open,
               row_number() OVER (PARTITION BY (q.status = 'submitted')
                                  ORDER BY COALESCE(q.decided_at, q.withdrawn_at, q.created_at) DESC) AS rn
          FROM warehouse_requests q
         WHERE has_permission('module.inventory.view'))
    SELECT r.id, r.kind, r.status, r.label, r.inbound_batch_id, r.output_batch_id, r.run_id, r.cod_id,
           r.reason, r.snapshot,
           CASE WHEN has_permission('data.view_prices') THEN r.amount_base END,
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

-- db/functions/soft_delete_inbound_batch.sql
-- APR-7(2026-09-25):注销进料批的那扇【一步】的门 —— 只剩空批(grilling Q1)。
--   还有料、或挂着已签发销毁证书的批次 → 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_inbound|批号:
--   它们走 submit_inbound_write_off_request,CFO 批准才生效。
--   空批还要问一句:它有没有被一张在等的申请碰到(回滚的投料、证书作废)→ WAREHOUSE_REQUEST_OPEN。
--   其余原样交给 soft_delete_inbound_batch_internal(理由必填、定价申请、欠款、证书刷新都在那里)。
-- 门 action.batch_write_off(ROLE-1 Batch 3b)。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.soft_delete_inbound_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_open text;
BEGIN
    PERFORM require_permission('action.batch_write_off');
    SELECT code INTO v_code FROM inbound_batches WHERE id = p_batch_id AND deleted_at IS NULL;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF batch_write_off_needs_request(p_batch_id, NULL) THEN
        RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_inbound|%', v_code;
    END IF;
    v_open := warehouse_request_conflict('write_off_inbound', p_batch_id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    RETURN soft_delete_inbound_batch_internal(p_batch_id, p_reason, NULL);
END;
$function$;

-- db/functions/soft_delete_output_batch.sql
-- APR-7(2026-09-25):注销产出批的那扇【一步】的门 —— 只剩空批(grilling Q1)。
--   还有料 → 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_output|批号(走 submit_output_write_off_request)。
--   空批被一张在等的申请碰到(回滚的产出或投料)→ WAREHOUSE_REQUEST_OPEN。
--   其余原样交给 soft_delete_output_batch_internal。门 action.batch_write_off(ROLE-1 Batch 3b)。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.soft_delete_output_batch(p_batch_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_open text;
BEGIN
    PERFORM require_permission('action.batch_write_off');
    SELECT code INTO v_code FROM output_batches WHERE id = p_batch_id AND deleted_at IS NULL;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_batch_id::text, '?');
    END IF;
    IF batch_write_off_needs_request(NULL, p_batch_id) THEN
        RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|write_off_output|%', v_code;
    END IF;
    v_open := warehouse_request_conflict('write_off_output', p_batch_id);
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'WAREHOUSE_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;
    RETURN soft_delete_output_batch_internal(p_batch_id, p_reason, NULL);
END;
$function$;

-- db/functions/rollback_processing_run.sql
-- APR-7(2026-09-25):旧的一步回滚【一张都不回滚】—— 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|单号。
-- 回滚走 submit_rollback_request,CFO 批准才生效(Tim 的矩阵:仓库提,CFO 批每一张)。
-- 函数体搬进了 rollback_processing_run_internal;名字留着,是为了让旧屏幕与任何旧调用者得到一句按名的拒绝,
-- 而不是"函数不存在"。
-- 码先问(action.processing_rollback):没有它的人得到的仍是 PERMISSION_DENIED,与之前一样。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.rollback_processing_run(p_run_id uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.processing_rollback');
    RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|rollback|%',
        COALESCE((SELECT code FROM processing_runs WHERE id = p_run_id), '?');
END;
$function$;

-- db/functions/void_cod.sql
-- APR-7(2026-09-25):旧的一步作废【一张都不作废】—— 按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST|cod_void|证书号。
-- 作废走 submit_cod_void_request,CFO 批准才生效(Tim 的矩阵:仓库提,CFO 批每一张)。在等的时候,公开核验页
-- 照旧说"有效" —— 那是真的,还没有东西生效。
-- 作废本身仍是 void_cod_internal(字节档案与快照一个字不动)。
-- 码先问(action.issue_cod):没有它的人得到的仍是 PERMISSION_DENIED,与之前一样。
-- NOTE: rewritten by db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.void_cod(p_cod_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('action.issue_cod');
    RAISE EXCEPTION 'WAREHOUSE_NEEDS_APPROVED_REQUEST|cod_void|%',
        COALESCE((SELECT COALESCE(code, id::text) FROM certificates_of_destruction WHERE id = p_cod_id), '?');
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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废 · 手工凭证 · 仓库(注销 / 回滚 / 证书作废)六种申请与发货放行 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

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
            ARRAY['module.finance.view', 'data.view_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- ── 4 · 冻结守卫:库存流水与定价申请(Q3)──────────────────────────────────────
CREATE TRIGGER trg_inventory_movements_warehouse_request_freeze
    BEFORE INSERT ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_warehouse_request_freeze();
CREATE TRIGGER trg_receipt_price_requests_warehouse_request_freeze
    BEFORE INSERT ON public.receipt_price_requests
    FOR EACH ROW EXECUTE FUNCTION public.guard_warehouse_request_freeze();

-- ── 5 · EXECUTE:内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)────────
REVOKE EXECUTE ON FUNCTION public.soft_delete_inbound_batch_internal(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.soft_delete_output_batch_internal(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rollback_processing_run_internal(uuid, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_submit_internal(text, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_execute_internal(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_dry_run(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_touches(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_freezing(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_snapshot(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.warehouse_request_conflict(text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_write_off_needs_request(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.void_cod_internal(uuid, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_warehouse_request_freeze() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_inbound_write_off_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_output_write_off_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_rollback_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_cod_void_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.decide_warehouse_request(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.withdraw_warehouse_request(uuid, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.warehouse_requests_visible(integer) FROM PUBLIC, anon;

-- ── 6 · operations_now:加一支 warehouse_request_pending(镜像原样)──────────────
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
CREATE FUNCTION pg_temp.a7_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE a7_pending_after ON COMMIT DROP AS
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

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码,Q8)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a7_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a7_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR7_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR7_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;分录、流水、批次、加工单、证书、留痕一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a7_pending_before b EXCEPT SELECT a.k, a.id FROM a7_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a7_pending_after a EXCEPT SELECT b.k, b.id FROM a7_pending_before b)) THEN
        RAISE EXCEPTION 'APR7_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a7_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM inventory_movements) AS movements,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS inbound_deleted,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS output_deleted,
       (SELECT count(*) FROM processing_runs WHERE deleted_at IS NOT NULL) AS runs_deleted,
       (SELECT string_agg(status || ':' || n, ' ' ORDER BY status)
          FROM (SELECT status, count(*) AS n FROM certificates_of_destruction GROUP BY status) c) AS cods) n) THEN
        RAISE EXCEPTION 'APR7_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a7_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM inventory_movements) AS movements,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS inbound_deleted,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS output_deleted,
       (SELECT count(*) FROM processing_runs WHERE deleted_at IS NOT NULL) AS runs_deleted,
       (SELECT string_agg(status || ':' || n, ' ' ORDER BY status)
          FROM (SELECT status, count(*) AS n FROM certificates_of_destruction GROUP BY status) c) AS cods) n);
    END IF;
    IF EXISTS (SELECT 1 FROM warehouse_requests) THEN
        RAISE EXCEPTION 'APR7_PROOF|warehouse_requests is not empty';
    END IF;

    -- ④ 结构:申请表上没有写策略;两支冻结守卫挂上;内层算子 authenticated 调不到;旧的回滚 / 作废门只会拒、
    --    不再调函数体;两扇一步删的门先问"要不要经 CFO";名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename = 'warehouse_requests' AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR7_PROOF|a warehouse_requests write policy exists';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_inventory_movements_warehouse_request_freeze',
                      'trg_receipt_price_requests_warehouse_request_freeze');
    IF v_n <> 2 THEN RAISE EXCEPTION 'APR7_PROOF|expected 2 freeze triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY['public.soft_delete_inbound_batch_internal(uuid, text, uuid)', 'public.soft_delete_output_batch_internal(uuid, text, uuid)', 'public.rollback_processing_run_internal(uuid, text, uuid)', 'public.warehouse_request_submit_internal(text, uuid, text)', 'public.warehouse_request_execute_internal(uuid)', 'public.warehouse_request_dry_run(uuid)', 'public.warehouse_request_touches(text, uuid)', 'public.warehouse_request_freezing(uuid, uuid)', 'public.warehouse_request_snapshot(text, uuid)', 'public.warehouse_request_conflict(text, uuid)', 'public.batch_write_off_needs_request(uuid, uuid)', 'public.void_cod_internal(uuid, text, uuid, uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR7_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.rollback_processing_run(uuid, text)'::regprocedure)
         NOT LIKE '%WAREHOUSE_NEEDS_APPROVED_REQUEST%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.rollback_processing_run(uuid, text)'::regprocedure)
         LIKE '%_internal%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.void_cod(uuid, text)'::regprocedure)
         NOT LIKE '%WAREHOUSE_NEEDS_APPROVED_REQUEST%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.void_cod(uuid, text)'::regprocedure)
         LIKE '%_internal%' THEN
        RAISE EXCEPTION 'APR7_PROOF|an old one-step rollback / void door still does the work';
    END IF;
    IF (SELECT count(*) FROM pg_proc
         WHERE oid IN ('public.soft_delete_inbound_batch(uuid, text)'::regprocedure,
                       'public.soft_delete_output_batch(uuid, text)'::regprocedure)
           AND prosrc LIKE '%batch_write_off_needs_request%') <> 2 THEN
        RAISE EXCEPTION 'APR7_PROOF|a one-step delete door does not ask whether the CFO is needed';
    END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'warehouse_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR7_PROOF|warehouse_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('warehouse_request', 'decide_warehouse_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR7_PROOF|nobody can decide a warehouse request'; END IF;
    RAISE NOTICE 'APR7 deciders for warehouse_request: %', v_n;

    -- ⑥ 每一张在途单据 —— 连同每一条申请链(Q9)—— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a7_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR7 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a7_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR7_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a7_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a7_pending_decider_check(boolean);

COMMIT;

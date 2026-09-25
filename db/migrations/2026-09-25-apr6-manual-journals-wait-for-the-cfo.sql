-- db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql
-- APR-6 —— 手工凭证与它的冲销要 CFO 批准才过账;系统生成的分录不经这里(docs/role-matrix.md「手工凭证与冲销」· N5)。
-- 由 db/scripts/build_apr6_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-6 grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   ① 界线划在权限上(Q1):post_journal_entry 的 EXECUTE 从 authenticated 收回;journal_entries /
--      journal_lines 的 INSERT 写策略拿掉,直连写按名拒 JOURNAL_THROUGH_FUNCTION_ONLY(语句级守卫)。
--      线上调 post_journal_entry 的 30 支函数全是 SECURITY DEFINER(属主 postgres),照常过账 —— 月结、外币重估、
--      折旧、年结、以及每一张单据自己的函数都不经审批(N5)。
--   ② journal_requests(Q3):entry = 一张手工凭证(永远过成 'manual',source_id = 申请);reversal = 冲一张没有自己
--      冲销路径的分录。财务提(module.finance.edit),CFO 批每一张、不分档(N1 对 journal_entries 退休,Q2),
--      批准【当场过账】,按提交时冻下来的日期;rejected(要理由)· withdrawn(提单人或 module.finance.edit)。
--      提交按同一支过账试跑(PQ005)。审批关着时生下来就是 approved 并当场过账(auto_approved)。
--      提单人之外没人批得动 → JOURNAL_REQUEST_NO_OTHER_DECIDER(assert_other_decider)。
--   ③ 期间锁永远赢(Q4):锁不因为一张在等的申请而被拒;批准时的过账按引擎原话拒(PERIOD_LOCKED)。
--   ④ 职责分离(Q5):sod_manual_posters_in 认【提单人】—— COALESCE(申请.created_by, 分录.created_by)。
--   ⑤ 冲销(Q6):reverse_journal_entry 一张都不冲 —— 有自己路径的按名拒 JE_REVERSE_USE_SOURCE_PATH(加上 expense ·
--      freight · allocation · processing_cost · year_close),其余按名拒 JOURNAL_NEEDS_APPROVED_REQUEST(走冲销申请)。
--      一份判据:journal_entry_reversal_route。
--   ⑥ 控制科目(Q7):申请过出来的分录碰 1100 / 2000 → JE_MANUAL_CONTROL_ACCOUNT(重估的冲销例外);
--      贷银行科目准许,申请上标 credits_bank。
--   ⑦ 引擎登记(Q8):approval_chain_gates 一行(二级,module.finance.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 journal_request;record_approval_decision 一支(本位币);operations_now 一支 journal_request_pending。
--
-- 【不做什么】不新增任何权限码,所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行;不改任何一支系统过账函数。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;approval_log、
-- journal_entries、journal_lines 一行没变;授权一条没变;申请表是空的;职责分离的读数没变;两张分录表上没有写策略、
-- 两支守卫挂上;post_journal_entry 与三支内层算子 authenticated 调不到;除 post_journal_entry 自己之外,调它的
-- 每一支函数都是 SECURITY DEFINER(否则那条系统路径会在本刀之后断掉);旧的冲销门只会拒;新链有人批得了;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR6_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.journal_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR6_PRE|journal_requests already exists';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND policyname IN ('journal_entries insert by permission', 'journal_lines insert by permission')) <> 2 THEN
        RAISE EXCEPTION 'APR6_PRE|the two journal insert policies are not both there to drop';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.post_journal_entry(date, text, text, uuid, jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'APR6_PRE|post_journal_entry is expected to be executable by authenticated before this cut';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.finance.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR6_PRE|cfo does not hold both gate codes';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a6_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE a6_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'manual') AS manual_entries,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total;
CREATE TEMP TABLE a6_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
-- 职责分离的读数:改写 sod_manual_posters_in 之前,全期间里"记过手工凭证的人"是谁
CREATE TEMP TABLE a6_sod_before ON COMMIT DROP AS
SELECT sod_manual_posters_in(NULL, '9999-12-31'::date) AS posters;

-- ── 1 · journal_requests(镜像原样)──────────────────────────────────────────
CREATE TABLE public.journal_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind                    text NOT NULL CHECK (kind IN ('entry', 'reversal')),
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label                   text NOT NULL,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- entry:凭证日;reversal:冲销日(提交时就定下,决定落进哪个期间)
    entry_date              date NOT NULL,
    -- entry:摘要(必填);reversal:冲销的理由(必填,写进冲销分录的摘要)
    memo                    text NOT NULL CHECK (btrim(memo) <> ''),
    -- entry 的行,原样(post_journal_entry 的 p_lines);reversal 为 NULL
    lines                   jsonb,
    -- reversal 冲的那一张;entry 为 NULL
    target_entry_id         uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base             numeric NOT NULL CHECK (amount_base >= 0),
    -- 过出来的分录贷了现金 / 银行科目(试跑读出,批准时重读)
    credits_bank            boolean NOT NULL DEFAULT false,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    -- 批准当场过账:过出来的那一张分录
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    withdraw_reason         text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT journal_requests_kind_shape CHECK (
        (kind = 'entry') = (lines IS NOT NULL)
        AND (kind = 'reversal') = (target_entry_id IS NOT NULL)),
    CONSTRAINT journal_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT journal_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT journal_requests_approved_shape CHECK (
        (status = 'approved') = (result_journal_entry_id IS NOT NULL)),
    CONSTRAINT journal_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.journal_requests IS
    'APR-6:手工凭证与冲销的申请(Tim 的矩阵:财务提,CFO 批每一张,不分档;批准当场过账)。entry = 一张手工凭证(过出来永远是 manual,source_id = 本申请);reversal = 冲一张没有自己冲销路径的分录。submitted → approved(CFO,当场按冻结的日期过账)· rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。审批关着时生下来就是 approved 并当场过账(auto_approved)。1100 / 2000 按名拒(JE_MANUAL_CONTROL_ACCOUNT);贷银行科目准许并标 credits_bank。';

COMMENT ON COLUMN public.journal_requests.amount_base IS
    'APR-6:本位币 = 过出来那张分录的借方合计。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账的那一个(写进 approved 留痕)。N1 对 journal_entries 退休(grilling Q2):不分档,没有档可越。';

COMMENT ON COLUMN public.journal_requests.credits_bank IS
    'APR-6(grilling Q7):过出来的分录贷了一个 is_cash 科目。银行科目准许手工凭证,但要经 CFO 批准,而且 CFO 那一块要把这句说出来。';

CREATE UNIQUE INDEX journal_requests_one_open_reversal
    ON public.journal_requests (target_entry_id)
    WHERE status = 'submitted' AND kind = 'reversal';
CREATE INDEX journal_requests_target_entry_id_rel ON public.journal_requests (target_entry_id);
CREATE INDEX journal_requests_result_journal_entry_id_rel ON public.journal_requests (result_journal_entry_id);

ALTER TABLE public.journal_requests ENABLE ROW LEVEL SECURITY;

-- 读:凭证页的门(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。写:一条策略都不给 ——
-- 只经 submit_journal_request · submit_journal_reversal_request · decide_journal_request ·
-- withdraw_journal_request(全是 SECURITY DEFINER)。
CREATE POLICY "journal_requests select by permission" ON public.journal_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.journal_requests FROM anon;

-- ── 2 · approval_log:主体类型加 journal_request;读策略加同名一支 ──────────────
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
                            'journal_request'));
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
            ELSE false
        END
    );

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/guard_journal_direct_write.sql
-- APR-6(2026-09-25,grilling Q1 · Q9):**journal_entries 与 journal_lines 没有直连写**。
--
-- 【量过的】写这两张表的只有 post_journal_entry(插入)与 reverse_journal_entry_internal(posted → reversed
-- 那一次翻转);调用它们的 30 支函数在线上全是 SECURITY DEFINER、属主 postgres(rolbypassrls)—— APR-6 Step 0
-- 以 postgres 读 pg_proc。app/ 里对这两张表只有读。于是两条 INSERT 写策略(都开在 module.finance.edit 上)
-- 一并拿掉。它们放行过的路:
--   · 直连 INSERT 一张分录头:自己挑编号(无缝编号从此有缝)、自己填 created_by(职责分离那条规矩认的就是它)、
--     自己填 status / reversed_by / source_type —— 一张 'purchase' 或 'payment' 分录不经任何单据就进了账;
--   · 直连 INSERT 分录行,挂在一张【已过账】的分录上(JE-APPEND):开着的期间里,一张过完账的凭证金额还能动;
--   · 一张没有行的分录头(平衡触发器只在插行时排队)。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 INSERT 报的是一句 RLS 的原文(new row violates row-level
-- security policy),UPDATE / DELETE 则是【零行、不报错】(SILENT-1 那一族)。本守卫零行也照样触发,按名拒
-- JOURNAL_THROUGH_FUNCTION_ONLY。属主路径(row_security_active = false)一律放行 —— 那就是 30 支 DEFINER 过账
-- 函数与 reverse_journal_entry_internal 走的路。形状照 guard_invoice_direct_write。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_journal_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'JOURNAL_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_journal_direct_write() IS
'APR-6:journal_entries 与 journal_lines 的任何直连写(row_security_active,语句级,零行也触发)按名拒 JOURNAL_THROUGH_FUNCTION_ONLY。写它们的只有 post_journal_entry(EXECUTE 已从 authenticated 收回)与 reverse_journal_entry_internal,调用方全是 SECURITY DEFINER;一张手工凭证走 submit_journal_request → CFO 批准。';

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
--                  revaluation · depreciation · asset_disposal · shipment · fx · 工资的【付款】分录)。
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
                            'expense', 'freight', 'allocation', 'processing_cost', 'year_close') THEN
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

-- db/functions/journal_request_post_internal.sql
-- APR-6(2026-09-25):把一张手工凭证 / 冲销申请【过账】—— 批准那一刻(或审批关着时提交那一刻)跑的那一支,
-- 也是试跑(journal_request_dry_run)跑的同一支。参数全从申请行上读,就是提交时冻下来的那一组(grilling Q3)。
--
--   entry    → post_journal_entry(entry_date, memo, 'manual', 本申请的 id, lines)—— 永远是 'manual',
--              source_id 指回申请(Q3)。人给不了别的 source_type:post_journal_entry 对 authenticated 已收回(Q1)。
--   reversal → reverse_journal_entry_internal(target, entry_date, memo)—— 先问 journal_entry_reversal_route:
--              只有 'request' 这一格能走到这里;'source_path' 按名拒 JE_REVERSE_USE_SOURCE_PATH,
--              已冲过的交给引擎按原话拒(JE_ALREADY_REVERSED)。
--   其它种类 → JOURNAL_REQUEST_KIND_UNKNOWN(不认识的种类按名拒,不许落进一个 ELSE 去做别的事)。
--
-- 【过完账再读那一张分录,按它说话】与 invoice_request_post_internal 读它自己那张分录同一条 —— 同一支引擎的
-- 产物,不在这里另算一份会漂开的数:
--   · amount_base = 借方合计(本位币);credits_bank = 有一行贷在 is_cash 科目上(Q7:准许,但要说出来)。
--   · ★ 1100 / 2000 按名拒 JE_MANUAL_CONTROL_ACCOUNT|label|科目(Q7):应收、应付的总账数只能由它们自己的
--     单据动 —— 手敲一行,list_ledger_reconciliation 那两边就会出现一笔说不出名字的差。冲销申请同一条
--     (冲掉一张 sale / prepayment 分录的总账一半,单据那一半不动,同样是一笔说不出名字的差);唯一的例外是
--     'revaluation' 的冲销 —— 那一条核对按 source_type 点名扣掉重估,冲销抄原分录的 source_type,仍被点名。
--   拒绝就是抛错:外层(批准 / 提交 / 试跑)整笔回滚,过出来的分录与编号一起消失。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_request_post_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      journal_requests%ROWTYPE;
    v_res    jsonb;
    v_entry  uuid;
    v_code   text;
    v_src    text;
    v_route  text;
    v_ctrl   text;
    v_base   numeric;
    v_bank   boolean;
BEGIN
    SELECT * INTO v_r FROM journal_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;

    CASE v_r.kind
    WHEN 'entry' THEN
        v_res := post_journal_entry(v_r.entry_date, v_r.memo, 'manual', v_r.id, v_r.lines);
        v_entry := (v_res->>'entry_id')::uuid;
        v_code := v_res->>'code';
        v_src := 'manual';
    WHEN 'reversal' THEN
        SELECT je.code, je.source_type INTO v_code, v_src FROM journal_entries je WHERE je.id = v_r.target_entry_id;
        v_route := journal_entry_reversal_route(v_r.target_entry_id);
        IF v_route = 'source_path' THEN
            RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
        END IF;
        v_res := reverse_journal_entry_internal(v_r.target_entry_id, v_r.entry_date, v_r.memo);
        v_entry := (v_res->>'reversal_id')::uuid;
        v_code := v_res->>'code';
    ELSE
        RAISE EXCEPTION 'JOURNAL_REQUEST_KIND_UNKNOWN|%|%', v_r.label, v_r.kind;
    END CASE;

    SELECT string_agg(DISTINCT a.code, ',' ORDER BY a.code) INTO v_ctrl
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = v_entry AND a.code IN ('1100', '2000');
    IF v_ctrl IS NOT NULL AND NOT (v_r.kind = 'reversal' AND v_src = 'revaluation') THEN
        RAISE EXCEPTION 'JE_MANUAL_CONTROL_ACCOUNT|%|%', v_r.label, v_ctrl;
    END IF;

    SELECT round(COALESCE(sum(l.debit), 0), 2),
           COALESCE(bool_or(l.credit > 0 AND a.is_cash), false)
      INTO v_base, v_bank
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = v_entry;

    RETURN jsonb_build_object('entry_id', v_entry, 'journal_code', v_code,
                              'amount_base', v_base, 'credits_bank', v_bank);
END;
$function$;

-- db/functions/journal_request_dry_run.sql
-- APR-6(2026-09-25):按【批准那一刻会用的同一支过账】把一张手工凭证 / 冲销申请试跑一遍,然后整个回滚 ——
-- 分录、编号、冲销标记一样都不留。提交时跑一次(提单人当场听见引擎的原话)。
--
-- 【为什么不写一份"校验函数"】与 invoice_request_dry_run、payment_request_dry_run、payroll_request_dry_run、
-- receipt_price_request_dry_run 逐字同一条:借贷不平、科目停用、币种、汇率、GST 税码、期间锁、年结、
-- 超出当月、冲销日早于原分录、控制科目 —— 抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份。
-- 返回 journal_request_post_internal 的返回值(变量的赋值不随子事务回滚),所以 amount_base 与
-- credits_bank 从这里来。
--
-- 【借贷平衡是【延迟】触发器】trg_journal_lines_balance 在提交时才判;子事务的回滚不会让它开火。所以试跑里
-- 先把【这一支】约束触发器改成 IMMEDIATE(排着的那几条当场跑掉),再改回 DEFERRED —— 否则一张借贷不平的
-- 申请会在试跑里"过得去",直到批准那一刻的提交才炸,而那时 CFO 已经按过了。只点名这一支,不用 ALL:
-- ALL 会把调用方这笔事务里别处排着的延迟检查(库存恒等式之类)一起提前,那不是试跑该管的事。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。过账跑完抛专用 SQLSTATE PQ005,
-- 只接这一个 —— 引擎自己的任何拒绝照常往外抛。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_res jsonb;
BEGIN
    BEGIN
        v_res := journal_request_post_internal(p_request_id);
        SET CONSTRAINTS trg_journal_lines_balance IMMEDIATE;
        SET CONSTRAINTS trg_journal_lines_balance DEFERRED;
        RAISE EXCEPTION USING ERRCODE = 'PQ005', MESSAGE = 'JOURNAL_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ005' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$;

-- db/functions/journal_request_submit_internal.sql
-- APR-6(2026-09-25):提一张手工凭证 / 冲销申请 —— submit_journal_request 与 submit_journal_reversal_request
-- 都落进来的那一支。两扇门各自先问 module.finance.edit;本支不问码。
--
--   1. 日期、摘要 / 理由在写入之前就按名拒(JE_LINE_INVALID|entry_date · REVERSAL_DATE_REQUIRED ·
--      JE_MEMO_REQUIRED · JOURNAL_REVERSAL_REASON_REQUIRED)—— 否则撞上的是表上的 NOT NULL / CHECK,屏幕只能说"意外错误"。
--      【日期决定期间,所以必填、从不代填】(AGENTS.md「Dates and amounts that decide a period」)。
--   2. reversal:那张分录要在(JE_NOT_FOUND),要冲得了(已冲过 → JE_ALREADY_REVERSED),而且要落在
--      'request' 那一格 —— 有自己冲销路径的按名拒 JE_REVERSE_USE_SOURCE_PATH(journal_entry_reversal_route
--      一份判据,Q6)。同一张分录已经挂着一张在等的冲销 → JOURNAL_REQUEST_OPEN|分录|那一张(唯一索引是第二道)。
--   3. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动(assert_other_decider,按人认)。
--      没有 → JOURNAL_REQUEST_NO_OTHER_DECIDER|label。线上是 admin@:它与 tim@ 是同一个人,而二级只有 tim@。
--   4. 落一行 submitted;参数原样冻结。
--   5. 按批准那一刻会用的同一支过账试跑(journal_request_dry_run)—— 借贷不平、科目、币种、汇率、期间锁、
--      年结、超出当月、1100 / 2000,这里按引擎的原话拒。amount_base 与 credits_bank 取试跑的结果。
--   6. 审批开着:留痕 submitted,二级。关着:当场过账(journal_request_post_internal),状态 approved,
--      留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.journal_request_submit_internal(p_kind text, p_entry_date date, p_memo text, p_lines jsonb, p_target_entry_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_je    journal_entries%ROWTYPE;
    v_route text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_post  jsonb := NULL;
BEGIN
    IF p_kind = 'entry' THEN
        IF p_entry_date IS NULL THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
        END IF;
        IF p_memo IS NULL OR btrim(p_memo) = '' THEN
            RAISE EXCEPTION 'JE_MEMO_REQUIRED';
        END IF;
        IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
            RAISE EXCEPTION 'JE_LINE_INVALID|lines';
        END IF;
    ELSIF p_kind = 'reversal' THEN
        IF p_entry_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        IF p_memo IS NULL OR btrim(p_memo) = '' THEN
            RAISE EXCEPTION 'JOURNAL_REVERSAL_REASON_REQUIRED';
        END IF;
        SELECT * INTO v_je FROM journal_entries WHERE id = p_target_entry_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_target_entry_id::text, '?');
        END IF;
        v_route := journal_entry_reversal_route(v_je.id);
        IF v_route = 'reversed' THEN
            RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_je.code;
        END IF;
        IF v_route = 'source_path' THEN
            RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_je.code, v_je.source_type;
        END IF;
        SELECT q.label INTO v_open FROM journal_requests q
         WHERE q.target_entry_id = v_je.id AND q.kind = 'reversal' AND q.status = 'submitted';
        IF FOUND THEN
            RAISE EXCEPTION 'JOURNAL_REQUEST_OPEN|%|%', v_je.code, v_open;
        END IF;
    ELSE
        RAISE EXCEPTION 'JOURNAL_REQUEST_KIND_UNKNOWN|%|%', '?', COALESCE(p_kind, '?');
    END IF;

    -- label 的序号:同一种类里第几张。咨询锁串行化"数一遍 + 1",与 post_journal_entry 的编号同一个手法。
    PERFORM pg_advisory_xact_lock(hashtext('journal_request_label')::bigint);
    IF p_kind = 'entry' THEN
        SELECT count(*) + 1 INTO v_n FROM journal_requests WHERE kind = 'entry';
        v_label := 'manual journal #' || v_n::text;
    ELSE
        SELECT count(*) + 1 INTO v_n FROM journal_requests WHERE kind = 'reversal' AND target_entry_id = v_je.id;
        v_label := v_je.code || ' · reversal #' || v_n::text;
    END IF;

    PERFORM assert_other_decider('journal_request', 'decide_journal_request', 2::smallint,
                                 'JOURNAL_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO journal_requests (id, kind, status, label, entry_date, memo, lines, target_entry_id,
                                  amount_base, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label, p_entry_date, btrim(p_memo),
            CASE WHEN p_kind = 'entry' THEN p_lines END,
            CASE WHEN p_kind = 'reversal' THEN v_je.id END,
            0, auth.uid());

    v_dry := journal_request_dry_run(v_id);
    UPDATE journal_requests
       SET amount_base = (v_dry->>'amount_base')::numeric,
           credits_bank = (v_dry->>'credits_bank')::boolean
     WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('journal_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_post := journal_request_post_internal(v_id);
        UPDATE journal_requests
           SET status = 'approved', amount_base = (v_post->>'amount_base')::numeric,
               credits_bank = (v_post->>'credits_bank')::boolean,
               result_journal_entry_id = (v_post->>'entry_id')::uuid
         WHERE id = v_id;
        PERFORM record_approval_decision('journal_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场过账,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'amount_base', COALESCE(v_post->'amount_base', v_dry->'amount_base'),
        'credits_bank', COALESCE(v_post->'credits_bank', v_dry->'credits_bank'),
        'entry_id', v_post->>'entry_id',
        'journal_code', v_post->>'journal_code');
END;
$function$;

-- db/functions/submit_journal_request.sql
-- APR-6(2026-09-25):财务提一张手工凭证 —— 参数就是手工凭证页一直交给 post_journal_entry 的那一组
-- (凭证日、摘要、行),只是少了 source_type 与 source_id:过出来的永远是 'manual',source_id 指回申请
-- (grilling Q1 · Q3)。CFO 批准那一刻按这一组过账。人手里能过一张手工凭证的门,只剩这一扇。
-- 门 module.finance.edit(矩阵「做:= 不变」);其余全在 journal_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_journal_request(p_entry_date date, p_memo text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN journal_request_submit_internal('entry', p_entry_date, p_memo, p_lines, NULL::uuid);
END;
$function$;

-- db/functions/submit_journal_reversal_request.sql
-- APR-6(2026-09-25):财务提一张冲销申请 —— 冲一张【没有自己冲销路径】的分录(手工凭证,以及 sale ·
-- stocktake · writeoff · prepayment · revaluation · depreciation · asset_disposal · shipment · 工资付款分录;
-- grilling Q6 (i)(iii))。参数与 reverse_journal_entry 一字不差(分录、冲销日、理由),只是冲销日【必填】
-- (它决定期间 —— AGENTS.md:决定期间的日期从不代填)。CFO 批准那一刻按这一组冲。
-- 门 module.finance.edit(原 reverse_journal_entry 的门);其余全在 journal_request_submit_internal。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.submit_journal_reversal_request(p_entry_id uuid, p_reversal_date date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.finance.edit');
    RETURN journal_request_submit_internal('reversal', p_reversal_date, p_reason, NULL::jsonb, p_entry_id);
END;
$function$;

-- db/functions/decide_journal_request.sql
-- APR-6(2026-09-25):CFO 批准或驳回一张手工凭证 / 冲销申请。批准【当场过账】(grilling Q3),按提交时冻下来的
-- 那一组 —— 日期就是提单人填的那一天。
--
-- 【门】module.finance.view + data.view_prices —— 与付款、贷项申请同一对码(凭证页的门,加上看得见金额的那个码;
-- docs/approvals.md §5)。【不是】module.finance.edit:那是提单的码。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】二级审批人,每一张、不分档,从不经按金额分档的那一支(N1 对 journal_entries 退休,Q2)。
-- 【四眼】forbid_self_approval(提单人, NULL, …)—— 一张手工凭证不是谁的"自己的单据",主角那条腿对谁都不成立;
-- 提单人那条腿按人认:admin@ 提的,tim@ 批不了(同一个人)—— 所以提交时就按名拒
-- JOURNAL_REQUEST_NO_OTHER_DECIDER,不让它挂到这里。self_approval_exception 不认本类型,R2 不适用。
--
-- 【批准之前不另查】批准就是那一次真的过账:期间在等待中被锁上(PERIOD_LOCKED)、年结(YEAR_CLOSED)、
-- 科目被停用、那张要冲的分录已经被别的路冲掉 —— 全按引擎原话拒,整笔回滚,申请仍在等;CFO 驳回,
-- 或财务撤回、换一个开着的日子再提(Q4:锁永远赢,从不因为一张在等的申请而被拒)。驳回从不检查这些:
-- 驳回一张坏掉的申请,正是出路。驳回要理由。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
--
-- 【过出来那张分录的 created_by 是批准的 CFO】(列默认 auth.uid(),而过账发生在批准这一刻)。职责分离那条
-- 规矩(sod_manual_posters_in)因此经 journal_requests.result_journal_entry_id 找回【提单人】—— Q5:
-- 批准的 CFO 不是"记手工凭证的人"。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.decide_journal_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r    journal_requests%ROWTYPE;
    v_post jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_r FROM journal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'journal_request');
    PERFORM require_approver_for(2::smallint);

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'JOURNAL_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE journal_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('journal_request', p_request_id, 'rejected', 2::smallint,
                                         btrim(p_notes));
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    v_post := journal_request_post_internal(p_request_id);

    UPDATE journal_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           amount_base = (v_post->>'amount_base')::numeric,
           credits_bank = (v_post->>'credits_bank')::boolean,
           result_journal_entry_id = (v_post->>'entry_id')::uuid
     WHERE id = p_request_id;
    PERFORM record_approval_decision('journal_request', p_request_id, 'approved', 2::smallint,
                                     NULLIF(btrim(COALESCE(p_notes, '')), ''));
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'kind', v_r.kind,
                              'entry_id', v_post->>'entry_id',
                              'journal_code', v_post->>'journal_code',
                              'amount_base', v_post->'amount_base');
END;
$function$;

-- db/functions/withdraw_journal_request.sql
-- APR-6(2026-09-25,grilling Q3):撤回一张在等的手工凭证 / 冲销申请。
-- 谁能撤:提单人本人(按人认 —— self_leg 说这个账号就是提单人那个人),或任何持 module.finance.edit 的人。
-- 只撤 submitted。撤回不过账,只是放弃;记在本行上(谁、何时、为什么),【不】写 approval_log ——
-- 撤回不是一次决定(付款、工资、收货定价、贷项申请同一条)。
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.withdraw_journal_request(p_request_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r journal_requests%ROWTYPE;
BEGIN
    SELECT * INTO v_r FROM journal_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF self_leg(v_r.created_by, NULL, auth.uid()) <> 'raiser' THEN
        PERFORM require_permission('module.finance.edit');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'JOURNAL_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE journal_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid(),
           withdraw_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$;

-- db/functions/reverse_journal_entry.sql
-- 手工冲销一张分录(module.finance.edit)。付款、转账、代扣税缴纳的分录按名拒,走各自的申请。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q5):工资期的过账分录与它的冲销也按名拒 —— 撤销走撤销申请。
-- ★ APR-5a(2026-09-25,grilling Q11 ④):发票与贷项通知的分录(以及它们的冲销)也按名拒 —— 走作废 / 贷项申请。
-- ★★ APR-6(2026-09-25,grilling Q6):**这扇门从此一张都不冲 —— 它只会拒,而且说出去哪儿冲。**
--   · 有自己冲销路径的(journal_entry_reversal_route = 'source_path':上面那些,加上 expense · freight ·
--     allocation · processing_cost · year_close)→ JE_REVERSE_USE_SOURCE_PATH|编号|source_type,与以前同一句。
--   · 其余一切('request':手工凭证,以及没有自己路径的系统分录)→ JOURNAL_NEEDS_APPROVED_REQUEST|编号 ——
--     冲它要提一张冲销申请(submit_journal_reversal_request),CFO 批准那一刻才冲(矩阵「手工凭证与冲销 |
--     财务 | CFO」)。批准就是执行,所以永远不存在"批了还没冲"的申请 —— 这扇门因此没有"带着申请"那一支
--     (APR-5a 的 create_credit_note / void_invoice 同形)。
--   · 已经冲过的 → JE_ALREADY_REVERSED(与引擎同一句);找不到 → JE_NOT_FOUND。
--   签名不变:旧的冲销钮在破窗里调它,得到的是一句按名的拒绝,而不是一次不经批准的冲销。
--   冲销的本体一直在 reverse_journal_entry_internal(EXECUTE 早已收回),各单据自己的冲销路径照旧调它。

CREATE OR REPLACE FUNCTION public.reverse_journal_entry(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_src   text;
    v_code  text;
    v_route text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT source_type, code INTO v_src, v_code FROM journal_entries WHERE id = p_entry_id;
    v_route := journal_entry_reversal_route(p_entry_id);
    IF v_route IS NULL THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_entry_id::text, '?');
    END IF;
    IF v_route = 'reversed' THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_code;
    END IF;
    IF v_route = 'source_path' THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_SOURCE_PATH|%|%', v_code, v_src;
    END IF;
    RAISE EXCEPTION 'JOURNAL_NEEDS_APPROVED_REQUEST|%', v_code;
END;
$function$;

-- db/functions/sod_manual_posters_in.sql
-- SOD-1:问法① —— "这个期间里,谁记过手工凭证?"返回一个主语集合。
--
-- 【为什么只算 source_type='manual'】其余每一种 source_type 都是另一个受控动作的
-- 【后果】(一笔付款、一次销售、一次工资过账),各有各的门。把它们算进来等于
-- "凡引起过任何一笔分录的人都不许关账" —— 在一个财务只有一个人的公司里
-- 那不是控制,是一把锁死的门。要防的是那一笔【自由裁量的调整】,
-- 然后把期间锁上让它没人再看得见。范围写在这里,不留给读的人推断。
--
-- ★ APR-6(2026-09-25,grilling Q5):**"谁记的"从此是【提单人】,不是过账那一刻的 auth.uid()。**
--   APR-6 起一张手工凭证在 CFO 批准那一刻才过账,于是 journal_entries.created_by(列默认 auth.uid())是
--   批准的 CFO。照旧读它,规矩就会绑错人:CFO(以及与他同一个人的 admin@)从此锁不了那个月,而真正敲
--   那一笔的财务锁得了 —— 财务是提单人时,两边一起锁死,月结没人关得了。所以:
--     主语 = COALESCE(申请的 created_by, 分录的 created_by),经 journal_requests.result_journal_entry_id 接回。
--   · APR-6 之前直接过的手工凭证(没有申请)照旧读 created_by —— JE-2026-0079 仍然算 chooer@。
--   · 范围多了一类:【经冲销申请冲掉的系统分录】(冲销件抄原分录的 source_type,例如 'sale')。
--     从凭证页冲一张 sale 分录是一个人的裁量,与手敲一张凭证是同一件事,所以它的提单人也算。
--   · 批准的 CFO 【不是】记手工凭证的人 —— 他看过、批过,那是四眼的另一只眼。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.sod_manual_posters_in(p_from date, p_to date)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(array_agg(DISTINCT COALESCE(jr.created_by, je.created_by)), '{}'::uuid[])
      FROM journal_entries je
      LEFT JOIN journal_requests jr ON jr.result_journal_entry_id = je.id
     WHERE (je.source_type = 'manual' OR jr.id IS NOT NULL)
       AND COALESCE(jr.created_by, je.created_by) IS NOT NULL
       AND je.entry_date >= COALESCE(p_from, '-infinity'::date)
       AND je.entry_date <= p_to;
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
$function$;

COMMENT ON FUNCTION public.approval_pending_documents() IS
'APR-3(Tim 的 Q6):哪些单据正在等人批 —— 逐行,一份判据三个读它的人(屏幕的逐链计数 · 关闭那道闸要的编号 · APPROVALS_POLICY_WOULD_STRAND 要的金额)。★ blocks_disable 把两个长得一样的数分开:「有多少在等人批」每条链都算,「关掉审批会搁死谁」只有一部分链算。判别的那一句话:这条链的决定函数在审批关着时还跑不跑得动 —— 跑不动才 true。采购单 true(approve_purchase_order 开头就 RAISE APPROVALS_NOT_ENABLED);报销单 false;付款 · 工资 · 收货定价 · 贷项 / 作废 · 手工凭证五种申请与发货放行 true(它们的决定函数同样在审批关着时按名拒,fixed_level = 2)。★ 盘点不在本表里(Tim 的 Q4:open 是"正在点",不是"在等人批"),工单也不在(它没有等人批的队列)。amount_base 为 NULL = 这一张分不了档,不读成零。';

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
            ARRAY['module.finance.view', 'data.view_prices']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- ── 4 · journal_entries / journal_lines:两条 INSERT 写策略拿掉;两支语句级守卫 ─────────
DROP POLICY "journal_entries insert by permission" ON public.journal_entries;
DROP POLICY "journal_lines insert by permission" ON public.journal_lines;
CREATE TRIGGER trg_journal_entries_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.journal_entries
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_journal_direct_write();
CREATE TRIGGER trg_journal_lines_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.journal_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_journal_direct_write();

-- ── 5 · EXECUTE:过账核心与三支内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)──
REVOKE EXECUTE ON FUNCTION public.post_journal_entry(date, text, text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_submit_internal(text, date, text, jsonb, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_post_internal(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.journal_request_dry_run(uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_journal_direct_write() FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.journal_entry_reversal_route(uuid) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_journal_request(date, text, jsonb) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submit_journal_reversal_request(uuid, date, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.decide_journal_request(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.withdraw_journal_request(uuid, text) FROM PUBLIC, anon;

-- ── 6 · operations_now:加一支 journal_request_pending(镜像原样)────────────────
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
CREATE FUNCTION pg_temp.a6_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE a6_pending_after ON COMMIT DROP AS
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

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a6_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a6_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR6_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR6_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;分录与留痕一行没变;申请表是空的;职责分离的读数没变
    IF EXISTS ((SELECT b.k, b.id FROM a6_pending_before b EXCEPT SELECT a.k, a.id FROM a6_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a6_pending_after a EXCEPT SELECT b.k, b.id FROM a6_pending_before b)) THEN
        RAISE EXCEPTION 'APR6_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a6_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'manual') AS manual_entries,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total) n) THEN
        RAISE EXCEPTION 'APR6_PROOF|a journal / log count changed: % → %',
            (SELECT row(c.*)::text FROM a6_counts_before c), (SELECT row(n.*)::text FROM (SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT count(*) FROM journal_entries WHERE source_type = 'manual') AS manual_entries,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total) n);
    END IF;
    IF EXISTS (SELECT 1 FROM journal_requests) THEN
        RAISE EXCEPTION 'APR6_PROOF|journal_requests is not empty';
    END IF;
    IF (SELECT array(SELECT unnest(posters) ORDER BY 1) FROM a6_sod_before)
       IS DISTINCT FROM array(SELECT unnest(sod_manual_posters_in(NULL, '9999-12-31'::date)) ORDER BY 1) THEN
        RAISE EXCEPTION 'APR6_PROOF|the manual-poster reading changed with no request in existence';
    END IF;

    -- ④ 结构:两张分录表上没有任何写策略;两支守卫挂上;过账核心与内层算子 authenticated 调不到;
    --    除 post_journal_entry 自己之外,调它的每一支函数都是 SECURITY DEFINER —— 一支 INVOKER 调用者会在
    --    收回之后以 42501 断掉(那就是一条被本刀弄坏的系统路径);旧的冲销门只会拒;名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('journal_entries', 'journal_lines') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR6_PROOF|a journal write policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_journal_entries_direct_write', 'trg_journal_lines_direct_write');
    IF v_n <> 2 THEN RAISE EXCEPTION 'APR6_PROOF|expected 2 journal guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY['public.post_journal_entry(date, text, text, uuid, jsonb)', 'public.journal_request_submit_internal(text, date, text, jsonb, uuid)', 'public.journal_request_post_internal(uuid)', 'public.journal_request_dry_run(uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR6_PROOF|authenticated can still execute: %', v_bad; END IF;
    SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO v_bad FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prosrc ~ 'post_journal_entry\s*\('
       AND p.proname <> 'post_journal_entry' AND NOT p.prosecdef;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'APR6_PROOF|an INVOKER function calls post_journal_entry and would break: %', v_bad;
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace AND p.prosrc ~ 'post_journal_entry\s*\('
       AND p.proname <> 'post_journal_entry';
    RAISE NOTICE 'APR6 posting callers (all SECURITY DEFINER): %', v_n;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.reverse_journal_entry(uuid, date, text)'::regprocedure)
       NOT LIKE '%JOURNAL_NEEDS_APPROVED_REQUEST%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.reverse_journal_entry(uuid, date, text)'::regprocedure)
       LIKE '%reverse_journal_entry_internal%' THEN
        RAISE EXCEPTION 'APR6_PROOF|reverse_journal_entry still does the work itself';
    END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'journal_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR6_PROOF|journal_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('journal_request', 'decide_journal_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR6_PROOF|nobody can decide a journal request'; END IF;
    RAISE NOTICE 'APR6 deciders for journal_request: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a6_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR6 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a6_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR6_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a6_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a6_pending_decider_check(boolean);

COMMIT;

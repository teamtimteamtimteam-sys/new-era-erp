-- db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql
-- PAYROLL-APR-1 —— 工资过账与撤销要 CFO 批准,批之前什么都不过账(docs/role-matrix.md §5)。
-- 由 db/scripts/build_payrollapr1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(grilling Q1–Q9,Tim 2026-09-24 全部接受)
--   ① payroll_requests:过账(post)或撤销过账(reversal)的申请。财务提(module.hr.edit),
--      CFO 批每一张、不分档(require_approver_for(2)),财务执行。审批关着时生下来就是 approved。
--   ② ★ 工资期是【公司的单据】(Q1 (A)):主角那条腿对谁都不成立,提单人那条照判、按人认。
--      CFO 批一期含他自己工资行的工资,留痕的备注说出来;不标 self_decided。
--   ③ post_payroll_period / unpost_payroll_period 成了【外门】:没有这一期、这一种的已批申请就
--      按名拒(PAYROLL_NEEDS_APPROVED_REQUEST)。函数体搬进 *_internal(authenticated 调不到),
--      批准与提交各按同一支引擎试跑一遍再回滚(payroll_request_dry_run)。
--      ☞ unpost_payroll_period 的签名从 (uuid, text) 改成 (uuid):理由取申请上那一句。
--   ④ 等待期间冻住(Q4):保存拒 PAYROLL_REQUEST_OPEN;那个月的考勤不许重开;批准与执行各比一次
--      snapshot(PAYROLL_CHANGED_SINCE_REQUEST)。
--   ⑤ 三扇侧门(Q5):直连写 status / 过账列 → PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;
--      已过账或在等批的期间,直连写它的行与被批的数 → PAYROLL_LINES_FROZEN;
--      reverse_journal_entry 冲工资过账分录(或它的冲销)→ JE_REVERSE_USE_SOURCE_PATH。
--   ⑥ 挂着撤销申请时,三支付款函数按名拒(Q6,PAYROLL_REVERSAL_REQUESTED)。
--   ⑦ 引擎登记(Q8):approval_chain_gates 一行(二级,module.hr.view + data.view_pay);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);
--      approval_log 的主体类型与读策略各加 payroll_request;record_approval_decision 一支
--      (金额 = gross 折本位币,N4);operations_now 一支 payroll_request_pending(data.view_pay)。
--
-- 【不做什么】不新增任何权限码(Q8),所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;
-- approval_log、journal_entries、工资期与工资行一行没变;授权一条没变;每一张在途单据都还有一个
-- 【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.payroll_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|payroll_requests already exists';
    END IF;
    IF to_regprocedure('public.unpost_payroll_period(uuid, text)') IS NULL THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|unpost_payroll_period(uuid, text) is not the live signature';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('trg_payroll_periods_direct_write',
                                                        'trg_payroll_lines_direct_write')) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PRE|a PAYROLL-APR-1 trigger already exists';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE pa1_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');
CREATE TEMP TABLE pa1_counts_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM approval_log) AS approval_log, (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM payroll_periods WHERE status = 'posted') AS periods_posted,
       (SELECT count(*) FROM payroll_periods WHERE status = 'draft') AS periods_draft,
       (SELECT count(*) FROM payroll_lines) AS lines,
       (SELECT count(*) FROM payroll_lines WHERE paid_at IS NOT NULL) AS lines_paid;
CREATE TEMP TABLE pa1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · payroll_requests(镜像原样)──────────────────────────────────────────
CREATE TABLE public.payroll_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_period_id       uuid NOT NULL REFERENCES public.payroll_periods (id) ON DELETE RESTRICT,
    kind                    text NOT NULL CHECK (kind IN ('post', 'reversal')),
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'withdrawn', 'approved', 'rejected', 'executed')),
    label                   text NOT NULL,
    -- ── 冻结的那一组数(审批人批的就是它)──────────────────────────────────────
    snapshot                jsonb NOT NULL,
    currency                text NOT NULL REFERENCES public.currencies (code),
    fx_rate                 numeric NOT NULL CHECK (fx_rate > 0),
    gross_total             numeric NOT NULL,
    -- 留痕与分档用的金额 = gross_total 折本位币(Tim 的 N4:工资按 gross 路由)
    amount_base             numeric NOT NULL,
    notes                   text,
    -- ── 决定与执行 ───────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    executed_at             timestamptz,
    executed_by             uuid,
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT payroll_requests_reversal_reason CHECK (
        kind <> 'reversal' OR btrim(COALESCE(notes, '')) <> ''),
    CONSTRAINT payroll_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT payroll_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT payroll_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL)),
    CONSTRAINT payroll_requests_executed_shape CHECK (
        (status = 'executed') = (executed_at IS NOT NULL)
        AND (executed_at IS NULL) = (executed_by IS NULL)
        AND (executed_at IS NULL) = (result_journal_entry_id IS NULL))
);

COMMENT ON TABLE public.payroll_requests IS
    'PAYROLL-APR-1:工资过账与撤销的申请(Tim 的矩阵 §5:财务提,CFO 批每一张,不分档;批之前什么都不过账)。submitted → approved(CFO)→ executed(财务按过账 / 撤销;分录只在这一刻过账)。另有 rejected(要理由)与 withdrawn(submitted 或 approved)。审批关着时生下来就是 approved(auto_approved)。工资期是公司的单据:主角那条腿对谁都不成立(Tim 的 Q1 (A)),提单人那条照判、按人认。snapshot 冻结批的那一组数,批准与执行各比一次(PAYROLL_CHANGED_SINCE_REQUEST)。一个期间同时只挂一张未了结的申请。';

COMMENT ON COLUMN public.payroll_requests.amount_base IS
    'PAYROLL-APR-1:gross_total × fx_rate(期间自己的汇率),两位小数 —— approval_log 冻结的金额(Tim 的 N4:工资按 gross 路由;这条链不分档,金额只供审批人读与留痕)。';

CREATE UNIQUE INDEX payroll_requests_one_open_per_period
    ON public.payroll_requests (payroll_period_id)
    WHERE status IN ('submitted', 'approved');
CREATE INDEX payroll_requests_payroll_period_id_rel ON public.payroll_requests (payroll_period_id);
CREATE INDEX payroll_requests_result_journal_entry_id_rel ON public.payroll_requests (result_journal_entry_id);

ALTER TABLE public.payroll_requests ENABLE ROW LEVEL SECURITY;

-- 读:与 payroll_periods 同一个码。写:一条策略都不给 —— 只经 submit / withdraw / decide 与
-- post_payroll_period / unpost_payroll_period 五支函数(全是 SECURITY DEFINER)。
CREATE POLICY "payroll_requests select by permission" ON public.payroll_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.payroll_requests FROM anon;

-- ── 2 · approval_log:主体类型加 payroll_request;读策略加同名一支 ────────────
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
                            'payroll_request'));
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
            ELSE false
        END
    );

-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/payroll_period_fingerprint.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q4):一个工资期【此刻】的那一组数 —— 审批人批的就是它。
--
-- 五个合计、行数、逐行摘要(每人一行:员工 · gross · 雇主 CPF · 员工 CPF · 其它扣款 · 净额)、
-- 发薪日、币种、汇率。submit_payroll_request 把它存进 payroll_requests.snapshot;
-- decide_payroll_request 与两支执行函数各再算一次,不相等就按名拒
-- (PAYROLL_CHANGED_SINCE_REQUEST)。
--
-- 【为什么要逐行摘要,不只比合计】两个人的数对调,合计一个都不变 —— 而批的是【谁拿多少】。
-- 【为什么数字按原样变成文本】5000 与 5000.00 是同一个钱、不同的字;重存一次换了写法也会
-- 读成"变了"。那是安全的方向:它只会多拒,不会漏放(而申请开着时保存本来就被拒)。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回(db/views/zzz_function_grants.sql)。
-- 期间不存在 → NULL;调用方先查过期间,所以这个 NULL 不会被读成"没变"。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.payroll_period_fingerprint(p_period_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT jsonb_build_object(
               'payment_date', p.payment_date,
               'currency', p.currency,
               'fx_rate', p.fx_rate::text,
               'gross_total', p.gross_total::text,
               'employer_cpf_total', p.employer_cpf_total::text,
               'employee_cpf_total', p.employee_cpf_total::text,
               'other_deductions_total', p.other_deductions_total::text,
               'net_pay_total', p.net_pay_total::text,
               'line_count', (SELECT count(*) FROM payroll_lines l WHERE l.payroll_period_id = p.id),
               'lines_digest', (SELECT md5(COALESCE(string_agg(
                                    l.employee_id::text || ':' || l.gross_pay::text || ':' || l.employer_cpf::text
                                    || ':' || l.employee_cpf::text || ':' || l.other_deductions::text
                                    || ':' || l.net_pay::text, ',' ORDER BY l.employee_id), ''))
                                  FROM payroll_lines l WHERE l.payroll_period_id = p.id))
      FROM payroll_periods p
     WHERE p.id = p_period_id
$function$
;

-- db/functions/payroll_period_frozen.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q4 · Q5):这个工资期的数【此刻能不能被直接改】——
-- 返回 'posted'(已过账)、'requested'(挂着一张未了结的申请)或 'open'。永不返回 NULL:
-- 期间不存在也答 'open'(那是插入一行新期间时的情形,守卫另有判据)。
--
-- 【它为什么必须是 DEFINER】两支守卫(guard_payroll_period_direct_write ·
-- guard_payroll_line_direct_write)是 INVOKER —— 它们要用 row_security_active 分出
-- 直连写与属主路径。可 payroll_requests 的读策略要 module.hr.view,一个持 hr.edit 却不持
-- hr.view 的写入者在 INVOKER 里读它会拿到【零行】,守卫就会把"看不见"读成"没有申请"而
-- 静默放行 —— 正是 AGENTS.md 那条「守卫对主语缺席这一格是瞎的」。
--
-- 【它为什么不能收回 EXECUTE,也不能加调用者检查】调它的是 INVOKER 触发器,EXECUTE 按
-- 当前用户判 —— 收回它,每一次直连写都 42501;加 has_permission 门,持 hr.edit 的写入者照样过、
-- 不持的人本来就被 RLS 挡在写外,门什么都不守(period_close_floor 逐字同一条理由)。
-- 它吐出的只有一个状态词,而那个状态在工资期页上本来就看得见。
-- 两处 allowlist 同改:db/check_mirrors.py 的 DEFINER_NO_CHECK_ALLOWED 与
-- db/verify_rebuild.py 的 DEFINER_UNCHECKED_EXEC_ALLOWED。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.payroll_period_frozen(p_period_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
               WHEN EXISTS (SELECT 1 FROM payroll_periods p WHERE p.id = p_period_id AND p.status = 'posted')
                   THEN 'posted'
               WHEN EXISTS (SELECT 1 FROM payroll_requests r WHERE r.payroll_period_id = p_period_id
                                AND r.status IN ('submitted', 'approved'))
                   THEN 'requested'
               ELSE 'open'
           END
$function$
;

-- db/functions/post_payroll_period_internal.sql
-- PAYROLL-APR-1(2026-09-24):工资过账的【引擎】—— 原 post_payroll_period 的函数体,
-- 只拿掉了 require_permission('module.hr.edit')。
--
-- 【为什么拆出来】批准之前要按【执行那一刻会用的同一支引擎】试跑一遍(payroll_request_dry_run),
-- 而批准的人是 CFO,CFO 不持 module.hr.edit。与 record_payment_internal 同一个理由、同一个形状:
-- 引擎没有调用者检查,靠的是调不到 —— EXECUTE 已从 authenticated 收回
-- (db/views/zzz_function_grants.sql)。唯一的外门是 post_payroll_period(要一张已批的申请)。
--
-- 函数体一个判据都没改:考勤依据(ATTEND-1)、币种、分录的五条腿、期间锁,原样。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql;
--       the body is post_payroll_period's as of db/migrations/2026-08-04-fin4-pay-per-employee.sql + ATTEND-1.

CREATE OR REPLACE FUNCTION public.post_payroll_period_internal(p_payroll_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_p     record;
    v_bank  text;
    v_lines jsonb := '[]'::jsonb;
    v_je    jsonb;
    v_cpf   numeric;
BEGIN
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_payroll_period_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ══ ATTEND-1:★【过账要有依据,而依据是一句【人的断言】】★ ═════════════
    -- 【为什么拒在这里,而不是 upsert】记录服务商送回来的数字只是【捕获一个
    -- 已经发生的事实】,拦住它只会把那些数字推到系统外面去保管。
    -- 过账才是公司认下这些数字的那一刻,依据必须在这一刻存在。
    -- 【它并不检查"考勤对不对"】系统无从知道;它检查的是【有没有人说过
    -- 这个月的底稿齐全了】—— 与 finance_settings.system_start_date 是
    -- 【声明】而不是【推断】同一条。
    -- 【为什么必须是拒绝,而不是警告】一次静静地把"缺勤未知"当成"全勤"的
    -- 工资过账,是这里所有选项里最坏的一个;而一句没有牙齿的警告,
    -- 在一个月一次的收尾动作上会被直接点过去 —— 这个仓库为"学会忽略警报"
    -- 付过账。
    IF NOT EXISTS (
        SELECT 1 FROM attendance_periods ap
         WHERE ap.status = 'complete'
           AND ap.period_month = date_trunc('month', v_p.period_month)::date
    ) THEN
        RAISE EXCEPTION 'PAYROLL_ATTENDANCE_NOT_COMPLETE|%|%',
            v_p.code, to_char(v_p.period_month, 'YYYY-MM');
    END IF;

    -- FIN-4:过账【不碰银行】—— 钱还没出去。净额挂 2300 应付净薪,
    -- 逐人付款(pay_payroll_lines)时才贷银行,一人一条,各自对账。
    -- OPS-8:"支持哪些币种"就是 currencies 表本身,不是这里另抄一份码表
    IF NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = v_p.currency) THEN
        RAISE EXCEPTION 'PAYROLL_CURRENCY_UNSUPPORTED|%', v_p.currency;
    END IF;

    -- 借 6100 工资薪金(服务商口径的 gross)
    IF v_p.gross_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6100', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.gross_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 借 6110 公积金-雇主部分(公司成本,不从员工工资里出)
    IF v_p.employer_cpf_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '6110', 'side', 'debit', 'currency', v_p.currency,
            'amount_ccy', v_p.employer_cpf_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2400 公积金应付:雇主 + 员工两侧合计,汇给公积金局之前都欠着
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2400', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_cpf, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2200 应计费用:服务商【代公司扣下】的其它款项,在汇出去之前挂在这里。
    -- 【注意区分】如果某项扣款本质上是"公司成本变少"(而不是替员工代扣代缴),
    -- 那它就不该出现在这里 —— 应该让服务商把它并进 gross 里去。
    IF v_p.other_deductions_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2200', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.other_deductions_total, 'fx_rate', v_p.fx_rate);
    END IF;
    -- 贷 2300 应付净薪:实发净额,付给每个人之前都欠着
    IF v_p.net_pay_total > 0 THEN
        v_lines := v_lines || jsonb_build_object(
            'account_code', '2300', 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_p.net_pay_total, 'fx_rate', v_p.fx_rate);
    END IF;

    -- 期间锁在 post_journal_entry 内生效(PERIOD_LOCKED 原样上抛)
    v_je := post_journal_entry(
        v_p.payment_date,
        'Payroll ' || v_p.code,
        'payroll',
        v_p.id,
        v_lines
    );

    UPDATE payroll_periods
    SET status = 'posted', journal_entry_id = (v_je->>'entry_id')::uuid, updated_by = v_user
    WHERE id = p_payroll_period_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_payroll_period_id,
        'code', v_p.code,
        'journal_code', v_je->>'code',
        'gross_total', v_p.gross_total,
        'employer_cpf_total', v_p.employer_cpf_total,
        'employee_cpf_total', v_p.employee_cpf_total,
        'net_pay_total', v_p.net_pay_total
    );
END;
$function$

;

-- db/functions/unpost_payroll_period_internal.sql
-- PAYROLL-APR-1(2026-09-24):撤销工资过账的【引擎】—— 原 unpost_payroll_period(uuid, text)
-- 的函数体,只拿掉了 require_permission('module.hr.edit')。理由与 post_payroll_period_internal
-- 同一条:CFO 批准时要以同一支引擎试跑,而 CFO 不持 hr.edit。EXECUTE 已从 authenticated 收回;
-- 唯一的外门是 unpost_payroll_period(uuid)(要一张已批的撤销申请,理由取申请上那一句)。
--
-- 函数体一个判据都没改:已付的行 / CPF / 扣款按名拒,冲销日 = reversal_date_for(AP-RECON-1 B)。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.unpost_payroll_period_internal(p_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_p    record;
    v_je   jsonb;
BEGIN
    SELECT * INTO v_p FROM payroll_periods
    WHERE id = p_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;
    -- FIN-4:已有工资行付了钱,冲销周期会让那些结算变孤儿 —— 拒绝,先冲付款
    IF EXISTS (SELECT 1 FROM payroll_lines
               WHERE payroll_period_id = p_id AND paid_at IS NOT NULL) THEN
        RAISE EXCEPTION 'PAYROLL_LINES_PAID|%', v_p.code;
    END IF;
    -- FIN-5:CPF / 代扣款已汇出的期间同理 —— 先冲那笔汇款
    IF v_p.cpf_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_CPF_PAID|%', v_p.code;
    END IF;
    IF v_p.deductions_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_DEDUCTIONS_PAID|%', v_p.code;
    END IF;

    -- 冲销分录;原分录留在账上并被标记为已冲销 —— 不删账
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个。薪资按【发薪日】过账,而发薪日
    -- 可以晚于今天(28 号过账、月末发薪);撤回一张还没到发薪日的薪资是正当的更正,
    -- 所以冲销落在发薪日,而不是被 REVERSAL_BEFORE_ORIGINAL 拒掉。
    v_je := reverse_journal_entry_internal(v_p.journal_entry_id, reversal_date_for(v_p.journal_entry_id), 'Payroll reversal ' || v_p.code);

    UPDATE payroll_periods
    SET status = 'draft',
        journal_entry_id = NULL,
        notes = COALESCE(notes || E'\n', '')
                || '[' || to_char(now(), 'YYYY-MM-DD HH24:MI') || ' unposted] ' || btrim(p_reason),
        updated_by = v_user
    WHERE id = p_id;

    RETURN jsonb_build_object(
        'payroll_period_id', p_id,
        'code', v_p.code,
        'status', 'draft',
        'reversal_journal_code', v_je->>'code'
    );
END;
$function$;

-- db/functions/payroll_request_dry_run.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q7):按【执行那一刻会用的同一支引擎】把一张工资申请
-- 试跑一遍,然后整个回滚 —— 分录、编号、期间状态一样都不留。
--
-- 【为什么不写一份"校验函数"】与 payment_request_dry_run 逐字同一条:考勤依据、币种、期间锁、
-- 已付的行 / CPF / 扣款,抄一份出来,写下那天一致、之后悄悄分开。试跑【就是】那一份,
-- 审批人看见的拒绝是引擎自己的原话。
--
-- 【怎么做到"整个回滚"】带 EXCEPTION 子句的块就是一个子事务。引擎跑完抛专用 SQLSTATE
-- PQ002,只接这一个 —— 引擎自己的任何拒绝(PAYROLL_ATTENDANCE_NOT_COMPLETE、PERIOD_LOCKED、
-- PAYROLL_LINES_PAID……)照常往外抛。
-- 不认识的种类按名拒(PAYROLL_REQUEST_KIND_UNKNOWN)—— PAY-REQ-1 Batch B 在付款申请上
-- 记过那个 ELSE 的教训。
--
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.payroll_request_dry_run(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   payroll_requests%ROWTYPE;
    v_res jsonb;
BEGIN
    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    BEGIN
        CASE v_r.kind
        WHEN 'post' THEN
            v_res := post_payroll_period_internal(v_r.payroll_period_id);
        WHEN 'reversal' THEN
            v_res := unpost_payroll_period_internal(v_r.payroll_period_id, v_r.notes);
        ELSE
            RAISE EXCEPTION 'PAYROLL_REQUEST_KIND_UNKNOWN|%|%', v_r.label, v_r.kind;
        END CASE;
        RAISE EXCEPTION USING ERRCODE = 'PQ002', MESSAGE = 'PAYROLL_REQUEST_DRY_RUN';
    EXCEPTION WHEN SQLSTATE 'PQ002' THEN
        NULL;
    END;
    RETURN v_res;
END;
$function$
;

-- db/functions/post_payroll_period.sql
-- 工资过账的【外门】—— PAYROLL-APR-1(2026-09-24)起,它只执行一张【已批准】的过账申请。
--
-- Tim 的矩阵 §5:工资过账,财务做,CFO 批每一张、不分档;**批之前什么都不过账**(grilling Q3)。
-- 所以这支函数:
--   ① 仍要 module.hr.edit(做的人是财务,与从前同一个码);
--   ② 找【这个期间、kind = 'post'、status = 'approved'】的那一张申请 —— 没有就按名拒
--      PAYROLL_NEEDS_APPROVED_REQUEST|<期间编号>|post。审批关着时申请生下来就是 approved,
--      所以关着的时候这条路照样走得通,只是多了一张 auto_approved 的申请;
--   ③ 批的那一组数与此刻的数再比一次(PAYROLL_CHANGED_SINCE_REQUEST);
--   ④ 交给引擎 post_payroll_period_internal(考勤、币种、分录、期间锁原样),
--      把申请标成 executed 并记下那张分录。
-- 执行的人可以就是提单人(PAY-REQ-1 的 Q3:四眼在"提"与"批"之间)。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql; the door shape by
--       db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.post_payroll_period(p_payroll_period_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p   payroll_periods%ROWTYPE;
    v_r   payroll_requests%ROWTYPE;
    v_res jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
     WHERE id = p_payroll_period_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status = 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
    END IF;

    SELECT * INTO v_r FROM payroll_requests
     WHERE payroll_period_id = p_payroll_period_id AND kind = 'post' AND status = 'approved'
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NEEDS_APPROVED_REQUEST|%|post', v_p.code;
    END IF;
    IF payroll_period_fingerprint(p_payroll_period_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_res := post_payroll_period_internal(p_payroll_period_id);

    UPDATE payroll_requests
       SET status = 'executed', executed_at = now(), executed_by = auth.uid(),
           result_journal_entry_id = (SELECT journal_entry_id FROM payroll_periods WHERE id = p_payroll_period_id)
     WHERE id = v_r.id;

    RETURN v_res || jsonb_build_object('request_id', v_r.id, 'request_label', v_r.label);
END;
$function$
;

-- 旧签名 (uuid, text) 退场:理由取申请上那一句(见 unpost_payroll_period 抬头)
DROP FUNCTION public.unpost_payroll_period(uuid, text);

-- db/functions/unpost_payroll_period.sql
-- 撤销工资过账的【外门】—— PAYROLL-APR-1(2026-09-24)起,它只执行一张【已批准】的撤销申请。
--
-- Tim 的矩阵 §5:工资过账的撤销,财务做,CFO 批每一张、不分档(grilling Q3)。
--   ① 仍要 module.hr.edit;
--   ② 找【这个期间、kind = 'reversal'、status = 'approved'】的那一张 —— 没有就按名拒
--      PAYROLL_NEEDS_APPROVED_REQUEST|<期间编号>|reversal;
--   ③ 批的那一组数与此刻的数再比一次(PAYROLL_CHANGED_SINCE_REQUEST);
--   ④ 交给引擎 unpost_payroll_period_internal,理由取【申请上】那一句 —— CFO 批的就是它,
--      执行的人不另给一句。所以签名从 (uuid, text) 改成了 (uuid):一个会被忽略的参数,
--      比一个不存在的参数更会骗人。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql; the door shape by
--       db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.unpost_payroll_period(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p   payroll_periods%ROWTYPE;
    v_r   payroll_requests%ROWTYPE;
    v_je  uuid;
    v_res jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM payroll_periods
     WHERE id = p_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;

    SELECT * INTO v_r FROM payroll_requests
     WHERE payroll_period_id = p_id AND kind = 'reversal' AND status = 'approved'
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NEEDS_APPROVED_REQUEST|%|reversal', v_p.code;
    END IF;
    IF payroll_period_fingerprint(p_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_res := unpost_payroll_period_internal(p_id, v_r.notes);

    SELECT reversed_by INTO v_je FROM journal_entries WHERE id = v_p.journal_entry_id;
    UPDATE payroll_requests
       SET status = 'executed', executed_at = now(), executed_by = auth.uid(),
           result_journal_entry_id = v_je
     WHERE id = v_r.id;

    RETURN v_res || jsonb_build_object('request_id', v_r.id, 'request_label', v_r.label);
END;
$function$
;

-- db/functions/submit_payroll_request.sql
-- PAYROLL-APR-1(2026-09-24):提一张工资申请 —— 过账(post)或撤销过账(reversal)。
--
-- Tim 的矩阵 §5:财务提(module.hr.edit —— 工资期本来就归这个码),CFO 批每一张、不分档。
--   · post     —— 期间必须是 draft、有行;
--   · reversal —— 期间必须是 posted;理由必填(PAYROLL_REVERSAL_REASON_REQUIRED),
--                 审批人读的就是它,执行时它也是撤销分录上的那一句。
--   · 一个期间同时只挂一张未了结的申请(PAYROLL_REQUEST_OPEN;唯一索引是第二道)。
--   · snapshot = payroll_period_fingerprint:批的那一组数(grilling Q4)。
--   · 提交时照执行那一刻的同一支引擎试跑一遍(payroll_request_dry_run,grilling Q7)——
--     考勤没做齐、期间已锁、已付过钱,这里就按引擎的原话拒,而不是等 CFO 批完才撞上。
--
-- 【审批关着时】生下来就是 approved,留痕 auto_approved —— 没有人按过批准,留痕就不许说有人按过
-- (采购单与付款申请同形,PAY-REQ-1 的 Q8)。
-- 【主角】工资期是公司的单据(Tim 的 Q1 (A)):留痕的主角为 NULL,见 payroll_requests 抬头。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_payroll_request(p_payroll_period_id uuid, p_kind text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p     payroll_periods%ROWTYPE;
    v_id    uuid := gen_random_uuid();
    v_on    boolean := approvals_enabled();
    v_label text;
    v_n     integer;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_p FROM payroll_periods
     WHERE id = p_payroll_period_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;

    IF p_kind = 'post' THEN
        IF v_p.status = 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_ALREADY_POSTED|%', v_p.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p_payroll_period_id) THEN
            RAISE EXCEPTION 'NO_LINES';
        END IF;
    ELSIF p_kind = 'reversal' THEN
        IF v_p.status <> 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
        END IF;
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'PAYROLL_REVERSAL_REASON_REQUIRED|%', v_p.code;
        END IF;
    ELSE
        RAISE EXCEPTION 'PAYROLL_REQUEST_KIND_UNKNOWN|%|%', v_p.code, COALESCE(p_kind, '?');
    END IF;

    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = p_payroll_period_id AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', v_p.code;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM payroll_requests
     WHERE payroll_period_id = p_payroll_period_id AND kind = p_kind;
    v_label := v_p.code || ' · ' || p_kind || ' #' || v_n::text;

    INSERT INTO payroll_requests (id, payroll_period_id, kind, status, label, snapshot,
                                  currency, fx_rate, gross_total, amount_base, notes, created_by)
    VALUES (v_id, p_payroll_period_id, p_kind,
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_label, payroll_period_fingerprint(p_payroll_period_id),
            v_p.currency, v_p.fx_rate, v_p.gross_total, round(v_p.gross_total * v_p.fx_rate, 2),
            NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    PERFORM payroll_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('payroll_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payroll_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'label', v_label,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$
;

-- db/functions/withdraw_payroll_request.sql
-- PAYROLL-APR-1(2026-09-24):撤回一张工资申请。submitted 与 approved 都可以撤回
-- (PAY-REQ-1 的第 1 条:一张执行不了的申请不许永远占着它的期间 —— 而申请开着时
-- 那个期间不许保存、那个月的考勤不许重开,撤回就是回去改的那条路)。
-- 撤回不过账,只是放弃;executed / rejected / withdrawn 不能撤。
-- 谁能撤:财务(module.hr.edit)—— 提单人本来就持这个码。
-- 不写 approval_log:撤回不是一次【决定】(与付款申请、报销单的撤回同一条)。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.withdraw_payroll_request(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r payroll_requests%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status NOT IN ('submitted', 'approved') THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_OPEN|%|%', v_r.label, v_r.status;
    END IF;
    UPDATE payroll_requests
       SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = auth.uid()
     WHERE id = p_request_id;
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'withdrawn');
END;
$function$
;

-- db/functions/decide_payroll_request.sql
-- PAYROLL-APR-1(2026-09-24):CFO 批准或驳回一张工资申请(过账或撤销过账)。
--
-- 【门】module.hr.view + data.view_pay(grilling Q8)—— 工资期页的门,加上看得见工资数的那个码
-- (docs/approvals.md §5:批的人必须看得见他批的那个数)。【不是】module.hr.edit:
-- 那是提单的码,一个提得了申请的审批人不是一道控制。cfo 两个都持(Step 0 以 postgres 读基表)。
-- 【谁能批】require_approver_for(2)—— CFO 批每一张、不分档,从不经 approval_level_for:
-- 路由的定义仍然只有一份(approval_level2_role_code)。一级持有人批不了(R1 只往下)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ 四眼:提单人那条腿按人判;主角那条腿对谁都不成立(Tim 的 Q1 (A))★★
-- ════════════════════════════════════════════════════════════════════════════
--   forbid_self_approval(created_by, NULL, 'payroll_request') —— 工资期是公司的单据。
--   Tim 的理由:CFO 在这一步改不了他自己的月薪(月薪只经绩效评估或调薪申请改动),
--   要紧的那道控制是"做的人不是批的人"。从 admin@ 提的申请 tim@ 批不了(同一个人,
--   Step 0 实测 SELF_APPROVAL_FORBIDDEN|raiser)。self_approval_exception 不认
--   payroll_request,所以 R2 永远帮不上这里。
--   ☞ 当审批人自己在这一期里有工资行,决定照常,并在 approval_log 的备注里记下
--   (「本期含审批人自己的工资行」+ 员工编号)。**不**标 self_decided —— record_approval_decision
--   只在"是提单人或主角"时标它,这里主角是 NULL,所以它是 false;approval_log_self_decided_scope
--   也不许 payroll_request 为 true。屏幕上同一句话由工资期页说出。
--
-- 【批准之前】冻结的那一组数与此刻再比一次(PAYROLL_CHANGED_SINCE_REQUEST),再按执行那一刻的
-- 同一支引擎试跑(payroll_request_dry_run)—— 审批人看见的拒绝是引擎的原话。
-- 驳回从不检查这些:驳回一张坏掉的申请,正是出路。
-- 审批关着时按名拒(APPROVALS_NOT_ENABLED)—— 所以这条链的在途申请挡关闭(blocks_disable)。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.decide_payroll_request(p_request_id uuid, p_approve boolean, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     payroll_requests%ROWTYPE;
    v_own   text;
    v_note  text;
BEGIN
    PERFORM require_permission('module.hr.view');
    PERFORM require_permission('data.view_pay');

    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.status <> 'submitted' THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_SUBMITTED|%|%', v_r.label, v_r.status;
    END IF;
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'APPROVALS_NOT_ENABLED';
    END IF;

    PERFORM forbid_self_approval(v_r.created_by, NULL, 'payroll_request');
    PERFORM require_approver_for(2::smallint);

    -- 审批人自己在这一期里有没有工资行(按人认:account_person)
    SELECT e.code INTO v_own
      FROM payroll_lines l JOIN employees e ON e.id = l.employee_id
     WHERE l.payroll_period_id = v_r.payroll_period_id
       AND l.employee_id = account_person(auth.uid());
    v_note := NULLIF(btrim(COALESCE(p_notes, '')), '');
    IF v_own IS NOT NULL THEN
        v_note := concat_ws(E'\n', v_note,
            '本期含审批人自己的工资行 · this period includes the approver''s own pay line: ' || v_own);
    END IF;

    IF NOT p_approve THEN
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'PAYROLL_REQUEST_REJECT_REASON_REQUIRED|%', v_r.label;
        END IF;
        UPDATE payroll_requests
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_request_id;
        PERFORM record_approval_decision('payroll_request', p_request_id, 'rejected', 2::smallint, v_note);
        RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'rejected');
    END IF;

    IF payroll_period_fingerprint(v_r.payroll_period_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;
    PERFORM payroll_request_dry_run(p_request_id);

    UPDATE payroll_requests
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), '')
     WHERE id = p_request_id;
    PERFORM record_approval_decision('payroll_request', p_request_id, 'approved', 2::smallint, v_note);
    RETURN jsonb_build_object('request_id', p_request_id, 'label', v_r.label, 'status', 'approved',
                              'includes_own_line', v_own IS NOT NULL);
END;
$function$
;

-- db/functions/upsert_payroll_period.sql
-- 录入 / 重导一个工资期(服务商的数)。已过账的不收(PAYROLL_POSTED)。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q4):挂着未了结的过账或撤销申请时也不收(PAYROLL_REQUEST_OPEN)。

CREATE OR REPLACE FUNCTION public.upsert_payroll_period(p_period_month date, p_payment_date date, p_currency text, p_fx_rate numeric, p_source_note text, p_notes text, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_base     text;   -- OPS-8:本位币从 currencies.is_base 读
    v_period   record;
    v_id       uuid;
    v_code     text;
    v_el       jsonb;
    v_emp      record;
    v_seen     uuid[] := ARRAY[]::uuid[];
    v_gross    numeric;
    v_er_cpf   numeric;
    v_ee_cpf   numeric;
    v_other    numeric;
    v_net      numeric;
    v_expected numeric;
    v_count    integer := 0;
    v_t_gross  numeric := 0;
    v_t_er     numeric := 0;
    v_t_ee     numeric := 0;
    v_t_other  numeric := 0;
    v_t_net    numeric := 0;
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    PERFORM require_permission('module.hr.edit');
    IF p_period_month IS NULL OR p_period_month <> date_trunc('month', p_period_month)::date THEN
        RAISE EXCEPTION 'PERIOD_MONTH_INVALID|%', COALESCE(p_period_month::text, '?');
    END IF;
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    IF p_fx_rate IS NULL OR p_fx_rate <= 0 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', COALESCE(p_fx_rate::text, '?');
    END IF;
    -- FIN-0:本位币期间的 fx_rate 只能是 1(OPS-8:本位币问 currencies.is_base,
    -- 不写 'SGD' —— 这一句自己的注释就承认它判的是本位币)
    IF p_currency = v_base AND p_fx_rate <> 1 THEN
        RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
    END IF;
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    SELECT * INTO v_period FROM payroll_periods
    WHERE period_month = p_period_month AND deleted_at IS NULL
    FOR UPDATE;

    IF FOUND THEN
        -- 已过账的周期不接受重导:先 unpost 才能改(总账已经认了这批数)
        IF v_period.status = 'posted' THEN
            RAISE EXCEPTION 'PAYROLL_POSTED|%', v_period.code;
        END IF;
        -- ★ PAYROLL-APR-1(Tim 的 Q4):挂着未了结的申请时不许重导 —— CFO 批的是那一组数。
        --   先撤回申请,改完再提一张。
        IF EXISTS (SELECT 1 FROM payroll_requests r
                    WHERE r.payroll_period_id = v_period.id AND r.status IN ('submitted', 'approved')) THEN
            RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', v_period.code;
        END IF;
        v_id := v_period.id;
        v_code := v_period.code;
        UPDATE payroll_periods
        SET payment_date = p_payment_date, currency = p_currency, fx_rate = p_fx_rate,
            source_note = p_source_note, notes = p_notes, updated_by = v_user
        WHERE id = v_id;
        DELETE FROM payroll_lines WHERE payroll_period_id = v_id;
    ELSE
        v_id := gen_random_uuid();
        v_code := next_payroll_code(p_period_month);
        INSERT INTO payroll_periods (id, code, period_month, payment_date, currency, fx_rate,
                                     source_note, notes, created_by, updated_by)
        VALUES (v_id, v_code, p_period_month, p_payment_date, p_currency, p_fx_rate,
                p_source_note, p_notes, v_user, v_user);
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        SELECT id, code INTO v_emp FROM employees
        WHERE id = (v_el->>'employee_id')::uuid AND deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(v_el->>'employee_id', '?');
        END IF;
        IF v_emp.id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_EMPLOYEE|%', v_emp.code;
        END IF;
        v_seen := v_seen || v_emp.id;

        v_gross  := (v_el->>'gross_pay')::numeric;
        v_er_cpf := COALESCE((v_el->>'employer_cpf')::numeric, 0);
        v_ee_cpf := COALESCE((v_el->>'employee_cpf')::numeric, 0);
        v_other  := COALESCE((v_el->>'other_deductions')::numeric, 0);
        v_net    := (v_el->>'net_pay')::numeric;

        IF v_gross IS NULL OR v_net IS NULL
           OR v_gross < 0 OR v_er_cpf < 0 OR v_ee_cpf < 0 OR v_other < 0 OR v_net < 0 THEN
            RAISE EXCEPTION 'AMOUNT_INVALID|%', v_emp.code;
        END IF;

        -- 服务商给的行必须自洽。这是本函数【唯一】的算术 —— 不是在算工资,
        -- 是在把录错/解析错的一行挡在总账之外。
        v_expected := round(v_gross - v_ee_cpf - v_other, 2);
        IF v_expected <> round(v_net, 2) THEN
            RAISE EXCEPTION 'LINE_NOT_BALANCED|%|%|%', v_emp.code, v_expected, round(v_net, 2);
        END IF;

        INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, employer_cpf,
                                   employee_cpf, other_deductions, net_pay, notes)
        VALUES (v_id, v_emp.id, v_gross, v_er_cpf, v_ee_cpf, v_other, v_net, v_el->>'notes');

        v_count := v_count + 1;
        v_t_gross := v_t_gross + v_gross;
        v_t_er    := v_t_er + v_er_cpf;
        v_t_ee    := v_t_ee + v_ee_cpf;
        v_t_other := v_t_other + v_other;
        v_t_net   := v_t_net + v_net;
    END LOOP;

    UPDATE payroll_periods
    SET gross_total = round(v_t_gross, 2),
        employer_cpf_total = round(v_t_er, 2),
        employee_cpf_total = round(v_t_ee, 2),
        other_deductions_total = round(v_t_other, 2),
        net_pay_total = round(v_t_net, 2),
        updated_by = v_user
    WHERE id = v_id;

    RETURN jsonb_build_object(
        'payroll_period_id', v_id,
        'code', v_code,
        'line_count', v_count,
        'gross_total', round(v_t_gross, 2),
        'employer_cpf_total', round(v_t_er, 2),
        'employee_cpf_total', round(v_t_ee, 2),
        'other_deductions_total', round(v_t_other, 2),
        'net_pay_total', round(v_t_net, 2)
    );
END;
$function$;

-- db/functions/reopen_attendance_period.sql
-- 重开一个已完成的考勤月(ATTEND-1)。已过账的那个月不许重开(ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL)。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q4):那个月的工资挂着未了结的过账申请时也不许
--   (ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST)—— 先撤回申请。

CREATE OR REPLACE FUNCTION public.reopen_attendance_period(p_period_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_p attendance_periods%ROWTYPE; v_pay text;
BEGIN
    PERFORM require_permission('module.hr.edit');
    SELECT * INTO v_p FROM attendance_periods WHERE id = p_period_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_FOUND|%', COALESCE(p_period_id::text, '?');
    END IF;
    IF v_p.status <> 'complete' THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_NOT_COMPLETE|%|%', v_p.code, v_p.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ATTENDANCE_REOPEN_REASON_REQUIRED|%', v_p.code;
    END IF;

    -- ★【那个月的工资已经过账,就不许再动它的依据】★
    -- 一张已过账工资单的依据不能在它脚下改变。改法是先 unpost ——
    -- 而 unpost_payroll_period 自己带着守卫(CPF/扣款已汇出就拒),
    -- 所以这条顺序是可执行的,不是一句劝告。
    SELECT code INTO v_pay FROM payroll_periods
     WHERE deleted_at IS NULL AND status = 'posted'
       AND date_trunc('month', period_month)::date = v_p.period_month LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL|%|%', v_p.code, v_pay;
    END IF;

    -- ★ PAYROLL-APR-1(Tim 的 Q4):那个月的工资挂着一张【未了结的过账申请】时也不许重开 ——
    --   CFO 批的那一期站在这份底稿上;底稿在等待期间变了,批的就不再是它。先撤回申请。
    SELECT p.code INTO v_pay FROM payroll_periods p
      JOIN payroll_requests r ON r.payroll_period_id = p.id
     WHERE p.deleted_at IS NULL AND r.kind = 'post' AND r.status IN ('submitted', 'approved')
       AND date_trunc('month', p.period_month)::date = v_p.period_month LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST|%|%', v_p.code, v_pay;
    END IF;

    UPDATE attendance_periods
       SET status = 'open', completed_at = NULL, completed_by = NULL,
           reopened_at = now(), reopened_by = auth.uid(), reopen_reason = btrim(p_reason)
     WHERE id = p_period_id;

    RETURN jsonb_build_object('period_id', p_period_id, 'code', v_p.code, 'status', 'open');
END;
$function$

;

-- db/functions/pay_payroll_lines.sql
-- 发薪(FIN-4):付掉一个周期里【任意子集】的工资行 —— 转账会失败重发,
-- 所以一次付款跑批覆盖哪些行由调用方点名。一跑一张凭证:
--   借 2300 应付净薪(合计一条)
--   贷 银行 —— 【一人一条,金额 = 该人净额,备注 = 工号 + 姓名】
-- 每条银行行各自认领自己的对账单行,这是本切存在的理由(C3)。
-- 一行只许付一次(paid_at 即闸);发薪是银行操作,财务或 HR 都做得动。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin4-pay-per-employee.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。

--
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q6):一期挂着未了结的【撤销过账】申请时按名拒
--   PAYROLL_REVERSAL_REQUESTED。付款仍归财务、不另批;它只能跟在一次批过的过账后面 ——
--   status = 'posted' 从此只经批过的申请到达,所以那一半由上面的 PAYROLL_NOT_POSTED 守着。
CREATE OR REPLACE FUNCTION public.pay_payroll_lines(p_payroll_period_id uuid, p_line_ids uuid[], p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p     payroll_periods%ROWTYPE;
    v_bank  text;
    v_date  date;
    v_total numeric := 0;
    v_lines jsonb := '[]'::jsonb;
    v_l     record;
    v_n     integer := 0;
    v_je    jsonb;
BEGIN
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF NOT (has_permission('module.finance.edit') OR has_permission('module.hr.edit')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;

    SELECT * INTO v_p FROM payroll_periods WHERE id = p_payroll_period_id FOR UPDATE;
    IF NOT FOUND OR v_p.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    -- ★ PAYROLL-APR-1(Tim 的 Q6):财务已经申请撤销这一期的过账,钱就不许再照它出去 ——
    --   付了,那张撤销申请执行时会撞 PAYROLL_*_PAID,而钱已经走了。先撤回申请,或等它了结。
    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = v_p.id AND r.kind = 'reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REVERSAL_REQUESTED|%', v_p.code;
    END IF;
    IF p_line_ids IS NULL OR array_length(p_line_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- OPS-8:币种 → 银行科目的映射只有一份(bank_account_for_currency)
    v_bank := COALESCE(p_bank_account, bank_account_for_currency(v_p.currency));
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := p_payment_date;

    FOR v_l IN
        SELECT pl.id, pl.net_pay, pl.paid_at, e.code AS emp_code, e.legal_name
        FROM payroll_lines pl
        JOIN employees e ON e.id = pl.employee_id
        WHERE pl.id = ANY (p_line_ids)
        ORDER BY e.code
        FOR UPDATE OF pl
    LOOP
        IF NOT EXISTS (SELECT 1 FROM payroll_lines x
                       WHERE x.id = v_l.id AND x.payroll_period_id = p_payroll_period_id) THEN
            RAISE EXCEPTION 'PAYROLL_LINE_INVALID|%', v_l.id;
        END IF;
        IF v_l.paid_at IS NOT NULL THEN
            RAISE EXCEPTION 'PAYROLL_LINE_ALREADY_PAID|%', v_l.emp_code;
        END IF;
        IF v_l.net_pay <= 0 THEN
            CONTINUE;  -- 净额为零的行没有转账,也没有对账单行
        END IF;
        -- 【一人一条银行行】备注带工号姓名,statement 上那一行就是这一条
        v_lines := v_lines || jsonb_build_object(
            'account_code', v_bank, 'side', 'credit', 'currency', v_p.currency,
            'amount_ccy', v_l.net_pay, 'fx_rate', 1,
            'line_memo', v_l.emp_code || ' ' || v_l.legal_name);
        v_total := round(v_total + v_l.net_pay, 2);
        v_n := v_n + 1;
    END LOOP;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_lines := jsonb_build_array(jsonb_build_object(
        'account_code', '2300', 'side', 'debit', 'currency', v_p.currency,
        'amount_ccy', v_total, 'fx_rate', 1,
        'line_memo', 'Salary run ' || v_p.code)) || v_lines;

    v_je := post_journal_entry(v_date, 'Salary payment ' || v_p.code, 'payroll',
                               p_payroll_period_id, v_lines);

    UPDATE payroll_lines
    SET paid_at = now(), paid_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = ANY (p_line_ids);

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'entry_id', v_je->>'entry_id',
                              'lines_paid', v_n, 'total_paid', v_total);
END;
$function$;

-- db/functions/pay_payroll_cpf.sql
-- 汇 CPF(FIN-5)。【与 FIN-4 刻意相反的形状,规则却是同一条:照着对账单记】——
-- 净薪是 ~15 个人各收一笔,对账单 15 行,所以分录 15 条银行行(pay_payroll_lines);
-- CPF 是给公积金局【一笔】汇款,对账单 1 行,所以分录【1 条】银行行。
-- 按人头的 CPF 明细在 payroll_lines 上,报局用查询,不用分录行(B3)。
-- 【单据记清结算的是哪个期间、何时付的】—— 当月的 CPF 次月才汇,两个月份不同是设计。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin5-relieve-cpf.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。

--
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q6):一期挂着未了结的【撤销过账】申请时按名拒
--   PAYROLL_REVERSAL_REQUESTED。付款仍归财务、不另批;它只能跟在一次批过的过账后面 ——
--   status = 'posted' 从此只经批过的申请到达,所以那一半由上面的 PAYROLL_NOT_POSTED 守着。
CREATE OR REPLACE FUNCTION public.pay_payroll_cpf(p_payroll_period_id uuid, p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payroll_periods%ROWTYPE;
    v_cpf  numeric;
    v_bank text;
    v_date date;
    v_je   jsonb;
BEGIN
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF NOT (has_permission('module.finance.edit') OR has_permission('module.hr.edit')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    SELECT * INTO v_p FROM payroll_periods WHERE id = p_payroll_period_id FOR UPDATE;
    IF NOT FOUND OR v_p.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    -- ★ PAYROLL-APR-1(Tim 的 Q6):财务已经申请撤销这一期的过账,钱就不许再照它出去 ——
    --   付了,那张撤销申请执行时会撞 PAYROLL_*_PAID,而钱已经走了。先撤回申请,或等它了结。
    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = v_p.id AND r.kind = 'reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REVERSAL_REQUESTED|%', v_p.code;
    END IF;
    IF v_p.cpf_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_CPF_ALREADY_PAID|%', v_p.code;
    END IF;
    v_cpf := round(COALESCE(v_p.employer_cpf_total, 0) + COALESCE(v_p.employee_cpf_total, 0), 2);
    IF v_cpf <= 0 THEN
        RAISE EXCEPTION 'PAYROLL_NOTHING_TO_PAY|%', v_p.code;
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := p_payment_date;

    v_je := post_journal_entry(v_date, 'CPF ' || v_p.code, 'payroll', v_p.id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2400', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', v_cpf,
                'line_memo', 'CPF for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_cpf,
                'line_memo', 'CPF Board')));

    UPDATE payroll_periods
    SET cpf_paid_at = v_date, cpf_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'cpf_paid', v_cpf,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;

-- db/functions/pay_payroll_deductions.sql
-- 汇付某期间代扣的其它款项(FIN-5 B6)。payroll 过账把 other_deductions 挂 2200,
-- 此前【没有任何东西借得动它】—— 与 2400 同一个缺陷的第二处。
-- 代扣款是替员工代收、汇给第三方(保险/扣押令等)的【一笔】款,对账单 1 行,
-- 分录 1 条银行行 —— 照着对账单记,同 pay_payroll_cpf 的规则。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin5-relieve-cpf.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。

--
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q6):一期挂着未了结的【撤销过账】申请时按名拒
--   PAYROLL_REVERSAL_REQUESTED。付款仍归财务、不另批;它只能跟在一次批过的过账后面 ——
--   status = 'posted' 从此只经批过的申请到达,所以那一半由上面的 PAYROLL_NOT_POSTED 守着。
CREATE OR REPLACE FUNCTION public.pay_payroll_deductions(p_payroll_period_id uuid, p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_p    payroll_periods%ROWTYPE;
    v_amt  numeric;
    v_bank text;
    v_date date;
    v_je   jsonb;
BEGIN
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    IF NOT (has_permission('module.finance.edit') OR has_permission('module.hr.edit')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.edit';
    END IF;
    SELECT * INTO v_p FROM payroll_periods WHERE id = p_payroll_period_id FOR UPDATE;
    IF NOT FOUND OR v_p.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(p_payroll_period_id::text, '?');
    END IF;
    IF v_p.status <> 'posted' THEN
        RAISE EXCEPTION 'PAYROLL_NOT_POSTED|%', v_p.code;
    END IF;
    -- ★ PAYROLL-APR-1(Tim 的 Q6):财务已经申请撤销这一期的过账,钱就不许再照它出去 ——
    --   付了,那张撤销申请执行时会撞 PAYROLL_*_PAID,而钱已经走了。先撤回申请,或等它了结。
    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = v_p.id AND r.kind = 'reversal'
                  AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REVERSAL_REQUESTED|%', v_p.code;
    END IF;
    IF v_p.deductions_paid_at IS NOT NULL THEN
        RAISE EXCEPTION 'PAYROLL_DEDUCTIONS_ALREADY_PAID|%', v_p.code;
    END IF;
    v_amt := round(COALESCE(v_p.other_deductions_total, 0), 2);
    IF v_amt <= 0 THEN
        RAISE EXCEPTION 'PAYROLL_NOTHING_TO_PAY|%', v_p.code;
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    v_date := p_payment_date;

    v_je := post_journal_entry(v_date, 'Payroll deductions ' || v_p.code, 'payroll', v_p.id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2200', 'side', 'debit',
                'currency', base_currency_code(), 'amount_ccy', v_amt,
                'line_memo', 'Deductions for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', base_currency_code(), 'amount_ccy', v_amt)));

    UPDATE payroll_periods
    SET deductions_paid_at = v_date, deductions_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'deductions_paid', v_amt,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;

-- db/functions/reverse_journal_entry.sql
-- 手工冲销一张分录(module.finance.edit)。付款、转账、代扣税缴纳的分录按名拒,走各自的申请。
-- ★ PAYROLL-APR-1(2026-09-24,Tim 的 Q5):工资期的过账分录与它的冲销也按名拒 —— 撤销走撤销申请。

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
    IF v_src IN ('payment', 'transfer', 'wht_remittance') THEN
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
            ARRAY['module.purchasing.view', 'data.view_prices']::text[]),
        ('purchase_order'::text, 'approve_purchase_order'::text, 2::smallint,
            ARRAY['module.purchasing.view', 'data.view_prices']::text[]),
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
            ARRAY['module.hr.view', 'data.view_pay']::text[])
      ) AS v(subject_type, action_function, level, gate_permissions)
$function$;

COMMENT ON FUNCTION public.approval_chain_gates() IS
'APR-2(APR-3 加进报销单两行):接上了 require_approver_for 的链,以及每一支动作【自己的】模块门(可能是几个码的合取)。★ 它存在是因为 WO-1b 实测在线上造出过一个死锁:一级审批角色 finance 的唯一真持有人不持 module.processing.edit,于是审批一开,工单谁都放行不了,而三道闸全绿。这张名册是手写的,所以 db/fixtures/203 有一条目录派生的断言钉住它与 pg_proc 里真正调用 require_approver_for 的那组函数逐字相等 —— 加一条链就要在这里加一行。★ APR-3 的报销单两行取的门是 module.finance.view + data.view_prices,【不是】module.finance.edit —— 写成 edit 的话,今天二级还有一个人靠的只是 cfo 的唯一真持有人就是 admin 账号(§0b 那次撞车),而独立 CFO 账号一落地它就归零。';

-- db/functions/guard_payroll_period_direct_write.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q5):工资期的【状态】与【已冻结的数】只走函数。
--
-- 【Step 0 实测的侧门】payroll_periods 的 UPDATE / INSERT 策略开在 module.hr.edit 上,表上
-- 【没有】管 status 的守卫。以 chooer@ 在一笔回滚的事务里直连
-- `UPDATE payroll_periods SET status = 'draft', journal_entry_id = NULL` —— 1 行,成功。
-- 反过来写成 'posted' 同样成功:一期没有分录、没有批准的工资就"过了账",付款三支函数
-- (只看 status = 'posted')照样把钱付出去。**不关这扇门,"批之前什么都不过账"就是一句假话。**
--
-- 本守卫(直连写才判,row_security_active):
--   · INSERT:status 必须是 draft,五个"过账 / 汇款"列(journal_entry_id · cpf_paid_at ·
--     cpf_journal_entry_id · deductions_paid_at · deductions_journal_entry_id)必须为空
--     → 否则 PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;
--   · UPDATE:改动 status 或那五列 → PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;
--   · UPDATE:期间已过账或挂着未了结的申请(payroll_period_frozen)时,改动那组【被批的数】
--     (五个合计 · 发薪日 · 币种 · 汇率 · 月份)→ PAYROLL_LINES_FROZEN;
--   · UPDATE:挂着未了结的申请时软删 → PAYROLL_REQUEST_OPEN(已过账的软删另有
--     guard_payroll_period_delete 管)。
-- 备注、出处这几列照旧归 hr.edit。所有写函数都是 SECURITY DEFINER(row_security_active = false),
-- 本守卫看不见它们;迁移与 fixture 以属主身份写,也看不见。
--
-- 【为什么是 INVOKER】要分出直连写与属主路径(guard_assay_applied_columns 同一条)。
-- 期间是否冻结经 payroll_period_frozen 问(DEFINER)—— INVOKER 里直接读 payroll_requests,
-- 一个不持 hr.view 的写入者会读到零行而静默放行。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_payroll_period_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft'
           OR num_nonnulls(NEW.journal_entry_id, NEW.cpf_paid_at, NEW.cpf_journal_entry_id,
                           NEW.deductions_paid_at, NEW.deductions_journal_entry_id) > 0 THEN
            RAISE EXCEPTION 'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|%', NEW.code;
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status
       OR NEW.journal_entry_id IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.cpf_paid_at IS DISTINCT FROM OLD.cpf_paid_at
       OR NEW.cpf_journal_entry_id IS DISTINCT FROM OLD.cpf_journal_entry_id
       OR NEW.deductions_paid_at IS DISTINCT FROM OLD.deductions_paid_at
       OR NEW.deductions_journal_entry_id IS DISTINCT FROM OLD.deductions_journal_entry_id THEN
        RAISE EXCEPTION 'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|%', OLD.code;
    END IF;

    v_state := payroll_period_frozen(OLD.id);
    IF v_state <> 'open' THEN
        IF NEW.gross_total IS DISTINCT FROM OLD.gross_total
           OR NEW.employer_cpf_total IS DISTINCT FROM OLD.employer_cpf_total
           OR NEW.employee_cpf_total IS DISTINCT FROM OLD.employee_cpf_total
           OR NEW.other_deductions_total IS DISTINCT FROM OLD.other_deductions_total
           OR NEW.net_pay_total IS DISTINCT FROM OLD.net_pay_total
           OR NEW.payment_date IS DISTINCT FROM OLD.payment_date
           OR NEW.currency IS DISTINCT FROM OLD.currency
           OR NEW.fx_rate IS DISTINCT FROM OLD.fx_rate
           OR NEW.period_month IS DISTINCT FROM OLD.period_month THEN
            RAISE EXCEPTION 'PAYROLL_LINES_FROZEN|%|%', OLD.code, v_state;
        END IF;
        IF v_state = 'requested' AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', OLD.code;
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_payroll_period_direct_write() IS
'PAYROLL-APR-1(Tim 的 Q5):直连写(row_security_active)payroll_periods —— INSERT 不是 draft 或带着过账 / 汇款列、UPDATE 改动 status 或那五列,按名拒 PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;期间已过账或挂着未了结的申请时改动被批的数(合计 · 日期 · 币种 · 汇率 · 月份)拒 PAYROLL_LINES_FROZEN,软删拒 PAYROLL_REQUEST_OPEN。INVOKER,以分出直连写与属主路径;冻结状态经 payroll_period_frozen(DEFINER)问。';

-- db/functions/guard_payroll_line_direct_write.sql
-- PAYROLL-APR-1(2026-09-24,grilling Q5):已过账、或挂着未了结申请的工资期,它的【行】不许直连改。
--
-- 【Step 0 实测的侧门】payroll_lines 的写策略开在 module.hr.edit 上;以 chooer@ 在一笔回滚的
-- 事务里直连改 PAY-2026-0001(已过账、已付清)的一行 —— 1 行,成功。一期被批过、过过账的工资,
-- 它的行可以在总账脚下被改掉;一期正在等 CFO 批的工资,它的行可以在批之前被换掉。
--
-- 本守卫(直连写才判,row_security_active):行所在的期间 payroll_period_frozen ≠ 'open'
-- (已过账或挂着 submitted / approved 的申请)时,INSERT / UPDATE / DELETE 一律按名拒
-- PAYROLL_LINES_FROZEN|<期间编号>|<posted|requested>。UPDATE 把行挪到另一期,两边都判。
-- 草稿且没有申请的期间照旧可以直连改(那是 hr.edit 本来的活)。
-- upsert_payroll_period 与付款三支函数都是 SECURITY DEFINER,本守卫看不见它们。
--
-- 【为什么是 INVOKER】同 guard_payroll_period_direct_write。
-- NOTE: introduced by db/migrations/2026-09-24-payrollapr1-payroll-posts-only-after-cfo-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_payroll_line_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pid   uuid;
    v_state text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    END IF;
    FOREACH v_pid IN ARRAY (CASE TG_OP
                                WHEN 'INSERT' THEN ARRAY[NEW.payroll_period_id]
                                WHEN 'DELETE' THEN ARRAY[OLD.payroll_period_id]
                                ELSE ARRAY[OLD.payroll_period_id, NEW.payroll_period_id] END) LOOP
        v_state := payroll_period_frozen(v_pid);
        IF v_state <> 'open' THEN
            RAISE EXCEPTION 'PAYROLL_LINES_FROZEN|%|%',
                COALESCE((SELECT code FROM payroll_period_lookup WHERE id = v_pid), v_pid::text), v_state;
        END IF;
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$function$;

COMMENT ON FUNCTION public.guard_payroll_line_direct_write() IS
'PAYROLL-APR-1(Tim 的 Q5):直连写(row_security_active)一个已过账或挂着未了结申请的工资期的行(INSERT / UPDATE / DELETE),按名拒 PAYROLL_LINES_FROZEN|<期间>|<posted|requested>。草稿且没有申请的期间照旧。INVOKER,以分出直连写与属主路径;冻结状态经 payroll_period_frozen(DEFINER)问。';

-- ── 4 · 侧门(Q5):两张表各一支 BEFORE 行级守卫 ───────────────────────────────
CREATE TRIGGER trg_payroll_periods_direct_write
    BEFORE INSERT OR UPDATE ON public.payroll_periods
    FOR EACH ROW EXECUTE FUNCTION public.guard_payroll_period_direct_write();
CREATE TRIGGER trg_payroll_lines_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.payroll_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_payroll_line_direct_write();

-- ── 5 · operations_now:加一支 payroll_request_pending(镜像原样)────────────────
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
          WHERE q.status = 'submitted'::text) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type))) AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

-- ── 6 · 自证 ──────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.pa1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE pa1_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved');

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM pa1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM pa1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'PAYROLLAPR1_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、工资期与工资行一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM pa1_pending_before b EXCEPT SELECT a.k, a.id FROM pa1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM pa1_pending_after a EXCEPT SELECT b.k, b.id FROM pa1_pending_before b)) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT (approval_log, journal_entries, periods_posted, periods_draft, lines, lines_paid) FROM pa1_counts_before)
       IS DISTINCT FROM
       (SELECT ((SELECT count(*) FROM approval_log), (SELECT count(*) FROM journal_entries),
                (SELECT count(*) FROM payroll_periods WHERE status = 'posted'),
                (SELECT count(*) FROM payroll_periods WHERE status = 'draft'),
                (SELECT count(*) FROM payroll_lines),
                (SELECT count(*) FROM payroll_lines WHERE paid_at IS NOT NULL))) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|a business row count changed';
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests) THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|payroll_requests is not empty';
    END IF;

    -- ④ 结构:旧签名已退场;两支守卫挂上;链的名册一行、只有二级
    IF to_regprocedure('public.unpost_payroll_period(uuid, text)') IS NOT NULL
       OR to_regprocedure('public.unpost_payroll_period(uuid)') IS NULL THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|unpost_payroll_period signature';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_payroll_periods_direct_write',
                                                             'trg_payroll_lines_direct_write');
    IF v_n <> 2 THEN RAISE EXCEPTION 'PAYROLLAPR1_PROOF|expected 2 guard triggers, got %', v_n; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'payroll_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|payroll_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('payroll_request', 'decide_payroll_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'PAYROLLAPR1_PROOF|nobody can decide a payroll request'; END IF;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.pa1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'PAYROLLAPR1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.pa1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'PAYROLLAPR1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.pa1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.pa1_pending_decider_check(boolean);

COMMIT;

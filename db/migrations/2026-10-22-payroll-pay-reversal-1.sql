-- db/migrations/2026-10-22-payroll-pay-reversal-1.sql
-- PAYROLL-PAY-REVERSAL-1 —— 工资 / CPF / 扣款付款的冲销路;四条冲销路都不冲已配对的银行行;新入职的人按服务期给假;/me 列出每一种假的余额。
--   (v1.4.66;发布那一行在 docs/handbacks/PAYROLL-PAY-REVERSAL-1.md 的抬头。)
--   由 db/scripts/build_payroll_pay_reversal1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-22 的裁定:Step 0 Q1–Q13)
--   ① payroll_requests 第三种 payment_reversal(target_entry_id = 那一张付款分录):财务提(submit_payroll_payment_reversal_request)·
--      CFO 批(decide_payroll_request,不改)· 财务执行(reverse_payroll_payment,冲销日由人给、必填)。整张冲(Q2);期间仍 posted,
--      清掉那张分录付过的行的戳(含净额为零的行)或那一期 CPF / 扣款的日期与链接(Q5);工资 / CPF / 扣款同一种申请(Q7)。
--   ② 通用日记账冲销(reverse_journal_entry · 冲销申请的提交与过账)对工资付款分录与它们的冲销按名拒
--      JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL(journal_entry_reversal_route 的第五个答案 'payroll_payment',Q8)。
--   ③ 银行行已经配上对账单行的分录,四条冲销路(工资付款 · 付款 · 行内转账 · 代扣税缴纳)在提、批、执行三处都按名拒
--      REVERSAL_BANK_MATCHED(assert_entry_not_bank_matched,Q6)。不自动取消配对。
--   ④ leave_types 四列(资格期 · 规矩 · 台阶 · 折算下限)与它们的值;leave_balance_internal 按服务期给额度(B1,Q10 · Q11)。
--   ⑤ leave_balances:一个人每一种有额度的假别的余额,一次调用(B2,Q12)。payroll_payment_entries:付薪页上每一次付款一行。
--
-- 【不做什么】不碰审批开关、hook、存储、任何账号与角色;不建任何单据;不改任何分录;require_calibrated_since 保持空。
--   既有的行一行没动,只有 leave_types 八行被写上新的四列(这是本刀的意图;那八行原有各列逐字未变)。
--
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):旧的凭证页对工资付款分录仍画「提冲销申请」—— 按下去库按名拒(新码,旧应用不认得,
--   印原文);旧的 /me 只读年假(leave_balance 签名未变)—— 病假余额按服务期变成 0(线上 6 个人都不满 3 个月;线上 0 张非年假请假)。
--   其余都是收紧或新增,旧应用一条都碰不到。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;既有的行逐字未变;
--   本事务写的变更记录只有 leave_types 那八行;清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;两张 COD 原样;328 张表;
--   变更记录覆盖零缺口、豁免 9;匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权;在途单据一张不少、每一张仍有一个决定人。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
CREATE TEMP TABLE ppr1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PPR1_PRE|approvals are expected ON';
    END IF;
    IF to_regprocedure('public.reverse_payroll_payment(uuid, date)') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'payroll_requests' AND column_name = 'target_entry_id')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'leave_types' AND column_name = 'service_rule') THEN
        RAISE EXCEPTION 'PPR1_PRE|this migration has already run';
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests WHERE kind NOT IN ('post', 'reversal')) THEN
        RAISE EXCEPTION 'PPR1_PRE|unexpected payroll request kinds';
    END IF;
    IF EXISTS (SELECT 1 FROM journal_requests jr JOIN journal_entries je ON je.id = jr.target_entry_id
                WHERE je.source_type = 'payroll' AND jr.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PPR1_PRE|an open journal request targets a payroll entry (Step 0 measured 0) — it would be stranded by Q8';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '634c00f9-c3a9-4444-9eed-b624cb6a2a93' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'PPR1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 328 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected 328 public tables';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'PPR1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected the two recorded COD byte strings';
    END IF;
    IF (SELECT count(*) FROM leave_types WHERE code IN ('sick', 'hospitalisation', 'childcare', 'extended_childcare', 'maternity',
            'paternity', 'shared_parental', 'infant_care', 'marriage', 'compassionate', 'examination')
            AND default_days_per_year IS NOT NULL AND NOT is_accrued) <> 11 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected the 11 non-annual quota leave types';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00 —— 以 tim@(cfo)身份【读】,读完即清
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'PPR1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO ppr1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE ppr1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE ppr1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE ppr1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE ppr1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_requests t ) AS payroll_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'updated_at')::text, '|' ORDER BY (to_jsonb(t) - 'updated_at')::text), '')) FROM leave_types t ) AS leave_types,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_periods t ) AS payroll_periods,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_lines t ) AS payroll_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t ) AS payment_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_transfers t ) AS bank_transfers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM wht_remittances t ) AS wht_remittances,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_statements t ) AS bank_statements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_statement_lines t ) AS bank_statement_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_line_matches t ) AS bank_line_matches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_requests t ) AS journal_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM leave_requests t ) AS leave_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM leave_grants t ) AS leave_grants,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) AS employees,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) AS accounts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM account_settings t ) AS account_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues;
CREATE TEMP TABLE ppr1_storage_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM storage.objects) AS objects, (SELECT count(*) FROM storage.buckets) AS buckets,
       (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') AS policies;

-- ── 1 · payroll_requests:第三种 payment_reversal 与它冲的那一张分录(镜像:db/tables/payroll_requests.sql)──
ALTER TABLE public.payroll_requests DROP CONSTRAINT payroll_requests_kind_check;
ALTER TABLE public.payroll_requests ADD CONSTRAINT payroll_requests_kind_check CHECK (kind IN ('post', 'reversal', 'payment_reversal'));
ALTER TABLE public.payroll_requests ADD COLUMN target_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT;
ALTER TABLE public.payroll_requests DROP CONSTRAINT payroll_requests_reversal_reason;
ALTER TABLE public.payroll_requests ADD CONSTRAINT payroll_requests_reversal_reason CHECK (
        kind NOT IN ('reversal', 'payment_reversal') OR btrim(COALESCE(notes, '')) <> '');
ALTER TABLE public.payroll_requests ADD CONSTRAINT payroll_requests_payment_reversal_target CHECK ((kind = 'payment_reversal') = (target_entry_id IS NOT NULL));
CREATE INDEX payroll_requests_target_entry_id_rel ON public.payroll_requests (target_entry_id);
COMMENT ON COLUMN public.payroll_requests.target_entry_id IS
    'PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22):payment_reversal 冲的那一张付款分录(工资 / CPF / 扣款,payroll_payment_entry_kind 认种类)。另外两种为 NULL(payroll_requests_payment_reversal_target)。';

-- 列授权不随 ADD COLUMN 延伸(AGENTS.md「Adding a column to a masked table」):同一支迁移里补进列授权与遮蔽视图
GRANT SELECT (id, payroll_period_id, kind, status, label, currency, fx_rate, notes, decided_at, decided_by, decision_notes,
              withdrawn_at, withdrawn_by, executed_at, executed_by, result_journal_entry_id, created_at, created_by, target_entry_id)
    ON public.payroll_requests TO authenticated;

CREATE OR REPLACE VIEW public.payroll_requests_masked WITH (security_invoker = off) AS
 SELECT id,
    payroll_period_id,
    kind,
    status,
    label,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN snapshot
            ELSE NULL::jsonb
        END AS snapshot,
    currency,
    fx_rate,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN gross_total
            ELSE NULL::numeric
        END AS gross_total,
        CASE
            WHEN has_permission('data.view_pay'::text) THEN amount_base
            ELSE NULL::numeric
        END AS amount_base,
    notes,
    decided_at,
    decided_by,
    decision_notes,
    withdrawn_at,
    withdrawn_by,
    executed_at,
    executed_by,
    result_journal_entry_id,
    created_at,
    created_by,
    target_entry_id
   FROM payroll_requests
  WHERE has_permission('module.hr.view'::text);

-- ── 2 · leave_types:按服务期给额度的四列与它们的值(镜像:db/tables/leave_types.sql)──
ALTER TABLE public.leave_types ADD COLUMN qualifying_service_months      smallint NOT NULL DEFAULT 0 CHECK (qualifying_service_months >= 0);
ALTER TABLE public.leave_types ADD COLUMN service_rule                   text NOT NULL DEFAULT 'full' CHECK (service_rule IN ('full', 'steps', 'prorate_first_year'));
ALTER TABLE public.leave_types ADD COLUMN service_steps                  jsonb;
ALTER TABLE public.leave_types ADD COLUMN prorate_minimum_days           numeric CHECK (prorate_minimum_days IS NULL OR prorate_minimum_days >= 0);
ALTER TABLE public.leave_types ADD CONSTRAINT leave_types_service_steps_shape CHECK ((service_rule = 'steps') = (service_steps IS NOT NULL));
UPDATE public.leave_types SET qualifying_service_months = 3, service_rule = 'steps', service_steps = '{"3": 5, "4": 8, "5": 11}'::jsonb WHERE code = 'sick';
UPDATE public.leave_types SET qualifying_service_months = 3, service_rule = 'steps', service_steps = '{"3": 15, "4": 30, "5": 45}'::jsonb WHERE code = 'hospitalisation';
UPDATE public.leave_types SET qualifying_service_months = 3, service_rule = 'prorate_first_year', prorate_minimum_days = 2 WHERE code = 'childcare';
UPDATE public.leave_types SET qualifying_service_months = 3, service_rule = 'prorate_first_year' WHERE code = 'extended_childcare';
UPDATE public.leave_types SET qualifying_service_months = 3 WHERE code IN ('maternity', 'paternity', 'shared_parental', 'infant_care');

-- ── 3 · 新函数(镜像原样)──

-- db/functions/assert_entry_not_bank_matched.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q6):一张分录的银行行已经配上了对账单行,就不许冲它 —— 按名拒,说出怎么办。
--
--   REVERSAL_BANK_MATCHED|<分录编号>|<对账单编号>|<open|reconciled>
--     open       → 先在对账单上把那一行【取消配对】(unmatch_bank_line),再冲;
--     reconciled → 那张对账单已经对完账,先【撤销对账】(unreconcile_statement),再取消配对,再冲。
--   不替人自动取消配对:对完账的单子取消不了配对(STATEMENT_RECONCILED),而悄悄撤销一次对账比拒绝更坏。
--
-- 【为什么四条冲销路都要它】冲销把原分录翻成 reversed,而 bank_line_matches 里那一行仍指着它 ——
--   对账单上那一行从此"配着"一张已经不在账上的分录;match_bank_line 自己对 reversed 分录按名拒(JL_ENTRY_REVERSED),
--   于是这个状态只能从冲销那一侧产生。Step 0 量过:库里没有任何一条冲销路看 bank_line_matches(grep 只命中配对 / 取消配对 /
--   对账行 / 两支留痕函数)。工资付款、付款、行内转账、代扣税缴纳四条冲销引擎都在冲之前调它;
--   提交与批准各自的试跑走的是同一支引擎,所以提、批、执行三处都拒。
--
-- 【INVOKER,不问码】它只在四支 SECURITY DEFINER 引擎里被调(属主身份,bank_line_matches 的 RLS 不参与);
--   authenticated 收回了 EXECUTE(db/views/zzz_function_grants.sql)—— 够不着,而不是靠门。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.assert_entry_not_bank_matched(p_entry_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code   text;
    v_stmt   text;
    v_status text;
BEGIN
    SELECT je.code, s.code, s.status INTO v_code, v_stmt, v_status
      FROM journal_lines jl
      JOIN journal_entries je ON je.id = jl.entry_id
      JOIN bank_line_matches m ON m.journal_line_id = jl.id
      JOIN bank_statement_lines bl ON bl.id = m.statement_line_id
      JOIN bank_statements s ON s.id = bl.statement_id
     WHERE jl.entry_id = p_entry_id
     ORDER BY s.code
     LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'REVERSAL_BANK_MATCHED|%|%|%', v_code, v_stmt, v_status;
    END IF;
END;
$function$;

-- db/functions/payroll_payment_entry_kind.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q7):一张分录是不是一次工资【付款】,是哪一种 —— 读【已付的戳】:
--   'salary'     —— 有工资行的 paid_journal_entry_id 指着它(pay_payroll_lines 一次调用 = 一张分录,一人一条银行行);
--   'cpf'        —— 某一期的 cpf_journal_entry_id 指着它(pay_payroll_cpf);
--   'deductions' —— 某一期的 deductions_journal_entry_id 指着它(pay_payroll_deductions);
--   NULL         —— 都不是(工资期的过账分录、已经被冲掉而戳已清掉的付款、别的什么分录)。
-- 一支判据,三个读它的人:工资付款冲销的引擎(认种类、决定清哪一组戳)、journal_entry_reversal_route(通用口按名拒)、
-- payroll_payment_entries(付薪页上每一次付款画一行)。
-- 【INVOKER,不问码】只在 DEFINER 函数里被调;authenticated 收回了 EXECUTE。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.payroll_payment_entry_kind(p_entry_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
               WHEN p_entry_id IS NULL THEN NULL
               WHEN EXISTS (SELECT 1 FROM payroll_lines pl WHERE pl.paid_journal_entry_id = p_entry_id) THEN 'salary'
               WHEN EXISTS (SELECT 1 FROM payroll_periods pp WHERE pp.cpf_journal_entry_id = p_entry_id) THEN 'cpf'
               WHEN EXISTS (SELECT 1 FROM payroll_periods pp WHERE pp.deductions_journal_entry_id = p_entry_id) THEN 'deductions'
           END
$function$;

-- db/functions/reverse_payroll_payment_internal.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q2 · Q4 · Q5 · Q6 · Q7):冲掉一次工资【付款】—— 引擎(不问码)。
--
--   · 冲的是【一整张】付款分录(pay_payroll_lines 一次调用 = 一张分录;CPF / 扣款各一张)—— 不能只冲一个人(Q2)。
--     付对了的人,冲销之后再付一次。
--   · 哪一种付款,从【已付的戳】认(payroll_payment_entry_kind,Q7):工资 / CPF / 扣款同一种申请。认不出 → 按名拒
--     PAYROLL_PAYMENT_ENTRY_UNKNOWN(过账分录、已冲过而戳已清的付款、别的分录都落在这里)。
--   · 冲销日由人给、必填、不默认(Q3):REVERSAL_DATE_REQUIRED;晚于今天按名拒 DOCUMENT_DATE_IN_FUTURE|payroll_payment_reversal|…
--     (与六扇出钱的门同一句,Q4);早于原付款由 reverse_journal_entry_internal 按名拒 REVERSAL_BEFORE_ORIGINAL;
--     落在锁定期由 post_journal_entry 按期间锁拒 —— 原付款所在的月关了,冲销就选一个开着的月份,原件留在原地(Q4)。
--   · 付款的银行行已经配上了对账单行 → 按名拒 REVERSAL_BANK_MATCHED(assert_entry_not_bank_matched,Q6)。不自动取消配对。
--   · 冲完:期间【仍是 posted】;那张分录付过的行(含净额为零、没有银行行却同样盖了戳的行)清掉 paid_at 与
--     paid_journal_entry_id;CPF / 扣款清掉那一期的日期与分录链接(Q5)。于是那一期可以再付;一笔付款都不剩时,
--     既有的撤销过账申请又走得通(unpost_payroll_period_internal 的 PAYROLL_*_PAID 三道闸自然放行)。
--     历史留在申请行(target_entry_id · result_journal_entry_id)与那张已冲销的分录上。
--
-- 【调用者】reverse_payroll_payment(执行门,批过的申请)与 payroll_request_dry_run(提、批两次试跑,永远回滚)。
-- authenticated 收回了 EXECUTE(db/views/zzz_function_grants.sql)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.reverse_payroll_payment_internal(p_entry_id uuid, p_reversal_date date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_je    journal_entries%ROWTYPE;
    v_kind  text;
    v_res   jsonb;
    v_n     integer := 0;
    v_pid   uuid;
BEGIN
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;
    IF p_reversal_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|payroll_payment_reversal|%|%', p_reversal_date, CURRENT_DATE;
    END IF;

    SELECT * INTO v_je FROM journal_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_entry_id::text, '?');
    END IF;
    v_kind := payroll_payment_entry_kind(v_je.id);
    IF v_je.source_type IS DISTINCT FROM 'payroll' OR v_kind IS NULL THEN
        RAISE EXCEPTION 'PAYROLL_PAYMENT_ENTRY_UNKNOWN|%', v_je.code;
    END IF;
    IF v_je.status <> 'posted' OR v_je.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'JE_ALREADY_REVERSED|%', v_je.code;
    END IF;

    PERFORM assert_entry_not_bank_matched(v_je.id);

    v_res := reverse_journal_entry_internal(v_je.id, p_reversal_date,
                 'Payroll payment reversal ' || v_je.code || COALESCE(' — ' || NULLIF(btrim(p_memo), ''), ''));

    IF v_kind = 'salary' THEN
        UPDATE payroll_lines
           SET paid_at = NULL, paid_journal_entry_id = NULL
         WHERE paid_journal_entry_id = v_je.id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    ELSIF v_kind = 'cpf' THEN
        UPDATE payroll_periods
           SET cpf_paid_at = NULL, cpf_journal_entry_id = NULL
         WHERE cpf_journal_entry_id = v_je.id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    ELSE
        UPDATE payroll_periods
           SET deductions_paid_at = NULL, deductions_journal_entry_id = NULL
         WHERE deductions_journal_entry_id = v_je.id;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    v_pid := v_je.source_id;

    RETURN jsonb_build_object('entry_id', v_je.id, 'code', v_je.code, 'kind', v_kind,
                              'payroll_period_id', v_pid, 'cleared', v_n,
                              'reversal_id', v_res->>'reversal_id', 'reversal_code', v_res->>'code');
END;
$function$;

-- db/functions/submit_payroll_payment_reversal_request.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q1):提一张【工资付款冲销】申请 —— payroll_requests 的第三种(payment_reversal)。
--   财务提(module.hr.edit,工资期本来就归这个码;finance 角色持有它)· CFO 批每一张、不分档(decide_payroll_request,不改)·
--   财务执行(reverse_payroll_payment,提单人也可以)。审批关着时生下来就是 approved(auto_approved),与另外两种同形。
--   期间冻结与「一期同时只挂一张未了结的申请」照用(payroll_requests_one_open_per_period)。
--   理由必填:审批人读的就是它,也是冲销分录摘要里那一句。
--   提交时就以【今天】为探测日试跑一次真引擎(payroll_request_dry_run,永远回滚):已冲过、认不出、银行行已配对(Q6)
--   都在 CFO 看见之前按引擎原话拒;真正的冲销日在执行时由人给(Q3)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.submit_payroll_payment_reversal_request(p_entry_id uuid, p_notes text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_je    journal_entries%ROWTYPE;
    v_p     payroll_periods%ROWTYPE;
    v_id    uuid := gen_random_uuid();
    v_on    boolean := approvals_enabled();
    v_label text;
    v_n     integer;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_je FROM journal_entries WHERE id = p_entry_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'JE_NOT_FOUND|%', COALESCE(p_entry_id::text, '?');
    END IF;
    IF v_je.source_type IS DISTINCT FROM 'payroll' OR payroll_payment_entry_kind(v_je.id) IS NULL THEN
        RAISE EXCEPTION 'PAYROLL_PAYMENT_ENTRY_UNKNOWN|%', v_je.code;
    END IF;
    SELECT * INTO v_p FROM payroll_periods
     WHERE id = v_je.source_id AND deleted_at IS NULL
     FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_NOT_FOUND|%', COALESCE(v_je.source_id::text, '?');
    END IF;
    IF p_notes IS NULL OR btrim(p_notes) = '' THEN
        RAISE EXCEPTION 'PAYROLL_REVERSAL_REASON_REQUIRED|%', v_p.code;
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests r
                WHERE r.payroll_period_id = v_p.id AND r.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_OPEN|%', v_p.code;
    END IF;

    PERFORM assert_other_decider('payroll_request', 'decide_payroll_request', 2::smallint,
                                 'PAYROLL_NO_OTHER_DECIDER|' || v_p.code);

    SELECT count(*) + 1 INTO v_n FROM payroll_requests
     WHERE payroll_period_id = v_p.id AND kind = 'payment_reversal';
    v_label := v_p.code || ' · payment_reversal #' || v_n::text;

    INSERT INTO payroll_requests (id, payroll_period_id, kind, status, label, snapshot,
                                  currency, fx_rate, gross_total, amount_base, notes, created_by, target_entry_id)
    VALUES (v_id, v_p.id, 'payment_reversal',
            CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
            v_label, payroll_period_fingerprint(v_p.id),
            v_p.currency, v_p.fx_rate, v_p.gross_total, round(v_p.gross_total * v_p.fx_rate, 2),
            btrim(p_notes), auth.uid(), v_je.id);

    PERFORM payroll_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('payroll_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM record_approval_decision('payroll_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved,没有人按过批准');
    END IF;

    RETURN jsonb_build_object('request_id', v_id, 'label', v_label, 'entry_code', v_je.code,
                              'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$;

-- db/functions/reverse_payroll_payment.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q1 · Q3):执行一张【批过的】工资付款冲销申请 —— 门。
--   财务执行(module.hr.edit;提单人也可以)。冲销日由执行的人给、必填、不默认(Q3)—— 那是钱真的回来的那一天;
--   日期的三道闸(不晚于今天 · 不早于原付款 · 不落在锁定期)在引擎与过账里(Q4)。
--   申请必须是这一种、而且是 approved:否则按名拒 PAYROLL_NEEDS_APPROVED_REQUEST|<申请>|payment_reversal。
--   批的那一组数(期间指纹)变了 → PAYROLL_CHANGED_SINCE_REQUEST(与另外两种同一句)。
--   银行行在批准之后才配上的 → 引擎按名拒 REVERSAL_BANK_MATCHED(Q6:执行时再判一次)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.reverse_payroll_payment(p_request_id uuid, p_reversal_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r   payroll_requests%ROWTYPE;
    v_res jsonb;
BEGIN
    PERFORM require_permission('module.hr.edit');
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;
    SELECT * INTO v_r FROM payroll_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYROLL_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF v_r.kind <> 'payment_reversal' OR v_r.status <> 'approved' THEN
        RAISE EXCEPTION 'PAYROLL_NEEDS_APPROVED_REQUEST|%|payment_reversal', v_r.label;
    END IF;
    IF payroll_period_fingerprint(v_r.payroll_period_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'PAYROLL_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    v_res := reverse_payroll_payment_internal(v_r.target_entry_id, p_reversal_date, v_r.notes);

    UPDATE payroll_requests
       SET status = 'executed', executed_at = now(), executed_by = auth.uid(),
           result_journal_entry_id = (v_res->>'reversal_id')::uuid
     WHERE id = v_r.id;

    RETURN v_res || jsonb_build_object('request_id', v_r.id, 'request_label', v_r.label);
END;
$function$;

-- db/functions/payroll_payment_entries.sql
-- PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q1 · Q6 · Q8):付薪页(/finance/payroll-payments)上每一期的【每一次付款】一行 ——
--   冲销申请就从这一行提,通用日记账冲销按名拒时指的也是这一页(JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL)。
--   每一行:分录 id / 编号 / 日期 / 状态 · 种类(salary · cpf · deductions,payroll_payment_entry_kind)· 金额(贷方银行合计,本位币;
--   不持 data.view_pay → NULL,屏幕印「受限」)· 银行行有没有配上对账单行、配在哪一张、那一张对完账没有(Q6:钮看得见、按不动、说出先做什么)·
--   这一期挂着的那一张未了结申请(任何一种;一期同时只挂一张)。
--   只列【还盖着戳】的付款 —— 冲掉之后戳清了,它就从这里消失;历史在页底的审计记录与那张已冲销的分录上。
-- 【门】module.finance.view 或 module.hr.view(付薪页的门是前者;工资期页的门是后者)—— 不持任何一个按名拒,不回零行。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.payroll_payment_entries(p_period_ids uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_pay boolean := has_permission('data.view_pay');
BEGIN
    IF NOT (has_permission('module.finance.view') OR has_permission('module.hr.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'entry_id', je.id, 'code', je.code, 'entry_date', je.entry_date, 'status', je.status,
                   'payroll_period_id', je.source_id, 'kind', k.kind,
                   'amount', CASE WHEN v_pay THEN (SELECT round(sum(jl.credit), 2) FROM journal_lines jl
                                                    JOIN accounts a ON a.id = jl.account_id
                                                   WHERE jl.entry_id = je.id AND a.code IN ('1000', '1010')) END,
                   'lines_paid', CASE WHEN k.kind = 'salary'
                                      THEN (SELECT count(*) FROM payroll_lines pl WHERE pl.paid_journal_entry_id = je.id) END,
                   'bank_statement', m.stmt, 'bank_statement_status', m.st,
                   'open_request', (SELECT jsonb_build_object('id', r.id, 'label', r.label, 'kind', r.kind, 'status', r.status,
                                                              'target_entry_id', r.target_entry_id)
                                      FROM payroll_requests r
                                     WHERE r.payroll_period_id = je.source_id AND r.status IN ('submitted', 'approved')
                                     LIMIT 1))
                   ORDER BY je.entry_date, je.code)
          FROM journal_entries je
          CROSS JOIN LATERAL (SELECT payroll_payment_entry_kind(je.id) AS kind) k
          LEFT JOIN LATERAL (SELECT s.code AS stmt, s.status AS st
                               FROM journal_lines jl
                               JOIN bank_line_matches bm ON bm.journal_line_id = jl.id
                               JOIN bank_statement_lines bl ON bl.id = bm.statement_line_id
                               JOIN bank_statements s ON s.id = bl.statement_id
                              WHERE jl.entry_id = je.id
                              ORDER BY s.code LIMIT 1) m ON true
         WHERE je.source_type = 'payroll' AND je.source_id = ANY (p_period_ids) AND k.kind IS NOT NULL), '[]'::jsonb);
END;
$function$;

-- db/functions/leave_service_entitlement.sql
-- PAYROLL-PAY-REVERSAL-1 · B1(Tim 2026-10-22,Step 0 Q10 · Q11):一个按年额度的假别,对【服务了这么久】的人,这一年给多少天。
--
--   服务期 = 从 hire_date 到 p_as_of(请假的开始日;余额页上是今天)之间【完整的月数】,不满一个月的那一截不算(Q10):
--     age(p_as_of, hire_date) 的 年 × 12 + 月。1 月 31 日入职、2 月 28 日请 —— 0 个月。
--   规矩全是 leave_types 上的列(Q11:配置,不是写死的假别码):
--     qualifying_service_months   不满这么多个完整的月 → 0 天;
--     service_rule = 'full'       满了就是 default_days_per_year 整年(产假 · 陪产假 · 共享育儿假 · 婴儿看护假:3 个月;
--                                 婚假 · 恩恤假 · 考试假:0 个月,公司政策);
--     service_rule = 'steps'      满了按 service_steps 的台阶给:{"3": 5, "4": 8, "5": 11} = 第 3 / 4 / 5 个完整月各给几天,
--                                 过了最高一级台阶 → default_days_per_year(门诊病假 5 / 8 / 11 → 14;住院假 15 / 30 / 45 → 60,MOM 的表);
--     service_rule = 'prorate_first_year'  服务不满 12 个完整月时按月折算:
--                                 default_days_per_year × 完整月数 ÷ 12,四舍五入到整天(半天进位:floor(x + 0.5)),
--                                 再不少于 prorate_minimum_days(育儿假 2 天,Tim 加的);满 12 个月 → 整年。
--   p_hire_date 为 NULL(不会发生:employees.hire_date NOT NULL)按 0 个月算。
--   【INVOKER,不问码】只读 leave_types(人人可读的目录);只在 leave_balance_internal(DEFINER)里被调。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.leave_service_entitlement(p_leave_type_code text, p_hire_date date, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t      leave_types%ROWTYPE;
    v_months integer := 0;
    v_days   numeric;
    v_step   integer;
BEGIN
    SELECT * INTO v_t FROM leave_types WHERE code = p_leave_type_code;
    IF NOT FOUND OR v_t.default_days_per_year IS NULL THEN
        RETURN jsonb_build_object('days', NULL, 'service_months', NULL, 'rule', NULL);
    END IF;
    IF p_hire_date IS NOT NULL AND p_as_of >= p_hire_date THEN
        v_months := (EXTRACT(YEAR FROM age(p_as_of, p_hire_date)) * 12 + EXTRACT(MONTH FROM age(p_as_of, p_hire_date)))::integer;
    END IF;

    IF v_months < v_t.qualifying_service_months THEN
        v_days := 0;
    ELSIF v_t.service_rule = 'steps' THEN
        SELECT max(k::integer) INTO v_step
          FROM jsonb_object_keys(v_t.service_steps) k
         WHERE k::integer <= v_months;
        IF v_step IS NULL THEN
            v_days := 0;
        ELSIF v_months > (SELECT max(k::integer) FROM jsonb_object_keys(v_t.service_steps) k) THEN
            v_days := v_t.default_days_per_year;
        ELSE
            v_days := (v_t.service_steps ->> v_step::text)::numeric;
        END IF;
    ELSIF v_t.service_rule = 'prorate_first_year' AND v_months < 12 THEN
        v_days := GREATEST(floor(v_t.default_days_per_year * v_months / 12.0 + 0.5),
                           COALESCE(v_t.prorate_minimum_days, 0));
    ELSE
        v_days := v_t.default_days_per_year;
    END IF;

    RETURN jsonb_build_object('days', trim_scale(v_days), 'service_months', v_months, 'rule', v_t.service_rule,
                              'qualifying_months', v_t.qualifying_service_months,
                              'full_days', v_t.default_days_per_year);
END;
$function$;

-- db/functions/leave_balances.sql
-- PAYROLL-PAY-REVERSAL-1 · B2(Tim 2026-10-22,Step 0 Q12):一个人【每一种有额度的假别】的余额,一次调用读完 ——
--   /me 那张表画的就是它(年假在内,共 12 种;无薪假没有额度,不在里面)。每一项 = leave_balance_internal 的原样回答,
--   外加假别编号与 gender_restriction(员工档案没有性别,所以产假 / 陪产假对每个人都列出来,屏幕上标「视资格而定」)。
--   顺序 = leave_types.sort_order。只列 is_active 的假别。
-- 【门】与 leave_balance 同一道:本人或 module.hr.view(COALESCE 把「没有员工档案」读成「不是本人」—— U1-B 那条)。
-- NOTE: introduced by db/migrations/2026-10-22-payroll-pay-reversal-1.sql.

CREATE OR REPLACE FUNCTION public.leave_balances(p_employee_id uuid, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_out jsonb := '[]'::jsonb;
    r     record;
BEGIN
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    FOR r IN
        SELECT lt.code, lt.gender_restriction
          FROM leave_types lt
         WHERE lt.is_active AND (lt.is_accrued OR lt.default_days_per_year IS NOT NULL)
         ORDER BY lt.sort_order, lt.code
    LOOP
        v_out := v_out || jsonb_build_array(
            leave_balance_internal(p_employee_id, r.code, p_as_of)
            || jsonb_build_object('gender_restriction', r.gender_restriction));
    END LOOP;
    RETURN v_out;
END;
$function$;

-- ── 4 · 换掉的函数(镜像原样,同签名)──

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

-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q1 · Q3 · Q6):第三种 payment_reversal 试跑工资付款冲销的引擎。真正的冲销日在【执行】时
--   由人给(Q3),试跑只能拿一个探测日:reversal_date_for(原付款)= 今天与原付款日里较晚的那一个(付款日不晚于今天,所以就是今天)。
--   它答得了的:已冲过、认不出、银行行已配对(Q6)、今天落在锁定期;答不了的(人在执行时给的那一天)由执行再判。

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
        WHEN 'payment_reversal' THEN
            v_res := reverse_payroll_payment_internal(v_r.target_entry_id, reversal_date_for(v_r.target_entry_id), v_r.notes);
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
--   ★ MES-7a-2(2026-10-16,MES-7a Step 0 Q12):maintenance_part(备件出给保养 / 退回)进 'source_path'。更正一次出库是一行退回
--     (return_spare_parts),冲掉那张分录只会把总账拿回来、流水与那一行出库照旧 —— 1200 与库存当场对不上。
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
-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q8):工资【付款】分录与它们的冲销有了自己的路(付款冲销申请),
--   从 'request' 挪进第五个答案 'payroll_payment':三个读它的人(reverse_journal_entry · 冲销申请的提交与过账)按名拒
--   JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL,凭证页的钮看得见、按不动、指向付薪页。认它的判据:
--   戳指着它或它的原件(payroll_payment_entry_kind)—— 或者一张付款冲销申请以它或它的原件为目标
--   (冲掉之后戳清了,冲销件只能从申请上认出来)。其余的工资分录(过账与它的冲销)仍是 'source_path'。
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
                            'asset_disposal', 'maintenance_part') THEN
        RETURN 'source_path';
    END IF;
    IF v_je.source_type = 'payroll' THEN
        IF payroll_payment_entry_kind(v_je.id) IS NOT NULL
           OR payroll_payment_entry_kind(v_je.source_id) IS NOT NULL
           OR EXISTS (SELECT 1 FROM payroll_requests r
                       WHERE r.kind = 'payment_reversal' AND r.target_entry_id IN (v_je.id, v_je.source_id)) THEN
            RETURN 'payroll_payment';
        END IF;
        RETURN 'source_path';
    END IF;
    RETURN 'request';
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

-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q8):路由的第五个答案 'payroll_payment'(工资付款分录与它们的冲销)按名拒
--   JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL —— 它们有自己的冲销路(付薪页上的付款冲销申请),从这里冲会留下已付的戳。

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
    IF v_route = 'payroll_payment' THEN
        RAISE EXCEPTION 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%', v_code;
    END IF;
    RAISE EXCEPTION 'JOURNAL_NEEDS_APPROVED_REQUEST|%', v_code;
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

-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q8):路由的第五个答案 'payroll_payment'(工资付款分录与它们的冲销)按名拒
--   JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL —— 它们有自己的冲销路(付薪页上的付款冲销申请),从这里冲会留下已付的戳。

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
        IF v_route = 'payroll_payment' THEN
            RAISE EXCEPTION 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%', v_je.code;
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
        -- U1-B:返回值也是一扇读的门 —— 工资分录的冲销申请,金额只给持 data.view_pay 的人(journal_request_amount_visible)。
        'amount_base', CASE WHEN journal_request_amount_visible(v_id)
                            THEN COALESCE(v_post->'amount_base', v_dry->'amount_base') END,
        'credits_bank', COALESCE(v_post->'credits_bank', v_dry->'credits_bank'),
        'entry_id', v_post->>'entry_id',
        'journal_code', v_post->>'journal_code');
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

-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q8):路由的第五个答案 'payroll_payment'(工资付款分录与它们的冲销)按名拒
--   JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL —— 它们有自己的冲销路(付薪页上的付款冲销申请),从这里冲会留下已付的戳。

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
        IF v_route = 'payroll_payment' THEN
            RAISE EXCEPTION 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%', v_code;
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

-- db/functions/reverse_payment_internal.sql
-- PAY-REQ-1(2026-09-23):reverse_payment 的函数体搬到这里,拿掉了权限检查,
-- 并补上镜像行漏抄的 employee_id。下面是它原来的抬头,照录:
--
-- SOD-1(2026-08-24):这支函数现在【声明】自己在冲销。
-- guard_payment_sod 会拦住"建收款人的人付款给该收款人",而冲销的镜像行
-- direction/counterparty 与原单相同,会走到那道闸上。冲销是把钱【收回来】的
-- 更正动作 —— 拦住它只会把一笔记错的付款锁死在账上,而且拦不住任何舞弊。
-- 所以由调用方显式声明,不由守卫去猜(po_status_ctx / close_ctx / alloc_ctx 同一惯用法)。
-- 【用完立刻清掉】set_config(..., true) 是【事务】局部,不是语句局部 ——
-- 只设不清,同一事务里后面任何一笔直连 INSERT 都会畅通无阻(APR-2c fu2 实测过)。
-- fixture 127 的 B5 臂把"立起来"与"落下去"一起断言。

-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q6):银行行已经配上了对账单行就不冲 —— 按名拒 REVERSAL_BANK_MATCHED
--   (assert_entry_not_bank_matched;先取消配对,对完账的先撤销对账)。提、批两次试跑与执行走的都是这支引擎,所以三处都拒。

CREATE OR REPLACE FUNCTION public.reverse_payment_internal(p_payment_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        payments%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    -- ★ PAY-REQ-1:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回。
    --   唯一的外门是 pay_payment_request(finance.edit,且只执行一张已批准的冲销申请);
    --   payment_request_dry_run 在提交与批准时照同一套规矩核一遍再回滚。
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    PERFORM assert_entry_not_bank_matched(v_orig.journal_entry_id);

    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN document_type_prefix('payment_receipt') ELSE document_type_prefix('payment_out') END, CURRENT_DATE);

    -- SOD-1:告诉 guard_payment_sod 这是一次【冲销】,不是一次付款。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '1', true);
    -- ★ PAY-REQ-1:镜像行此前【漏抄 employee_id】—— payments 的形状 CHECK 要求
    --   付给员工的那一行恰好带着它,于是冲销一笔员工付款会撞 CHECK 失败
    --   (PAY-REQ-1 grilling 读代码发现;从此每一次冲销都走申请,这条路第一次真的会被走到)。
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          employee_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id, v_orig.employee_id,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.bank_account_code, CURRENT_DATE,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());
    -- 【立刻清掉】—— 事务局部,不清就一直开着。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '', true);

    UPDATE payments
    SET status = 'reversed', reversed_by_payment = v_mirror_id
    WHERE id = p_payment_id;

    RETURN jsonb_build_object(
        'reversal_payment_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;

-- db/functions/reverse_bank_transfer_internal.sql
-- PAY-REQ-1 · Batch B(2026-09-23):reverse_bank_transfer 的函数体搬到这里,拿掉了权限检查。
-- 原来的抬头照录:冲销一笔行内转账(FIN-1b B5:更正靠冲销,不靠改)。
-- 分录走 reverse_journal_entry_internal(镜像反向行,两边账户如数还原);
-- 转账行打上 reversed_* 标记,不许二次冲销。日期必填(FIN-10:不默认今天)。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q6):银行行已经配上了对账单行就不冲 —— 按名拒 REVERSAL_BANK_MATCHED
--   (assert_entry_not_bank_matched;先取消配对,对完账的先撤销对账)。提、批两次试跑与执行走的都是这支引擎,所以三处都拒。

CREATE OR REPLACE FUNCTION public.reverse_bank_transfer_internal(p_transfer_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t  bank_transfers%ROWTYPE;
    v_je jsonb;
BEGIN
    -- ★ PAY-REQ-1 Batch B:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回;
    --   唯一的外门是 pay_payment_request(一张已批准的 bank_transfer_reversal 申请)。
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_t FROM bank_transfers WHERE id = p_transfer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TRANSFER_NOT_FOUND|%', COALESCE(p_transfer_id::text, '?');
    END IF;
    IF v_t.reversed_at IS NOT NULL THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_REVERSED|%', p_transfer_id;
    END IF;

    PERFORM assert_entry_not_bank_matched(v_t.journal_entry_id);

    v_je := reverse_journal_entry_internal(v_t.journal_entry_id,
                p_reversal_date,
                COALESCE(p_memo, 'Reverse bank transfer'));

    UPDATE bank_transfers
    SET reversed_at = now(), reversed_by = auth.uid(),
        reversal_entry_id = (v_je->>'reversal_id')::uuid
    WHERE id = p_transfer_id;

    RETURN jsonb_build_object('transfer_id', p_transfer_id,
                              'reversal_journal_code', v_je->>'code',
                              'reversal_entry_id', v_je->>'reversal_id');
END;
$function$;

-- db/functions/reverse_wht_remittance_internal.sql
-- PAY-REQ-1 · Batch B(2026-09-23,Tim 的 Q3):更正一笔代扣税缴纳。
--
-- 此前它的更正是在通用冲销口冲它的分录(Batch A 故意留着那扇门,因为没有别的路)。
-- 现在它走一张 wht_remittance_reversal 申请:财务提、CFO 批、财务执行,执行时调这里。
-- 那扇门(reverse_journal_entry 对 source_type = 'wht_remittance')同一刀关上。
--
-- 【它做的事与通用冲销口逐字相同】冲掉缴纳那张分录(reverse_journal_entry_internal,
-- 镜像反向行,source_type 照抄 'wht_remittance')。wht_remittances 那一行【不动】——
-- 它是只可追加的(WHT_REMITTANCE_IMMUTABLE)。它从"已汇"里掉出来,靠的是
-- wht_liability_by_month 只认分录仍是 posted 的缴纳:于是这个月的欠款原样回来。
-- fixture 142 G 臂断言的正是这一句。
--
-- 日期必填(FIN-10:不默认今天);已冲过的缴纳按名拒。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

-- ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Step 0 Q6):银行行已经配上了对账单行就不冲 —— 按名拒 REVERSAL_BANK_MATCHED
--   (assert_entry_not_bank_matched;先取消配对,对完账的先撤销对账)。提、批两次试跑与执行走的都是这支引擎,所以三处都拒。

CREATE OR REPLACE FUNCTION public.reverse_wht_remittance_internal(p_remittance_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_w  wht_remittances%ROWTYPE;
    v_st text;
    v_je jsonb;
BEGIN
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;
    SELECT * INTO v_w FROM wht_remittances WHERE id = p_remittance_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_NOT_FOUND|%', COALESCE(p_remittance_id::text, '?');
    END IF;
    SELECT status INTO v_st FROM journal_entries WHERE id = v_w.journal_entry_id;
    IF v_st IS DISTINCT FROM 'posted' THEN
        RAISE EXCEPTION 'WHT_REMITTANCE_ALREADY_REVERSED|%', v_w.code;
    END IF;

    PERFORM assert_entry_not_bank_matched(v_w.journal_entry_id);

    v_je := reverse_journal_entry_internal(v_w.journal_entry_id, p_reversal_date,
                COALESCE(p_memo, 'Reverse withholding tax remittance ' || v_w.code));

    RETURN jsonb_build_object('remittance_id', p_remittance_id, 'code', v_w.code,
                              'reversal_journal_code', v_je->>'code',
                              'reversal_entry_id', v_je->>'reversal_id');
END;
$function$
;

-- db/functions/leave_balance_internal.sql
-- 余额的算式(不查权限)。三个来源:授予行 + 当年度的派生累积(年假)+ 按年额度(其余有额度的假别)。
-- 【HR-2a 那个重复计数的坑】carried_out 扣减照旧:结转是把剩余搬走,不是复制一份。
-- 当年累积没有 expires_on,所以「先用旧的」天然把它排在结转之后,失效逻辑也碰不到它。
--
-- ★ LEAVE-BAL-1(2026-09-28,Tim Q1–Q22):
--   · 'available' 的含义【一个字没改】= 额度 − 已批(employees_masked 与三个页面照旧读它)。
--   · 新增 'pending'(同一人、同一假别、开始日在同一年、还在等批的天数)与
--     'bookable' = available − pending —— 【提交】看 bookable,【审批】看 available(Q10 Option A:
--     别人还在等的单不算,批准不可能让已批超过额度)。
--   · 'balance_checked':这个假别【有没有额度】—— 年假(is_accrued)或 default_days_per_year 不为空。
--     只有 unpaid 没有(Q1)。没有额度的假别 available/bookable 照算(= 0 或授予),但【没有人拿它拒】。
--   · 按年额度:按【开始日】所在公历年扣已批(Q5 · Q7)。
--   ★ PAYROLL-PAY-REVERSAL-1 · B1(Tim 2026-10-22):额度按服务期给(leave_service_entitlement)—— LEAVE-BAL-1 Q6 登记的
--     「整年给足、不看服务期」(LEAVEBAL1-NO-NEW-HIRE-PRORATING)到此关闭。
--
-- NOTE: introduced/updated by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       LEAVE-BAL-1 by db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql.

CREATE OR REPLACE FUNCTION public.leave_balance_internal(p_employee_id uuid, p_leave_type_code text DEFAULT 'annual'::text, p_as_of date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_break   jsonb := '[]'::jsonb;
    v_granted numeric := 0;
    v_used    numeric := 0;
    v_expired numeric := 0;
    v_avail   numeric := 0;
    v_accrued numeric := 0;
    v_acc_used numeric := 0;
    v_year    integer := EXTRACT(YEAR FROM p_as_of)::integer;
    v_type    record;
    v_yearly  numeric := 0;
    v_yr_used numeric := 0;
    v_pending numeric := 0;
    v_checked boolean;
    v_svc     jsonb;
    r         record;
BEGIN
    -- 【本人或 HR】与 leave_balance 同一道口径。
    -- U1-B(U1A-SELF-GATE-NULL-TRAP):没有员工档案的账号,current_user_employee() 是 NULL,
    --   NOT (false OR NULL) 是 NULL,IF NULL 不进分支 —— 门曾经是开的。COALESCE 把「未知」读成「不是本人」。
    IF NOT (has_permission('module.hr.view') OR COALESCE(p_employee_id = current_user_employee(), false)) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;
    FOR r IN
        SELECT g.id, g.leave_year, g.days, g.granted_on, g.expires_on, g.grant_type,
               COALESCE((SELECT SUM(CASE WHEN c.entry_type='draw' THEN c.days ELSE -c.days END)
                         FROM leave_consumption c WHERE c.leave_grant_id = g.id), 0) AS consumed,
               -- 【已被结转走的部分】。结转是把剩余【搬到】下一年的一笔新授予里,
               -- 不是复制一份 —— 若不在这里扣掉,同样的天数会在来源授予和结转授予里
               -- 【各算一次】,余额凭空翻倍。这一条是本切最容易做错的地方之一。
               COALESCE((SELECT SUM(cf.days) FROM leave_grants cf
                         WHERE cf.source_grant_id = g.id AND cf.grant_type = 'carry_forward'
                           AND cf.deleted_at IS NULL), 0) AS carried_out
        FROM leave_grants g
        WHERE g.employee_id = p_employee_id AND g.leave_type_code = p_leave_type_code
          AND g.deleted_at IS NULL AND g.granted_on <= p_as_of
        ORDER BY g.expires_on NULLS LAST, g.granted_on
    LOOP
        v_granted := v_granted + r.days;
        v_used := v_used + r.consumed;
        IF r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0 THEN
            NULL;
        ELSIF r.expires_on IS NOT NULL AND r.expires_on < p_as_of THEN
            v_expired := v_expired + (r.days - r.consumed - r.carried_out);
        ELSE
            v_avail := v_avail + (r.days - r.consumed - r.carried_out);
        END IF;
        v_break := v_break || jsonb_build_object(
            'source', 'grant',
            'grant_id', r.id, 'leave_year', r.leave_year, 'grant_type', r.grant_type,
            'days', r.days, 'consumed', r.consumed, 'carried_forward_out', r.carried_out,
            'remaining', r.days - r.consumed - r.carried_out,
            'expires_on', r.expires_on,
            'status', CASE WHEN r.carried_out > 0 AND (r.days - r.consumed - r.carried_out) <= 0
                                THEN 'carried_forward'
                           WHEN r.expires_on IS NOT NULL AND r.expires_on < p_as_of
                                THEN 'expired' ELSE 'active' END);
    END LOOP;

    -- ── 第二个来源:当年度的派生累积(只有年假) ─────────────────────────────
    -- 【它没有 expires_on】—— 于是"先用旧的"天然把它排在结转行之后,
    -- 也于是失效逻辑【碰不到它】:没有可比的日期,当年挣的天数无从作废(D4)。
    IF p_leave_type_code = 'annual' THEN
        v_accrued  := accrued_annual_leave(p_employee_id, p_as_of);
        v_acc_used := consumed_from_accrual(p_employee_id, v_year);
        v_granted := v_granted + v_accrued;
        v_used    := v_used + v_acc_used;
        v_avail   := v_avail + (v_accrued - v_acc_used);
        v_break := v_break || jsonb_build_object(
            'source', 'accrual',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'monthly_accrual',
            'days', v_accrued, 'consumed', v_acc_used, 'carried_forward_out', 0,
            'remaining', v_accrued - v_acc_used,
            'expires_on', NULL, 'status', 'active');
    END IF;

    -- ── 第三个来源(LEAVE-BAL-1):按年额度 —— 年假以外、default_days_per_year 不为空的假别 ──────
    -- 【不写 leave_consumption】这些假别批准时从来不记消耗行;"已用"就是开始日落在这一年的【已批】单。
    -- 跨年的单整张算在开始日那一年(Q7)—— 与年假的 accrual_year、证明规则的年份同一个口径。
    SELECT lt.is_accrued, lt.default_days_per_year INTO v_type
      FROM leave_types lt WHERE lt.code = p_leave_type_code;
    v_checked := COALESCE(v_type.is_accrued, false) OR v_type.default_days_per_year IS NOT NULL;
    IF NOT COALESCE(v_type.is_accrued, false) AND v_type.default_days_per_year IS NOT NULL THEN
        -- ★ PAYROLL-PAY-REVERSAL-1 · B1(Tim 2026-10-22,Q10 · Q11):按服务期给 —— 资格期、MOM 的台阶、第一年按月折算,
        --   全是 leave_types 上的列,算式在 leave_service_entitlement。服务期量到 p_as_of(提交与审批传的是请假的开始日)。
        v_svc := leave_service_entitlement(p_leave_type_code,
                     (SELECT e.hire_date FROM employees e WHERE e.id = p_employee_id), p_as_of);
        v_yearly := (v_svc ->> 'days')::numeric;
        SELECT COALESCE(SUM(lr.days), 0) INTO v_yr_used
          FROM leave_requests lr
         WHERE lr.employee_id = p_employee_id AND lr.leave_type_code = p_leave_type_code
           AND lr.deleted_at IS NULL AND lr.status = 'approved'
           AND EXTRACT(YEAR FROM lr.start_date)::integer = v_year;
        v_granted := v_granted + v_yearly;
        v_used    := v_used + v_yr_used;
        v_avail   := v_avail + (v_yearly - v_yr_used);
        v_break := v_break || jsonb_build_object(
            'source', 'yearly',
            'grant_id', NULL, 'leave_year', v_year, 'grant_type', 'yearly_entitlement',
            'days', v_yearly, 'consumed', v_yr_used, 'carried_forward_out', 0,
            'remaining', v_yearly - v_yr_used,
            'expires_on', NULL, 'status', 'active',
            'service_months', v_svc -> 'service_months', 'full_days', v_svc -> 'full_days',
            'qualifying_months', v_svc -> 'qualifying_months', 'service_rule', v_svc -> 'rule');
    END IF;

    -- ── 还在等批的(LEAVE-BAL-1):只有【提交】扣它;审批不扣(Q10 Option A)──────────────
    -- 口径与已批同一个:同一人、同一假别、开始日在同一年,不论先后(Q9)。
    SELECT COALESCE(SUM(lr.days), 0) INTO v_pending
      FROM leave_requests lr
     WHERE lr.employee_id = p_employee_id AND lr.leave_type_code = p_leave_type_code
       AND lr.deleted_at IS NULL AND lr.status = 'pending'
       AND EXTRACT(YEAR FROM lr.start_date)::integer = v_year;

    RETURN jsonb_build_object(
        'employee_id', p_employee_id, 'leave_type_code', p_leave_type_code, 'as_of', p_as_of,
        'granted', v_granted, 'consumed', v_used, 'expired', v_expired,
        'accrued_this_year', v_accrued, 'consumed_from_accrual', v_acc_used,
        -- 【向下取到 0.5】—— 结转与消耗本就是 0.5 的整数倍,这里是防御性的一层
        'available', trim_scale(floor(v_avail * 2) / 2),
        'pending', trim_scale(v_pending),
        'bookable', trim_scale(floor(v_avail * 2) / 2 - v_pending),
        'balance_checked', v_checked,
        'breakdown', v_break);
END;
$function$
;

-- ── 5 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.assert_entry_not_bank_matched(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.assert_entry_not_bank_matched(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.payroll_payment_entry_kind(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_payment_entry_kind(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reverse_payroll_payment_internal(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_payroll_payment_internal(uuid, date, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.submit_payroll_payment_reversal_request(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_payroll_payment_reversal_request(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reverse_payroll_payment(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_payroll_payment(uuid, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.payroll_payment_entries(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payroll_payment_entries(uuid[]) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.leave_service_entitlement(text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.leave_service_entitlement(text, date, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.leave_balances(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.leave_balances(uuid, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.reverse_payroll_payment_internal(uuid, date, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.assert_entry_not_bank_matched(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payroll_payment_entry_kind(uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.leave_service_entitlement(text, date, date) FROM authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.payroll_requests_masked FROM anon, authenticated, PUBLIC;

-- ── 6 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.ppr1_pending_decider_check(p_after boolean DEFAULT true)
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
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim_items',
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

CREATE TEMP TABLE ppr1_pending_after ON COMMIT DROP AS
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
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_recon jsonb;
    k       text;
BEGIN
    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'PPR1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM ppr1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM ppr1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'PPR1_PROOF|an account or its roles changed';
    END IF;

    -- ② 在途单据一张不少、一张不多;既有的行逐字未变(payroll_requests 比去掉新列之后的,leave_types 比去掉四列与 updated_at 之后的);
    --   本事务写的变更记录只有 leave_types 那八行
    IF EXISTS ((SELECT b.k, b.id FROM ppr1_pending_before b EXCEPT SELECT a2.k, a2.id FROM ppr1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM ppr1_pending_after a2 EXCEPT SELECT b.k, b.id FROM ppr1_pending_before b)) THEN
        RAISE EXCEPTION 'PPR1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'target_entry_id')::text, '|' ORDER BY (to_jsonb(t) - 'target_entry_id')::text), '')) FROM payroll_requests t ) IS DISTINCT FROM (SELECT payroll_requests FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'updated_at' - 'qualifying_service_months' - 'service_rule' - 'service_steps' - 'prorate_minimum_days')::text, '|' ORDER BY (to_jsonb(t) - 'updated_at' - 'qualifying_service_months' - 'service_rule' - 'service_steps' - 'prorate_minimum_days')::text), '')) FROM leave_types t ) IS DISTINCT FROM (SELECT leave_types FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_periods t ) IS DISTINCT FROM (SELECT payroll_periods FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_lines t ) IS DISTINCT FROM (SELECT payroll_lines FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t ) IS DISTINCT FROM (SELECT payment_requests FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_transfers t ) IS DISTINCT FROM (SELECT bank_transfers FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM wht_remittances t ) IS DISTINCT FROM (SELECT wht_remittances FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_statements t ) IS DISTINCT FROM (SELECT bank_statements FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_statement_lines t ) IS DISTINCT FROM (SELECT bank_statement_lines FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_line_matches t ) IS DISTINCT FROM (SELECT bank_line_matches FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_requests t ) IS DISTINCT FROM (SELECT journal_requests FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM leave_requests t ) IS DISTINCT FROM (SELECT leave_requests FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM leave_grants t ) IS DISTINCT FROM (SELECT leave_grants FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) IS DISTINCT FROM (SELECT employees FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) IS DISTINCT FROM (SELECT accounts FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) IS DISTINCT FROM (SELECT permissions FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) IS DISTINCT FROM (SELECT role_permissions FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM account_settings t ) IS DISTINCT FROM (SELECT account_settings FROM ppr1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM ppr1_rows_before) THEN
        RAISE EXCEPTION 'PPR1_PROOF|a pre-existing row changed';
    END IF;
    SELECT count(*), COALESCE(string_agg(DISTINCT c.table_name, ','), '') INTO v_n, v_bad
      FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM ppr1_log_before), 0) AND c.txid = txid_current();
    IF v_n <> 8 OR v_bad <> 'leave_types' THEN
        RAISE EXCEPTION 'PPR1_PROOF|expected exactly the 8 leave_types change-log rows, got % on %', v_n, v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'PPR1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;
    IF (SELECT row(objects, buckets, policies) FROM ppr1_storage_before) IS DISTINCT FROM
       row((SELECT count(*) FROM storage.objects), (SELECT count(*) FROM storage.buckets), (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage')) THEN
        RAISE EXCEPTION 'PPR1_PROOF|storage changed';
    END IF;

    -- ③ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM ppr1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'PPR1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ④ 结构:新函数都在;四支内层 authenticated 调不到,五支外门调得到,anon 一支都调不到;线上三张工资付款分录的路由是 payroll_payment;
    --   leave_types 的值就是裁定
    IF to_regprocedure('public.assert_entry_not_bank_matched(uuid)') IS NULL OR to_regprocedure('public.payroll_payment_entry_kind(uuid)') IS NULL OR to_regprocedure('public.reverse_payroll_payment_internal(uuid, date, text)') IS NULL OR to_regprocedure('public.submit_payroll_payment_reversal_request(uuid, text)') IS NULL OR to_regprocedure('public.reverse_payroll_payment(uuid, date)') IS NULL OR to_regprocedure('public.payroll_payment_entries(uuid[])') IS NULL OR to_regprocedure('public.leave_service_entitlement(text, date, date)') IS NULL OR to_regprocedure('public.leave_balances(uuid, date)') IS NULL THEN
        RAISE EXCEPTION 'PPR1_PROOF|a new function is missing';
    END IF;
    IF has_function_privilege('authenticated', 'public.reverse_payroll_payment_internal(uuid, date, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.assert_entry_not_bank_matched(uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.payroll_payment_entry_kind(uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.leave_service_entitlement(text, date, date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'PPR1_PROOF|an internal function is executable by authenticated';
    END IF;
    IF NOT has_function_privilege('authenticated', 'public.submit_payroll_payment_reversal_request(uuid, text)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.reverse_payroll_payment(uuid, date)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.payroll_payment_entries(uuid[])', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.leave_balances(uuid, date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'PPR1_PROOF|a door is not executable by authenticated';
    END IF;
    IF has_function_privilege('anon', 'public.assert_entry_not_bank_matched(uuid)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.payroll_payment_entry_kind(uuid)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.reverse_payroll_payment_internal(uuid, date, text)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.submit_payroll_payment_reversal_request(uuid, text)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.reverse_payroll_payment(uuid, date)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.payroll_payment_entries(uuid[])', 'EXECUTE')
       OR has_function_privilege('anon', 'public.leave_service_entitlement(text, date, date)', 'EXECUTE')
       OR has_function_privilege('anon', 'public.leave_balances(uuid, date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'PPR1_PROOF|anon executes a new function';
    END IF;
    IF EXISTS (SELECT 1 FROM journal_entries je WHERE je.source_type = 'payroll' AND je.status = 'posted'
                AND payroll_payment_entry_kind(je.id) IS NOT NULL AND journal_entry_reversal_route(je.id) <> 'payroll_payment')
       OR EXISTS (SELECT 1 FROM payroll_periods pp WHERE pp.journal_entry_id IS NOT NULL
                   AND journal_entry_reversal_route(pp.journal_entry_id) NOT IN ('source_path', 'reversed')) THEN
        RAISE EXCEPTION 'PPR1_PROOF|a payroll payment entry does not route to payroll_payment, or a posting entry moved';
    END IF;
    SELECT string_agg(code || ':' || qualifying_service_months || ':' || service_rule || ':' || COALESCE(service_steps::text, '-')
                      || ':' || COALESCE(prorate_minimum_days::text, '-'), ' ' ORDER BY code) INTO v_bad
      FROM leave_types WHERE default_days_per_year IS NOT NULL;
    IF v_bad <> 'childcare:3:prorate_first_year:-:2 compassionate:0:full:-:- examination:0:full:-:- extended_childcare:3:prorate_first_year:-:- '
                || 'hospitalisation:3:steps:{"3": 15, "4": 30, "5": 45}:- infant_care:3:full:-:- marriage:0:full:-:- maternity:3:full:-:- '
                || 'paternity:3:full:-:- shared_parental:3:full:-:- sick:3:steps:{"3": 5, "4": 8, "5": 11}:-' THEN
        RAISE EXCEPTION 'PPR1_PROOF|leave_types service rules are not the ruling: %', v_bad;
    END IF;

    -- ⑤ 328 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 328 THEN
        RAISE EXCEPTION 'PPR1_PROOF|expected 328 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'PPR1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'PPR1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'PPR1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑥ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'PPR1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'PPR1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑦ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.ppr1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'PPR1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.ppr1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'PPR1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.ppr1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;

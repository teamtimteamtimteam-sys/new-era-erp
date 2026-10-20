-- db/migrations/2026-10-20-expense-multiline-1.sql
-- EXPENSE-MULTILINE-1 —— 费用单变成【表头 + 行】,报销单变成【表头 + 明细】。(v1.4.64;发布那一行在 docs/handbacks/EXPENSE-MULTILINE-1.md 的抬头。)
--   由 db/scripts/build_expense_multiline1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-20 的裁定:Step 0 Q1–Q16 · Step 0b Q1–Q10)
--   ① 新表 expense_lines:每一行自己的科目 · 税码 · 净额 · 税 · 备注;不可改、不可删;未注册时写不进税码(GST-2 那道闸随码搬来)。
--      表头 expenses 拿掉 account_code / tax_code / tax_rate_pct;四个合计(amount_ccy · amount_base · tax_ccy · tax_base)留在表头,
--      由 guard_expense_totals(延迟的约束触发器,两张表各一条)强制 = 各行之和、至少一行(Q10)。
--   ② record_expense_document:唯一的写入者,表头 + p_lines;一张分录、一笔应付;资本单恰好一行(Q1,EXPENSE_CAPITAL_SOLE_LINE);
--      代扣一张单一个性质与税率、按净额之和算(Q12);带代扣的单任何一行都不许带 GST(Q2)。record_expense 原签名是它的单行包装(Q11)。
--      冲销是整张单(Q4):镜像单带着原单的行。电费分摊与加工费结算各写一行。
--   ③ 新表 expense_claim_items:报销单的明细(日期 · 金额 · 说明 · 无收据理由;批准时财务逐笔给科目与税码,Step 0b Q1)。
--      表头 expense_claims 拿掉 account_code / tax_code / no_receipt_reason;spend_date = 最晚那一笔、amount_ccy = 明细之和,
--      由 guard_expense_claim_totals 强制。submit_expense_claim_items / decide_expense_claim_items 是新的两支;旧的两支是单笔包装(Q8)。
--      一张单一个币种(Q4);同一个日历月、外币同一天(Q5);驳回整张(Q3)。expense_claim_status 去掉搬走的三列、加 item_count。
--      搜索只读表头的用途(Q7):document_types 的 expense_claim 那一行去掉 no_receipt_reason。
--   ④ 既有的 10 张费用单与 4 张报销单【机械地】各转成一行 / 一笔(Q5 · Step 0b Q9:测试数据,全新重建时消失;
--      docs/known-wrong-until-cutover.md 记着)。分录、付款、资产、定金、附件一行不动 —— 它们指着的表头 id 没变。
--
-- 【不做什么】不碰审批开关、hook、任何账号与角色;不建任何单据;不改任何分录;require_calibrated_since 保持空;
--   按行资本化(停放)· 收据上传(CLAIM-RECEIPTS-1)· 加工费那扇 paid 侧门(只登记)都不在本刀。
--
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):读表头 account_code 的费用清单页与费用详情页、读 expense_claim_status 里
--   no_receipt_reason / account_code / tax_code 的 /finance/claims 与 /me 的报销那一块、GST 首页那一个按 expenses.tax_code 数的格子
--   —— 它们的查询会撞 42703(列不存在)而报错。录入都还走得通:费用表单调 record_expense(签名未变)、/me 提交调
--   submit_expense_claim、批准调 decide_expense_claim(都是包装,签名未变)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;每一张费用单恰好一行、
--   逐字等于它搬走之前的科目 / 净额 / 税;每一张报销单恰好一笔、逐字等于它的日期 / 金额 / 说明 / 理由 / 科目 / 税码;
--   拿掉搬走的列之后两张表头逐字未变;其余二十几张表逐字未变;本事务写进变更记录的只有两张新表(与 document_types 那一行);
--   清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;两张 COD 原样;327 张表;变更记录覆盖零缺口、豁免 9;
--   匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权;在途单据一张不少、每一张仍有一个决定人。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
CREATE TEMP TABLE em1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'EM1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.expense_lines') IS NOT NULL OR to_regclass('public.expense_claim_items') IS NOT NULL
       OR to_regprocedure('public.record_expense_document(date, text, jsonb, text, text, uuid, text, text, jsonb, uuid, uuid, text, numeric, text, uuid, boolean)') IS NOT NULL THEN
        RAISE EXCEPTION 'EM1_PRE|the line tables or the document writer already exist';
    END IF;
    IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expenses'
          AND column_name IN ('account_code', 'tax_code', 'tax_rate_pct')) <> 3
       OR (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expense_claims'
          AND column_name IN ('account_code', 'tax_code', 'no_receipt_reason')) <> 3 THEN
        RAISE EXCEPTION 'EM1_PRE|expected the single-line header columns';
    END IF;
    IF (SELECT count(*) FROM expenses) <> 10 OR (SELECT count(*) FROM expense_claims) <> 4 THEN
        RAISE EXCEPTION 'EM1_PRE|expected 10 expenses and 4 expense claims (Step 0 measurement)';
    END IF;
    IF NOT (SELECT gst_registered FROM finance_settings) AND EXISTS (SELECT 1 FROM expenses WHERE tax_code IS NOT NULL) THEN
        RAISE EXCEPTION 'EM1_PRE|GST is off while coded expenses exist —— the moved tax-code guard would refuse their lines';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '634c00f9-c3a9-4444-9eed-b624cb6a2a93' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'EM1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'EM1_PRE|expected 325 public tables';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'EM1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'EM1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'EM1_PRE|expected the two recorded COD byte strings';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00 —— 以 tim@(cfo)身份【读】,读完即清
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'EM1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO em1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE em1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE em1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE em1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE em1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'account_code' - 'tax_code' - 'tax_rate_pct')::text, '|' ORDER BY (to_jsonb(t) - 'account_code' - 'tax_code' - 'tax_rate_pct')::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'account_code' - 'tax_code' - 'no_receipt_reason')::text, '|' ORDER BY (to_jsonb(t) - 'account_code' - 'tax_code' - 'no_receipt_reason')::text), '')) FROM expense_claims t ) AS expense_claims,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t WHERE key <> 'expense_claim') AS document_types,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) AS accounts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t ) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t ) AS payment_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM prepayment_applications t ) AS prepayment_applications,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t ) AS fixed_assets,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_asset_cost_entries t ) AS fixed_asset_cost_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_asset_depreciation_anchors t ) AS fixed_asset_depreciation_anchors,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t ) AS equipment_maintenance,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM medical_claims t ) AS medical_claims,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_attachments t ) AS finance_attachments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_cost_entries t ) AS processing_cost_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM electricity_allocations t ) AS electricity_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t ) AS assay_disputes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM tax_codes t ) AS tax_codes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) AS suppliers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) AS employees;
-- 搬走之前的那几列,逐行记下 —— 转换之后每一行 / 每一笔都要逐字等于它
CREATE TEMP TABLE em1_expense_cols ON COMMIT DROP AS
SELECT id, account_code, amount_ccy, amount_base, tax_code, tax_rate_pct, tax_ccy, tax_base, created_at, created_by FROM expenses;
CREATE TEMP TABLE em1_claim_cols ON COMMIT DROP AS
SELECT id, spend_date, amount_ccy, description, no_receipt_reason, account_code, tax_code, created_at, created_by FROM expense_claims;

-- ── 1 · 两支合计守卫(镜像原样:db/tables/expenses.sql · db/tables/expense_claims.sql)──
CREATE OR REPLACE FUNCTION public.guard_expense_totals()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id uuid;
    v_h  record;
    v_s  record;
BEGIN
    IF TG_TABLE_NAME = 'expenses' THEN
        v_id := NEW.id;
    ELSE
        v_id := NEW.expense_id;
    END IF;
    SELECT e.code, e.amount_ccy, e.amount_base, e.tax_ccy, e.tax_base INTO v_h FROM expenses e WHERE e.id = v_id;
    IF NOT FOUND THEN
        RETURN NULL;   -- 外键已经保证行有表头;这里只为不在一个不存在的表头上编一句话
    END IF;
    SELECT count(*) AS n,
           COALESCE(sum(l.amount_ccy), 0) AS amount_ccy, COALESCE(sum(l.amount_base), 0) AS amount_base,
           COALESCE(sum(l.tax_ccy), 0) AS tax_ccy, COALESCE(sum(l.tax_base), 0) AS tax_base
      INTO v_s FROM expense_lines l WHERE l.expense_id = v_id;
    IF v_s.n = 0 THEN
        RAISE EXCEPTION 'EXPENSE_HAS_NO_LINES|%', v_h.code;
    END IF;
    IF v_h.amount_ccy IS DISTINCT FROM v_s.amount_ccy OR v_h.amount_base IS DISTINCT FROM v_s.amount_base
       OR v_h.tax_ccy IS DISTINCT FROM v_s.tax_ccy OR v_h.tax_base IS DISTINCT FROM v_s.tax_base THEN
        RAISE EXCEPTION 'EXPENSE_TOTALS_MISMATCH|%|header %/%/%/%|lines %/%/%/%', v_h.code,
            v_h.amount_ccy, v_h.amount_base, v_h.tax_ccy, v_h.tax_base,
            v_s.amount_ccy, v_s.amount_base, v_s.tax_ccy, v_s.tax_base;
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_expense_claim_totals()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id uuid;
    v_h  record;
    v_s  record;
BEGIN
    IF TG_TABLE_NAME = 'expense_claims' THEN
        v_id := NEW.id;
    ELSE
        v_id := NEW.claim_id;
    END IF;
    SELECT c.code, c.amount_ccy, c.spend_date INTO v_h FROM expense_claims c WHERE c.id = v_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT count(*) AS n, COALESCE(sum(i.amount_ccy), 0) AS amount_ccy, max(i.spend_date) AS spend_date
      INTO v_s FROM expense_claim_items i WHERE i.claim_id = v_id;
    IF v_s.n = 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_HAS_NO_ITEMS|%', v_h.code;
    END IF;
    IF v_h.amount_ccy IS DISTINCT FROM v_s.amount_ccy OR v_h.spend_date IS DISTINCT FROM v_s.spend_date THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_TOTALS_MISMATCH|%|header %/%|items %/%', v_h.code,
            v_h.amount_ccy, v_h.spend_date, v_s.amount_ccy, v_s.spend_date;
    END IF;
    RETURN NULL;
END;
$function$;

-- ── 2 · 两张新表(建表脚本原样:db/tables/expense_lines.sql · db/tables/expense_claim_items.sql)──
-- db/tables/expense_lines.sql
-- EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q1–Q16):费用单的【行】。表头在 expenses(日期 · 收款方 · 币种 · 备注 · 单据合计),
-- 每一行在这里:自己的费用科目 · 税码 · 不含税净额 · 税 · 备注。
--
-- 【一张单 = 一张分录 = 一笔应付】(Tim)每一行在分录里各有自己的借方腿(科目 + 税码)与税腿(可抵的借 1400、不可抵的借进
--   这一行自己的科目),贷 2000 也按行各记一条净额、一条 'GST on <单号>' —— 所以每一行在本位币上自己就平,分录不会因为
--   "合计先四舍五入"差出一分钱(post_journal_entry 逐行 round)。应付只有一笔:付款、定金冲抵、报销单读的都是表头。
-- 【税按行算】(Q16)每一行各自 round —— 与供应商按整张单算的税可能差一分钱,Tim 接受,不设改写栏。
-- 【混税码可以】(Q2)同一张单上可抵与不可抵的行可以并存;唯一的例外:要代扣预提税的单据【任何一行】都不许带 GST
--   (EXPENSE_WHT_WITH_GST,按单据判,与此前一样)。
-- 【资本支出单恰好一行】(Q1)科目 1500 的那一行只能是单据唯一的一行,与普通行混装按名拒(EXPENSE_CAPITAL_SOLE_LINE);
--   资产、采购单行与维修资本化的链接因此仍挂在表头。按行资本化是另一刀(docs/forward-queue.md,已停放)。
-- 【不可改、不可删】与表头同一条:更正走冲销(整张单,Q4)。冲销镜像单带着同样的行(科目 + 净额,不带税码,与镜像表头一致)。
-- 【读】持 module.finance.view(与表头同一条);【写】只经 record_expense_document 与那几支系统写入者(电费分摊 · 加工费结算 ·
--   冲销),表上那条 INSERT 策略与表头逐字同形 —— 直插一行进旧表头会在提交时被 guard_expense_totals 拒掉。

CREATE TABLE public.expense_lines (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    expense_id    uuid NOT NULL REFERENCES public.expenses (id),
    line_no       integer NOT NULL CHECK (line_no >= 1),
    account_code  text NOT NULL REFERENCES public.accounts (code),
    amount_ccy    numeric NOT NULL CHECK (amount_ccy > 0),   -- 这一行的【不含税净额】,单据币种
    amount_base   numeric NOT NULL,                          -- round(amount_ccy × 表头 fx_rate, 2)
    tax_code      text REFERENCES public.tax_codes (code),
    tax_rate_pct  numeric,
    tax_ccy       numeric NOT NULL DEFAULT 0,
    tax_base      numeric NOT NULL DEFAULT 0,
    notes         text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid DEFAULT auth.uid(),
    CONSTRAINT expense_lines_line_no_unique UNIQUE (expense_id, line_no),
    -- 【四列是一件事】原来表头上 expenses_tax_shape + expenses_tax_ccy_shape 两条说的,现在逐行说。
    CONSTRAINT expense_lines_tax_shape CHECK (
        (tax_code IS NULL     AND tax_rate_pct IS NULL     AND tax_ccy = 0  AND tax_base = 0)
     OR (tax_code IS NOT NULL AND tax_rate_pct IS NOT NULL AND tax_ccy >= 0 AND tax_base >= 0))
);

COMMENT ON TABLE public.expense_lines IS
    'EXPENSE-MULTILINE-1(Tim 2026-10-20):费用单的行 —— 每一行自己的科目、税码、不含税净额、税与备注。表头(expenses)的四个合计由 guard_expense_totals 强制等于各行之和;行不可改、不可删。资本支出单恰好一行(Q1)。';

CREATE INDEX expense_lines_account_code ON public.expense_lines (account_code);

-- 不可改、不可删(与 guard_expense_mutation 同一条:更正走冲销)
CREATE OR REPLACE FUNCTION public.guard_expense_line_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'EXPENSE_LINE_IMMUTABLE';
END;
$function$;

CREATE TRIGGER trg_expense_lines_immutable
    BEFORE UPDATE OR DELETE ON public.expense_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_line_mutation();

-- GST-2 那道闸,随税码从表头搬过来:未注册时写不进税码(与 invoice_lines / credit_note_lines 同一支函数)
CREATE TRIGGER trg_expense_lines_tax_code_registered
    BEFORE INSERT OR UPDATE OF tax_code ON public.expense_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_document_tax_code();

-- 表头合计 = 各行之和(guard_expense_totals 住在 db/tables/expenses.sql;两张表各挂一条,同一支函数)
CREATE CONSTRAINT TRIGGER trg_expense_lines_totals_match
    AFTER INSERT ON public.expense_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_totals();

ALTER TABLE public.expense_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "expense_lines select by permission"
    ON public.expense_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

CREATE POLICY "expense_lines insert by permission"
    ON public.expense_lines
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

REVOKE ALL ON public.expense_lines FROM anon;

-- db/tables/expense_claim_items.sql
-- EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q1–Q10):报销单的【明细】。表头在 expense_claims(报销人 · 币种 ·
-- 用途 · 状态与决定 · 合计);每一笔花销在这里:哪天 · 收据上的金额(含税,与此前一样)· 说明 · 没有收据时的理由 ——
-- 以及批准那一刻由财务给的科目与税码。批准时这张单生出【一张】费用单,每一笔明细是它的一行(行备注 = 明细说明)。
--
-- 【提报人陈述事实,审批人陈述会计】(CLAIM-1;Tim Step 0b Q1)科目与税码由财务在批准时【逐笔】给,什么都不预选;
--   提交时这两列必须是空的,只在 decide_expense_claim_items 那一步写一次(guard_expense_claim_item_mutation)。
-- 【日期】(Q5)一张单的明细落在【同一个日历月】里(一张费用单一个入账期间,EXPENSE_CLAIM_ITEMS_SPAN_MONTHS);
--   非本位币的单所有明细【同一天】(一张费用单一个汇率,EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE)。表头的 spend_date = 最晚那一笔。
-- 【币种】(Q4)一张单一个币种 —— 在表头,明细没有自己的币种列。
-- 【凭据】在 CLAIM-RECEIPTS-1 之前员工传不了收据(docs/known-issues.md § EXPENSE-CLAIM-NO-RECEIPT-UPLOAD),所以每一笔
--   要么那张单上有附件、要么它自己有一句无收据理由;批准时逐笔查(EXPENSE_CLAIM_NO_EVIDENCE|单号|第几笔)。
-- 【说明不遮】(Tim 2026-10-20:一般报销的说明不遮)明细说明与表头用途同一条。【搜索】只读表头的用途(Q7)。
-- 【读】与表头同一条:持 module.finance.view,或者这张单说的就是你。【写】只经属主权限函数(没有写策略)。

CREATE TABLE public.expense_claim_items (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id          uuid NOT NULL REFERENCES public.expense_claims (id),
    line_no           integer NOT NULL CHECK (line_no >= 1),
    spend_date        date NOT NULL,
    amount_ccy        numeric NOT NULL CHECK (amount_ccy > 0),   -- 收据上的金额(含税),表头币种
    description       text NOT NULL CHECK (btrim(description) <> ''),
    no_receipt_reason text,
    account_code      text REFERENCES public.accounts (code),    -- 批准时由财务给
    tax_code          text REFERENCES public.tax_codes (code),   -- 批准时由财务给(GST 关着时为空)
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    CONSTRAINT expense_claim_items_line_no_unique UNIQUE (claim_id, line_no)
);

COMMENT ON TABLE public.expense_claim_items IS
    'EXPENSE-MULTILINE-1(Tim 2026-10-20):报销单的明细 —— 日期、收据金额(含税)、说明、无收据理由;科目与税码由财务在批准时逐笔给(Step 0b Q1)。批准时整张单生出一张费用单,每笔明细一行。表头的金额与日期由 guard_expense_claim_totals 强制等于明细之和 / 最晚那一笔。';

-- 只许在批准那一步写一次科目与税码;别的列不可改,行不可删
CREATE OR REPLACE FUNCTION public.guard_expense_claim_item_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEM_IMMUTABLE';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.claim_id IS DISTINCT FROM OLD.claim_id
       OR NEW.line_no IS DISTINCT FROM OLD.line_no OR NEW.spend_date IS DISTINCT FROM OLD.spend_date
       OR NEW.amount_ccy IS DISTINCT FROM OLD.amount_ccy OR NEW.description IS DISTINCT FROM OLD.description
       OR NEW.no_receipt_reason IS DISTINCT FROM OLD.no_receipt_reason
       OR NEW.created_at IS DISTINCT FROM OLD.created_at OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR OLD.account_code IS NOT NULL OR OLD.tax_code IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEM_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_expense_claim_items_immutable
    BEFORE UPDATE OR DELETE ON public.expense_claim_items
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_item_mutation();

-- 表头的合计与日期 = 明细推出来的那一个(guard_expense_claim_totals 住在 db/tables/expense_claims.sql)
CREATE CONSTRAINT TRIGGER trg_expense_claim_items_totals_match
    AFTER INSERT ON public.expense_claim_items
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_totals();

ALTER TABLE public.expense_claim_items ENABLE ROW LEVEL SECURITY;

-- 与表头同一条:财务看得见全部,员工看得见自己那张单的明细
CREATE POLICY "expense_claim_items select by permission" ON public.expense_claim_items
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text)
        OR EXISTS (SELECT 1 FROM public.expense_claims c
                    WHERE c.id = expense_claim_items.claim_id AND c.employee_id = current_user_employee()));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限函数(submit_expense_claim_items · decide_expense_claim_items)。
REVOKE ALL ON public.expense_claim_items FROM anon;

-- 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.expense_lines
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.expense_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.expense_claim_items
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.expense_claim_items
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- 表头那一侧的两条合计触发器(镜像原样)
CREATE CONSTRAINT TRIGGER trg_expenses_totals_match
    AFTER INSERT ON public.expenses
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_totals();

CREATE CONSTRAINT TRIGGER trg_expense_claims_totals_match
    AFTER INSERT OR UPDATE OF amount_ccy, spend_date ON public.expense_claims
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_totals();

-- ── 3 · 既有的单据机械地各转成一行 / 一笔(Tim Q5 · Step 0b Q9:测试数据,不为它们多做任何事)──
--   行与明细的合计守卫在提交时逐张核对表头 = 行之和(这一步本身就被它证明)。
INSERT INTO public.expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base,
                                  tax_code, tax_rate_pct, tax_ccy, tax_base, notes, created_at, created_by)
SELECT e.id, 1, e.account_code, e.amount_ccy, e.amount_base, e.tax_code, e.tax_rate_pct, e.tax_ccy, e.tax_base,
       NULL, e.created_at, e.created_by
  FROM public.expenses e;
INSERT INTO public.expense_claim_items (claim_id, line_no, spend_date, amount_ccy, description, no_receipt_reason,
                                        account_code, tax_code, created_at, created_by)
SELECT c.id, 1, c.spend_date, c.amount_ccy, c.description, c.no_receipt_reason, c.account_code, c.tax_code,
       c.created_at, c.created_by
  FROM public.expense_claims c;

-- ── 4 · 表头拿掉搬走的列 ──────────────────────────────────────────────
DROP TRIGGER trg_expenses_tax_code_registered ON public.expenses;
ALTER TABLE public.expenses
    DROP CONSTRAINT expenses_tax_shape,
    DROP CONSTRAINT expenses_tax_ccy_shape,
    DROP COLUMN account_code,
    DROP COLUMN tax_code,
    DROP COLUMN tax_rate_pct;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_tax_shape CHECK (tax_base >= 0);
ALTER TABLE public.expenses ADD CONSTRAINT expenses_tax_ccy_shape CHECK (tax_ccy >= 0);
COMMENT ON COLUMN public.expenses.tax_base IS
    'GST-2:本单的进项税,以【本位币】计。**amount_ccy 始终是不含税的净额** —— 供应商账单上的总额 = 净额 + 税。可抵的(TX/ZP)那一笔税借 1400 进项税;不可抵的(BL)【有税但要不回来】,那笔税借进费用科目本身、且【不带税码】,好让 box5 报的仍然是采购净额。★ EXPENSE-MULTILINE-1:这是【各行 tax_base 之和】(guard_expense_totals 强制),每一行的码与率在 expense_lines。';

DROP VIEW public.expense_claim_status;
ALTER TABLE public.expense_claims
    DROP COLUMN account_code,
    DROP COLUMN tax_code,
    DROP COLUMN no_receipt_reason;
COMMENT ON TABLE public.expense_claims IS
    'CLAIM-1:员工费用报销的【请求】与【决定】。★【备用金是被否决的,不是被推迟的】★(Tim 2026-08-27):一切事后按实际花掉的钱报销 —— 不预支、不对余额、离职不用追回;六个人的规模够用,而且事后报销天然带一道审批,备用金则是在任何人看到收据之前就把钱交出去。【为什么另起一张表而不是扩 medical_claims】那一套是完整可用的五支函数流程,形状几乎一样,但它唯一属于医疗的东西是【年度限额】—— 那不是字段是规矩,来源在 HR 侧;而一般报销要科目码、币种、税码,医疗一个都没有。合成一张表就得让每个读者先问"这一行是哪一种",答案却在另一个模块。【链路的其余部分早就有了】公司欠员工 = expenses.employee_id(PAYEE-1a,表上 CHECK 保证未付时恰好一个往来对象);看得见 = ap_open_items 带员工名(fixture 90 守着,它的原话是"消失比空白更坏");付得掉 = record_payment 出款侧显式允许 employee。所以本刀建的只是前面两步。【一笔报销一笔费用】claim → expense 一对一,应付因此追得回是谁提的。~~多行的出差报三笔~~ ★ EXPENSE-MULTILINE-1(Tim 2026-10-20):一张报销单可以有多笔明细(expense_claim_items),批准时生出【一张】费用单、每笔明细一行;仍然是一张报销单对一张费用单。';

-- ── 5 · 表头的不可改守卫(镜像原样:少了 account_code 那一句)──
CREATE OR REPLACE FUNCTION public.guard_expense_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NEW.id                  IS DISTINCT FROM OLD.id
       OR NEW.code                IS DISTINCT FROM OLD.code
       OR NEW.expense_date        IS DISTINCT FROM OLD.expense_date
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base          IS DISTINCT FROM OLD.amount_base
       OR NEW.payment_status      IS DISTINCT FROM OLD.payment_status
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       -- PAYEE-1a fu1:往来对象的另一半,补进这份清单是为了【让清单完整】。
       -- 注意:即使少了这一行,下面那句"只放行 过账→冲销"的兜底也会拒掉
       -- 任何别的 UPDATE(实测过)—— 所以这不是在补洞,是在让这份
       -- 声称完整的枚举名副其实。两道闸各自独立,兜底放宽时清单就是唯一那道。
       OR NEW.employee_id         IS DISTINCT FROM OLD.employee_id
       OR NEW.payee_name          IS DISTINCT FROM OLD.payee_name
       OR NEW.notes               IS DISTINCT FROM OLD.notes
       OR NEW.journal_entry_id    IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR NEW.created_by          IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by_expense IS NULL AND NEW.reversed_by_expense IS NOT NULL) THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    -- ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q33 · Q34,Tim):冲销的理由、时刻与人只在 posted → reversed 这一步写,
    --   理由不许是空的 —— 这一步之外它们改不了(上面那句已经拒掉了任何别的 UPDATE),而这一步里少了理由按名拒。
    --   表上的 expenses_reversal_shape 是第二道:posted 的行三列都空,reversed 的行理由与时刻都在。
    IF OLD.reversal_reason IS NOT NULL OR OLD.reversed_at IS NOT NULL OR OLD.reversed_by IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NEW.reversal_reason IS NULL OR btrim(NEW.reversal_reason) = '' OR NEW.reversed_at IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 6 · 新函数(镜像原样)──

CREATE OR REPLACE FUNCTION public.record_expense_document(p_expense_date date, p_currency text, p_lines jsonb, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text, p_maintenance_id uuid DEFAULT NULL::uuid, p_amount_includes_tax boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- ════════════════════════════════════════════════════════════════════════════
-- EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q1–Q16):费用单的【唯一】写入者 —— 表头 + 行。
--   p_lines = [{account_code, amount, tax_code?, notes?}, ...],至少一行(EXPENSE_LINES_REQUIRED),没有上限(Q7)。
--   每一行:自己的科目、税码(供应商默认 + 本行改写,按费用日解析税率)、净额、税(按行 round,Q16)、备注。
--   单据一级:日期 · 币种与汇率(一张单一个)· 收款方 · 预提税(一张单一个性质与税率,按各行净额之和算,Q12)·
--   编号 · 【一张】分录 · 【一笔】应付。表头的四个合计 = 各行之和(guard_expense_totals 在提交时强制,Q10)。
--   资本支出(科目 1500 + p_asset)只能是单据唯一的一行,不与普通行混(Q1,EXPENSE_CAPITAL_SOLE_LINE);
--   采购单行与维修资本化同理 —— 它们只活在资本单上。
-- record_expense 保留原签名,是这一支的【单行包装】(Q11):它的三个库内调用者、两个应用调用者与 140 处 fixture 调用一个字不改。
-- 下面那些段落(采购单行 · 预提税 · 资本化)是从 record_expense 原样搬过来的 —— 一份实现,不是第二份。
-- ════════════════════════════════════════════════════════════════════════════
DECLARE
    v_user       uuid := auth.uid();
    v_account    record;
    v_fx         numeric;
    v_bank       text;
    v_expense_id uuid := gen_random_uuid();
    v_year       integer;
    v_seq        integer;
    v_code       text;
    v_je         jsonb;
    v_asset_id   uuid;
    v_append_id  uuid;   -- FA-1a:追加模式的目标资产
    v_target     fixed_assets%ROWTYPE;
    -- ── CAPEX-1 ──────────────────────────────────────────────────────────
    v_maint      equipment_maintenance%ROWTYPE;  -- 那条【说了这是资本化】的维修记录
    v_anchor_from date;    -- 新锚点从哪个月起
    v_prev       record;   -- 现行锚点(可能没有 —— 那就是首次资本化)
    v_pre_target numeric;  -- 锚点之前那一段的累计目标(存下来的常数)
    v_prev_start date;     -- 现行那一段是从哪天起算的
    v_prev_rem   numeric;  -- 现行那一段还剩几个月
    v_rem        numeric;  -- 新锚点剩几个月
    v_asset_code text;
    v_life       integer;
    v_residual   numeric;
    v_in_service date;
    v_poline     record;   -- EQP-1b-ii:这笔支出付的那一条采购单行
    v_poline_po  record;   -- 那一行所属的采购单
    v_billed     text;     -- 该行上已有的、【未冲销的】支出编号
    -- ── GST-2 ────────────────────────────────────────────────────────────
    v_sup_default text;
    v_jlines     jsonb;
    v_cost_ccy   numeric;   -- 资本化口径:净额 + 【不可抵】的那笔税
    v_cost_base  numeric;
    -- ── WHT-1 ────────────────────────────────────────────────────────────
    v_residence     text;      -- 收款人【此刻】的税务居民身份,抄一份冻进这张单
    v_wht_nature    text;      -- 这笔款在预提税上是什么('none' = 显式的否)
    v_wht_rate      numeric;   -- 实际适用税率(条约减免后)
    v_wht_statutory numeric;   -- 当天的法定税率 —— 减免的上限
    v_wht_ccy       numeric := 0;  -- 全额结清时会代扣多少(单据币种,预期值)
    v_wht_ref       text;
    -- ── EXPENSE-MULTILINE-1:行 ───────────────────────────────────────────
    v_n          integer;          -- 行数
    v_i          integer;
    v_line       jsonb;
    v_acct       text;
    v_first_account text;          -- 第一行的科目(资本单 / 采购单行那几条错误消息说的就是它)
    v_amt        numeric;          -- 这一行传进来的金额(含税与否由 p_amount_includes_tax 说)
    v_l_net      numeric;
    v_l_base     numeric;
    v_l_code     text;
    v_l_rate     numeric;
    v_l_tax      numeric;
    v_l_tax_base numeric;
    v_l_claim    boolean;
    v_calc       jsonb := '[]'::jsonb;   -- 每一行算好的那几个数,过账与落库都读它 —— 一份算术
    v_sum_net    numeric := 0;
    v_sum_base   numeric := 0;
    v_sum_tax    numeric := 0;
    v_sum_tax_base numeric := 0;
    v_first_taxed_code text;       -- 第一条带税的行的税码(EXPENSE_WHT_WITH_GST 消息里说它)
    v_c          jsonb;
    v_suffix     text;             -- 多行单据的错误码尾巴 '|<行号>';单行为空,与此前逐字相同
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'JE_LINE_INVALID|entry_date';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):一张费用单记的是【已经发生】的供应,日期晚于今天按名拒。
    IF p_expense_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_expense_date, CURRENT_DATE;
    END IF;

    -- 1b. 行:至少一行,每一行是一个对象。多行单据的错误码带一个 '|<行号>' 尾巴,单行与此前逐字相同。
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'EXPENSE_LINES_REQUIRED';
    END IF;
    v_n := jsonb_array_length(p_lines);
    -- 资本单恰好一行(Q1):资本科目、资产、采购单行、维修资本化,任何一样出现在多行单据上都按名拒
    IF v_n > 1 AND (p_asset IS NOT NULL OR p_purchase_order_line IS NOT NULL OR p_maintenance_id IS NOT NULL
                    OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) x WHERE x->>'account_code' = '1500')) THEN
        RAISE EXCEPTION 'EXPENSE_CAPITAL_SOLE_LINE|%', v_n
          USING HINT = '资本支出单只能有一行,不与普通费用行混在一张单上 —— 把资本那一笔单独记一张';
    END IF;
    FOR v_i IN 1 .. v_n LOOP
        v_line := p_lines -> (v_i - 1);
        v_suffix := CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        IF jsonb_typeof(v_line) <> 'object' THEN
            RAISE EXCEPTION 'EXPENSE_LINE_INVALID|%', v_i;
        END IF;
        v_acct := NULLIF(btrim(COALESCE(v_line->>'account_code', '')), '');
        IF v_i = 1 THEN v_first_account := v_acct; END IF;
        -- 1. 科目:必须存在、启用,且是 expense 类型(只有 6xxx 是合法开支落点)
        SELECT code, is_active, account_type INTO v_account
        FROM accounts WHERE code = v_acct;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_FOUND|%', COALESCE(v_acct, '?') || v_suffix;
        END IF;
        IF NOT v_account.is_active THEN
            RAISE EXCEPTION 'ACCOUNT_INACTIVE|%', v_account.code || v_suffix;
        END IF;
        -- FIN-22:资本性支出 —— 科目 1500 与 p_asset【互相要求】。
        --   * 1500 而无 p_asset:这条路上不许出现没有台账行的固定资产借方;
        --   * p_asset 而非 1500:资本标记只有一个落点,别的科目不接受;
        --   * 其余科目照旧只认 expense 类型("只有 6xxx 是合法开支落点"的原规矩)。
        IF v_acct = '1500' THEN
            IF p_asset IS NULL THEN
                RAISE EXCEPTION 'CAPITAL_REQUIRES_ASSET|1500';
            END IF;
        ELSIF p_asset IS NOT NULL THEN
            RAISE EXCEPTION 'ASSET_REQUIRES_CAPITAL_ACCOUNT|%', v_account.code;
        ELSIF v_account.account_type <> 'expense' THEN
            RAISE EXCEPTION 'ACCOUNT_NOT_EXPENSE|%', v_account.code || v_suffix;
        END IF;
    END LOOP;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-ii:这笔支出付的是【哪一条采购单行】。
    -- 整块只在 p_purchase_order_line 非空时生效 —— 绝大多数支出根本没有采购单
    -- (D1 那个可空就是为它们留的);而运保关税、安装、调试按 D5 挂在【资产】上
    -- 走追加模式,【不带】采购单行。列注释把这两句话写在了数据库里。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_purchase_order_line IS NOT NULL THEN
        SELECT l.id, l.line_no, l.asset_id, l.purchase_order_id
        INTO v_poline
        FROM purchase_order_lines l
        WHERE l.id = p_purchase_order_line;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_LINE_NOT_FOUND|%', p_purchase_order_line;
        END IF;

        -- ── D2:与 apply_prepayment 同形的三条单据守卫 ────────────────────────
        -- 【"存在"= 没有被软删】apply_prepayment 的那句 WHERE 也带着 deleted_at,
        -- 照抄它是刻意的:少了这一句,一张已被软删的采购单照样收得下账单。
        SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status
        INTO v_poline_po
        FROM purchase_orders po
        WHERE po.id = v_poline.purchase_order_id AND po.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', v_poline.purchase_order_id;
        END IF;
        IF v_poline_po.status = 'cancelled' THEN
            RAISE EXCEPTION 'PO_CANCELLED|%', v_poline_po.code;
        END IF;
        IF v_poline_po.approval_status <> 'approved' THEN
            RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_poline_po.code, v_poline_po.approval_status;
        END IF;

        -- ── D3 上半:这条链接只在【设备行】上成立 ────────────────────────────
        -- 材料行经【收货】计价形成应付(reprice_inbound_batch),而收货量就是
        -- 它的计费上限。让费用单也挂得上去,等于给材料开【第二条计费路】,
        -- 而没有任何东西把这两条对得起来。同一条规矩也在表上(见下面那个触发器)。
        IF v_poline.asset_id IS NULL THEN
            RAISE EXCEPTION 'PO_LINE_NOT_EQUIPMENT|%', v_poline.line_no
              USING HINT = '材料行经收货计价形成应付,不经费用单';
        END IF;

        -- ── D3 下半:支出的资产必须【就是】行上那一台 ────────────────────────
        -- 拆成三种情形分别点名,因为它们的【修法互不相同】。合成一句"资产对不上"
        -- 会把两种根本不是"对不上"的情形也说成对不上 —— 尤其是新建那一支:
        -- 那里的资产是这一刻才生出来的,报一个"你填的 id 与行上的不符"
        -- 会打发人去核对一个一毫秒之前还不存在的 id。
        IF p_asset IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_NOT_CAPITAL|%|%', v_poline.line_no, v_first_account
              USING HINT = '挂在设备行上的支出必须是资本支出:科目 1500 + p_asset';
        END IF;
        IF (p_asset->>'asset_id') IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CREATES_ASSET|%', v_poline.line_no
              USING HINT = '设备行引用的资产卡【已经存在】(行不创建资产),这笔支出要以追加模式挂上去:p_asset.asset_id';
        END IF;
        IF (p_asset->>'asset_id')::uuid <> v_poline.asset_id THEN
            RAISE EXCEPTION 'EXPENSE_ASSET_MISMATCH|%|%', p_asset->>'asset_id', v_poline.asset_id
              USING HINT = 'B 机器的发票不能记到 A 机器的订单行上';
        END IF;

        -- ── D2 第四条:供应商一致 —— 但先问【有没有供应商】────────────────────
        -- 【这条规矩的主体可以缺席】expenses_counterparty_shape 只对 unpaid 强制
        -- 往来对象;paid 的费用单 supplier_id 合法地为空(线上那 2 笔就是)。
        -- 于是"供应商一致"若直接写成比较,对一半的单据是拿 NULL 去比 ——
        -- 那不是"不一致",是"没人说过"。两件事两个名字。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_SUPPLIER_NOT_STATED|%', v_poline_po.code
              USING HINT = '挂在采购单行上的支出必须说出开这张票的供应商';
        END IF;
        IF p_supplier_id <> v_poline_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_poline_po.code, p_supplier_id;
        END IF;

        -- ── D4:覆盖推导 —— 一条设备行只报销一次 ─────────────────────────────
        -- 【必须排除已冲销的】一笔冲销掉的支出【没有发生过】,它的行因此重新
        -- 可计费。判据只有一句:status = 'posted'。它站得住,是因为
        -- guard_expense_mutation 只放行 posted→reversed 且同时首挂
        -- reversed_by_expense,并且拒绝一切 DELETE —— 两列永远同步,
        -- 所以 status='reversed' 与 reversed_by_expense IS NOT NULL 是同一件事。
        -- 【这段话原本说"冲销了再记一笔"会把成本记成 170,000 —— EQP-1b-iii 之后
        --   它不再成立,所以就地退休,而不是留在这里骗下一个读它的人。】
        -- 当时(EQP-1b-ii)的实测是:冲销一笔追加模式的资本支出【允许】、分录冲掉、
        -- 而 cost_base 与成本明细原样不动,于是"冲销再记"= 100,000 的机器记成 170,000。
        -- EQP-1b-iii 修好了那一条:冲销现在会把成本退回去,并当场核对
        -- 表头 = 未冲销明细之和。所以【未投用】的机器,"冲销那笔支出再记一笔"
        -- 现在是一条安全的路,消息里也就照直说了。
        -- 【但它只在未投用时安全】资产一旦投用,冲销按名拒
        -- (ASSET_IN_SERVICE_COST_LOCKED),而向下修正一台已投用资产的成本
        -- 今天【没有任何路】—— 记在 docs/known-issues.md,带返回条件。
        -- 消息因此仍然把【改订单】放在前面:发票与估价对不上时,那才是要改的东西。
        -- 【第二层是索引】uq_expenses_live_po_line,谓词与这里逐字相同。
        -- 这里负责【可读】(带上占着这条行的那张单的编号),索引负责【正确】
        -- (并发下两笔同时通过本判据时,只有一笔落得下去)—— invoice_lines 的原话。
        SELECT e.code INTO v_billed
        FROM expenses e
        WHERE e.purchase_order_line_id = p_purchase_order_line
          AND e.status = 'posted'
        LIMIT 1;
        IF v_billed IS NOT NULL THEN
            RAISE EXCEPTION 'PO_LINE_ALREADY_EXPENSED|%|%', v_poline.line_no, v_billed
              USING HINT = '一条设备行只报销一次。若是【订单上的估价】与发票对不上,要改的是订单(改行,不是删行),不是再记一笔';
        END IF;
    END IF;


    -- 2. 金额/币种/汇率(FIN-0:SGD 本位免换算,外币按费用日牌价估值)—— 金额逐行
    FOR v_i IN 1 .. v_n LOOP
        v_amt := NULLIF(p_lines -> (v_i - 1) ->> 'amount', '')::numeric;
        IF v_amt IS NULL OR v_amt <= 0 THEN
            RAISE EXCEPTION 'AMOUNT_INVALID%', CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        END IF;
    END LOOP;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【费用日】的行方卖出价(tt_sell)估值 ——
    -- 应付与开销是我们将来要【向银行买】的外币。当日无牌价即拒(FX_RATE_MISSING)。
    -- 一张单一个汇率:各行共用表头的币种与日期。
    v_fx := fx_rate_for(p_currency, p_expense_date, 'tt_sell');

    -- 3. 支付状态
    IF p_payment_status IS NULL OR p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    -- ★★ PAY-REQ-1(Tim 的 Q2(c),2026-09-23):一张费用单【不许生下来就是已付】。
    --   费用一律挂账(unpaid),钱经付款申请 → CFO 批准 → 付款离开。
    --   (加工费结算 relieve_processing_accruals 仍可直接写 paid —— 那扇侧门登记在 docs/known-issues.md,
    --    EXPENSE-MULTILINE-1 只登记不修,Tim Q14。)
    IF p_payment_status = 'paid' THEN
        RAISE EXCEPTION 'EXPENSE_PAID_AT_CREATION_REFUSED'
          USING HINT = '费用先挂账(未付),再提付款申请、经 CFO 批准后付款(PAY-REQ-1)';
    END IF;
    -- unpaid:往来对象【二选一】—— 供应商 或 员工,恰好一个(PAYEE-1a)。银行科目必须为空。
    IF num_nonnulls(p_supplier_id, p_employee_id) = 0 THEN
        RAISE EXCEPTION 'COUNTERPARTY_REQUIRED_FOR_UNPAID';
    END IF;
    IF num_nonnulls(p_supplier_id, p_employee_id) > 1 THEN
        RAISE EXCEPTION 'COUNTERPARTY_AMBIGUOUS';
    END IF;
    IF p_supplier_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
    END IF;
    IF p_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM employees WHERE id = p_employee_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_employee_id;
    END IF;
    v_bank := NULL;

    -- 4. 净额与税,逐行。**amount_ccy 始终是【不含税净额】**。
    --    CLAIM-GST-1:p_amount_includes_tax = true(报销单与医疗申报)时,每一行传进来的是【收据上的总额】,
    --    税从里面拆出来(tax_included_in),净额 = 总额 − 税;false(费用表单、供应商账单)时传进来的就是净额。
    --    4b. GST-2:进项税码 —— 【供应商默认 + 本行改写】,税率按【费用日】解析(进项侧的税点就是供应商税务发票那一天)。
    --    ★ EXPENSE-MULTILINE-1(Tim Q2 · Q16):每一行自己的税码,可抵与不可抵可以并存;税逐行 round。
    IF gst_registered() THEN
        SELECT default_tax_code INTO v_sup_default FROM suppliers WHERE id = p_supplier_id;
    END IF;
    FOR v_i IN 1 .. v_n LOOP
        v_line   := p_lines -> (v_i - 1);
        v_amt    := (v_line->>'amount')::numeric;
        v_l_net  := v_amt;
        v_l_code := NULL; v_l_rate := 0; v_l_tax := 0; v_l_claim := false;
        IF gst_registered() THEN
            -- 【没有供应商的单据必须自己带码】它没有可以继承默认的对象 —— 要么本行指定,要么按名拒。不猜。
            v_l_code := resolve_tax_code(v_line->>'tax_code', v_sup_default, 'input', 'supplier');
            v_l_rate := tax_rate_for(v_l_code, p_expense_date);
            IF p_amount_includes_tax THEN
                v_l_tax := tax_included_in(v_amt, v_l_rate);
                v_l_net := v_amt - v_l_tax;
            ELSE
                v_l_tax := tax_amount_for(v_amt, v_l_rate);
            END IF;
            SELECT is_claimable INTO v_l_claim FROM tax_codes WHERE code = v_l_code;
        ELSE
            -- 【未注册:与建 GST 之前一模一样】传了码要按名拒,不能悄悄忽略。
            IF NULLIF(btrim(COALESCE(v_line->>'tax_code', '')), '') IS NOT NULL THEN
                RAISE EXCEPTION 'GST_NOT_REGISTERED|%', v_line->>'tax_code';
            END IF;
        END IF;
        v_l_base     := round(v_l_net * v_fx, 2);
        v_l_tax_base := round(v_l_tax * v_fx, 2);
        IF v_l_tax > 0 AND v_first_taxed_code IS NULL THEN v_first_taxed_code := v_l_code; END IF;
        v_calc := v_calc || jsonb_build_object(
            'line_no', v_i, 'account_code', btrim(v_line->>'account_code'),
            'net', v_l_net, 'net_base', v_l_base,
            'tax_code', v_l_code, 'tax_rate', CASE WHEN v_l_code IS NULL THEN NULL ELSE v_l_rate END,
            'tax', v_l_tax, 'tax_base', v_l_tax_base, 'claimable', COALESCE(v_l_claim, false),
            'notes', NULLIF(btrim(COALESCE(v_line->>'notes', '')), ''));
        v_sum_net      := v_sum_net + v_l_net;
        v_sum_base     := v_sum_base + v_l_base;
        v_sum_tax      := v_sum_tax + v_l_tax;
        v_sum_tax_base := v_sum_tax_base + v_l_tax_base;
    END LOOP;

    -- ════════════════════════════════════════════════════════════════════════
    -- 4c. WHT-1:预提税 —— **这张单要不要替收款人代扣,以及扣多少**。
    --
    -- ★【这【不是】GST 的第二个实例,两者在这张单上做的是相反的事】★
    --   进项税是【加】在供应商账单上、公司还能要回来的钱;
    --   预提税是【从】要付给供应商的钱里【扣下来】、替他交给 IRAS 的钱。
    --   所以这一段不碰分录:记这张费用单的时候什么都没扣 —— 债是全额的。
    --   代扣发生在【付款】那一刻(record_payment),因为法定义务是就
    --   "你实际付出去的那部分"代扣。这里只把【裁定】冻下来。
    --
    -- 【裁定的三个部件,以及它们各自的来路】
    --   ① 居民身份 —— 从 suppliers.tax_residence 抄一份冻住(见列注释);
    --   ② 性质     —— 由记账人显式回答,'none' 是一个合法且显式的"否";
    --   ③ 税率     —— wht_rate_for(性质, 费用日),条约减免时由本单覆盖并出示凭据。
    -- ════════════════════════════════════════════════════════════════════════
    v_residence  := NULL;
    v_wht_nature := NULLIF(btrim(COALESCE(p_wht_nature, '')), '');
    v_wht_ref    := NULLIF(btrim(COALESCE(p_wht_treaty_ref, '')), '');
    IF p_supplier_id IS NOT NULL THEN
        SELECT tax_residence INTO v_residence FROM suppliers WHERE id = p_supplier_id;
    END IF;

    IF v_wht_nature IS NOT NULL THEN
        -- ── 有人断言这张单要做代扣裁定 ──────────────────────────────────
        -- 【收款人必须是供应商】员工与"只有名字的收款人"都到不了这里:
        -- employees 没有税务居民身份这一列,而 payee_name 是一段自由文本 ——
        -- 对一段文本做税务裁定是没有主语的。两者都是【具名缺席】,记在
        -- docs/known-issues.md,不是靠这里悄悄放过。
        IF p_supplier_id IS NULL THEN
            RAISE EXCEPTION 'WHT_PAYEE_NOT_A_SUPPLIER|%', v_wht_nature
              USING HINT = '预提税裁定只能落在一个在册供应商上 —— 员工报销与只有名字的收款人不在本刀范围内';
        END IF;
        IF v_residence IS NULL THEN
            RAISE EXCEPTION 'WHT_RESIDENCE_NOT_STATED|%', p_supplier_id
              USING HINT = '这家供应商还没有申报税务居民身份 —— 先在供应商档案上填,再记这张单';
        END IF;
        IF v_residence <> 'non_resident' THEN
            -- 居民收款人不代扣。悄悄扣 0 会在账上留下一条"想过了"的假痕迹。
            RAISE EXCEPTION 'WHT_PAYEE_IS_RESIDENT|%|%', p_supplier_id, v_wht_nature
              USING HINT = '这家供应商申报的是新加坡税务居民 —— 付给他的款不代扣';
        END IF;
        -- ★【A2:'paid' 那一支按名拒,并且【说出该怎么走】】★
        --   record_expense 的 p_payment_status 默认就是 'paid',而那一支
        --   借 6xxx / 贷银行 一步到位,不产生应付、不经过 record_payment ——
        --   也就是不经过唯一知道怎么劈账的那段代码。让它自己也会劈,
        --   就是把同一份算术写第二遍(AGENTS.md 的预览规则,已犯四次)。
        --   【一条不指路的拒绝,在默认路径上就是一条会被绕开的拒绝】——
        --   所以 HINT 说的是走法,不是"不行"。
        --   ★【判据是【真的要扣钱吗】,不是【回答了这个问题吗】★
        --   fu2 修正:原实现把这道拒绝放在解析税率【之前】,谓词只看
        --   "有没有给性质"。于是对一个非居民收款人当场付清一笔【不适用代扣】的
        --   款(性质 = 'none',税率 0),它也拒 —— 而那一支非居民收款人的
        --   paid 费用单因此【一条路都没有】:不回答被 WHT_NATURE_REQUIRED 拒,
        --   回答"不适用"被这一条拒。**一个两边都堵死的问题,不是一道闸,是一堵墙。**
        --   所以税率先解析,再按【税率 > 0】判 —— 没有钱要被扣下来的时候,
        --   paid 那一支没有任何东西需要劈,也就没有理由拦它。
        --   (界面那一侧本来就写对了:`whtNature !== 'none' && paid` 才提示。
        --    两边不一致时先问哪一边错了 —— 这一次错的是服务端。)
        v_wht_statutory := wht_rate_for(v_wht_nature, p_expense_date);
        IF p_wht_rate_pct IS NULL THEN
            -- 没有主张条约减免:按法定税率。
            IF v_wht_ref IS NOT NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_WITHOUT_RATE|%', v_wht_ref
                  USING HINT = '给了居民证明书编号却没有给协定税率 —— 两者要么都给,要么都不给';
            END IF;
            v_wht_rate := v_wht_statutory;
        ELSE
            IF p_wht_rate_pct < 0 THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_INVALID|%', p_wht_rate_pct;
            END IF;
            -- 【永远不许高于法定】协定只会调低,不会调高。高于法定的"减免"
            -- 是一个打错的数字,而它会算得出来。
            IF p_wht_rate_pct > v_wht_statutory THEN
                RAISE EXCEPTION 'WHT_TREATY_RATE_ABOVE_STATUTORY|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory;
            END IF;
            -- 【低于法定必须出示凭据】没有居民证明书,IRAS 按法定税率征,
            -- 协定写什么都不作数 —— 所以少扣的那一部分是公司自己要补的钱。
            IF p_wht_rate_pct < v_wht_statutory AND v_wht_ref IS NULL THEN
                RAISE EXCEPTION 'WHT_TREATY_REF_REQUIRED|%|%|%',
                    v_wht_nature, p_wht_rate_pct, v_wht_statutory
                  USING HINT = '低于法定税率要凭居民证明书(Certificate of Residence)—— 填它的编号';
            END IF;
            v_wht_rate := p_wht_rate_pct;
        END IF;
        -- ★【A2:'paid' 那一支按名拒,并且【说出该怎么走】】★
        --   record_expense 的 p_payment_status 默认就是 'paid',而那一支
        --   借 6xxx / 贷银行 一步到位,不产生应付、不经过 record_payment ——
        --   也就是不经过唯一知道怎么劈账的那段代码。让它自己也会劈,
        --   就是把同一份算术写第二遍(AGENTS.md 的预览规则,已犯四次)。
        --   【一条不指路的拒绝,在默认路径上就是一条会被绕开的拒绝】——
        --   所以 HINT 说的是走法,不是"不行"。
        --   【谓词是税率 > 0】见上面 fu2 那段:不扣钱就没有要劈的东西。
        IF p_payment_status = 'paid' AND v_wht_rate > 0 THEN
            RAISE EXCEPTION 'WHT_ON_PAID_EXPENSE_UNSUPPORTED|%', v_wht_nature
              USING HINT = '要代扣的费用请先记成【未付】(挂应付),再用付款功能付掉 —— 代扣在付款那一步发生,那里只有一份劈账的实现';
        END IF;

        -- 【预期值:全额结清时会扣多少】真正的代扣按实付部分算,见 record_payment。
        -- ★ EXPENSE-MULTILINE-1(Tim Q12):一张单一个代扣性质与税率,金额按【各行净额之和】算。
        v_wht_ccy := round(v_sum_net * v_wht_rate / 100.0, 2);
    ELSE
        -- ── 没有给性质 ──────────────────────────────────────────────────
        IF p_wht_rate_pct IS NOT NULL OR v_wht_ref IS NOT NULL THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|rate_without_nature'
              USING HINT = '给了协定税率或证明书编号,却没有说这笔款是什么性质';
        END IF;
        -- ★【承重的那一条】★ 收款人【申报过】是非居民,就必须回答这个问题。
        --   答"不适用"用 'none' —— 它是一个显式的否,不是一个空白。
        --   身份为 NULL 时【不问】:那是一个量过成本的取舍,理由整段写在
        --   db/tables/suppliers.sql 的 tax_residence 列注释里,不在这里复述。
        IF v_residence = 'non_resident' THEN
            RAISE EXCEPTION 'WHT_NATURE_REQUIRED|%', p_supplier_id
              USING HINT = '收款人是非居民 —— 说明这笔款的预提税性质;确实不适用就选「不适用代扣」(none),不要留空';
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- AP-RECON-1(Tim AP-RECON-1 Q2):【同一张单既要代扣又带进项税 —— 按名拒】
    --   应付额现在是 净额 + 税(amount_ccy + tax_ccy),而代扣按【实付的核销额】× 税率算
    --   (record_payment)。两者同在一张单上,代扣就会把 GST 也扣进去,Σ 代扣超过这里冻下的
    --   wht_amount_ccy(fixture 142 D 臂钉的那个等式)。
    --   而这个组合在现实里本不该出现:要代扣的是【非居民】收款人,非居民供应商不收新加坡 GST
    --   (进口服务走反向征收,不是账单上的税)。线上 0 张这样的单。所以拒绝不挡任何真业务,
    --   只挡一个会让两条规矩算出互相矛盾的数的输入。判据与 A2 同形:【真的要扣钱】且【真的有税】。
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ EXPENSE-MULTILINE-1(Tim Q2):按【单据】判 —— 任何一行带税,整张单就不许代扣。
    IF COALESCE(v_wht_rate, 0) > 0 AND COALESCE(v_sum_tax, 0) > 0 THEN
        RAISE EXCEPTION 'EXPENSE_WHT_WITH_GST|%|%', v_wht_nature, v_first_taxed_code
          USING HINT = '要代扣预提税的非居民收款人不应在账单上收新加坡 GST —— 请核对税码(非居民服务通常不带进项税码)';
    END IF;


    -- 【资本化口径:不可抵的进项税【是】资产成本的一部分】(资本单恰好一行,所以这里读第一行)
    -- 可抵的税要得回来,它从来不是成本;不可抵的税(BL)要不回来,它和买价一样是为取得这台资产付出去的钱。
    v_c := v_calc -> 0;
    v_cost_ccy  := round((v_c->>'net')::numeric
                         + CASE WHEN (v_c->>'claimable')::boolean THEN 0 ELSE (v_c->>'tax')::numeric END, 2);
    v_cost_base := round((v_c->>'net_base')::numeric
                         + CASE WHEN (v_c->>'claimable')::boolean THEN 0 ELSE (v_c->>'tax_base')::numeric END, 2);

    -- 5. 无缝编号:咨询锁串行化"取当年最大号+1"(同 JE/收付款编号手法);失败回滚会释放号码。
    v_year := EXTRACT(YEAR FROM p_expense_date)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('expense') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 6. 先过分录(source_id = 预生成的 expense id,无需回填),期间锁在此生效。行走原币。
    -- ── 分录的形状(GST-2,EXPENSE-MULTILINE-1 按行展开)──────────────────
    -- 【净额那条腿带税码】F5 的 box5 = Σ(借−贷) FILTER (tax_code IN (TX,ZP,BL)) —— 报的是【采购净额】。
    -- 【可抵的税借 1400】那条腿【不带】税码(不然 box5 会把税也算进采购额);
    -- 【不可抵的税借进这一行自己的科目】同样不带税码。
    -- 【贷 2000 也按行】每一行一条净额、一条 'GST on <单号>' —— post_journal_entry 逐行 round 到本位币,
    --   所以每一行在本位币上自己就平,不会因为"合计先四舍五入"差出一分钱。应付仍是一笔(表头)。
    -- 单行单据的分录与此前逐行逐字相同(借净额 · 借税 · 贷净额 · 贷税)。
    v_jlines := '[]'::jsonb;
    FOR v_i IN 0 .. v_n - 1 LOOP
        v_c := v_calc -> v_i;
        v_jlines := v_jlines || jsonb_build_object('account_code', v_c->>'account_code', 'side', 'debit',
                           'currency', p_currency, 'amount_ccy', (v_c->>'net')::numeric, 'fx_rate', v_fx,
                           'tax_code', v_c->>'tax_code', 'line_memo', v_c->>'notes');
        IF (v_c->>'tax')::numeric > 0 THEN
            IF (v_c->>'claimable')::boolean THEN
                v_jlines := v_jlines || jsonb_build_object('account_code', '1400', 'side', 'debit',
                    'currency', p_currency, 'amount_ccy', (v_c->>'tax')::numeric, 'fx_rate', v_fx,
                    'line_memo', 'input tax ' || (v_c->>'tax_code'));
            ELSE
                v_jlines := v_jlines || jsonb_build_object('account_code', v_c->>'account_code', 'side', 'debit',
                    'currency', p_currency, 'amount_ccy', (v_c->>'tax')::numeric, 'fx_rate', v_fx,
                    'line_memo', 'blocked input tax ' || (v_c->>'tax_code'));
            END IF;
        END IF;
    END LOOP;
    FOR v_i IN 0 .. v_n - 1 LOOP
        v_c := v_calc -> v_i;
        v_jlines := v_jlines || jsonb_build_object('account_code', '2000', 'side', 'credit',
            'currency', p_currency, 'amount_ccy', (v_c->>'net')::numeric, 'fx_rate', v_fx);
        IF (v_c->>'tax')::numeric > 0 THEN
            v_jlines := v_jlines || jsonb_build_object('account_code', '2000', 'side', 'credit',
                'currency', p_currency, 'amount_ccy', (v_c->>'tax')::numeric, 'fx_rate', v_fx,
                'line_memo', 'GST on ' || v_code);
        END IF;
    END LOOP;

    v_je := post_journal_entry(
        p_expense_date,
        'Expense ' || v_code || ' ' || CASE WHEN v_n = 1 THEN v_first_account ELSE '(' || v_n || ' lines)' END,
        'expense', v_expense_id,
        v_jlines
    );

    -- 7. 表头(带着分录链接一次到位;不可变表无后续 UPDATE)—— 四个合计 = 各行之和
    INSERT INTO expenses (id, code, expense_date, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id, employee_id,
                          payee_name, notes, journal_entry_id, created_by,
                          purchase_order_line_id,
                          tax_base, tax_ccy,
                          wht_payee_residence, wht_nature, wht_rate_pct,
                          wht_amount_ccy, wht_treaty_ref)
    VALUES (v_expense_id, v_code, p_expense_date, v_sum_net, p_currency, v_fx,
            v_sum_base, p_payment_status, v_bank, p_supplier_id, p_employee_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, v_user,
            p_purchase_order_line,
            v_sum_tax_base, v_sum_tax,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_residence END,
            v_wht_nature,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
            CASE WHEN v_wht_nature IS NULL THEN 0    ELSE v_wht_ccy END,
            CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_ref END);

    -- 7b. 行
    INSERT INTO expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base,
                               tax_code, tax_rate_pct, tax_ccy, tax_base, notes, created_by)
    SELECT v_expense_id, (c->>'line_no')::integer, c->>'account_code', (c->>'net')::numeric, (c->>'net_base')::numeric,
           c->>'tax_code', (c->>'tax_rate')::numeric, (c->>'tax')::numeric, (c->>'tax_base')::numeric, c->>'notes', v_user
      FROM jsonb_array_elements(v_calc) c;

    -- FIN-22:资本行 → 同一事务生成台账。成本 = 本单金额;汇率 = 上面按
    -- 【费用日 = 购置日】取的 tt_sell 牌价 —— 资产是非货币项目,这个汇率
    -- 定格成本,永不重译(表注有言,重估扫不到 1500/1510)。
    IF p_asset IS NOT NULL THEN
        -- ── FA-1a:同一扇门,两种模式 ────────────────────────────────────────
        -- 【为什么不开第二个函数】1500 ↔ p_asset 的互相要求是这条路上唯一的
        -- 不变量:没有台账行的 1500 借方进不来,资本标记也落不到别的科目上。
        -- 再开一个 add_cost_to_asset() 等于开第二扇门,而那个不变量只守得住
        -- 第一扇 —— 与"单据不该有第二个写法"同一条(so_issues / approval_log)。
        -- 所以追加走【同一个函数】:p_asset 带 asset_id 就是追加,不带就是新建。
        v_append_id := (p_asset->>'asset_id')::uuid;

        IF v_append_id IS NOT NULL THEN
            -- ── 追加成本(运费、关税、安装调试)──────────────────────────
            SELECT * INTO v_target FROM fixed_assets WHERE id = v_append_id FOR UPDATE;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ASSET_NOT_FOUND|%', v_append_id;
            END IF;
            IF v_target.status <> 'active' THEN
                RAISE EXCEPTION 'ASSET_DISPOSED|%', v_target.code;
            END IF;

            -- ════════════════════════════════════════════════════════════════
            -- ★★【CAPEX-1:投用之后的追加 —— 那条【一律拒】换成了一条【窄】的】★★
            --
            -- FIN-22 原本在这里无条件拒(ASSET_ALREADY_IN_SERVICE),而它守的是
            -- **两件事**,必须分开说,因为只有一件被解决了:
            --   ① 【算术危险】抬高 cost_base 会让累计目标算法把过去每一个月
            --      重算一遍,整笔补提落在本期。
            --      —— 这一件由 fixed_asset_depreciation_anchors 【结构性】解决了:
            --      锚点之前那一段成了一个存下来的常数,新成本乘不到它身上。
            --   ② 【会计判断】投用后的花费算资本化改良,还是算当期费用?
            --      —— 这一件【没有】被解决,也解决不了:它是人的判断。
            --
            -- 所以窄的那条规矩保住的正是②:**判断仍然交还给人,只是人现在可以
            -- 在系统里回答,而不是被挡在门外。** 而回答的地方【不新开一处】——
            -- equipment_maintenance 已经是记录这个判断的地方(capitalised +
            -- capitalisation_reason,表上有 CHECK 逼理由非空),而
            -- capitalised_expense_id 这一列的注释早就写着它在等的就是这一刀。
            --
            -- 【为什么不接受一段自由文本的理由参数】那会让"这笔钱是资本化的、
            -- 理由是什么"同时住在两张表里,而两处之间没有任何链接 ——
            -- 一个判断两个真源。Tim 2026-08-29 裁定:走维修记录这一条路。
            --
            -- 【那条被关掉的路,按名拒并说出走法】一次不经维修记录的中途升级
            -- (比如按采购而不是按维修记下来的)今天没有路。**不给它开第二个
            -- 入口**:两个来源加一条优先级规则,是第二个定义披着"打平局"的外衣。
            -- 拒绝要指路 —— 先记一条维修记录、标资本化并写明理由,再对着它资本化。
            IF v_target.in_service_date IS NOT NULL THEN
                IF p_maintenance_id IS NULL THEN
                    RAISE EXCEPTION 'ASSET_IN_SERVICE_NEEDS_MAINTENANCE|%|%',
                        v_target.code, v_target.in_service_date
                      USING HINT = '给一台在跑的机器追加成本,要先有一条【标了资本化并写明理由】的维修记录,再对着它资本化 —— 那个判断(资本化改良 vs 当期费用)是人的,系统不替你做';
                END IF;
                SELECT * INTO v_maint FROM equipment_maintenance
                 WHERE id = p_maintenance_id FOR UPDATE;
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'MAINTENANCE_NOT_FOUND|%', p_maintenance_id;
                END IF;
                -- 【维修记录必须指着【这一台】】否则一次资本化会挂到别的机器的判断上。
                IF v_maint.equipment_id IS DISTINCT FROM v_append_id THEN
                    RAISE EXCEPTION 'MAINTENANCE_ASSET_MISMATCH|%|%', v_target.code, p_maintenance_id;
                END IF;
                -- 【判断必须已经做过】capitalised = false 意味着没有人说过这是资本化。
                -- 表上那条 CHECK 保证 capitalised ⇒ 理由非空,所以到这里理由必然有。
                IF NOT v_maint.capitalised THEN
                    RAISE EXCEPTION 'MAINTENANCE_NOT_CAPITALISED|%', p_maintenance_id
                      USING HINT = '这条维修记录没有被标成资本化 —— 先在机器页上把它标成资本化并写明理由';
                END IF;
                -- 【一条维修记录只资本化一次】否则同一次大修会被加两遍成本。
                IF v_maint.capitalised_expense_id IS NOT NULL THEN
                    RAISE EXCEPTION 'MAINTENANCE_ALREADY_CAPITALISED|%|%',
                        p_maintenance_id, v_maint.capitalised_expense_id;
                END IF;
            ELSIF p_maintenance_id IS NOT NULL THEN
                -- 还没投用的机器不需要这条路 —— 成本本来就加得上去。
                -- 悄悄忽略这个参数会让调用方以为它起了作用。
                RAISE EXCEPTION 'MAINTENANCE_NOT_APPLICABLE|%', v_target.code
                  USING HINT = '这台机器还没投用,成本直接加得上去,不需要经维修记录';
            END IF;

            -- 每一笔追加带【自己的】三件套:原币金额、它自己那天的汇率、本位币额。
            -- 表头那三列是【第一笔】的(购置那一笔),不是合计 —— 合计只有
            -- cost_base 一个数,而各笔的原币可以不同(进口机器 USD、本地运费 SGD)。
            INSERT INTO fixed_asset_cost_entries
                (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
            VALUES (v_append_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);

            UPDATE fixed_assets
               SET cost_base = cost_base + v_cost_base
             WHERE id = v_append_id;

            -- ════════════════════════════════════════════════════════════════
            -- ★★【CAPEX-1:落一个折旧锚点 —— 这里就是回溯补提被挡住的地方】★★
            --
            -- 上面那句 UPDATE 刚把 cost_base 抬高了。**如果什么都不做**,
            -- 月度例程下一次跑就会用新成本把【每一个已经过去的月份】的目标重算,
            -- 整笔补提落在本期 —— 那正是 4.7 明令禁止的。
            --
            -- 锚点把"过去那一段"冻成一个数:
            --   · pre_anchor_target_base = 按【锚点之前】那套算术、到锚点前一天
            --     为止【应当】累计多少。**注意是"应当",不是"已经提了多少"** ——
            --     欠着的那几期仍要按【旧费率】补上(delta = target − 已提 自动做到),
            --     不该被卷进新费率里摊掉。
            --   · remaining_months = 现行那一段的剩余月数,减去它已经走掉的部分。
            --     递归地写:没有现行锚点时,现行那一段就是"从投用日起、共 useful_life
            --     个月",于是这条式子对首次与第二次资本化是同一条。
            --
            -- 【生效日取当月 1 号】资本化落在哪个月,就从那个月末那一次起用新费率。
            IF v_target.in_service_date IS NOT NULL THEN
                v_anchor_from := date_trunc('month', p_expense_date)::date;

                SELECT * INTO v_prev FROM fixed_asset_depreciation_anchors an
                 WHERE an.asset_id = v_append_id AND an.effective_from <= v_anchor_from
                 ORDER BY an.effective_from DESC LIMIT 1;
                IF FOUND THEN
                    v_prev_start := v_prev.effective_from;
                    v_prev_rem   := v_prev.remaining_months;
                    -- 锚点之前那一段的目标 = 上一个常数 + 上一段走掉的部分
                    v_pre_target := v_prev.pre_anchor_target_base
                        + LEAST(round(v_target.cost_base - v_cost_base - v_target.residual_base
                                      - v_prev.pre_anchor_target_base, 2),
                                round((v_target.cost_base - v_cost_base - v_target.residual_base
                                       - v_prev.pre_anchor_target_base)
                                      / v_prev.remaining_months
                                      * depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 2));
                ELSE
                    v_prev_start := v_target.in_service_date;
                    v_prev_rem   := v_target.useful_life_months;
                    -- 【注意 cost_base 减回本次追加】v_target 是 UPDATE 之【前】读的那一行,
                    -- 所以它的 cost_base 本来就是旧值 —— 这里不减。写出来是因为
                    -- 下一个读的人会问:常数用的是【加钱之前】的成本吗?是。
                    v_pre_target := LEAST(
                        round(v_target.cost_base - v_target.residual_base, 2),
                        round((v_target.cost_base - v_target.residual_base)
                              / v_target.useful_life_months
                              * depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 2));
                END IF;

                v_rem := round(v_prev_rem
                               - depreciation_months_elapsed(v_prev_start, v_anchor_from - 1), 6);
                -- 【寿命走完的机器不许再资本化】剩余月数 ≤ 0 时那条公式的分母是零或负,
                -- 而它背后的现实是:一台已经提完的机器,再投的钱要么是当期费用,
                -- 要么需要先重估寿命 —— 两者都不是这条路。按名拒,不猜。
                IF v_rem <= 0 THEN
                    RAISE EXCEPTION 'ASSET_LIFE_EXHAUSTED|%|%', v_target.code, v_target.useful_life_months
                      USING HINT = '这台机器的使用年限已经走完,没有"剩余年限"可以摊 —— 这笔钱要么是当期费用,要么先要有一次使用年限重估(那一条还没有建,见 docs/known-issues.md)';
                END IF;

                INSERT INTO fixed_asset_depreciation_anchors
                    (asset_id, effective_from, pre_anchor_target_base, remaining_months,
                     expense_id, maintenance_id, reason, created_by)
                VALUES (v_append_id, v_anchor_from, v_pre_target, v_rem,
                        v_expense_id, p_maintenance_id, v_maint.capitalisation_reason, v_user);

                -- 【回填 capitalised_expense_id —— 1.5 找到的那个缺口在这里闭合】
                -- 在此之前没有任何一条代码路径写过这一列,因为这笔支出建不出来。
                UPDATE equipment_maintenance
                   SET capitalised_expense_id = v_expense_id
                 WHERE id = p_maintenance_id;
            END IF;

            RETURN jsonb_build_object(
                'expense_id', v_expense_id,
                'asset_id', v_append_id, 'asset_code', v_target.code,
                'asset_mode', 'append',
                -- CAPEX-1:把锚点回给调用方 —— 屏幕要说得出"从这个月起按新费率摊,
                -- 还剩几个月",而不是让页面自己再算一遍。
                'anchor_from', v_anchor_from,
                'anchor_remaining_months', v_rem,
                'journal_entry_id', (v_je->>'entry_id')::uuid,
                'journal_code', v_je->>'code',
                'code', v_code);
        END IF;

        -- ── 新建(FIN-22 起的原样路径)──────────────────────────────────────
        -- 【两扇建卡的门,而【两扇都不是遗留】—— EQP-1c-a 记在这里,免得下一个
        --   读到 create_fixed_asset 的人以为这一支该被删掉。】
        --   * 这一支(卡与成本【同时】诞生):一台【没有采购单、当场买断】的机器。
        --     那件事的真实形状就是"一张发票同时带来这台机器和它的成本",
        --     硬要拆成两步反而是编造一个不存在的中间状态。
        --   * create_fixed_asset(卡先诞生、成本后到):设备采购的常态 ——
        --     先下单(而采购单行必须引用一张【已存在】的卡,EQP-1a),
        --     后开票。发票经【追加】模式落到那张卡上。
        --   判据一句话:**这台机器在拿到它的成本之前,需不需要先被别的单据引用?**
        --   需要 → create_fixed_asset;不需要 → 这一支。
        IF COALESCE(p_asset->>'description', '') = '' THEN
            RAISE EXCEPTION 'ASSET_DESCRIPTION_REQUIRED';
        END IF;
        v_life := (p_asset->>'useful_life_months')::integer;
        IF v_life IS NULL OR v_life <= 0 THEN
            RAISE EXCEPTION 'ASSET_LIFE_INVALID|%', COALESCE(p_asset->>'useful_life_months', '?');
        END IF;
        v_residual := COALESCE((p_asset->>'residual_base')::numeric, 0);
        IF v_residual < 0 OR v_residual >= v_cost_base THEN
            RAISE EXCEPTION 'ASSET_RESIDUAL_INVALID|%|%', v_residual, v_cost_base;
        END IF;
        v_in_service := (p_asset->>'in_service_date')::date;
        IF v_in_service IS NOT NULL AND v_in_service < p_expense_date THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_BEFORE_ACQUISITION|%|%', v_in_service, p_expense_date;
        END IF;

        v_asset_id := gen_random_uuid();
        -- EQP-1c-a:取号提成 next_fixed_asset_code(),两扇门共用一个号段。
        -- 【行为逐字不变】它就是原来这四行:同一把咨询锁(键也是按年拼的
        -- 'fixed_asset_code_'||year)、同一个"当年最大号 + 1"。提出来是因为
        -- 现在有【两扇】建卡的门,而两份同样的取号逻辑迟早会漂开。
        v_asset_code := next_fixed_asset_code(p_expense_date);

        INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date,
                                  cost_ccy, currency, fx_rate, cost_base, useful_life_months,
                                  residual_base, depreciation_account_code, expense_id, notes, created_by)
        VALUES (v_asset_id, v_asset_code, p_asset->>'description',
                COALESCE(p_asset->>'category', 'equipment'),
                p_expense_date, v_in_service,
                v_cost_ccy, p_currency, v_fx, v_cost_base, v_life,
                v_residual, COALESCE(p_asset->>'depreciation_account_code', '6700'),
                v_expense_id, p_asset->>'notes', v_user);

        -- 【第一笔也进明细表】否则"这台机器的成本由哪几笔构成"对第一笔要查
        -- expenses、对后续几笔要查明细表 —— 两处读法,迟早各说各话。
        INSERT INTO fixed_asset_cost_entries
            (asset_id, expense_id, amount_ccy, currency, fx_rate, amount_base, created_by)
        VALUES (v_asset_id, v_expense_id, v_cost_ccy, p_currency, v_fx, v_cost_base, v_user);
    END IF;

    RETURN jsonb_build_object(
        'expense_id', v_expense_id,
        'asset_id', v_asset_id, 'asset_code', v_asset_code,
        'code', v_code,
        'amount_base', v_sum_base,
        'amount_ccy', v_sum_net, 'tax_ccy', v_sum_tax,
        'journal_code', v_je->>'code',
        'payment_status', p_payment_status,
        'wht_nature', v_wht_nature,
        'wht_rate_pct', CASE WHEN v_wht_nature IS NULL THEN NULL ELSE v_wht_rate END,
        'wht_amount_ccy', CASE WHEN v_wht_nature IS NULL THEN 0 ELSE v_wht_ccy END,
        'currency', p_currency,
        'line_count', v_n
    );
END;
$function$
;

-- db/functions/submit_expense_claim_items.sql
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q4 · Q5 · Q7):提交一张【多笔】报销单。
--   p_purpose  —— 整张单的用途(必填;落进 expense_claims.description,搜索读它,Q7);
--   p_items    —— [{spend_date, amount, description, no_receipt_reason?}, ...],至少一笔。金额是【收据上的总额】(含税,与此前一样)。
--   一张单一个币种(Q4)。日期(Q5,两条都按名拒):
--     · 所有明细落在【同一个日历月】—— 一张单生出一张费用单,一张费用单只有一个入账期间
--       (EXPENSE_CLAIM_ITEMS_SPAN_MONTHS|最早|最晚);
--     · 非本位币的单,所有明细【同一天】—— 一张费用单只有一个汇率,而汇率规矩是"按交易自己那一天"
--       (EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE|币种|最早|最晚)。
--   表头 spend_date = 最晚那一笔(它决定审批档次、默认入账日与汇率);amount_ccy = 明细之和 —— 两样都由
--   guard_expense_claim_totals 在提交时强制。科目与税码【不在这里】:那是财务批准时逐笔给的(Step 0b Q1)。
--   submit_expense_claim(旧签名)是这一支的【单笔包装】(Q8)。
CREATE OR REPLACE FUNCTION public.submit_expense_claim_items(p_employee_id uuid, p_currency text, p_purpose text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp   employees%ROWTYPE;
    v_code  text;
    v_id    uuid;
    v_base  numeric;
    v_n     integer;
    v_i     integer;
    v_it    jsonb;
    v_date  date;
    v_amt   numeric;
    v_first date;
    v_last  date;
    v_total numeric := 0;
BEGIN
    -- 【自助:本人,或者持财务读权限的人代录】与 submit_medical_claim 同一条谓词
    -- ★ EMP-SELF-1(Q9 · Q2):COALESCE(…, false)。没有员工档案的账号 current_user_employee() 是 NULL,
    --   于是 NOT (false OR NULL) = NULL,IF 不触发 —— 这一道门对它【从来没有关上过】。
    IF NOT COALESCE(has_permission('module.finance.view') OR p_employee_id = current_user_employee(), false) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.finance.view';
    END IF;

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', COALESCE(p_employee_id::text, '?');
    END IF;
    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_REQUIRED';
    END IF;
    v_n := jsonb_array_length(p_items);
    -- 逐笔:日期必填、不晚于今天,金额为正(多笔的单错误码带一个 '|<第几笔>' 尾巴;单笔与此前逐字相同)
    FOR v_i IN 1 .. v_n LOOP
        v_it := p_items -> (v_i - 1);
        IF jsonb_typeof(v_it) <> 'object' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_INVALID|%', v_i;
        END IF;
        v_date := NULLIF(v_it->>'spend_date', '')::date;
        IF v_date IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_REQUIRED%', CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        END IF;
        IF v_date > CURRENT_DATE THEN
            -- 一笔"将来才会花的钱"不是报销,那是备用金 —— 而备用金被否决了(§0)
            RAISE EXCEPTION 'EXPENSE_CLAIM_SPEND_DATE_FUTURE|%|%', v_date::text, CURRENT_DATE::text;
        END IF;
        v_amt := NULLIF(v_it->>'amount', '')::numeric;
        IF v_amt IS NULL OR v_amt <= 0 THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_INVALID|%', COALESCE(v_amt::text, '?');
        END IF;
        v_first := LEAST(COALESCE(v_first, v_date), v_date);
        v_last  := GREATEST(COALESCE(v_last, v_date), v_date);
        v_total := v_total + v_amt;
    END LOOP;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies WHERE code = p_currency) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_CURRENCY_UNKNOWN|%', COALESCE(p_currency, '?');
    END IF;
    FOR v_i IN 1 .. v_n LOOP
        IF NULLIF(btrim(COALESCE(p_items -> (v_i - 1) ->> 'description', '')), '') IS NULL THEN
            -- 「买了什么」是审批人唯一能据以判断的东西 —— 逐笔
            RAISE EXCEPTION 'EXPENSE_CLAIM_DESCRIPTION_REQUIRED%', CASE WHEN v_n > 1 THEN '|' || v_i ELSE '' END;
        END IF;
    END LOOP;
    IF p_purpose IS NULL OR btrim(p_purpose) = '' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_PURPOSE_REQUIRED';
    END IF;
    -- Q5:同一个日历月;非本位币同一天
    IF date_trunc('month', v_first) <> date_trunc('month', v_last) THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_SPAN_MONTHS|%|%', v_first::text, v_last::text
          USING HINT = '一张报销单生出一张费用单,只有一个入账期间 —— 跨月的花销分成每月一张';
    END IF;
    IF p_currency <> base_currency_code() AND v_first <> v_last THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_FOREIGN_ITEMS_ONE_DATE|%|%|%', p_currency, v_first::text, v_last::text
          USING HINT = '外币报销单只有一个汇率,而汇率按花钱那一天取 —— 不同日子的外币花销分开报';
    END IF;

    v_code := next_expense_claim_code(v_last);
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description, created_by)
    VALUES (v_code, p_employee_id, v_last, v_total, p_currency, btrim(p_purpose), auth.uid())
    RETURNING id INTO v_id;
    INSERT INTO expense_claim_items (claim_id, line_no, spend_date, amount_ccy, description, no_receipt_reason, created_by)
    SELECT v_id, x.ord::integer, (x.it->>'spend_date')::date, (x.it->>'amount')::numeric, btrim(x.it->>'description'),
           NULLIF(btrim(COALESCE(x.it->>'no_receipt_reason', '')), ''), auth.uid()
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS x(it, ord);

    -- ★ U1-B(ROLE1B3A-NO-OTHER-DECIDER-PO-EXPENSE 的报销单那一半,与采购单 APR-10 同一个形状):
    --   审批开着时,按这张单会落到的那一级问一句"提单人与主角之外,有没有人批得动";没有 → 按名拒,整张单不落库
    --   (单号随回滚放回去)。主角要传 —— 报销单的四眼也看【报的是谁】(decide_expense_claim 的 forbid_self_approval)。
    --   【分档读同一份】expense_claim_amount_base 是 decide_expense_claim 分档用的那一支;折不出本位币(没有牌价)时
    --   不在这里另造一句拒绝 —— 那张单在决定时会被 fx_rate_for 按名拒(那句话归它),而在牌价补上之前谁都批不了它。
    IF approvals_enabled() THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(v_id) b;
        IF v_base IS NOT NULL THEN
            PERFORM assert_other_decider_for_subject('expense_claim', 'decide_expense_claim_items',
                                                     approval_level_for(v_base), p_employee_id,
                                                     'EXPENSE_CLAIM_NO_OTHER_DECIDER|' || v_code);
        END IF;
    END IF;

    RETURN jsonb_build_object('claim_id', v_id, 'code', v_code, 'status', 'submitted', 'item_count', v_n);
END;
$function$
;

-- db/functions/decide_expense_claim_items.sql
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q3 · Step 0b Q1 · Q3 · Q8):报销单的决定路径,【按明细】。
--   p_items = [{line_no, account_code, tax_code?}, ...] —— 财务给【每一笔】明细一个科目与税码,什么都不预选(Q1);
--   必须逐笔覆盖整张单(少一笔 → EXPENSE_CLAIM_ACCOUNT_REQUIRED|单号|第几笔;多出一个不存在的行号 →
--   EXPENSE_CLAIM_ITEM_UNKNOWN|单号|行号)。驳回【只能整张】(Q3),理由可以点名是哪一笔。
--   批准时整张单生出【一张】费用单(record_expense_document),每一笔明细一行、行备注 = 明细说明;
--   表头备注 = 'Expense claim <单号> (<员工号>) — <用途>'。
--   decide_expense_claim(旧签名)是这一支的【单笔包装】(Q8):多笔的单走旧调用按名拒(EXPENSE_CLAIM_HAS_ITEMS)。
--   下面 CLAIM-1 / APR-3 / CLAIM-GST-1 的说明原样保留 —— 它们说的是这一支的门、分档与税,而那几样一个字都没变。
-- 报销单的决定路径。CLAIM-1 建的;★ APR-3(2026-09-22)把它接上审批引擎。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-3 在这支函数上改了三件事,每一件都是 Tim 的一条裁定 ★★★
-- ════════════════════════════════════════════════════════════════════════════
--
-- ① 【门从 module.finance.edit 换成 module.finance.view + data.view_prices】(Q1)
--    采购单那条链的形状,原样照搬 —— approve_purchase_order 要的正是这两个码,
--    而它【刻意】不要 edit:「一个提得了这张单的人不是一道管控」。
--    ★ 而决定性的理由是实测出来的:cfo 持 module.finance.view 与 data.view_prices,
--      【不持】module.finance.edit。写成 edit,今天二级之所以还有一个人批得动,
--      靠的只是 cfo 的唯一真持有人就是 admin 账号(docs/approvals.md §0b 记着的
--      那次撞车);Tim 一拿到独立的 CFO 账号、把 cfo 从 admin 上收回,
--      二级当场归零,approval_gate_intersections 会在【那一天】才变红,
--      而那时没有任何东西会说是这一刀造成的。
--    ⚠【代价照直说,因为它是真的】本函数是 SECURITY DEFINER,批准那一支会
--      调 record_expense 建一张开支单。于是一个持 view + prices 而【不持】
--      module.finance.edit 的人,经由这条路造得出一笔开支 —— 线上是 phua 与
--      sandra 两个人。这是 Tim 的裁定,不是疏忽:批的人与做的人本来就该分开,
--      而"做"这一步是引擎代他做的,不是他自己去写那张表。
--
-- ② 【四眼换成全库唯一的那一份判据】(Q5)
--    此前这里调的是 assert_segregated('EXPENSE_CLAIM_SELF_APPROVAL', …) ——
--    两条腿(受益人 + 提报人)其实是对的,但它是四眼的【第二份定义】,
--    而 APR-2 §3d 的全部论证就是"一条写成两遍的规矩,第三条链会漏掉它"。
--    ★ 而它同时在屏幕上说错过一句话:两条腿共用一句
--      「报销 X 是你提的,所以批它的不能是你」—— 当拒绝是因为【你就是那张单
--      说的那个人】时,那句话是假的,并且把人指去修错的东西。
--      APR-2 把这一句拆成两句,正是为了这个;这里接上那两句。
--    ☞ assert_segregated 本身【留着】,它还有三个正当的调用方
--      (guard_payment_sod · guard_finance_settings_sod · sod_supplier_creator)。
--
-- ③ 【接上分档与留痕】(本刀的主体)
--    approvals_enabled() 为真时按金额分档并 require_approver_for(级别);
--    两条分支【都】落一行 approval_log。
--    ★【永远不写 auto_approved】Tim 对 HR 三条链的裁定逐字适用:
--      开着还是关着,做决定的都是一个人。审批关着时写的是 approved/rejected、
--      level 为 NULL —— 不是"系统盖的章"。
--    ★【驳回也分档,所以驳回也要看得见金额】与采购单不同:那里 reject 单独一支
--      函数、门窄一格(不显示金额)。这里是一支函数两条分支,两边都落带 level
--      的留痕,所以两边都得先知道这是几级的单 —— 门一样宽,registry 里那两行
--      因此是同一个 gate_permissions。
--
-- 【金额从哪来】expense_claims 上没有 fx_rate 也没有 amount_base,所以那个数要算,
--   而判据只有一份:expense_claim_amount_base()(spend_date 的 tt_sell,理由见
--   那个文件的抬头 —— 一句话:posting_date 是审批人自己填的入参,拿它分档等于
--   让审批人挑自己的权限)。查不到牌价时它返回 NULL,由【这里】按名拒:
--   那句 FX_RATE_MISSING 归 fx_rate_for() 那一份定义所有,本函数不复述它。

-- CLAIM-GST-1(2026-09-24):报销单的 amount_ccy 是【收据上的总额】,已含 GST。
-- 此前它被当成净额、在上面再加 9%(TX 时那 9% 进 1400):报 100 记成欠员工 109(CLM-2026-0002 →
-- EXP-2026-0007,留作测试数据残留,见 docs/known-wrong-until-cutover.md)。现在调 record_expense 时
-- 传 p_amount_includes_tax := true,税从总额里拆出来,欠员工的恰好是收据上的数。
--
CREATE OR REPLACE FUNCTION public.decide_expense_claim_items(p_claim_id uuid, p_approve boolean, p_items jsonb DEFAULT NULL::jsonb, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_c        expense_claims%ROWTYPE;
    v_emp      employees%ROWTYPE;
    v_has_att  boolean;
    v_exp      jsonb;
    v_item     record;
    v_pick     jsonb;     -- 财务给这一笔的那一条 {line_no, account_code, tax_code}
    v_acct     text;
    v_tax      text;
    v_lines    jsonb := '[]'::jsonb;
    v_x        jsonb;
    v_date     date;
    v_base     numeric;
    v_level    smallint;
    v_appr_on  boolean := approvals_enabled();
BEGIN
    -- ① APR-3(Q1):门是【看得见财务 + 看得见金额】,不是【改得了财务】。
    --    两个码分两句,与 approve_purchase_order 同形 —— 拒绝要说清缺的是哪一个。
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');

    SELECT * INTO v_c FROM expense_claims WHERE id = p_claim_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_FOUND|%', COALESCE(p_claim_id::text, '?');
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT * INTO v_emp FROM employees WHERE id = v_c.employee_id;

    -- ══ ★② 四眼:全库【唯一】一份判据,两条腿 ★ ════════════════════════════
    -- 【为什么这道闸必须在这里】SOD-1 的 guard_payment_sod 明确豁免了付给员工的
    -- 款,理由是"由 HR 建档、财务付款,已经跨了两个模块的门"。那句话在写下的
    -- 那天是对的 —— 而 CLAIM-1 开出了一条新路:**员工自己发起**。发起人现在
    -- 就是受益人,那个论证对新路不成立。「换了推导来源,闸就要跟着搬」。
    -- 【两条腿各是谁】raiser = 提这张单的人(代人录入时不是员工本人);
    -- subject = 这张单【说的是谁】,也就是拿到这笔钱的那位员工。
    -- 顺序是定的:raiser 先判(APR-2 §3.5)。
    PERFORM forbid_self_approval(v_c.created_by, v_c.employee_id, 'expense_claim');

    -- ══ ★③ 分档 ★ ════════════════════════════════════════════════════════
    -- 【只在审批开着时问这一句】关着的时候,分档是一个没有意义的动作:
    -- 没有哪一级在生效,而 require_approver_for 会拿一条没有人在执行的策略
    -- 去拒绝一个本来做得了决定的人。这与 HR 三条链的形状一致 ——
    -- ☞ 也正因为如此,一张 submitted 的报销单【不挡】审批关闭
    --   (approval_pending_documents 的 blocks_disable = false,理由写在那里)。
    IF v_appr_on THEN
        SELECT b.amount_base INTO v_base FROM expense_claim_amount_base(p_claim_id) b;
        IF v_base IS NULL THEN
            -- 【那句话归 fx_rate_for 所有,这里只是把它请出来】——
            -- 自己拼一句 FX_RATE_MISSING 就是这条 FX 规矩的第二份定义。
            PERFORM fx_rate_for(v_c.currency, v_c.spend_date, 'tt_sell');
            -- 上面必定抛;真走到这里说明牌价其实查得到而上一步算出了 NULL,
            -- 那是一个【不该发生】的状态,按名拒而不是继续往下走。
            RAISE EXCEPTION 'EXPENSE_CLAIM_AMOUNT_BASE_UNRESOLVED|%', v_c.code;
        END IF;
        v_level := approval_level_for(v_base);
        PERFORM require_approver_for(v_level);
    END IF;

    -- ══ 驳回 ══════════════════════════════════════════════════════════════
    IF NOT p_approve THEN
        -- 【按名拒,而不是让 CHECK 抛约束原文】fixture 90 立的那条
        IF p_notes IS NULL OR btrim(p_notes) = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_REJECT_REASON_REQUIRED|%', v_c.code;
        END IF;
        UPDATE expense_claims
           SET status = 'rejected', decided_at = now(), decided_by = auth.uid(),
               decision_notes = btrim(p_notes)
         WHERE id = p_claim_id;
        -- ★ 驳回【也】留痕 —— APR-1 建这张表的第一条理由就是"驳回 → 重提 →
        --   批准之后,驳回那一次不留痕迹"。报销单此前正是那个形状:
        --   decision_notes 会被下一次决定覆盖掉。
        PERFORM record_approval_decision('expense_claim', p_claim_id, 'rejected',
                                         v_level, btrim(p_notes));
        RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'rejected',
                                  'level', v_level);
    END IF;

    -- ══ 批准 ══════════════════════════════════════════════════════════════
    -- ★ EXPENSE-MULTILINE-1:p_items 里每一个行号都必须是这张单上的一笔(不认识的行号按名拒,不悄悄丢掉)
    IF p_items IS NOT NULL AND jsonb_typeof(p_items) <> 'array' THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_ITEMS_INVALID|%', v_c.code;
    END IF;
    FOR v_x IN SELECT x FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) x LOOP
        IF NOT EXISTS (SELECT 1 FROM expense_claim_items i
                        WHERE i.claim_id = p_claim_id AND i.line_no = NULLIF(v_x->>'line_no', '')::integer) THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_ITEM_UNKNOWN|%|%', v_c.code, COALESCE(v_x->>'line_no', '?');
        END IF;
    END LOOP;

    SELECT EXISTS (SELECT 1 FROM finance_attachments
                    WHERE claim_id = p_claim_id AND deleted_at IS NULL) INTO v_has_att;

    FOR v_item IN SELECT * FROM expense_claim_items WHERE claim_id = p_claim_id ORDER BY line_no LOOP
        SELECT x INTO v_pick FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) x
         WHERE NULLIF(x->>'line_no', '')::integer = v_item.line_no LIMIT 1;
        v_acct := NULLIF(btrim(COALESCE(v_pick->>'account_code', '')), '');
        v_tax  := NULLIF(btrim(COALESCE(v_pick->>'tax_code', '')), '');
        IF v_acct IS NULL THEN
            -- 会计口径由审批人给 —— 没有科目就没法记账,而猜一个科目比拒绝坏(逐笔)
            RAISE EXCEPTION 'EXPENSE_CLAIM_ACCOUNT_REQUIRED|%|%', v_c.code, v_item.line_no;
        END IF;

        -- ★【GST 开着时,税码是【必给】的 —— 而且只能由审批人给】★(逐笔)
        -- 实测:resolve_tax_code 接受 override 或【往来对象的默认税码】,两者皆空就
        -- 按名拒(TAX_CODE_REQUIRED)。而 employees **没有 default_tax_code 这一列** ——
        -- 员工这一侧【永远】解析不出默认值。所以报销这条路上,税码只能显式给。
        -- 【为什么在这里先拒一次,而不是让 resolve_tax_code 去拒】它的提示语是
        -- 「给这个往来对象设一个默认税码,或在这张单据上指定一个」—— 对员工来说
        -- 前半句是【做不到的事】,于是那句话有一半是错的指路。这里按名拒并说清楚
        -- 要做的判断:进项税可抵是 TX,不可抵是 BL,而那是一个财务判断。
        IF (SELECT gst_registered FROM finance_settings) AND v_tax IS NULL THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_TAX_CODE_REQUIRED|%|%', v_c.code, v_item.line_no;
        END IF;

        -- ★【凭据:要么有附件,要么有一句说得出为什么没有】★ —— 逐笔(Tim Step 0b Q2)
        -- 【为什么查在这一步而不是提交那一步】凭据真正起作用的时刻,正是有人要据它做决定的时刻。
        -- 【为什么留了一条例外的路】一条没有例外出口的规矩会被绕过 —— 允许没有收据,但要求把【为什么】说出来。
        -- ⚠ 在 CLAIM-RECEIPTS-1 之前员工传不了收据(docs/known-issues.md § EXPENSE-CLAIM-NO-RECEIPT-UPLOAD),
        --   所以今天实际上每一笔都要有自己的无收据理由。
        IF NOT v_has_att AND COALESCE(btrim(v_item.no_receipt_reason), '') = '' THEN
            RAISE EXCEPTION 'EXPENSE_CLAIM_NO_EVIDENCE|%|%', v_c.code, v_item.line_no;
        END IF;

        UPDATE expense_claim_items SET account_code = v_acct, tax_code = v_tax WHERE id = v_item.id;
        v_lines := v_lines || jsonb_build_object('account_code', v_acct, 'amount', v_item.amount_ccy,
                                                 'tax_code', v_tax, 'notes', v_item.description);
    END LOOP;

    -- 入账日:默认花钱那天;期间关了账时由审批人显式给
    v_date := COALESCE(p_posting_date, v_c.spend_date);

    -- 【成本与欠款在这里同时落地】unpaid = 一笔挂在这名员工头上的应付,
    -- 它会立刻出现在 ap_open_items 里带着他自己的名字(PAYEE-1a)。
    -- 汇率传 NULL:由 record_expense 按【那一天】自己查牌价 —— 一条 FX 规矩,
    -- 查不到就按名拒(FX_RATE_MISSING),报销不是它的例外。
    -- ⚠ APR-3 照直说:这里过账取的是 v_date 那天的牌价,而上面分档取的是
    --   spend_date 那天的 —— 两个日期不同时,两个数可以不一样。那是两个不同的
    --   问题(这笔承诺有多大 / 账上记多少),理由写在 expense_claim_amount_base。
    -- ★★【这张开支单【不】另外走一次审批】它是引擎在一个人已经批准之后代他
    --   记的账,不是一份新提交的单据 —— 与 N5 对系统生成凭证的裁定逐字同源。
    --   expense 这个 subject_type 在 APR-3 里【没有】接上引擎(Tim 的 Q2 裁定:
    --   payments / expenses 没有在途态,要先做一次建模改动),所以今天这一格
    --   不需要任何豁免机制;那条路开工时,豁免要写成一个【显式入参】,不是 GUC
    --   (Tim 的 Q9),理由记在 docs/forward-queue.md。
    -- ★ EXPENSE-MULTILINE-1:一张报销单 → 【一张】费用单,每笔明细一行(Tim Step 0 Q3)。
    v_exp := record_expense_document(
        p_expense_date   := v_date,
        p_currency       := v_c.currency,
        p_lines          := v_lines,
        p_payment_status := 'unpaid',
        p_bank_account   := NULL,
        p_supplier_id    := NULL,
        p_employee_id    := v_c.employee_id,
        p_payee_name     := v_emp.legal_name,
        p_notes          := format('Expense claim %s (%s) — %s', v_c.code, v_emp.code, v_c.description),
        -- CLAIM-GST-1(Tim Q3):员工报上来的是【收据上的总额】,已含 GST —— 税从里面拆出来,不加在上面(逐行)。
        p_amount_includes_tax := true);

    UPDATE expense_claims
       SET status = 'approved', decided_at = now(), decided_by = auth.uid(),
           decision_notes = NULLIF(btrim(COALESCE(p_notes, '')), ''),
           posting_date = v_date,
           expense_id = (v_exp->>'expense_id')::uuid
     WHERE id = p_claim_id;

    PERFORM record_approval_decision('expense_claim', p_claim_id, 'approved',
                                     v_level, NULLIF(btrim(COALESCE(p_notes, '')), ''));

    RETURN jsonb_build_object('claim_id', p_claim_id, 'code', v_c.code, 'status', 'approved',
                              'expense_id', v_exp->>'expense_id', 'posting_date', v_date,
                              'level', v_level);
END;
$function$;

-- ── 7 · 换掉的函数(镜像原样,同签名)──

CREATE OR REPLACE FUNCTION public.record_expense(p_expense_date date, p_account_code text, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_payment_status text DEFAULT 'unpaid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_asset jsonb DEFAULT NULL::jsonb, p_employee_id uuid DEFAULT NULL::uuid, p_purchase_order_line uuid DEFAULT NULL::uuid, p_tax_code text DEFAULT NULL::text, p_wht_nature text DEFAULT NULL::text, p_wht_rate_pct numeric DEFAULT NULL::numeric, p_wht_treaty_ref text DEFAULT NULL::text, p_maintenance_id uuid DEFAULT NULL::uuid, p_amount_includes_tax boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- ════════════════════════════════════════════════════════════════════════════
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0 Q11):record_expense 是 record_expense_document 的【单行包装】。
--   签名一个字不变 —— 三个库内调用者(decide_expense_claim_items 之外的报销 / 医疗 / 资产页那几条路)、两个应用调用者
--   (费用表单之外:资产页追加成本 · 设备页资本化)与 140 处 fixture 调用照旧。它只做一件事:把 (科目, 金额, 税码) 包成一行,
--   交给那一支唯一的写入者 —— 一份实现,两个入口。原来这里的每一段(采购单行 · 预提税 · 资本化 · 分录形状)
--   原样搬进了 record_expense_document,读那一支。
--   p_notes 记在【表头】;单行单据的那一行不另带备注(与此前一模一样:一张单只有一句备注)。
-- 【汇率不由调用方递入】FX_RATE_NOT_ACCEPTED 留在包装里:牌价属于 fx_rates,不属于表单(FIN-0)。新的那一支干脆没有这个参数。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    RETURN record_expense_document(
        p_expense_date        := p_expense_date,
        p_currency            := p_currency,
        p_lines               := jsonb_build_array(jsonb_build_object(
                                     'account_code', p_account_code, 'amount', p_amount, 'tax_code', p_tax_code)),
        p_payment_status      := p_payment_status,
        p_bank_account        := p_bank_account,
        p_supplier_id         := p_supplier_id,
        p_payee_name          := p_payee_name,
        p_notes               := p_notes,
        p_asset               := p_asset,
        p_employee_id         := p_employee_id,
        p_purchase_order_line := p_purchase_order_line,
        p_wht_nature          := p_wht_nature,
        p_wht_rate_pct        := p_wht_rate_pct,
        p_wht_treaty_ref      := p_wht_treaty_ref,
        p_maintenance_id      := p_maintenance_id,
        p_amount_includes_tax := p_amount_includes_tax);
END;
$function$
;

-- db/functions/reverse_expense_internal.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q24,Tim):【冲销一张费用单的那一段 —— 两个调用方,一份实现】。
--   reverse_expense(冲一张费用单)与 reverse_electricity_allocation(撤回一张电费单)都经它冲费用单与分录:
--   原来写在 reverse_expense 里的那一整段(资本支出的两条规矩、冲分录、镜像费用单、成本退回并当场核对)原样搬到这里,
--   一个字的算术都没改 —— 只是不再问码(调用方问),也不再拒电费分摊的费用单(那一句留在 reverse_expense:分摊那一路正是从这里冲它)。
--   ★ 新加一道(Q24):经付款结过的费用单按名拒 EXPENSE_HAS_SETTLEMENT,冲抵过预付款的按名拒 EXPENSE_HAS_PREPAYMENT_APPLIED ——
--     放在这里而不是放在两个调用方里,于是【每一种】费用单、两条路都过同一道。
--   内层:不是 DEFINER,authenticated 调不到(zzz_function_grants.sql)。
--   reverse_expense 抬头那一段(FIN-22 / EQP-1b-iii / CAPEX-1 的两条规矩与它们的不对称)说的就是这里的算术,读那里。
-- ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q33 · Q34,Tim):第二个参数从此是【冲销的理由】—— 空白按名拒
--   EXPENSE_REVERSAL_REASON_REQUIRED|<单号>(两个调用方先各自拒过一次;这一道让将来任何一条新路都绕不过它)。
--   理由、时刻与人写在【被冲掉的那一张】上(reversal_reason / reversed_at / reversed_by,与 status 同一句 UPDATE);
--   镜像单的 notes 回到只有 'REVERSAL: <原单号>' 一句机器字 —— 人写的话不再和机器字挤在一列里(AT1D1 那一族)。
--   电费单的撤回传它自己的理由,不加前缀(Q34;分摊那一侧另在 electricity_allocation_reversals.reason 上留一份)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE OR REPLACE FUNCTION public.reverse_expense_internal(p_expense_id uuid, p_memo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        expenses%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_mirror_code text;
    v_je          jsonb;
    -- EQP-1b-iii:追加模式那一笔的成本明细,以及它挂着的那张资产卡
    v_entry       record;
    v_asset       record;
    v_sum         numeric;   -- 未冲销明细之和(推导出来的那一侧)
    v_after       numeric;   -- 退回之后的表头(被维护的那一侧)
    v_settled     numeric;   -- MES-5b-2:经付款核销掉的(付款币种 = 单据币种)
    v_prepaid     numeric;   -- MES-5b-2:冲抵上去的预付款
    v_reason      text := NULLIF(btrim(COALESCE(p_memo, '')), '');   -- MES-6a-1(F3):冲销的理由
BEGIN
    SELECT * INTO v_orig FROM expenses WHERE id = p_expense_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', p_expense_id;
    END IF;
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', v_orig.code
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_expense IS NOT NULL THEN
        RAISE EXCEPTION 'EXPENSE_ALREADY_REVERSED|%', v_orig.code;
    END IF;
    -- FIN-22:挂着固定资产台账行的资本性支出不许冲销 —— 冲掉它会留下无对价的
    -- 资产(或者说资产背后那笔应付蒸发)。先处置资产,或走人工分录改正。
    IF EXISTS (SELECT 1 FROM fixed_assets fa WHERE fa.expense_id = p_expense_id) THEN
        RAISE EXCEPTION 'EXPENSE_HAS_ASSET|%', v_orig.code;
    END IF;
    -- ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q24,Tim):【经付款结过的费用单不许冲】—— 每一种费用单都一样(普通、报销、医疗、冲抵、电费分摊、资本)。
    --   冲掉它,应付清单上那一行消失,而指着它的核销行原样留着:2000 借方多出那笔钱、清单读 0,差额落进 list_ledger_reconciliation
    --   的 unexplained(Step 0 §1.4)。先经付款冲销申请把那笔付款冲掉,再冲这张单 —— reverse_freight_document 的 FREIGHT_HAS_SETTLEMENT 先例。
    --   ★ 预付款冲抵同一个形状(ap_open_items 把它算作已结):冲抵一经落下就不可改(prepayment_applications 不可变),没有撤回它的路,
    --   所以这里同样按名拒,并在 docs/known-issues.md 记下(MES5B2-PREPAYMENT-APPLIED-EXPENSE-NOT-REVERSIBLE)。
    SELECT COALESCE(sum(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.expense_id = p_expense_id;
    IF v_settled > 0 THEN
        RAISE EXCEPTION 'EXPENSE_HAS_SETTLEMENT|%|%|%', v_orig.code, v_settled, v_orig.currency
          USING HINT = '这张费用单已经经付款结过 —— 先经付款冲销申请冲掉那笔付款,再冲销这张单';
    END IF;
    SELECT COALESCE(sum(ppa.amount_base), 0) INTO v_prepaid FROM prepayment_applications ppa WHERE ppa.expense_id = p_expense_id;
    IF v_prepaid > 0 THEN
        RAISE EXCEPTION 'EXPENSE_HAS_PREPAYMENT_APPLIED|%|%', v_orig.code, v_prepaid
          USING HINT = '这张费用单上冲抵过预付款,而冲抵撤不回 —— 冲销它会让应付清单与 2000 对不上';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1b-iii:【追加模式】的资本支出 —— 冲销它必须把成本退回去。
    -- 上面那条 FIN-22 的守卫只认【建卡的那一笔】(fixed_assets.expense_id),
    -- 追加进来的每一笔(运费、关税、安装,以及设备发票本身)都不是任何一张卡的
    -- 出生证,所以一律冲得掉 —— 而分录冲掉了、cost_base 却原样不动。
    -- 实测(EQP-1b-ii 的回滚探针):100,000 → 100,000,明细 2 行 → 2 行。
    -- 总账从此与台账不一致,而【折旧读的是台账】。
    --
    -- 【为什么这里不加一列"这条明细已冲销"】那件事已经记在 expenses.status 上了,
    -- 而 fixed_asset_cost_entries 对 expense_id 是 UNIQUE —— 一条明细对一笔支出,
    -- 所以"这条明细还算不算数"= "它那笔支出冲了没有",一个事实一个地方。
    -- 本仓库对"已冲销"的既有写法正是这样一个 JOIN(ap_open_items 与
    -- apply_prepayment 都是),invoice_lines 那个冗余列是被【部分索引的 WHERE
    -- 引用不了另一张表】逼出来的,这里没有那个约束,也就不该抄那半代价。
    SELECT fce.id AS entry_id, fce.asset_id, fce.amount_base
      INTO v_entry
      FROM fixed_asset_cost_entries fce
     WHERE fce.expense_id = p_expense_id;

    IF FOUND THEN
        SELECT fa.code, fa.in_service_date, fa.status AS asset_status
          INTO v_asset
          FROM fixed_assets fa
         WHERE fa.id = v_entry.asset_id
           FOR UPDATE;

        -- 【与 record_expense 同一个铰链,方向相反】那边拒绝往已投用的资产上
        -- 【加】钱(ASSET_ALREADY_IN_SERVICE),理由是"已经提过的那几期会全错,
        -- 而它们已经过账、可能已经锁进期间"。【减】钱撞的是同一堵墙,所以判据
        -- 用同一句 in_service_date IS NOT NULL —— 一个铰链管两个方向。
        -- 【为什么不改成"提过折旧没有"】那是【第二个、更晚】的事实:一台已投用
        -- 但月结还没跑的资产会因此今天准冲、明天不准,而资产本身什么都没变;
        -- 而且加钱那边照旧拒,两个方向就不对称了。一个可判定的规则,不是两个。
        -- 【码另起一个,不复用 ASSET_ALREADY_IN_SERVICE】动作不同、话也不同:
        -- 那一句讲的是"投用后的追加是一次会计判断",对冲销是答非所问。
        IF v_asset.in_service_date IS NOT NULL THEN
            RAISE EXCEPTION 'ASSET_IN_SERVICE_COST_LOCKED|%|%|%',
                v_orig.code, v_asset.code, v_asset.in_service_date
              USING HINT = '这台资产已经投用,它的成本不能再被冲回 —— 这需要一次财务上的裁定';
        END IF;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Expense reversal ' || v_orig.code);

    -- 镜像开支单(同形状、status 'posted'、挂冲销分录、不带核销行)。
    -- 镜像行只是冲销的记录凭证,不是新的应付单据 —— ap_open_items 里按
    -- "被别的开支单指为 reversed_by_expense" 排除它。
    v_year := EXTRACT(YEAR FROM CURRENT_DATE)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || v_year::text || '-%';
    v_mirror_code := document_type_prefix('expense') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 【EQP-1b-iii · D3:employee_id 要抄,purchase_order_line_id 【不要】抄】
    -- 抄 employee_id:PAYEE-1a 加了这一列并放宽了 expenses_counterparty_shape
    -- (unpaid 必须【恰好】挂一个往来对象),但镜像 INSERT 没跟着改 —— 于是冲销
    -- 一张【欠员工】的报销单会撞出一条裸的 CHECK 违例。这是那一列缺席造成的,
    -- 不是别的。
    -- 不抄 purchase_order_line_id:镜像单是【记录凭证】,不是第二张账单。它一带上
    -- 那一列就会立刻重新占住那条采购单行,而"冲销之后行重新可计费"是 EQP-1b-ii
    -- 明文的行为(fixture 105 的 F3③ 钉着它)。那一列的列注释里点名交代过这件事,
    -- 交代的对象就是这一刀 —— 所以这里把两句话并排写下:一列抄,一列不抄。
    -- 【已逐列核对过一遍,不是只看这两列】expenses 共 20 列,镜像显式写 15 列;
    -- 另外 5 列:status(默认 posted,镜像是在册凭证)、reversed_by_expense(NULL,
    -- 镜像自己没被冲)、created_at(now())——三条都是有意的;employee_id 是唯一
    -- 的漏抄;purchase_order_line_id 是唯一有意不抄的。
    INSERT INTO expenses (id, code, expense_date, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          employee_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, CURRENT_DATE,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.payment_status, v_orig.bank_account_code, v_orig.supplier_id,
            v_orig.employee_id,
            v_orig.payee_name,
            'REVERSAL: ' || v_orig.code,
            (v_je->>'reversal_id')::uuid, auth.uid());

    -- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Q4:冲销是整张单):镜像单带着原单的【每一行】—— 科目 + 净额(原币与本位币),
    --   不带税码、税为 0,与镜像表头一致(镜像表头一向只抄净额,不带税码;那张冲销分录才是把税翻回去的东西)。
    --   表头合计 = 各行之和由 guard_expense_totals 在提交时照样强制。
    INSERT INTO expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base, notes, created_by)
    SELECT v_mirror_id, l.line_no, l.account_code, l.amount_ccy, l.amount_base, NULL, auth.uid()
      FROM expense_lines l
     WHERE l.expense_id = p_expense_id;

    UPDATE expenses
    SET status = 'reversed', reversed_by_expense = v_mirror_id,
        reversal_reason = v_reason, reversed_at = now(), reversed_by = auth.uid()
    WHERE id = p_expense_id;

    -- ── EQP-1b-iii:把成本退回去,并【当场核对】──────────────────────────────
    -- 顺序要紧:上面那句 UPDATE 已经把原单置为 reversed,所以下面那个求和
    -- 【天然排除】了它 —— 判据读的是"未冲销明细之和",不是"减掉一笔之后应该是多少"。
    IF v_entry.entry_id IS NOT NULL THEN
        UPDATE fixed_assets
           SET cost_base = cost_base - v_entry.amount_base
         WHERE id = v_entry.asset_id
        RETURNING cost_base INTO v_after;

        -- 【两侧能不能分开动?能 —— 所以这是一条真检查,不是装饰】
        -- 左边是被 record_expense 逐笔累加维护的表头(一个缓存);
        -- 右边是从明细现算的和。两者由不同的代码路径产生,drift 是可能的,
        -- 而这正是 OPS-17 对 ties/balanced 那类自检提的那个问题:
        -- "要怎样它们才会不相等?" —— 这里答得出来。
        SELECT COALESCE(SUM(fce.amount_base), 0) INTO v_sum
          FROM fixed_asset_cost_entries fce
          JOIN expenses e ON e.id = fce.expense_id
         WHERE fce.asset_id = v_entry.asset_id
           AND e.status = 'posted';

        IF v_after <> v_sum THEN
            RAISE EXCEPTION 'ASSET_COST_LEDGER_DIVERGED|%|%|%',
                v_asset.code, v_after, v_sum;
        END IF;
    END IF;

    -- 【两条 CHECK 都不会被这次减法撞到,而这是可以证明的,不是碰巧】
    --   fixed_assets_cost_base_check      cost_base > 0
    --   fixed_assets_residual_below_cost  residual_base < cost_base
    -- 能被冲销的只有【追加】那些笔(建卡那一笔由 EXPENSE_HAS_ASSET 拦着),
    -- 而 residual_base 只在建卡时写入一次(全库只有 record_expense 写它),
    -- 当时就校验过 residual < 建卡金额。把追加全部冲光,表头也还剩建卡金额,
    -- 于是 cost_base ≥ 建卡金额 > residual_base ≥ 0,两条恒成立。
    RETURN jsonb_build_object(
        'reversal_expense_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code',
        'reversal_journal_id', v_je->>'reversal_id',
        'asset_id', v_entry.asset_id,
        'asset_cost_base_after', v_after,
        'reversal_reason', v_reason
    );
END;
$function$;

-- db/functions/post_electricity_allocation.sql
-- MES-5a-2(2026-10-08,MES-0 Q26;MES-5a Step 0 Q24 · Q27 · Q28,Tim):【一张电费单过账 —— 它就是这张账单【唯一】的一笔】。
--   门:module.finance.edit(分摊、汇出、冲抵加工成本用的同一个码;线上 admin · finance)。没有新的审批(Q29):这是一张账单的
--   入账,不是一张等人批的单据;未付的那一张之后走既有的付款申请(1,000 分级)。
--   一笔事务里(Q24):
--     ① 规则全部来自 electricity_allocation_compute(预览用的同一支;它拒的这里一样拒 —— 外币、时间段重叠、量到的超过账单……)。
--        之前先拿一把咨询锁,于是两次同时过账不会都看见"不重叠"。
--     ② 记一张费用单(EXP-YYYY-NNNN,编号与 record_expense / relieve_processing_accruals 同一套;科目 5110 —— 这张单的名义科目,
--        与冲抵加工成本那一路同一个;真正的借方在下面那张分录里);币种 = 本位币【从数据读】(currencies.is_base,不写字面量 —— Q35),本位币对自己的汇率是 1。
--     ③ 那张分录(日期 = 账单日):借 2200 各炉之和 · 借 6200 余数 · 贷 应付 2000(未付)或银行(已付)账单全额。
--     ④ 每一炉一条实际电费成本行(录入即照旧借 5110 / 贷 2200),落库时就标成已结(remitted_at = 账单日、remitted_journal_entry_id = ③)——
--        于是谁都改不了它的额、删不掉它(guard_cost_entry_settled);一行 electricity_allocation_lines 指着它。
--     ⑤ 这些炉上手敲的、还没结过的电费估计:标 relieved_at = 账单日、relief_expense_id = ② 并【软删】—— 一炉不再同时带着估计与实际
--        (软删照旧过冲销分录 借 2200 / 贷 5110)。被覆盖之外的炉上的估计一条都不碰(Q26)。
--   拒:账单日没给 / 在将来;账单号没给;未付却没有供应商(SUPPLIER_REQUIRED_FOR_UNPAID)。
--   返回 {allocation_id, expense_id, expense_code, journal_code, runs, relieved}。
--   ★ MES-5b-2(2026-10-09,MES-5b Step 0 Q28 · Q26 · Q23,Tim):① 过账也要 module.finance.view —— 它不再比自己的预览少问一个码
--     (MES-5a-2 close-out §2 f;线上持 edit 的都持 view,没有人因此失去这一步);② 结算戳只许经财务函数写:写已结的实际行与冲掉估计之前
--     设事务级标记 evoltrya.cost_settlement_ctx,用毕即清(guard_cost_entry_settled);③ "一炉只分一次"改成"一炉最多在一张没撤回的分摊里"
--     (compute 与 guard_electricity_line_one_live_allocation)。一张分摊的撤回:reverse_electricity_allocation。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.

CREATE OR REPLACE FUNCTION public.post_electricity_allocation(p_period_from date, p_period_to date, p_bill_date date, p_invoice_ref text, p_bill_amount numeric, p_bill_kwh numeric, p_currency text, p_payment_status text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v          jsonb;
    v_base     text := base_currency_code();
    v_ref      text := NULLIF(btrim(COALESCE(p_invoice_ref, '')), '');
    v_exp_id   uuid := gen_random_uuid();
    v_alloc_id uuid := gen_random_uuid();
    v_code     text;
    v_je       jsonb;
    v_je_id    uuid;
    v_run      jsonb;
    v_entry    uuid;
    v_ids      uuid[];
    v_n        int := 0;
BEGIN
    PERFORM require_permission('module.finance.edit');
    PERFORM require_permission('module.finance.view');
    IF p_bill_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DATE_REQUIRED';
    END IF;
    IF p_bill_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_bill_date, CURRENT_DATE;
    END IF;
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'ELECTRICITY_INVOICE_REF_REQUIRED';
    END IF;
    IF p_payment_status = 'unpaid' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;
    IF p_supplier_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM suppliers s WHERE s.id = p_supplier_id) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', p_supplier_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('electricity_allocation')::bigint);
    v := electricity_allocation_compute(p_period_from, p_period_to, p_bill_amount, p_bill_kwh, p_currency, p_payment_status, p_bank_account);

    -- ② 费用单编号:与 record_expense / relieve_processing_accruals 同一套(按年咨询锁 + 年内递增)
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || EXTRACT(YEAR FROM p_bill_date)::integer::text)::bigint);
    SELECT document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_bill_date)::integer::text || '-' ||
           LPAD((COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1)::text, 4, '0')
      INTO v_code
      FROM expenses
     WHERE code LIKE document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_bill_date)::integer::text || '-%';

    -- ③ 那张分录(规则算出来的那几行,原样)
    v_je := post_journal_entry(p_bill_date, 'Electricity bill ' || v_code || ' ' || v_ref,
                               'expense', v_exp_id, v -> 'journal');
    v_je_id := (v_je ->> 'entry_id')::uuid;

    INSERT INTO expenses (id, code, expense_date, amount_ccy, currency, fx_rate, amount_base, payment_status,
                          bank_account_code, supplier_id, payee_name, notes, journal_entry_id, created_by)
    VALUES (v_exp_id, v_code, p_bill_date, p_bill_amount, v_base, 1, p_bill_amount, p_payment_status,
            CASE WHEN p_payment_status = 'paid' THEN p_bank_account END, p_supplier_id, NULLIF(btrim(COALESCE(p_payee_name, '')), ''),
            'Electricity bill ' || v_ref || ' · ' || p_period_from || ' – ' || p_period_to
              || CASE WHEN NULLIF(btrim(COALESCE(p_notes, '')), '') IS NOT NULL THEN ' · ' || btrim(p_notes) ELSE '' END,
            v_je_id, auth.uid());
    -- ★ EXPENSE-MULTILINE-1:这张单的那一行 —— 名义科目(电费的 5xxx)与账单金额,与表头合计相等(guard_expense_totals)。
    INSERT INTO expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base, created_by)
    VALUES (v_exp_id, 1, fin_cost_account('electricity'), p_bill_amount, p_bill_amount, auth.uid());

    INSERT INTO electricity_allocations (id, period_from, period_to, bill_date, invoice_ref, supplier_id, payee_name, currency,
        bill_amount, bill_kwh, price_per_kwh, metered_kwh, allocated_kwh, shared_pool_kwh, unallocated_metered_kwh, unmetered_kwh,
        allocated_amount, overhead_amount, relieved_estimate_amount, relieved_estimate_count, payment_status, bank_account_code,
        expense_id, journal_entry_id, notes)
    VALUES (v_alloc_id, p_period_from, p_period_to, p_bill_date, v_ref, p_supplier_id, NULLIF(btrim(COALESCE(p_payee_name, '')), ''),
        v ->> 'currency', p_bill_amount, p_bill_kwh, (v ->> 'price_per_kwh')::numeric, (v ->> 'metered_kwh')::numeric,
        (v ->> 'allocated_kwh')::numeric, (v ->> 'shared_pool_kwh')::numeric, (v ->> 'unallocated_metered_kwh')::numeric,
        (v ->> 'unmetered_kwh')::numeric, (v ->> 'allocated_amount')::numeric, (v ->> 'overhead_amount')::numeric,
        (v ->> 'relieved_estimate_amount')::numeric, (v ->> 'relieved_estimate_count')::int, p_payment_status,
        CASE WHEN p_payment_status = 'paid' THEN p_bank_account END, v_exp_id, v_je_id, NULLIF(btrim(COALESCE(p_notes, '')), ''));

    -- ④ 每一炉一条已结的实际电费成本行 + 一行分摊(结算戳只许经财务函数写 —— 标记用毕即清,在 ⑤ 之后)
    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    FOR v_run IN SELECT x FROM jsonb_array_elements(v -> 'runs') x LOOP
        INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes, created_by, updated_by,
                                             remitted_at, remitted_journal_entry_id)
        VALUES ((v_run ->> 'run_id')::uuid, 'electricity', (v_run ->> 'amount')::numeric, false,
                'Electricity bill ' || v_ref || ' (' || v_code || ') · ' || (v_run ->> 'kwh') || ' kWh · '
                  || CASE v_run ->> 'basis' WHEN 'recorded_energy' THEN 'split by recorded run energy' ELSE 'split by run time' END,
                auth.uid(), auth.uid(), p_bill_date, v_je_id)
        RETURNING id INTO v_entry;
        INSERT INTO electricity_allocation_lines (allocation_id, run_id, equipment_id, basis, run_energy_kwh, run_minutes, weight, share,
                                                  machine_kwh, kwh, amount, cost_entry_id)
        VALUES (v_alloc_id, (v_run ->> 'run_id')::uuid, (v_run ->> 'equipment_id')::uuid, v_run ->> 'basis',
                (v_run ->> 'own_kwh')::numeric, (v_run ->> 'minutes')::numeric, (v_run ->> 'weight')::numeric,
                (v_run ->> 'share')::numeric, (v_run ->> 'machine_kwh')::numeric, (v_run ->> 'kwh')::numeric,
                (v_run ->> 'amount')::numeric, v_entry);
        v_n := v_n + 1;
    END LOOP;

    -- ⑤ 冲掉被覆盖的炉上那几条估计(锁住它们,确认它们仍然没结过 —— 与预览之间被别人结掉的,拒而不是悄悄少冲)
    SELECT array_agg((x ->> 'id')::uuid) INTO v_ids FROM jsonb_array_elements(v -> 'estimates') x;
    IF v_ids IS NOT NULL THEN
        PERFORM 1 FROM processing_cost_entries e WHERE e.id = ANY (v_ids) FOR UPDATE;
        IF EXISTS (SELECT 1 FROM processing_cost_entries e WHERE e.id = ANY (v_ids)
                     AND (e.deleted_at IS NOT NULL OR e.remitted_at IS NOT NULL OR e.relieved_at IS NOT NULL)) THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|electricity';
        END IF;
        UPDATE processing_cost_entries
           SET relieved_at = p_bill_date, relief_expense_id = v_exp_id, deleted_at = now(), updated_by = auth.uid()
         WHERE id = ANY (v_ids);
    END IF;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN jsonb_build_object('allocation_id', v_alloc_id, 'expense_id', v_exp_id, 'expense_code', v_code,
                              'journal_code', v_je ->> 'code', 'runs', v_n, 'relieved', COALESCE(array_length(v_ids, 1), 0));
END;
$function$;

-- db/functions/relieve_processing_accruals.sql
-- 真实发票冲抵【估算】应计(FIN-6 C)。一张水电/燃气账单盖住整月多个 run 的
-- 估算行 —— 【多对一,不要求一一对应】(C3)。分录:
--   借 2200 被清的应计合计;差额(实际 − 估算)借/贷该成本类型的 5xxx 行 ——
--   估算与实际的差落进【发票所在期间】的损益(既定);
--   贷 银行(已付)或 贷 2000 应付(挂账,须给供应商 —— 之后走正常收付款核销)。
-- 【差异不回摊到批次】(既定,写在迁移头):化验改的是批次自己的料价,回摊天经地义;
-- 水电是横跨多个 run 的公摊,它的差异不属于任何单一批次。本函数【一个字都不碰】
-- 批次成本、存货计价、COGS —— fixture 逐项断言。
-- 【结构性防重复】发票只从这里进账;record_expense 早已拒收 5xxx(ACCOUNT_NOT_EXPENSE,
-- 5xxx 是 cogs 型),被清过的应计行不能再清(COST_ENTRY_ALREADY_SETTLED)。
-- 一次冲抵限一个 cost_type(账单本来就是按类型来的;差异报表按类型分组)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.
--
-- MES-5b-2(2026-10-09,MES-5a Step 0 Q35 · MES-5b Step 0 Q21 · Q26,Tim):① 费用单的币种不再写死成 SGD 字面量(汇率 1)—— 读 base_currency_code()
--   (currencies.is_base;本位币对自己的汇率是 1)。关掉 MES5A2-RELIEVE-SGD-LITERAL。② 盖冲抵戳之前设事务级标记
--   evoltrya.cost_settlement_ctx(结算戳只许经财务函数改 —— guard_cost_entry_settled),用毕即清。③ 冲销这张费用单(reverse_expense)
--   会把它冲抵掉的估计放回"未结",于是它们能再被冲抵一次(F2)。

CREATE OR REPLACE FUNCTION public.relieve_processing_accruals(p_entry_ids uuid[], p_actual_amount numeric, p_expense_date date, p_payment_status text DEFAULT 'paid'::text, p_bank_account text DEFAULT NULL::text, p_supplier_id uuid DEFAULT NULL::uuid, p_payee_name text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_accrued numeric := 0;
    v_type    text;
    v_n int := 0;
    v_e record;
    v_var numeric;
    v_bank text;
    v_lines jsonb;
    v_je jsonb;
    v_expense_id uuid := gen_random_uuid();
    v_code text;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_entry_ids IS NULL OR array_length(p_entry_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;
    IF p_actual_amount IS NULL OR p_actual_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_payment_status NOT IN ('paid','unpaid') THEN
        RAISE EXCEPTION 'PAYMENT_STATUS_INVALID|%', COALESCE(p_payment_status, '?');
    END IF;
    IF p_payment_status = 'unpaid' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;
    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):这里直接写一张费用单(不经 record_expense),记的同样是【已经发生】的一张发票(Tim Batch B Q6),日期晚于今天按名拒。
    IF p_expense_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|expense|%|%', p_expense_date, CURRENT_DATE;
    END IF;

    FOR v_e IN SELECT * FROM processing_cost_entries WHERE id = ANY (p_entry_ids) FOR UPDATE
    LOOP
        IF v_e.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'COST_ENTRY_INVALID|%', v_e.id; END IF;
        IF NOT v_e.is_estimate THEN RAISE EXCEPTION 'COST_ENTRY_NOT_ESTIMATE|%', v_e.cost_type; END IF;
        IF v_e.remitted_at IS NOT NULL OR v_e.relieved_at IS NOT NULL THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|%', v_e.cost_type;
        END IF;
        IF v_type IS NULL THEN v_type := v_e.cost_type;
        ELSIF v_type <> v_e.cost_type THEN
            RAISE EXCEPTION 'RELIEF_MIXED_COST_TYPES|%|%', v_type, v_e.cost_type;
        END IF;
        v_accrued := round(v_accrued + v_e.amount_base, 2);
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_accrued <= 0 THEN RAISE EXCEPTION 'NO_LINES'; END IF;

    IF p_payment_status = 'paid' THEN
        v_bank := COALESCE(p_bank_account, '1000');
        IF v_bank NOT IN ('1000','1010') THEN RAISE EXCEPTION 'BANK_INVALID|%', v_bank; END IF;
    END IF;

    -- 借 2200 清应计;差额进当期 5xxx;贷 银行/应付 记实际
    v_var := round(p_actual_amount - v_accrued, 2);
    v_lines := jsonb_build_array(jsonb_build_object(
        'account_code', '2200', 'side', 'debit', 'currency', base_currency_code(),
        'amount_ccy', v_accrued, 'line_memo', 'clear accrued ' || v_type));
    IF v_var > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', v_var,
            'line_memo', 'estimate-to-actual variance');
    ELSIF v_var < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', fin_cost_account(v_type),
            'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', -v_var,
            'line_memo', 'estimate-to-actual variance');
    END IF;
    v_lines := v_lines || jsonb_build_object(
        'account_code', CASE WHEN p_payment_status = 'paid' THEN v_bank ELSE '2000' END,
        'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', p_actual_amount);

    -- 单据号:与 record_expense 同一套(advisory lock + 年内递增)
    PERFORM pg_advisory_xact_lock(hashtext('expense_code_' || EXTRACT(YEAR FROM p_expense_date)::integer::text)::bigint);
    SELECT document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-' ||
           LPAD((COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1)::text, 4, '0')
    INTO v_code
    FROM expenses
    WHERE code LIKE document_type_prefix('expense') || '-' || EXTRACT(YEAR FROM p_expense_date)::integer::text || '-%';
    v_je := post_journal_entry(p_expense_date, 'Expense ' || v_code || ' ' || fin_cost_account(v_type),
                               'expense', v_expense_id, v_lines);

    -- 发票立成正常开支单据:挂账的走既有收付款核销;科目 = 该成本类型的 5xxx
    INSERT INTO expenses (id, code, expense_date, amount_ccy, currency, fx_rate,
                          amount_base, payment_status, bank_account_code, supplier_id,
                          payee_name, notes, journal_entry_id, created_by)
    VALUES (v_expense_id, v_code, p_expense_date, p_actual_amount, base_currency_code(), 1,
            p_actual_amount, p_payment_status, v_bank, p_supplier_id,
            p_payee_name, p_notes, (v_je->>'entry_id')::uuid, auth.uid());
    -- ★ EXPENSE-MULTILINE-1:这张单的那一行 —— 该成本类型的 5xxx 与实际金额,与表头合计相等(guard_expense_totals)。
    INSERT INTO expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base, created_by)
    VALUES (v_expense_id, 1, fin_cost_account(v_type), p_actual_amount, p_actual_amount, auth.uid());

    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries
    SET relieved_at = p_expense_date, relief_expense_id = v_expense_id
    WHERE id = ANY (p_entry_ids);
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN jsonb_build_object('expense_id', v_expense_id, 'expense_code', v_code,
        'journal_code', v_je->>'code', 'cost_type', v_type,
        'accrued_cleared', v_accrued, 'actual', p_actual_amount, 'variance', v_var, 'entries', v_n);
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_prepayment(p_purchase_order_id uuid, p_inbound_batch_id uuid, p_amount numeric, p_notes text DEFAULT NULL::text, p_expense_id uuid DEFAULT NULL::uuid, p_release_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user        uuid := auth.uid();
    v_base        text := base_currency_code();
    v_po          record;
    v_batch       record;
    v_exp         record;
    v_prepaid     numeric;   -- Σ 已付到该单的预付,本位币
    v_prepaid_ccy numeric;   -- Σ 同上,按【采购单币种】
    v_applied     numeric;   -- Σ 已冲抵,本位币
    v_available   numeric;
    v_dep_ccy     text;      -- 定金的币种 = 采购单的币种
    v_dep_rate    numeric;   -- 定金的加权平均汇率
    v_pay_ccy     text;      -- 被解除应付的计价币种
    v_pay_rate    numeric;   -- 被解除应付的【入账】汇率
    v_value       numeric;
    v_settled     numeric;
    v_open        numeric;
    v_dep_ccy_amt numeric;   -- 本次消耗的定金,按定金币种
    v_dep_base    numeric;   -- 本次消耗的定金,本位币(= 落库的 amount_base)
    v_pay_base    numeric;   -- 本次解除的应付,本位币
    v_realised    numeric;
    v_dest_code   text;      -- 目的地单据的编号(分录摘要用)
    v_lines       jsonb;
    v_app_id      uuid := gen_random_uuid();
    v_je          jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ════════════════════════════════════════════════════════════════════════
    -- EQP-1c-b(X1):冲抵日【必填,永不默认】。
    -- 【它决定一个期间】这笔分录借 2000 / 贷 1300,过在哪一天就落在哪个月。
    -- 此前它是 CURRENT_DATE,而 AGENTS.md 那条规矩点名的正是这种默认:
    -- 今天的日期【永远撞不上 PERIOD_LOCKED】,于是"把日期留空"变成一条
    -- 比"填对一个已关期间的日期"更顺的路 —— 这条路奖励留空。
    -- 【为什么用"带默认值 + 按名拒",而不是让它位置上必填】FIN-10 那十一个函数
    -- 立的先例:老调用方少传一个参数时,应当拿到一句【人话】,而不是
    -- "function does not exist"。破窗期间生产跑的是旧代码,它就落在这一句上。
    IF p_release_date IS NULL THEN
        RAISE EXCEPTION 'RELEASE_DATE_REQUIRED';
    END IF;

    -- 目的地【恰好一个】。表上那条 CHECK 是兜底(直插也逃不掉);这里按名拒绝,
    -- 因为本仓库的规矩是"拒绝要有名字,屏幕上不出现裸的约束违例"。
    IF num_nonnulls(p_inbound_batch_id, p_expense_id) <> 1 THEN
        RAISE EXCEPTION 'PREPAY_DESTINATION_INVALID|%',
            num_nonnulls(p_inbound_batch_id, p_expense_id)
          USING HINT = '一次冲抵恰好冲一个目的地:一张进料批次,或一张费用单';
    END IF;

    SELECT po.id, po.code, po.supplier_id, po.status, po.approval_status, po.currency
    INTO v_po
    FROM purchase_orders po
    WHERE po.id = p_purchase_order_id AND po.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PO_NOT_FOUND|%', COALESCE(p_purchase_order_id::text, '?');
    END IF;
    IF v_po.status = 'cancelled' THEN
        RAISE EXCEPTION 'PO_CANCELLED|%', v_po.code;
    END IF;
    -- APR-2:未获批的采购单不能动钱
    IF v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- 定金那一侧。
    -- 【币种】1300 由 record_payment 按【单据(= 采购单)币种】归集(FIN-16 的
    -- v_pre 逐币种发行控制科目行),所以定金的币种就是采购单的币种。
    -- 【汇率】复用 FIN-16 已经记下来的结果,不重算:
    --     加权平均 = Σ allocated_base / Σ allocated_ccy
    -- ════════════════════════════════════════════════════════════════════════
    v_dep_ccy := v_po.currency;

    SELECT COALESCE(SUM(pa.allocated_base), 0), COALESCE(SUM(pa.allocated_ccy), 0)
    INTO v_prepaid, v_prepaid_ccy
    FROM payment_allocations pa
    JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
    WHERE pa.purchase_order_id = p_purchase_order_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【可用预付这条守卫留在本位币空间 —— 这是刻意的,不要"顺手"改成币种空间】
    -- amount_ccy 在那一条 2026-07-31 的历史行上是 NULL(FIN-0 翻转之前记的,
    -- 刻意不回填)。一旦改成 Σ amount_ccy,那一行会被【静默跳过】,于是
    -- PO-2026-0001 上一笔【已经全额冲抵完】的 30,000 定金会读成"还有 30,000 可用",
    -- 冲第二次而没有任何东西反对。amount_base 在那一行上是有值的,所以本位币
    -- 空间数得对。币种是【记下来、过账用】的,不用来决定还剩多少。
    -- fixture 103b 的 H 臂把这一条钉死了。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(SUM(ppa.amount_base), 0) INTO v_applied
    FROM prepayment_applications ppa
    WHERE ppa.purchase_order_id = p_purchase_order_id;

    v_available := round(v_prepaid - v_applied, 2);
    IF v_prepaid_ccy > 0 THEN
        v_dep_rate := v_prepaid / v_prepaid_ccy;
    END IF;
    IF v_dep_rate IS NULL OR v_dep_rate <= 0 THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', 0, p_amount;
    END IF;

    -- ── 目的地:两种单据,各自解出【计价币种】、【入账汇率】与【敞口】───────
    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT ib.id, ib.code, ib.supplier_id, ib.quantity, ib.unit_price
        INTO v_batch
        FROM inbound_batches ib
        WHERE ib.id = p_inbound_batch_id AND ib.deleted_at IS NULL;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
        IF v_batch.unit_price IS NULL THEN
            RAISE EXCEPTION 'INBOUND_UNPRICED|%', v_batch.code;
        END IF;
        IF v_batch.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_batch.code;
        END IF;

        -- 【进料应付恒以本位币计价】reprice_inbound_batch(set_inbound_unit_price
        -- 只是它的转发)按 base_currency_code() 过账 2000,ap_open_items 的进料支
        -- 也把 currency 取成 currencies.is_base。线上 9 条 source_type='purchase'
        -- 的 2000 行,fx_rate 无一例外是 1 —— 即当日的本位币。
        v_pay_ccy  := v_base;
        v_pay_rate := 1;

        v_value := round(v_batch.quantity * v_batch.unit_price, 2);
        SELECT COALESCE(SUM(pa.allocated_base), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.inbound_batch_id = p_inbound_batch_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
              WHERE ppa.inbound_batch_id = p_inbound_batch_id), 0);
        v_open := round(v_value - v_settled, 2);
        v_dest_code := v_batch.code;
    ELSE
        SELECT e.id, e.code, e.currency, e.fx_rate, e.amount_ccy, e.tax_ccy,
               e.supplier_id, e.status, e.payment_status
        INTO v_exp
        FROM expenses e WHERE e.id = p_expense_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'EXPENSE_NOT_FOUND|%', COALESCE(p_expense_id::text, '?');
        END IF;
        IF v_exp.status <> 'posted' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_POSTED|%|%', v_exp.code, v_exp.status;
        END IF;
        -- 已付的费用单没有应付可解除 —— 那笔钱当时就走了银行。
        IF v_exp.payment_status <> 'unpaid' THEN
            RAISE EXCEPTION 'EXPENSE_NOT_PAYABLE|%', v_exp.code
              USING HINT = '只有挂账(unpaid)的费用单才有应付可以让定金去冲';
        END IF;
        -- 冲销镜像单只是记录凭证,不是新的应付单据(ap_open_items 也把它排除)。
        IF EXISTS (SELECT 1 FROM expenses o WHERE o.reversed_by_expense = v_exp.id) THEN
            RAISE EXCEPTION 'EXPENSE_IS_REVERSAL_MIRROR|%', v_exp.code;
        END IF;
        IF v_exp.supplier_id IS DISTINCT FROM v_po.supplier_id THEN
            RAISE EXCEPTION 'SUPPLIER_MISMATCH|%|%', v_po.code, v_exp.code;
        END IF;

        -- 费用单的应付以【单据自己的币种】计价(record_expense 按 p_currency 贷 2000),
        -- 入账汇率就是单据上冻住的那一个。敞口因此在单据币种空间递减 ——
        -- 与 ap_open_items 的费用支同一个口径。
        v_pay_ccy  := v_exp.currency;
        v_pay_rate := v_exp.fx_rate;

        SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.expense_id = p_expense_id;
        v_settled := v_settled + COALESCE(
            (SELECT SUM(ppa.amount_ccy) FROM prepayment_applications ppa
              WHERE ppa.expense_id = p_expense_id), 0);
        -- AP-RECON-1:应付额是【净额 + 进项税】(CLAIM-GST-1 起读落库的 amount_ccy + tax_ccy)——
        -- 只认净额的上限会让定金冲不掉那张单上的税,而那一笔税就挂在 2000 上没人能动。
        v_open := round(v_exp.amount_ccy + v_exp.tax_ccy - v_settled, 2);
        v_dest_code := v_exp.code;
    END IF;

    -- p_amount 以【被解除应付的币种】陈述(进料支即本位币,与本刀之前逐字一致)
    IF p_amount > v_open THEN
        RAISE EXCEPTION 'EXCEEDS_OPEN|%|%', v_open, p_amount;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- R1 / R2 / R3 —— 判据是【定金币种】与【应付币种】的关系。
    -- 两条支路都【不读任何当日牌价】:两条腿都是历史入账,没有钱在动,
    -- 也就没有一次兑换需要定价。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_pay_ccy = v_dep_ccy THEN
        -- R1 单位对齐:付了 10,000 USD、欠 50,000 USD 的人,现在欠 40,000 USD。
        -- 已实现汇兑 = 同样这 A 个单位,按应付的入账汇率与按定金的加权汇率,
        -- 两个【历史】本位币值之差。
        v_dep_ccy_amt := p_amount;
        v_dep_base    := round(p_amount * v_dep_rate, 2);
        v_pay_base    := round(p_amount * v_pay_rate, 2);
    ELSIF v_pay_ccy = v_base OR v_dep_ccy = v_base THEN
        -- R2 价值对齐:两者恰有一个是本位币。按定金【自己的】汇率折出等值的
        -- 定金数量,于是两侧本位币值恒等,7100 恒为零。
        -- 【那个零是构造出来的,不是漏算的】1300 是 is_monetary = false:预付按
        -- 付款那天的汇率计量,此后永不重译。按它自己的汇率消耗它,不可能产生损益。
        v_pay_base    := round(p_amount * v_pay_rate, 2);
        v_dep_base    := v_pay_base;
        v_dep_ccy_amt := round(v_pay_base / v_dep_rate, 2);
    ELSE
        -- R3 两边都是外币且不同 —— 这才需要一次真正的换算,而这盘生意里它不存在。
        RAISE EXCEPTION 'PREPAY_TWO_FOREIGN_CURRENCIES|%|%', v_dep_ccy, v_pay_ccy
          USING HINT = '定金与应付是两种不同的外币 —— 请让其中一方以本位币开票';
    END IF;

    IF v_dep_ccy_amt IS NULL OR v_dep_ccy_amt <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF v_dep_base > v_available THEN
        RAISE EXCEPTION 'PREPAY_INSUFFICIENT|%|%', v_available, v_dep_base;
    END IF;

    v_realised := round(v_pay_base - v_dep_base, 2);

    -- 分录:钱早就出去了,这里只是科目之间的搬运。
    -- 【汇率逐行给成 base/ccy 的商】与 record_payment 同一个手法 —— 这样
    -- post_journal_entry 折出来的本位币值与上面算的逐分相等,分录不会因为
    -- 一次四舍五入而不平,R2 的"恒为零"也才真的是零。
    v_lines := jsonb_build_array(
        jsonb_build_object('account_code', '2000', 'side', 'debit',
                           'currency', v_pay_ccy, 'amount_ccy', p_amount,
                           'fx_rate', v_pay_base / p_amount),
        jsonb_build_object('account_code', '1300', 'side', 'credit',
                           'currency', v_dep_ccy, 'amount_ccy', v_dep_ccy_amt,
                           'fx_rate', v_dep_base / v_dep_ccy_amt,
                           'line_memo', 'Prepayment applied'));
    -- 借方合计 − 贷方合计:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)。
    -- 与 record_payment 的方向约定逐字一致。
    IF v_realised > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
            'currency', v_base, 'amount_ccy', v_realised, 'fx_rate', 1);
    ELSIF v_realised < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
            'currency', v_base, 'amount_ccy', -v_realised, 'fx_rate', 1);
    END IF;

    v_je := post_journal_entry(
        p_release_date,
        -- 【不要写 COALESCE(v_batch.code, v_exp.code)】没走到的那一支里,那个
        -- record 变量【从未被赋值】,读它的字段是一个错误(record ... is not
        -- assigned yet),不是 NULL —— COALESCE 救不了。实测撞过。
        'Prepayment applied ' || v_po.code || ' → ' || v_dest_code,
        'prepayment', v_app_id, v_lines);

    INSERT INTO prepayment_applications (id, purchase_order_id, inbound_batch_id, expense_id,
                                         amount_base, currency, amount_ccy,
                                         notes, journal_entry_id, created_by)
    VALUES (v_app_id, p_purchase_order_id, p_inbound_batch_id, p_expense_id,
            v_dep_base, v_pay_ccy, p_amount,
            p_notes, (v_je->>'entry_id')::uuid, v_user);

    RETURN jsonb_build_object(
        'application_id', v_app_id,
        'purchase_order_id', p_purchase_order_id,
        'inbound_batch_id', p_inbound_batch_id,
        'expense_id', p_expense_id,
        'currency', v_pay_ccy,
        'amount_ccy', p_amount,
        'amount_base', v_dep_base,
        'deposit_currency', v_dep_ccy,
        'deposit_amount_ccy', v_dep_ccy_amt,
        'deposit_rate', v_dep_rate,
        'realised_fx', v_realised,
        'journal_code', v_je->>'code',
        'prepaid_remaining', round(v_available - v_dep_base, 2)
    );
END;
$function$;

-- db/functions/guard_gst_switch.sql
-- GST-3:注册开关两个方向的闸。
-- 【开】登记号必须在册 —— IRAS 要求税务发票印它,而发票 PDF 在号码为空时
--   那一行【整条消失】(不是拒绝出票,是安静地不印)。空白字符串与 NULL 同罪:
--   判据要与【印出来的结果】一致,不是与列的可空性一致。
-- 【关】两条拒绝、两个【不同】的理由,不合并:
--   · 带税码的费用单 —— 机械事实:GST-2 让冲销把 tax_code 一起翻过去,
--     而未注册时带税码的行写不进去,于是关掉之后它们再也冲销不了;
--   · 在册的带税发票 —— 判断:它们冲销得了(税腿不带税码),但留下的状态
--     自相矛盾(账上报着某季供应额,公司却声称那一季未注册)。
--   合成一句会让机械的那一半被判断的那一半稀释。
-- 【为什么闸在库上,不在 server action 上】开关本来就是由 SQL 翻的,而
--   module.finance.edit 经 RLS 直接授予 UPDATE —— 只住在 action 里的闸
--   恰好挡不住会用它的那批人。与 trg_approvals_switch 同一个落点、同一个理由。
CREATE OR REPLACE FUNCTION public.guard_gst_switch()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n      integer;
    v_codes  text;
BEGIN
    -- ── 开:登记号必须先在册 ────────────────────────────────────────────────
    -- 【为什么是 btrim + NULLIF,不是 IS NOT NULL】一段空白字符串在数据库里
    -- 是"有值"的,而在发票上它与 NULL 一样什么都不印。判据要与【印出来的结果】
    -- 一致,不是与列的可空性一致。
    IF NEW.gst_registered AND NOT OLD.gst_registered THEN
        IF NULLIF(btrim(COALESCE(NEW.gst_registration_no, '')), '') IS NULL THEN
            RAISE EXCEPTION 'GST_REGISTRATION_NO_REQUIRED';
        END IF;
    END IF;

    -- ── 关:两条拒绝,两个【不同】的理由 ────────────────────────────────────
    IF OLD.gst_registered AND NOT NEW.gst_registered THEN

        -- 【① 机械】带税码的费用单:关掉之后它们【冲销不了】。
        -- 判据取自那件真正会坏的事 —— 分录行上带着税码、分录还没有被冲销。
        -- reverse_expense 会把这张分录整个翻边,而翻边【会把 tax_code 一起抄过去】
        -- (GST-2 修的那一条);未注册时 post_journal_entry 拒收带税码的行,
        -- 于是那一笔永远冲不掉。
        SELECT count(*), string_agg(e.code, ', ' ORDER BY e.code)
          INTO v_n, v_codes
          FROM expenses e
          JOIN journal_entries je ON je.id = e.journal_entry_id
         WHERE EXISTS (SELECT 1 FROM expense_lines l WHERE l.expense_id = e.id AND l.tax_code IS NOT NULL)   -- EXPENSE-MULTILINE-1:税码在行上
           AND e.status = 'posted'
           AND je.status = 'posted'
           AND EXISTS (SELECT 1 FROM journal_lines jl
                        WHERE jl.entry_id = je.id AND jl.tax_code IS NOT NULL);
        IF COALESCE(v_n, 0) > 0 THEN
            RAISE EXCEPTION 'GST_CANNOT_DISABLE_WITH_CODED_EXPENSES|%|%', v_n, v_codes
              USING HINT = '先把这些费用单冲销掉(冲销要在开关【还开着】的时候做),再关开关';
        END IF;

        -- 【② 判断】在册的带税发票:它们【冲销得了】(税腿不带税码),
        -- 但留下的状态自相矛盾 —— F5 报着那一季的供应额,而公司声称未注册。
        -- 这一条是判断,不是机械事实,所以它另起一个码、另说一句话。
        SELECT count(*), string_agg(DISTINCT i.code, ', ')
          INTO v_n, v_codes
          FROM invoices i
         WHERE i.status <> 'void'
           AND EXISTS (SELECT 1 FROM invoice_lines il
                        WHERE il.invoice_id = i.id AND il.tax_code IS NOT NULL);
        IF COALESCE(v_n, 0) > 0 THEN
            RAISE EXCEPTION 'GST_CANNOT_DISABLE_WITH_TAXED_INVOICES|%|%', v_n, v_codes
              USING HINT = '这些发票作废之后才谈得上"未注册" —— 否则账上报着供应额,而公司说那一季没注册';
        END IF;
    END IF;

    RETURN NEW;
END;
$function$
;

-- db/functions/submit_expense_claim.sql
-- CLAIM-1:提交一张报销单(旧签名)。
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0b Q8):这一支现在是 submit_expense_claim_items 的【单笔包装】——
--   签名一个字不变(/me 的旧表单之外,12 份 fixture 里 19 处调用照旧)。一句说明同时是整张单的用途与那一笔的说明;
--   无收据理由落在那一笔上。门、日期、金额、四眼预检的全部说明在 submit_expense_claim_items.sql。
--   【包装是 INVOKER】它自己不读不写任何表,门在它调的那一支(SECURITY DEFINER,开头就问调用者是谁)——
--   一支没有自己的调用者检查的属主权限函数是 B2 要拒的形状,而这里本来就不需要属主权限。
CREATE OR REPLACE FUNCTION public.submit_expense_claim(p_employee_id uuid, p_spend_date date, p_amount numeric, p_currency text, p_description text, p_no_receipt_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN submit_expense_claim_items(
        p_employee_id := p_employee_id,
        p_currency    := p_currency,
        p_purpose     := p_description,
        p_items       := jsonb_build_array(jsonb_build_object(
                             'spend_date', p_spend_date, 'amount', p_amount, 'description', p_description,
                             'no_receipt_reason', p_no_receipt_reason)));
END;
$function$
;

-- db/functions/decide_expense_claim.sql
-- 报销单的决定路径(旧签名)。CLAIM-1 建的;APR-3 接上审批引擎;CLAIM-GST-1 拆税。
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0b Q8):这一支现在是 decide_expense_claim_items 的【单笔包装】 ——
--   签名一个字不变(12 份 fixture 里 32 处调用、7 支证明脚本照旧);一张单只有一笔明细时,把 (科目, 税码) 包成那一笔的选择,
--   交给按明细的那一支。门、四眼、分档、驳回、凭据、入账日与过账的全部说明都在 decide_expense_claim_items.sql —— 读那一份。
--   【多笔的单走这里按名拒】EXPENSE_CLAIM_HAS_ITEMS|单号|笔数 —— 一个科目套在几笔上,就是替财务把逐笔的判断做掉了(Step 0b Q1);
--   驳回也一样拒:走旧调用的那个人手里没有逐笔的界面,让他一律去新的那一支,比一半走得通一半走不通好读。
CREATE OR REPLACE FUNCTION public.decide_expense_claim(p_claim_id uuid, p_approve boolean, p_account_code text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_n    integer;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');
    SELECT c.code, (SELECT count(*) FROM expense_claim_items i WHERE i.claim_id = c.id)
      INTO v_code, v_n FROM expense_claims c WHERE c.id = p_claim_id;
    IF v_n > 1 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_HAS_ITEMS|%|%', v_code, v_n
          USING HINT = '这张报销单有多笔明细 —— 用 decide_expense_claim_items 逐笔给科目与税码';
    END IF;
    RETURN decide_expense_claim_items(
        p_claim_id     := p_claim_id,
        p_approve      := p_approve,
        p_items        := CASE WHEN p_approve THEN jsonb_build_array(jsonb_build_object(
                              'line_no', 1, 'account_code', p_account_code, 'tax_code', p_tax_code)) END,
        p_posting_date := p_posting_date,
        p_notes        := p_notes);
END;
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- EXPENSE-MULTILINE-1(Tim 2026-10-20):费用单的行 —— 家在费用单(行没有自己的页面)
        ('expense', 13, 'expense_lines',            'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- EXPENSE-MULTILINE-1(Tim 2026-10-20):报销单的明细 —— 家在报销单那一块(/finance/claims);/me 上本人读同样的几笔
        ('expense_claim',    4, 'expense_claim_items', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('my_expense_claim', 4, 'expense_claim_items', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q39):一份化验的指标(残粉 · 箔纯度 · 粒径)与它的金属行同一个形状 ——
        --    住在那份化验挂着的那一批下(化验没有自己的主语;它的金属行也是这样挂的)。──
        ('inbound_batch',     47, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        ('output_batch',      45, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-1(2026-10-15,MES-6b Step 0 Q39):不合格报告也出现在它那一批上(家在报告自己那里);质量验收限的判定住在产出批下
        --    (判定挂在批次上,没有自己的主语);合同的第八张条款表住在合同下。──
        ('inbound_batch',     48, 'nonconformance_reports',           'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      46, 'nonconformance_reports',           'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      47, 'quality_limit_judgements',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, true),
        ('contract',          11, 'contract_quality_limits',          'contracts',                    'contract_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-6b-2(2026-10-15,MES-6b Step 0 Q38 · Q39):一张分析证书 —— 它的字节档案(家在证书)、作废它的 CFO 申请与那张申请的审批。
        --    证书也出现在两个批次主语下(家在证书自己那里):产出批 —— 它自己的证书、字节、作废申请与审批;进料批 —— 吃过这一批的加工单
        --    做出来的产出批上的证书(垫脚石:加工单 → 它的产出腿 → 那一批产出,只走一层;证书说的"来料化学确定度"正是这一批的事)。──
        ('coa',                1, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, true),
        ('coa',                2, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('coa',                3, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch',      48, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      49, 'coa_issues',                       'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      50, 'warehouse_requests',               'certificates_of_analysis',     'coa_id',              '{}'::jsonb, 'down', true, false),
        ('output_batch',      51, 'approval_log',                     'warehouse_requests',           'subject_id',          '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch',     49, 'processing_outputs',               'processing_runs',              'run_id',              '{}'::jsonb, 'down', false, false),
        ('inbound_batch',     50, 'output_batches',                   'processing_outputs',           'output_batch_id',     '{}'::jsonb, 'up',   false, false),
        ('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7a-2(2026-10-16,MES-7a Step 0 Q20):备件出给保养与退回 —— 没有自己的主语(它没有自己的页)。家在设备(经那一条保养记录);
        --    也出现在进料批下(出的是这一批),连同那张分录(借 6800 / 贷 1200,source_type = maintenance_part,财务读)。──
        ('equipment',          5, 'maintenance_part_issues',          'equipment_maintenance',        'maintenance_id',      '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     52, 'maintenance_part_issues',          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     53, 'journal_entries',                  'maintenance_part_issues',      'source_id',           '{"source_type": "maintenance_part"}'::jsonb, 'down', true, false),
        -- ── MES-7b-1(2026-10-16,MES-7b Step 0 Q12 · Q19):一件事故 —— 之后的事实与批次链接住在这里;交接班的引用住在交接班下(家),
        --    也出现在事故上;来源 incident 的不合格报告也出现在事故上(家在报告自己那里)。批次链接也出现在那一批上(Q19:事故在批次上看得见)。──
        ('incident',           1, 'incident_updates',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           2, 'incident_batches',                 'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, true),
        ('incident',           3, 'shift_handover_incident_refs',     'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('incident',           4, 'nonconformance_reports',           'incidents',                    'incident_id',         '{}'::jsonb, 'down', true, false),
        ('shift_handover',     3, 'shift_handover_incident_refs',     'shift_handovers',              'handover_id',         '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     54, 'incident_batches',                 'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      52, 'incident_batches',                 'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-7b-2(2026-10-16,MES-7b Step 0 Q19):一次巡检 —— 它的结果、发现与发现的关闭住在这里;引用一条发现的不合格报告也出现在这里
        --    (家在报告自己那里)。一张巡检清单 —— 它的检查项住在这里。──
        ('inspection_run',      1, 'inspection_results',               'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      2, 'inspection_findings',              'inspection_runs',              'run_id',              '{}'::jsonb, 'down', true, true),
        ('inspection_run',      3, 'inspection_finding_closures',      'inspection_findings',          'finding_id',          '{}'::jsonb, 'down', true, true),
        ('inspection_run',      4, 'nonconformance_reports',           'inspection_findings',          'inspection_finding_id', '{}'::jsonb, 'down', true, false),
        ('inspection_template', 1, 'inspection_template_items',        'inspection_templates',         'template_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8a(2026-10-16,MES-8 Step 0 Q22):一份供应商对账单 —— 它的签发档住在这里。一家供应商的评审也出现在它下面
        --    (家在评分卡页那条集合记录里)。──
        ('supplier_statement',  1, 'supplier_statement_issues',        'supplier_statements',          'statement_id',        '{}'::jsonb, 'down', true, true),
        ('supplier',            6, 'supplier_scorecard_reviews',       'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, false),
        -- ── MES-9a(2026-10-19,MES-9 Step 0 §6 · Q21):一家供应商的门户账号 —— 开、撤销、匿名化住在这里 ──
        ('supplier',            7, 'supplier_portal_users',            'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-9c(2026-10-20,MES-9 Step 0 §5 · §6 · Q19 · Q21):门户交上来的证书 —— 交、接受、驳回住在这里 ──
        ('supplier',            8, 'portal_certificate_submissions',   'suppliers',                    'supplier_id',         '{}'::jsonb, 'down', true, true),
        -- ── MES-8b-1(2026-10-17,MES-8 Step 0 Q22):一份合规包 —— 它的签发档住在这里。──
        ('compliance_pack',     1, 'compliance_pack_issues',           'compliance_packs',             'pack_id',             '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

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
        -- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0b Q8):分档与那一句按级要人的调用住在 decide_expense_claim_items;
        --   decide_expense_claim 是它的单笔包装,自己不分档 —— 名册登记的是【真正把关的那一支】(fixture 203E:名册 = 目录)。
        ('expense_claim'::text, 'decide_expense_claim_items'::text, 1::smallint,
            ARRAY['module.finance.view', 'data.view_prices']::text[]),
        ('expense_claim'::text, 'decide_expense_claim_items'::text, 2::smallint,
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

-- ── 8 · expense_claim_status 重建(镜像原样)——视图的写授权由 apply_migration.sh 随后重放 zzz_function_grants.sql 的 F16 那一段收回;
--   本事务里的自证要先看到它收回,所以这里也收一次(同一句话)──
-- db/views/expense_claim_status.sql
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20):表头这一行不再带 account_code / tax_code / no_receipt_reason —— 它们搬到了
--   每一笔明细(expense_claim_items,页面另读);多了 item_count。description 现在是整张单的【用途】(Step 0b Q7)。
--   属主权限与行谓词原样。【明细为什么不并进这张视图】一行一张单是它的全部契约(清单、在途、/me 都按单读);
--   明细是一对多,另读那张表 —— 它的读策略与本视图的行谓词同一条。
-- CLAIM-1：每一笔报销一行，而「付了没有」是从核销额【推导】出来的。
--
-- ★ WITH (security_invoker = off) 与 COMMENT ON VIEW 都是【手工补回来的】★
-- pg_get_viewdef() 只吐 SELECT —— 既不吐 reloptions，也不吐对象注释。
-- 照它重建镜像会把两样都悄悄丢掉（AGENTS.md 为前者记过一次；后者是
-- STATEMENT-1 漏过、CHASE-1-FU 补上的那一条）。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★ APR-ROUTE-1 · F1(Tim 的 R5,2026-09-23):这张视图此前把【每一笔】报销
--     交给【任何一个】登录的人 ★★★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它是什么形状】属主权限(security_invoker = off),于是 expense_claims 的 RLS
-- 根本不参与;而函数体【没有任何行谓词】。EMP-SELF-0 §3 以 fusheng(warehouse,
-- 不持 module.finance.view)的真身份实测:看得见 4 行 —— 线上全部 4 行,
-- 跨 2 名员工,带姓名、金额、事由。/me 只是因为页面自己加了
-- `.eq('employee_id', …)` 才没有在屏幕上露出来 —— 一道只在【页面】上的过滤,
-- 对一个直接调 PostgREST 的人什么都不是。
--
-- 【谓词】与 medical_claim_status 逐字同形:财务看全部,其余每个人只看自己的。
--   has_permission('module.finance.view') OR employee_id = current_user_employee()
-- ★ 两个都按【调用者】求值(两者都是 SECURITY DEFINER、读 auth.uid()),
--   所以属主权限不会把它们变成"属主看得见的一切"。
--
-- 【下面 COD-2 那段理由,在这张视图上是【假】的,照直更正】它说"本视图要喂
-- operations_now,加谓词会让没有财务权限的人的行静默消失"。EMP-SELF-0 §3 与
-- APR-ROUTE-1 grilling 各查一遍:`grep expense_claim_status` 在 db/views、
-- db/functions、app、lib 里只命中两处 —— app/me/page.tsx(本人)与
-- app/finance/claims/page.tsx(页闸 module.finance.view)。**没有任何视图或函数
-- 读它。** 于是这一句谓词没有让任何一个合法读者少一行。
-- ☞ 那段话大概是从 collection_promise_status(同一次 COD-2 一起收权的另一张)
--   上抄过来的。它留在下面,因为 REVOKE FROM anon 那一句仍然对 —— 错的只是理由。
--
-- 【一个读者真的少了行:db/fixtures/196 的 F0b】它以 postgres、清空 claims 的身份
-- 读这张视图来自证"视图里有东西"。postgres 没有 JWT → has_permission 恒假、
-- current_user_employee() 为 NULL → 0 行 → F0b 响亮地报"前提不成立"。
-- 同一刀里改成以一个持 module.finance.view 的身份读(Tim 的 Q11)。
--
-- NOTE: introduced by db/migrations/2026-08-28-claim1-employee-expense-claims.sql.

-- AP-RECON-1(2026-09-24):「付清了没有」对着【净额 + 进项税】判(CLAIM-GST-1 起读 amount_ccy + tax_ccy,
-- 落库的那一笔税;此前是 expense_payable_ccy 重算)——
-- CLAIM-GST-1 还在末尾【追加】两列 expense_net_ccy / expense_tax_ccy(费用单上的净额与税):
-- 批准之后,屏幕要说得出员工报的那个总额被拆成了什么 —— 读落库的两个数,不在页面上再算一遍。
-- 只追加、不动既有列序 → 迁移走 CREATE OR REPLACE。
-- 那是总账 2000 上欠员工的全部;只对着净额判,会在那笔税还欠着的时候说"已付"。
-- (报销的税是【从报销额里拆出来】的 —— CLAIM-GST-1,2026-09-24:decide_expense_claim 传
--  p_amount_includes_tax := true,于是 amount_ccy + tax_ccy 恰好等于员工报的那个总额。)

CREATE VIEW public.expense_claim_status WITH (security_invoker = off) AS
SELECT c.id AS claim_id,
    c.code,
    c.employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    c.spend_date,
    c.submitted_at,
    c.amount_ccy,
    c.currency,
    c.description,
    c.status,
    c.decided_at,
    c.decision_notes,
    c.posting_date,
    c.expense_id,
    x.payment_status,
    x.status = 'reversed'::text AS expense_reversed,
    COALESCE(a.settled_ccy, 0::numeric) AS settled_ccy,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) >= (x.amount_ccy + x.tax_ccy) AS is_paid,
    c.status = 'approved'::text AND x.status = 'posted'::text AND COALESCE(a.settled_ccy, 0::numeric) < (x.amount_ccy + x.tax_ccy) AS is_owing,
    (EXISTS ( SELECT 1
           FROM finance_attachments fa
          WHERE fa.claim_id = c.id AND fa.deleted_at IS NULL)) AS has_receipt,
    x.amount_ccy AS expense_net_ccy,
    x.tax_ccy AS expense_tax_ccy,
    ( SELECT count(*) AS count
           FROM expense_claim_items i
          WHERE i.claim_id = c.id) AS item_count
   FROM expense_claims c
     JOIN employees e ON e.id = c.employee_id
     LEFT JOIN expenses x ON x.id = c.expense_id
     LEFT JOIN LATERAL ( SELECT round(sum(pa.allocated_ccy), 2) AS settled_ccy
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id
          WHERE pa.expense_id = c.expense_id AND p.status = 'posted'::text) a ON true
  WHERE has_permission('module.finance.view'::text) OR c.employee_id = current_user_employee();

COMMENT ON VIEW public.expense_claim_status IS
    'CLAIM-1:每一笔报销一行,而【付了没有是推导出来的】—— 与 medical_claim_status 同一条:付款状态归 expenses 所有,存一份副本第一次冲销付款时两边就分家。expense_reversed 单独露出来,因为"批准被撤销"在本刀里【没有】自己的机制:改法是冲销那笔费用(expenses 本来就有冲销路径与 reversed_by_expense),claim 的状态跟着它走 —— 两个撤销机制会对"这笔钱还欠不欠"各说各话。属主权限(security_invoker = off):它横跨 finance 与 hr(employees 有 RLS),invoker 会让读者无权的那一侧静默丢掉行,而行消失在这里意味着"少了一笔欠员工的钱"(OPS-14 修法 (a))。★ APR-ROUTE-1(F1,Tim 的 R5):行谓词写在视图里 —— has_permission(''module.finance.view'') OR employee_id = current_user_employee(),与 medical_claim_status 同形;此前它把每一笔报销交给任何一个登录的人,只靠页面自己的过滤挡着。';

-- ════════════════════════════════════════════════════════════════════════════
-- ★ COD-2(2026-09-08):从 anon 手里收回 —— 这一行必须在镜像里,不能只在迁移里 ★
-- ════════════════════════════════════════════════════════════════════════════
-- 【它此前是什么状态】ANON-0 实测:本视图是属主权限(security_invoker = off,
-- 于是基表的 RLS 根本不参与)、授给了 anon、body 里没有任何权限判据、也不调
-- 任何带门的函数。**它今天回空只因为基表还没有行。** ANON-0 的原话:
-- 它不是在漏,它是【上了膛】—— 第一条真实记录写进来的那一刻它就开了,
-- 而在此之前没有任何检查会说一句话(check_mirrors.py 第 59 行自己写着「不比 GRANT」)。
--
-- 【为什么是 REVOKE,而不是给 body 加一句 has_permission】
--   本文件上面那段注释自己写着:它【刻意只有纯 SQL、一个函数都不调】,
--   因为它要喂 operations_now —— 那是没有财务权限的人也在看的首页。
--   加一句谓词会让那些人的行【静默消失】,而"少了一个逾期承诺"与"报错"
--   完全不是一回事。那正是 OPS-14 修法 (a) 要避开的东西。
--   而 REVOKE 对 authenticated 零代价:anon 从来不是它的合法读者。
--
-- 【为什么这一行住在镜像里】db/views/batch_lineage_all.sql 的抬头记着这个疤:
--   一条只住在迁移里的 REVOKE,重建出来的库【是开着的】——「线上收着,
--   重建出来的库开着」。看着它别再漂回去的是 db/check_grants.py(COD-2)。
REVOKE ALL ON public.expense_claim_status FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.expense_claim_status FROM anon, authenticated, PUBLIC;

-- ── 9 · 搜索只读报销单表头的用途(Step 0b Q7;与 db/tables/document_types.sql 那一行同一个值)──
UPDATE public.document_types SET match_columns = ARRAY['description', 'decision_notes']::text[] WHERE key = 'expense_claim';

-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.record_expense_document(date, text, jsonb, text, text, uuid, text, text, jsonb, uuid, uuid, text, numeric, text, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_expense_document(date, text, jsonb, text, text, uuid, text, text, jsonb, uuid, uuid, text, numeric, text, uuid, boolean) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.submit_expense_claim_items(uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_expense_claim_items(uuid, text, text, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.decide_expense_claim_items(uuid, boolean, jsonb, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decide_expense_claim_items(uuid, boolean, jsonb, date, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_expense_totals() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_expense_totals() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_expense_claim_totals() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_expense_claim_totals() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_expense_line_mutation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_expense_line_mutation() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_expense_claim_item_mutation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_expense_claim_item_mutation() TO authenticated, service_role;

-- ── 11 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.em1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE em1_pending_after ON COMMIT DROP AS
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
    -- 合计守卫在提交前就跑一遍(它们是延迟的):每一张表头 = 它的行 / 明细之和
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'EM1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM em1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM em1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'EM1_PROOF|an account or its roles changed';
    END IF;

    -- ② 每一张费用单恰好一行,逐字等于搬走之前;每一张报销单恰好一笔,逐字等于搬走之前
    IF EXISTS (SELECT 1 FROM expenses e WHERE (SELECT count(*) FROM expense_lines l WHERE l.expense_id = e.id) <> 1)
       OR (SELECT count(*) FROM expense_lines) <> 10
       OR EXISTS ((SELECT id, account_code, amount_ccy, amount_base, tax_code, tax_rate_pct, tax_ccy, tax_base, created_at, created_by
                     FROM em1_expense_cols
                   EXCEPT SELECT l.expense_id, l.account_code, l.amount_ccy, l.amount_base, l.tax_code, l.tax_rate_pct,
                                 l.tax_ccy, l.tax_base, l.created_at, l.created_by FROM expense_lines l WHERE l.line_no = 1 AND l.notes IS NULL)) THEN
        RAISE EXCEPTION 'EM1_PROOF|the expense conversion is not one exact line per document';
    END IF;
    IF EXISTS (SELECT 1 FROM expense_claims c WHERE (SELECT count(*) FROM expense_claim_items i WHERE i.claim_id = c.id) <> 1)
       OR (SELECT count(*) FROM expense_claim_items) <> 4
       OR EXISTS ((SELECT id, spend_date, amount_ccy, description, no_receipt_reason, account_code, tax_code, created_at, created_by
                     FROM em1_claim_cols
                   EXCEPT SELECT i.claim_id, i.spend_date, i.amount_ccy, i.description, i.no_receipt_reason, i.account_code,
                                 i.tax_code, i.created_at, i.created_by FROM expense_claim_items i WHERE i.line_no = 1)) THEN
        RAISE EXCEPTION 'EM1_PROOF|the claim conversion is not one exact item per claim';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(两张表头比拿掉搬走的列之后的);变更记录只写了两张新表与 document_types 那一行
    IF EXISTS ((SELECT b.k, b.id FROM em1_pending_before b EXCEPT SELECT a2.k, a2.id FROM em1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM em1_pending_after a2 EXCEPT SELECT b.k, b.id FROM em1_pending_before b)) THEN
        RAISE EXCEPTION 'EM1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'account_code' - 'tax_code' - 'tax_rate_pct')::text, '|' ORDER BY (to_jsonb(t) - 'account_code' - 'tax_code' - 'tax_rate_pct')::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'account_code' - 'tax_code' - 'no_receipt_reason')::text, '|' ORDER BY (to_jsonb(t) - 'account_code' - 'tax_code' - 'no_receipt_reason')::text), '')) FROM expense_claims t ) IS DISTINCT FROM (SELECT expense_claims FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM document_types t WHERE key <> 'expense_claim') IS DISTINCT FROM (SELECT document_types FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t ) IS DISTINCT FROM (SELECT accounts FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t ) IS DISTINCT FROM (SELECT payment_allocations FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t ) IS DISTINCT FROM (SELECT payment_requests FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM prepayment_applications t ) IS DISTINCT FROM (SELECT prepayment_applications FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_assets t ) IS DISTINCT FROM (SELECT fixed_assets FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_asset_cost_entries t ) IS DISTINCT FROM (SELECT fixed_asset_cost_entries FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM fixed_asset_depreciation_anchors t ) IS DISTINCT FROM (SELECT fixed_asset_depreciation_anchors FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM equipment_maintenance t ) IS DISTINCT FROM (SELECT equipment_maintenance FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM medical_claims t ) IS DISTINCT FROM (SELECT medical_claims FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_attachments t ) IS DISTINCT FROM (SELECT finance_attachments FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_cost_entries t ) IS DISTINCT FROM (SELECT processing_cost_entries FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM electricity_allocations t ) IS DISTINCT FROM (SELECT electricity_allocations FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t ) IS DISTINCT FROM (SELECT assay_disputes FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) IS DISTINCT FROM (SELECT permissions FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) IS DISTINCT FROM (SELECT role_permissions FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM tax_codes t ) IS DISTINCT FROM (SELECT tax_codes FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t ) IS DISTINCT FROM (SELECT suppliers FROM em1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM employees t ) IS DISTINCT FROM (SELECT employees FROM em1_rows_before) THEN
        RAISE EXCEPTION 'EM1_PROOF|a pre-existing row changed';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM document_types WHERE key = 'expense_claim'
                    AND match_columns = ARRAY['description', 'decision_notes']::text[]) THEN
        RAISE EXCEPTION 'EM1_PROOF|the expense_claim search columns are not as ruled';
    END IF;
    SELECT COALESCE(string_agg(DISTINCT c.table_name, ', ' ORDER BY c.table_name), '') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM em1_log_before), 0) AND c.txid = txid_current();
    IF v_bad NOT IN ('expense_claim_items, expense_lines', 'document_types, expense_claim_items, expense_lines') THEN
        RAISE EXCEPTION 'EM1_PROOF|this migration wrote change_log rows for: %', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'EM1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;

    -- ④ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM em1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'EM1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ⑤ 结构:新函数在;旧签名各只有一支;搬走的列不在了;两张新表开着 RLS、anon 一个权限都没有;四条合计触发器是延迟的
    IF to_regprocedure('public.record_expense_document(date, text, jsonb, text, text, uuid, text, text, jsonb, uuid, uuid, text, numeric, text, uuid, boolean)') IS NULL
       OR to_regprocedure('public.submit_expense_claim_items(uuid, text, text, jsonb)') IS NULL
       OR to_regprocedure('public.decide_expense_claim_items(uuid, boolean, jsonb, date, text)') IS NULL
       OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'
            AND p.proname IN ('record_expense', 'submit_expense_claim', 'decide_expense_claim', 'record_expense_document',
                              'submit_expense_claim_items', 'decide_expense_claim_items')) <> 6 THEN
        RAISE EXCEPTION 'EM1_PROOF|expected exactly one signature of each writer';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                AND ((table_name = 'expenses' AND column_name IN ('account_code', 'tax_code', 'tax_rate_pct'))
                  OR (table_name = 'expense_claims' AND column_name IN ('account_code', 'tax_code', 'no_receipt_reason')))) THEN
        RAISE EXCEPTION 'EM1_PROOF|a moved column is still on a header';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.expense_lines'::regclass)
       OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.expense_claim_items'::regclass)
       OR has_table_privilege('anon', 'public.expense_lines', 'SELECT') OR has_table_privilege('anon', 'public.expense_claim_items', 'SELECT') THEN
        RAISE EXCEPTION 'EM1_PROOF|the new tables are not closed to anon / not under RLS';
    END IF;
    IF (SELECT count(*) FROM pg_trigger WHERE tgname IN ('trg_expenses_totals_match', 'trg_expense_lines_totals_match',
            'trg_expense_claims_totals_match', 'trg_expense_claim_items_totals_match') AND tgdeferrable AND tginitdeferred) <> 4 THEN
        RAISE EXCEPTION 'EM1_PROOF|the four totals triggers are not all deferred constraint triggers';
    END IF;

    -- ⑥ 327 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 327 THEN
        RAISE EXCEPTION 'EM1_PROOF|expected 327 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'EM1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'EM1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'EM1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'EM1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'EM1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.em1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'EM1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.em1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'EM1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.em1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;

-- db/migrations/2026-10-20-fin-chain-1.sql
-- FIN-CHAIN-1 —— 销售链与财务链的几处正确性,科目表增补十四个科目。(v1.4.63;发布那一行在 docs/handbacks/FIN-CHAIN-1.md 的抬头。)
--   由 db/scripts/build_fin_chain1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-20 的裁定:委托书 A–E 与 Step 0 Q1–Q13)
--   A1 · A2  十四个非系统科目:2600 应付借款(负债 · 货币性 · 筹资段)+ 十三个费用科目(非货币性)。只插新行,既有的科目一行不动。
--   B1  set_sales_order_status:作废一张挂着在册订单流发票的订单 → SO_CANCEL_HAS_LIVE_INVOICE|订单|发票(先提发票作废申请)。
--   B2  create_invoice:订单流的销售(sales_order_line_id 非空)→ SALE_IS_ORDER_FLOW|批次(它已经在订单发票上了)。
--   B3  set_sales_order_status:partially_shipped → closed 的显式短装收尾 —— 理由必填(SO_CLOSE_REASON_REQUIRED);
--       开了票、没发、也没被贷项取消的数量 → SO_CLOSE_INVOICED_UNSHIPPED|订单|行|数量;剩下的预留释放;写一行历史。
--   B4  quotes 新增行级守卫 trg_quotes_status_through_function:直连改 status / converted_order_id / decline_reason
--       (或直连插一行不是 draft 的)→ QT_STATUS_THROUGH_FUNCTION_ONLY;属主路径(三支 SECURITY DEFINER 函数)放行。
--   C1  六扇出钱的门(pay_payroll_lines · pay_payroll_cpf · pay_payroll_deductions · remit_processing_costs ·
--       remit_wht_internal · record_bank_transfer_internal)日期晚于今天 → DOCUMENT_DATE_IN_FUTURE|<种类>|日期|今天。
--   C2  management_pack_data:应收 / 应付的「未解释」改由 list_ledger_reconciliation 答(连同读它的时刻存进包);
--       旧的按机制分解原样保留。已冻结的包一行不动。
--   C3  close_period:清单 ↔ 总账任何一边未解释 ≠ 0 → CLOSE_LEDGER_LIST_UNEXPLAINED|边|金额;答不上来 → CLOSE_RECON_UNANSWERABLE。
--   C6  reverse_freight_document 多一个参数 p_reversal_date(必填 → REVERSAL_DATE_REQUIRED;不早于原分录;不默认)。
--       签名变了,所以先 DROP 旧签名(函数权限由 apply_migration.sh 随后整份重放 zzz_function_grants.sql 恢复)。
--
-- 【不做什么】不碰审批开关、hook、任何账号与角色;不改任何既有的行;不回填;不建任何单据;require_calibrated_since 保持空;
--   C4(结算过账)与 C5(薪资付款冲销)不在本刀(Tim Q1 · Q6)。
--
-- 【破窗】旧应用 + 新库这一窗里坏的只有一件:运费单详情页的「冲销」不传日期,会读到 REVERSAL_DATE_REQUIRED(按名拒,
--   不写任何东西)。其余全是收紧:旧页面上原来能做、现在被按名拒的动作(作废挂票的订单、给订单流销售开 sale 票、
--   明天的出钱日期、带未解释差额关账)—— 线上此刻这几种情形一张都没有(勾稽两边未解释 0.00,文末断言)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;十四个科目逐字是 Tim 定的那样,
--   2600 不在费用单的下拉里(account_type ≠ expense);既有的科目与单据行逐字未变;本事务写进变更记录的只有那十四行新科目;
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;
--   两张 COD 原样;变更记录覆盖零缺口、豁免 9;325 张表;匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
CREATE TEMP TABLE finchain1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM accounts WHERE code IN ('2600', '6010', '6130', '6140', '6210', '6220', '6230', '6240', '6250', '6310', '6410', '6420', '6510', '6520')) THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|one of the fourteen account codes already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE code = '3000' AND name_en = 'Share Capital')
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '6300' AND name_en = 'Transport & Logistics')
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '6900' AND name_en = 'Miscellaneous') THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|3000 / 6300 / 6900 are expected with their current names';
    END IF;
    IF to_regprocedure('public.reverse_freight_document(uuid, text)') IS NULL OR to_regprocedure('public.reverse_freight_document(uuid, text, date)') IS NOT NULL
       OR to_regprocedure('public.guard_quote_status_through_function()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_quotes_status_through_function') THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected the two-argument reverse_freight_document and no quote status guard yet';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ('admin@swm-os.test', 'chooer@evoltrya.test', 'fusheng@evoltrya.test', 'phua@evolytra.test', 'sandra@evoltrya.test', 'tim@evoltrya.test', 'vince@evoltrya.test')) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '634c00f9-c3a9-4444-9eed-b624cb6a2a93' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected 325 public tables';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected the two recorded COD byte strings';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00(委托书:勾稽保持 0.00)—— 以 tim@(cfo)身份【读】,读完即清
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO finchain1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE finchain1_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE finchain1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE finchain1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE finchain1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t WHERE code NOT IN ('2600', '6010', '6130', '6140', '6210', '6220', '6230', '6240', '6250', '6310', '6410', '6420', '6510', '6520')) AS accounts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM quotes t ) AS quotes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t ) AS sales_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_lines t ) AS sales_order_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_reservations t ) AS sales_order_reservations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_records t ) AS sales_records,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoices t ) AS invoices,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoice_lines t ) AS invoice_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM credit_notes t ) AS credit_notes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM freight_documents t ) AS freight_documents,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM management_packs t ) AS management_packs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM period_closes t ) AS period_closes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_periods t ) AS payroll_periods,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_lines t ) AS payroll_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM wht_remittances t ) AS wht_remittances,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_transfers t ) AS bank_transfers,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) AS approval_log,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) AS permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) AS role_permissions,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) AS roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) AS user_roles,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) AS finance_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) AS ingest_settings,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) AS cod_issues,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM list_ledger_residue t ) AS list_ledger_residue;

-- ── 1 · A1 · A2:十四个非系统科目(镜像原样;2600 的筹资段与镜像里那句 UPDATE 同一个值)──
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_system, is_monetary) VALUES
    ('2600', 'Loan Payable', '应付借款', 'liability', false, true),
    ('6010', 'Equipment Rental', '设备租赁费', 'expense', false, false),
    ('6130', 'Staff Training & Development', '员工培训与发展', 'expense', false, false),
    ('6140', 'Recruitment Expenses', '招聘费用', 'expense', false, false),
    ('6210', 'Telephone & Internet', '电话与网络费', 'expense', false, false),
    ('6220', 'IT & Software Expenses', 'IT与软件费用', 'expense', false, false),
    ('6230', 'Printing & Stationery', '印刷与文具', 'expense', false, false),
    ('6240', 'Office Expenses', '办公费用', 'expense', false, false),
    ('6250', 'Cleaning Expenses', '清洁费用', 'expense', false, false),
    ('6310', 'Vehicle Expenses', '车辆费用', 'expense', false, false),
    ('6410', 'Licences & Permits', '执照与许可费', 'expense', false, false),
    ('6420', 'Insurance Expenses', '保险费', 'expense', false, false),
    ('6510', 'Business Travel Expenses', '差旅费', 'expense', false, false),
    ('6520', 'Entertainment Expenses', '业务招待费', 'expense', false, false);
UPDATE public.accounts SET cash_flow_section = 'financing' WHERE code = '2600';

-- ── 2 · 换掉的函数(镜像原样,同签名)──

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
    -- FIN-CHAIN-1(Tim AP-RECON-1 Batch B Q6,2026-10-20 落地):钱离开银行是一件【已经发生】的事 —— 日期晚于今天按名拒(与 record_payment_internal 同一句)。
    IF p_payment_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|payroll_payment|%|%', p_payment_date, CURRENT_DATE;
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
    -- FIN-CHAIN-1(Tim AP-RECON-1 Batch B Q6,2026-10-20 落地):钱离开银行是一件【已经发生】的事 —— 日期晚于今天按名拒(与 record_payment_internal 同一句)。
    IF p_payment_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|cpf_payment|%|%', p_payment_date, CURRENT_DATE;
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
    -- FIN-CHAIN-1(Tim AP-RECON-1 Batch B Q6,2026-10-20 落地):钱离开银行是一件【已经发生】的事 —— 日期晚于今天按名拒(与 record_payment_internal 同一句)。
    IF p_payment_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|deductions_payment|%|%', p_payment_date, CURRENT_DATE;
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

-- db/functions/remit_processing_costs.sql
-- 汇付【实际额】(is_estimate = false)的加工成本(FIN-6 B)。FIN-5 的形状:
-- 一次汇款 = 对账单一行 = 分录一条银行行;借 2200 合计。照着对账单记。
-- 估算行不走这里(COST_ENTRY_IS_ESTIMATE)—— 估算由真实发票冲抵(relieve_processing_accruals)。
--
-- NOTE: introduced by db/migrations/2026-08-04-fin6-relieve-processing-accruals.sql.
--
-- FIN-10(2026-08-05):日期不再有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。
-- 默认成今天永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关,
-- 这条路径专门奖励留空。要求由函数自己声明,而不是靠调用方自觉。
-- 详见 db/migrations/2026-08-05-fin10-no-default-posting-dates.sql。
--
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q26):盖汇出戳之前设事务级标记 evoltrya.cost_settlement_ctx(结算戳只许经财务函数改 ——
--   guard_cost_entry_settled),用毕即清。其余一个字不动。

CREATE OR REPLACE FUNCTION public.remit_processing_costs(p_entry_ids uuid[], p_payment_date date DEFAULT NULL::date, p_bank_account text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_total numeric := 0;
    v_n int := 0;
    v_e record;
    v_bank text;
    v_date date;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    -- FIN-CHAIN-1(Tim AP-RECON-1 Batch B Q6,2026-10-20 落地):钱离开银行是一件【已经发生】的事 —— 日期晚于今天按名拒(与 record_payment_internal 同一句)。
    IF p_payment_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|processing_cost_remittance|%|%', p_payment_date, CURRENT_DATE;
    END IF;
    IF p_entry_ids IS NULL OR array_length(p_entry_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN RAISE EXCEPTION 'BANK_INVALID|%', v_bank; END IF;
    v_date := p_payment_date;

    FOR v_e IN SELECT * FROM processing_cost_entries WHERE id = ANY (p_entry_ids) FOR UPDATE
    LOOP
        IF v_e.deleted_at IS NOT NULL THEN RAISE EXCEPTION 'COST_ENTRY_INVALID|%', v_e.id; END IF;
        IF v_e.is_estimate THEN RAISE EXCEPTION 'COST_ENTRY_IS_ESTIMATE|%', v_e.cost_type; END IF;
        IF v_e.remitted_at IS NOT NULL OR v_e.relieved_at IS NOT NULL THEN
            RAISE EXCEPTION 'COST_ENTRY_ALREADY_SETTLED|%', v_e.cost_type;
        END IF;
        v_total := round(v_total + v_e.amount_base, 2);
        v_n := v_n + 1;
    END LOOP;
    IF v_n = 0 OR v_total <= 0 THEN RAISE EXCEPTION 'NO_LINES'; END IF;

    v_je := post_journal_entry(v_date, 'Processing cost remittance', 'processing_cost', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '2200', 'side', 'debit', 'currency', base_currency_code(),
                               'amount_ccy', v_total),
            jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', base_currency_code(),
                               'amount_ccy', v_total)));

    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries
    SET remitted_at = v_date, remitted_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = ANY (p_entry_ids);
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'entries', v_n, 'total', v_total);
END;
$function$;

-- db/functions/remit_wht_internal.sql
-- PAY-REQ-1 · Batch B(2026-09-23):remit_wht 的函数体搬到这里,拿掉了写权限检查,
-- 多了一个参数 p_expected_amount(申请冻结的数,付款时推导值不同就按名拒),
-- 返回值多了 entry_id(试跑按它读这次会过账的本位币额)。原来的抬头照录如下。
--
-- WHT-1:把一个代扣月的预提税汇给 IRAS。
--
-- ★【它与 pay_payroll_cpf 是同一个形状,而那不是巧合 —— 是同一件事】★
--   两者都是【从别人的钱里扣下来、替他交给一个法定机构】:CPF 扣自员工的薪,
--   预提税扣自非居民收款人的款。所以两者的分录逐字同形(借那笔负债 / 贷银行)、
--   都在次月到期、都不豁免期间锁,而且【告警清除的条件都是钱真的动了】。
--   两个到期日不同(CPF 次月 14 日、预提税次月 15 日),各自来自各自的法令 ——
--   **不要"顺手统一"**:一个凑整过的法定期限,是一个会让公司逾期的数字。
--
-- ★【为什么不需要"先打开一期"】★ gst_periods 要先 open_gst_period 才能申报;
--   这里没有那个动作,因为【欠多少是推导出来的】(wht_liability_by_month 从总账
--   读代扣),不需要谁先声明这个月存在。于是"没有人开这一期,于是这个月的税
--   悄悄没人管"这种失败模式,在结构上不存在。
--
-- FIN-10:日期没有 CURRENT_DATE 默认值 —— 缺了就抛具名错误。默认成今天
-- 永远撞不上 PERIOD_LOCKED,于是留空反而比填对更容易过关。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.remit_wht_internal(p_period_month date, p_remitted_on date DEFAULT NULL::date, p_filed_reference text DEFAULT NULL::text, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_expected_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_month   date;
    v_amount  numeric;
    v_bank    text;
    v_base    text;
    v_ref     text;
    v_seq     integer;
    v_code    text;
    v_je      jsonb;
    v_id      uuid := gen_random_uuid();
BEGIN
    -- ★ PAY-REQ-1 Batch B:这里【没有】写权限检查 —— 内层引擎,EXECUTE 已从 authenticated
    --   收回;唯一的外门是 pay_payment_request(finance.edit,只执行一张已批准的代扣税缴纳申请)。
    --   下面那一句 view 检查【留着】,而它不是调用者检查,是这次【读】的前提(WHT-1 fu1):
    PERFORM require_permission('module.finance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'WHT_PERIOD_REQUIRED';
    END IF;
    v_month := date_trunc('month', p_period_month)::date;

    IF p_remitted_on IS NULL THEN
        RAISE EXCEPTION 'WHT_REMIT_DATE_REQUIRED|%', v_month;
    END IF;
    IF p_remitted_on < v_month THEN
        -- 还没发生的代扣汇不出去。
        RAISE EXCEPTION 'WHT_REMIT_DATE_BEFORE_PERIOD|%|%', p_remitted_on, v_month;
    END IF;
    -- FIN-CHAIN-1(Tim AP-RECON-1 Batch B Q6,2026-10-20 落地):钱离开银行是一件【已经发生】的事 —— 日期晚于今天按名拒(与 record_payment_internal 同一句)。
    IF p_remitted_on > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|wht_remittance|%|%', p_remitted_on, CURRENT_DATE;
    END IF;

    -- 【参考号必填,而 gst_periods 那一条允许空 —— 两者不是同一件事】
    -- GST 那边"申报"与"缴款"是两个动作,回执可能晚到;这里是【一次缴款】,
    -- 而一笔说不出参考号的缴款,日后对着 IRAS 无从交代。
    v_ref := NULLIF(btrim(COALESCE(p_filed_reference, '')), '');
    IF v_ref IS NULL THEN
        RAISE EXCEPTION 'WHT_FILED_REFERENCE_REQUIRED|%', v_month
          USING HINT = '填 IRAS S45 申报的回执/参考号 —— 一笔交代不出出处的缴款,日后无从对账';
    END IF;

    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- 【银行必须是本位币户,而这一条【故意】比 pay_payroll_cpf 严】
    -- IRAS 只收新元。pay_payroll_cpf 允许 1010 却把两条腿都按本位币记 ——
    -- 那意味着一笔从美元户走的钱会被记成等额新元离开,而实际离开的是美元。
    -- 那一支不在本刀范围内(不顺手改别人的函数),但这一支不复制它。
    v_bank := COALESCE(p_bank_account, '1000');
    IF v_bank NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', v_bank;
    END IF;
    IF bank_native_currency(v_bank) <> v_base THEN
        RAISE EXCEPTION 'WHT_REMIT_BANK_NOT_BASE|%|%', v_bank, bank_native_currency(v_bank)
          USING HINT = 'IRAS 只收本位币 —— 从外币户汇出去要先兑换,而那笔兑换是它自己的一笔交易';
    END IF;

    -- 【欠多少从那张视图读,不在这里再算一遍】视图是唯一的实现,而它对
    -- 冲销的处理(经 journal_activity_lines)是这条链上最容易写错的一段。
    -- 在这里重算 = 第二份实现,而两份会在写下来那天一致、之后悄悄分开。
    SELECT unremitted_base INTO v_amount
    FROM wht_liability_by_month WHERE period_month = v_month;

    IF COALESCE(v_amount, 0) <= 0 THEN
        RAISE EXCEPTION 'WHT_NOTHING_TO_REMIT|%|%', v_month, COALESCE(v_amount, 0)
          USING HINT = '这个月没有未汇的代扣税 —— 也可能是已经汇过了(补汇是新的一行,不是改旧的那一行)';
    END IF;

    -- ★ PAY-REQ-1 Batch B:申请冻结的是【提交那一刻】推导出来的数,CFO 批的就是它。
    --   付款那一刻推导值变了(这个月又进了一笔带代扣的付款、有一笔被冲销、有人手工调了 2150),
    --   就按名拒 —— 不许悄悄汇一个没人批过的数。撤回这张、按新数重提。
    IF p_expected_amount IS NOT NULL AND v_amount <> p_expected_amount THEN
        RAISE EXCEPTION 'WHT_REMIT_AMOUNT_CHANGED|%|%|%', v_month, p_expected_amount, v_amount
          USING HINT = '申请批的是提交时的数;现在推导出来的不一样了 —— 撤回这张申请,按新数重提';
    END IF;

    -- 分录走【普通过账路径】,所以期间锁照常生效 —— 与 CPF 同一条:
    -- 一笔汇款不因为它是法定义务就可以进一个已经关掉的月份。
    v_je := post_journal_entry(
        p_remitted_on,
        'Withholding tax remittance ' || to_char(v_month, 'YYYY-MM'),
        'wht_remittance', v_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2150', 'side', 'debit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'WHT for ' || to_char(v_month, 'YYYY-MM')),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', v_base, 'amount_ccy', v_amount,
                'line_memo', 'IRAS ' || v_ref)));

    -- 编号:同一个月可以有多笔(补汇),第二笔起带序号。
    -- 咨询锁串行化,与 EXP/JE/收付款的取号手法一致。
    PERFORM pg_advisory_xact_lock(hashtext('wht_remit_' || to_char(v_month, 'YYYY-MM'))::bigint);
    SELECT COUNT(*) + 1 INTO v_seq FROM wht_remittances WHERE period_month = v_month;
    v_code := document_type_prefix('wht_remittance') || '-' || to_char(v_month, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    INSERT INTO wht_remittances (id, code, period_month, remitted_on, amount_base,
                                 filed_reference, journal_entry_id, notes, created_by)
    VALUES (v_id, v_code, v_month, p_remitted_on, v_amount,
            v_ref, (v_je->>'entry_id')::uuid, p_notes, auth.uid());

    RETURN jsonb_build_object(
        'remittance_id', v_id,
        'code', v_code,
        'period_month', v_month,
        'remitted_on', p_remitted_on,
        'amount_base', v_amount,
        'currency', v_base,
        'filed_reference', v_ref,
        'journal_code', v_je->>'code',
        'entry_id', v_je->>'entry_id');
END;
$function$
;

-- db/functions/record_bank_transfer_internal.sql
-- PAY-REQ-1 · Batch B(2026-09-23):record_bank_transfer 的函数体搬到这里,拿掉了权限检查。
-- 下面是它原来的抬头,照录:
--
-- 行内转账(FIN-1b)。两边金额照银行水单;分录两条银行线,各记各的本币 ——
-- 两个账户各自的对账单都要能认领自己那条(B3,本切的全部要点)。
-- 跨币种:外币线 fx = 实际隐含汇率(对方金额 ÷ 本方金额),分录恰好配平,
-- 【不出汇兑损益行】—— 已实现差异的归属是 Part C 待定的会计政策,这里不预设。
-- 同币种:两边必须相等(不然配不平;手续费另有各自的记法),fx 恒 1,零汇率依赖。
-- 期间锁由 post_journal_entry 统一把守(PERIOD_LOCKED)。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreqb-transfers-and-wht-through-requests.sql.

CREATE OR REPLACE FUNCTION public.record_bank_transfer_internal(p_transfer_date date, p_from_account text, p_to_account text, p_amount_out numeric, p_amount_in numeric, p_bank_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base     text;   -- OPS-8:本位币从 currencies.is_base 读
    v_from_ccy text;
    v_to_ccy   text;
    v_fx_out   numeric;
    v_fx_in    numeric;
    v_je       jsonb;
    v_id       uuid;
BEGIN
    -- OPS-8:本位币是【数据】(currencies.is_base),不是字面量。
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- ★ PAY-REQ-1 Batch B:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回。
    --   唯一的外门是 pay_payment_request(finance.edit,且只执行一张已批准的转账申请);
    --   payment_request_dry_run 在提交与批准时照同一套规矩核一遍再回滚。

    IF p_from_account IS NULL OR p_from_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_from_account, '?');
    END IF;
    IF p_to_account IS NULL OR p_to_account NOT IN ('1000','1010') THEN
        RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_to_account, '?');
    END IF;
    IF p_from_account = p_to_account THEN
        RAISE EXCEPTION 'TRANSFER_SAME_ACCOUNT|%', p_from_account;
    END IF;
    IF p_amount_out IS NULL OR p_amount_out <= 0 OR p_amount_in IS NULL OR p_amount_in <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_transfer_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    -- FIN-CHAIN-1(Tim AP-RECON-1 Batch B Q6,2026-10-20 落地):钱离开银行是一件【已经发生】的事 —— 日期晚于今天按名拒(与 record_payment_internal 同一句)。
    IF p_transfer_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|bank_transfer|%|%', p_transfer_date, CURRENT_DATE;
    END IF;

    v_from_ccy := bank_native_currency(p_from_account);
    v_to_ccy   := bank_native_currency(p_to_account);

    -- 同币种:没有 FX 这回事,两边必须相等
    IF v_from_ccy = v_to_ccy AND p_amount_out <> p_amount_in THEN
        RAISE EXCEPTION 'TRANSFER_AMOUNTS_UNEQUAL|%|%', p_amount_out, p_amount_in;
    END IF;

    -- 本位币侧 fx=1;外币侧 fx=本笔实际隐含汇率(两边都是实际数,分录恰好配平)
    v_fx_out := CASE WHEN v_from_ccy = v_base THEN 1 ELSE p_amount_in / p_amount_out END;
    v_fx_in  := CASE WHEN v_to_ccy   = v_base THEN 1 ELSE p_amount_out / p_amount_in END;

    v_je := post_journal_entry(
        p_transfer_date,
        format('Transfer %s -> %s%s', p_from_account, p_to_account,
               CASE WHEN p_bank_reference IS NULL THEN '' ELSE ' (' || p_bank_reference || ')' END),
        'transfer',
        NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', p_to_account,   'side', 'debit',
                               'currency', v_to_ccy,   'amount_ccy', p_amount_in,  'fx_rate', v_fx_in),
            jsonb_build_object('account_code', p_from_account, 'side', 'credit',
                               'currency', v_from_ccy, 'amount_ccy', p_amount_out, 'fx_rate', v_fx_out)));

    INSERT INTO bank_transfers (transfer_date, from_account, to_account, amount_out, amount_in,
                                bank_reference, notes, journal_entry_id)
    VALUES (p_transfer_date, p_from_account, p_to_account, p_amount_out, p_amount_in,
            p_bank_reference, p_notes, (v_je->>'entry_id')::uuid)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('transfer_id', v_id, 'journal_code', v_je->>'code',
                              'entry_id', v_je->>'entry_id');
END;
$function$;

CREATE OR REPLACE FUNCTION public.close_period(p_period_end date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_locked   date;
    v_count    integer;
    v_debits   numeric;
    v_credits  numeric;
    v_new_lock date;
    v_dep      numeric;
    v_run_n    integer;
    v_runs     text;
    v_side     jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL
       OR p_period_end <> (date_trunc('month', p_period_end) + interval '1 month - 1 day')::date THEN
        RAISE EXCEPTION 'NOT_MONTH_END|%', COALESCE(p_period_end::text, '?');
    END IF;

    SELECT locked_before INTO v_locked FROM finance_settings WHERE id FOR UPDATE;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'ALREADY_CLOSED|%', v_locked;
    END IF;

    v_dep := (preview_depreciate_fixed_assets(p_period_end)->>'total_delta')::numeric;
    IF COALESCE(v_dep, 0) > 0 THEN
        RAISE EXCEPTION 'DEPRECIATION_OUTSTANDING|%|%', p_period_end, v_dep;
    END IF;

    -- ★ INV-VAL-1 R8:第五条 —— 已提交但从未分摊成本的加工单挡住关账。
    -- 与折旧那一条同形(都是"这个月还欠着一件必须做完的事"),所以紧挨着它。
    -- U1-B:判据抽成 processing_runs_blocking_close —— 月结清单读同一支,两边从此数的是同一样东西。
    SELECT b.run_count, b.run_codes
      INTO v_run_n, v_runs
      FROM processing_runs_blocking_close(p_period_end) b;
    IF COALESCE(v_run_n, 0) > 0 THEN
        RAISE EXCEPTION 'PROCESSING_COSTS_UNALLOCATED|%|%|%', p_period_end, v_run_n, v_runs
          USING HINT = '这些加工单已提交但从未分摊成本 —— 料已经动了,而 1200 还没有被解除。'
                    || '在关账之前把它们分摊掉,或者冲销掉不该存在的那些。';
    END IF;

    -- ★ FIN-CHAIN-1(Tim 2026-10-20,AP-RECON-1 Q11 的裁定):清单 ↔ 总账有【未解释】的差,就不许关账。
    -- 判据就是月结页那一步读的那一支(list_ledger_reconciliation):它不截日 —— 关 M 月时问的是【此刻】全账的勾稽,
    -- 所以 M 之后才出现的差同样挡住关 M(Tim 认的取舍:宁可严,而且按名说出来)。
    -- 一边答不上来(调用者看不见那一侧的价格,refusal 非空)也按名拒 —— 答不上来不是对得上,绝不读成 0。
    FOR v_side IN SELECT s FROM jsonb_array_elements(list_ledger_reconciliation() -> 'sides') s LOOP
        IF v_side ->> 'refusal' IS NOT NULL OR v_side ->> 'unexplained_base' IS NULL THEN
            RAISE EXCEPTION 'CLOSE_RECON_UNANSWERABLE|%|%', v_side ->> 'side', COALESCE(v_side ->> 'refusal', 'NO_ANSWER');
        END IF;
        IF (v_side ->> 'unexplained_base')::numeric <> 0 THEN
            RAISE EXCEPTION 'CLOSE_LEDGER_LIST_UNEXPLAINED|%|%', v_side ->> 'side', v_side ->> 'unexplained_base';
        END IF;
    END LOOP;

    SELECT COUNT(DISTINCT jl.entry_id),
           round(COALESCE(SUM(jl.debit), 0), 2),
           round(COALESCE(SUM(jl.credit), 0), 2)
    INTO v_count, v_debits, v_credits
    FROM journal_lines jl
    JOIN journal_entries je ON je.id = jl.entry_id
    WHERE je.entry_date <= p_period_end;

    IF v_debits <> v_credits THEN
        RAISE EXCEPTION 'TRIAL_BALANCE_UNBALANCED|%|%', v_debits, v_credits;
    END IF;

    v_new_lock := p_period_end + 1;

    INSERT INTO period_closes (period_end, notes, entries_count, total_debits, total_credits)
    VALUES (p_period_end, p_notes, v_count, v_debits, v_credits);

    UPDATE finance_settings
    SET locked_before = v_new_lock, updated_by = auth.uid()
    WHERE id;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'locked_before', v_new_lock,
        'entries_count', v_count,
        'total_debits', v_debits,
        'total_credits', v_credits
    );
END;
$function$
;

-- db/functions/management_pack_data.sql
-- GLEXPORT-1:一个月的管理报表包 —— **它自己一个数都不算。**
--
-- ★【本函数的全部工作是【调用】,而那不是偷懒,是这一刀的要求】★
--   包里的每一个数字都已经有一支函数在算它,而屏幕上也已经印着同一个数。
--   在这里再算一遍 = 第二份实现,两份会在写下来那天一致、之后悄悄分开 ——
--   这个仓库为这个形状付过四次账(AGENTS.md 的预览规则)。
--   所以下面每一段都是一次调用,并在旁边写明【调的是谁】:
--     · 损益      → pnl_statement(start, end)
--     · 资产负债  → balance_sheet(end)
--     · 现金流量  → cash_flow_statement(start, end)
--     · 应收/应付账龄 → ar_aging_asof / ap_aging_asof
--     · 控制科目勾稽 → gl_control_reconciliation(按机制的分解 —— 不是缺陷检查)
--     · 清单 ↔ 总账   → list_ledger_reconciliation(应收/应付的「未解释」从它来,FIN-CHAIN-1)
--     · 月末外币就绪 → fx_month_end_readiness(视图)
--     · 银行对账     → bank_reconciliations(已冻结的那些行)
--     · 现金预测     → cash_forecasts(已冻结的那一份,不是现算)
--
-- ★【一份实现,两个调用方】★ 屏幕读它,冻结(freeze_management_pack)也读它。
--   于是"屏幕上看到的"与"冻下来的"不可能是两个数 —— 这正是 reprice_split /
--   preview_revalue_foreign_balances 立下的那个形状。
--
-- ★★【账龄的截止日可能【不是】月末,而这必须说出来】★★
--   ar/ap_aging_asof 对未来的截止日按名拒(AGING_AS_OF_FUTURE)。
--   于是【当月】的实时预览取不到月末账龄 —— 取到今天为止的。
--   本函数因此把 aging_as_of 单独返回,并在 caveats 里点名
--   `aging_capped_at_today`。**冻结的包不会遇到这一条**:只有已关账的月份
--   才冻得下来,而已关账的月份月末必在过去。
--
-- 【为什么 balance_sheet 用 end 而账龄用 LEAST(end, today)】资产负债表是纯总账
--   推导,对未来日期没有意见;账龄要读单据的"那一天是什么状态",而未来那一天
--   还没有发生。两者不同,所以两个日期,而不是把其中一个悄悄改成另一个。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【INV-VAL-1(2026-08-31):存货那一节是【自动】冻进来的】
--   本函数早就在调 gl_control_reconciliation 并把【整个返回值】存进
--   'control_reconciliation'。勾稽长出两条存货腿之后,管理包因此自动冻住了
--   存货的账面、明细、每一条具名差异与 unexplained —— 一行都没为它改。
--
--   本刀只补 caveats 里确实缺的两件:
--     · control_unexplained_sides —— 四条腿之后,"有一条没解释干净"必须说得出
--       【是哪一条】;
--     · inventory_section_refused / _refusal —— SUM 会跳过 NULL,于是一条
--       【被拒绝、根本没评估过】的腿会让 control_unexplained 显示 false,
--       那是一句假话。拒绝单独记一条。
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.management_pack_data(p_period_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_aging   date;
    v_base    text;
    v_locked  date;
    v_is_locked boolean;
    v_pnl     jsonb; v_bs jsonb; v_cf jsonb;
    v_ar      jsonb; v_ap jsonb; v_recon jsonb;
    v_fx      jsonb; v_bank jsonb; v_forecast jsonb;
    v_split   jsonb;
    v_unexp   numeric;
    -- INV-VAL-1:冻下来的记录必须说出【是哪一条腿】没解释干净,
    -- 而不只是「有一条腿」。四条腿之后,一个布尔量已经不够用了。
    v_unexp_sides jsonb;
    v_inv_refused boolean;
    v_inv_refusal text;
    -- FIN-CHAIN-1(Tim 2026-10-20,AP-RECON-1 Q8 的改基):应收 / 应付的「未解释」改由清单 ↔ 总账那一支答。
    v_list    jsonb;
    v_list_refused jsonb;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;
    -- 【封顶,而不是拒绝】实时预览要能看当月;拒绝会让当月完全看不见,
    -- 而那比"看到截至今天的账龄并被告知它被封顶了"坏。
    v_aging := LEAST(v_end, CURRENT_DATE);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT locked_before INTO v_locked FROM finance_settings;
    -- 【已关账 = 这个月的每一天都不能再过账】locked_before 是"早于它的都锁了",
    -- 所以判据是 locked_before > period_end,与 file_gst_return 逐字同源。
    v_is_locked := (v_locked IS NOT NULL AND v_locked > v_end);

    -- ── 三张报表:全部是调用 ────────────────────────────────────────────────
    v_pnl := pnl_statement(v_start, v_end);
    v_bs  := balance_sheet(v_end);
    v_cf  := cash_flow_statement(v_start, v_end);

    -- ── 账龄与控制科目勾稽 ──────────────────────────────────────────────────
    v_ar    := ar_aging_asof(v_aging);
    v_ap    := ap_aging_asof(v_aging);
    v_recon := gl_control_reconciliation(v_aging);
    -- ★ FIN-CHAIN-1:gl_control_reconciliation 按【机制】分类(起单/结算/重估),它的"起单差异"会把缺陷一起吸进去
    --   (AP-RECON-1 §3)—— 它的 reconciled = true 只是"差额按机制分完了"。应收与应付【有没有没人解释过的差】
    --   改问 list_ledger_reconciliation(月结页与关账读的同一支)。它不截日:冻进包里的是【冻结那一刻】读到的答案,
    --   所以连同读它的时刻一起存(list_ledger_read_at)。存货两条腿只有旧的那一支在答,照旧从它来。
    v_list := list_ledger_reconciliation() || jsonb_build_object('read_at', now());

    -- ── 月末外币就绪:【读那张视图,不自己判】 ───────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'currency', f.currency, 'has_mid', f.has_mid,
               'mid_rate', f.mid_rate, 'mid_rate_as_of', f.mid_rate_as_of,
               'revalued', f.revalued, 'blocks_close', f.blocks_close) ORDER BY f.currency), '[]'::jsonb)
      INTO v_fx
      FROM fx_month_end_readiness f
     WHERE f.month_end = v_end;

    -- ── 银行对账:这个月有没有对过 ─────────────────────────────────────────
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'account_code', bs.bank_account_code, 'statement_code', bs.code,
               'currency', br.currency, 'as_of', br.as_of,
               'bank_closing_balance', br.bank_closing_balance,
               'book_balance', br.book_balance, 'difference', br.difference,
               'reconciled_at', br.reconciled_at) ORDER BY bs.bank_account_code), '[]'::jsonb)
      INTO v_bank
      FROM bank_reconciliations br
      JOIN bank_statements bs ON bs.id = br.statement_id
     WHERE br.as_of BETWEEN v_start AND v_end
       AND br.superseded_at IS NULL;

    -- ── 现金预测:读【冻下来的那一份】,不现算 ──────────────────────────────
    -- 现算会让"这个包里的预测"与"当时那一份"是两个数,而 CASHFLOW-1 冻结它
    -- 的全部理由就是偏差要拿【过去那一份】比。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'code', cfz.code, 'week_start', cfz.week_start,
               'frozen_at', cfz.frozen_at) ORDER BY cfz.week_start), '[]'::jsonb)
      INTO v_forecast
      FROM cash_forecasts cfz
     WHERE cfz.week_start BETWEEN v_start AND v_end
       AND cfz.superseded_at IS NULL;

    -- ── ★【拆散在两个月的冲销对】★ ─────────────────────────────────────────
    -- 一张分录落在本月、而它的冲销件(或它冲销的那一张)落在【别的月】,
    -- 本月的数字就带着一条没有对手的腿。这【不是错】—— 跨期冲销完全合法,
    -- 年结时尤其常见 —— 但它是「这个月怎么看着不对」最可能的答案,
    -- 而对手件的日期只有一个 join 之遥,所以说出来比让人去猜便宜得多。
    -- 【实测:线上就有三对】JE-2027-0001/2/3(2027-09-05)由
    -- JE-2026-0058/59/60(2026-08-20)冲销 —— 于是 2026-08 带着三条没有原件的
    -- 冲销腿,合计对 2000 影响 −3,703.68,而全时段净额恰好是 0。
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'entry_code', x.code, 'entry_date', x.entry_date,
               'counterpart_code', x.cp_code, 'counterpart_date', x.cp_date,
               'amount_base', x.amt) ORDER BY x.entry_date, x.code), '[]'::jsonb)
      INTO v_split
      FROM (
        -- 本月的原件,冲销件在别的月
        SELECT o.code, o.entry_date, r.code AS cp_code, r.entry_date AS cp_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = o.id) AS amt
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE o.entry_date BETWEEN v_start AND v_end
           AND r.entry_date NOT BETWEEN v_start AND v_end
        UNION ALL
        -- 本月的冲销件,原件在别的月
        SELECT r.code, r.entry_date, o.code, o.entry_date,
               (SELECT COALESCE(SUM(jl.debit), 0) FROM journal_lines jl WHERE jl.entry_id = r.id)
          FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by
         WHERE r.entry_date BETWEEN v_start AND v_end
           AND o.entry_date NOT BETWEEN v_start AND v_end
      ) x;

    -- FIN-CHAIN-1:应收/应付取清单 ↔ 总账那一支;存货两条腿取旧的那一支(只有它在答)。
    SELECT COALESCE(SUM((s->>'unexplained_base')::numeric), 0) INTO v_unexp
      FROM (SELECT s FROM jsonb_array_elements(v_list->'sides') s
            UNION ALL
            SELECT s FROM jsonb_array_elements(v_recon->'sides') s WHERE s->>'side' LIKE 'inventory%') x(s);

    -- ★ INV-VAL-1:【是哪一条腿】。SUM 会把 NULL 跳过去,于是一条【被拒绝、
    -- 根本没评估过】的腿会让 control_unexplained 显示 false —— 那是一句假话。
    -- 所以拒绝单独记一条,不混进"解释干净了"里。
    SELECT COALESCE(jsonb_agg(s->>'side' ORDER BY s->>'side'), '[]'::jsonb)
      INTO v_unexp_sides
      FROM (SELECT s FROM jsonb_array_elements(v_list->'sides') s
            UNION ALL
            SELECT s FROM jsonb_array_elements(v_recon->'sides') s WHERE s->>'side' LIKE 'inventory%') x(s)
     WHERE (s->>'unexplained_base') IS NOT NULL
       AND (s->>'unexplained_base')::numeric <> 0;

    -- 清单 ↔ 总账那一边答不上来(看不见那一侧的价格)是一句【具名的拒绝】,不是"解释干净了"。
    SELECT COALESCE(jsonb_agg(s->>'side' ORDER BY s->>'side'), '[]'::jsonb)
      INTO v_list_refused
      FROM jsonb_array_elements(v_list->'sides') s
     WHERE s->>'refusal' IS NOT NULL;

    SELECT bool_or(s->>'subledger_basis' = 'refused'),
           max(s->>'refusal')
      INTO v_inv_refused, v_inv_refusal
      FROM jsonb_array_elements(v_recon->'sides') s
     WHERE s->>'side' LIKE 'inventory%';

    RETURN jsonb_build_object(
        'period_month',  v_start,
        'period_start',  v_start,
        'period_end',    v_end,
        'aging_as_of',   v_aging,
        'generated_on',  CURRENT_DATE,
        'base_currency', v_base,
        'locked_before', v_locked,
        'month_locked',  v_is_locked,
        'pnl',           v_pnl,
        'balance_sheet', v_bs,
        'cash_flow',     v_cf,
        'ar_aging',      v_ar,
        'ap_aging',      v_ap,
        'control_reconciliation', v_recon,
        'list_ledger_reconciliation', v_list,
        'fx_month_end',  v_fx,
        'bank_reconciliations', v_bank,
        'cash_forecasts', v_forecast,
        'split_reversal_pairs', v_split,
        -- ★【这个包看不见什么 —— 逐条,而不是留给读的人猜】★
        -- 预测那一刀立的规矩:一份悄悄漏掉一整类东西的报表,是一个会被人当真
        -- 的数字。所以缺席是【具名的】,而且带着它自己的判据。
        'caveats', jsonb_build_object(
            'month_not_locked',        NOT v_is_locked,
            'aging_capped_at_today',   (v_aging < v_end),
            'fx_missing_mid',          EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'has_mid')::boolean IS NOT TRUE),
            'fx_not_revalued',         EXISTS (SELECT 1 FROM jsonb_array_elements(v_fx) f
                                                WHERE (f->>'revalued')::boolean IS NOT TRUE),
            'control_unexplained',     (v_unexp <> 0),
            'control_unexplained_base', v_unexp,
            -- ★ INV-VAL-1(R3/4b):冻结的记录自己说出是哪一条腿没解释干净。
            'control_unexplained_sides', v_unexp_sides,
            -- ★ FIN-CHAIN-1:应收/应付的「未解释」此后来自 list_ledger_reconciliation,读于 list_ledger_read_at。
            'control_unexplained_basis', 'list_ledger_reconciliation',
            'list_ledger_read_at',     v_list->'read_at',
            'list_ledger_refused_sides', v_list_refused,
            -- ★【存货这一节被拒绝了,而拒绝【不是】零】(R3/4c)
            -- 已关账的月份 aging_as_of = 月末(过去),存货明细侧重建不出来,
            -- 于是这一节是一句【具名的拒绝】。它必须与"存货为零"长得完全不一样:
            -- 一个读到 0.00 的人会把它抄进底稿,读到拒绝的人会去问为什么。
            'inventory_section_refused', COALESCE(v_inv_refused, false),
            'inventory_section_refusal', v_inv_refusal,
            'split_reversal_pairs_n',  jsonb_array_length(v_split),
            'no_bank_reconciliation',  (jsonb_array_length(v_bank) = 0),
            'no_cash_forecast',        (jsonb_array_length(v_forecast) = 0)));
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_sales_order_status(p_order_id uuid, p_to text, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_order sales_orders%ROWTYPE;
    v_cust  record;
    v_ok    boolean;
    v_res   record;
    v_freed numeric := 0;
    v_left  int;
    v_inv   text;
    v_short record;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_order FROM sales_orders WHERE id = p_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_order_id::text, '?');
    END IF;

    -- 【允许的去处,逐个状态写出来】
    -- SO-3b:履约两态落地,而它们【不在这张表的右边】—— partially_shipped /
    -- shipped 由 ship_order 按"已发 vs 已订"现算后写入(经 so_status_ctx),
    -- 不是人手点的。这张表只管【人能点的那些】。
    -- 【closed 现在要求发完货】confirmed → closed 那条路没了:一张还没发货的
    -- 订单"走完了"是说不通的,而此前它是可点的。
    -- 【发出去的货收不回来】partially_shipped 是终点之一:2500 已经释放进 4000、
    -- 库存已经离开台账,作废它需要的是【贷项凭证】(sales_records 表头停放的
    -- 未来概念),不是一次状态跳转。shipped 只能走向 closed,同理。
    -- ★ FIN-CHAIN-1(Tim 2026-10-20,APR-5 Q12 · Step 0 Q5):partially_shipped → closed 是一次【显式的短装收尾】——
    --   理由必填;还有【开了票、没发、也没被贷项取消】的数量就按名拒(先开未发货取消的贷项);
    --   剩下的预留当场释放;写一行历史。从不自动发生。作废(cancelled)仍然不许 —— 发出去的货收不回来。
    v_ok := CASE v_order.status
        WHEN 'draft'             THEN p_to IN ('confirmed','cancelled')
        WHEN 'confirmed'         THEN p_to IN ('cancelled')
        WHEN 'partially_shipped' THEN p_to IN ('closed')   -- 短装收尾(FIN-CHAIN-1);作废仍走贷项凭证
        WHEN 'shipped'           THEN p_to IN ('closed')
        WHEN 'closed'            THEN false      -- 终态
        WHEN 'cancelled'         THEN false      -- 终态
        ELSE false
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'SO_TRANSITION_NOT_ALLOWED|%|%', v_order.status, p_to;
    END IF;

    IF p_to = 'cancelled' AND (p_reason IS NULL OR btrim(p_reason) = '') THEN
        RAISE EXCEPTION 'SO_CANCEL_REASON_REQUIRED|%', v_order.code;
    END IF;

    -- ★ FIN-CHAIN-1(Tim 2026-10-20,APR-5 Q12 · Step 0 Q4):一张挂着【在册订单流发票】的订单不许作废 ——
    --   作废了它,那张票还在册:应收与 2500 的合同负债就挂在一张已经不存在的订单上。按名拒,
    --   并点名那张票;先提发票作废申请(CFO 批),票作废之后再来作废订单。不替人自动提申请(Q4)。
    IF p_to = 'cancelled' THEN
        SELECT i.code INTO v_inv
          FROM invoices i
         WHERE i.sales_order_id = p_order_id AND i.kind = 'order' AND i.status = 'issued'
         ORDER BY i.code
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SO_CANCEL_HAS_LIVE_INVOICE|%|%', v_order.code, v_inv;
        END IF;
    END IF;

    -- ★ FIN-CHAIN-1:短装收尾的两道闸 —— 理由必填;每一条订单行【开票 − 未发货取消 − 已发】必须 ≤ 0。
    --   开票 − 取消只有一处推导(sales_order_line_releasable_all,ship_order 的天花板读同一张);已发 = Σ shipment_lines。
    --   一张在等 CFO 的未发货取消贷项还没有落账,所以那一截仍然算"没取消" —— 等它批了再收尾。
    IF v_order.status = 'partially_shipped' AND p_to = 'closed' THEN
        IF p_reason IS NULL OR btrim(p_reason) = '' THEN
            RAISE EXCEPTION 'SO_CLOSE_REASON_REQUIRED|%', v_order.code;
        END IF;
        SELECT l.line_no, x.open_qty INTO v_short
          FROM sales_order_lines l
          CROSS JOIN LATERAL (
              SELECT COALESCE((SELECT sum(ra.releasable_qty) FROM sales_order_line_releasable_all ra
                                WHERE ra.sales_order_line_id = l.id), 0)
                   - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                                WHERE sl.sales_order_line_id = l.id), 0) AS open_qty) x
         WHERE l.sales_order_id = p_order_id AND x.open_qty > 0
         ORDER BY l.line_no
         LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SO_CLOSE_INVOICED_UNSHIPPED|%|%|%', v_order.code, v_short.line_no, trim_scale(v_short.open_qty);
        END IF;
    END IF;

    -- 【确认要看客户的信用冻结】一张确认了的订单是一个承诺;对一个被冻结的
    -- 客户做承诺,与 record_output_sale 拒绝给他发货是同一条判断,只是早一步。
    -- 【只看 credit_hold,不看额度】额度是随敞口变的,而订单还没产生敞口 ——
    -- 拿一个将来的数去拒绝一张今天的单,会把"可能超限"演成"已经超限"。
    IF p_to = 'confirmed' THEN
        SELECT credit_hold, code INTO v_cust FROM customers WHERE id = v_order.customer_id;
        IF v_cust.credit_hold THEN
            RAISE EXCEPTION 'SO_CUSTOMER_ON_HOLD|%', v_cust.code;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM sales_order_lines WHERE sales_order_id = p_order_id) THEN
            RAISE EXCEPTION 'SO_NO_LINES|%', v_order.code;
        END IF;
    END IF;

    -- ════════════════════════════════════════════════════════════════════════
    -- SO-2:【作废即释放,而且在改状态【之前】做】
    -- 一张作废的订单不该继续扣着货 —— 那批货会以 committed 的身份留在账上,
    -- 谁也卖不掉、谁也投不了,而屏幕上没有任何东西解释为什么。
    -- 【为什么在 UPDATE 之前】释放走 release_reservation,它会重新读这一行;
    -- 放在后面就得让它面对一个已经作废的订单,那是给自己造一个例外。
    -- 放在前面,任何一条释放失败都会把整个作废一起回滚 —— 要么单据作废了、
    -- 货也放回来了,要么两件都没发生。
    -- 【closed 不释放,那是另一件事】走完的订单,它的货是发出去了,不是放回去了。
    -- ★ FIN-CHAIN-1:【短装收尾】要释放 —— 没发的那一截不会再发了,扣着它就是谁也卖不掉的货。
    -- ════════════════════════════════════════════════════════════════════════
    IF p_to = 'cancelled' OR (v_order.status = 'partially_shipped' AND p_to = 'closed') THEN
        FOR v_res IN
            SELECT r.id, r.qty
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL AND r.consumed_at IS NULL
             ORDER BY r.created_at
        LOOP
            PERFORM release_reservation(v_res.id, NULL,
                CASE WHEN p_to = 'cancelled' THEN 'order cancelled: ' ELSE 'order closed short: ' END || btrim(p_reason));
            v_freed := v_freed + v_res.qty;
        END LOOP;

        -- 【断言,不是假设】上面那个循环跑完之后【不该】还剩活预留。
        -- 一条 release 悄悄没生效(将来有人给它加了一个提前 RETURN),
        -- 结果是一张作废的单还扣着货 —— 而那件事不会有任何东西报出来。
        SELECT count(*) INTO v_left
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE l.sales_order_id = p_order_id AND r.released_at IS NULL AND r.consumed_at IS NULL;
        IF v_left <> 0 THEN
            RAISE EXCEPTION 'SO_CANCEL_RESERVATIONS_LEFT|%|%', v_order.code, v_left;
        END IF;
    END IF;

    -- 上下文标记:让冻结守卫知道是【转换函数】在动状态列(同 po_status_ctx)
    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status       = p_to,
           confirmed_at = CASE WHEN p_to = 'confirmed' THEN now() ELSE confirmed_at END,
           closed_at    = CASE WHEN p_to = 'closed'    THEN now() ELSE closed_at END,
           cancelled_at = CASE WHEN p_to = 'cancelled' THEN now() ELSE cancelled_at END,
           cancel_reason= CASE WHEN p_to = 'cancelled' THEN p_reason ELSE cancel_reason END,
           updated_at   = now(),
           updated_by   = auth.uid()
     WHERE id = p_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail)
    VALUES (p_order_id, p_to, p_reason);

    RETURN jsonb_build_object('id', p_order_id, 'status', p_to,
                              'released_qty', v_freed);
END;
$function$

;

-- db/functions/create_invoice.sql
-- GST-2(2026-08-25):发票开始【携带税】,并过一张【只有税】的分录。
-- 此前它读 finance_settings.gst_rate_pct 这个标量算税、且一张分录都不过。
-- 标量表达不了税率史(2022 年那张票永远是 7%),也表达不了零税率 / 豁免 /
-- 不在范围内这三件税率都为零、进的格子却完全不同的事。
-- 【分录只过税】收入在【销售】那一刻已经认过(借 1100 / 贷 4000);
-- 开票再认一次就是把同一笔生意记两遍。而税从来没有人过过 ——
-- invoices.total_base 一直写着 subtotal + tax,这张分录是第一次在总账里兑现它。
-- 【税码与税率冻在行上】已开出的发票永不按今天的设置重算它的税。
CREATE OR REPLACE FUNCTION public.create_invoice(p_customer_id uuid, p_sales_record_ids uuid[], p_issue_date date DEFAULT NULL::date, p_payment_terms_days integer DEFAULT NULL::integer, p_notes text DEFAULT NULL::text, p_terms_text text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cust        customers%ROWTYPE;
    -- PARTY-1:开票快照里的联系人 —— 取本客户的【主联系人】那一行
    v_contact     counterparty_contacts%ROWTYPE;
    v_issue       date := COALESCE(p_issue_date, CURRENT_DATE);
    v_terms       integer;
    v_due         date;
    v_invoice_id  uuid := gen_random_uuid();
    v_year        integer;
    v_seq         integer;
    v_code        text;
    v_sale_id     uuid;
    v_seen        uuid[] := ARRAY[]::uuid[];
    v_sale        record;
    v_currency    text;
    v_no          integer := 0;
    v_subtotal    numeric := 0;
    v_tax_code    text;
    v_tax_rate    numeric := 0;
    v_tax         numeric := 0;
    v_line_tax    numeric;
    v_existing    text;
    v_base        text;
    v_je          jsonb;
    v_entry_id    uuid;
    v_lines       jsonb := '[]'::jsonb;  -- 第一趟收集,第二趟落库
    v_line        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT c.code INTO v_base FROM currencies c WHERE c.is_base;
    -- 1. 客户
    SELECT * INTO v_cust FROM customers
    WHERE id = p_customer_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', COALESCE(p_customer_id::text, '?');
    END IF;

    -- PARTY-1:主联系人。**没有也不拒绝** —— 一张开给没填联系人的客户的发票
    -- 一直都是合法的,本刀不顺手把它变成一道新闸(那会是一次没人裁定过的收紧)。
    -- 没有时 v_contact 的三个字段是 NULL,快照里那三个键就是 NULL。
    SELECT * INTO v_contact FROM counterparty_contacts
     WHERE customer_id = v_cust.id AND is_primary AND deleted_at IS NULL;

    -- AP-RECON-1 Batch B(Tim AP-RECON-1 Q7):税点就是开票日,一张明天的发票会把销项税记进一个还没到的期间,日期晚于今天按名拒。
    IF v_issue > CURRENT_DATE THEN
        RAISE EXCEPTION 'DOCUMENT_DATE_IN_FUTURE|invoice|%|%', v_issue, CURRENT_DATE;
    END IF;
    IF p_sales_record_ids IS NULL OR array_length(p_sales_record_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    -- ★★【2. 账期:显式 > 客户设定 > 【按名拒】—— 原来这里兜底 30 天】★★
    --   **PARTY-1(2026-08-29)把那个 30 拿掉了,而它不是一个装饰性的默认值。**
    --   实测:线上三个客户 payment_terms_days 全是 NULL,于是【九张发票无一例外】
    --   带着一个编出来的 30 天账期 —— 而 due_date 喂着 ar_aging_asof、
    --   customer_statement_data(对账单【与】催收,催收还把它冻起来)与
    --   cash_forecast_data。**一个编出来的到期日于是同时进了四个看起来权威的地方。**
    --   这是 FIN-10 那条规矩换了身衣服:那条说"决定期间的【日期】不许有默认值",
    --   这里是"决定到期日的【账期】不许有默认值"。
    --   【为什么不回填】把 30 写进客户主数据,就是把我的猜测变成一条永久的、
    --   而且再也标不出来的事实。已经开出去的九张单【保留】它们的 30 ——
    --   那是当时发出去的东西,历史不改写。
    v_terms := COALESCE(p_payment_terms_days, v_cust.payment_terms_days);
    IF v_terms IS NULL THEN
        RAISE EXCEPTION 'CUSTOMER_PAYMENT_TERMS_NOT_SET|%|%', v_cust.code, v_cust.legal_name
          USING HINT = '这张发票的到期日没有来路:客户主数据里没有付款账期,这次调用也没有给一个。去【客户 → 编辑】把「付款账期(天)」填上,或者在开票时明确指定一个 —— 系统不再替你假设 30 天。';
    END IF;
    IF v_terms < 0 THEN
        RAISE EXCEPTION 'TERMS_INVALID|%', v_terms;
    END IF;
    v_due := v_issue + v_terms;

    -- ════════════════════════════════════════════════════════════════════════
    -- 3. 【税点在这里】GST-2:税码经"往来对象默认 + 本单改写"解析,
    --    税率按【这张发票自己的开票日】解析 —— 两者一起冻在行上。
    -- ════════════════════════════════════════════════════════════════════════
    IF gst_registered() THEN
        v_tax_code := resolve_tax_code(p_tax_code, v_cust.default_tax_code, 'output', 'customer');
        v_tax_rate := tax_rate_for(v_tax_code, v_issue);
    ELSE
        -- 【未注册:与建 GST 之前一模一样】不解析、不盖码、不过分录。
        -- 【但传了码要按名拒,不能悄悄忽略】悄悄忽略会让一个以为自己在计税的人
        -- 以为计了 —— 而屏幕上一切正常。
        IF NULLIF(btrim(COALESCE(p_tax_code, '')), '') IS NOT NULL THEN
            RAISE EXCEPTION 'GST_NOT_REGISTERED|%', p_tax_code;
        END IF;
        v_tax_code := NULL;
        v_tax_rate := 0;
    END IF;

    -- 4. 无缝编号(按 issue_date 的年份),咨询锁串行化;回滚即释放号码
    v_year := EXTRACT(YEAR FROM v_issue)::integer;
    PERFORM pg_advisory_xact_lock(hashtext('invoice_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM invoices
    WHERE code LIKE document_type_prefix('invoice') || '-' || v_year::text || '-%';
    v_code := document_type_prefix('invoice') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');

    -- 5. 第一趟:逐张销售校验(存在 → 归属 → 未被占用 → 币种一致)并累计金额。
    FOREACH v_sale_id IN ARRAY p_sales_record_ids
    LOOP
        IF v_sale_id = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_SALE|%',
                COALESCE((SELECT ob.code FROM sales_records sr
                          JOIN output_batches ob ON ob.id = sr.output_batch_id
                          WHERE sr.id = v_sale_id), v_sale_id::text);
        END IF;
        v_seen := v_seen || v_sale_id;

        SELECT sr.id, sr.customer_id, sr.quantity, sr.unit_price, sr.currency,
               sr.amount_base, ob.code AS batch_code, ob.unit, m.name AS material_name,
               sr.sales_order_line_id
        INTO v_sale
        FROM sales_records sr
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        LEFT JOIN materials m ON m.id = ob.material_id
        WHERE sr.id = v_sale_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SALE_NOT_FOUND|%', v_sale_id;
        END IF;

        -- sales_records.customer_id 可空 —— 批次可能在客户还没登记时就卖了。
        -- SAL-C:【但无主的销售不能开给客户】。开票是对外声称"这个人欠这笔钱";
        -- 声称之前,销售自己得先记下这件事。出路是先补挂
        -- (attribute_sale_customer),不是在这里默认它属于收票人。
        -- ★ FIN-CHAIN-1(Tim APR-5 Q12,2026-10-20):【订单流的销售已经开过票了】—— 它是 ship_order 写的
        --   (sales_order_line_id 非空),它的钱在订单发票(kind='order')上,而那张票在发货【之前】就开了。
        --   再开一张 sale 型的票 = 同一批货向客户要两次钱,而 ALREADY_INVOICED 看不见它(订单发票的行挂在
        --   订单行上,不挂在销售记录上)。按名拒;/finance/invoices/new 的候选清单也不列它们。
        IF v_sale.sales_order_line_id IS NOT NULL THEN
            RAISE EXCEPTION 'SALE_IS_ORDER_FLOW|%', v_sale.batch_code;
        END IF;
        IF v_sale.customer_id IS NULL THEN
            RAISE EXCEPTION 'SALE_NOT_ATTRIBUTED|%', v_sale.batch_code;
        END IF;
        IF v_sale.customer_id <> p_customer_id THEN
            RAISE EXCEPTION 'SALE_WRONG_CUSTOMER|%', v_sale.batch_code;
        END IF;

        SELECT i.code INTO v_existing
        FROM invoice_lines il
        JOIN invoices i ON i.id = il.invoice_id
        WHERE il.sales_record_id = v_sale_id AND NOT il.invoice_voided
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'ALREADY_INVOICED|%|%', v_sale.batch_code, v_existing;
        END IF;

        IF v_currency IS NULL THEN
            v_currency := v_sale.currency;
        ELSIF v_currency <> v_sale.currency THEN
            RAISE EXCEPTION 'MIXED_CURRENCY|%|%', v_currency, v_sale.currency;
        END IF;

        -- 【逐行算税、逐行取整,行加起来就是表头】口径与行金额一致:
        -- 表头的税 = Σ 行税,不是 round(Σ 行净额 × 税率) —— 两种算法差几分,
        -- 而客户手里那张纸上印的是行。
        v_line_tax := CASE WHEN v_tax_code IS NULL THEN 0
                           -- PO-GST-1:提取成 tax_amount_for(表达式逐字未变)。
                           ELSE tax_amount_for(v_sale.amount_base, v_tax_rate) END;

        v_no := v_no + 1;
        v_lines := v_lines || jsonb_build_object(
            'sales_record_id', v_sale_id,
            'line_no', v_no,
            'description', v_sale.batch_code || COALESCE(' — ' || v_sale.material_name, ''),
            'quantity', v_sale.quantity,
            'unit', v_sale.unit,
            'unit_price', v_sale.unit_price,
            'amount_base', v_sale.amount_base,
            'tax_base', v_line_tax);

        v_subtotal := v_subtotal + v_sale.amount_base;
        v_tax := v_tax + v_line_tax;
    END LOOP;

    v_subtotal := round(v_subtotal, 2);
    v_tax := round(v_tax, 2);

    -- ════════════════════════════════════════════════════════════════════════
    -- 6. 【只过税的那张分录】借 1100 应收 / 贷 2100 销项税。
    --    零税率 / 豁免 / 不在范围内(税额为 0)不过分录 —— 一条 0 的腿在分录上
    --    读起来像"这一段发生了但金额为零",而且 post_journal_entry 会拒。
    --    供应额本身【不在这张分录里】,它在发票行上;F5 的 box1 从那里推导。
    --    期间锁与年结闸由 post_journal_entry 对 v_issue 统一执行。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_tax <> 0 THEN
        v_je := post_journal_entry(
            v_issue,
            'Invoice ' || v_code || ' GST',
            'invoice', v_invoice_id,
            jsonb_build_array(
                jsonb_build_object('account_code', '1100', 'side', 'debit',
                    'currency', v_base, 'amount_ccy', v_tax,
                    'line_memo', 'output tax ' || v_tax_code),
                jsonb_build_object('account_code', '2100', 'side', 'credit',
                    'currency', v_base, 'amount_ccy', v_tax,
                    'line_memo', 'output tax ' || v_tax_code)));
        v_entry_id := (v_je->>'entry_id')::uuid;
    END IF;

    -- 7. 第二趟:金额已定,一次写对发票头,再落明细行。
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days,
                          currency, subtotal_base, tax_rate_pct, tax_base, total_base,
                          notes, terms_text, bill_to_snapshot, entry_id)
    VALUES (v_invoice_id, v_code, p_customer_id, v_issue, v_due, v_terms,
            v_currency, v_subtotal, v_tax_rate, v_tax, round(v_subtotal + v_tax, 2),
            p_notes, p_terms_text,
            jsonb_build_object(
                'code', v_cust.code,
                'legal_name', v_cust.legal_name,
                'short_name', v_cust.short_name,
                'country', v_cust.country,
                'tax_id', v_cust.tax_id,
                'address', v_cust.address,
                'payment_terms', v_cust.payment_terms,
                'incoterm', v_cust.incoterm,
                -- ★【联系人从 counterparty_contacts 的【主联系人】取,不再从客户那三列取】★
                --   PARTY-1 把那三列搬进了子表并删掉。**已经存下来的快照不受影响**:
                --   它们是自成一体的 jsonb,记的是开票那一刻的事实 —— 变的只是
                --   【下一张】发票从哪儿取。没有主联系人时这三个键是 NULL,
                --   与本刀之前"客户没填联系人"的效果逐字一致。
                'contact_person', v_contact.name,
                'email', v_contact.email,
                'phone', v_contact.phone),
            v_entry_id);

    FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines)
    LOOP
        INSERT INTO invoice_lines (invoice_id, sales_record_id, line_no, description,
                                   quantity, unit, unit_price, amount_base,
                                   tax_code, tax_rate_pct, tax_base)
        VALUES (v_invoice_id,
                (v_line->>'sales_record_id')::uuid,
                (v_line->>'line_no')::integer,
                v_line->>'description',
                (v_line->>'quantity')::numeric,
                v_line->>'unit',
                (v_line->>'unit_price')::numeric,
                (v_line->>'amount_base')::numeric,
                v_tax_code,
                CASE WHEN v_tax_code IS NULL THEN NULL ELSE v_tax_rate END,
                (v_line->>'tax_base')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'invoice_id', v_invoice_id,
        'code', v_code,
        'issue_date', v_issue,
        'due_date', v_due,
        'subtotal_base', v_subtotal,
        'tax_code', v_tax_code,
        'tax_rate_pct', v_tax_rate,
        'tax_base', v_tax,
        'total_base', round(v_subtotal + v_tax, 2),
        'line_count', v_no,
        'currency', v_currency,
        'journal_code', v_je->>'code'
    );
END;
$function$
;

-- ── 3 · B4:新守卫(镜像原样)与它的触发器(与 db/tables/quotes.sql 同一串字)──

-- db/functions/guard_quote_status_through_function.sql
-- FIN-CHAIN-1(Tim 2026-10-20,APR-5 Q12 · APR5-QUOTE-STATUS-DIRECT-UPDATE):**报价的状态只经函数写**。
--
-- 【量过的】写报价状态的三支函数 —— record_qt_issue(draft → issued)· decline_quote(→ declined + 理由)·
-- convert_quote(→ converted + converted_order_id)—— 全是 SECURITY DEFINER;没有一个屏幕直连改 status
-- (app/ 里对 quotes 只有一条 .insert,不带 status)。而 RLS 的 UPDATE / INSERT 策略开在 module.sales.edit 上,
-- 于是持这个码的人此前可以【直连】把一张报价改成 issued / declined / converted —— 绕开签发留痕
-- (qt_issues)、谢绝理由的门与转单的门。
--
-- 【为什么是行级、只看这三列,而不是 sales_records 那种语句级一律拒】报价的其余列【本来就该直连改】
-- (改价改量是报价的用途 —— 表注释)。所以本守卫只认:
--   · UPDATE 改了 status / converted_order_id / decline_reason;
--   · INSERT 带着一个不是 draft 的 status,或者带着 converted_order_id / decline_reason。
-- 属主路径(row_security_active = false —— 三支 SECURITY DEFINER 函数与迁移)一律放行;与
-- guard_sales_record_direct_write · guard_processing_direct_write 同一个判据。
-- 本函数是 SECURITY INVOKER:它要问的正是【调用者】是不是在 RLS 之下。
--
-- 【与 guard_quote_converted_immutable 的先后】同为 BEFORE 行级,按触发器名排序:converted 那一支
-- (trg_quotes_converted_immutable)先跑 —— 对一张已转单的报价,直连改任何列仍然读到 QT_CONVERTED_IMMUTABLE
-- (fixture 72 钉着)。
--
-- NOTE: introduced by db/migrations/2026-10-20-fin-chain-1.sql.

CREATE OR REPLACE FUNCTION public.guard_quote_status_through_function()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|status|%', NEW.status;
        END IF;
        IF NEW.converted_order_id IS NOT NULL THEN
            RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|converted_order_id|%', NEW.status;
        END IF;
        IF NEW.decline_reason IS NOT NULL THEN
            RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|decline_reason|%', NEW.status;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|status|%', OLD.code;
    END IF;
    IF NEW.converted_order_id IS DISTINCT FROM OLD.converted_order_id THEN
        RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|converted_order_id|%', OLD.code;
    END IF;
    IF NEW.decline_reason IS DISTINCT FROM OLD.decline_reason THEN
        RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|decline_reason|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_quotes_status_through_function
    BEFORE INSERT OR UPDATE ON public.quotes
    FOR EACH ROW EXECUTE FUNCTION public.guard_quote_status_through_function();

-- ── 4 · C6:reverse_freight_document 多一个参数 —— 签名变了,先 DROP 旧签名,再按镜像建 ──

DROP FUNCTION public.reverse_freight_document(uuid, text);

CREATE OR REPLACE FUNCTION public.reverse_freight_document(p_freight_document_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_orig freight_documents%ROWTYPE;
    v_settled numeric;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ★ FIN-CHAIN-1(Tim 2026-10-20,Step 0 Q7 · APR4-FREIGHT-REVERSAL-DATED-TODAY):【冲销日由人选,必填,不默认】——
    --   与日记账冲销申请 · 发票作废 · 代扣税缴纳 · 银行划转那四个由人给日期的冲销同一条(FIN-10:决定期间的日期不许默认)。
    --   不许早于原分录(reverse_journal_entry_internal 按名拒 REVERSAL_BEFORE_ORIGINAL);落在已关账的期间按名拒
    --   PERIOD_LOCKED(post_journal_entry)—— 锁永远赢。
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;

    -- 【理由必填,拒绝按名】—— AUDEL 家族那一条。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'FREIGHT_REVERSAL_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM freight_documents WHERE id = p_freight_document_id), '?')
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;

    SELECT * INTO v_orig FROM freight_documents
     WHERE id = p_freight_document_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FREIGHT_NOT_FOUND|%', COALESCE(p_freight_document_id::text, '?');
    END IF;
    IF v_orig.status <> 'posted' THEN
        RAISE EXCEPTION 'FREIGHT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 【已被结清的单据不许冲销】—— 冲掉它,账龄里那一行消失,而指向它的核销行
    -- 原样留着:一笔真的付过的钱,从此挂在一张"不欠任何人"的单据上。
    -- 与 FIN-22 的 EXPENSE_HAS_ASSET 同一条:先把下游拆掉,或走人工分录改正。
    SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa
      JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.freight_document_id = p_freight_document_id;
    IF v_settled > 0 THEN
        RAISE EXCEPTION 'FREIGHT_HAS_SETTLEMENT|%|%', v_orig.code, v_settled
          USING HINT = '这张运费单已经被付过款 —— 先冲掉那笔付款,再冲销单据';
    END IF;

    -- 冲其分录(冲销日 = 人选的那一天;期间锁在 post_journal_entry 内生效)。
    -- 【镜像的是原分录本身】,所以两个方向自动各自对称:进料侧冲掉 1200/5000,
    -- 出境侧冲掉 6300 —— 这个函数一个科目码都不需要知道。
    -- FIN-CHAIN-1:冲销日 = p_reversal_date(此前是 reversal_date_for —— 今天与原分录日里较晚的那个,没有人选得了)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, p_reversal_date,
        'Freight reversal ' || v_orig.code);

    -- 【状态只能从这里改】—— 守卫认这个标记,PostgREST 够不着它。
    PERFORM set_config('evoltrya.freight_reverse_ctx', '1', true);
    UPDATE freight_documents
       SET status = 'reversed', reversed_at = now(), reversed_by = v_user,
           reversal_reason = btrim(p_reason),
           reversal_entry_id = (v_je->>'reversal_id')::uuid,
           updated_by = v_user
     WHERE id = p_freight_document_id;
    PERFORM set_config('evoltrya.freight_reverse_ctx', '', true);   -- 用毕即清

    RETURN jsonb_build_object(
        'freight_document_id', p_freight_document_id, 'code', v_orig.code,
        'direction', v_orig.direction, 'status', 'reversed',
        'reversed_by', v_user, 'reason', btrim(p_reason),
        'reversal_entry_id', v_je->>'reversal_id', 'journal_code', v_je->>'code');
END;
$function$;

-- ── 5 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.reverse_freight_document(uuid, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reverse_freight_document(uuid, text, date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_quote_status_through_function() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_quote_status_through_function() TO authenticated, service_role;

-- ── 6 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.finchain1_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE finchain1_pending_after ON COMMIT DROP AS
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
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'FINCHAIN1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM finchain1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM finchain1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|an account or its roles changed';
    END IF;

    -- ② 十四个科目逐字是 Tim 定的那样:非系统、启用;2600 负债 · 货币性 · 筹资;十三个费用非货币性;2600 不在费用单下拉的集合里
    IF (SELECT count(*) FROM accounts WHERE code IN ('2600', '6010', '6130', '6140', '6210', '6220', '6230', '6240', '6250', '6310', '6410', '6420', '6510', '6520') AND NOT is_system AND is_active) <> 14
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '2600' AND name_en = 'Loan Payable' AND name_zh = '应付借款'
                       AND account_type = 'liability' AND is_monetary AND cash_flow_section = 'financing' AND NOT is_cash)
       OR (SELECT count(*) FROM accounts WHERE code IN ('2600', '6010', '6130', '6140', '6210', '6220', '6230', '6240', '6250', '6310', '6410', '6420', '6510', '6520') AND code <> '2600' AND account_type = 'expense'
            AND NOT is_monetary AND NOT is_cash AND cash_flow_section IS NULL) <> 13
       OR EXISTS (SELECT 1 FROM accounts WHERE code = '2600' AND account_type = 'expense') THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|the fourteen accounts are not as ruled';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变;本事务写进变更记录的只有那十四行新科目
    IF EXISTS ((SELECT b.k, b.id FROM finchain1_pending_before b EXCEPT SELECT a2.k, a2.id FROM finchain1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM finchain1_pending_after a2 EXCEPT SELECT b.k, b.id FROM finchain1_pending_before b)) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM accounts t WHERE code NOT IN ('2600', '6010', '6130', '6140', '6210', '6220', '6230', '6240', '6250', '6310', '6410', '6420', '6510', '6520')) IS DISTINCT FROM (SELECT accounts FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM quotes t ) IS DISTINCT FROM (SELECT quotes FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t ) IS DISTINCT FROM (SELECT sales_orders FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_lines t ) IS DISTINCT FROM (SELECT sales_order_lines FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_order_reservations t ) IS DISTINCT FROM (SELECT sales_order_reservations FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_records t ) IS DISTINCT FROM (SELECT sales_records FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoices t ) IS DISTINCT FROM (SELECT invoices FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM invoice_lines t ) IS DISTINCT FROM (SELECT invoice_lines FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM credit_notes t ) IS DISTINCT FROM (SELECT credit_notes FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM freight_documents t ) IS DISTINCT FROM (SELECT freight_documents FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM management_packs t ) IS DISTINCT FROM (SELECT management_packs FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM period_closes t ) IS DISTINCT FROM (SELECT period_closes FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_periods t ) IS DISTINCT FROM (SELECT payroll_periods FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payroll_lines t ) IS DISTINCT FROM (SELECT payroll_lines FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM wht_remittances t ) IS DISTINCT FROM (SELECT wht_remittances FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM bank_transfers t ) IS DISTINCT FROM (SELECT bank_transfers FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t ) IS DISTINCT FROM (SELECT journal_entries FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t ) IS DISTINCT FROM (SELECT journal_lines FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t ) IS DISTINCT FROM (SELECT payments FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t ) IS DISTINCT FROM (SELECT expenses FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM approval_log t ) IS DISTINCT FROM (SELECT approval_log FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM permissions t ) IS DISTINCT FROM (SELECT permissions FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM role_permissions t ) IS DISTINCT FROM (SELECT role_permissions FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM roles t ) IS DISTINCT FROM (SELECT roles FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM user_roles t ) IS DISTINCT FROM (SELECT user_roles FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM finance_settings t ) IS DISTINCT FROM (SELECT finance_settings FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM ingest_settings t ) IS DISTINCT FROM (SELECT ingest_settings FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM cod_issues t ) IS DISTINCT FROM (SELECT cod_issues FROM finchain1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM list_ledger_residue t ) IS DISTINCT FROM (SELECT list_ledger_residue FROM finchain1_rows_before) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|a pre-existing row changed';
    END IF;
    SELECT COALESCE(string_agg(DISTINCT c.table_name, ', '), '') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM finchain1_log_before), 0) AND c.txid = txid_current();
    IF v_bad NOT IN ('', 'accounts') THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|this migration wrote change_log rows for: %', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;

    -- ④ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    PERFORM set_config('request.jwt.claims', '{"sub":"634c00f9-c3a9-4444-9eed-b624cb6a2a93","role":"authenticated"}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM finchain1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ⑤ 函数与守卫:旧的两参运费冲销不在了,新的三参在;守卫是 INVOKER、触发器挂在 quotes 上
    IF to_regprocedure('public.reverse_freight_document(uuid, text)') IS NOT NULL OR to_regprocedure('public.reverse_freight_document(uuid, text, date)') IS NULL
       OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'reverse_freight_document') <> 1 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|reverse_freight_document: expected exactly the three-argument signature';
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.guard_quote_status_through_function()'::regprocedure)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_quotes_status_through_function'
                       AND tgrelid = 'public.quotes'::regclass AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|the quote status guard is not in place as an invoker trigger';
    END IF;

    -- ⑥ 结构:325 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|expected 325 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')));
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.finchain1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'FINCHAIN1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.finchain1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.finchain1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;

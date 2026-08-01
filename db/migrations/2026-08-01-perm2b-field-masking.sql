-- db/migrations/2026-08-01-perm2b-field-masking.sql
-- Permissions cut 2b: 字段级遮蔽 —— 财务看得见价格,仓储与现场看不见。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是视图,不是列权限,也不是应用层隐藏】
--   PostgreSQL 的 RLS 是【行级】的,表达不了"这一行你能读,但这一列不能"。
--   两条路可走:列级 GRANT(PostgREST 上表现为硬报错,且和 SELECT * 相处很差),
--   或者遮蔽视图。本切用【遮蔽视图】:一个视图可以按 has_permission() 把某一列
--   置空【而保留整行可读】,于是同一条查询对每个角色都成立,只是拿回来的东西更少。
--   只在应用层隐藏是【化妆】—— 任何人拿着 anon key 和一个 REST 客户端就能把原始列读走,
--   而那正是本切要堵的缺口。
--
-- 【视图为什么是属主权限(security_invoker = off),这一点是量出来的,不是猜的】
--   security_invoker = on 的视图【以调用者身份】读基表。于是任何强到能挡住原始列的
--   机制,同样会挡住这个视图本身 —— 实测两次:
--     · 收紧基表行策略  → invoker 遮蔽视图返回 0 行(而不是"整行在、价格为空");
--     · 收回列权限      → invoker 遮蔽视图直接 42501。
--   所以遮蔽视图必须是属主权限,并【在视图体里把模块谓词原样加回来】:
--       WHERE has_permission('module.<m>.view')
--   因为 cut 2a 的每一条 SELECT 策略都恰好是这同一个布尔量(与行内容无关,整表要么全可见
--   要么全不可见),所以"属主权限 + 谓词加回"与"调用者的 RLS"是【逐行等价】的,
--   视图【不会放宽任何行访问】。实测佐证:一个完全没有该模块权限的用户查遮蔽视图 → 0 行。
--
-- 【基表的原始列怎么挡住】
--   表级 SELECT 授权【蕴含所有列】,所以必须先收回表级 SELECT,再把【非敏感列】逐列授回:
--       REVOKE SELECT ON <t> FROM authenticated, anon;
--       GRANT  SELECT (<非敏感列...>) ON <t> TO authenticated;
--   于是原始敏感列在 PostgREST 上是 42501 硬报错(不是静悄悄的泄露),
--   而模块级的其它读取、全部写入、以及所有触发器一行都不用改。
--   —— 基表的【行策略保持 cut 2a 原样】,因为收紧它会让基表整个消失:
--      实测 INSERT ... RETURNING 被拒、收货路径当场断掉,而安全性一点没多。
-- ════════════════════════════════════════════════════════════════════════════
--
-- ════════════════════ B1. 敏感列清单(权威参考)════════════════════
--
--   【data.view_prices —— 我们付出什么、东西成本几何】
--     inbound_batches                (inbound   ) unit_price
--     invoice_lines                  (finance   ) amount_usd, unit_price
--     invoices                       (finance   ) subtotal_usd, tax_usd, total_usd
--     payment_term_template_lines    (purchasing) fixed_amount_usd
--     prepayment_applications        (finance   ) amount_usd
--     price_history                  (inbound   ) fx_rate, new_unit_price, old_unit_price, original_price
--     pricing_formula_metals         (pricing   ) payable_pct
--     pricing_formulas               (pricing   ) flat_discount_pct, treatment_charge_usd_per_tonne
--     processing_cost_entries        (processing) amount_usd
--     processing_outputs             (processing) allocated_cost_usd, unit_cost_usd
--     processing_runs                (processing) capitalized_cost_usd, material_cost_usd, process_cost_usd, total_cost_usd
--     purchase_order_lines           (purchasing) estimated_amount_usd, estimated_unit_price
--     purchase_order_payment_terms   (purchasing) fixed_amount_usd
--     purchase_orders                (purchasing) estimated_total_usd, fx_rate
--     sales_records                  (finance   ) amount_usd, fx_rate, unit_price
--
--   【data.view_pay —— 按人头的薪酬】
--     payroll_lines                  (hr        ) employee_cpf, employer_cpf, gross_pay, net_pay, other_deductions
--
--   【data.view_identity —— 身份与联系方式】
--     employees                      (hr        ) identity_no, work_email, work_pass_no, work_phone
--
-- 销售价的判断:产出批次的售价同样是商业机密,但发货的现场人员并不需要它 ——
-- 因此 sales_records 的单价金额、invoices / invoice_lines 的金额【一并归入 data.view_prices】。
--
-- ──────────────── 明确【不】遮蔽的东西,以及为什么 ────────────────
--   * employees.work_pass_type / work_pass_issue_date / work_pass_expiry_date
--       证件【号码】才是身份数据;有效期是合规信号 —— hr_alerts 到期看板与 employee_directory 的预警都靠它。把日期也蒙
--       上会让没有 data.view_identity 的人看不见到期提醒,那是拿合规去换一个它保护不了的秘密(号码已经蒙掉了)。
--   * payroll_periods.gross_total / employer_cpf_total / employee_cpf_total / other_deductions_total / net_pay_total
--       【本切最需要写清楚的一条】按人头的工资是个人数据,归 HR;期间合计是公司支出 —— 它们已经以"薪金工资""公积金-雇主"的科目余额躺在总账里
--       ,财务要结月、要出损益表就必须看得见。把期间合计蒙上、而同一个数字在试算平衡表上大喇喇地列着,那是做戏,还会挡住正当的工作。所以:payroll
--       _lines 的按人头金额要 data.view_pay;payroll_periods 的合计只要 module.finance.view。
--   * journal_lines.debit / credit, payments.amount_usd, expenses.amount_usd, period_closes 合计
--       都在 module.finance 之下,而今天持有 module.finance.view 的三个角色(admin / finance / a
--       uditor)恰好都持有 data.view_prices —— 蒙上它们【今天一行行为都不会改变】,只会多出一层日后会漂移的机关。真正的边界是
--       模块权限,这里不重复设防。
--   * metal_prices.price_usd_per_tonne
--       市场行情(LME 一类),cut 2a 已明确判定为任何登录用户可读的参考数据 —— 它不是本公司的成本。
--   * fx_rates.rate_to_usd
--       汇率是公开数据,且整张表已在 module.finance 之下。
--   * customers / suppliers.credit_rating, payment_terms
--       是交易对手的条款而非本公司的成本,且两张表分属 customers / suppliers 模块,仓储与现场本来就读不到。留待日后若要做"商务敏
--       感"这一类权限时再统一处理。
--   * invoices.tax_rate_pct
--       GST 税率是公开的法定比率,不是金额。
--   * assay_result_metals / inbound_batch_metals / output_batch_metals.content_pct
--       化验品位是技术数据,不是价格;蒙掉它会让现场没法核对物料。
--
-- ──────────────── 本切【没有】处理、但survey 中发现的暴露面 ────────────────
--   ! company_profile.bank_account_no / bank_swift / bank_account_name
--       cut 2a 把 company_profile 定为【任何登录用户可读】(开票抬头要用)。这意味着公司银行账号对每一个登录用户可见 —— 包括
--       只有 module.tasks 的人。它不属于本切的三个权限中的任何一个,因此本切不动它,但这是一个真实的暴露面,建议下一切用一个 data.v
--       iew_banking 之类的码收拢。
--
-- ════════════════════ 函数 ════════════════════
-- 两个 SECURITY INVOKER 函数会读到被收回的列,必须处理(其余 6 个碰到敏感列的都是
-- 用 NEW/OLD 的触发器守卫,不 SELECT 基表,不受影响):
--   * calculate_metal_price —— 【拆成两个】。它既被采购页面直接调用,又被
--     apply_assay_result(DEFINER,仓储/运营在用)内部调用。若只加一道 data.view_prices,
--     化验应用会对仓储当场失败。因此:
--       calculate_metal_price_internal  DEFINER,不检查,【对 authenticated 收回 EXECUTE】,
--                                       只能从别的函数体内调用;
--       calculate_metal_price           DEFINER,顶部 require_permission('data.view_prices'),
--                                       是给界面用的入口。
--   * preview_reprice_inbound_batch —— 它【返回价格】,所以顶部要 data.view_prices。
--     没有这个码的人(仓储/运营)拿到 PERMISSION_DENIED,界面渲染「受限」。
--     真正的应用动作 apply_assay_result 仍只要 module.inbound.edit,照常可用。
--
-- ════════════════════ PostgREST ════════════════════
-- 遮蔽视图建在 public 架构下,而 public 就是 PostgREST 暴露的 API 架构,因此
-- 视图天然可以按 /rest/v1/<view> 访问;只需把 SELECT 授给 authenticated。
-- 末尾 NOTIFY pgrst, 'reload schema' 让 PostgREST 立刻重载架构缓存。
--
-- NOTE: applied to project wvywpohbwkiinmipmuku via the Management API.

BEGIN;

-- ============================================================================
-- B2. 遮蔽视图
-- ============================================================================
-- employees_masked (hr) — 遮蔽 identity_no, work_email, work_pass_no, work_phone
CREATE VIEW public.employees_masked WITH (security_invoker = off) AS
SELECT
    id,
    code,
    legal_name,
    preferred_name,
    department_id,
    job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
    separation_notes,
    annual_leave_days,
    CASE WHEN has_permission('data.view_identity') THEN work_email ELSE NULL END AS work_email,
    CASE WHEN has_permission('data.view_identity') THEN work_phone ELSE NULL END AS work_phone,
    residency_status,
    CASE WHEN has_permission('data.view_identity') THEN identity_no ELSE NULL END AS identity_no,
    work_pass_type,
    CASE WHEN has_permission('data.view_identity') THEN work_pass_no ELSE NULL END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by
FROM public.employees
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.hr.view');
GRANT SELECT ON public.employees_masked TO authenticated;

-- inbound_batches_masked (inbound) — 遮蔽 unit_price
CREATE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
SELECT
    id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
    CASE WHEN has_permission('data.view_prices') THEN unit_price ELSE NULL END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status
FROM public.inbound_batches
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.inbound.view');
GRANT SELECT ON public.inbound_batches_masked TO authenticated;

-- invoice_lines_masked (finance) — 遮蔽 amount_usd, unit_price
CREATE VIEW public.invoice_lines_masked WITH (security_invoker = off) AS
SELECT
    id,
    invoice_id,
    sales_record_id,
    line_no,
    description,
    quantity,
    unit,
    CASE WHEN has_permission('data.view_prices') THEN unit_price ELSE NULL END AS unit_price,
    CASE WHEN has_permission('data.view_prices') THEN amount_usd ELSE NULL END AS amount_usd,
    invoice_voided,
    created_at
FROM public.invoice_lines
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.finance.view');
GRANT SELECT ON public.invoice_lines_masked TO authenticated;

-- invoices_masked (finance) — 遮蔽 subtotal_usd, tax_usd, total_usd
CREATE VIEW public.invoices_masked WITH (security_invoker = off) AS
SELECT
    id,
    code,
    customer_id,
    issue_date,
    due_date,
    payment_terms_days,
    currency,
    CASE WHEN has_permission('data.view_prices') THEN subtotal_usd ELSE NULL END AS subtotal_usd,
    tax_rate_pct,
    CASE WHEN has_permission('data.view_prices') THEN tax_usd ELSE NULL END AS tax_usd,
    CASE WHEN has_permission('data.view_prices') THEN total_usd ELSE NULL END AS total_usd,
    status,
    void_reason,
    voided_at,
    voided_by,
    notes,
    terms_text,
    bill_to_snapshot,
    created_at,
    created_by
FROM public.invoices
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.finance.view');
GRANT SELECT ON public.invoices_masked TO authenticated;

-- payment_term_template_lines_masked (purchasing) — 遮蔽 fixed_amount_usd
CREATE VIEW public.payment_term_template_lines_masked WITH (security_invoker = off) AS
SELECT
    id,
    template_id,
    seq,
    label,
    percentage,
    CASE WHEN has_permission('data.view_prices') THEN fixed_amount_usd ELSE NULL END AS fixed_amount_usd,
    trigger_event,
    days_offset,
    notes,
    created_at
FROM public.payment_term_template_lines
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.purchasing.view');
GRANT SELECT ON public.payment_term_template_lines_masked TO authenticated;

-- payroll_lines_masked (hr) — 遮蔽 employee_cpf, employer_cpf, gross_pay, net_pay, other_deductions
CREATE VIEW public.payroll_lines_masked WITH (security_invoker = off) AS
SELECT
    id,
    payroll_period_id,
    employee_id,
    CASE WHEN has_permission('data.view_pay') THEN gross_pay ELSE NULL END AS gross_pay,
    CASE WHEN has_permission('data.view_pay') THEN employer_cpf ELSE NULL END AS employer_cpf,
    CASE WHEN has_permission('data.view_pay') THEN employee_cpf ELSE NULL END AS employee_cpf,
    CASE WHEN has_permission('data.view_pay') THEN other_deductions ELSE NULL END AS other_deductions,
    CASE WHEN has_permission('data.view_pay') THEN net_pay ELSE NULL END AS net_pay,
    notes,
    created_at
FROM public.payroll_lines
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.hr.view');
GRANT SELECT ON public.payroll_lines_masked TO authenticated;

-- prepayment_applications_masked (finance) — 遮蔽 amount_usd
CREATE VIEW public.prepayment_applications_masked WITH (security_invoker = off) AS
SELECT
    id,
    purchase_order_id,
    inbound_batch_id,
    CASE WHEN has_permission('data.view_prices') THEN amount_usd ELSE NULL END AS amount_usd,
    notes,
    journal_entry_id,
    created_at,
    created_by
FROM public.prepayment_applications
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.finance.view');
GRANT SELECT ON public.prepayment_applications_masked TO authenticated;

-- price_history_masked (inbound) — 遮蔽 fx_rate, new_unit_price, old_unit_price, original_price
CREATE VIEW public.price_history_masked WITH (security_invoker = off) AS
SELECT
    id,
    inbound_batch_id,
    CASE WHEN has_permission('data.view_prices') THEN old_unit_price ELSE NULL END AS old_unit_price,
    CASE WHEN has_permission('data.view_prices') THEN new_unit_price ELSE NULL END AS new_unit_price,
    currency,
    CASE WHEN has_permission('data.view_prices') THEN original_price ELSE NULL END AS original_price,
    CASE WHEN has_permission('data.view_prices') THEN fx_rate ELSE NULL END AS fx_rate,
    notes,
    created_at,
    created_by
FROM public.price_history
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.inbound.view');
GRANT SELECT ON public.price_history_masked TO authenticated;

-- pricing_formula_metals_masked (pricing) — 遮蔽 payable_pct
CREATE VIEW public.pricing_formula_metals_masked WITH (security_invoker = off) AS
SELECT
    formula_id,
    metal,
    CASE WHEN has_permission('data.view_prices') THEN payable_pct ELSE NULL END AS payable_pct,
    created_at,
    created_by,
    updated_at,
    updated_by
FROM public.pricing_formula_metals
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.pricing.view');
GRANT SELECT ON public.pricing_formula_metals_masked TO authenticated;

-- pricing_formulas_masked (pricing) — 遮蔽 flat_discount_pct, treatment_charge_usd_per_tonne
CREATE VIEW public.pricing_formulas_masked WITH (security_invoker = off) AS
SELECT
    id,
    code,
    name,
    direction,
    price_basis,
    average_days,
    CASE WHEN has_permission('data.view_prices') THEN treatment_charge_usd_per_tonne ELSE NULL END AS treatment_charge_usd_per_tonne,
    CASE WHEN has_permission('data.view_prices') THEN flat_discount_pct ELSE NULL END AS flat_discount_pct,
    supplier_id,
    customer_id,
    notes,
    is_active,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by
FROM public.pricing_formulas
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.pricing.view');
GRANT SELECT ON public.pricing_formulas_masked TO authenticated;

-- processing_cost_entries_masked (processing) — 遮蔽 amount_usd
CREATE VIEW public.processing_cost_entries_masked WITH (security_invoker = off) AS
SELECT
    id,
    run_id,
    cost_type,
    CASE WHEN has_permission('data.view_prices') THEN amount_usd ELSE NULL END AS amount_usd,
    is_estimate,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by
FROM public.processing_cost_entries
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.processing.view');
GRANT SELECT ON public.processing_cost_entries_masked TO authenticated;

-- processing_outputs_masked (processing) — 遮蔽 allocated_cost_usd, unit_cost_usd
CREATE VIEW public.processing_outputs_masked WITH (security_invoker = off) AS
SELECT
    id,
    run_id,
    output_batch_id,
    quantity_produced,
    created_at,
    CASE WHEN has_permission('data.view_prices') THEN allocated_cost_usd ELSE NULL END AS allocated_cost_usd,
    CASE WHEN has_permission('data.view_prices') THEN unit_cost_usd ELSE NULL END AS unit_cost_usd
FROM public.processing_outputs
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.processing.view');
GRANT SELECT ON public.processing_outputs_masked TO authenticated;

-- processing_runs_masked (processing) — 遮蔽 capitalized_cost_usd, material_cost_usd, process_cost_usd, total_cost_usd
CREATE VIEW public.processing_runs_masked WITH (security_invoker = off) AS
SELECT
    id,
    code,
    process_date,
    total_input,
    total_output,
    loss_qty,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    allocation_basis,
    CASE WHEN has_permission('data.view_prices') THEN material_cost_usd ELSE NULL END AS material_cost_usd,
    CASE WHEN has_permission('data.view_prices') THEN process_cost_usd ELSE NULL END AS process_cost_usd,
    CASE WHEN has_permission('data.view_prices') THEN total_cost_usd ELSE NULL END AS total_cost_usd,
    allocation_snapshot,
    allocated_at,
    allocated_by,
    CASE WHEN has_permission('data.view_prices') THEN capitalized_cost_usd ELSE NULL END AS capitalized_cost_usd,
    capitalization_entry_id
FROM public.processing_runs
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.processing.view');
GRANT SELECT ON public.processing_runs_masked TO authenticated;

-- purchase_order_lines_masked (purchasing) — 遮蔽 estimated_amount_usd, estimated_unit_price
CREATE VIEW public.purchase_order_lines_masked WITH (security_invoker = off) AS
SELECT
    id,
    purchase_order_id,
    line_no,
    material_id,
    quantity,
    unit,
    pricing_formula_id,
    CASE WHEN has_permission('data.view_prices') THEN estimated_unit_price ELSE NULL END AS estimated_unit_price,
    CASE WHEN has_permission('data.view_prices') THEN estimated_amount_usd ELSE NULL END AS estimated_amount_usd,
    expected_assay,
    notes,
    created_at,
    created_by
FROM public.purchase_order_lines
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.purchasing.view');
GRANT SELECT ON public.purchase_order_lines_masked TO authenticated;

-- purchase_order_payment_terms_masked (purchasing) — 遮蔽 fixed_amount_usd
CREATE VIEW public.purchase_order_payment_terms_masked WITH (security_invoker = off) AS
SELECT
    id,
    purchase_order_id,
    seq,
    label,
    percentage,
    CASE WHEN has_permission('data.view_prices') THEN fixed_amount_usd ELSE NULL END AS fixed_amount_usd,
    trigger_event,
    due_date,
    notes,
    created_at
FROM public.purchase_order_payment_terms
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.purchasing.view');
GRANT SELECT ON public.purchase_order_payment_terms_masked TO authenticated;

-- purchase_orders_masked (purchasing) — 遮蔽 estimated_total_usd, fx_rate
CREATE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
SELECT
    id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
    CASE WHEN has_permission('data.view_prices') THEN fx_rate ELSE NULL END AS fx_rate,
    CASE WHEN has_permission('data.view_prices') THEN estimated_total_usd ELSE NULL END AS estimated_total_usd,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by
FROM public.purchase_orders
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.purchasing.view');
GRANT SELECT ON public.purchase_orders_masked TO authenticated;

-- sales_records_masked (finance) — 遮蔽 amount_usd, fx_rate, unit_price
CREATE VIEW public.sales_records_masked WITH (security_invoker = off) AS
SELECT
    id,
    output_batch_id,
    customer_id,
    quantity,
    CASE WHEN has_permission('data.view_prices') THEN unit_price ELSE NULL END AS unit_price,
    currency,
    CASE WHEN has_permission('data.view_prices') THEN fx_rate ELSE NULL END AS fx_rate,
    CASE WHEN has_permission('data.view_prices') THEN amount_usd ELSE NULL END AS amount_usd,
    sale_date,
    notes,
    movement_id,
    created_at,
    created_by,
    cogs_entry_id
FROM public.sales_records
-- 谓词与 cut 2a 的 SELECT 策略逐字相同:视图不放宽任何行访问
WHERE has_permission('module.finance.view');
GRANT SELECT ON public.sales_records_masked TO authenticated;

-- ============================================================================
-- B3a. 既有视图【就地遮蔽】:把基表换成遮蔽伴生视图,视图体其余部分逐字不变。
-- 这些视图保持 security_invoker = on —— 它们读的是遮蔽视图(属主权限、已自带谓词),
-- 因此既拿得到数据,又不会绕过任何模块边界。
-- ============================================================================
-- ap_open_items — 改读 inbound_batches_masked, prepayment_applications_masked
DROP VIEW public.ap_open_items;
CREATE VIEW public.ap_open_items WITH (security_invoker = on) AS
 SELECT doc_kind,
    doc_id,
    doc_code,
    inbound_batch_id,
    supplier_id,
    supplier_name,
    doc_date,
    doc_value_usd,
    settled_usd,
    open_usd,
    CURRENT_DATE - doc_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - doc_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - doc_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - doc_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket
   FROM ( SELECT 'inbound'::text AS doc_kind,
            ib.id AS doc_id,
            ib.code AS doc_code,
            ib.id AS inbound_batch_id,
            ib.supplier_id,
            sup.legal_name AS supplier_name,
            COALESCE(ib.arrival_date, ib.created_at::date) AS doc_date,
            round(ib.quantity * ib.unit_price, 2) AS doc_value_usd,
            round(COALESCE(s.settled, 0::numeric) + COALESCE(pp.applied, 0::numeric), 2) AS settled_usd,
            round(round(ib.quantity * ib.unit_price, 2) - COALESCE(s.settled, 0::numeric) - COALESCE(pp.applied, 0::numeric), 2) AS open_usd
           FROM inbound_batches_masked ib
             JOIN suppliers sup ON sup.id = ib.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.inbound_batch_id = ib.id) s ON true
             LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
                   FROM prepayment_applications_masked ppa
                  WHERE ppa.inbound_batch_id = ib.id) pp ON true
          WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL
        UNION ALL
         SELECT 'expense'::text AS doc_kind,
            e.id AS doc_id,
            e.code AS doc_code,
            NULL::uuid AS inbound_batch_id,
            e.supplier_id,
            sup.legal_name AS supplier_name,
            e.expense_date AS doc_date,
            e.amount_usd AS doc_value_usd,
            round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
            round(e.amount_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd
           FROM expenses e
             JOIN suppliers sup ON sup.id = e.supplier_id
             LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
                   FROM payment_allocations pa
                     JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
                  WHERE pa.expense_id = e.id) s ON true
          WHERE e.payment_status = 'unpaid'::text AND e.status = 'posted'::text AND NOT (EXISTS ( SELECT 1
                   FROM expenses o
                  WHERE o.reversed_by_expense = e.id))) d
  WHERE open_usd > 0::numeric;
GRANT SELECT ON public.ap_open_items TO authenticated;

-- ar_open_items — 改读 sales_records_masked, invoices_masked, invoice_lines_masked
DROP VIEW public.ar_open_items;
CREATE VIEW public.ar_open_items WITH (security_invoker = on) AS
 SELECT sr.id AS sales_record_id,
    ob.code AS doc_code,
    sr.customer_id,
    c.legal_name AS customer_name,
    sr.sale_date,
    sr.amount_usd,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
    round(sr.amount_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd,
    CURRENT_DATE - sr.sale_date AS days_outstanding,
        CASE
            WHEN (CURRENT_DATE - sr.sale_date) <= 30 THEN 'b0_30'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 60 THEN 'b31_60'::text
            WHEN (CURRENT_DATE - sr.sale_date) <= 90 THEN 'b61_90'::text
            ELSE 'b90_plus'::text
        END AS bucket,
    inv.invoice_id,
    inv.invoice_code
   FROM sales_records_masked sr
     JOIN output_batches ob ON ob.id = sr.output_batch_id
     LEFT JOIN customers c ON c.id = sr.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.sales_record_id = sr.id) s ON true
     LEFT JOIN LATERAL ( SELECT i.id AS invoice_id,
            i.code AS invoice_code
           FROM invoice_lines_masked il
             JOIN invoices_masked i ON i.id = il.invoice_id
          WHERE il.sales_record_id = sr.id AND NOT il.invoice_voided
         LIMIT 1) inv ON true
  WHERE round(sr.amount_usd - COALESCE(s.settled, 0::numeric), 2) > 0::numeric;
GRANT SELECT ON public.ar_open_items TO authenticated;

-- batch_assay_status — 改读 inbound_batches_masked, pricing_formulas_masked, purchase_orders_masked
DROP VIEW public.batch_assay_status;
CREATE VIEW public.batch_assay_status WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    sup.legal_name AS supplier_name,
    m.name AS material_name,
    ib.quantity,
    ib.unit,
    ib.unit_price,
    ib.pricing_status,
    ib.pricing_formula_id,
    pf.code AS formula_code,
    COALESCE(a.assay_count, 0::bigint) AS assay_count,
    a.latest_assay_id,
    a.latest_assay_code,
    a.latest_assay_date,
    COALESCE(a.latest_assay_applied, false) AS latest_assay_applied,
    COALESCE(a.has_unapplied_assay, false) AS has_unapplied_assay,
    ib.purchase_order_id,
    po.code AS po_code
   FROM inbound_batches_masked ib
     JOIN suppliers sup ON sup.id = ib.supplier_id
     JOIN materials m ON m.id = ib.material_id
     LEFT JOIN pricing_formulas_masked pf ON pf.id = ib.pricing_formula_id
     LEFT JOIN purchase_orders_masked po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT count(*) AS assay_count,
            bool_or(ar.applied_at IS NULL) AS has_unapplied_assay,
            (array_agg(ar.id ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_id,
            (array_agg(ar.code ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_code,
            (array_agg(ar.assay_date ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_date,
            (array_agg(ar.applied_at IS NOT NULL ORDER BY ar.assay_date DESC, ar.created_at DESC, ar.code DESC))[1] AS latest_assay_applied
           FROM assay_results ar
          WHERE ar.inbound_batch_id = ib.id AND ar.deleted_at IS NULL) a ON true
  WHERE ib.deleted_at IS NULL;
GRANT SELECT ON public.batch_assay_status TO authenticated;

-- employee_directory — 改读 payroll_lines_masked, employees_masked
DROP VIEW public.employee_directory;
CREATE VIEW public.employee_directory WITH (security_invoker = on) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    e.department_id,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    e.job_title,
    e.manager_id,
    mgr.code AS manager_code,
    mgr.legal_name AS manager_name,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    e.annual_leave_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_expiry_date,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::integer
            ELSE e.work_pass_expiry_date - CURRENT_DATE
        END AS days_to_work_pass_expiry,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::text
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 90 THEN 'warning'::text
            ELSE NULL::text
        END AS work_pass_alert,
    pay.gross_pay AS current_gross_pay,
    pay.period_month AS current_pay_period,
    COALESCE(tr.training_count, 0::bigint) AS training_count
   FROM employees_masked e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees_masked mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT pl.gross_pay,
            pp.period_month
           FROM payroll_lines_masked pl
             JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND pp.status = 'posted'::text AND pp.deleted_at IS NULL
          ORDER BY pp.period_month DESC
         LIMIT 1) pay ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS training_count
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
  WHERE e.deleted_at IS NULL;
GRANT SELECT ON public.employee_directory TO authenticated;

-- invoice_status — 改读 invoices_masked, invoice_lines_masked
DROP VIEW public.invoice_status;
CREATE VIEW public.invoice_status WITH (security_invoker = on) AS
 SELECT i.id AS invoice_id,
    i.code,
    i.customer_id,
    c.legal_name AS customer_name,
    i.issue_date,
    i.due_date,
    i.currency,
    i.total_usd,
    round(COALESCE(s.settled, 0::numeric), 2) AS settled_usd,
    round(i.total_usd - COALESCE(s.settled, 0::numeric), 2) AS open_usd,
    GREATEST(CURRENT_DATE - i.due_date, 0) AS days_overdue,
        CASE
            WHEN round(i.total_usd - COALESCE(s.settled, 0::numeric), 2) <= 0::numeric THEN 'paid'::text
            WHEN COALESCE(s.settled, 0::numeric) > 0::numeric THEN 'partial'::text
            ELSE 'unpaid'::text
        END AS payment_state,
    CURRENT_DATE > i.due_date AND round(i.total_usd - COALESCE(s.settled, 0::numeric), 2) > 0::numeric AS overdue
   FROM invoices_masked i
     JOIN customers c ON c.id = i.customer_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM invoice_lines_masked il
             JOIN payment_allocations pa ON pa.sales_record_id = il.sales_record_id
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE il.invoice_id = i.id) s ON true
  WHERE i.status <> 'void'::text;
GRANT SELECT ON public.invoice_status TO authenticated;

-- po_prepayment_applicable — 改读 inbound_batches_masked, purchase_orders_masked, prepayment_applications_masked
DROP VIEW public.po_prepayment_applicable;
CREATE VIEW public.po_prepayment_applicable WITH (security_invoker = on) AS
 SELECT ib.id AS inbound_batch_id,
    ib.code AS batch_code,
    po.id AS purchase_order_id,
    po.code AS po_code,
    po.supplier_id,
    round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2) AS batch_ap_open_usd,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2) AS po_unapplied_prepayment_usd,
    GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) AS applicable_usd
   FROM inbound_batches_masked ib
     JOIN purchase_orders_masked po ON po.id = ib.purchase_order_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS settled
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.inbound_batch_id = ib.id) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.inbound_batch_id = ib.id) app_b ON true
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app_po ON true
  WHERE ib.deleted_at IS NULL AND ib.unit_price IS NOT NULL AND GREATEST(LEAST(round(round(ib.quantity * ib.unit_price, 2) - COALESCE(pay.settled, 0::numeric) - COALESCE(app_b.applied, 0::numeric), 2), round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app_po.applied, 0::numeric), 2)), 0::numeric) > 0::numeric;
GRANT SELECT ON public.po_prepayment_applicable TO authenticated;

-- po_receivable_lines — 改读 inbound_batches_masked, purchase_orders_masked, purchase_order_lines_masked
DROP VIEW public.po_receivable_lines;
CREATE VIEW public.po_receivable_lines WITH (security_invoker = on) AS
 SELECT po.id AS po_id,
    po.code AS po_code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    pol.id AS line_id,
    pol.line_no,
    pol.material_id,
    m.name AS material_name,
    pol.quantity AS ordered_qty,
    pol.unit,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(GREATEST(pol.quantity - COALESCE(rec.qty, 0::numeric), 0::numeric), 4) AS remaining_qty,
    pol.pricing_formula_id,
    pol.estimated_unit_price,
    pol.expected_assay
   FROM purchase_orders_masked po
     JOIN suppliers sup ON sup.id = po.supplier_id
     JOIN purchase_order_lines_masked pol ON pol.purchase_order_id = po.id
     JOIN materials m ON m.id = pol.material_id
     LEFT JOIN LATERAL ( SELECT sum(ib.quantity) AS qty
           FROM inbound_batches_masked ib
          WHERE ib.purchase_order_line_id = pol.id AND ib.deleted_at IS NULL) rec ON true
  WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]));
GRANT SELECT ON public.po_receivable_lines TO authenticated;

-- purchase_order_status — 改读 inbound_batches_masked, purchase_orders_masked, purchase_order_lines_masked, prepayment_applications_masked
DROP VIEW public.purchase_order_status;
CREATE VIEW public.purchase_order_status WITH (security_invoker = on) AS
 SELECT po.id AS po_id,
    po.code,
    po.supplier_id,
    sup.legal_name AS supplier_name,
    po.order_date,
    po.expected_delivery_date,
    po.status,
    po.currency,
    po.estimated_total_usd,
    round(COALESCE(pre.prepaid, 0::numeric), 2) AS prepaid_usd,
    round(COALESCE(app.applied, 0::numeric), 2) AS prepaid_applied_usd,
    round(COALESCE(pre.prepaid, 0::numeric) - COALESCE(app.applied, 0::numeric), 2) AS prepaid_remaining_usd,
    COALESCE(rec.batches, 0::bigint) AS received_batches,
    round(COALESCE(rec.qty, 0::numeric), 4) AS received_qty,
    round(COALESCE(ord.qty, 0::numeric), 4) AS ordered_qty,
        CASE
            WHEN COALESCE(ord.qty, 0::numeric) = 0::numeric THEN NULL::numeric
            ELSE round(COALESCE(rec.qty, 0::numeric) / ord.qty * 100::numeric, 2)
        END AS receipt_pct
   FROM purchase_orders_masked po
     JOIN suppliers sup ON sup.id = po.supplier_id
     LEFT JOIN LATERAL ( SELECT sum(pa.allocated_usd) AS prepaid
           FROM payment_allocations pa
             JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'::text
          WHERE pa.purchase_order_id = po.id) pre ON true
     LEFT JOIN LATERAL ( SELECT sum(ppa.amount_usd) AS applied
           FROM prepayment_applications_masked ppa
          WHERE ppa.purchase_order_id = po.id) app ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS batches,
            sum(ib.quantity) AS qty
           FROM inbound_batches_masked ib
          WHERE ib.purchase_order_id = po.id AND ib.deleted_at IS NULL) rec ON true
     LEFT JOIN LATERAL ( SELECT sum(pol.quantity) AS qty
           FROM purchase_order_lines_masked pol
          WHERE pol.purchase_order_id = po.id) ord ON true
  WHERE po.deleted_at IS NULL AND po.status <> 'cancelled'::text;
GRANT SELECT ON public.purchase_order_status TO authenticated;

-- ============================================================================
-- B3b. 收回基表原始敏感列
-- 表级 SELECT 蕴含所有列 —— 必须先整表收回,再逐列授回非敏感列。
-- service_role / postgres 不动(它们本来就 BYPASSRLS,是运维与迁移的通道)。
-- ============================================================================
-- employees: 收回 identity_no, work_email, work_pass_no, work_phone
REVOKE SELECT ON public.employees FROM authenticated, anon;
GRANT SELECT (id, code, legal_name, preferred_name, department_id, job_title, manager_id, employment_type, work_category, hire_date, probation_end_date, employment_status, separation_date, separation_type, separation_notes, annual_leave_days, residency_status, work_pass_type, work_pass_issue_date, work_pass_expiry_date, user_id, notes, deleted_at, created_at, created_by, updated_at, updated_by)
    ON public.employees TO authenticated;

-- inbound_batches: 收回 unit_price
REVOKE SELECT ON public.inbound_batches FROM authenticated, anon;
GRANT SELECT (id, code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, stage, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, purchase_order_id, purchase_order_line_id, pricing_formula_id, pricing_status)
    ON public.inbound_batches TO authenticated;

-- invoice_lines: 收回 amount_usd, unit_price
REVOKE SELECT ON public.invoice_lines FROM authenticated, anon;
GRANT SELECT (id, invoice_id, sales_record_id, line_no, description, quantity, unit, invoice_voided, created_at)
    ON public.invoice_lines TO authenticated;

-- invoices: 收回 subtotal_usd, tax_usd, total_usd
REVOKE SELECT ON public.invoices FROM authenticated, anon;
GRANT SELECT (id, code, customer_id, issue_date, due_date, payment_terms_days, currency, tax_rate_pct, status, void_reason, voided_at, voided_by, notes, terms_text, bill_to_snapshot, created_at, created_by)
    ON public.invoices TO authenticated;

-- payment_term_template_lines: 收回 fixed_amount_usd
REVOKE SELECT ON public.payment_term_template_lines FROM authenticated, anon;
GRANT SELECT (id, template_id, seq, label, percentage, trigger_event, days_offset, notes, created_at)
    ON public.payment_term_template_lines TO authenticated;

-- payroll_lines: 收回 employee_cpf, employer_cpf, gross_pay, net_pay, other_deductions
REVOKE SELECT ON public.payroll_lines FROM authenticated, anon;
GRANT SELECT (id, payroll_period_id, employee_id, notes, created_at)
    ON public.payroll_lines TO authenticated;

-- prepayment_applications: 收回 amount_usd
REVOKE SELECT ON public.prepayment_applications FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, inbound_batch_id, notes, journal_entry_id, created_at, created_by)
    ON public.prepayment_applications TO authenticated;

-- price_history: 收回 fx_rate, new_unit_price, old_unit_price, original_price
REVOKE SELECT ON public.price_history FROM authenticated, anon;
GRANT SELECT (id, inbound_batch_id, currency, notes, created_at, created_by)
    ON public.price_history TO authenticated;

-- pricing_formula_metals: 收回 payable_pct
REVOKE SELECT ON public.pricing_formula_metals FROM authenticated, anon;
GRANT SELECT (formula_id, metal, created_at, created_by, updated_at, updated_by)
    ON public.pricing_formula_metals TO authenticated;

-- pricing_formulas: 收回 flat_discount_pct, treatment_charge_usd_per_tonne
REVOKE SELECT ON public.pricing_formulas FROM authenticated, anon;
GRANT SELECT (id, code, name, direction, price_basis, average_days, supplier_id, customer_id, notes, is_active, deleted_at, created_at, created_by, updated_at, updated_by)
    ON public.pricing_formulas TO authenticated;

-- processing_cost_entries: 收回 amount_usd
REVOKE SELECT ON public.processing_cost_entries FROM authenticated, anon;
GRANT SELECT (id, run_id, cost_type, is_estimate, notes, deleted_at, created_at, created_by, updated_at, updated_by)
    ON public.processing_cost_entries TO authenticated;

-- processing_outputs: 收回 allocated_cost_usd, unit_cost_usd
REVOKE SELECT ON public.processing_outputs FROM authenticated, anon;
GRANT SELECT (id, run_id, output_batch_id, quantity_produced, created_at)
    ON public.processing_outputs TO authenticated;

-- processing_runs: 收回 capitalized_cost_usd, material_cost_usd, process_cost_usd, total_cost_usd
REVOKE SELECT ON public.processing_runs FROM authenticated, anon;
GRANT SELECT (id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, allocation_basis, allocation_snapshot, allocated_at, allocated_by, capitalization_entry_id)
    ON public.processing_runs TO authenticated;

-- purchase_order_lines: 收回 estimated_amount_usd, estimated_unit_price
REVOKE SELECT ON public.purchase_order_lines FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, line_no, material_id, quantity, unit, pricing_formula_id, expected_assay, notes, created_at, created_by)
    ON public.purchase_order_lines TO authenticated;

-- purchase_order_payment_terms: 收回 fixed_amount_usd
REVOKE SELECT ON public.purchase_order_payment_terms FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, seq, label, percentage, trigger_event, due_date, notes, created_at)
    ON public.purchase_order_payment_terms TO authenticated;

-- purchase_orders: 收回 estimated_total_usd, fx_rate
REVOKE SELECT ON public.purchase_orders FROM authenticated, anon;
GRANT SELECT (id, code, supplier_id, order_date, expected_delivery_date, currency, status, approval_status, approved_at, approved_by, incoterm, terms_text, notes, closed_at, cancelled_at, cancel_reason, deleted_at, created_at, created_by, updated_at, updated_by)
    ON public.purchase_orders TO authenticated;

-- sales_records: 收回 amount_usd, fx_rate, unit_price
REVOKE SELECT ON public.sales_records FROM authenticated, anon;
GRANT SELECT (id, output_batch_id, customer_id, quantity, currency, sale_date, notes, movement_id, created_at, created_by, cogs_entry_id)
    ON public.sales_records TO authenticated;

-- ============================================================================
-- B3c. 会读到被收回的列的 SECURITY INVOKER 函数
-- ============================================================================

-- calculate_metal_price:【一分为二】。
-- 它同时被采购页面直接调用(界面入口,必须查 data.view_prices),
-- 又被 apply_assay_result 内部调用(仓储/运营在跑,他们没有这个码)。
-- 只加一道检查会让化验应用对仓储当场失败,所以把「算」和「谁能问」分开。

-- (1) 内部算子:DEFINER,不检查,【对 authenticated / anon 收回 EXECUTE】——
--     于是它只能从别的函数体内被调用,不能当作 RPC 直接问出一个价格来。
CREATE OR REPLACE FUNCTION public.calculate_metal_price_internal(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f            pricing_formulas%ROWTYPE;
    v_ref          date := COALESCE(p_reference_date, CURRENT_DATE);
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
    v_has_terms    boolean;
    v_price        numeric;
    v_price_date   date;
    v_from         date;
    v_to           date;
    v_contained    numeric;
    v_payable_kg   numeric;
    v_value        numeric;
    v_lines        jsonb := '[]'::jsonb;
    v_skipped      text[] := ARRAY[]::text[];
    v_unpaid       text[] := ARRAY[]::text[];
    v_gross        numeric := 0;
    v_treatment    numeric;
    v_discount     numeric;
    v_net          numeric;
    v_unit         numeric;
BEGIN
    -- 1. 公式
    SELECT * INTO v_f FROM pricing_formulas
    WHERE id = p_formula_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_formula_id::text, '?');
    END IF;
    IF NOT v_f.is_active THEN
        RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
    END IF;

    -- 2. 数量
    IF p_quantity_kg IS NULL OR p_quantity_kg <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;

    -- 3. 金属清单
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        IF v_metal IS NULL OR v_metal NOT IN ('ni','co','li','mn','cu','al','fe') THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;

        v_content := (v_el->>'content_pct')::numeric;
        IF v_content IS NULL OR v_content < 0 OR v_content > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;

        -- 4. 商务条款:公式里没有这个金属 = 完全不计价(payable 0),记入 unpaid_metals。
        --    注意与 skipped 的区别:unpaid 是"没谈价",skipped 是"没行情"。
        SELECT pfm.payable_pct INTO v_payable
        FROM pricing_formula_metals pfm
        WHERE pfm.formula_id = p_formula_id AND pfm.metal = v_metal;
        v_has_terms := FOUND;
        IF NOT v_has_terms THEN
            v_payable := 0;
            v_unpaid := v_unpaid || v_metal;
        END IF;

        -- 5. 行情:spot 取参考日之前最近一条;average 取窗口内均值(窗口内无行 → NULL)。
        v_price := NULL; v_price_date := NULL; v_from := NULL; v_to := NULL;
        IF v_f.price_basis = 'spot' THEN
            SELECT mp.price_usd_per_tonne, mp.price_date
            INTO v_price, v_price_date
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL AND mp.price_date <= v_ref
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            SELECT avg(mp.price_usd_per_tonne), min(mp.price_date), max(mp.price_date)
            INTO v_price, v_from, v_to
            FROM metal_prices mp
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
              AND mp.price_date BETWEEN (v_ref - (v_f.average_days - 1)) AND v_ref;
        END IF;

        -- 无可用行情 → 跳过(贡献 0),记入 skipped_metals;沿用 allocate_processing_costs
        -- 的先例:缺行情从来不是硬错误。
        IF v_price IS NULL THEN
            v_skipped := v_skipped || v_metal;
        END IF;

        -- 6. 逐行数量与金额
        v_contained  := round(p_quantity_kg * v_content / 100.0, 4);
        v_payable_kg := round(v_contained * v_payable / 100.0, 4);
        v_value      := CASE WHEN v_price IS NULL THEN 0
                             ELSE round(v_payable_kg / 1000.0 * v_price, 2) END;
        v_gross := v_gross + v_value;

        -- 缺行情/未计价的金属同样出现在 lines 里(金额 0、价格 NULL)——
        -- 结算单据要能逐项交代,不能让它们凭空消失。
        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal,
            'content_pct', v_content,
            'payable_pct', v_payable,
            'contained_kg', v_contained,
            'payable_kg', v_payable_kg,
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', v_value
        );
    END LOOP;

    -- 7. 汇总
    v_gross     := round(v_gross, 2);
    v_treatment := round(p_quantity_kg / 1000.0 * v_f.treatment_charge_usd_per_tonne, 2);
    v_discount  := round(v_gross * v_f.flat_discount_pct / 100.0, 2);
    v_net       := round(v_gross - v_treatment - v_discount, 2);
    v_unit      := round(v_net / p_quantity_kg, 4);

    RETURN jsonb_build_object(
        'formula_id', v_f.id,
        'formula_code', v_f.code,
        'formula_name', v_f.name,
        'price_basis', v_f.price_basis,
        'average_days', v_f.average_days,
        'reference_date', v_ref,
        'quantity_kg', p_quantity_kg,
        'lines', v_lines,
        'gross_value_usd', v_gross,
        'treatment_usd', v_treatment,
        'discount_usd', v_discount,
        'net_value_usd', v_net,
        'unit_price_usd_per_kg', v_unit,
        -- 低品位料确实可能"不值它的处理费";照实返回,由调用方决定接不接这单。
        'negative_value', (v_net < 0),
        'skipped_metals', to_jsonb(v_skipped),
        'unpaid_metals', to_jsonb(v_unpaid)
    );
END;
$function$;
-- 【PUBLIC 默认就有 EXECUTE】—— 只收回 authenticated/anon 是不够的,必须先收回 PUBLIC,
-- 否则这个内部算子仍然可以被任何登录用户当 RPC 直接问出价格来。
REVOKE ALL ON FUNCTION public.calculate_metal_price_internal(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date) FROM PUBLIC, authenticated, anon;

-- (2) 界面入口:DEFINER + 顶部 data.view_prices,然后原样委托给内部算子。
CREATE OR REPLACE FUNCTION public.calculate_metal_price(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('data.view_prices');
    RETURN calculate_metal_price_internal(p_formula_id, p_metals, p_quantity_kg, p_reference_date);
END;
$function$;

-- (3) apply_assay_result 改调内部算子 —— 它自己的闸门仍是 module.inbound.edit,
--     化验应用不该因为调用者看不见价格而失败。
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
BEGIN
    PERFORM require_permission('module.inbound.edit');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
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

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    SELECT jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 公式解析:入参 → 批次 → 采购单明细行 → 无
    v_formula := COALESCE(
        p_pricing_formula_id,
        v_batch.pricing_formula_id,
        (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
          WHERE pol.id = v_batch.purchase_order_line_id)
    );

    IF v_formula IS NOT NULL THEN
        -- 3. 与计价器同一 DB 函数算价,再走与手工计价【同一条】重计价路径
        --    (reprice_inbound_batch)—— 价差分录、price_history、1200/5000 拆账
        --    三件事只存在一份实现。参考日默认化验日:结算价随行情,行情看化验那天。
        v_calc := calculate_metal_price_internal(v_formula, v_metals, v_batch.quantity,
                                        COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
        SELECT code INTO v_fcode FROM pricing_formulas WHERE id = v_formula;

        IF v_unit > 0 THEN
            v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                           'Assay ' || v_assay.code || ' applied');
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 无公式可解:含量照常落地、化验照常标记已执行,价格不动 ——
        --    手工计价的采购本来就由人定价,这不是错误。
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次的定价状态:只有真的重了价才谈得上 final
    v_status := CASE WHEN v_priced AND v_assay.is_final THEN 'final'
                     ELSE v_batch.pricing_status END;
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        pricing_status = v_status,
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

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'priced', v_priced,
        'formula_code', v_fcode,
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
$function$;

-- preview_reprice_inbound_batch:它【返回价格】,所以入口本身就要 data.view_prices。
-- 没有这个码的人拿到 PERMISSION_DENIED|data.view_prices,界面渲染「受限」;
-- 真正的应用动作 apply_assay_result 只要 module.inbound.edit,照常可用。
CREATE OR REPLACE FUNCTION public.preview_reprice_inbound_batch(p_inbound_batch_id uuid, p_new_unit_price numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old       numeric;
    v_qty       numeric;
    v_remaining numeric;
    v_usd       numeric;
    v_split     jsonb;
BEGIN
    PERFORM require_permission('data.view_prices');
    SELECT unit_price, quantity, remaining_qty
    INTO v_old, v_qty, v_remaining
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    IF p_new_unit_price IS NULL OR p_new_unit_price <= 0 THEN
        RAISE EXCEPTION 'PRICE_INVALID';
    END IF;

    -- 与提交路径同一舍入(USD 时 fx = 1)
    v_usd := round(p_new_unit_price, 4);
    v_split := reprice_split(v_qty, v_remaining, v_old, v_usd);

    RETURN jsonb_build_object(
        'old_unit_price', v_old,
        'new_unit_price', v_usd,
        'delta_usd', (v_split->>'delta_usd')::numeric,
        'in_stock_ratio', (v_split->>'in_stock_ratio')::numeric,
        'inventory_share_usd', (v_split->>'inventory_share_usd')::numeric,
        'cost_share_usd', (v_split->>'cost_share_usd')::numeric
    );
END;
$function$;


-- 让 PostgREST 立刻看到新视图与新的列权限
NOTIFY pgrst, 'reload schema';

COMMIT;

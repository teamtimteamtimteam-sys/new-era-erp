-- FIN-10:把"日期缺了就用今天"这个默认值本身拿掉。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么删默认值,而不是继续在调用方设防】
-- ════════════════════════════════════════════════════════════════════════════
-- 走查里那只虫的根不在应用层传了个空串,而在函数里【蹲着】一个
-- COALESCE(p_date, CURRENT_DATE)。只要它还在,任何调用方都能碰到它,而
-- AGENTS.md 的告诫只保护"先读了文档的人"。
--
-- 这个默认值比填错更危险,理由很具体:换成【今天】的日期永远撞不上
-- PERIOD_LOCKED。把正确的(已关期间的)日期填进去会当场被拒;留空反而顺顺当当
-- 滑进未关的当月。也就是说,这条路径专门奖励留空。
--
-- 于是:凡是这个日期决定【过账期间】或【取哪天的汇率/行情】的函数,一律去掉默认值,
-- 缺了就抛具名错误。函数自己声明了这个要求,"顺手改成 || undefined 显得干净"
-- 这个诱惑就不存在了 —— 而不是靠一条注释去劝阻。
--
-- 【调用方已核对】(按要求,先查后删):
--   * calculate_metal_price_internal 有两个库内调用方 —— calculate_metal_price
--     原样透传;apply_assay_result 传的是 COALESCE(p_reference_date, v_assay.assay_date),
--     而 assay_date 非空,所以【两者都不依赖这个默认值】,删除不会打断它们。
--   * 其余 10 个没有任何库内调用方。
--   * reverse_bank_transfer 的应用层动作此前【只传 transfer_id】,靠默认值兜底;
--     该动作目前在界面上没有任何调用点,本次一并改成必须传日期。
--
-- 【顺带修掉一处不一致】create_purchase_order 里 v_date 走了 COALESCE,
-- 而 fx_rate_for(p_currency, p_order_date, 'tt_sell') 用的是【原始参数】。
-- 也就是说:下单日留空 + 外币 → 汇率查 NULL → FX_RATE_MISSING(看得见);
-- 下单日留空 + SGD → fx_rate_for 直接返回 1,不查表 → 单据【静默记成今天】。
-- 现在参数非空是前置条件,两条路径不可能再分叉。
--
-- 【故意保留默认值的那些,见 docs/empty-string-to-rpc-audit.md 的"该留的默认值"】
-- 简言之:next_*_code(编号取年份)、leave_balance / accrued_annual_leave /
-- available_annual_accrual / annual_leave_available_from(p_as_of,"截至今天"的只读查询)、
-- create_invoice(p_issue_date,只定发票号年份与到期日,不过账、不取汇率)。
-- 它们既不决定过账期间也不决定汇率,默认成今天是对的。

BEGIN;

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
    IF p_line_ids IS NULL OR array_length(p_line_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_bank := COALESCE(p_bank_account, CASE v_p.currency WHEN 'SGD' THEN '1000' ELSE '1010' END);
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
                'currency', 'SGD', 'amount_ccy', v_cpf, 'fx_rate', 1,
                'line_memo', 'CPF for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', v_cpf, 'fx_rate', 1,
                'line_memo', 'CPF Board')));

    UPDATE payroll_periods
    SET cpf_paid_at = v_date, cpf_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'cpf_paid', v_cpf,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;


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
                'currency', 'SGD', 'amount_ccy', v_amt, 'fx_rate', 1,
                'line_memo', 'Deductions for ' || v_p.code),
            jsonb_build_object('account_code', v_bank, 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', v_amt, 'fx_rate', 1)));

    UPDATE payroll_periods
    SET deductions_paid_at = v_date, deductions_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = v_p.id;

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'deductions_paid', v_amt,
                              'period', v_p.code, 'paid_on', v_date);
END;
$function$;


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
            jsonb_build_object('account_code', '2200', 'side', 'debit', 'currency', 'SGD',
                               'amount_ccy', v_total, 'fx_rate', 1),
            jsonb_build_object('account_code', v_bank, 'side', 'credit', 'currency', 'SGD',
                               'amount_ccy', v_total, 'fx_rate', 1)));

    UPDATE processing_cost_entries
    SET remitted_at = v_date, remitted_journal_entry_id = (v_je->>'entry_id')::uuid
    WHERE id = ANY (p_entry_ids);

    RETURN jsonb_build_object('journal_code', v_je->>'code', 'entries', v_n, 'total', v_total);
END;
$function$;


CREATE OR REPLACE FUNCTION public.record_output_sale(p_output_batch_id uuid, p_quantity numeric, p_unit_price numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_customer_id uuid DEFAULT NULL::uuid, p_sale_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user          uuid := auth.uid();
    v_deleted       timestamptz;
    v_remaining     numeric;
    v_code          text;
    v_new_remaining numeric;
    v_state         text;
    v_fx            numeric;
    v_amount_base    numeric;
    v_movement_id   uuid;
    v_sale_id       uuid;
    v_sale_date     date;
    v_unit_cost     numeric;
    v_cogs          numeric;
    v_je1           jsonb;
    v_je2           jsonb;
BEGIN
    PERFORM require_permission('module.output.edit');
    IF p_sale_date IS NULL THEN
        RAISE EXCEPTION 'SALE_DATE_REQUIRED';
    END IF;
    v_sale_date := p_sale_date;
    SELECT deleted_at, remaining_qty, code INTO v_deleted, v_remaining, v_code
    FROM output_batches WHERE id = p_output_batch_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', p_output_batch_id;
    END IF;
    IF v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'OUTPUT_DELETED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'SALE_QTY_INVALID';
    END IF;
    IF p_quantity > v_remaining THEN
        RAISE EXCEPTION 'SALE_EXCEEDS_REMAINING|%|%', p_quantity, v_remaining;
    END IF;

    IF p_unit_price IS NULL OR p_unit_price <= 0 THEN
        RAISE EXCEPTION 'SALE_PRICE_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【交易日】的行方买入价(tt_buy)估值 ——
    -- 收入与应收是我们将来要【卖给银行】的外币。当日无牌价即拒(FX_RATE_MISSING),
    -- 不许悄悄用最近一天的。汇率不再由调用方递入:牌价属于 fx_rates,不属于表单。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, v_sale_date, 'tt_buy');
    v_amount_base := round(p_quantity * p_unit_price * v_fx, 2);

    INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
    VALUES (p_output_batch_id, 'sale', -p_quantity, v_sale_date, p_notes, v_user)
    RETURNING id INTO v_movement_id;

    -- customer_id 有效性由 FK 把关(可空:批次可能未指定客户)
    INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, movement_id, created_by)
    VALUES (p_output_batch_id, p_customer_id, p_quantity, p_unit_price, p_currency, v_fx, v_amount_base, v_sale_date, p_notes, v_movement_id, v_user)
    RETURNING id INTO v_sale_id;

    -- cut 2a JE#1:收入 —— 借 1100 / 贷 4000,原币行(amount_ccy = qty × price,
    -- fx 原样),USD 侧由 post_journal_entry 折算,与 amount_base 同式同值。
    v_je1 := post_journal_entry(
        v_sale_date,
        'Sale ' || v_code,
        'sale', v_sale_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '1100', 'side', 'debit',  'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit', 'currency', p_currency, 'amount_ccy', p_quantity * p_unit_price, 'fx_rate', v_fx)));

    -- cut 2a JE#2:COGS —— 有产出腿单位成本才挂;没有则只挂收入(cogs_journal 为
    -- null),等 allocate_processing_costs 补挂(见其 COGS catch-up)。
    SELECT po.unit_cost_base INTO v_unit_cost
    FROM processing_outputs po
    WHERE po.output_batch_id = p_output_batch_id
    LIMIT 1;

    IF v_unit_cost IS NOT NULL THEN
        v_cogs := round(p_quantity * v_unit_cost, 2);
        IF v_cogs <> 0 THEN
            v_je2 := post_journal_entry(
                v_sale_date,
                'COGS ' || v_code,
                'sale', v_sale_id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', 'SGD', 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', 'SGD', 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
        END IF;
    END IF;

    v_new_remaining := v_remaining - p_quantity;
    v_state := CASE WHEN v_new_remaining = 0 THEN '已售罄' ELSE '部分售出' END;

    UPDATE output_batches
    SET remaining_qty = v_new_remaining,
        state = v_state,
        updated_by = v_user,
        updated_at = now()
    WHERE id = p_output_batch_id;

    RETURN jsonb_build_object(
        'output_batch_id', p_output_batch_id,
        'sold', p_quantity,
        'remaining_qty', v_new_remaining,
        'state', v_state,
        'sale_id', v_sale_id,
        'amount_base', v_amount_base,
        'revenue_journal', v_je1->>'code',
        'cogs_journal', v_je2->>'code'
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.record_payment(p_direction text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_fx_rate numeric DEFAULT NULL::numeric, p_bank_account text DEFAULT NULL::text, p_payment_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_allocations jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user         uuid := auth.uid();
    v_date         date;
    v_fx           numeric;
    v_amount_base   numeric;
    v_doc_ccy      text;
    v_doc_fx       numeric;
    v_alloc_base   numeric;
    v_base_total   numeric := 0;
    v_bank_base    numeric;
    v_unalloc_ccy  numeric;
    v_unalloc_base numeric;
    v_po_pay_base  numeric;
    v_realised     numeric;
    v_po_base      numeric := 0;
    v_bank         text;
    v_payment_id   uuid := gen_random_uuid();
    v_code         text;
    v_alloc        jsonb;
    v_sale_id      uuid;
    v_batch_id     uuid;
    v_expense_id   uuid;
    v_po_id        uuid;
    v_alloc_usd    numeric;
    v_doc          record;
    v_doc_value    numeric;
    v_settled      numeric;
    v_open         numeric;
    v_alloc_total  numeric := 0;
    v_je           jsonb;
    -- 拆账与两遍处理用
    v_key          text;
    v_running      jsonb := '{}'::jsonb;   -- 目标 id → 本笔内已累计核销额
    v_prior        numeric;
    v_valid        jsonb := '[]'::jsonb;   -- ①校验通过的核销行,②之后据此落库
    v_po_usd       numeric := 0;           -- 本笔中指向 PO 的预付合计(USD)
    v_ap_usd       numeric;
    v_po_ccy       numeric;
    v_ap_ccy       numeric;
    v_cap          numeric;
    v_delta        numeric;
    v_found        boolean;
    v_lines        jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_payment_date IS NULL THEN
        RAISE EXCEPTION 'PAYMENT_DATE_REQUIRED';
    END IF;
    v_date := p_payment_date;
    -- 1. 基础校验
    IF p_direction IS NULL OR p_direction NOT IN ('in','out') THEN
        RAISE EXCEPTION 'DIRECTION_INVALID|%', COALESCE(p_direction, '?');
    END IF;

    IF p_direction = 'in' THEN
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM customers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    ELSE
        IF p_counterparty_id IS NULL OR NOT EXISTS (
            SELECT 1 FROM suppliers WHERE id = p_counterparty_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'COUNTERPARTY_NOT_FOUND|%', COALESCE(p_counterparty_id::text, '?');
        END IF;
    END IF;

    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'AMOUNT_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0 三分支:
    --   SGD(本位)                → 1,无换算;
    --   外币、且走该币种的外币户   → 没有发生兑换,按【付款日】牌价估值:
    --                                收款 tt_buy / 付款 tt_sell,当日无牌价即拒;
    --   外币、但走的不是该币种的户 → 银行【实际做了兑换】,必须递入按银行水单
    --                                实际金额折出的汇率(C4:实际兑换用实际数,
    --                                永远不用牌价);此时 p_fx_rate 必填。
    IF p_currency = 'SGD' THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := 1;
    ELSIF bank_native_currency(COALESCE(p_bank_account,
              CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END)) = p_currency THEN
        IF p_fx_rate IS NOT NULL THEN
            RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
        END IF;
        v_fx := fx_rate_for(p_currency, v_date,
                            CASE WHEN p_direction = 'in' THEN 'tt_buy' ELSE 'tt_sell' END);
    ELSE
        IF p_fx_rate IS NULL THEN
            RAISE EXCEPTION 'FX_RATE_REQUIRED|%', p_currency;
        END IF;
        IF p_fx_rate <= 0 THEN
            RAISE EXCEPTION 'FX_RATE_INVALID|%', p_fx_rate;
        END IF;
        v_fx := p_fx_rate;
    END IF;

    -- 银行科目:显式给了必须合法;不给按币种默认(SGD → 1000,USD → 1010)
    IF p_bank_account IS NOT NULL THEN
        IF p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', p_bank_account;
        END IF;
        v_bank := p_bank_account;
    ELSE
        v_bank := CASE WHEN p_currency = 'SGD' THEN '1000' ELSE '1010' END;
    END IF;

    -- 2. USD 金额
    v_amount_base := round(p_amount * v_fx, 2);

    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array' THEN
        RAISE EXCEPTION 'ALLOC_INVALID|not_an_array';
    END IF;

    -- ========================================================================
    -- ① 核销行:逐条校验,不落库。顺序:存在 → 归属 → 计价 → 敞口。
    --    'in' 只认 sales_record_id;'out' 认 inbound_batch_id / expense_id /
    --    purchase_order_id(预付)。
    -- ========================================================================
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations)
    LOOP
        v_sale_id    := (v_alloc->>'sales_record_id')::uuid;
        v_batch_id   := (v_alloc->>'inbound_batch_id')::uuid;
        v_expense_id := (v_alloc->>'expense_id')::uuid;
        v_po_id      := (v_alloc->>'purchase_order_id')::uuid;
        v_alloc_usd  := (v_alloc->>'amount_doc')::numeric;  -- FIN-2:单据币种金额

        IF v_alloc_usd IS NULL OR v_alloc_usd <= 0
           OR num_nonnulls(v_sale_id, v_batch_id, v_expense_id, v_po_id) <> 1 THEN
            RAISE EXCEPTION 'ALLOC_INVALID|%', v_alloc::text;
        END IF;

        IF p_direction = 'in' THEN
            IF v_batch_id IS NOT NULL OR v_expense_id IS NOT NULL OR v_po_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT sr.id, ob.code AS doc_code, sr.customer_id AS party_id,
                   round(sr.quantity * sr.unit_price, 2) AS doc_value,
                   sr.currency AS doc_ccy, sr.fx_rate AS doc_fx
            INTO v_doc
            FROM sales_records sr
            JOIN output_batches ob ON ob.id = sr.output_batch_id
            WHERE sr.id = v_sale_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_sale_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_sale_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.sales_record_id = v_sale_id;

        ELSIF v_po_id IS NOT NULL THEN
            -- 预付款:PO 上【没有敞口上限】—— 定金不是在还债,那一刻还没有债。
            -- 唯一的栏杆是"累计预付不得超过估算总额 × 1.5",防手滑多打一个零。
            SELECT po.id, po.code AS doc_code, po.supplier_id AS party_id,
                   po.estimated_total_usd, po.status AS po_status,
                   po.currency AS doc_ccy, po.fx_rate AS doc_fx
            INTO v_doc
            FROM purchase_orders po
            WHERE po.id = v_po_id AND po.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_po_id;
            END IF;
            IF v_doc.po_status = 'cancelled' THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_doc.doc_code;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_po_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.purchase_order_id = v_po_id;

            -- 1.5 倍是【刻意留出的余量】:估算按谈价时的行情算,实际化验和金属价格
            -- 波动都会把真实金额顶高,预付超过估算是正常的;超过一半就不正常了。
            v_cap := round(v_doc.estimated_total_usd * 1.5, 2);
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            IF round(v_settled + v_prior + v_alloc_usd, 2) > v_cap THEN
                RAISE EXCEPTION 'PREPAY_EXCEEDS_ESTIMATE|%|%|%',
                    v_doc.doc_code, round(v_settled + v_prior + v_alloc_usd, 2), v_cap;
            END IF;

            v_po_usd := round(v_po_usd + v_alloc_usd, 2);  -- FIN-2 起为单据币种累计
            v_doc_value := NULL;  -- 无敞口上限,跳过下面的 ALLOC_EXCEEDS

        ELSIF v_batch_id IS NOT NULL THEN
            IF v_sale_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            SELECT ib.id, ib.code AS doc_code, ib.supplier_id AS party_id,
                   ib.unit_price, ib.quantity
            INTO v_doc
            FROM inbound_batches ib
            WHERE ib.id = v_batch_id AND ib.deleted_at IS NULL;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_batch_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            IF v_doc.unit_price IS NULL THEN
                RAISE EXCEPTION 'ALLOC_UNPRICED|%', v_doc.doc_code;
            END IF;
            -- 应付额永远对着"当前"批次价值(改价即改欠款)
            v_doc_value := round(v_doc.quantity * v_doc.unit_price, 2);
            v_doc_ccy := 'SGD'; v_doc_fx := 1;  -- FIN-0 起批次价值即本位币
            v_key := v_batch_id::text;

            -- 已结 = 收付款核销 + 预付冲抵(B6 起,预付冲抵也在还这张单的应付)
            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.inbound_batch_id = v_batch_id;
            v_settled := v_settled + COALESCE(
                (SELECT SUM(ppa.amount_base) FROM prepayment_applications ppa
                  WHERE ppa.inbound_batch_id = v_batch_id), 0);

        ELSE
            IF v_sale_id IS NOT NULL THEN
                RAISE EXCEPTION 'ALLOC_WRONG_SIDE';
            END IF;
            -- 挂账开支:必须是 unpaid + posted(不存在/已付/已冲销 → ALLOC_INVALID)
            SELECT e.id, e.code AS doc_code, e.supplier_id AS party_id,
                   e.amount_ccy AS doc_value, e.currency AS doc_ccy, e.fx_rate AS doc_fx
            INTO v_doc
            FROM expenses e
            WHERE e.id = v_expense_id AND e.payment_status = 'unpaid' AND e.status = 'posted';
            IF NOT FOUND THEN
                RAISE EXCEPTION 'ALLOC_INVALID|%', v_expense_id;
            END IF;
            IF v_doc.party_id IS DISTINCT FROM p_counterparty_id THEN
                RAISE EXCEPTION 'ALLOC_WRONG_PARTY|%', v_doc.doc_code;
            END IF;
            v_doc_value := v_doc.doc_value;
            v_doc_ccy := v_doc.doc_ccy; v_doc_fx := v_doc.doc_fx;
            v_key := v_expense_id::text;

            SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
            FROM payment_allocations pa
            JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
            WHERE pa.expense_id = v_expense_id;
        END IF;

        -- 【FIN-2】结算在单据自己的币种里:USD 单据只收 USD 付款,敞口、核销、
        -- 关账全在单据币种空间闭合(基准差异归 FIN-3 期末重估,不在这里认列)。
        IF v_doc_ccy <> p_currency THEN
            RAISE EXCEPTION 'ALLOC_CURRENCY_MISMATCH|%|%|%', v_doc.doc_code, v_doc_ccy, p_currency;
        END IF;
        v_alloc_base := round(v_alloc_usd * v_doc_fx, 2);
        v_base_total := v_base_total + v_alloc_base;
        IF v_po_id IS NOT NULL THEN v_po_base := v_po_base + v_alloc_base; END IF;

        -- 敞口校验(预付除外:v_doc_value 为 NULL)。v_running 让同一目标在同一笔里
        -- 出现两次时,后一条能看见前一条 —— 原实现靠"边插边查"拿到的就是这个语义。
        IF v_doc_value IS NOT NULL THEN
            v_prior := COALESCE((v_running->>v_key)::numeric, 0);
            v_open := round(v_doc_value - v_settled - v_prior, 2);
            IF v_alloc_usd > v_open THEN
                RAISE EXCEPTION 'ALLOC_EXCEEDS|%|%|%', v_doc.doc_code, v_alloc_usd, v_open;
            END IF;
        END IF;

        v_running := v_running || jsonb_build_object(
            v_key, COALESCE((v_running->>v_key)::numeric, 0) + v_alloc_usd);
        v_valid := v_valid || jsonb_build_array(jsonb_build_object(
            'sales_record_id', v_sale_id, 'inbound_batch_id', v_batch_id,
            'expense_id', v_expense_id, 'purchase_order_id', v_po_id,
            'amount_ccy', v_alloc_usd, 'amount_base', v_alloc_base));
        v_alloc_total := v_alloc_total + v_alloc_usd;
    END LOOP;

    -- Σ 核销不得超过款额(欠核销 = 挂账余额,允许)
    IF v_alloc_total > p_amount THEN
        RAISE EXCEPTION 'ALLOC_EXCEEDS_PAYMENT|%|%', v_alloc_total, p_amount;
    END IF;
    -- 【FIN-3 修订的 C2】已实现汇兑在【结算时点】认列:
    --   控制科目按【单据的】汇率解除(不变);银行按【结算日】口径(牌价/实际);
    --   差额进 7100(已实现)。只要单据汇率和当日汇率,两个数,不追每一块钱的均价。
    -- 未核销部分与预付(非货币,按付款日历史汇率入账)都按当日口径,不产生已实现差异。
    v_bank_base    := round(p_amount * v_fx, 2);
    v_amount_base  := v_bank_base;
    v_unalloc_ccy  := p_amount - v_alloc_total;
    v_unalloc_base := round(v_unalloc_ccy * v_fx, 2);
    v_po_pay_base  := round(v_po_usd * v_fx, 2);
    -- 已实现 = 单据口径解除额 − 当日口径(同币种两率同为 1 ⇒ 恒为 0,不出现 FX 行)
    v_realised := round((v_base_total - v_po_base) - round((v_alloc_total - v_po_usd) * v_fx, 2), 2);

    -- ========================================================================
    -- ② 分录。'out' 且本笔含 PO 预付时【拆两条借方】:
    --      借 1300 预付款项  = 指向 PO 的部分
    --      借 2000 应付账款  = 其余(含未核销部分 —— 与改动前对全额借 2000 一致)
    --      贷 银行          = 全额
    --    金额:核销额是 USD,分录行按原币记,故 po_ccy = round(po_usd / fx, 2),
    --    ap_ccy = p_amount − po_ccy(【相减而非各自取整】,保证两条借方的原币恰好
    --    合计等于贷方)。USD 侧由 post_journal_entry 用 round(ccy × fx, 2) 反算,
    --    非本位币下双重取整可能差 1 分,故下面在 ±0.02 内挑一个能让 USD 恰好配平的
    --    拆分点(USD 付款 fx=1,偏移恒为 0)。
    -- ========================================================================
    v_code := fin_next_payment_code(CASE WHEN p_direction = 'in' THEN 'RCPT' ELSE 'PMT' END, v_date);

    -- 行 fx = 目标基准额 ÷ 原币额(除后反乘取整恰好还原);0 金额行一律不发。
    v_lines := '[]'::jsonb;
    IF p_direction = 'in' THEN
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'debit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        IF v_alloc_total > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                'currency', p_currency, 'amount_ccy', v_alloc_total, 'fx_rate', v_base_total / v_alloc_total,
                'line_memo', 'settled at document rate');
        END IF;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '1100', 'side', 'credit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        -- 已实现差额:贷方合计 − 银行借方。>0 = 损(补借 7100),<0 = 益(补贷 7100)
        v_realised := round(COALESCE(v_base_total, 0) + v_unalloc_base - v_bank_base, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', 'SGD', 'amount_ccy', v_realised, 'fx_rate', 1);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', -v_realised, 'fx_rate', 1);
        END IF;
    ELSE
        IF v_alloc_total - v_po_usd > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_alloc_total - v_po_usd,
                'fx_rate', (v_base_total - v_po_base) / (v_alloc_total - v_po_usd),
                'line_memo', 'settled at document rate');
        END IF;
        IF v_unalloc_ccy > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '2000', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_unalloc_ccy, 'fx_rate', v_unalloc_base / v_unalloc_ccy);
        END IF;
        IF v_po_usd > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '1300', 'side', 'debit',
                'currency', p_currency, 'amount_ccy', v_po_usd, 'fx_rate', v_po_pay_base / v_po_usd,
                'line_memo', 'Prepayment');
        END IF;
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'credit',
            'currency', p_currency, 'amount_ccy', p_amount, 'fx_rate', v_bank_base / p_amount);
        -- 借方合计 − 银行贷方:>0 说明按旧率解除得多 → 贷 7100(益);<0 → 借 7100(损)
        v_realised := round((v_base_total - v_po_base) + v_unalloc_base + v_po_pay_base - v_bank_base, 2);
        IF v_realised > 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'credit',
                'currency', 'SGD', 'amount_ccy', v_realised, 'fx_rate', 1);
        ELSIF v_realised < 0 THEN
            v_lines := v_lines || jsonb_build_object('account_code', '7100', 'side', 'debit',
                'currency', 'SGD', 'amount_ccy', -v_realised, 'fx_rate', 1);
        END IF;
    END IF;

    v_je := post_journal_entry(
        v_date,
        CASE WHEN p_direction = 'in' THEN 'Receipt ' ELSE 'Payment ' END || v_code,
        'payment', v_payment_id, v_lines);

    -- ③ 插入收付款单(带着分录链接一次到位;不可变表无后续 UPDATE)
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_payment_id, v_code, p_direction,
            CASE WHEN p_direction = 'in' THEN 'customer' ELSE 'supplier' END,
            CASE WHEN p_direction = 'in' THEN p_counterparty_id END,
            CASE WHEN p_direction = 'out' THEN p_counterparty_id END,
            p_amount, p_currency, v_fx, v_amount_base, v_bank,
            v_date, p_notes, (v_je->>'entry_id')::uuid, v_user);

    -- ④ 核销行落库(①已全部校验过,这里只写)
    FOR v_alloc IN SELECT * FROM jsonb_array_elements(v_valid)
    LOOP
        INSERT INTO payment_allocations (payment_id, sales_record_id, inbound_batch_id,
                                         expense_id, purchase_order_id, allocated_ccy, allocated_base)
        VALUES (v_payment_id,
                (v_alloc->>'sales_record_id')::uuid,
                (v_alloc->>'inbound_batch_id')::uuid,
                (v_alloc->>'expense_id')::uuid,
                (v_alloc->>'purchase_order_id')::uuid,
                (v_alloc->>'amount_ccy')::numeric,
                (v_alloc->>'amount_base')::numeric);
    END LOOP;

    RETURN jsonb_build_object(
        'payment_id', v_payment_id,
        'code', v_code,
        'amount_base', v_amount_base,
        'journal_code', v_je->>'code',
        'allocated_total', v_alloc_total,
        'unallocated', round(p_amount - v_alloc_total, 2),
        'prepaid_total', v_po_usd
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.pay_medical_claim(p_claim_id uuid, p_expense_date date DEFAULT NULL::date, p_supplier_id uuid DEFAULT NULL::uuid, p_fx_rate numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_claim record;
    v_emp   record;
    v_exp   jsonb;
    v_code  text;
    v_date  date;
    v_fx    numeric;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_expense_date IS NULL THEN
        RAISE EXCEPTION 'EXPENSE_DATE_REQUIRED';
    END IF;
    v_date := p_expense_date;

    SELECT * INTO v_claim FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'CLAIM_NOT_FOUND'; END IF;

    -- HR 那一半的把关:必须已经被批准过
    IF v_claim.status <> 'approved' THEN
        RAISE EXCEPTION 'CLAIM_NOT_APPROVED|%', v_claim.status;
    END IF;

    IF v_claim.expense_id IS NOT NULL THEN
        SELECT code INTO v_code FROM expenses WHERE id = v_claim.expense_id;
        RAISE EXCEPTION 'CLAIM_ALREADY_PAID|%', COALESCE(v_code, v_claim.expense_id::text);
    END IF;

    SELECT id, code, legal_name INTO v_emp FROM employees WHERE id = v_claim.employee_id;

    -- 【未付费用必须有一个往来对象】:expenses 的 CHECK 要求 unpaid 时 supplier_id 非空
    -- (应付账上总得有"付给谁")。员工不是供应商,所以实务上建一个
    -- "员工报销 / Staff Reimbursements" 的往来户,具体是谁写在 payee_name 与备注里。
    IF p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_REQUIRED_FOR_UNPAID';
    END IF;

    -- FIN-0:报销是 SGD,账本也是 SGD —— 不再需要任何汇率。
    -- (旧版在这里取"当天或之前最近"的一条汇率;那正是 C5 要禁掉的写法,随基准换币一并拆除。)
    IF p_fx_rate IS NOT NULL AND p_fx_rate <> 1 THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|SGD';
    END IF;
    v_fx := 1;

    v_exp := record_expense(
        p_expense_date  := v_date,
        p_account_code  := '6120',
        p_amount        := v_claim.amount_sgd,
        p_currency      := 'SGD',
        p_fx_rate       := NULL,
        p_payment_status:= 'unpaid',
        p_bank_account  := NULL,
        p_supplier_id   := p_supplier_id,
        p_payee_name    := v_emp.legal_name,
        p_notes         := format('Medical claim %s (%s)', v_claim.code, v_emp.code));

    -- 【状态仍然是 approved,不是 paid】。
    -- 这笔费用刚建出来是 unpaid —— 员工手里一分钱还没拿到。此刻把报销标成
    -- "paid" 是在说一件没发生的事。真正的结清由付款流程完成,
    -- medical_claim_status 视图从 expenses.payment_status 推导出真实状态。
    UPDATE medical_claims
    SET expense_id = (v_exp->>'expense_id')::uuid, updated_by = auth.uid()
    WHERE id = p_claim_id;

    RETURN jsonb_build_object(
        'claim_id', p_claim_id, 'claim_code', v_claim.code,
        'expense_id', v_exp->>'expense_id', 'expense_code', v_exp->>'code',
        'account_code', '6120', 'amount_sgd', v_claim.amount_sgd, 'fx_rate', v_fx,
        'payment_status', 'unpaid',
        'claim_status', 'approved',
        'note', 'An unpaid expense has been raised. The claim becomes settled when that expense is paid through the payment flow; it is not marked paid on creation.');
END;
$function$;


CREATE OR REPLACE FUNCTION public.commit_processing_run(p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id      uuid := auth.uid();
    v_process_date date;
    v_run_id       uuid;
    v_total_input  numeric := 0;
    v_total_output numeric := 0;
    v_input        jsonb;
    v_output       jsonb;
    v_inbound_id   uuid;
    v_consumed     numeric;
    v_remaining    numeric;
    v_new_remaining numeric;
    v_material_id  uuid;
    v_qty          numeric;
    v_unit         text;
    v_purity       text;
    v_new_output_id uuid;
BEGIN
    PERFORM require_permission('module.processing.edit');
    IF p_process_date IS NULL THEN
        RAISE EXCEPTION 'PROCESS_DATE_REQUIRED';
    END IF;
    v_process_date := p_process_date;
    -- 0. 基本校验
    IF p_inputs IS NULL OR jsonb_array_length(p_inputs) = 0 THEN
        RAISE EXCEPTION 'NO_INPUTS';
    END IF;
    IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN
        RAISE EXCEPTION 'NO_OUTPUTS';
    END IF;
    IF p_loss_qty IS NOT NULL AND p_loss_qty < 0 THEN
        RAISE EXCEPTION 'LOSS_NEGATIVE';
    END IF;

    -- 0b. 同一进料批次不能重复添加
    IF (SELECT count(DISTINCT elem->>'inbound_batch_id')
        FROM jsonb_array_elements(p_inputs) elem) <> jsonb_array_length(p_inputs) THEN
        RAISE EXCEPTION 'DUPLICATE_INPUT';
    END IF;

    -- 1. 遍历投入:校验库存(并锁行)+ 累计投入合计
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        IF v_consumed IS NULL OR v_consumed <= 0 THEN
            RAISE EXCEPTION 'INPUT_QTY_INVALID';
        END IF;

        SELECT remaining_qty INTO v_remaining
        FROM inbound_batches
        WHERE id = v_inbound_id AND deleted_at IS NULL
        FOR UPDATE;

        IF v_remaining IS NULL THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_inbound_id;
        END IF;
        IF v_consumed > v_remaining THEN
            RAISE EXCEPTION 'CONSUMED_EXCEEDS_REMAINING|%|%', v_consumed, v_remaining;
        END IF;

        v_total_input := v_total_input + v_consumed;
    END LOOP;

    -- 2. 遍历产出:校验 + 累计产出合计
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_qty := (v_output->>'quantity')::numeric;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'OUTPUT_QTY_INVALID';
        END IF;
        IF (v_output->>'material_id') IS NULL THEN
            RAISE EXCEPTION 'OUTPUT_NO_MATERIAL';
        END IF;
        v_total_output := v_total_output + v_qty;
    END LOOP;

    -- 3. 质量守恒:产出不能大于投入
    IF v_total_output > v_total_input THEN
        RAISE EXCEPTION 'OUTPUT_EXCEEDS_INPUT|%|%', v_total_output, v_total_input;
    END IF;

    -- 4. 建加工单表头(code 由触发器生成)
    INSERT INTO processing_runs (
        process_date, total_input, total_output, loss_qty, notes, status, created_by, updated_by
    ) VALUES (
        v_process_date, v_total_input, v_total_output,
        COALESCE(p_loss_qty, v_total_input - v_total_output),
        p_notes, 'committed', v_user_id, v_user_id
    )
    RETURNING id INTO v_run_id;

    -- 5. 再遍历投入:扣库存 + 更新阶段 + 建投入腿 + 记库存流水(消耗)
    FOR v_input IN SELECT * FROM jsonb_array_elements(p_inputs)
    LOOP
        v_inbound_id := (v_input->>'inbound_batch_id')::uuid;
        v_consumed   := (v_input->>'quantity_consumed')::numeric;

        SELECT remaining_qty INTO v_remaining
        FROM inbound_batches WHERE id = v_inbound_id;
        v_new_remaining := v_remaining - v_consumed;

        UPDATE inbound_batches
        SET remaining_qty = v_new_remaining,
            stage = CASE WHEN v_new_remaining <= 0 THEN '已加工完' ELSE '加工中' END,
            updated_by = v_user_id,
            updated_at = now()
        WHERE id = v_inbound_id;

        INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, run_id, business_date, created_by)
        VALUES (v_inbound_id, 'processing_consume', -v_consumed, v_run_id, v_process_date, v_user_id);

        INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed)
        VALUES (v_run_id, v_inbound_id, v_consumed);
    END LOOP;

    -- 6. 遍历产出:建产出批次 + 建产出腿
    --    产出的入库流水由 AFTER INSERT 触发器发出;先设置上下文标记本批产出属于本加工单。
    PERFORM set_config('evoltrya.movement_ctx', 'processing:' || v_run_id::text, true);
    FOR v_output IN SELECT * FROM jsonb_array_elements(p_outputs)
    LOOP
        v_material_id := (v_output->>'material_id')::uuid;
        v_qty         := (v_output->>'quantity')::numeric;
        v_unit        := COALESCE(NULLIF(v_output->>'unit', ''), 'kg');
        v_purity      := NULLIF(v_output->>'purity', '');

        INSERT INTO output_batches (
            material_id, quantity, unit, remaining_qty, output_date, state, purity,
            created_by, updated_by
        ) VALUES (
            v_material_id, v_qty, v_unit, v_qty, v_process_date, '库存中', v_purity,
            v_user_id, v_user_id
        )
        RETURNING id INTO v_new_output_id;

        INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced)
        VALUES (v_run_id, v_new_output_id, v_qty);
    END LOOP;

    RETURN v_run_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.calculate_metal_price_internal(p_formula_id uuid, p_metals jsonb, p_quantity_kg numeric, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_f            pricing_formulas%ROWTYPE;
    v_ref          date;
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
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    v_ref := p_reference_date;
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


CREATE OR REPLACE FUNCTION public.create_purchase_order(p_supplier_id uuid, p_order_date date, p_expected_delivery date, p_currency text, p_fx_rate numeric, p_incoterm text, p_terms_text text, p_notes text, p_lines jsonb, p_payment_terms jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user       uuid := auth.uid();
    v_date       date;
    v_fx         numeric;
    v_po_id      uuid := gen_random_uuid();
    v_code       text;
    v_line       jsonb;
    v_line_no    integer;
    v_qty        numeric;
    v_price      numeric;
    v_amount     numeric;
    v_material   uuid;
    v_formula    uuid;
    v_f          record;
    v_total      numeric := 0;
    v_count      integer := 0;
    v_term       jsonb;
    v_seq        integer;
    v_expect     integer := 0;
    v_pct_total  numeric := 0;
    v_term_count integer := 0;
BEGIN
    PERFORM require_permission('module.purchasing.edit');
    IF p_order_date IS NULL THEN
        RAISE EXCEPTION 'ORDER_DATE_REQUIRED';
    END IF;
    v_date := p_order_date;
    IF p_supplier_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM suppliers WHERE id = p_supplier_id AND deleted_at IS NULL
    ) THEN
        RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', COALESCE(p_supplier_id::text, '?');
    END IF;

    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;
    -- FIN-0:本位币 SGD 免换算;外币按【下单日】的行方卖出价(tt_sell)估值。
    -- 当日无牌价即拒 —— 这也逼着牌价当天录入(隔天可能就查不到了)。
    IF p_fx_rate IS NOT NULL THEN
        RAISE EXCEPTION 'FX_RATE_NOT_ACCEPTED|%', p_currency;
    END IF;
    v_fx := fx_rate_for(p_currency, p_order_date, 'tt_sell');

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'NO_LINES';
    END IF;

    v_code := next_purchase_order_code(v_date);

    INSERT INTO purchase_orders (id, code, supplier_id, order_date, expected_delivery_date,
                                 currency, fx_rate, estimated_total_usd, status,
                                 approval_status, approved_at, approved_by,
                                 incoterm, terms_text, notes, created_by, updated_by)
    VALUES (v_po_id, v_code, p_supplier_id, v_date, p_expected_delivery,
            p_currency, v_fx, 0, 'confirmed',
            -- 两级审批留到权限切次:这里直接盖章,结构在、流程不在(见 B1 注释)
            'approved', now(), v_user,
            p_incoterm, p_terms_text, p_notes, v_user, v_user);

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_count := v_count + 1;
        v_line_no := COALESCE((v_line->>'line_no')::integer, v_count);
        v_material := (v_line->>'material_id')::uuid;
        v_qty := (v_line->>'quantity')::numeric;
        v_price := (v_line->>'estimated_unit_price')::numeric;
        v_formula := (v_line->>'pricing_formula_id')::uuid;

        IF v_material IS NULL OR NOT EXISTS (
            SELECT 1 FROM materials WHERE id = v_material AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(v_material::text, '?');
        END IF;
        IF v_qty IS NULL OR v_qty <= 0 THEN
            RAISE EXCEPTION 'LINE_QTY_INVALID|%', v_line_no;
        END IF;
        IF v_formula IS NOT NULL THEN
            SELECT id, code, is_active, deleted_at INTO v_f
            FROM pricing_formulas WHERE id = v_formula;
            IF NOT FOUND OR v_f.deleted_at IS NOT NULL THEN
                RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_formula;
            END IF;
            IF NOT v_f.is_active THEN
                RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_f.code;
            END IF;
        END IF;

        -- 没给估价就是 0:PO 是承诺,估算金额可以留白(公式定价的料常常如此)
        v_amount := CASE WHEN v_price IS NULL THEN 0 ELSE round(v_qty * v_price, 2) END;
        v_total := v_total + v_amount;

        INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity,
                                          unit, pricing_formula_id, estimated_unit_price,
                                          estimated_amount_usd, expected_assay, notes, created_by)
        VALUES (v_po_id, v_line_no, v_material, v_qty,
                COALESCE(v_line->>'unit', 'kg'), v_formula, v_price,
                v_amount, v_line->'expected_assay', v_line->>'notes', v_user);
    END LOOP;

    UPDATE purchase_orders SET estimated_total_usd = v_total, updated_by = v_user
    WHERE id = v_po_id;

    -- 付款计划是【可选的】:有些采购就是到货即付,没有分期可言。
    IF p_payment_terms IS NOT NULL AND jsonb_typeof(p_payment_terms) = 'array'
       AND jsonb_array_length(p_payment_terms) > 0 THEN
        FOR v_term IN SELECT * FROM jsonb_array_elements(p_payment_terms)
        LOOP
            v_expect := v_expect + 1;
            v_seq := (v_term->>'seq')::integer;
            IF v_seq IS DISTINCT FROM v_expect THEN
                RAISE EXCEPTION 'TERMS_SEQ_INVALID';
            END IF;
            v_pct_total := v_pct_total + COALESCE((v_term->>'percentage')::numeric, 0);

            INSERT INTO purchase_order_payment_terms (purchase_order_id, seq, label, percentage,
                                                      fixed_amount_usd, trigger_event, due_date, notes)
            VALUES (v_po_id, v_seq, v_term->>'label',
                    (v_term->>'percentage')::numeric,
                    (v_term->>'fixed_amount_usd')::numeric,
                    v_term->>'trigger_event',
                    (v_term->>'due_date')::date,
                    v_term->>'notes');
            v_term_count := v_term_count + 1;
        END LOOP;

        IF v_pct_total > 100 THEN
            RAISE EXCEPTION 'TERMS_PCT_EXCEEDS|%', v_pct_total;
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'purchase_order_id', v_po_id,
        'code', v_code,
        'estimated_total_usd', v_total,
        'line_count', v_count,
        'term_count', v_term_count
    );
END;
$function$;


CREATE OR REPLACE FUNCTION public.reverse_bank_transfer(p_transfer_id uuid, p_reversal_date date DEFAULT NULL::date, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_t  bank_transfers%ROWTYPE;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
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

COMMIT;

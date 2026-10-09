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

    INSERT INTO expenses (id, code, expense_date, account_code, amount_ccy, currency, fx_rate, amount_base, payment_status,
                          bank_account_code, supplier_id, payee_name, notes, journal_entry_id, created_by)
    VALUES (v_exp_id, v_code, p_bill_date, fin_cost_account('electricity'), p_bill_amount, v_base, 1, p_bill_amount, p_payment_status,
            CASE WHEN p_payment_status = 'paid' THEN p_bank_account END, p_supplier_id, NULLIF(btrim(COALESCE(p_payee_name, '')), ''),
            'Electricity bill ' || v_ref || ' · ' || p_period_from || ' – ' || p_period_to
              || CASE WHEN NULLIF(btrim(COALESCE(p_notes, '')), '') IS NOT NULL THEN ' · ' || btrim(p_notes) ELSE '' END,
            v_je_id, auth.uid());

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
$function$

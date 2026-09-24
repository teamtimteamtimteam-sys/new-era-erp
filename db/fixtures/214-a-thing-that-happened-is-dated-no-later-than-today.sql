-- 214 一件已经发生的事,日期不晚于今天;一张分录,不晚于本月末;一张冲销,不早于原件(AP-RECON-1 Batch B)
--
-- Tim AP-RECON-1 Q7(Batch B 落地)的三条日期规矩,以及它们【没有测试开关】这件事:
--   A  业务单据晚于今天按名拒 DOCUMENT_DATE_IN_FUTURE|<kind>|…,七个门各撞一次:
--      费用 · 收付款 · 运费 · 出口运费 · sale 型发票 · 订单发票 · 加工应计转费用(Batch B Q6)。
--      ★ 每个门先证【非空转】:同一个调用换成今天必须过 —— 否则"被拒"可能是别的原因。
--   B  assert_posting_allowed:本月末放行(月结可以在 28 号做),下月一号按名拒。
--   C  冲销:早于原分录按名拒 REVERSAL_BEFORE_ORIGINAL,同日放行。
--   D  由系统代填冲销日的七个调用点走 reversal_date_for(今天与原分录日里较晚的那个)——
--      一张记在本月末的分录,今天就能被撤回,冲销落在月末,而不是被拒(Batch B Q5)。
--      ★ 目录断言:六支函数里那七次调用都经 reversal_date_for,没有一处再直接递 CURRENT_DATE。
--
-- 日期全部相对今天:这份 fixture 测的正是"今天"这条线本身。
-- 当天恰好是月末时,D 的"没有它就会被拒"那一半没有可分的两边 —— 照直说出来(NOTICE),不假装。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_base text;
    d  date := CURRENT_DATE;
    d_month_end date := (date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date;
    v_sup uuid; v_fwd uuid; v_cust uuid; v_mat uuid; v_mat2 uuid; v_ob uuid; v_ib uuid; v_run uuid;
    v_pce1 uuid; v_pce2 uuid; v_so uuid; v_sale uuid;
    v_res jsonb; v_je jsonb; v_je_id uuid; v_msg text; v_ok boolean; v_door text; v_n int;
    v_fn text;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-214', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    UPDATE finance_settings SET locked_before = NULL, gst_registered = false;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX214-S', 'fixture 214 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX214-F', 'fixture 214 forwarder', 'SG', 'active', 'forwarder') RETURNING id INTO v_fwd;
    INSERT INTO customers (code, legal_name, country, payment_terms_days)
    VALUES ('ZZFIX214-C', 'fixture 214 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX214-M', 'fixture 214 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZFIX214-P', 'fixture 214 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction') RETURNING id INTO v_mat2;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX214-OB', v_mat, 10000, 10000, d) RETURNING id INTO v_ob;
    -- 会话在主数据【之后】、订单行【之前】设上:订单行上的可售守卫在插入那一刻就问调用者
    -- 看不看得见物料形态;而供应商若由同一个人建,付款会撞上职责分离(SOD_PAYEE_AND_PAY)。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user), true);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_base, 1) RETURNING id INTO v_so;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_so, 1, v_mat, 10, 5);
    -- 加工应计:两条估算成本,一条给"明天"撞,一条给"今天"过
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        source_reason_code, source_reason_note)
    VALUES ('ZZFIX214-IB', v_mat2, v_sup, 100, 100, 'kg', d - 1, 'other', 'fixture 214 自带数据') RETURNING id INTO v_ib;
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (v_ib, 'discharged_verified');

    PERFORM set_sales_order_status(v_so, 'confirmed');
    PERFORM reprice_inbound_batch(v_ib, 5, v_base, NULL, 'f214');
    v_run := commit_processing_run(d, 'f214 放电', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge');
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate)
    VALUES (v_run, 'electricity', 40, true) RETURNING id INTO v_pce1;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate)
    VALUES (v_run, 'electricity', 60, true) RETURNING id INTO v_pce2;

    -- 发票要一张在册的销售(建在循环外 —— 被拒的那一次会把它所在的子事务一起回滚)
    v_res := record_output_sale(v_ob, 1, 5, v_base, NULL, v_cust, d, 'f214', 'manual', NULL);
    v_sale := (v_res->>'sale_id')::uuid;

    -- ══════════ A · 七个门:明天按名拒,今天放行 ══════════
    FOR v_door IN SELECT unnest(ARRAY['expense','payment','freight','export_freight','invoice_sale','invoice_order','accrual_relief']) LOOP
        v_ok := false; v_msg := NULL;
        BEGIN
            CASE v_door
            WHEN 'expense' THEN
                PERFORM record_expense(p_expense_date := d + 1, p_account_code := '6400', p_amount := 1,
                    p_currency := v_base, p_supplier_id := v_sup);
            WHEN 'payment' THEN
                PERFORM record_payment_internal('out', v_sup, 1, v_base, NULL, NULL, d + 1, 'f214', '[]'::jsonb, 'supplier');
            WHEN 'freight' THEN
                PERFORM record_freight_document(d + 1, v_fwd, 1, v_base, 'weight', 'unpaid', NULL,
                    jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib)), 'f214', NULL);
            WHEN 'export_freight' THEN
                PERFORM record_export_freight_document(d + 1, v_fwd, 1, v_base, 'unpaid', NULL, NULL, 'f214');
            WHEN 'invoice_sale' THEN
                PERFORM create_invoice(v_cust, ARRAY[v_sale], d + 1);
            WHEN 'invoice_order' THEN
                PERFORM create_order_invoice(v_so, d + 1);
            WHEN 'accrual_relief' THEN
                PERFORM relieve_processing_accruals(ARRAY[v_pce1], 40, d + 1, 'unpaid', NULL, v_sup, NULL, 'f214');
            END CASE;
        EXCEPTION WHEN OTHERS THEN
            v_msg := SQLERRM;
            v_ok := (SQLERRM LIKE 'DOCUMENT_DATE_IN_FUTURE|'
                     || CASE v_door WHEN 'invoice_sale' THEN 'invoice' WHEN 'invoice_order' THEN 'invoice'
                                    WHEN 'accrual_relief' THEN 'expense' ELSE v_door END
                     || '|' || (d + 1)::text || '|' || d::text);
        END;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'FIXTURE 214A 失败:明天的 % 应当 DOCUMENT_DATE_IN_FUTURE,实得 %', v_door, COALESCE(v_msg, '(收下了)');
        END IF;
        -- ★ 非空转:同一个门,今天必须过
        CASE v_door
        WHEN 'expense' THEN
            PERFORM record_expense(p_expense_date := d, p_account_code := '6400', p_amount := 1,
                p_currency := v_base, p_supplier_id := v_sup);
        WHEN 'payment' THEN
            PERFORM record_payment_internal('out', v_sup, 1, v_base, NULL, NULL, d, 'f214', '[]'::jsonb, 'supplier');
        WHEN 'freight' THEN
            PERFORM record_freight_document(d, v_fwd, 1, v_base, 'weight', 'unpaid', NULL,
                jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib)), 'f214', NULL);
        WHEN 'export_freight' THEN
            PERFORM record_export_freight_document(d, v_fwd, 1, v_base, 'unpaid', NULL, NULL, 'f214');
        WHEN 'invoice_sale' THEN
            PERFORM create_invoice(v_cust, ARRAY[v_sale], d);
        WHEN 'invoice_order' THEN
            PERFORM create_order_invoice(v_so, d);
        WHEN 'accrual_relief' THEN
            PERFORM relieve_processing_accruals(ARRAY[v_pce2], 60, d, 'unpaid', NULL, v_sup, NULL, 'f214');
        END CASE;
    END LOOP;

    -- ══════════ B · 分录:本月末放行,下月一号按名拒 ══════════
    PERFORM post_journal_entry(d_month_end, 'fixture 214 month end', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', '6400', 'side', 'debit',  'currency', v_base, 'amount_ccy', 1),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 1)));
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM post_journal_entry(d_month_end + 1, 'fixture 214 next month', 'manual', NULL, jsonb_build_array(
            jsonb_build_object('account_code', '6400', 'side', 'debit',  'currency', v_base, 'amount_ccy', 1),
            jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 1)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_ok := (SQLERRM = 'POSTING_DATE_BEYOND_CURRENT_MONTH|' || (d_month_end + 1)::text || '|' || d_month_end::text);
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 214B 失败:下月一号的分录应当 POSTING_DATE_BEYOND_CURRENT_MONTH,实得 %', COALESCE(v_msg, '(过账了)');
    END IF;
    -- 直接写 journal_entries 的路(触发器 → assert_posting_allowed)同样拦得住
    v_ok := false; v_msg := NULL;
    BEGIN
        INSERT INTO journal_entries (code, entry_date, memo, source_type) VALUES ('ZZFIX214-JE', d_month_end + 1, 'f214', 'manual');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := (SQLERRM LIKE 'POSTING_DATE_BEYOND_CURRENT_MONTH|%');
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 214B 失败:直接插一张下月的分录应当同样被拒,实得 %', COALESCE(v_msg, '(插进去了)');
    END IF;

    -- ══════════ C · 冲销:早于原分录按名拒,同日放行 ══════════
    v_je := post_journal_entry(d, 'fixture 214 to reverse', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', '6400', 'side', 'debit',  'currency', v_base, 'amount_ccy', 2),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 2)));
    v_je_id := (v_je->>'entry_id')::uuid;
    v_ok := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_journal_entry_internal(v_je_id, d - 1, 'fixture 214');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_ok := (SQLERRM = 'REVERSAL_BEFORE_ORIGINAL|' || (v_je->>'code') || '|' || (d - 1)::text || '|' || d::text);
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 214C 失败:早于原分录一天的冲销应当 REVERSAL_BEFORE_ORIGINAL,实得 %', COALESCE(v_msg, '(冲了)');
    END IF;
    PERFORM reverse_journal_entry_internal(v_je_id, d, 'fixture 214');

    -- ══════════ D · 代填冲销日:今天与原分录日里较晚的那个 ══════════
    v_je := post_journal_entry(d_month_end, 'fixture 214 month-end entry', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', '6400', 'side', 'debit',  'currency', v_base, 'amount_ccy', 3),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 3)));
    v_je_id := (v_je->>'entry_id')::uuid;
    IF reversal_date_for(v_je_id) <> d_month_end THEN
        RAISE EXCEPTION 'FIXTURE 214D 失败:记在 % 的分录,代填的冲销日应当是 %,实得 %', d_month_end, d_month_end, reversal_date_for(v_je_id);
    END IF;
    IF d_month_end > d THEN
        -- ★ 非空转:不经它、直接递今天,就会被拒 —— 这正是它存在的理由
        v_ok := false;
        BEGIN
            PERFORM reverse_journal_entry_internal(v_je_id, d, 'fixture 214 today');
        EXCEPTION WHEN OTHERS THEN v_ok := (SQLERRM LIKE 'REVERSAL_BEFORE_ORIGINAL|%');
        END;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'FIXTURE 214D 失败(空转):直接递今天去冲一张记在月末的分录,本应 REVERSAL_BEFORE_ORIGINAL';
        END IF;
    ELSE
        RAISE NOTICE 'fixture 214 D:今天恰好是月末,"直接递今天会被拒"那一半没有可分的两边 —— 本次只证了 reversal_date_for 的值';
    END IF;
    PERFORM reverse_journal_entry_internal(v_je_id, reversal_date_for(v_je_id), 'fixture 214');
    IF (SELECT r.entry_date FROM journal_entries o JOIN journal_entries r ON r.id = o.reversed_by WHERE o.id = v_je_id) <> d_month_end THEN
        RAISE EXCEPTION 'FIXTURE 214D 失败:冲销应当落在原分录那一天 %', d_month_end;
    END IF;
    -- 目录断言:七次代填全部经 reversal_date_for,没有一处再直接递 CURRENT_DATE
    FOREACH v_fn IN ARRAY ARRAY['reverse_expense(uuid,text)', 'reverse_payment_internal(uuid,text)',
                                'reverse_freight_document(uuid,text)', 'unpost_payroll_period(uuid,text)',
                                'rollback_processing_run(uuid,text)', 'allocate_processing_costs(uuid,text)'] LOOP
        IF to_regprocedure('public.' || v_fn) IS NULL THEN
            RAISE EXCEPTION 'FIXTURE 214D 前提失败:找不到 % —— 签名变了,这条目录断言要跟着改', v_fn;
        END IF;
        IF pg_get_functiondef(to_regprocedure('public.' || v_fn)) ~ 'reverse_journal_entry_internal\([^,]*,\s*CURRENT_DATE' THEN
            RAISE EXCEPTION 'FIXTURE 214D 失败:% 仍然直接用 CURRENT_DATE 冲销 —— 记在月末的原件会被 REVERSAL_BEFORE_ORIGINAL 挡住', v_fn;
        END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ~ 'reverse_journal_entry_internal\([^,]*,\s*reversal_date_for\(';
    IF v_n <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 214D 失败:经 reversal_date_for 代填冲销日的函数应当恰好 6 支(七次调用),实得 %', v_n;
    END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'FIXTURE 214 全部通过:A 七个门明天按名拒、今天放行 · B 分录不晚于本月末 · C 冲销不早于原件 · D 代填冲销日取较晚者';
END $$;
ROLLBACK;

-- fixture 296 —— 四条单据链上【任两步】互相找得到:每一步的单据页上,单据链条都指得到每一步的那一张(SYSTEM-MAP-3)
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 2026-10-26 裁定 2.4 (12) · 2026-10-27 SYSTEM-MAP-3 Step 1:"a gate fixture on a local rebuild that builds one complete
--   document set per chain and proves every adjacent pair links both ways through the bar, every case rolled back"。
--
-- 【证的是什么】单据链条的取数是 document_chain_walk()(页面原样调它,lib/chains.ts 原样给它定义)。
--   本文件给四条链各造【一套完整的单据】(每一步恰好一张),然后从【每一步的那一张】出发走一次,
--   断言链上【每一步】都找到了那一步的那一张 —— 于是任两步(含相邻的每一对)两个方向都连得上。
--   比"相邻两步"更强:它也证了隔着几步的那几格(付款单页上看得见采购单)。
-- 【A 臂】四条链 × 每一步出发:8 + 5 + 8 + 5 = 26 次走,每次 N 格。
-- 【N 臂 —— 反面对照】一个只有采购与进料闸的读者,从采购单走:进料批找得到、付款申请 / 付款 / 对账单【一张都找不到】
--   (RLS 自己回答 —— 页面上那几步按权限画「受限」)。没有这一臂,A 臂可以是"函数返回了全部"。
-- 【R 臂 —— 声明的边与关联页是同一份】search_related_rows() 经 'arm' 分支从工资期间数出那一张已批准的请假,
--   而【待批】的那一张不在(Tim Q3);从付款申请数出那一批货;从付款数出那一张对账单。
-- 【C 臂 —— 加班批的单据号(Tim Q4)】触发器开着插两批:当月第一批 OT-YYYY-MM,补充批 OT-YYYY-MM-2。
-- 【T 臂 —— 时间上限(-fu2)】app.chain_walk_budget_ms 收到 0:按名拒 DOCUMENT_CHAIN_WALK_BUDGET;放回之后照常。
-- 【D 臂 —— 定义坏了要响】一个不在册的种类 · 一个认不出的判据 · 一条指出界的边 · 读者那一张不在它说的那一步:四种都按名拒。
--
-- ★ 定义是 lib/chains.ts 的那四条(chainWalkDefinition 的输出),下面逐字抄着;scripts/check-chain-bar.mjs 逐条核对
--   这四行 `-- CHAIN <id>` 与那个文件说的是同一件事 —— 改链不改这里,构建就红。
-- ★ 造数据走 session_replication_role = replica(只在本地重建上 —— 这支 fixture 只由 db/gate.py 对着一个一次性的本地库跑;
--   线上从来不跑它,那条规矩写在 AGENTS.md 与委托书的 LIVE SAFETY 里)。外键与触发器在 replica 下都不跑,
--   所以单据号与外键值都由本文件自己写对。读一律在 SET LOCAL ROLE authenticated + 读者的 claims 下。
-- 自带数据、日期落在 2025(README 第 2/4/5 条),整支回滚。
BEGIN;
DO $f296$
DECLARE
    c_purchasing constant jsonb := '{"steps":[{"keys":["purchase_order"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["assay_result"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["inbound_batch"],"filter":"payable"},{"keys":["payment_request"],"filter":null},{"keys":["payment_out"],"filter":null},{"keys":["bank_statement"],"filter":null}],"edges":[[0,1],[1,2],[1,3],[2,3],[3,4],[4,5],[5,6],[4,6],[6,7]]}';  -- CHAIN purchasing
    c_processing constant jsonb := '{"steps":[{"keys":["work_order"],"filter":null},{"keys":["processing_run"],"filter":null},{"keys":["inbound_batch"],"filter":null},{"keys":["output_batch","output_aluminium_foil","output_anode_powder","output_anode_sheet","output_casing","output_cathode_powder","output_cathode_sheet","output_cell","output_collected_dust","output_copper_foil","output_harness_bms_busbar","output_separator","output_structural_parts"],"filter":null},{"keys":["processing_run"],"filter":"cost_allocation"}],"edges":[[0,1],[1,2],[1,3],[1,4]]}';  -- CHAIN processing
    c_sales      constant jsonb := '{"steps":[{"keys":["quote"],"filter":null},{"keys":["sales_order"],"filter":null},{"keys":["sales_order"],"filter":"reservation"},{"keys":["shipment"],"filter":null},{"keys":["container"],"filter":null},{"keys":["invoice"],"filter":null},{"keys":["payment_receipt"],"filter":null},{"keys":["credit_note"],"filter":null}],"edges":[[0,1],[1,2],[1,3],[2,3],[3,4],[1,5],[5,6],[5,7]]}';  -- CHAIN sales
    c_people     constant jsonb := '{"steps":[{"keys":["attendance_period"],"filter":null},{"keys":["overtime_batch"],"filter":null},{"keys":["leave_request"],"filter":null},{"keys":["payroll_period"],"filter":null},{"keys":["journal_entry"],"filter":"payroll_payment"}],"edges":[[0,3],[1,3],[2,3],[3,4]]}';  -- CHAIN people

    u_all   uuid := gen_random_uuid();
    u_purch uuid := gen_random_uuid();
    r_all   uuid;
    r_purch uuid;
    v_ccy   text;
    v_acct  uuid;
    v_lt    text;
    m       constant date := DATE '2025-06-01';

    v_sup uuid := gen_random_uuid(); v_mat uuid := gen_random_uuid(); v_cus uuid := gen_random_uuid(); v_emp uuid := gen_random_uuid();
    -- 采购
    po uuid := gen_random_uuid(); ib uuid := gen_random_uuid(); asy uuid := gen_random_uuid(); je_buy uuid := gen_random_uuid();
    preq uuid := gen_random_uuid(); pmt uuid := gen_random_uuid(); je_pmt uuid := gen_random_uuid(); jl_pmt uuid := gen_random_uuid();
    bs uuid := gen_random_uuid(); bsl uuid := gen_random_uuid();
    -- 加工
    wo uuid := gen_random_uuid(); run uuid := gen_random_uuid(); ib2 uuid := gen_random_uuid(); ob uuid := gen_random_uuid();
    -- 销售
    qt uuid := gen_random_uuid(); so uuid := gen_random_uuid(); sol uuid := gen_random_uuid(); ob2 uuid := gen_random_uuid();
    shp uuid := gen_random_uuid(); ctr uuid := gen_random_uuid(); inv uuid := gen_random_uuid(); je_inv uuid := gen_random_uuid();
    rcpt uuid := gen_random_uuid(); je_rcpt uuid := gen_random_uuid(); cn uuid := gen_random_uuid(); je_cn uuid := gen_random_uuid();
    -- 人事
    att uuid := gen_random_uuid(); ot uuid := gen_random_uuid(); lv uuid := gen_random_uuid(); lv_pending uuid := gen_random_uuid();
    pay uuid := gen_random_uuid(); je_pay uuid := gen_random_uuid();

    -- 每条链每一步的那一张:(步骤, 种类, id)
    want jsonb;
    c    record;
    s    record;
    t    record;
    v_n  integer;
    v_hits integer := 0;
    v_walks integer := 0;
    v_msg text;
    v_code text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    SELECT id INTO v_acct FROM accounts WHERE code = '1000';
    SELECT code INTO v_lt FROM leave_types ORDER BY code LIMIT 1;
    IF v_ccy IS NULL OR v_acct IS NULL OR v_lt IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 296 前提失败:基础币种 % · 科目 1000 % · 假期类型 % 应当由种子给出', v_ccy, v_acct, v_lt;
    END IF;

    -- 读者:一个持四条链全部读码的,一个只持采购与进料的
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-296-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.purchasing.view', 'module.inbound.view', 'module.finance.view', 'module.processing.view',
        'module.output.view', 'module.sales.view', 'module.logistics.view', 'module.hr.view', 'data.view_pay', 'data.view_prices',
        'data.view_purchase_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-296-purch', 'f', 'f', true) RETURNING id INTO r_purch;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_purch, unnest(ARRAY['module.purchasing.view', 'module.inbound.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_purch, r_purch);

    -- ══ 造数据(replica:外键与触发器不跑,单据号与外键值由这里写对)══════════════
    SET LOCAL session_replication_role = replica;
    INSERT INTO suppliers (id, code, legal_name, country, counterparty_type, status)
    VALUES (v_sup, 'SUP-2025-9296', 'fixture 296 supplier', 'SG', 'goods_supplier', 'active');
    INSERT INTO materials (id, code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES (v_mat, 'MAT-2025-9296', 'fixture 296 material', 'battery_material', true, 'black_mass', 'end_of_life');
    INSERT INTO customers (id, code, legal_name, country) VALUES (v_cus, 'CUS-2025-9296', 'fixture 296 customer', 'SG');
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date)
    VALUES (v_emp, 'EMP-2025-9296', 'fixture 296 employee', 'full_time', 'office', DATE '2024-01-01');

    -- 采购:采购单 → 进料批 → 化验 → 定价(同一批)→ 应付(这一批的计价分录)→ 付款申请(核销这一批)→ 付款 → 对账单(匹配付款那一行)
    INSERT INTO purchase_orders (id, code, supplier_id, order_date, fx_rate, category, currency)
    VALUES (po, 'PO-2025-9296', v_sup, DATE '2025-06-02', 1, 'consumables', v_ccy);
    INSERT INTO inbound_batches (id, code, material_id, supplier_id, quantity, remaining_qty, purchase_order_id, arrival_date)
    VALUES (ib, 'IN-2025-9296', v_mat, v_sup, 100, 100, po, DATE '2025-06-03');
    INSERT INTO assay_results (id, code, assay_date, result_party, inbound_batch_id)
    VALUES (asy, 'ASY-2025-9296', DATE '2025-06-04', 'ours', ib);
    INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
    VALUES (je_buy, 'JE-2025-9201', DATE '2025-06-05', 'purchase', ib, 'posted');
    INSERT INTO payments (id, code, direction, counterparty_type, supplier_id, amount_ccy, currency, fx_rate, amount_base,
                          bank_account_code, payment_date, journal_entry_id, status)
    VALUES (pmt, 'PMT-2025-9296', 'out', 'supplier', v_sup, 50, v_ccy, 1, 50, '1000', DATE '2025-06-07', je_pmt, 'posted');
    INSERT INTO payment_requests (id, code, kind, counterparty_type, supplier_id, amount_ccy, currency, amount_base, created_by,
                                  planned_date, allocations, status, decided_at, decided_by, paid_at, paid_by, result_payment_id)
    VALUES (preq, 'PREQ-2025-9296', 'payment_out', 'supplier', v_sup, 50, v_ccy, 50, u_all, DATE '2025-06-06',
            jsonb_build_array(jsonb_build_object('inbound_batch_id', ib::text, 'amount', 50)),
            'paid', now(), u_all, now(), u_all, pmt);
    INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status)
    VALUES (je_pmt, 'JE-2025-9202', DATE '2025-06-07', 'payment', pmt, 'posted');
    INSERT INTO journal_lines (id, entry_id, account_id, currency, amount_ccy, fx_rate, debit, credit)
    VALUES (jl_pmt, je_pmt, v_acct, v_ccy, 50, 1, 0, 50);
    INSERT INTO bank_statements (id, code, bank_account_code, currency, period_start, period_end, opening_balance, closing_balance)
    VALUES (bs, 'BS-2025-9296', '1000', v_ccy, DATE '2025-06-01', DATE '2025-06-30', 100, 50);
    INSERT INTO bank_statement_lines (id, statement_id, line_no, line_date, amount, match_status)
    VALUES (bsl, bs, 1, DATE '2025-06-07', -50, 'matched');
    INSERT INTO bank_line_matches (statement_line_id, journal_line_id, matched_amount) VALUES (bsl, jl_pmt, 50);

    -- 加工:工单 → 加工(投入一批货、产出一批、有一行成本分摊)
    INSERT INTO work_orders (id, code, status) VALUES (wo, 'WO-2025-9296', 'released');
    INSERT INTO inbound_batches (id, code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES (ib2, 'IN-2025-9297', v_mat, v_sup, 100, 0, DATE '2025-06-03');
    INSERT INTO processing_runs (id, code, status, allocation_basis, work_order_id, operation_type_code)
    VALUES (run, 'PROC-2025-9296', 'committed', 'weight', wo, 'shred');
    INSERT INTO processing_inputs (run_id, inbound_batch_id, quantity_consumed) VALUES (run, ib2, 100);
    INSERT INTO output_batches (id, code, material_id, quantity, remaining_qty) VALUES (ob, 'OUT-2025-9296', v_mat, 90, 90);
    INSERT INTO processing_outputs (run_id, output_batch_id, quantity_produced) VALUES (run, ob, 90);
    INSERT INTO batch_processing_cost_allocations (run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
    VALUES (run, ib2, 10, 100, 100);

    -- 销售:报价 → 订单(有一行预留)→ 发货 → 柜 → 发票 → 收款 → 贷项通知单
    INSERT INTO sales_orders (id, code, customer_id, order_date, currency, fx_rate, status)
    VALUES (so, 'SO-2025-9296', v_cus, DATE '2025-06-10', v_ccy, 1, 'confirmed');
    INSERT INTO quotes (id, code, customer_id, quote_date, valid_until, currency, fx_rate, status, converted_order_id)
    VALUES (qt, 'QT-2025-9296', v_cus, DATE '2025-06-09', DATE '2025-07-09', v_ccy, 1, 'converted', so);
    INSERT INTO sales_order_lines (id, sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (sol, so, 1, v_mat, 10, 5);
    INSERT INTO output_batches (id, code, material_id, quantity, remaining_qty) VALUES (ob2, 'OUT-2025-9297', v_mat, 10, 10);
    INSERT INTO sales_order_reservations (sales_order_line_id, output_batch_id, qty, pair_id) VALUES (sol, ob2, 10, gen_random_uuid());
    INSERT INTO containers (id, code, departure_date) VALUES (ctr, 'CTR-2025-9296', DATE '2025-06-12');
    INSERT INTO shipments (id, code, sales_order_id, ship_date, container_id) VALUES (shp, 'SHP-2025-9296', so, DATE '2025-06-12', ctr);
    INSERT INTO journal_entries (id, code, entry_date, source_type, status) VALUES (je_inv, 'JE-2025-9203', DATE '2025-06-11', 'invoice', 'posted');
    INSERT INTO invoices (id, code, customer_id, issue_date, due_date, payment_terms_days, currency, subtotal_base, total_base,
                          bill_to_snapshot, kind, sales_order_id, entry_id, fx_rate, status)
    VALUES (inv, 'INV-2025-9296', v_cus, DATE '2025-06-11', DATE '2025-07-11', 30, v_ccy, 50, 50, '{}'::jsonb, 'order', so, je_inv, 1, 'issued');
    INSERT INTO journal_entries (id, code, entry_date, source_type, status) VALUES (je_rcpt, 'JE-2025-9204', DATE '2025-06-20', 'payment', 'posted');
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, amount_ccy, currency, fx_rate, amount_base,
                          bank_account_code, payment_date, journal_entry_id, status)
    VALUES (rcpt, 'RCPT-2025-9296', 'in', 'customer', v_cus, 40, v_ccy, 1, 40, '1000', DATE '2025-06-20', je_rcpt, 'posted');
    INSERT INTO payment_allocations (payment_id, invoice_id, allocated_base, allocated_ccy, allocated_pay) VALUES (rcpt, inv, 40, 40, 40);
    INSERT INTO journal_entries (id, code, entry_date, source_type, status) VALUES (je_cn, 'JE-2025-9205', DATE '2025-06-21', 'credit_note', 'posted');
    INSERT INTO credit_notes (id, code, invoice_id, reason, note_date, entry_id, currency, fx_rate)
    VALUES (cn, 'CN-2025-9296', inv, 'fixture 296', DATE '2025-06-21', je_cn, v_ccy, 1);

    -- 人事:那个月的考勤 · 一批已批准的加班 · 一张已批准的请假(另有一张【待批】的,不该连上)→ 工资期间 → 付薪分录
    INSERT INTO attendance_periods (id, code, period_month) VALUES (att, 'ATT-2025-06', m);
    INSERT INTO overtime_batches (id, label, period_month, seq, status, submitted_at, decided_at, code)
    VALUES (ot, 'OT 2025-06 #1', m, 1, 'approved', now(), now(), 'OT-2025-06');
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status)
    VALUES (lv, 'LV-2025-9296', v_emp, v_lt, DATE '2025-05-30', DATE '2025-06-03', 3, 'approved');
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status)
    VALUES (lv_pending, 'LV-2025-9297', v_emp, v_lt, DATE '2025-06-10', DATE '2025-06-11', 2, 'pending');
    INSERT INTO payroll_periods (id, code, period_month, payment_date, fx_rate, currency) VALUES (pay, 'PAY-2025-9296', m, DATE '2025-06-28', 1, v_ccy);
    INSERT INTO journal_entries (id, code, entry_date, source_type, source_id, status) VALUES (je_pay, 'JE-2025-9206', DATE '2025-06-28', 'payroll', pay, 'posted');
    INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, net_pay, paid_journal_entry_id, paid_at)
    VALUES (pay, v_emp, 1000, 800, je_pay, now());
    SET LOCAL session_replication_role = origin;

    -- 每条链每一步的那一张
    want := jsonb_build_object(
        'purchasing', jsonb_build_array(
            jsonb_build_array('purchase_order', po), jsonb_build_array('inbound_batch', ib), jsonb_build_array('assay_result', asy),
            jsonb_build_array('inbound_batch', ib), jsonb_build_array('inbound_batch', ib), jsonb_build_array('payment_request', preq),
            jsonb_build_array('payment_out', pmt), jsonb_build_array('bank_statement', bs)),
        'processing', jsonb_build_array(
            jsonb_build_array('work_order', wo), jsonb_build_array('processing_run', run), jsonb_build_array('inbound_batch', ib2),
            jsonb_build_array('output_batch', ob), jsonb_build_array('processing_run', run)),
        'sales', jsonb_build_array(
            jsonb_build_array('quote', qt), jsonb_build_array('sales_order', so), jsonb_build_array('sales_order', so),
            jsonb_build_array('shipment', shp), jsonb_build_array('container', ctr), jsonb_build_array('invoice', inv),
            jsonb_build_array('payment_receipt', rcpt), jsonb_build_array('credit_note', cn)),
        'people', jsonb_build_array(
            jsonb_build_array('attendance_period', att), jsonb_build_array('overtime_batch', ot), jsonb_build_array('leave_request', lv),
            jsonb_build_array('payroll_period', pay), jsonb_build_array('journal_entry', je_pay)));

    -- ══ A 臂:四条链 × 每一步出发,链上每一步都找到那一张 ══════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    FOR c IN SELECT * FROM (VALUES ('purchasing', c_purchasing), ('processing', c_processing), ('sales', c_sales), ('people', c_people)) x(name, def) LOOP
        FOR s IN SELECT (o.i - 1)::integer AS idx, o.v->>0 AS k, (o.v->>1)::uuid AS doc
                   FROM jsonb_array_elements(want->c.name) WITH ORDINALITY o(v, i) LOOP
            v_walks := v_walks + 1;
            FOR t IN SELECT (o.i - 1)::integer AS idx, o.v->>0 AS k, (o.v->>1)::uuid AS doc
                       FROM jsonb_array_elements(want->c.name) WITH ORDINALITY o(v, i) LOOP
                SELECT count(*) INTO v_n FROM document_chain_walk(c.def, s.idx, s.k, s.doc) w
                 WHERE w.step = t.idx AND w.id = t.doc AND w.key = t.k;
                IF v_n <> 1 THEN
                    RAISE EXCEPTION 'FIXTURE 296A 失败:% 链,从第 % 步(% %)出发,第 % 步没有找到它的那一张(% %);走出来的是 %',
                        c.name, s.idx, s.k, s.doc, t.idx, t.k, t.doc,
                        (SELECT coalesce(string_agg(w.step || ':' || w.code, ', ' ORDER BY w.step), '(空)')
                           FROM document_chain_walk(c.def, s.idx, s.k, s.doc) w);
                END IF;
                v_hits := v_hits + 1;
            END LOOP;
            -- 一步只有那一张 —— 走出来的不多不少(待批的请假、别的单据都不在)
            SELECT count(*) INTO v_n FROM document_chain_walk(c.def, s.idx, s.k, s.doc);
            IF v_n <> jsonb_array_length(want->c.name) THEN
                RAISE EXCEPTION 'FIXTURE 296A 失败:% 链,从第 % 步出发走出 % 行,应当恰好 % 行(每步一张):%', c.name, s.idx, v_n,
                    jsonb_array_length(want->c.name),
                    (SELECT string_agg(w.step || ':' || w.code, ', ' ORDER BY w.step) FROM document_chain_walk(c.def, s.idx, s.k, s.doc) w);
            END IF;
        END LOOP;
    END LOOP;
    IF v_walks <> 26 OR v_hits <> 8*8 + 5*5 + 8*8 + 5*5 THEN
        RAISE EXCEPTION 'FIXTURE 296A 失败:只走了 % 次、核对了 % 格,应当 26 次 · 178 格 —— 判据瞎了', v_walks, v_hits;
    END IF;
    -- 地址:单据步骤落在那一张自己的页面上(进料批是 /inbound/<id>/edit,化验单是 /inbound/<批>/assays/<id>)
    SELECT count(*) INTO v_n FROM document_chain_walk(c_purchasing, 0, 'purchase_order', po) w
     WHERE (w.step = 1 AND w.href = '/inbound/' || ib || '/edit')
        OR (w.step = 2 AND w.href = '/inbound/' || ib || '/assays/' || asy)
        OR (w.step = 0 AND w.href = '/purchasing/orders/' || po);
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 296A 失败:detail_route 没有填对(3 格里对了 %)', v_n;
    END IF;

    -- ══ R 臂:声明的边就是关联页的边 ══════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM search_related_rows('payroll_period', pay, 'leave_request', 20, NULL);
    IF v_n <> 1 OR NOT EXISTS (SELECT 1 FROM search_related_rows('payroll_period', pay, 'leave_request', 20, NULL) x WHERE x.id = lv) THEN
        RAISE EXCEPTION 'FIXTURE 296R 失败:工资期间的关联请假应当恰好是那一张已批准的(待批的不算,Tim Q3),数出 %', v_n;
    END IF;
    SELECT n INTO v_n FROM search_related('payment_request', preq) WHERE target_key = 'inbound_batch';
    IF v_n IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FIXTURE 296R 失败:关联计数(search_related)从付款申请数进料批应当 1,得 %', v_n;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM search_related_rows('payment_out', pmt, 'bank_statement', 20, NULL) x WHERE x.id = bs) THEN
        RAISE EXCEPTION 'FIXTURE 296R 失败:付款 → 对账单那条声明的边在关联页上不在';
    END IF;

    -- ══ N 臂:反面对照 —— 只有采购与进料闸的读者 ══════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_purch), true);
    SELECT count(*) INTO v_n FROM document_chain_walk(c_purchasing, 0, 'purchase_order', po) w WHERE w.step = 1 AND w.id = ib;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 296N 失败:前提 —— 采购读者从采购单应当找得到进料批';
    END IF;
    SELECT count(*) INTO v_n FROM document_chain_walk(c_purchasing, 0, 'purchase_order', po) w WHERE w.step IN (4, 5, 6, 7);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 296N 失败:一个没有财务闸的读者从采购单走出了 % 张应付 / 付款申请 / 付款 / 对账单 —— 取数没有按读者自己的身份走', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM search_related_rows('inbound_batch', ib, 'payment_request', 20, NULL);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 296N 失败:声明的边绕过了付款申请的读策略(% 行)', v_n;
    END IF;
    EXECUTE 'RESET ROLE';

    -- ══ C 臂:加班批的单据号由触发器铸(Tim Q4)══════════════════════════════════
    SET LOCAL session_replication_role = origin;
    INSERT INTO overtime_batches (label, period_month, seq, status) VALUES ('OT 2025-04 #1', DATE '2025-04-01', 1, 'draft') RETURNING code INTO v_code;
    IF v_code IS DISTINCT FROM 'OT-2025-04' THEN
        RAISE EXCEPTION 'FIXTURE 296C 失败:当月第一批的单据号应当是 OT-2025-04,得 %', v_code;
    END IF;
    INSERT INTO overtime_batches (label, period_month, seq, status, discarded_at) VALUES ('OT 2025-04 #2', DATE '2025-04-01', 2, 'discarded', now()) RETURNING code INTO v_code;
    IF v_code IS DISTINCT FROM 'OT-2025-04-2' THEN
        RAISE EXCEPTION 'FIXTURE 296C 失败:补充批的单据号应当是 OT-2025-04-2,得 %', v_code;
    END IF;

    -- ══ D 臂:定义坏了要响 ════════════════════════════════════════════════════════
    BEGIN
        PERFORM * FROM document_chain_walk('{"steps":[{"keys":["no_such_kind"],"filter":null}],"edges":[]}'::jsonb, 0, 'no_such_kind', po);
        RAISE EXCEPTION 'FIXTURE 296D 失败:不在册的种类没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'SEARCH_UNKNOWN_DOCUMENT_TYPE|%' THEN RAISE EXCEPTION 'FIXTURE 296D 失败:%', v_msg; END IF;
    END;
    BEGIN
        PERFORM * FROM document_chain_walk('{"steps":[{"keys":["purchase_order"],"filter":"nope"}],"edges":[]}'::jsonb, 0, 'purchase_order', po);
        RAISE EXCEPTION 'FIXTURE 296D 失败:认不出的判据没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'DOCUMENT_CHAIN_UNKNOWN_FILTER|%' THEN RAISE EXCEPTION 'FIXTURE 296D 失败:%', v_msg; END IF;
    END;
    BEGIN
        PERFORM * FROM document_chain_walk('{"steps":[{"keys":["purchase_order"],"filter":null}],"edges":[[0,3]]}'::jsonb, 0, 'purchase_order', po);
        RAISE EXCEPTION 'FIXTURE 296D 失败:出界的边没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'DOCUMENT_CHAIN_BAD_DEFINITION|%' THEN RAISE EXCEPTION 'FIXTURE 296D 失败:%', v_msg; END IF;
    END;
    BEGIN
        PERFORM * FROM document_chain_walk(c_purchasing, 0, 'inbound_batch', ib);
        RAISE EXCEPTION 'FIXTURE 296D 失败:读者那一张不在它说的那一步,没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'DOCUMENT_CHAIN_KEY_NOT_IN_STEP|%' THEN RAISE EXCEPTION 'FIXTURE 296D 失败:%', v_msg; END IF;
    END;

    -- ══ T 臂:时间上限真的会拒(-fu2)—— 上限收到 0,第一跳之前就按名拒;放回之后照常 ══════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    PERFORM set_config('app.chain_walk_budget_ms', '0', true);
    BEGIN
        PERFORM * FROM document_chain_walk(c_purchasing, 0, 'purchase_order', po);
        RAISE EXCEPTION 'FIXTURE 296T 失败:上限 0 毫秒的一次走链没有被拒';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'DOCUMENT_CHAIN_WALK_BUDGET|%' THEN RAISE EXCEPTION 'FIXTURE 296T 失败:%', v_msg; END IF;
    END;
    PERFORM set_config('app.chain_walk_budget_ms', '', true);
    SELECT count(*) INTO v_n FROM document_chain_walk(c_purchasing, 0, 'purchase_order', po);
    IF v_n <> 8 THEN RAISE EXCEPTION 'FIXTURE 296T 失败:上限放回之后应当照常走出 8 行,得 %', v_n; END IF;
    EXECUTE 'RESET ROLE';

    RAISE NOTICE 'FIXTURE 296 全部通过:A 四条链 26 次走、178 格(任两步互相找得到,每步恰好一张,地址落在单据自己那一页)· '
                 'R 声明的边就是关联页的边(已批准的请假在、待批的不在)· N 没有财务闸的读者走不到应付以后 · '
                 'C OT-2025-04 / OT-2025-04-2 · D 四种坏定义按名拒 · T 时间上限按名拒(DOCUMENT_CHAIN_WALK_BUDGET)';
END;
$f296$;
ROLLBACK;

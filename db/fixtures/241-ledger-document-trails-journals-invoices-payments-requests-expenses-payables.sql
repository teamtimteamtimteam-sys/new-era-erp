-- 241 AUDIT-TRAIL-1c-1:账上单据的审计记录 —— 分录 · 发票 · 贷项通知 · 收付款 · 付款申请 · 费用 · 应付;
--     M7(没有外键的表整张属于一个单行设置主语)· Q16(一次操作一个键)· Q12(引用里的员工名照 ActorName 的规矩)
--     (2026-10-03)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1c Step 0 §a 的登记表与 Q3 · Q5 · Q9 · Q12 · Q13 · Q15 · Q16 · Q31 · Q32 · Q33,Tim 2026-10-03 全部照建议)
--   M   M7:一个临时主语(单行的 finance_settings + 一张没有外键的 period_closes,hop = 'all')—— 那张表的每一行与它的
--       每一行变更记录都在(今天已经不在的那一行也在,从记录里找回);/settings/change-history 的 Record 一栏把它归到那一行设置;
--       挂在一张【不是根表】的父表下的 'all' 什么都不展开
--   J   分录:建立(行 = 子行)· 审批关着时的人工分录申请生下来就批准(Q32:申请 INSERT 已是 approved + 一行 auto_approved)·
--       冲销(关键事件:根行翻 reversed + 冲销分录的建立,同一笔);★ Q33:冲销分录的行【不】在原分录的记录里;
--       冲销分录自己的页上:它的行在、原分录翻状态那一行也在。分录不可改(直连改 memo 按名拒)—— 没有"字段编辑"那一样
--   I   发票:开出(行 = 子行)· 作废申请 → 批准(关键事件)· 申请与审批留痕都在;发票不可改
--   C   贷项通知:由申请批准开出 —— 它的行、开出它的那张申请、它的分录;发票的记录里有这张贷项通知的建立
--   P   收付款 · 付款申请(Q13 · Q16 · Q31):出款申请(要结清一张费用)→ 批准 → 付款(一笔付款 + 一行核销);
--       冲销申请 → 批准 → 付款(镜像单)。原单的记录里:核销(子行)、翻 reversed 与镜像单的建立(同一个 op_key);
--       ★ Q16:原单与镜像单两条记录里,那一次冲销的行带着【同一个】op_key;建立那一次是另一个。
--       付款申请的记录里:审批留痕、付出的那一笔(往上一跳)、refs.allocations 把费用的 id 说成它的单号(Q13);
--       审批关着时的申请生下来就 approved,留痕 auto_approved(Q32)
--   E   费用:建立 · 附件(子行)· 核销;另一张冲销(关键事件,镜像单)。费用不可改(直连改备注按名拒)。
--       ★ Q12:费用的 employee_id —— 不持 module.hr.view 的财务读者读到 person.state = restricted;持的读到名字
--   B   应付(Q5,M3 · M6):收货 · 定价(price_history = 子行;unit_price = 字段编辑)· 注销(关键事件,另一批);
--       只持 module.finance.view 的读者【不被拒】(M3),根行那几次是 Restricted;根行的影像只有应付那几列(M6)
--   S   Q9:记录开始之前作废的发票 —— 那一戳是那件事唯一的记录,拼回来;付款申请的 paid、报销单的 decided 登记在册
--   Q15 冲销分录的来源:source_type 照抄、source_id 是原分录 —— 界面把来源换成原分录的(sourceLinkReversal.ts,
--       金句在 check-trail-wording ⑧);这里钉住它赖以成立的那个数据形状
--   每一条记录:一行只出现一次
-- 【整支是一笔事务】措辞(每一句英文)不在这里证 —— 它在 scripts/check-trail-wording.mjs 的 ⑧ 账上的单据那一臂。
-- 自带数据(README 第 2 条):账号、角色、员工、客户、供应商、物料、订单、批次全部本支自建;科目、币种是稳定的引导数据。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

-- ══ M7 的临时主语:必须在本会话第一次调 record_trail 之前装上(PL/pgSQL 的计划会缓存它解析到的那一支函数)══
ALTER FUNCTION public.trail_subjects() RENAME TO trail_subjects_f241;
ALTER FUNCTION public.trail_subject_members() RENAME TO trail_subject_members_f241;
CREATE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql IMMUTABLE AS $f$
    SELECT * FROM public.trail_subjects_f241()
    UNION ALL SELECT 'fx241_lock', ARRAY['module.finance.view'], 'finance_settings', 'id', 'table', ARRAY['locked_before']
$f$;
CREATE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql IMMUTABLE AS $f$
    SELECT * FROM public.trail_subject_members_f241()
    UNION ALL SELECT 'fx241_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true
    -- 一行挂在【不是根表】的父表下的 'all':什么都不该展开
    UNION ALL SELECT 'fx241_lock', 2, 'year_closes', 'journal_entries', NULL, '{}'::jsonb, 'all', true, false
$f$;

CREATE FUNCTION pg_temp.f241_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f241_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f241_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, p_n) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

CREATE FUNCTION pg_temp.f241_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 241 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

-- 这条记录里有没有这一种行:表 · 操作 ·(可选)改了这一列 ·(可选)新影像里包含这一段
CREATE FUNCTION pg_temp.f241_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT jsonb_typeof(p_trail) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                   WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                     AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
                     AND (p_new IS NULL OR e -> 'new' @> p_new))
$f$;

CREATE FUNCTION pg_temp.f241_need(p_arm text, p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF NOT pg_temp.f241_has(p_trail, p_table, p_op, p_col, p_new) THEN
        RAISE EXCEPTION 'FIXTURE 241 %: expected a % % row% in the trail, got %', p_arm, p_table, p_op,
            COALESCE(' changing ' || p_col, '') || COALESCE(' with ' || p_new::text, ''), p_trail;
    END IF;
END;
$f$;

-- 一行在一条记录里只出现一次
CREATE FUNCTION pg_temp.f241_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 持全部码:建单、提申请、付款(不是审批角色)
    u_sup  uuid := gen_random_uuid();   -- 建供应商的人(付款人不能是建户人,SOD)
    u_cfo  uuid := gen_random_uuid();   -- 二级审批角色(批申请)
    u_l1   uuid := gen_random_uuid();   -- 一级审批角色
    u_fin  uuid := gen_random_uuid();   -- 只有 module.finance.view + 价格码:不持 hr.view(Q12)、不持 inbound.view(M3)
    r_all uuid; r_l1 uuid; r_l2 uuid; r_fin uuid;
    e_emp uuid := gen_random_uuid();
    v_base text; v_acct text; v_began timestamptz := change_log_began_at(); t0 timestamptz;
    d date := CURRENT_DATE - 1;
    v_res jsonb; v_j jsonb; v_j2 jsonb; v_x text; v_n int; v_k text; v_k2 text;
    v_sup uuid; v_cust uuid; v_mat uuid; so1 uuid; so2 uuid; l1 uuid; l2 uuid;
    inv1 uuid; inv2 uuid; il2 uuid; v_cn uuid;
    je1 uuid; je1r uuid; jr uuid;
    ex0 uuid; ex1 uuid; ex2 uuid; ex2m uuid;
    pr0 uuid; pr1 uuid; pr2 uuid; p1 uuid; p1m uuid;
    b1 uuid; b2 uuid; jb uuid; jbr uuid;
    v_pc uuid; v_rec jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    IF v_base IS NULL OR v_acct IS NULL THEN RAISE EXCEPTION 'FIXTURE 241 布景失败:缺本位币或费用科目'; END IF;
    t0 := v_began - interval '10 days';

    -- ══════════════ 布景 ══════════════
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx241-all@test.local', now()), (u_sup, 'fx241-sup@test.local', now()), (u_cfo, 'fx241-cfo@test.local', now()),
        (u_l1, 'fx241-l1@test.local', now()), (u_fin, 'fx241-fin@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx241-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx241-l1', 'f', 'f', true) RETURNING id INTO r_l1;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx241-l2', 'f', 'f', true) RETURNING id INTO r_l2;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx241-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    -- 审批角色持每一个码(每条分档链的门都有人)—— 本支测的不是审批的门
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, code FROM permissions, unnest(ARRAY[r_all, r_l1, r_l2]) r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.view'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_sup, r_all), (u_cfo, r_l2), (u_l1, r_l1), (u_fin, r_fin);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date)
    VALUES (e_emp, 'FX241-E', 'FX241 Employee', 'Fixture Person', 'full_time', 'office', DATE '2020-01-01');
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx241-l1', approval_level2_role_code = 'fx241-l2', approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;

    PERFORM pg_temp.f241_as(u_sup);
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'FX241-SUP', 'FX241 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    PERFORM pg_temp.f241_as(u_all);
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ241-C1', 'fixture 241 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ241-M', 'f241 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    -- ══════════════ M · M7(先跑:临时主语已经装上)══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    INSERT INTO period_closes (period_end, closed_at, entries_count, total_debits, total_credits)
    VALUES (DATE '2025-01-31', now(), 0, 0, 0) RETURNING id INTO v_pc;
    INSERT INTO period_closes (period_end, closed_at, entries_count, total_debits, total_credits)
    VALUES (DATE '2025-02-28', now(), 0, 0, 0);
    -- 一行今天已经不在了(period_closes 不许删 —— CLOSE_IMMUTABLE;这里绕开触发器把它拿掉,只为造出"只在变更记录里"的那一行)
    SET LOCAL session_replication_role = replica;
    DELETE FROM period_closes WHERE period_end = DATE '2025-02-28';
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f241_ok('M', pg_temp.f241_trail(u_all, 'fx241_lock', 'true'));
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'period_closes' AND e ->> 'op' = 'INSERT';
    -- 两次 INSERT 都在:今天还在的那一行(按表找到)与今天已经不在的那一行(只在变更记录里 —— M7 的第二条路)
    IF v_n <> 2 THEN RAISE EXCEPTION 'FIXTURE 241 M: both period_closes inserts should reach the singleton''s trail (M7), got %: %', v_n, v_j; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'year_closes') THEN
        RAISE EXCEPTION 'FIXTURE 241 M: an ''all'' member under a parent that is not the root expanded anyway: %', v_j; END IF;
    v_rec := trail_row_record('period_closes', jsonb_build_object('id', v_pc), NULL, NULL);
    IF v_rec ->> 'table' <> 'finance_settings' THEN
        RAISE EXCEPTION 'FIXTURE 241 M: the summary page''s Record for a period close should be the settings row (M7 home), got %', v_rec; END IF;

    -- ══════════════ 审批关着的那一段:人工分录(Q32)· 一张自动批准的付款申请(Q32)· 批次的注销(Q5)══════════════
    PERFORM pg_temp.f241_as(u_all);
    v_res := submit_journal_request(d, 'fixture 241 accrual', jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 120, 'line_memo', 'f241 dr'),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 120, 'line_memo', 'f241 cr')));
    je1 := (v_res ->> 'entry_id')::uuid;
    jr := (v_res ->> 'request_id')::uuid;
    IF je1 IS NULL THEN RAISE EXCEPTION 'FIXTURE 241 布景:审批关着时人工分录应当当场过账,得到 %', v_res; END IF;

    ex0 := (record_expense(d, v_acct, 40, v_base, NULL, 'unpaid', NULL, v_sup) ->> 'expense_id')::uuid;
    pr0 := (submit_payment_request(v_sup, 40, v_base, NULL, NULL, d, 'auto', jsonb_build_array(jsonb_build_object('expense_id', ex0, 'amount_doc', 40))) ->> 'request_id')::uuid;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ241-IB1', v_mat, v_sup, 100, 100, 'kg', d, 'other', 'fixture 241') RETURNING id INTO b1;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ241-IB2', v_mat, v_sup, 50, 50, 'kg', d, 'other', 'fixture 241') RETURNING id INTO b2;
    PERFORM reprice_inbound_batch(b1, 2.5, v_base, NULL, 'fixture 241 final assay');
    PERFORM submit_inbound_write_off_request(b2, 'fixture 241 contaminated');
    INSERT INTO finance_attachments (inbound_batch_id, file_name, file_path, doc_type) VALUES (b1, 'grn-241.pdf', 'fx241/grn.pdf', 'receipt');

    -- ══════════════ 审批开着 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    PERFORM pg_temp.f241_as(u_all);

    -- 分录的冲销:申请 → CFO 批准(当场过账冲销分录)
    jr := (submit_journal_reversal_request(je1, d, 'fixture 241 wrong account') ->> 'request_id')::uuid;
    PERFORM pg_temp.f241_as(u_cfo);
    PERFORM decide_journal_request(jr, true, 'fine');
    PERFORM pg_temp.f241_as(u_all);
    SELECT reversed_by INTO je1r FROM journal_entries WHERE id = je1;
    IF je1r IS NULL THEN RAISE EXCEPTION 'FIXTURE 241 布景:批准之后原分录应当已被冲销'; END IF;

    -- 发票两张(作废一张,另一张开贷项通知)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d), v_cust, d, v_base, 1) RETURNING id INTO so1;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so1, 1, v_mat, 10, 10) RETURNING id INTO l1;
    PERFORM set_sales_order_status(so1, 'confirmed');
    inv1 := (create_order_invoice(so1, d, NULL, NULL, NULL, ARRAY[l1]) ->> 'invoice_id')::uuid;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate) VALUES (next_sales_order_code(d), v_cust, d, v_base, 1) RETURNING id INTO so2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price) VALUES (so2, 1, v_mat, 10, 10) RETURNING id INTO l2;
    PERFORM set_sales_order_status(so2, 'confirmed');
    inv2 := (create_order_invoice(so2, d, NULL, NULL, NULL, ARRAY[l2]) ->> 'invoice_id')::uuid;
    SELECT id INTO il2 FROM invoice_lines WHERE invoice_id = inv2;
    v_res := submit_invoice_void_request(inv1, 'fixture 241 wrong customer', d);
    PERFORM pg_temp.f241_as(u_cfo);
    PERFORM decide_invoice_request((v_res ->> 'request_id')::uuid, true, NULL);
    PERFORM pg_temp.f241_as(u_all);
    v_res := submit_credit_note_request(inv2, d, 'fixture 241 price adjustment',
        jsonb_build_array(jsonb_build_object('invoice_line_id', il2, 'kind', 'unshipped_cancel', 'amount', 20, 'qty', 2)));
    PERFORM pg_temp.f241_as(u_cfo);
    PERFORM decide_invoice_request((v_res ->> 'request_id')::uuid, true, NULL);
    PERFORM pg_temp.f241_as(u_all);
    SELECT id INTO v_cn FROM credit_notes WHERE invoice_id = inv2;
    IF v_cn IS NULL OR (SELECT status FROM invoices WHERE id = inv1) <> 'void' THEN RAISE EXCEPTION 'FIXTURE 241 布景:作废 / 贷项通知没有执行'; END IF;

    -- 费用:一张付掉(出款申请 → 批准 → 付款 → 冲销)、一张带员工(Q12)然后冲销
    ex1 := (record_expense(d, v_acct, 300, v_base, NULL, 'unpaid', NULL, v_sup) ->> 'expense_id')::uuid;
    INSERT INTO finance_attachments (expense_id, file_name, file_path, doc_type) VALUES (ex1, 'bill-241.pdf', 'fx241/bill.pdf', 'invoice');
    ex2 := (record_expense(p_expense_date := d, p_account_code := v_acct, p_amount := 80, p_currency := v_base,
                           p_payment_status := 'unpaid', p_employee_id := e_emp, p_notes := 'fixture 241 taxi') ->> 'expense_id')::uuid;
    ex2m := (reverse_expense(ex2, 'fixture 241 wrong account') ->> 'reversal_expense_id')::uuid;
    IF ex2m IS NULL THEN SELECT reversed_by_expense INTO ex2m FROM expenses WHERE id = ex2; END IF;

    pr1 := (submit_payment_request(v_sup, 300, v_base, NULL, NULL, d, 'fixture 241 pay the bill',
            jsonb_build_array(jsonb_build_object('expense_id', ex1, 'amount_doc', 300))) ->> 'request_id')::uuid;
    PERFORM pg_temp.f241_as(u_cfo);
    PERFORM decide_payment_request(pr1, true, NULL);
    PERFORM pg_temp.f241_as(u_all);
    PERFORM pay_payment_request(pr1, d, NULL);
    SELECT result_payment_id INTO p1 FROM payment_requests WHERE id = pr1;
    pr2 := (submit_payment_reversal_request(p1, 'fixture 241 paid twice') ->> 'request_id')::uuid;
    PERFORM pg_temp.f241_as(u_cfo);
    PERFORM decide_payment_request(pr2, true, NULL);
    PERFORM pg_temp.f241_as(u_all);
    PERFORM pay_payment_request(pr2, NULL, NULL);
    SELECT reversed_by_payment INTO p1m FROM payments WHERE id = p1;
    IF p1 IS NULL OR p1m IS NULL THEN RAISE EXCEPTION 'FIXTURE 241 布景:付款或它的冲销没有执行(p1 %, mirror %)', p1, p1m; END IF;

    -- ══════════════ J · 分录 ══════════════
    v_j := pg_temp.f241_ok('J', pg_temp.f241_trail(u_all, 'journal_entry', je1::text));
    PERFORM pg_temp.f241_need('J (child: the journal''s lines)', v_j, 'journal_lines', 'INSERT');
    -- Q32:审批关着时,申请在同一笔事务里建出来、当场翻成 approved(journal_request_submit_internal 先插 submitted 再改)
    PERFORM pg_temp.f241_need('J (Q32: the request raised)', v_j, 'journal_requests', 'INSERT');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) a, jsonb_array_elements(v_j) b
                    WHERE a ->> 'table_name' = 'journal_requests' AND a ->> 'op' = 'INSERT'
                      AND b ->> 'table_name' = 'journal_requests' AND b ->> 'op' = 'UPDATE' AND b -> 'new' ->> 'status' = 'approved'
                      AND a ->> 'op_key' = b ->> 'op_key') THEN
        RAISE EXCEPTION 'FIXTURE 241 J (Q32): the auto-approved request should be raised and approved in one operation: %', v_j; END IF;
    PERFORM pg_temp.f241_need('J (Q32: auto_approved trail)', v_j, 'approval_log', 'INSERT', NULL, '{"decision": "auto_approved"}');
    PERFORM pg_temp.f241_need('J (key event: reversed)', v_j, 'journal_entries', 'UPDATE', 'reversed_by');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'journal_entries' AND e -> 'row_key' ->> 'id' = je1r::text) THEN
        RAISE EXCEPTION 'FIXTURE 241 J: the reversal journal is not on the original''s trail: %', v_j; END IF;
    PERFORM pg_temp.f241_need('J (the reversal request and its decision)', v_j, 'journal_requests', 'UPDATE', 'status');
    -- ★ Q33:冲销分录的行不在原分录的记录里
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'journal_lines'
                  AND COALESCE(e -> 'new', e -> 'ctx') ->> 'entry_id' = je1r::text) THEN
        RAISE EXCEPTION 'FIXTURE 241 J (Q33): the reversal''s lines leaked onto the original''s trail: %', v_j; END IF;
    v_x := pg_temp.f241_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 241 J: shown twice: %', v_x; END IF;
    v_j2 := pg_temp.f241_ok('J (reversal page)', pg_temp.f241_trail(u_all, 'journal_entry', je1r::text));
    PERFORM pg_temp.f241_need('J (reversal page: its own lines)', v_j2, 'journal_lines', 'INSERT');
    PERFORM pg_temp.f241_need('J (reversal page: the original flipping)', v_j2, 'journal_entries', 'UPDATE', 'reversed_by');
    -- 分录不可改:没有"字段编辑"那一样(直连改摘要按名拒)
    BEGIN
        UPDATE journal_entries SET memo = 'x' WHERE id = je1;
        RAISE EXCEPTION 'FIXTURE 241 J: a posted journal''s memo could be edited directly';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FIXTURE 241%' THEN RAISE; END IF;
    END;

    -- ══════════════ I · 发票 ══════════════
    v_j := pg_temp.f241_ok('I', pg_temp.f241_trail(u_all, 'invoice', inv1::text));
    PERFORM pg_temp.f241_need('I (issued)', v_j, 'invoices', 'INSERT');
    PERFORM pg_temp.f241_need('I (child: its line)', v_j, 'invoice_lines', 'INSERT');
    PERFORM pg_temp.f241_need('I (key event: voided)', v_j, 'invoices', 'UPDATE', 'status', '{"status": "void"}');
    PERFORM pg_temp.f241_need('I (the void request)', v_j, 'invoice_requests', 'INSERT', NULL, '{"kind": "void"}');
    PERFORM pg_temp.f241_need('I (its approval)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "invoice_request", "decision": "approved"}');
    v_x := pg_temp.f241_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 241 I: shown twice: %', v_x; END IF;

    -- ══════════════ C · 贷项通知(与它挂在发票上的那一面)══════════════
    v_j := pg_temp.f241_ok('C', pg_temp.f241_trail(u_all, 'credit_note', v_cn::text));
    PERFORM pg_temp.f241_need('C (issued)', v_j, 'credit_notes', 'INSERT');
    PERFORM pg_temp.f241_need('C (child: its line)', v_j, 'credit_note_lines', 'INSERT');
    PERFORM pg_temp.f241_need('C (the request that issued it)', v_j, 'invoice_requests', 'INSERT', NULL, '{"kind": "credit_note"}');
    PERFORM pg_temp.f241_need('C (its journal)', v_j, 'journal_entries', 'INSERT');
    v_j := pg_temp.f241_ok('C (on the invoice)', pg_temp.f241_trail(u_all, 'invoice', inv2::text));
    PERFORM pg_temp.f241_need('C (the invoice shows the credit note it carries)', v_j, 'credit_notes', 'INSERT');

    -- ══════════════ P · 收付款 · 付款申请 ══════════════
    v_j := pg_temp.f241_ok('P', pg_temp.f241_trail(u_all, 'payment', p1::text));
    PERFORM pg_temp.f241_need('P (child: the allocation)', v_j, 'payment_allocations', 'INSERT');
    PERFORM pg_temp.f241_need('P (key event: reversed)', v_j, 'payments', 'UPDATE', 'reversed_by_payment');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'payments' AND e ->> 'op' = 'INSERT' AND e -> 'row_key' ->> 'id' = p1m::text) THEN
        RAISE EXCEPTION 'FIXTURE 241 P (Q31): the mirror''s creation is not on the original''s trail: %', v_j; END IF;
    PERFORM pg_temp.f241_need('P (the request that paid it)', v_j, 'payment_requests', 'UPDATE', 'status', '{"status": "paid"}');
    v_x := pg_temp.f241_twice(v_j); IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 241 P: shown twice: %', v_x; END IF;
    -- ★ Q16:原单与镜像单两条记录里,那一次冲销带着同一个 op_key;建立那一次是另一个
    SELECT e ->> 'op_key' INTO v_k FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'payments' AND e ->> 'op' = 'UPDATE' LIMIT 1;
    v_j2 := pg_temp.f241_ok('P (mirror)', pg_temp.f241_trail(u_all, 'payment', p1m::text));
    SELECT e ->> 'op_key' INTO v_k2 FROM jsonb_array_elements(v_j2) e WHERE e ->> 'table_name' = 'payments' AND e ->> 'op' = 'INSERT' AND e -> 'row_key' ->> 'id' = p1m::text;
    IF v_k IS NULL OR v_k IS DISTINCT FROM v_k2 OR v_k NOT LIKE 'L%' THEN
        RAISE EXCEPTION 'FIXTURE 241 P (Q16): one operation should carry one op_key on both records: % vs %', v_k, v_k2; END IF;
    -- 本支是一笔事务,所以这里每一行的 op_key 都一样 —— 能证的是它【是什么】:记录开始之后 = 'L' || 那一行的 txid
    --   (一次操作 = 一笔事务,Q2),不是这条记录里的条目号(那样两条记录的同一次操作就各是各的)
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e JOIN change_log c ON c.seq = (e ->> 'seq')::bigint
                WHERE e ->> 'op_key' IS DISTINCT FROM 'L' || c.txid) THEN
        RAISE EXCEPTION 'FIXTURE 241 P (Q16): op_key is not the row''s transaction: %', v_j; END IF;

    v_j := pg_temp.f241_ok('P (request)', pg_temp.f241_trail(u_all, 'payment_request', pr1::text));
    PERFORM pg_temp.f241_need('P (request: sent)', v_j, 'payment_requests', 'INSERT');
    PERFORM pg_temp.f241_need('P (request: approved)', v_j, 'approval_log', 'INSERT', NULL, '{"decision": "approved"}');
    PERFORM pg_temp.f241_need('P (request: paid)', v_j, 'payment_requests', 'UPDATE', 'status', '{"status": "paid"}');
    PERFORM pg_temp.f241_need('P (request: the payment it made)', v_j, 'payments', 'INSERT');
    -- ★ Q13:要结清的单据按单号说
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'payment_requests' AND e ->> 'op' = 'INSERT'
                      AND e -> 'refs' -> 'allocations' -> ex1::text ->> 'label' = (SELECT code FROM expenses WHERE id = ex1)) THEN
        RAISE EXCEPTION 'FIXTURE 241 P (Q13): the expense the request settles is not named by its code: %', v_j; END IF;
    v_j := pg_temp.f241_ok('P (auto request)', pg_temp.f241_trail(u_all, 'payment_request', pr0::text));
    PERFORM pg_temp.f241_need('P (Q32: born approved)', v_j, 'payment_requests', 'INSERT', NULL, '{"status": "approved"}');
    PERFORM pg_temp.f241_need('P (Q32: auto_approved)', v_j, 'approval_log', 'INSERT', NULL, '{"decision": "auto_approved"}');

    -- ══════════════ E · 费用(Q12)══════════════
    v_j := pg_temp.f241_ok('E', pg_temp.f241_trail(u_all, 'expense', ex1::text));
    PERFORM pg_temp.f241_need('E (recorded)', v_j, 'expenses', 'INSERT');
    PERFORM pg_temp.f241_need('E (child: the attachment)', v_j, 'finance_attachments', 'INSERT');
    -- 费用不可改(trg 守卫:建立之后只有冲销能动它)—— 没有"字段编辑"那一样
    BEGIN
        UPDATE expenses SET notes = 'x' WHERE id = ex1;
        RAISE EXCEPTION 'FIXTURE 241 E: a posted expense''s notes could be edited directly';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FIXTURE 241%' THEN RAISE; END IF;
    END;
    PERFORM pg_temp.f241_need('E (the allocation that paid it)', v_j, 'payment_allocations', 'INSERT');
    v_j := pg_temp.f241_ok('E (reversed)', pg_temp.f241_trail(u_all, 'expense', ex2::text));
    PERFORM pg_temp.f241_need('E (key event: reversed)', v_j, 'expenses', 'UPDATE', 'reversed_by_expense');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'expenses' AND e ->> 'op' = 'INSERT' AND e -> 'row_key' ->> 'id' = ex2m::text) THEN
        RAISE EXCEPTION 'FIXTURE 241 E (Q31): the mirror expense''s creation is missing: %', v_j; END IF;
    -- ★ Q12:引用里的员工名 —— 不持 hr.view 的财务读者读到 restricted;持的读到名字
    IF (SELECT e -> 'refs' -> 'employee_id' -> e_emp::text -> 'person' ->> 'state' FROM jsonb_array_elements(v_j) e
         WHERE e ->> 'table_name' = 'expenses' AND e -> 'row_key' ->> 'id' = ex2::text AND e ->> 'op' = 'INSERT') IS DISTINCT FROM 'person' THEN
        RAISE EXCEPTION 'FIXTURE 241 E (Q12): a reader with module.hr.view should see the employee''s name: %', v_j; END IF;
    v_j := pg_temp.f241_ok('E (Q12, finance-only reader)', pg_temp.f241_trail(u_fin, 'expense', ex2::text));
    v_x := (SELECT e -> 'refs' -> 'employee_id' -> e_emp::text -> 'person' ->> 'state' FROM jsonb_array_elements(v_j) e
             WHERE e ->> 'table_name' = 'expenses' AND e -> 'row_key' ->> 'id' = ex2::text AND e ->> 'op' = 'INSERT');
    IF v_x IS DISTINCT FROM 'restricted' THEN
        RAISE EXCEPTION 'FIXTURE 241 E (Q12): a reader without module.hr.view should see Restricted for the employee, got % in %', v_x, v_j; END IF;
    IF v_j::text LIKE '%Fixture Person%' OR v_j::text LIKE '%FX241 Employee%' THEN
        RAISE EXCEPTION 'FIXTURE 241 E (Q12): the employee''s name reached a reader without module.hr.view: %', v_j; END IF;

    -- ══════════════ B · 应付(Q5:M3 · M6)══════════════
    v_j := pg_temp.f241_ok('B', pg_temp.f241_trail(u_all, 'payable', b1::text));
    PERFORM pg_temp.f241_need('B (received)', v_j, 'inbound_batches', 'INSERT');
    PERFORM pg_temp.f241_need('B (child: price history)', v_j, 'price_history', 'INSERT');
    PERFORM pg_temp.f241_need('B (field edit: unit price)', v_j, 'inbound_batches', 'UPDATE', 'unit_price');
    PERFORM pg_temp.f241_need('B (child: the finance attachment)', v_j, 'finance_attachments', 'INSERT');
    -- M6:根行只有应付那几列
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e, jsonb_object_keys(COALESCE(e -> 'new', '{}'::jsonb)) k
                WHERE e ->> 'table_name' = 'inbound_batches'
                  AND k NOT IN ('supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                                'deleted_at', 'deleted_by', 'delete_reason')) THEN
        RAISE EXCEPTION 'FIXTURE 241 B (M6): a warehouse column of the batch reached the payable trail: %', v_j; END IF;
    v_j := pg_temp.f241_ok('B (written off)', pg_temp.f241_trail(u_all, 'payable', b2::text));
    PERFORM pg_temp.f241_need('B (key event: written off)', v_j, 'inbound_batches', 'UPDATE', 'deleted_at');
    -- M3:只持 finance.view 的读者不被拒;根行那几次是 Restricted(不是消失)
    v_j := pg_temp.f241_ok('B (M3, finance-only reader)', pg_temp.f241_trail(u_fin, 'payable', b1::text));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 241 B (M3): the batch''s own rows should read Restricted for a finance-only reader: %', v_j; END IF;
    IF pg_temp.f241_has(v_j, 'inbound_batches', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 241 B (M3): a finance-only reader saw the batch row itself: %', v_j; END IF;
    PERFORM pg_temp.f241_need('B (M3: the money rows stay visible)', v_j, 'finance_attachments', 'INSERT');

    -- ══════════════ Q15 · 冲销分录的来源是原分录(界面据此换成原分录的来源)══════════════
    SELECT id INTO jb FROM journal_entries WHERE source_id = b1 AND source_type = 'purchase' AND status = 'posted' ORDER BY created_at LIMIT 1;
    IF jb IS NULL THEN RAISE EXCEPTION 'FIXTURE 241 Q15 布景:定价没有过账一张 purchase 分录'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    jbr := (reverse_journal_entry_internal(jb, (SELECT entry_date FROM journal_entries WHERE id = jb), 'fixture 241 Q15') ->> 'reversal_id')::uuid;
    IF (SELECT row(source_type, source_id)::text FROM journal_entries WHERE id = jbr) IS DISTINCT FROM row('purchase', jb)::text THEN
        RAISE EXCEPTION 'FIXTURE 241 Q15: a reversal''s source should be (the original''s type, the original journal) — the shape sourceLinkReversal.ts relies on'; END IF;
    v_j := pg_temp.f241_ok('Q15 (payable)', pg_temp.f241_trail(u_all, 'payable', b1::text));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'journal_entries' AND e -> 'row_key' ->> 'id' = jbr::text) THEN
        RAISE EXCEPTION 'FIXTURE 241 Q15: the reversal of the batch''s purchase journal is not on the payable trail (one hop up through reversed_by): %', v_j; END IF;

    -- ══════════════ S · Q9:记录开始之前的那一戳是那件事唯一的记录 ══════════════
    SET LOCAL session_replication_role = replica;   -- 只为拼出"记录开始之前"的样子:不写变更记录、不跑触发器
    UPDATE invoices SET status = 'void', voided_at = t0, voided_by = u_all, void_reason = 'fixture 241 old void' WHERE id = inv2;
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f241_ok('S (invoice)', pg_temp.f241_trail(u_all, 'invoice', inv2::text));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'invoices' AND (e ->> 'prelog')::boolean
                      AND e -> 'changed_columns' ? 'voided_at' AND e -> 'new' ->> 'void_reason' = 'fixture 241 old void') THEN
        RAISE EXCEPTION 'FIXTURE 241 S (Q9): an invoice voided before the log should come back from its stamp: %', v_j; END IF;
    -- 付款申请的"付了"与报销单的"决定了"同样登记成戳(Q9)—— 一张早于记录的付款申请造不出来(它的形状检查要一笔真的付款),
    --   所以这里证登记本身在,拼法与上面那一臂同一条路
    IF NOT EXISTS (SELECT 1 FROM trail_prelog_sources() ps WHERE ps.table_name = 'payment_requests' AND ps.kind = 'stamp' AND ps.at_column = 'paid_at')
       OR NOT EXISTS (SELECT 1 FROM trail_prelog_sources() ps WHERE ps.table_name = 'expense_claims' AND ps.kind = 'stamp' AND ps.at_column = 'decided_at') THEN
        RAISE EXCEPTION 'FIXTURE 241 S (Q9): the paid / decided stamps are not registered'; END IF;
    v_j := pg_temp.f241_ok('S (invoice, op key)', pg_temp.f241_trail(u_all, 'invoice', inv2::text));
    -- Q16:拼回来的行没有事务 —— 它的 op_key 是那一刻('P' || 时刻),同一刻写下的归成一次操作
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean AND e ->> 'op_key' NOT LIKE 'P%') THEN
        RAISE EXCEPTION 'FIXTURE 241 S (Q16): a pre-log row''s op_key should be its moment: %', v_j; END IF;

    -- 门:一个码都不持的人按名拒(不是一张空表)
    v_j := pg_temp.f241_trail(gen_random_uuid(), 'payment', p1::text);
    IF jsonb_typeof(v_j) = 'array' OR v_j ->> 'error' NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 241: a reader with no codes should be refused by name, got %', v_j; END IF;

    RAISE NOTICE 'FIXTURE 241 全部通过:M(M7)· J(Q32 · Q33)· I · C · P(Q13 · Q16 · Q31 · Q32)· E(Q12)· B(M3 · M6)· Q15 · S(Q9)';
END;
$$;

ROLLBACK;

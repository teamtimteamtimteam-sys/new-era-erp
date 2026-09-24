-- db/scripts/2026-09-24-role1b2a-live-proof.sql
-- ROLE-1 · Batch 2a 的线上证明 —— 拒绝、读回,以及几次【整支回滚】的对照。
-- 整支一笔事务,最后 ROLLBACK:线上一行都不留(状态变动、留痕、申请、测试供应商、存储对象)。
--
-- 为什么不在 db/fixtures/:它要的是【线上真账号】在【线上真数据】上被拒 / 走得通。
-- fixture 216 在重建库上证同一批规矩的形状;这一支证的是"线上此刻,这几个人,真的是这样"。
-- 存储桶的策略【不在镜像里】(AGENTS.md),所以 company-assets 那两格只能在这里证。
--
-- 身份:以 postgres 连接(rolbypassrls = t),每一格用 set_config('request.jwt.claims') 换成那个
-- 真账号,并在 SET LOCAL ROLE authenticated 之下跑 —— RLS、列权限、函数 EXECUTE 按那个人判。
-- 读回也在那个人的身份下读(视图的谓词问的是"你是谁")。
-- 失败 = RAISE(退出码非零);成功 = 最后一行 NOTICE 'ROLE1B2A LIVE PROOF: n cells passed'。
--
-- 用到的线上数据(tim@ 读 ap_open_items 视图,2026-09-24 19:1x CST):
--   SUP-2026-0002 Acme(draft,created_by 空)· EXP-2026-0001 SGD 1.30 仍开着 → 本支付 1.00
--   SUP-2026-0095 Bosch(draft)· SUP-2026-0445 Ever Higher(draft,chooer@ 建)
--   CUS-2026-0003(限额 1,000,未冻结)
BEGIN;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no such account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $$;

-- 以 authenticated 跑一句 SQL,读回它的报错(没有报错 → NULL)。成功的那一句【留在事务里】,
-- 所以后面的格子看得见它(顺序即剧本);失败的那一句随它自己的子事务退掉。
CREATE FUNCTION pg_temp.try_sql(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        EXECUTE 'RESET ROLE';
        RETURN NULL;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        EXECUTE 'RESET ROLE';
        RETURN v_msg;
    END;
END $$;

CREATE FUNCTION pg_temp.run_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

CREATE FUNCTION pg_temp.count_as(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

-- 一格:谁、说什么、跑哪句、期望(NULL = 必须通过;否则 LIKE 模式)
CREATE FUNCTION pg_temp.cell(p_who text, p_label text, p_sql text, p_expect text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    PERFORM pg_temp.as_user(p_who);
    v_msg := pg_temp.try_sql(p_sql);
    IF p_expect IS NULL THEN
        IF v_msg IS NOT NULL THEN
            RAISE EXCEPTION 'PROOF_FAILED|% | % | expected success, got %', p_who, p_label, v_msg;
        END IF;
        RAISE NOTICE 'CELL ok  | % | % | passes', p_who, p_label;
    ELSE
        IF v_msg IS NULL OR v_msg NOT LIKE p_expect THEN
            RAISE EXCEPTION 'PROOF_FAILED|% | % | expected %, got %', p_who, p_label, p_expect, COALESCE(v_msg, '(passed)');
        END IF;
        RAISE NOTICE 'CELL ok  | % | % | %', p_who, p_label, v_msg;
    END IF;
END $$;

DO $proof$
DECLARE
    v_cells int := 0;
    v_acme uuid; v_bosch uuid; v_eh uuid; v_cus uuid; v_exp1 uuid; v_tim uuid; v_admin uuid;
    v_req uuid; v_self uuid; v_res jsonb; v_n bigint; v_je_before bigint; v_hist_before bigint;
    v_txt text;
BEGIN
    SELECT id INTO v_acme  FROM suppliers WHERE code = 'SUP-2026-0002';
    SELECT id INTO v_bosch FROM suppliers WHERE code = 'SUP-2026-0095';
    SELECT id INTO v_eh    FROM suppliers WHERE code = 'SUP-2026-0445';
    SELECT id INTO v_cus   FROM customers WHERE code = 'CUS-2026-0003';
    SELECT id INTO v_exp1  FROM expenses  WHERE code = 'EXP-2026-0001';
    SELECT id INTO v_tim   FROM auth.users WHERE email = 'tim@evoltrya.test';
    SELECT id INTO v_admin FROM auth.users WHERE email = 'admin@swm-os.test';
    SELECT count(*) INTO v_je_before FROM journal_entries;
    IF v_acme IS NULL OR v_bosch IS NULL OR v_eh IS NULL OR v_cus IS NULL OR v_exp1 IS NULL THEN
        RAISE EXCEPTION 'PROOF_SETUP|a named live row is missing';
    END IF;

    -- ══════════ S · 供应商:送审、批准、自批、主语钉死 ══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance submits Acme for review',
        format('SELECT set_supplier_status(%L::uuid, %L, %L)', v_acme, 'pending_review', 'B2a live proof'), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance cannot approve Acme',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_acme, 'approved'), 'PERMISSION_DENIED|action.supplier_approve'); v_cells := v_cells + 1;
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_n := pg_temp.count_as(format('SELECT count(*) FROM operations_now WHERE item_type = %L AND item_id = %L::uuid', 'supplier_pending_approval', v_acme));
    IF v_n <> 0 THEN RAISE EXCEPTION 'PROOF_FAILED|chooer@ should not see the supplier queue, got %', v_n; END IF;
    RAISE NOTICE 'READ ok  | chooer@evoltrya.test | operations_now supplier_pending_approval for Acme | 0 rows (does not hold action.supplier_approve)';
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    v_n := pg_temp.count_as(format('SELECT count(*) FROM operations_now WHERE item_type = %L AND item_id = %L::uuid', 'supplier_pending_approval', v_acme));
    IF v_n <> 1 THEN RAISE EXCEPTION 'PROOF_FAILED|tim@ should see Acme in the queue, got %', v_n; END IF;
    RAISE NOTICE 'READ ok  | tim@evoltrya.test | operations_now supplier_pending_approval for Acme | 1 row';
    v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO approves Acme (creator NULL → rule not applicable)',
        format('SELECT set_supplier_status(%L::uuid, %L, %L)', v_acme, 'approved', 'B2a live proof'), NULL); v_cells := v_cells + 1;
    IF (SELECT approved_by FROM suppliers WHERE id = v_acme) IS DISTINCT FROM v_tim
       OR (SELECT approved_at FROM suppliers WHERE id = v_acme) IS NULL THEN
        RAISE EXCEPTION 'PROOF_FAILED|Acme approval stamp not tim@';
    END IF;
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    v_n := pg_temp.count_as(format('SELECT count(*) FROM approval_log WHERE subject_type = %L AND subject_id = %L::uuid', 'supplier', v_acme));
    IF v_n <> 2 THEN RAISE EXCEPTION 'PROOF_FAILED|tim@ should read 2 supplier approval_log rows for Acme, got %', v_n; END IF;
    RAISE NOTICE 'READ ok  | tim@evoltrya.test | Acme approved_by = tim@, approval_log supplier rows = 2 (submitted, approved)';

    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance submits Ever Higher (created by chooer@)',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_eh, 'pending_review'), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO approves Ever Higher (creator is another person)',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_eh, 'approved'), NULL); v_cells := v_cells + 1;

    -- 一个人、两个账号:admin@ 建档并送审,tim@(同一个人 EMP-2026-0002)批 → 拒
    PERFORM pg_temp.as_user('admin@swm-os.test');
    v_res := pg_temp.run_json($q$WITH s AS (INSERT INTO suppliers (code, legal_name, country, counterparty_type)
                                VALUES ('ZZ-B2A-PROOF', 'ZZ B2a proof supplier', 'SG', 'service_vendor') RETURNING id, created_by)
                                SELECT to_jsonb(s) FROM s$q$);
    v_self := (v_res->>'id')::uuid;
    IF (v_res->>'created_by')::uuid IS DISTINCT FROM v_admin THEN
        RAISE EXCEPTION 'PROOF_FAILED|admin@ direct insert should stamp created_by = admin@, got %', v_res;
    END IF;
    RAISE NOTICE 'CELL ok  | admin@swm-os.test | direct insert of a draft supplier | passes, created_by = admin@';
    v_cells := v_cells + 1;
    PERFORM pg_temp.cell('admin@swm-os.test', 'admin@ submits it',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_self, 'pending_review'), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'same person, other account: tim@ approves admin@''s supplier',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_self, 'approved'), 'SELF_APPROVAL_FORBIDDEN|raiser'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'same person, other account: tim@ rejects admin@''s supplier',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_self, 'rejected'), 'SELF_APPROVAL_FORBIDDEN|raiser'); v_cells := v_cells + 1;
    -- ★ admin@ 的 cfo 授权【已撤销】(user_roles.revoked_at = 2026-09-23 15:00:48 CST,以 postgres 读基表)——
    --   Step 0 那条"admin@ 持 cfo"的读数没有过滤 revoked_at,是错的。admin 角色不拿新码(Tim),
    --   所以 admin@ 在这里先撞上的是权限,不是自批。
    PERFORM pg_temp.cell('admin@swm-os.test', 'admin@ (admin role only; its cfo grant is revoked) approves a supplier',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_self, 'approved'), 'PERMISSION_DENIED|action.supplier_approve'); v_cells := v_cells + 1;

    -- 主语钉死(直连写)
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct insert with a forged creator (tim@)',
        format($q$INSERT INTO suppliers (code, legal_name, country, counterparty_type, created_by)
                  VALUES ('ZZ-B2A-FORGED', 'x', 'SG', 'service_vendor', %L::uuid)$q$, v_tim), 'SUPPLIER_CREATED_BY_FORGED'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct insert of an active supplier',
        $q$INSERT INTO suppliers (code, legal_name, country, counterparty_type, status)
           VALUES ('ZZ-B2A-ACTIVE', 'x', 'SG', 'service_vendor', 'active')$q$, 'SUPPLIER_INSERT_MUST_BE_DRAFT|active'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct update of created_by on Ever Higher',
        format('UPDATE suppliers SET created_by = %L::uuid WHERE id = %L::uuid', v_tim, v_eh), 'SUPPLIER_CREATED_BY_IMMUTABLE'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct status update on Bosch',
        format('UPDATE suppliers SET status = %L WHERE id = %L::uuid', 'pending_review', v_bosch), 'SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse creates a draft supplier (Q5)',
        $q$INSERT INTO suppliers (code, legal_name, country, counterparty_type) VALUES ('ZZ-B2A-WH', 'x', 'SG', 'goods_supplier')$q$, NULL); v_cells := v_cells + 1;

    -- ══════════ P · 付款:提交、批准、付款三处都按名拒 ══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'payment request to Bosch (draft) — submit',
        format($q$SELECT submit_payment_request(%L::uuid, 1, 'SGD', NULL, NULL, CURRENT_DATE, 'proof', '[]'::jsonb, 'supplier')$q$, v_bosch),
        'PAYMENT_REQUEST_SUPPLIER_BLOCKED|SUP-2026-0095|draft'); v_cells := v_cells + 1;
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_res := pg_temp.run_json(format($q$SELECT submit_payment_request(%L::uuid, 1, 'SGD', NULL, NULL, CURRENT_DATE, 'B2a live proof', %L::jsonb, 'supplier')$q$,
                              v_acme, jsonb_build_array(jsonb_build_object('expense_id', v_exp1, 'amount_doc', 1))));
    v_req := (v_res->>'request_id')::uuid;
    IF v_req IS NULL THEN RAISE EXCEPTION 'PROOF_FAILED|submit to approved Acme returned %', v_res; END IF;
    RAISE NOTICE 'CELL ok  | chooer@evoltrya.test | payment request to Acme (now approved) — submit | passes, %', v_res->>'code';
    v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance suspends Acme (suppliers.edit)',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_acme, 'suspended'), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO approves the request while Acme is suspended',
        format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req), 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|SUP-2026-0002|suspended'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance reactivates Acme (suppliers.edit)',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_acme, 'active'), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO approves the request (Acme active)',
        format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance cannot blacklist Acme',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_acme, 'blacklisted'), 'PERMISSION_DENIED|action.supplier_approve'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO blacklists Acme',
        format('SELECT set_supplier_status(%L::uuid, %L, %L)', v_acme, 'blacklisted', 'B2a live proof'), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance pays the approved request (Acme blacklisted)',
        format('SELECT pay_payment_request(%L::uuid, CURRENT_DATE, NULL)', v_req), 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|SUP-2026-0002|blacklisted'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance cannot restore a blacklisted supplier',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_acme, 'archived'), 'PERMISSION_DENIED|action.supplier_approve'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO restores Acme (blacklisted → archived)',
        format('SELECT set_supplier_status(%L::uuid, %L)', v_acme, 'archived'), NULL); v_cells := v_cells + 1;
    SELECT count(*) INTO v_n FROM supplier_status_history WHERE supplier_id = v_acme;
    IF v_n <> 6 THEN RAISE EXCEPTION 'PROOF_FAILED|Acme should have 6 status-history rows, got %', v_n; END IF;
    RAISE NOTICE 'READ ok  | postgres (base table) | supplier_status_history for Acme | 6 rows (submit · approve · suspend · activate · blacklist · restore)';

    -- ══════════ O · 新采购单 ══════════
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco raises a PO to Bosch (draft) via create_purchase_order',
        format($q$SELECT create_purchase_order(%L::uuid, CURRENT_DATE, NULL, 'SGD', NULL, NULL, NULL, NULL, '[{"placeholder": true}]'::jsonb)$q$, v_bosch),
        'PO_SUPPLIER_NOT_APPROVED|SUP-2026-0095|draft'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco inserts a PO to Bosch directly (the RLS door)',
        format($q$INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
                  VALUES ('ZZ-B2A-PO1', %L::uuid, CURRENT_DATE, 'SGD', 1, 'draft', 'pending')$q$, v_bosch),
        'PO_SUPPLIER_NOT_APPROVED|SUP-2026-0095|draft'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'control: cco inserts a PO to SUP-2026-0003 (approved)',
        $q$INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
           VALUES ('ZZ-B2A-PO2', (SELECT id FROM suppliers WHERE code = 'SUP-2026-0003'), CURRENT_DATE, 'SGD', 1, 'draft', 'pending')$q$, NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'existing PO-2026-0007 (Bosch, draft) still editable',
        $q$UPDATE purchase_orders SET notes = notes WHERE code = 'PO-2026-0007'$q$, NULL); v_cells := v_cells + 1;

    -- ══════════ F · 财务设置 ══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance changes the GST registration number directly',
        $q$UPDATE finance_settings SET gst_registration_no = 'X' WHERE id$q$, 'FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|gst_registration_no'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance calls set_finance_settings',
        $q$SELECT set_finance_settings('{"gst_registration_no": "M90312345A"}'::jsonb)$q$, 'PERMISSION_DENIED|action.finance_settings'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'control: finance writes the period lock (same value)',
        $q$UPDATE finance_settings SET locked_before = locked_before WHERE id$q$, NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance edits the company profile',
        $q$UPDATE company_profile SET invoice_footer_text = invoice_footer_text WHERE id$q$, 'PERMISSION_DENIED|action.finance_settings'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance edits the chart of accounts',
        $q$UPDATE accounts SET notes = notes WHERE code = '2000'$q$, 'PERMISSION_DENIED|action.finance_settings'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance uploads to company-assets',
        $q$INSERT INTO storage.objects (bucket_id, name) VALUES ('company-assets', 'logo/zz-b2a-proof-finance.png')$q$, 'new row violates row-level security policy%'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO sets GST registration through set_finance_settings (same value)',
        $q$SELECT set_finance_settings('{"gst_registration_no": "M90312345A"}'::jsonb)$q$, NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO edits the company profile directly',
        $q$UPDATE company_profile SET invoice_footer_text = invoice_footer_text WHERE id$q$, NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO uploads to company-assets',
        $q$INSERT INTO storage.objects (bucket_id, name) VALUES ('company-assets', 'logo/zz-b2a-proof-cfo.png')$q$, NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO still cannot touch the lock through set_finance_settings',
        $q$SELECT set_finance_settings('{"locked_before": "2026-08-01"}'::jsonb)$q$, 'FINANCE_SETTINGS_KEY_NOT_HERE|locked_before'); v_cells := v_cells + 1;

    -- ══════════ C · 客户信用 ══════════
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco changes a credit limit directly',
        format('UPDATE customers SET credit_limit_base = 2000 WHERE id = %L::uuid', v_cus), 'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'control: cco saves the customer with credit unchanged',
        format('UPDATE customers SET notes = notes, credit_limit_base = credit_limit_base, credit_hold = credit_hold WHERE id = %L::uuid', v_cus), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance calls set_customer_credit',
        format('SELECT set_customer_credit(%L::uuid, 1500, false)', v_cus), 'PERMISSION_DENIED|action.customer_credit'); v_cells := v_cells + 1;
    SELECT count(*) INTO v_hist_before FROM customer_credit_history WHERE customer_id = v_cus;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'CFO sets CUS-2026-0003 to 1,500 / not on hold',
        format('SELECT set_customer_credit(%L::uuid, 1500, false)', v_cus), NULL); v_cells := v_cells + 1;
    SELECT count(*) INTO v_n FROM customer_credit_history WHERE customer_id = v_cus AND changed_by = v_tim AND new_credit_limit_base = 1500;
    IF v_n <> 1 OR (SELECT count(*) FROM customer_credit_history WHERE customer_id = v_cus) <> v_hist_before + 1 THEN
        RAISE EXCEPTION 'PROOF_FAILED|credit change should leave exactly one history row by tim@';
    END IF;
    RAISE NOTICE 'READ ok  | postgres (base table) | customer_credit_history for CUS-2026-0003 | +1 row, changed_by = tim@';

    -- ══════════ 收尾:分录一张没多(付款被拒;批准的试跑回滚)══════════
    IF (SELECT count(*) FROM journal_entries) <> v_je_before THEN
        RAISE EXCEPTION 'PROOF_FAILED|journal_entries moved inside the proof: % → %', v_je_before, (SELECT count(*) FROM journal_entries);
    END IF;
    RAISE NOTICE 'READ ok  | postgres (base table) | journal_entries inside the proof | % = before', v_je_before;

    RAISE NOTICE 'ROLE1B2A LIVE PROOF: % cells passed', v_cells;
END;
$proof$;

ROLLBACK;

-- 216 ROLE-1 · Batch 2a:财务设置、客户信用、供应商审批 —— 只归 CFO;未批准的供应商不付款、不开新单
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Tim 的 Batch 2 grilling Q5–Q11 + Batch 2a grilling Q1–Q8)
--   A  ★★ 供应商的主语钉死(直连写,SET LOCAL ROLE authenticated):
--        A1 直连 INSERT 一家 active → SUPPLIER_INSERT_MUST_BE_DRAFT|active
--        A2 直连 INSERT 伪造 created_by(写成 CFO)→ SUPPLIER_CREATED_BY_FORGED
--        A3 直连 INSERT draft → 成功,created_by = 自己
--        A4 改 created_by → SUPPLIER_CREATED_BY_IMMUTABLE —— 直连与【属主】两条路都拒
--        A5 直连改状态 → SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY
--   B  ★★ 送审与批准:建档员送审 → 成功(approval_log submitted · 变动史带附注);
--        建档员批准 → PERMISSION_DENIED|action.supplier_approve;CFO 的 operations_now 里有它、
--        建档员的没有;CFO 批准 → approved_by / approved_at 盖上,approval_log approved
--   C  ★★★ 自批按【人】认,跨两个账号:人甲用第二个账号(只持 suppliers.edit)建档并送审,
--        人甲的主账号(CFO)批准与驳回 → SELF_APPROVAL_FORBIDDEN|raiser(对照:B 臂批得动)
--   D  ★ 建档人为 NULL 的供应商(属主路径建的)不受那条规矩管:CFO 批得动(Tim,Q8)
--   E  ★★ 拉黑与恢复归 CFO:建档员拉黑 → 拒;CFO 拉黑 → 成功,变动史有行、approval_log 没有;
--        建档员把拉黑的归档 → 拒;CFO 归档 → 成功;建档员归档后回草稿 → 成功,批准戳清空(Q4)
--   F  ★★ 可付 = approved / active 且没被删:payee_check 对八种状态逐一问 + 已删;
--        一张给 draft 供应商的付款申请提交时按名拒;冲销那一种不查
--   G  ★★ 新采购单:create_purchase_order 给 draft 供应商 → PO_SUPPLIER_NOT_APPROVED|…|draft;
--        直连 INSERT(purchasing.edit 的 RLS 那扇门)→ 同一个拒绝;既有的单在供应商被暂停之后仍改得动
--   H  ★★ 财务设置:财务直连改 GST 登记号 → FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|gst_registration_no;
--        财务直连往前锁 → 成功(锁期仍归财务);财务调 set_finance_settings → PERMISSION_DENIED;
--        CFO 调 → 成功;锁期 / 审批列 / 不认识的键 → 各自按名拒;公司资料与科目表:财务直连写 →
--        PERMISSION_DENIED|action.finance_settings,CFO 直连写 → 成功
--   I  ★★ 客户信用:直连改限额 / 直连 INSERT 带冻结 → CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY;
--        原样写回 → 放行;财务调 set_customer_credit → PERMISSION_DENIED;CFO 调 → 成功且留痕;
--        批量导入的禁列里有两列
--   J  ★ 故障注入:摘掉 trg_suppliers_direct_write,A2 那一次伪造就写得进去 —— 守卫是承重的
--   K  ★ 跳转图:18 步,CFO 四类 5 步(与 ROLE-1 之前触发器体里那一份逐条相同)
--
-- 自带数据(README 第 2 条);锁期自己设(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_clerk  uuid := gen_random_uuid();   -- 建档员 + 财务:suppliers.edit · customers.edit · finance.edit · purchasing.edit
    u_cfo    uuid := gen_random_uuid();   -- 人甲的主账号:三个新码 + 读码
    u_cfo2   uuid := gen_random_uuid();   -- 人甲的第二个账号:只持 suppliers.edit(admin@ 的形状)
    r_clerk uuid; r_cfo uuid; r_edit uuid;
    e_a uuid := gen_random_uuid();        -- 人甲
    e_k uuid := gen_random_uuid();        -- 建档员这个人
    s_a uuid; s_self uuid; s_null uuid; s_act uuid; s_del uuid; s_j uuid;
    c_1 uuid;
    po_ok uuid;
    v_base text;
    v_n integer; v_msg text; v_denied boolean; v_uuid uuid; v_txt text; v_ts timestamptz;
    v_status text;
    rep jsonb := '{}'::jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════════════════ 布景 ══════════════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_clerk, now()), (u_cfo, now()), (u_cfo2, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx216-clerk','f','f',true) RETURNING id INTO r_clerk;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx216-cfo','f','f',true)   RETURNING id INTO r_cfo;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx216-edit','f','f',true)  RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_clerk, 'module.suppliers.edit'), (r_clerk, 'module.suppliers.view'),
        (r_clerk, 'module.customers.edit'), (r_clerk, 'module.customers.view'),
        (r_clerk, 'module.finance.edit'),   (r_clerk, 'module.finance.view'),
        (r_clerk, 'module.purchasing.edit'), (r_clerk, 'module.purchasing.view'),
        (r_clerk, 'data.view_prices'),
        (r_cfo, 'action.supplier_approve'), (r_cfo, 'action.finance_settings'), (r_cfo, 'action.customer_credit'),
        (r_cfo, 'module.suppliers.view'), (r_cfo, 'module.customers.view'), (r_cfo, 'module.finance.view'),
        (r_edit, 'module.suppliers.edit'), (r_edit, 'module.suppliers.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_clerk, r_clerk), (u_cfo, r_cfo), (u_cfo2, r_edit);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_a, 'FX216-A', 'Person A', 'full_time', 'office', DATE '2020-01-01', u_cfo),
        (e_k, 'FX216-K', 'Clerk K',  'full_time', 'office', DATE '2020-01-01', u_clerk);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_a);
    IF account_person(u_cfo2) IS DISTINCT FROM e_a OR account_person(u_cfo) IS DISTINCT FROM e_a THEN
        RAISE EXCEPTION 'FIXTURE 216 布景失败:人甲的两个账号没有答同一个人'; END IF;

    -- ══════════════ K · 跳转图 ══════════════
    IF (SELECT count(*) FROM supplier_status_moves()) <> 18
       OR (SELECT count(*) FROM supplier_status_moves() WHERE required_code = 'action.supplier_approve') <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 216K 失败:跳转图不是裁定的那一份'; END IF;

    -- ══════════════ A · 主语钉死(直连写)══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO suppliers (code, legal_name, country, counterparty_type, status)
        VALUES ('FX216-A1', 'a1', 'SG', 'goods_supplier', 'active');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SUPPLIER_INSERT_MUST_BE_DRAFT|active'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216A1 失败:直连生出一家 active,实得 %', COALESCE(v_msg, '(写进去了)'); END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO suppliers (code, legal_name, country, counterparty_type, created_by)
        VALUES ('FX216-A2', 'a2', 'SG', 'goods_supplier', u_cfo);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SUPPLIER_CREATED_BY_FORGED'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216A2 失败:伪造的建档人写得进去,实得 %', COALESCE(v_msg, '(写进去了)'); END IF;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX216-SA', 'Supplier A', 'SG', 'goods_supplier') RETURNING id, created_by INTO s_a, v_uuid;
    IF v_uuid IS DISTINCT FROM u_clerk THEN
        RAISE EXCEPTION 'FIXTURE 216A3 失败:直连建档的 created_by 应当是自己,实得 %', v_uuid; END IF;

    v_denied := false; v_msg := NULL;
    BEGIN UPDATE suppliers SET created_by = u_cfo WHERE id = s_a;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SUPPLIER_CREATED_BY_IMMUTABLE'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216A4 失败:直连改得动 created_by,实得 %', COALESCE(v_msg, '(改了)'); END IF;

    v_denied := false; v_msg := NULL;
    BEGIN UPDATE suppliers SET status = 'pending_review' WHERE id = s_a;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216A5 失败:直连改得动状态,实得 %', COALESCE(v_msg, '(改了)'); END IF;
    EXECUTE 'RESET ROLE';

    -- 属主路径也改不动 created_by(清成 NULL = 规矩不再适用,这正是那个洞)
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE suppliers SET created_by = NULL WHERE id = s_a;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SUPPLIER_CREATED_BY_IMMUTABLE'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216A4 失败:属主路径清得掉 created_by,实得 %', COALESCE(v_msg, '(清了)'); END IF;
    rep := rep || jsonb_build_object('A_subject_pinned', true);

    -- ══════════════ B · 送审与批准 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    PERFORM set_supplier_status(s_a, 'pending_review', 'fx216 please review');
    SELECT count(*) INTO v_n FROM approval_log WHERE subject_type = 'supplier' AND subject_id = s_a AND decision = 'submitted';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 216B1 失败:送审应当写一行 approval_log submitted,实得 %', v_n; END IF;
    SELECT note INTO v_txt FROM supplier_status_history
     WHERE supplier_id = s_a AND from_status = 'draft' AND to_status = 'pending_review';
    IF v_txt IS DISTINCT FROM 'fx216 please review' THEN
        RAISE EXCEPTION 'FIXTURE 216B1 失败:变动史应当带着附注,实得 %', v_txt; END IF;
    IF current_setting('evoltrya.supplier_status_note', true) <> '' THEN
        RAISE EXCEPTION 'FIXTURE 216B1 失败:附注设置项没有清掉'; END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_supplier_status(s_a, 'approved', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.supplier_approve'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216B2 失败:建档员批得动,实得 %', COALESCE(v_msg, '(批了)'); END IF;

    -- CFO 的队列里有它;建档员的没有(不持 action.supplier_approve)
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'supplier_pending_approval' AND item_id = s_a;
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 216B3 失败:建档员的 operations_now 里不该有待批供应商,实得 %', v_n; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'supplier_pending_approval' AND item_id = s_a;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 216B3 失败:CFO 的 operations_now 里应当有这一家,实得 %', v_n; END IF;

    PERFORM set_supplier_status(s_a, 'approved', 'fx216 ok');
    SELECT status::text, approved_by, approved_at INTO v_status, v_uuid, v_ts FROM suppliers WHERE id = s_a;
    IF v_status <> 'approved' OR v_uuid IS DISTINCT FROM u_cfo OR v_ts IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 216B4 失败:批准之后应当是 approved 且盖上 CFO 的戳,实得 % / % / %', v_status, v_uuid, v_ts; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type = 'supplier' AND subject_id = s_a AND decision = 'approved' AND actor_user_id = u_cfo
       AND subject_code = 'FX216-SA' AND amount_ccy IS NULL AND NOT self_decided;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 216B4 失败:批准应当写一行 approval_log approved,实得 %', v_n; END IF;
    -- 读策略那一支:CFO(持 suppliers.view)读得到;漏掉那一支就是"写得进、读不出"
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM approval_log WHERE subject_type = 'supplier' AND subject_id = s_a;
    EXECUTE 'RESET ROLE';
    IF v_n <> 2 THEN RAISE EXCEPTION 'FIXTURE 216B5 失败:CFO 应当读得到这一家的两行留痕,实得 %', v_n; END IF;
    rep := rep || jsonb_build_object('B_submit_and_approve', true);

    -- ══════════════ C · 自批按人认,跨两个账号 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo2), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX216-SELF', 'Self Supplier', 'SG', 'goods_supplier') RETURNING id INTO s_self;
    EXECUTE 'RESET ROLE';
    PERFORM set_supplier_status(s_self, 'pending_review', NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_supplier_status(s_self, 'approved', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 216C 失败:人甲用第二个账号建的供应商,人甲的主账号批得动,实得 %', COALESCE(v_msg, '(批了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_supplier_status(s_self, 'rejected', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 216C 失败:驳回自己建的也该拒,实得 %', COALESCE(v_msg, '(驳了)'); END IF;
    IF (SELECT status::text FROM suppliers WHERE id = s_self) <> 'pending_review' THEN
        RAISE EXCEPTION 'FIXTURE 216C 失败:被拒之后状态应当还是 pending_review'; END IF;
    rep := rep || jsonb_build_object('C_self_approval_by_person', true);

    -- ══════════════ D · 建档人为 NULL:规矩不适用 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    INSERT INTO suppliers (code, legal_name, country, counterparty_type, status)
    VALUES ('FX216-NULL', 'Null Creator', 'SG', 'goods_supplier', 'pending_review') RETURNING id, created_by INTO s_null, v_uuid;
    IF v_uuid IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 216D 布景失败:属主建的 created_by 应当为 NULL'; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM set_supplier_status(s_null, 'approved', NULL);
    rep := rep || jsonb_build_object('D_null_creator_approvable', true);

    -- ══════════════ E · 拉黑与恢复 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    PERFORM set_supplier_status(s_a, 'active', NULL);      -- 启用:suppliers.edit
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_supplier_status(s_a, 'blacklisted', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.supplier_approve'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216E 失败:建档员拉黑得动,实得 %', COALESCE(v_msg, '(拉黑了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM set_supplier_status(s_a, 'blacklisted', 'fx216 blacklist');
    SELECT count(*) INTO v_n FROM supplier_status_history
     WHERE supplier_id = s_a AND to_status = 'blacklisted' AND changed_by = u_cfo AND note = 'fx216 blacklist';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 216E 失败:拉黑应当进变动史,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM approval_log WHERE subject_type = 'supplier' AND subject_id = s_a;
    IF v_n <> 2 THEN RAISE EXCEPTION 'FIXTURE 216E 失败:拉黑不是一次审批,approval_log 应当仍是 2 行,实得 %', v_n; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_supplier_status(s_a, 'archived', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.supplier_approve'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216E 失败:建档员恢复得了拉黑的,实得 %', COALESCE(v_msg, '(恢复了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM set_supplier_status(s_a, 'archived', 'fx216 restore');
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    PERFORM set_supplier_status(s_a, 'draft', NULL);
    SELECT approved_by, approved_at INTO v_uuid, v_ts FROM suppliers WHERE id = s_a;
    IF v_uuid IS NOT NULL OR v_ts IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 216E 失败:回到草稿之后批准戳应当清空,实得 % / %', v_uuid, v_ts; END IF;
    SELECT count(*) INTO v_n FROM supplier_status_history WHERE supplier_id = s_a;
    IF v_n <> 6 THEN RAISE EXCEPTION 'FIXTURE 216E 失败:六步应当六行变动史,实得 %', v_n; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_supplier_status(s_a, 'approved', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'INVALID_STATUS_TRANSITION|draft|approved'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216E 失败:草稿不能一步到批准,实得 %', COALESCE(v_msg, '(过了)'); END IF;
    rep := rep || jsonb_build_object('E_blacklist_and_restore', true);

    -- ══════════════ F · 可付 = approved / active 且没被删 ══════════════
    -- 属主 INSERT 可以直接落任何状态(跳转触发器跳过 INSERT,直连守卫只管客户端),
    -- 所以八种状态各建一家,逐一问 payee_check。
    PERFORM set_config('request.jwt.claims', '', true);
    FOR v_status IN SELECT unnest(enum_range(NULL::supplier_status))::text LOOP
        INSERT INTO suppliers (code, legal_name, country, counterparty_type, status)
        VALUES ('FX216-F-' || v_status, 'F ' || v_status, 'SG', 'service_vendor', v_status::supplier_status)
        RETURNING id INTO v_uuid;
        v_denied := false; v_msg := NULL;
        BEGIN PERFORM payment_request_payee_check('payment_out', v_uuid);
        EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
        IF v_status IN ('approved', 'active') THEN
            IF v_denied THEN RAISE EXCEPTION 'FIXTURE 216F 失败:% 应当可付,实得 %', v_status, v_msg; END IF;
        ELSE
            IF NOT v_denied OR v_msg <> format('PAYMENT_REQUEST_SUPPLIER_BLOCKED|FX216-F-%s|%s', v_status, v_status) THEN
                RAISE EXCEPTION 'FIXTURE 216F 失败:% 应当按名拒,实得 %', v_status, COALESCE(v_msg, '(放行)'); END IF;
        END IF;
        -- 冲销不查(Q5 豁免)
        PERFORM payment_request_payee_check('payment_reversal', v_uuid);
    END LOOP;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type, status, deleted_at)
    VALUES ('FX216-F-DEL', 'F deleted', 'SG', 'service_vendor', 'active', now()) RETURNING id INTO s_del;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM payment_request_payee_check('payment_out', s_del);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|FX216-F-DEL|deleted'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216F 失败:已删的 active 供应商应当按名拒,实得 %', COALESCE(v_msg, '(放行)'); END IF;

    -- 走真门:给一家 draft 供应商提付款申请 → 提交时就拒
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_payment_request((SELECT id FROM suppliers WHERE code = 'FX216-F-draft'), 100, v_base,
                                         NULL, NULL, DATE '2030-03-01', 'fx216 F', '[]'::jsonb, 'supplier');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|FX216-F-draft|draft'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216F 失败:给 draft 供应商的付款申请提得进去,实得 %', COALESCE(v_msg, '(提了)'); END IF;
    rep := rep || jsonb_build_object('F_payable_means_approved_or_active', true);

    -- ══════════════ G · 新采购单 ══════════════
    v_denied := false; v_msg := NULL;
    -- 一条占位行:表头的 INSERT 先于任何一行被读,拒绝就落在表头上
    BEGIN PERFORM create_purchase_order((SELECT id FROM suppliers WHERE code = 'FX216-F-draft'), DATE '2030-03-01', NULL,
                                        v_base, NULL, NULL, NULL, NULL, '[{"placeholder": true}]'::jsonb);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PO_SUPPLIER_NOT_APPROVED|FX216-F-draft|draft'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216G 失败:给 draft 供应商开得出新采购单,实得 %', COALESCE(v_msg, '(开了)'); END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
        VALUES ('FX216-PO-X', (SELECT id FROM suppliers WHERE code = 'FX216-F-pending_review'), DATE '2030-03-01', v_base, 1, 'draft', 'draft');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PO_SUPPLIER_NOT_APPROVED|FX216-F-pending_review|pending_review'); END;
    EXECUTE 'RESET ROLE';
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216G 失败:直连 INSERT 那扇门绕得过去,实得 %', COALESCE(v_msg, '(开了)'); END IF;
    -- 对照:active 供应商开得出;之后供应商被暂停,这张既有的单照样改得动(Q7:既有采购单照常收货)
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX216-PO-OK', (SELECT id FROM suppliers WHERE code = 'FX216-F-active'), DATE '2030-03-01', v_base, 1, 'confirmed', 'approved')
    RETURNING id INTO po_ok;
    UPDATE suppliers SET status = 'suspended' WHERE code = 'FX216-F-active';
    UPDATE purchase_orders SET notes = 'fx216 still editable' WHERE id = po_ok;
    IF (SELECT notes FROM purchase_orders WHERE id = po_ok) IS DISTINCT FROM 'fx216 still editable' THEN
        RAISE EXCEPTION 'FIXTURE 216G 失败:供应商被暂停之后,既有采购单改不动了'; END IF;
    rep := rep || jsonb_build_object('G_new_po_needs_approved_supplier', true);

    -- ══════════════ H · 财务设置 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE finance_settings SET gst_registration_no = 'FX216-GST';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|gst_registration_no'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216H1 失败:财务直连改得动 GST 登记号,实得 %', COALESCE(v_msg, '(改了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE finance_settings SET fy_end_day = 30;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'FINANCE_SETTINGS_THROUGH_FUNCTION_ONLY|fy_end_day'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216H1 失败:财务直连改得动会计年度,实得 %', COALESCE(v_msg, '(改了)'); END IF;
    -- 对照:锁期仍归财务
    UPDATE finance_settings SET locked_before = DATE '2020-01-01';
    IF (SELECT locked_before FROM finance_settings) IS DISTINCT FROM DATE '2020-01-01' THEN
        RAISE EXCEPTION 'FIXTURE 216H2 失败:财务直连锁期应当照常'; END IF;
    -- 公司资料与科目表:写权换到 action.finance_settings
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE company_profile SET invoice_footer_text = 'fx216';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.finance_settings'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216H3 失败:财务直连改得动公司资料,实得 %', COALESCE(v_msg, '(改了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE accounts SET notes = 'fx216' WHERE code = '2000';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.finance_settings'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216H3 失败:财务直连改得动科目表,实得 %', COALESCE(v_msg, '(改了)'); END IF;
    EXECUTE 'RESET ROLE';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_finance_settings('{"fy_end_day": 31}'::jsonb);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.finance_settings'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216H4 失败:财务调得动 set_finance_settings,实得 %', COALESCE(v_msg, '(调了)'); END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM set_finance_settings('{"fy_end_month": 12, "fy_end_day": 31, "default_allocation_basis": "weight"}'::jsonb);
    IF (SELECT default_allocation_basis FROM finance_settings) <> 'weight'
       OR (SELECT updated_by FROM finance_settings) IS DISTINCT FROM u_cfo THEN
        RAISE EXCEPTION 'FIXTURE 216H5 失败:CFO 的 set_finance_settings 没有落地'; END IF;
    FOR v_txt, v_msg IN VALUES ('{"locked_before": "2020-01-01"}', 'FINANCE_SETTINGS_KEY_NOT_HERE|locked_before'),
                              ('{"approvals_enabled": false}', 'FINANCE_SETTINGS_KEY_NOT_HERE|approvals_enabled'),
                              ('{"nonsense": 1}', 'FINANCE_SETTINGS_KEY_UNKNOWN|nonsense'),
                              ('{}', 'FINANCE_SETTINGS_NOTHING_TO_CHANGE') LOOP
        v_denied := false;
        BEGIN PERFORM set_finance_settings(v_txt::jsonb);
        EXCEPTION WHEN OTHERS THEN v_denied := (SQLERRM = v_msg); END;
        IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216H6 失败:% 应当拒 %', v_txt, v_msg; END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM company_profile) THEN
        PERFORM set_config('request.jwt.claims', '', true);
        INSERT INTO company_profile (legal_name) VALUES ('FX216 Co');
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE company_profile SET invoice_footer_text = 'fx216 by cfo';
    UPDATE accounts SET notes = 'fx216 by cfo' WHERE code = '2000';
    EXECUTE 'RESET ROLE';
    IF (SELECT invoice_footer_text FROM company_profile LIMIT 1) IS DISTINCT FROM 'fx216 by cfo'
       OR (SELECT notes FROM accounts WHERE code = '2000') IS DISTINCT FROM 'fx216 by cfo' THEN
        RAISE EXCEPTION 'FIXTURE 216H7 失败:CFO 直连写公司资料 / 科目表应当落地'; END IF;
    rep := rep || jsonb_build_object('H_finance_settings_cfo_only', true);

    -- ══════════════ I · 客户信用 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO customers (code, legal_name, country) VALUES ('FX216-C1', 'C1', 'SG') RETURNING id INTO c_1;
    v_denied := false; v_msg := NULL;
    BEGIN INSERT INTO customers (code, legal_name, country, credit_hold) VALUES ('FX216-C2', 'C2', 'SG', true);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216I1 失败:直连 INSERT 带着冻结写得进去,实得 %', COALESCE(v_msg, '(写了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE customers SET credit_limit_base = 5000 WHERE id = c_1;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216I1 失败:直连改得动限额,实得 %', COALESCE(v_msg, '(改了)'); END IF;
    -- 原样写回 → 放行(编辑表单保存时两列没动)
    UPDATE customers SET notes = 'fx216', credit_limit_base = NULL, credit_hold = false WHERE id = c_1;
    EXECUTE 'RESET ROLE';
    IF (SELECT notes FROM customers WHERE id = c_1) IS DISTINCT FROM 'fx216' THEN
        RAISE EXCEPTION 'FIXTURE 216I2 失败:原样写回应当放行'; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM set_customer_credit(c_1, 1000, false);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|action.customer_credit'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216I3 失败:财务调得动 set_customer_credit,实得 %', COALESCE(v_msg, '(调了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM set_customer_credit(c_1, 1000, true);
    IF (SELECT credit_limit_base FROM customers WHERE id = c_1) IS DISTINCT FROM 1000
       OR NOT (SELECT credit_hold FROM customers WHERE id = c_1) THEN
        RAISE EXCEPTION 'FIXTURE 216I4 失败:CFO 的 set_customer_credit 没有落地'; END IF;
    SELECT count(*) INTO v_n FROM customer_credit_history
     WHERE customer_id = c_1 AND new_credit_limit_base = 1000 AND new_credit_hold AND changed_by = u_cfo;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 216I4 失败:信用变动应当留痕,实得 %', v_n; END IF;
    IF (set_customer_credit(c_1, 1000, true)->>'changed')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 216I5 失败:原样再设一次不该算一次变动'; END IF;
    v_denied := false;
    BEGIN PERFORM set_customer_credit(c_1, -1, false);
    EXCEPTION WHEN OTHERS THEN v_denied := (SQLERRM = 'CUSTOMER_CREDIT_LIMIT_INVALID|-1'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'FIXTURE 216I5 失败:负数限额应当按名拒'; END IF;
    IF NOT ('credit_limit_base' = ANY (master_import_forbidden_columns()))
       OR NOT ('credit_hold' = ANY (master_import_forbidden_columns()))
       OR NOT ('approved_by' = ANY (master_import_forbidden_columns())) THEN
        RAISE EXCEPTION 'FIXTURE 216I6 失败:批量导入的禁列里少了信用两列或批准戳'; END IF;
    rep := rep || jsonb_build_object('I_customer_credit_cfo_only', true);

    -- ══════════════ J · 故障注入:摘掉守卫,伪造就写得进去 ══════════════
    ALTER TABLE suppliers DISABLE TRIGGER trg_suppliers_direct_write;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_clerk), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO suppliers (code, legal_name, country, counterparty_type, created_by)
    VALUES ('FX216-J', 'J', 'SG', 'goods_supplier', u_cfo) RETURNING id INTO s_j;
    EXECUTE 'RESET ROLE';
    ALTER TABLE suppliers ENABLE TRIGGER trg_suppliers_direct_write;
    IF (SELECT created_by FROM suppliers WHERE id = s_j) IS DISTINCT FROM u_cfo THEN
        RAISE EXCEPTION 'FIXTURE 216J 失败:注入没有生效 —— 摘掉守卫之后伪造应当写得进去'; END IF;
    rep := rep || jsonb_build_object('J_guard_is_load_bearing', true);

    RAISE NOTICE 'FIXTURE 216 全部通过 %', rep::text;
END $$;
ROLLBACK;

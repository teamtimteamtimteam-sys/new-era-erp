-- 295 SYSTEM-MAP-2:待办上列着的 ⇔ 那一支真的决定函数接受 —— 24 种 × 七个线上角色(2026-10-27)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Tim 2026-10-27 Q7:"the full 24 types x 7 roles check runs as a gate fixture on a local rebuild with the
--   live role grants loaded: for each type and role, shown on the to-do list <=> the real decide function accepts it, every case
--   rolled back")
--   M  ★★ 矩阵:七个读者(admin · cco · cfo · cto · finance · gm · warehouse,码 = 线上那七个角色 2026-10-27 的快照,见下面
--        的 VALUES —— 量法 docs/surveys/SYSTEM-MAP-2/readings/live-survey.sql)× 24 种(23 种审批 + 已批准等付款)。每一格:
--        waiting_decisions() 里有没有这一张 ⇔ 以这个读者的身份调那一支【真的】决定函数接不接受(每一格在一个子块里调,
--        成功就 RAISE 一个哨兵把它回滚)。接受 = 哨兵,或那一种自己点名的"门之后"的错(下面 POSTGATE,逐种写明为什么);
--        拒绝 = 门上的错(PERMISSION_DENIED · APPROVAL_NOT_AUTHORISED · SELF_APPROVAL_FORBIDDEN · APPROVALS_NOT_ENABLED ·
--        SOD_PAYEE_AND_PAY);
--        别的任何错 = 本 fixture 自己的布景坏了(按名报,不读成拒绝)。
--   N  每一种至少有一个读者接受 —— 否则那一列的 ⇔ 是空转(一张谁都批不了的单据,两边都是"否")。
--   R  提单人自己:每一种带四眼的,提单人既不在待办上、决定函数也拒他(SELF_APPROVAL_FORBIDDEN)。
--   X  R2 的自批例外:一张主角是 CFO 本人的报销单,CFO 批得了、也列着;别人提给 finance 本人的那一张,finance 不列、也批不了。
--   S  盘点不在待办上(Tim Q4 a):一张 open 的盘点,对七个读者 waiting_decisions 都没有它。
--   O  提醒页的审批支与待办同一支:每个读者在 operations_now 里看见的审批支行,逐行对得上他的 waiting_decisions。
--   C  首页的数 = 待办的行数(waiting_for_me_count = count(waiting_for_me))。
--   B  批量(Tim C,只在本地重建上证):CFO 把待办上能批量的每一行逐项驳回(一次一项、同一句理由,lib/bulkRun.ts 的形状),
--        混进一张他自己提的 —— 只有那一项被拒、别的照做;之后那几行从待办上消失。采集草稿由 cto 驳回。
--   T  我的:finance 只看见自己那一张未完成的任务(不是它看得见的 team 任务);cco 要写的考核;gm 的自评;通知读过就消失。
--   ★ 故障注入(Q7):把一种的门放宽给批不了它的角色(decision_gate_code 的 medical_claim 改成 module.hr.view),本 fixture
--     必须按格点名变红 —— 读数在 docs/surveys/SYSTEM-MAP-2/readings/fixture-295-injection.txt。
--
-- 自带数据(README 第 2 条);审批策略、锁期自己设(README 第 4、5 条)。角色是本 fixture 自建的 fx295-*(README「权限:自建角色」),
-- 码逐字取自线上快照 —— 线上改了角色的码,这一支不会自己变;要再对一次,重跑上面那条查询并替换 VALUES。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f295_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 【门之后】的错:那一种的门已经过了,是布景没给到它要的后续数据。逐种写明;空 = 必须走到哨兵。
CREATE FUNCTION pg_temp.f295_postgate(p_type text) RETURNS text
LANGUAGE sql AS $f$
    SELECT CASE p_type
        -- release_blending_plan:门(require_permission action.wo_release)与四眼在前,之后才问计划有没有目标与配料行 ——
        --   本 fixture 不造配料(那要一整套产出物料与成分),所以过了门的人停在 BLEND_PLAN_NO_TARGETS。
        WHEN 'blending_plan' THEN '^(BLEND_PLAN_NO_TARGETS|BLEND_NO_LINES)'
        ELSE '^F295_NEVER$'
    END
$f$;

DO $$
DECLARE
    v_roles text[] := ARRAY['admin', 'cco', 'cfo', 'cto', 'finance', 'gm', 'warehouse'];
    r text; t text; v_uid uuid; v_rid uuid; v_eid uuid;
    u   jsonb := '{}'::jsonb;    -- role → user id
    emp jsonb := '{}'::jsonb;    -- role → employee id
    u_raise uuid := gen_random_uuid();  e_raise uuid := gen_random_uuid();
    e_subj  uuid := gen_random_uuid();
    v_ccy text; d date := CURRENT_DATE;
    v_sup uuid; v_mat uuid; v_cust uuid; v_ib uuid; v_inv uuid; v_so uuid; v_pp uuid; v_asset uuid; v_gst uuid;
    v_formula uuid; v_contact uuid; u_portal uuid := gen_random_uuid(); v_portal_link uuid; v_inbox bigint;
    v_sup_pending uuid;
    docs jsonb := '[]'::jsonb;   -- [{type, id, sql, postgate}]
    doc jsonb; v_id uuid; v_sql text; v_msg text; v_listed boolean; v_accepted boolean; v_fail text := '';
    v_n int; v_cells int := 0; v_any jsonb := '{}'::jsonb;
    c_fx_self uuid; c_fin_self uuid; v_st uuid; v_cycle uuid; v_loc uuid; v_ntf uuid; v_cnt int; v_rows int; v_ops text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 七个线上角色的码(快照 2026-10-27,线上 postgres 读 role_permissions)══════════════
    FOR r, t IN SELECT x.role, array_to_string(x.codes, ',') FROM (VALUES
        ('admin', ARRAY['action.anonymise_employee', 'action.apply_assay', 'action.approve_review', 'action.batch_write_off', 'action.bulk_import', 'action.compliance_pack', 'action.confirm_capture', 'action.contract_terms', 'action.customer_credit', 'action.decide_hr_requests', 'action.direct_sale', 'action.finance_reopen', 'action.finance_settings', 'action.hr_reviews', 'action.issue_coa', 'action.issue_cod', 'action.manage_devices', 'action.manage_permissions', 'action.manage_portal_users', 'action.metal_prices', 'action.ncr_decide', 'action.overtime_approve', 'action.overtime_enter', 'action.price_receipts', 'action.processing_aftercare', 'action.processing_commit', 'action.processing_rollback', 'action.raise_po_consumables', 'action.raise_po_equipment', 'action.raise_po_office', 'action.receive_goods', 'action.request_shipping_release', 'action.ship_goods', 'action.stocktake_count', 'action.stocktake_post', 'action.supplier_approve', 'action.supplier_review', 'action.wo_create', 'action.wo_release', 'data.view_banking', 'data.view_change_log', 'data.view_deleted', 'data.view_floor_board', 'data.view_health', 'data.view_identity', 'data.view_pay', 'data.view_prices', 'data.view_purchase_prices', 'data.view_reviews', 'data.view_sales', 'data.view_self_approvals', 'module.compliance.view', 'module.customers.edit', 'module.customers.view', 'module.finance.edit', 'module.finance.view', 'module.hr.edit', 'module.hr.view', 'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit', 'module.inventory.view', 'module.logistics.view', 'module.materials.edit', 'module.materials.view', 'module.output.edit', 'module.output.view', 'module.pricing.edit', 'module.pricing.view', 'module.processing.edit', 'module.processing.view', 'module.purchasing.edit', 'module.purchasing.view', 'module.quality.edit', 'module.quality.view', 'module.safety.edit', 'module.safety.view', 'module.sales.edit', 'module.sales.view', 'module.stocktakes.edit', 'module.stocktakes.view', 'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit', 'module.tasks.view', 'module.tasks.view_all']::text[]),
        ('cco', ARRAY['action.contract_terms', 'action.decide_hr_requests', 'action.direct_sale', 'action.hr_reviews', 'action.issue_coa', 'action.manage_portal_users', 'action.ncr_decide', 'action.raise_po_equipment', 'action.request_shipping_release', 'action.supplier_review', 'data.view_banking', 'data.view_deleted', 'data.view_health', 'data.view_pay', 'data.view_prices', 'data.view_purchase_prices', 'data.view_reviews', 'data.view_sales', 'module.compliance.view', 'module.customers.edit', 'module.customers.view', 'module.finance.view', 'module.hr.edit', 'module.hr.view', 'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit', 'module.inventory.view', 'module.logistics.view', 'module.materials.edit', 'module.materials.view', 'module.output.edit', 'module.output.view', 'module.pricing.edit', 'module.pricing.view', 'module.processing.edit', 'module.processing.view', 'module.purchasing.edit', 'module.purchasing.view', 'module.quality.edit', 'module.quality.view', 'module.safety.view', 'module.sales.edit', 'module.sales.view', 'module.stocktakes.edit', 'module.stocktakes.view', 'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit', 'module.tasks.view']::text[]),
        ('cfo', ARRAY['action.approve_review', 'action.customer_credit', 'action.decide_hr_requests', 'action.finance_reopen', 'action.finance_settings', 'action.supplier_approve', 'data.view_banking', 'data.view_change_log', 'data.view_deleted', 'data.view_floor_board', 'data.view_health', 'data.view_identity', 'data.view_pay', 'data.view_prices', 'data.view_purchase_prices', 'data.view_reviews', 'data.view_sales', 'data.view_self_approvals', 'module.compliance.view', 'module.customers.view', 'module.finance.view', 'module.hr.view', 'module.inbound.view', 'module.inventory.view', 'module.logistics.view', 'module.materials.view', 'module.output.view', 'module.pricing.view', 'module.processing.view', 'module.purchasing.view', 'module.quality.view', 'module.safety.view', 'module.sales.view', 'module.stocktakes.view', 'module.suppliers.view', 'module.tasks.view']::text[]),
        ('cto', ARRAY['action.apply_assay', 'action.compliance_pack', 'action.confirm_capture', 'action.manage_devices', 'action.ncr_decide', 'data.view_banking', 'data.view_deleted', 'data.view_prices', 'data.view_purchase_prices', 'data.view_reviews', 'data.view_sales', 'module.compliance.view', 'module.customers.edit', 'module.customers.view', 'module.finance.view', 'module.hr.view', 'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit', 'module.inventory.view', 'module.logistics.view', 'module.materials.edit', 'module.materials.view', 'module.output.edit', 'module.output.view', 'module.pricing.view', 'module.processing.edit', 'module.processing.view', 'module.purchasing.edit', 'module.purchasing.view', 'module.quality.edit', 'module.quality.view', 'module.safety.edit', 'module.safety.view', 'module.sales.view', 'module.stocktakes.edit', 'module.stocktakes.view', 'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit', 'module.tasks.view']::text[]),
        ('finance', ARRAY['action.decide_hr_requests', 'action.metal_prices', 'action.overtime_enter', 'action.price_receipts', 'action.raise_po_office', 'action.stocktake_post', 'action.wo_release', 'data.view_banking', 'data.view_deleted', 'data.view_health', 'data.view_identity', 'data.view_pay', 'data.view_prices', 'data.view_purchase_prices', 'data.view_sales', 'module.customers.edit', 'module.customers.view', 'module.finance.edit', 'module.finance.view', 'module.hr.edit', 'module.hr.view', 'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit', 'module.inventory.view', 'module.logistics.view', 'module.materials.edit', 'module.materials.view', 'module.output.edit', 'module.output.view', 'module.pricing.view', 'module.processing.view', 'module.purchasing.edit', 'module.purchasing.view', 'module.quality.view', 'module.safety.view', 'module.sales.view', 'module.stocktakes.edit', 'module.stocktakes.view', 'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit', 'module.tasks.view']::text[]),
        ('gm', ARRAY['data.view_banking', 'data.view_prices', 'data.view_purchase_prices', 'data.view_reviews', 'data.view_sales', 'data.view_self_approvals', 'module.compliance.view', 'module.customers.view', 'module.finance.view', 'module.hr.view', 'module.inbound.view', 'module.inventory.view', 'module.logistics.view', 'module.materials.view', 'module.output.view', 'module.pricing.view', 'module.processing.view', 'module.purchasing.view', 'module.safety.view', 'module.sales.view', 'module.stocktakes.view', 'module.suppliers.view', 'module.tasks.view']::text[]),
        ('warehouse', ARRAY['action.batch_write_off', 'action.confirm_capture', 'action.issue_cod', 'action.overtime_approve', 'action.processing_aftercare', 'action.processing_commit', 'action.processing_rollback', 'action.raise_po_consumables', 'action.receive_goods', 'action.ship_goods', 'action.stocktake_count', 'action.wo_create', 'data.view_purchase_prices', 'module.inbound.edit', 'module.inbound.view', 'module.inventory.edit', 'module.inventory.view', 'module.logistics.view', 'module.output.edit', 'module.output.view', 'module.processing.view', 'module.purchasing.view', 'module.quality.view', 'module.safety.edit', 'module.safety.view', 'module.stocktakes.edit', 'module.stocktakes.view', 'module.suppliers.edit', 'module.suppliers.view', 'module.tasks.edit', 'module.tasks.view']::text[])
    ) x(role, codes) LOOP
        INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx295-' || r, 'fx295 ' || r, 'fx295 ' || r, true) RETURNING id INTO v_rid;
        INSERT INTO role_permissions (role_id, permission_code) SELECT v_rid, c FROM unnest(string_to_array(t, ',')) c;
        v_uid := gen_random_uuid(); v_eid := gen_random_uuid();
        INSERT INTO auth.users (id, email_confirmed_at) VALUES (v_uid, now());
        INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_rid);
        INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES (v_eid, 'FX295-' || upper(r), 'FX295 ' || r, 'full_time', 'office', d - 400, v_uid);
        u := u || jsonb_build_object(r, v_uid); emp := emp || jsonb_build_object(r, v_eid);
    END LOOP;
    -- 提单人(不持任何角色)与一位主角员工(没有账号)
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_raise, now());
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_raise, 'FX295-RAISE', 'FX295 Raiser', 'full_time', 'office', d - 400, u_raise),
        (e_subj,  'FX295-SUBJ',  'FX295 Subject', 'full_time', 'shopfloor', d - 400, NULL);

    -- 策略:一级 fx295-finance、二级 fx295-cfo、门槛 1,000;审批打开(线上的形状)
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx295-finance', approval_level2_role_code = 'fx295-cfo',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ 布景:每一种一张在等的单据,提单人 = u_raise ══════════════
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, created_by)
        VALUES ('active', 'ZZFX295-SUP', 'ZZ FX295 Supplier', 'SG', 'goods_supplier', u_raise) RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed) VALUES ('ZZFX295-M', 'ZZ FX295 material', 'consumable', false) RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZFX295-C', 'ZZ FX295 Customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date, unit_price, source_reason_code, source_reason_note)
        VALUES ('ZZFX295-IB', v_mat, v_sup, 100, 100, d - 10, 10, 'other', 'fixture 295 自带数据') RETURNING id INTO v_ib;
    INSERT INTO invoices (code, customer_id, issue_date, due_date, payment_terms_days, currency, subtotal_base, total_base, bill_to_snapshot, status)
        VALUES ('ZZFX295-INV', v_cust, d - 5, d + 25, 30, v_ccy, 100, 100, jsonb_build_object('name', 'fixture 295'), 'issued') RETURNING id INTO v_inv;
    INSERT INTO sales_orders (code, customer_id, order_date, status, currency, fx_rate)
        VALUES ('ZZFX295-SO', v_cust, d - 5, 'confirmed', v_ccy, 1) RETURNING id INTO v_so;
    INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate, status)
        VALUES ('ZZFX295-PR', date_trunc('month', d)::date, d + 5, v_ccy, 1, 'draft') RETURNING id INTO v_pp;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base, depreciation_account_code, status)
        VALUES ('ZZFX295-FA', 'fixture 295 asset', 'equipment', d - 400, 1000, v_ccy, 1, 1000, 120, 0, '6000', 'active') RETURNING id INTO v_asset;
    INSERT INTO gst_periods (code, period_start, period_end, status) VALUES ('ZZFX295-GST', d - 90, d - 1, 'open') RETURNING id INTO v_gst;
    INSERT INTO pricing_formulas (code, name) VALUES ('ZZFX295-F', 'fixture 295 formula') RETURNING id INTO v_formula;

    -- 采购单(< 1,000 → 一级:finance 与 cfo 都有资格)
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, estimated_total_ccy, category, status, approval_status, created_by)
        VALUES ('ZZFX295-PO', v_sup, d - 3, v_ccy, 1, 500, 'consumables', 'draft', 'pending', u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'purchase_order', 'id', v_id, 'sql', format('SELECT approve_purchase_order(%L)', v_id));
    -- 报销(< 1,000)与一张大额(≥ 1,000 → 只有二级)
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description, created_by)
        VALUES ('ZZFX295-CLM', e_subj, d - 3, 120, v_ccy, 'fixture 295 claim', u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'expense_claim', 'id', v_id, 'sql', format('SELECT decide_expense_claim_items(%L, false, NULL, NULL, %L)', v_id, 'fx295'));
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description, created_by)
        VALUES ('ZZFX295-CLM2', e_subj, d - 3, 4000, v_ccy, 'fixture 295 big claim', u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'expense_claim', 'id', v_id, 'sql', format('SELECT decide_expense_claim_items(%L, false, NULL, NULL, %L)', v_id, 'fx295'));
    -- 十种 CFO 级申请
    INSERT INTO payment_requests (code, kind, counterparty_type, supplier_id, planned_date, amount_ccy, currency, amount_base, created_by)
        VALUES ('ZZFX295-PRQ', 'payment_out', 'supplier', v_sup, d + 3, 300, v_ccy, 300, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'payment_request', 'id', v_id, 'sql', format('SELECT decide_payment_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO payroll_requests (payroll_period_id, kind, label, snapshot, currency, fx_rate, gross_total, amount_base, created_by)
        VALUES (v_pp, 'post', 'ZZFX295-PAY', '{}'::jsonb, v_ccy, 1, 1000, 1000, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'payroll_request', 'id', v_id, 'sql', format('SELECT decide_payroll_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO receipt_price_requests (inbound_batch_id, source, label, unit_price_ccy, currency, snapshot, amount_base, created_by)
        VALUES (v_ib, 'manual', 'ZZFX295-RPR', 12, v_ccy, '{}'::jsonb, 200, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'receipt_price_request', 'id', v_id, 'sql', format('SELECT decide_receipt_price_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO invoice_requests (invoice_id, kind, label, reason, amount_base, created_by)
        VALUES (v_inv, 'void', 'ZZFX295-IRQ', 'fixture 295', 100, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'invoice_request', 'id', v_id, 'sql', format('SELECT decide_invoice_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO shipping_releases (sales_order_id, label, amount_base, created_by)
        VALUES (v_so, 'ZZFX295-SR', 100, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'shipping_release', 'id', v_id, 'sql', format('SELECT decide_shipping_release(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO journal_requests (kind, label, entry_date, memo, lines, amount_base, created_by)
        VALUES ('entry', 'ZZFX295-JR', d, 'fixture 295', '[]'::jsonb, 50, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'journal_request', 'id', v_id, 'sql', format('SELECT decide_journal_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO warehouse_requests (kind, label, reason, snapshot, amount_base, inbound_batch_id, created_by)
        VALUES ('write_off_inbound', 'ZZFX295-WR', 'fixture 295', '{}'::jsonb, 10, v_ib, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'warehouse_request', 'id', v_id, 'sql', format('SELECT decide_warehouse_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO terms_requests (kind, label, reason, snapshot, fingerprint, formula_id, proposed, created_by)
        VALUES ('formula_change', 'ZZFX295-TR', 'fixture 295', '{}'::jsonb, 'fx295', v_formula, '{}'::jsonb, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'terms_request', 'id', v_id, 'sql', format('SELECT decide_terms_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO asset_disposal_requests (label, asset_id, proceeds_base, reason, snapshot, estimate, amount_base, created_by)
        VALUES ('ZZFX295-ADR', v_asset, 0, 'fixture 295', '{}'::jsonb, '{}'::jsonb, 1000, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'asset_disposal_request', 'id', v_id, 'sql', format('SELECT decide_asset_disposal_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO gst_filing_requests (label, period_id, boxes, created_by)
        VALUES ('ZZFX295-GFR', v_gst, '[]'::jsonb, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'gst_filing_request', 'id', v_id, 'sql', format('SELECT decide_gst_filing_request(%L, false, %L)', v_id, 'fx295'));
    -- 调薪(主角 e_subj,与 CFO 无关 → action.approve_review 那一码)
    INSERT INTO salary_change_requests (label, employee_id, old_monthly_salary, new_monthly_salary, effective_date, reason, snapshot, created_by)
        VALUES ('ZZFX295-SCR', e_subj, 3000, 3200, d + 30, 'fixture 295', '{}'::jsonb, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'salary_change_request', 'id', v_id, 'sql', format('SELECT decide_salary_change_request(%L, false, %L)', v_id, 'fx295'));
    -- 加班(一行,员工 e_subj)
    INSERT INTO overtime_batches (label, period_month, seq, status, submitted_at, submitted_by, created_by)
        VALUES ('ZZFX295-OT', date_trunc('month', d)::date, 1, 'submitted', now(), u_raise, u_raise) RETURNING id INTO v_id;
    INSERT INTO overtime_lines (batch_id, employee_id, work_date, hours, day_kind) VALUES (v_id, e_subj, d - 2, 2, 'weekday');
    docs := docs || jsonb_build_object('type', 'overtime_batch', 'id', v_id, 'sql', format('SELECT decide_overtime_batch(%L, %L, %L)', v_id, 'rejected', 'fx295'));
    -- 考核批准(annual,提交人 u_raise,员工 e_subj)
    INSERT INTO review_cycles (name, period_start, period_end, due_date, status) VALUES ('ZZFX295 cycle', d - 365, d - 1, d + 30, 'open') RETURNING id INTO v_cycle;
    INSERT INTO performance_reviews (cycle_id, employee_id, review_type, period_start, period_end, reviewer_employee_id, status, rating_code, summary_text, submitted_at, submitted_by, created_by)
        VALUES (v_cycle, e_subj, 'annual', d - 365, d - 1, e_raise, 'submitted', (SELECT code FROM review_rating_scale ORDER BY 1 LIMIT 1), 'fixture 295', now(), u_raise, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'performance_review', 'id', v_id, 'sql', format('SELECT approve_review(%L)', v_id));
    -- 请假 · 医疗
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days, status, created_by)
        VALUES ('ZZFX295-LV', e_subj, 'unpaid', d + 10, d + 10, 1, 'pending', u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'leave_request', 'id', v_id, 'sql', format('SELECT decide_leave_request(%L, false, %L)', v_id, 'fx295'));
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd, status, created_by)
        VALUES ('ZZFX295-MC', e_subj, d - 2, extract(year FROM d)::int, 50, 'submitted', u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'medical_claim', 'id', v_id, 'sql', format('SELECT decide_medical_claim(%L, false, %L)', v_id, 'fx295'));
    -- 不合格报告(manual,开单人 u_raise)
    INSERT INTO nonconformance_reports (code, inbound_batch_id, source, description, status, opened_by)
        VALUES ('ZZFX295-NCR', v_ib, 'manual', 'fixture 295', 'open', u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'ncr', 'id', v_id, 'sql', format('SELECT decide_ncr(%L, %L, %L)', v_id, 'accept', 'fx295'));
    -- 工单 · 配料计划(draft)
    INSERT INTO work_orders (code, status, created_by) VALUES ('ZZFX295-WO', 'draft', u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'work_order', 'id', v_id, 'sql', format('SELECT release_work_order(%L)', v_id));
    INSERT INTO blending_plans (code, status, output_material_id, created_by) VALUES ('ZZFX295-BP', 'draft', v_mat, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'blending_plan', 'id', v_id, 'sql', format('SELECT release_blending_plan(%L)', v_id));
    -- 供应商批准(pending_review,建档人 u_raise)
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type, created_by)
        VALUES ('pending_review', 'ZZFX295-SUP2', 'ZZ FX295 Pending', 'SG', 'goods_supplier', u_raise) RETURNING id INTO v_sup_pending;
    docs := docs || jsonb_build_object('type', 'supplier', 'id', v_sup_pending, 'sql', format('SELECT set_supplier_status(%L, %L)', v_sup_pending, 'approved'));
    -- 采集草稿(手工录入,录入人 u_raise)
    PERFORM set_config('evoltrya.ingest_ctx', '1', true);
    INSERT INTO ingest_inbox (source, data_class, payload, payload_bytes, payload_sha256, entered_by)
        VALUES ('manual', 'weighing', '{}'::jsonb, 2, sha256('{}'::bytea), u_raise) RETURNING id INTO v_inbox;
    PERFORM set_config('evoltrya.ingest_ctx', '', true);
    INSERT INTO capture_drafts (inbox_id, data_class, source, proposed) VALUES (v_inbox, 'weighing', 'manual', '{}'::jsonb) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'capture_draft', 'id', v_id, 'sql', format('SELECT reject_capture_draft(%L, %L)', v_id, 'fx295'));
    -- 门户证书(供应商 v_sup 的门户账号交来)
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_portal, now());
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (v_sup, 'FX295 Portal', 'fx295@portal.test') RETURNING id INTO v_contact;
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (u_portal, v_sup, v_contact) RETURNING id INTO v_portal_link;
    INSERT INTO portal_certificate_submissions (portal_user_id, user_id, supplier_id, cert_type_code, cert_no, file_name, file_type, file_size, storage_path, status, submitted_at)
        VALUES (v_portal_link, u_portal, v_sup, 'iso', 'FX295-ISO', 'iso.pdf', 'application/pdf', 100, 'fx295/iso.pdf', 'submitted', now()) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'portal_certificate', 'id', v_id, 'sql', format('SELECT portal_submission_reject(%L, %L)', v_id, 'fx295'));
    -- 已批准、等付款的付款申请
    INSERT INTO payment_requests (code, kind, counterparty_type, supplier_id, planned_date, amount_ccy, currency, amount_base, status, decided_at, decided_by, created_by)
        VALUES ('ZZFX295-PAY2', 'payment_out', 'supplier', v_sup, d + 3, 300, v_ccy, 300, 'approved', now(), (u ->> 'cfo')::uuid, u_raise) RETURNING id INTO v_id;
    docs := docs || jsonb_build_object('type', 'payment_to_pay', 'id', v_id, 'sql', format('SELECT pay_payment_request(%L, %L::date)', v_id, d));
    -- X · R2 的自批例外:主角是 CFO 本人(CFO 是二级真持有人 → 批得了);主角是 finance 本人(不是二级 → 批不了)
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description, created_by)
        VALUES ('ZZFX295-CLM-CFO', (emp ->> 'cfo')::uuid, d - 3, 80, v_ccy, 'fixture 295 cfo own claim', u_raise) RETURNING id INTO c_fx_self;
    docs := docs || jsonb_build_object('type', 'expense_claim', 'id', c_fx_self, 'sql', format('SELECT decide_expense_claim_items(%L, false, NULL, NULL, %L)', c_fx_self, 'fx295'));
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description, created_by)
        VALUES ('ZZFX295-CLM-FIN', (emp ->> 'finance')::uuid, d - 3, 80, v_ccy, 'fixture 295 finance own claim', u_raise) RETURNING id INTO c_fin_self;
    docs := docs || jsonb_build_object('type', 'expense_claim', 'id', c_fin_self, 'sql', format('SELECT decide_expense_claim_items(%L, false, NULL, NULL, %L)', c_fin_self, 'fx295'));
    -- 我的(waiting_mine):finance 的一张任务 · cto 的一张 team 任务(finance 看得见而不是它的)· cco 要写的考核 · gm 要做的自评
    INSERT INTO tasks (code, title, status, task_type, owner_id, created_by) VALUES
        ('ZZFX295-T1', 'fx295 finance task', 'todo', 'personal', (emp ->> 'finance')::uuid, (u ->> 'finance')::uuid),
        ('ZZFX295-T2', 'fx295 cto team task', 'in_progress', 'team', (emp ->> 'cto')::uuid, (u ->> 'cto')::uuid),
        ('ZZFX295-T3', 'fx295 finance done', 'done', 'personal', (emp ->> 'finance')::uuid, (u ->> 'finance')::uuid);
    INSERT INTO performance_reviews (cycle_id, employee_id, review_type, period_start, period_end, reviewer_employee_id, status, created_by)
        VALUES (v_cycle, e_raise, 'annual', d - 365, d - 1, (emp ->> 'cco')::uuid, 'draft', u_raise),
               (v_cycle, (emp ->> 'gm')::uuid, 'annual', d - 365, d - 1, e_raise, 'self_review', u_raise);
    -- 一条没读过的通知(库位 → module.inventory.view 的读者看得见)
    INSERT INTO storage_locations (code, name) VALUES ('ZZFX295-LOC', 'fx295 loc') RETURNING id INTO v_loc;
    INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload)
        VALUES ('iod_class_unconfigured_location', 'storage_location', v_loc, 'ZZFX295-LOC', '{}'::jsonb) RETURNING id INTO v_ntf;
    -- 一张 open 的盘点(S 臂)
    INSERT INTO stocktakes (code, status, created_by) VALUES ('ZZFX295-ST', 'open', u_raise) RETURNING id INTO v_st;

    -- ══════════════ M · 矩阵 ══════════════
    FOREACH r IN ARRAY v_roles LOOP
        PERFORM pg_temp.f295_as((u ->> r)::uuid);
        FOR doc IN SELECT * FROM jsonb_array_elements(docs) LOOP
            t := doc ->> 'type'; v_id := (doc ->> 'id')::uuid; v_sql := doc ->> 'sql';
            SELECT EXISTS (SELECT 1 FROM waiting_decisions() w WHERE w.item_type = t AND w.item_id = v_id) INTO v_listed;
            BEGIN
                EXECUTE v_sql;
                RAISE EXCEPTION 'F295_ACCEPTED';
            EXCEPTION WHEN OTHERS THEN
                v_msg := SQLERRM;
            END;
            IF v_msg = 'F295_ACCEPTED' OR v_msg ~ pg_temp.f295_postgate(t) THEN
                v_accepted := true;
            ELSIF v_msg ~ '^(PERMISSION_DENIED|APPROVAL_NOT_AUTHORISED|SELF_APPROVAL_FORBIDDEN|APPROVALS_NOT_ENABLED|SOD_PAYEE_AND_PAY)' THEN
                v_accepted := false;
            ELSE
                RAISE EXCEPTION 'FIXTURE 295 布景坏了:% 以 % 调 % → %', t, r, v_sql, v_msg;
            END IF;
            v_cells := v_cells + 1;
            IF v_accepted THEN v_any := v_any || jsonb_build_object(t, true); END IF;
            IF v_listed IS DISTINCT FROM v_accepted THEN
                v_fail := v_fail || format(E'\n  %s · %s:待办 %s,决定函数 %s(%s)', r, t, v_listed, v_accepted, v_msg);
            END IF;
            RAISE NOTICE 'F295|%|%|listed=%|accepted=%|%', r, t, v_listed, v_accepted, left(v_msg, 80);
        END LOOP;
    END LOOP;
    IF v_fail <> '' THEN RAISE EXCEPTION 'FIXTURE 295M 失败:待办与决定函数对不上 —— %', v_fail; END IF;

    -- X · 自批例外两张(上面的矩阵已经逐格比过 ⇔;这里点名它们的方向)
    PERFORM pg_temp.f295_as((u ->> 'cfo')::uuid);
    IF NOT EXISTS (SELECT 1 FROM waiting_decisions() w WHERE w.item_id = c_fx_self) THEN
        RAISE EXCEPTION 'FIXTURE 295X 失败:主角是 CFO 本人的报销单不在 CFO 的待办上(R2 例外)'; END IF;
    PERFORM pg_temp.f295_as((u ->> 'finance')::uuid);
    IF EXISTS (SELECT 1 FROM waiting_decisions() w WHERE w.item_id = c_fin_self) THEN
        RAISE EXCEPTION 'FIXTURE 295X 失败:主角是 finance 本人的报销单出现在 finance 的待办上'; END IF;

    FOREACH r IN ARRAY v_roles LOOP
        PERFORM pg_temp.f295_as((u ->> r)::uuid);
        -- S · 盘点不在待办上
        IF EXISTS (SELECT 1 FROM waiting_for_me() w WHERE w.item_id = v_st) THEN
            RAISE EXCEPTION 'FIXTURE 295S 失败:一张 open 的盘点出现在 % 的待办上(Tim Q4 a)', r; END IF;
        -- O · 提醒页的审批支逐行 = 待办的那几行(有支的那几种)
        SELECT string_agg(format('%s %s', o.item_type, o.item_code), ', ') INTO v_ops
          FROM operations_now o JOIN decision_arms() t ON t.arm = o.item_type
         WHERE NOT EXISTS (SELECT 1 FROM waiting_decisions() w
                            WHERE w.item_type = t.decision_type
                              AND ((NOT t.parent_keyed AND w.item_id = o.item_id) OR (t.parent_keyed AND w.parent_id = o.item_id AND w.code = o.item_code)));
        IF v_ops IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 295O 失败:% 在提醒页上看见批不了的审批行:%', r, v_ops; END IF;
        SELECT string_agg(format('%s %s', w.item_type, w.code), ', ') INTO v_ops
          FROM waiting_decisions() w
         WHERE w.item_type NOT IN ('payment_to_pay', 'ncr')   -- 这两种没有审批支(付款不是审批;ncr_open 是一个例外支,见 decision_arms())
           AND NOT EXISTS (SELECT 1 FROM operations_now o JOIN decision_arms() t ON t.arm = o.item_type
                            WHERE t.decision_type = w.item_type
                              AND ((NOT t.parent_keyed AND w.item_id = o.item_id) OR (t.parent_keyed AND w.parent_id = o.item_id AND w.code = o.item_code)));
        IF v_ops IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 295O 失败:% 批得了、提醒页上却没有那一行:%', r, v_ops; END IF;
        -- C · 首页的数 = 待办的行数(以 authenticated 身份读:通知那一段按读者自己的 RLS)
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT waiting_for_me_count(), (SELECT count(*) FROM waiting_for_me()) INTO v_cnt, v_rows;
        EXECUTE 'RESET ROLE';
        IF v_cnt IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'FIXTURE 295C 失败:% 的首页数 % ≠ 待办行数 %', r, v_cnt, v_rows; END IF;
        RAISE NOTICE 'F295C|%|todo=%', r, v_cnt;
    END LOOP;

    -- 我的:finance 只有自己那一张未完成的任务(看得见 cto 的 team 任务,但它不在等 finance);cco 有一份要写的考核;gm 有一份自评
    PERFORM pg_temp.f295_as((u ->> 'finance')::uuid);
    IF (SELECT array_agg(code ORDER BY code) FROM waiting_mine() WHERE item_type = 'task') IS DISTINCT FROM ARRAY['ZZFX295-T1'] THEN
        RAISE EXCEPTION 'FIXTURE 295T 失败:finance 的待办任务应当只有 ZZFX295-T1,实际 %', (SELECT array_agg(code) FROM waiting_mine() WHERE item_type = 'task'); END IF;
    PERFORM pg_temp.f295_as((u ->> 'cco')::uuid);
    IF (SELECT count(*) FROM waiting_mine() WHERE item_type = 'review_write') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 295T 失败:cco 是考核人的那一份 draft 不在它的待办上'; END IF;
    PERFORM pg_temp.f295_as((u ->> 'gm')::uuid);
    IF (SELECT count(*) FROM waiting_mine() WHERE item_type = 'self_review') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 295T 失败:gm 的自评不在它的待办上'; END IF;
    -- 通知:持 module.inventory.view 的读者有它一行,读过之后没有;不持的读者从来没有(按读者自己的 RLS)
    PERFORM pg_temp.f295_as((u ->> 'warehouse')::uuid);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM waiting_for_me() WHERE kind = 'notification' AND item_id = v_ntf;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 295T 失败:warehouse 没读过的那一条通知不在待办上(%)', v_n; END IF;
    INSERT INTO notification_reads (notification_id, user_id) VALUES (v_ntf, (u ->> 'warehouse')::uuid);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM waiting_for_me() WHERE kind = 'notification' AND item_id = v_ntf;
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 295T 失败:读过的通知仍在待办上'; END IF;

    -- R · 提单人自己:给 u_raise 七个角色里最宽的两个(fx295-admin 的全部码 + fx295-cfo 的二级资格),他提的每一张
    --   带四眼的单据都不在他的待办上、决定函数拒他 SELF_APPROVAL_FORBIDDEN;不带四眼的两种(采集草稿 · 门户证书)照列照批;
--   付款:他建了这家供应商,guard_payment_sod 拒他(SOD_PAYEE_AND_PAY),待办也不列
    BEGIN
        INSERT INTO user_roles (user_id, role_id) SELECT u_raise, id FROM roles WHERE code IN ('fx295-admin', 'fx295-cfo');
        PERFORM pg_temp.f295_as(u_raise);
        FOR doc IN SELECT * FROM jsonb_array_elements(docs) LOOP
            t := doc ->> 'type'; v_id := (doc ->> 'id')::uuid;
            SELECT EXISTS (SELECT 1 FROM waiting_decisions() w WHERE w.item_id = v_id) INTO v_listed;
            BEGIN EXECUTE doc ->> 'sql'; RAISE EXCEPTION 'F295_ACCEPTED'; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
            IF t = 'payment_to_pay' THEN
                -- 付款没有四眼,但 u_raise 建了这家供应商:guard_payment_sod 拒他,待办也不列
                IF v_listed OR v_msg !~ '^SOD_PAYEE_AND_PAY' THEN
                    RAISE EXCEPTION 'FIXTURE 295R 失败:建供应商的人付它的款 —— 列 %,%', v_listed, v_msg; END IF;
            ELSIF t IN ('capture_draft', 'portal_certificate') THEN
                IF NOT v_listed OR NOT (v_msg = 'F295_ACCEPTED' OR v_msg ~ pg_temp.f295_postgate(t)) THEN
                    RAISE EXCEPTION 'FIXTURE 295R 失败:% 没有四眼,提单人应当照列照批(列 %,%)', t, v_listed, v_msg; END IF;
            ELSIF v_listed OR v_msg !~ '^SELF_APPROVAL_FORBIDDEN' THEN
                RAISE EXCEPTION 'FIXTURE 295R 失败:% 是提单人自己的,却 列 % / %', t, v_listed, v_msg;
            END IF;
        END LOOP;
        RAISE EXCEPTION 'F295_R_DONE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'F295_R_DONE' THEN RAISE; END IF;
    END;

    -- B · 批量(Tim C,只在本地重建上证):待办页的批量 = 每一项走它自己那一种的单项动作、一次一项(lib/bulkRun.ts runOneAtATime)。
    --   CFO 把待办上【能批量】的每一行(凭证 · 仓库 · 条款 · 资产处置 · 一般报销;采集草稿归 cto/warehouse)逐项驳回,
    --   同一句理由;再混进一张他【自己提】的仓库申请:那一项被按名拒(SELF_APPROVAL_FORBIDDEN),别的照做 —— 结果名单逐项说出理由。
    --   之后这几行从他的待办上消失;他自己那一张在库里仍是 submitted(四眼拦下的,不是被跳过)。
    BEGIN
        DECLARE
            v_cfo uuid := (u ->> 'cfo')::uuid; v_own uuid; v_ib2 uuid; b record; v_done int := 0; v_refused text := ''; v_left int;
        BEGIN
            -- 一批一张在等的仓库申请(warehouse_requests_one_open_inbound)—— 他自己那一张挂在另一批上
            INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date, unit_price, source_reason_code, source_reason_note)
                VALUES ('ZZFX295-IB2', v_mat, v_sup, 10, 10, d - 10, 10, 'other', 'fixture 295 B') RETURNING id INTO v_ib2;
            INSERT INTO warehouse_requests (kind, label, reason, snapshot, amount_base, inbound_batch_id, created_by)
                VALUES ('write_off_inbound', 'ZZFX295-WR-OWN', 'fixture 295 B', '{}'::jsonb, 10, v_ib2, v_cfo) RETURNING id INTO v_own;
            PERFORM pg_temp.f295_as(v_cfo);
            FOR b IN SELECT w.item_type, w.item_id, w.code FROM waiting_decisions() w
                      WHERE w.item_type IN ('journal_request', 'warehouse_request', 'terms_request', 'asset_disposal_request', 'expense_claim')
                     UNION ALL SELECT 'warehouse_request', v_own, 'ZZFX295-WR-OWN'
                     ORDER BY 3 LOOP
                BEGIN
                    CASE b.item_type
                        WHEN 'journal_request' THEN PERFORM decide_journal_request(b.item_id, false, 'fixture 295 B 批量驳回');
                        WHEN 'warehouse_request' THEN PERFORM decide_warehouse_request(b.item_id, false, 'fixture 295 B 批量驳回');
                        WHEN 'terms_request' THEN PERFORM decide_terms_request(b.item_id, false, 'fixture 295 B 批量驳回');
                        WHEN 'asset_disposal_request' THEN PERFORM decide_asset_disposal_request(b.item_id, false, 'fixture 295 B 批量驳回');
                        WHEN 'expense_claim' THEN PERFORM decide_expense_claim_items(b.item_id, false, NULL, NULL, 'fixture 295 B 批量驳回');
                    END CASE;
                    v_done := v_done + 1;
                EXCEPTION WHEN OTHERS THEN
                    v_refused := v_refused || b.code || ' → ' || SQLERRM || '; ';
                END;
            END LOOP;
            IF v_refused !~ '^ZZFX295-WR-OWN → SELF_APPROVAL_FORBIDDEN' OR v_refused ~ ';.*;' THEN
                RAISE EXCEPTION 'FIXTURE 295B 失败:只有 CFO 自己提的那一张该被拒(SELF_APPROVAL_FORBIDDEN),实得:%', v_refused; END IF;
            IF v_done < 5 THEN RAISE EXCEPTION 'FIXTURE 295B 失败:批量驳回应当做成至少五项(凭证 · 仓库 · 条款 · 资产 · 报销),实得 %', v_done; END IF;
            SELECT count(*) INTO v_left FROM waiting_decisions() w
             WHERE w.item_type IN ('journal_request', 'warehouse_request', 'terms_request', 'asset_disposal_request', 'expense_claim');
            IF v_left <> 0 THEN RAISE EXCEPTION 'FIXTURE 295B 失败:驳回之后 CFO 的待办上还剩 % 行能批量的', v_left; END IF;
            IF (SELECT status FROM warehouse_requests WHERE id = v_own) <> 'submitted'
               OR (SELECT count(*) FROM warehouse_requests WHERE label LIKE 'ZZFX295-WR%' AND status = 'rejected' AND decision_notes = 'fixture 295 B 批量驳回') <> 1 THEN
                RAISE EXCEPTION 'FIXTURE 295B 失败:被拒的那一张应当仍在等、做成的那一张应当带着那句理由'; END IF;
            -- 采集草稿:cto 那一侧(只驳回)
            PERFORM pg_temp.f295_as((u ->> 'cto')::uuid);
            FOR b IN SELECT w.item_id FROM waiting_decisions() w WHERE w.item_type = 'capture_draft' LOOP
                PERFORM reject_capture_draft(b.item_id, 'fixture 295 B 批量驳回');
            END LOOP;
            IF EXISTS (SELECT 1 FROM waiting_decisions() w WHERE w.item_type = 'capture_draft') THEN
                RAISE EXCEPTION 'FIXTURE 295B 失败:驳回之后采集草稿仍在 cto 的待办上'; END IF;
            RAISE NOTICE 'F295B|done=%|refused=%', v_done, v_refused;
            RAISE EXCEPTION 'F295_B_DONE';
        END;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'F295_B_DONE' THEN RAISE; END IF;
    END;

    -- N · 每一种至少有一个读者接受
    SELECT string_agg(x, ', ') INTO v_msg FROM (SELECT DISTINCT d2 ->> 'type' AS x FROM jsonb_array_elements(docs) d2) q WHERE NOT v_any ? q.x;
    IF v_msg IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 295N 失败:这几种七个读者谁都批不了(⇔ 空转):%', v_msg; END IF;
    SELECT count(DISTINCT d2 ->> 'type') INTO v_n FROM jsonb_array_elements(docs) d2;
    IF v_n <> 24 THEN RAISE EXCEPTION 'FIXTURE 295N 失败:布景应当覆盖 24 种,实际 %', v_n; END IF;

    RAISE NOTICE 'FIXTURE 295 全部通过:% 格(7 个线上角色 × % 张单据,24 种),待办 ⇔ 决定函数逐格相等', v_cells, jsonb_array_length(docs);
END;
$$;

ROLLBACK;

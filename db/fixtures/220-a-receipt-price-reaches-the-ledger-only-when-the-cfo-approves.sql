-- 220 ROLE-1 · Batch 4b:一个收货价格只有 CFO 批了才进账(2026-09-25)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Batch 4 grilling Q2–Q8 + Batch 4b grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   A  引擎登记:链的名册只有二级一行,门 = module.inbound.view + data.view_purchase_prices;
--        在途清单那一支 blocks_disable = true、fixed_level = 2;operations_now 有 receipt_price_request_pending
--   B  ★★ 提(审批开着):申请 submitted;单价、price_history、分录、应付清单那一格【一样都没动】;
--        留痕 submitted、二级、金额 = |Δ 应付|
--   C  ★ 等待期间冻住:第二张申请 · 直连改供应商 · 手工含量 · 注销 ·
--        应用化验(手工申请在等)→ 全部 RECEIPT_PRICE_REQUEST_OPEN
--   D  谁批不了:提单人 → SELF_APPROVAL_FORBIDDEN|raiser;一级 → APPROVAL_NOT_AUTHORISED;
--        不持采购码的二级 → PERMISSION_DENIED;驳回不给理由 → …_REJECT_REASON_REQUIRED
--   E  ★★ CFO 批准:当场过账 —— 单价、price_history 各一行、purchase 分录一张;2000 的贷方增量 =
--        清单那一格的增量 = 数量 × 价(清单对总账两边动同一个数);留痕 approved
--   F  ★ 指纹:批准前那一组事实变了 → RECEIPT_PRICE_CHANGED_SINCE_REQUEST,一行不落
--   G  ★ 低于已付:提交与批准都按名拒 RECEIPT_PRICE_BELOW_SETTLED(已付 = 预付冲抵)
--   H  ★★ 提单人之外没人批得动(4b Q1):CFO 那个人的另一个账号提 → RECEIPT_PRICE_NO_OTHER_DECIDER,一行不落
--   I  ★★ 化验:应用照旧全部落地、同一事务提一张来源 assay 的申请,pricing_status 不升;新化验取代它
--        (撤回并写明理由);撤销应用撤回它那一张;批准后才升 final(4b Q3 · Q5)
--   J  撤回:提单人本人、持 action.price_receipts 的人撤得了;别人 → PERMISSION_DENIED|action.price_receipts
--   K  ★ pricing_status 直连写 → PRICING_STATUS_VIA_FUNCTION(4b Q3)
--   L  收货台带价建单:收货落下【不带价】,同一事务里一张 desk 申请在等(Q4)
--   M  审批关着:生下来 approved、当场过账、留痕 auto_approved;批准按名拒
--   N  ★ 故障注入:拿掉含量守卫的触发器,C 那一次手工含量就写得进 —— 它是承重的
--
-- 自带数据(README 第 2 条);锁期自己设(README 第 4 条);牌价与行情自己插。
-- 【数字怎么来的】I 臂:ni 行情 15,000 USD/t、批次 100 kg、可付 70%、处理费 200 USD/t、fx USD tt_sell 1.26:
--   化验 ni 30% → (100×0.30×0.70×15 − 100/1000×200)/100 = 2.95 USD/kg → 3.717 本位币;
--   化验 ni 40% → (420 − 20)/100 = 4.00 USD/kg → 5.04 本位币。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f220_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f220_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 这张收货在 2000 上的净贷方(本位币),按 source_id 归集(本支不冲销,一跳就够)
CREATE FUNCTION pg_temp.f220_ap(p_batch uuid) RETURNS numeric
LANGUAGE sql AS $f$
    SELECT COALESCE(sum(l.credit - l.debit), 0)
      FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
      JOIN accounts a ON a.id = l.account_id
     WHERE e.source_id = p_batch AND a.code = '2000'
$f$;

DO $$
DECLARE
    u_fin   uuid := gen_random_uuid();   -- 财务:action.price_receipts + 两个价格码 + inbound
    u_cfo   uuid := gen_random_uuid();   -- 二级:inbound.view + 采购码(CFO 的形状);在册员工 e_cfo 的主账号
    u_cfo2  uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持财务角色 —— "同一个人提的"那一臂
    u_l1    uuid := gen_random_uuid();   -- 一级
    u_cto   uuid := gen_random_uuid();   -- action.apply_assay + inbound.edit + 采购码
    u_wh    uuid := gen_random_uuid();   -- inbound.edit + inbound.view,【不】持 price_receipts
    r_fin uuid; r_l1 uuid; r_l2 uuid; r_cto uuid; r_wh uuid;
    e_cfo uuid := gen_random_uuid();
    v_base text; v_sup uuid; v_sup2 uuid; v_mat uuid; v_formula uuid; v_commit uuid; v_po uuid;
    b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid;
    q uuid; q2 uuid; q3 uuid; v_res jsonb; v_msg text; v_n int; v_n0 int; v_je0 int; v_ph0 int; v_log0 int;
    v_ap0 numeric; v_ap1 numeric; v_a1 uuid; v_a2 uuid; v_a3 uuid;
    v_metals30 jsonb := jsonb_build_array(jsonb_build_object('metal','ni','content_pct',30));
    v_metals40 jsonb := jsonb_build_array(jsonb_build_object('metal','ni','content_pct',40));
    v_today date := CURRENT_DATE;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_cto, now()), (u_wh, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx220-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx220-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx220-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx220-cto','f','f',true) RETURNING id INTO r_cto;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx220-wh','f','f',true)  RETURNING id INTO r_wh;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'action.price_receipts'), (r_fin, 'data.view_purchase_prices'), (r_fin, 'data.view_prices'),
        (r_fin, 'module.inbound.edit'), (r_fin, 'module.inbound.view'),
        (r_fin, 'module.finance.view'), (r_fin, 'module.finance.edit'),
        -- ROLE-1 Batch 3b:L 臂在收货台带价建单 —— 从本刀起建单要 action.receive_goods(线上只有 admin 同时持它与定价码)。
        (r_fin, 'action.receive_goods'),
        -- 一级:审批开得了(每条分档链的门它都持)—— 批不了定价申请只能因为【级别】
        (r_l1, 'module.purchasing.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'),
        (r_l1, 'module.finance.view'), (r_l1, 'module.hr.view'), (r_l1, 'data.view_pay'), (r_l1, 'module.inbound.view'),
        -- 二级:CFO 的形状 —— 读得到、看得见,【没有】price_receipts、没有 inbound.edit
        (r_l2, 'module.purchasing.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'),
        (r_l2, 'module.finance.view'), (r_l2, 'module.hr.view'), (r_l2, 'data.view_pay'), (r_l2, 'module.inbound.view'),
        (r_cto, 'action.apply_assay'), (r_cto, 'module.inbound.edit'), (r_cto, 'module.inbound.view'),
        (r_cto, 'data.view_purchase_prices'),
        -- ROLE-1 Batch 3b:注销批次是它自己的码(action.batch_write_off),仓库持有 —— C5 拒在等待中的申请上,不拒在码上。
        (r_wh, 'module.inbound.edit'), (r_wh, 'module.inbound.view'), (r_wh, 'action.batch_write_off');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_cfo, r_l2), (u_cfo2, r_fin), (u_l1, r_l1), (u_cto, r_cto), (u_wh, r_wh);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_cfo, 'FX220-CFO', 'FX220 CFO', 'full_time', 'office', v_today - 400, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES
        ('ZZFIX220-S', 'fixture 220 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES
        ('ZZFIX220-S2', 'fixture 220 supplier 2', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX220-M', 'fixture 220 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date,
                                 source_reason_code, source_reason_note) VALUES
        ('ZZFIX220-IB1', v_mat, v_sup, 680, 680, v_today, 'other', 'fixture 220'),
        ('ZZFIX220-IB2', v_mat, v_sup, 10, 10, v_today, 'other', 'fixture 220'),
        ('ZZFIX220-IB3', v_mat, v_sup, 100, 100, v_today, 'other', 'fixture 220'),
        ('ZZFIX220-IB4', v_mat, v_sup, 10, 10, v_today, 'other', 'fixture 220');
    SELECT id INTO b1 FROM inbound_batches WHERE code = 'ZZFIX220-IB1';
    SELECT id INTO b2 FROM inbound_batches WHERE code = 'ZZFIX220-IB2';
    SELECT id INTO b3 FROM inbound_batches WHERE code = 'ZZFIX220-IB3';
    SELECT id INTO b4 FROM inbound_batches WHERE code = 'ZZFIX220-IB4';
    -- b2 已经定过价(属主路径直写;价格守卫只挡 UPDATE 之外的路)—— G 臂的"已付"站在它上面
    PERFORM set_config('evoltrya.price_ctx', 'fixture', true);
    UPDATE inbound_batches SET unit_price = 10 WHERE id = b2;
    PERFORM set_config('evoltrya.price_ctx', '', true);

    -- 化验布景(I 臂):牌价、行情、公式、实验室;b3 的承诺副本(结算时指名)
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD' AND rate_date = v_today AND rate_type = 'tt_sell';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit) VALUES ('USD', v_today, 'tt_sell', 1.26);
    DELETE FROM metal_prices WHERE metal = 'ni' AND price_date = v_today;
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source) VALUES ('ni', v_today, 15000, 'broker_quote');
    INSERT INTO pricing_formulas (code, name, direction, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct, is_active)
    VALUES ('', 'Fixture Formula 220', 'purchase', 'spot', 200, 0, true) RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_formula, 'ni', 70);
    INSERT INTO laboratories (code, name_en, name_zh, sort_order) VALUES ('Fixture Lab 220', 'Fixture Lab 220', 'Fixture Lab 220', 99);

    -- 策略:一级 fx220-l1、二级 fx220-l2;审批打开;期间不锁
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx220-l1', approval_level2_role_code = 'fx220-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 引擎登记 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'receipt_price_request')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'receipt_price_request')
         IS DISTINCT FROM ARRAY['module.inbound.view', 'data.view_purchase_prices']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 220A1 失败:链的名册应当只有二级一行,门 = inbound.view + 采购码'; END IF;
    IF position('receipt_price_request_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 220A2 失败:operations_now 没有 receipt_price_request_pending 那一支'; END IF;

    -- ══════════════ B · 提(审批开着)══════════════
    SELECT count(*) INTO v_je0 FROM journal_entries;
    SELECT count(*) INTO v_ph0 FROM price_history;
    v_ap0 := pg_temp.f220_ap(b1);
    PERFORM pg_temp.f220_as(u_fin);
    v_res := set_inbound_unit_price(b1, 2, v_base, NULL, 'fixture 220 B');
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 220B1 失败:审批开着时定价应当提一张 submitted 的申请,实得 %', v_res; END IF;
    IF (SELECT unit_price FROM inbound_batches WHERE id = b1) IS NOT NULL
       OR (SELECT count(*) FROM price_history) <> v_ph0
       OR (SELECT count(*) FROM journal_entries) <> v_je0
       OR pg_temp.f220_ap(b1) <> v_ap0 THEN
        RAISE EXCEPTION 'FIXTURE 220B2 失败:一张在等的申请不该动单价、price_history、分录或 2000'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'receipt_price_request' AND subject_id = q
                    AND decision = 'submitted' AND level = 2 AND amount_base = 1360.00 AND currency = v_base) THEN
        RAISE EXCEPTION 'FIXTURE 220B3 失败:留痕应当是 submitted、二级、|Δ| = 680 × 2 = 1,360.00 本位币'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() d WHERE d.subject_type = 'receipt_price_request'
                    AND d.doc_id = q AND d.blocks_disable AND d.fixed_level = 2 AND d.subject_employee_id IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 220B4 失败:在途清单那一支应当 blocks_disable、fixed_level = 2、主角 NULL'; END IF;

    -- ══════════════ C · 等待期间冻住 ══════════════
    v_msg := pg_temp.f220_try(format('SELECT set_inbound_unit_price(%L, 3, %L)', b1, v_base));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|ZZFIX220-IB1|%' THEN
        RAISE EXCEPTION 'FIXTURE 220C1 失败:第二张申请应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f220_as(u_wh);
    v_msg := pg_temp.f220_try(format('UPDATE inbound_batches SET supplier_id = %L WHERE id = %L', v_sup2, b1), true);
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|ZZFIX220-IB1|%' THEN
        RAISE EXCEPTION 'FIXTURE 220C2 失败:直连改供应商应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f220_try(format('INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (%L, %L, 12, %L)', b1, 'ni', 'manual'), true);
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|ZZFIX220-IB1|%' THEN
        RAISE EXCEPTION 'FIXTURE 220C4 失败:手工录含量应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f220_try(format('SELECT soft_delete_inbound_batch(%L, %L)', b1, 'fixture 220 C5'));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|ZZFIX220-IB1|%' THEN
        RAISE EXCEPTION 'FIXTURE 220C5 失败:注销应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f220_as(u_cto);
    v_res := record_assay_result(p_assay_date => v_today, p_metals => v_metals30, p_lab_name => 'Fixture Lab 220',
                                 p_inbound_batch_id => b1, p_weight_basis => 'as_received', p_result_party => 'ours');
    v_msg := pg_temp.f220_try(format('SELECT apply_assay_result(%L)', v_res->>'assay_result_id'));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_OPEN|ZZFIX220-IB1|%' THEN
        RAISE EXCEPTION 'FIXTURE 220C6 失败:手工申请在等时应用化验应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ D · 谁批不了 ══════════════
    PERFORM pg_temp.f220_as(u_fin);
    v_msg := pg_temp.f220_try(format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'SELF_APPROVAL_FORBIDDEN|raiser%' THEN
        RAISE EXCEPTION 'FIXTURE 220D1 失败:提单人批自己的申请应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f220_as(u_l1);
    v_msg := pg_temp.f220_try(format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN
        RAISE EXCEPTION 'FIXTURE 220D2 失败:一级批不了二级的链,实得 %', v_msg; END IF;
    PERFORM pg_temp.f220_as(u_wh);
    v_msg := pg_temp.f220_try(format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg <> 'PERMISSION_DENIED|data.view_purchase_prices' THEN
        RAISE EXCEPTION 'FIXTURE 220D3 失败:不持采购码的人应当在门上被拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f220_as(u_cfo);
    v_msg := pg_temp.f220_try(format('SELECT decide_receipt_price_request(%L, false, %L)', q, '  '));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_REJECT_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 220D4 失败:驳回不给理由应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ F · 指纹(放在 E 之前:同一张申请,先证"变了就拒",再真批)══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE receipt_price_requests SET snapshot = snapshot || '{"quantity": 999}'::jsonb WHERE id = q;
    PERFORM pg_temp.f220_as(u_cfo);
    v_msg := pg_temp.f220_try(format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_CHANGED_SINCE_REQUEST|%' OR (SELECT unit_price FROM inbound_batches WHERE id = b1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 220F1 失败:指纹变了应当按名拒且不过账,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE receipt_price_requests SET snapshot = receipt_price_fingerprint(b1) WHERE id = q;

    -- ══════════════ E · CFO 批准:当场过账 ══════════════
    PERFORM pg_temp.f220_as(u_cfo);
    v_res := decide_receipt_price_request(q, true, 'fixture 220 E');
    v_ap1 := pg_temp.f220_ap(b1);
    IF (SELECT status FROM receipt_price_requests WHERE id = q) <> 'approved'
       OR (SELECT unit_price FROM inbound_batches WHERE id = b1) <> 2
       OR (SELECT count(*) FROM price_history WHERE inbound_batch_id = b1) <> 1
       OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR (SELECT result_journal_entry_id FROM receipt_price_requests WHERE id = q) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 220E1 失败:批准应当当场过账(单价 2、price_history 一行、分录一张),实得 %', v_res; END IF;
    -- 清单那一格(round(数量 × 单价, 2) − 已付)与 2000 的增量是同一个数
    IF v_ap1 - v_ap0 <> round(680 * 2, 2) OR v_ap1 - v_ap0 <> 1360.00 THEN
        RAISE EXCEPTION 'FIXTURE 220E2 失败:2000 的贷方增量 % 应当等于清单那一格的增量 1,360.00', v_ap1 - v_ap0; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = q AND decision = 'approved' AND level = 2
                    AND actor_user_id = u_cfo AND amount_base = 1360.00 AND NOT self_decided) THEN
        RAISE EXCEPTION 'FIXTURE 220E3 失败:留痕应当是 approved、二级、CFO、1,360.00'; END IF;
    IF (SELECT pricing_status FROM inbound_batches WHERE id = b1) <> 'provisional' THEN
        RAISE EXCEPTION 'FIXTURE 220E4 失败:手工价不该把状态升 final'; END IF;

    -- ══════════════ G · 低于已付 ══════════════
    -- b2:10 kg × 10 = 100 已计价;预付冲抵 60 → 已付 60。5 × 10 = 50 < 60 → 拒;7 × 10 = 70 → 放
    INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate)
    VALUES ('ZZFIX220-PO', v_sup, v_today, 'confirmed', v_base, 1) RETURNING id INTO v_po;
    INSERT INTO prepayment_applications (purchase_order_id, inbound_batch_id, amount_base, currency, amount_ccy)
    VALUES (v_po, b2, 60, v_base, 60);
    PERFORM pg_temp.f220_as(u_fin);
    v_msg := pg_temp.f220_try(format('SELECT set_inbound_unit_price(%L, 5, %L)', b2, v_base));
    IF v_msg <> 'RECEIPT_PRICE_BELOW_SETTLED|ZZFIX220-IB2|50.00|60.00' THEN
        RAISE EXCEPTION 'FIXTURE 220G1 失败:提交低于已付应当按名拒,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM receipt_price_requests WHERE inbound_batch_id = b2) THEN
        RAISE EXCEPTION 'FIXTURE 220G2 失败:被拒的提交不该留下申请'; END IF;
    v_res := set_inbound_unit_price(b2, 7, v_base);
    q2 := (v_res->>'request_id')::uuid;
    -- 等待期间又冲了 20(已付 80 > 70)—— 批准那一刻按那一刻再比
    INSERT INTO prepayment_applications (purchase_order_id, inbound_batch_id, amount_base, currency, amount_ccy)
    VALUES (v_po, b2, 20, v_base, 20);
    PERFORM pg_temp.f220_as(u_cfo);
    v_msg := pg_temp.f220_try(format('SELECT decide_receipt_price_request(%L, true)', q2));
    IF v_msg <> 'RECEIPT_PRICE_BELOW_SETTLED|ZZFIX220-IB2|70.00|80.00' OR (SELECT unit_price FROM inbound_batches WHERE id = b2) <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 220G3 失败:批准时低于已付应当按名拒且不过账,实得 %', v_msg; END IF;
    v_res := decide_receipt_price_request(q2, false, 'fixture 220 G: below what was paid');
    IF (SELECT status FROM receipt_price_requests WHERE id = q2) <> 'rejected'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = q2 AND decision = 'rejected') THEN
        RAISE EXCEPTION 'FIXTURE 220G4 失败:驳回应当落 rejected 与留痕'; END IF;

    -- ══════════════ H · 提单人之外没人批得动 ══════════════
    SELECT count(*) INTO v_n0 FROM receipt_price_requests;
    PERFORM pg_temp.f220_as(u_cfo2);
    v_msg := pg_temp.f220_try(format('SELECT set_inbound_unit_price(%L, 4, %L)', b4, v_base));
    IF v_msg <> 'RECEIPT_PRICE_NO_OTHER_DECIDER|ZZFIX220-IB4' OR (SELECT count(*) FROM receipt_price_requests) <> v_n0 THEN
        RAISE EXCEPTION 'FIXTURE 220H1 失败:CFO 那个人的另一个账号提的申请没人批得了,应当在提交时按名拒,实得 %', v_msg; END IF;

    -- ══════════════ J · 撤回 ══════════════
    PERFORM pg_temp.f220_as(u_fin);
    q3 := (set_inbound_unit_price(b4, 4, v_base)->>'request_id')::uuid;
    PERFORM pg_temp.f220_as(u_wh);
    v_msg := pg_temp.f220_try(format('SELECT withdraw_receipt_price_request(%L)', q3));
    IF v_msg <> 'PERMISSION_DENIED|action.price_receipts' THEN
        RAISE EXCEPTION 'FIXTURE 220J1 失败:别人撤不了,实得 %', v_msg; END IF;
    PERFORM pg_temp.f220_as(u_cfo2);   -- 不是提单人,但持 action.price_receipts
    PERFORM withdraw_receipt_price_request(q3, 'fixture 220 J');
    IF (SELECT status FROM receipt_price_requests WHERE id = q3) <> 'withdrawn'
       OR (SELECT withdraw_reason FROM receipt_price_requests WHERE id = q3) <> 'fixture 220 J' THEN
        RAISE EXCEPTION 'FIXTURE 220J2 失败:持 price_receipts 的人应当撤得了,理由记在行上'; END IF;

    -- ══════════════ I · 化验 ══════════════
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM set_config('request.jwt.claims', '', true);
    v_commit := commit_pricing_terms(v_formula, NULL, b3);
    PERFORM pg_temp.f220_as(u_cto);
    v_a1 := (record_assay_result(p_assay_date => v_today, p_metals => v_metals30, p_lab_name => 'Fixture Lab 220',
                                 p_inbound_batch_id => b3, p_weight_basis => 'as_received', p_result_party => 'ours')->>'assay_result_id')::uuid;
    v_res := apply_assay_result(v_a1);
    IF (v_res->'price_request'->>'status') <> 'submitted'
       OR (SELECT applied_at FROM assay_results WHERE id = v_a1) IS NULL
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_metals WHERE inbound_batch_id = b3 AND metal = 'ni' AND content_pct = 30
                       AND content_source = 'assay' AND source_assay_id = v_a1)
       OR (SELECT unit_price FROM inbound_batches WHERE id = b3) IS NOT NULL
       OR (SELECT pricing_status FROM inbound_batches WHERE id = b3) <> 'provisional'
       OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 220I1 失败:应用应当全部落地、提一张 submitted 的化验申请、不过账不升 final,实得 %', v_res; END IF;
    q := (v_res->'price_request'->>'request_id')::uuid;
    IF (SELECT (source, assay_result_id, created_by, unit_price_ccy, currency)
          FROM receipt_price_requests WHERE id = q) IS DISTINCT FROM ('assay'::text, v_a1, u_cto, 2.95::numeric, 'USD'::text) THEN
        RAISE EXCEPTION 'FIXTURE 220I2 失败:化验申请应当是 assay 来源、指着那份化验、提单人 = 按应用的人、冻结 2.95 USD'; END IF;
    -- 新化验取代它
    v_a2 := (record_assay_result(p_assay_date => v_today, p_metals => v_metals40, p_lab_name => 'Fixture Lab 220',
                                 p_inbound_batch_id => b3, p_weight_basis => 'as_received', p_result_party => 'ours')->>'assay_result_id')::uuid;
    v_res := apply_assay_result(v_a2);
    q2 := (v_res->'price_request'->>'request_id')::uuid;
    IF (SELECT status FROM receipt_price_requests WHERE id = q) <> 'withdrawn'
       OR (SELECT withdraw_reason FROM receipt_price_requests WHERE id = q) NOT LIKE 'Superseded by assay %'
       OR (SELECT (status, unit_price_ccy) FROM receipt_price_requests WHERE id = q2) IS DISTINCT FROM ('submitted'::text, 4.00::numeric) THEN
        RAISE EXCEPTION 'FIXTURE 220I3 失败:新化验应当撤回在等的那张(写明理由)并提自己的 4.00'; END IF;
    -- 撤销应用撤回它那一张
    PERFORM unapply_assay_result(v_a2, 'fixture 220 I4');
    IF (SELECT status FROM receipt_price_requests WHERE id = q2) <> 'withdrawn'
       OR (SELECT withdraw_reason FROM receipt_price_requests WHERE id = q2) NOT LIKE '% unapplied: fixture 220 I4' THEN
        RAISE EXCEPTION 'FIXTURE 220I4 失败:撤销应用应当撤回那份化验的申请'; END IF;
    -- 第三份化验(ni 30%)应用,CFO 批:当场过账、升 final
    v_a3 := (record_assay_result(p_assay_date => v_today, p_metals => v_metals30, p_lab_name => 'Fixture Lab 220',
                                 p_inbound_batch_id => b3, p_weight_basis => 'as_received', p_result_party => 'ours')->>'assay_result_id')::uuid;
    v_res := apply_assay_result(v_a3);
    q3 := (v_res->'price_request'->>'request_id')::uuid;
    PERFORM pg_temp.f220_as(u_cfo);
    PERFORM decide_receipt_price_request(q3, true);
    IF (SELECT unit_price FROM inbound_batches WHERE id = b3) <> 3.717
       OR (SELECT pricing_status FROM inbound_batches WHERE id = b3) <> 'final' THEN
        RAISE EXCEPTION 'FIXTURE 220I5 失败:批准化验申请应当过账 3.717 并升 final,实得 % / %',
            (SELECT unit_price FROM inbound_batches WHERE id = b3), (SELECT pricing_status FROM inbound_batches WHERE id = b3); END IF;

    -- ══════════════ K · pricing_status 直连写 ══════════════
    PERFORM pg_temp.f220_as(u_wh);
    v_msg := pg_temp.f220_try(format('UPDATE inbound_batches SET pricing_status = %L WHERE id = %L', 'final', b1), true);
    IF v_msg <> 'PRICING_STATUS_VIA_FUNCTION|ZZFIX220-IB1' THEN
        RAISE EXCEPTION 'FIXTURE 220K1 失败:直连写 pricing_status 应当按名拒,实得 %', v_msg; END IF;

    -- ══════════════ L · 收货台带价建单 ══════════════
    PERFORM pg_temp.f220_as(u_fin);
    v_res := create_inbound_batch(v_mat, v_sup, 3, 'kg', v_today, '待加工', 9, 'fixture 220 L',
        p_source_reason_code => 'other', p_source_reason_note => 'fixture 220', p_currency => v_base);
    b5 := (v_res->>'batch_id')::uuid;
    IF (SELECT unit_price FROM inbound_batches WHERE id = b5) IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM receipt_price_requests WHERE inbound_batch_id = b5 AND source = 'desk' AND status = 'submitted') THEN
        RAISE EXCEPTION 'FIXTURE 220L1 失败:带价建单应当落一张【不带价】的收货,同一事务里一张 desk 申请在等,实得 %', v_res; END IF;

    -- ══════════════ N · 故障注入:含量守卫是承重的 ══════════════
    SELECT id INTO q FROM receipt_price_requests WHERE inbound_batch_id = b5 AND status = 'submitted';
    PERFORM set_config('request.jwt.claims', '', true);
    ALTER TABLE public.inbound_batch_metals DISABLE TRIGGER trg_inbound_batch_metals_price_request;
    PERFORM pg_temp.f220_as(u_wh);
    v_msg := pg_temp.f220_try(format('INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (%L, %L, 12, %L)', b5, 'ni', 'manual'), true);
    PERFORM set_config('request.jwt.claims', '', true);
    ALTER TABLE public.inbound_batch_metals ENABLE TRIGGER trg_inbound_batch_metals_price_request;
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 220N1 失败:拿掉守卫之后那次手工含量应当写得进(证明守卫承重),实得 %', v_msg; END IF;

    -- ══════════════ M · 审批关着 ══════════════
    PERFORM pg_temp.f220_as(u_fin);
    PERFORM withdraw_receipt_price_request(q);   -- 先撤回在等的那张(关审批会被 blocks_disable 挡住)
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f220_as(u_fin);
    v_res := set_inbound_unit_price(b4, 4, v_base);
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'approved' OR v_res->>'journal_code' IS NULL
       OR (SELECT unit_price FROM inbound_batches WHERE id = b4) <> 4
       OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = q AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 220M1 失败:审批关着时应当生下来 approved、当场过账、留痕 auto_approved,实得 %', v_res; END IF;
    PERFORM pg_temp.f220_as(u_cfo);
    v_msg := pg_temp.f220_try(format('SELECT decide_receipt_price_request(%L, true)', q));
    IF v_msg NOT LIKE 'RECEIPT_PRICE_REQUEST_NOT_SUBMITTED|%' AND v_msg <> 'APPROVALS_NOT_ENABLED' THEN
        RAISE EXCEPTION 'FIXTURE 220M2 失败:审批关着时不该有人按批准,实得 %', v_msg; END IF;

    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'FIXTURE 220 全部通过:A 引擎登记 · B 提(不动账)· C 等待期间冻住 · D 谁批不了 · E CFO 批准当场过账(2000 与清单同动 1,360.00)· F 指纹 · G 低于已付(提交与批准)· H 提单人之外没人批得动 · I 化验(取代 · 撤销 · 批准才 final)· J 撤回 · K pricing_status 只经函数 · L 收货台带价 · M 审批关着 · N 故障注入';
END $$;
ROLLBACK;

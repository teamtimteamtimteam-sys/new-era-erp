-- 219 ROLE-1 · Batch 4a:采购价自成一个码,收货只由财务定价,看不见价格的人在库里就定不了价(2026-09-25)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Batch 4 grilling Q1 · Q4 · Q7 · Q9 · Q11,Tim 2026-09-25 全部接受)
--   A  引导:每一个持 data.view_prices 的角色都持 data.view_purchase_prices;warehouse 持采购码、
--        【不】持 view_prices;finance 持 action.price_receipts,warehouse 不持
--   B  ★ 可见性按侧分:只持采购码的人读得到收货单价与改价历史;只持 view_prices 的人读到 NULL
--   C  ★★ 谁定价:只持 inbound.edit + 采购码的人(今天的仓库)—— set_inbound_unit_price、
--        reprice_from_committed_terms、建单带价 → PERMISSION_DENIED|action.price_receipts,
--        建单那一笔整笔回滚;不带价建单照成
--   D  ★★ 看不见价格的人不能定价,在库里挡:持 action.price_receipts 却不持采购码 →
--        PERMISSION_DENIED|data.view_purchase_prices;引擎 reprice_inbound_batch 本身(应用化验落进来的
--        那一支)对一个不持采购码的调用者 → 同一句
--   E  持两个码的人定价 → 过一条 purchase 分录、一行 price_history
--   F  ★ 三扇侧门:直连插 price_history → RLS 拒;以 authenticated 直调 reprice_inbound_batch → 42501;
--        reverse_journal_entry 冲 purchase 分录 → JE_REVERSE_USE_SOURCE_PATH|…|purchase
--   G  ★ 定价公式按行遮:只持采购码的人看得见采购公式的 TC、看不见销售公式的;只持 view_prices 的人
--        反过来;计价器对销售公式问 view_prices
--   H  ★ 清单对总账按边问码:只持 view_prices 的人 AP 那边 PRICES_RESTRICTED、AR 那边不拒;
--        只持采购码的人反过来
--   I  role_can_see_amounts:一个角色只持其中一个价格码 → false;两个都持 → true
--   J  ★ 故障注入:把 price_history 那条 INSERT 策略放回去,F 那一次直连插入就插得进 —— 拿掉它是承重的
--
-- 自带数据(README 第 2 条);锁期自己设(README 第 4 条);本位币定价,不借线上的牌价。
-- 【SET CONSTRAINTS ALL IMMEDIATE】放在末尾(借贷平衡是 DEFERRABLE 的,fixture 104 同款)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_wh    uuid := gen_random_uuid();   -- inbound.edit + 采购码:今天的仓库
    u_fin   uuid := gen_random_uuid();   -- price_receipts + 两个价格码 + inbound / finance
    u_blind uuid := gen_random_uuid();   -- price_receipts + inbound.edit,【不】持采购码
    u_sale  uuid := gen_random_uuid();   -- view_prices + finance.view + pricing.view + inbound.view,【不】持采购码
    u_prc   uuid := gen_random_uuid();   -- 采购码 + finance.view + pricing.view,【不】持 view_prices
    r_wh uuid; r_fin uuid; r_blind uuid; r_sale uuid; r_prc uuid;
    v_base text; v_sup uuid; v_mat uuid; v_b uuid; v_b2 uuid; v_n int; v_n0 int; v_msg text; v_denied boolean;
    v_res jsonb; v_je uuid; v_je_code text; v_f_sale uuid; v_f_buy uuid; v_tc numeric; v_side jsonb;
    rep jsonb := '{}'::jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ A · 引导 ══════════════
    SELECT string_agg(r.code, ', ') INTO v_msg FROM roles r
     WHERE EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id AND rp.permission_code = 'data.view_prices')
       AND NOT EXISTS (SELECT 1 FROM role_permissions rp WHERE rp.role_id = r.id
                        AND rp.permission_code = 'data.view_purchase_prices');
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 219A1 失败:这些角色持 view_prices 却不持采购码(谁都不该少看一格):%', v_msg; END IF;
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                    WHERE r.code = 'warehouse' AND rp.permission_code = 'data.view_purchase_prices')
       OR EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                   WHERE r.code = 'warehouse' AND rp.permission_code IN ('data.view_prices', 'action.price_receipts'))
       OR NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                       WHERE r.code = 'finance' AND rp.permission_code = 'action.price_receipts') THEN
        RAISE EXCEPTION 'FIXTURE 219A2 失败:引导里仓库应当只持采购码、不持 view_prices 与 price_receipts;财务应当持 price_receipts'; END IF;
    rep := rep || jsonb_build_object('A_bootstrap', 'ok');

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at)
    VALUES (u_wh, now()), (u_fin, now()), (u_blind, now()), (u_sale, now()), (u_prc, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx219-wh','f','f',true)    RETURNING id INTO r_wh;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx219-fin','f','f',true)   RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx219-blind','f','f',true) RETURNING id INTO r_blind;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx219-sale','f','f',true)  RETURNING id INTO r_sale;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx219-prc','f','f',true)   RETURNING id INTO r_prc;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_wh, 'module.inbound.edit'), (r_wh, 'module.inbound.view'), (r_wh, 'data.view_purchase_prices'),
        (r_fin, 'action.price_receipts'), (r_fin, 'data.view_purchase_prices'), (r_fin, 'data.view_prices'),
        (r_fin, 'module.inbound.edit'), (r_fin, 'module.inbound.view'),
        (r_fin, 'module.finance.edit'), (r_fin, 'module.finance.view'),
        (r_blind, 'action.price_receipts'), (r_blind, 'module.inbound.edit'), (r_blind, 'module.inbound.view'),
        (r_sale, 'data.view_prices'), (r_sale, 'module.finance.view'), (r_sale, 'module.pricing.view'),
        (r_sale, 'module.inbound.view'),
        (r_prc, 'data.view_purchase_prices'), (r_prc, 'module.finance.view'), (r_prc, 'module.pricing.view');
    INSERT INTO user_roles (user_id, role_id)
    VALUES (u_wh, r_wh), (u_fin, r_fin), (u_blind, r_blind), (u_sale, r_sale), (u_prc, r_prc);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX219-S', 'fixture 219 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX219-M', 'fixture 219 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    -- 一张【已定价】的收货(属主路径直写;价格守卫只挡 UPDATE)与一张未定价的
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZFIX219-IB1', v_mat, v_sup, 10, 10, CURRENT_DATE, 5, 'other', 'fixture 219 自带数据') RETURNING id INTO v_b;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
                                 arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZFIX219-IB2', v_mat, v_sup, 10, 10, CURRENT_DATE, 'other', 'fixture 219 自带数据') RETURNING id INTO v_b2;
    INSERT INTO pricing_formulas (name, direction, treatment_charge_usd_per_tonne)
    VALUES ('fixture 219 sale', 'sale', 111) RETURNING id INTO v_f_sale;
    INSERT INTO pricing_formulas (name, direction, treatment_charge_usd_per_tonne)
    VALUES ('fixture 219 purchase', 'purchase', 222) RETURNING id INTO v_f_buy;

    -- ══════════════ B · 可见性按侧分 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_wh), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT unit_price INTO v_tc FROM inbound_batches_masked WHERE id = v_b;
    EXECUTE 'RESET ROLE';
    IF v_tc IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'FIXTURE 219B1 失败:只持采购码的人应当读得到收货单价 5,实得 %', v_tc; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_sale), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT unit_price INTO v_tc FROM inbound_batches_masked WHERE id = v_b;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    IF v_n <> 1 OR v_tc IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 219B2 失败:只持 view_prices 的人应当看得见这一行、单价为 NULL(受限),实得 % 行 / %', v_n, v_tc; END IF;
    rep := rep || jsonb_build_object('B_visibility_by_side', 'ok');

    -- ══════════════ C · 今天的仓库定不了价 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_wh), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_msg := NULL;
    BEGIN PERFORM set_inbound_unit_price(v_b2, 7, v_base);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 219C1 失败:仓库定价应当按名拒 PERMISSION_DENIED|action.price_receipts,实得 %', COALESCE(v_msg, '(成功了)'); END IF;
    v_msg := NULL;
    BEGIN PERFORM reprice_from_committed_terms(v_b2, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 219C2 失败:仓库按已承诺条款改价应当按名拒,实得 %', COALESCE(v_msg, '(成功了)'); END IF;
    SELECT count(*) INTO v_n0 FROM inbound_batches WHERE supplier_id = v_sup;
    v_msg := NULL;
    BEGIN
        PERFORM create_inbound_batch(v_mat, v_sup, 3, 'kg', CURRENT_DATE, '待加工', 9, 'fixture 219 C3',
            p_source_reason_code => 'other', p_source_reason_note => 'fixture 219 自带数据', p_currency => v_base);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    SELECT count(*) INTO v_n FROM inbound_batches WHERE supplier_id = v_sup;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|action.price_receipts' OR v_n <> v_n0 THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 219C3 失败:仓库建单带价应当按名拒且一行不落,实得 % / 批次 % → %', COALESCE(v_msg, '(成功了)'), v_n0, v_n; END IF;
    v_res := create_inbound_batch(v_mat, v_sup, 3, 'kg', CURRENT_DATE, '待加工', NULL, 'fixture 219 C4',
        p_source_reason_code => 'other', p_source_reason_note => 'fixture 219 自带数据');
    EXECUTE 'RESET ROLE';
    IF v_res->>'batch_id' IS NULL OR v_res->'pricing' <> 'null'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 219C4 失败:仓库不带价建单应当照成,实得 %', v_res; END IF;
    rep := rep || jsonb_build_object('C_warehouse_cannot_price', 'ok');

    -- ══════════════ D · 看不见价格的人不能定价 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_blind), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_msg := NULL;
    BEGIN PERFORM set_inbound_unit_price(v_b2, 7, v_base);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|data.view_purchase_prices' THEN
        RAISE EXCEPTION 'FIXTURE 219D1 失败:持 price_receipts 却看不见采购价的人定价应当按名拒 data.view_purchase_prices,实得 %', COALESCE(v_msg, '(成功了)'); END IF;
    -- 引擎本身(以属主身份调,像 apply_assay_result 那样),调用者仍是 u_blind
    v_msg := NULL;
    BEGIN PERFORM reprice_inbound_batch(v_b2, 7, v_base, NULL, 'fixture 219 D2');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|data.view_purchase_prices' THEN
        RAISE EXCEPTION 'FIXTURE 219D2 失败:定价引擎对看不见采购价的调用者应当按名拒,实得 %', COALESCE(v_msg, '(成功了)'); END IF;
    rep := rep || jsonb_build_object('D_cannot_see_cannot_price', 'ok');

    -- ══════════════ E · 财务定价 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := set_inbound_unit_price(v_b2, 7, v_base);
    EXECUTE 'RESET ROLE';
    SELECT id, code INTO v_je, v_je_code FROM journal_entries WHERE source_type = 'purchase' AND source_id = v_b2;
    IF v_je IS NULL OR (SELECT count(*) FROM price_history WHERE inbound_batch_id = v_b2 AND new_unit_price = 7) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 219E 失败:财务定价应当过一条 purchase 分录、留一行改价历史,实得 %', v_res; END IF;
    rep := rep || jsonb_build_object('E_finance_prices', v_je_code);

    -- ══════════════ F · 三扇侧门 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN
        INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate)
        VALUES (v_b2, 7, 1, v_base, 1, 1);
    EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 219F1 失败:直连插得进一行改价历史 —— 侧门 (a) 没关'; END IF;
    v_denied := false;
    BEGIN PERFORM reprice_inbound_batch(v_b2, 8, v_base, NULL, 'fixture 219 F2');
    EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
    IF NOT v_denied THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 219F2 失败:authenticated 直调得了定价引擎 —— 侧门 (c) 没关'; END IF;
    v_msg := NULL;
    BEGIN PERFORM reverse_journal_entry(v_je, CURRENT_DATE, 'fixture 219 F3');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg IS DISTINCT FROM format('JE_REVERSE_USE_SOURCE_PATH|%s|purchase', v_je_code) THEN
        RAISE EXCEPTION 'FIXTURE 219F3 失败:冲销收货定价分录应当按名拒,实得 %', COALESCE(v_msg, '(成功了)'); END IF;
    rep := rep || jsonb_build_object('F_side_doors', 'ok');

    -- ══════════════ G · 定价公式按行遮 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_prc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF (SELECT treatment_charge_usd_per_tonne FROM pricing_formulas_masked WHERE id = v_f_buy) IS DISTINCT FROM 222
       OR (SELECT treatment_charge_usd_per_tonne FROM pricing_formulas_masked WHERE id = v_f_sale) IS NOT NULL THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 219G1 失败:只持采购码的人应当看得见采购公式的 TC、看不见销售公式的'; END IF;
    v_msg := NULL;
    BEGIN PERFORM calculate_metal_price(v_f_sale, '[]'::jsonb, 1000, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    EXECUTE 'RESET ROLE';
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|data.view_prices' THEN
        RAISE EXCEPTION 'FIXTURE 219G2 失败:只持采购码的人用计价器算销售公式应当按名拒 data.view_prices,实得 %', COALESCE(v_msg, '(过了门)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_sale), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF (SELECT treatment_charge_usd_per_tonne FROM pricing_formulas_masked WHERE id = v_f_sale) IS DISTINCT FROM 111
       OR (SELECT treatment_charge_usd_per_tonne FROM pricing_formulas_masked WHERE id = v_f_buy) IS NOT NULL THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'FIXTURE 219G3 失败:只持 view_prices 的人应当看得见销售公式的 TC、看不见采购公式的'; END IF;
    EXECUTE 'RESET ROLE';
    rep := rep || jsonb_build_object('G_formulas_by_row', 'ok');

    -- ══════════════ H · 清单对总账按边问码 ══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_sale), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT string_agg((s->>'side') || '=' || COALESCE(s->>'refusal', 'answered'), ' ' ORDER BY s->>'side') INTO v_msg
      FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s;
    EXECUTE 'RESET ROLE';
    IF v_msg IS DISTINCT FROM 'ap=PRICES_RESTRICTED ar=answered' THEN
        RAISE EXCEPTION 'FIXTURE 219H1 失败:只持 view_prices 的人应当 AP 受限、AR 答得上,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_prc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT string_agg((s->>'side') || '=' || COALESCE(s->>'refusal', 'answered'), ' ' ORDER BY s->>'side') INTO v_msg
      FROM jsonb_array_elements(list_ledger_reconciliation()->'sides') s;
    EXECUTE 'RESET ROLE';
    IF v_msg IS DISTINCT FROM 'ap=answered ar=PRICES_RESTRICTED' THEN
        RAISE EXCEPTION 'FIXTURE 219H2 失败:只持采购码的人应当 AP 答得上、AR 受限,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('H_list_vs_ledger_by_side', 'ok');

    -- ══════════════ I · 审批人看得见金额 = 两个价格码都有 ══════════════
    IF role_can_see_amounts('fx219-sale') OR role_can_see_amounts('fx219-prc') OR NOT role_can_see_amounts('fx219-fin') THEN
        RAISE EXCEPTION 'FIXTURE 219I 失败:role_can_see_amounts 应当只对两个价格码都持的角色为真'; END IF;
    rep := rep || jsonb_build_object('I_approver_sees_amounts', 'ok');

    -- ══════════════ J · 故障注入:把 INSERT 策略放回去 ══════════════
    EXECUTE $p$CREATE POLICY "fx219 injected insert" ON public.price_history AS PERMISSIVE FOR INSERT TO authenticated
               WITH CHECK (has_permission('module.inbound.edit'::text))$p$;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false;
    BEGIN
        INSERT INTO price_history (inbound_batch_id, old_unit_price, new_unit_price, currency, original_price, fx_rate)
        VALUES (v_b2, 7, 1, v_base, 1, 1);
    EXCEPTION WHEN insufficient_privilege THEN v_denied := true; END;
    EXECUTE 'RESET ROLE';
    EXECUTE 'DROP POLICY "fx219 injected insert" ON public.price_history';
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 219J 失败:注入没有生效 —— 放回 INSERT 策略之后直连插入仍被拒,F1 钉的就不是那条策略'; END IF;
    rep := rep || jsonb_build_object('J_policy_drop_is_load_bearing', true);

    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE NOTICE 'FIXTURE 219 全部通过 %', rep::text;
END $$;
ROLLBACK;

-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 261 —— 一件化验争议挡住定价与结算、点名哪一份说了算而什么都不应用;仲裁费付给实验室的那一户;每一次费用冲销说得出为什么
--   (MES-6a-1,2026-10-09;MES-0 Q62–Q64;MES-6a Step 0 Q16–Q24 · Q33–Q37 · Q42,Tim 照推荐裁定)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   OPEN   立案:module.quality.edit(没有 → PERMISSION_DENIED);理由必填;出具方按名核对(ours / counterparty);两份必须同一批;
--          一批同时一件开着的;买方的容差与费用规则在案为空(limit not set · Not yet set)
--   HOLD   进料(Q18 A + C):开着时 apply_assay_result 与 preview_assay_price 按名拒、【同一句】(fixture 40 的规矩);
--          手工定价与按已承诺条款改价照提照批(过账);一张在争议之前就在等的化验申请,CFO 批准那一刻按名拒(什么都不落);
--          撤回之后应用放开,化验申请照常批得下来
--   RESOLVE 结案:action.apply_assay(没有 → PERMISSION_DENIED,质量编辑码不够);说明必填;说了算的那一份必须是同一批的;
--          ★ 结案【什么都不应用】—— 批次含量、化验的应用与取代、定价申请、分录、单价逐字未变;之后挡着的那张申请批得下来;
--          结案 / 撤回过的不能再结 / 再撤
--   SELL   卖方(Q21):指了销售单 → 容差与仲裁费规则从那张单的合同副本抄进来;开着时 sale_settlement_compute 按名拒;撤回之后照常算
--   DISAGREE 卖方提示(Q17):一批产出批两方结果差得超过合同容差、没有争议 → assay_results_disagree 一行(质量查看码);立了争议 → 消失;
--          买方两份对不上 → 没有这一行(买方合同没有容差)
--   D4     应用一份对手方 / 仲裁的结果【不】把我们的标成 superseded;再应用一份我们的 → 只取代我们的上一份(进料与产出两侧)
--   FEE    实验室指着一户供应商(字典编辑码,直连写);仲裁费是一张普通的未付费用单,付给那一户;没记仲裁结果 / 实验室没指供应商 /
--          费用单的供应商不对 → 按名拒;挂上之后再挂 → 按名拒;那一户没批准 → 付款申请按名拒(PAYMENT_REQUEST_SUPPLIER_BLOCKED);
--          对手方那一份按规则(equal → 50%)算出来,金额只给财务查看码(其余 NULL + fee_restricted);每一步之后应付清单 = 总账、0.00
--   V14    一份有过争议、而仲裁费规则为空的合同 → 待补的值 V14 一行(客户查看码);给了规则 → 消失
--   F3     普通费用单:reverse_expense 不给理由 / 空白 → EXPENSE_REVERSAL_REASON_REQUIRED|单号(码之后第一件事;没有码先撞码);
--          reverse_expense_internal 自己再拒空白;带理由 → 写在原单上(去头尾空白)、时刻与人同一步,镜像单 notes 只剩 'REVERSAL: 单号';
--          行守卫:直连 posted → reversed 不带理由按名拒;冲过的那一行理由改不了;一张 posted 的行带着理由插不进来(CHECK)
--
-- 自带数据(README 第 2 条);锁期、审批策略、牌价与行情自己设(README 第 4、5 条)。以 postgres 跑;员工的调用切成 authenticated + JWT。
-- 【数怎么来的】进料:ni 行情 15,000 USD/t、可付 70%、处理费 200 USD/t、USD tt_sell 1.26 → 化验 ni 30% 的批次 100 kg:
--   (100×0.30×0.70×15 − 100/1000×200)/100 = 2.95 USD/kg → 3.717 本位币(fixture 220 I 臂的同一组数)。
--   卖方:fixture 149 的行情与条款(LME 9 月每个交易日 10,000;ni 可付 70%)—— 本支只断言结算【算得出 / 被拒】,不重证它的数。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f261_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f261_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f261_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f261_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f261_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_prev, ''), true);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f261_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx261-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx261-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

-- 应付清单 = 总账,两边 unexplained 0.00(以全码那个人的会话读 —— 那支函数按读者的码过滤)
CREATE FUNCTION pg_temp.f261_agree(p_user uuid, p_step text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb;
BEGIN
    v := pg_temp.f261_get(p_user, $q$SELECT list_ledger_reconciliation()$q$);
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'FIXTURE 261 AGREE %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'FIXTURE 261 AGREE %: % side list % / ledger % / unexplained % (refusal %)', p_step, s ->> 'side',
                s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base', s ->> 'refusal';
        END IF;
    END LOOP;
END;
$f$;

-- 一批的"状态指纹":含量、化验的应用与取代、定价申请、单价、定价状态 —— 结案前后逐字比
CREATE FUNCTION pg_temp.f261_state(p_batch uuid) RETURNS text
LANGUAGE sql AS $f$
    SELECT md5(concat_ws('|',
        (SELECT string_agg(metal || ':' || content_pct || ':' || COALESCE(source_assay_id::text, '-'), ',' ORDER BY metal) FROM inbound_batch_metals WHERE inbound_batch_id = p_batch),
        (SELECT string_agg(code || ':' || (applied_at IS NOT NULL) || ':' || COALESCE(superseded_by::text, '-'), ',' ORDER BY code) FROM assay_results WHERE inbound_batch_id = p_batch),
        (SELECT string_agg(label || ':' || status, ',' ORDER BY label) FROM receipt_price_requests WHERE inbound_batch_id = p_batch),
        (SELECT COALESCE(unit_price::text, '-') || ':' || pricing_status FROM inbound_batches WHERE id = p_batch),
        (SELECT count(*)::text FROM journal_entries)))
$f$;

DO $$
DECLARE
    u_all uuid; u_fin uuid; u_cfo uuid; u_l1 uuid; u_cto uuid; u_qe uuid; u_qv uuid; u_fv uuid; u_cust uuid; u_iv uuid;
    v_today date := CURRENT_DATE; v_base text;
    v_sup uuid; v_lab_sup uuid; v_other_sup uuid; v_mat uuid; v_formula uuid; v_cust uuid;
    b1 uuid; b2 uuid; b3 uuid; b4 uuid; ob1 uuid; ob2 uuid; ob3 uuid;
    a1 uuid; c1 uuid; a2 uuid; c2 uuid; x1 uuid; o1 uuid; p1 uuid; o2 uuid; u1 uuid;
    oa uuid; oc uuid; ou uuid; oa2 uuid; oc2 uuid; ua uuid; us uuid; d4a uuid; d4c uuid; d4o2 uuid; d4u uuid;
    con1 uuid; con2 uuid; so1 uuid; so2 uuid; sol uuid;
    d1 uuid; d2 uuid; d3 uuid; d4 uuid; dS uuid;
    q uuid; q2 uuid; e_fee uuid; e_other uuid; e_rev uuid; e_g uuid;
    v_j jsonb; v_msg text; v_msg2 text; v_n bigint; v_before text; v_je0 bigint; v_m30 jsonb; v_m33 jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    v_m30 := jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 30));
    v_m33 := jsonb_build_array(jsonb_build_object('metal', 'ni', 'content_pct', 33));
    u_all  := pg_temp.f261_user('all', (SELECT array_agg(code) FROM permissions));
    u_fin  := pg_temp.f261_user('fin', ARRAY['action.price_receipts', 'data.view_purchase_prices', 'data.view_prices', 'module.inbound.edit',
                                             'module.inbound.view', 'module.finance.view', 'module.finance.edit', 'module.suppliers.view']);
    u_cfo  := pg_temp.f261_user('cfo', ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices', 'module.finance.view',
                                             'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view', 'module.pricing.view',
                                             'module.suppliers.view', 'module.customers.view']);
    u_l1   := pg_temp.f261_user('l1', ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices', 'module.finance.view',
                                            'module.hr.view', 'data.view_pay', 'module.inbound.view']);
    u_cto  := pg_temp.f261_user('cto', ARRAY['action.apply_assay', 'module.inbound.edit', 'module.inbound.view', 'module.output.edit',
                                             'module.output.view', 'data.view_purchase_prices', 'module.quality.view']);
    u_qe   := pg_temp.f261_user('qe', ARRAY['module.quality.view', 'module.quality.edit']);
    u_qv   := pg_temp.f261_user('qv', ARRAY['module.quality.view']);
    u_fv   := pg_temp.f261_user('fv', ARRAY['module.quality.view', 'module.finance.view']);
    u_cust := pg_temp.f261_user('cust', ARRAY['module.customers.view']);
    u_iv   := pg_temp.f261_user('iv', ARRAY['module.inbound.view']);

    -- ══════════════ 布景 ══════════════
    PERFORM pg_temp.f261_as(NULL);
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ261-S', 'f261 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    -- 实验室的那一户:【没批准】(draft)—— FEE 臂的最后一格靠它
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ261-LABS', 'f261 umpire lab ltd', 'SG', 'draft', 'service_vendor') RETURNING id INTO v_lab_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ261-OTHER', 'f261 someone else', 'SG', 'active', 'service_vendor') RETURNING id INTO v_other_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ261-BM', 'f261 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order) VALUES
        ('ZZ261-OURS', 'f261 our lab', 'f261 我方', true, 980), ('ZZ261-BUY', 'f261 their lab', 'f261 对方', true, 981),
        ('ZZ261-UMP', 'f261 umpire lab', 'f261 仲裁', true, 982);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note) VALUES
        ('ZZ261-B1', v_mat, v_sup, 100, 100, 'kg', v_today, 'other', 'fixture 261'),
        ('ZZ261-B2', v_mat, v_sup, 100, 100, 'kg', v_today, 'other', 'fixture 261'),
        ('ZZ261-B3', v_mat, v_sup, 100, 100, 'kg', v_today, 'other', 'fixture 261'),
        ('ZZ261-B4', v_mat, v_sup, 100, 100, 'kg', v_today, 'other', 'fixture 261');
    SELECT id INTO b1 FROM inbound_batches WHERE code = 'ZZ261-B1';
    SELECT id INTO b2 FROM inbound_batches WHERE code = 'ZZ261-B2';
    SELECT id INTO b3 FROM inbound_batches WHERE code = 'ZZ261-B3';
    SELECT id INTO b4 FROM inbound_batches WHERE code = 'ZZ261-B4';
    -- 牌价、行情、公式;B1 / B2 的承诺副本
    UPDATE fx_rates SET deleted_at = now() WHERE currency = 'USD' AND rate_date = v_today AND rate_type = 'tt_sell';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit) VALUES ('USD', v_today, 'tt_sell', 1.26);
    DELETE FROM metal_prices WHERE metal = 'ni' AND price_date = v_today;
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source) VALUES ('ni', v_today, 15000, 'broker_quote');
    INSERT INTO pricing_formulas (code, name, direction, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct, is_active)
    VALUES ('', 'Fixture Formula 261', 'purchase', 'spot', 200, 0, true) RETURNING id INTO v_formula;
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct) VALUES (v_formula, 'ni', 70);
    PERFORM commit_pricing_terms(v_formula, NULL, b1);
    PERFORM commit_pricing_terms(v_formula, NULL, b2);
    -- 审批:一级 fx261-l1、二级 fx261-cfo;打开
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx261-l1', approval_level2_role_code = 'fx261-cfo', approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '', true);

    -- 化验(都由 cto 记 —— 记录归 inbound.edit / output.edit)
    PERFORM pg_temp.f261_as(u_cto);
    a1 := (record_assay_result(p_assay_date => v_today, p_metals => v_m30, p_lab_name => 'ZZ261-OURS', p_inbound_batch_id => b1,
                               p_weight_basis => 'as_received', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    c1 := (record_assay_result(p_assay_date => v_today, p_metals => v_m33, p_lab_name => 'ZZ261-BUY', p_inbound_batch_id => b1,
                               p_weight_basis => 'as_received', p_result_party => 'counterparty') ->> 'assay_result_id')::uuid;
    a2 := (record_assay_result(p_assay_date => v_today, p_metals => v_m30, p_lab_name => 'ZZ261-OURS', p_inbound_batch_id => b2,
                               p_weight_basis => 'as_received', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    c2 := (record_assay_result(p_assay_date => v_today, p_metals => v_m33, p_lab_name => 'ZZ261-BUY', p_inbound_batch_id => b2,
                               p_weight_basis => 'as_received', p_result_party => 'counterparty') ->> 'assay_result_id')::uuid;
    x1 := (record_assay_result(p_assay_date => v_today, p_metals => v_m33, p_lab_name => 'ZZ261-UMP', p_inbound_batch_id => b2,
                               p_weight_basis => 'as_received', p_result_party => 'umpire') ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.f261_as(NULL);
    PERFORM pg_temp.f261_agree(u_all, 'start');

    -- ══════════════ OPEN ══════════════
    RAISE NOTICE 'fixture 261 · OPEN';
    v_msg := pg_temp.f261_do(u_cto, format($q$SELECT open_assay_dispute(%L, %L, 'their figure is 3 points higher')$q$, a1, c1));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.quality.edit%' THEN RAISE EXCEPTION 'FIXTURE 261 OPEN: opening needs module.quality.edit, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT open_assay_dispute(%L, %L, '   ')$q$, a1, c1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 261 OPEN: a reason is required, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'swapped')$q$, c1, a1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_PARTY_MISMATCH|%|counterparty|ours' THEN RAISE EXCEPTION 'FIXTURE 261 OPEN: parties are checked by name, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'two batches')$q$, a1, c2));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_NOT_SAME_BATCH|%' THEN RAISE EXCEPTION 'FIXTURE 261 OPEN: both results must be on one batch, got %', v_msg; END IF;
    v_j := pg_temp.f261_get(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'their figure is 3 points higher')$q$, a1, c1));
    d1 := (v_j ->> 'dispute_id')::uuid;
    IF (v_j ->> 'batch_code') <> 'ZZ261-B1' OR (v_j ->> 'limit_pct_at') IS NOT NULL OR (v_j ->> 'fee_rule_at') IS NOT NULL
       OR (SELECT status FROM assay_disputes WHERE id = d1) <> 'open' THEN
        RAISE EXCEPTION 'FIXTURE 261 OPEN: a buy-side dispute opens with no limit and no fee rule in force (limit not set), got %', v_j; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'again')$q$, a1, c1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_ALREADY_OPEN|ZZ261-B1%' THEN RAISE EXCEPTION 'FIXTURE 261 OPEN: one open dispute per batch, got %', v_msg; END IF;

    -- ══════════════ HOLD ══════════════
    RAISE NOTICE 'fixture 261 · HOLD';
    v_msg := pg_temp.f261_do(u_cto, format($q$SELECT apply_assay_result(%L)$q$, a1));
    v_msg2 := pg_temp.f261_do(u_cto, format($q$SELECT preview_assay_price(%L, %L::jsonb, CURRENT_DATE)$q$, b1, v_m30));
    IF v_msg NOT LIKE format('ASSAY_DISPUTE_OPEN|ZZ261-B1|%s', d1) OR v_msg <> v_msg2 THEN
        RAISE EXCEPTION 'FIXTURE 261 HOLD: apply and preview refuse with the same named code while the dispute is open, got apply «%» preview «%»', v_msg, v_msg2; END IF;
    IF (SELECT applied_at FROM assay_results WHERE id = a1) IS NOT NULL OR EXISTS (SELECT 1 FROM inbound_batch_metals WHERE inbound_batch_id = b1) THEN
        RAISE EXCEPTION 'FIXTURE 261 HOLD: a refused apply leaves nothing behind'; END IF;
    -- 手工定价照提照批(一个暂定价不是最终改价 —— Q62)
    v_msg := pg_temp.f261_do(u_fin, format($q$SELECT set_inbound_unit_price(%L, 2, 'USD')$q$, b1));
    SELECT id INTO q FROM receipt_price_requests WHERE inbound_batch_id = b1 AND status = 'submitted' AND source = 'manual';
    v_msg2 := pg_temp.f261_do(u_cfo, format($q$SELECT decide_receipt_price_request(%L, true)$q$, q));
    IF v_msg <> 'OK' OR v_msg2 <> 'OK' OR (SELECT unit_price FROM inbound_batches WHERE id = b1) <> 2.52 THEN
        RAISE EXCEPTION 'FIXTURE 261 HOLD: manual repricing still submits and posts while a dispute is open (2 USD × 1.26 = 2.52), got % / % / %',
            v_msg, v_msg2, (SELECT unit_price FROM inbound_batches WHERE id = b1); END IF;
    PERFORM pg_temp.f261_agree(u_all, 'manual priced under dispute');
    -- 按已承诺条款改价照提照批:含量先手工记(ni 30)
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (b1, 'ni', 30, 'manual');
    v_msg := pg_temp.f261_do(u_fin, format($q$SELECT reprice_from_committed_terms(%L, CURRENT_DATE)$q$, b1));
    SELECT id INTO q FROM receipt_price_requests WHERE inbound_batch_id = b1 AND status = 'submitted' AND source = 'committed_terms';
    v_msg2 := pg_temp.f261_do(u_cfo, format($q$SELECT decide_receipt_price_request(%L, true)$q$, q));
    IF v_msg <> 'OK' OR v_msg2 <> 'OK' OR (SELECT unit_price FROM inbound_batches WHERE id = b1) <> 3.717 THEN
        RAISE EXCEPTION 'FIXTURE 261 HOLD: committed-terms repricing still submits and posts while a dispute is open (2.95 × 1.26 = 3.717), got % / % / %',
            v_msg, v_msg2, (SELECT unit_price FROM inbound_batches WHERE id = b1); END IF;
    PERFORM pg_temp.f261_agree(u_all, 'committed terms priced under dispute');
    -- 一张在争议之前就在等的化验申请(B2):批准那一刻按名拒,什么都不落
    v_j := pg_temp.f261_get(u_cto, format($q$SELECT apply_assay_result(%L)$q$, a2));
    q2 := (v_j -> 'price_request' ->> 'request_id')::uuid;
    IF (v_j -> 'price_request' ->> 'status') <> 'submitted' THEN RAISE EXCEPTION 'FIXTURE 261 HOLD: setup — the assay request waits for the CFO, got %', v_j; END IF;
    d2 := (pg_temp.f261_get(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'opened while the price waits')$q$, a2, c2)) ->> 'dispute_id')::uuid;
    v_je0 := (SELECT count(*) FROM journal_entries);
    v_msg := pg_temp.f261_do(u_cfo, format($q$SELECT decide_receipt_price_request(%L, true)$q$, q2));
    IF v_msg NOT LIKE format('ASSAY_DISPUTE_OPEN|ZZ261-B2|%s', d2) OR (SELECT status FROM receipt_price_requests WHERE id = q2) <> 'submitted'
       OR (SELECT unit_price FROM inbound_batches WHERE id = b2) IS NOT NULL OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 261 HOLD: an assay-sourced request already waiting cannot be approved while a dispute is open, and nothing posts, got %', v_msg; END IF;
    -- 撤回之后放开(B1):应用照常,化验申请照常批
    v_msg := pg_temp.f261_do(u_qv, format($q$SELECT withdraw_assay_dispute(%L, 'agreed')$q$, d1));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.quality.edit%' THEN RAISE EXCEPTION 'FIXTURE 261 HOLD: withdrawing needs module.quality.edit, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT withdraw_assay_dispute(%L, '  ')$q$, d1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 261 HOLD: withdrawing needs a reason, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT withdraw_assay_dispute(%L, 'Supplier accepted our figure')$q$, d1));
    IF v_msg <> 'OK' OR (SELECT (status, withdraw_reason, withdrawn_by) FROM assay_disputes WHERE id = d1)
         IS DISTINCT FROM ('withdrawn'::text, 'Supplier accepted our figure'::text, u_qe) THEN
        RAISE EXCEPTION 'FIXTURE 261 HOLD: withdrawn with its reason and who, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT withdraw_assay_dispute(%L, 'again')$q$, d1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_NOT_OPEN|withdrawn%' THEN RAISE EXCEPTION 'FIXTURE 261 HOLD: a withdrawn dispute cannot be withdrawn again, got %', v_msg; END IF;
    v_j := pg_temp.f261_get(u_cto, format($q$SELECT apply_assay_result(%L)$q$, a1));
    q := (v_j -> 'price_request' ->> 'request_id')::uuid;
    v_msg := pg_temp.f261_do(u_cfo, format($q$SELECT decide_receipt_price_request(%L, true)$q$, q));
    IF v_msg <> 'OK' OR (SELECT pricing_status FROM inbound_batches WHERE id = b1) <> 'final' THEN
        RAISE EXCEPTION 'FIXTURE 261 HOLD: after the withdrawal the assay applies and its request posts (final), got %', v_msg; END IF;
    PERFORM pg_temp.f261_agree(u_all, 'assay priced after withdrawal');

    -- ══════════════ RESOLVE ══════════════
    RAISE NOTICE 'fixture 261 · RESOLVE';
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT resolve_assay_dispute(%L, %L, 'umpire governs')$q$, d2, x1));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.apply_assay%' THEN RAISE EXCEPTION 'FIXTURE 261 RESOLVE: resolving needs action.apply_assay (quality edit is not enough), got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_cto, format($q$SELECT resolve_assay_dispute(%L, %L, ' ')$q$, d2, x1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_NOTE_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 261 RESOLVE: a note is required, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_cto, format($q$SELECT resolve_assay_dispute(%L, %L, 'wrong batch')$q$, d2, a1));
    IF v_msg NOT LIKE 'ASSAY_NOT_FOR_BATCH|%' THEN RAISE EXCEPTION 'FIXTURE 261 RESOLVE: the governing result must be on the disputed batch, got %', v_msg; END IF;
    v_before := pg_temp.f261_state(b2);
    v_msg := pg_temp.f261_do(u_cto, format($q$SELECT resolve_assay_dispute(%L, %L, 'The umpire''s 33%% governs, per the contract')$q$, d2, x1));
    IF v_msg <> 'OK' OR (SELECT (status, governing_assay_id, resolved_by) FROM assay_disputes WHERE id = d2)
         IS DISTINCT FROM ('resolved'::text, x1, u_cto) THEN
        RAISE EXCEPTION 'FIXTURE 261 RESOLVE: resolved, naming the umpire result, by the assay applier, got %', v_msg; END IF;
    IF pg_temp.f261_state(b2) <> v_before OR (SELECT applied_at FROM assay_results WHERE id = x1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 261 RESOLVE: resolving applies NOTHING — content, applications, requests, price and the ledger are unchanged'; END IF;
    v_msg := pg_temp.f261_do(u_cto, format($q$SELECT resolve_assay_dispute(%L, %L, 'twice')$q$, d2, x1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_NOT_OPEN|resolved%' THEN RAISE EXCEPTION 'FIXTURE 261 RESOLVE: a resolved dispute cannot be resolved again, got %', v_msg; END IF;
    -- 挡着的那张申请现在批得下来(说了算的那一份照常经应用 —— 那是另一件事,不在结案里)
    v_msg := pg_temp.f261_do(u_cfo, format($q$SELECT decide_receipt_price_request(%L, true)$q$, q2));
    IF v_msg <> 'OK' OR (SELECT status FROM receipt_price_requests WHERE id = q2) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 261 RESOLVE: the held request posts once the dispute is resolved, got %', v_msg; END IF;
    PERFORM pg_temp.f261_agree(u_all, 'held request posted after resolution');

    -- ══════════════ D4 ══════════════
    RAISE NOTICE 'fixture 261 · D4';
    -- 进料(B3:没有公式 —— 应用只落含量,不提申请,专看取代链)
    PERFORM pg_temp.f261_as(u_cto);
    d4a := (record_assay_result(p_assay_date => v_today, p_metals => v_m30, p_inbound_batch_id => b3, p_weight_basis => 'as_received', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    d4c := (record_assay_result(p_assay_date => v_today, p_metals => v_m33, p_inbound_batch_id => b3, p_weight_basis => 'as_received', p_result_party => 'counterparty') ->> 'assay_result_id')::uuid;
    d4u := (record_assay_result(p_assay_date => v_today, p_metals => v_m33, p_inbound_batch_id => b3, p_weight_basis => 'as_received', p_result_party => 'umpire') ->> 'assay_result_id')::uuid;
    d4o2 := (record_assay_result(p_assay_date => v_today, p_metals => v_m30, p_inbound_batch_id => b3, p_weight_basis => 'as_received', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    PERFORM apply_assay_result(d4a);
    PERFORM apply_assay_result(d4c);
    PERFORM apply_assay_result(d4u);
    PERFORM pg_temp.f261_as(NULL);
    IF (SELECT superseded_by FROM assay_results WHERE id = d4a) IS NOT NULL OR (SELECT superseded_by FROM assay_results WHERE id = d4c) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 261 D4: applying a counterparty or umpire result never supersedes ours (inbound)'; END IF;
    PERFORM pg_temp.f261_as(u_cto);
    PERFORM apply_assay_result(d4o2);
    PERFORM pg_temp.f261_as(NULL);
    IF (SELECT superseded_by FROM assay_results WHERE id = d4a) IS DISTINCT FROM d4o2
       OR (SELECT superseded_by FROM assay_results WHERE id = d4c) IS NOT NULL OR (SELECT superseded_by FROM assay_results WHERE id = d4u) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 261 D4: a new result of ours supersedes only our previous one (inbound)'; END IF;
    -- 产出(OB3)
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ261-OB3', v_mat, 100, 100, v_today) RETURNING id INTO ob3;
    PERFORM pg_temp.f261_as(u_cto);
    oa := (record_assay_result(p_assay_date => v_today, p_metals => v_m30, p_output_batch_id => ob3, p_weight_basis => 'dry', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    oc := (record_assay_result(p_assay_date => v_today, p_metals => v_m33, p_output_batch_id => ob3, p_weight_basis => 'dry', p_result_party => 'counterparty') ->> 'assay_result_id')::uuid;
    oa2 := (record_assay_result(p_assay_date => v_today, p_metals => v_m30, p_output_batch_id => ob3, p_weight_basis => 'dry', p_result_party => 'ours') ->> 'assay_result_id')::uuid;
    PERFORM apply_output_assay(oa);
    PERFORM apply_output_assay(oc);
    PERFORM pg_temp.f261_as(NULL);
    IF (SELECT superseded_by FROM assay_results WHERE id = oa) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 261 D4: applying the counterparty result never supersedes ours (output)'; END IF;
    PERFORM pg_temp.f261_as(u_cto);
    PERFORM apply_output_assay(oa2);
    PERFORM pg_temp.f261_as(NULL);
    IF (SELECT superseded_by FROM assay_results WHERE id = oa) IS DISTINCT FROM oa2 OR (SELECT superseded_by FROM assay_results WHERE id = oc) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 261 D4: a new result of ours supersedes only our previous one (output)'; END IF;

    -- ══════════════ SELL ══════════════
    RAISE NOTICE 'fixture 261 · SELL';
    -- fixture 149 的行情与条款:LME 9 月每个交易日 10,000;ni 可付 70%,cu 1%;干基结算,我们的化验说了算;容差 0.5;仲裁费各半
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', d::date, EXTRACT(ISODOW FROM d) < 6, 'fixture 261'
      FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d
    ON CONFLICT DO NOTHING;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT 'ni', 10000, c.calendar_date, 'published_index', 'LME'
      FROM index_market_calendar c WHERE c.index_code = 'LME' AND c.is_trading_day AND c.calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'
    ON CONFLICT DO NOTHING;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ261-C', 'f261 customer', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f261 with a limit and a fee rule', DATE '2026-01-01', 'active') RETURNING id INTO con1;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (v_cust, 'offtake', 'f261 with a limit and no fee rule', DATE '2026-01-01', 'active') RETURNING id INTO con2;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (con1, 'ni', 'assay_complete', 0, 'LME', 70), (con2, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, splitting_limit_pct, sample_retention_required,
                                           refining_charge_basis, penalty_basis, arbitration_fee_rule)
    VALUES (con1, 'dry', 'ours', 0.5, false, 'none_agreed', 'none_agreed', 'equal'),
           (con2, 'dry', 'ours', 0.5, false, 'none_agreed', 'none_agreed', NULL);
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ261-SO1', v_cust, DATE '2026-06-10', v_base, 1) RETURNING id INTO so1;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ261-SO2', v_cust, DATE '2026-06-10', v_base, 1) RETURNING id INTO so2;
    PERFORM pg_temp.f261_as(u_all);
    PERFORM link_document_to_contract('sales_order', so1, con1);
    PERFORM link_document_to_contract('sales_order', so2, con2);
    PERFORM pg_temp.f261_as(NULL);
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ261-OB1', v_mat, 10000, 10000, DATE '2026-09-14') RETURNING id INTO ob1;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name)
    VALUES ('ZZ261-OB1-OURS', ob1, DATE '2026-09-15', true, 'dry', 10, 'ours', 'ZZ261-OURS') RETURNING id INTO o1;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name)
    VALUES ('ZZ261-OB1-CP', ob1, DATE '2026-09-15', true, 'dry', 10, 'counterparty', 'ZZ261-BUY') RETURNING id INTO p1;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (o1, 'ni', 20), (p1, 'ni', 20.3);
    v_msg := pg_temp.f261_do(u_all, format($q$SELECT sale_settlement_compute(%L, %L, %L)$q$, so1, ob1, o1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 261 SELL: setup — within the 0.5 limit the settlement computes, got %', v_msg; END IF;
    v_j := pg_temp.f261_get(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'buyer contests nickel', %L)$q$, o1, p1, so1));
    dS := (v_j ->> 'dispute_id')::uuid;
    IF (v_j ->> 'limit_pct_at')::numeric IS DISTINCT FROM 0.5 OR (v_j ->> 'fee_rule_at') IS DISTINCT FROM 'equal' THEN
        RAISE EXCEPTION 'FIXTURE 261 SELL: the sell-side dispute copies the limit and the fee rule from the sales order''s contract snapshot, got %', v_j; END IF;
    v_msg := pg_temp.f261_do(u_all, format($q$SELECT sale_settlement_compute(%L, %L, %L)$q$, so1, ob1, o1));
    IF v_msg NOT LIKE format('ASSAY_DISPUTE_OPEN|ZZ261-OB1|%s', dS) THEN
        RAISE EXCEPTION 'FIXTURE 261 SELL: settlement is refused by name while the dispute is open, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'x', %L)$q$, a1, c1, so1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_SALES_ORDER_NEEDS_OUTPUT_BATCH%' THEN RAISE EXCEPTION 'FIXTURE 261 SELL: a buy-side dispute names no sales order, got %', v_msg; END IF;

    -- ══════════════ FEE ══════════════
    RAISE NOTICE 'fixture 261 · FEE';
    -- 仲裁的样品与结果(都在 OB1 上)
    us := (pg_temp.f261_get(u_qe, format($q$SELECT record_sample('umpire', DATE '2026-09-16', p_output_batch_id => %L)$q$, ob1)) ->> 'sample_id')::uuid;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, moisture_pct, result_party, lab_name, sample_id)
    VALUES ('ZZ261-OB1-UMP', ob1, DATE '2026-09-20', true, 'dry', 10, 'umpire', 'ZZ261-UMP', us) RETURNING id INTO ua;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (ua, 'ni', 20.25);
    PERFORM pg_temp.f261_as(u_fin);
    e_fee := (record_expense(v_today, '6400', 1000, v_base, p_supplier_id => v_lab_sup, p_notes => 'Umpire assay fee ZZ261-OB1') ->> 'expense_id')::uuid;
    e_other := (record_expense(v_today, '6400', 300, v_base, p_supplier_id => v_other_sup, p_notes => 'Courier') ->> 'expense_id')::uuid;
    PERFORM pg_temp.f261_as(NULL);
    PERFORM pg_temp.f261_agree(u_all, 'fee expenses recorded');
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT link_dispute_fee(%L, %L)$q$, dS, e_fee));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_FEE_NO_UMPIRE_ASSAY%' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: the fee follows the umpire result''s lab — none recorded yet, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qv, format($q$SELECT record_dispute_umpire(%L, %L, %L)$q$, dS, us, ua));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.quality.edit%' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: recording the umpire needs quality edit, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT record_dispute_umpire(%L, NULL, %L)$q$, dS, o1));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_PARTY_MISMATCH|%|ours|umpire' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: the umpire result must be the umpire''s, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT record_dispute_umpire(%L, %L, %L)$q$, dS, us, ua));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: umpire sample and result recorded, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT link_dispute_fee(%L, %L)$q$, dS, e_fee));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_FEE_LAB_HAS_NO_SUPPLIER|ZZ261-UMP%' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: a lab with no supplier cannot be paid, got %', v_msg; END IF;
    -- 字典编辑码在实验室那一行上指供应商(直连写,表的写策略 module.materials.edit)
    v_msg := pg_temp.f261_do(u_qe, format($q$UPDATE laboratories SET supplier_id = %L WHERE code = 'ZZ261-UMP'$q$, v_lab_sup));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.materials.edit%' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: linking a lab to a supplier needs module.materials.edit, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_all, format($q$UPDATE laboratories SET supplier_id = %L WHERE code = 'ZZ261-UMP'$q$, v_lab_sup));
    IF v_msg <> 'OK' OR (SELECT supplier_id FROM laboratories WHERE code = 'ZZ261-UMP') IS DISTINCT FROM v_lab_sup THEN
        RAISE EXCEPTION 'FIXTURE 261 FEE: the lab now points at its supplier, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT link_dispute_fee(%L, %L)$q$, dS, e_other));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_FEE_SUPPLIER_MISMATCH|%|ZZ261-UMP' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: the fee must be owed to the lab''s supplier, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT link_dispute_fee(%L, %L)$q$, dS, e_fee));
    IF v_msg <> 'OK' OR (SELECT fee_expense_id FROM assay_disputes WHERE id = dS) IS DISTINCT FROM e_fee THEN
        RAISE EXCEPTION 'FIXTURE 261 FEE: the fee expense is linked, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_qe, format($q$SELECT link_dispute_fee(%L, %L)$q$, dS, e_other));
    IF v_msg NOT LIKE 'ASSAY_DISPUTE_FEE_ALREADY_LINKED|%' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: one fee per dispute, got %', v_msg; END IF;
    -- 对手方那一份(equal → 50%):金额只给财务查看码
    v_j := pg_temp.f261_get(u_fv, format($q$SELECT to_jsonb(r) FROM assay_dispute_rows r WHERE r.id = %L$q$, dS));
    IF (v_j ->> 'fee_amount_base')::numeric <> 1000 OR (v_j ->> 'counterparty_share_pct')::numeric <> 50
       OR (v_j ->> 'counterparty_share_base')::numeric <> 500 OR (v_j ->> 'fee_restricted')::boolean
       OR (v_j ->> 'umpire_lab_code') <> 'ZZ261-UMP' OR (v_j ->> 'max_diff_pct')::numeric <> 0.3 OR (v_j ->> 'beyond_limit')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 261 FEE: a finance reader sees the 1,000 fee and the counterparty''s 500 (equal), got %', v_j; END IF;
    v_j := pg_temp.f261_get(u_qv, format($q$SELECT to_jsonb(r) FROM assay_dispute_rows r WHERE r.id = %L$q$, dS));
    IF (v_j ->> 'fee_amount_base') IS NOT NULL OR (v_j ->> 'counterparty_share_base') IS NOT NULL OR NOT (v_j ->> 'fee_restricted')::boolean
       OR (v_j ->> 'counterparty_share_pct')::numeric <> 50 OR (v_j ->> 'fee_expense_code') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 261 FEE: without finance view the money reads Restricted (not 0), the share and the expense number stay, got %', v_j; END IF;
    IF (SELECT count(*) FROM jsonb_array_elements(pg_temp.f261_get(u_qv, format($q$SELECT jsonb_agg(to_jsonb(m)) FROM assay_dispute_metals m WHERE m.dispute_id = %L$q$, dS)))
          e WHERE e ->> 'metal' = 'ni' AND (e ->> 'ours_pct')::numeric = 20 AND (e ->> 'counterparty_pct')::numeric = 20.3
            AND (e ->> 'umpire_pct')::numeric = 20.25 AND (e ->> 'diff_pct')::numeric = 0.3 AND NOT (e ->> 'beyond_limit')::boolean) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 261 FEE: the per-metal differences are computed (ours 20 · counterparty 20.3 · umpire 20.25 · 0.3 within 0.5)'; END IF;
    -- 那一户没批准:付款申请按名拒
    v_msg := pg_temp.f261_do(u_fin, format($q$SELECT submit_payment_request(%L, 1000, %L, p_bank_account => '1000', p_planned_date => CURRENT_DATE, p_allocations => %L::jsonb)$q$,
                                         v_lab_sup, v_base, jsonb_build_array(jsonb_build_object('expense_id', e_fee, 'amount', 1000))));
    IF v_msg NOT LIKE 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|ZZ261-LABS|draft%' THEN
        RAISE EXCEPTION 'FIXTURE 261 FEE: paying the fee still needs the lab''s supplier approved, got %', v_msg; END IF;
    PERFORM pg_temp.f261_agree(u_all, 'fee linked, payment refused');
    -- 结案点名仲裁的那一份
    v_msg := pg_temp.f261_do(u_cto, format($q$SELECT resolve_assay_dispute(%L, %L, 'Umpire within the limit; umpire governs')$q$, dS, ua));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 261 FEE: resolved on the umpire, got %', v_msg; END IF;

    -- ══════════════ DISAGREE ══════════════
    RAISE NOTICE 'fixture 261 · DISAGREE';
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZ261-OB2', v_mat, 1000, 1000, DATE '2026-09-14') RETURNING id INTO ob2;
    INSERT INTO assay_results (code, output_batch_id, assay_date, is_final, weight_basis, result_party) VALUES
        ('ZZ261-OB2-OURS', ob2, DATE '2026-09-15', true, 'dry', 'ours'), ('ZZ261-OB2-CP', ob2, DATE '2026-09-16', true, 'dry', 'counterparty');
    SELECT id INTO oa FROM assay_results WHERE code = 'ZZ261-OB2-OURS';
    SELECT id INTO oc FROM assay_results WHERE code = 'ZZ261-OB2-CP';
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (oa, 'ni', 20), (oc, 'ni', 21);
    -- 这一批经一行预留挂到 SO2(容差 0.5,仲裁费规则空)—— 可售判据要一个读得到物料的会话
    PERFORM pg_temp.f261_as(u_all);
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so2, 1, v_mat, 1000, 5) RETURNING id INTO sol;
    INSERT INTO sales_order_reservations (sales_order_line_id, output_batch_id, qty, pair_id) VALUES (sol, ob2, 100, gen_random_uuid());
    PERFORM pg_temp.f261_as(NULL);
    -- 买方:B4 两份对不上(没有容差可比 —— 不会有提示)
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final, weight_basis, result_party) VALUES
        ('ZZ261-B4-OURS', b4, v_today, true, 'dry', 'ours'), ('ZZ261-B4-CP', b4, v_today, true, 'dry', 'counterparty');
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
    SELECT id, 'ni', CASE WHEN result_party = 'ours' THEN 20 ELSE 25 END FROM assay_results WHERE inbound_batch_id = b4;
    v_j := pg_temp.f261_get(u_qv, $q$SELECT jsonb_agg(jsonb_build_object('code', item_code, 'so', subject) ORDER BY item_code) FROM operations_now WHERE item_type = 'assay_results_disagree'$q$);
    IF v_j IS DISTINCT FROM '[{"so": "ZZ261-SO2", "code": "ZZ261-OB2"}]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 261 DISAGREE: exactly the sell-side batch beyond its contract''s limit is prompted (OB1 is within 0.5 and disputed; B4 is buy side), got %', v_j; END IF;
    IF (pg_temp.f261_get(u_iv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'assay_results_disagree'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 261 DISAGREE: the prompt is for quality-view holders only'; END IF;
    d3 := (pg_temp.f261_get(u_qe, format($q$SELECT open_assay_dispute(%L, %L, 'beyond the limit', %L)$q$, oa, oc, so2)) ->> 'dispute_id')::uuid;
    IF (pg_temp.f261_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'assay_results_disagree'$q$))::text::int <> 0
       OR (pg_temp.f261_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'assay_dispute_open'$q$))::text::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 261 DISAGREE: once a dispute is open the prompt goes and the open-dispute reminder shows (OB2 only)'; END IF;

    -- ══════════════ V14 ══════════════
    RAISE NOTICE 'fixture 261 · V14';
    v_j := pg_temp.f261_get(u_cust, $q$SELECT jsonb_agg(item_code ORDER BY item_code) FROM pending_values WHERE value_code = 'V14'$q$);
    IF v_j IS DISTINCT FROM jsonb_build_array((SELECT code FROM contracts WHERE id = con2)) THEN
        RAISE EXCEPTION 'FIXTURE 261 V14: one row — the contract with a dispute and no fee rule (con1 has "equal"), got %', v_j; END IF;
    IF (pg_temp.f261_get(u_qv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V14'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 261 V14: the row is read with the terms'' own code (customers view)'; END IF;
    UPDATE contract_settlement_terms SET arbitration_fee_rule = 'loser_pays' WHERE contract_id = con2;
    IF (pg_temp.f261_get(u_cust, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V14'$q$))::text::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 261 V14: once the rule is given the row goes'; END IF;
    BEGIN
        UPDATE contract_settlement_terms SET arbitration_fee_rule = 'whoever' WHERE contract_id = con2;
        RAISE EXCEPTION 'F261_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%arbitration_fee_rule%' THEN RAISE EXCEPTION 'FIXTURE 261 V14: five rules only, got %', SQLERRM; END IF;
    END;

    -- ══════════════ F3 ══════════════
    RAISE NOTICE 'fixture 261 · F3';
    PERFORM pg_temp.f261_as(u_fin);
    e_rev := (record_expense(v_today, '6400', 250, v_base, p_supplier_id => v_other_sup, p_notes => 'Courier for the umpire sample') ->> 'expense_id')::uuid;
    e_g := (record_expense(v_today, '6400', 80, v_base, p_supplier_id => v_other_sup, p_notes => 'Guard test') ->> 'expense_id')::uuid;
    PERFORM pg_temp.f261_as(NULL);
    PERFORM pg_temp.f261_agree(u_all, 'F3 expenses recorded');
    v_msg := pg_temp.f261_do(u_qv, format($q$SELECT reverse_expense(%L)$q$, e_rev));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.edit%' THEN RAISE EXCEPTION 'FIXTURE 261 F3: the permission comes first, got %', v_msg; END IF;
    v_msg := pg_temp.f261_do(u_fin, format($q$SELECT reverse_expense(%L)$q$, e_rev));
    v_msg2 := pg_temp.f261_do(u_fin, format($q$SELECT reverse_expense(%L, '   ')$q$, e_rev));
    IF v_msg NOT LIKE format('EXPENSE_REVERSAL_REASON_REQUIRED|%s', (SELECT code FROM expenses WHERE id = e_rev))
       OR v_msg2 NOT LIKE format('EXPENSE_REVERSAL_REASON_REQUIRED|%s', (SELECT code FROM expenses WHERE id = e_rev)) THEN
        RAISE EXCEPTION 'FIXTURE 261 F3: no reason and a blank reason are both refused by name, naming the expense, got «%» «%»', v_msg, v_msg2; END IF;
    BEGIN
        PERFORM reverse_expense_internal(e_rev, '  ');
        RAISE EXCEPTION 'F261_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'EXPENSE_REVERSAL_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'FIXTURE 261 F3: the internal path refuses a blank reason too, got %', SQLERRM; END IF;
    END;
    IF (SELECT status FROM expenses WHERE id = e_rev) <> 'posted' THEN RAISE EXCEPTION 'FIXTURE 261 F3: a refused reversal changes nothing'; END IF;
    v_j := pg_temp.f261_get(u_fin, format($q$SELECT reverse_expense(%L, '  Courier invoice was for another job  ')$q$, e_rev));
    IF (v_j ->> 'reversal_reason') <> 'Courier invoice was for another job'
       OR (SELECT (status, reversal_reason, reversed_at IS NOT NULL, reversed_by) FROM expenses WHERE id = e_rev)
            IS DISTINCT FROM ('reversed'::text, 'Courier invoice was for another job'::text, true, u_fin)
       OR (SELECT m.notes FROM expenses o JOIN expenses m ON m.id = o.reversed_by_expense WHERE o.id = e_rev)
            IS DISTINCT FROM 'REVERSAL: ' || (SELECT code FROM expenses WHERE id = e_rev)
       OR (SELECT (reversal_reason, reversed_at, reversed_by) FROM expenses m WHERE m.id = (SELECT reversed_by_expense FROM expenses WHERE id = e_rev))
            IS DISTINCT FROM (NULL::text, NULL::timestamptz, NULL::uuid) THEN
        RAISE EXCEPTION 'FIXTURE 261 F3: the reason (trimmed), when and who are on the reversed expense; the mirror''s notes are "REVERSAL: <code>" only and it carries no reason, got %', v_j; END IF;
    PERFORM pg_temp.f261_agree(u_all, 'expense reversed with a reason');
    -- 行守卫
    BEGIN
        UPDATE expenses SET status = 'reversed', reversed_by_expense = e_rev WHERE id = e_g;
        RAISE EXCEPTION 'F261_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'EXPENSE_REVERSAL_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'FIXTURE 261 F3: the row guard refuses posted → reversed without a reason, got %', SQLERRM; END IF;
    END;
    BEGIN
        UPDATE expenses SET reversal_reason = 'a different story' WHERE id = e_rev;
        RAISE EXCEPTION 'F261_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'EXPENSE_IMMUTABLE%' THEN RAISE EXCEPTION 'FIXTURE 261 F3: a reversal reason is never rewritten, got %', SQLERRM; END IF;
    END;
    BEGIN
        UPDATE expenses SET reversal_reason = 'early' WHERE id = e_g;
        RAISE EXCEPTION 'F261_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'EXPENSE_IMMUTABLE%' THEN RAISE EXCEPTION 'FIXTURE 261 F3: no reason outside the posted → reversed step, got %', SQLERRM; END IF;
    END;
    BEGIN
        INSERT INTO expenses (code, expense_date, account_code, amount_ccy, currency, fx_rate, amount_base, payment_status, supplier_id, reversal_reason)
        VALUES ('ZZ261-EXP-X', v_today, '6400', 1, v_base, 1, 1, 'unpaid', v_other_sup, 'pre-written');
        RAISE EXCEPTION 'F261_PROBE';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%expenses_reversal_shape%' THEN RAISE EXCEPTION 'FIXTURE 261 F3: a posted expense cannot carry a reversal reason (CHECK), got %', SQLERRM; END IF;
    END;

    RAISE NOTICE 'FIXTURE 261 全部通过: OPEN · HOLD · RESOLVE · D4 · SELL · FEE · DISAGREE · V14 · F3';
END $$;

ROLLBACK;

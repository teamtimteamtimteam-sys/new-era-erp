-- db/scripts/2026-10-10-mes6a2-live-proof.sql
-- MES-6a-2 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关;审批的设定一个字都不改。
--   由 db/scripts/2026-10-10-mes6a2-live-proof.mjs 驱动:它先用 mintThrowaway 造一次性账号(前缀 mes6a2probe),
--   再以 psql 跑本文件,把那些邮箱经 -v 传进来;跑完按 ephemeral 计划收走账号、授权、一次性角色。
--   【每一个动作都以一次性账号跑】(七个真账号一个都不用):
--     cco = action.contract_terms + module.customers.view/edit + module.suppliers.view + module.pricing.view/edit + data.view_prices
--           + data.view_purchase_prices                                —— 写合同条款(惩罚元素 · 计价条款)、提一张公式
--     fin = action.metal_prices + module.pricing.view + data.view_prices + data.view_purchase_prices —— 记行情
--     rec = module.inbound/output.view + .edit                             —— 两张化验表单(进料 · 产出)
--     apl = module.output.view + module.inbound.view + action.apply_assay  —— 应用那一份产出化验(含量落进批次)
--     sal = module.customers.view/edit + module.output.view + module.pricing.view + data.view_prices —— 挂合同、算卖方结算、报价
--     iv  = module.inbound.view + module.output.view                       —— 读回指标(读策略跟着化验的父批次)
--     c_<角色> = 七个真角色【此刻的码】的一次性克隆(cloneOf)—— 只读:逐角色读数表;对账在 c_cfo 的会话里读
--   【布景】(以属主插,都是我自己的行,前缀 ZZ-PROBE-MES6A2):一家供应商、一种物料、一批进料、两批产出、一个客户、一份卖方合同
--     (草稿 → 写条款 → 以属主改成生效:那一步代替 CFO 的批准,只作用在我自己的这一份上)、两张销售单、9 月 LME 的日历与 ni 行情、
--     8 月 14 日的 USD 牌价与 ni 行情。线上原本【没有】这些日子的牌价、行情与日历(读过:0 行)—— 所以这里插自己的,随回滚消失。
--   ① 惩罚元素:cco 在我的卖方合同上加 F(阈值 0.005 %,1,000 USD / 结算吨 / 百分点)→ 收;
--      F 在行情(fin · upsert_metal_prices)、公式(cco · submit_formula_create_request)、合同计价条款(cco)上 → 按名拒 SUBSTANCE_NOT_PAYABLE|f。
--   ② 化验:rec 在产出批上记一份卖方化验(ni 20 · F 0.0123 · Cl 0.004,在 % 里录)、在另一批产出上记一份产出化验(同样带 F · Cl),
--      在进料批上记一份进料化验(带 F)—— 三份都存成原样(0.0123 / 0.004,不舍到两位);驱动拿这几个数过 lib/substances.ts 印出屏幕上的写法。
--   ③ 卖方结算与报价:sal 算结算(F 有阈值 → 惩罚一行;Cl 没有条款 → 不罚;两者都不进计价那一圈)→ 不报错,金属价值与一份不带 F / Cl 的
--      孪生化验逐分相同;apl 应用产出化验(F 落进批次含量)→ sal 报价(现价预设)不报错,与一批不带 F 的孪生批同价。
--   ④ 指标:rec 在进料化验上记五个指标、在产出化验上记五个指标(两张表单走的同一支 record_assay_result);iv 读回各五个。
--   ⑤ 逐角色读数表(只读):两张化验表单进得去、存得下吗;读得到指标的定义与这份化验上的指标值吗;读得到合同的惩罚元素吗、改得动吗;
--      行情页进得去吗、记得了行情吗;字典里读到几种物质。
--   每一个碰到钱的步骤之后:AP / AR 清单 = 总账,两边 unexplained 0.00(c_cfo 的会话)。在册的东西一张都不碰、不决定、不改。
-- 打印的每一行都是 STEP|… 或 ROLE|… ;任何一处与预期不符就 RAISE,整笔回滚。
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SELECT set_config('mes6a2.cco', :'cco', true), set_config('mes6a2.fin', :'fin', true), set_config('mes6a2.rec', :'rec', true),
       set_config('mes6a2.apl', :'apl', true), set_config('mes6a2.sal', :'sal', true), set_config('mes6a2.iv', :'iv', true),
       set_config('mes6a2.c_admin', :'c_admin', true), set_config('mes6a2.c_finance', :'c_finance', true),
       set_config('mes6a2.c_warehouse', :'c_warehouse', true), set_config('mes6a2.c_cto', :'c_cto', true),
       set_config('mes6a2.c_cco', :'c_cco', true), set_config('mes6a2.c_cfo', :'c_cfo', true), set_config('mes6a2.c_gm', :'c_gm', true) \g /dev/null

CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid; e text := current_setting('mes6a2.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = e;
    IF v IS NULL OR e NOT LIKE 'mes6a2probe-%@test.local' THEN RAISE EXCEPTION 'MES6A2_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
CREATE FUNCTION pg_temp.try_(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; out text := '';
BEGIN
    PERFORM pg_temp.as_('c_cfo');
    v := list_ledger_reconciliation();
    PERFORM pg_temp.me_();
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES6A2_LIVE|AP/AR list <> ledger after %: % list % ledger % unexplained %', p_step, s ->> 'side', s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base';
        END IF;
        out := out || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RETURN out;
END $f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_(), pg_temp.try_(text) TO authenticated;

CREATE TEMP TABLE mes6a2_roles (who text, role text, codes integer, inbound_form boolean, output_form boolean, indicator_defs bigint,
    indicator_values bigint, penalty_rows bigint, penalty_edit boolean, price_page boolean, price_edit boolean, substances bigint) ON COMMIT DROP;
GRANT INSERT ON mes6a2_roles TO authenticated;

DO $live$
DECLARE
    v_base text := (SELECT code FROM currencies WHERE is_base);
    v_day date := DATE '2026-09-15';      -- 结算:9 月计价期(LME 日历 + 每个交易日的 ni 报价,都是我插的)
    v_qd  date := DATE '2026-08-14';      -- 报价:那一天的 USD 牌价与 ni 行情(我插的)
    sup uuid; mat uuid; b1 uuid; ob uuid; ob_twin uuid; ob_q uuid; ob_q_twin uuid; cust uuid; con uuid; so uuid;
    a_sale uuid; a_twin uuid; a_out uuid; a_in uuid;
    v_msg text; v_j jsonb; v_j2 jsonb; v_rec text; v_t text; v_n bigint; v_fp_before text;
    v_pending text := (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    v_t0 timestamptz := now();
    v_ind jsonb := '[{"indicator": "residual_powder_pct", "value": 0.85}, {"indicator": "foil_purity_pct", "value": 99.2},
                     {"indicator": "d10_um", "value": 3.1}, {"indicator": "d50_um", "value": 11.4}, {"indicator": "d90_um", "value": 28.75}]';
    r record;
BEGIN
    -- 在册的东西先记一个指纹(我的行 created_at = 事务开始时刻 = v_t0,比较时按 < v_t0 排除;substances 减掉 role 只比既有那七行)
    SELECT md5(concat_ws('#',
        (SELECT md5(string_agg((to_jsonb(x) - 'role')::text, '|' ORDER BY x.code)) FROM substances x WHERE x.code NOT IN ('f', 'cl')),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.assay_result_id, x.metal)) FROM assay_result_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM receipt_price_requests x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contracts x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_settlement_terms x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_pricing_terms x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_penalty_elements x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM pricing_formulas x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_orders x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM customers x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM fx_rates x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM metal_prices x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM assay_indicators x),
        (SELECT md5(to_jsonb(x)::text) FROM finance_settings x),
        (SELECT md5(to_jsonb(x)::text) FROM pricing_settings x)))
      INTO v_fp_before;
    v_rec := pg_temp.agree_('start');
    RAISE NOTICE 'STEP|start|%', v_rec;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6A2_LIVE|approvals are off on live'; END IF;
    IF EXISTS (SELECT 1 FROM assay_result_indicators) OR EXISTS (SELECT 1 FROM contract_penalty_elements)
       OR EXISTS (SELECT 1 FROM assay_result_metals WHERE metal IN ('f', 'cl')) THEN
        RAISE EXCEPTION 'MES6A2_LIVE|live already has an indicator value, a penalty element or an F / Cl content — this proof expects none';
    END IF;
    -- (牌价不必先查:我插的那三行若撞上一条在册的,唯一索引 idx_fx_rates_one_per_day 当场拒,整笔回滚 —— 不会覆盖任何人的牌价)
    IF EXISTS (SELECT 1 FROM metal_prices WHERE metal = 'ni' AND (price_date = v_qd OR price_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'))
       OR EXISTS (SELECT 1 FROM index_market_calendar WHERE index_code = 'LME' AND calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30') THEN
        RAISE EXCEPTION 'MES6A2_LIVE|live now has a USD rate, an ni quote or an LME calendar day on the proof dates — pick other dates';
    END IF;

    -- ══ 布景(属主) ══
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZ-PROBE-MES6A2-S', 'ZZ-PROBE-MES6A2 goods supplier', 'SG', 'active', 'goods_supplier', 'OP') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ-PROBE-MES6A2-BM', 'ZZ-PROBE-MES6A2 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO mat;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (mat, sup, 100, 100, 'kg', v_qd, 'other', 'ZZ-PROBE-MES6A2 live proof') RETURNING id INTO b1;
    INSERT INTO output_batches (material_id, quantity, remaining_qty, unit, output_date, notes) VALUES
        (mat, 10000, 10000, 'kg', v_day, 'ZZ-PROBE-MES6A2 sale'), (mat, 10000, 10000, 'kg', v_day, 'ZZ-PROBE-MES6A2 sale twin'),
        (mat, 10000, 10000, 'kg', v_qd, 'ZZ-PROBE-MES6A2 quote'), (mat, 10000, 10000, 'kg', v_qd, 'ZZ-PROBE-MES6A2 quote twin');
    SELECT id INTO ob FROM output_batches WHERE notes = 'ZZ-PROBE-MES6A2 sale';
    SELECT id INTO ob_twin FROM output_batches WHERE notes = 'ZZ-PROBE-MES6A2 sale twin';
    SELECT id INTO ob_q FROM output_batches WHERE notes = 'ZZ-PROBE-MES6A2 quote';
    SELECT id INTO ob_q_twin FROM output_batches WHERE notes = 'ZZ-PROBE-MES6A2 quote twin';
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    SELECT 'USD', v_qd, t, rt FROM (VALUES ('tt_sell', 1.30), ('tt_buy', 1.28), ('mid', 1.29)) AS y(t, rt);
    INSERT INTO metal_prices (metal, price_date, price_usd_per_tonne, source, price_index) VALUES ('ni', v_qd, 15000, 'broker_quote', NULL);
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', d::date, EXTRACT(ISODOW FROM d) < 6, 'ZZ-PROBE-MES6A2' FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT 'ni', 10000, c.calendar_date, 'published_index', 'LME'
      FROM index_market_calendar c WHERE c.index_code = 'LME' AND c.is_trading_day AND c.calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30';
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ-PROBE-MES6A2-C', 'ZZ-PROBE-MES6A2 customer', 'SG', 30) RETURNING id INTO cust;
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (cust, 'offtake', 'ZZ-PROBE-MES6A2 offtake (F penalty)', DATE '2026-01-01', 'draft') RETURNING id INTO con;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES ('ZZ-PROBE-MES6A2-SO', cust, DATE '2026-06-10', v_base, 1) RETURNING id INTO so;
    RAISE NOTICE 'STEP|setup|draft sell contract % · inbound % · output % (sale) / % (sale twin) / % (quote) / % (quote twin) · own USD rate and ni quote for %, own LME September calendar and ni quotes (live had none)',
        (SELECT code FROM contracts WHERE id = con), (SELECT code FROM inbound_batches WHERE id = b1), (SELECT code FROM output_batches WHERE id = ob),
        (SELECT code FROM output_batches WHERE id = ob_twin), (SELECT code FROM output_batches WHERE id = ob_q), (SELECT code FROM output_batches WHERE id = ob_q_twin), v_qd;

    -- ══ ① 惩罚元素收 F;F 在行情、公式、计价条款上按名拒 ══
    PERFORM pg_temp.as_('cco');
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (con, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis)
    VALUES (con, 'dry', 'ours', false, 'per_metal', 'per_element');
    INSERT INTO contract_refining_charges (contract_id, metal, usd_per_tonne_of_metal) VALUES (con, 'ni', 100);
    v_msg := pg_temp.try_(format($q$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'f', 0.005, 1000)$q$, con));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'MES6A2_LIVE|F as a penalty element: %', v_msg; END IF;
    v_t := pg_temp.try_(format($q$INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (%L, 'f', 'assay_complete', 0, 'LME', 50)$q$, con));
    v_j := to_jsonb(pg_temp.try_($q$SELECT submit_formula_create_request('{"name": "ZZ-PROBE-MES6A2 formula", "direction": "sale", "price_basis": "spot", "metals": [{"metal": "ni", "payable_pct": 80}, {"metal": "f", "payable_pct": 10}]}'::jsonb, 'ZZ-PROBE-MES6A2')$q$));
    PERFORM pg_temp.as_('fin');
    v_msg := pg_temp.try_(format($q$SELECT upsert_metal_prices(%L, '[{"metal": "f", "price_usd_per_tonne": 5}]'::jsonb, NULL, 'broker_quote')$q$, v_qd));
    PERFORM pg_temp.me_();
    IF v_t <> 'SUBSTANCE_NOT_PAYABLE|f' OR v_j #>> '{}' <> 'SUBSTANCE_NOT_PAYABLE|f' OR v_msg <> 'SUBSTANCE_NOT_PAYABLE|f' THEN
        RAISE EXCEPTION 'MES6A2_LIVE|F on price paths — pricing term «%» · formula «%» · metal price «%»', v_t, v_j #>> '{}', v_msg;
    END IF;
    IF EXISTS (SELECT 1 FROM metal_prices WHERE metal = 'f') OR EXISTS (SELECT 1 FROM pricing_formula_metals WHERE metal = 'f')
       OR EXISTS (SELECT 1 FROM contract_pricing_terms WHERE metal = 'f') OR EXISTS (SELECT 1 FROM pricing_formulas WHERE name = 'ZZ-PROBE-MES6A2 formula') THEN
        RAISE EXCEPTION 'MES6A2_LIVE|a refused F left a row behind';
    END IF;
    -- 我的合同生效(属主路径 —— 代替 CFO 的批准,只作用在这一份我自己的草稿上;随回滚消失)
    UPDATE contracts SET status = 'active' WHERE id = con;
    PERFORM pg_temp.as_('sal');
    PERFORM link_document_to_contract('sales_order', so, con);
    PERFORM pg_temp.me_();
    RAISE NOTICE 'STEP|penalty|cco named F on % (threshold %, % USD per settlement tonne per point over) · F refused by name on a pricing term «%», a formula «%» and a metal price «%» — nothing left behind',
        (SELECT code FROM contracts WHERE id = con), (SELECT threshold_pct FROM contract_penalty_elements WHERE contract_id = con AND substance = 'f'),
        (SELECT usd_per_tonne_per_pct_over FROM contract_penalty_elements WHERE contract_id = con AND substance = 'f'), v_t, v_j #>> '{}', v_msg;

    -- ══ ② 化验:卖方 · 产出 · 进料,带 F / Cl,在 % 里录;两张表单都记五个指标 ══
    PERFORM pg_temp.as_('rec');
    a_sale := (record_assay_result(p_assay_date => v_day, p_output_batch_id => ob, p_weight_basis => 'dry', p_moisture_pct => 10, p_result_party => 'ours',
               p_metals => '[{"metal": "ni", "content_pct": 20}, {"metal": "f", "content_pct": 0.0123}, {"metal": "cl", "content_pct": 0.004}]'::jsonb) ->> 'assay_result_id')::uuid;
    a_twin := (record_assay_result(p_assay_date => v_day, p_output_batch_id => ob_twin, p_weight_basis => 'dry', p_moisture_pct => 10, p_result_party => 'ours',
               p_metals => '[{"metal": "ni", "content_pct": 20}]'::jsonb) ->> 'assay_result_id')::uuid;
    v_j := record_assay_result(p_assay_date => v_qd, p_output_batch_id => ob_q, p_weight_basis => 'dry', p_result_party => 'ours',
               p_metals => '[{"metal": "ni", "content_pct": 20}, {"metal": "f", "content_pct": 0.0123}, {"metal": "cl", "content_pct": 0.004}]'::jsonb,
               p_indicators => v_ind);
    a_out := (v_j ->> 'assay_result_id')::uuid;
    v_j2 := record_assay_result(p_assay_date => v_qd, p_inbound_batch_id => b1, p_weight_basis => 'as_received', p_result_party => 'ours',
               p_metals => '[{"metal": "ni", "content_pct": 30}, {"metal": "f", "content_pct": 0.0050}, {"metal": "cl", "content_pct": 0.00005}]'::jsonb,
               p_indicators => v_ind);
    a_in := (v_j2 ->> 'assay_result_id')::uuid;
    PERFORM pg_temp.me_();
    IF (v_j ->> 'indicator_count')::int <> 5 OR (v_j2 ->> 'indicator_count')::int <> 5 THEN
        RAISE EXCEPTION 'MES6A2_LIVE|both forms record five indicators: output % · inbound %', v_j ->> 'indicator_count', v_j2 ->> 'indicator_count';
    END IF;
    SELECT string_agg(a.code || ':' || m.metal || '=' || m.content_pct::text, ',' ORDER BY a.code, m.metal) INTO v_t
      FROM assay_result_metals m JOIN assay_results a ON a.id = m.assay_result_id
     WHERE m.assay_result_id IN (a_sale, a_out, a_in) AND m.metal IN ('f', 'cl');
    IF v_t NOT LIKE '%:cl=0.004,%:f=0.0123,%' OR v_t NOT LIKE '%:cl=0.00005,%:f=0.0050%' THEN
        RAISE EXCEPTION 'MES6A2_LIVE|F / Cl stored as entered, got %', v_t;
    END IF;
    RAISE NOTICE 'STEP|assays|rec recorded sale assay %, output assay % and inbound assay % with F and Cl in %%; stored as entered: %',
        (SELECT code FROM assay_results WHERE id = a_sale), (SELECT code FROM assay_results WHERE id = a_out), (SELECT code FROM assay_results WHERE id = a_in), v_t;
    RAISE NOTICE 'STEP|ppm|%', (SELECT string_agg(m.metal || '=' || m.content_pct::text || '=' || s.role, ',' ORDER BY m.content_pct DESC)
                                FROM assay_result_metals m JOIN substances s ON s.code = m.metal
                               WHERE m.assay_result_id IN (a_sale, a_in) AND m.metal IN ('f', 'cl', 'ni'));

    -- ══ ③ 卖方结算与报价 ══
    PERFORM pg_temp.as_('sal');
    v_msg := pg_temp.try_(format('SELECT sale_settlement_compute(%L, %L, %L)', so, ob, a_sale));
    IF v_msg <> 'OK' THEN PERFORM pg_temp.me_(); RAISE EXCEPTION 'MES6A2_LIVE|sale settlement with F and Cl: %', v_msg; END IF;
    v_j := sale_settlement_compute(so, ob, a_sale);
    v_j2 := sale_settlement_compute(so, ob_twin, a_twin);
    PERFORM pg_temp.me_();
    -- 手算(与 fixture 262 SETTLE 同一组数):结算重量 9,000 kg;ni 1,800 kg 含、可付 70 % = 1,260 kg × 10,000 = 12,600.00;
    --   精炼费 1.8 t × 100 = 180.00;F 超 0.0073 个百分点 × 9 t × 1,000 = 65.70;金额 12,354.30。孪生化验没有 F:惩罚 0,金属价值相同。
    IF (v_j ->> 'metal_value_usd')::numeric <> 12600.00 OR (v_j ->> 'refining_charge_usd')::numeric <> 180.00
       OR (v_j ->> 'penalty_usd')::numeric <> 65.70 OR (v_j ->> 'amount_usd')::numeric <> 12354.30
       OR (v_j2 ->> 'metal_value_usd')::numeric <> (v_j ->> 'metal_value_usd')::numeric OR (v_j2 ->> 'penalty_usd')::numeric <> 0
       OR (SELECT string_agg(e ->> 'metal', ',') FROM jsonb_array_elements(v_j -> 'breakdown' -> 'metals') e) <> 'ni'
       OR (SELECT string_agg(e ->> 'substance', ',') FROM jsonb_array_elements(v_j -> 'breakdown' -> 'penalties') e) <> 'f' THEN
        RAISE EXCEPTION 'MES6A2_LIVE|settlement: with F % / % / % / % · twin % / %', v_j ->> 'metal_value_usd', v_j ->> 'refining_charge_usd',
            v_j ->> 'penalty_usd', v_j ->> 'amount_usd', v_j2 ->> 'metal_value_usd', v_j2 ->> 'penalty_usd';
    END IF;
    RAISE NOTICE 'STEP|settlement|sal settled % against % without error: metal value % (ni only) − refining % − penalty % (F only; Cl has no term) = % USD · twin assay without F/Cl: metal value %, penalty %',
        (SELECT code FROM output_batches WHERE id = ob), (SELECT code FROM assay_results WHERE id = a_sale),
        v_j ->> 'metal_value_usd', v_j ->> 'refining_charge_usd', v_j ->> 'penalty_usd', v_j ->> 'amount_usd', v_j2 ->> 'metal_value_usd', v_j2 ->> 'penalty_usd';
    PERFORM pg_temp.as_('apl');
    v_msg := pg_temp.try_(format('SELECT apply_output_assay(%L)', a_out));
    PERFORM pg_temp.me_();
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'MES6A2_LIVE|applying the output assay with F: %', v_msg; END IF;
    IF (SELECT string_agg(metal || '=' || content_pct::text, ',' ORDER BY metal) FROM output_batch_metals WHERE output_batch_id = ob_q)
         IS DISTINCT FROM 'cl=0.004,f=0.0123,ni=20' THEN
        RAISE EXCEPTION 'MES6A2_LIVE|the applied content (F and Cl recorded, not priced): %',
            (SELECT string_agg(metal || '=' || content_pct::text, ',' ORDER BY metal) FROM output_batch_metals WHERE output_batch_id = ob_q);
    END IF;
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob_q_twin, 'ni', 20, 'manual');
    PERFORM pg_temp.as_('sal');
    v_msg := pg_temp.try_(format('SELECT price_output_sale(%L, NULL, %L, 1000, %L)', ob_q, v_base, v_qd));
    IF v_msg <> 'OK' THEN PERFORM pg_temp.me_(); RAISE EXCEPTION 'MES6A2_LIVE|the sale quote with F: %', v_msg; END IF;
    v_j := price_output_sale(ob_q, NULL, v_base, 1000, v_qd);
    v_j2 := price_output_sale(ob_q_twin, NULL, v_base, 1000, v_qd);
    PERFORM pg_temp.me_();
    IF (v_j ->> 'unit_price_ccy')::numeric IS DISTINCT FROM (v_j2 ->> 'unit_price_ccy')::numeric OR (v_j ->> 'unit_price_ccy')::numeric <= 0
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_j -> 'breakdown' -> 'lines') e WHERE e ->> 'metal' IN ('f', 'cl')) THEN
        RAISE EXCEPTION 'MES6A2_LIVE|quote with F % vs twin %', v_j ->> 'unit_price_ccy', v_j2 ->> 'unit_price_ccy';
    END IF;
    v_rec := pg_temp.agree_('settlement and quote');
    RAISE NOTICE 'STEP|quote|apl applied % (batch content now cl 0.004 · f 0.0123 · ni 20) · sal quoted % (preset, %) without error: % % per kg, the same as the twin batch without F (% %) · reconciliation %',
        (SELECT code FROM assay_results WHERE id = a_out), (SELECT code FROM output_batches WHERE id = ob_q), v_qd,
        v_j ->> 'unit_price_ccy', v_base, v_j2 ->> 'unit_price_ccy', v_base, v_rec;

    -- ══ ④ 指标:两张表单各五个,iv 读回 ══
    PERFORM pg_temp.as_('iv');
    SELECT string_agg(a.code || ':' || i.indicator || '=' || i.value::text, ',' ORDER BY a.code, i.indicator) INTO v_t
      FROM assay_result_indicators i JOIN assay_results a ON a.id = i.assay_result_id WHERE i.assay_result_id IN (a_out, a_in);
    SELECT count(*) INTO v_n FROM assay_result_indicators WHERE assay_result_id IN (a_out, a_in);
    PERFORM pg_temp.me_();
    IF v_n <> 10 THEN RAISE EXCEPTION 'MES6A2_LIVE|an inbound + output viewer reads the ten indicator values, got % (%)', v_n, v_t; END IF;
    RAISE NOTICE 'STEP|indicators|both forms recorded the five (no limit applied); read back by a batch viewer: %', v_t;

    -- ══ ⑤ 逐角色读数表(只读)══
    FOR r IN SELECT unnest(ARRAY['c_admin', 'c_finance', 'c_warehouse', 'c_cto', 'c_cco', 'c_cfo', 'c_gm']) AS who LOOP
        PERFORM pg_temp.as_(r.who);
        INSERT INTO mes6a2_roles
        SELECT r.who, (SELECT ro.code FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ur.user_id = auth.uid() LIMIT 1),
               cardinality(current_user_permissions()),
               has_permission('module.inbound.edit'), has_permission('module.output.edit'),
               (SELECT count(*) FROM assay_indicators),
               (SELECT count(*) FROM assay_result_indicators WHERE assay_result_id IN (a_out, a_in)),
               (SELECT count(*) FROM contract_penalty_elements WHERE contract_id = con),
               has_permission('action.contract_terms'),
               has_permission('module.pricing.view'), has_permission('action.metal_prices'),
               (SELECT count(*) FROM substances);
        PERFORM pg_temp.me_();
    END LOOP;
    FOR r IN SELECT * FROM mes6a2_roles LOOP
        RAISE NOTICE 'ROLE|%|% (% codes)|inbound assay form %|output assay form %|indicator definitions %|indicator values on the two assays %|penalty elements on the contract %|penalty edit %|metal-price page %|metal-price edit %|substances %',
            r.who, r.role, r.codes, r.inbound_form, r.output_form, r.indicator_defs, r.indicator_values, r.penalty_rows, r.penalty_edit,
            r.price_page, r.price_edit, r.substances;
    END LOOP;

    -- ══ 在册的东西一个字都没动 ══
    IF md5(concat_ws('#',
        (SELECT md5(string_agg((to_jsonb(x) - 'role')::text, '|' ORDER BY x.code)) FROM substances x WHERE x.code NOT IN ('f', 'cl')),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.assay_result_id, x.metal)) FROM assay_result_metals x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM receipt_price_requests x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contracts x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_settlement_terms x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_pricing_terms x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_penalty_elements x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM pricing_formulas x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_orders x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM customers x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM fx_rates x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM metal_prices x WHERE x.created_at < v_t0),
        (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM assay_indicators x),
        (SELECT md5(to_jsonb(x)::text) FROM finance_settings x),
        (SELECT md5(to_jsonb(x)::text) FROM pricing_settings x))) IS DISTINCT FROM v_fp_before THEN
        RAISE EXCEPTION 'MES6A2_LIVE|a pre-existing substance, batch, content, assay, price request, contract, term, formula, sales order, expense, payment, journal, supplier, customer, rate, quote, indicator definition or setting changed';
    END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> v_pending THEN
        RAISE EXCEPTION 'MES6A2_LIVE|pending documents changed: % → %', v_pending,
            (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES6A2_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6A2_LIVE|approvals switched off'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing substances (apart from role), batches, content, assays, price requests, contracts, terms, formulas, sales orders, expenses, payments, journals, suppliers, customers, rates, quotes, indicator definitions and settings identical; pending %; approvals on; reconciliation %',
        v_pending, v_rec;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - v_t0;
END
$live$;

ROLLBACK;

SELECT 'AFTER|indicator values=' || (SELECT count(*) FROM assay_result_indicators)
    || '|penalty elements=' || (SELECT count(*) FROM contract_penalty_elements)
    || '|F/Cl contents=' || ((SELECT count(*) FROM assay_result_metals WHERE metal IN ('f', 'cl')) + (SELECT count(*) FROM output_batch_metals WHERE metal IN ('f', 'cl'))
                             + (SELECT count(*) FROM inbound_batch_metals WHERE metal IN ('f', 'cl')))
    || '|probe suppliers=' || (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES6A2%')
    || '|probe customers=' || (SELECT count(*) FROM customers WHERE code LIKE 'ZZ-PROBE-MES6A2%')
    || '|probe contracts=' || (SELECT count(*) FROM contracts WHERE title LIKE 'ZZ-PROBE-MES6A2%')
    || '|ni quotes on the proof dates=' || (SELECT count(*) FROM metal_prices WHERE metal = 'ni' AND (price_date = DATE '2026-08-14' OR price_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30'))
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');

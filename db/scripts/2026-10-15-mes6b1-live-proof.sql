-- db/scripts/2026-10-15-mes6b1-live-proof.sql
-- MES-6b-1 · 线上的证明 —— 【一笔事务,以 ROLLBACK 收尾】:什么都不留。审批开着,一处都不关;审批的设定一个字都不改。
--   由 db/scripts/2026-10-15-mes6b1-live-proof.mjs 驱动:它先用 mintThrowaway 造一次性账号(前缀 mes6b1probe),
--   再以 psql 跑本文件,把那些邮箱经 -v 传进来;跑完按 ephemeral 计划收走账号、授权、一次性角色。
--   【每一个动作都以一次性账号跑】(七个真账号一个都不用):
--     cco = 合同条款(写合同、条款、质量验收限;提生效申请)       cfo = 真的 cfo 角色本身(realRole)—— 只为【决定】二级审批的三张申请
--     sal = 销售单、挂合同、预留、提放行申请、算结算            fin = 开票(module.finance.edit)
--     rec = 两张化验表单(进料 · 产出)                        apl = 应用化验(两侧)
--     wh  = 转移、发货、注销申请                               wo  = 建配料计划          pc = 加工提交
--     qe  = 开不合格报告,【也持决定码】(开单人决定自己那一张 → 按名拒)
--     qd  = 第二个持决定码的人(决定)
--     c_<角色> = 七个真角色【此刻的码】的一次性克隆(cloneOf)—— 只读:逐角色读数表;对账在 c_cfo 的会话里读
--   【布景】(以属主插,都是我自己的行,前缀 ZZ-PROBE-MES6B1):一家供应商、一种物料、一个客户、一个库位、三批进料、三批产出、
--     9 月 LME 的日历与 ni 报价(线上这几天原本没有 —— 读过、先断言)。
--   ① V17 · 申请生效:口径没设 → 按名拒;per_parameter 没有行 → 按名拒 QUALITY_LIMITS_NOT_FILED;填一条水分 ≤ 8 → 申请 → cfo 批 → 生效。
--      F4:同一份合同上罚铜(cu)收;再给铜计价 → 按名拒 SUBSTANCE_PRICED_AND_PENALISED|cu。
--   ② 判定:rec 在一批产出上记一份化验(水分 9.2、ni 20、cu 3);sal 预留给挂着这份合同的单 → 预留留着、同一笔里开一张系统的报告。
--   ③ 暂扣:那一批 —— 结算(预览与落库)、发货(开票 + 放行申请 cfo 批过之后)按名拒,转移放行;
--      进料一批 —— qe 开一张手工报告 → 加工投料、配料计划按名拒,转移放行;qe 决定自己那一张 → 按名拒(SELF_APPROVAL_FORBIDDEN)。
--   ④ 决定:qd 接受系统那一张 → 发货照走、结算算得出(铜罚、不计价);qd 拒收手工那一张 → 投料仍按名拒;
--      wh 提注销申请 → cfo 批 → 货没了、暂扣结束。
--   ⑤ F5:进料一批与产出一批各有 ni 与 f 的含量;各记一份只测 f、cl 的化验并应用 → 只换掉 f、cl,ni 原样,不计价。
--   ⑥ 逐角色读数表(只读):报告清单 / 报告页 / 批次页的暂扣那一行 / 合同的质量验收限 / 两张化验表单 / 开 · 决定报告。
--   ⑦ 最后一格(放在最后,因为它要在 contract_pricing_terms 上持一把锁直到回滚):一份草稿合同,守卫关掉一格写进"既计价又罚",
--      清单点名、申请生效按名拒 —— 守卫随即打开,整笔回滚。
--   每一个碰到钱的步骤之后:AP / AR 清单 = 总账,两边 unexplained 0.00(c_cfo 的会话)。在册的东西一张都不碰、不决定、不改。
-- 打印的每一行都是 STEP|… 或 ROLE|… ;任何一处与预期不符就 RAISE,整笔回滚。
\pset pager off
\pset format unaligned
\pset tuples_only on
BEGIN;
SET LOCAL statement_timeout = '300s';
SET LOCAL lock_timeout = '10s';
SELECT set_config('mes6b1.cco', :'cco', true), set_config('mes6b1.cfo', :'cfo', true), set_config('mes6b1.sal', :'sal', true),
       set_config('mes6b1.fin', :'fin', true), set_config('mes6b1.rec', :'rec', true), set_config('mes6b1.apl', :'apl', true),
       set_config('mes6b1.wh', :'wh', true), set_config('mes6b1.wo', :'wo', true), set_config('mes6b1.pc', :'pc', true),
       set_config('mes6b1.qe', :'qe', true), set_config('mes6b1.qd', :'qd', true),
       set_config('mes6b1.c_admin', :'c_admin', true), set_config('mes6b1.c_finance', :'c_finance', true),
       set_config('mes6b1.c_warehouse', :'c_warehouse', true), set_config('mes6b1.c_cto', :'c_cto', true),
       set_config('mes6b1.c_cco', :'c_cco', true), set_config('mes6b1.c_cfo', :'c_cfo', true), set_config('mes6b1.c_gm', :'c_gm', true) \g /dev/null

CREATE FUNCTION pg_temp.as_(p_who text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v uuid; e text := current_setting('mes6b1.' || p_who);
BEGIN
    EXECUTE 'RESET ROLE';
    SELECT id INTO v FROM auth.users WHERE email = e;
    IF v IS NULL OR e NOT LIKE 'mes6b1probe-%@test.local' THEN RAISE EXCEPTION 'MES6B1_LIVE|not a throwaway account: % (%)', p_who, e; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
END $f$;
CREATE FUNCTION pg_temp.me_() RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
END $f$;
-- 以 p_who 的身份跑一句;成 → 'OK',拒 → 那一句原话。身份在里面换、在外面还原(拒绝也一样)。
CREATE FUNCTION pg_temp.try_(p_who text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.as_(p_who);
    EXECUTE p_sql;
    PERFORM pg_temp.me_();
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.me_();
    RETURN SQLERRM;
END $f$;
CREATE FUNCTION pg_temp.get_(p_who text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.as_(p_who);
    EXECUTE p_sql INTO v;
    PERFORM pg_temp.me_();
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.me_();
    RAISE;
END $f$;
CREATE FUNCTION pg_temp.agree_(p_step text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb; out text := '';
BEGIN
    v := pg_temp.get_('c_cfo', 'SELECT list_ledger_reconciliation()');
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'MES6B1_LIVE|reconciliation after %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'MES6B1_LIVE|AP/AR list <> ledger after %: % list % ledger % unexplained %', p_step, s ->> 'side', s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base';
        END IF;
        out := out || (s ->> 'side') || ' ' || (s ->> 'list_base') || ' / ' || (s ->> 'ledger_base') || ' / ' || (s ->> 'unexplained_base') || '; ';
    END LOOP;
    RETURN out;
END $f$;
-- 在册的东西的指纹:我的行 created_at = 事务开始时刻(now()),按 < v_t0 排除
CREATE FUNCTION pg_temp.fp_(v_t0 timestamptz) RETURNS text LANGUAGE sql AS $f$
SELECT md5(concat_ws('#',
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contracts x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_settlement_terms x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_pricing_terms x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM contract_penalty_elements x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM terms_requests x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inbound_batches x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM output_batches x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.inbound_batch_id, x.metal)) FROM inbound_batch_metals x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.output_batch_id, x.metal)) FROM output_batch_metals x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_results x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.assay_result_id, x.metal)) FROM assay_result_metals x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM inventory_movements x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_order_reservations x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_orders x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_order_lines x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM sales_settlements x WHERE x.computed_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM shipping_releases x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM invoices x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM blending_plans x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM processing_runs x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM warehouse_requests x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM receipt_price_requests x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM assay_disputes x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM expenses x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM payments x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_entries x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM journal_lines x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM suppliers x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM customers x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM materials x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.id)) FROM metal_prices x WHERE x.created_at < v_t0),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM substances x),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.code)) FROM permissions x),
    (SELECT md5(string_agg(to_jsonb(x)::text, '|' ORDER BY x.role_id, x.permission_code)) FROM role_permissions x
      WHERE x.role_id IN (SELECT id FROM roles WHERE code NOT LIKE 'probe-%')),
    (SELECT md5(to_jsonb(x)::text) FROM finance_settings x),
    (SELECT md5(to_jsonb(x)::text) FROM ingest_settings x)))
$f$;
GRANT EXECUTE ON FUNCTION pg_temp.as_(text), pg_temp.me_() TO authenticated;

CREATE TEMP TABLE mes6b1_roles (who text, role text, codes integer, ncr_list boolean, ncr_rows bigint, hold_line bigint,
    limit_rows bigint, inbound_form boolean, output_form boolean, open_ncr boolean, decide_ncr boolean) ON COMMIT DROP;
GRANT INSERT ON mes6b1_roles TO authenticated;

DO $live$
DECLARE
    v_base text := (SELECT code FROM currencies WHERE is_base);
    v_t0 timestamptz := now();
    v_today date := CURRENT_DATE;
    v_ad date := DATE '2026-09-15';     -- 化验日:9 月计价期(LME 日历 + 每个交易日的 ni 报价,都是我插的)
    sup uuid; mat uuid; cust uuid; loc uuid;
    ib_n uuid; ib_s uuid; ob1 uuid; ob2 uuid;
    con uuid; con2 uuid; so uuid; l1 uuid; inv uuid; rel uuid; r1 uuid; tr uuid; wr uuid;
    a1 uuid; a_ib uuid; a_ob uuid; n_sys uuid; n_man uuid;
    v_msg text; v_msg2 text; v_j jsonb; v_j2 jsonb; v_rec text; v_t text; v_n bigint; v_fp text;
    v_pending text := (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    r record;
BEGIN
    v_fp := pg_temp.fp_(v_t0);
    v_rec := pg_temp.agree_('start');
    RAISE NOTICE 'STEP|start|%', v_rec;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6B1_LIVE|approvals are off on live'; END IF;
    IF EXISTS (SELECT 1 FROM nonconformance_reports) OR EXISTS (SELECT 1 FROM contract_quality_limits) OR EXISTS (SELECT 1 FROM quality_limit_judgements) THEN
        RAISE EXCEPTION 'MES6B1_LIVE|live already has an NCR, a quality limit or a judgement — this proof expects none';
    END IF;
    IF EXISTS (SELECT 1 FROM metal_prices WHERE metal = 'ni' AND price_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30')
       OR EXISTS (SELECT 1 FROM index_market_calendar WHERE index_code = 'LME' AND calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30') THEN
        RAISE EXCEPTION 'MES6B1_LIVE|live now has an ni quote or an LME calendar day in September 2026 — pick other dates';
    END IF;
    IF (SELECT string_agg(r2.code, ',' ORDER BY r2.code) FROM role_permissions rp JOIN roles r2 ON r2.id = rp.role_id
         WHERE rp.permission_code = 'action.ncr_decide' AND r2.code NOT LIKE 'probe-%') IS DISTINCT FROM 'admin,cco,cto' THEN
        RAISE EXCEPTION 'MES6B1_LIVE|action.ncr_decide should be held by exactly admin, cco, cto';
    END IF;

    -- ══ 布景(属主) ══
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type, default_tax_code)
    VALUES ('ZZ-PROBE-MES6B1-S', 'ZZ-PROBE-MES6B1 goods supplier', 'SG', 'active', 'goods_supplier', 'OP') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-PROBE-MES6B1-BM', 'ZZ-PROBE-MES6B1 black mass', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO mat;
    INSERT INTO customers (code, legal_name, country, payment_terms_days, default_tax_code) VALUES ('ZZ-PROBE-MES6B1-C', 'ZZ-PROBE-MES6B1 customer', 'SG', 30, 'SR') RETURNING id INTO cust;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ-PROBE-MES6B1-L', 'ZZ-PROBE-MES6B1 shelf') RETURNING id INTO loc;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (mat, sup, 100, 100, 'kg', v_today - 5, 'other', 'ZZ-PROBE-MES6B1 manual NCR') RETURNING id INTO ib_n;
    INSERT INTO inbound_batches (material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (mat, sup, 100, 100, 'kg', v_today - 5, 'other', 'ZZ-PROBE-MES6B1 supplement') RETURNING id INTO ib_s;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (ib_n, 'discharged_verified'), (ib_s, 'discharged_verified');
    -- 产出批经 create_output_batch(它连同那一笔产出的流水一起落;rec 持 module.output.edit)
    ob1 := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 10000, 'kg', %L, p_notes => 'ZZ-PROBE-MES6B1 limit')$q$, mat, v_today - 3)) ->> 'batch_id')::uuid;
    ob2 := (pg_temp.get_('rec', format($q$SELECT create_output_batch(%L, 100, 'kg', %L, p_notes => 'ZZ-PROBE-MES6B1 supplement')$q$, mat, v_today - 3)) ->> 'batch_id')::uuid;
    INSERT INTO index_market_calendar (index_code, calendar_date, is_trading_day, note)
    SELECT 'LME', d::date, EXTRACT(ISODOW FROM d) < 6, 'ZZ-PROBE-MES6B1' FROM generate_series(DATE '2026-09-01', DATE '2026-09-30', interval '1 day') d;
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source, price_index)
    SELECT 'ni', 10000, c.calendar_date, 'published_index', 'LME'
      FROM index_market_calendar c WHERE c.index_code = 'LME' AND c.is_trading_day AND c.calendar_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30';
    RAISE NOTICE 'STEP|setup|inbound % (manual NCR) / % (supplement) · output % (limit) / % (supplement) · own LME September calendar and ni quotes (live had none)',
        (SELECT code FROM inbound_batches WHERE id = ib_n), (SELECT code FROM inbound_batches WHERE id = ib_s),
        (SELECT code FROM output_batches WHERE id = ob1), (SELECT code FROM output_batches WHERE id = ob2);

    -- ══ ① V17 · 申请生效;F4 ══
    PERFORM pg_temp.as_('cco');
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (cust, 'offtake', 'ZZ-PROBE-MES6B1 offtake (moisture limit)', DATE '2026-01-01', 'draft') RETURNING id INTO con;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (con, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis)
    VALUES (con, 'dry', 'ours', false, 'none_agreed', 'none_agreed');
    PERFORM pg_temp.me_();
    v_t := array_to_string(contract_activation_missing(con), ',');
    v_msg := pg_temp.try_('cco', format($q$SELECT submit_contract_activation_request(%L, 'ZZ-PROBE-MES6B1')$q$, con));
    IF v_t <> 'quality_limit_basis' OR v_msg <> 'CONTRACT_TERMS_INCOMPLETE|' || (SELECT code FROM contracts WHERE id = con) || '|quality_limit_basis' THEN
        RAISE EXCEPTION 'MES6B1_LIVE|activation with the basis unset: checklist «%» · refusal «%»', v_t, v_msg;
    END IF;
    -- F4:罚铜收;再给铜计价 → 按名拒
    v_msg2 := pg_temp.try_('cco', format($q$INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (%L, 'cu', 2, 150)$q$, con));
    v_t := pg_temp.try_('cco', format($q$INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (%L, 'cu', 'assay_complete', 0, 'LME', 50)$q$, con));
    IF v_msg2 <> 'OK' OR v_t <> 'SUBSTANCE_PRICED_AND_PENALISED|cu' OR EXISTS (SELECT 1 FROM contract_pricing_terms WHERE contract_id = con AND metal = 'cu') THEN
        RAISE EXCEPTION 'MES6B1_LIVE|copper as a penalty element «%» · copper priced as well «%»', v_msg2, v_t;
    END IF;
    v_msg2 := pg_temp.try_('cco', format($q$UPDATE contract_settlement_terms SET quality_limit_basis = 'per_parameter', penalty_basis = 'per_element' WHERE contract_id = %L$q$, con));
    IF v_msg2 <> 'OK' THEN RAISE EXCEPTION 'MES6B1_LIVE|setting the basis: «%»', v_msg2; END IF;
    v_t := array_to_string(contract_activation_missing(con), ',');
    v_msg := pg_temp.try_('cco', format($q$SELECT submit_contract_activation_request(%L, 'ZZ-PROBE-MES6B1')$q$, con));
    IF v_t <> 'quality_limits' OR v_msg <> 'QUALITY_LIMITS_NOT_FILED|' || (SELECT code FROM contracts WHERE id = con) THEN
        RAISE EXCEPTION 'MES6B1_LIVE|per_parameter with no rows: checklist «%» · refusal «%»', v_t, v_msg;
    END IF;
    v_msg2 := pg_temp.try_('cco', format($q$INSERT INTO contract_quality_limits (contract_id, parameter, max_value, notes) VALUES (%L, 'moisture_pct', 8, 'ZZ-PROBE-MES6B1')$q$, con));
    v_j := pg_temp.get_('cco', format($q$SELECT submit_contract_activation_request(%L, 'ZZ-PROBE-MES6B1')$q$, con));
    IF v_msg2 <> 'OK' OR (v_j ->> 'status') <> 'submitted' THEN RAISE EXCEPTION 'MES6B1_LIVE|the complete contract asks the CFO: limit «%» · request %', v_msg2, v_j; END IF;
    tr := (v_j ->> 'request_id')::uuid;
    v_msg := pg_temp.try_('cfo', format($q$SELECT decide_terms_request(%L, true)$q$, tr));
    IF v_msg <> 'OK' OR (SELECT status FROM contracts WHERE id = con) <> 'active' THEN RAISE EXCEPTION 'MES6B1_LIVE|the CFO activates it: «%»', v_msg; END IF;
    RAISE NOTICE 'STEP|activation|% refused with the basis unset («%» first) and with per_parameter and no row (QUALITY_LIMITS_NOT_FILED) · copper named as a penalty, priced copper refused (SUBSTANCE_PRICED_AND_PENALISED|cu) · moisture ≤ 8 filed → % → the CFO approved → active',
        (SELECT code FROM contracts WHERE id = con), 'CONTRACT_TERMS_INCOMPLETE', (v_j ->> 'label');

    -- ══ ② 判定:化验在先,预留时判 ══
    PERFORM pg_temp.as_('sal');
    so := (create_sales_order(cust, v_today - 4, v_base, 1, jsonb_build_array(jsonb_build_object('material_id', mat, 'quantity', 10000, 'unit_price', 1)),
                              'ZZ-PROBE-MES6B1') ->> 'id')::uuid;
    SELECT id INTO l1 FROM sales_order_lines WHERE sales_order_id = so;
    PERFORM set_sales_order_status(so, 'confirmed');
    PERFORM link_document_to_contract('sales_order', so, con);
    PERFORM pg_temp.me_();
    v_j := pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => %L, p_output_batch_id => %L, p_weight_basis => 'dry', p_moisture_pct => 9.2,
              p_result_party => 'ours', p_metals => '[{"metal": "ni", "content_pct": 20}, {"metal": "cu", "content_pct": 3}]'::jsonb)$q$, v_ad, ob1));
    a1 := (v_j ->> 'assay_result_id')::uuid;
    IF (v_j ->> 'quality_judged')::int <> 0 THEN RAISE EXCEPTION 'MES6B1_LIVE|nothing is reserved yet, so nothing is judged at recording, got %', v_j; END IF;
    v_j := pg_temp.get_('sal', format($q$SELECT reserve_stock(%L, %L, 9000)$q$, l1, ob1));
    r1 := (v_j ->> 'reservation_id')::uuid;
    SELECT id INTO n_sys FROM nonconformance_reports WHERE code = v_j -> 'ncrs_opened' ->> 0;
    IF (v_j ->> 'quality_judged')::int <> 1 OR jsonb_array_length(v_j -> 'ncrs_opened') <> 1 OR r1 IS NULL
       OR (SELECT released_at FROM sales_order_reservations WHERE id = r1) IS NOT NULL
       OR (SELECT result || ':' || value || ':' || limit_max_at || ':' || trigger_event FROM quality_limit_judgements WHERE assay_result_id = a1) <> 'above_max:9.2:8:reserved'
       OR (SELECT source || ':' || COALESCE(opened_by::text, 'system') || ':' || status FROM nonconformance_reports WHERE id = n_sys) <> 'quality_limit:system:open'
       OR (SELECT sales_order_id FROM nonconformance_reports WHERE id = n_sys) <> so OR (SELECT assay_result_id FROM nonconformance_reports WHERE id = n_sys) <> a1 THEN
        RAISE EXCEPTION 'MES6B1_LIVE|reserving a batch whose assay breaches the limit keeps the reservation and opens a system NCR, got %', v_j;
    END IF;
    RAISE NOTICE 'STEP|judged|rec recorded % on % (moisture 9.2, ni 20, cu 3) · sal reserved 9,000 kg of 10,000 on % → judged above_max (9.2 > 8, trigger reserved) · reservation kept · % opened by the system: «%»',
        (SELECT code FROM assay_results WHERE id = a1), (SELECT code FROM output_batches WHERE id = ob1), (SELECT code FROM sales_orders WHERE id = so),
        (SELECT code FROM nonconformance_reports WHERE id = n_sys), (SELECT description FROM nonconformance_reports WHERE id = n_sys);

    -- ══ ③ 暂扣 —— 产出那一批:结算、发货按名拒,转移放行 ══
    v_msg := pg_temp.try_('sal', format($q$SELECT sale_settlement_compute(%L, %L, %L)$q$, so, ob1, a1));
    v_msg2 := pg_temp.try_('sal', format($q$SELECT record_sale_settlement(%L, %L, %L)$q$, so, ob1, a1));
    v_t := 'QUALITY_HOLD_OPEN|' || (SELECT code FROM output_batches WHERE id = ob1) || '|' || (SELECT code FROM nonconformance_reports WHERE id = n_sys);
    IF v_msg <> v_t OR v_msg2 <> v_t OR EXISTS (SELECT 1 FROM sales_settlements WHERE sales_order_id = so) THEN
        RAISE EXCEPTION 'MES6B1_LIVE|settlement while held: preview «%» · record «%» (expected «%»)', v_msg, v_msg2, v_t;
    END IF;
    v_j := pg_temp.get_('fin', format($q$SELECT create_order_invoice(%L, %L)$q$, so, v_today));
    inv := (v_j ->> 'invoice_id')::uuid;
    v_rec := pg_temp.agree_('invoice');
    v_j := pg_temp.get_('sal', format($q$SELECT submit_shipping_release(%L)$q$, so));
    rel := (v_j ->> 'release_id')::uuid;
    v_msg := pg_temp.try_('cfo', format($q$SELECT decide_shipping_release(%L, true)$q$, rel));
    IF (v_j ->> 'status') <> 'submitted' OR v_msg <> 'OK' THEN RAISE EXCEPTION 'MES6B1_LIVE|shipping release: % · decision «%»', v_j, v_msg; END IF;
    v_msg := pg_temp.try_('wh', format($q$SELECT ship_order(%L, %L, %L::jsonb)$q$, so, v_today, jsonb_build_array(jsonb_build_object('reservation_id', r1, 'qty', 9000))));
    IF v_msg <> v_t THEN RAISE EXCEPTION 'MES6B1_LIVE|shipping a held reserved batch: «%»', v_msg; END IF;
    v_msg2 := pg_temp.try_('wh', format($q$SELECT create_stock_transfer(10, %L, p_output_batch_id => %L)$q$, loc, ob1));
    IF v_msg2 <> 'OK' THEN RAISE EXCEPTION 'MES6B1_LIVE|a transfer stays allowed under the hold: «%»', v_msg2; END IF;
    RAISE NOTICE 'STEP|held output|settlement preview and record refused «%» · invoiced % (reconciliation %) · release % approved by the CFO · shipping refused by name · a 10 kg transfer of the unreserved 1,000 kg allowed',
        v_t, (SELECT code FROM invoices WHERE id = inv), v_rec, (SELECT label FROM shipping_releases WHERE id = rel);

    -- ══ ③ 暂扣 —— 进料那一批:手工报告;投料、配料按名拒,转移放行;开单人决定不了 ══
    v_j := pg_temp.get_('qe', format($q$SELECT open_ncr('manual', 'ZZ-PROBE-MES6B1 wet sacks on arrival', p_inbound_batch_id => %L)$q$, ib_n));
    n_man := (v_j ->> 'ncr_id')::uuid;
    v_t := 'QUALITY_HOLD_OPEN|' || (SELECT code FROM inbound_batches WHERE id = ib_n) || '|' || (v_j ->> 'code');
    v_msg := pg_temp.try_('pc', format($q$SELECT commit_processing_run(CURRENT_DATE - 1, 'ZZ-PROBE-MES6B1 run', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 40)),
        'weight', NULL, NULL, 'manual_disassembly', p_started_at => (CURRENT_DATE - 1)::timestamptz,
        p_ended_at => (CURRENT_DATE - 1)::timestamptz + interval '1 hour', p_shift_code => 'day')$q$, ib_n, mat));
    v_msg2 := pg_temp.try_('wo', format($q$SELECT create_blending_plan(%L, %L::jsonb, '[{"metal":"ni","min_pct":10}]'::jsonb)$q$,
             mat, jsonb_build_array(jsonb_build_object('inbound_batch_id', ib_n, 'planned_kg', 10))));
    IF v_msg <> v_t OR v_msg2 <> v_t THEN RAISE EXCEPTION 'MES6B1_LIVE|held inbound batch: consumption «%» · blending «%» (expected «%»)', v_msg, v_msg2, v_t; END IF;
    v_msg := pg_temp.try_('wh', format($q$SELECT create_stock_transfer(10, %L, p_inbound_batch_id => %L)$q$, loc, ib_n));
    v_msg2 := pg_temp.try_('qe', format($q$SELECT decide_ncr(%L, 'accept', 'my own')$q$, n_man));
    IF v_msg <> 'OK' OR v_msg2 <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'MES6B1_LIVE|transfer «%» · the opener deciding their own NCR «%»', v_msg, v_msg2;
    END IF;
    RAISE NOTICE 'STEP|held inbound|qe opened % on % · processing consumption and a blending plan refused «%» · a 10 kg transfer allowed · qe (who holds the decide code) deciding their own: «%»',
        v_j ->> 'code', (SELECT code FROM inbound_batches WHERE id = ib_n), v_t, v_msg2;

    -- ══ ⑥ 逐角色读数表(只读;两批此刻都在暂扣里 —— 产出那一批被系统那一张扣着,进料那一批被手工那一张扣着)══
    FOR r IN SELECT unnest(ARRAY['c_admin', 'c_finance', 'c_warehouse', 'c_cto', 'c_cco', 'c_cfo', 'c_gm']) AS who LOOP
        PERFORM pg_temp.as_(r.who);
        INSERT INTO mes6b1_roles
        SELECT r.who, (SELECT ro.code FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id WHERE ur.user_id = auth.uid() LIMIT 1),
               cardinality(current_user_permissions()),
               has_permission('module.quality.view'),
               (SELECT count(*) FROM ncr_rows WHERE id IN (n_sys, n_man)),
               (SELECT count(*) FROM ncr_rows WHERE id IN (n_sys, n_man) AND holding),
               (SELECT count(*) FROM contract_quality_limits WHERE contract_id = con),
               has_permission('module.inbound.edit'), has_permission('module.output.edit'),
               has_permission('module.quality.edit'), has_permission('action.ncr_decide');
        PERFORM pg_temp.me_();
    END LOOP;
    FOR r IN SELECT * FROM mes6b1_roles LOOP
        RAISE NOTICE 'ROLE|%|% (% codes)|NCR list %|NCR rows readable %/2|batch-page hold lines readable %/2|contract quality limits %|inbound assay form %|output assay form %|open an NCR %|decide an NCR %',
            r.who, r.role, r.codes, r.ncr_list, r.ncr_rows, r.hold_line, r.limit_rows, r.inbound_form, r.output_form, r.open_ncr, r.decide_ncr;
    END LOOP;

    -- ══ ④ 决定:接受系统那一张 → 发货、结算;拒收手工那一张 → 仍扣着,注销申请批过 → 结束 ══
    v_j := pg_temp.get_('qd', format($q$SELECT decide_ncr(%L, 'accept', 'ZZ-PROBE-MES6B1 buyer accepts this lot at 9.2')$q$, n_sys));
    IF (v_j ->> 'batch_still_held')::boolean THEN RAISE EXCEPTION 'MES6B1_LIVE|accepting releases the batch, got %', v_j; END IF;
    v_msg := pg_temp.try_('wh', format($q$SELECT ship_order(%L, %L, %L::jsonb)$q$, so, v_today, jsonb_build_array(jsonb_build_object('reservation_id', r1, 'qty', 8990))));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'MES6B1_LIVE|once accepted the reservation ships: «%»', v_msg; END IF;
    v_rec := pg_temp.agree_('shipped after the decision');
    v_j := pg_temp.get_('sal', format($q$SELECT sale_settlement_compute(%L, %L, %L)$q$, so, ob1, a1));
    -- 手算:结算重量 = 干基;ni 计价、铜只罚。铜 3 % 超阈值 2 % 一个百分点 × 结算吨 × 150。
    IF (SELECT string_agg(e ->> 'metal', ',') FROM jsonb_array_elements(v_j -> 'breakdown' -> 'metals') e) <> 'ni'
       OR (SELECT string_agg(e ->> 'substance', ',') FROM jsonb_array_elements(v_j -> 'breakdown' -> 'penalties') e) <> 'cu'
       OR (v_j ->> 'penalty_usd')::numeric <> round(1 * ((v_j ->> 'settlement_weight_kg')::numeric / 1000) * 150, 2)
       OR (v_j ->> 'penalty_usd')::numeric <= 0
       OR (v_j ->> 'amount_usd')::numeric <> (v_j ->> 'metal_value_usd')::numeric - (v_j ->> 'refining_charge_usd')::numeric - (v_j ->> 'penalty_usd')::numeric THEN
        RAISE EXCEPTION 'MES6B1_LIVE|settlement: copper penalised and not priced, got metals % penalties % weight % penalty % amount %',
            v_j -> 'breakdown' -> 'metals', v_j -> 'breakdown' -> 'penalties', v_j ->> 'settlement_weight_kg', v_j ->> 'penalty_usd', v_j ->> 'amount_usd';
    END IF;
    RAISE NOTICE 'STEP|released|qd accepted % → shipped 8,990 kg (reconciliation %) · settlement computes: metal value % USD (ni only) − refining % − penalty % (cu only, 1 point over on % kg) = % USD',
        (SELECT code FROM nonconformance_reports WHERE id = n_sys), v_rec, v_j ->> 'metal_value_usd', v_j ->> 'refining_charge_usd', v_j ->> 'penalty_usd',
        v_j ->> 'settlement_weight_kg', v_j ->> 'amount_usd';
    v_j := pg_temp.get_('qd', format($q$SELECT decide_ncr(%L, 'reject', 'ZZ-PROBE-MES6B1 not processable')$q$, n_man));
    v_msg := pg_temp.try_('pc', format($q$SELECT commit_processing_run(CURRENT_DATE - 1, 'ZZ-PROBE-MES6B1 run', NULL,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 50)),
        jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 40)),
        'weight', NULL, NULL, 'manual_disassembly', p_started_at => (CURRENT_DATE - 1)::timestamptz,
        p_ended_at => (CURRENT_DATE - 1)::timestamptz + interval '1 hour', p_shift_code => 'day')$q$, ib_n, mat));
    IF NOT (v_j ->> 'batch_still_held')::boolean OR v_msg NOT LIKE 'QUALITY_HOLD_OPEN|%' THEN
        RAISE EXCEPTION 'MES6B1_LIVE|reject keeps the hold while stock remains: % · consumption «%»', v_j, v_msg;
    END IF;
    v_j := pg_temp.get_('wh', format($q$SELECT submit_inbound_write_off_request(%L, 'ZZ-PROBE-MES6B1 rejected')$q$, ib_n));
    wr := (v_j ->> 'request_id')::uuid;
    v_msg := pg_temp.try_('cfo', format($q$SELECT decide_warehouse_request(%L, true)$q$, wr));
    IF (v_j ->> 'status') <> 'submitted' OR v_msg <> 'OK' OR EXISTS (SELECT 1 FROM batch_quality_hold(ib_n, NULL)) THEN
        RAISE EXCEPTION 'MES6B1_LIVE|the CFO write-off ends the hold: % · decision «%»', v_j, v_msg;
    END IF;
    v_rec := pg_temp.agree_('write-off of a rejected batch');
    RAISE NOTICE 'STEP|rejected|qd rejected % → still held, consumption still refused · wh asked % → the CFO approved → batch % written off (remaining %, deleted %) → no longer held · reconciliation %',
        (SELECT code FROM nonconformance_reports WHERE id = n_man), v_j ->> 'label', (SELECT code FROM inbound_batches WHERE id = ib_n),
        (SELECT remaining_qty FROM inbound_batches WHERE id = ib_n), (SELECT deleted_at IS NOT NULL FROM inbound_batches WHERE id = ib_n), v_rec;

    -- ══ ⑤ F5:只测 f、cl 的化验是补充 ══
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source) VALUES (ib_s, 'ni', 30, 'manual'), (ib_s, 'f', 0.02, 'manual');
    INSERT INTO output_batch_metals (output_batch_id, metal, content_pct, content_source) VALUES (ob2, 'ni', 20, 'manual'), (ob2, 'f', 0.02, 'manual');
    a_ib := (pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE, p_inbound_batch_id => %L, p_weight_basis => 'dry', p_result_party => 'ours',
               p_metals => '[{"metal": "f", "content_pct": 0.0123}, {"metal": "cl", "content_pct": 0.004}]'::jsonb)$q$, ib_s)) ->> 'assay_result_id')::uuid;
    a_ob := (pg_temp.get_('rec', format($q$SELECT record_assay_result(p_assay_date => CURRENT_DATE, p_output_batch_id => %L, p_weight_basis => 'dry', p_result_party => 'ours',
               p_metals => '[{"metal": "f", "content_pct": 0.0123}, {"metal": "cl", "content_pct": 0.004}]'::jsonb)$q$, ob2)) ->> 'assay_result_id')::uuid;
    v_j := pg_temp.get_('apl', format($q$SELECT preview_assay_price(%L, '[{"metal": "f", "content_pct": 0.0123}, {"metal": "cl", "content_pct": 0.004}]'::jsonb, CURRENT_DATE)$q$, ib_s));
    v_j2 := pg_temp.get_('apl', format($q$SELECT preview_apply_output_assay(%L, %L)$q$, ob2, a_ob));
    IF (v_j ->> 'supplement')::boolean IS NOT TRUE OR v_j -> 'replaces' <> '["cl", "f"]'::jsonb
       OR (v_j2 ->> 'supplement')::boolean IS NOT TRUE OR v_j2 -> 'replaces' <> '["cl", "f"]'::jsonb THEN
        RAISE EXCEPTION 'MES6B1_LIVE|both previews say supplement, replaces cl and f: % · %', v_j, v_j2;
    END IF;
    v_j := pg_temp.get_('apl', format($q$SELECT apply_assay_result(%L)$q$, a_ib));
    v_j2 := pg_temp.get_('apl', format($q$SELECT apply_output_assay(%L)$q$, a_ob));
    IF (SELECT string_agg(metal || '=' || content_pct || '=' || content_source, ',' ORDER BY metal) FROM inbound_batch_metals WHERE inbound_batch_id = ib_s)
         <> 'cl=0.004=assay,f=0.0123=assay,ni=30=manual'
       OR (SELECT string_agg(metal || '=' || content_pct || '=' || content_source, ',' ORDER BY metal) FROM output_batch_metals WHERE output_batch_id = ob2)
         <> 'cl=0.004=assay,f=0.0123=assay,ni=20=manual'
       OR EXISTS (SELECT 1 FROM receipt_price_requests WHERE inbound_batch_id = ib_s) THEN
        RAISE EXCEPTION 'MES6B1_LIVE|a penalty-only assay replaces only F and Cl on both sides and prices nothing: % · %', v_j, v_j2;
    END IF;
    RAISE NOTICE 'STEP|supplement|inbound %: ni 30 (manual) · f 0.02 → apply % (f 0.0123, cl 0.004) → cl 0.004 · f 0.0123 · ni 30 unchanged, no price request · output %: same, ni 20 unchanged · both previews said supplement, replaces cl, f',
        (SELECT code FROM inbound_batches WHERE id = ib_s), (SELECT code FROM assay_results WHERE id = a_ib), (SELECT code FROM output_batches WHERE id = ob2);

    -- ══ 在册的东西一个字都没动 ══
    IF pg_temp.fp_(v_t0) IS DISTINCT FROM v_fp THEN
        RAISE EXCEPTION 'MES6B1_LIVE|a pre-existing contract, term, batch, content, assay, movement, reservation, order, settlement, release, invoice, plan, run, request, dispute, expense, payment, journal, supplier, customer, material, quote, substance, permission, grant or setting changed';
    END IF;
    IF (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents()) <> v_pending THEN
        RAISE EXCEPTION 'MES6B1_LIVE|pending documents changed: % → %', v_pending,
            (SELECT COALESCE(string_agg(subject_type || ':' || code, ',' ORDER BY code), '') FROM approval_pending_documents());
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN RAISE EXCEPTION 'MES6B1_LIVE|require_calibrated_since set'; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'MES6B1_LIVE|approvals switched off'; END IF;
    v_rec := pg_temp.agree_('end');
    RAISE NOTICE 'STEP|untouched|pre-existing rows identical; pending %; approvals on; reconciliation %', v_pending, v_rec;

    -- ══ ⑦ 最后一格:条款表之外写进去的"既计价又罚" —— 申请生效按名拒(守卫关掉一格,随即打开;锁持到回滚)══
    PERFORM pg_temp.as_('cco');
    INSERT INTO contracts (customer_id, kind, title, effective_from, status)
    VALUES (cust, 'offtake', 'ZZ-PROBE-MES6B1 offtake (priced and penalised)', DATE '2026-01-01', 'draft') RETURNING id INTO con2;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (con2, 'ni', 'assay_complete', 0, 'LME', 70);
    INSERT INTO contract_settlement_terms (contract_id, sale_weight_basis, settling_party, sample_retention_required, refining_charge_basis, penalty_basis, quality_limit_basis)
    VALUES (con2, 'dry', 'ours', false, 'none_agreed', 'per_element', 'none_agreed');
    INSERT INTO contract_penalty_elements (contract_id, substance, threshold_pct, usd_per_tonne_per_pct_over) VALUES (con2, 'cu', 2, 150);
    PERFORM pg_temp.me_();
    ALTER TABLE contract_pricing_terms DISABLE TRIGGER trg_contract_pricing_terms_unpenalised;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct) VALUES (con2, 'cu', 'assay_complete', 0, 'LME', 50);
    ALTER TABLE contract_pricing_terms ENABLE TRIGGER trg_contract_pricing_terms_unpenalised;
    v_t := array_to_string(contract_activation_missing(con2), ',');
    v_msg := pg_temp.try_('cco', format($q$SELECT submit_contract_activation_request(%L, 'ZZ-PROBE-MES6B1')$q$, con2));
    IF v_t <> 'priced_and_penalised:cu' OR v_msg <> 'SUBSTANCE_PRICED_AND_PENALISED|cu' THEN
        RAISE EXCEPTION 'MES6B1_LIVE|a contract that prices and penalises copper: checklist «%» · activation «%»', v_t, v_msg;
    END IF;
    RAISE NOTICE 'STEP|priced and penalised|% with copper in both tables (the guard switched off for one insert, then on again): checklist «%» · activation refused «%»',
        (SELECT code FROM contracts WHERE id = con2), v_t, v_msg;
    RAISE NOTICE 'STEP|done|%', clock_timestamp() - v_t0;
END
$live$;

ROLLBACK;

SELECT 'AFTER|NCRs=' || (SELECT count(*) FROM nonconformance_reports)
    || '|quality limits=' || (SELECT count(*) FROM contract_quality_limits)
    || '|judgements=' || (SELECT count(*) FROM quality_limit_judgements)
    || '|probe suppliers=' || (SELECT count(*) FROM suppliers WHERE code LIKE 'ZZ-PROBE-MES6B1%')
    || '|probe customers=' || (SELECT count(*) FROM customers WHERE code LIKE 'ZZ-PROBE-MES6B1%')
    || '|probe contracts=' || (SELECT count(*) FROM contracts WHERE title LIKE 'ZZ-PROBE-MES6B1%')
    || '|probe batches=' || ((SELECT count(*) FROM inbound_batches WHERE source_reason_note LIKE 'ZZ-PROBE-MES6B1%') + (SELECT count(*) FROM output_batches WHERE notes LIKE 'ZZ-PROBE-MES6B1%'))
    || '|probe materials=' || (SELECT count(*) FROM materials WHERE code LIKE 'ZZ-PROBE-MES6B1%')
    || '|ni quotes in September 2026=' || (SELECT count(*) FROM metal_prices WHERE metal = 'ni' AND price_date BETWEEN DATE '2026-09-01' AND DATE '2026-09-30')
    || '|pricing guard enabled=' || (SELECT tgenabled::text FROM pg_trigger WHERE tgname = 'trg_contract_pricing_terms_unpenalised')
    || '|require_calibrated_since=' || COALESCE((SELECT require_calibrated_since::text FROM ingest_settings), 'NULL');

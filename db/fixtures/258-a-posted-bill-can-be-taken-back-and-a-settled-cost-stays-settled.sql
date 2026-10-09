-- 258 MES-5b-2:一张过了账的电费单可以整张撤回(带理由),撤回之后同一段时间能再过一张改正过的;冲掉一张月结冲抵,它冲抵掉的估计
--     能再冲抵一次;经付款结过的费用单先冲付款;结算戳只经财务函数改(MES-5b Step 0 Q21–Q29 · Q32 · Q35,Tim;v1.4.46)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-09-mes5b2-fixture-injections.py)必须让它红在它点名的那一臂。
--   PERM   撤回要 module.finance.edit、要理由;过账也要 module.finance.view(Q28);reverse_expense 拒电费单的费用单并点出那张分摊(Q22)
--   UNPAID 一张未付的电费单撤回:费用单与分录冲掉(镜像费用单、原分录 reversed);各炉的实际电费行清戳并软删;被冲掉的估计清戳、
--          取消软删、明写重新计提(借 5110 / 贷 2200,一条一张);一行撤回记录(件数、金额);2200 · 5110 · 6200 · 2000 回到过账之前;
--          那几炉的成本行回到过账之前(估计在、实际不在);一炉的电不再读那一张;撤回过的不能再撤(Q22)
--   REPOST 撤回之后同一段时间再过一张改正过的:过得去,估计被它再冲一次;一炉两行(一张撤回过、一张没有),电只读没撤回的那一张;
--          往一张没撤回的分摊里的炉再插一行 → ELECTRICITY_RUN_ALREADY_ALLOCATED(守卫,取代唯一约束)(Q23)
--   PAID   一张已付(本位币银行)的电费单:借 2200 / 借 6200 / 贷 银行;撤回借回银行;镜像费用单已付、带银行(Q24)
--   F2     冲掉一张月结冲抵:它冲抵过的估计清戳、回到"未结"、能再冲抵一次;不过分录(冲掉的那张分录已还回 2200);
--          那一炉此后被一张没撤回的电费分摊覆盖了 → RELIEF_ESTIMATE_NOW_ALLOCATED(点出那一炉与那张单);撤回那张单之后就冲得掉(Q21)
--   VAR    偏差视图不算冲销过的冲抵 —— 包括戳没清掉的那一种(本刀之前冲销的)(Q21)
--   CCY    冲抵的费用单币种从数据读:把本位币换成另一种,冲抵出来的费用单就是那一种(Q21 · MES-5a Q35)
--   LOCK   冲销日在锁住的期间里 → PERIOD_LOCKED,什么都没动(Q22)
--   KINDS  经付款结过的费用单【每一种】都按名拒 EXPENSE_HAS_SETTLEMENT(普通 · 欠员工 · 月结冲抵 · 资本追加 · 电费分摊);部分付也拒;
--          冲抵过预付款的拒 EXPENSE_HAS_PREPAYMENT_APPLIED;先冲掉付款,冲得掉(Q24)
--   GUARD  加工编辑者直连改结算戳(清汇出 · 盖冲抵 · 清冲抵)或插一条带戳的行 → COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY;
--          连属主也一样;改一条没结的估计的金额照常;一支财务函数跑完之后标记不留下来(Q26)
--          五支财务函数各自动得了戳:relieve(盖冲抵)· remit(盖汇出)· post(插已结的行 + 盖冲抵)· reverse_expense(清冲抵)·
--          reverse_electricity_allocation(清两种)—— 在用到它们的那几臂里各自被走到,GUARD 末尾再总的断言一次(Q26)
--   MASK   没有 data.view_prices 的读者:撤回记录的三列金额为空、件数照见;三列不在列级授权里(Q32)
--   LOG    撤回进变更记录(覆盖零缺口、豁免仍是 8);审计记录:撤回在那张单上、也在它覆盖过的炉上;V37 的改动在工序页自己的记录上(Q27 · Q32)
--   AGREE  每一步之后:应付清单 = 总账,两边 unexplained 0.00
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的调用真的切成 authenticated + 那个人的 JWT。
-- 【数怎么来的】(README 第 1 条)
--   机器 A(表 1000 → 1300 = 300 kWh;两炉都没记电量 → 按运行时长 60 / 120 分钟:100 / 200 kWh)。
--     账单一(未付):600 / 400 kWh,单价 1.5:r1 150.00 · r2 300.00 · 6200 150.00;估计 e1 120 · e2 250 被冲掉(370)。
--     改正过的账单:640 / 400 kWh,单价 1.6:r1 160.00 · r2 320.00 · 6200 160.00。
--   机器 B(表 50 → 150 = 100 kWh;两炉各 60 分钟:50 / 50)。账单二(已付):300 / 200 kWh,单价 1.5:r3 75.00 · r5 75.00 · 6200 150.00;
--     估计 e3 90 被冲掉;r5 的估计 e7 60 在过账之前已被月结冲抵 W(70)冲抵过 —— 所以它不再被账单二冲(已结),而 W 从此冲不掉。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f258_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人跑一句;返回 'OK' 或错误原文。之后身份回到调用之前的那一个。
CREATE FUNCTION pg_temp.f258_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f258_as(p_user);
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

-- 以某人读一个值(读不到就抛 —— 读的失败不许被读成一个答案)
CREATE FUNCTION pg_temp.f258_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f258_as(p_user);
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

-- 一个科目在总账上的余额(借 − 贷,本位币)
CREATE FUNCTION pg_temp.f258_bal(p_code text) RETURNS numeric
LANGUAGE sql AS $f$
    SELECT COALESCE(sum(l.debit - l.credit), 0)
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE a.code = p_code
$f$;

-- 应付清单 = 总账,两边 unexplained 0.00(以全码那个人的会话读 —— 那支函数按读者的码过滤)
CREATE FUNCTION pg_temp.f258_agree(p_user uuid, p_step text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; s jsonb;
BEGIN
    v := pg_temp.f258_get(p_user, $q$SELECT list_ledger_reconciliation()$q$);
    IF jsonb_array_length(v -> 'sides') <> 2 THEN RAISE EXCEPTION 'FIXTURE 258 AGREE %: expected two sides, got %', p_step, v; END IF;
    FOR s IN SELECT * FROM jsonb_array_elements(v -> 'sides') LOOP
        IF s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0 THEN
            RAISE EXCEPTION 'FIXTURE 258 AGREE %: % side list % / ledger % / unexplained % (refusal %)', p_step, s ->> 'side',
                s ->> 'list_base', s ->> 'ledger_base', s ->> 'unexplained_base', s ->> 'refusal';
        END IF;
    END LOOP;
END;
$f$;

DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 全部码
    u_fview uuid := gen_random_uuid();   -- 只看财务(撤不了)
    u_fedit uuid := gen_random_uuid();   -- 只有财务编辑、没有财务查看(Q28)
    u_pedit uuid := gen_random_uuid();   -- 加工查看 + 加工编辑(结算戳那扇侧门的主人)
    u_np    uuid := gen_random_uuid();   -- 看财务与加工,没有价格码
    r uuid;
    d0 date := CURRENT_DATE - 40; d1 date := CURRENT_DATE - 31;   -- 时间段一(机器 A)
    d2 date := CURRENT_DATE - 25; d3 date := CURRENT_DATE - 22;   -- 时间段二(机器 B)
    dx date := CURRENT_DATE - 6;                                    -- 费用单与冲抵的日期
    v_base text; v_other text; v_bank text; v_fbank text;
    v_sup uuid; v_emp uuid; m_mod uuid; m_bm uuid; b uuid;
    eq_a uuid; eq_b uuid; eq_c uuid; mt_a uuid; mt_b uuid;
    r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid;
    e1 uuid; e2 uuid; e3 uuid; e4 uuid; e6 uuid; e7 uuid; e8 uuid; e_lab uuid;
    v_msg text; v_j jsonb; v_x jsonb; v_n bigint; v_num numeric;
    a1 uuid; x1 uuid; je1 uuid; a1b uuid; x1b uuid; a2 uuid; x2 uuid; je2 uuid;
    w uuid; w2 uuid; rel uuid; rel2 uuid; z uuid;
    v_pay uuid; v_exp uuid; v_asset uuid; v_po uuid;
    v_b2200 numeric; v_b5110 numeric; v_b6200 numeric; v_b2000 numeric; v_bbank numeric;
    v_live_before text; v_live_after text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_other FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1;
    SELECT c INTO v_bank FROM unnest(ARRAY['1000', '1010']) c WHERE bank_native_currency(c) = v_base LIMIT 1;
    SELECT c INTO v_fbank FROM unnest(ARRAY['1000', '1010']) c WHERE bank_native_currency(c) IS DISTINCT FROM v_base LIMIT 1;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx258-all@test.local', now(), now()), (u_fview, 'fx258-fview@test.local', now(), now()),
        (u_fedit, 'fx258-fedit@test.local', now(), now()), (u_pedit, 'fx258-pedit@test.local', now(), now()),
        (u_np, 'fx258-np@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx258-all', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx258-fview', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fview, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx258-fedit', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.finance.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fedit, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx258-pedit', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view'), (r, 'module.processing.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_pedit, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx258-np', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.finance.view'), (r, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_np, r);
    -- 往来对象不经任何一个会话建(付款的职责分离认"建 / 改收款方的人不付它")
    PERFORM pg_temp.f258_as(NULL);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ258-S', 'f258 utility and goods', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZ258-E', 'f258 employee', 'full_time', 'office', d0 - 400) RETURNING id INTO v_emp;
    PERFORM pg_temp.f258_as(u_all);
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ258-MOD', 'f258 modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code) VALUES
        ('ZZ258-BM', 'f258 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_bm;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ258-B', m_mod, v_sup, 5000, 5000, 'kg', d0 - 30, 'other', 'fixture 258 自带数据') RETURNING id INTO b;
    PERFORM reprice_inbound_batch(b, 1, v_base, NULL, 'f258');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = b;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (b, 'charged_not_discharged');
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ258-EQA', 'f258 machine A', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq_a;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ258-EQB', 'f258 machine B', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq_b;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ258-EQC', 'f258 machine C (no meter)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq_c;
    mt_a := (pg_temp.f258_get(u_all, format($q$SELECT to_jsonb(save_device('{"name":"f258 meter A","kind":"meter","equipment_id":"%s"}'::jsonb))$q$, eq_a)) #>> '{}')::uuid;
    mt_b := (pg_temp.f258_get(u_all, format($q$SELECT to_jsonb(save_device('{"name":"f258 meter B","kind":"meter","equipment_id":"%s"}'::jsonb))$q$, eq_b)) #>> '{}')::uuid;
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT record_meter_reading(%L, %L, 1000)$q$, mt_a, (d0::timestamp + interval '1 hour') AT TIME ZONE 'Asia/Singapore'))
          || pg_temp.f258_do(u_all, format($q$SELECT record_meter_reading(%L, %L, 1300)$q$, mt_a, (d1::timestamp + interval '23 hours') AT TIME ZONE 'Asia/Singapore'))
          || pg_temp.f258_do(u_all, format($q$SELECT record_meter_reading(%L, %L, 50)$q$, mt_b, (d2::timestamp + interval '1 hour') AT TIME ZONE 'Asia/Singapore'))
          || pg_temp.f258_do(u_all, format($q$SELECT record_meter_reading(%L, %L, 150)$q$, mt_b, (d3::timestamp + interval '23 hours') AT TIME ZONE 'Asia/Singapore'));
    IF v_msg <> 'OKOKOKOK' THEN RAISE EXCEPTION 'FIXTURE 258 setup: readings (%)', v_msg; END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    r1 := commit_processing_run(d0 + 2, 'f258 r1', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_a, 'deep_discharge', (d0 + 2)::timestamp + interval '9 hours', (d0 + 2)::timestamp + interval '10 hours', 'day');
    r2 := commit_processing_run(d0 + 3, 'f258 r2', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_a, 'deep_discharge', (d0 + 3)::timestamp + interval '9 hours', (d0 + 3)::timestamp + interval '11 hours', 'day');
    r3 := commit_processing_run(d2 + 1, 'f258 r3', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_b, 'deep_discharge', (d2 + 1)::timestamp + interval '9 hours', (d2 + 1)::timestamp + interval '10 hours', 'day');
    r5 := commit_processing_run(d2 + 2, 'f258 r5', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_b, 'deep_discharge', (d2 + 2)::timestamp + interval '9 hours', (d2 + 2)::timestamp + interval '10 hours', 'day');
    r4 := commit_processing_run(CURRENT_DATE - 18, 'f258 r4', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_c, 'deep_discharge', (CURRENT_DATE - 18)::timestamp + interval '9 hours', (CURRENT_DATE - 18)::timestamp + interval '10 hours', 'day');
    EXECUTE 'RESET ROLE';
    -- 手敲的估计(以属主身份插,没有戳 —— 守卫只拦带戳的)
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r1, 'electricity', 120, true, 'f258 e1') RETURNING id INTO e1;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r2, 'electricity', 250, true, 'f258 e2') RETURNING id INTO e2;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r3, 'electricity', 90, true, 'f258 e3') RETURNING id INTO e3;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r4, 'electricity', 80, true, 'f258 e4') RETURNING id INTO e4;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r4, 'gas', 30, true, 'f258 e6') RETURNING id INTO e6;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r5, 'electricity', 60, true, 'f258 e7') RETURNING id INTO e7;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r4, 'other', 15, true, 'f258 e8') RETURNING id INTO e8;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r1, 'labour', 20, true, 'f258 labour estimate');
    PERFORM pg_temp.f258_agree(u_all, 'setup');

    -- ══════════════ PERM ══════════════
    RAISE NOTICE 'fixture 258 · PERM';
    v_msg := pg_temp.f258_do(u_fedit, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-258-1', 600, 400, %L, 'unpaid', NULL, %L)$q$, d0, d1, d1 + 1, v_base, v_sup));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.view%' THEN
        RAISE EXCEPTION 'FIXTURE 258 PERM: posting must also need module.finance.view (Q28), got %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocations) THEN RAISE EXCEPTION 'FIXTURE 258 PERM: a refused post left an allocation'; END IF;

    -- ══════════════ UNPAID · 过一张未付的,再整张撤回 ══════════════
    RAISE NOTICE 'fixture 258 · UNPAID';
    SELECT string_agg(id::text || ':' || amount_base || ':' || is_estimate, ',' ORDER BY id) INTO v_live_before
      FROM processing_cost_entries WHERE run_id IN (r1, r2) AND deleted_at IS NULL;
    v_b2200 := pg_temp.f258_bal('2200'); v_b5110 := pg_temp.f258_bal('5110'); v_b6200 := pg_temp.f258_bal('6200'); v_b2000 := pg_temp.f258_bal('2000');
    v_j := pg_temp.f258_get(u_all, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-258-1', 600, 400, %L, 'unpaid', NULL, %L)$q$, d0, d1, d1 + 1, v_base, v_sup));
    a1 := (v_j ->> 'allocation_id')::uuid; x1 := (v_j ->> 'expense_id')::uuid;
    SELECT journal_entry_id INTO je1 FROM electricity_allocations WHERE id = a1;
    IF (SELECT string_agg(amount::text, ',' ORDER BY amount) FROM electricity_allocation_lines WHERE allocation_id = a1) IS DISTINCT FROM '150.00,300.00'
       OR (SELECT relieved_estimate_amount FROM electricity_allocations WHERE id = a1) <> 370 THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: setup — the bill should split 150 / 300 and relieve 370 of estimates'; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'UNPAID posted');
    -- reverse_expense 拒这张费用单,并点出那张分摊(页面据此指路)
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, x1));
    IF v_msg NOT LIKE format('EXPENSE_IS_ELECTRICITY_ALLOCATION|%s|%s%%', (SELECT code FROM expenses WHERE id = x1), a1) THEN
        RAISE EXCEPTION 'FIXTURE 258 PERM: reverse_expense must refuse the allocation''s expense and name the allocation, got %', v_msg; END IF;
    v_msg := pg_temp.f258_do(u_fview, format($q$SELECT reverse_electricity_allocation(%L, 'wrong bill')$q$, a1));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.edit%' THEN RAISE EXCEPTION 'FIXTURE 258 PERM: reversing needs module.finance.edit, got %', v_msg; END IF;
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_electricity_allocation(%L, '   ')$q$, a1));
    IF v_msg NOT LIKE 'ELECTRICITY_REVERSAL_REASON_REQUIRED|%' THEN RAISE EXCEPTION 'FIXTURE 258 PERM: a reason is required, got %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_reversals) THEN RAISE EXCEPTION 'FIXTURE 258 PERM: a refused reversal left a row'; END IF;

    v_j := pg_temp.f258_get(u_all, format($q$SELECT reverse_electricity_allocation(%L, 'The utility re-issued the bill with the right meter total')$q$, a1));
    -- 费用单与分录
    IF NOT EXISTS (SELECT 1 FROM expenses WHERE id = x1 AND status = 'reversed' AND reversed_by_expense IS NOT NULL)
       OR (SELECT status FROM journal_entries WHERE id = je1) IS DISTINCT FROM 'reversed' THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: the expense and the allocation journal must be reversed (%)', v_j; END IF;
    -- 实际电费行:清戳、软删
    IF EXISTS (SELECT 1 FROM electricity_allocation_lines l JOIN processing_cost_entries c ON c.id = l.cost_entry_id
                WHERE l.allocation_id = a1 AND (c.deleted_at IS NULL OR c.remitted_at IS NOT NULL OR c.remitted_journal_entry_id IS NOT NULL)) THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: each run''s actual line must be unsettled and soft-deleted'; END IF;
    -- 估计:清戳、取消软删
    IF EXISTS (SELECT 1 FROM processing_cost_entries WHERE id IN (e1, e2) AND (deleted_at IS NOT NULL OR relieved_at IS NOT NULL OR relief_expense_id IS NOT NULL)) THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: the relieved estimates must be restored (no stamps, not deleted)'; END IF;
    -- 明写的重新计提:一条估计一张,借 5110 / 贷 2200
    IF (SELECT count(*) FROM journal_entries je WHERE je.source_type = 'processing_cost' AND je.source_id IN (e1, e2) AND je.memo LIKE 'Cost restored%') <> 2
       OR (SELECT string_agg(a.code || ':' || CASE WHEN l.debit > 0 THEN 'd' ELSE 'c' END || ':' || (l.debit + l.credit), ',' ORDER BY a.code, l.debit + l.credit)
             FROM journal_entries je JOIN journal_lines l ON l.entry_id = je.id JOIN accounts a ON a.id = l.account_id
            WHERE je.source_type = 'processing_cost' AND je.source_id IN (e1, e2) AND je.memo LIKE 'Cost restored%')
          IS DISTINCT FROM '2200:c:120.00,2200:c:250.00,5110:d:120.00,5110:d:250.00' THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: each restored estimate needs its explicit re-accrual Dr 5110 / Cr 2200'; END IF;
    -- 一行撤回记录
    IF (SELECT count(*) FROM electricity_allocation_reversals) <> 1
       OR NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = a1 AND v.actual_line_count = 2 AND v.actual_line_amount = 450
                        AND v.restored_estimate_count = 2 AND v.restored_estimate_amount = 370 AND v.bill_amount = 600 AND v.payment_status = 'unpaid'
                        AND v.bank_account_code IS NULL AND v.reversal_date = CURRENT_DATE
                        AND v.reason = 'The utility re-issued the bill with the right meter total'
                        AND v.reversal_expense_id = (SELECT reversed_by_expense FROM expenses WHERE id = x1)) THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: one reversal record (2 lines 450, 2 estimates 370, bill 600, unpaid, today, the reason)'; END IF;
    -- 四个科目回到过账之前
    IF pg_temp.f258_bal('2200') <> v_b2200 OR pg_temp.f258_bal('5110') <> v_b5110 OR pg_temp.f258_bal('6200') <> v_b6200 OR pg_temp.f258_bal('2000') <> v_b2000 THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: 2200 / 5110 / 6200 / 2000 must be back where they were before the bill (moves % / % / % / %)',
            pg_temp.f258_bal('2200') - v_b2200, pg_temp.f258_bal('5110') - v_b5110, pg_temp.f258_bal('6200') - v_b6200, pg_temp.f258_bal('2000') - v_b2000; END IF;
    -- 那几炉的成本行回到过账之前
    SELECT string_agg(id::text || ':' || amount_base || ':' || is_estimate, ',' ORDER BY id) INTO v_live_after
      FROM processing_cost_entries WHERE run_id IN (r1, r2) AND deleted_at IS NULL;
    IF v_live_after IS DISTINCT FROM v_live_before THEN RAISE EXCEPTION 'FIXTURE 258 UNPAID: the runs'' live cost lines must be as before the bill'; END IF;
    -- 应付清单里没有它与它的镜像
    IF EXISTS (SELECT 1 FROM ap_open_items WHERE doc_id IN (x1, (SELECT reversed_by_expense FROM expenses WHERE id = x1))) THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: the reversed expense and its mirror must leave the AP list'; END IF;
    -- 一炉的电不再读那一张
    IF (pg_temp.f258_get(u_all, format($q$SELECT to_jsonb(e) FROM processing_run_energy e WHERE run_id = %L$q$, r2))) ->> 'allocated_kwh' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 258 UNPAID: a run''s energy must not read a reversed allocation'; END IF;
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_electricity_allocation(%L, 'again')$q$, a1));
    IF v_msg NOT LIKE 'ELECTRICITY_ALLOCATION_ALREADY_REVERSED|%' THEN RAISE EXCEPTION 'FIXTURE 258 UNPAID: a reversed allocation cannot be reversed again, got %', v_msg; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'UNPAID reversed');

    -- ══════════════ REPOST · 同一段时间再过一张改正过的 ══════════════
    RAISE NOTICE 'fixture 258 · REPOST';
    v_j := pg_temp.f258_get(u_all, format($q$SELECT preview_electricity_allocation(%L, %L, 640, 400, %L)$q$, d0, d1, v_base));
    IF (SELECT string_agg(x ->> 'amount', ',' ORDER BY (x ->> 'amount')::numeric) FROM jsonb_array_elements(v_j -> 'runs') x) IS DISTINCT FROM '160.00,320.00'
       OR (v_j ->> 'relieved_estimate_amount')::numeric <> 370 THEN
        RAISE EXCEPTION 'FIXTURE 258 REPOST: the corrected bill previews 160 / 320 and relieves the restored 370 again, got %', v_j; END IF;
    v_j := pg_temp.f258_get(u_all, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-258-1R', 640, 400, %L, 'unpaid', NULL, %L)$q$, d0, d1, d1 + 1, v_base, v_sup));
    a1b := (v_j ->> 'allocation_id')::uuid; x1b := (v_j ->> 'expense_id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e1 AND deleted_at IS NOT NULL AND relief_expense_id = x1b)
       OR (SELECT count(*) FROM electricity_allocation_lines WHERE run_id = r1) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 258 REPOST: the corrected bill relieves the estimates again; the run now has two lines (one reversed)'; END IF;
    IF (SELECT count(*) FROM processing_run_energy WHERE run_id = r2) <> 1
       OR (SELECT allocation_id FROM processing_run_energy WHERE run_id = r2) IS DISTINCT FROM a1b
       OR (SELECT allocated_kwh FROM processing_run_energy WHERE run_id = r2) IS DISTINCT FROM 200 THEN
        RAISE EXCEPTION 'FIXTURE 258 REPOST: a run''s energy reads one row, from the allocation that is not reversed'; END IF;
    -- 守卫:往一张没撤回的分摊里的炉再插一行 → 拒(唯一约束拿掉了,这一道还在)
    BEGIN
        INSERT INTO electricity_allocation_lines (allocation_id, run_id, equipment_id, basis, run_minutes, weight, share, machine_kwh, kwh, amount, cost_entry_id)
        SELECT a1, r1, eq_a, 'run_time', 60, 60, 1, 300, 100, 1, (SELECT id FROM processing_cost_entries WHERE run_id = r1 AND cost_type = 'labour');
        RAISE EXCEPTION 'FIXTURE 258 REPOST: a run already in a live allocation took a second line';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'ELECTRICITY_RUN_ALREADY_ALLOCATED|%' THEN RAISE EXCEPTION 'FIXTURE 258 REPOST: expected ELECTRICITY_RUN_ALREADY_ALLOCATED, got %', SQLERRM; END IF;
    END;
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT preview_electricity_allocation(%L, %L, 10, 100, %L)$q$, d1, d1, v_base));
    IF v_msg NOT LIKE 'ELECTRICITY_PERIOD_OVERLAPS|%' THEN RAISE EXCEPTION 'FIXTURE 258 REPOST: the live allocation still blocks an overlapping period, got %', v_msg; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'REPOST');

    -- ══════════════ F2 前置:r5 的估计 e7 先被月结冲抵 W(未付,挂供应商)══════════════
    v_j := pg_temp.f258_get(u_all, format($q$SELECT relieve_processing_accruals(ARRAY[%L]::uuid[], 70, %L, 'unpaid', NULL, %L, NULL, 'f258 W')$q$, e7, dx, v_sup));
    w := (v_j ->> 'expense_id')::uuid;
    PERFORM pg_temp.f258_agree(u_all, 'F2 relief W');

    -- ══════════════ PAID · 一张已付的(本位币银行)══════════════
    RAISE NOTICE 'fixture 258 · PAID';
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-258-2', 300, 200, %L, 'paid', %L)$q$, d2, d3, d3 + 1, v_base, v_fbank));
    IF v_msg NOT LIKE format('ELECTRICITY_BANK_NOT_BASE|%s|%s%%', v_fbank, v_base) THEN
        RAISE EXCEPTION 'FIXTURE 258 PAID: a foreign-currency bank must be refused by name, got %', v_msg; END IF;
    v_b2200 := pg_temp.f258_bal('2200'); v_b5110 := pg_temp.f258_bal('5110'); v_b6200 := pg_temp.f258_bal('6200');
    v_b2000 := pg_temp.f258_bal('2000'); v_bbank := pg_temp.f258_bal(v_bank);
    v_j := pg_temp.f258_get(u_all, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-258-2', 300, 200, %L, 'paid', %L)$q$, d2, d3, d3 + 1, v_base, v_bank));
    a2 := (v_j ->> 'allocation_id')::uuid; x2 := (v_j ->> 'expense_id')::uuid;
    SELECT journal_entry_id INTO je2 FROM electricity_allocations WHERE id = a2;
    SELECT jsonb_object_agg(a.code || ':' || CASE WHEN l.debit > 0 THEN 'debit' ELSE 'credit' END, l.debit + l.credit) INTO v_x
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = je2;
    IF v_x IS DISTINCT FROM jsonb_build_object('2200:debit', 150.00, '6200:debit', 150.00, v_bank || ':credit', 300.00) THEN
        RAISE EXCEPTION 'FIXTURE 258 PAID: a paid bill is Dr 2200 150 / Dr 6200 150 / Cr the bank 300, got %', v_x; END IF;
    IF NOT EXISTS (SELECT 1 FROM expenses WHERE id = x2 AND payment_status = 'paid' AND bank_account_code = v_bank AND supplier_id IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 258 PAID: the expense is paid, from the base bank, with no supplier needed'; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'PAID posted');

    -- F2:W 冲抵过的估计所在的 r5 此后被账单二覆盖了 → 冲不掉 W
    RAISE NOTICE 'fixture 258 · F2';
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, w));
    IF v_msg NOT LIKE format('RELIEF_ESTIMATE_NOW_ALLOCATED|%s|%s%%', (SELECT code FROM processing_runs WHERE id = r5), (SELECT code FROM expenses WHERE id = x2)) THEN
        RAISE EXCEPTION 'FIXTURE 258 F2: reversing a relief whose run has since been allocated must be refused, naming the run and the bill — got %', v_msg; END IF;
    IF (SELECT status FROM expenses WHERE id = w) <> 'posted' OR (SELECT relief_expense_id FROM processing_cost_entries WHERE id = e7) IS DISTINCT FROM w THEN
        RAISE EXCEPTION 'FIXTURE 258 F2: the refused reversal must leave the relief and its stamps as they were'; END IF;

    -- 撤回账单二(已付):借回银行
    RAISE NOTICE 'fixture 258 · PAID (reverse)';
    v_j := pg_temp.f258_get(u_all, format($q$SELECT reverse_electricity_allocation(%L, 'Bill posted against the wrong period')$q$, a2));
    IF pg_temp.f258_bal('2200') <> v_b2200 OR pg_temp.f258_bal('5110') <> v_b5110 OR pg_temp.f258_bal('6200') <> v_b6200
       OR pg_temp.f258_bal('2000') <> v_b2000 OR pg_temp.f258_bal(v_bank) <> v_bbank THEN
        RAISE EXCEPTION 'FIXTURE 258 PAID: reversing a paid bill must debit the bank back and return 2200 / 5110 / 6200 / 2000 (moves % / % / % / % / bank %)',
            pg_temp.f258_bal('2200') - v_b2200, pg_temp.f258_bal('5110') - v_b5110, pg_temp.f258_bal('6200') - v_b6200,
            pg_temp.f258_bal('2000') - v_b2000, pg_temp.f258_bal(v_bank) - v_bbank; END IF;
    IF NOT EXISTS (SELECT 1 FROM expenses m JOIN expenses o ON o.reversed_by_expense = m.id WHERE o.id = x2 AND m.payment_status = 'paid' AND m.bank_account_code = v_bank)
       OR NOT EXISTS (SELECT 1 FROM electricity_allocation_reversals WHERE allocation_id = a2 AND payment_status = 'paid' AND bank_account_code = v_bank
                        AND restored_estimate_count = 1 AND restored_estimate_amount = 90)
       OR EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e3 AND (deleted_at IS NOT NULL OR relieved_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'FIXTURE 258 PAID: the mirror is paid from the same bank; the record says so; e3 is restored'; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'PAID reversed');

    -- F2:账单二撤回之后,W 冲得掉:e7 的戳清掉、回到未结、没有分录;能再冲抵一次
    RAISE NOTICE 'fixture 258 · F2 (restore)';
    v_n := (SELECT count(*) FROM journal_entries);
    v_j := pg_temp.f258_get(u_all, format($q$SELECT reverse_expense(%L, 'relief entered against the wrong invoice')$q$, w));
    IF (v_j ->> 'restored_estimates')::int <> 1
       OR EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e7 AND (relieved_at IS NOT NULL OR relief_expense_id IS NOT NULL OR deleted_at IS NOT NULL)) THEN
        RAISE EXCEPTION 'FIXTURE 258 F2: reversing the relief must clear its estimate''s stamps (got %)', v_j; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_n + 1 THEN
        RAISE EXCEPTION 'FIXTURE 258 F2: the only journal is the relief''s own reversal (no extra journal for the restore), got % new', (SELECT count(*) FROM journal_entries) - v_n; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'F2 reversed');
    v_j := pg_temp.f258_get(u_all, format($q$SELECT relieve_processing_accruals(ARRAY[%L]::uuid[], 65, %L, 'unpaid', NULL, %L, NULL, 'f258 W again')$q$, e7, dx, v_sup));
    w2 := (v_j ->> 'expense_id')::uuid;
    IF (SELECT relief_expense_id FROM processing_cost_entries WHERE id = e7) IS DISTINCT FROM w2 THEN
        RAISE EXCEPTION 'FIXTURE 258 F2: the restored estimate must be relievable again'; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'F2 relieved again');

    -- ══════════════ VAR · 偏差视图 ══════════════
    RAISE NOTICE 'fixture 258 · VAR';
    -- 月结冲抵 e4(80 → 100),冲掉,再冲抵(80 → 95):电费那一格只算 95(W 的 65 对 60 也在同一格:实际 95 + 65、估计 80 + 60)
    v_j := pg_temp.f258_get(u_all, format($q$SELECT relieve_processing_accruals(ARRAY[%L]::uuid[], 100, %L, 'unpaid', NULL, %L, NULL, 'f258 X')$q$, e4, dx, v_sup));
    rel := (v_j ->> 'expense_id')::uuid;
    PERFORM pg_temp.f258_get(u_all, format($q$SELECT reverse_expense(%L)$q$, rel));
    v_j := pg_temp.f258_get(u_all, format($q$SELECT relieve_processing_accruals(ARRAY[%L]::uuid[], 95, %L, 'unpaid', NULL, %L, NULL, 'f258 Y')$q$, e4, dx, v_sup));
    rel2 := (v_j ->> 'expense_id')::uuid;
    v_j := pg_temp.f258_get(u_all, format($q$SELECT to_jsonb(v) FROM processing_cost_variance v WHERE month = %L AND cost_type = 'electricity'$q$, date_trunc('month', dx)::date));
    IF (v_j ->> 'actual_total')::numeric IS DISTINCT FROM 160 OR (v_j ->> 'estimated_total')::numeric IS DISTINCT FROM 140 THEN
        RAISE EXCEPTION 'FIXTURE 258 VAR: the variance counts only live reliefs (actual 95 + 65, estimated 80 + 60), got %', v_j; END IF;
    -- 戳没清掉的那一种(本刀之前冲销的冲抵):e8 被 Z 冲抵,Z 冲销,再以财务函数的身份把戳摆回去 —— 视图照样不算它
    v_j := pg_temp.f258_get(u_all, format($q$SELECT relieve_processing_accruals(ARRAY[%L]::uuid[], 40, %L, 'unpaid', NULL, %L, NULL, 'f258 Z')$q$, e8, dx, v_sup));
    z := (v_j ->> 'expense_id')::uuid;
    PERFORM pg_temp.f258_get(u_all, format($q$SELECT reverse_expense(%L)$q$, z));
    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries SET relieved_at = dx, relief_expense_id = z WHERE id = e8;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);
    IF EXISTS (SELECT 1 FROM processing_cost_variance WHERE month = date_trunc('month', dx)::date AND cost_type = 'other') THEN
        RAISE EXCEPTION 'FIXTURE 258 VAR: a reversed relief must not be counted even when its stamps were never cleared'; END IF;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    UPDATE processing_cost_entries SET relieved_at = NULL, relief_expense_id = NULL WHERE id = e8;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);
    PERFORM pg_temp.f258_agree(u_all, 'VAR');

    -- ══════════════ CCY · 冲抵的费用单币种从数据读 ══════════════
    RAISE NOTICE 'fixture 258 · CCY';
    IF (SELECT currency FROM expenses WHERE id = rel2) IS DISTINCT FROM v_base THEN
        RAISE EXCEPTION 'FIXTURE 258 CCY: the relief expense is in the base currency'; END IF;
    IF v_other IS NOT NULL THEN
        BEGIN
            UPDATE currencies SET is_base = (code = v_other);
            v_j := relieve_processing_accruals(ARRAY[e6], 33, dx, 'unpaid', NULL, v_sup, NULL, 'f258 CCY probe');
            RAISE EXCEPTION 'F258_CCY_PROBE|%', (SELECT currency || ':' || fx_rate FROM expenses WHERE id = (v_j ->> 'expense_id')::uuid);
        EXCEPTION WHEN OTHERS THEN
            v_msg := SQLERRM;
        END;
        IF v_msg IS DISTINCT FROM 'F258_CCY_PROBE|' || v_other || ':1' THEN
            RAISE EXCEPTION 'FIXTURE 258 CCY: with % as the base, the relief expense must be in % at rate 1 (read from data, not a literal) — got %', v_other, v_other, v_msg; END IF;
        IF base_currency_code() IS DISTINCT FROM v_base THEN RAISE EXCEPTION 'FIXTURE 258 CCY: the probe must leave the base as it was'; END IF;
    END IF;

    -- ══════════════ LOCK · 冲销日在锁住的期间里 ══════════════
    RAISE NOTICE 'fixture 258 · LOCK';
    UPDATE finance_settings SET locked_before = CURRENT_DATE + 1;
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_electricity_allocation(%L, 'locked')$q$, a1b));
    UPDATE finance_settings SET locked_before = NULL;
    IF v_msg NOT LIKE 'PERIOD_LOCKED%' OR EXISTS (SELECT 1 FROM electricity_allocation_reversals WHERE allocation_id = a1b)
       OR (SELECT status FROM expenses WHERE id = x1b) <> 'posted' THEN
        RAISE EXCEPTION 'FIXTURE 258 LOCK: a reversal dated in a locked period must be refused and change nothing, got %', v_msg; END IF;

    -- ══════════════ KINDS · 经付款结过的,每一种都拒;先冲付款就冲得掉 ══════════════
    RAISE NOTICE 'fixture 258 · KINDS';
    -- 电费分摊(改正过的那一张,未付)经付款付清 → 撤回拒
    v_j := record_payment_internal('out', v_sup, 640, v_base, NULL, NULL, CURRENT_DATE - 2, 'f258 pay the bill',
                                   jsonb_build_array(jsonb_build_object('expense_id', x1b, 'amount_doc', 640)));
    v_pay := (v_j ->> 'payment_id')::uuid;
    PERFORM pg_temp.f258_agree(u_all, 'KINDS allocation paid');
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_electricity_allocation(%L, 'paid already')$q$, a1b));
    IF v_msg NOT LIKE format('EXPENSE_HAS_SETTLEMENT|%s|640%%', (SELECT code FROM expenses WHERE id = x1b)) THEN
        RAISE EXCEPTION 'FIXTURE 258 KINDS: an allocation paid through a payment must be refused by name, got %', v_msg; END IF;
    PERFORM reverse_payment_internal(v_pay, 'f258');
    v_j := pg_temp.f258_get(u_all, format($q$SELECT reverse_electricity_allocation(%L, 'payment reversed first, now the bill')$q$, a1b));
    IF (SELECT status FROM expenses WHERE id = x1b) <> 'reversed' THEN RAISE EXCEPTION 'FIXTURE 258 KINDS: once the payment is reversed the bill reverses'; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'KINDS allocation reversed');

    -- 普通(挂供应商):部分付就拒;冲掉付款就冲得掉
    v_j := record_expense(p_expense_date := dx, p_account_code := '6400', p_amount := 100, p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup);
    v_exp := (v_j ->> 'expense_id')::uuid;
    v_j := record_payment_internal('out', v_sup, 40, v_base, NULL, NULL, CURRENT_DATE - 2, 'f258 part',
                                   jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 40)));
    v_pay := (v_j ->> 'payment_id')::uuid;
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, v_exp));
    -- 先问总账:要是这一次冲销放过去了,清单与总账当场就差那 40(这正是这道拒绝存在的理由 —— Step 0 §1.4)
    PERFORM pg_temp.f258_agree(u_all, 'KINDS ordinary refused');
    IF v_msg NOT LIKE format('EXPENSE_HAS_SETTLEMENT|%s|40%%', (SELECT code FROM expenses WHERE id = v_exp)) THEN
        RAISE EXCEPTION 'FIXTURE 258 KINDS: an ordinary expense part-paid through a payment must be refused, got %', v_msg; END IF;
    PERFORM reverse_payment_internal(v_pay, 'f258');
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, v_exp));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 258 KINDS: with the payment reversed the expense reverses, got %', v_msg; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'KINDS ordinary reversed');
    -- 欠员工的(报销 / 医疗走的同一扇门 record_expense,往来对象是员工)
    v_j := record_expense(p_expense_date := dx, p_account_code := '6400', p_amount := 50, p_currency := v_base, p_payment_status := 'unpaid', p_employee_id := v_emp);
    v_exp := (v_j ->> 'expense_id')::uuid;
    PERFORM record_payment_internal('out', v_emp, 50, v_base, NULL, NULL, CURRENT_DATE - 2, 'f258 reimburse',
                                    jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 50)), 'employee');
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, v_exp));
    IF v_msg NOT LIKE 'EXPENSE_HAS_SETTLEMENT|%' THEN RAISE EXCEPTION 'FIXTURE 258 KINDS: an employee expense paid through a payment must be refused, got %', v_msg; END IF;
    -- 月结冲抵(Y,未付)经付款付清
    PERFORM record_payment_internal('out', v_sup, 95, v_base, NULL, NULL, CURRENT_DATE - 2, 'f258 pay relief',
                                    jsonb_build_array(jsonb_build_object('expense_id', rel2, 'amount_doc', 95)));
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, rel2));
    IF v_msg NOT LIKE 'EXPENSE_HAS_SETTLEMENT|%' OR (SELECT relief_expense_id FROM processing_cost_entries WHERE id = e4) IS DISTINCT FROM rel2 THEN
        RAISE EXCEPTION 'FIXTURE 258 KINDS: a relief paid through a payment must be refused and keep its stamps, got %', v_msg; END IF;
    -- 资本追加(资产还没投用)
    v_j := record_expense(dx, '1500', 1000, v_base, NULL, 'unpaid', NULL, v_sup, NULL, NULL, jsonb_build_object('description', 'f258 machine', 'useful_life_months', 100));
    v_asset := (v_j ->> 'asset_id')::uuid;
    v_j := record_expense(dx, '1500', 200, v_base, NULL, 'unpaid', NULL, v_sup, NULL, NULL, jsonb_build_object('asset_id', v_asset));
    v_exp := (v_j ->> 'expense_id')::uuid;
    PERFORM record_payment_internal('out', v_sup, 200, v_base, NULL, NULL, CURRENT_DATE - 2, 'f258 pay install',
                                    jsonb_build_array(jsonb_build_object('expense_id', v_exp, 'amount_doc', 200)));
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, v_exp));
    IF v_msg NOT LIKE 'EXPENSE_HAS_SETTLEMENT|%' OR (SELECT cost_base FROM fixed_assets WHERE id = v_asset) <> 1200 THEN
        RAISE EXCEPTION 'FIXTURE 258 KINDS: a capital append paid through a payment must be refused (cost untouched), got %', v_msg; END IF;
    -- 冲抵过预付款的
    v_j := create_purchase_order(v_sup, dx, dx + 10, v_base, NULL, NULL, NULL, 'f258 PO',
        jsonb_build_array(jsonb_build_object('material_id', m_bm, 'quantity', 10, 'unit', 'kg', 'estimated_unit_price', 20)), p_category => 'equipment_goods');
    v_po := (v_j ->> 'purchase_order_id')::uuid;
    PERFORM record_payment_internal('out', v_sup, 100, v_base, NULL, NULL, dx, 'f258 deposit',
        jsonb_build_array(jsonb_build_object('purchase_order_id', v_po, 'amount_doc', 100)), 'supplier');
    v_j := record_expense(p_expense_date := dx, p_account_code := '6400', p_amount := 60, p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup);
    v_exp := (v_j ->> 'expense_id')::uuid;
    PERFORM apply_prepayment(v_po, NULL, 60, NULL, v_exp, CURRENT_DATE - 1);
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT reverse_expense(%L)$q$, v_exp));
    IF v_msg NOT LIKE format('EXPENSE_HAS_PREPAYMENT_APPLIED|%s|60%%', (SELECT code FROM expenses WHERE id = v_exp)) THEN
        RAISE EXCEPTION 'FIXTURE 258 KINDS: an expense with a prepayment applied must be refused, got %', v_msg; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'KINDS');

    -- ══════════════ GUARD · 结算戳只经财务函数改 ══════════════
    RAISE NOTICE 'fixture 258 · GUARD';
    -- 一条实际的人工行,经 remit 汇出(财务函数动得了戳)
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r4, 'labour', 70, false, 'f258 actual') RETURNING id INTO e_lab;
    v_msg := pg_temp.f258_do(u_all, format($q$SELECT remit_processing_costs(ARRAY[%L]::uuid[], %L, %L)$q$, e_lab, dx, v_bank));
    IF v_msg <> 'OK' OR (SELECT remitted_at FROM processing_cost_entries WHERE id = e_lab) IS DISTINCT FROM dx THEN
        RAISE EXCEPTION 'FIXTURE 258 GUARD: (funcs) remit must set the remitted stamp, got %', v_msg; END IF;
    -- 同一笔事务里、财务函数之后:加工编辑者直连清汇出戳 → 拒(标记没留下来)
    v_msg := pg_temp.f258_do(u_pedit, format($q$UPDATE processing_cost_entries SET remitted_at = NULL, remitted_journal_entry_id = NULL WHERE id = %L$q$, e_lab));
    IF v_msg NOT LIKE 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|remitted%' OR (SELECT remitted_at FROM processing_cost_entries WHERE id = e_lab) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 258 GUARD: a processing editor clearing a remitted stamp must be refused by name, got %', v_msg; END IF;
    -- 盖冲抵戳 / 清冲抵戳 / 插一条带戳的行 → 拒
    v_msg := pg_temp.f258_do(u_pedit, format($q$UPDATE processing_cost_entries SET relieved_at = CURRENT_DATE, relief_expense_id = %L WHERE id = %L$q$, w2, e6));
    IF v_msg NOT LIKE 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|relieved%' THEN RAISE EXCEPTION 'FIXTURE 258 GUARD: stamping relieved directly, got %', v_msg; END IF;
    v_msg := pg_temp.f258_do(u_pedit, format($q$UPDATE processing_cost_entries SET relieved_at = NULL, relief_expense_id = NULL WHERE id = %L$q$, e7));
    IF v_msg NOT LIKE 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|relieved%' OR (SELECT relief_expense_id FROM processing_cost_entries WHERE id = e7) IS DISTINCT FROM w2 THEN
        RAISE EXCEPTION 'FIXTURE 258 GUARD: clearing a relieved stamp directly, got %', v_msg; END IF;
    v_msg := pg_temp.f258_do(u_pedit, format($q$INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, remitted_at) VALUES (%L, 'labour', 5, false, CURRENT_DATE)$q$, r4));
    IF v_msg NOT LIKE 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|remitted%' THEN RAISE EXCEPTION 'FIXTURE 258 GUARD: inserting a born-settled line, got %', v_msg; END IF;
    -- 连属主也一样(没有标记就没有后门)
    BEGIN
        UPDATE processing_cost_entries SET remitted_at = NULL WHERE id = e_lab;
        RAISE EXCEPTION 'FIXTURE 258 GUARD: the owner cleared a stamp without the context';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY|%' THEN RAISE EXCEPTION 'FIXTURE 258 GUARD: owner update, got %', SQLERRM; END IF;
    END;
    -- 改一条没结的估计的金额照常(守卫不多拦)
    v_msg := pg_temp.f258_do(u_pedit, format($q$UPDATE processing_cost_entries SET amount_base = 31 WHERE id = %L$q$, e6));
    IF v_msg <> 'OK' OR (SELECT amount_base FROM processing_cost_entries WHERE id = e6) <> 31 THEN
        RAISE EXCEPTION 'FIXTURE 258 GUARD: an unsettled estimate''s amount still edits, got %', v_msg; END IF;
    -- FUNCS:五支各自动过戳(relieve 盖冲抵 · remit 盖汇出 · post 插已结的行并盖冲抵 · reverse_expense 清冲抵 · reverse_electricity_allocation 清两种)
    IF (SELECT relief_expense_id FROM processing_cost_entries WHERE id = e7) IS DISTINCT FROM w2
       OR NOT EXISTS (SELECT 1 FROM electricity_allocation_lines l JOIN processing_cost_entries c ON c.id = l.cost_entry_id
                       WHERE l.allocation_id = a1b AND c.remitted_journal_entry_id IS NULL AND c.deleted_at IS NOT NULL)
       OR EXISTS (SELECT 1 FROM processing_cost_entries WHERE id IN (e1, e2, e3) AND relieved_at IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 258 GUARD: (funcs) relieve / post / reverse_expense / reverse_electricity_allocation each changed the stamps'; END IF;
    PERFORM pg_temp.f258_agree(u_all, 'GUARD');

    -- ══════════════ MASK ══════════════
    RAISE NOTICE 'fixture 258 · MASK';
    v_j := pg_temp.f258_get(u_np, format($q$SELECT to_jsonb(v) FROM electricity_allocation_reversals_masked v WHERE allocation_id = %L$q$, a1));
    IF v_j ->> 'bill_amount' IS NOT NULL OR v_j ->> 'actual_line_amount' IS NOT NULL OR v_j ->> 'restored_estimate_amount' IS NOT NULL
       OR (v_j ->> 'actual_line_count')::int IS DISTINCT FROM 2 OR v_j ->> 'reason' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 258 MASK: without data.view_prices the amounts are hidden, the counts and reason shown — got %', v_j; END IF;
    v_j := pg_temp.f258_get(u_all, format($q$SELECT to_jsonb(v) FROM electricity_allocation_reversals_masked v WHERE allocation_id = %L$q$, a1));
    IF (v_j ->> 'bill_amount')::numeric IS DISTINCT FROM 600 OR (v_j ->> 'restored_estimate_amount')::numeric IS DISTINCT FROM 370 THEN
        RAISE EXCEPTION 'FIXTURE 258 MASK: with data.view_prices the amounts show, got %', v_j; END IF;
    IF has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'bill_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'actual_line_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'restored_estimate_amount', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 258 MASK: the three amounts stay out of the column grant'; END IF;

    -- ══════════════ LOG · 变更记录与审计记录 ══════════════
    RAISE NOTICE 'fixture 258 · LOG';
    v_j := change_log_coverage_gaps();
    IF COALESCE(jsonb_array_length(v_j -> 'gaps'), -1) <> 0 OR (v_j ->> 'excluded')::int IS DISTINCT FROM 8 THEN
        RAISE EXCEPTION 'FIXTURE 258 LOG: the reversals table is logged, exclusions still 8 — got %', v_j; END IF;
    IF (SELECT count(*) FROM change_log WHERE table_name = 'electricity_allocation_reversals' AND op = 'INSERT') <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 258 LOG: the three reversals should be in the change log'; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'processing_cost_entries' AND op = 'UPDATE' AND 'relieved_at' = ANY (changed_columns)
                     AND (row_key ->> 'id')::uuid = e7) THEN
        RAISE EXCEPTION 'FIXTURE 258 LOG: a stamp change is in the change log (no new history kind — Q27)'; END IF;
    v_n := (pg_temp.f258_get(u_all, format($q$SELECT to_jsonb(count(*)) FROM record_trail('electricity_allocation', %L, 500) t WHERE t.table_name = 'electricity_allocation_reversals'$q$, a1)))::text::bigint;
    IF v_n IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FIXTURE 258 LOG: the allocation''s trail carries its reversal (got %)', v_n; END IF;
    v_n := (pg_temp.f258_get(u_all, format($q$SELECT to_jsonb(count(*)) FROM record_trail('processing_run', %L, 500) t WHERE t.table_name = 'electricity_allocation_reversals'$q$, r1)))::text::bigint;
    IF v_n IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FIXTURE 258 LOG: the run''s trail shows the two reversals of bills that covered it (got %)', v_n; END IF;
    -- V37 的改动在工序页自己的审计记录上(MES5B1-V37-NOT-ON-OPERATION-TRAIL)
    UPDATE operation_type_output_forms SET expected_yield_pct = 70 WHERE operation_type_code = 'battery_powder_line' AND form_code = 'black_mass';
    v_n := (pg_temp.f258_get(u_all, $q$SELECT to_jsonb(count(*)) FROM record_trail('operation_type', 'battery_powder_line', 500) t WHERE t.table_name = 'operation_type_output_forms'$q$))::text::bigint;
    IF COALESCE(v_n, 0) < 1 THEN RAISE EXCEPTION 'FIXTURE 258 LOG: a V37 change must show on the operation''s own trail (got %)', v_n; END IF;

    PERFORM pg_temp.f258_agree(u_all, 'end');
    RAISE NOTICE 'FIXTURE 258 全部通过: PERM · UNPAID · REPOST · PAID · F2 · VAR · CCY · LOCK · KINDS · GUARD · MASK · LOG · AGREE';
END;
$$;

ROLLBACK;

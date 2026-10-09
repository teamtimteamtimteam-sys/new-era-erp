-- 256 MES-5a-2:一台电表读的是累计寄存器;一炉分到它那台机器量到的电(都记了电量按电量分,有一炉没记就整台按运行时长分,
-- ★ MES-6a-1(2026-10-09,F3 · MES-6a Step 0 Q44,Tim):每一次费用冲销都要一句理由 —— 本支里只带单号的 reverse_expense 调用一律补上一句理由,
--   好让它们照旧走到各自断言的那一道拒绝(而不是先撞上 EXPENSE_REVERSAL_REASON_REQUIRED)。断言一条没减;空理由那几臂在 fixture 261。
--     依据印在每一行);一张电费单只过一次账 —— 一张费用单、每一炉一条实际电费行、一张结掉它们的分录、被覆盖的炉上的估计被冲掉
--     (MES-5a Step 0 Q19–Q28 · Q30–Q32 · Q35,Tim;v1.4.44)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-08-mes5a2-fixture-injections.py)必须让它红在它点名的那一臂。
--   METER  电表是一台 kind = meter 的设备;它的机器 = equipment_id,空 = 共用池;只有 action.manage_devices 设得动(save_device)(Q19)
--   READ   累计寄存器读数:只追加(直连改拒)· 比前一条小拒 · 标成寄存器清零并写理由就收(没理由拒)· 补记一条比后面那条大拒 ·
--          同一刻两条拒 · 将来的时刻拒 · 更正是新行要理由 · 更正过的那条不能再更正 · 撤回 · 只有 action.confirm_capture 记得进 ·
--          meter_readings_current 的 delta(清零那一条为空)(Q20)
--   RUNE   一炉的电量 = 它自己记的 energy_kwh(有就用,哪怕分摊给它的 kWh 不同);没记才用分到的;放电回收的能量另列、不相抵(Q21)
--   SPLIT  一台机器这段时间【每一炉】都记了电量 → 按电量分;有一炉没记 → 整台机器按运行时长分(记了的那一炉也一样);依据印在每一行;
--          各炉之和恰好等于那台机器量到的(Q22)
--   TONNE  每吨电耗 = 电量 ÷ 投入吨数(Q23)
--   ALLOC  预览 = 过账(逐键);一张费用单(本位币、未付、挂供应商);一炉一行;那张分录 借 2200 / 借 6200 / 贷 2000 平;各炉的实际
--          电费行已结、改不了;被覆盖的炉上的估计被冲掉(软删 + 冲抵到这张费用单),没被覆盖的(没装表的机器 · 量不出来的机器 ·
--          时间段外)一条不动;不计量与共用池的电留在 6200;总账四个科目的余额逐个对;应付清单 = 总账,unexplained 0.00(Q24 · Q25 · Q26)
--   CCY    外币账单按名拒,本位币从数据读(Q28);时间段重叠拒;量到的超过账单拒
--   PERM   没有 module.finance.edit 过不了账;没有 module.finance.view 看不了预览;没有 action.confirm_capture 记不了读数(Q27)
--   MASK   没有 data.view_prices 的读者:金额为空、kWh 照见;五列金额不在列级授权里(Q30)
--   LOG    四张新表都进变更记录(覆盖零缺口、豁免仍是 8);审计记录:读数在电表上,一张单与它的行在那张单上,分给一炉的那一行也在那一炉上(Q31)
--   V25    有共用池电表而规则为空 → 待补的值那一行;写下规则那一行就消失;规则写下之后分摊【仍然】把共用池留在 6200(本刀不按它摊)(Q32)
--   REV    一次分摊的费用单不许单独冲(EXPENSE_IS_ELECTRICITY_ALLOCATION)
--   ALLOC-PAID ★ MES-5b-2(Step 0 Q29,MES-5a-2 close-out 裁定 b):一张【已付】的本位币电费单 —— 借 2200 / 借 6200 / 贷【本位币银行】;
--          费用单 paid、带那个银行、不必有供应商;外币银行按名拒 ELECTRICITY_BANK_NOT_BASE;应付清单 = 总账,unexplained 0.00。
--          数:时间段 今天往前 6 天到往前 4 天;机器 A 表 1600 → 1700 → 1800,段内 100 kWh,只有 r6(没记电量,60 分钟)→ 100 kWh;
--          账单 250 / 200 kWh,单价 1.25:r6 125.00 · 6200 125.00(不计量 100 kWh);r6 的估计 e6 35 被冲掉。
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS);员工的调用真的切成 authenticated + 那个人的 JWT。
-- 日期:时间段 = 今天往前 20 天到往前 11 天(d0..d1);炉在 d0+3 / d0+4;段外的那一炉在今天往前 5 天。读数在段的头尾与中间。
-- 【数怎么来的】(README 第 1 条:字面量就是断言时写出推导)
--   机器 A:表 1000 → 1250 → 1600 = 600 kWh;两炉都记了电量 30 / 10 → 按电量:450 / 150。
--   机器 B:表 200 → 600 = 400 kWh;一炉记了 20、一炉没记 → 整台按运行时长 60 / 180 分钟:100 / 300。
--   共用池:50 → 80(+30)→ 清零 5(那一对不计)→ 25(+20)= 50 kWh。机器 D 的表只有一条读数 → 量不出来。
--   账单 1,337.50 / 1,200 kWh,单价 1.114583…;量到 600 + 400 + 50 = 1,050,不计量 150。
--   各炉:450 → 501.5625 → 501.56 · 150 → 167.1875 → 167.19 · 100 → 111.4583 → 111.46 · 300 → 334.375 → 334.38;合计 1,114.59;
--   6200 = 1,337.50 − 1,114.59 = 222.91。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f256_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人跑一句;返回 'OK' 或错误原文。之后身份回到调用之前的那一个。
CREATE FUNCTION pg_temp.f256_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f256_as(p_user);
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
CREATE FUNCTION pg_temp.f256_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_prev text := NULLIF(current_setting('request.jwt.claims', true), '');
BEGIN
    PERFORM pg_temp.f256_as(p_user);
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
CREATE FUNCTION pg_temp.f256_bal(p_code text) RETURNS numeric
LANGUAGE sql AS $f$
    SELECT COALESCE(sum(l.debit - l.credit), 0)
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE a.code = p_code
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码
    u_view uuid := gen_random_uuid();   -- 只看加工
    u_cap  uuid := gen_random_uuid();   -- 采集确认 + 看加工
    u_dev  uuid := gen_random_uuid();   -- 管设备 + 看加工
    u_finv uuid := gen_random_uuid();   -- 只看财务(不能动账)
    u_proc uuid := gen_random_uuid();   -- 看加工,没有价格码
    r uuid;
    d0 date := CURRENT_DATE - 20;
    d1 date := CURRENT_DATE - 11;
    t0 timestamptz; tm timestamptz; tm2 timestamptz; t1 timestamptz;
    v_sup uuid; m_mod uuid; b uuid;
    eq_a uuid; eq_b uuid; eq_c uuid; eq_d uuid;
    mt_a uuid; mt_b uuid; mt_p uuid; mt_d uuid;
    r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid; r6 uuid; r7 uuid;
    e1 uuid; e5 uuid; e6 uuid; e7 uuid;
    v_msg text; v_j jsonb; v_p jsonb; v_n bigint; v_id bigint; v_num numeric; v_alloc uuid; v_exp uuid; v_je uuid;
    v_other text; v_base text; v_id_bank text; v_fbank text;
    v_b2200 numeric; v_b5110 numeric; v_b6200 numeric; v_b2000 numeric;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    t0  := ((d0)::timestamp + interval '1 hour') AT TIME ZONE 'Asia/Singapore';
    tm  := ((d0 + 4)::timestamp + interval '12 hours') AT TIME ZONE 'Asia/Singapore';
    tm2 := ((d0 + 6)::timestamp + interval '12 hours') AT TIME ZONE 'Asia/Singapore';
    t1  := ((d1)::timestamp + interval '23 hours') AT TIME ZONE 'Asia/Singapore';
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_other FROM currencies WHERE NOT is_base ORDER BY code LIMIT 1;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx256-all@test.local', now(), now()), (u_view, 'fx256-view@test.local', now(), now()),
        (u_cap, 'fx256-cap@test.local', now(), now()), (u_dev, 'fx256-dev@test.local', now(), now()),
        (u_finv, 'fx256-finv@test.local', now(), now()), (u_proc, 'fx256-proc@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx256-all', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx256-view', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_view, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx256-cap', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view'), (r, 'action.confirm_capture');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_cap, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx256-dev', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view'), (r, 'action.manage_devices');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_dev, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx256-finv', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_finv, r);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx256-proc', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r, 'module.processing.view'), (r, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_proc, r);
    PERFORM pg_temp.f256_as(u_all);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ256-S', 'f256 power utility', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ256-MOD', 'f256 modules', 'battery_material', true, 'module', 'end_of_life', 'ev_traction') RETURNING id INTO m_mod;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ256-B', m_mod, v_sup, 5000, 5000, 'kg', d0 - 30, 'other', 'fixture 256 自带数据') RETURNING id INTO b;
    PERFORM reprice_inbound_batch(b, 1, v_base, NULL, 'f256');
    UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = b;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (b, 'charged_not_discharged');
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ256-EQA', 'f256 machine A (metered, every run records energy)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq_a;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ256-EQB', 'f256 machine B (metered, one run without energy)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq_b;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ256-EQC', 'f256 machine C (no meter)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq_c;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_base, currency, cost_ccy, fx_rate, status, useful_life_months, residual_base) VALUES
        ('ZZ256-EQD', 'f256 machine D (one reading only)', 'equipment', d0 - 200, 0, v_base, 0, 1, 'active', 100, 0) RETURNING id INTO eq_d;
    -- 深度放电今天没有"电量"这个字段;fixture 自己给它一个,这样一炉放电就能记 energy_kwh(规则看的是字段码,不看工序)
    INSERT INTO operation_type_fields (operation_type_code, field_code, name_en, name_zh, kind, value_type, unit, sort_order, notes)
    VALUES ('deep_discharge', 'energy_kwh', 'Energy', '能耗', 'indicator', 'number', 'kWh', 90, 'fixture 256');

    -- ══════════════ METER · 电表与它的机器 ══════════════
    RAISE NOTICE 'fixture 256 · METER';
    v_msg := pg_temp.f256_do(u_view, $q$SELECT save_device('{"name":"f256 nope","kind":"meter"}'::jsonb)$q$);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' THEN RAISE EXCEPTION 'FIXTURE 256 METER: only action.manage_devices registers a meter, got %', v_msg; END IF;
    mt_a := (pg_temp.f256_get(u_dev, format($q$SELECT to_jsonb(save_device('{"name":"f256 meter A","kind":"meter","equipment_id":"%s"}'::jsonb))$q$, eq_a)) #>> '{}')::uuid;
    mt_b := (pg_temp.f256_get(u_dev, format($q$SELECT to_jsonb(save_device('{"name":"f256 meter B","kind":"meter","equipment_id":"%s"}'::jsonb))$q$, eq_b)) #>> '{}')::uuid;
    mt_p := (pg_temp.f256_get(u_dev, $q$SELECT to_jsonb(save_device('{"name":"f256 shared pool","kind":"meter"}'::jsonb))$q$) #>> '{}')::uuid;
    mt_d := (pg_temp.f256_get(u_dev, format($q$SELECT to_jsonb(save_device('{"name":"f256 meter D","kind":"meter","equipment_id":"%s"}'::jsonb))$q$, eq_d)) #>> '{}')::uuid;
    IF (SELECT equipment_id FROM devices WHERE id = mt_a) IS DISTINCT FROM eq_a OR (SELECT equipment_id FROM devices WHERE id = mt_p) IS NOT NULL
       OR (SELECT kind FROM devices WHERE id = mt_p) IS DISTINCT FROM 'meter' THEN
        RAISE EXCEPTION 'FIXTURE 256 METER: a meter with a machine and a shared-pool meter (no machine) should both register';
    END IF;
    v_msg := pg_temp.f256_do(u_view, format($q$SELECT save_device('{"equipment_id":"%s"}'::jsonb, %L)$q$, eq_c, mt_p));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.manage_devices%' OR (SELECT equipment_id FROM devices WHERE id = mt_p) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 256 METER: only action.manage_devices may move a meter onto a machine, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_dev, format($q$SELECT save_device('{"equipment_id":"%s"}'::jsonb, %L)$q$, eq_c, mt_d));
    v_msg := v_msg || pg_temp.f256_do(u_dev, format($q$SELECT save_device('{"equipment_id":"%s"}'::jsonb, %L)$q$, eq_d, mt_d));
    IF v_msg <> 'OKOK' OR (SELECT equipment_id FROM devices WHERE id = mt_d) IS DISTINCT FROM eq_d THEN
        RAISE EXCEPTION 'FIXTURE 256 METER: the device page''s save should move a meter between machines (%)', v_msg; END IF;

    -- ══════════════ READ · 累计寄存器读数 ══════════════
    RAISE NOTICE 'fixture 256 · READ';
    v_msg := pg_temp.f256_do(u_view, format($q$SELECT record_meter_reading(%L, %L, 1000)$q$, mt_a, t0));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|action.confirm_capture%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a viewer must not record a reading, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1000)$q$, mt_a, t0))
          || pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1600)$q$, mt_a, t1));
    IF v_msg <> 'OKOK' THEN RAISE EXCEPTION 'FIXTURE 256 READ: recording two readings, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1250)$q$, mt_a, tm));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a back-dated reading between two should be accepted, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1700)$q$, mt_a, tm2));
    IF v_msg NOT LIKE 'METER_READING_ABOVE_NEXT|1700|1600%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a back-dated reading above the next one, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1500)$q$, mt_a, t1 + interval '1 hour'));
    IF v_msg NOT LIKE 'METER_READING_BELOW_PREVIOUS|1500|1600%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a reading lower than the previous one must be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1600)$q$, mt_a, t1));
    IF v_msg NOT LIKE 'METER_READING_TIME_TAKEN|%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: two readings at one moment, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 2000)$q$, mt_a, now() + interval '1 day'));
    IF v_msg NOT LIKE 'METER_READING_IN_FUTURE|%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a reading in the future, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1)$q$, eq_a, t0));
    IF v_msg NOT LIKE 'METER_READING_DEVICE_NOT_METER|%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a reading on something that is not a meter, got %', v_msg; END IF;
    -- 共用池:50 → 80 → 清零 5(理由)→ 25
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 50)$q$, mt_p, t0))
          || pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 80)$q$, mt_p, tm));
    IF v_msg <> 'OKOK' THEN RAISE EXCEPTION 'FIXTURE 256 READ: pool readings, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 5, true)$q$, mt_p, tm2));
    IF v_msg NOT LIKE 'METER_RESET_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a register reset without a reason, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 5, true, 'Meter replaced by the contractor')$q$, mt_p, tm2));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a register reset with a reason should be accepted, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 25)$q$, mt_p, t1));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a reading after a reset, got %', v_msg; END IF;
    -- 机器 B:200 → 600;机器 D:只有一条
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 200)$q$, mt_b, t0))
          || pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 600)$q$, mt_b, t1))
          || pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 70)$q$, mt_d, tm));
    IF v_msg <> 'OKOKOK' THEN RAISE EXCEPTION 'FIXTURE 256 READ: meter B and D readings, got %', v_msg; END IF;
    -- 当前读数视图的 delta:A 是 250 / 350;清零那一条为空
    v_j := pg_temp.f256_get(u_view, format($q$SELECT jsonb_agg(delta_kwh ORDER BY read_at) FROM meter_readings_current WHERE device_id = %L$q$, mt_a));
    IF v_j IS DISTINCT FROM '[null, 250, 350]'::jsonb THEN RAISE EXCEPTION 'FIXTURE 256 READ: meter A deltas should read [null, 250, 350], got %', v_j; END IF;
    v_j := pg_temp.f256_get(u_view, format($q$SELECT jsonb_agg(delta_kwh ORDER BY read_at) FROM meter_readings_current WHERE device_id = %L$q$, mt_p));
    IF v_j IS DISTINCT FROM '[null, 30, null, 20]'::jsonb THEN RAISE EXCEPTION 'FIXTURE 256 READ: across a register reset the delta is unknown, got %', v_j; END IF;
    -- 更正:新行要理由;更正过的不能再更正;撤回
    SELECT id INTO v_id FROM meter_readings WHERE device_id = mt_b AND register_kwh = 600;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT correct_meter_reading(%s, '', p_register_kwh => 610)$q$, v_id));
    IF v_msg NOT LIKE 'METER_CORRECTION_REASON_REQUIRED%' THEN RAISE EXCEPTION 'FIXTURE 256 READ: a correction without a reason, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT correct_meter_reading(%s, 'Read the wrong register', p_register_kwh => 610)$q$, v_id));
    IF v_msg <> 'OK' OR NOT EXISTS (SELECT 1 FROM meter_readings WHERE corrects_id = v_id AND register_kwh = 610 AND correction_reason = 'Read the wrong register')
       OR (SELECT register_kwh FROM meter_readings WHERE id = v_id) IS DISTINCT FROM 600 THEN
        RAISE EXCEPTION 'FIXTURE 256 READ: a correction should be a new row pointing at the original, which stays (%)', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT correct_meter_reading(%s, 'again', p_register_kwh => 620)$q$, v_id));
    IF v_msg NOT LIKE format('METER_READING_SUPERSEDED|%s%%', v_id) THEN RAISE EXCEPTION 'FIXTURE 256 READ: a superseded reading may not be corrected again, got %', v_msg; END IF;
    SELECT id INTO v_id FROM meter_readings WHERE corrects_id = v_id;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT correct_meter_reading(%s, 'Back to what the display said', p_register_kwh => 600)$q$, v_id));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 256 READ: correcting back, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 650)$q$, mt_b, t1 + interval '30 minutes'));
    SELECT id INTO v_id FROM meter_readings WHERE device_id = mt_b AND register_kwh = 650;
    v_msg := v_msg || pg_temp.f256_do(u_cap, format($q$SELECT correct_meter_reading(%s, 'Recorded on the wrong meter', p_withdraw => true)$q$, v_id));
    IF v_msg <> 'OKOK' OR EXISTS (SELECT 1 FROM meter_readings_current WHERE device_id = mt_b AND register_kwh = 650) THEN
        RAISE EXCEPTION 'FIXTURE 256 READ: a withdrawn reading should leave the current readings (%)', v_msg; END IF;
    -- 只追加:直连改与删都拒
    BEGIN
        UPDATE meter_readings SET register_kwh = 0 WHERE device_id = mt_a;
        RAISE EXCEPTION 'FIXTURE 256 READ: a reading row was updated in place';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'APPEND_ONLY|meter_readings|update%' THEN RAISE; END IF;
    END;

    -- ══════════════ 七炉 ══════════════
    -- A:r1(记 30 kWh,60 分钟,100 kg)· r2(记 10,120 分钟,50 kg);B:r3(记 20,60 分钟,200 kg)· r4(没记,180 分钟,300 kg);
    -- C(没装表):r5;D(只有一条读数):r7;A 但在时间段之外:r6。
    EXECUTE 'SET LOCAL ROLE authenticated';
    r1 := commit_processing_run(d0 + 3, 'f256 r1', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_a, 'deep_discharge', (d0 + 3)::timestamp + interval '9 hours', (d0 + 3)::timestamp + interval '10 hours', 'day');
    r2 := commit_processing_run(d0 + 3, 'f256 r2', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 50)), '[]'::jsonb,
                                'weight', NULL, eq_a, 'deep_discharge', (d0 + 3)::timestamp + interval '11 hours', (d0 + 3)::timestamp + interval '13 hours', 'day');
    r3 := commit_processing_run(d0 + 4, 'f256 r3', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 200)), '[]'::jsonb,
                                'weight', NULL, eq_b, 'deep_discharge', (d0 + 4)::timestamp + interval '9 hours', (d0 + 4)::timestamp + interval '10 hours', 'day');
    r4 := commit_processing_run(d0 + 4, 'f256 r4', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 300)), '[]'::jsonb,
                                'weight', NULL, eq_b, 'deep_discharge', (d0 + 4)::timestamp + interval '11 hours', (d0 + 4)::timestamp + interval '14 hours', 'day');
    r5 := commit_processing_run(d0 + 4, 'f256 r5', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_c, 'deep_discharge', (d0 + 4)::timestamp + interval '15 hours', (d0 + 4)::timestamp + interval '16 hours', 'day');
    r6 := commit_processing_run(CURRENT_DATE - 5, 'f256 r6', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_a, 'deep_discharge', (CURRENT_DATE - 5)::timestamp + interval '9 hours', (CURRENT_DATE - 5)::timestamp + interval '10 hours', 'day');
    r7 := commit_processing_run(d0 + 4, 'f256 r7', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', b, 'quantity_consumed', 100)), '[]'::jsonb,
                                'weight', NULL, eq_d, 'deep_discharge', (d0 + 4)::timestamp + interval '17 hours', (d0 + 4)::timestamp + interval '18 hours', 'day');
    PERFORM record_run_value(r1, 'energy_kwh', '30'::jsonb);
    PERFORM record_run_value(r2, 'energy_kwh', '10'::jsonb);
    PERFORM record_run_value(r3, 'energy_kwh', '20'::jsonb);
    EXECUTE 'RESET ROLE';
    -- 手敲的电费估计:r1 50(会被冲掉)· r5 40(没装表,不动)· r6 35(段外,不动)· r7 30(量不出来的机器,不动);另有 r1 上一条人工费估计(不是电,不动)
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r1, 'electricity', 50, true, 'f256 typed estimate') RETURNING id INTO e1;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r5, 'electricity', 40, true, 'f256 typed estimate') RETURNING id INTO e5;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r6, 'electricity', 35, true, 'f256 typed estimate') RETURNING id INTO e6;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r7, 'electricity', 30, true, 'f256 typed estimate') RETURNING id INTO e7;
    INSERT INTO processing_cost_entries (run_id, cost_type, amount_base, is_estimate, notes) VALUES (r1, 'labour', 20, true, 'f256 labour estimate');

    -- ══════════════ RUNE · 一炉的电量 ══════════════
    RAISE NOTICE 'fixture 256 · RUNE';
    PERFORM set_batch_module_count('inbound', b, 1);
    PERFORM record_discharge_module_result(r1, 'inbound', b, 'M01', 0.4, 'pass', (d0 + 3)::timestamp + interval '9 hours 30 minutes',
                                           p_energy_recovered_wh => 500);
    v_j := pg_temp.f256_get(u_view, format($q$SELECT to_jsonb(e) FROM processing_run_energy e WHERE run_id = %L$q$, r1));
    IF (v_j ->> 'own_kwh')::numeric IS DISTINCT FROM 30 OR (v_j ->> 'energy_kwh')::numeric IS DISTINCT FROM 30 OR v_j ->> 'energy_source' IS DISTINCT FROM 'recorded'
       OR (v_j ->> 'recovered_kwh')::numeric IS DISTINCT FROM 0.5 THEN
        RAISE EXCEPTION 'FIXTURE 256 RUNE: a run''s energy is its own recorded value (30), and energy recovered (0.5 kWh) is shown apart, never netted — got %', v_j; END IF;
    v_j := pg_temp.f256_get(u_view, format($q$SELECT to_jsonb(e) FROM processing_run_energy e WHERE run_id = %L$q$, r4));
    IF v_j ->> 'energy_kwh' IS NOT NULL OR v_j ->> 'energy_source' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 256 RUNE: a run with no recorded energy and no allocation has no energy figure (not zero), got %', v_j; END IF;

    -- ══════════════ V25 · 共用池的规则 ══════════════
    RAISE NOTICE 'fixture 256 · V25';
    v_n := (pg_temp.f256_get(u_all, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V25'$q$))::text::bigint;
    IF v_n IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FIXTURE 256 V25: a shared-pool meter with no rule should list V25 once (got %)', v_n; END IF;
    v_n := (pg_temp.f256_get(u_view, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V25'$q$))::text::bigint;
    IF v_n IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FIXTURE 256 V25: V25 is behind module.finance.view (got % for a processing viewer)', v_n; END IF;

    -- ══════════════ SPLIT · CCY · PERM · 预览 ══════════════
    RAISE NOTICE 'fixture 256 · SPLIT';
    v_p := pg_temp.f256_get(u_finv, format($q$SELECT preview_electricity_allocation(%L, %L, 1337.50, 1200, %L)$q$, d0, d1, v_base));
    IF (v_p ->> 'metered_kwh')::numeric IS DISTINCT FROM 1050 OR (v_p ->> 'shared_pool_kwh')::numeric IS DISTINCT FROM 50 OR (v_p ->> 'unmetered_kwh')::numeric IS DISTINCT FROM 150
       OR (v_p ->> 'allocated_kwh')::numeric IS DISTINCT FROM 1000 OR (v_p ->> 'unallocated_metered_kwh')::numeric IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 256 SPLIT: metered 1050 (A 600 + B 400 + pool 50; D unmeasured), unmetered 150, allocated 1000 — got %', v_p; END IF;
    SELECT jsonb_object_agg(x ->> 'code', jsonb_build_object('basis', x ->> 'basis', 'kwh', (x ->> 'kwh')::numeric, 'amount', (x ->> 'amount')::numeric))
      INTO v_j FROM jsonb_array_elements(v_p -> 'runs') x;
    IF v_j -> (SELECT code FROM processing_runs WHERE id = r1) IS DISTINCT FROM '{"basis": "recorded_energy", "kwh": 450, "amount": 501.56}'::jsonb
       OR v_j -> (SELECT code FROM processing_runs WHERE id = r2) IS DISTINCT FROM '{"basis": "recorded_energy", "kwh": 150, "amount": 167.19}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 256 SPLIT: machine A — every run recorded its energy, so 600 kWh splits 30 : 10 → 450 / 150 by recorded energy; got %', v_j; END IF;
    IF v_j -> (SELECT code FROM processing_runs WHERE id = r3) IS DISTINCT FROM '{"basis": "run_time", "kwh": 100, "amount": 111.46}'::jsonb
       OR v_j -> (SELECT code FROM processing_runs WHERE id = r4) IS DISTINCT FROM '{"basis": "run_time", "kwh": 300, "amount": 334.38}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 256 SPLIT: machine B — one run without energy switches the whole machine to run time (60 : 180 min → 100 / 300), the recorded run too; got %', v_j; END IF;
    IF COALESCE(jsonb_array_length(v_p -> 'runs'), 0) <> 4 OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_p -> 'runs') x WHERE x ->> 'basis' IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 256 SPLIT: four runs covered (not C without a meter, not D unmeasured, not the run outside the period), each with its basis'; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_p -> 'machines') x WHERE (x ->> 'equipment_id')::uuid = eq_d AND NOT (x ->> 'measured')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 256 SPLIT: machine D (one reading) should be reported as not measured'; END IF;
    IF (v_p ->> 'allocated_amount')::numeric IS DISTINCT FROM 1114.59 OR (v_p ->> 'overhead_amount')::numeric IS DISTINCT FROM 222.91 THEN
        RAISE EXCEPTION 'FIXTURE 256 SPLIT: runs 1114.59, the rest (unmetered and the shared pool) 222.91 in 6200 — got % / %', v_p ->> 'allocated_amount', v_p ->> 'overhead_amount'; END IF;
    IF (SELECT string_agg((x ->> 'id'), ',') FROM jsonb_array_elements(v_p -> 'estimates') x) IS DISTINCT FROM e1::text THEN
        RAISE EXCEPTION 'FIXTURE 256 SPLIT: only the electricity estimate on a covered run (r1) is to be relieved — got %', v_p -> 'estimates'; END IF;

    RAISE NOTICE 'fixture 256 · CCY';
    IF v_other IS NOT NULL THEN
        v_msg := pg_temp.f256_do(u_all, format($q$SELECT preview_electricity_allocation(%L, %L, 100, 100, %L)$q$, d0, d1, v_other));
        IF v_msg NOT LIKE format('ELECTRICITY_BILL_CURRENCY_NOT_BASE|%s|%s%%', v_other, base_currency_code()) THEN
            RAISE EXCEPTION 'FIXTURE 256 CCY: a foreign-currency bill must be refused by name, naming the base read from data — got %', v_msg; END IF;
    END IF;
    IF (v_p ->> 'currency') IS DISTINCT FROM base_currency_code() THEN
        RAISE EXCEPTION 'FIXTURE 256 CCY: the allocation''s currency is the base currency read from data, got %', v_p ->> 'currency'; END IF;
    v_msg := pg_temp.f256_do(u_all, format($q$SELECT preview_electricity_allocation(%L, %L, 1000, 1000, %L)$q$, d0, d1, v_base));
    IF v_msg NOT LIKE 'ELECTRICITY_METERED_EXCEEDS_BILL|1050|1000%' THEN
        RAISE EXCEPTION 'FIXTURE 256 CCY: more metered than billed must be refused, got %', v_msg; END IF;

    RAISE NOTICE 'fixture 256 · PERM';
    v_msg := pg_temp.f256_do(u_view, format($q$SELECT preview_electricity_allocation(%L, %L, 1337.50, 1200, %L)$q$, d0, d1, v_base));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.view%' THEN RAISE EXCEPTION 'FIXTURE 256 PERM: a preview needs module.finance.view, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_finv, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-256', 1337.50, 1200, %L, 'unpaid', NULL, %L)$q$, d0, d1, d1 + 1, v_base, v_sup));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.edit%' THEN RAISE EXCEPTION 'FIXTURE 256 PERM: posting needs module.finance.edit, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_finv, $q$SELECT set_electricity_shared_pool_rule('pro rata')$q$);
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.edit%' THEN RAISE EXCEPTION 'FIXTURE 256 PERM: V25 is set under module.finance.edit, got %', v_msg; END IF;

    -- ══════════════ ALLOC · 过账 ══════════════
    RAISE NOTICE 'fixture 256 · ALLOC';
    v_b2200 := pg_temp.f256_bal('2200'); v_b5110 := pg_temp.f256_bal('5110'); v_b6200 := pg_temp.f256_bal('6200'); v_b2000 := pg_temp.f256_bal('2000');
    v_j := pg_temp.f256_get(u_all, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-256', 1337.50, 1200, %L, 'unpaid', NULL, %L)$q$, d0, d1, d1 + 1, v_base, v_sup));
    v_alloc := (v_j ->> 'allocation_id')::uuid; v_exp := (v_j ->> 'expense_id')::uuid;
    SELECT journal_entry_id INTO v_je FROM electricity_allocations WHERE id = v_alloc;
    -- 预览 = 过账:表头逐键、每一行逐键
    IF NOT EXISTS (SELECT 1 FROM electricity_allocations a WHERE a.id = v_alloc
                     AND a.metered_kwh = (v_p ->> 'metered_kwh')::numeric AND a.allocated_kwh = (v_p ->> 'allocated_kwh')::numeric
                     AND a.shared_pool_kwh = (v_p ->> 'shared_pool_kwh')::numeric AND a.unmetered_kwh = (v_p ->> 'unmetered_kwh')::numeric
                     AND a.unallocated_metered_kwh = (v_p ->> 'unallocated_metered_kwh')::numeric
                     AND a.allocated_amount = (v_p ->> 'allocated_amount')::numeric AND a.overhead_amount = (v_p ->> 'overhead_amount')::numeric
                     AND a.price_per_kwh = (v_p ->> 'price_per_kwh')::numeric
                     AND a.relieved_estimate_amount = (v_p ->> 'relieved_estimate_amount')::numeric
                     AND a.relieved_estimate_count = (v_p ->> 'relieved_estimate_count')::int AND a.currency = base_currency_code()) THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: the posted header must equal the preview key by key (%)', v_p; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_p -> 'runs') x
                WHERE NOT EXISTS (SELECT 1 FROM electricity_allocation_lines l WHERE l.allocation_id = v_alloc AND l.run_id = (x ->> 'run_id')::uuid
                                    AND l.basis = x ->> 'basis' AND l.kwh = (x ->> 'kwh')::numeric AND l.amount = (x ->> 'amount')::numeric
                                    AND l.share = (x ->> 'share')::numeric AND l.machine_kwh = (x ->> 'machine_kwh')::numeric))
       OR (SELECT count(*) FROM electricity_allocation_lines WHERE allocation_id = v_alloc) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: every posted line must equal its preview line (one per covered run)'; END IF;
    -- 一张费用单:本位币、未付、挂供应商、账单金额
    IF (SELECT count(*) FROM expenses WHERE id = v_exp) <> 1
       OR NOT EXISTS (SELECT 1 FROM expenses e WHERE e.id = v_exp AND e.amount_base = 1337.50 AND e.amount_ccy = 1337.50
                        AND e.currency = base_currency_code() AND e.payment_status = 'unpaid' AND e.supplier_id = v_sup
                        AND e.journal_entry_id = v_je AND e.status = 'posted') THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: one expense document for the bill (base currency, unpaid, the supplier, the allocation''s journal)'; END IF;
    -- 那张分录:借 2200 1114.59 · 借 6200 222.91 · 贷 2000 1337.50,平
    SELECT jsonb_object_agg(a.code || ':' || CASE WHEN l.debit > 0 THEN 'debit' ELSE 'credit' END, l.debit + l.credit) INTO v_j
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je;
    IF v_j IS DISTINCT FROM '{"2200:debit": 1114.59, "6200:debit": 222.91, "2000:credit": 1337.50}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: the allocation journal should be Dr 2200 1114.59 / Dr 6200 222.91 / Cr 2000 1337.50, got %', v_j; END IF;
    -- 各炉的实际电费行:已结(账单日、这张分录),改不了
    IF (SELECT count(*) FROM processing_cost_entries c JOIN electricity_allocation_lines l ON l.cost_entry_id = c.id
         WHERE l.allocation_id = v_alloc AND c.cost_type = 'electricity' AND NOT c.is_estimate AND c.amount_base = l.amount
           AND c.remitted_at = d1 + 1 AND c.remitted_journal_entry_id = v_je AND c.deleted_at IS NULL) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: each covered run should carry one settled actual electricity line for its share'; END IF;
    BEGIN
        UPDATE processing_cost_entries SET amount_base = 1 WHERE id = (SELECT cost_entry_id FROM electricity_allocation_lines WHERE run_id = r1);
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: an allocated line could be edited';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'COST_ENTRY_SETTLED|%' THEN RAISE; END IF;
    END;
    -- 估计:r1 的电费估计被冲掉(软删 + 冲抵到这张费用单);r5 · r6 · r7 的与 r1 的人工费估计一条不动
    IF NOT EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e1 AND deleted_at IS NOT NULL AND relieved_at = d1 + 1 AND relief_expense_id = v_exp) THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: the typed electricity estimate on a covered run must be relieved (and leave the run''s cost)'; END IF;
    IF EXISTS (SELECT 1 FROM processing_cost_entries WHERE id IN (e5, e6, e7) AND (deleted_at IS NOT NULL OR relieved_at IS NOT NULL))
       OR EXISTS (SELECT 1 FROM processing_cost_entries WHERE run_id = r1 AND cost_type = 'labour' AND deleted_at IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: estimates on uncovered runs (no meter, unmeasured, outside the period) and other cost types must be untouched'; END IF;
    IF (SELECT count(*) FROM processing_cost_entries WHERE run_id = r1 AND cost_type = 'electricity' AND deleted_at IS NULL) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: a covered run must not carry both an estimate and an actual line'; END IF;
    -- 总账(从过账之前量起):2200 +50(份额的应计 1114.59 被这张分录结掉,净 0;r1 那条估计在过账之前就记下的 50 应计被冲掉)·
    --   5110 +1114.59 −50 = +1064.59 · 6200 +222.91 · 2000 −1337.50
    IF pg_temp.f256_bal('2200') - v_b2200 IS DISTINCT FROM 50 OR pg_temp.f256_bal('5110') - v_b5110 IS DISTINCT FROM 1064.59
       OR pg_temp.f256_bal('6200') - v_b6200 IS DISTINCT FROM 222.91 OR pg_temp.f256_bal('2000') - v_b2000 IS DISTINCT FROM -1337.50 THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: ledger moves should be 2200 +50 / 5110 +1064.59 / 6200 +222.91 / 2000 −1337.50, got % / % / % / %',
            pg_temp.f256_bal('2200') - v_b2200, pg_temp.f256_bal('5110') - v_b5110, pg_temp.f256_bal('6200') - v_b6200, pg_temp.f256_bal('2000') - v_b2000; END IF;
    -- 应付清单 = 总账,unexplained 0.00
    v_j := pg_temp.f256_get(u_all, $q$SELECT list_ledger_reconciliation()$q$);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j -> 'sides') s WHERE (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j -> 'sides') s WHERE s ->> 'side' = 'ap') THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC: AP list = ledger with 0.00 unexplained after posting, got %', v_j -> 'sides'; END IF;
    -- 分到电量之后:r4 的电量是分到的 300 kWh(它自己没记),r1 仍是它自己记的 30(分到 450 也不变)
    v_j := pg_temp.f256_get(u_view, format($q$SELECT to_jsonb(e) FROM processing_run_energy e WHERE run_id = %L$q$, r4));
    IF (v_j ->> 'energy_kwh')::numeric IS DISTINCT FROM 300 OR v_j ->> 'energy_source' IS DISTINCT FROM 'allocated' OR v_j ->> 'allocation_basis' IS DISTINCT FROM 'run_time' THEN
        RAISE EXCEPTION 'FIXTURE 256 RUNE: a run without its own value uses its allocated share (300, run time), got %', v_j; END IF;
    v_j := pg_temp.f256_get(u_view, format($q$SELECT to_jsonb(e) FROM processing_run_energy e WHERE run_id = %L$q$, r1));
    IF (v_j ->> 'energy_kwh')::numeric IS DISTINCT FROM 30 OR (v_j ->> 'allocated_kwh')::numeric IS DISTINCT FROM 450 THEN
        RAISE EXCEPTION 'FIXTURE 256 RUNE: a recorded value wins over the allocated share (30, not 450), got %', v_j; END IF;

    -- ══════════════ TONNE · 每吨 ══════════════
    RAISE NOTICE 'fixture 256 · TONNE';
    -- r1:30 kWh ÷ 0.1 t = 300;r4:300 kWh ÷ 0.3 t = 1000
    IF (pg_temp.f256_get(u_view, format($q$SELECT to_jsonb(kwh_per_tonne) FROM processing_run_energy WHERE run_id = %L$q$, r1)))::text::numeric IS DISTINCT FROM 300
       OR (pg_temp.f256_get(u_view, format($q$SELECT to_jsonb(kwh_per_tonne) FROM processing_run_energy WHERE run_id = %L$q$, r4)))::text::numeric IS DISTINCT FROM 1000 THEN
        RAISE EXCEPTION 'FIXTURE 256 TONNE: per tonne divides by total input (r1 30 kWh / 0.1 t = 300; r4 300 / 0.3 = 1000)'; END IF;

    -- ══════════════ 重叠 · 撤销 ══════════════
    RAISE NOTICE 'fixture 256 · REV';
    v_msg := pg_temp.f256_do(u_all, format($q$SELECT preview_electricity_allocation(%L, %L, 10, 100, %L)$q$, d1, d1, v_base));
    IF v_msg NOT LIKE 'ELECTRICITY_PERIOD_OVERLAPS|%' THEN RAISE EXCEPTION 'FIXTURE 256 CCY: an overlapping period must be refused, got %', v_msg; END IF;
    v_msg := pg_temp.f256_do(u_all, format($q$SELECT reverse_expense(%L, 'fixture 256: reversal reason')$q$, v_exp));
    IF v_msg NOT LIKE 'EXPENSE_IS_ELECTRICITY_ALLOCATION|%' THEN RAISE EXCEPTION 'FIXTURE 256 REV: the allocation''s expense must not be reversed on its own, got %', v_msg; END IF;

    -- ══════════════ MASK · 金额遮蔽 ══════════════
    RAISE NOTICE 'fixture 256 · MASK';
    v_j := pg_temp.f256_get(u_proc, format($q$SELECT to_jsonb(a) FROM electricity_allocations_masked a WHERE id = %L$q$, v_alloc));
    IF v_j ->> 'bill_amount' IS NOT NULL OR v_j ->> 'allocated_amount' IS NOT NULL OR v_j ->> 'overhead_amount' IS NOT NULL
       OR v_j ->> 'price_per_kwh' IS NOT NULL OR v_j ->> 'relieved_estimate_amount' IS NOT NULL OR (v_j ->> 'bill_kwh')::numeric IS DISTINCT FROM 1200 THEN
        RAISE EXCEPTION 'FIXTURE 256 MASK: a reader without data.view_prices sees no amount but the kWh, got %', v_j; END IF;
    v_j := pg_temp.f256_get(u_proc, format($q$SELECT jsonb_agg(jsonb_build_object('amount', amount, 'kwh', kwh)) FROM electricity_allocation_lines_masked WHERE allocation_id = %L$q$, v_alloc));
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE x ->> 'amount' IS NOT NULL OR x ->> 'kwh' IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 256 MASK: line amounts masked, kWh visible, got %', v_j; END IF;
    v_j := pg_temp.f256_get(u_all, format($q$SELECT to_jsonb(a) FROM electricity_allocations_masked a WHERE id = %L$q$, v_alloc));
    IF (v_j ->> 'bill_amount')::numeric IS DISTINCT FROM 1337.50 THEN RAISE EXCEPTION 'FIXTURE 256 MASK: a reader with data.view_prices sees the amount'; END IF;
    IF has_column_privilege('authenticated', 'public.electricity_allocations'::regclass, 'bill_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_lines'::regclass, 'amount', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.electricity_allocations'::regclass, 'bill_kwh', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 256 MASK: amounts stay out of the column grant, kWh in it'; END IF;

    -- ══════════════ LOG · 变更记录与审计记录 ══════════════
    RAISE NOTICE 'fixture 256 · LOG';
    v_j := change_log_coverage_gaps();
    IF COALESCE(jsonb_array_length(v_j -> 'gaps'), -1) <> 0 OR (v_j ->> 'excluded')::int IS DISTINCT FROM 8 THEN
        RAISE EXCEPTION 'FIXTURE 256 LOG: every new table logged, exclusions still 8 — got %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'meter_readings' AND op = 'INSERT')
       OR NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'electricity_allocations' AND op = 'INSERT')
       OR NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'electricity_allocation_lines' AND op = 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 256 LOG: readings, the allocation and its lines should be in the change log'; END IF;
    v_n := (pg_temp.f256_get(u_all, format($q$SELECT to_jsonb(count(*)) FROM record_trail('electricity_allocation', %L, 500) t WHERE t.table_name = 'electricity_allocation_lines'$q$, v_alloc)))::text::bigint;
    IF v_n IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'FIXTURE 256 LOG: the allocation''s trail should carry its four lines (got %)', v_n; END IF;
    v_n := (pg_temp.f256_get(u_all, format($q$SELECT to_jsonb(count(*)) FROM record_trail('processing_run', %L, 500) t WHERE t.table_name = 'electricity_allocation_lines'$q$, r4)))::text::bigint;
    IF v_n IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FIXTURE 256 LOG: the run''s trail should show its allocation line (got %)', v_n; END IF;
    v_n := (pg_temp.f256_get(u_all, format($q$SELECT to_jsonb(count(*)) FROM record_trail('device', %L, 500) t WHERE t.table_name = 'meter_readings'$q$, mt_a)))::text::bigint;
    IF COALESCE(v_n, 0) < 3 THEN RAISE EXCEPTION 'FIXTURE 256 LOG: the meter''s trail should carry its readings (got %)', v_n; END IF;

    -- ══════════════ V25 · 写下规则 ══════════════
    RAISE NOTICE 'fixture 256 · V25';
    v_msg := pg_temp.f256_do(u_all, $q$SELECT set_electricity_shared_pool_rule('Spread by run time across all metered machines')$q$);
    v_n := (pg_temp.f256_get(u_all, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V25'$q$))::text::bigint;
    IF v_msg <> 'OK' OR v_n IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FIXTURE 256 V25: writing the rule clears the V25 row (%, %)', v_msg, v_n; END IF;
    -- 规则写下之后,共用池量到的电【仍然】留在 6200(本刀不按它摊):下一段共用池 30 → 40 = 10 kWh,账单全部是余数
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 30)$q$, mt_p, ((d1 + 1)::timestamp + interval '12 hours') AT TIME ZONE 'Asia/Singapore'))
          || pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 40)$q$, mt_p, ((d1 + 3)::timestamp + interval '12 hours') AT TIME ZONE 'Asia/Singapore'));
    v_p := pg_temp.f256_get(u_all, format($q$SELECT preview_electricity_allocation(%L, %L, 500, 1000, %L)$q$, d1 + 1, d1 + 3, v_base));
    IF (v_p ->> 'shared_pool_rule') IS DISTINCT FROM 'Spread by run time across all metered machines' THEN
        RAISE EXCEPTION 'FIXTURE 256 V25: the preview should name the rule as written, got %', v_p ->> 'shared_pool_rule'; END IF;
    IF v_msg <> 'OKOK' OR (v_p ->> 'shared_pool_kwh')::numeric IS DISTINCT FROM 10 OR (v_p ->> 'overhead_amount')::numeric IS DISTINCT FROM 500 OR (v_p ->> 'allocated_amount')::numeric IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 256 V25: with the rule written the shared pool still stays in 6200 (pool 10 kWh, overhead 500) — got % / % / %',
            v_p ->> 'shared_pool_kwh', v_p ->> 'overhead_amount', v_msg; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'electricity_settings' AND op = 'UPDATE') THEN
        RAISE EXCEPTION 'FIXTURE 256 V25: the rule change should be in the change log'; END IF;

    -- ══════════════ ALLOC-PAID · 一张已付的本位币电费单(MES-5b-2,Q29)══════════════
    RAISE NOTICE 'fixture 256 · ALLOC-PAID';
    SELECT c INTO v_id_bank FROM unnest(ARRAY['1000', '1010']) c WHERE bank_native_currency(c) = v_base LIMIT 1;
    SELECT c INTO v_fbank FROM unnest(ARRAY['1000', '1010']) c WHERE bank_native_currency(c) IS DISTINCT FROM v_base LIMIT 1;
    v_msg := pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1700)$q$, mt_a, ((CURRENT_DATE - 6)::timestamp + interval '1 hour') AT TIME ZONE 'Asia/Singapore'))
          || pg_temp.f256_do(u_cap, format($q$SELECT record_meter_reading(%L, %L, 1800)$q$, mt_a, ((CURRENT_DATE - 4)::timestamp + interval '23 hours') AT TIME ZONE 'Asia/Singapore'));
    IF v_msg <> 'OKOK' THEN RAISE EXCEPTION 'FIXTURE 256 ALLOC-PAID: setup readings (%)', v_msg; END IF;
    IF v_fbank IS NOT NULL THEN
        v_msg := pg_temp.f256_do(u_all, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-256-P', 250, 200, %L, 'paid', %L)$q$,
                                              CURRENT_DATE - 6, CURRENT_DATE - 4, CURRENT_DATE - 3, v_base, v_fbank));
        IF v_msg NOT LIKE format('ELECTRICITY_BANK_NOT_BASE|%s|%s%%', v_fbank, v_base) THEN
            RAISE EXCEPTION 'FIXTURE 256 ALLOC-PAID: a foreign-currency bank must be refused by name, got %', v_msg; END IF;
    END IF;
    v_b2200 := pg_temp.f256_bal('2200'); v_b6200 := pg_temp.f256_bal('6200'); v_b2000 := pg_temp.f256_bal('2000'); v_num := pg_temp.f256_bal(v_id_bank);
    v_j := pg_temp.f256_get(u_all, format($q$SELECT post_electricity_allocation(%L, %L, %L, 'INV-256-P', 250, 200, %L, 'paid', %L)$q$,
                                          CURRENT_DATE - 6, CURRENT_DATE - 4, CURRENT_DATE - 3, v_base, v_id_bank));
    v_alloc := (v_j ->> 'allocation_id')::uuid; v_exp := (v_j ->> 'expense_id')::uuid;
    SELECT journal_entry_id INTO v_je FROM electricity_allocations WHERE id = v_alloc;
    SELECT jsonb_object_agg(a.code || ':' || CASE WHEN l.debit > 0 THEN 'debit' ELSE 'credit' END, l.debit + l.credit) INTO v_j
      FROM journal_lines l JOIN accounts a ON a.id = l.account_id WHERE l.entry_id = v_je;
    IF v_j IS DISTINCT FROM jsonb_build_object('2200:debit', 125.00, '6200:debit', 125.00, v_id_bank || ':credit', 250.00) THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC-PAID: a paid bill is Dr 2200 125 / Dr 6200 125 / Cr the base bank 250 (never 2000), got %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM expenses e WHERE e.id = v_exp AND e.payment_status = 'paid' AND e.bank_account_code = v_id_bank
                     AND e.supplier_id IS NULL AND e.amount_base = 250 AND e.currency = v_base)
       OR NOT EXISTS (SELECT 1 FROM electricity_allocations WHERE id = v_alloc AND payment_status = 'paid' AND bank_account_code = v_id_bank) THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC-PAID: the expense and the allocation are paid from the base bank, with no supplier needed'; END IF;
    IF pg_temp.f256_bal(v_id_bank) - v_num IS DISTINCT FROM -250.00 OR pg_temp.f256_bal('2000') - v_b2000 IS DISTINCT FROM 0
       OR pg_temp.f256_bal('6200') - v_b6200 IS DISTINCT FROM 125.00 OR pg_temp.f256_bal('2200') - v_b2200 IS DISTINCT FROM 35.00 THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC-PAID: ledger moves should be bank −250 / 2000 0 / 6200 +125 / 2200 +35 (the relieved estimate), got % / % / % / %',
            pg_temp.f256_bal(v_id_bank) - v_num, pg_temp.f256_bal('2000') - v_b2000, pg_temp.f256_bal('6200') - v_b6200, pg_temp.f256_bal('2200') - v_b2200; END IF;
    IF NOT EXISTS (SELECT 1 FROM processing_cost_entries WHERE id = e6 AND deleted_at IS NOT NULL AND relief_expense_id = v_exp) THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC-PAID: r6''s typed estimate is relieved by the paid bill'; END IF;
    v_j := pg_temp.f256_get(u_all, $q$SELECT list_ledger_reconciliation()$q$);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j -> 'sides') s WHERE (s ->> 'unexplained_base')::numeric IS DISTINCT FROM 0)
       OR EXISTS (SELECT 1 FROM ap_open_items WHERE doc_id = v_exp) THEN
        RAISE EXCEPTION 'FIXTURE 256 ALLOC-PAID: a paid bill is never on the AP list; AP list = ledger with 0.00 unexplained, got %', v_j -> 'sides'; END IF;

    RAISE NOTICE 'FIXTURE 256 全部通过: METER · READ · RUNE · SPLIT · TONNE · ALLOC · CCY · PERM · MASK · LOG · V25 · REV · ALLOC-PAID';
END;
$$;

ROLLBACK;

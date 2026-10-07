-- 251 MES-3a:一张收货对着执照的库存上限判一次并记下来;鼓包或漏液只能进隔离库位;一条安全状态被结束而不是被删,
--     它待了多久读得出来;加工的回滚撤回它对状态做过的事(MES-3a Step 0 Q1–Q33;v1.4.39)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一组裁定;每一臂都有故障注入(db/scripts/2026-10-06-mes3a-fixture-injections.py)必须让它红在它点名的那一臂。
--   PV       待补的值:V29(类别列表是空的 → 一行;有了 → 每一种没有类别的电池料一行)· V2(在效执照 × 没给上限的类别)·
--            V3(没给滞留天数的状态)· V4(没定要不要隔离的状态)· V34(要隔离、却一个隔离库位都没有);给了就消失;
--            不持那一支的码的人一行都看不见(Q31)
--   CEIL     库存上限的五种结果,在两支收货函数与 create_output_batch 上:licence_not_in_force · category_not_set ·
--            ceiling_not_set · within(存量是这一批进来之前的、三种库存状态都算)· 超过给了的上限按名拒 STORAGE_CEILING_EXCEEDED
--            (什么都不留);执照按"那一天在效的 gwdf"挑,过期的那张不算(Q5–Q10)
--   TOTAL    执照的总上限(approved_storage_limit_tonnes)对着所有有类别的存量之和:超了按名拒(类别写 *);没超照收、记在 total_*(Q6)
--   UNIT     换算不成吨(件):这一类没给上限 → 记 unit_not_convertible;给了 → 按名拒 STORAGE_CEILING_UNIT_NOT_CONVERTIBLE(Q8)
--   EXCEEDED 不经收货而超了(加工把料变成了有上限的那一类;上限被调低)→ storage_ceiling_status = exceeded,提醒臂
--            storage_ceiling_exceeded 只给持库存查看码的人;加工本身不被拒(Q9 · Q13)
--   DWELL    滞留时钟从状态被记下的那一刻起算,不因保存重来;没给天数 → not_set;到了 → past,上提醒臂 safety_state_dwell
--            (只给持那一侧查看码的人);货不在厂里了就不上(Q14–Q16)
--   QUAR     收货与转移:要隔离的状态只能落进在用的隔离库位(未指定不算);不要隔离 / 没定的照收;移进隔离永远准许;
--            一个状态记在已经放好的货上【不拒】,但被标出来(quarantine_exposure · 提醒臂 quarantine_required),
--            而它的下一次移动只能进隔离(Q17–Q21)
--   HIST     只加新勾上的、只结束拿掉的;拿掉要理由;直连写按名拒;删除永远拒;一行只结束一次;结束只改那四格(Q22–Q25)
--   RUN      一炉深度放电结束它解决掉的状态(记下是哪一炉)、写上的结果状态记 created_by_run_id;回滚结束它写上的那一条、
--            把它结束掉的重新开出来(记录时刻照抄原行);批次本来就带着的那一条,回滚不碰(Q2)
--   MOVE     库存流水不许从会话里直连插:MOVEMENTS_THROUGH_FUNCTION_ONLY(Q3)
--   TICKET   收货单页上那一行地磅单的数据源:分出去之后更正毛重,weighbridge_ticket_weights 的净重与差额跟着变(裁定 2)
--
-- 并发(两张收货都"刚好没超")不是一个会话里证得了的事 —— 它由 db/scripts/2026-10-06-mes3a-ceiling-concurrency.py
-- 在一份重建库上用两条连接证,并且注入"不锁"让它红。
--
-- 自带数据(README 第 2 条)。以 postgres 跑(绕过 RLS)—— 员工的读写真的切成 authenticated + 那个人的 JWT。
-- 会改状态的"能不能过"一律放进 f251_try(失败的那一次整句回滚);要看记录的才真写。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f251_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;成功回 'OK'(改动留着),失败回错误原文(没名字的 42501 回 '42501')
CREATE FUNCTION pg_temp.f251_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f251_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN CASE WHEN SQLSTATE = '42501' AND SQLERRM NOT LIKE 'PERMISSION_DENIED%' THEN '42501' ELSE SQLERRM END;
END;
$f$;

-- 以某人的身份读一个 jsonb;读不出来就抛,带着臂名 —— 一次失败不许被读成 0 或 NULL
CREATE FUNCTION pg_temp.f251_read(p_arm text, p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f251_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RAISE EXCEPTION 'FIXTURE 251 %: the read failed: % — %', p_arm, SQLSTATE, SQLERRM;
END;
$f$;

-- 一张收货(建单那一支),回批次 id;p_loc 空 = 未指定
CREATE FUNCTION pg_temp.f251_rcv(p_arm text, p_user uuid, p_mat uuid, p_sup uuid, p_qty numeric, p_unit text, p_on date,
                                 p_loc uuid DEFAULT NULL, p_states text[] DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
BEGIN
    RETURN (pg_temp.f251_read(p_arm, p_user, format(
        $q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => %s, p_unit => %L, p_arrival_date => %L,
              p_location_id => %L, p_safety_states => %L::text[], p_chemistry_certainty => 'single_known',
              p_source_reason_code => 'other', p_source_reason_note => 'fixture 251') -> 'batch_id'$q$,
        p_mat, p_sup, p_qty, p_unit, p_on, p_loc, p_states))) #>> '{}';
END;
$f$;

-- 同一张收货,但只要它的拒绝原文(失败的那一次整句回滚)
CREATE FUNCTION pg_temp.f251_rcv_try(p_user uuid, p_mat uuid, p_sup uuid, p_qty numeric, p_unit text, p_on date,
                                     p_loc uuid DEFAULT NULL, p_states text[] DEFAULT NULL) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    RETURN pg_temp.f251_try(p_user, format(
        $q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => %s, p_unit => %L, p_arrival_date => %L,
              p_location_id => %L, p_safety_states => %L::text[], p_chemistry_certainty => 'single_known',
              p_source_reason_code => 'other', p_source_reason_note => 'fixture 251')$q$,
        p_mat, p_sup, p_qty, p_unit, p_on, p_loc, p_states));
END;
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码
    u_inb  uuid := gen_random_uuid();   -- 只看进料
    u_inv  uuid := gen_random_uuid();   -- 只看库存
    u_none uuid := gen_random_uuid();   -- 一个码都没有
    r_all uuid; r_inb uuid; r_inv uuid; r_none uuid;
    d date := (now() AT TIME ZONE 'Asia/Singapore')::date;
    v_ccy text;
    sup uuid; m_a uuid; m_b uuid; m_n uuid;
    lic uuid; lic_old uuid; lim_a uuid; lim_b uuid;
    l_norm uuid; l_norm2 uuid; q1 uuid; q2 uuid; l_norm_code text;
    b uuid; b2 uuid; b_in uuid; b_q uuid; b_p uuid; b_h uuid; b_d1 uuid; b_d2 uuid; b_r uuid; b_r2 uuid; o uuid; o_p uuid;
    run uuid; run2 uuid; t uuid; w_g uuid;
    v_j jsonb; v_msg text; v_n int; v_m int; v_t text; v_x uuid; v_y uuid; v_at timestamptz; v_k numeric;
    v_codes text[];
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx251-all@test.local', now(), now()), (u_inb, 'fx251-inb@test.local', now(), now()),
        (u_inv, 'fx251-inv@test.local', now(), now()), (u_none, 'fx251-none@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx251-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx251-inb', 'f', 'f', true) RETURNING id INTO r_inb;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx251-inv', 'f', 'f', true) RETURNING id INTO r_inv;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx251-none', 'f', 'f', true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_inb, 'module.inbound.view'), (r_inv, 'module.inventory.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_inb, r_inb), (u_inv, r_inv), (u_none, r_none);
    PERFORM pg_temp.f251_as(u_all);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ251-S', 'f251 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code) VALUES
        ('ZZ251-A', 'f251 category A', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction'),
        ('ZZ251-B', 'f251 category B', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction'),
        ('ZZ251-N', 'f251 no category', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction');
    SELECT id INTO m_a FROM materials WHERE code = 'ZZ251-A';
    SELECT id INTO m_b FROM materials WHERE code = 'ZZ251-B';
    SELECT id INTO m_n FROM materials WHERE code = 'ZZ251-N';

    -- ══════════════ PV · 一开始:类别列表空(V29 一行)· 五个状态都没给天数(V3)· 三个没定隔离(V4)· 没有隔离库位(V34)══════════════
    IF EXISTS (SELECT 1 FROM nea_waste_categories) OR EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine) THEN
        RAISE EXCEPTION 'FIXTURE 251 PV: setup — a fresh database should have no NEA category and no quarantine location'; END IF;
    v_j := pg_temp.f251_read('PV', u_all, $q$SELECT jsonb_agg(value_code || ':' || item_code ORDER BY value_code, item_code) FROM pending_values WHERE value_code IN ('V2','V29','V3','V4','V34')$q$);
    IF v_j IS DISTINCT FROM '["V29:nea_waste_categories", "V3:charged_not_discharged", "V3:damaged_deformed", "V3:discharged_verified", "V3:swollen_leaking", "V3:water_exposed", "V34:quarantine_location", "V4:charged_not_discharged", "V4:damaged_deformed", "V4:water_exposed"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 251 PV: the opening pending values are wrong: %', v_j; END IF;
    v_n := (pg_temp.f251_read('PV', u_none, $q$SELECT to_jsonb(count(*)) FROM pending_values$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 PV: a reader with no code sees % pending value(s)', v_n; END IF;
    v_n := (pg_temp.f251_read('PV', u_inv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code <> 'V34'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 PV: a reader with only inventory view sees % value(s) of other codes', v_n; END IF;

    -- ══════════════ CEIL · licence_not_in_force(还没有执照)══════════════
    b := pg_temp.f251_rcv('CEIL', u_all, m_a, sup, 1000, 'kg', d);
    SELECT outcome, licence_id INTO v_t, v_x FROM receipt_ceiling_checks WHERE inbound_batch_id = b;
    IF v_t IS DISTINCT FROM 'licence_not_in_force' OR v_x IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: with no licence the receipt should record licence_not_in_force, got %', v_t; END IF;

    -- 执照:一张过期的、一张今天在效的(只有后者算 —— Q5)
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, status, valid_from, valid_until)
    VALUES ('gwdf', 'ZZ-F251-OLD', 'NEA', 'active', d - 400, d - 31) RETURNING id INTO lic_old;
    INSERT INTO company_compliance (cert_type_code, cert_no, issuing_body, status, valid_from, valid_until)
    VALUES ('gwdf', 'ZZ-F251', 'NEA', 'active', d - 30, d + 30) RETURNING id INTO lic;
    IF storage_licence_in_force(d) IS DISTINCT FROM lic OR storage_licence_in_force(d - 100) IS DISTINCT FROM lic_old
       OR storage_licence_in_force(d + 31) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: storage_licence_in_force did not pick the licence in force on the date'; END IF;

    -- 类别:两类;A 与 B 两种料,N 没有类别
    INSERT INTO nea_waste_categories (code, name_en, name_zh, sort_order) VALUES
        ('F251A', 'f251 category A', 'f251 类别 A', 1), ('F251B', 'f251 category B', 'f251 类别 B', 2);
    UPDATE materials SET nea_waste_category_code = 'F251A' WHERE id = m_a;
    UPDATE materials SET nea_waste_category_code = 'F251B' WHERE id = m_b;

    -- PV:V29 换成"没有类别的电池料";V2 = 在效执照 × 两类
    v_j := pg_temp.f251_read('PV', u_all, $q$SELECT jsonb_agg(value_code || ':' || item_code ORDER BY value_code, item_code) FROM pending_values WHERE value_code IN ('V2','V29') AND (item_code LIKE 'F251%' OR item_code LIKE 'ZZ251%' OR item_code = 'nea_waste_categories')$q$);
    IF v_j IS DISTINCT FROM '["V2:F251A", "V2:F251B", "V29:ZZ251-N"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 251 PV: after the categories exist, V2 / V29 should be the two categories and the uncategorised material: %', v_j; END IF;

    -- ══════════════ CEIL · category_not_set · ceiling_not_set ══════════════
    b := pg_temp.f251_rcv('CEIL', u_all, m_n, sup, 500, 'kg', d);
    SELECT outcome, licence_id INTO v_t, v_x FROM receipt_ceiling_checks WHERE inbound_batch_id = b;
    IF v_t IS DISTINCT FROM 'category_not_set' OR v_x IS DISTINCT FROM lic THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: a material with no NEA category should record category_not_set under the licence, got % / %', v_t, v_x; END IF;
    b := pg_temp.f251_rcv('CEIL', u_all, m_a, sup, 1000, 'kg', d);
    SELECT to_jsonb(c) INTO v_j FROM receipt_ceiling_checks c WHERE inbound_batch_id = b;
    IF v_j ->> 'outcome' IS DISTINCT FROM 'ceiling_not_set' OR (v_j ->> 'on_hand_before_t')::numeric IS DISTINCT FROM 1
       OR (v_j ->> 'quantity_t')::numeric IS DISTINCT FROM 1 OR v_j ->> 'category_code' IS DISTINCT FROM 'F251A' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: no ceiling for the category should record ceiling_not_set with 1 t before and 1 t in: %', v_j; END IF;

    -- 上限:A = 5 t(V2 那一行跟着消失)
    INSERT INTO licence_storage_limits (licence_id, category_code, limit_tonnes) VALUES (lic, 'F251A', 5) RETURNING id INTO lim_a;
    v_n := (pg_temp.f251_read('PV', u_all, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V2' AND item_code = 'F251A'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 PV: V2 still lists a category whose ceiling was given'; END IF;

    -- ══════════════ CEIL · within / 超了按名拒 —— 建单 ══════════════
    b := pg_temp.f251_rcv('CEIL', u_all, m_a, sup, 2000, 'kg', d);
    SELECT to_jsonb(c) INTO v_j FROM receipt_ceiling_checks c WHERE inbound_batch_id = b;
    IF v_j ->> 'outcome' IS DISTINCT FROM 'within' OR (v_j ->> 'on_hand_before_t')::numeric IS DISTINCT FROM 2
       OR (v_j ->> 'limit_t')::numeric IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: 2 t + 2 t under 5 t should record within: %', v_j; END IF;
    v_n := (SELECT count(*) FROM inbound_batches WHERE material_id = m_a);
    v_msg := pg_temp.f251_rcv_try(u_all, m_a, sup, 1500, 'kg', d);
    IF v_msg IS DISTINCT FROM 'STORAGE_CEILING_EXCEEDED|ZZ-F251|F251A|4.000|1.500|5' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: 4 t + 1.5 t over 5 t was not refused by name: %', v_msg; END IF;
    IF (SELECT count(*) FROM inbound_batches WHERE material_id = m_a) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: a refused receipt left a batch behind'; END IF;

    -- ══════════════ CEIL · 按单收货那一支(单位固定 kg)══════════════
    v_j := pg_temp.f251_read('CEIL', u_all, format(
        $q$SELECT receive_inbound_batch_against_po(p_material_id => %L, p_supplier_id => %L, p_quantity => 500, p_arrival_date => %L,
              p_chemistry_certainty => 'single_known', p_source_reason_code => 'other', p_source_reason_note => 'fixture 251')$q$, m_a, sup, d));
    IF v_j -> 'ceiling' ->> 'outcome' IS DISTINCT FROM 'within' OR (v_j -> 'ceiling' ->> 'on_hand_before_t')::numeric IS DISTINCT FROM 4 THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: the field receipt did not judge the ceiling (within, 4 t before): %', v_j -> 'ceiling'; END IF;
    v_msg := pg_temp.f251_try(u_all, format(
        $q$SELECT receive_inbound_batch_against_po(p_material_id => %L, p_supplier_id => %L, p_quantity => 600, p_arrival_date => %L,
              p_chemistry_certainty => 'single_known', p_source_reason_code => 'other', p_source_reason_note => 'fixture 251')$q$, m_a, sup, d));
    IF v_msg IS DISTINCT FROM 'STORAGE_CEILING_EXCEEDED|ZZ-F251|F251A|4.500|0.600|5' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: the field receipt over the ceiling was not refused by name: %', v_msg; END IF;

    -- ══════════════ CEIL · 手工建的产出批 ══════════════
    v_j := pg_temp.f251_read('CEIL', u_all, format(
        $q$SELECT create_output_batch(p_material_id => %L, p_quantity => 400, p_unit => 'kg', p_output_date => %L)$q$, m_a, d));
    o := (v_j ->> 'batch_id')::uuid;
    IF (SELECT outcome FROM receipt_ceiling_checks WHERE output_batch_id = o) IS DISTINCT FROM 'within' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: a manual output batch under the ceiling should record within: %', v_j -> 'ceiling'; END IF;
    v_msg := pg_temp.f251_try(u_all, format(
        $q$SELECT create_output_batch(p_material_id => %L, p_quantity => 200, p_unit => 'kg', p_output_date => %L)$q$, m_a, d));
    IF v_msg IS DISTINCT FROM 'STORAGE_CEILING_EXCEEDED|ZZ-F251|F251A|4.900|0.200|5' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: a manual output batch over the ceiling was not refused by name: %', v_msg; END IF;
    v_j := pg_temp.f251_read('CEIL', u_all, format(
        $q$SELECT create_output_batch(p_material_id => %L, p_quantity => 300, p_unit => 'kg', p_output_date => %L)$q$, m_b, d));
    IF (SELECT outcome FROM receipt_ceiling_checks WHERE output_batch_id = (v_j ->> 'batch_id')::uuid) IS DISTINCT FROM 'ceiling_not_set' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: a manual output batch of a category with no ceiling should record ceiling_not_set'; END IF;
    v_j := pg_temp.f251_read('CEIL', u_all, format(
        $q$SELECT create_output_batch(p_material_id => %L, p_quantity => 10, p_unit => 'kg', p_output_date => %L)$q$, m_n, d));
    IF (SELECT outcome FROM receipt_ceiling_checks WHERE output_batch_id = (v_j ->> 'batch_id')::uuid) IS DISTINCT FROM 'category_not_set' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: a manual output batch of an uncategorised material should record category_not_set'; END IF;
    -- 判法只追加
    v_msg := pg_temp.f251_try(u_all, format('UPDATE receipt_ceiling_checks SET outcome = %L WHERE output_batch_id = %L', 'within', o));
    IF v_msg IS DISTINCT FROM 'STORAGE_CEILING_CHECK_APPEND_ONLY|update' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: a ceiling record was changed: %', v_msg; END IF;
    BEGIN UPDATE receipt_ceiling_checks SET outcome = 'within' WHERE output_batch_id = o; v_msg := 'changed';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'STORAGE_CEILING_CHECK_APPEND_ONLY|update' THEN
        RAISE EXCEPTION 'FIXTURE 251 CEIL: even the owner path changed a ceiling record: %', v_msg; END IF;

    -- ══════════════ TOTAL · 执照的总上限对着所有有类别的存量(A 4.9 t + B 0.3 t = 5.2 t)══════════════
    UPDATE company_compliance SET approved_storage_limit_tonnes = 5.3 WHERE id = lic;
    v_msg := pg_temp.f251_rcv_try(u_all, m_b, sup, 200, 'kg', d);
    IF v_msg IS DISTINCT FROM 'STORAGE_CEILING_EXCEEDED|ZZ-F251|*|5.200|0.200|5.3' THEN
        RAISE EXCEPTION 'FIXTURE 251 TOTAL: the licence total was not judged (5.2 t + 0.2 t over 5.3 t): %', v_msg; END IF;
    b := pg_temp.f251_rcv('TOTAL', u_all, m_b, sup, 50, 'kg', d);
    SELECT to_jsonb(c) INTO v_j FROM receipt_ceiling_checks c WHERE inbound_batch_id = b;
    IF v_j ->> 'outcome' IS DISTINCT FROM 'ceiling_not_set' OR (v_j ->> 'total_on_hand_before_t')::numeric IS DISTINCT FROM 5.2
       OR (v_j ->> 'total_limit_t')::numeric IS DISTINCT FROM 5.3 THEN
        RAISE EXCEPTION 'FIXTURE 251 TOTAL: under the total, a category with no ceiling should record ceiling_not_set with the total: %', v_j; END IF;
    UPDATE company_compliance SET approved_storage_limit_tonnes = NULL WHERE id = lic;

    -- ══════════════ UNIT · 换算不成吨 ══════════════
    b := pg_temp.f251_rcv('UNIT', u_all, m_b, sup, 3, '件', d);
    IF (SELECT outcome FROM receipt_ceiling_checks WHERE inbound_batch_id = b) IS DISTINCT FROM 'unit_not_convertible' THEN
        RAISE EXCEPTION 'FIXTURE 251 UNIT: pieces in a category with no ceiling should record unit_not_convertible'; END IF;
    v_msg := pg_temp.f251_rcv_try(u_all, m_a, sup, 3, '件', d);
    IF v_msg NOT LIKE 'STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|IN-%|F251A' THEN
        RAISE EXCEPTION 'FIXTURE 251 UNIT: pieces in a category with a ceiling were not refused by name: %', v_msg; END IF;
    INSERT INTO licence_storage_limits (licence_id, category_code, limit_tonnes) VALUES (lic, 'F251B', 10) RETURNING id INTO lim_b;
    v_msg := pg_temp.f251_rcv_try(u_all, m_b, sup, 10, 'kg', d);
    IF v_msg NOT LIKE 'STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|IN-%|F251B' THEN
        RAISE EXCEPTION 'FIXTURE 251 UNIT: a category whose stock holds pieces cannot be shown under its ceiling — not refused: %', v_msg; END IF;
    IF quantity_in_tonnes(2500, '吨') <> 2500 OR quantity_in_tonnes(2500, 'kg') <> 2.5 OR quantity_in_tonnes(2500000, '克') <> 2.5
       OR quantity_in_tonnes(1, '件') IS NOT NULL OR quantity_in_tonnes(1, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 251 UNIT: quantity_in_tonnes does not convert kg / 吨 / 克 and refuse 件'; END IF;
    DELETE FROM licence_storage_limits WHERE id = lim_b;

    -- ══════════════ EXCEEDED · 不经收货超了:调低上限 · 加工 ══════════════
    UPDATE licence_storage_limits SET limit_tonnes = 4 WHERE id = lim_a;
    IF (SELECT status FROM storage_ceiling_status WHERE category_code = 'F251A') IS DISTINCT FROM 'exceeded' THEN
        RAISE EXCEPTION 'FIXTURE 251 EXCEEDED: a lowered ceiling did not show as exceeded'; END IF;
    v_n := (pg_temp.f251_read('EXCEEDED', u_inv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'storage_ceiling_exceeded' AND item_code = 'F251A'$q$))::int;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 251 EXCEEDED: an inventory reader sees % storage_ceiling_exceeded row(s), expected 1', v_n; END IF;
    v_n := (pg_temp.f251_read('EXCEEDED', u_none, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'storage_ceiling_exceeded'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 EXCEEDED: a reader with no code is reminded of % ceiling(s)', v_n; END IF;
    UPDATE licence_storage_limits SET limit_tonnes = 5 WHERE id = lim_a;
    IF (SELECT status FROM storage_ceiling_status WHERE category_code = 'F251A') IS DISTINCT FROM 'within' THEN
        RAISE EXCEPTION 'FIXTURE 251 EXCEEDED: back under the ceiling, the status did not return to within'; END IF;
    -- 加工:一批没有类别的料(1 t)拆成 A 类的产出(0.9 t)→ A 从 4.9 t 到 5.8 t。加工不被拒,提醒臂说出来。
    b_in := pg_temp.f251_rcv('EXCEEDED', u_all, m_n, sup, 1000, 'kg', d, NULL, ARRAY['discharged_verified']);
    PERFORM reprice_inbound_batch(b_in, 1, v_ccy, NULL, 'f251');
    run := (pg_temp.f251_read('EXCEEDED', u_all, format($q$SELECT to_jsonb(commit_processing_run(%L, 'f251 to category A', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 1000)),
            jsonb_build_array(jsonb_build_object('material_id', %L, 'weight_kg', 900)), 'weight', NULL, NULL, 'manual_disassembly', p_started_at => (%1$L)::timestamptz, p_ended_at => LEAST((%1$L)::timestamptz + interval '1 hour', now()), p_shift_code => 'day'))$q$,
            d, b_in, m_a))) #>> '{}';
    IF run IS NULL THEN RAISE EXCEPTION 'FIXTURE 251 EXCEEDED: the processing run was refused'; END IF;
    IF (SELECT status FROM storage_ceiling_status WHERE category_code = 'F251A') IS DISTINCT FROM 'exceeded'
       OR (SELECT on_hand_t FROM storage_ceiling_status WHERE category_code = 'F251A') IS DISTINCT FROM 5.8 THEN
        RAISE EXCEPTION 'FIXTURE 251 EXCEEDED: processing into category A did not show 5.8 t, exceeded (%)',
            (SELECT on_hand_t FROM storage_ceiling_status WHERE category_code = 'F251A'); END IF;

    -- ══════════════ DWELL · 时钟、没给 / 到了、提醒臂 ══════════════
    b_d1 := pg_temp.f251_rcv('DWELL', u_all, m_n, sup, 100, 'kg', d, NULL, ARRAY['water_exposed']);
    SELECT id, created_at INTO v_x, v_at FROM inbound_batch_safety_states WHERE inbound_batch_id = b_d1 AND ended_at IS NULL;
    IF (SELECT dwell_status FROM safety_state_dwell WHERE state_row_id = v_x) IS DISTINCT FROM 'not_set' THEN
        RAISE EXCEPTION 'FIXTURE 251 DWELL: a state with no dwell period should read not_set'; END IF;
    PERFORM pg_temp.f251_read('DWELL', u_all, format($q$SELECT set_inbound_safety_states(%L, ARRAY['water_exposed'])$q$, b_d1));
    PERFORM pg_temp.f251_read('DWELL', u_all, format($q$SELECT set_inbound_safety_states(%L, ARRAY['water_exposed', 'damaged_deformed'])$q$, b_d1));
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE id = v_x AND created_at = v_at AND ended_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 251 DWELL: saving the same state again restarted its clock (the row was replaced)'; END IF;
    -- 一条六天前记下的状态(以属主身份插,只为造出一个"过去")
    b_d2 := pg_temp.f251_rcv('DWELL', u_all, m_n, sup, 100, 'kg', d);
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_at, created_by)
    VALUES (b_d2, 'damaged_deformed', now() - interval '6 days', u_all) RETURNING id INTO v_y;
    UPDATE inbound_safety_states SET dwell_warning_days = 5 WHERE code = 'damaged_deformed';
    UPDATE inbound_safety_states SET dwell_warning_days = 30 WHERE code = 'water_exposed';
    SELECT to_jsonb(x) INTO v_j FROM safety_state_dwell x WHERE state_row_id = v_y;
    IF v_j ->> 'dwell_status' IS DISTINCT FROM 'past' OR (v_j ->> 'days_recorded')::int IS DISTINCT FROM 6 OR NOT (v_j ->> 'on_site')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 251 DWELL: six days against five should read past, on site: %', v_j; END IF;
    IF (SELECT dwell_status FROM safety_state_dwell WHERE state_row_id = v_x) IS DISTINCT FROM 'within' THEN
        RAISE EXCEPTION 'FIXTURE 251 DWELL: a fresh state against 30 days should read within'; END IF;
    v_n := (pg_temp.f251_read('DWELL', u_inb, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'safety_state_dwell' AND item_id = %L AND days_waiting = 6 AND doc_kind = 'inbound'$q$, b_d2)))::int;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 251 DWELL: an inbound reader sees % dwell reminder(s) for the six-day state, expected 1', v_n; END IF;
    v_n := (pg_temp.f251_read('DWELL', u_inv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'safety_state_dwell'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 DWELL: a reader without inbound view is reminded of % dwell(s)', v_n; END IF;
    v_n := (pg_temp.f251_read('DWELL', u_all, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V3' AND item_code IN ('damaged_deformed', 'water_exposed')$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 PV: V3 still lists a state whose dwell period was given'; END IF;
    -- 货不在厂里了(加工整批投掉)→ 不上提醒
    UPDATE inbound_safety_states SET dwell_warning_days = 1 WHERE code = 'discharged_verified';
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_at, created_by)
    SELECT b_in, 'water_exposed', now() - interval '40 days', u_all;
    IF EXISTS (SELECT 1 FROM safety_state_dwell WHERE batch_id = b_in AND on_site) THEN
        RAISE EXCEPTION 'FIXTURE 251 DWELL: a batch fully consumed by processing still reads on site'; END IF;
    v_n := (pg_temp.f251_read('DWELL', u_inb, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'safety_state_dwell' AND item_id = %L$q$, b_in)))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 DWELL: a batch no longer on site is still reminded (% row(s))', v_n; END IF;

    -- ══════════════ QUAR · 隔离 ══════════════
    l_norm  := (pg_temp.f251_read('QUAR', u_all, $q$SELECT to_jsonb(save_storage_location('ZZ251-L1', 'f251 rack', ARRAY[]::text[]))$q$)) #>> '{}';
    l_norm2 := (pg_temp.f251_read('QUAR', u_all, $q$SELECT to_jsonb(save_storage_location('ZZ251-L2', 'f251 rack 2', ARRAY[]::text[]))$q$)) #>> '{}';
    SELECT code INTO l_norm_code FROM storage_locations WHERE id = l_norm;
    v_msg := pg_temp.f251_rcv_try(u_all, m_n, sup, 100, 'kg', d, l_norm, ARRAY['swollen_leaking']);
    IF v_msg IS DISTINCT FROM 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|ZZ251-L1' THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: a swollen receipt into a normal location was not refused by name: %', v_msg; END IF;
    v_msg := pg_temp.f251_rcv_try(u_all, m_n, sup, 100, 'kg', d, NULL, ARRAY['swollen_leaking']);
    IF v_msg IS DISTINCT FROM 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|unspecified' THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: an unspecified location counted as quarantine: %', v_msg; END IF;
    v_n := (pg_temp.f251_read('PV', u_inv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V34'$q$))::int;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 251 PV: with no quarantine location V34 should show one row to an inventory reader, got %', v_n; END IF;
    q1 := (pg_temp.f251_read('QUAR', u_all, $q$SELECT to_jsonb(save_storage_location('ZZ251-Q1', 'f251 quarantine', ARRAY[]::text[], p_is_quarantine => true))$q$)) #>> '{}';
    q2 := (pg_temp.f251_read('QUAR', u_all, $q$SELECT to_jsonb(save_storage_location('ZZ251-Q2', 'f251 quarantine 2', ARRAY[]::text[], p_is_quarantine => true))$q$)) #>> '{}';
    v_n := (pg_temp.f251_read('PV', u_inv, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V34'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 PV: V34 did not disappear once a quarantine location exists'; END IF;
    -- 修改一个库位、不传隔离那一格 → 不改(旧页面的调用)
    PERFORM pg_temp.f251_read('QUAR', u_all, format($q$SELECT to_jsonb(save_storage_location('ZZ251-Q1', 'f251 quarantine renamed', ARRAY[]::text[], %L::uuid))$q$, q1));
    IF NOT (SELECT is_quarantine FROM storage_locations WHERE id = q1) THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: saving a location without the quarantine flag cleared it'; END IF;
    b_q := pg_temp.f251_rcv('QUAR', u_all, m_n, sup, 100, 'kg', d, q1, ARRAY['swollen_leaking']);
    b := pg_temp.f251_rcv('QUAR', u_all, m_n, sup, 100, 'kg', d, l_norm, ARRAY['damaged_deformed']);
    IF b IS NULL THEN RAISE EXCEPTION 'FIXTURE 251 QUAR: a state that does not require quarantine was refused'; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT create_stock_transfer(10, %L, %L, NULL, %L)$q$, l_norm, b_q, q1));
    IF v_msg IS DISTINCT FROM 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|ZZ251-L1' THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: a swollen batch moved out of quarantine to a normal location: %', v_msg; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT create_stock_transfer(10, %L, %L, NULL, %L)$q$, q2, b_q, q1));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 251 QUAR: a move between quarantine locations was refused: %', v_msg; END IF;
    -- 一个状态记在已经放好的货上:不拒,但被标出来;下一次移动只能进隔离
    b_p := pg_temp.f251_rcv('QUAR', u_all, m_n, sup, 100, 'kg', d, l_norm);
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT set_inbound_safety_states(%L, ARRAY['swollen_leaking'])$q$, b_p));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 251 QUAR: recording a hazard on placed stock was refused: %', v_msg; END IF;
    v_n := (pg_temp.f251_read('QUAR', u_inb, format($q$SELECT to_jsonb(count(*)) FROM quarantine_exposure WHERE batch_id = %L AND location_code = 'ZZ251-L1' AND qty = 100$q$, b_p)))::int;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 251 QUAR: the swollen batch in a normal location is not listed as exposed'; END IF;
    v_n := (pg_temp.f251_read('QUAR', u_inb, format($q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'quarantine_required' AND item_id = %L$q$, b_p)))::int;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 251 QUAR: the quarantine_required reminder shows % row(s) for the exposed batch, expected 1', v_n; END IF;
    v_n := (pg_temp.f251_read('QUAR', u_inv, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'quarantine_required'$q$))::int;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 251 QUAR: a reader without inbound view is reminded of % exposure(s)', v_n; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT create_stock_transfer(100, %L, %L, NULL, %L)$q$, l_norm2, b_p, l_norm));
    IF v_msg IS DISTINCT FROM 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|ZZ251-L2' THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: the exposed batch moved to another normal location: %', v_msg; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT create_stock_transfer(100, %L, %L, NULL, %L)$q$, q1, b_p, l_norm));
    IF v_msg IS DISTINCT FROM 'OK' THEN RAISE EXCEPTION 'FIXTURE 251 QUAR: moving the exposed batch into quarantine was refused: %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM quarantine_exposure WHERE batch_id = b_p) THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: the batch is still listed as exposed after moving into quarantine'; END IF;
    -- 产出批那一侧同一条
    v_j := pg_temp.f251_read('QUAR', u_all, format(
        $q$SELECT create_output_batch(p_material_id => %L, p_quantity => 50, p_unit => 'kg', p_output_date => %L, p_location_id => %L)$q$, m_n, d, l_norm));
    o_p := (v_j ->> 'batch_id')::uuid;
    PERFORM pg_temp.f251_read('QUAR', u_all, format($q$SELECT set_output_safety_states(%L, ARRAY['swollen_leaking'])$q$, o_p));
    IF NOT EXISTS (SELECT 1 FROM quarantine_exposure WHERE batch_id = o_p AND batch_kind = 'output') THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: a swollen output batch in a normal location is not listed as exposed'; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT create_stock_transfer(50, %L, NULL, %L, %L)$q$, l_norm2, o_p, l_norm));
    IF v_msg IS DISTINCT FROM 'QUARANTINE_LOCATION_REQUIRED|swollen_leaking|ZZ251-L2' THEN
        RAISE EXCEPTION 'FIXTURE 251 QUAR: the exposed output batch moved to another normal location: %', v_msg; END IF;

    -- ══════════════ HIST · 只加、只结束、要理由、不删、只结束一次 ══════════════
    b_h := pg_temp.f251_rcv('HIST', u_all, m_n, sup, 100, 'kg', d, NULL, ARRAY['water_exposed', 'damaged_deformed']);
    SELECT id, created_at INTO v_x, v_at FROM inbound_batch_safety_states WHERE inbound_batch_id = b_h AND safety_state_code = 'water_exposed';
    SELECT id INTO v_y FROM inbound_batch_safety_states WHERE inbound_batch_id = b_h AND safety_state_code = 'damaged_deformed';
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT set_inbound_safety_states(%L, ARRAY['water_exposed'])$q$, b_h));
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_END_REASON_REQUIRED|damaged_deformed' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: un-ticking a state without a reason was not refused by name: %', v_msg; END IF;
    IF (SELECT count(*) FROM inbound_batch_safety_states WHERE inbound_batch_id = b_h AND ended_at IS NULL) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: a refused un-tick changed the states'; END IF;
    PERFORM pg_temp.f251_read('HIST', u_all, format($q$SELECT set_inbound_safety_states(%L, ARRAY['water_exposed'], '  dried and inspected  ')$q$, b_h));
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE id = v_y AND ended_at IS NOT NULL AND ended_by = u_all
                     AND end_reason = 'dried and inspected' AND ended_by_run_id IS NULL)
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE id = v_x AND created_at = v_at AND ended_at IS NULL)
       OR (SELECT count(*) FROM inbound_batch_safety_states WHERE inbound_batch_id = b_h) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: the un-ticked state was not ended (by whom, why) while the kept one stayed exactly as it was'; END IF;
    PERFORM pg_temp.f251_read('HIST', u_all, format($q$SELECT set_inbound_safety_states(%L, ARRAY['water_exposed', 'damaged_deformed'])$q$, b_h));
    IF (SELECT count(*) FROM inbound_batch_safety_states WHERE inbound_batch_id = b_h) <> 3
       OR (SELECT count(*) FROM inbound_batch_safety_states WHERE inbound_batch_id = b_h AND ended_at IS NULL) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: re-recording an ended state did not add a new row beside the ended one'; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code) VALUES (%L, 'charged_not_discharged')$q$, b_h));
    IF v_msg IS DISTINCT FROM 'SAFETY_STATES_THROUGH_FUNCTION_ONLY|inbound_batch_safety_states|insert' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: a direct insert was not refused by name: %', v_msg; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$UPDATE inbound_batch_safety_states SET ended_at = now(), end_reason = 'x' WHERE id = %L$q$, v_x));
    IF v_msg IS DISTINCT FROM 'SAFETY_STATES_THROUGH_FUNCTION_ONLY|inbound_batch_safety_states|update' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: a direct update was not refused by name: %', v_msg; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$DELETE FROM inbound_batch_safety_states WHERE id = %L$q$, v_x));
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_NEVER_DELETED|inbound_batch_safety_states' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: a direct delete was not refused by name: %', v_msg; END IF;
    BEGIN DELETE FROM inbound_batch_safety_states WHERE id = v_x; v_msg := 'deleted';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_NEVER_DELETED|inbound_batch_safety_states' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: even the owner path deleted a state: %', v_msg; END IF;
    BEGIN UPDATE inbound_batch_safety_states SET ended_at = now(), end_reason = 'again' WHERE id = v_y; v_msg := 'ended twice';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_ALREADY_ENDED|damaged_deformed' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: an ended state was ended a second time: %', v_msg; END IF;
    -- 结束的同时偷改别的列(这里是状态本身)—— 结束只许改那四格
    BEGIN UPDATE inbound_batch_safety_states SET safety_state_code = 'swollen_leaking', ended_at = now(), end_reason = 'x' WHERE id = v_x; v_msg := 'rewritten';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_ROW_FIXED|inbound_batch_safety_states' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: an open state was rewritten into another state: %', v_msg; END IF;
    BEGIN UPDATE inbound_batch_safety_states SET ended_at = now(), end_reason = '  ' WHERE id = v_x; v_msg := 'ended without reason';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_END_REASON_REQUIRED|water_exposed' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: a state was ended with a blank reason: %', v_msg; END IF;
    -- 产出批那一侧:同一支守卫、同一条要理由
    v_msg := pg_temp.f251_try(u_all, format($q$SELECT set_output_safety_states(%L, ARRAY[]::text[])$q$, o_p));
    IF v_msg IS DISTINCT FROM 'SAFETY_STATE_END_REASON_REQUIRED|swollen_leaking' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: un-ticking an output state without a reason was not refused: %', v_msg; END IF;
    v_msg := pg_temp.f251_try(u_all, format($q$INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (%L, 'water_exposed')$q$, o_p));
    IF v_msg IS DISTINCT FROM 'SAFETY_STATES_THROUGH_FUNCTION_ONLY|output_batch_safety_states|insert' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: a direct insert on an output batch was not refused by name: %', v_msg; END IF;
    v_msg := pg_temp.f251_try(u_inb, format($q$SELECT set_output_safety_states(%L, ARRAY['swollen_leaking'])$q$, o_p));
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.output.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 251 HIST: a reader without output edit set an output state: %', v_msg; END IF;

    -- ══════════════ RUN · 一炉放电结束它解决掉的、写上它的结果;回滚撤回(Q2)══════════════
    b_r := pg_temp.f251_rcv('RUN', u_all, m_n, sup, 100, 'kg', d, NULL, ARRAY['charged_not_discharged']);
    PERFORM reprice_inbound_batch(b_r, 1, v_ccy, NULL, 'f251');
    SELECT id, created_at INTO v_x, v_at FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'charged_not_discharged';
    run := (pg_temp.f251_read('RUN', u_all, format($q$SELECT to_jsonb(commit_processing_run(%L, 'f251 discharge', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 100)), '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge', p_started_at => (%1$L)::timestamptz, p_ended_at => LEAST((%1$L)::timestamptz + interval '1 hour', now()), p_shift_code => 'day'))$q$,
            d, b_r))) #>> '{}';
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE id = v_x AND ended_by_run_id = run AND end_reason LIKE 'resolved by processing run PROC-%')
       OR NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'discharged_verified'
                        AND ended_at IS NULL AND created_by_run_id = run) THEN
        RAISE EXCEPTION 'FIXTURE 251 RUN: the discharge did not end charged (naming the run) and write discharged (owned by the run)'; END IF;
    PERFORM rollback_processing_run_internal(run, 'f251 wrong batch', u_all);
    IF EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'discharged_verified' AND ended_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 251 RUN: after the rollback the batch still reads discharged'; END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'discharged_verified'
                     AND created_by_run_id = run AND end_reason LIKE 'undone by rollback of PROC-%: f251 wrong batch') THEN
        RAISE EXCEPTION 'FIXTURE 251 RUN: the run''s discharged state was not ended by the rollback, with the reason'; END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r AND safety_state_code = 'charged_not_discharged'
                     AND ended_at IS NULL AND reopened_from_id = v_x AND created_at = v_at) THEN
        RAISE EXCEPTION 'FIXTURE 251 RUN: the rollback did not reopen charged with its original recorded time'; END IF;
    -- 批次本来就带着"已放电"那一条:这一炉不写它,回滚也不碰它
    b_r2 := pg_temp.f251_rcv('RUN', u_all, m_n, sup, 100, 'kg', d, NULL, ARRAY['charged_not_discharged', 'discharged_verified']);
    PERFORM reprice_inbound_batch(b_r2, 1, v_ccy, NULL, 'f251');
    SELECT id INTO v_y FROM inbound_batch_safety_states WHERE inbound_batch_id = b_r2 AND safety_state_code = 'discharged_verified';
    run2 := (pg_temp.f251_read('RUN', u_all, format($q$SELECT to_jsonb(commit_processing_run(%L, 'f251 discharge 2', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', %L, 'quantity_consumed', 100)), '[]'::jsonb, 'weight', NULL, NULL, 'deep_discharge', p_started_at => (%1$L)::timestamptz, p_ended_at => LEAST((%1$L)::timestamptz + interval '1 hour', now()), p_shift_code => 'day'))$q$,
            d, b_r2))) #>> '{}';
    PERFORM rollback_processing_run_internal(run2, 'f251 again', u_all);
    IF NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE id = v_y AND ended_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 251 RUN: the rollback ended a discharged state the run had not written'; END IF;

    -- ══════════════ MOVE · 库存流水的直连插入(Q3)══════════════
    -- 一对手搭的、形状完全合法的转移(出隔离、进普通库位)—— 过得了台账不变式,却绕过隔离闸;它必须在第一行就被按名拒
    v_y := gen_random_uuid();
    v_msg := pg_temp.f251_try(u_all, format($q$INSERT INTO inventory_movements (inbound_batch_id, location_id, movement_type, qty_delta, stock_status, pair_id, business_date)
                                              VALUES (%L, %L, 'transfer_out', -1, 'available', %L, %L), (%L, %L, 'transfer_in', 1, 'available', %L, %L)$q$,
                                              b_q, q1, v_y, d, b_q, l_norm, v_y, d));
    IF v_msg IS DISTINCT FROM 'MOVEMENTS_THROUGH_FUNCTION_ONLY|transfer_out' THEN
        RAISE EXCEPTION 'FIXTURE 251 MOVE: a direct movement insert was not refused by name: %', v_msg; END IF;

    -- ══════════════ TICKET · 收货单上那一行的数据源:更正毛重之后,净重与差额跟着变(裁定 2)══════════════
    t := (pg_temp.f251_read('TICKET', u_all, $q$SELECT submit_manual_capture('weighing', '{"weight_kg": 12000}'::jsonb, NULL, now() - interval '2 minutes', now() - interval '1 minute', '{"new_ticket": {"direction": "inbound", "vehicle_reg": "ZZ 251"}}'::jsonb) -> 'weighing_id'$q$)) #>> '{}';
    SELECT ticket_id INTO t FROM weighings WHERE id = t;
    SELECT id INTO w_g FROM weighings WHERE ticket_id = t AND role = 'gross';
    PERFORM pg_temp.f251_read('TICKET', u_all, format($q$SELECT submit_manual_capture('weighing', '{"weight_kg": 4000}'::jsonb, NULL, now() - interval '1 minute', now(), jsonb_build_object('ticket_id', %L::uuid))$q$, t));
    v_j := pg_temp.f251_read('TICKET', u_all, format(
        $q$SELECT create_inbound_batch(p_material_id => %L, p_supplier_id => %L, p_quantity => 8000, p_unit => 'kg', p_arrival_date => %L,
              p_source_reason_code => 'other', p_source_reason_note => 'fixture 251', p_ticket_id => %L, p_ticket_share_kg => 8000)$q$, m_n, sup, d, t));
    IF (SELECT net_kg FROM weighbridge_ticket_weights WHERE ticket_id = t) IS DISTINCT FROM 8000
       OR (SELECT difference_kg FROM weighbridge_ticket_weights WHERE ticket_id = t) IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 251 TICKET: before the correction the ticket should read net 8000, difference 0'; END IF;
    PERFORM pg_temp.f251_read('TICKET', u_all, format($q$SELECT to_jsonb(correct_weighing(%L, 11900, 'pallet left on the scale'))$q$, w_g));
    IF (SELECT net_kg FROM weighbridge_ticket_weights WHERE ticket_id = t) IS DISTINCT FROM 7900
       OR (SELECT difference_kg FROM weighbridge_ticket_weights WHERE ticket_id = t) IS DISTINCT FROM -100 THEN
        RAISE EXCEPTION 'FIXTURE 251 TICKET: after correcting the gross the receipt''s ticket line should read net 7900, difference -100 (got %, %)',
            (SELECT net_kg FROM weighbridge_ticket_weights WHERE ticket_id = t), (SELECT difference_kg FROM weighbridge_ticket_weights WHERE ticket_id = t); END IF;

    RAISE NOTICE 'FIXTURE 251 全部通过:库存上限的五种结果与超限拒绝(两支收货 + 手工产出)、总上限、换算不成吨、不经收货的超限提醒;'
                 '滞留时钟不因保存重来、没给 / 到了 / 不在厂里;隔离的收货与转移闸、记在已放好的货上被标出来、下一次只能进隔离;'
                 '状态只加只结束、要理由、不删、只结束一次;放电的回滚撤回它的状态;库存流水不许直连插;地磅单那一行跟着更正变;待补的值 V2 · V29 · V3 · V4 · V34。';
END
$$;

ROLLBACK;

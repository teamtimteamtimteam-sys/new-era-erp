-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 265 —— 一段停机说出它的原因,设备只经函数记,可靠性按运转时段的并集算
--   (MES-7a-1,2026-10-15;MES-0 Q71;MES-7a Step 0 Q3–Q7 · Q19 · Q20,Tim 照推荐裁定)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   CAUSE   原因字典:三行引导,每一类一行(failure · planned · external);代号 other 与类别 other 都被拒;被引用之后类别冻住
--           (DOWNTIME_CAUSE_CLASS_LOCKED),没被引用的照改;名字照改;只持查看码的人写不了字典,持 module.processing.edit 的加得了一种
--   REQUIRE 新记的停机必须有原因(插入时判,连属主路径也拒 —— DOWNTIME_CAUSE_REQUIRED);一行"本刀之前"的停机(原因为空)原样留着、
--           读作未分类;关上它不碰原因;更正它必须给原因;已有原因的不能改回空;停用的原因不能用
--   SOURCE  来源 manual · device:device 保留,一行都插不进(DOWNTIME_SOURCE_RESERVED);来源不改(DOWNTIME_SOURCE_FIXED);函数只写 manual
--   OPEN    open_equipment_downtime 的每一句拒绝:没有码 · 找不到 · 不是设备 · 没有开始 · 没有原因 / 不认得 / 停用 · 没有说明 · 已经开着一段 ·
--           开始在未来 · 与另一段重叠
--   CLOSE   close_equipment_downtime:找不到 · 已作废 · 已经关了 · 没有结束 · 结束早于开始 · 结束在未来
--   CORRECT correct_equipment_downtime:找不到 · 已作废 · 开着的不借更正关上 · 关了的要结束时刻 · 结束早于开始 · 原因 · 说明 ·
--           什么都没改 · 改得了原因与时刻
--   MAINT   record_equipment_maintenance:没有码 · 不是设备 · 没有日期 · 种类不认得 · 没有描述 · 谁做的没说 / 两个 · 资本化没有理由 ·
--           点名的停机找不到 / 是别的机器的 / 已作废;点名同一台机器开着的一段 → 记得上、downtime_id 落下
--   INTERVAL save_equipment_service_interval:什么都没说 · 量度 ≤ 0 · 少提前量 · 提前量不小于间隔 · 后果不认得 · 一种活一条 · 改别的机器的 ·
--           找不到;新加与改都成;量度清空时提前量一并清空
--   DIRECT  直连写一律按名拒(EQUIPMENT_THROUGH_FUNCTION_ONLY|表|动作):停机 / 保养 / 间隔的 INSERT 与 UPDATE,保养的 DELETE;
--           停机的 DELETE 仍是 DOWNTIME_NEVER_DELETED;间隔的 DELETE 策略留着(持码人删得掉 = 回到「未监控」);作废照旧只经函数
--   REL     equipment_reliability:运转小时 = 已提交未冲销的单的 [开始, 结束) 的并集(两张重叠的单只数一次,冲销的不数,没时刻的不数);
--           故障 = 未作废、failure 类、开始在区间里(计划内、外部、未分类、作废、区间之前的都不数;开着的数);MTBF = 小时 ÷ 次数;
--           MTTR = 已关上的故障的平均时长;零次故障 → no_failure、零小时 → no_hours,都不给数;没机器的单与没时刻的单各数出来;
--           区间默认 = 取得日到此刻;区间倒着 → RELIABILITY_RANGE_INVALID;只列设备类;没有查看码按名拒
--   LIST    equipment_usage 带着资产类别(/operation/equipment 只列 equipment 那一类,Q7)
--   TRAIL   字典段 dictionary_downtime_causes 在册(没有新的记录主语);一段停机的 INSERT 在变更记录里带着原因与来源;
--           原因字典进变更记录,豁免仍是 8
--
-- 自带数据(README 第 2 条);以 postgres 跑;员工的调用切成 authenticated + JWT(AGENTS.md:RLS 断言必须切角色)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f265_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句;返回 'OK' 或那一句的错误(SQLERRM)
CREATE FUNCTION pg_temp.f265_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f265_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f265_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f265_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f265_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f265_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f265_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f265_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f265_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx265-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx265-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f265_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got IS NULL OR p_got NOT LIKE p_like THEN
        RAISE EXCEPTION 'FIXTURE 265 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 一张已提交的加工单(属主路径直插;开始 / 结束为空时绕过 MES-4a 的表头触发器 —— 那就是"MES-4a 之前"的一张单,fixture 253 的先例)
CREATE FUNCTION pg_temp.f265_run(p_code text, p_machine uuid, p_d date, p_from timestamptz, p_to timestamptz, p_status text)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    IF p_from IS NULL THEN
        ALTER TABLE processing_runs DISABLE TRIGGER trg_processing_runs_header;
    END IF;
    INSERT INTO processing_runs (code, status, allocation_basis, process_date, operation_type_code, equipment_id,
                                 started_at, ended_at, shift_code, deleted_at, total_input, total_output, loss_qty)
    VALUES (p_code, p_status, 'weight', p_d, 'manual_disassembly', p_machine, p_from, p_to,
            CASE WHEN p_from IS NULL THEN NULL ELSE 'day' END,
            CASE WHEN p_status = 'reversed' THEN now() END, 10, 10, 0)
    RETURNING id INTO v;
    IF p_from IS NULL THEN
        ALTER TABLE processing_runs ENABLE TRIGGER trg_processing_runs_header;
    END IF;
    RETURN v;
END;
$f$;

DO $$
DECLARE
    u_rec uuid; u_view uuid; u_none uuid;
    v_base text;
    d date := CURRENT_DATE - 10;
    t0 timestamptz;
    m uuid; m2 uuid; m3 uuid; veh uuid;
    dt_f1 uuid; dt_f2 uuid; dt_p uuid; dt_e uuid; dt_v uuid; dt_u uuid; dt_f3 uuid; dt_pre uuid; dt_m3 uuid;
    mt uuid; iv uuid; iv2 uuid;
    v_j jsonb; v_msg text; v_n bigint; v_nomach_before int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f265_as(NULL);
    t0 := d::timestamp AT TIME ZONE 'Asia/Singapore';

    u_rec  := pg_temp.f265_user('rec',  ARRAY['module.processing.view', 'module.processing.edit']);
    u_view := pg_temp.f265_user('view', ARRAY['module.processing.view']);
    u_none := pg_temp.f265_user('none', ARRAY['module.inbound.view']);

    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('FX265-M', 'fixture 265 shredder', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO m;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('FX265-M2', 'fixture 265 press', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO m2;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('FX265-M3', 'fixture 265 idle cutter', 'equipment', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO m3;
    INSERT INTO fixed_assets (code, description, category, acquisition_date, cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base)
    VALUES ('FX265-VEH', 'fixture 265 van', 'vehicle', d - 50, 0, v_base, 1, 0, 60, 0) RETURNING id INTO veh;

    -- ══════════════ CAUSE · 字典 ══════════════
    RAISE NOTICE 'fixture 265 · CAUSE';
    IF (SELECT string_agg(code || ':' || class, ',' ORDER BY code) FROM downtime_causes)
         IS DISTINCT FROM 'breakdown:failure,external:external,planned_maintenance:planned' THEN
        RAISE EXCEPTION 'FIXTURE 265 CAUSE seed: %', (SELECT string_agg(code || ':' || class, ',' ORDER BY code) FROM downtime_causes);
    END IF;
    v_msg := pg_temp.f265_do(u_rec, $q$INSERT INTO downtime_causes (code, class, name_en, name_zh) VALUES ('other', 'failure', 'Other', '其它')$q$);
    PERFORM pg_temp.f265_expect('CAUSE other code', v_msg, '%downtime_causes_code_check%');
    v_msg := pg_temp.f265_do(u_rec, $q$INSERT INTO downtime_causes (code, class, name_en, name_zh) VALUES ('misc', 'other', 'Misc', '杂')$q$);
    PERFORM pg_temp.f265_expect('CAUSE other class', v_msg, '%downtime_causes_class_check%');
    v_msg := pg_temp.f265_do(u_view, $q$INSERT INTO downtime_causes (code, class, name_en, name_zh) VALUES ('power_cut', 'external', 'Power cut', '停电')$q$);
    PERFORM pg_temp.f265_expect('CAUSE viewer writes', v_msg, '%row-level security%');
    v_msg := pg_temp.f265_do(u_rec, $q$INSERT INTO downtime_causes (code, class, name_en, name_zh, sort_order) VALUES ('power_cut', 'external', 'Power cut', '停电', 40)$q$);
    PERFORM pg_temp.f265_expect('CAUSE editor adds', v_msg, 'OK');
    v_msg := pg_temp.f265_do(u_rec, $q$INSERT INTO downtime_causes (code, class, name_en, name_zh, is_active) VALUES ('retired_cause', 'failure', 'Retired', '停用', false)$q$);
    PERFORM pg_temp.f265_expect('CAUSE editor adds inactive', v_msg, 'OK');
    -- 没被引用的照改类别
    v_msg := pg_temp.f265_do(u_rec, $q$UPDATE downtime_causes SET class = 'planned' WHERE code = 'power_cut'$q$);
    PERFORM pg_temp.f265_expect('CAUSE uncited class change', v_msg, 'OK');
    UPDATE downtime_causes SET class = 'external' WHERE code = 'power_cut';

    -- ══════════════ REQUIRE / SOURCE · 表上的两道 ══════════════
    RAISE NOTICE 'fixture 265 · REQUIRE';
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason) VALUES (m, t0 - interval '20 days', t0 - interval '20 days' + interval '1 hour', 'no cause');
        RAISE EXCEPTION 'FIXTURE 265 REQUIRE owner insert without cause passed';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f265_expect('REQUIRE owner insert', SQLERRM, 'DOWNTIME_CAUSE_REQUIRED%');
    END;
    BEGIN
        INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason, cause_code, source)
        VALUES (m, t0 - interval '20 days', t0 - interval '20 days' + interval '1 hour', 'from a box', 'breakdown', 'device');
        RAISE EXCEPTION 'FIXTURE 265 SOURCE device insert passed';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f265_expect('SOURCE device', SQLERRM, 'DOWNTIME_SOURCE_RESERVED|device%');
    END;
    -- 停机按时间先后记(一段开着的停机上界是无穷,所以比它早的一段之后再也开不进来 —— FIX-1 的重叠判据)。
    -- 区间之前的一段故障(默认区间数它,显式区间不数)
    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 - interval '1 day' + interval '3 hours', 'breakdown', 'before range'));
    dt_pre := (v_j ->> 'downtime_id')::uuid;
    PERFORM pg_temp.f265_get(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_pre, t0 - interval '1 day' + interval '4 hours'));
    -- "本刀之前"的一行:原因为空(只能在守卫关着的时候种下 —— 线上那一行 "Test-1" 的样子)
    ALTER TABLE equipment_downtime DISABLE TRIGGER trg_equipment_downtime_cause;
    INSERT INTO equipment_downtime (equipment_id, started_at, ended_at, reason)
    VALUES (m, t0 + interval '15 hours', NULL, 'fixture 265 old unclassified') RETURNING id INTO dt_u;
    ALTER TABLE equipment_downtime ENABLE TRIGGER trg_equipment_downtime_cause;
    IF (SELECT cause_code FROM equipment_downtime WHERE id = dt_u) IS NOT NULL
       OR (SELECT source FROM equipment_downtime WHERE id = dt_u) IS DISTINCT FROM 'manual' THEN
        RAISE EXCEPTION 'FIXTURE 265 REQUIRE old row must read unclassified and manual';
    END IF;
    -- 关上它不碰原因
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_u, t0 + interval '16 hours'));
    PERFORM pg_temp.f265_expect('REQUIRE close old row', v_msg, 'OK');
    IF (SELECT cause_code FROM equipment_downtime WHERE id = dt_u) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 265 REQUIRE closing the old row classified it';
    END IF;
    -- 更正它必须给原因
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, NULL, %L)', dt_u,
                             t0 + interval '15 hours', t0 + interval '16 hours', 'fixture 265 old unclassified'));
    PERFORM pg_temp.f265_expect('REQUIRE correct old row without cause', v_msg, 'DOWNTIME_CAUSE_REQUIRED%');
    -- 来源不改
    BEGIN
        UPDATE equipment_downtime SET source = 'device' WHERE id = dt_u;
        RAISE EXCEPTION 'FIXTURE 265 SOURCE change passed';
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.f265_expect('SOURCE change', SQLERRM, 'DOWNTIME_SOURCE_FIXED|manual%');
    END;

    -- ══════════════ OPEN ══════════════
    RAISE NOTICE 'fixture 265 · OPEN';
    v_msg := pg_temp.f265_do(u_view, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 1 hour', 'breakdown', 'x'));
    PERFORM pg_temp.f265_expect('OPEN no code', v_msg, 'PERMISSION_DENIED|module.processing.edit%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', gen_random_uuid(), t0, 'breakdown', 'x'));
    PERFORM pg_temp.f265_expect('OPEN not found', v_msg, 'EQUIPMENT_NOT_FOUND|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', veh, t0, 'breakdown', 'x'));
    PERFORM pg_temp.f265_expect('OPEN not a machine', v_msg, 'EQUIPMENT_NOT_A_MACHINE|FX265-VEH%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, NULL, %L, %L)', m, 'breakdown', 'x'));
    PERFORM pg_temp.f265_expect('OPEN no start', v_msg, 'DOWNTIME_START_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, NULL, %L)', m, t0 + interval '1 day 1 hour', 'x'));
    PERFORM pg_temp.f265_expect('OPEN no cause', v_msg, 'DOWNTIME_CAUSE_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 1 hour', 'gremlins', 'x'));
    PERFORM pg_temp.f265_expect('OPEN unknown cause', v_msg, 'DOWNTIME_CAUSE_UNKNOWN|gremlins%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 1 hour', 'retired_cause', 'x'));
    PERFORM pg_temp.f265_expect('OPEN inactive cause', v_msg, 'DOWNTIME_CAUSE_INACTIVE|retired_cause%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 1 hour', 'breakdown', '  '));
    PERFORM pg_temp.f265_expect('OPEN no reason', v_msg, 'DOWNTIME_REASON_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, now() + interval '1 day', 'breakdown', 'tomorrow'));
    PERFORM pg_temp.f265_expect('OPEN future', v_msg, 'DOWNTIME_START_IN_FUTURE%');

    -- 故障 F1(1 小时)· F2(3 小时)· 计划内 · 外部 · 一段将被作废的故障 —— 都经函数开、经函数关
    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L, %L)', m, t0 + interval '1 day 1 hour', 'breakdown', 'bearing seized', 'F1'));
    dt_f1 := (v_j ->> 'downtime_id')::uuid;
    IF (SELECT cause_code || '|' || source || '|' || COALESCE(ended_at::text, 'open') FROM equipment_downtime WHERE id = dt_f1) <> 'breakdown|manual|open' THEN
        RAISE EXCEPTION 'FIXTURE 265 OPEN wrote the wrong row';
    END IF;
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 3 hours', 'breakdown', 'second'));
    PERFORM pg_temp.f265_expect('OPEN already open', v_msg, 'DOWNTIME_ALREADY_OPEN|%');

    -- ══════════════ CLOSE ══════════════
    RAISE NOTICE 'fixture 265 · CLOSE';
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, %L)', gen_random_uuid(), t0));
    PERFORM pg_temp.f265_expect('CLOSE not found', v_msg, 'DOWNTIME_NOT_FOUND|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, NULL)', dt_f1));
    PERFORM pg_temp.f265_expect('CLOSE no end', v_msg, 'DOWNTIME_END_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_f1, t0 + interval '1 day'));
    PERFORM pg_temp.f265_expect('CLOSE end before start', v_msg, 'DOWNTIME_END_BEFORE_START|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_f1, now() + interval '1 hour'));
    PERFORM pg_temp.f265_expect('CLOSE future', v_msg, 'DOWNTIME_END_IN_FUTURE%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_f1, t0 + interval '1 day 2 hours'));
    PERFORM pg_temp.f265_expect('CLOSE ok', v_msg, 'OK');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_f1, t0 + interval '1 day 2 hours'));
    PERFORM pg_temp.f265_expect('CLOSE already closed', v_msg, 'DOWNTIME_ALREADY_CLOSED|%');

    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 5 hours', 'breakdown', 'belt snapped'));
    dt_f2 := (v_j ->> 'downtime_id')::uuid;
    PERFORM pg_temp.f265_get(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_f2, t0 + interval '1 day 8 hours'));
    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 10 hours', 'planned_maintenance', 'oil change'));
    dt_p := (v_j ->> 'downtime_id')::uuid;
    PERFORM pg_temp.f265_get(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_p, t0 + interval '1 day 11 hours'));
    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 12 hours', 'power_cut', 'grid'));
    dt_e := (v_j ->> 'downtime_id')::uuid;
    PERFORM pg_temp.f265_get(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_e, t0 + interval '1 day 12 hours 30 minutes'));
    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 14 hours', 'breakdown', 'wrong machine'));
    dt_v := (v_j ->> 'downtime_id')::uuid;
    PERFORM pg_temp.f265_get(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_v, t0 + interval '1 day 15 hours'));
    v_msg := pg_temp.f265_do(u_rec, format('SELECT void_equipment_downtime(%L, %L)', dt_v, 'entered on the wrong machine'));
    PERFORM pg_temp.f265_expect('VOID ok', v_msg, 'OK');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_v, t0 + interval '1 day 15 hours'));
    PERFORM pg_temp.f265_expect('CLOSE voided', v_msg, 'DOWNTIME_VOIDED|%');
    -- 重叠:一段落在 F2 里面
    v_msg := pg_temp.f265_do(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '1 day 6 hours', 'breakdown', 'inside F2'));
    PERFORM pg_temp.f265_expect('OPEN overlap', v_msg, 'DOWNTIME_OVERLAPS|%');
    -- 被引用的原因:类别冻住;名字照改
    v_msg := pg_temp.f265_do(u_rec, $q$UPDATE downtime_causes SET class = 'failure' WHERE code = 'power_cut'$q$);
    PERFORM pg_temp.f265_expect('CAUSE cited class locked', v_msg, 'DOWNTIME_CAUSE_CLASS_LOCKED|power_cut|1%');
    v_msg := pg_temp.f265_do(u_rec, $q$UPDATE downtime_causes SET name_en = 'Grid power cut' WHERE code = 'power_cut'$q$);
    PERFORM pg_temp.f265_expect('CAUSE cited rename', v_msg, 'OK');

    -- ══════════════ CORRECT ══════════════
    RAISE NOTICE 'fixture 265 · CORRECT';
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', gen_random_uuid(), t0, t0, 'breakdown', 'x'));
    PERFORM pg_temp.f265_expect('CORRECT not found', v_msg, 'DOWNTIME_NOT_FOUND|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', dt_v, t0 + interval '1 day 14 hours', t0 + interval '1 day 15 hours', 'breakdown', 'x'));
    PERFORM pg_temp.f265_expect('CORRECT voided', v_msg, 'DOWNTIME_VOIDED|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, NULL, %L, %L)', dt_f2, t0 + interval '1 day 5 hours', 'breakdown', 'belt snapped'));
    PERFORM pg_temp.f265_expect('CORRECT closed needs end', v_msg, 'DOWNTIME_END_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', dt_f2, t0 + interval '1 day 5 hours', t0 + interval '1 day 4 hours', 'breakdown', 'belt snapped'));
    PERFORM pg_temp.f265_expect('CORRECT end before start', v_msg, 'DOWNTIME_END_BEFORE_START|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, NULL, %L)', dt_f2, t0 + interval '1 day 5 hours', t0 + interval '1 day 8 hours', 'belt snapped'));
    PERFORM pg_temp.f265_expect('CORRECT no cause', v_msg, 'DOWNTIME_CAUSE_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', dt_f2, t0 + interval '1 day 5 hours', t0 + interval '1 day 8 hours', 'breakdown', ''));
    PERFORM pg_temp.f265_expect('CORRECT no reason', v_msg, 'DOWNTIME_REASON_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', dt_f2, t0 + interval '1 day 5 hours', t0 + interval '1 day 8 hours', 'breakdown', 'belt snapped'));
    PERFORM pg_temp.f265_expect('CORRECT nothing changed', v_msg, 'DOWNTIME_NOTHING_CHANGED|%');
    -- 改原因:把那一段外部原因更正成计划内,再改回来 —— 更正改得了原因
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', dt_e, t0 + interval '1 day 12 hours', t0 + interval '1 day 12 hours 30 minutes', 'planned_maintenance', 'grid'));
    PERFORM pg_temp.f265_expect('CORRECT cause', v_msg, 'OK');
    IF (SELECT cause_code FROM equipment_downtime WHERE id = dt_e) <> 'planned_maintenance' THEN
        RAISE EXCEPTION 'FIXTURE 265 CORRECT did not change the cause';
    END IF;
    PERFORM pg_temp.f265_get(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', dt_e, t0 + interval '1 day 12 hours', t0 + interval '1 day 12 hours 30 minutes', 'power_cut', 'grid power'));
    -- 开着的一段:F3(开着,算一次故障,不进 MTTR)
    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m, t0 + interval '2 days 9 hours', 'breakdown', 'motor burnt'));
    dt_f3 := (v_j ->> 'downtime_id')::uuid;
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, %L, %L, %L)', dt_f3, t0 + interval '2 days 9 hours', t0 + interval '2 days 10 hours', 'breakdown', 'motor burnt'));
    PERFORM pg_temp.f265_expect('CORRECT cannot close', v_msg, 'DOWNTIME_CORRECT_CANNOT_CLOSE|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT correct_equipment_downtime(%L, %L, NULL, %L, %L)', dt_f3, t0 + interval '2 days 9 hours', 'breakdown', 'motor burnt out'));
    PERFORM pg_temp.f265_expect('CORRECT open row reason', v_msg, 'OK');
    IF (SELECT ended_at FROM equipment_downtime WHERE id = dt_f3) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 265 CORRECT closed an open row';
    END IF;
    -- 空转机器上的一段故障
    v_j := pg_temp.f265_get(u_rec, format('SELECT open_equipment_downtime(%L, %L, %L, %L)', m3, t0 + interval '1 day 1 hour', 'breakdown', 'idle cutter jam'));
    dt_m3 := (v_j ->> 'downtime_id')::uuid;
    PERFORM pg_temp.f265_get(u_rec, format('SELECT close_equipment_downtime(%L, %L)', dt_m3, t0 + interval '1 day 2 hours'));

    -- ══════════════ MAINT ══════════════
    RAISE NOTICE 'fixture 265 · MAINT';
    v_msg := pg_temp.f265_do(u_view, format('SELECT record_equipment_maintenance(%L, %L, %L, %L, NULL, NULL, %L)', m, d, 'repair', 'x', 'Ali'));
    PERFORM pg_temp.f265_expect('MAINT no code', v_msg, 'PERMISSION_DENIED|module.processing.edit%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(%L, %L, %L, %L, NULL, NULL, %L)', veh, d, 'repair', 'x', 'Ali'));
    PERFORM pg_temp.f265_expect('MAINT not a machine', v_msg, 'EQUIPMENT_NOT_A_MACHINE|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(%L, NULL, %L, %L, NULL, NULL, %L)', m, 'repair', 'x', 'Ali'));
    PERFORM pg_temp.f265_expect('MAINT no date', v_msg, 'MAINT_DATE_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(%L, %L, %L, %L, NULL, NULL, %L)', m, d, 'overhaul', 'x', 'Ali'));
    PERFORM pg_temp.f265_expect('MAINT kind', v_msg, 'MAINT_KIND_INVALID|overhaul%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(%L, %L, %L, %L, NULL, NULL, %L)', m, d, 'repair', ' ', 'Ali'));
    PERFORM pg_temp.f265_expect('MAINT description', v_msg, 'MAINT_DESCRIPTION_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(%L, %L, %L, %L)', m, d, 'repair', 'x'));
    PERFORM pg_temp.f265_expect('MAINT performer', v_msg, 'MAINT_PERFORMER_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(%L, %L, %L, %L, %L, %L)', m, d, 'repair', 'x', gen_random_uuid(), gen_random_uuid()));
    PERFORM pg_temp.f265_expect('MAINT two performers', v_msg, 'MAINT_PERFORMER_AMBIGUOUS%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => %L, p_description => %L, p_performed_by_name => %L, p_capitalised => true)', m, d, 'repair', 'x', 'Ali'));
    PERFORM pg_temp.f265_expect('MAINT capitalised without reason', v_msg, 'MAINT_REASON_REQUIRED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => %L, p_description => %L, p_performed_by_name => %L, p_downtime_id => %L)', m, d, 'repair', 'x', 'Ali', gen_random_uuid()));
    PERFORM pg_temp.f265_expect('MAINT downtime not found', v_msg, 'MAINTENANCE_DOWNTIME_NOT_FOUND|%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => %L, p_description => %L, p_performed_by_name => %L, p_downtime_id => %L)', m2, d, 'repair', 'x', 'Ali', dt_f1));
    PERFORM pg_temp.f265_expect('MAINT other machine', v_msg, 'MAINTENANCE_DOWNTIME_OTHER_MACHINE|%|FX265-M%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => %L, p_description => %L, p_performed_by_name => %L, p_downtime_id => %L)', m, d, 'repair', 'x', 'Ali', dt_v));
    PERFORM pg_temp.f265_expect('MAINT voided downtime', v_msg, 'MAINTENANCE_DOWNTIME_VOIDED|%');
    -- 同一台机器【开着】的一段:记得上
    v_j := pg_temp.f265_get(u_rec, format('SELECT record_equipment_maintenance(p_equipment_id => %L, p_performed_on => %L, p_kind => %L, p_description => %L, p_performed_by_name => %L, p_downtime_id => %L, p_capitalised => true, p_capitalisation_reason => %L)', m, d, 'repair', 'rewound the motor', 'Ali', dt_f3, 'extends the life'));
    mt := (v_j ->> 'maintenance_id')::uuid;
    IF (SELECT downtime_id FROM equipment_maintenance WHERE id = mt) IS DISTINCT FROM dt_f3
       OR NOT (SELECT capitalised FROM equipment_maintenance WHERE id = mt) THEN
        RAISE EXCEPTION 'FIXTURE 265 MAINT did not record the link';
    END IF;

    -- ══════════════ INTERVAL ══════════════
    RAISE NOTICE 'fixture 265 · INTERVAL';
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, NULL, NULL, NULL, NULL)', m, 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL nothing', v_msg, 'INTERVAL_NOTHING_STATED%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, NULL, NULL, 0, 0)', m, 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL zero', v_msg, 'INTERVAL_VALUE_INVALID|days%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, 500, NULL, NULL, NULL)', m, 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL lead kg', v_msg, 'INTERVAL_LEAD_REQUIRED|kg%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, NULL, NULL, 30, 30)', m, 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL lead not below', v_msg, 'INTERVAL_LEAD_NOT_BELOW|days%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, NULL, NULL, 30, 3, %L)', m, 'service', 'block'));
    PERFORM pg_temp.f265_expect('INTERVAL disposition', v_msg, 'INTERVAL_DISPOSITION_INVALID|block%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, NULL, NULL, 30, 3)', m, 'tune'));
    PERFORM pg_temp.f265_expect('INTERVAL kind', v_msg, 'INTERVAL_KIND_INVALID|tune%');
    v_j := pg_temp.f265_get(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, 500, 50, 30, 3)', m, 'service'));
    iv := (v_j ->> 'interval_id')::uuid;
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, NULL, NULL, 60, 6)', m, 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL one per kind', v_msg, 'INTERVAL_ALREADY_SET|service%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, %L, %L, NULL, NULL, 60, 6)', m2, iv, 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL other machine', v_msg, 'INTERVAL_OTHER_MACHINE|FX265-M2%');
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, %L, %L, NULL, NULL, 60, 6)', m, gen_random_uuid(), 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL not found', v_msg, 'INTERVAL_NOT_FOUND|%');
    -- 改:公斤清空(提前量一并清空,哪怕表单递了一个旧值)
    v_msg := pg_temp.f265_do(u_rec, format('SELECT save_equipment_service_interval(%L, %L, %L, NULL, 50, 60, 6)', m, iv, 'service'));
    PERFORM pg_temp.f265_expect('INTERVAL update', v_msg, 'OK');
    IF (SELECT row(interval_kg, lead_kg, interval_days, lead_days)::text FROM equipment_service_intervals WHERE id = iv) <> '(,,60,6)' THEN
        RAISE EXCEPTION 'FIXTURE 265 INTERVAL update wrote %', (SELECT row(interval_kg, lead_kg, interval_days, lead_days)::text FROM equipment_service_intervals WHERE id = iv);
    END IF;

    -- ══════════════ DIRECT · 直连写一律按名拒 ══════════════
    RAISE NOTICE 'fixture 265 · DIRECT';
    v_msg := pg_temp.f265_do(u_rec, format($q$INSERT INTO equipment_downtime (equipment_id, started_at, reason, cause_code) VALUES (%L, %L, 'direct', 'breakdown')$q$, m2, t0 + interval '3 days'));
    PERFORM pg_temp.f265_expect('DIRECT downtime insert', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_downtime|insert%');
    v_msg := pg_temp.f265_do(u_rec, format($q$UPDATE equipment_downtime SET reason = 'direct' WHERE id = %L$q$, dt_f1));
    PERFORM pg_temp.f265_expect('DIRECT downtime update', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_downtime|update%');
    v_msg := pg_temp.f265_do(u_rec, format($q$DELETE FROM equipment_downtime WHERE id = %L$q$, dt_f1));
    PERFORM pg_temp.f265_expect('DIRECT downtime delete', v_msg, 'DOWNTIME_NEVER_DELETED%');
    v_msg := pg_temp.f265_do(u_rec, format($q$UPDATE equipment_downtime SET voided_at = now(), void_reason = 'x' WHERE id = %L$q$, dt_f1));
    PERFORM pg_temp.f265_expect('DIRECT downtime void', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_downtime|update%');
    v_msg := pg_temp.f265_do(u_rec, format($q$INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description, performed_by_name) VALUES (%L, %L, 'service', 'direct', 'Ali')$q$, m, d));
    PERFORM pg_temp.f265_expect('DIRECT maintenance insert', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_maintenance|insert%');
    v_msg := pg_temp.f265_do(u_rec, format($q$UPDATE equipment_maintenance SET description = 'direct' WHERE id = %L$q$, mt));
    PERFORM pg_temp.f265_expect('DIRECT maintenance update', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_maintenance|update%');
    v_msg := pg_temp.f265_do(u_rec, format($q$DELETE FROM equipment_maintenance WHERE id = %L$q$, mt));
    PERFORM pg_temp.f265_expect('DIRECT maintenance delete', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_maintenance|delete%');
    v_msg := pg_temp.f265_do(u_rec, format($q$INSERT INTO equipment_service_intervals (equipment_id, kind, interval_days, lead_days) VALUES (%L, 'repair', 30, 3)$q$, m));
    PERFORM pg_temp.f265_expect('DIRECT interval insert', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_service_intervals|insert%');
    v_msg := pg_temp.f265_do(u_rec, format($q$UPDATE equipment_service_intervals SET lead_days = 5 WHERE id = %L$q$, iv));
    PERFORM pg_temp.f265_expect('DIRECT interval update', v_msg, 'EQUIPMENT_THROUGH_FUNCTION_ONLY|equipment_service_intervals|update%');
    -- 只持查看码的人:直连写同样按名拒(不是一次静默的零行)
    v_msg := pg_temp.f265_do(u_view, format($q$UPDATE equipment_maintenance SET description = 'direct' WHERE id = %L$q$, mt));
    PERFORM pg_temp.f265_expect('DIRECT viewer update', v_msg, 'PERMISSION_DENIED|module.processing.edit%');
    -- 间隔的 DELETE 策略留着:持码人删得掉一条 = 回到「未监控」
    v_j := pg_temp.f265_get(u_rec, format('SELECT save_equipment_service_interval(%L, NULL, %L, NULL, NULL, 30, 3)', m2, 'service'));
    iv2 := (v_j ->> 'interval_id')::uuid;
    v_msg := pg_temp.f265_do(u_rec, format($q$DELETE FROM equipment_service_intervals WHERE id = %L$q$, iv2));
    PERFORM pg_temp.f265_expect('DIRECT interval delete stays', v_msg, 'OK');
    IF EXISTS (SELECT 1 FROM equipment_service_intervals WHERE id = iv2) THEN
        RAISE EXCEPTION 'FIXTURE 265 DIRECT interval delete deleted nothing';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals')
                 AND cmd IN ('INSERT', 'UPDATE', 'ALL')) THEN
        RAISE EXCEPTION 'FIXTURE 265 DIRECT a direct write policy remains';
    END IF;

    -- ══════════════ REL · MTBF / MTTR ══════════════
    RAISE NOTICE 'fixture 265 · REL';
    SELECT count(*) INTO v_nomach_before FROM processing_runs
     WHERE equipment_id IS NULL AND status = 'committed' AND deleted_at IS NULL AND process_date BETWEEN d AND d + 5;
    -- M:R1 [08,12) 与 R2 [10,14) 重叠 → 6 小时;R3 [20,22) → 2 小时;并集 8 小时。冲销的一张 [01,05) 不数;一张没时刻的不数(单独数出来)
    PERFORM pg_temp.f265_run('FX265-R1', m, d, t0 + interval '8 hours', t0 + interval '12 hours', 'committed');
    PERFORM pg_temp.f265_run('FX265-R2', m, d, t0 + interval '10 hours', t0 + interval '14 hours', 'committed');
    PERFORM pg_temp.f265_run('FX265-R3', m, d, t0 + interval '20 hours', t0 + interval '22 hours', 'committed');
    PERFORM pg_temp.f265_run('FX265-RREV', m, d, t0 + interval '1 hour', t0 + interval '5 hours', 'reversed');
    PERFORM pg_temp.f265_run('FX265-RNOT', m, d, NULL, NULL, 'committed');
    -- 一张没记机器的单
    PERFORM pg_temp.f265_run('FX265-RNOM', NULL, d, t0 + interval '2 hours', t0 + interval '3 hours', 'committed');
    -- M2:5 小时、零次故障
    PERFORM pg_temp.f265_run('FX265-R4', m2, d, t0 + interval '1 hour', t0 + interval '6 hours', 'committed');

    v_msg := pg_temp.f265_do(u_none, format('SELECT count(*) FROM equipment_reliability(%L)', m));
    PERFORM pg_temp.f265_expect('REL no code', v_msg, 'PERMISSION_DENIED|module.processing.view%');
    v_msg := pg_temp.f265_do(u_view, format('SELECT count(*) FROM equipment_reliability(%L, %L, %L)', m, t0 + interval '5 days', t0));
    PERFORM pg_temp.f265_expect('REL range backwards', v_msg, 'RELIABILITY_RANGE_INVALID|%');

    v_j := pg_temp.f265_get(u_view, format('SELECT to_jsonb(r) FROM equipment_reliability(%L, %L, %L) r', m, t0, t0 + interval '5 days'));
    IF (v_j ->> 'operating_hours')::numeric <> 8 OR (v_j ->> 'runs_counted')::int <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 265 REL union hours %', v_j;
    END IF;
    IF (v_j ->> 'failures')::int <> 3 OR (v_j ->> 'failures_open')::int <> 1 OR (v_j ->> 'repairs_closed')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 265 REL failure count %', v_j;
    END IF;
    -- 8 小时 ÷ 3 次 = 2.67;MTTR = (1 + 3) ÷ 2 = 2.00
    IF (v_j ->> 'mtbf_hours')::numeric <> 2.67 OR (v_j ->> 'mttr_hours')::numeric <> 2.00 OR v_j ->> 'mtbf_state' <> 'value' THEN
        RAISE EXCEPTION 'FIXTURE 265 REL mtbf / mttr %', v_j;
    END IF;
    IF (v_j ->> 'planned_stops')::int <> 1 OR (v_j ->> 'external_stops')::int <> 1 OR (v_j ->> 'unclassified_stops')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 265 REL other stops %', v_j;
    END IF;
    IF (v_j ->> 'runs_without_times')::int <> 1 OR (v_j ->> 'runs_without_machine')::int <> v_nomach_before + 1 THEN
        RAISE EXCEPTION 'FIXTURE 265 REL runs without times or machine %', v_j;
    END IF;
    -- 默认区间 = 取得日到此刻:区间之前那一段故障这一次数进来
    v_j := pg_temp.f265_get(u_view, format('SELECT to_jsonb(r) FROM equipment_reliability(%L) r', m));
    IF (v_j ->> 'failures')::int <> 4
       OR (v_j ->> 'range_from')::timestamptz <> ((d - 50)::timestamp AT TIME ZONE 'Asia/Singapore') THEN
        RAISE EXCEPTION 'FIXTURE 265 REL default range %', v_j;
    END IF;
    -- 零次故障 · 零运转小时:都不给数
    v_j := pg_temp.f265_get(u_view, format('SELECT to_jsonb(r) FROM equipment_reliability(%L, %L, %L) r', m2, t0, t0 + interval '5 days'));
    IF v_j ->> 'mtbf_state' <> 'no_failure' OR v_j ->> 'mtbf_hours' IS NOT NULL OR (v_j ->> 'operating_hours')::numeric <> 5
       OR v_j ->> 'mttr_hours' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 265 REL zero failures %', v_j;
    END IF;
    v_j := pg_temp.f265_get(u_view, format('SELECT to_jsonb(r) FROM equipment_reliability(%L, %L, %L) r', m3, t0, t0 + interval '5 days'));
    IF v_j ->> 'mtbf_state' <> 'no_hours' OR v_j ->> 'mtbf_hours' IS NOT NULL OR (v_j ->> 'operating_hours')::numeric <> 0
       OR (v_j ->> 'failures')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 265 REL zero hours %', v_j;
    END IF;
    -- 只列设备类
    v_j := pg_temp.f265_get(u_view, format($q$SELECT jsonb_agg(x.equipment_code ORDER BY x.equipment_code) FROM equipment_reliability(NULL, %L, %L) x
                                              WHERE x.equipment_code LIKE 'FX265-%%'$q$, t0, t0 + interval '5 days'));
    IF v_j IS DISTINCT FROM '["FX265-M", "FX265-M2", "FX265-M3"]'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 265 REL must list exactly the three machines, not the van (got %)', v_j;
    END IF;

    -- ══════════════ LIST ══════════════
    RAISE NOTICE 'fixture 265 · LIST';
    -- 以加工的读者读(equipment_usage 是属主权限视图,门在体里 —— postgres 没有 JWT,读到的是零行)
    v_j := pg_temp.f265_get(u_view, format($q$SELECT jsonb_object_agg(equipment_code, equipment_category) FROM equipment_usage
                                              WHERE equipment_id IN (%L, %L)$q$, veh, m));
    IF v_j IS DISTINCT FROM '{"FX265-M": "equipment", "FX265-VEH": "vehicle"}'::jsonb THEN
        RAISE EXCEPTION 'FIXTURE 265 LIST equipment_usage must carry the asset category';
    END IF;

    -- ══════════════ TRAIL ══════════════
    RAISE NOTICE 'fixture 265 · TRAIL';
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'dictionary_downtime_causes' AND s.root_table = 'downtime_causes') THEN
        RAISE EXCEPTION 'FIXTURE 265 TRAIL dictionary block missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'equipment_downtime' AND c.op = 'INSERT'
                     AND c.new ->> 'id' = dt_f1::text AND c.new ->> 'cause_code' = 'breakdown' AND c.new ->> 'source' = 'manual') THEN
        RAISE EXCEPTION 'FIXTURE 265 TRAIL the downtime insert must carry its cause and source in the change log';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'downtime_causes' AND c.op = 'INSERT' AND c.new ->> 'code' = 'power_cut') THEN
        RAISE EXCEPTION 'FIXTURE 265 TRAIL downtime_causes must be change-logged';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 265 TRAIL change-log coverage %', v_j;
    END IF;

    RAISE NOTICE 'FIXTURE 265 全部通过: CAUSE · REQUIRE · SOURCE · OPEN · CLOSE · CORRECT · MAINT · INTERVAL · DIRECT · REL · LIST · TRAIL';
END $$;

ROLLBACK;

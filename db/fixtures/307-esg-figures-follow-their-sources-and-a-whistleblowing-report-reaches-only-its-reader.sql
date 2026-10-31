-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 307 —— ESG-2:Scope 2 按年份的电网因子与按天摊的月份、误工事故频率按考勤折出的工时、培训的覆盖与到期、制度的版本,
--   以及一件举报只到它的那一位读者(Tim 2026-10-31 Q1–Q15)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   P   三个新码在目录里;引导的 cco 持 action.manage_esg + data.view_whistleblowing,cfo 持 action.manage_esg + data.view_whistleblowing_escalated,
--       admin 持 action.manage_esg 而【不持】两个举报码(Q9 · Q13 的例外);别的角色一个都不持
--   F   电网因子:不持码的人设不了;第一次不要理由;同一年再设没理由 / 值与出处都一样各自按名拒,带理由是新版本、最后一个说了算;
--       某一年没有就用更早最近的一年;比所有年份都早 → 零行;写下的一行改不了、删不掉
--   S   Scope 2:每张单 = kWh × 那一年(账期结束那天的年份)的因子 ÷ 1000;没设因子 → 空;冲回的单不算;月份按天摊、各月之和 = 各单之和;
--       一个月里有一张没设因子 → 那个月为空;不持财务 / 加工查看码的人按名拒(不是零行)
--   H   工时:标准日工时不持码设不了、不合理按名拒;一个月:没有考勤期 → no_period · 有一行没记 → incomplete(n / m)· 没设标准日工时 → hours_not_set ·
--       都齐 → (在职工作日 − 批准的请假天数)× 标准日工时 + 加班;年初至今只有每个月都齐才有工时与率
--   L   误工事故:种类 injury、受伤的是员工、误工天数 > 0;非员工另数;误工 0 天不算;更正过的误工天数说了算;LTIFR = 事故 × 1,000,000 ÷ 工时;
--       不持 data.view_health 的人工时照读、事故 / 天数 / 率为空;不持 module.safety.view 按名拒
--   C   误工天数的更正:不持 module.safety.edit 不行;理由空 / 与现在相同 / 负数 / 没有受伤的人 / 已关闭各自按名拒;incident_rows 对持健康码的人
--       与受伤的员工本人给更正后的值、对别人为空;更正表只给这两种人读;改不了、删不掉
--   T   必修培训:不持码不能建;点名岗位却没选岗位按名拒;同名按名拒;覆盖:有效 / 快到期(90 天内)/ 已过期 / 没有;记录没写到期日时按有效期算;
--       停用之后从覆盖里拿掉;不持 module.hr.view 按名拒
--   D   制度:不持码登记不了;新版本取代旧版本(旧的记 superseded_at)、被取代过的不能再被取代、版本号相同按名拒、复审早于生效按名拒;
--       复审逾期只标现在那一版;有员工档案的人读得到、没有员工档案又不持码的人读不到;改不了、删不掉
--   W   举报(两条路,Q13):员工交一件【没标】涉及 CCO 的 → 只有 cco 读得到(cfo · admin 读不到);交一件【标了】的 → 只有 cfo 读得到(cco · admin 读不到);
--       没有员工档案的会话交不了;关切必须答;外来的:cco 能登记没标的(匿名来源)、登记不了标了的,cfo 能登记标了的;追加状态:读不到的人得到「找不到」、
--       结案之后不再收;交的人经 my_concerns 读到状态、读不到说明;基表的读策略与视图同一个答案;改不了、删不掉;两张表不进变更记录
-- 自带数据(README 第 2 条):员工、岗位、考勤、请假、事故、电费单都在本支里建,整支回滚。
-- 注入(记录在 docs/surveys/ESG-2/readings/fixture-307-injections.txt):
--   ① whistleblowing_report_readable 不看 concerns_cco(一律问 data.view_whistleblowing)→ W 臂红(cco 读到标了涉及 CCO 的那一件);
--   ② whistleblowing_report_readable 对没标的也问 data.view_whistleblowing_escalated → W 臂红(cfo 读到没标的那一件、cco 读不到)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f307_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
        CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以 p_user 调一句(属主权限函数或 SELECT),回第一列的字或 'ERR|<错>'
CREATE FUNCTION pg_temp.f307_call(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f307_as(p_user);
    BEGIN EXECUTE p_sql INTO v; EXCEPTION WHEN OTHERS THEN v := 'ERR|' || SQLERRM; END;
    PERFORM pg_temp.f307_as(NULL);
    RETURN COALESCE(v, '<null>');
END;
$f$;

-- 以 p_user、切成 authenticated 跑一句:SELECT 回第一列(数),别的回影响行数;被拒回 -1
CREATE FUNCTION pg_temp.f307_rc(p_user uuid, p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.f307_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        IF p_sql ~* '^\s*select' THEN EXECUTE p_sql INTO v;
        ELSE EXECUTE p_sql; GET DIAGNOSTICS v = ROW_COUNT; END IF;
    EXCEPTION WHEN OTHERS THEN v := -1; END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f307_as(NULL);
    RETURN v;
END;
$f$;

CREATE FUNCTION pg_temp.f307_role(p_code text, p_codes text[]) RETURNS uuid
LANGUAGE sql AS $f$
    WITH r AS (INSERT INTO roles (code, name_en, name_zh, is_active) VALUES (p_code, 'f', 'f', true) RETURNING id),
         g AS (INSERT INTO role_permissions (role_id, permission_code) SELECT r.id, c FROM r, unnest(p_codes) c RETURNING role_id)
    SELECT id FROM r
$f$;

CREATE FUNCTION pg_temp.f307_expect_err(p_got text, p_code text, p_what text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got NOT LIKE 'ERR|%' || p_code || '%' THEN
        RAISE EXCEPTION 'FIXTURE 307 %: expected %, got %', p_what, p_code, p_got;
    END IF;
END;
$f$;

CREATE FUNCTION pg_temp.f307_expect_ok(p_got text, p_what text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got LIKE 'ERR|%' THEN
        RAISE EXCEPTION 'FIXTURE 307 %: expected success, got %', p_what, p_got;
    END IF;
END;
$f$;

DO $f307$
DECLARE
    u_all    uuid := gen_random_uuid();   -- 目录里每一个码(电费单过账要 module.finance.edit;也持 action.manage_esg)
    u_none   uuid := gen_random_uuid();   -- 员工、一个码都没有(交举报的人;读制度)
    u_fin    uuid := gen_random_uuid();   -- 只持 module.finance.view
    u_safe   uuid := gen_random_uuid();   -- 只持 module.safety.view
    u_health uuid := gen_random_uuid();   -- module.safety.view + data.view_health
    u_sedit  uuid := gen_random_uuid();   -- module.safety.view + module.safety.edit(不持健康码)
    u_hr     uuid := gen_random_uuid();   -- 只持 module.hr.view
    u_cco    uuid := gen_random_uuid();   -- 引导的 cco 角色
    u_cfo    uuid := gen_random_uuid();   -- 引导的 cfo 角色
    u_admin  uuid := gen_random_uuid();   -- 引导的 admin 角色
    u_inj    uuid := gen_random_uuid();   -- 受伤的那名员工(一个码都没有)
    u_portal uuid := gen_random_uuid();   -- 没有员工档案、一个码都没有
    e_none uuid; e_inj uuid; e_off uuid; e_shop uuid; e_cco uuid;
    v_pos uuid; v_pos2 uuid;
    v_base text; v_sup uuid;
    v_msg text; v_j jsonb; v_n bigint; v_num numeric; v_txt text;
    a_jan uuid; a_old uuid; a_rev uuid;
    i_emp uuid; i_non uuid; i_zero uuid; i_closed uuid; i_nm uuid;
    rt_all uuid; rt_pos uuid; rt_val uuid;
    pol1 uuid; pol2 uuid; pol3 uuid;
    w_plain uuid; w_cco uuid; w_out uuid;
    v_exp_hours numeric; v_wd numeric; v_leave numeric;
    v_year integer := EXTRACT(year FROM (now() AT TIME ZONE 'Asia/Singapore'))::integer - 1;   -- 去年:12 个月都在过去
    v_y2   integer := EXTRACT(year FROM (now() AT TIME ZONE 'Asia/Singapore'))::integer - 2;   -- 前年:12 个月都建考勤期(年初至今齐)
    v_today date := (now() AT TIME ZONE 'Asia/Singapore')::date;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    SELECT code INTO v_base FROM currencies WHERE is_base;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at)
    SELECT u, 'fx307-' || n || '@test.local', now(), now()
      FROM unnest(ARRAY[u_all, u_none, u_fin, u_safe, u_health, u_sedit, u_hr, u_cco, u_cfo, u_admin, u_inj, u_portal],
                  ARRAY['all', 'none', 'fin', 'safe', 'health', 'sedit', 'hr', 'cco', 'cfo', 'admin', 'inj', 'portal']) AS t(u, n);
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all, pg_temp.f307_role('fx307-all', (SELECT array_agg(code) FROM permissions))),
        (u_fin, pg_temp.f307_role('fx307-fin', ARRAY['module.finance.view'])),
        (u_safe, pg_temp.f307_role('fx307-safe', ARRAY['module.safety.view'])),
        (u_health, pg_temp.f307_role('fx307-health', ARRAY['module.safety.view', 'data.view_health'])),
        (u_sedit, pg_temp.f307_role('fx307-sedit', ARRAY['module.safety.view', 'module.safety.edit'])),
        (u_hr, pg_temp.f307_role('fx307-hr', ARRAY['module.hr.view'])),
        (u_cco, (SELECT id FROM roles WHERE code = 'cco')),
        (u_cfo, (SELECT id FROM roles WHERE code = 'cfo')),
        (u_admin, (SELECT id FROM roles WHERE code = 'admin'));

    INSERT INTO positions (code, title) VALUES ('ZZ-F307-P1', 'fixture 307 operator') RETURNING id INTO v_pos;
    INSERT INTO positions (code, title) VALUES ('ZZ-F307-P2', 'fixture 307 clerk') RETURNING id INTO v_pos2;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id, position_id)
    VALUES ('ZZ-F307-N', 'fixture 307 filer', 'full_time', 'office', make_date(v_y2, 1, 1), u_none, v_pos2) RETURNING id INTO e_none;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id, position_id)
    VALUES ('ZZ-F307-I', 'fixture 307 injured', 'full_time', 'shopfloor', make_date(v_y2, 1, 1), u_inj, v_pos) RETURNING id INTO e_inj;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, position_id)
    VALUES ('ZZ-F307-O', 'fixture 307 office', 'full_time', 'office', make_date(v_y2, 1, 1), v_pos2) RETURNING id INTO e_off;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, position_id)
    VALUES ('ZZ-F307-S', 'fixture 307 shopfloor', 'full_time', 'shopfloor', make_date(v_year, 3, 17), v_pos) RETURNING id INTO e_shop;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES ('ZZ-F307-C', 'fixture 307 cco', 'full_time', 'office', make_date(v_y2, 1, 1), u_cco) RETURNING id INTO e_cco;

    -- ══════════════ P · 三个新码与引导的授予 ══════════════
    IF (SELECT count(*) FROM permissions WHERE code IN ('action.manage_esg', 'data.view_whistleblowing', 'data.view_whistleblowing_escalated')) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 307 P: the three new codes are not all in the catalogue';
    END IF;
    IF (SELECT string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code)
          FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code IN ('action.manage_esg', 'data.view_whistleblowing', 'data.view_whistleblowing_escalated')
           AND r.code NOT LIKE 'fx307-%')
       IS DISTINCT FROM 'admin:action.manage_esg,cco:action.manage_esg,cco:data.view_whistleblowing,cfo:action.manage_esg,cfo:data.view_whistleblowing_escalated' THEN
        RAISE EXCEPTION 'FIXTURE 307 P: bootstrap grants of the new codes are %',
            (SELECT string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code)
               FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
              WHERE rp.permission_code IN ('action.manage_esg', 'data.view_whistleblowing', 'data.view_whistleblowing_escalated') AND r.code NOT LIKE 'fx307-%');
    END IF;

    -- ══════════════ F · 电网因子 ══════════════
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_fin, format('SELECT esg_set_grid_factor(%s, 0.402, %L)', v_year - 1, 'EMA SES')), 'PERMISSION_DENIED', 'F no code');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, format('SELECT esg_set_grid_factor(%s, 0, %L)', v_year - 1, 'EMA SES')), 'ESG_GRID_FACTOR_VALUE_INVALID', 'F zero');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, format('SELECT esg_set_grid_factor(%s, 0.4, %L)', v_year - 1, '  ')), 'ESG_GRID_FACTOR_SOURCE_REQUIRED', 'F source');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, 'SELECT esg_set_grid_factor(1999, 0.4, ''x'')'), 'ESG_GRID_FACTOR_YEAR_INVALID', 'F year');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_cfo, format('SELECT esg_set_grid_factor(%s, 0.5, %L)', v_year - 1, 'EMA SES 2024 Table 2.4')), 'F first version (cfo)');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, format('SELECT esg_set_grid_factor(%s, 0.4, %L)', v_year - 1, 'EMA SES 2025 Table 2.4')), 'ESG_GRID_FACTOR_REASON_REQUIRED', 'F correction without reason');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, format('SELECT esg_set_grid_factor(%s, 0.5, %L, %L)', v_year - 1, 'EMA SES 2024 Table 2.4', 'again')), 'ESG_GRID_FACTOR_NO_CHANGE', 'F unchanged');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_cco, format('SELECT esg_set_grid_factor(%s, 0.4, %L, %L)', v_year - 1, 'EMA SES 2025 Table 2.4', 'EMA revised the figure')), 'F correction (cco)');
    IF (SELECT count(*) FROM grid_emission_factors WHERE factor_year = v_year - 1) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 307 F: a correction must add a version, not replace one';
    END IF;
    IF (SELECT factor_year || ':' || kg_co2_per_kwh FROM grid_emission_factor_for(v_year + 1)) IS DISTINCT FROM (v_year - 1) || ':0.4' THEN
        RAISE EXCEPTION 'FIXTURE 307 F: a year without a factor must use the latest earlier year''s latest version, got %',
            (SELECT factor_year || ':' || kg_co2_per_kwh FROM grid_emission_factor_for(v_year + 1));
    END IF;
    IF EXISTS (SELECT 1 FROM grid_emission_factor_for(v_year - 2)) THEN
        RAISE EXCEPTION 'FIXTURE 307 F: a year before every factor must have none';
    END IF;
    BEGIN
        UPDATE grid_emission_factors SET kg_co2_per_kwh = 9 WHERE factor_year = v_year - 1;
        RAISE EXCEPTION 'FIXTURE 307 F: a factor row was updated';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%ESG_GRID_FACTOR_IMMUTABLE%' THEN RAISE; END IF;
    END;
    IF pg_temp.f307_rc(u_portal, 'SELECT count(*) FROM grid_emission_factors') <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 307 F: every signed-in user reads the factors';
    END IF;

    -- ══════════════ S · Scope 2 ══════════════
    PERFORM pg_temp.f307_as(NULL);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F307-SUP', 'fixture 307 utility', 'SG', 'active', 'service_vendor') RETURNING id INTO v_sup;
    -- 一张跨两个月的单(去年 1 月 15 日 – 2 月 14 日,31 天,3,100 kWh):用前年的因子(去年没有)
    v_msg := pg_temp.f307_call(u_all, format('SELECT post_electricity_allocation(%L, %L, %L, ''ZZ-F307-1'', 500, 3100, %L, ''unpaid'', NULL, %L)',
                                             make_date(v_year, 1, 15), make_date(v_year, 2, 14), make_date(v_year, 2, 20), v_base, v_sup));
    PERFORM pg_temp.f307_expect_ok(v_msg, 'S post bill 1');
    a_jan := (v_msg::jsonb ->> 'allocation_id')::uuid;
    -- 一张比所有因子都早的单(三年前 6 月,整月)
    v_msg := pg_temp.f307_call(u_all, format('SELECT post_electricity_allocation(%L, %L, %L, ''ZZ-F307-2'', 100, 1000, %L, ''unpaid'', NULL, %L)',
                                             make_date(v_year - 2, 6, 1), make_date(v_year - 2, 6, 30), make_date(v_year - 2, 7, 5), v_base, v_sup));
    PERFORM pg_temp.f307_expect_ok(v_msg, 'S post bill 2');
    a_old := (v_msg::jsonb ->> 'allocation_id')::uuid;
    -- 一张冲回的单(去年 3 月)
    v_msg := pg_temp.f307_call(u_all, format('SELECT post_electricity_allocation(%L, %L, %L, ''ZZ-F307-3'', 100, 900, %L, ''unpaid'', NULL, %L)',
                                             make_date(v_year, 3, 1), make_date(v_year, 3, 31), make_date(v_year, 4, 2), v_base, v_sup));
    PERFORM pg_temp.f307_expect_ok(v_msg, 'S post bill 3');
    a_rev := (v_msg::jsonb ->> 'allocation_id')::uuid;
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_all, format('SELECT reverse_electricity_allocation(%L, %L)', a_rev, 'fixture 307: wrong bill')), 'S reverse bill 3');

    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_safe, 'SELECT count(*) FROM esg_scope2_bills()'), 'PERMISSION_DENIED', 'S bills without the energy codes');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_safe, format('SELECT count(*) FROM esg_scope2_monthly(%s)', v_year)), 'PERMISSION_DENIED', 'S monthly without the energy codes');
    v_txt := pg_temp.f307_call(u_fin, format($q$SELECT string_agg(invoice_ref || '=' || bill_year || '/' || COALESCE(factor_year::text, '-') || '/' || COALESCE(tco2::text, '-'), ',' ORDER BY invoice_ref)
                                              FROM esg_scope2_bills() WHERE invoice_ref LIKE 'ZZ-F307-%%'$q$));
    IF v_txt IS DISTINCT FROM format('ZZ-F307-1=%s/%s/1.240000,ZZ-F307-2=%s/-/-', v_year, v_year - 1, v_year - 2) THEN
        RAISE EXCEPTION 'FIXTURE 307 S: per-bill Scope 2 is %', v_txt;
    END IF;
    -- 1 月 17 天 / 31、2 月 14 天 / 31:1,700 kWh · 0.68 t 与 1,400 kWh · 0.56 t
    v_txt := pg_temp.f307_call(u_fin, format($q$SELECT string_agg(to_char(month, 'MM') || '=' || kwh || '/' || COALESCE(tco2::text, '-') || '/' || bills, ',' ORDER BY month)
                                              FROM esg_scope2_monthly(%s) WHERE month < make_date(%s, 4, 1)$q$, v_year, v_year));
    IF v_txt IS DISTINCT FROM '01=1700.000/0.680000/1,02=1400.000/0.560000/1,03=0/0/0' THEN
        RAISE EXCEPTION 'FIXTURE 307 S: monthly apportionment is %', v_txt;
    END IF;
    v_txt := pg_temp.f307_call(u_fin, format($q$SELECT kwh || '/' || COALESCE(tco2::text, '-') || '/' || factor_missing FROM esg_scope2_monthly(%s) WHERE month = make_date(%s, 6, 1)$q$, v_year - 2, v_year - 2));
    IF v_txt IS DISTINCT FROM '1000.000/-/true' THEN
        RAISE EXCEPTION 'FIXTURE 307 S: a month whose bill has no factor must read factor-not-set, got %', v_txt;
    END IF;

    -- ══════════════ H · 工时 ══════════════
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_health, 'SELECT esg_set_standard_hours(8)'), 'PERMISSION_DENIED', 'H no code');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, 'SELECT esg_set_standard_hours(25)'), 'ESG_STANDARD_HOURS_INVALID', 'H 25 hours');
    -- 去年:只有 3 月与 4 月有考勤期;3 月三行都记了,4 月一行没记
    PERFORM pg_temp.f307_as(NULL);
    INSERT INTO attendance_periods (code, period_month) VALUES ('ZZ-F307-' || v_year || '-03', make_date(v_year, 3, 1)), ('ZZ-F307-' || v_year || '-04', make_date(v_year, 4, 1));
    INSERT INTO attendance_lines (period_id, employee_id, ot_normal_hours, ot_rest_day_hours, ot_public_holiday_hours, recorded_at, recorded_by)
    SELECT p.id, e, CASE WHEN e = e_inj THEN 6 ELSE 0 END, CASE WHEN e = e_inj THEN 2 ELSE 0 END, 0, now(), u_all
      FROM attendance_periods p CROSS JOIN unnest(ARRAY[e_inj, e_off, e_shop]) e WHERE p.period_month = make_date(v_year, 3, 1);
    INSERT INTO attendance_lines (period_id, employee_id, recorded_at, recorded_by)
    SELECT p.id, e, CASE WHEN e = e_off THEN NULL ELSE now() END, CASE WHEN e = e_off THEN NULL ELSE u_all END
      FROM attendance_periods p CROSS JOIN unnest(ARRAY[e_inj, e_off, e_shop]) e WHERE p.period_month = make_date(v_year, 4, 1);
    -- e_off 在 3 月请了两个整天(年假,批准);e_shop 3 月 17 日入职
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days, status)
    VALUES ('ZZ-F307-L1', e_off, (SELECT code FROM leave_types ORDER BY code LIMIT 1), make_date(v_year, 3, 10), make_date(v_year, 3, 11),
            calculate_leave_days(make_date(v_year, 3, 10), make_date(v_year, 3, 11)), 'approved');

    v_txt := pg_temp.f307_call(u_safe, format($q$SELECT hours_state || '/' || lines_recorded || '/' || lines_total FROM esg_safety_rates(%s) WHERE month = make_date(%s, 3, 1)$q$, v_year, v_year));
    IF v_txt IS DISTINCT FROM 'hours_not_set/3/3' THEN
        RAISE EXCEPTION 'FIXTURE 307 H: with no standard hours a complete month must read hours_not_set, got %', v_txt;
    END IF;
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_admin, 'SELECT esg_set_standard_hours(8)'), 'H set 8 (admin)');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, 'SELECT esg_set_standard_hours(8)'), 'ESG_STANDARD_HOURS_NO_CHANGE', 'H unchanged');
    v_wd := calculate_leave_days(make_date(v_year, 3, 1), make_date(v_year, 3, 31));
    v_leave := calculate_leave_days(make_date(v_year, 3, 10), make_date(v_year, 3, 11));
    v_exp_hours := v_wd * 8 + 8                                              -- e_inj:整月 + 8 小时加班
                 + (v_wd - v_leave) * 8                                       -- e_off:扣两天请假
                 + calculate_leave_days(make_date(v_year, 3, 17), make_date(v_year, 3, 31)) * 8;   -- e_shop:17 日起
    v_txt := pg_temp.f307_call(u_safe, format($q$SELECT hours_state || '/' || hours_worked || '/' || injury_visible || '/' || COALESCE(lti::text, '-')
                                               FROM esg_safety_rates(%s) WHERE month = make_date(%s, 3, 1)$q$, v_year, v_year));
    IF v_txt IS DISTINCT FROM 'complete/' || round(v_exp_hours, 2) || '/false/-' THEN
        RAISE EXCEPTION 'FIXTURE 307 H: March should be complete with % hours and no injury figures for a reader without health, got %', round(v_exp_hours, 2), v_txt;
    END IF;
    v_txt := pg_temp.f307_call(u_safe, format($q$SELECT string_agg(to_char(month, 'MM') || '=' || hours_state || '/' || lines_recorded || '/' || lines_total, ',' ORDER BY month)
                                               FROM esg_safety_rates(%s) WHERE month IN (make_date(%s, 2, 1), make_date(%s, 4, 1))$q$, v_year, v_year, v_year));
    IF v_txt IS DISTINCT FROM '02=no_period/0/0,04=incomplete/2/3' THEN
        RAISE EXCEPTION 'FIXTURE 307 H: February / April states are %', v_txt;
    END IF;
    v_txt := pg_temp.f307_call(u_health, format($q$SELECT hours_state || '/' || COALESCE(hours_worked::text, '-') || '/' || COALESCE(ltifr::text, '-') FROM esg_safety_rates(%s) WHERE month IS NULL$q$, v_year));
    IF v_txt IS DISTINCT FROM 'incomplete/-/-' THEN
        RAISE EXCEPTION 'FIXTURE 307 H: year to date with incomplete months must carry no hours and no rate, got %', v_txt;
    END IF;
    IF pg_temp.f307_call(u_safe, format('SELECT count(*) FROM esg_safety_rates(%s)', v_year + 3)) <> '0' THEN
        RAISE EXCEPTION 'FIXTURE 307 H: a future year has no months';
    END IF;
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_fin, format('SELECT count(*) FROM esg_safety_rates(%s)', v_year)), 'PERMISSION_DENIED', 'H without module.safety.view');

    -- ══════════════ L · 误工事故与率 ══════════════
    PERFORM pg_temp.f307_as(NULL);
    INSERT INTO incidents (code, kind_code, occurred_at, what_happened, immediate_action, responsible_name, nea_reportable, injured_employee_id, injury_nature, days_lost)
    VALUES ('ZZ-F307-I1', 'injury', make_date(v_year, 3, 12) + time '10:00', 'cut hand', 'first aid', 'supervisor', false, e_inj, 'cut', 3) RETURNING id INTO i_emp;
    INSERT INTO incidents (code, kind_code, occurred_at, what_happened, immediate_action, responsible_name, nea_reportable, injured_person_name, injury_nature, days_lost)
    VALUES ('ZZ-F307-I2', 'injury', make_date(v_year, 3, 13) + time '10:00', 'visitor slipped', 'first aid', 'supervisor', false, 'a visitor', 'sprain', 2) RETURNING id INTO i_non;
    INSERT INTO incidents (code, kind_code, occurred_at, what_happened, immediate_action, responsible_name, nea_reportable, injured_employee_id, injury_nature, days_lost)
    VALUES ('ZZ-F307-I3', 'injury', make_date(v_year, 3, 14) + time '10:00', 'bruise', 'ice', 'supervisor', false, e_off, 'bruise', 0) RETURNING id INTO i_zero;
    INSERT INTO incidents (code, kind_code, occurred_at, what_happened, immediate_action, responsible_name, nea_reportable, injured_employee_id, injury_nature, days_lost)
    VALUES ('ZZ-F307-I4', 'injury', make_date(v_year, 4, 2) + time '10:00', 'strain', 'rest', 'supervisor', false, e_shop, 'strain', 1) RETURNING id INTO i_closed;
    INSERT INTO incident_updates (incident_id, kind, summary, recorded_by) VALUES (i_closed, 'closed', 'done', u_all);

    v_txt := pg_temp.f307_call(u_health, format($q$SELECT lti || '/' || days_lost || '/' || nonemployee_injuries || '/' || ltifr FROM esg_safety_rates(%s) WHERE month = make_date(%s, 3, 1)$q$, v_year, v_year));
    IF v_txt IS DISTINCT FROM '1/3/1/' || round(1 * 1000000 / v_exp_hours, 2) THEN
        RAISE EXCEPTION 'FIXTURE 307 L: March for a health reader should be 1 LTI, 3 days, 1 non-employee, rate %, got %', round(1 * 1000000 / v_exp_hours, 2), v_txt;
    END IF;
    v_txt := pg_temp.f307_call(u_health, format($q$SELECT lti || '/' || days_lost || '/' || COALESCE(ltifr::text, '-') FROM esg_safety_rates(%s) WHERE month = make_date(%s, 4, 1)$q$, v_year, v_year));
    IF v_txt IS DISTINCT FROM '1/1/-' THEN
        RAISE EXCEPTION 'FIXTURE 307 L: April counts its injury but has no rate (incomplete), got %', v_txt;
    END IF;

    -- ══════════════ C · 误工天数的更正 ══════════════
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_health, format('SELECT record_incident_days_lost_correction(%L, 5, %L)', i_emp, 'longer MC')), 'PERMISSION_DENIED', 'C no edit code');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_sedit, format('SELECT record_incident_days_lost_correction(%L, 5, %L)', i_emp, '  ')), 'INCIDENT_CORRECTION_REASON_REQUIRED', 'C reason');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_sedit, format('SELECT record_incident_days_lost_correction(%L, 3, %L)', i_emp, 'same')), 'INCIDENT_CORRECTION_NO_CHANGE', 'C same');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_sedit, format('SELECT record_incident_days_lost_correction(%L, -1, %L)', i_emp, 'neg')), 'INCIDENT_DAYS_LOST_INVALID', 'C negative');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_sedit, format('SELECT record_incident_days_lost_correction(%L, 2, %L)', i_closed, 'late')), 'INCIDENT_CLOSED', 'C closed');
    PERFORM pg_temp.f307_as(NULL);
    INSERT INTO incidents (code, kind_code, occurred_at, what_happened, immediate_action, responsible_name, nea_reportable)
    VALUES ('ZZ-F307-I5', 'near_miss', make_date(v_year, 3, 15) + time '10:00', 'near miss', 'none', 'supervisor', false) RETURNING id INTO i_nm;
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_sedit, format('SELECT record_incident_days_lost_correction(%L, 1, %L)', i_nm, 'x')),
                                    'INCIDENT_INJURY_NEEDS_PERSON', 'C no injured person');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_sedit, format('SELECT record_incident_days_lost_correction(%L, 5, %L)', i_emp, 'MC extended')), 'C first correction');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_sedit, format('SELECT record_incident_days_lost_correction(%L, 6, %L)', i_emp, 'MC extended again')), 'C second correction');
    IF pg_temp.f307_call(u_health, format('SELECT days_lost::text || ''/'' || days_lost_recorded || ''/'' || days_lost_corrections FROM incident_rows WHERE id = %L', i_emp)) IS DISTINCT FROM '6/3/2' THEN
        RAISE EXCEPTION 'FIXTURE 307 C: incident_rows should give the latest correction to a health reader, got %',
            pg_temp.f307_call(u_health, format('SELECT days_lost::text || ''/'' || days_lost_recorded || ''/'' || days_lost_corrections FROM incident_rows WHERE id = %L', i_emp));
    END IF;
    IF pg_temp.f307_call(u_inj, format('SELECT days_lost::text FROM incident_rows WHERE id = %L', i_emp)) IS DISTINCT FROM '6' THEN
        RAISE EXCEPTION 'FIXTURE 307 C: the injured employee reads their own corrected days lost';
    END IF;
    IF pg_temp.f307_call(u_sedit, format('SELECT COALESCE(days_lost::text, ''-'') || ''/'' || COALESCE(days_lost_corrections::text, ''-'') FROM incident_rows WHERE id = %L', i_emp)) IS DISTINCT FROM '-/-' THEN
        RAISE EXCEPTION 'FIXTURE 307 C: a reader without health must not see days lost or its corrections';
    END IF;
    IF pg_temp.f307_rc(u_sedit, 'SELECT count(*) FROM incident_days_lost_corrections') <> 0
       OR pg_temp.f307_rc(u_health, format('SELECT count(*) FROM incident_days_lost_corrections WHERE incident_id = %L', i_emp)) <> 2
       OR pg_temp.f307_rc(u_inj, format('SELECT count(*) FROM incident_days_lost_corrections WHERE incident_id = %L', i_emp)) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 307 C: the corrections table is read by health holders and the injured employee only';
    END IF;
    v_txt := pg_temp.f307_call(u_health, format($q$SELECT lti || '/' || days_lost FROM esg_safety_rates(%s) WHERE month = make_date(%s, 3, 1)$q$, v_year, v_year));
    IF v_txt IS DISTINCT FROM '1/6' THEN
        RAISE EXCEPTION 'FIXTURE 307 C: the rates must use the corrected days lost, got %', v_txt;
    END IF;
    BEGIN
        DELETE FROM incident_days_lost_corrections WHERE incident_id = i_emp;
        RAISE EXCEPTION 'FIXTURE 307 C: a correction was deleted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%INCIDENT_IMMUTABLE%' THEN RAISE; END IF;
    END;

    -- 前年:12 个月都有考勤期、每一行都记了 → 年初至今有工时与率
    PERFORM pg_temp.f307_as(NULL);
    INSERT INTO attendance_periods (code, period_month)
    SELECT 'ZZ-F307-' || v_y2 || '-' || lpad(k::text, 2, '0'), make_date(v_y2, k, 1) FROM generate_series(1, 12) k;
    INSERT INTO attendance_lines (period_id, employee_id, recorded_at, recorded_by)
    SELECT p.id, e_none, now(), u_all FROM attendance_periods p WHERE p.code LIKE 'ZZ-F307-' || v_y2 || '-%';
    v_txt := pg_temp.f307_call(u_health, format($q$SELECT hours_state || '/' || hours_worked || '/' || lti || '/' || ltifr FROM esg_safety_rates(%s) WHERE month IS NULL$q$, v_y2));
    IF v_txt IS DISTINCT FROM 'complete/' || round(calculate_leave_days(make_date(v_y2, 1, 1), make_date(v_y2, 12, 31)) * 8, 2) || '/0/0.00' THEN
        RAISE EXCEPTION 'FIXTURE 307 H: a year whose every month is complete carries year-to-date hours and a rate, got %', v_txt;
    END IF;

    -- ══════════════ T · 必修培训 ══════════════
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_hr, 'SELECT required_training_save(NULL, ''Forklift'', ''safety'', 24, ''everyone'')'), 'PERMISSION_DENIED', 'T no code');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, 'SELECT required_training_save(NULL, ''Forklift'', ''safety'', 24, ''positions'', ''{}''::uuid[])'), 'REQUIRED_TRAINING_POSITIONS_REQUIRED', 'T positions empty');
    v_msg := pg_temp.f307_call(u_cco, format('SELECT required_training_save(NULL, ''ZZ F307 forklift'', ''safety'', 24, ''positions'', ARRAY[%L]::uuid[])', v_pos));
    PERFORM pg_temp.f307_expect_ok(v_msg, 'T save positions'); rt_pos := (v_msg::jsonb ->> 'id')::uuid;
    v_msg := pg_temp.f307_call(u_cfo, 'SELECT required_training_save(NULL, ''ZZ F307 induction'', ''induction'', NULL, ''everyone'')');
    PERFORM pg_temp.f307_expect_ok(v_msg, 'T save everyone'); rt_all := (v_msg::jsonb ->> 'id')::uuid;
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, 'SELECT required_training_save(NULL, ''zz f307 INDUCTION'', NULL, NULL, ''everyone'')'), 'REQUIRED_TRAINING_NAME_TAKEN', 'T same name');
    v_msg := pg_temp.f307_call(u_cfo, 'SELECT required_training_save(NULL, ''ZZ F307 validity'', ''compliance'', 12, ''office'')');
    PERFORM pg_temp.f307_expect_ok(v_msg, 'T save office'); rt_val := (v_msg::jsonb ->> 'id')::uuid;
    PERFORM pg_temp.f307_as(NULL);
    INSERT INTO training_records (employee_id, training_name, category, completed_date, expiry_date, required_training_id) VALUES
        (e_inj,  'Forklift', 'safety', v_today - 300, v_today + 400, rt_pos),     -- 有效
        (e_shop, 'Forklift', 'safety', v_today - 700, v_today + 20,  rt_pos),     -- 快到期(紧急)
        (e_inj,  'Induction', 'induction', v_today - 30, NULL, rt_all),           -- 不过期
        (e_off,  'Induction', 'induction', v_today - 30, NULL, NULL),             -- 没挂上 → 对这一门是 missing
        (e_none, 'Compliance', 'compliance', v_today - 400, NULL, rt_val),        -- 12 个月有效期 → 已过期
        (e_off,  'Compliance', 'compliance', v_today - 300, NULL, rt_val);        -- 12 个月有效期 → 快到期
    v_txt := pg_temp.f307_call(u_hr, format($q$SELECT string_agg(employee_code || ':' || status, ',' ORDER BY employee_code) FROM esg_training_status() WHERE required_training_id = %L$q$, rt_pos));
    IF v_txt IS DISTINCT FROM 'ZZ-F307-I:valid,ZZ-F307-S:expiring' THEN
        RAISE EXCEPTION 'FIXTURE 307 T: the positions training covers exactly the two operators, got %', v_txt;
    END IF;
    v_txt := pg_temp.f307_call(u_hr, format($q$SELECT string_agg(employee_code || ':' || status || ':' || COALESCE(expiry_date::text, '-'), ',' ORDER BY employee_code) FROM esg_training_status()
                                             WHERE required_training_id = %L AND employee_code LIKE 'ZZ-F307-%%'$q$, rt_val));
    IF v_txt IS DISTINCT FROM format('ZZ-F307-C:missing:-,ZZ-F307-N:expired:%s,ZZ-F307-O:expiring:%s', (v_today - 400 + interval '12 months')::date, (v_today - 300 + interval '12 months')::date) THEN
        RAISE EXCEPTION 'FIXTURE 307 T: the office training with a 12-month validity reads %', v_txt;
    END IF;
    v_txt := pg_temp.f307_call(u_hr, format($q$SELECT string_agg(employee_code || ':' || status, ',' ORDER BY employee_code) FROM esg_training_status() WHERE required_training_id = %L AND employee_code LIKE 'ZZ-F307-%%'$q$, rt_all));
    IF v_txt IS DISTINCT FROM 'ZZ-F307-C:missing,ZZ-F307-I:valid,ZZ-F307-N:missing,ZZ-F307-O:missing,ZZ-F307-S:missing' THEN
        RAISE EXCEPTION 'FIXTURE 307 T: an unlinked record does not cover a required training, got %', v_txt;
    END IF;
    v_txt := pg_temp.f307_call(u_hr, format($q$SELECT applicable || '/' || valid || '/' || expiring || '/' || expired || '/' || missing FROM esg_training_coverage() WHERE required_training_id = %L$q$, rt_pos));
    IF v_txt IS DISTINCT FROM '2/1/1/0/0' THEN
        RAISE EXCEPTION 'FIXTURE 307 T: coverage of the positions training is %', v_txt;
    END IF;
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_safe, 'SELECT count(*) FROM esg_training_coverage()'), 'PERMISSION_DENIED', 'T coverage without hr');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_safe, 'SELECT count(*) FROM esg_training_status()'), 'PERMISSION_DENIED', 'T status without hr');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_cfo, format('SELECT required_training_retire(%L)', rt_val)), 'T retire');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, format('SELECT required_training_retire(%L)', rt_val)), 'REQUIRED_TRAINING_RETIRED', 'T retire twice');
    IF pg_temp.f307_call(u_hr, format('SELECT count(*) FROM esg_training_coverage() WHERE required_training_id = %L', rt_val)) <> '0' THEN
        RAISE EXCEPTION 'FIXTURE 307 T: a retired training leaves the coverage';
    END IF;
    IF (SELECT count(*) FROM training_records WHERE required_training_id = rt_val) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 307 T: retiring a training keeps the records linked to it';
    END IF;

    -- ══════════════ D · 制度登记簿 ══════════════
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_hr, format('SELECT company_policy_record(NULL, ''Code of conduct'', ''1.0'', %L, %L, %L, ''SharePoint/HR/coc.pdf'')', e_cco, v_today - 400, v_today - 35)),
                                    'PERMISSION_DENIED', 'D no code');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, format('SELECT company_policy_record(NULL, ''Code of conduct'', ''1.0'', %L, %L, %L, ''x'')', e_cco, v_today, v_today - 1)),
                                    'COMPANY_POLICY_REVIEW_BEFORE_EFFECTIVE', 'D review before effective');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, format('SELECT company_policy_record(NULL, ''Code of conduct'', ''1.0'', %L, NULL, %L, ''x'')', e_cco, v_today)),
                                    'COMPANY_POLICY_DATES_REQUIRED', 'D dates');
    v_msg := pg_temp.f307_call(u_cco, format('SELECT company_policy_record(NULL, ''ZZ F307 code of conduct'', ''1.0'', %L, %L, %L, ''SharePoint/HR/coc-1.0.pdf'')', e_cco, v_today - 400, v_today - 35));
    PERFORM pg_temp.f307_expect_ok(v_msg, 'D first'); pol1 := (v_msg::jsonb ->> 'id')::uuid;
    IF pg_temp.f307_call(u_none, format('SELECT is_current || ''/'' || review_overdue FROM company_policy_rows WHERE id = %L', pol1)) IS DISTINCT FROM 'true/true' THEN
        RAISE EXCEPTION 'FIXTURE 307 D: the current version past its review date is flagged overdue';
    END IF;
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, format('SELECT company_policy_record(%L, ''ZZ F307 code of conduct'', ''1.0'', %L, %L, %L, ''x'')', pol1, e_cco, v_today, v_today + 365)),
                                    'COMPANY_POLICY_VERSION_SAME', 'D same version');
    v_msg := pg_temp.f307_call(u_cfo, format('SELECT company_policy_record(%L, ''ZZ F307 code of conduct'', ''2.0'', %L, %L, %L, ''SharePoint/HR/coc-2.0.pdf'')', pol1, e_cco, v_today, v_today + 365));
    PERFORM pg_temp.f307_expect_ok(v_msg, 'D new version'); pol2 := (v_msg::jsonb ->> 'id')::uuid;
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, format('SELECT company_policy_record(%L, ''ZZ F307 code of conduct'', ''3.0'', %L, %L, %L, ''x'')', pol1, e_cco, v_today, v_today + 365)),
                                    'COMPANY_POLICY_ALREADY_SUPERSEDED', 'D supersede twice');
    v_txt := pg_temp.f307_call(u_none, format($q$SELECT string_agg(version || ':' || is_current || ':' || review_overdue, ',' ORDER BY version) FROM company_policy_rows WHERE id IN (%L, %L)$q$, pol1, pol2));
    IF v_txt IS DISTINCT FROM '1.0:false:false,2.0:true:false' THEN
        RAISE EXCEPTION 'FIXTURE 307 D: versions read %', v_txt;
    END IF;
    IF pg_temp.f307_call(u_none, format('SELECT owner_label FROM company_policy_rows WHERE id = %L', pol2)) IS DISTINCT FROM 'ZZ-F307-C · fixture 307 cco' THEN
        RAISE EXCEPTION 'FIXTURE 307 D: the owner label is code · name';
    END IF;
    IF pg_temp.f307_rc(u_portal, 'SELECT count(*) FROM company_policy_rows') <> 0 OR pg_temp.f307_rc(u_portal, 'SELECT count(*) FROM company_policies') <> 0
       OR pg_temp.f307_rc(u_none, format('SELECT count(*) FROM company_policies WHERE id IN (%L, %L)', pol1, pol2)) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 307 D: employees read the register; a session with no employee record and no code does not';
    END IF;
    BEGIN
        UPDATE company_policies SET document_ref = 'tampered' WHERE id = pol2;
        RAISE EXCEPTION 'FIXTURE 307 D: a policy version was edited';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%COMPANY_POLICY_IMMUTABLE%' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM company_policies WHERE id = pol2;
        RAISE EXCEPTION 'FIXTURE 307 D: a policy version was deleted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%COMPANY_POLICY_IMMUTABLE%' THEN RAISE; END IF;
    END;

    -- ══════════════ W · 举报:两条路 ══════════════
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_portal, 'SELECT whistleblowing_report_file(''x'', ''y'', false)'), 'WHISTLEBLOWING_EMPLOYEES_ONLY', 'W no employee record');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_none, 'SELECT whistleblowing_report_file(''x'', ''y'', NULL)'), 'WHISTLEBLOWING_CONCERNS_CCO_REQUIRED', 'W concerns unanswered');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_none, 'SELECT whistleblowing_report_file(''  '', ''y'', false)'), 'WHISTLEBLOWING_SUBJECT_REQUIRED', 'W subject');
    v_msg := pg_temp.f307_call(u_none, 'SELECT whistleblowing_report_file(''ZZ F307 plain'', ''Expense claims padded'', false)');
    PERFORM pg_temp.f307_expect_ok(v_msg, 'W file plain'); w_plain := (v_msg::jsonb ->> 'id')::uuid;
    v_msg := pg_temp.f307_call(u_none, 'SELECT whistleblowing_report_file(''ZZ F307 about the CCO'', ''The CCO approved their own vendor'', true)');
    PERFORM pg_temp.f307_expect_ok(v_msg, 'W file concerning the CCO'); w_cco := (v_msg::jsonb ->> 'id')::uuid;

    -- 路一:没标的 —— 只有 cco
    IF pg_temp.f307_rc(u_cco, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain)) <> 1
       OR pg_temp.f307_rc(u_cfo, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain)) <> 0
       OR pg_temp.f307_rc(u_admin, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain)) <> 0
       OR pg_temp.f307_rc(u_none, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 307 W route 1: an unmarked report is read by the cco only (cco %, cfo %, admin %, filer %)',
            pg_temp.f307_rc(u_cco, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain)),
            pg_temp.f307_rc(u_cfo, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain)),
            pg_temp.f307_rc(u_admin, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain)),
            pg_temp.f307_rc(u_none, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_plain));
    END IF;
    -- 路二:标了涉及 CCO 的 —— 只有 cfo
    IF pg_temp.f307_rc(u_cfo, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_cco)) <> 1
       OR pg_temp.f307_rc(u_cco, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_cco)) <> 0
       OR pg_temp.f307_rc(u_admin, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_cco)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 307 W route 2: a report concerning the CCO is read by the cfo only (cfo %, cco %, admin %)',
            pg_temp.f307_rc(u_cfo, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_cco)),
            pg_temp.f307_rc(u_cco, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_cco)),
            pg_temp.f307_rc(u_admin, format('SELECT count(*) FROM whistleblowing_report_rows WHERE id = %L', w_cco));
    END IF;
    -- 基表的读策略与视图同一个答案
    IF pg_temp.f307_rc(u_cco, format('SELECT count(*) FROM whistleblowing_reports WHERE id IN (%L, %L)', w_plain, w_cco)) <> 1
       OR pg_temp.f307_rc(u_cfo, format('SELECT count(*) FROM whistleblowing_reports WHERE id IN (%L, %L)', w_plain, w_cco)) <> 1
       OR pg_temp.f307_rc(u_admin, format('SELECT count(*) FROM whistleblowing_reports WHERE id IN (%L, %L)', w_plain, w_cco)) <> 0
       OR pg_temp.f307_rc(u_cco, format('SELECT count(*) FROM whistleblowing_reports WHERE id = %L', w_cco)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 307 W: the base table''s read policy disagrees with the view';
    END IF;
    IF pg_temp.f307_call(u_cco, format('SELECT filed_by_label FROM whistleblowing_report_rows WHERE id = %L', w_plain)) IS DISTINCT FROM 'ZZ-F307-N · fixture 307 filer' THEN
        RAISE EXCEPTION 'FIXTURE 307 W: confidential, not anonymous — the reader sees who filed it';
    END IF;
    -- 外来的
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_cco, format('SELECT whistleblowing_report_record_outside(%L, ''letter'', NULL, ''ZZ F307 letter'', ''An unsigned letter'', false)', v_today - 2)), 'W cco records an anonymous letter');
    w_out := (SELECT id FROM whistleblowing_reports WHERE subject = 'ZZ F307 letter');
    IF (SELECT source FROM whistleblowing_reports WHERE id = w_out) <> 'outside_anonymous' THEN
        RAISE EXCEPTION 'FIXTURE 307 W: a report recorded with no reporter name is an anonymous source';
    END IF;
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, format('SELECT whistleblowing_report_record_outside(%L, ''email'', ''A. Person'', ''x'', ''y'', true)', v_today)), 'PERMISSION_DENIED', 'W cco cannot record a report concerning the CCO');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_cfo, format('SELECT whistleblowing_report_record_outside(%L, ''email'', ''A. Person'', ''ZZ F307 email'', ''About the CCO'', true)', v_today)), 'W cfo records a named email concerning the CCO');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, format('SELECT whistleblowing_report_record_outside(%L, ''email'', NULL, ''x'', ''y'', true)', v_today + 1)), 'WHISTLEBLOWING_RECEIVED_ON_IN_FUTURE', 'W future date');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_admin, format('SELECT whistleblowing_report_record_outside(%L, ''email'', NULL, ''x'', ''y'', false)', v_today)), 'PERMISSION_DENIED', 'W admin records nothing');
    -- 追加状态
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, format('SELECT whistleblowing_report_update(%L, ''acknowledged'', ''seen'')', w_cco)), 'WHISTLEBLOWING_NOT_FOUND', 'W cco cannot touch the escalated one');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cco, format('SELECT whistleblowing_report_update(%L, ''acknowledged'', ''  '')', w_plain)), 'WHISTLEBLOWING_NOTE_REQUIRED', 'W note');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_cco, format('SELECT whistleblowing_report_update(%L, ''investigating'', ''Interviewing the finance clerk on Monday'')', w_plain)), 'W cco updates');
    PERFORM pg_temp.f307_expect_ok(pg_temp.f307_call(u_cfo, format('SELECT whistleblowing_report_update(%L, ''closed'', ''Board informed; vendor contract suspended'')', w_cco)), 'W cfo closes');
    PERFORM pg_temp.f307_expect_err(pg_temp.f307_call(u_cfo, format('SELECT whistleblowing_report_update(%L, ''investigating'', ''again'')', w_cco)), 'WHISTLEBLOWING_CLOSED', 'W closed');
    v_txt := pg_temp.f307_call(u_none, $q$SELECT string_agg(subject || ':' || status, ',' ORDER BY subject) FROM my_concerns()$q$);
    IF v_txt IS DISTINCT FROM 'ZZ F307 about the CCO:closed,ZZ F307 plain:investigating' THEN
        RAISE EXCEPTION 'FIXTURE 307 W: the filer sees the status of their own reports, got %', v_txt;
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.routines rt JOIN information_schema.parameters pa ON pa.specific_name = rt.specific_name
                WHERE rt.routine_name = 'my_concerns' AND pa.parameter_mode = 'OUT' AND pa.parameter_name IN ('note', 'details', 'filed_by_employee_id')) THEN
        RAISE EXCEPTION 'FIXTURE 307 W: my_concerns must not return the readers'' notes or the details';
    END IF;
    IF pg_temp.f307_call(u_cco, $q$SELECT count(*) FROM my_concerns()$q$) <> '0' THEN
        RAISE EXCEPTION 'FIXTURE 307 W: my_concerns returns only the caller''s own reports';
    END IF;
    IF pg_temp.f307_rc(u_cco, format('SELECT count(*) FROM whistleblowing_updates WHERE report_id IN (%L, %L)', w_plain, w_cco)) <> 1
       OR pg_temp.f307_rc(u_none, format('SELECT count(*) FROM whistleblowing_updates WHERE report_id IN (%L, %L)', w_plain, w_cco)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 307 W: status updates follow their report''s reader code';
    END IF;
    BEGIN
        UPDATE whistleblowing_reports SET subject = 'tampered' WHERE id = w_plain;
        RAISE EXCEPTION 'FIXTURE 307 W: a report was edited';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%WHISTLEBLOWING_IMMUTABLE%' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM whistleblowing_updates WHERE report_id = w_plain;
        RAISE EXCEPTION 'FIXTURE 307 W: a status update was deleted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%WHISTLEBLOWING_IMMUTABLE%' THEN RAISE; END IF;
    END;
    IF EXISTS (SELECT 1 FROM change_log WHERE table_name IN ('whistleblowing_reports', 'whistleblowing_updates')) THEN
        RAISE EXCEPTION 'FIXTURE 307 W: whistleblowing rows must not enter the change log';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'grid_emission_factors')
       OR NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'company_policies')
       OR NOT EXISTS (SELECT 1 FROM change_log WHERE table_name = 'incident_days_lost_corrections') THEN
        RAISE EXCEPTION 'FIXTURE 307: the ESG registers are recorded in the change log';
    END IF;

    RAISE NOTICE 'FIXTURE 307 全部通过: P F S H L C T D W';
END;
$f307$;

ROLLBACK;

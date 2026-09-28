-- db/scripts/2026-09-28-leavebal1-live-proof.sql
-- LEAVE-BAL-1 · 线上证明(一笔事务,最后 ROLLBACK;只用本事务里自己建的员工与请假单 ——
-- 已有的请假单 LV-2026-0004 / 0005 / 0006 与其它任何单据一张都不碰,连读都只读它们的计数)。
--
-- 身份:以 postgres 连接建布景(两名临时员工、两张直写的待批单);每一臂以一个【真账号】的 JWT、
-- SET LOCAL ROLE authenticated 跑 —— admin@(持 module.hr.edit,HR 代录与直写那几臂)、tim@(cfo,
-- 持 action.decide_hr_requests,经 employee_accounts 归到 EMP-2026-0002,不是任何一张临时单的当事人)。
-- 额度不写死:从线上的累积规则现算(finance_settings.system_start_date = 2026-08-01,办公室 24 天/年),
-- 断言写成"比它多一天被拒 / 正好等于它照收"。
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.lp_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

DO $$
DECLARE
    u_admin uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@swm-os.test(role admin)
    u_tim   uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';   -- tim@evoltrya.test(role cfo)
    e_t  uuid := gen_random_uuid(); e_t2 uuid := gen_random_uuid(); e_n uuid := gen_random_uuid();
    p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid();
    v_acc numeric; v_days numeric; v_msg text; v_bal jsonb; v_fn text; v_ln text;
BEGIN
    IF current_user <> 'postgres' THEN RAISE EXCEPTION 'LIVE PROOF: expected to start as postgres'; END IF;
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'LIVE PROOF: approvals expected ON'; END IF;

    -- 布景:两名临时员工(办公室,2020 年入职,在职,没有账号)
    INSERT INTO employees (id, code, legal_name, first_name, employment_type, work_category, hire_date, employment_status) VALUES
        (e_t,  'ZZ-LB1-T1', 'ZZ LB1 Temp One', 'Temp', 'full_time', 'office', DATE '2020-01-01', 'active'),
        (e_t2, 'ZZ-LB1-T2', 'ZZ LB1 Temp Two', 'Temp', 'full_time', 'office', DATE '2020-01-01', 'active');

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    v_acc := (leave_balance_internal(e_t, 'annual', DATE '2026-12-01')->>'available')::numeric;
    RAISE NOTICE 'LIVE annual accrued by 2026-12-01 for a 2020 office hire (system start 2026-08-01): %', v_acc;
    IF v_acc IS NULL OR v_acc <= 0 THEN RAISE EXCEPTION 'LIVE PROOF: accrual % is not positive', v_acc; END IF;

    -- ① 超额被拒:admin@ 代录 2026-12-01 → 12-31(整个十二月)
    v_days := calculate_leave_days(DATE '2026-12-01', DATE '2026-12-31');
    IF v_days <= v_acc THEN RAISE EXCEPTION 'LIVE PROOF: December (% days) is not over %', v_days, v_acc; END IF;
    v_msg := pg_temp.lp_try(u_admin, format(
        'SELECT submit_leave_request(%L::uuid, %L, %L::date, %L::date)', e_t, 'annual', '2026-12-01', '2026-12-31'));
    RAISE NOTICE 'LIVE ① over balance (% days vs % available) → %', v_days, v_acc, v_msg;
    IF v_msg IS DISTINCT FROM format('INSUFFICIENT_ACCRUED_LEAVE|%s|%s', trim_scale(v_acc), trim_scale(v_days)) THEN
        RAISE EXCEPTION 'LIVE PROOF ① failed: %', v_msg; END IF;

    -- ② 额度内照收:admin@ 代录 2026-12-07(一)一天,然后本人那一侧的余额现在扣着它
    v_msg := pg_temp.lp_try(u_admin, format(
        'SELECT submit_leave_request(%L::uuid, %L, %L::date, %L::date)', e_t, 'annual', '2026-12-07', '2026-12-07'));
    v_bal := leave_balance_internal(e_t, 'annual', DATE '2026-12-01');
    RAISE NOTICE 'LIVE ② within balance → % · balance now available % pending % bookable %',
        v_msg, v_bal->>'available', v_bal->>'pending', v_bal->>'bookable';
    IF v_msg <> 'OK' OR (v_bal->>'pending')::numeric <> 1 OR (v_bal->>'bookable')::numeric <> v_acc - 1 THEN
        RAISE EXCEPTION 'LIVE PROOF ② failed: % / %', v_msg, v_bal; END IF;

    -- ③ 两张各自够、合起来不够的待批(直写,旧单的形状):先批的过,后一张「可用 0」
    -- ★ created_by 显式 NULL,并先清掉 JWT:否则它取 DEFAULT auth.uid() = 上面设的 admin@ ——
    --   而 admin@ 与 tim@ 是【同一个人】(EMP-2026-0002),四眼会正确地以 raiser 拒掉 tim@
    --   (第一次跑就是这么停下的:SELF_APPROVAL_FORBIDDEN|raiser,整笔回滚)。
    PERFORM set_config('request.jwt.claims', '', true);
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by) VALUES
        (p1, 'ZZ-LB1-P1', e_t2, 'annual', DATE '2026-12-01', DATE '2026-12-11', v_acc, 'pending', NULL),
        (p2, 'ZZ-LB1-P2', e_t2, 'annual', DATE '2026-12-14', DATE '2026-12-14', 1, 'pending', NULL);
    v_msg := pg_temp.lp_try(u_tim, format('SELECT decide_leave_request(%L::uuid, true, NULL)', p1));
    RAISE NOTICE 'LIVE ③a tim@ approves the first (% days, the other pending not counted) → % · status %',
        v_acc, v_msg, (SELECT status FROM leave_requests WHERE id = p1);
    IF v_msg <> 'OK' OR (SELECT status FROM leave_requests WHERE id = p1) <> 'approved' THEN
        RAISE EXCEPTION 'LIVE PROOF ③a failed: %', v_msg; END IF;
    v_msg := pg_temp.lp_try(u_tim, format('SELECT decide_leave_request(%L::uuid, true, NULL)', p2));
    RAISE NOTICE 'LIVE ③b tim@ approves the second → % · status %', v_msg, (SELECT status FROM leave_requests WHERE id = p2);
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_ACCRUED_LEAVE|0|1' OR (SELECT status FROM leave_requests WHERE id = p2) <> 'pending' THEN
        RAISE EXCEPTION 'LIVE PROOF ③b failed: %', v_msg; END IF;

    -- ④ 直写被拒:admin@ 持 module.hr.edit,直接 UPDATE 一张【本事务自己的】单
    v_msg := pg_temp.lp_try(u_admin, format('UPDATE leave_requests SET status = %L WHERE id = %L::uuid', 'approved', p2));
    RAISE NOTICE 'LIVE ④ admin@ direct UPDATE → %', v_msg;
    IF v_msg IS DISTINCT FROM 'permission denied for table leave_requests' THEN
        RAISE EXCEPTION 'LIVE PROOF ④ failed: %', v_msg; END IF;

    -- ⑤ 一名员工存成「有名字、没有姓氏」:以 admin@ 建档再保存(走 RLS 与列授权的那条路),再以 admin@ 经 employees_masked 读回
    v_msg := pg_temp.lp_try(u_admin, format(
        'INSERT INTO employees (id, code, legal_name, first_name, last_name, employment_type, work_category, hire_date) '
        'VALUES (%L::uuid, %L, %L, %L, NULL, %L, %L, %L::date)',
        e_n, 'ZZ-LB1-N1', 'ZZ LB1 Name Legal', 'Ann', 'full_time', 'office', '2026-09-01'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'LIVE PROOF ⑤ insert failed: %', v_msg; END IF;
    v_msg := pg_temp.lp_try(u_admin, format(
        'UPDATE employees SET first_name = %L, last_name = NULL WHERE id = %L::uuid', 'Ann', e_n));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'LIVE PROOF ⑤ update failed: %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_admin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT first_name, last_name INTO v_fn, v_ln FROM employees_masked WHERE id = e_n;
    EXECUTE 'RESET ROLE';
    RAISE NOTICE 'LIVE ⑤ saved with a first name and no last name → employees_masked reads first_name=% last_name=%', v_fn, COALESCE(v_ln, 'NULL');
    IF v_fn IS DISTINCT FROM 'Ann' OR v_ln IS NOT NULL THEN RAISE EXCEPTION 'LIVE PROOF ⑤ failed'; END IF;

    -- 已有的单一张没被本事务碰到:【本事务自己的员工之外】的每一行,整行指纹 = 迁移前读数
    -- (db/scripts/2026-09-28-leavebal1-readings.sql,2026-09-28 18:19:20,6 行,e4334e8c…)。
    -- ★ 第二次跑时这一句按 code LIKE 'LV-%' 比,把本事务 ② 自己生出的 LV-2026-0007 也算了进去 —— 错的是判据,已改。
    IF (SELECT md5(string_agg(row(l.*)::text, ',' ORDER BY l.id)) FROM leave_requests l
         WHERE l.employee_id NOT IN (e_t, e_t2))
       IS DISTINCT FROM 'e4334e8c873c6aa55670381f388a50d4' THEN
        RAISE EXCEPTION 'LIVE PROOF: a pre-existing leave request changed inside the proof'; END IF;
    RAISE NOTICE 'LIVE pre-existing leave requests inside the proof: % rows, fingerprint unchanged (e4334e8c…)',
        (SELECT count(*) FROM leave_requests WHERE employee_id NOT IN (e_t, e_t2));
    RAISE NOTICE 'LIVE PROOF 全部通过 —— 整笔回滚';
END $$;

ROLLBACK;

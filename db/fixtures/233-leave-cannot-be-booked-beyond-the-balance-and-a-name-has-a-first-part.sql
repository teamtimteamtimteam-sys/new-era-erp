-- 233 LEAVE-BAL-1 + NAME-1:请假不能超过余额 —— 提交扣待批、审批只扣已批;员工有了名字与姓氏(2026-09-28)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(LEAVE-BAL-1 grilling Q1–Q22,Tim 2026-09-28 全部接受)
--   A  年假:A0 本人自助超额 → INSUFFICIENT_ACCRUED_LEAVE|6|7;A1 额度内照收;
--        ★ A2 待批计入提交:4 天待批之后再请 3 天 → |2|3;★ A3 正好等于可请(2 = 2)照收;
--        A4 HR 代录超额 → |0|1
--   B  非年假(病假,额度本支自己设成 5):B1 半天存 0.5、待批 0.5、可请 4.5;B2 额度内照收;
--        B3 本人自助超额 → INSUFFICIENT_BALANCE|0.5|1;B4 HR 代录超额 → 同;
--        ★ B5 HR 例外(手填 3 天)超额照样拒 —— 没有口子(Q11)
--   C  C1 无薪假不查(20 天照收);★ C2 婴儿看护假(无薪、但有额度)查 → |3|4(Q1)
--   D  ★★ 审批只扣已批(Q10 Option A):两张各自够、合起来不够的待批单(直写,旧单的形状)——
--        D1 先批的那张过(另一张待批不算);D2 后一张被拒 INSUFFICIENT_ACCRUED_LEAVE|0|2;
--        D3/D4 同一件事在非年假上:先批的过,后一张 INSUFFICIENT_BALANCE|1|3
--   W  ★ 持 module.hr.edit 的登录用户直接 INSERT / UPDATE / DELETE leave_requests → permission denied(Q12)
--   M  M1 名字与姓氏跟 legal_name 同一个可见性:基表列授权 + employees_masked 都读得到
--   N  N1 个人数据导出带着 first_name / last_name(姓氏为空时键仍在、值为 null);
--      N2 anonymise_employee 把两列都清成 NULL
--
--   ☞「名字必填 / 姓氏可空 / 空白存 NULL」是【应用层】的规矩(Tim Q17:库里没有约束),
--     所以它的证据不在这里,在 scripts/check-employee-names.mjs(npm run build 里)。
--   ☞ 同一名员工的行锁(Q13)是并发性质,一支单会话的 fixture 证不了;写在交回报告里。
--
-- 自带数据(README 第 2 条):员工的年假费率用【员工行】钉死 24 天/年(不读类别行这份运行时配置);
-- 病假、婴儿看护假、无薪假的额度本支自己 UPDATE;锁期与系统起始日自己设;全部日期在 2030 年 ——
-- 引导数据里没有 2030 的公共假日,于是周一到周五就是工作日。
-- 2030-01-01 是星期二,2030-04-01 是星期一:到 4 月的任何一天,已满的月份是 1–3 月 → 年假累积 3 × 2 = 6 天。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f233_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 以某人的身份(authenticated 角色)跑一句,返回 'OK' 或那一句拒绝
CREATE FUNCTION pg_temp.f233_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f233_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM p_user THEN
        RAISE EXCEPTION 'FIXTURE 233 布景失败:身份没有切过去(%, %)', current_user, auth.uid(); END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

-- 以某人的身份(authenticated 角色)读一个标量
CREATE FUNCTION pg_temp.f233_val(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f233_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN 'ERROR: ' || SQLERRM;
END;
$f$;

-- 一句 submit_leave_request 的 SQL
CREATE FUNCTION pg_temp.f233_submit(p_emp uuid, p_type text, p_start date, p_end date,
                                    p_start_half boolean DEFAULT false,
                                    p_exception_days numeric DEFAULT NULL) RETURNS text
LANGUAGE sql AS $f$
    SELECT format('SELECT submit_leave_request(%L::uuid, %L, %L::date, %L::date, %L::boolean, false, NULL, NULL, %L::boolean, %L::numeric, %L)',
                  p_emp, p_type, p_start, p_end, p_start_half,
                  p_exception_days IS NOT NULL, p_exception_days,
                  CASE WHEN p_exception_days IS NOT NULL THEN 'six-day schedule' END)
$f$;

DO $$
DECLARE
    u_emp  uuid := gen_random_uuid();   -- 一个普通员工:一个码都不持
    u_two  uuid := gen_random_uuid();   -- 另一个普通员工(审批那一臂的主角)
    u_hr   uuid := gen_random_uuid();   -- HR:module.hr.edit + module.hr.view + action.anonymise_employee
    u_apr  uuid := gen_random_uuid();   -- 审批人:action.decide_hr_requests + module.hr.view(不是任何一张单的当事人)
    r_hr uuid; r_apr uuid;
    e_emp uuid := gen_random_uuid(); e_two uuid := gen_random_uuid();
    e_hr uuid := gen_random_uuid(); e_apr uuid := gen_random_uuid(); e_gone uuid := gen_random_uuid();
    p1 uuid := gen_random_uuid(); p2 uuid := gen_random_uuid();
    sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid();
    v_msg text; v_bal jsonb; v_j jsonb; v_n numeric;
BEGIN
    -- ══════════════ 布景 ══════════════
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;
    UPDATE leave_types SET is_active = true WHERE code IN ('annual', 'sick', 'unpaid', 'infant_care');
    UPDATE leave_types SET default_days_per_year = 5, requires_certificate_after_days = NULL WHERE code = 'sick';
    UPDATE leave_types SET default_days_per_year = 3, requires_certificate_after_days = NULL WHERE code = 'infant_care';
    UPDATE leave_types SET default_days_per_year = NULL WHERE code = 'unpaid';
    IF NOT (SELECT is_accrued FROM leave_types WHERE code = 'annual')
       OR (SELECT is_accrued FROM leave_types WHERE code = 'sick')
       OR (SELECT is_paid FROM leave_types WHERE code = 'infant_care') THEN
        RAISE EXCEPTION 'FIXTURE 233 布景失败:假别目录不是本支假设的形状(annual 累积 · sick 不累积 · infant_care 无薪)';
    END IF;

    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_emp, now()), (u_two, now()), (u_hr, now()), (u_apr, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx233-hr','f','f',true)  RETURNING id INTO r_hr;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx233-apr','f','f',true) RETURNING id INTO r_apr;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_hr, c FROM unnest(ARRAY['module.hr.edit', 'module.hr.view', 'action.anonymise_employee']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_apr, c FROM unnest(ARRAY['module.hr.view', 'action.decide_hr_requests']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_hr, r_hr), (u_apr, r_apr);

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status, user_id) VALUES
        (e_emp, 'FX233-EMP', 'FX233 Employee Legal', 'full_time', 'office', DATE '2020-01-01', 'active', u_emp),
        (e_two, 'FX233-TWO', 'FX233 Two Legal',      'full_time', 'office', DATE '2020-01-01', 'active', u_two),
        (e_hr,  'FX233-HR',  'FX233 HR Legal',       'full_time', 'office', DATE '2020-01-01', 'active', u_hr),
        (e_apr, 'FX233-APR', 'FX233 Approver Legal', 'full_time', 'office', DATE '2020-01-01', 'active', u_apr);
    INSERT INTO employees (id, code, legal_name, first_name, last_name, employment_type, work_category, hire_date,
                           employment_status, separation_date, separation_type) VALUES
        (e_gone, 'FX233-GONE', 'FX233 Gone Legal', 'Gone', 'Person', 'full_time', 'office', DATE '2019-01-01',
         'separated', DATE '2020-01-31', 'resignation');
    -- 年假费率:员工行钉死 24 天/年(= 每满一个月 2 天)
    INSERT INTO leave_accrual_rates (employee_id, days_per_year, effective_from, reason)
    SELECT e, 24, DATE '2000-01-01', 'fixture 233' FROM unnest(ARRAY[e_emp, e_two]) e;

    -- ★ U1-B(U1A-SELF-GATE-NULL-TRAP):这一句原来没有会话(以 postgres、不带 JWT 读)—— 那正是 NULL 陷阱放行的形状:
    --   current_user_employee() 是 NULL,"持码或本人"那道门从来没有关上。门关上之后,读的人要说出自己是谁 —— 以 HR 的身份读。
    PERFORM pg_temp.f233_as(u_hr);
    v_bal := leave_balance_internal(e_emp, 'annual', DATE '2030-04-01');
    PERFORM set_config('request.jwt.claims', '', true);
    IF (v_bal->>'available')::numeric <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 233 布景失败:2030-04-01 的年假累积应为 6,实为 %', v_bal->>'available';
    END IF;

    -- ══════════════ A · 年假 ══════════════
    -- A0 本人自助,7 天(4/1 一 → 4/9 二)> 6
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'annual', '2030-04-01', '2030-04-09'));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_ACCRUED_LEAVE|6|7' THEN
        RAISE EXCEPTION 'FIXTURE 233A0 失败:本人自助请 7 天年假(可请 6)应当被拒 INSUFFICIENT_ACCRUED_LEAVE|6|7,实得 %', v_msg; END IF;
    -- A1 本人自助,4 天(4/1 → 4/4)≤ 6 → 收下,留着待批
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'annual', '2030-04-01', '2030-04-04'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 233A1 失败:额度内的 4 天年假应当收下,实得 %', v_msg; END IF;
    -- A2 ★ 待批计入提交:再请 3 天(4/8 → 4/10),可请 6 − 4 = 2
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'annual', '2030-04-08', '2030-04-10'));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_ACCRUED_LEAVE|2|3' THEN
        RAISE EXCEPTION 'FIXTURE 233A2 失败:4 天待批之后再请 3 天应当被拒 INSUFFICIENT_ACCRUED_LEAVE|2|3(待批要计入),实得 %', v_msg; END IF;
    -- A3 ★ 正好等于可请:2 天(4/8 → 4/9)
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'annual', '2030-04-08', '2030-04-09'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 233A3 失败:正好等于可请(2 = 2)应当收下,实得 %', v_msg; END IF;
    v_bal := leave_balance_internal(e_emp, 'annual', DATE '2030-04-01');
    IF (v_bal->>'pending')::numeric <> 6 OR (v_bal->>'bookable')::numeric <> 0 OR (v_bal->>'available')::numeric <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 233A3 失败:两张待批之后应为 available 6 · pending 6 · bookable 0,实为 %', v_bal; END IF;
    -- A4 HR 代录 1 天(4/11)> 0
    v_msg := pg_temp.f233_try(u_hr, pg_temp.f233_submit(e_emp, 'annual', '2030-04-11', '2030-04-11'));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_ACCRUED_LEAVE|0|1' THEN
        RAISE EXCEPTION 'FIXTURE 233A4 失败:HR 代录超额的年假应当被拒 INSUFFICIENT_ACCRUED_LEAVE|0|1,实得 %', v_msg; END IF;

    -- ══════════════ B · 病假(额度 5)══════════════
    -- B1 半天(5/6 一,上午半天)
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'sick', '2030-05-06', '2030-05-06', true));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 233B1 失败:半天病假应当收下,实得 %', v_msg; END IF;
    SELECT days INTO v_n FROM leave_requests WHERE employee_id = e_emp AND leave_type_code = 'sick' AND start_date = '2030-05-06';
    v_bal := leave_balance_internal(e_emp, 'sick', DATE '2030-05-06');
    IF v_n IS DISTINCT FROM 0.5 OR (v_bal->>'pending')::numeric <> 0.5 OR (v_bal->>'bookable')::numeric <> 4.5
       OR NOT (v_bal->>'balance_checked')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 233B1 失败:半天应存 0.5、待批 0.5、可请 4.5、要查余额;实为 days=% 余额 %', v_n, v_bal; END IF;
    -- B2 4 天(5/7 二 → 5/10 五)≤ 4.5
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'sick', '2030-05-07', '2030-05-10'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 233B2 失败:额度内的 4 天病假应当收下,实得 %', v_msg; END IF;
    -- B3 本人自助 1 天(5/13)> 0.5
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'sick', '2030-05-13', '2030-05-13'));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_BALANCE|0.5|1' THEN
        RAISE EXCEPTION 'FIXTURE 233B3 失败:本人自助超额的病假应当被拒 INSUFFICIENT_BALANCE|0.5|1,实得 %', v_msg; END IF;
    -- B4 HR 代录 1 天(5/14)> 0.5
    v_msg := pg_temp.f233_try(u_hr, pg_temp.f233_submit(e_emp, 'sick', '2030-05-14', '2030-05-14'));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_BALANCE|0.5|1' THEN
        RAISE EXCEPTION 'FIXTURE 233B4 失败:HR 代录超额的病假应当被拒 INSUFFICIENT_BALANCE|0.5|1,实得 %', v_msg; END IF;
    -- B5 ★ HR 例外:手填 3 天(5/20)> 0.5 —— 没有口子
    v_msg := pg_temp.f233_try(u_hr, pg_temp.f233_submit(e_emp, 'sick', '2030-05-20', '2030-05-20', false, 3));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_BALANCE|0.5|3' THEN
        RAISE EXCEPTION 'FIXTURE 233B5 失败:HR 例外超额应当照样被拒 INSUFFICIENT_BALANCE|0.5|3(Q11 没有口子),实得 %', v_msg; END IF;

    -- ══════════════ C · 无薪假不查;婴儿看护假(无薪、有额度)查 ══════════════
    -- C1 无薪假 20 天(6/3 一 → 6/28 五)
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'unpaid', '2030-06-03', '2030-06-28'));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 233C1 失败:无薪假没有额度、不查余额,20 天应当收下,实得 %', v_msg; END IF;
    -- C2 婴儿看护假 4 天(7/1 一 → 7/4 四)> 3
    v_msg := pg_temp.f233_try(u_emp, pg_temp.f233_submit(e_emp, 'infant_care', '2030-07-01', '2030-07-04'));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_BALANCE|3|4' THEN
        RAISE EXCEPTION 'FIXTURE 233C2 失败:婴儿看护假有额度,4 天 > 3 应当被拒 INSUFFICIENT_BALANCE|3|4(Q1),实得 %', v_msg; END IF;

    -- ══════════════ D · 审批只扣已批(Q10 Option A)══════════════
    -- 两张待批【直写】(提交时代之前的旧单就是这个形状:各自够、合起来不够)
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by) VALUES
        (p1, 'FX233-P1', e_two, 'annual', DATE '2030-04-01', DATE '2030-04-08', 6, 'pending', u_two),
        (p2, 'FX233-P2', e_two, 'annual', DATE '2030-04-10', DATE '2030-04-11', 2, 'pending', u_two),
        (sa, 'FX233-SA', e_two, 'sick',   DATE '2030-05-06', DATE '2030-05-09', 4, 'pending', u_two),
        (sb, 'FX233-SB', e_two, 'sick',   DATE '2030-05-13', DATE '2030-05-15', 3, 'pending', u_two);
    -- D1 先批 6 天那张:可用 6,另一张 2 天待批【不算】
    v_msg := pg_temp.f233_try(u_apr, format('SELECT decide_leave_request(%L::uuid, true, NULL)', p1));
    IF v_msg <> 'OK' OR (SELECT status FROM leave_requests WHERE id = p1) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 233D1 失败:审批只扣已批,6 天(可用 6,另一张待批不算)应当批得下,实得 %', v_msg; END IF;
    -- D2 后一张:可用 6 − 6 = 0 < 2
    v_msg := pg_temp.f233_try(u_apr, format('SELECT decide_leave_request(%L::uuid, true, NULL)', p2));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_ACCRUED_LEAVE|0|2' OR (SELECT status FROM leave_requests WHERE id = p2) <> 'pending' THEN
        RAISE EXCEPTION 'FIXTURE 233D2 失败:后一张应当在审批时被拒 INSUFFICIENT_ACCRUED_LEAVE|0|2 并留在待批,实得 %', v_msg; END IF;
    -- D3 非年假同一件事:先批 4 天(额度 5,3 天那张待批不算)
    v_msg := pg_temp.f233_try(u_apr, format('SELECT decide_leave_request(%L::uuid, true, NULL)', sa));
    IF v_msg <> 'OK' OR (SELECT status FROM leave_requests WHERE id = sa) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 233D3 失败:病假 4 天(额度 5,另一张待批不算)应当批得下,实得 %', v_msg; END IF;
    -- D4 后一张 3 天:5 − 4 = 1 < 3
    v_msg := pg_temp.f233_try(u_apr, format('SELECT decide_leave_request(%L::uuid, true, NULL)', sb));
    IF v_msg IS DISTINCT FROM 'INSUFFICIENT_BALANCE|1|3' OR (SELECT status FROM leave_requests WHERE id = sb) <> 'pending' THEN
        RAISE EXCEPTION 'FIXTURE 233D4 失败:病假后一张应当在审批时被拒 INSUFFICIENT_BALANCE|1|3,实得 %', v_msg; END IF;

    -- ══════════════ W · 直写被拒(Q12)—— u_hr 持 module.hr.edit ══════════════
    v_msg := pg_temp.f233_try(u_hr, format(
        'INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days) VALUES (%L, %L::uuid, %L, %L::date, %L::date, 1)',
        'FX233-W', e_emp, 'annual', '2030-09-02', '2030-09-02'));
    IF v_msg IS DISTINCT FROM 'permission denied for table leave_requests' THEN
        RAISE EXCEPTION 'FIXTURE 233W1 失败:登录用户直接 INSERT leave_requests 应当 permission denied,实得 %', v_msg; END IF;
    v_msg := pg_temp.f233_try(u_hr, format('UPDATE leave_requests SET status = %L WHERE id = %L::uuid', 'approved', p2));
    IF v_msg IS DISTINCT FROM 'permission denied for table leave_requests'
       OR (SELECT status FROM leave_requests WHERE id = p2) <> 'pending' THEN
        RAISE EXCEPTION 'FIXTURE 233W2 失败:登录用户直接 UPDATE leave_requests 应当 permission denied,实得 %', v_msg; END IF;
    v_msg := pg_temp.f233_try(u_hr, format('DELETE FROM leave_requests WHERE id = %L::uuid', p2));
    IF v_msg IS DISTINCT FROM 'permission denied for table leave_requests' OR NOT EXISTS (SELECT 1 FROM leave_requests WHERE id = p2) THEN
        RAISE EXCEPTION 'FIXTURE 233W3 失败:登录用户直接 DELETE leave_requests 应当 permission denied,实得 %', v_msg; END IF;

    -- ══════════════ M · 名字与姓氏的可见性 = legal_name ══════════════
    UPDATE employees SET first_name = 'Emma', last_name = NULL WHERE id = e_emp;
    v_msg := pg_temp.f233_val(u_hr, format('SELECT first_name || %L || COALESCE(last_name, %L) FROM employees WHERE id = %L::uuid', '/', '∅', e_emp));
    IF v_msg IS DISTINCT FROM 'Emma/∅' THEN
        RAISE EXCEPTION 'FIXTURE 233M1 失败:HR 读基表的 first_name / last_name 应得 Emma/∅(列授权),实得 %', v_msg; END IF;
    v_msg := pg_temp.f233_val(u_hr, format('SELECT first_name || %L || COALESCE(last_name, %L) FROM employees_masked WHERE id = %L::uuid', '/', '∅', e_emp));
    IF v_msg IS DISTINCT FROM 'Emma/∅' THEN
        RAISE EXCEPTION 'FIXTURE 233M1 失败:HR 读 employees_masked 的 first_name / last_name 应得 Emma/∅,实得 %', v_msg; END IF;

    -- ══════════════ N · 个人数据导出与匿名化 ══════════════
    v_msg := pg_temp.f233_val(u_emp, 'SELECT (export_my_personal_data()->''about'')::text');
    v_j := v_msg::jsonb;
    IF v_j->>'first_name' IS DISTINCT FROM 'Emma' OR NOT (v_j ? 'last_name') OR v_j->>'last_name' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 233N1 失败:导出应带 first_name = Emma 与一个值为 null 的 last_name 键,实得 %', v_msg; END IF;

    UPDATE hr_settings SET personal_data_retention_months = 12;
    PERFORM pg_temp.f233_as(u_hr);
    PERFORM anonymise_employee(e_gone, 'fixture 233: retention elapsed');
    IF (SELECT first_name FROM employees WHERE id = e_gone) IS NOT NULL
       OR (SELECT last_name FROM employees WHERE id = e_gone) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 233N2 失败:anonymise_employee 应当把 first_name / last_name 清成 NULL,实为 % / %',
            (SELECT first_name FROM employees WHERE id = e_gone), (SELECT last_name FROM employees WHERE id = e_gone); END IF;

    RAISE NOTICE 'FIXTURE 233 全部通过:提交扣待批、审批只扣已批;11 个有额度的假别都查、无薪假不查;例外没有口子;直写被拒;名字与姓氏的读、导出、匿名化';
END $$;

ROLLBACK;

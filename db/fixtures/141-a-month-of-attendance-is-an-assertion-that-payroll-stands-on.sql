-- 141 考勤:一个月的底稿是【一句断言】,而工资过账站在它上面(ATTEND-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉六件事】
--   · **"没人记过"与"记了、是零"是两件事** —— 判据是 recorded_at,不是
--     "工时加起来是不是 0"。把这两件事混起来,就等于把【缺勤未知】当成
--     【全勤】送进工资单,而那是这一刀存在的全部理由。
--   · **一句容得下空白的"完成"是勾选框,不是断言** —— 完成必须按名拒,
--     并且说得出【还差几行】,而那个数必须对得上。
--   · **先补名单,再判完整** —— 顺序反过来,就会有一份"声称完整"却少了
--     月中入职者的底稿,而那句断言恰恰在这种时候才要紧。
--   · **无薪假是【筛出来的推导】,不是重记** —— 只认 unpaid 且 approved;
--     半天标记只在裁剪之后仍是原端点时才成立。
--   · **完成之后冻住** —— 请假单事后被取消,底稿仍说得出我们当时报了什么。
--   · **工资过账要有依据,而且是【那个月的】依据** —— 拒绝必须绑在
--     period_month 上;"库里有一个完成了的月份"不算数。
--
-- ★【两个反复出现的陷阱,这份 fixture 都刻意躲开】★
--   ① 靠"两个实现碰巧一致"通过:半天那一臂(F)不比"两个数相等",它比
--      【把标记原样透传下去会得到一个不同的数】—— 而那个不同必须先被证明。
--   ② 断言被计数写死:A 臂一个数都不写死,它比的是【谁在册谁有行】,
--      因为线上与重建库的员工总数本就不同(README 第 2 条)。
--
-- 自带数据(README 第 2 条);期间锁自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_uid    uuid := gen_random_uuid();
    r_all    uuid;
    v_m      date;   -- 上个月:主战场
    v_m2     date;   -- 上上个月:工资过账那一臂用
    v_end    date;
    v_e1 uuid; v_e2 uuid; v_e3 uuid; v_e4 uuid; v_e5 uuid;
    v_res    jsonb; v_pid uuid; v_pid2 uuid; v_line uuid; v_lv uuid;
    v_pay    uuid; v_pl uuid;
    r        record;
    v_msg    text; v_missing int; v_n int;
    v_days numeric; v_frozen numeric; v_live numeric;
    v_full numeric; v_naive numeric; v_want numeric;
    v_rec timestamptz; v_view numeric; v_posted boolean;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_uid);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-141', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;
    -- 【月份是【找】出来的,不写死,也不靠清场】
    -- ① 写死任何一个月都不行:线上是模拟时间(日期读作 2026,真实日历是
    --    2025 年 12 月),重建库跑在真实时间上,同一个常量会在一边变成
    --    "还没到的月份"而撞上 ATTENDANCE_MONTH_FUTURE。
    -- ② 而"上个月"也不行:payroll_posted 那一栏问的是【这个月有没有已过账
    --    的工资】,线上上个月恰好就有一张(PAY-2026-0001)。于是"我没建
    --    工资单所以该是 false"会在线上是假的 —— 一句【继承了时点状态】的断言。
    -- ③ 清场更不行:guard_payroll_period_delete 正确地拒绝软删一张已过账的
    --    工资单 —— 那道守卫是对的,不该为了测试绕过它。
    -- 于是往回找:找到连着两个【既没有工资单、也没有考勤底稿】的月份。
    -- 找不到就按名失败 —— 一个悄悄空转的前提比一次失败坏得多。
    v_m := NULL;
    FOR v_n IN 1..24 LOOP
        v_m2 := (date_trunc('month', CURRENT_DATE) - make_interval(months => v_n + 1))::date;
        IF NOT EXISTS (SELECT 1 FROM payroll_periods pp
                        WHERE date_trunc('month', pp.period_month)::date
                              IN (v_m2, (v_m2 + interval '1 month')::date))
           AND NOT EXISTS (SELECT 1 FROM attendance_periods ap
                            WHERE ap.period_month IN (v_m2, (v_m2 + interval '1 month')::date))
        THEN
            v_m := (v_m2 + interval '1 month')::date;
            EXIT;
        END IF;
    END LOOP;
    IF v_m IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 141 前提不成立:往回 24 个月都找不到连着两个没有工资单、也没有考勤底稿的月份';
    END IF;
    v_end := (v_m + interval '1 month - 1 day')::date;

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('FIXT-E141-1', 'Fixture 141 Early',   'full_time', 'office', (v_m2 - 60))
    RETURNING id INTO v_e1;
    -- 月中入职:开期间的时候就该被铺进去(hire_date <= 月末)
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('FIXT-E141-2', 'Fixture 141 MidHire', 'full_time', 'office', (v_m + 14))
    RETURNING id INTO v_e2;
    -- 这个月【之前】就离职:不该有行
    INSERT INTO employees (code, legal_name, employment_type, work_category,
                           hire_date, employment_status, separation_date)
    VALUES ('FIXT-E141-3', 'Fixture 141 Gone',    'full_time', 'office',
            (v_m2 - 60), 'separated', (v_m - 1))
    RETURNING id INTO v_e3;
    -- 这个月【之后】才入职:不该有行
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('FIXT-E141-4', 'Fixture 141 Future',  'full_time', 'office', (v_end + 1))
    RETURNING id INTO v_e4;

    -- ══════════════════ A ══════════════════
    -- 【谁在这个月里在册过,谁就有一行】—— 一个数都不写死
    v_res := open_attendance_period(v_m);
    v_pid := (v_res->>'period_id')::uuid;

    IF NOT EXISTS (SELECT 1 FROM attendance_lines WHERE period_id = v_pid AND employee_id = v_e1) THEN
        RAISE EXCEPTION 'FIXTURE 141-A 失败:整月在册的人没有行';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM attendance_lines WHERE period_id = v_pid AND employee_id = v_e2) THEN
        RAISE EXCEPTION 'FIXTURE 141-A 失败:★月中入职的人没有行★ —— 而工资照样要发给他';
    END IF;
    IF EXISTS (SELECT 1 FROM attendance_lines WHERE period_id = v_pid AND employee_id = v_e3) THEN
        RAISE EXCEPTION 'FIXTURE 141-A 失败:这个月之前就离职的人被铺了一行';
    END IF;
    IF EXISTS (SELECT 1 FROM attendance_lines WHERE period_id = v_pid AND employee_id = v_e4) THEN
        RAISE EXCEPTION 'FIXTURE 141-A 失败:这个月之后才入职的人被铺了一行';
    END IF;
    -- 非空转:这一臂比的是"有 / 没有",所以至少要真的有两行
    SELECT count(*) INTO v_n FROM attendance_lines WHERE period_id = v_pid;
    IF v_n < 2 THEN
        RAISE EXCEPTION 'FIXTURE 141-A 失败:只铺出 % 行 —— 上面四条判断有一半是空转的', v_n;
    END IF;
    -- 刚铺出来的每一行都必须是【没人记过】
    SELECT count(*) INTO v_n FROM attendance_lines
     WHERE period_id = v_pid AND recorded_at IS NOT NULL;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 141-A 失败:刚开的期间里有 % 行已经带着 recorded_at', v_n;
    END IF;

    -- ══════════════════ B ══════════════════
    -- ★【三个 0 也是一次记录】★ —— 判据是 recorded_at,不是工时之和
    SELECT id INTO v_line FROM attendance_lines WHERE period_id = v_pid AND employee_id = v_e1;
    PERFORM record_attendance(v_line);          -- 三个默认 0
    SELECT recorded_at INTO v_rec FROM attendance_lines WHERE id = v_line;
    IF v_rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 141-B 失败:记了三个 0 之后 recorded_at 仍是 NULL —— "记了是零"与"没人记过"被混成了一件事';
    END IF;
    SELECT ot_normal_hours + ot_rest_day_hours + ot_public_holiday_hours
      INTO v_days FROM attendance_lines WHERE id = v_line;
    IF v_days <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 141-B 失败:三个 0 记完之后工时之和是 % —— 这一臂要的正是"和为 0 却已被记录"', v_days;
    END IF;

    -- ══════════════════ C ══════════════════
    -- 【还有没记的就拒,而且那个数必须对得上】
    SELECT count(*) INTO v_missing FROM attendance_lines
     WHERE period_id = v_pid AND recorded_at IS NULL;
    IF v_missing = 0 THEN
        RAISE EXCEPTION 'FIXTURE 141-C 失败:此刻不该已经记满 —— 这一臂空转了';
    END IF;
    BEGIN
        PERFORM complete_attendance_period(v_pid);
        RAISE EXCEPTION 'FIXTURE 141-C 失败:还有 % 行没人记,完成却通过了 —— 一个容得下空白的"完成"是勾选框,不是断言', v_missing;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'ATTENDANCE_PERIOD_INCOMPLETE|%' THEN RAISE; END IF;
        IF split_part(v_msg, '|', 3) <> v_missing::text THEN
            RAISE EXCEPTION 'FIXTURE 141-C 失败:拒绝里说还差 %,实际还差 % —— 一句说不准数目的拒绝会被当成噪音',
                split_part(v_msg, '|', 3), v_missing;
        END IF;
    END;

    -- ══════════════════ D ══════════════════
    -- 【先补名单,再判完整】—— 期间开完之后才入职的人
    FOR r IN SELECT id FROM attendance_lines WHERE period_id = v_pid AND recorded_at IS NULL LOOP
        PERFORM record_attendance(r.id, 2, 0, 0);
    END LOOP;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('FIXT-E141-5', 'Fixture 141 LateJoin', 'full_time', 'office', (v_m + 20))
    RETURNING id INTO v_e5;
    -- 此刻【已铺出来的行】全部记满了,唯一的缺口是这个还没铺的人
    BEGIN
        PERFORM complete_attendance_period(v_pid);
        RAISE EXCEPTION 'FIXTURE 141-D 失败:期间开完之后入职的人没有被补进来 —— 一份"声称完整"却少了人的底稿';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'ATTENDANCE_PERIOD_INCOMPLETE|%' THEN RAISE; END IF;
        IF split_part(v_msg, '|', 3) <> '1' THEN
            RAISE EXCEPTION 'FIXTURE 141-D 失败:该差 1 行(新补进来的那个人),拒绝却说差 %', split_part(v_msg, '|', 3);
        END IF;
    END;
    -- ★【拒绝把它自己补出来的那一行也回滚掉了】★ —— 这不是缺陷,是
    -- PostgreSQL 的语句语义;而正因如此,补名单必须【另有一条自己提交的路】,
    -- 否则操作员会被告知"还差 1 行",屏幕上却根本没有那一行可记 ——
    -- 一条无法被满足的拒绝不是守卫,是死锁。
    IF EXISTS (SELECT 1 FROM attendance_lines WHERE period_id = v_pid AND employee_id = v_e5) THEN
        RAISE EXCEPTION 'FIXTURE 141-D 失败:那一行竟然在拒绝之后活了下来 —— 下面这半臂(sync 存在的理由)就成了空转';
    END IF;
    v_res := sync_attendance_period(v_pid);
    IF (v_res->>'lines_added')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 141-D 失败:sync 该补出 1 行,实得 %', v_res->>'lines_added';
    END IF;
    SELECT id INTO v_line FROM attendance_lines WHERE period_id = v_pid AND employee_id = v_e5;
    IF v_line IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 141-D 失败:sync 报了 1 行,那个人却还是没有行';
    END IF;
    -- 而【安全网仍在】:就算没人调过 sync,complete 也漏不掉这个人 ——
    -- 上面那次拒绝本身就是证据(它是在 complete 内部补完之后才数出来的)。

    -- ══════════════════ E ══════════════════
    -- 【无薪假是筛出来的】:只认 unpaid 且 approved
    -- 三张单子,只有第一张该被数进去
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days, status, reason)
    VALUES ('FIXT-LV141-A', v_e1, 'unpaid', v_m + 6, v_m + 8,
            calculate_leave_days(v_m + 6, v_m + 8), 'approved', 'f141')
    RETURNING id INTO v_lv;
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days, status, reason)
    VALUES ('FIXT-LV141-B', v_e1, 'unpaid', v_m + 13, v_m + 15,
            calculate_leave_days(v_m + 13, v_m + 15), 'pending', 'f141'),
           ('FIXT-LV141-C', v_e1, 'annual', v_m + 20, v_m + 22,
            calculate_leave_days(v_m + 20, v_m + 22), 'approved', 'f141');
    v_want := calculate_leave_days(v_m + 6, v_m + 8);
    IF v_want <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 141-E 失败:那三天一个工作日都不是 —— 这一臂空转了';
    END IF;
    v_days := attendance_unpaid_days(v_e1, v_m);
    IF v_days <> v_want THEN
        RAISE EXCEPTION 'FIXTURE 141-E 失败:无薪假天数应为 %(只认 unpaid 且 approved 的那一张),实得 %', v_want, v_days;
    END IF;

    -- ══════════════════ F ══════════════════
    -- ★【半天标记只在裁剪之后仍是原端点时才成立】★
    -- 跨月请假:起点在上上个月(会被裁掉),终点在本月内(是原端点)。
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date,
                                start_half_day, end_half_day, days, status, reason)
    VALUES ('FIXT-LV141-D', v_e2, 'unpaid', v_m - 5, v_m + 2, true, true,
            calculate_leave_days(v_m - 5, v_m + 2, true, true), 'approved', 'f141');
    v_want  := calculate_leave_days(v_m, v_m + 2, false, true);  -- 起点半天【不】成立
    v_naive := calculate_leave_days(v_m, v_m + 2, true,  true);  -- 把标记原样透传下去
    v_full  := calculate_leave_days(v_m - 5, v_m + 2, true, true);
    IF v_want = v_naive THEN
        RAISE EXCEPTION 'FIXTURE 141-F 失败:透传与不透传得到同一个数(%) —— 这一臂分辨不出两个实现', v_want;
    END IF;
    IF v_full <= v_want THEN
        RAISE EXCEPTION 'FIXTURE 141-F 失败:整段(%)没有比裁剪后(%)更长 —— 裁剪什么都没做', v_full, v_want;
    END IF;
    v_days := attendance_unpaid_days(v_e2, v_m);
    IF v_days <> v_want THEN
        RAISE EXCEPTION 'FIXTURE 141-F 失败:跨月裁剪后应为 %,实得 %(透传写法会得到 %,整段是 %)',
            v_want, v_days, v_naive, v_full;
    END IF;

    -- ══════════════════ G ══════════════════
    -- 【完成之后冻住】—— 请假单事后被取消,底稿仍说得出当时报了什么
    PERFORM record_attendance(v_line, 0, 4, 0);      -- 把 D 臂补出来的那行记掉
    v_res := complete_attendance_period(v_pid);
    IF (v_res->>'status') <> 'complete' THEN
        RAISE EXCEPTION 'FIXTURE 141-G 失败:记满之后仍然完成不了';
    END IF;
    SELECT unpaid_days INTO v_frozen FROM attendance_lines
     WHERE period_id = v_pid AND employee_id = v_e1;
    IF v_frozen IS NULL OR v_frozen <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 141-G 失败:冻下来的无薪假天数是 % —— 这一臂空转了', v_frozen;
    END IF;
    UPDATE leave_requests SET status = 'cancelled' WHERE id = v_lv;
    v_live := attendance_unpaid_days(v_e1, v_m);
    IF v_live = v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 141-G 失败:取消之后实时推导仍是 % —— "冻住"与"实时"没有分开过,这一臂证明不了任何事', v_live;
    END IF;
    SELECT unpaid_days INTO v_days FROM attendance_lines
     WHERE period_id = v_pid AND employee_id = v_e1;
    IF v_days <> v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 141-G 失败:请假单一取消,已完成的底稿就跟着变了(% → %) —— 我们再也说不出当时报的是什么', v_frozen, v_days;
    END IF;

    -- ══════════════════ H ══════════════════
    -- 【完成之后不许再记】:那份底稿【就是】我们报出去的东西
    BEGIN
        PERFORM record_attendance(v_line, 99, 0, 0);
        RAISE EXCEPTION 'FIXTURE 141-H 失败:已完成的期间还能改工时';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'ATTENDANCE_PERIOD_NOT_OPEN|%' THEN RAISE; END IF;
    END;

    -- ══════════════════ I ══════════════════
    -- 三道小拒绝:未来的月份不开 / 一个月只有一份底稿 / 负工时不收
    BEGIN
        PERFORM open_attendance_period((date_trunc('month', CURRENT_DATE) + interval '1 month')::date);
        RAISE EXCEPTION 'FIXTURE 141-I 失败:还没到的月份也开得出来 —— 而它不可能是完整的';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'ATTENDANCE_MONTH_FUTURE|%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM open_attendance_period(v_m + 10);   -- 同一个月,不同的日子
        RAISE EXCEPTION 'FIXTURE 141-I 失败:同一个月开出了第二份底稿';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'ATTENDANCE_PERIOD_EXISTS|%' THEN RAISE; END IF;
    END;

    -- ══════════════════ J ══════════════════
    -- ★【工资过账要有依据,而且是【那个月的】依据】★
    -- 此刻 v_m 是 complete,而工资单是 v_m2 的 —— "库里有一个完成了的月份"不算数
    INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate,
                                 status, gross_total, net_pay_total)
    VALUES ('FIXT-PAY141', v_m2, (v_m2 + interval '1 month')::date + 6, 'SGD', 1,
            'draft', 3000, 2500)
    RETURNING id INTO v_pay;
    INSERT INTO payroll_lines (payroll_period_id, employee_id, gross_pay, net_pay)
    VALUES (v_pay, v_e1, 3000, 2500) RETURNING id INTO v_pl;

    IF NOT EXISTS (SELECT 1 FROM attendance_periods WHERE period_month = v_m AND status = 'complete') THEN
        RAISE EXCEPTION 'FIXTURE 141-J 失败:另一个月并不是 complete —— 这一臂分辨不出"任意一个"与"那一个"';
    END IF;
    BEGIN
        PERFORM post_payroll_period(v_pay);
        RAISE EXCEPTION 'FIXTURE 141-J 失败:那个月的底稿没人说过它齐全,工资却过账了 —— 缺勤未知被当成了全勤';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'PAYROLL_ATTENDANCE_NOT_COMPLETE|%' THEN RAISE; END IF;
        IF split_part(v_msg, '|', 3) <> to_char(v_m2, 'YYYY-MM') THEN
            RAISE EXCEPTION 'FIXTURE 141-J 失败:拒绝里点的月份是 %,工资单却是 %',
                split_part(v_msg, '|', 3), to_char(v_m2, 'YYYY-MM');
        END IF;
    END;

    -- 把 v_m2 也做齐,同一次调用必须【通过】—— 否则上面的拒绝可能来自别处
    v_res := open_attendance_period(v_m2);
    v_pid2 := (v_res->>'period_id')::uuid;
    FOR r IN SELECT id FROM attendance_lines WHERE period_id = v_pid2 LOOP
        PERFORM record_attendance(r.id);
    END LOOP;
    PERFORM complete_attendance_period(v_pid2);
    v_res := post_payroll_period(v_pay);
    IF (v_res->>'journal_code') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 141-J 失败:底稿做齐之后工资仍然过不了账 —— 这道拒绝拦住的不止是它该拦的';
    END IF;
    SELECT payroll_posted INTO v_posted FROM attendance_period_status WHERE period_id = v_pid2;
    IF NOT v_posted THEN
        RAISE EXCEPTION 'FIXTURE 141-J 失败:工资刚过完账,视图却说这个月没有过账的工资 —— 而重开那道拒绝正压在这一栏上';
    END IF;

    -- ══════════════════ K ══════════════════
    -- 【已过账的那个月不许重开】,而 unpost 之后可以 —— 但必须给理由
    BEGIN
        PERFORM reopen_attendance_period(v_pid2, '改一改');
        RAISE EXCEPTION 'FIXTURE 141-K 失败:一张已过账工资单的依据可以在它脚下被改动';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL|%' THEN RAISE; END IF;
    END;
    PERFORM unpost_payroll_period(v_pay, 'fixture 141');
    BEGIN
        PERFORM reopen_attendance_period(v_pid2, '   ');
        RAISE EXCEPTION 'FIXTURE 141-K 失败:不给理由也能重开 —— 那条改动就成了无主的';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'ATTENDANCE_REOPEN_REASON_REQUIRED|%' THEN RAISE; END IF;
    END;
    v_res := reopen_attendance_period(v_pid2, '服务商退回了一条加班工时');
    IF (v_res->>'status') <> 'open' THEN
        RAISE EXCEPTION 'FIXTURE 141-K 失败:撤销过账之后仍然重开不了 —— 那条"先 unpost"的路走不通';
    END IF;
    SELECT reopen_reason INTO v_msg FROM attendance_periods WHERE id = v_pid2;
    IF v_msg IS NULL OR btrim(v_msg) = '' THEN
        RAISE EXCEPTION 'FIXTURE 141-K 失败:重开了,理由却没留下来';
    END IF;

    -- ══════════════════ L ══════════════════
    -- 【视图两条分支都要走到】已完成的读【冻下来的】,还开着的读【此刻的】。
    -- 视图是按期间汇总的,所以这里比的是【整个期间的合计】,不是某一个人。
    SELECT COALESCE(sum(al.unpaid_days), 0),
           COALESCE(sum(attendance_unpaid_days(al.employee_id, v_m)), 0)
      INTO v_frozen, v_live
      FROM attendance_lines al WHERE al.period_id = v_pid;
    IF v_frozen = v_live THEN
        RAISE EXCEPTION 'FIXTURE 141-L 失败:冻下来的合计与此刻推导的合计都是 % —— 两条分支分辨不开,这一臂空转', v_frozen;
    END IF;
    SELECT unpaid_days, payroll_posted INTO v_view, v_posted
      FROM attendance_period_status WHERE period_id = v_pid;      -- complete
    IF v_view <> v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 141-L 失败:已完成的月份,视图报 %,冻下来的是 %(此刻推导是 %) —— 屏幕说的不是我们报出去的那份',
            v_view, v_frozen, v_live;
    END IF;
    IF v_posted THEN
        RAISE EXCEPTION 'FIXTURE 141-L 失败:这个月没有过账的工资,视图却说有';
    END IF;

    -- 另一条分支:v_pid2 在 K 臂里被重开了,此刻是 open。给它添一张【冻之后
    -- 才批的】无薪假 —— 冻下来的是 0,此刻推导不是 0,视图必须报后者。
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days, status, reason)
    VALUES ('FIXT-LV141-E', v_e1, 'unpaid', v_m2 + 6, v_m2 + 8,
            calculate_leave_days(v_m2 + 6, v_m2 + 8), 'approved', 'f141');
    SELECT COALESCE(sum(al.unpaid_days), 0),
           COALESCE(sum(attendance_unpaid_days(al.employee_id, v_m2)), 0)
      INTO v_frozen, v_live
      FROM attendance_lines al WHERE al.period_id = v_pid2;
    IF v_frozen = v_live THEN
        RAISE EXCEPTION 'FIXTURE 141-L 失败:open 那一侧两条分支同值(%) —— 这半臂空转', v_frozen;
    END IF;
    SELECT unpaid_days INTO v_view FROM attendance_period_status WHERE period_id = v_pid2;
    IF v_view <> v_live THEN
        RAISE EXCEPTION 'FIXTURE 141-L 失败:还开着的月份,视图报 %,此刻推导是 %(冻下来的是 %) —— 一个还没定稿的月份被当成定稿的读了',
            v_view, v_live, v_frozen;
    END IF;
    SELECT unrecorded_count INTO v_n FROM attendance_period_status WHERE period_id = v_pid2;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 141-L 失败:v_m2 的行全部记过,视图却说还有 % 行没记', v_n;
    END IF;
END $$;
ROLLBACK;

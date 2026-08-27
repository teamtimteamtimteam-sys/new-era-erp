-- 136 试用期转正:这条路【从产品内部走得通】,而且一路走到员工档案上(PROBATION-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉的是一件曾经【一步都走不了】的事】REVIEW-SURVEY 测出来:
-- 试用期评估的下游全部建好了,而【没有任何东西造得出那一行】——
-- open_review_cycle 只造 annual 且排除试用期员工,cycle_shape 让它结构上也造不出,
-- app 里没有一处 INSERT performance_reviews。**冒烟必须直接 POST 到 REST 才测得了页面。**
--
-- 所以本 fixture 的形状与别的不同:它不是断言某一条规则,
-- **它把整条链从头走到尾,并在每一步断言"这一步真的改变了什么"。**
-- 一条链上任何一环变成空操作,都必须让它红 —— 而"空操作"正是这条链的历史病症。
--
-- ★【每一臂如何做到【按构造】非空】★
--   每一步都先取状态、执行、再取状态,断言【两者不同】,而不是只断言终态。
--   只断言终态的写法,在"这一步本来就是那个值"时会安静地通过 ——
--   而这正是一条没有门的链看起来的样子。
--
-- 自带数据(README 第 2 条);评级表、期间锁自己设(第 4/5 条)。
-- 日期一律相对 CURRENT_DATE:hr_alerts 的两支要落在【到期前 30 天】与【已过期】
-- 两个窗口里,写死日期会在某一天悄悄滑出窗口(README 第 4 条的反面用法 ——
-- 这里【必须】相对,因为被测的正是那个窗口)。
-- 注意 employees_probation_cap:probation_end_date ≤ hire_date + 3 个月。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_hr1   uuid := gen_random_uuid();   -- 提交的人
    v_hr2   uuid := gen_random_uuid();   -- 批准的人(四眼:批准人不能是提交人)
    v_subu  uuid := gen_random_uuid();   -- 被评估人自己的账号(写自评要用)
    r_all   uuid;
    v_dept  uuid; v_mgr uuid; v_sub uuid; v_sub2 uuid; v_other uuid;
    v_rev   uuid; v_goal uuid; v_res jsonb;
    d_hire  date := CURRENT_DATE - 60;
    d_end   date := CURRENT_DATE + 10;   -- 到期前 30 天窗口内 → probation_ending 会响
    v_n int; v_n2 int; v_msg text; v_denied boolean;
    v_status text; v_status2 text; v_rid uuid;
    v_conf_before date; v_conf_after date;
    v_es_before text;  v_es_after text;
    v_hist_before int;  v_hist_after int;
    v_reviewer uuid; v_ps date; v_pe date; v_cycle uuid;
    v_txt text;
BEGIN
    -- ══════════════════ 布景 ══════════════════
    -- 【真的账号】`employees.user_id` 有指向 auth.users 的外键
    -- (`employees_user_id_fkey`,ON DELETE SET NULL)。README 第 80 行那句
    -- 「没有指向 auth.users 的外键」说的是 `user_roles.user_id` —— 那一条仍然成立,
    -- 但 employees 这一侧【有】,所以写自评的那个人必须是一个真的账号。
    -- 同一惯用法见 fixture 126 / 127 / 35。
    INSERT INTO auth.users (id) VALUES (v_hr1), (v_hr2), (v_subu);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-136', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_hr1, r_all), (v_hr2, r_all), (v_subu, r_all);

    UPDATE finance_settings SET locked_before = NULL;

    -- 自己的评级表一行(引导表里的四行是运行时可改的 —— README 第 5 条)
    INSERT INTO review_rating_scale (code, name_en, name_zh, sort_order, is_probation_pass)
    VALUES ('FIXT-PASS-136', 'Fixture Pass 136', '测试合格 136', 936, true);

    -- 部门 + 部门经理 —— 评估人三级解析的第一级要能解析得出来,
    -- 否则 A 臂里"评估人被解析出来了"会因为【没有经理】而假绿。
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
    VALUES ('ZZ-F136-MGR', 'fixture 136 manager', 'full_time', 'office', CURRENT_DATE - 400)
    RETURNING id INTO v_mgr;
    INSERT INTO departments (code, name_en, name_zh, is_active, manager_employee_id)
    VALUES ('ZZ-F136-D', 'fixture 136 dept', '测试部门 136', true, v_mgr)
    RETURNING id INTO v_dept;

    -- 被评估人:在试用期,入职日与到期日都填好
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, probation_end_date, department_id, user_id)
    VALUES ('ZZ-F136-SUB', 'fixture 136 subject', 'full_time', 'office', d_hire,
            'probation', d_end, v_dept, v_subu)
    RETURNING id INTO v_sub;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_hr1), true);

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 门造得出那一行,而且【形状是对的】
    -- 期间必须来自【员工档案上的两个日期】,不是今天 —— 那正是"替人编一个
    -- 试用期终点"会留下的痕迹。
    -- ══════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM performance_reviews WHERE employee_id = v_sub;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 136A 布景不成立:开始前这个人不该有任何评估,实得 % 份', v_n;
    END IF;

    v_res := open_probation_review(v_sub);
    v_rev := (v_res->>'review_id')::uuid;

    SELECT count(*) INTO v_n2 FROM performance_reviews WHERE employee_id = v_sub;
    IF v_n2 <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:门应当【恰好】造出一份评估,实得 % 份', v_n2;
    END IF;
    -- ★ 自证非空:前后必须不同,否则这一臂对着一个本来就存在的行也会绿
    IF v_n = v_n2 THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败(空转):调用前后评估份数相同 —— 这扇门什么也没造出来';
    END IF;

    SELECT review_type, cycle_id, period_start, period_end, reviewer_employee_id, status
      INTO v_txt, v_cycle, v_ps, v_pe, v_reviewer, v_status
      FROM performance_reviews WHERE id = v_rev;

    IF v_txt <> 'probation' THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:review_type 应为 probation,实得 %', v_txt;
    END IF;
    -- cycle_shape:probation ⇒ cycle_id IS NULL。这正是"它不是 annual 的变体"那句话。
    IF v_cycle IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:试用期评估不该挂在评估轮上(cycle_shape),实得 %', v_cycle;
    END IF;
    IF v_ps IS DISTINCT FROM d_hire OR v_pe IS DISTINCT FROM d_end THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:期间应为 % → %(取自员工档案),实得 % → %',
            d_hire, d_end, v_ps, v_pe;
    END IF;
    -- ★ 而且它【不能】是今天:一个用 CURRENT_DATE 顶上去的实现会在这里露出来
    IF v_ps = CURRENT_DATE OR v_pe = CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:期间落在今天 —— 这是替人编日期的痕迹,而不是读档案';
    END IF;
    IF v_reviewer IS DISTINCT FROM v_mgr THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:评估人应解析为部门经理,实得 %',
            COALESCE(v_reviewer::text, '(NULL)');
    END IF;
    IF (v_res->>'reviewer_resolved')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:返回值应如实报出评估人已解析';
    END IF;
    IF v_status <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 136A 失败:新建的评估应为 draft,实得 %', v_status;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · 门【不是】一扇随便谁都推得开的门 —— 五条按名拒绝
    -- ══════════════════════════════════════════════════════════════════════
    -- ① 已经有一份非作废的 → 按名拒(而不是让唯一索引抛 23505)
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM open_probation_review(v_sub);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('PROBATION_REVIEW_EXISTS' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 136B① 失败:重复发起必须按名拒(PROBATION_REVIEW_EXISTS),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- ② 不在试用期的人
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status)
    VALUES ('ZZ-F136-ACT', 'fixture 136 active', 'full_time', 'office', CURRENT_DATE - 300, 'active')
    RETURNING id INTO v_other;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM open_probation_review(v_other);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('EMPLOYEE_NOT_ON_PROBATION' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 136B② 失败:对已转正的人必须按名拒(EMPLOYEE_NOT_ON_PROBATION),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- ③ 【到期日没填】—— 实测线上 4 个试用期员工全都是这样,所以这一条不是假想
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, probation_end_date)
    VALUES ('ZZ-F136-NOD', 'fixture 136 no end date', 'full_time', 'office', CURRENT_DATE - 30,
            'probation', NULL)
    RETURNING id INTO v_sub2;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM open_probation_review(v_sub2);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('PROBATION_END_DATE_NOT_SET' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 136B③ 失败:到期日为空必须按名拒(PROBATION_END_DATE_NOT_SET),实得:% —— 一个用今天顶上去的实现会在这里通过',
            COALESCE(v_msg, '(通过了)');
    END IF;
    -- ★ 而且它【什么都没写】:拒绝要是先写后回滚,这一条就只是运气
    SELECT count(*) INTO v_n FROM performance_reviews WHERE employee_id = v_sub2;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 136B③ 失败:被拒之后不该留下任何评估行,实得 % 份', v_n;
    END IF;

    -- ④ 查无此人
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM open_probation_review(gen_random_uuid());
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('EMPLOYEE_NOT_FOUND' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 136B④ 失败:查无此人必须按名拒(EMPLOYEE_NOT_FOUND),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · 新门【不通向另一个死胡同】—— GOALS_REQUIRED 仍然咬,而目标加得进去
    --
    -- 这一臂是本刀的自我怀疑:装了一扇门,而门后是一堵墙,等于什么都没做。
    -- ══════════════════════════════════════════════════════════════════════
    UPDATE performance_reviews SET probation_outcome = 'confirm' WHERE id = v_rev;
    PERFORM set_review_conclusion(v_rev, 'FIXT-PASS-136', 'fixture 136 conclusion');

    -- 零目标时提交必须按名拒
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_review(v_rev);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('GOALS_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 136C 失败:零目标提交必须按名拒(GOALS_REQUIRED),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- 而目标【加得进去】—— 否则上面那条拒绝就是一堵墙,不是一道闸
    v_res := add_review_goal(v_rev, 'fixture 136 objective', 10, 'units');
    v_goal := (v_res->>'goal_id')::uuid;
    SELECT count(*) INTO v_n FROM review_goals WHERE review_id = v_rev;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 136C 失败:目标应当加得进去(1 条),实得 % —— 门后是一堵墙', v_n;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · 自评那一段真的走得通,而且【真的写进去了】
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM open_for_self_assessment(v_rev);
    SELECT status INTO v_status FROM performance_reviews WHERE id = v_rev;
    IF v_status <> 'self_review' THEN
        RAISE EXCEPTION 'FIXTURE 136D 失败:开自评之后状态应为 self_review,实得 %', v_status;
    END IF;

    -- 换成【被评估人本人】写自评 —— 这支函数是全仓库唯一不带"或有权限"那半句的
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_subu), true);
    SELECT self_assessment_text INTO v_txt FROM performance_reviews WHERE id = v_rev;
    IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 136D 布景不成立:写之前自评应为空,实得 %', v_txt;
    END IF;
    PERFORM save_self_assessment(v_rev, 'fixture 136 self assessment',
        jsonb_build_array(jsonb_build_object('goal_id', v_goal,
                                             'result_text', 'fixture 136 result',
                                             'actual_value', 9)), false);
    SELECT self_assessment_text INTO v_txt FROM performance_reviews WHERE id = v_rev;
    IF v_txt IS DISTINCT FROM 'fixture 136 self assessment' THEN
        RAISE EXCEPTION 'FIXTURE 136D 失败:自评正文没有落到库里,实得 %', COALESCE(v_txt,'(NULL)');
    END IF;
    SELECT count(*) INTO v_n FROM review_goals
     WHERE id = v_goal AND employee_result_text = 'fixture 136 result' AND actual_value = 9;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 136D 失败:自评的结果与实际值没有写到目标上';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · 提交 → 批准,四眼由【函数】兑现,不只是界面上少一个按钮
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_hr1), true);
    PERFORM submit_review(v_rev);
    SELECT status INTO v_status FROM performance_reviews WHERE id = v_rev;
    IF v_status <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 136E 失败:提交之后状态应为 submitted,实得 %', v_status;
    END IF;

    -- 提交人自己批准 → 必须按名拒(四眼)
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM approve_review(v_rev);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR position('SELF_APPROVAL_FORBIDDEN' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 136E 失败:提交人自批必须按名拒(SELF_APPROVAL_FORBIDDEN),实得:%',
            COALESCE(v_msg, '(通过了)');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 ·【转正真的写到了员工档案上】—— 本刀的终点,也是它的全部意义
    --
    -- 只断言"函数返回了"是不够的:approve_review 的转正分支若一行都不改,
    -- 它照样返回。所以这里取【三个】改动之前的值,批准之后逐个断言它们变了。
    -- ══════════════════════════════════════════════════════════════════════
    SELECT confirmation_date, employment_status INTO v_conf_before, v_es_before
      FROM employees WHERE id = v_sub;
    SELECT count(*) INTO v_hist_before FROM employment_history
     WHERE employee_id = v_sub AND change_type = 'confirmed';

    IF v_conf_before IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 136F 布景不成立:批准前转正日应为空,实得 %', v_conf_before;
    END IF;
    IF v_es_before <> 'probation' THEN
        RAISE EXCEPTION 'FIXTURE 136F 布景不成立:批准前应仍在试用期,实得 %', v_es_before;
    END IF;

    -- 换第二个人批准(四眼)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_hr2), true);
    PERFORM approve_review(v_rev);

    SELECT confirmation_date, employment_status INTO v_conf_after, v_es_after
      FROM employees WHERE id = v_sub;
    SELECT count(*) INTO v_hist_after FROM employment_history
     WHERE employee_id = v_sub AND change_type = 'confirmed';

    IF v_conf_after IS DISTINCT FROM d_end THEN
        RAISE EXCEPTION 'FIXTURE 136F 失败:转正日应写成试用期到期日 %,实得 %',
            d_end, COALESCE(v_conf_after::text, '(NULL)');
    END IF;
    IF v_es_after <> 'active' THEN
        RAISE EXCEPTION 'FIXTURE 136F 失败:转正后在职状态应为 active,实得 %', v_es_after;
    END IF;
    IF v_hist_after <> v_hist_before + 1 THEN
        RAISE EXCEPTION 'FIXTURE 136F 失败:转正应当【恰好】留下一行履历,前 % 后 %',
            v_hist_before, v_hist_after;
    END IF;
    -- ★ 三个自证非空:每一个都必须【变过】
    IF v_conf_before IS NOT DISTINCT FROM v_conf_after THEN
        RAISE EXCEPTION 'FIXTURE 136F 失败(空转):转正日前后相同 —— 批准什么都没写';
    END IF;
    IF v_es_before = v_es_after THEN
        RAISE EXCEPTION 'FIXTURE 136F 失败(空转):在职状态前后相同';
    END IF;
    IF v_hist_before = v_hist_after THEN
        RAISE EXCEPTION 'FIXTURE 136F 失败(空转):履历行数前后相同';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · 告警认得出"已经有人在办了" —— 而【过期那一支不许被软化】
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_hr1), true);

    -- 一个新的、到期在即、还没有人动过的试用期员工
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, probation_end_date, department_id)
    VALUES ('ZZ-F136-AL', 'fixture 136 alert', 'full_time', 'office', CURRENT_DATE - 60,
            'probation', CURRENT_DATE + 10, v_dept)
    RETURNING id INTO v_sub2;

    SELECT count(*) INTO v_n FROM hr_alerts
     WHERE employee_id = v_sub2 AND alert_type = 'probation_ending';
    SELECT count(*) INTO v_n2 FROM hr_alerts
     WHERE employee_id = v_sub2 AND alert_type = 'probation_review_underway';
    IF v_n <> 1 OR v_n2 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 136G 布景不成立:动手之前应当是 ending=1 / underway=0,实得 % / %', v_n, v_n2;
    END IF;

    PERFORM open_probation_review(v_sub2);

    SELECT count(*) INTO v_n FROM hr_alerts
     WHERE employee_id = v_sub2 AND alert_type = 'probation_ending';
    SELECT count(*) INTO v_n2 FROM hr_alerts
     WHERE employee_id = v_sub2 AND alert_type = 'probation_review_underway';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 136G 失败:发起之后 probation_ending 应当让位,实得 % 行 —— 做对事的人还在被同一盏灯催', v_n;
    END IF;
    IF v_n2 <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 136G 失败:发起之后应当出现 probation_review_underway,实得 % 行', v_n2;
    END IF;

    -- 【过期那一支不许被软化】已过期 + 手上有草稿 → 仍然必须是 expired 的 overdue。
    -- 这一条是本刀唯一有可能把真问题弄安静的地方,所以单独钉住。
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date,
                           employment_status, probation_end_date, department_id)
    VALUES ('ZZ-F136-OD', 'fixture 136 overdue', 'full_time', 'office', CURRENT_DATE - 80,
            'probation', CURRENT_DATE - 5, v_dept)
    RETURNING id INTO v_other;
    PERFORM open_probation_review(v_other);
    SELECT count(*) INTO v_n FROM hr_alerts
     WHERE employee_id = v_other AND alert_type = 'probation_overdue' AND severity = 'expired';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 136G 失败:已过期的那一支【不该】因为有人在办就变安静,实得 % 行', v_n;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 ·「谁评估这个人」只有【一处】定义 —— 目录断言,不是数字断言
    -- ══════════════════════════════════════════════════════════════════════
    -- ★【先把注释剥掉再比】★ 第一版写的是直接对 pg_get_functiondef 做 LIKE,
    -- 而故障注入当场证明了它是空的:把调用换回内联的 COALESCE 之后,
    -- **函数体里那句解释性注释仍然写着 resolve_review_reviewer**,于是断言照样通过。
    -- 一条读到了注释而不是代码的断言,比没有断言更坏 —— 它会被信。
    -- 所以这里先 regexp 掉 `--` 行注释,再比【调用】本身(带左括号)。
    IF regexp_replace(pg_get_functiondef('public.open_review_cycle(uuid)'::regprocedure),
                      '--[^' || chr(10) || ']*', '', 'g')
         NOT LIKE '%resolve_review_reviewer(%' THEN
        RAISE EXCEPTION 'FIXTURE 136H 失败:open_review_cycle 没有【调用】resolve_review_reviewer —— 那段三级解析被抄回去了,而抄回去的那份会与这一份漂开';
    END IF;
    IF regexp_replace(pg_get_functiondef('public.open_probation_review(uuid)'::regprocedure),
                      '--[^' || chr(10) || ']*', '', 'g')
         NOT LIKE '%resolve_review_reviewer(%' THEN
        RAISE EXCEPTION 'FIXTURE 136H 失败:open_probation_review 没有【调用】resolve_review_reviewer';
    END IF;
END $$;
ROLLBACK;

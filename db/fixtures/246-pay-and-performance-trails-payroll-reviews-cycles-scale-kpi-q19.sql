-- 246 AUDIT-TRAIL-1d-3:工资与评审的审计记录 —— 工资期 · 评审(HR 与审核人两页)· 评审轮次 · 评分刻度 · KPI 条目 · Q19(2026-10-04)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1d Step 0 的 Q1–Q38,Tim 2026-10-04 全部照建议;这是 1d-3 那一刀)
--   PP  工资期:建立 · 重导(一个人没变、一个人变了 —— 两对一删一插都在,配对是造句器那一半,见 check-trail-wording ⑬)·
--       过账 · 撤销(备注末尾那一行与它的理由在;原分录被冲销、冲销分录经 reversed_by 找到 —— 期间的 journal_entry_id 已经
--       置空,分录仍在这一段里:按 source_id 找,不按 journal_entry_id)· 申请的撤回 · 发薪 · CPF;
--       不持 data.view_pay 的 HR 读者:工资行在、金额 Restricted;不持财务的读者:分录那几行是 Restricted(row_hidden);
--       一个码都没有的人 → TRAIL_NOT_PERMITTED
--   PQ  工资申请撤回,记录开始之前(Q12):只剩 withdrawn_at / withdrawn_by 那一对戳 —— 拼出来是一次 UPDATE,人是撤回的人
--   RV  评审:开(试用期)· 定审核人 · 加目标 · 写结论 · HR 的决定(新月薪)· 审核人送审 · 批准 —— 评审那一行与两行审批留痕、
--       目标在;批准在同一笔里改的员工那一行与任职履历【不】在(Q7);不持 view_pay 的读者读到的新月薪是 Restricted(Q7:遮蔽照今天)
--   MR  /my-reviews(M8 + M12,Q5):审核人读得到,审批那几行对他是 Restricted;被评审的本人(批准之后他经"own approved"读得到
--       那一行)→ TRAIL_NOT_PERMITTED;审核人读带页面码的 performance_review → 被拒(不持 hr.view)
--   RX  作废:作废那一次在(理由在);记录开始之前的作废(Q12)只剩 voided_at / voided_by 那一对戳,理由一并取
--   CY  轮次(Q6):建 · 开 · 关三次改动在;开轮铺下的评审【不】在轮次那一段里;铺下的那一份评审自己的那一段以它的建立开头,
--       cycle_id 指着这一轮
--   SC  评分刻度(M11 集合):加一档 · 改说明 · 停用 —— 都在;不持 hr.view → 被拒
--   KP  KPI 条目:一次生成(五条)· 打分 · 改分;不持 view_reviews 的 HR 读者读别人那一条 → 被拒(根行的读规则);
--       员工本人读自己那一条 → 被拒(这一个主语要 hr.view —— /me 上没有 KPI 的审计记录,Q14 · Q16);
--       记录开始之前的打分(本刀登记的戳)只剩 scored_at / scored_by 与分数
--   Q   Q19:不持 hr.view 的员工经 my_period_labels() 读到自己考勤行与工资单所在的期间 —— 只有编号与月份四列;
--       别人的期间、没有他那一行的期间一个都不回;两张期间表直接读仍是 0 行;一个没有员工档案的账号 0 行;anon 调不到
--   R   登记:Q12 的三个戳在 trail_prelog_sources 里;my_review 是 M8 + M12;评审的目标那几行的家落在 /hr/reviews;
--       工资申请的名字里没有原样的种类(Q10);/me 上没有评审与 KPI 的主语(Q14)
--
-- 自带数据(README 第 2 条):账号、角色、员工、考勤、工资期、申请、评审、轮次、刻度的那一档、KPI 月份全部本支自建;
--   职位与 KPI 模板、评分刻度的四档是稳定的引导数据(第 4 条)。月份是【找】出来的(fixture 141 · 218 的做法)。
-- 以 postgres 跑(绕过 RLS)—— 每一次读都切成 authenticated + 那个人的 JWT(fixture 26 的教训)。
-- 【一笔事务】本支的每一次写都在同一笔里(同一个 txid),所以记录开始【之后】的"同一次操作"在这里证不出来 —— 那一半由
--   check-trail-wording ⑬ 的金句证(工资行按员工配对、一次生成五条是一条);这里证的是行在不在、谁看得见、之前那一段从哪来。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f246_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f246_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f246_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, p_n) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

-- 以某人的身份跑一句、取回一个 jsonb(读 Q19 那支函数用)
CREATE FUNCTION pg_temp.f246_read(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f246_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

CREATE FUNCTION pg_temp.f246_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 246 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

CREATE FUNCTION pg_temp.f246_refused(p_arm text, p_trail jsonb) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF COALESCE(p_trail ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 246 %: expected TRAIL_NOT_PERMITTED, got %', p_arm, left(p_trail::text, 400); END IF;
END;
$f$;

-- 那一行(表 · 操作 · 可选:改了哪一列 · 新值包含 · 旧值包含 · 是否 prelog);返回第一行,找不到就 NULL
CREATE FUNCTION pg_temp.f246_find(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL,
                                  p_old jsonb DEFAULT NULL, p_prelog boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT e FROM jsonb_array_elements(p_trail) e
     WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
       AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
       AND (p_new IS NULL OR e -> 'new' @> p_new)
       AND (p_old IS NULL OR e -> 'old' @> p_old)
       AND (p_prelog IS NULL OR (e ->> 'prelog')::boolean = p_prelog)
     LIMIT 1
$f$;

CREATE FUNCTION pg_temp.f246_need(p_arm text, p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL,
                                  p_old jsonb DEFAULT NULL, p_prelog boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := pg_temp.f246_find(p_trail, p_table, p_op, p_col, p_new, p_old, p_prelog);
BEGIN
    IF v IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 246 %: expected a % % row% in the trail, got %', p_arm, p_table, p_op,
            COALESCE(' changing ' || p_col, '') || COALESCE(' with new ' || p_new::text, '') || COALESCE(' with old ' || p_old::text, '')
            || COALESCE(' prelog=' || p_prelog::text, ''),
            left(p_trail::text, 1500);
    END IF;
    RETURN v;
END;
$f$;

CREATE FUNCTION pg_temp.f246_count(p_trail jsonb, p_table text) RETURNS int
LANGUAGE sql AS $f$
    SELECT count(*)::int FROM jsonb_array_elements(p_trail) e WHERE e ->> 'table_name' = p_table AND NOT (e ->> 'row_hidden')::boolean
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码(做事的人:HR、财务、批准人)
    u_pay  uuid := gen_random_uuid();   -- module.hr.view + data.view_pay + module.finance.view(看得见金额与分录)
    u_hr   uuid := gen_random_uuid();   -- 只持 module.hr.view(cto / gm 的形状:不持 view_pay、不持 view_reviews 时看不见别人的 KPI)
    u_rvw  uuid := gen_random_uuid();   -- module.hr.view + data.view_reviews,不持 data.view_pay(Q7 的读者)
    u_emp  uuid := gen_random_uuid();   -- 被评审的员工本人(一个码都没有 —— Q19 的主角)
    u_rev  uuid := gen_random_uuid();   -- 审核人(一个码都没有 —— /my-reviews 的主角)
    u_none uuid := gen_random_uuid();   -- 一个码都没有、也没有员工档案
    r_all uuid; r_pay uuid; r_hr uuid; r_rvw uuid;
    e_emp uuid := gen_random_uuid(); e_rev uuid := gen_random_uuid();
    t0 timestamptz := TIMESTAMPTZ '2026-09-01 10:00:00+08';    -- 都早于 change_log_began_at()(2026-09-28 23:58)
    t1 timestamptz := TIMESTAMPTZ '2026-09-02 11:00:00+08';
    t2 timestamptz := TIMESTAMPTZ '2026-09-03 12:00:00+08';
    t3 timestamptz := TIMESTAMPTZ '2026-09-04 13:00:00+08';
    v_m date; v_m2 date; v_n int; v_att uuid; v_att_code text; r record;
    pp uuid; pp2 uuid; v_pp_code text; q uuid; q_pre uuid := gen_random_uuid(); v_lines jsonb; v_line_ids uuid[];
    rv uuid; rv2 uuid; rv3 uuid := gen_random_uuid(); g1 uuid; cyc uuid; kc uuid; k1 uuid; k_pre uuid := gen_random_uuid();
    v_pos uuid; v_tpl uuid;
    v_j jsonb; v_r jsonb; v_r2 jsonb; v_txt text;
BEGIN
    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx246-all@test.local', now(), now()), (u_pay, 'fx246-pay@test.local', now(), now()),
        (u_hr, 'fx246-hr@test.local', now(), now()), (u_rvw, 'fx246-rvw@test.local', now(), now()),
        (u_emp, 'fx246-emp@test.local', now(), now()), (u_rev, 'fx246-rev@test.local', now(), now()),
        (u_none, 'fx246-none@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx246-all', 'FX246 All', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx246-pay', 'FX246 Pay reader', 'f', true) RETURNING id INTO r_pay;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx246-hr', 'FX246 HR only', 'f', true) RETURNING id INTO r_hr;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx246-rvw', 'FX246 Review reader', 'f', true) RETURNING id INTO r_rvw;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_pay, 'module.hr.view'), (r_pay, 'data.view_pay'), (r_pay, 'module.finance.view'),
        (r_hr, 'module.hr.view'),
        (r_rvw, 'module.hr.view'), (r_rvw, 'data.view_reviews');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_pay, r_pay), (u_hr, r_hr), (u_rvw, r_rvw);
    SELECT id INTO v_pos FROM positions WHERE code = 'CTO';
    IF v_pos IS NULL THEN RAISE EXCEPTION 'FIXTURE 246 setup: the CTO position (bootstrap) is missing'; END IF;

    -- 月份:往回找连着两个既没有工资单、也没有考勤底稿的月份(fixture 141 · 218 的理由:线上与重建库的日历不同)
    v_m := NULL;
    FOR v_n IN 1..24 LOOP
        v_m2 := (date_trunc('month', CURRENT_DATE) - make_interval(months => v_n + 1))::date;
        IF NOT EXISTS (SELECT 1 FROM payroll_periods p2 WHERE date_trunc('month', p2.period_month)::date IN (v_m2, (v_m2 + interval '1 month')::date))
           AND NOT EXISTS (SELECT 1 FROM attendance_periods ap WHERE ap.period_month IN (v_m2, (v_m2 + interval '1 month')::date)) THEN
            v_m := (v_m2 + interval '1 month')::date;
            EXIT;
        END IF;
    END LOOP;
    IF v_m IS NULL THEN RAISE EXCEPTION 'FIXTURE 246 setup: no two empty months within 24 months'; END IF;

    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status,
                           probation_end_date, monthly_salary, user_id) VALUES
        (e_emp, 'FX246-EMP', 'FX246 Employee', 'Emp', 'full_time', 'office', v_m2 - 120, 'probation', v_m2 - 30, 4000, u_emp);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status,
                           position_id, monthly_salary, user_id) VALUES
        (e_rev, 'FX246-REV', 'FX246 Reviewer', 'Rev', 'full_time', 'office', v_m2 - 400, 'active', v_pos, 6000, u_rev);
    -- 审批关着(工资申请生下来就是 approved —— 自动批的那一行留痕;本支不测批准的门,fixture 218 测);期间不锁
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;

    PERFORM pg_temp.f246_as(u_all);
    -- 那个月的考勤做齐(过账站在它上面)
    v_r := open_attendance_period(v_m2);
    v_att := (v_r ->> 'period_id')::uuid;
    v_att_code := v_r ->> 'code';
    FOR r IN SELECT id FROM attendance_lines WHERE period_id = v_att LOOP PERFORM record_attendance(r.id); END LOOP;
    PERFORM complete_attendance_period(v_att);

    -- ══════════════ PP · 工资期 ══════════════
    v_lines := jsonb_build_array(
        jsonb_build_object('employee_id', e_emp, 'gross_pay', 3000, 'employee_cpf', 600, 'employer_cpf', 510, 'other_deductions', 0, 'net_pay', 2400),
        jsonb_build_object('employee_id', e_rev, 'gross_pay', 9000, 'employee_cpf', 1200, 'employer_cpf', 1020, 'other_deductions', 0, 'net_pay', 7800));
    v_r := upsert_payroll_period(v_m2, v_m2 + 27, 'SGD', 1, 'fx246 provider file', 'FX246 bonus month', v_lines);
    pp := (v_r ->> 'payroll_period_id')::uuid;
    v_pp_code := v_r ->> 'code';
    -- 重导:FX246-EMP 一分没变,FX246-REV 的工资变了(Q11:两对一删一插)
    v_lines := jsonb_build_array(
        jsonb_build_object('employee_id', e_emp, 'gross_pay', 3000, 'employee_cpf', 600, 'employer_cpf', 510, 'other_deductions', 0, 'net_pay', 2400),
        jsonb_build_object('employee_id', e_rev, 'gross_pay', 9500, 'employee_cpf', 1300, 'employer_cpf', 1100, 'other_deductions', 0, 'net_pay', 8200));
    PERFORM upsert_payroll_period(v_m2, v_m2 + 27, 'SGD', 1, 'fx246 provider file', 'FX246 bonus month', v_lines);
    -- 过账 → 撤销(理由)→ 再提一张、撤回 → 再提一张、过账 → 发薪 → CPF
    q := (submit_payroll_request(pp, 'post') ->> 'request_id')::uuid;
    PERFORM post_payroll_period(pp);
    PERFORM submit_payroll_request(pp, 'reversal', 'FX246 wrong CPF rate');
    PERFORM unpost_payroll_period(pp);
    q := (submit_payroll_request(pp, 'post') ->> 'request_id')::uuid;
    PERFORM withdraw_payroll_request(q);
    PERFORM submit_payroll_request(pp, 'post');
    PERFORM post_payroll_period(pp);
    SELECT array_agg(id) INTO v_line_ids FROM payroll_lines WHERE payroll_period_id = pp;
    PERFORM pay_payroll_lines(pp, v_line_ids, v_m2 + 27, NULL);
    PERFORM pay_payroll_cpf(pp, v_m2 + 40, NULL);
    -- 另一期:只有 FX246-REV 一行(Q 臂:没有你那一行的期间不该回给你)
    pp2 := (upsert_payroll_period(v_m, v_m + 27, 'SGD', 1, 'fx246', NULL,
            jsonb_build_array(jsonb_build_object('employee_id', e_rev, 'gross_pay', 100, 'employee_cpf', 0, 'employer_cpf', 0,
                                                 'other_deductions', 0, 'net_pay', 100))) ->> 'payroll_period_id')::uuid;

    v_j := pg_temp.f246_ok('PP', pg_temp.f246_trail(u_pay, 'payroll_period', pp::text));
    PERFORM pg_temp.f246_need('PP (recorded)', v_j, 'payroll_periods', 'INSERT');
    v_r := pg_temp.f246_need('PP (Q11: the changed line, deleted)', v_j, 'payroll_lines', 'DELETE', NULL, NULL, jsonb_build_object('employee_id', e_rev, 'gross_pay', 9000));
    v_r2 := pg_temp.f246_need('PP (Q11: the changed line, re-inserted)', v_j, 'payroll_lines', 'INSERT', NULL, jsonb_build_object('employee_id', e_rev, 'gross_pay', 9500));
    PERFORM pg_temp.f246_need('PP (Q11: the unchanged line, deleted)', v_j, 'payroll_lines', 'DELETE', NULL, NULL, jsonb_build_object('employee_id', e_emp, 'gross_pay', 3000));
    PERFORM pg_temp.f246_need('PP (Q11: the unchanged line, re-inserted)', v_j, 'payroll_lines', 'INSERT', NULL, jsonb_build_object('employee_id', e_emp, 'gross_pay', 3000));
    IF v_r ->> 'op_key' <> v_r2 ->> 'op_key' THEN
        RAISE EXCEPTION 'FIXTURE 246 PP (Q11): the delete and the re-insert of one person''s line must be one operation'; END IF;
    PERFORM pg_temp.f246_need('PP (posted)', v_j, 'payroll_periods', 'UPDATE', 'status', '{"status": "posted"}');
    v_r := pg_temp.f246_need('PP (Q10: unposted — the note line carries the reason)', v_j, 'payroll_periods', 'UPDATE', 'notes', '{"status": "draft"}');
    IF v_r -> 'new' ->> 'notes' NOT LIKE '%unposted] FX246 wrong CPF rate' THEN
        RAISE EXCEPTION 'FIXTURE 246 PP (Q10): the unpost appends "[… unposted] <reason>" to the notes, got %', v_r -> 'new' ->> 'notes'; END IF;
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'journal_entries' AND e ->> 'op' = 'INSERT' AND NOT (e ->> 'row_hidden')::boolean;
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 246 PP: expected the five journals of this period on its trail (post, reversal, post again, salaries, CPF) — got % (the posting journal is found by source_id, not by journal_entry_id, which the unpost cleared)', v_n; END IF;
    PERFORM pg_temp.f246_need('PP (the original journal reversed)', v_j, 'journal_entries', 'UPDATE', 'status', '{"status": "reversed"}');
    PERFORM pg_temp.f246_need('PP (Q12: the request withdrawn — after the log, the row itself)', v_j, 'payroll_requests', 'UPDATE', 'withdrawn_at', '{"status": "withdrawn"}');
    PERFORM pg_temp.f246_need('PP (executed)', v_j, 'payroll_requests', 'UPDATE', 'status', '{"status": "executed"}');
    PERFORM pg_temp.f246_need('PP (the automatic approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "payroll_request", "decision": "auto_approved"}');
    PERFORM pg_temp.f246_need('PP (salaries paid: the paid stamp)', v_j, 'payroll_lines', 'UPDATE', 'paid_at');
    PERFORM pg_temp.f246_need('PP (CPF paid)', v_j, 'payroll_periods', 'UPDATE', 'cpf_paid_at');
    -- 不持 view_pay、不持财务的 HR 读者:工资行在,金额受限;分录那几行看不见
    v_j := pg_temp.f246_ok('PP (hr.view only)', pg_temp.f246_trail(u_hr, 'payroll_period', pp::text));
    v_r := pg_temp.f246_need('PP (hr.view only: the line is there)', v_j, 'payroll_lines', 'INSERT', NULL, jsonb_build_object('employee_id', e_rev));
    IF NOT (v_r -> 'new' -> 'gross_pay' ? '$restricted') THEN
        RAISE EXCEPTION 'FIXTURE 246 PP: a reader without data.view_pay must see the gross pay as Restricted, got %', v_r -> 'new' -> 'gross_pay'; END IF;
    IF pg_temp.f246_count(v_j, 'journal_entries') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 246 PP: a reader without finance must not read the payroll journals'; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 246 PP (Q4): the journals should keep their place as Restricted'; END IF;
    PERFORM pg_temp.f246_refused('PP (no code)', pg_temp.f246_trail(u_none, 'payroll_period', pp::text));

    -- ══════════════ PQ · 工资申请撤回,记录开始之前(Q12)══════════════
    SET LOCAL session_replication_role = replica;
    INSERT INTO payroll_requests (id, payroll_period_id, kind, status, label, snapshot, currency, fx_rate, gross_total, amount_base,
                                  withdrawn_at, withdrawn_by, created_at, created_by)
        VALUES (q_pre, pp, 'post', 'withdrawn', v_pp_code || ' · post #9', '{}'::jsonb, 'SGD', 1, 12500, 12500, t1, u_all, t0, u_all);
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f246_ok('PQ', pg_temp.f246_trail(u_pay, 'payroll_period', pp::text));
    v_r := pg_temp.f246_need('PQ (Q12: withdrawn, before the log)', v_j, 'payroll_requests', 'UPDATE', 'withdrawn_at', '{"status": "withdrawn"}', NULL, true);
    IF COALESCE(v_r -> 'actor' ->> 'state', 'unknown') = 'unknown' THEN
        RAISE EXCEPTION 'FIXTURE 246 PQ (Q12): the withdrawal stamp names who withdrew (an account, never "Not recorded"), got %', v_r -> 'actor'; END IF;
    PERFORM pg_temp.f246_need('PQ (requested, before the log)', v_j, 'payroll_requests', 'INSERT', NULL, NULL, NULL, true);

    -- ══════════════ RV · 评审(试用期)══════════════
    rv := (open_probation_review(e_emp) ->> 'review_id')::uuid;
    PERFORM set_review_reviewer(rv, e_rev);
    g1 := (add_review_goal(rv, 'FX246 run the monthly stocktake', 12, 'counts') ->> 'goal_id')::uuid;
    PERFORM set_review_conclusion(rv, 'MEETS', 'FX246 a steady probation');
    UPDATE performance_reviews SET probation_outcome = 'confirm', new_monthly_salary = 4300, salary_effective_date = DATE '2030-01-01' WHERE id = rv;
    PERFORM pg_temp.f246_as(u_rev);
    PERFORM submit_review(rv);
    PERFORM pg_temp.f246_as(u_all);
    PERFORM approve_review(rv);
    IF (SELECT status FROM performance_reviews WHERE id = rv) <> 'approved' THEN RAISE EXCEPTION 'FIXTURE 246 RV setup: the review was not approved'; END IF;
    v_j := pg_temp.f246_ok('RV', pg_temp.f246_trail(u_all, 'performance_review', rv::text));
    PERFORM pg_temp.f246_need('RV (opened)', v_j, 'performance_reviews', 'INSERT');
    PERFORM pg_temp.f246_need('RV (submitted)', v_j, 'performance_reviews', 'UPDATE', 'status', '{"status": "submitted"}');
    PERFORM pg_temp.f246_need('RV (approved — key event)', v_j, 'performance_reviews', 'UPDATE', 'status', '{"status": "approved"}');
    PERFORM pg_temp.f246_need('RV (the submit approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "performance_review", "decision": "submitted"}');
    PERFORM pg_temp.f246_need('RV (the approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "performance_review", "decision": "approved"}');
    PERFORM pg_temp.f246_need('RV (a goal added)', v_j, 'review_goals', 'INSERT');
    PERFORM pg_temp.f246_need('RV (field edit: the HR decision)', v_j, 'performance_reviews', 'UPDATE', 'new_monthly_salary');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' IN ('employees', 'employment_history')) THEN
        RAISE EXCEPTION 'FIXTURE 246 RV (Q7): the employee row and the employment history the approval wrote are not on the review''s trail'; END IF;
    -- Q7:结论按评审自己的几列说,遮蔽照今天 —— 不持 view_pay 的读者读到的新月薪是 Restricted,评级照样读得到
    v_j := pg_temp.f246_ok('RV (Q7 reader)', pg_temp.f246_trail(u_rvw, 'performance_review', rv::text));
    v_r := pg_temp.f246_need('RV (Q7: approved, read without view_pay)', v_j, 'performance_reviews', 'UPDATE', 'status', '{"status": "approved"}');
    IF NOT (v_r -> 'ctx' -> 'new_monthly_salary' ? '$restricted') OR v_r -> 'ctx' ->> 'rating_code' IS DISTINCT FROM 'MEETS' THEN
        RAISE EXCEPTION 'FIXTURE 246 RV (Q7): the outcome reads from the review''s own columns, salary masked as today — got %', v_r -> 'ctx'; END IF;
    PERFORM pg_temp.f246_refused('RV (the reviewer has no hr.view: the HR page''s subject)', pg_temp.f246_trail(u_rev, 'performance_review', rv::text));

    -- ══════════════ MR · /my-reviews(M8 + M12 · Q5)══════════════
    v_j := pg_temp.f246_ok('MR', pg_temp.f246_trail(u_rev, 'my_review', rv::text));
    PERFORM pg_temp.f246_need('MR (the reviewer reads the review)', v_j, 'performance_reviews', 'UPDATE', 'status', '{"status": "approved"}');
    PERFORM pg_temp.f246_need('MR (the reviewer reads the goals)', v_j, 'review_goals', 'INSERT');
    IF pg_temp.f246_count(v_j, 'approval_log') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 246 MR (Q5): the approval rows must be Restricted to a reviewer without hr.view'; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 246 MR (Q4): the approval rows should keep their place as Restricted'; END IF;
    PERFORM pg_temp.f246_refused('MR (M12: the reviewed employee, who can read the approved row, is not the reviewer)', pg_temp.f246_trail(u_emp, 'my_review', rv::text));
    PERFORM pg_temp.f246_refused('MR (a stranger)', pg_temp.f246_trail(u_none, 'my_review', rv::text));

    -- ══════════════ CY · 评审轮次(Q6)══════════════
    INSERT INTO review_cycles (name, period_start, period_end, due_date) VALUES ('FX246 cycle', v_m2, v_m2 + 300, v_m2 + 330) RETURNING id INTO cyc;
    PERFORM open_review_cycle(cyc);
    UPDATE review_cycles SET status = 'closed' WHERE id = cyc;
    SELECT id INTO rv2 FROM performance_reviews WHERE cycle_id = cyc AND employee_id = e_rev;
    IF rv2 IS NULL THEN RAISE EXCEPTION 'FIXTURE 246 CY setup: opening the cycle created no review for FX246-REV'; END IF;
    v_j := pg_temp.f246_ok('CY', pg_temp.f246_trail(u_all, 'review_cycle', cyc::text));
    PERFORM pg_temp.f246_need('CY (created)', v_j, 'review_cycles', 'INSERT');
    PERFORM pg_temp.f246_need('CY (opened — key event)', v_j, 'review_cycles', 'UPDATE', 'status', '{"status": "open"}');
    PERFORM pg_temp.f246_need('CY (closed — key event)', v_j, 'review_cycles', 'UPDATE', 'status', '{"status": "closed"}');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'performance_reviews') THEN
        RAISE EXCEPTION 'FIXTURE 246 CY (Q6): the reviews the cycle created are not on the cycle''s trail'; END IF;
    v_j := pg_temp.f246_ok('CY (the review it created)', pg_temp.f246_trail(u_all, 'performance_review', rv2::text));
    PERFORM pg_temp.f246_need('CY (Q6: the annual review opens with its cycle)', v_j, 'performance_reviews', 'INSERT', NULL,
                              jsonb_build_object('review_type', 'annual', 'cycle_id', cyc));

    -- ══════════════ RX · 作废(之后 · 之前)══════════════
    PERFORM void_review(rv2, 'FX246 opened in error');
    v_j := pg_temp.f246_ok('RX', pg_temp.f246_trail(u_all, 'performance_review', rv2::text));
    PERFORM pg_temp.f246_need('RX (voided, with its reason)', v_j, 'performance_reviews', 'UPDATE', 'status', '{"status": "void", "void_reason": "FX246 opened in error"}');
    SET LOCAL session_replication_role = replica;
    INSERT INTO performance_reviews (id, employee_id, review_type, cycle_id, period_start, period_end, reviewer_employee_id, status,
                                     void_reason, voided_at, voided_by, created_at, created_by, updated_at)
        VALUES (rv3, e_emp, 'probation', NULL, v_m2 - 120, v_m2 - 30, e_rev, 'void', 'FX246 duplicate', t2, u_all, t1, u_all, t2);
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f246_ok('RX (before the log)', pg_temp.f246_trail(u_all, 'performance_review', rv3::text));
    v_r := pg_temp.f246_need('RX (Q12: voided before the log, with its reason)', v_j, 'performance_reviews', 'UPDATE', 'voided_at',
                             '{"status": "void", "void_reason": "FX246 duplicate"}', NULL, true);
    IF COALESCE(v_r -> 'actor' ->> 'state', 'unknown') = 'unknown' THEN
        RAISE EXCEPTION 'FIXTURE 246 RX (Q12): the void stamp names who voided (an account, never "Not recorded"), got %', v_r -> 'actor'; END IF;

    -- ══════════════ SC · 评分刻度(M11)══════════════
    INSERT INTO review_rating_scale (code, name_en, name_zh, sort_order) VALUES ('FX246', 'FX246 level', '测试档', 99);
    UPDATE review_rating_scale SET description_en = 'FX246 changed' WHERE code = 'FX246';
    UPDATE review_rating_scale SET is_active = false WHERE code = 'FX246';
    v_j := pg_temp.f246_ok('SC', pg_temp.f246_trail(u_hr, 'review_rating_scale', 'all'));
    PERFORM pg_temp.f246_need('SC (added)', v_j, 'review_rating_scale', 'INSERT', NULL, '{"name_en": "FX246 level"}');
    PERFORM pg_temp.f246_need('SC (field edit)', v_j, 'review_rating_scale', 'UPDATE', 'description_en', '{"description_en": "FX246 changed"}');
    PERFORM pg_temp.f246_need('SC (deactivated — key event)', v_j, 'review_rating_scale', 'UPDATE', 'is_active', '{"is_active": false}');
    PERFORM pg_temp.f246_refused('SC (no hr.view)', pg_temp.f246_trail(u_none, 'review_rating_scale', 'all'));

    -- ══════════════ KP · KPI 条目 ══════════════
    INSERT INTO kpi_cycles (name, period_start, period_end, due_date, status) VALUES ('FX246 KPI month', v_m2, v_m2 + 27, v_m2 + 35, 'open') RETURNING id INTO kc;
    PERFORM assign_position_kpis(e_rev, kc);
    SELECT id, source_template_id INTO k1, v_tpl FROM kpi_entries WHERE cycle_id = kc AND employee_id = e_rev ORDER BY kpi_ref LIMIT 1;
    IF k1 IS NULL THEN RAISE EXCEPTION 'FIXTURE 246 KP setup: no KPI entries were generated'; END IF;
    PERFORM score_kpi_entry(k1, 4, 'judged', 'FX246 three counts');
    PERFORM score_kpi_entry(k1, 3, 'judged', 'FX246 one variance');
    v_j := pg_temp.f246_ok('KP', pg_temp.f246_trail(u_rvw, 'kpi_entry', k1::text));
    PERFORM pg_temp.f246_need('KP (generated)', v_j, 'kpi_entries', 'INSERT');
    PERFORM pg_temp.f246_need('KP (scored — key event)', v_j, 'kpi_entries', 'UPDATE', 'score', '{"score": 4}');
    PERFORM pg_temp.f246_need('KP (re-scored)', v_j, 'kpi_entries', 'UPDATE', 'score', '{"score": 3}');
    PERFORM pg_temp.f246_refused('KP (hr.view without view_reviews, someone else''s entry)', pg_temp.f246_trail(u_hr, 'kpi_entry', k1::text));
    PERFORM pg_temp.f246_refused('KP (Q14 · Q16: the employee''s own entry — no KPI trail on /me)', pg_temp.f246_trail(u_rev, 'kpi_entry', k1::text));
    SET LOCAL session_replication_role = replica;
    INSERT INTO kpi_entries (id, cycle_id, employee_id, source_position_id, source_template_id, source_template_version, kpi_ref, title, weight_pct,
                             target_text, org_codes, score, score_kind, scored_at, scored_by, created_at, created_by)
        VALUES (k_pre, kc, e_rev, v_pos, v_tpl, 1, 'FX9', 'FX246 earlier KPI', 10, 'FX246 target', ARRAY['O1'], 2, 'judged', t3, u_all, t0, u_all);
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f246_ok('KP (before the log)', pg_temp.f246_trail(u_rvw, 'kpi_entry', k_pre::text));
    PERFORM pg_temp.f246_need('KP (scored before the log: the stamp)', v_j, 'kpi_entries', 'UPDATE', 'scored_at', '{"score": 2, "score_kind": "judged"}', NULL, true);

    -- ══════════════ Q · Q19:本人读得到自己期间的编号与月份,别的一概不给 ══════════════
    v_r := pg_temp.f246_read(u_emp, 'SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.kind), ''[]''::jsonb) FROM my_period_labels() x');
    IF jsonb_typeof(v_r) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 246 Q19: my_period_labels() refused the employee: %', v_r; END IF;
    IF jsonb_array_length(v_r) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 246 Q19: expected exactly the two periods of the employee''s own lines (attendance + payroll), got %', v_r; END IF;
    IF NOT (v_r @> jsonb_build_array(jsonb_build_object('kind', 'attendance', 'period_id', v_att, 'code', v_att_code, 'period_month', v_m2))
            AND v_r @> jsonb_build_array(jsonb_build_object('kind', 'payroll', 'period_id', pp, 'code', v_pp_code, 'period_month', v_m2))) THEN
        RAISE EXCEPTION 'FIXTURE 246 Q19: the code and month of the employee''s own periods, got %', v_r; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r) x
                WHERE (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(x) k) <> ARRAY['code', 'kind', 'period_id', 'period_month']) THEN
        RAISE EXCEPTION 'FIXTURE 246 Q19: nothing else of the period — only kind, id, code and month, got %', v_r; END IF;
    IF v_r::text LIKE '%' || pp2::text || '%' THEN
        RAISE EXCEPTION 'FIXTURE 246 Q19: a period with no line of the employee must not be returned'; END IF;
    v_r := pg_temp.f246_read(u_emp, 'SELECT to_jsonb((SELECT count(*) FROM payroll_periods) + (SELECT count(*) FROM attendance_periods))');
    IF v_r::text <> '0' THEN
        RAISE EXCEPTION 'FIXTURE 246 Q19: the two period tables stay hr.view only when read directly, got % rows', v_r; END IF;
    v_r := pg_temp.f246_read(u_none, 'SELECT to_jsonb(count(*)) FROM my_period_labels()');
    IF v_r::text <> '0' THEN RAISE EXCEPTION 'FIXTURE 246 Q19: an account with no employee record reads no period, got %', v_r; END IF;
    IF has_function_privilege('anon', 'public.my_period_labels()', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.my_period_labels()', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 246 Q19: my_period_labels() is for signed-in callers only'; END IF;

    -- ══════════════ R · 登记 ══════════════
    SELECT count(*) INTO v_n FROM trail_prelog_sources() p
     WHERE (p.table_name, p.kind, p.at_column, p.by_column) IN (('payroll_requests', 'stamp', 'withdrawn_at', 'withdrawn_by'),
           ('performance_reviews', 'stamp', 'voided_at', 'voided_by'), ('kpi_entries', 'stamp', 'scored_at', 'scored_by'));
    IF v_n <> 3 THEN RAISE EXCEPTION 'FIXTURE 246 R (Q12): expected the three stamps registered, found %', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'my_review' AND cardinality(s.view_codes) = 0 AND s.root_rule = 'gate:reviewer') THEN
        RAISE EXCEPTION 'FIXTURE 246 R (Q5): my_review must be M8 + M12 (no page code, the reviewer gate)'; END IF;
    IF EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.root_table IN ('performance_reviews', 'kpi_entries') AND cardinality(s.view_codes) = 0
                  AND s.root_rule = 'table') THEN
        RAISE EXCEPTION 'FIXTURE 246 R (Q14): no subject may open a review or a KPI entry to its own employee (there is no /me trail for them)'; END IF;
    v_r := trail_row_record('review_goals', jsonb_build_object('id', g1), NULL, NULL);
    IF v_r ->> 'route' IS DISTINCT FROM '/hr/reviews' OR v_r ->> 'table' <> 'performance_reviews' THEN
        RAISE EXCEPTION 'FIXTURE 246 R: a goal belongs to its review, linked at /hr/reviews — got %', v_r; END IF;
    v_txt := trail_ref_label('payroll_requests', 'id', q::text) ->> 'label';
    IF v_txt IS NULL OR v_txt LIKE '%post #%' OR v_txt NOT LIKE v_pp_code || '%' THEN
        RAISE EXCEPTION 'FIXTURE 246 R (Q10): a payroll request is named by its period without the raw kind, got %', v_txt; END IF;

    RAISE NOTICE 'FIXTURE 246 全部通过:PP(Q11 · Q10 · Q4)· PQ(Q12)· RV(Q7)· MR(M12 · Q5)· CY(Q6)· RX(Q12)· SC(M11)· KP(Q14 · Q16 · Q12)· Q(Q19)· R(Q12 · Q5 · Q14 · Q10)';
END;
$$;

ROLLBACK;

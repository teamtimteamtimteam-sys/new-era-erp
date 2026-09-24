-- fixture 218 —— 工资过账与撤销,批之前什么都不过账(PAYROLL-APR-1,2026-09-24)
--
-- Tim 的矩阵 §5:工资过账与撤销 —— 财务提,CFO 批每一张,不分档;付工资、CPF、扣款仍归财务、
-- 不另批,但只能跟在一次批过的过账后面。工资期是【公司的单据】:主角那条腿对谁都不成立,
-- 提单人那条照判、按人认(Tim 的 Q1 (A))。
--
-- 各臂:
--   A  门:没有已批的申请,过账与撤销都按名拒;两支引擎、试跑、指纹 authenticated 调不到;
--      payroll_period_frozen 调得到(两支 INVOKER 守卫要它)
--   B  提:落 submitted、留痕 submitted/二级、总账一行不多、期间仍是 draft;同一期不许挂两张
--   C  等待期间冻住:保存 → PAYROLL_REQUEST_OPEN;直连改行 / 改合计 → PAYROLL_LINES_FROZEN;
--      那个月的考勤重开 → ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST
--   D  批:提单人批不了(|raiser)· 一级持有人批不了(不分档)· 驳回要理由 · 数变了批不了
--      (PAYROLL_CHANGED_SINCE_REQUEST)· CFO 批得了,留痕的备注说出"本期含审批人自己的工资行",
--      self_decided = false —— ★ 主角那条腿对 CFO 不成立(Q1 (A))
--   E  同一个人的另一个账号提的申请,CFO 批不了(提单人那条按人认)
--   F  执行:审批人执行不了(没有 hr.edit)· 财务执行 → 一张分录、期间 posted、申请 executed
--   G  撤销:理由必填 · 挂着撤销申请时三支付款按名拒(Q6)· 批 → 执行 → 期间 draft、分录已冲销
--   H  侧门(Q5,SET LOCAL ROLE authenticated):直连改 status / 直连插一行 posted →
--      PAYROLL_STATUS_THROUGH_FUNCTION_ONLY;已过账的行 → PAYROLL_LINES_FROZEN;
--      reverse_journal_entry 冲过账分录 → JE_REVERSE_USE_SOURCE_PATH;对照:草稿且没有申请的行照改
--   I  试跑:那个月考勤没做齐,提交就按引擎原话拒(PAYROLL_ATTENDANCE_NOT_COMPLETE),不留申请
--   J  撤回(approved 也可以)· 驳回留痕
--   K  引擎登记:approval_chain_gates 一行(二级、hr.view + view_pay)· 在途清单一行
--      (blocks_disable、fixed_level = 2、主角 NULL)· self_approval_exception 不认它
--   L  审批关着:有 submitted 的工资申请关不掉;关着时提 → 生下来 approved + auto_approved;
--      批 → APPROVALS_NOT_ENABLED;执行照走
--
-- 自带数据(README 第 2 条);月份是【找】出来的(fixture 141 的做法:线上与重建库的日历不同)。
BEGIN;
SET LOCAL statement_timeout = '180s';

-- 试一句 SQL:返回 'OK' 或错误原文。p_auth = true 时以 authenticated 身份跑(直连写那几臂)。
CREATE FUNCTION pg_temp.f218_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
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
    u_fin   uuid := gen_random_uuid();   -- 财务:提、执行、付
    u_cfo   uuid := gen_random_uuid();   -- 二级审批角色;也是在册员工 e_cfo 的主账号
    u_cfo2  uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持财务角色 —— "同一个人提的"那一臂
    u_l1    uuid := gen_random_uuid();   -- 一级审批角色
    r_fin uuid; r_l1 uuid; r_l2 uuid;
    e_fin uuid := gen_random_uuid();
    e_cfo uuid := gen_random_uuid();
    v_m2 date; v_m date; v_n int; v_je int; v_log int;
    v_att uuid; v_att2 uuid; r record;
    p1 uuid; p2 uuid; p3 uuid;
    q uuid; q2 uuid; q3 uuid;
    v_res jsonb; v_msg text; v_st text; v_code text; v_je_id uuid; v_line uuid;
    v_lines jsonb;
    rep jsonb := '{}'::jsonb;
BEGIN
    -- ── 布景 ──────────────────────────────────────────────────────────────
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx218-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx218-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx218-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.hr.view'), (r_fin, 'module.hr.edit'), (r_fin, 'data.view_pay'),
        (r_fin, 'module.finance.view'), (r_fin, 'module.finance.edit'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices'),
        -- 一级:审批开得了(每条分档链的门它都持),也看得见工资 —— 批不了工资申请只能因为【级别】
        (r_l1, 'module.purchasing.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'), (r_l1, 'module.finance.view'),
        (r_l1, 'module.hr.view'), (r_l1, 'data.view_pay'),
        -- 二级:CFO 的形状 —— 读得到、看得见,【没有】hr.edit
        (r_l2, 'module.purchasing.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'), (r_l2, 'module.finance.view'),
        (r_l2, 'module.hr.view'), (r_l2, 'data.view_pay');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_cfo, r_l2), (u_cfo2, r_fin), (u_l1, r_l1);

    -- 月份:往回找连着两个既没有工资单、也没有考勤底稿的月份(fixture 141 的理由)
    v_m := NULL;
    FOR v_n IN 1..24 LOOP
        v_m2 := (date_trunc('month', CURRENT_DATE) - make_interval(months => v_n + 1))::date;
        IF NOT EXISTS (SELECT 1 FROM payroll_periods pp
                        WHERE date_trunc('month', pp.period_month)::date IN (v_m2, (v_m2 + interval '1 month')::date))
           AND NOT EXISTS (SELECT 1 FROM attendance_periods ap
                            WHERE ap.period_month IN (v_m2, (v_m2 + interval '1 month')::date)) THEN
            v_m := (v_m2 + interval '1 month')::date;
            EXIT;
        END IF;
    END LOOP;
    IF v_m IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 218 前提不成立:往回 24 个月都找不到连着两个空月份'; END IF;

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_fin, 'FX218-FIN', 'FX218 Finance', 'full_time', 'office', v_m2 - 60, u_fin),
           (e_cfo, 'FX218-CFO', 'FX218 CFO',     'full_time', 'office', v_m2 - 60, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    -- 策略:一级 fx218-l1、二级 fx218-l2、门槛 1000;审批打开;期间不锁
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx218-l1',
                                approval_level2_role_code = 'fx218-l2',
                                approval_threshold_base   = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- v_m2 的考勤做齐(P1 站在它上面);v_m 的考勤开着、没做齐(I 臂)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_att := (open_attendance_period(v_m2)->>'period_id')::uuid;
    FOR r IN SELECT id FROM attendance_lines WHERE period_id = v_att LOOP
        PERFORM record_attendance(r.id);
    END LOOP;
    PERFORM complete_attendance_period(v_att);
    v_att2 := (open_attendance_period(v_m)->>'period_id')::uuid;

    v_lines := jsonb_build_array(
        jsonb_build_object('employee_id', e_fin, 'gross_pay', 3000, 'employee_cpf', 600, 'employer_cpf', 510,
                           'other_deductions', 20, 'net_pay', 2380),
        jsonb_build_object('employee_id', e_cfo, 'gross_pay', 9000, 'employee_cpf', 1200, 'employer_cpf', 1020,
                           'other_deductions', 0, 'net_pay', 7800));
    p1 := (upsert_payroll_period(v_m2, v_m2 + 27, 'SGD', 1, 'fx218', NULL, v_lines)->>'payroll_period_id')::uuid;
    p2 := (upsert_payroll_period(v_m, v_m + 5, 'SGD', 1, 'fx218', NULL, v_lines)->>'payroll_period_id')::uuid;

    -- ══════════ A · 门 ══════════════════════════════════════════════════════
    v_msg := pg_temp.f218_try(format('SELECT post_payroll_period(%L)', p1));
    IF v_msg NOT LIKE 'PAYROLL_NEEDS_APPROVED_REQUEST|%|post' THEN
        RAISE EXCEPTION 'FIXTURE 218A1 失败:没有已批的申请,过账应当按名拒,实得 %', v_msg; END IF;
    IF has_function_privilege('authenticated', 'public.post_payroll_period_internal(uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.unpost_payroll_period_internal(uuid, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.payroll_request_dry_run(uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.payroll_period_fingerprint(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 218A2 失败:authenticated 能直接调过账引擎 —— 申请这道闸形同虚设'; END IF;
    IF NOT has_function_privilege('authenticated', 'public.payroll_period_frozen(uuid)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.post_payroll_period(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 218A2 失败(对照):外门与 payroll_period_frozen 应当对 authenticated 可执行'; END IF;
    IF to_regprocedure('public.unpost_payroll_period(uuid, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 218A3 失败:旧签名 unpost_payroll_period(uuid, text) 还在 —— 执行的人另给一句理由,而批的是申请上那一句'; END IF;
    rep := rep || jsonb_build_object('A', 'doors');

    -- ══════════ I · 试跑:考勤没做齐,提交就按引擎原话拒 ═══════════════════
    v_msg := pg_temp.f218_try(format('SELECT submit_payroll_request(%L, %L)', p2, 'post'));
    IF v_msg NOT LIKE 'PAYROLL_ATTENDANCE_NOT_COMPLETE|%' THEN
        RAISE EXCEPTION 'FIXTURE 218I 失败:那个月考勤没做齐,提交应当按引擎原话拒,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests WHERE payroll_period_id = p2) THEN
        RAISE EXCEPTION 'FIXTURE 218I 失败:被拒的提交留下了一张申请'; END IF;

    -- ══════════ B · 提 ══════════════════════════════════════════════════════
    SELECT count(*) INTO v_je FROM journal_entries;
    v_res := submit_payroll_request(p1, 'post');
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 218B1 失败:审批开着,申请应当是 submitted,实得 %', v_res; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je OR (SELECT status FROM payroll_periods WHERE id = p1) <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 218B1 失败:提交碰了总账或期间状态'; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type = 'payroll_request' AND subject_id = q AND decision = 'submitted' AND level = 2
       AND amount_base = 12000 AND currency = 'SGD';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 218B2 失败:应当落一行 submitted/二级、金额 = gross 12000,实得 %', v_n; END IF;
    v_msg := pg_temp.f218_try(format('SELECT submit_payroll_request(%L, %L)', p1, 'post'));
    IF v_msg NOT LIKE 'PAYROLL_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 218B3 失败:同一期不许挂第二张申请,实得 %', v_msg; END IF;

    -- ══════════ C · 等待期间冻住 ═════════════════════════════════════════════
    v_msg := pg_temp.f218_try(format('SELECT upsert_payroll_period(%L, %L, %L, 1, NULL, NULL, %L::jsonb)',
                                     v_m2, v_m2 + 27, 'SGD', v_lines));
    IF v_msg NOT LIKE 'PAYROLL_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 218C1 失败:申请开着时保存应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('UPDATE payroll_lines SET notes = %L WHERE payroll_period_id = %L', 'x', p1), true);
    IF v_msg NOT LIKE 'PAYROLL_LINES_FROZEN|%|requested' THEN
        RAISE EXCEPTION 'FIXTURE 218C2 失败:申请开着时直连改行应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('UPDATE payroll_periods SET gross_total = gross_total + 1 WHERE id = %L', p1), true);
    IF v_msg NOT LIKE 'PAYROLL_LINES_FROZEN|%|requested' THEN
        RAISE EXCEPTION 'FIXTURE 218C3 失败:申请开着时直连改合计应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('SELECT reopen_attendance_period(%L, %L)', v_att, 'fx218'));
    IF v_msg NOT LIKE 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST|%' THEN
        RAISE EXCEPTION 'FIXTURE 218C4 失败:那个月的工资在等批,考勤不该重开得了,实得 %', v_msg; END IF;
    -- 对照:备注这类列照旧归 hr.edit
    v_msg := pg_temp.f218_try(format('UPDATE payroll_periods SET notes = %L WHERE id = %L', 'fx218 note', p1), true);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 218C5 失败(对照):改备注不该被冻住,实得 %', v_msg; END IF;

    -- ══════════ D · 批 ══════════════════════════════════════════════════════
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 218D1 失败:提单人自己批,应当 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, true)', q));
    IF v_msg <> 'APPROVAL_NOT_AUTHORISED|2|fx218-l2' THEN
        RAISE EXCEPTION 'FIXTURE 218D2 失败:一级持有人批一张工资申请应当被拒(不分档),实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, false, %L)', q, '  '));
    IF v_msg NOT LIKE 'PAYROLL_REQUEST_REJECT_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 218D3 失败:驳回要理由,实得 %', v_msg; END IF;
    -- 数在等待期间被属主路径改了(守卫只管直连写)→ 批准按名拒;改回来再批
    UPDATE payroll_lines SET gross_pay = 3001, net_pay = 2381 WHERE payroll_period_id = p1 AND employee_id = e_fin;
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, true)', q));
    IF v_msg NOT LIKE 'PAYROLL_CHANGED_SINCE_REQUEST|%' THEN
        RAISE EXCEPTION 'FIXTURE 218D4 失败:批的数变了,批准应当按名拒,实得 %', v_msg; END IF;
    UPDATE payroll_lines SET gross_pay = 3000, net_pay = 2380 WHERE payroll_period_id = p1 AND employee_id = e_fin;
    SELECT count(*) INTO v_je FROM journal_entries;
    v_res := decide_payroll_request(q, true, 'fx218 ok');
    IF v_res->>'status' <> 'approved' OR NOT (v_res->>'includes_own_line')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 218D5 失败:CFO 应当批得了、并认出本期含他自己的工资行,实得 %', v_res; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_id = q AND decision = 'approved' AND level = 2 AND NOT self_decided
       AND note LIKE '%FX218-CFO%' AND note LIKE 'fx218 ok%';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 218D6 失败:批准的留痕应当说出审批人自己的工资行、self_decided = false,实得 %', v_n; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je OR (SELECT status FROM payroll_periods WHERE id = p1) <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 218D7 失败:批准碰了总账或期间状态(试跑没有回滚干净)'; END IF;

    -- ══════════ F · 执行 ════════════════════════════════════════════════════
    v_msg := pg_temp.f218_try(format('SELECT post_payroll_period(%L)', p1));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 218F1 失败:审批人不持 hr.edit,执行应当被拒,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := post_payroll_period(p1);
    SELECT status, journal_entry_id INTO v_st, v_je_id FROM payroll_periods WHERE id = p1;
    IF v_st <> 'posted' OR v_je_id IS NULL OR (SELECT count(*) FROM journal_entries) <> v_je + 1 THEN
        RAISE EXCEPTION 'FIXTURE 218F2 失败:执行应当过一张分录、期间 posted'; END IF;
    IF (SELECT status FROM payroll_requests WHERE id = q) <> 'executed'
       OR (SELECT result_journal_entry_id FROM payroll_requests WHERE id = q) <> v_je_id THEN
        RAISE EXCEPTION 'FIXTURE 218F3 失败:申请应当是 executed 并记下那张分录'; END IF;

    -- ══════════ H · 侧门(直连写,authenticated)════════════════════════════════
    v_msg := pg_temp.f218_try(format('UPDATE payroll_periods SET status = %L, journal_entry_id = NULL WHERE id = %L', 'draft', p1), true);
    IF v_msg NOT LIKE 'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|%' THEN
        RAISE EXCEPTION 'FIXTURE 218H1 失败:直连改 status 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format(
        'INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate, status) VALUES (%L, %L, %L, %L, 1, %L)',
        'FX218-SIDE', (v_m2 - interval '12 months')::date, v_m2 - 300, 'SGD', 'posted'), true);
    IF v_msg NOT LIKE 'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|%' THEN
        RAISE EXCEPTION 'FIXTURE 218H2 失败:直连插一行 posted 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('UPDATE payroll_lines SET notes = %L WHERE payroll_period_id = %L', 'x', p1), true);
    IF v_msg NOT LIKE 'PAYROLL_LINES_FROZEN|%|posted' THEN
        RAISE EXCEPTION 'FIXTURE 218H3 失败:已过账的行直连改应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('DELETE FROM payroll_lines WHERE payroll_period_id = %L', p1), true);
    IF v_msg NOT LIKE 'PAYROLL_LINES_FROZEN|%|posted' THEN
        RAISE EXCEPTION 'FIXTURE 218H4 失败:已过账的行直连删应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('SELECT reverse_journal_entry(%L, %L)', v_je_id, v_m2 + 27));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|payroll' THEN
        RAISE EXCEPTION 'FIXTURE 218H5 失败:从通用冲销口冲工资过账分录应当按名拒,实得 %', v_msg; END IF;
    -- 对照:草稿、没有申请的期间,行照旧可以直连改
    v_msg := pg_temp.f218_try(format('UPDATE payroll_lines SET notes = %L WHERE payroll_period_id = %L', 'x', p2), true);
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 218H6 失败(对照):草稿期间的行不该被冻住,实得 %', v_msg; END IF;

    -- ══════════ G · 撤销 ════════════════════════════════════════════════════
    v_msg := pg_temp.f218_try(format('SELECT unpost_payroll_period(%L)', p1));
    IF v_msg NOT LIKE 'PAYROLL_NEEDS_APPROVED_REQUEST|%|reversal' THEN
        RAISE EXCEPTION 'FIXTURE 218G1 失败:没有已批的撤销申请,撤销应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('SELECT submit_payroll_request(%L, %L, %L)', p1, 'reversal', ' '));
    IF v_msg NOT LIKE 'PAYROLL_REVERSAL_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 218G2 失败:撤销要理由,实得 %', v_msg; END IF;
    q2 := (submit_payroll_request(p1, 'reversal', 'fx218 服务商退回')->>'request_id')::uuid;
    v_msg := pg_temp.f218_try(format('SELECT pay_payroll_lines(%L, ARRAY(SELECT id FROM payroll_lines WHERE payroll_period_id = %L), %L)', p1, p1, v_m2 + 27));
    IF v_msg NOT LIKE 'PAYROLL_REVERSAL_REQUESTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 218G3 失败:挂着撤销申请时付工资应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('SELECT pay_payroll_cpf(%L, %L)', p1, v_m2 + 27));
    IF v_msg NOT LIKE 'PAYROLL_REVERSAL_REQUESTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 218G4 失败:挂着撤销申请时汇 CPF 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f218_try(format('SELECT pay_payroll_deductions(%L, %L)', p1, v_m2 + 27));
    IF v_msg NOT LIKE 'PAYROLL_REVERSAL_REQUESTED|%' THEN
        RAISE EXCEPTION 'FIXTURE 218G5 失败:挂着撤销申请时汇扣款应当按名拒,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payroll_request(q2, true);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := unpost_payroll_period(p1);
    IF (SELECT status FROM payroll_periods WHERE id = p1) <> 'draft'
       OR (SELECT status FROM journal_entries WHERE id = v_je_id) <> 'reversed'
       OR (SELECT status FROM payroll_requests WHERE id = q2) <> 'executed'
       OR (SELECT result_journal_entry_id FROM payroll_requests WHERE id = q2)
          IS DISTINCT FROM (SELECT reversed_by FROM journal_entries WHERE id = v_je_id)
       OR (SELECT notes FROM payroll_periods WHERE id = p1) NOT LIKE '%fx218 服务商退回%' THEN
        RAISE EXCEPTION 'FIXTURE 218G6 失败:执行撤销之后应当 draft、原分录已冲销、申请记下冲销分录、理由取申请上那一句'; END IF;
    -- 撤销分录也不许从通用口再冲回去(那等于不经申请重新过账)
    v_msg := pg_temp.f218_try(format('SELECT reverse_journal_entry(%L, %L)',
                                     (SELECT reversed_by FROM journal_entries WHERE id = v_je_id), v_m2 + 27));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|payroll' THEN
        RAISE EXCEPTION 'FIXTURE 218G7 失败:冲回一张工资撤销分录应当按名拒,实得 %', v_msg; END IF;

    -- ══════════ E · 同一个人的另一个账号提的,CFO 批不了 ═══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo2), true);
    q3 := (submit_payroll_request(p1, 'post')->>'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, true)', q3));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 218E 失败:同一个人的另一个账号提的申请,应当 |raiser,实得 %', v_msg; END IF;

    -- ══════════ K · 引擎登记 ═════════════════════════════════════════════════
    IF NOT EXISTS (SELECT 1 FROM approval_chain_gates()
                    WHERE subject_type = 'payroll_request' AND action_function = 'decide_payroll_request'
                      AND level = 2 AND gate_permissions = ARRAY['module.hr.view', 'data.view_pay'])
       OR EXISTS (SELECT 1 FROM approval_chain_gates() WHERE subject_type = 'payroll_request' AND level = 1) THEN
        RAISE EXCEPTION 'FIXTURE 218K1 失败:工资申请应当只有二级一行,门 hr.view + view_pay'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() d
                    WHERE d.subject_type = 'payroll_request' AND d.doc_id = q3 AND d.blocks_disable
                      AND d.fixed_level = 2 AND d.subject_employee_id IS NULL AND d.amount_base = 12000) THEN
        RAISE EXCEPTION 'FIXTURE 218K2 失败:在途清单里应当有这张申请(挡关闭、固定二级、主角 NULL)'; END IF;
    IF self_approval_exception('payroll_request', e_cfo, u_cfo, 'fx218-l2') THEN
        RAISE EXCEPTION 'FIXTURE 218K3 失败:R2 永远不覆盖工资'; END IF;

    -- ══════════ L · 审批关着 ═════════════════════════════════════════════════
    v_code := (SELECT label FROM payroll_requests WHERE id = q3);
    v_msg := NULL;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%' OR position(v_code IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 218L1 失败:有一张 submitted 的工资申请时关得掉审批,实得 %', COALESCE(v_msg, '(关掉了)'); END IF;

    -- ══════════ J · 撤回与驳回 ═══════════════════════════════════════════════
    -- 驳回同样是一次决定:同一个人提的,CFO 也驳不了(四眼对两个方向都成立)
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, false, %L)', q3, 'x'));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 218J0 失败:同一个人提的申请,驳回也应当 |raiser,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo2), true);
    PERFORM withdraw_payroll_request(q3);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    q3 := (submit_payroll_request(p1, 'post')->>'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, false, %L)', q3, 'fx218 退回重做'));
    IF v_msg <> 'OK' OR (SELECT status FROM payroll_requests WHERE id = q3) <> 'rejected'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = q3 AND decision = 'rejected' AND note LIKE 'fx218 退回重做%') THEN
        RAISE EXCEPTION 'FIXTURE 218J1 失败:驳回应当落 rejected 与留痕,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    q := (submit_payroll_request(p1, 'post')->>'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payroll_request(q, true);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    PERFORM withdraw_payroll_request(q);
    IF (SELECT status FROM payroll_requests WHERE id = q) <> 'withdrawn' THEN
        RAISE EXCEPTION 'FIXTURE 218J2 失败:approved 的申请也应当撤回得了'; END IF;
    v_msg := pg_temp.f218_try(format('SELECT post_payroll_period(%L)', p1));
    IF v_msg NOT LIKE 'PAYROLL_NEEDS_APPROVED_REQUEST|%' THEN
        RAISE EXCEPTION 'FIXTURE 218J3 失败:撤回之后不该还过得了账,实得 %', v_msg; END IF;
    -- 撤回之后保存又放行了
    v_msg := pg_temp.f218_try(format('SELECT upsert_payroll_period(%L, %L, %L, 1, NULL, NULL, %L::jsonb)',
                                     v_m2, v_m2 + 27, 'SGD', v_lines));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 218J4 失败(对照):申请撤回之后保存应当放行,实得 %', v_msg; END IF;

    -- ══════════ L(续)· 关掉审批:生下来 approved,批不了,执行照走 ═══════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := submit_payroll_request(p1, 'post');
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'approved'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = q AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 218L2 失败:审批关着时应当生下来 approved 并落 auto_approved,实得 %', v_res; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_msg := pg_temp.f218_try(format('SELECT decide_payroll_request(%L, true)', q));
    IF v_msg NOT IN ('APPROVALS_NOT_ENABLED', 'PAYROLL_REQUEST_NOT_SUBMITTED|' || (SELECT label FROM payroll_requests WHERE id = q) || '|approved') THEN
        RAISE EXCEPTION 'FIXTURE 218L3 失败:审批关着时不该有人按批准,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    PERFORM post_payroll_period(p1);
    IF (SELECT status FROM payroll_periods WHERE id = p1) <> 'posted' THEN
        RAISE EXCEPTION 'FIXTURE 218L4 失败:审批关着时,生下来就批了的申请应当执行得了'; END IF;

    RAISE NOTICE 'FIXTURE 218 全部通过:A 门 · B 提 · C 等待期间冻住 · D 批(主角那条腿对 CFO 不成立,备注说出他自己的工资行)· E 同一个人的另一个账号 · F 执行 · G 撤销与付款互斥 · H 三扇侧门 · I 试跑 · J 撤回与驳回 · K 引擎登记 · L 审批关着';
END $$;
ROLLBACK;

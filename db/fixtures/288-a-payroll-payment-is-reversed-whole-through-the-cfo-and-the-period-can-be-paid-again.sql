-- fixture 288 —— 一次工资 / CPF / 扣款【付款】整张冲掉,经 CFO 批,期间之后能再付(PAYROLL-PAY-REVERSAL-1,2026-10-22)
--
-- Tim 2026-10-22 的裁定(Step 0 Q1–Q9):payroll_requests 第三种 payment_reversal;财务提、CFO 批(二级,不分档)、财务执行;
-- 整张冲(Q2);冲销日在执行时由人给、必填(Q3);不早于原付款、不晚于今天、不落锁定期(Q4);期间仍 posted、清掉那张分录付过的戳
-- (含净额为零的行),CPF / 扣款清那一期的日期与链接(Q5);银行行已配对按名拒,提 · 批 · 执行三处(Q6);工资 / CPF / 扣款同一种(Q7);
-- 通用冲销口按名拒 JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL(Q8);等待期间别的未付行照样能付(Q9)。
--
-- 各臂:
--   A  门:内层引擎 / 银行判据 / 付款种类 authenticated 调不到;提交与执行两扇外门调得到
--   B  布景:一期三行(一行净额为零)经申请过账;S1 付【两行】(含净额为零的那一行)· CPF · 扣款
--   C  通用口(Q8):路由 = payroll_payment;reverse_journal_entry 与冲销申请的提交都按名拒;过账分录仍是 source_path
--   D  提:没理由 / 认不出的分录(过账分录)按名拒;S1 → submitted、总账不动、留痕二级;同一期第二张按名拒
--   E  Q9:冲销申请开着时,那一期剩下的未付行照样能付(S2),指纹不含已付的戳
--   F  Q6:提(配上之后提)· 批(批之前配上)· 执行(批之后配上)三处都按名拒 REVERSAL_BANK_MATCHED;对完账的说 reconciled
--   G  批:提单人批不了;CFO 批得了,总账不动
--   H  执行的日期(Q3 · Q4):没给 / 晚于今天 / 早于原付款 / 落在锁定期 都按名拒;审批人(没有 hr.edit)执行不了
--   I  执行:一张冲销分录;S1 已冲;那两行(含零)的戳清掉、S2 那一行的戳还在;期间仍 posted;申请 executed、记下冲销分录;
--      冲销分录的路由仍是 payroll_payment,通用口冲它按名拒
--   J  再付:冲掉的两行能再付一次
--   K  CPF 与扣款同一种申请(Q7):各冲一次,戳与链接清掉;一笔付款都不剩时,撤销过账申请又提得上去(试跑放行)
--   L  审批关着:提 → 生下来 approved + auto_approved
--
-- 自带数据(README 第 2 条);月份是【找】出来的(fixture 141 / 218 的做法)。
BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f288_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f288_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    u_fin   uuid := gen_random_uuid();   -- 财务:提、执行、付
    u_cfo   uuid := gen_random_uuid();   -- 二级审批角色(CFO 的形状:读得到、看得见,没有 hr.edit)
    u_l1    uuid := gen_random_uuid();   -- 一级审批角色(开审批要它有人持)
    r_fin uuid; r_l1 uuid; r_l2 uuid;
    e_a uuid := gen_random_uuid();       -- 净额 2380
    e_z uuid := gen_random_uuid();       -- 净额 0(付款时没有银行行,却同样盖戳)
    e_b uuid := gen_random_uuid();       -- 净额 7800(E 臂在申请开着时付)
    v_m2 date; v_m date; v_n int; v_je int;
    v_att uuid; r record;
    p1 uuid; q uuid; q2 uuid;
    s1 uuid; s2 uuid; s1b uuid; c1 uuid; d1 uuid; v_post uuid; v_rev uuid;
    v_res jsonb; v_msg text; v_lines jsonb;
    v_stmt jsonb; v_stmt_id uuid; v_bl uuid; v_jl uuid;
BEGIN
    -- ── 布景:角色、审批、期间 ───────────────────────────────────────────
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_fin, now()), (u_cfo, now()), (u_l1, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx288-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx288-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx288-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.hr.view'), (r_fin, 'module.hr.edit'), (r_fin, 'data.view_pay'),
        (r_fin, 'module.finance.view'), (r_fin, 'module.finance.edit'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices'),
        (r_l1, 'module.purchasing.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'), (r_l1, 'module.finance.view');
    -- 二级:每条链的门都持(否则开不了审批 —— 218 / 211 记过的那几条)
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, c FROM unnest(ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices', 'module.finance.view',
                                     'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view', 'module.pricing.view',
                                     'module.suppliers.view', 'module.customers.view']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin), (u_cfo, r_l2), (u_l1, r_l1);

    v_m := NULL;
    FOR v_n IN 1..24 LOOP
        v_m2 := (date_trunc('month', CURRENT_DATE) - make_interval(months => v_n + 1))::date;
        IF NOT EXISTS (SELECT 1 FROM payroll_periods pp WHERE date_trunc('month', pp.period_month)::date = v_m2)
           AND NOT EXISTS (SELECT 1 FROM attendance_periods ap WHERE ap.period_month = v_m2) THEN
            v_m := v_m2;
            EXIT;
        END IF;
    END LOOP;
    IF v_m IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 288 前提不成立:往回 24 个月都找不到一个空月份'; END IF;

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_a, 'FX288-A', 'FX288 Alpha', 'full_time', 'office', v_m - 400, u_fin),
        (e_z, 'FX288-Z', 'FX288 Zero',  'full_time', 'office', v_m - 400, NULL),
        (e_b, 'FX288-B', 'FX288 Beta',  'full_time', 'office', v_m - 400, NULL);

    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx288-l1', approval_level2_role_code = 'fx288-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    PERFORM pg_temp.f288_as(u_fin);
    v_att := (open_attendance_period(v_m)->>'period_id')::uuid;
    FOR r IN SELECT id FROM attendance_lines WHERE period_id = v_att LOOP
        PERFORM record_attendance(r.id);
    END LOOP;
    PERFORM complete_attendance_period(v_att);
    v_lines := jsonb_build_array(
        jsonb_build_object('employee_id', e_a, 'gross_pay', 3000, 'employee_cpf', 600, 'employer_cpf', 510, 'other_deductions', 20, 'net_pay', 2380),
        jsonb_build_object('employee_id', e_z, 'gross_pay', 0, 'employee_cpf', 0, 'employer_cpf', 0, 'other_deductions', 0, 'net_pay', 0),
        jsonb_build_object('employee_id', e_b, 'gross_pay', 9000, 'employee_cpf', 1200, 'employer_cpf', 1020, 'other_deductions', 0, 'net_pay', 7800));
    p1 := (upsert_payroll_period(v_m, v_m + 20, 'SGD', 1, 'fx288', NULL, v_lines)->>'payroll_period_id')::uuid;
    q := (submit_payroll_request(p1, 'post')->>'request_id')::uuid;
    PERFORM pg_temp.f288_as(u_cfo);
    PERFORM decide_payroll_request(q, true);
    PERFORM pg_temp.f288_as(u_fin);
    PERFORM post_payroll_period(p1);
    v_post := (SELECT journal_entry_id FROM payroll_periods WHERE id = p1);

    -- ══════════ A · 门 ══════════════════════════════════════════════════════
    IF has_function_privilege('authenticated', 'public.reverse_payroll_payment_internal(uuid, date, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.assert_entry_not_bank_matched(uuid)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.payroll_payment_entry_kind(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 288A1 失败:authenticated 能直接调冲销引擎 / 银行判据 / 付款种类 —— 申请这道闸形同虚设'; END IF;
    IF NOT has_function_privilege('authenticated', 'public.submit_payroll_payment_reversal_request(uuid, text)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.reverse_payroll_payment(uuid, date)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.payroll_payment_entries(uuid[])', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 288A2 失败(对照):提交 / 执行 / 付薪页读者应当对 authenticated 可执行'; END IF;

    -- ══════════ B · 付款:S1 付两行(含净额为零的一行)· CPF · 扣款;e_b 留着不付 ══════
    s1 := (pay_payroll_lines(p1, ARRAY[(SELECT id FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id = e_a),
                                       (SELECT id FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id = e_z)],
                             v_m + 20)->>'entry_id')::uuid;
    PERFORM pay_payroll_cpf(p1, v_m + 21);
    PERFORM pay_payroll_deductions(p1, v_m + 21);
    c1 := (SELECT cpf_journal_entry_id FROM payroll_periods WHERE id = p1);
    d1 := (SELECT deductions_journal_entry_id FROM payroll_periods WHERE id = p1);
    IF (SELECT count(*) FROM payroll_lines WHERE paid_journal_entry_id = s1) <> 2
       OR payroll_payment_entry_kind(s1) <> 'salary' OR payroll_payment_entry_kind(c1) <> 'cpf'
       OR payroll_payment_entry_kind(d1) <> 'deductions' OR payroll_payment_entry_kind(v_post) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 288B 失败:布景不是本支假设的形状(S1 盖两行的戳;三种付款认得出;过账分录不是付款)'; END IF;

    -- ══════════ C · 通用口(Q8)═════════════════════════════════════════════
    IF journal_entry_reversal_route(s1) <> 'payroll_payment' OR journal_entry_reversal_route(c1) <> 'payroll_payment'
       OR journal_entry_reversal_route(d1) <> 'payroll_payment' OR journal_entry_reversal_route(v_post) <> 'source_path' THEN
        RAISE EXCEPTION 'FIXTURE 288C1 失败:三张付款分录应当路由到 payroll_payment、过账分录仍是 source_path'; END IF;
    v_msg := pg_temp.f288_try(format('SELECT reverse_journal_entry(%L, %L)', s1, v_m + 25));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%' THEN
        RAISE EXCEPTION 'FIXTURE 288C2 失败:通用冲销口冲工资付款应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f288_try(format('SELECT submit_journal_reversal_request(%L, %L, %L)', c1, v_m + 25, 'fx288'));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%' THEN
        RAISE EXCEPTION 'FIXTURE 288C3 失败:日记账冲销申请对 CPF 付款应当按名拒,实得 %', v_msg; END IF;

    -- ══════════ D · 提 ══════════════════════════════════════════════════════
    v_msg := pg_temp.f288_try(format('SELECT submit_payroll_payment_reversal_request(%L, %L)', s1, '  '));
    IF v_msg NOT LIKE 'PAYROLL_REVERSAL_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 288D1 失败:没理由应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f288_try(format('SELECT submit_payroll_payment_reversal_request(%L, %L)', v_post, 'fx288'));
    IF v_msg NOT LIKE 'PAYROLL_PAYMENT_ENTRY_UNKNOWN|%' THEN
        RAISE EXCEPTION 'FIXTURE 288D2 失败:过账分录不是一次付款,应当按名拒,实得 %', v_msg; END IF;
    SELECT count(*) INTO v_je FROM journal_entries;
    v_res := submit_payroll_payment_reversal_request(s1, 'fx288 wrong amount to Alpha');
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT count(*) FROM journal_entries) <> v_je
       OR (SELECT target_entry_id FROM payroll_requests WHERE id = q) <> s1
       OR (SELECT count(*) FROM payroll_lines WHERE paid_journal_entry_id = s1) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 288D3 失败:提交应当落 submitted、记下目标分录、总账与戳都不动,实得 %', v_res; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'payroll_request' AND subject_id = q
                    AND decision = 'submitted' AND level = 2) THEN
        RAISE EXCEPTION 'FIXTURE 288D4 失败:留痕应当有一行 submitted / 二级'; END IF;
    v_msg := pg_temp.f288_try(format('SELECT submit_payroll_payment_reversal_request(%L, %L)', c1, 'fx288'));
    IF v_msg NOT LIKE 'PAYROLL_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 288D5 失败:同一期不许挂第二张申请,实得 %', v_msg; END IF;

    -- ══════════ E · Q9:申请开着,剩下的未付行照样能付 ═════════════════════════
    s2 := (pay_payroll_lines(p1, ARRAY[(SELECT id FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id = e_b)],
                             v_m + 22)->>'entry_id')::uuid;
    IF s2 IS NULL OR (SELECT paid_journal_entry_id FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id = e_b) <> s2 THEN
        RAISE EXCEPTION 'FIXTURE 288E 失败:冲销申请开着时,别的未付行应当照样能付'; END IF;

    -- ══════════ F · Q6:配上了对账单行 —— 批的时候拒(提交那一格在下面 K 臂)═══════
    v_stmt := import_bank_statement('1000', v_m, v_m + 27, 10000, 7620, 'fx288.csv',
        jsonb_build_array(jsonb_build_object('line_date', v_m + 20, 'description', 'salary Alpha', 'reference', 'FX288', 'amount', -2380)));
    v_stmt_id := (v_stmt->>'statement_id')::uuid;
    SELECT id INTO v_bl FROM bank_statement_lines WHERE statement_id = v_stmt_id AND line_no = 1;
    SELECT l.id INTO v_jl FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = s1 AND a.code = '1000' AND l.credit = 2380;
    PERFORM match_bank_line(v_bl, ARRAY[v_jl]);
    PERFORM pg_temp.f288_as(u_cfo);
    v_msg := pg_temp.f288_try(format('SELECT decide_payroll_request(%L, true)', q));
    IF v_msg NOT LIKE 'REVERSAL_BANK_MATCHED|%|%|open' THEN
        RAISE EXCEPTION 'FIXTURE 288F1 失败:付款已配上对账单行,批准应当按名拒(open),实得 %', v_msg; END IF;
    -- 那张对账单对完账了:同一句,换成 reconciled(先撤销对账)。直接写状态 —— 本臂问的是那句话,不是对账本身
    UPDATE bank_statements SET status = 'reconciled' WHERE id = v_stmt_id;
    v_msg := pg_temp.f288_try(format('SELECT decide_payroll_request(%L, true)', q));
    IF v_msg NOT LIKE 'REVERSAL_BANK_MATCHED|%|%|reconciled' THEN
        RAISE EXCEPTION 'FIXTURE 288F2 失败:对完账的对账单,拒绝应当说 reconciled,实得 %', v_msg; END IF;
    UPDATE bank_statements SET status = 'open' WHERE id = v_stmt_id;
    PERFORM pg_temp.f288_as(u_fin);
    PERFORM unmatch_bank_line(v_bl);

    -- ══════════ G · 批 ══════════════════════════════════════════════════════
    v_msg := pg_temp.f288_try(format('SELECT decide_payroll_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 288G1 失败:提单人自己批,应当 SELF_APPROVAL_FORBIDDEN|raiser,实得 %', v_msg; END IF;
    PERFORM pg_temp.f288_as(u_cfo);
    SELECT count(*) INTO v_je FROM journal_entries;
    v_res := decide_payroll_request(q, true, 'fx288 ok');
    IF v_res->>'status' <> 'approved' OR (SELECT count(*) FROM journal_entries) <> v_je
       OR (SELECT count(*) FROM payroll_lines WHERE paid_journal_entry_id = s1) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 288G2 失败:CFO 应当批得了,而批准不碰总账与戳(试跑回滚干净),实得 %', v_res; END IF;

    -- ══════════ H · 执行的日期 · 谁能执行 ══════════════════════════════════
    v_msg := pg_temp.f288_try(format('SELECT reverse_payroll_payment(%L, %L)', q, v_m + 25));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 288H1 失败:审批人不持 hr.edit,执行应当被拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f288_as(u_fin);
    v_msg := pg_temp.f288_try(format('SELECT reverse_payroll_payment(%L, NULL)', q));
    IF v_msg <> 'REVERSAL_DATE_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 288H2 失败:没给冲销日应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f288_try(format('SELECT reverse_payroll_payment(%L, %L)', q, CURRENT_DATE + 1));
    IF v_msg NOT LIKE 'DOCUMENT_DATE_IN_FUTURE|payroll_payment_reversal|%' THEN
        RAISE EXCEPTION 'FIXTURE 288H3 失败:晚于今天的冲销日应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f288_try(format('SELECT reverse_payroll_payment(%L, %L)', q, v_m + 19));
    IF v_msg NOT LIKE 'REVERSAL_BEFORE_ORIGINAL|%' THEN
        RAISE EXCEPTION 'FIXTURE 288H4 失败:早于原付款的冲销日应当按名拒,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = v_m + 24;
    PERFORM pg_temp.f288_as(u_fin);
    v_msg := pg_temp.f288_try(format('SELECT reverse_payroll_payment(%L, %L)', q, v_m + 23));
    IF v_msg NOT LIKE 'PERIOD_LOCKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 288H5 失败:落在锁定期的冲销日应当按期间锁拒,实得 %', v_msg; END IF;
    -- 执行时银行行又配上了(批准之后)→ 执行也拒(Q6 的第三处)
    PERFORM match_bank_line(v_bl, ARRAY[v_jl]);
    v_msg := pg_temp.f288_try(format('SELECT reverse_payroll_payment(%L, %L)', q, v_m + 25));
    IF v_msg NOT LIKE 'REVERSAL_BANK_MATCHED|%|%|open' THEN
        RAISE EXCEPTION 'FIXTURE 288H6 失败:批准之后配上的银行行,执行应当按名拒,实得 %', v_msg; END IF;
    PERFORM unmatch_bank_line(v_bl);

    -- ══════════ I · 执行(原付款所在的月锁了:冲销落在一个开着的日子,原件留在原地 —— Q4)══════
    SELECT count(*) INTO v_je FROM journal_entries;
    v_res := reverse_payroll_payment(q, v_m + 25);
    v_rev := (v_res->>'reversal_id')::uuid;
    IF (SELECT count(*) FROM journal_entries) <> v_je + 1
       OR (SELECT status FROM journal_entries WHERE id = s1) <> 'reversed'
       OR (SELECT entry_date FROM journal_entries WHERE id = v_rev) <> v_m + 25
       OR (SELECT entry_date FROM journal_entries WHERE id = s1) <> v_m + 20 THEN
        RAISE EXCEPTION 'FIXTURE 288I1 失败:应当恰好一张冲销分录、落在执行给的日子,原付款已冲而日期不动,实得 %', v_res; END IF;
    IF EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id IN (e_a, e_z)
                AND (paid_at IS NOT NULL OR paid_journal_entry_id IS NOT NULL))
       OR (SELECT paid_journal_entry_id FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id = e_b) <> s2
       OR (v_res->>'cleared')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 288I2 失败:S1 付过的两行(含净额为零)应当清掉戳,S2 那一行不动,实得 %', v_res; END IF;
    IF (SELECT status FROM payroll_periods WHERE id = p1) <> 'posted'
       OR (SELECT cpf_journal_entry_id FROM payroll_periods WHERE id = p1) <> c1 THEN
        RAISE EXCEPTION 'FIXTURE 288I3 失败:期间应当仍是 posted,CPF 不动'; END IF;
    IF (SELECT status FROM payroll_requests WHERE id = q) <> 'executed'
       OR (SELECT result_journal_entry_id FROM payroll_requests WHERE id = q) <> v_rev THEN
        RAISE EXCEPTION 'FIXTURE 288I4 失败:申请应当 executed、记下冲销分录'; END IF;
    IF journal_entry_reversal_route(v_rev) <> 'payroll_payment' THEN
        RAISE EXCEPTION 'FIXTURE 288I5 失败:冲销分录(戳已清,只能从申请上认出)应当仍路由到 payroll_payment,实得 %',
            journal_entry_reversal_route(v_rev); END IF;
    v_msg := pg_temp.f288_try(format('SELECT reverse_journal_entry(%L, %L)', v_rev, v_m + 26));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL|%' THEN
        RAISE EXCEPTION 'FIXTURE 288I6 失败:从通用口冲回一张工资付款的冲销分录应当按名拒,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM pg_temp.f288_as(u_fin);

    -- ══════════ J · 再付 ════════════════════════════════════════════════════
    s1b := (pay_payroll_lines(p1, ARRAY[(SELECT id FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id = e_a),
                                        (SELECT id FROM payroll_lines WHERE payroll_period_id = p1 AND employee_id = e_z)],
                              v_m + 26)->>'entry_id')::uuid;
    IF s1b IS NULL OR (SELECT count(*) FROM payroll_lines WHERE paid_journal_entry_id = s1b) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 288J 失败:冲掉的两行应当能再付一次'; END IF;

    -- ══════════ K · CPF · 扣款 · 两张工资付款都冲掉 → 撤销过账又提得上去(Q5 · Q7)══════
    -- K0 提交那一格的 Q6:S1b 配上对账单行 → 提交就按名拒
    SELECT l.id INTO v_jl FROM journal_lines l JOIN accounts a ON a.id = l.account_id
     WHERE l.entry_id = s1b AND a.code = '1000' AND l.credit = 2380;
    PERFORM match_bank_line(v_bl, ARRAY[v_jl]);
    v_msg := pg_temp.f288_try(format('SELECT submit_payroll_payment_reversal_request(%L, %L)', s1b, 'fx288 K0'));
    IF v_msg NOT LIKE 'REVERSAL_BANK_MATCHED|%|%|open' THEN
        RAISE EXCEPTION 'FIXTURE 288K0 失败:付款已配上对账单行,提交应当按名拒,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests WHERE payroll_period_id = p1 AND status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'FIXTURE 288K0 失败:被拒的提交留下了一张申请'; END IF;
    PERFORM unmatch_bank_line(v_bl);
    FOR r IN SELECT x.e, x.k FROM (VALUES (c1, 'cpf'), (d1, 'deductions'), (s1b, 'salary'), (s2, 'salary')) x(e, k) LOOP
        PERFORM pg_temp.f288_as(u_fin);
        q2 := (submit_payroll_payment_reversal_request(r.e, 'fx288 K ' || r.k)->>'request_id')::uuid;
        PERFORM pg_temp.f288_as(u_cfo);
        PERFORM decide_payroll_request(q2, true);
        PERFORM pg_temp.f288_as(u_fin);
        v_res := reverse_payroll_payment(q2, v_m + 27);
        IF v_res->>'kind' <> r.k OR (SELECT status FROM journal_entries WHERE id = r.e) <> 'reversed' THEN
            RAISE EXCEPTION 'FIXTURE 288K1 失败:% 付款应当按同一种申请冲掉,实得 %', r.k, v_res; END IF;
    END LOOP;
    IF (SELECT row(cpf_paid_at, cpf_journal_entry_id, deductions_paid_at, deductions_journal_entry_id)
          FROM payroll_periods WHERE id = p1) IS DISTINCT FROM row(NULL::date, NULL::uuid, NULL::date, NULL::uuid)
       OR EXISTS (SELECT 1 FROM payroll_lines WHERE payroll_period_id = p1 AND paid_at IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 288K2 失败:CPF 与扣款的日期与链接、每一行的戳都应当清掉'; END IF;
    v_res := submit_payroll_request(p1, 'reversal', 'fx288 nothing paid any more');
    IF v_res->>'status' <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 288K3 失败:一笔付款都不剩时,撤销过账申请应当提得上去(试跑放行),实得 %', v_res; END IF;
    PERFORM withdraw_payroll_request((v_res->>'request_id')::uuid);
    -- CPF 能再汇一次
    PERFORM pay_payroll_cpf(p1, v_m + 27);
    IF (SELECT cpf_journal_entry_id FROM payroll_periods WHERE id = p1) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 288K4 失败:冲掉之后 CPF 应当能再汇一次'; END IF;

    -- ══════════ L · 审批关着 ════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f288_as(u_fin);
    v_res := submit_payroll_payment_reversal_request((SELECT cpf_journal_entry_id FROM payroll_periods WHERE id = p1), 'fx288 L');
    IF v_res->>'status' <> 'approved'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = (v_res->>'request_id')::uuid AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 288L 失败:审批关着时应当生下来 approved 并落 auto_approved,实得 %', v_res; END IF;

    RAISE NOTICE 'FIXTURE 288 全部通过:A 门 · B 布景 · C 通用口按名拒 · D 提 · E 申请开着时别的行照付 · F 批的时候银行行已配对(open / reconciled)· G 批 · H 执行的日期与谁能执行 · I 执行(整张冲、戳清掉、期间仍 posted)· J 再付 · K CPF / 扣款同一种、提交时配对按名拒、一笔不剩时撤销过账又提得上 · L 审批关着';
END $$;
ROLLBACK;

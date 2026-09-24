-- db/scripts/2026-09-24-payrollapr1-live-proof.sql
-- PAYROLL-APR-1 的线上证明 —— 拒绝、读回,以及一整条【申请 → 批准 → 过账 → 撤销申请 → 批准 → 撤销】
-- 在线上真账号、线上真数据上走一遍。整支一笔事务,最后 ROLLBACK:线上一行都不留
-- (考勤底稿、工资期、工资申请、分录、留痕)。
--
-- 为什么不在 db/fixtures/:它要的是【线上真账号】在【线上真数据】上被拒 / 走得通。
-- fixture 218 在重建库上证同一批规矩的形状;这一支证的是"线上此刻,这几个人,真的是这样"。
--
-- 身份:以 postgres 连接(rolbypassrls = t),每一格用 set_config('request.jwt.claims') 换成那个
-- 真账号,并在 SET LOCAL ROLE authenticated 之下跑 —— RLS、列权限、函数 EXECUTE 按那个人判。
-- 失败 = RAISE(退出码非零);成功 = 最后一行 NOTICE 'PAYROLLAPR1 LIVE PROOF: n cells passed'。
--
-- 用到的线上数据(以 postgres 读基表,2026-09-24 23:43 CST):
--   PAY-2026-0001(2026-07,posted,1 行,行 / CPF / 扣款都已付)· 它的过账分录 JE-2026-0017
--   attendance_periods 0 行 → 八月的底稿由本支自己开、记、做齐(回滚)
--   finance_settings.locked_before = 2026-08-01 → 八月的工资期发薪日 2026-08-31 不在锁里
--   EMP-2026-0001(Choo Er,主账号 chooer@)· EMP-2026-0002(Tim,主账号 admin@,另一个账号 tim@)
--   journal_entries / 工资期 / 考勤的编号都是 MAX+1,回滚不留空号
BEGIN;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no such account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $$;

-- 以 authenticated 跑一句 SQL,读回它的报错(没有报错 → NULL)。成功的那一句【留在事务里】。
CREATE FUNCTION pg_temp.try_sql(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        EXECUTE 'RESET ROLE';
        RETURN NULL;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        EXECUTE 'RESET ROLE';
        RETURN v_msg;
    END;
END $$;

CREATE FUNCTION pg_temp.run_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

-- 一格:谁、说什么、跑哪句、期望(NULL = 必须通过;否则 LIKE 模式)
CREATE FUNCTION pg_temp.cell(p_who text, p_label text, p_sql text, p_expect text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    PERFORM pg_temp.as_user(p_who);
    v_msg := pg_temp.try_sql(p_sql);
    IF p_expect IS NULL THEN
        IF v_msg IS NOT NULL THEN
            RAISE EXCEPTION 'PROOF_FAILED|% | % | expected success, got %', p_who, p_label, v_msg;
        END IF;
        RAISE NOTICE 'CELL ok  | % | % | passes', p_who, p_label;
    ELSE
        IF v_msg IS NULL OR v_msg NOT LIKE p_expect THEN
            RAISE EXCEPTION 'PROOF_FAILED|% | % | expected %, got %', p_who, p_label, p_expect, COALESCE(v_msg, '(passed)');
        END IF;
        RAISE NOTICE 'CELL ok  | % | % | %', p_who, p_label, v_msg;
    END IF;
END $$;

DO $proof$
DECLARE
    v_cells int := 0;
    v_jul uuid; v_je17 uuid; v_je_before bigint; v_n bigint;
    v_choo_emp uuid; v_tim_emp uuid;
    v_att uuid; v_aug uuid; v_req uuid; v_rev uuid; v_adm_req uuid; v_je uuid;
    v_rep jsonb; v_lines jsonb; r record; v_note text; v_self boolean;
BEGIN
    SELECT id INTO v_jul FROM payroll_periods WHERE code = 'PAY-2026-0001';
    SELECT id INTO v_je17 FROM journal_entries WHERE code = 'JE-2026-0017';
    SELECT id INTO v_choo_emp FROM employees WHERE code = 'EMP-2026-0001';
    SELECT id INTO v_tim_emp FROM employees WHERE code = 'EMP-2026-0002';
    SELECT count(*) INTO v_je_before FROM journal_entries;
    IF v_jul IS NULL OR v_je17 IS NULL OR v_choo_emp IS NULL OR v_tim_emp IS NULL THEN
        RAISE EXCEPTION 'PROOF_SETUP|a named live row is missing';
    END IF;
    RAISE NOTICE 'IDENTITY | % | rolbypassrls = % | cells run as each account under SET LOCAL ROLE authenticated',
        current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user);

    -- ══════════ A · 门:没有已批的申请,过账与撤销都按名拒 ══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'unpost PAY-2026-0001 with no request',
        format('SELECT unpost_payroll_period(%L)', v_jul), 'PAYROLL_NEEDS_APPROVED_REQUEST|PAY-2026-0001|reversal'); v_cells := v_cells + 1;
    -- 提交时按同一支引擎试跑:七月已经付清,撤销申请按引擎的原话拒,不留申请
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'request unposting PAY-2026-0001 (lines already paid)',
        format('SELECT submit_payroll_request(%L, %L, %L)', v_jul, 'reversal', 'proof'), 'PAYROLL_LINES_PAID|PAY-2026-0001'); v_cells := v_cells + 1;
    IF EXISTS (SELECT 1 FROM payroll_requests) THEN RAISE EXCEPTION 'PROOF_FAILED|a refused submit left a request'; END IF;

    -- ══════════ H · 三扇侧门(chooer@ 持 hr.edit 与 finance.edit)══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct UPDATE of a posted period''s status',
        format('UPDATE payroll_periods SET status = %L, journal_entry_id = NULL WHERE id = %L', 'draft', v_jul),
        'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|PAY-2026-0001'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct INSERT of a period born posted',
        $q$INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate, status)
           VALUES ('ZZ-PAY-PROOF', DATE '2025-01-01', DATE '2025-01-31', 'SGD', 1, 'posted')$q$,
        'PAYROLL_STATUS_THROUGH_FUNCTION_ONLY|ZZ-PAY-PROOF'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct UPDATE of a posted period''s line',
        format('UPDATE payroll_lines SET notes = %L WHERE payroll_period_id = %L', 'x', v_jul),
        'PAYROLL_LINES_FROZEN|PAY-2026-0001|posted'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'reverse_journal_entry on the payroll posting entry JE-2026-0017',
        format('SELECT reverse_journal_entry(%L, DATE %L)', v_je17, '2026-09-24'),
        'JE_REVERSE_USE_SOURCE_PATH|JE-2026-0017|payroll'); v_cells := v_cells + 1;

    -- ══════════ 布景:八月的考勤底稿(chooer@,回滚)══════════
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_rep := pg_temp.run_json($q$SELECT open_attendance_period(DATE '2026-08-01')$q$);
    v_att := (v_rep->>'period_id')::uuid;
    FOR r IN SELECT id FROM attendance_lines WHERE period_id = v_att LOOP
        PERFORM pg_temp.run_json(format('SELECT to_jsonb(record_attendance(%L))', r.id));
    END LOOP;
    PERFORM pg_temp.run_json(format('SELECT complete_attendance_period(%L)', v_att));
    v_lines := jsonb_build_array(
        jsonb_build_object('employee_id', v_choo_emp, 'gross_pay', 5000, 'employee_cpf', 1000, 'employer_cpf', 850,
                           'other_deductions', 0, 'net_pay', 4000),
        jsonb_build_object('employee_id', v_tim_emp, 'gross_pay', 9000, 'employee_cpf', 1200, 'employer_cpf', 1020,
                           'other_deductions', 0, 'net_pay', 7800));
    v_rep := pg_temp.run_json(format($q$SELECT upsert_payroll_period(DATE '2026-08-01', DATE '2026-08-31', 'SGD', 1,
                                          'proof', NULL, %L::jsonb)$q$, v_lines));
    v_aug := (v_rep->>'payroll_period_id')::uuid;
    RAISE NOTICE 'SETUP    | chooer@ | August attendance complete (% lines) and payroll period % drafted (2 lines, gross 14000)',
        (SELECT count(*) FROM attendance_lines WHERE period_id = v_att), v_rep->>'code';

    -- ══════════ A2 · 草稿不经申请过不了账 ══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'post August with no request',
        format('SELECT post_payroll_period(%L)', v_aug), 'PAYROLL_NEEDS_APPROVED_REQUEST|%|post'); v_cells := v_cells + 1;

    -- ══════════ B · 提 ══════════
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_rep := pg_temp.run_json(format('SELECT submit_payroll_request(%L, %L)', v_aug, 'post'));
    v_req := (v_rep->>'request_id')::uuid;
    IF v_rep->>'status' <> 'submitted' THEN RAISE EXCEPTION 'PROOF_FAILED|submit should be submitted, got %', v_rep; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je_before THEN RAISE EXCEPTION 'PROOF_FAILED|submit touched the ledger'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = v_req AND decision = 'submitted' AND level = 2
                    AND amount_base = 14000) THEN
        RAISE EXCEPTION 'PROOF_FAILED|no submitted/level-2/14000 approval_log row';
    END IF;
    RAISE NOTICE 'CELL ok  | chooer@evoltrya.test | request posting August | submitted (%) · ledger untouched · approval_log submitted, level 2, 14000.00',
        v_rep->>'label';
    v_cells := v_cells + 1;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() d WHERE d.doc_id = v_req AND d.blocks_disable AND d.fixed_level = 2) THEN
        RAISE EXCEPTION 'PROOF_FAILED|the request is not in approval_pending_documents()';
    END IF;
    SELECT string_agg(u.email, ' ' ORDER BY u.email) INTO v_note
      FROM approval_deciders('payroll_request', 'decide_payroll_request', 2::smallint,
                             (SELECT id FROM auth.users WHERE email = 'chooer@evoltrya.test'), NULL, 'finance', 'cfo') d
      JOIN auth.users u ON u.id = d.user_id;
    RAISE NOTICE 'READ ok  | postgres | approval_deciders for this request | %', COALESCE(v_note, '(nobody)');
    IF v_note IS DISTINCT FROM 'tim@evoltrya.test' THEN RAISE EXCEPTION 'PROOF_FAILED|deciders should be tim@ only, got %', v_note; END IF;
    v_cells := v_cells + 1;

    -- ══════════ C · 等待期间冻住 ══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'save August while the request waits',
        format($q$SELECT upsert_payroll_period(DATE '2026-08-01', DATE '2026-08-31', 'SGD', 1, 'proof', NULL, %L::jsonb)$q$, v_lines),
        'PAYROLL_REQUEST_OPEN|%'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'reopen August attendance while the request waits',
        format('SELECT reopen_attendance_period(%L, %L)', v_att, 'proof'), 'ATTENDANCE_PERIOD_LOCKED_BY_PAYROLL_REQUEST|%'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'direct UPDATE of a waiting period''s line',
        format('UPDATE payroll_lines SET notes = %L WHERE payroll_period_id = %L', 'x', v_aug), 'PAYROLL_LINES_FROZEN|%|requested'); v_cells := v_cells + 1;

    -- ══════════ D · 谁批得了 ══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'the raiser approves', format('SELECT decide_payroll_request(%L, true)', v_req),
        'SELF_APPROVAL_FORBIDDEN|raiser'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('admin@swm-os.test', 'admin@ approves (holds the gate codes, not the cfo role)',
        format('SELECT decide_payroll_request(%L, true)', v_req), 'APPROVAL_NOT_AUTHORISED|2|cfo'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco approves', format('SELECT decide_payroll_request(%L, true)', v_req),
        'APPROVAL_NOT_AUTHORISED|2|cfo'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('vince@evoltrya.test', 'gm approves', format('SELECT decide_payroll_request(%L, true)', v_req),
        'PERMISSION_DENIED|data.view_pay'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'the CFO executes the posting', format('SELECT post_payroll_period(%L)', v_aug),
        'PERMISSION_DENIED|module.hr.edit'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'the CFO rejects without a reason', format('SELECT decide_payroll_request(%L, false, %L)', v_req, ' '),
        'PAYROLL_REQUEST_REJECT_REASON_REQUIRED|%'); v_cells := v_cells + 1;
    -- ★ Q1 (A):这一期含 Tim 自己的工资行,而 tim@ 批得了;留痕的备注说出来,self_decided = false
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    v_rep := pg_temp.run_json(format('SELECT decide_payroll_request(%L, true, %L)', v_req, 'proof'));
    SELECT note, self_decided INTO v_note, v_self FROM approval_log WHERE subject_id = v_req AND decision = 'approved';
    IF v_rep->>'status' <> 'approved' OR NOT (v_rep->>'includes_own_line')::boolean
       OR v_note NOT LIKE '%EMP-2026-0002%' OR v_self THEN
        RAISE EXCEPTION 'PROOF_FAILED|tim@ approve: %, note %, self_decided %', v_rep, v_note, v_self;
    END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je_before THEN RAISE EXCEPTION 'PROOF_FAILED|approval touched the ledger'; END IF;
    RAISE NOTICE 'CELL ok  | tim@evoltrya.test | the CFO approves a period that includes his own line | approved · note "%" · self_decided = false · ledger untouched',
        replace(v_note, E'\n', ' / ');
    v_cells := v_cells + 1;

    -- ══════════ F · 执行 ══════════
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_rep := pg_temp.run_json(format('SELECT post_payroll_period(%L)', v_aug));
    SELECT journal_entry_id INTO v_je FROM payroll_periods WHERE id = v_aug;
    IF (SELECT status FROM payroll_periods WHERE id = v_aug) <> 'posted' OR v_je IS NULL
       OR (SELECT count(*) FROM journal_entries) <> v_je_before + 1
       OR (SELECT status FROM payroll_requests WHERE id = v_req) <> 'executed'
       OR (SELECT result_journal_entry_id FROM payroll_requests WHERE id = v_req) <> v_je THEN
        RAISE EXCEPTION 'PROOF_FAILED|execute post: %', v_rep;
    END IF;
    RAISE NOTICE 'CELL ok  | chooer@evoltrya.test | finance posts the approved request | posted, % · request executed · journal_entries % → %',
        v_rep->>'journal_code', v_je_before, v_je_before + 1;
    v_cells := v_cells + 1;

    -- ══════════ G · 撤销申请:付款互斥;批;执行 ══════════
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_rep := pg_temp.run_json(format('SELECT submit_payroll_request(%L, %L, %L)', v_aug, 'reversal', 'proof: provider returned a line'));
    v_rev := (v_rep->>'request_id')::uuid;
    RAISE NOTICE 'CELL ok  | chooer@evoltrya.test | request unposting August | %', v_rep->>'status';
    v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'pay salary lines while unposting waits',
        format('SELECT pay_payroll_lines(%L, ARRAY(SELECT id FROM payroll_lines WHERE payroll_period_id = %L), DATE %L)', v_aug, v_aug, '2026-08-31'),
        'PAYROLL_REVERSAL_REQUESTED|%'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'remit CPF while unposting waits',
        format('SELECT pay_payroll_cpf(%L, DATE %L)', v_aug, '2026-08-31'), 'PAYROLL_REVERSAL_REQUESTED|%'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'the CFO approves the unposting', format('SELECT decide_payroll_request(%L, true)', v_rev), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance executes the unposting', format('SELECT unpost_payroll_period(%L)', v_aug), NULL); v_cells := v_cells + 1;
    IF (SELECT status FROM payroll_periods WHERE id = v_aug) <> 'draft'
       OR (SELECT status FROM journal_entries WHERE id = v_je) <> 'reversed' THEN
        RAISE EXCEPTION 'PROOF_FAILED|after unposting the period should be draft and its entry reversed';
    END IF;

    -- ══════════ E · 从 admin@(Tim 的另一个账号)提的申请,tim@ 批不了 ══════════
    PERFORM pg_temp.as_user('admin@swm-os.test');
    v_rep := pg_temp.run_json(format('SELECT submit_payroll_request(%L, %L)', v_aug, 'post'));
    v_adm_req := (v_rep->>'request_id')::uuid;
    PERFORM pg_temp.cell('tim@evoltrya.test', 'the CFO approves a request raised from admin@ (same person)',
        format('SELECT decide_payroll_request(%L, true)', v_adm_req), 'SELF_APPROVAL_FORBIDDEN|raiser'); v_cells := v_cells + 1;

    -- ══════════ L · 有一张在等的工资申请时,审批关不掉 ══════════
    PERFORM pg_temp.cell('admin@swm-os.test', 'switch approvals off while a payroll request waits',
        $q$SELECT set_approvals_policy(false, 'finance', 'cfo', 1000)$q$, 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%'); v_cells := v_cells + 1;

    -- ══════════ R · 读回 ══════════
    SELECT count(*) INTO v_n FROM journal_entries;
    RAISE NOTICE 'READ ok  | postgres | inside the proof: journal_entries % (before %), payroll_requests %, approval_log +%',
        v_n, v_je_before, (SELECT count(*) FROM payroll_requests),
        (SELECT count(*) FROM approval_log WHERE subject_type = 'payroll_request');

    RAISE NOTICE 'PAYROLLAPR1 LIVE PROOF: % cells passed', v_cells;
END;
$proof$;

ROLLBACK;

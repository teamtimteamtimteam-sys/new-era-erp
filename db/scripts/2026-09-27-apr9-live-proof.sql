-- db/scripts/2026-09-27-apr9-live-proof.sql
-- APR-9 · 线上走证(整支一笔事务,最后 ROLLBACK —— 线上一行都不留)。grilling Q10 的清单:
--   调薪:chooer@ 录第一份月薪、再提一张调薪 → tim@ 批 → 月薪与履历读回;替 CFO 的那一张由 sandra@ 批;
--         拒:提单人批 / cco 批一张 CFO 不是当事人的 / 生效日落在已过账期 / admin@ 替 Sandra 提(没有别人)/
--         Step 0 那条评估侧门 / 直连写月薪。
--   处置:chooer@ 提 FA-2026-0001(收款 50,000 入 1000)→ 在途时关不了审批 → 旧门按名拒 → 提单人批不了 →
--         tim@ 批 → 分录读回 → 凭证页冲它走源路径;拒:FA-2026-0002 零成本 / admin@ 提(没有别人)。
-- 身份:以 postgres 连接;每一步用那个真账号的 JWT、SET LOCAL ROLE authenticated 去调(f9_try / 显式切换),
-- 读回一律 RESET ROLE 之后以 postgres(rolbypassrls = t)读基表。每一格按名 RAISE NOTICE;对不上就 RAISE EXCEPTION。
\pset footer off
BEGIN;
SET LOCAL statement_timeout = '180s';
SELECT current_user AS identity, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) AS bypassrls, now() AS read_at;

CREATE FUNCTION pg_temp.f9_try(p_user uuid, p_sql text) RETURNS text
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

CREATE FUNCTION pg_temp.f9_call(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END;
$f$;

DO $$
DECLARE
    u_chooer uuid := '476bf8c8-c248-4352-9a75-945bf52ca390';   -- finance · EMP-2026-0001
    u_tim    uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';   -- cfo · 人 = EMP-2026-0002
    u_admin  uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin · 人 = EMP-2026-0002(与 tim@ 同一个人)
    u_sandra uuid := '01ae00e4-306f-4527-8537-10291e4750c7';   -- cco · EMP-2026-0004
    e_fu uuid; e_tim uuid; e_sandra uuid; a1 uuid; a0 uuid;
    v jsonb; q uuid; v_msg text; v_je uuid; v_row record;
BEGIN
    SELECT id INTO e_fu FROM employees WHERE code = 'EMP-2026-0006';
    SELECT id INTO e_tim FROM employees WHERE code = 'EMP-2026-0002';
    SELECT id INTO e_sandra FROM employees WHERE code = 'EMP-2026-0004';
    SELECT id INTO a1 FROM fixed_assets WHERE code = 'FA-2026-0001';
    SELECT id INTO a0 FROM fixed_assets WHERE code = 'FA-2026-0002';

    -- ════ 调薪 ════
    -- S1 第一份月薪(ROLE-1 那扇门,照旧):Fu Sheng 5,000 · Tim 8,000 · Sandra 6,000,从 2026-10 起
    PERFORM pg_temp.f9_call(u_chooer, format('SELECT set_initial_salary(%L, 5000, ''2026-10-01'')', e_fu));
    PERFORM pg_temp.f9_call(u_chooer, format('SELECT set_initial_salary(%L, 8000, ''2026-10-01'')', e_tim));
    PERFORM pg_temp.f9_call(u_chooer, format('SELECT set_initial_salary(%L, 6000, ''2026-10-01'')', e_sandra));
    RAISE NOTICE 'S1 first salaries (chooer@, set_initial_salary): %',
        (SELECT string_agg(code || '=' || monthly_salary, ' ' ORDER BY code) FROM employees WHERE monthly_salary IS NOT NULL);

    -- S2 生效日落在已过账的 PAY-2026-0001(2026-07)
    v_msg := pg_temp.f9_try(u_chooer, format('SELECT submit_salary_change_request(%L, 5500, ''2026-07-15'', ''s2'')', e_fu));
    IF position('SALARY_EFFECTIVE_IN_POSTED_PERIOD|PAY-2026-0001' IN v_msg) = 0 THEN RAISE EXCEPTION 'S2 %', v_msg; END IF;
    RAISE NOTICE 'S2 posted period refused: %', v_msg;

    -- S3 chooer@ 提 Fu Sheng 5,000 → 5,500(2026-11 起)
    v := pg_temp.f9_call(u_chooer, format('SELECT submit_salary_change_request(%L, 5500, ''2026-11-01'', ''live proof S3'')', e_fu));
    q := (v->>'request_id')::uuid;
    IF v->>'status' <> 'submitted' OR (SELECT monthly_salary FROM employees WHERE id = e_fu) <> 5000 THEN
        RAISE EXCEPTION 'S3 %', v; END IF;
    RAISE NOTICE 'S3 submitted: % · salary still % · pending row: %', v,
        (SELECT monthly_salary FROM employees WHERE id = e_fu),
        (SELECT row(d.subject_type, d.code, d.blocks_disable, d.fixed_level)::text FROM approval_pending_documents() d WHERE d.doc_id = q);

    -- S4 提单人批 → 她不持批的码;cco 批一张 CFO 不是当事人的 → 同一句(要 CFO 的码)
    v_msg := pg_temp.f9_try(u_chooer, format('SELECT decide_salary_change_request(%L, true)', q));
    IF position('PERMISSION_DENIED|action.approve_review' IN v_msg) = 0 THEN RAISE EXCEPTION 'S4a %', v_msg; END IF;
    v_msg := pg_temp.f9_try(u_sandra, format('SELECT decide_salary_change_request(%L, true)', q));
    IF position('PERMISSION_DENIED|action.approve_review' IN v_msg) = 0 THEN RAISE EXCEPTION 'S4b %', v_msg; END IF;
    RAISE NOTICE 'S4 chooer@ and sandra@ cannot decide it: %', v_msg;

    -- S5 tim@ 批 → 月薪 5,500,履历一行
    v := pg_temp.f9_call(u_tim, format('SELECT decide_salary_change_request(%L, true, ''live proof'')', q));
    SELECT h.effective_date, h.old_monthly_salary, h.new_monthly_salary, h.notes INTO v_row
      FROM employment_history h WHERE h.employee_id = e_fu AND h.change_type = 'salary_change' AND h.new_monthly_salary = 5500;
    IF (SELECT monthly_salary FROM employees WHERE id = e_fu) <> 5500 OR v_row.effective_date <> DATE '2026-11-01' THEN
        RAISE EXCEPTION 'S5 %', v; END IF;
    RAISE NOTICE 'S5 tim@ approved: % · salary now % · history % % → % (%) · log: %', v,
        (SELECT monthly_salary FROM employees WHERE id = e_fu), v_row.effective_date, v_row.old_monthly_salary,
        v_row.new_monthly_salary, v_row.notes,
        (SELECT string_agg(decision || '/' || COALESCE(level::text, '-'), ' ' ORDER BY seq) FROM approval_log WHERE subject_id = q);

    -- S6 替 CFO 提 → 归 cco:tim@ 批不了,sandra@ 批得了
    v := pg_temp.f9_call(u_chooer, format('SELECT submit_salary_change_request(%L, 8800, ''2026-11-01'', ''live proof S6'')', e_tim));
    q := (v->>'request_id')::uuid;
    v_msg := pg_temp.f9_try(u_tim, format('SELECT decide_salary_change_request(%L, true)', q));
    IF v->>'decided_via' <> 'action.hr_reviews' OR position('PERMISSION_DENIED|action.hr_reviews' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'S6a % / %', v, v_msg; END IF;
    v := pg_temp.f9_call(u_sandra, format('SELECT decide_salary_change_request(%L, true)', q));
    IF (SELECT monthly_salary FROM employees WHERE id = e_tim) <> 8800 THEN RAISE EXCEPTION 'S6b %', v; END IF;
    RAISE NOTICE 'S6 CFO''s own raise: tim@ refused (%), sandra@ approved → %', v_msg, v;

    -- S7 admin@(= Tim)替 Sandra 提 → 两条路都被当事人占了,没有别人
    v_msg := pg_temp.f9_try(u_admin, format('SELECT submit_salary_change_request(%L, 6600, ''2026-11-01'', ''s7'')', e_sandra));
    IF position('SALARY_CHANGE_NO_OTHER_DECIDER' IN v_msg) = 0 THEN RAISE EXCEPTION 'S7 %', v_msg; END IF;
    RAISE NOTICE 'S7 admin@ for Sandra refused: %', v_msg;

    -- S8 Step 0 那条侧门:sandra@ 直连插一张 submitted_by = tim@ 的已提交评估
    v_msg := pg_temp.f9_try(u_sandra, format(
        'INSERT INTO performance_reviews (employee_id, review_type, period_start, period_end, reviewer_employee_id, status, '
        'rating_code, summary_text, probation_outcome, new_monthly_salary, salary_effective_date, submitted_at, submitted_by) '
        'VALUES (%L, ''probation'', ''2026-07-01'', ''2026-09-30'', (SELECT id FROM employees WHERE code = ''EMP-2026-0005''), '
        '''submitted'', (SELECT code FROM review_rating_scale ORDER BY code LIMIT 1), ''probe'', ''not_confirm'', 9999, ''2026-11-01'', now(), %L)',
        e_fu, u_tim));
    IF position('REVIEW_DIRECT_INSERT_DRAFT_ONLY' IN v_msg) = 0 THEN RAISE EXCEPTION 'S8 %', v_msg; END IF;
    RAISE NOTICE 'S8 Step 0 review side door closed: %', v_msg;

    -- S9 直连写月薪(ROLE-1 的守卫,重新断言)
    v_msg := pg_temp.f9_try(u_chooer, format('UPDATE employees SET monthly_salary = 1 WHERE id = %L', e_fu));
    IF position('SALARY_DIRECT_WRITE_REFUSED' IN v_msg) = 0 THEN RAISE EXCEPTION 'S9 %', v_msg; END IF;
    RAISE NOTICE 'S9 direct salary write refused: %', v_msg;

    -- ════ 处置 ════
    -- D1 旧门
    v_msg := pg_temp.f9_try(u_chooer, format('SELECT dispose_fixed_asset(%L, CURRENT_DATE, 0, NULL, ''d1'')', a1));
    IF position('ASSET_DISPOSAL_NEEDS_REQUEST|FA-2026-0001' IN v_msg) = 0 THEN RAISE EXCEPTION 'D1 %', v_msg; END IF;
    RAISE NOTICE 'D1 old door refused: %', v_msg;

    -- D2 chooer@ 提 FA-2026-0001,收款 50,000 入 1000
    v := pg_temp.f9_call(u_chooer, format('SELECT submit_asset_disposal_request(%L, 50000, ''1000'', ''live proof D2 sold'')', a1));
    q := (v->>'request_id')::uuid;
    IF v->>'status' <> 'submitted' OR (SELECT status FROM fixed_assets WHERE id = a1) <> 'active'
       OR EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'asset_disposal') THEN RAISE EXCEPTION 'D2 %', v; END IF;
    RAISE NOTICE 'D2 submitted: % · asset still % · pending row: %', v, (SELECT status FROM fixed_assets WHERE id = a1),
        (SELECT row(d.subject_type, d.code, d.amount_base, d.blocks_disable, d.fixed_level)::text FROM approval_pending_documents() d WHERE d.doc_id = q);

    -- D3 在途时关不了审批(子块,回滚)
    BEGIN
        PERFORM set_config('request.jwt.claims', '', true);
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
        RAISE EXCEPTION 'D3 switch went off';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF position('APPROVALS_CANNOT_DISABLE_WITH_PENDING' IN v_msg) = 0 THEN RAISE EXCEPTION 'D3 %', v_msg; END IF;
    RAISE NOTICE 'D3 switch-off refused while pending: %', v_msg;

    -- D4 提单人批
    v_msg := pg_temp.f9_try(u_chooer, format('SELECT decide_asset_disposal_request(%L, true)', q));
    IF position('SELF_APPROVAL_FORBIDDEN|raiser' IN v_msg) = 0 THEN RAISE EXCEPTION 'D4 %', v_msg; END IF;
    RAISE NOTICE 'D4 raiser cannot approve: %', v_msg;

    -- D5 tim@ 批 → 处置,分录读回
    v := pg_temp.f9_call(u_tim, format('SELECT decide_asset_disposal_request(%L, true, ''live proof'')', q));
    SELECT a.disposal_journal_id INTO v_je FROM fixed_assets a WHERE a.id = a1;
    IF (SELECT status FROM fixed_assets WHERE id = a1) <> 'disposed' OR (SELECT source_type FROM journal_entries WHERE id = v_je) <> 'asset_disposal' THEN
        RAISE EXCEPTION 'D5 %', v; END IF;
    RAISE NOTICE 'D5 tim@ approved: % · asset % on % · entry % lines: %', v,
        (SELECT status FROM fixed_assets WHERE id = a1), (SELECT disposal_date FROM fixed_assets WHERE id = a1),
        (SELECT code || ' ' || entry_date FROM journal_entries WHERE id = v_je),
        (SELECT string_agg(ac.code || ' Dr ' || l.debit || ' Cr ' || l.credit, ' · ' ORDER BY ac.code)
           FROM journal_lines l JOIN accounts ac ON ac.id = l.account_id WHERE l.entry_id = v_je);
    RAISE NOTICE 'D5 log: % · reversal route of the disposal entry: %',
        (SELECT string_agg(decision || '/' || COALESCE(level::text, '-') || '/' || COALESCE(amount_base::text, '-'), ' ' ORDER BY seq)
           FROM approval_log WHERE subject_id = q), journal_entry_reversal_route(v_je);
    IF journal_entry_reversal_route(v_je) <> 'source_path' THEN RAISE EXCEPTION 'D5 route'; END IF;

    -- D6 FA-2026-0002 零成本 → 试跑按原话拒;D7 admin@ 提 → 没有别人
    v_msg := pg_temp.f9_try(u_chooer, format('SELECT submit_asset_disposal_request(%L, 0, NULL, ''d6'')', a0));
    IF position('ASSET_HAS_NO_COST|FA-2026-0002' IN v_msg) = 0 THEN RAISE EXCEPTION 'D6 %', v_msg; END IF;
    RAISE NOTICE 'D6 zero-cost refused at submit: %', v_msg;
    v_msg := pg_temp.f9_try(u_admin, format('SELECT submit_asset_disposal_request(%L, 0, NULL, ''d7'')', a0));
    IF position('ASSET_DISPOSAL_NO_OTHER_DECIDER' IN v_msg) = 0 THEN RAISE EXCEPTION 'D7 %', v_msg; END IF;
    RAISE NOTICE 'D7 admin@ refused: %', v_msg;
    IF EXISTS (SELECT 1 FROM asset_disposal_requests WHERE asset_id = a0) THEN RAISE EXCEPTION 'D6/D7 left a row'; END IF;

    RAISE NOTICE 'APR9 LIVE PROOF ALL PASSED (everything below is rolled back)';
END;
$$;
ROLLBACK;
SELECT current_user AS identity,
       (SELECT count(*) FROM salary_change_requests) AS salary_requests_after_rollback,
       (SELECT count(*) FROM asset_disposal_requests) AS disposal_requests_after_rollback,
       (SELECT count(*) FROM employees WHERE monthly_salary IS NOT NULL) AS salaries_set_after_rollback,
       (SELECT status FROM fixed_assets WHERE code = 'FA-2026-0001') AS fa1_after_rollback,
       (SELECT count(*) FROM journal_entries) AS journal_entries_after_rollback;

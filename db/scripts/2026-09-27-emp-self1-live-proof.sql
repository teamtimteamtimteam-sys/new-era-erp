-- db/scripts/2026-09-27-emp-self1-live-proof.sql
-- EMP-SELF-1 · 线上走证(grilling (g),Tim 2026-09-27 接受)。★ 整支一笔事务,最后 ROLLBACK —— 线上一行都不留 ★
--
-- 身份:以 postgres 连接(rolbypassrls = t);每一格切到那个真账号的 JWT、SET LOCAL ROLE authenticated 再做,
-- 并且先断言 auth.uid() 与 current_user 真的切过去了。每一格的结果以 NOTICE 报出;任何一格不符 → RAISE,整支中止(仍然回滚)。
--   P1  fusheng@(仓库,一个 HR / 财务码都不持 —— 最像普通员工的那一个)提:两张请假(unpaid)· 两张医疗申报 · 两张报销
--   P2  sandra@(第二个人)提:一张请假 · 一张医疗申报
--   P3  chooer@ 决定 fusheng 的:请假一批准(带备注)· 医疗一驳回 · 报销一驳回(一级,approvals 开着)
--       tim@(EMP-2026-0002 的【附加账号】)驳回 sandra 的医疗申报;chooer@ 批准 sandra 的请假
--   P4  fusheng 读 my_document_decisions():他在线上原有的决定过的单据 + 这里决定的三张,决定人是人名、备注都在;sandra 那几张一张都没有
--   P5  fusheng 取消请假二(还在等)→ cancelled;取消请假一(已批)→ LEAVE_OWN_CANCEL_PENDING_ONLY;撤回医疗二 → withdrawn;
--       撤回医疗一(已驳回)→ MEDICAL_CLAIM_NOT_SUBMITTED;撤回报销二 → withdrawn
--   P6  各自只看得见自己的:fusheng 撤 sandra 的假 / 医疗 → PERMISSION_DENIED;sandra 的读者只有她的两张,
--       tim@ 做的那张显示成人名(不是账号)
--   P7  一个没有员工档案的身份(随机 sub,不在 auth.users)撤 chooer 的 CLM-2026-0004 → PERMISSION_DENIED
--       (Step 0 实测同一句在迁移之前走到了 UPDATE)
--   P8  sandra@ 的合同:草稿买方合同置成到期 → 改标题 / 改回草稿 → CONTRACT_TERMS_FROZEN|…|expired
--   P9  sandra@ 建一份带计价条款的卖方草稿 → tim@ 读敞口报表:no_active_contracts、0 条头寸
--   K   postgres:事务里分录数不变、审批开关仍开;然后 ROLLBACK
\set ON_ERROR_STOP 1
\pset footer off
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE TEMP TABLE pf (k text PRIMARY KEY, v text);

CREATE FUNCTION pg_temp.p_as(p_user uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
END $f$;

-- 以某人跑一句;返回 'OK:<结果>' 或拒绝原文。每一次先证明身份切过去了。
CREATE FUNCTION pg_temp.p_try(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.p_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM p_user THEN
        RAISE EXCEPTION 'PROOF 身份没有切过去(%, %)', current_user, auth.uid(); END IF;
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN 'OK:' || COALESCE(v, '');
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END $f$;

CREATE FUNCTION pg_temp.g(p_k text) RETURNS text LANGUAGE sql AS $f$ SELECT v FROM pf WHERE k = p_k $f$;
CREATE FUNCTION pg_temp.put(p_k text, p_v text) RETURNS void LANGUAGE sql AS $f$
    INSERT INTO pf VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v $f$;

DO $$
DECLARE
    u_fs  uuid := 'c8116e6c-80db-4a16-be12-24fb6ce6859d';   -- fusheng@
    u_sa  uuid := '01ae00e4-306f-4527-8537-10291e4750c7';   -- sandra@
    u_ce  uuid := '476bf8c8-c248-4352-9a75-945bf52ca390';   -- chooer@
    u_tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';   -- tim@(EMP-2026-0002 的附加账号)
    u_ghost uuid := '00000000-0000-4000-8000-00000000e5e1'; -- 没有员工档案、不在 auth.users
    e_fs uuid; e_sa uuid; v_base text; r text; v_n int; v_je int; v_j jsonb;
BEGIN
    SELECT count(*) INTO v_je FROM journal_entries;
    PERFORM pg_temp.put('je_before', v_je::text);
    SELECT code INTO v_base FROM currencies WHERE is_base;
    e_fs := account_person(u_fs); e_sa := account_person(u_sa);
    -- fusheng 在线上【已经】有决定过的单据(Step 0 读到 CLM-2026-0003,chooer 驳回)—— 读者应当给出它们 + 本走证新决定的三张。
    -- ☞ 第一次跑这支走证时这里写死了 3,于是在 P4 按名停下(PROOF_OWN_EXIT=3,整笔回滚):错的是期望,不是读者。
    PERFORM pg_temp.put('fs_prior', (
        (SELECT count(*) FROM leave_requests WHERE employee_id = e_fs AND deleted_at IS NULL AND decided_by IS NOT NULL)
      + (SELECT count(*) FROM medical_claims WHERE employee_id = e_fs AND deleted_at IS NULL AND decided_by IS NOT NULL)
      + (SELECT count(*) FROM expense_claims WHERE employee_id = e_fs AND decided_by IS NOT NULL))::text);
    RAISE NOTICE 'P0 identity=% bypassrls=% approvals=% je=% fusheng→% sandra→% tim@→%',
        current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user), approvals_enabled(), v_je,
        (SELECT code FROM employees WHERE id = e_fs), (SELECT code FROM employees WHERE id = e_sa),
        (SELECT code FROM employees WHERE id = account_person(u_tim));

    -- ── P1 fusheng 提 ──
    r := pg_temp.p_try(u_fs, format($s$SELECT submit_leave_request(%L, 'unpaid', DATE '2026-12-07', DATE '2026-12-07')->>'request_id'$s$, e_fs));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P1 leave1 %', r; END IF; PERFORM pg_temp.put('fs_lv1', substr(r, 4));
    r := pg_temp.p_try(u_fs, format($s$SELECT submit_leave_request(%L, 'unpaid', DATE '2026-12-08', DATE '2026-12-08')->>'request_id'$s$, e_fs));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P1 leave2 %', r; END IF; PERFORM pg_temp.put('fs_lv2', substr(r, 4));
    r := pg_temp.p_try(u_fs, format($s$SELECT submit_medical_claim(%L, DATE '2026-09-20', 10.00, 'proof clinic 1')->>'claim_id'$s$, e_fs));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P1 med1 %', r; END IF; PERFORM pg_temp.put('fs_mc1', substr(r, 4));
    r := pg_temp.p_try(u_fs, format($s$SELECT submit_medical_claim(%L, DATE '2026-09-21', 12.00, 'proof clinic 2')->>'claim_id'$s$, e_fs));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P1 med2 %', r; END IF; PERFORM pg_temp.put('fs_mc2', substr(r, 4));
    r := pg_temp.p_try(u_fs, format($s$SELECT submit_expense_claim(%L, DATE '2026-09-20', 15.00, %L, 'proof taxi', 'lost it')->>'claim_id'$s$, e_fs, v_base));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P1 exp1 %', r; END IF; PERFORM pg_temp.put('fs_x1', substr(r, 4));
    r := pg_temp.p_try(u_fs, format($s$SELECT submit_expense_claim(%L, DATE '2026-09-21', 16.00, %L, 'proof lunch', 'lost it')->>'claim_id'$s$, e_fs, v_base));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P1 exp2 %', r; END IF; PERFORM pg_temp.put('fs_x2', substr(r, 4));
    RAISE NOTICE 'P1 fusheng submitted: leave % %, medical % %, expense % %',
        (SELECT code FROM leave_requests WHERE id = pg_temp.g('fs_lv1')::uuid), (SELECT code FROM leave_requests WHERE id = pg_temp.g('fs_lv2')::uuid),
        (SELECT code FROM medical_claims WHERE id = pg_temp.g('fs_mc1')::uuid), (SELECT code FROM medical_claims WHERE id = pg_temp.g('fs_mc2')::uuid),
        (SELECT code FROM expense_claims WHERE id = pg_temp.g('fs_x1')::uuid), (SELECT code FROM expense_claims WHERE id = pg_temp.g('fs_x2')::uuid);

    -- ── P2 sandra 提 ──
    r := pg_temp.p_try(u_sa, format($s$SELECT submit_leave_request(%L, 'unpaid', DATE '2026-12-09', DATE '2026-12-09')->>'request_id'$s$, e_sa));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P2 leave %', r; END IF; PERFORM pg_temp.put('sa_lv', substr(r, 4));
    r := pg_temp.p_try(u_sa, format($s$SELECT submit_medical_claim(%L, DATE '2026-09-20', 20.00, 'proof dentist')->>'claim_id'$s$, e_sa));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P2 med %', r; END IF; PERFORM pg_temp.put('sa_mc', substr(r, 4));
    RAISE NOTICE 'P2 sandra submitted: leave %, medical %',
        (SELECT code FROM leave_requests WHERE id = pg_temp.g('sa_lv')::uuid), (SELECT code FROM medical_claims WHERE id = pg_temp.g('sa_mc')::uuid);

    -- ── P3 决定 ──
    r := pg_temp.p_try(u_ce, format($s$SELECT decide_leave_request(%L, true, 'Approved — cover arranged')->>'status'$s$, pg_temp.g('fs_lv1')));
    IF r <> 'OK:approved' THEN RAISE EXCEPTION 'P3 chooer approves fusheng leave1 %', r; END IF;
    r := pg_temp.p_try(u_ce, format($s$SELECT decide_medical_claim(%L, false, 'Receipt missing')->>'status'$s$, pg_temp.g('fs_mc1')));
    IF r <> 'OK:rejected' THEN RAISE EXCEPTION 'P3 chooer rejects fusheng med1 %', r; END IF;
    r := pg_temp.p_try(u_ce, format($s$SELECT decide_expense_claim(%L, false, NULL, NULL, NULL, 'Not a business trip')->>'status'$s$, pg_temp.g('fs_x1')));
    IF r <> 'OK:rejected' THEN RAISE EXCEPTION 'P3 chooer rejects fusheng exp1 %', r; END IF;
    r := pg_temp.p_try(u_tim, format($s$SELECT decide_medical_claim(%L, false, 'Dental is not covered')->>'status'$s$, pg_temp.g('sa_mc')));
    IF r <> 'OK:rejected' THEN RAISE EXCEPTION 'P3 tim@ rejects sandra med %', r; END IF;
    r := pg_temp.p_try(u_ce, format($s$SELECT decide_leave_request(%L, true, 'OK')->>'status'$s$, pg_temp.g('sa_lv')));
    IF r <> 'OK:approved' THEN RAISE EXCEPTION 'P3 chooer approves sandra leave %', r; END IF;
    RAISE NOTICE 'P3 decided: fusheng leave1 approved · med1 rejected · exp1 rejected (chooer@); sandra med rejected (tim@) · leave approved (chooer@)';

    -- ── P4 fusheng 读 ──
    r := pg_temp.p_try(u_fs, $s$SELECT jsonb_agg(to_jsonb(d) ORDER BY d.kind)::text FROM my_document_decisions() d$s$);
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P4 read %', r; END IF;
    v_j := substr(r, 4)::jsonb;
    RAISE NOTICE 'P4 fusheng reads my_document_decisions(): % row(s): %', jsonb_array_length(v_j),
        (SELECT string_agg(x->>'kind' || ' by ' || COALESCE(x->>'decider', '?') || ' · ' || COALESCE(x->>'decision_notes', '-')
                           || ' · self=' || (x->>'self_decided'), ' | ') FROM jsonb_array_elements(v_j) x);
    IF jsonb_array_length(v_j) <> pg_temp.g('fs_prior')::int + 3
       OR (SELECT count(*) FROM jsonb_array_elements(v_j) x
            WHERE (x->>'doc_id') IN (pg_temp.g('fs_lv1'), pg_temp.g('fs_mc1'), pg_temp.g('fs_x1'))) <> 3
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE x->>'decider' IS NULL OR x->>'decision_notes' IS NULL)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE (x->>'doc_id') IN (pg_temp.g('sa_lv'), pg_temp.g('sa_mc'))) THEN
        RAISE EXCEPTION 'P4 fusheng should see his % earlier decided document(s) + the 3 decided here, each with a decider and a note: %', pg_temp.g('fs_prior'), v_j; END IF;
    RAISE NOTICE 'P4 = % earlier decided document(s) on live + the 3 decided here; none of sandra''s', pg_temp.g('fs_prior');
    -- 同一张请假的备注,经 /me 读的那条路(本人行策略,基表)
    r := pg_temp.p_try(u_fs, format($s$SELECT decision_notes FROM leave_requests WHERE id = %L$s$, pg_temp.g('fs_lv1')));
    IF r <> 'OK:Approved — cover arranged' THEN RAISE EXCEPTION 'P4 leave note via own-rows RLS %', r; END IF;
    RAISE NOTICE 'P4 fusheng reads his leave note through leave_requests (own-rows RLS, base table): %', substr(r, 4);

    -- ── P5 取消 / 撤回 ──
    r := pg_temp.p_try(u_fs, format($s$SELECT cancel_leave_request(%L, NULL)->>'status'$s$, pg_temp.g('fs_lv2')));
    IF r <> 'OK:cancelled' THEN RAISE EXCEPTION 'P5 cancel own pending leave %', r; END IF;
    r := pg_temp.p_try(u_fs, format($s$SELECT cancel_leave_request(%L, NULL)->>'status'$s$, pg_temp.g('fs_lv1')));
    IF r NOT LIKE 'LEAVE_OWN_CANCEL_PENDING_ONLY|%|approved' THEN RAISE EXCEPTION 'P5 cancel own approved leave should be refused: %', r; END IF;
    RAISE NOTICE 'P5 cancel own approved leave → %', r;
    r := pg_temp.p_try(u_fs, format($s$SELECT withdraw_medical_claim(%L)->>'status'$s$, pg_temp.g('fs_mc2')));
    IF r <> 'OK:withdrawn' THEN RAISE EXCEPTION 'P5 withdraw own submitted medical %', r; END IF;
    r := pg_temp.p_try(u_fs, format($s$SELECT withdraw_medical_claim(%L)->>'status'$s$, pg_temp.g('fs_mc1')));
    IF r NOT LIKE 'MEDICAL_CLAIM_NOT_SUBMITTED|%|rejected' THEN RAISE EXCEPTION 'P5 withdraw own rejected medical should be refused: %', r; END IF;
    RAISE NOTICE 'P5 withdraw own rejected medical → %', r;
    r := pg_temp.p_try(u_fs, format($s$SELECT withdraw_expense_claim(%L)->>'status'$s$, pg_temp.g('fs_x2')));
    IF r <> 'OK:withdrawn' THEN RAISE EXCEPTION 'P5 withdraw own submitted expense %', r; END IF;
    RAISE NOTICE 'P5 fusheng: leave2 cancelled · med2 withdrawn · exp2 withdrawn';

    -- ── P6 各自只看得见 / 只动得了自己的 ──
    r := pg_temp.p_try(u_fs, format($s$SELECT cancel_leave_request(%L, NULL)->>'status'$s$, pg_temp.g('sa_lv')));
    IF r <> 'PERMISSION_DENIED|module.hr.edit' THEN RAISE EXCEPTION 'P6 fusheng cancels sandra leave %', r; END IF;
    r := pg_temp.p_try(u_fs, format($s$SELECT withdraw_medical_claim(%L)->>'status'$s$, pg_temp.g('sa_mc')));
    IF r <> 'PERMISSION_DENIED|module.hr.edit' THEN RAISE EXCEPTION 'P6 fusheng withdraws sandra medical %', r; END IF;
    r := pg_temp.p_try(u_sa, $s$SELECT jsonb_agg(to_jsonb(d) ORDER BY d.kind)::text FROM my_document_decisions() d$s$);
    v_j := substr(r, 4)::jsonb;
    RAISE NOTICE 'P6 sandra reads my_document_decisions(): % row(s): %', jsonb_array_length(v_j),
        (SELECT string_agg(x->>'kind' || ' by ' || COALESCE(x->>'decider', '?') || ' · ' || COALESCE(x->>'decision_notes', '-'), ' | ')
           FROM jsonb_array_elements(v_j) x);
    IF jsonb_array_length(v_j) <> 2
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) x WHERE (x->>'doc_id') NOT IN (pg_temp.g('sa_lv'), pg_temp.g('sa_mc')))
       OR (SELECT x->>'decider' FROM jsonb_array_elements(v_j) x WHERE x->>'doc_id' = pg_temp.g('sa_mc'))
          IS DISTINCT FROM (SELECT COALESCE(NULLIF(btrim(preferred_name), ''), legal_name) FROM employees WHERE id = account_person(u_tim)) THEN
        RAISE EXCEPTION 'P6 sandra should see only her 2, and tim@''s decision as the person: %', v_j; END IF;
    RAISE NOTICE 'P6 fusheng → sandra''s leave / medical: PERMISSION_DENIED|module.hr.edit (both)';

    -- ── P7 没有员工档案的身份 ──
    r := pg_temp.p_try(u_ghost, format($s$SELECT withdraw_expense_claim(%L)->>'status'$s$, (SELECT id FROM expense_claims WHERE code = 'CLM-2026-0004')));
    IF r <> 'PERMISSION_DENIED|module.finance.edit' THEN RAISE EXCEPTION 'P7 unlinked identity withdraws CLM-2026-0004 %', r; END IF;
    RAISE NOTICE 'P7 unlinked identity withdraw_expense_claim(CLM-2026-0004) → % (status still %)', r,
        (SELECT status FROM expense_claims WHERE code = 'CLM-2026-0004');

    -- ── P8 结束了的合同,表头冻结 ──
    r := pg_temp.p_try(u_sa, format($s$INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
          VALUES (%L, 'supply', 'proof ended', DATE '2026-09-01', 'draft') RETURNING id::text$s$,
          (SELECT id FROM suppliers WHERE deleted_at IS NULL ORDER BY code LIMIT 1)));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P8 draft %', r; END IF; PERFORM pg_temp.put('c_end', substr(r, 4));
    r := pg_temp.p_try(u_sa, format($s$UPDATE contracts SET status = 'expired' WHERE id = %L RETURNING status$s$, pg_temp.g('c_end')));
    IF r <> 'OK:expired' THEN RAISE EXCEPTION 'P8 draft → expired %', r; END IF;
    r := pg_temp.p_try(u_sa, format($s$UPDATE contracts SET title = 'late edit' WHERE id = %L RETURNING title$s$, pg_temp.g('c_end')));
    IF r NOT LIKE 'CONTRACT_TERMS_FROZEN|%|expired' THEN RAISE EXCEPTION 'P8 header edit on expired should be refused: %', r; END IF;
    RAISE NOTICE 'P8 sandra edits an expired contract''s title → %', r;
    r := pg_temp.p_try(u_sa, format($s$UPDATE contracts SET status = 'draft' WHERE id = %L RETURNING status$s$, pg_temp.g('c_end')));
    IF r NOT LIKE 'CONTRACT_TERMS_FROZEN|%|expired' THEN RAISE EXCEPTION 'P8 expired → draft should be refused: %', r; END IF;
    RAISE NOTICE 'P8 sandra sets it back to draft → %', r;

    -- ── P9 敞口报表不数草稿 ──
    r := pg_temp.p_try(u_sa, format($s$INSERT INTO contracts (customer_id, kind, title, effective_from, status)
          VALUES (%L, 'offtake', 'proof sell draft', DATE '2026-09-01', 'draft') RETURNING id::text$s$,
          (SELECT id FROM customers WHERE deleted_at IS NULL ORDER BY code LIMIT 1)));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P9 sell draft %', r; END IF; PERFORM pg_temp.put('c_sell', substr(r, 4));
    r := pg_temp.p_try(u_sa, format($s$INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
          VALUES (%L, 'ni', 'shipment', 1, 'LME', 90) RETURNING id::text$s$, pg_temp.g('c_sell')));
    IF r NOT LIKE 'OK:%' THEN RAISE EXCEPTION 'P9 pricing term on the draft %', r; END IF;
    r := pg_temp.p_try(u_tim, $s$SELECT jsonb_build_object('state', price_exposure_report()->'sell_side'->>'state',
          'positions', jsonb_array_length(price_exposure_report()->'sell_side'->'positions'),
          'coverage', price_exposure_report()->'coverage')::text$s$);
    v_j := substr(r, 4)::jsonb;
    IF v_j->>'state' <> 'no_active_contracts' OR (v_j->>'positions')::int <> 0 THEN
        RAISE EXCEPTION 'P9 exposure should ignore the draft: %', r; END IF;
    RAISE NOTICE 'P9 tim@ reads price_exposure_report with a sell draft carrying a pricing term: %', v_j;

    -- ── K 收尾 ──
    SELECT count(*) INTO v_n FROM journal_entries;
    IF v_n <> v_je THEN RAISE EXCEPTION 'K journal entries moved % → %', v_je, v_n; END IF;
    IF NOT approvals_enabled() THEN RAISE EXCEPTION 'K approvals switched off'; END IF;
    RAISE NOTICE 'K inside the transaction: journal entries % → % · approvals on · approval_log % (rolled back next)',
        v_je, v_n, (SELECT count(*) FROM approval_log);
END $$;

ROLLBACK;
SELECT 'PROOF ROLLED BACK' AS done, now() AS at;

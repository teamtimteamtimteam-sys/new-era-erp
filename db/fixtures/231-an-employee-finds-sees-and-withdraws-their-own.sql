-- 231 EMP-SELF-1:员工看得见自己的请假与报销是谁决定的、为什么;撤得掉自己还在等的;没有员工档案的账号什么都动不了(2026-09-27)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(EMP-SELF-1 grilling Q1–Q8,Tim 2026-09-27 全部接受)
--   N  ★★ Q9 · Q2:五支 NULL-blind 的写 —— 没有员工档案的账号(current_user_employee() 是 NULL)
--        submit_leave_request · submit_medical_claim · submit_expense_claim · cancel_leave_request ·
--        withdraw_expense_claim,以及生下来就硬的 withdraw_medical_claim,对【别人的】单据一律 PERMISSION_DENIED;
--        有档案的员工传 NULL 的 p_employee_id 也一律 PERMISSION_DENIED(而不是靠下一行的 EMPLOYEE_NOT_FOUND)
--   C  ★ Q1:本人撤自己还在等的假 → cancelled;本人撤自己【已批】的假 → LEAVE_OWN_CANCEL_PENDING_ONLY|编号|approved,
--        一个字不改;别人撤 → PERMISSION_DENIED;HR(module.hr.edit)撤已批的假照走
--   W  ★ G3b · Q8:本人撤自己 submitted 的医疗申报 → withdrawn(withdrawn_at 有值,decided_* 不碰);再撤 / 撤已批的
--        → MEDICAL_CLAIM_NOT_SUBMITTED|编号|状态;别人撤 → PERMISSION_DENIED;HR 臂照走;表约束钉住 withdrawn ⇔ withdrawn_at
--   D  ★★ G2 · Q3–Q5:my_document_decisions() —— 本人读到三种单据的决定人(人,不是账号:附加账号显示它主人的名字;
--        preferred_name 优先)、时刻、备注;自己撤掉的假 self_decided = t;没决定过的单据不出现;
--        另一个员工读不到本人的任何一行;没有档案的调用者 0 行;DEFINER、authenticated 调得到、anon 调不到
--   H  ★ Q7:到期 / 终止的合同表头任何一列、包括状态与软删,按名拒 CONTRACT_TERMS_FROZEN|编号|expired / terminated;
--        草稿直接置成终止照走;草稿的表头照常改得动
--   E  ★ Q6:敞口报表只算生效中的合同 —— 一份带计价条款的草稿 → no_active_contracts、0 条头寸;
--        加一份生效中的合同(无条款)→ no_pricing_terms(草稿那条不算);给它一条条款 → 正好 1 条头寸、是它;
--        暂停它 → 回到 no_active_contracts
--   I  ★ 故障注入:把 withdraw_medical_claim 的门换回裸的 NOT (… OR …),没有档案的账号就撤得掉别人的申报 ——
--        COALESCE 是承重的
--
-- 自带数据(README 第 2 条);锁期与系统起始日不依赖(单据直写、决定走驳回那一支,不过账、不算额度)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f231_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 以某人的身份跑一句,返回 'OK' 或那一句拒绝
CREATE FUNCTION pg_temp.f231_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f231_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

-- 以某人的身份读 my_document_decisions(),整张结果成一个 jsonb 数组
CREATE FUNCTION pg_temp.f231_read(p_user uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f231_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM p_user THEN
        RAISE EXCEPTION 'FIXTURE 231 布景失败:身份没有切过去(%, %)', current_user, auth.uid(); END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(d)), '[]'::jsonb) INTO v FROM my_document_decisions() d;
    EXECUTE 'RESET ROLE';
    RETURN v;
END;
$f$;

DO $$
DECLARE
    u_emp   uuid := gen_random_uuid();   -- 一个普通员工:一个码都不持
    u_other uuid := gen_random_uuid();   -- 另一个普通员工
    u_hr    uuid := gen_random_uuid();   -- HR:module.hr.edit + action.decide_hr_requests
    u_hr2   uuid := gen_random_uuid();   -- HR 那个人的【附加账号】(APR-ROUTE-1 Batch B)
    u_fin   uuid := gen_random_uuid();   -- 财务:决定报销
    u_cco   uuid := gen_random_uuid();   -- 合同:action.contract_terms
    u_none  uuid := gen_random_uuid();   -- ★ 有账号、没有员工档案、没有角色
    r_hr uuid; r_fin uuid; r_cco uuid;
    e_emp uuid := gen_random_uuid(); e_other uuid := gen_random_uuid();
    e_hr uuid := gen_random_uuid(); e_fin uuid := gen_random_uuid();
    lv_p uuid := gen_random_uuid(); lv_p2 uuid := gen_random_uuid(); lv_a uuid := gen_random_uuid();
    lv_r uuid := gen_random_uuid(); lv_oth uuid := gen_random_uuid();
    mc_s1 uuid := gen_random_uuid(); mc_s2 uuid := gen_random_uuid(); mc_a uuid := gen_random_uuid();
    mc_r uuid := gen_random_uuid(); mc_alt uuid := gen_random_uuid(); mc_inj uuid := gen_random_uuid();
    x_s uuid := gen_random_uuid(); x_r uuid := gen_random_uuid();
    v_base text; v_sup uuid; v_cust uuid;
    c_d uuid; c_d_code text; c_d2 uuid; c_sell_d uuid; c_act uuid; c_act_code text;
    v_msg text; v_n int; v_r jsonb; v_row jsonb;
    rep jsonb := '{}'::jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF v_base IS NULL THEN RAISE EXCEPTION 'FIXTURE 231 布景失败:currencies 里没有本位币'; END IF;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_emp, now()), (u_other, now()), (u_hr, now()), (u_hr2, now()), (u_fin, now()), (u_cco, now()), (u_none, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx231-hr','f','f',true)  RETURNING id INTO r_hr;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx231-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx231-cco','f','f',true) RETURNING id INTO r_cco;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_hr, c FROM unnest(ARRAY['module.hr.edit', 'module.hr.view', 'action.decide_hr_requests']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_fin, c FROM unnest(ARRAY['module.finance.view', 'module.finance.edit', 'data.view_prices']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_cco, c FROM unnest(ARRAY['module.pricing.view', 'data.view_prices', 'data.view_purchase_prices',
        'action.contract_terms', 'module.suppliers.view', 'module.customers.view']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_hr, r_hr), (u_hr2, r_hr), (u_fin, r_fin), (u_cco, r_cco);

    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_emp,   'FX231-EMP',   'FX231 Employee Legal', 'Emmy',    'full_time', 'office', DATE '2020-01-01', u_emp),
        (e_other, 'FX231-OTHER', 'FX231 Other Legal',    NULL,      'full_time', 'office', DATE '2020-01-01', u_other),
        (e_hr,    'FX231-HR',    'FX231 HR Legal',       'Harriet', 'full_time', 'office', DATE '2020-01-01', u_hr),
        (e_fin,   'FX231-FIN',   'FX231 Finance Legal',  '  ',      'full_time', 'office', DATE '2020-01-01', u_fin);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_hr2, e_hr);

    INSERT INTO leave_types (code, name_en, name_zh, is_accrued, is_active) VALUES ('fx231-lv', 'f', 'f', false, true);
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by) VALUES
        (lv_p,   'FX231-LV-P',   e_emp,   'fx231-lv', DATE '2030-03-04', DATE '2030-03-04', 1, 'pending', u_emp),
        (lv_p2,  'FX231-LV-P2',  e_emp,   'fx231-lv', DATE '2030-03-05', DATE '2030-03-05', 1, 'pending', u_emp),
        (lv_r,   'FX231-LV-R',   e_emp,   'fx231-lv', DATE '2030-03-06', DATE '2030-03-06', 1, 'pending', u_emp),
        (lv_oth, 'FX231-LV-OTH', e_other, 'fx231-lv', DATE '2030-03-06', DATE '2030-03-06', 1, 'pending', u_other);
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status,
                                decided_at, decided_by, decision_notes, created_by)
    VALUES (lv_a, 'FX231-LV-A', e_emp, 'fx231-lv', DATE '2030-03-07', DATE '2030-03-07', 1, 'approved',
            now(), u_hr, 'ok', u_emp);

    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status, created_by) VALUES
        (mc_s1,  'FX231-MC-S1',  e_emp, DATE '2030-03-04', 2030, 10, 'submitted', u_emp),
        (mc_s2,  'FX231-MC-S2',  e_emp, DATE '2030-03-04', 2030, 10, 'submitted', u_emp),
        (mc_r,   'FX231-MC-R',   e_emp, DATE '2030-03-04', 2030, 10, 'submitted', u_emp),
        (mc_inj, 'FX231-MC-INJ', e_emp, DATE '2030-03-04', 2030, 10, 'submitted', u_emp);
    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status,
                                decided_at, decided_by, decision_notes, created_by) VALUES
        (mc_a,   'FX231-MC-A',   e_emp, DATE '2030-03-04', 2030, 10, 'approved', now(), u_hr,  'fine', u_emp),
        -- 由 HR 那个人的【附加账号】决定的一张:读者应当显示它主人的名字
        (mc_alt, 'FX231-MC-ALT', e_emp, DATE '2030-03-04', 2030, 10, 'rejected', now(), u_hr2, 'alt says no', u_emp);

    INSERT INTO expense_claims (id, code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, status, created_by) VALUES
        (x_s, 'FX231-X-S', e_emp, DATE '2030-03-01', 20.00, v_base, 'taxi', 'none', 'submitted', u_emp),
        (x_r, 'FX231-X-R', e_emp, DATE '2030-03-01', 30.00, v_base, 'lunch', 'none', 'submitted', u_emp);

    -- ══════════════ N · 没有员工档案的账号,与 NULL 的 p_employee_id ══════════════
    IF (SELECT account_person(u_none)) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 231 布景失败:u_none 不该属于任何人'; END IF;
    v_msg := pg_temp.f231_try(u_none, format($s$SELECT submit_leave_request(%L, 'fx231-lv', DATE '2030-04-01', DATE '2030-04-01')$s$, e_emp));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 231N1 失败:没有档案的账号替别人请假应当按码拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_none, format($s$SELECT submit_medical_claim(%L, DATE '2030-04-01', 10)$s$, e_emp));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 231N2 失败:没有档案的账号替别人报医疗应当按码拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_none, format($s$SELECT submit_expense_claim(%L, DATE '2030-03-01', 10, %L, 'x', 'none')$s$, e_emp, v_base));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.view' THEN
        RAISE EXCEPTION 'FIXTURE 231N3 失败:没有档案的账号替别人报销应当按码拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_none, format($s$SELECT cancel_leave_request(%L, 'x')$s$, lv_p2));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' OR (SELECT status FROM leave_requests WHERE id = lv_p2) <> 'pending' THEN
        RAISE EXCEPTION 'FIXTURE 231N4 失败:没有档案的账号撤别人的假应当按码拒、一个字不改,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_none, format($s$SELECT withdraw_expense_claim(%L)$s$, x_s));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' OR (SELECT status FROM expense_claims WHERE id = x_s) <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 231N5 失败:没有档案的账号撤别人的报销应当按码拒、一个字不改,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_none, format($s$SELECT withdraw_medical_claim(%L)$s$, mc_s2));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' OR (SELECT status FROM medical_claims WHERE id = mc_s2) <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 231N6 失败:没有档案的账号撤别人的医疗申报应当按码拒、一个字不改,实得 %', v_msg; END IF;
    -- 有档案的员工传 NULL:门自己拒,不靠下一行
    v_msg := pg_temp.f231_try(u_emp, $s$SELECT submit_leave_request(NULL, 'fx231-lv', DATE '2030-04-01', DATE '2030-04-01')$s$);
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 231N7 失败:NULL 的员工应当被门拒(不是 EMPLOYEE_NOT_FOUND),实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_emp, $s$SELECT submit_medical_claim(NULL, DATE '2030-04-01', 10)$s$);
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 231N8 失败:NULL 的员工应当被门拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_emp, format($s$SELECT submit_expense_claim(NULL, DATE '2030-03-01', 10, %L, 'x', 'none')$s$, v_base));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.view' THEN
        RAISE EXCEPTION 'FIXTURE 231N9 失败:NULL 的员工应当被门拒,实得 %', v_msg; END IF;
    -- 对照:本人替自己提,门放行(走到 INSERT —— 证明上面那些拒绝不是"谁都拒")
    v_msg := pg_temp.f231_try(u_emp, format($s$SELECT submit_medical_claim(%L, DATE '2030-04-01', 12)$s$, e_emp));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 231N10 失败:本人替自己报医疗应当照走,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('N_null_blind_writes_closed', true);

    -- ══════════════ C · 撤自己的假 ══════════════
    v_msg := pg_temp.f231_try(u_emp, format($s$SELECT cancel_leave_request(%L, 'plans changed')$s$, lv_p));
    IF v_msg <> 'OK' OR (SELECT status FROM leave_requests WHERE id = lv_p) <> 'cancelled'
       OR (SELECT decided_by FROM leave_requests WHERE id = lv_p) IS DISTINCT FROM u_emp THEN
        RAISE EXCEPTION 'FIXTURE 231C1 失败:本人撤自己还在等的假应当成 cancelled,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_emp, format($s$SELECT cancel_leave_request(%L, 'x')$s$, lv_a));
    IF v_msg <> 'LEAVE_OWN_CANCEL_PENDING_ONLY|FX231-LV-A|approved'
       OR (SELECT status FROM leave_requests WHERE id = lv_a) <> 'approved'
       OR (SELECT decided_by FROM leave_requests WHERE id = lv_a) IS DISTINCT FROM u_hr THEN
        RAISE EXCEPTION 'FIXTURE 231C2 失败:本人撤自己已批的假应当按名拒、一个字不改,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_other, format($s$SELECT cancel_leave_request(%L, 'x')$s$, lv_p2));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 231C3 失败:别人撤本人的假应当按码拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_hr, format($s$SELECT cancel_leave_request(%L, 'hr cancels')$s$, lv_a));
    IF v_msg <> 'OK' OR (SELECT status FROM leave_requests WHERE id = lv_a) <> 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 231C4 失败:HR 撤已批的假应当照走,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('C_own_cancel_pending_only', true);

    -- ══════════════ W · 撤自己的医疗申报 ══════════════
    v_msg := pg_temp.f231_try(u_emp, format($s$SELECT withdraw_medical_claim(%L)$s$, mc_s1));
    IF v_msg <> 'OK' OR (SELECT status FROM medical_claims WHERE id = mc_s1) <> 'withdrawn'
       OR (SELECT withdrawn_at FROM medical_claims WHERE id = mc_s1) IS NULL
       OR (SELECT decided_by FROM medical_claims WHERE id = mc_s1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 231W1 失败:本人撤自己 submitted 的医疗申报应当成 withdrawn、不碰 decided_*,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_emp, format($s$SELECT withdraw_medical_claim(%L)$s$, mc_s1));
    IF v_msg <> 'MEDICAL_CLAIM_NOT_SUBMITTED|FX231-MC-S1|withdrawn' THEN
        RAISE EXCEPTION 'FIXTURE 231W2 失败:再撤一次应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_emp, format($s$SELECT withdraw_medical_claim(%L)$s$, mc_a));
    IF v_msg <> 'MEDICAL_CLAIM_NOT_SUBMITTED|FX231-MC-A|approved' OR (SELECT status FROM medical_claims WHERE id = mc_a) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 231W3 失败:撤已批的医疗申报应当按名拒、一个字不改,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_other, format($s$SELECT withdraw_medical_claim(%L)$s$, mc_s2));
    IF v_msg <> 'PERMISSION_DENIED|module.hr.edit' THEN
        RAISE EXCEPTION 'FIXTURE 231W4 失败:别人撤本人的医疗申报应当按码拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_hr, format($s$SELECT withdraw_medical_claim(%L)$s$, mc_s2));
    IF v_msg <> 'OK' OR (SELECT status FROM medical_claims WHERE id = mc_s2) <> 'withdrawn' THEN
        RAISE EXCEPTION 'FIXTURE 231W5 失败:HR 臂(module.hr.edit)应当撤得掉,实得 %', v_msg; END IF;
    BEGIN
        UPDATE medical_claims SET status = 'withdrawn' WHERE id = mc_r;   -- 没有 withdrawn_at
        RAISE EXCEPTION 'FIXTURE 231W6 失败:withdrawn 而没有 withdrawn_at 应当被表约束拒';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    rep := rep || jsonb_build_object('W_withdraw_medical', true);

    -- ══════════════ D · 谁决定的、为什么 ══════════════
    -- 真的决定三张(驳回那一支,不过账、不算额度)
    PERFORM pg_temp.f231_as(u_hr);
    PERFORM decide_leave_request(lv_r, false, 'no cover that day');
    PERFORM decide_medical_claim(mc_r, false, 'receipt unreadable');
    PERFORM pg_temp.f231_as(u_fin);
    PERFORM decide_expense_claim(x_r, false, NULL, NULL, NULL, 'personal meal');
    PERFORM set_config('request.jwt.claims', '', true);

    v_r := pg_temp.f231_read(u_emp);
    -- 本人的决定过的单据:LV-R · LV-P(自己撤的)· LV-A(HR 撤的)· MC-R · MC-A · MC-ALT · X-R;没决定过的不出现
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_r);
    IF v_n <> 7 THEN RAISE EXCEPTION 'FIXTURE 231D1 失败:本人应当读到 7 张决定过的单据,实得 % —— %', v_n, v_r; END IF;
    SELECT x INTO v_row FROM jsonb_array_elements(v_r) x WHERE (x->>'doc_id')::uuid = lv_r;
    IF v_row->>'kind' <> 'leave_request' OR v_row->>'decider' <> 'Harriet' OR v_row->>'decision_notes' <> 'no cover that day'
       OR (v_row->>'self_decided')::boolean OR v_row->>'decided_at' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 231D2 失败:驳回的假应当显示 Harriet(preferred_name)与备注,实得 %', v_row; END IF;
    SELECT x INTO v_row FROM jsonb_array_elements(v_r) x WHERE (x->>'doc_id')::uuid = mc_r;
    IF v_row->>'kind' <> 'medical_claim' OR v_row->>'decider' <> 'Harriet' OR v_row->>'decision_notes' <> 'receipt unreadable' THEN
        RAISE EXCEPTION 'FIXTURE 231D3 失败:驳回的医疗申报应当显示决定人与备注,实得 %', v_row; END IF;
    SELECT x INTO v_row FROM jsonb_array_elements(v_r) x WHERE (x->>'doc_id')::uuid = x_r;
    IF v_row->>'kind' <> 'expense_claim' OR v_row->>'decider' <> 'FX231 Finance Legal' OR v_row->>'decision_notes' <> 'personal meal' THEN
        RAISE EXCEPTION 'FIXTURE 231D4 失败:驳回的报销应当显示决定人(空白的 preferred_name 回落到 legal_name)与备注,实得 %', v_row; END IF;
    SELECT x INTO v_row FROM jsonb_array_elements(v_r) x WHERE (x->>'doc_id')::uuid = mc_alt;
    IF v_row->>'decider' <> 'Harriet' THEN
        RAISE EXCEPTION 'FIXTURE 231D5 失败:附加账号做的决定应当显示它主人的名字(人,不是账号),实得 %', v_row; END IF;
    SELECT x INTO v_row FROM jsonb_array_elements(v_r) x WHERE (x->>'doc_id')::uuid = lv_p;
    IF v_row->>'decider' <> 'Emmy' OR NOT (v_row->>'self_decided')::boolean OR v_row->>'decision_notes' <> 'plans changed' THEN
        RAISE EXCEPTION 'FIXTURE 231D6 失败:自己撤的假应当显示本人、self_decided = t、理由,实得 %', v_row; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r) x WHERE (x->>'doc_id')::uuid IN (lv_p2, mc_s1, x_s, lv_oth)) THEN
        RAISE EXCEPTION 'FIXTURE 231D7 失败:没决定过 / 撤回的 / 别人的单据不该出现'; END IF;
    -- 另一个员工:读不到本人的任何一行
    v_r := pg_temp.f231_read(u_other);
    IF jsonb_array_length(v_r) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 231D8 失败:另一个员工(自己一张都没决定过)应当读到 0 行,实得 %', v_r; END IF;
    -- HR:持 hr.view 也只读到【他自己的】—— 这支读者不是 HR 的列表
    v_r := pg_temp.f231_read(u_hr);
    IF jsonb_array_length(v_r) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 231D9 失败:这支读者只给调用者自己的单据,HR 也不例外,实得 %', v_r; END IF;
    -- 没有档案的调用者:0 行(不是全部)
    v_r := pg_temp.f231_read(u_none);
    IF jsonb_array_length(v_r) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 231D10 失败:没有员工档案的调用者应当读到 0 行,实得 %', jsonb_array_length(v_r); END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.my_document_decisions()'::regprocedure) THEN
        RAISE EXCEPTION 'FIXTURE 231D11 失败:my_document_decisions 必须是 SECURITY DEFINER(决定人的员工行 RLS 读不到)'; END IF;
    IF NOT has_function_privilege('authenticated', 'public.my_document_decisions()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.my_document_decisions()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 231D12 失败:authenticated 要调得到、anon 调不到'; END IF;
    rep := rep || jsonb_build_object('D_who_decided_and_why', true);

    -- ══════════════ E · 敞口报表只算生效中的合同 ══════════════
    DELETE FROM contract_pricing_terms;
    DELETE FROM contracts;
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZFIX231-C', 'fixture 231 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX231-S', 'fixture 231 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    PERFORM pg_temp.f231_as(u_fin);
    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'no_contracts' THEN
        RAISE EXCEPTION 'FIXTURE 231E0 失败:零份合同应当是 no_contracts,实得 %', v_r->'sell_side'->>'state'; END IF;
    INSERT INTO contracts (code, customer_id, kind, title, effective_from, status)
    VALUES ('F231-DRAFT', v_cust, 'offtake', 'f231 draft', DATE '2026-01-01', 'draft') RETURNING id INTO c_sell_d;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (c_sell_d, 'ni', 'shipment', 1, 'LME', 90);
    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'no_active_contracts'
       OR jsonb_array_length(v_r->'sell_side'->'positions') <> 0
       OR (v_r->'coverage'->>'contracts_total')::int <> 1
       OR (v_r->'coverage'->>'contracts_active')::int <> 0
       OR (v_r->'coverage'->>'contracts_with_pricing_terms')::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 231E1 失败:一份带计价条款的草稿不是头寸 —— 应当 no_active_contracts、0 条、生效 0,实得 %', v_r; END IF;
    INSERT INTO contracts (code, customer_id, kind, title, effective_from, status)
    VALUES ('F231-ACTIVE', v_cust, 'offtake', 'f231 active', DATE '2026-01-01', 'active') RETURNING id, code INTO c_act, c_act_code;
    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'no_pricing_terms' OR (v_r->'coverage'->>'contracts_active')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 231E2 失败:生效中的合同没有条款(草稿那条不算)应当是 no_pricing_terms,实得 %', v_r; END IF;
    INSERT INTO contract_pricing_terms (contract_id, metal, base_event, qp_months, index_code, payable_pct)
    VALUES (c_act, 'ni', 'shipment', 1, 'LME', 90);
    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'open_positions_listed'
       OR jsonb_array_length(v_r->'sell_side'->'positions') <> 1
       OR v_r->'sell_side'->'positions'->0->>'contract_code' <> c_act_code THEN
        RAISE EXCEPTION 'FIXTURE 231E3 失败:应当正好 1 条头寸、是生效中的那一份,实得 %', v_r->'sell_side'; END IF;
    UPDATE contracts SET status = 'suspended' WHERE id = c_act;
    v_r := price_exposure_report();
    IF v_r->'sell_side'->>'state' <> 'no_active_contracts' OR jsonb_array_length(v_r->'sell_side'->'positions') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 231E4 失败:暂停的合同不是头寸,应当回到 no_active_contracts,实得 %', v_r->'sell_side'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    rep := rep || jsonb_build_object('E_exposure_active_only', true);

    -- ══════════════ H · 结束了的合同,表头也冻结 ══════════════
    PERFORM pg_temp.f231_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'f231 ended', CURRENT_DATE, 'draft') RETURNING id, code INTO c_d, c_d_code;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
    VALUES (v_sup, 'supply', 'f231 abandoned', CURRENT_DATE, 'draft') RETURNING id INTO c_d2;
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET title = 'draft edit' WHERE id = %L$s$, c_d));
    IF v_msg <> 'OK' OR (SELECT title FROM contracts WHERE id = c_d) <> 'draft edit' THEN
        RAISE EXCEPTION 'FIXTURE 231H0 失败:草稿的表头应当照常改得动,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET status = 'terminated' WHERE id = %L$s$, c_d2));
    IF v_msg <> 'OK' OR (SELECT status FROM contracts WHERE id = c_d2) <> 'terminated' THEN
        RAISE EXCEPTION 'FIXTURE 231H1 失败:草稿直接置成终止应当照走(Q7),实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET status = 'expired' WHERE id = %L$s$, c_d));
    IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 231H2 失败:草稿置成到期应当照走,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET title = 'late edit' WHERE id = %L$s$, c_d));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_d_code || '|expired' OR (SELECT title FROM contracts WHERE id = c_d) <> 'draft edit' THEN
        RAISE EXCEPTION 'FIXTURE 231H3 失败:到期合同改标题应当按名拒 expired,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET status = 'draft' WHERE id = %L$s$, c_d));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_d_code || '|expired' THEN
        RAISE EXCEPTION 'FIXTURE 231H4 失败:到期合同改回草稿应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET status = 'terminated' WHERE id = %L$s$, c_d));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_d_code || '|expired' THEN
        RAISE EXCEPTION 'FIXTURE 231H5 失败:到期改终止也是一次表头改动,应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET deleted_at = now() WHERE id = %L$s$, c_d));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || c_d_code || '|expired' OR (SELECT deleted_at FROM contracts WHERE id = c_d) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 231H6 失败:到期合同软删应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f231_try(u_cco, format($s$UPDATE contracts SET notes = 'x' WHERE id = %L$s$, c_d2));
    IF v_msg <> 'CONTRACT_TERMS_FROZEN|' || (SELECT code FROM contracts WHERE id = c_d2) || '|terminated' THEN
        RAISE EXCEPTION 'FIXTURE 231H7 失败:终止合同改备注应当按名拒 terminated,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('H_ended_header_frozen', true);

    -- ══════════════ I · 故障注入:COALESCE 是承重的 ══════════════
    CREATE OR REPLACE FUNCTION public.withdraw_medical_claim(p_claim_id uuid)
     RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
    AS $inj$
    DECLARE v_c record;
    BEGIN
        SELECT * INTO v_c FROM medical_claims WHERE id = p_claim_id AND deleted_at IS NULL FOR UPDATE;
        IF NOT (has_permission('module.hr.edit') OR v_c.employee_id = current_user_employee()) THEN
            RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.edit';
        END IF;
        UPDATE medical_claims SET status = 'withdrawn', withdrawn_at = now() WHERE id = p_claim_id;
        RETURN '{}'::jsonb;
    END;
    $inj$;
    v_msg := pg_temp.f231_try(u_none, format($s$SELECT withdraw_medical_claim(%L)$s$, mc_inj));
    IF v_msg <> 'OK' OR (SELECT status FROM medical_claims WHERE id = mc_inj) <> 'withdrawn' THEN
        RAISE EXCEPTION 'FIXTURE 231I 失败:门换回裸的 NOT (… OR …) 时,没有档案的账号应当撤得掉(证明 N6 那道拒绝靠的就是 COALESCE),实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('I_coalesce_is_load_bearing', true);

    RAISE NOTICE 'FIXTURE 231 全部通过:N 五支写 + 新函数对没有档案的账号关上 · C 本人只撤还在等的假 · W 撤医疗申报 · D 谁决定的、为什么 · E 敞口只算生效中的合同 · H 结束了的合同表头冻结 · I 注入 %', rep::text;
END;
$$;
ROLLBACK;

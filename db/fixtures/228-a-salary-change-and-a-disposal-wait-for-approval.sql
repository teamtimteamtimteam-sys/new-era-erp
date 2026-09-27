-- 228 APR-9:调薪与固定资产处置 —— 批准之前什么都不生效;绩效评估的侧门关上(2026-09-27)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(APR-9 grilling Q1–Q10,Tim 2026-09-27 全部接受)
--   A  登记:名册里处置只有二级一行(finance.view + view_prices),调薪【不在】名册里;在途清单两支(处置 blocks_disable、
--        fixed_level 2;调薪 blocks_disable = false、fixed_level NULL、金额 NULL);operations_now 两支;内层算子
--        authenticated 调不到;两张申请表一条写策略都没有;两支守卫挂上;review_approval_code ≡ pay_decision_code
--   B  ★★ 绩效评估的侧门(Step 0 实测的那条路):cco 直连插一张 submitted、submitted_by = CFO 的评估 →
--        REVIEW_DIRECT_INSERT_DRAFT_ONLY;草稿照建;直连改 status / submitted_by → REVIEW_STATUS_THROUGH_FUNCTION_ONLY;
--        草稿里改调薪照走;提交之后改调薪 / 被评估人 → REVIEW_FROZEN_AFTER_SUBMIT;月薪为 NULL 的人,评估批准按名拒
--        SALARY_NOT_SET_USE_INITIAL;挂着调薪申请时提交一张带调薪的评估 → SALARY_CHANGE_OPEN
--   C  ★★ 调薪一整圈:财务提 → submitted、月薪没动、留痕 submitted(level NULL);在途时照样关得掉审批(不挡);
--        CFO 批 → 月薪变了、履历一行带生效日与新旧两个数、decided_via = action.approve_review、留痕 approved
--   D  提不了 / 批不了:给自己提 → SALARY_CHANGE_OWN_REFUSED;月薪 NULL → SALARY_NOT_SET_USE_INITIAL;一样的数 →
--        SALARY_CHANGE_NO_CHANGE;生效日在已过账期 / 挂着在途工资申请的期 → 按名拒;第二张 → SALARY_CHANGE_OPEN;
--        不持码 → PERMISSION_DENIED;提单人批 → SELF_APPROVAL_FORBIDDEN|raiser;cco 批一张 CFO 不是当事人的 →
--        PERMISSION_DENIED|action.approve_review;驳回不给理由 → …REJECT_REASON_REQUIRED
--   E  ★★ CFO 是当事人 → cco 批:财务替 CFO 提 → CFO 自己批不了(PERMISSION_DENIED|action.hr_reviews)、cco 批得了,
--        decided_via = action.hr_reviews;CFO 的另一个账号(财务角色)替员工提 → 仍归 cco;替 cco 提 → 没有别人 →
--        SALARY_CHANGE_NO_OTHER_DECIDER,一行不落
--   F  fingerprint:等待中月薪被属主路径改了 → 批准按名拒 SALARY_CHANGED_SINCE_REQUEST,申请仍在等;提单人撤回,
--        撤回不写留痕;驳回带理由
--   G  审批关着:调薪申请生下来仍是 submitted(不看开关),关着时照样批得了
--   H  ★★ 处置一整圈:财务提 → submitted、卡仍 active、estimate 有损益、留痕 submitted 二级;旧门 → ASSET_DISPOSAL_NEEDS_REQUEST;
--        在途时关不了审批;卡上改成本 → ASSET_DISPOSAL_REQUESTED;折旧照常跑;CFO 批 → disposed、处置日 = 今天、
--        分录 asset_disposal、result 与 estimate 并排、留痕 approved 二级;凭证页冲它 → source_path
--   I  处置提不了 / 批不了:提单人批 → SELF_APPROVAL_FORBIDDEN|raiser;零成本的卡 → ASSET_HAS_NO_COST,一行不落;
--        收款却没给银行 → BANK_INVALID;第二张 → ASSET_DISPOSAL_OPEN;CFO 的另一个账号提 → ASSET_DISPOSAL_NO_OTHER_DECIDER;
--        等待中卡变了(新的折旧锚点)→ ASSET_CHANGED_SINCE_REQUEST
--   J  审批关着:处置生下来就 approved 并当场处置,留痕 auto_approved
--   K  ★ 故障注入一:摘掉 trg_performance_reviews_guard_write,cco 的那条路回来了 —— 直连插一张 submitted_by = CFO
--        的评估、自己批掉、别人的月薪变了。守卫是承重的
--   L  ★ 故障注入二:摘掉 trg_fixed_assets_disposal_freeze,等待中改成本不再被拒
--
-- 自带数据(README 第 2 条);锁期自己设(第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f228_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f228_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    u_fin  uuid := gen_random_uuid();   -- 财务:提调薪(hr.edit + view_pay)、提处置(finance.edit)
    u_fin2 uuid := gen_random_uuid();   -- 另一个财务(替 u_fin 提、撤回的旁人)
    u_cfo  uuid := gen_random_uuid();   -- 二级 + action.approve_review:CFO 的形状;e_cfo 的主账号
    u_cfo2 uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持财务角色 —— admin@ 的形状
    u_cco  uuid := gen_random_uuid();   -- cco:action.hr_reviews + hr.view + view_pay + view_reviews
    u_l1   uuid := gen_random_uuid();   -- 一级
    u_none uuid := gen_random_uuid();   -- 什么码都没有
    r_fin uuid; r_cco uuid; r_l1 uuid; r_l2 uuid; r_none uuid;
    e_fin uuid := gen_random_uuid(); e_fin2 uuid := gen_random_uuid(); e_cfo uuid := gen_random_uuid();
    e_cco uuid := gen_random_uuid(); e_staff uuid := gen_random_uuid(); e_nosal uuid := gen_random_uuid();
    e_other uuid := gen_random_uuid();
    v_rating text; v_period uuid; v_period2 uuid;
    a1 uuid; a0 uuid; a2 uuid; v_je uuid;
    rv uuid; q uuid; q2 uuid; v_res jsonb; v_msg text; v_n int; v_log int; v_row record;
    rep jsonb := '{}'::jsonb;
BEGIN
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_fin2, now()), (u_cfo, now()), (u_cfo2, now()), (u_cco, now()), (u_l1, now()), (u_none, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx228-fin','f','f',true)  RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx228-cco','f','f',true)  RETURNING id INTO r_cco;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx228-l1','f','f',true)   RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx228-l2','f','f',true)   RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx228-none','f','f',true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_fin, c FROM unnest(ARRAY['module.finance.edit', 'module.finance.view', 'data.view_prices',
        'module.hr.edit', 'module.hr.view', 'data.view_pay']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_cco, c FROM unnest(ARRAY['action.hr_reviews', 'module.hr.view', 'data.view_pay', 'data.view_reviews']) c;
    -- 一级与二级:每一条链的门都持(审批开得了);二级多出条款链的三个码与批评估 / 调薪的那个码
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM unnest(ARRAY[r_l1, r_l2]) r(id)
     CROSS JOIN unnest(ARRAY['module.purchasing.view', 'data.view_prices', 'data.view_purchase_prices',
        'module.finance.view', 'module.hr.view', 'data.view_pay', 'module.inbound.view', 'module.sales.view']) c;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, c FROM unnest(ARRAY['module.pricing.view', 'module.suppliers.view', 'module.customers.view',
        'action.approve_review']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_fin2, r_fin), (u_cfo, r_l2), (u_cfo2, r_fin), (u_cco, r_cco), (u_l1, r_l1), (u_none, r_none);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id, employment_status) VALUES
        (e_fin,   'FX228-FIN',   'FX228 Finance',  'full_time', 'office', CURRENT_DATE - 400, u_fin,  'active'),
        (e_fin2,  'FX228-FIN2',  'FX228 Finance2', 'full_time', 'office', CURRENT_DATE - 400, u_fin2, 'active'),
        (e_cfo,   'FX228-CFO',   'FX228 CFO',      'full_time', 'office', CURRENT_DATE - 400, u_cfo,  'active'),
        (e_cco,   'FX228-CCO',   'FX228 CCO',      'full_time', 'office', CURRENT_DATE - 400, u_cco,  'active'),
        (e_staff, 'FX228-STAFF', 'FX228 Staff',    'full_time', 'office', CURRENT_DATE - 400, NULL,   'active'),
        (e_nosal, 'FX228-NOSAL', 'FX228 No salary','full_time', 'office', CURRENT_DATE - 400, NULL,   'active'),
        (e_other, 'FX228-OTHER', 'FX228 Other',    'full_time', 'office', CURRENT_DATE - 400, NULL,   'active');
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);
    -- 第一份月薪:属主路径直接写(set_initial_salary 的那一格不是本支要钉的)
    UPDATE employees SET monthly_salary = 5000 WHERE id IN (e_fin, e_fin2, e_cfo, e_cco, e_staff, e_other);

    SELECT code INTO v_rating FROM review_rating_scale ORDER BY code LIMIT 1;
    IF v_rating IS NULL THEN
        INSERT INTO review_rating_scale (code, name_en, name_zh, sort_order) VALUES ('fx228', 'f', 'f', 1);
        v_rating := 'fx228';
    END IF;

    -- 一个已过账的工资期(2026-07)与一个挂着在途过账申请的草稿期(2026-08)
    INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate, status)
    VALUES ('FX228-P07', DATE '2026-07-01', DATE '2026-07-31', base_currency_code(), 1, 'posted') RETURNING id INTO v_period;
    INSERT INTO payroll_periods (code, period_month, payment_date, currency, fx_rate, status)
    VALUES ('FX228-P08', DATE '2026-08-01', DATE '2026-08-31', base_currency_code(), 1, 'draft') RETURNING id INTO v_period2;
    -- (在途的过账申请只在 D5 那一格的子块里挂上 —— 它 blocks_disable,挂着会让本支别处的开关切不动)

    -- 两台资产:一台有成本、在役;一台零成本
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date, cost_ccy, currency,
                              fx_rate, cost_base, useful_life_months, residual_base)
    VALUES (gen_random_uuid(), 'FX228-A1', 'fixture 228 press', 'equipment', DATE '2026-01-05', DATE '2026-01-10',
            12000, base_currency_code(), 1, 12000, 60, 0) RETURNING id INTO a1;
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date, cost_ccy, currency,
                              fx_rate, cost_base, useful_life_months, residual_base)
    VALUES (gen_random_uuid(), 'FX228-A0', 'fixture 228 never arrived', 'equipment', DATE '2026-01-05',
            0, base_currency_code(), 1, 0, 60, 0) RETURNING id INTO a0;
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date, cost_ccy, currency,
                              fx_rate, cost_base, useful_life_months, residual_base)
    VALUES (gen_random_uuid(), 'FX228-A2', 'fixture 228 van', 'vehicle', DATE '2026-01-05', DATE '2026-01-10',
            6000, base_currency_code(), 1, 6000, 60, 0) RETURNING id INTO a2;

    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx228-l1', approval_level2_role_code = 'fx228-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 登记 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'asset_disposal_request')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'asset_disposal_request')
         IS DISTINCT FROM ARRAY['module.finance.view', 'data.view_prices']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 228A1 失败:处置在名册里应当只有二级一行,门是 finance.view + view_prices'; END IF;
    IF EXISTS (SELECT 1 FROM approval_chain_gates() WHERE subject_type = 'salary_change_request') THEN
        RAISE EXCEPTION 'FIXTURE 228A2 失败:调薪按人路由,不该在按级的名册里(Q2)'; END IF;
    IF position('asset_disposal_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0
       OR position('salary_change_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228A3 失败:operations_now 少了处置或调薪那一支'; END IF;
    SELECT string_agg(s, ', ') INTO v_msg FROM unnest(ARRAY[
        'public.salary_change_execute_internal(uuid)', 'public.salary_change_fingerprint(uuid)',
        'public.salary_change_open(uuid)', 'public.salary_change_deciders(uuid, uuid)',
        'public.salary_effective_period_block(date)', 'public.pay_decision_code(uuid, uuid)',
        'public.asset_disposal_execute_internal(uuid)', 'public.asset_disposal_dry_run(uuid)',
        'public.asset_disposal_fingerprint(uuid)', 'public.dispose_fixed_asset_internal(uuid, date, numeric, text, text)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 228A4 失败:authenticated 调得到内层算子 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('salary_change_requests', 'asset_disposal_requests') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 228A5 失败:申请表上有写策略'; END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE NOT tgisinternal AND tgname IN ('trg_performance_reviews_guard_write', 'trg_fixed_assets_disposal_freeze');
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 228A6 失败:应当挂着 2 支守卫,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM unnest(ARRAY[u_fin, u_cfo, u_cfo2, u_cco]) u CROSS JOIN unnest(ARRAY[e_cfo, e_staff, e_cco]) e
     WHERE review_approval_code(u, e) IS DISTINCT FROM pay_decision_code(u, e);
    IF v_n <> 0 OR pay_decision_code(u_fin, e_staff) <> 'action.approve_review'
       OR pay_decision_code(u_fin, e_cfo) <> 'action.hr_reviews' OR pay_decision_code(u_cfo2, e_staff) <> 'action.hr_reviews' THEN
        RAISE EXCEPTION 'FIXTURE 228A7 失败:一份判据 —— review_approval_code 应当逐对等于 pay_decision_code,CFO 是当事人时给 cco 的码'; END IF;
    rep := rep || jsonb_build_object('A_registered', true);

    -- ══════════════ B · 绩效评估的侧门 ══════════════
    PERFORM pg_temp.f228_as(u_cco);
    v_msg := pg_temp.f228_try(format(
        'INSERT INTO performance_reviews (employee_id, review_type, period_start, period_end, reviewer_employee_id, status, '
        'rating_code, summary_text, probation_outcome, new_monthly_salary, salary_effective_date, submitted_at, submitted_by) '
        'VALUES (%L, ''probation'', ''2026-06-01'', ''2026-09-30'', %L, ''submitted'', %L, ''b'', ''not_confirm'', 9999, %L, now(), %L)',
        e_staff, e_fin, v_rating, CURRENT_DATE + 40, u_cfo));
    IF position('REVIEW_DIRECT_INSERT_DRAFT_ONLY' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228B1 失败:直连插一张已提交的评估应当按名拒,实得 %', v_msg; END IF;
    rv := gen_random_uuid();
    v_msg := pg_temp.f228_try(format(
        'INSERT INTO performance_reviews (id, employee_id, review_type, period_start, period_end, reviewer_employee_id) '
        'VALUES (%L, %L, ''probation'', ''2026-06-01'', ''2026-09-30'', %L)', rv, e_staff, e_fin));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 228B2 失败:草稿照建,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('UPDATE performance_reviews SET status = ''submitted'' WHERE id = %L', rv));
    IF position('REVIEW_STATUS_THROUGH_FUNCTION_ONLY|status' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228B3 失败:直连改 status 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('UPDATE performance_reviews SET submitted_by = %L WHERE id = %L', u_cfo, rv));
    IF position('REVIEW_STATUS_THROUGH_FUNCTION_ONLY|submitted_by' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228B4 失败:伪造提交人应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format(
        'UPDATE performance_reviews SET new_monthly_salary = 5200, salary_effective_date = %L, rating_code = %L, '
        'summary_text = ''b'', probation_outcome = ''not_confirm'' WHERE id = %L', CURRENT_DATE + 40, v_rating, rv));
    IF v_msg <> 'OK' OR (SELECT new_monthly_salary FROM performance_reviews WHERE id = rv) <> 5200 THEN
        RAISE EXCEPTION 'FIXTURE 228B5 失败:草稿里写调薪照走,实得 %', v_msg; END IF;
    INSERT INTO review_goals (review_id, sequence, objective_text) VALUES (rv, 1, 'fixture 228 goal');
    -- 提交走函数(cco 持 action.hr_reviews)
    PERFORM pg_temp.f228_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM submit_review(rv);
    EXECUTE 'RESET ROLE';
    v_msg := pg_temp.f228_try(format('UPDATE performance_reviews SET new_monthly_salary = 9999 WHERE id = %L', rv));
    IF position('REVIEW_FROZEN_AFTER_SUBMIT|new_monthly_salary' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228B6 失败:提交之后改调薪应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('UPDATE performance_reviews SET employee_id = %L WHERE id = %L', e_other, rv));
    IF position('REVIEW_FROZEN_AFTER_SUBMIT|employee_id' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228B7 失败:提交之后换被评估人应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('UPDATE performance_reviews SET summary_text = ''b2'' WHERE id = %L', rv));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 228B8 失败:不动钱的列照旧由写策略管,实得 %', v_msg; END IF;
    -- 这张评估带调薪、已提交:同一个人再提一张调薪申请 → SALARY_CHANGE_OPEN(跨两条路)
    PERFORM pg_temp.f228_as(u_fin);
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 5300, %L, ''b'')', e_staff, CURRENT_DATE + 40));
    IF position('SALARY_CHANGE_OPEN|FX228-STAFF|review:' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228B9 失败:评估里挂着一次调薪,调薪申请应当按名拒,实得 %', v_msg; END IF;
    -- 作废它(属主路径),让后面的调薪臂从干净的一格开始
    UPDATE performance_reviews SET status = 'void', voided_at = now(), void_reason = 'fixture 228' WHERE id = rv;
    -- 月薪为 NULL 的人:评估批准按名拒
    INSERT INTO performance_reviews (id, employee_id, review_type, period_start, period_end, reviewer_employee_id,
                                     status, rating_code, summary_text, probation_outcome, new_monthly_salary,
                                     salary_effective_date, submitted_at, submitted_by)
    VALUES (gen_random_uuid(), e_nosal, 'probation', DATE '2026-06-01', DATE '2026-09-30', e_fin, 'submitted', v_rating,
            'b', 'not_confirm', 4000, CURRENT_DATE + 40, now(), u_cco) RETURNING id INTO rv;
    PERFORM pg_temp.f228_as(u_cfo);
    v_msg := pg_temp.f228_try(format('SELECT approve_review(%L)', rv));
    IF position('SALARY_NOT_SET_USE_INITIAL|FX228-NOSAL' IN v_msg) = 0
       OR (SELECT monthly_salary FROM employees WHERE id = e_nosal) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 228B10 失败:评估不许录第一份月薪,实得 %', v_msg; END IF;
    UPDATE performance_reviews SET status = 'void', voided_at = now(), void_reason = 'fixture 228' WHERE id = rv;
    rep := rep || jsonb_build_object('B_review_side_door', true);

    -- ══════════════ C · 调薪一整圈 ══════════════
    SELECT count(*) INTO v_log FROM approval_log WHERE subject_type = 'salary_change_request';
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_salary_change_request(e_staff, 5500, CURRENT_DATE + 40, 'fixture 228 C raise');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR v_res->>'decided_via' <> 'action.approve_review'
       OR (SELECT monthly_salary FROM employees WHERE id = e_staff) <> 5000
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'salary_change_request' AND subject_id = q
                       AND decision = 'submitted' AND level IS NULL AND amount_base IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 228C1 失败:提交之后申请在等、月薪没动、留痕 submitted(无级、无金额),实得 %', v_res; END IF;
    SELECT * INTO v_row FROM approval_pending_documents() d WHERE d.doc_id = q;
    IF NOT FOUND OR v_row.blocks_disable OR v_row.fixed_level IS NOT NULL OR v_row.amount_base IS NOT NULL
       OR v_row.subject_employee_id <> e_staff THEN
        RAISE EXCEPTION 'FIXTURE 228C2 失败:在途清单里调薪那一行应当不挡关闭、无级、无金额、主角是员工'; END IF;
    -- 不挡关闭:关掉,再开回来
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    PERFORM pg_temp.f228_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := decide_salary_change_request(q, true, 'ok');
    EXECUTE 'RESET ROLE';
    IF v_res->>'status' <> 'approved' OR (SELECT monthly_salary FROM employees WHERE id = e_staff) <> 5500
       OR (SELECT decided_via FROM salary_change_requests WHERE id = q) <> 'action.approve_review'
       OR NOT EXISTS (SELECT 1 FROM employment_history h WHERE h.employee_id = e_staff AND h.change_type = 'salary_change'
                       AND h.effective_date = CURRENT_DATE + 40 AND h.old_monthly_salary = 5000 AND h.new_monthly_salary = 5500
                       AND h.created_by = u_fin)
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'salary_change_request' AND subject_id = q
                       AND decision = 'approved' AND actor_user_id = u_cfo AND NOT self_decided) THEN
        RAISE EXCEPTION 'FIXTURE 228C3 失败:CFO 批准 → 月薪 5500、履历带生效日与新旧两个数、留痕 approved,实得 %', v_res; END IF;
    rep := rep || jsonb_build_object('C_salary_lifecycle', true);

    -- ══════════════ D · 提不了 / 批不了 ══════════════
    PERFORM pg_temp.f228_as(u_fin);
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 6000, %L, ''d'')', e_fin, CURRENT_DATE + 40));
    IF position('SALARY_CHANGE_OWN_REFUSED|FX228-FIN' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D1 失败:给自己提应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 6000, %L, ''d'')', e_nosal, CURRENT_DATE + 40));
    IF position('SALARY_NOT_SET_USE_INITIAL|FX228-NOSAL' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D2 失败:月薪 NULL 应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 5500, %L, ''d'')', e_staff, CURRENT_DATE + 40));
    IF position('SALARY_CHANGE_NO_CHANGE|FX228-STAFF' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D3 失败:一样的数应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 6000, ''2026-07-15'', ''d'')', e_staff));
    IF position('SALARY_EFFECTIVE_IN_POSTED_PERIOD|FX228-P07' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D4 失败:生效日在已过账期应当按名拒,实得 %', v_msg; END IF;
    BEGIN
        INSERT INTO payroll_requests (payroll_period_id, kind, status, label, snapshot, currency, fx_rate, gross_total,
                                      amount_base, created_by)
        VALUES (v_period2, 'post', 'submitted', 'FX228-P08 · post #1', '{}'::jsonb, base_currency_code(), 1, 0, 0, u_fin);
        v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 6000, ''2026-08-15'', ''d'')', e_staff));
        RAISE EXCEPTION 'F228_ROLLBACK_SUB|%', v_msg;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
    END;
    IF position('SALARY_EFFECTIVE_IN_REQUESTED_PERIOD|FX228-P08' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D5 失败:生效日在挂着在途工资申请的期应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 6000, NULL, ''d'')', e_staff));
    IF position('SALARY_EFFECTIVE_DATE_REQUIRED' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D6 失败:生效日必填,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_none);
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 6000, %L, ''d'')', e_staff, CURRENT_DATE + 40));
    IF position('PERMISSION_DENIED|module.hr.edit' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D7 失败:不持码的人提应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    q := (submit_salary_change_request(e_other, 5600, CURRENT_DATE + 40, 'fixture 228 D')->>'request_id')::uuid;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f228_as(u_fin2);
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 5700, %L, ''d'')', e_other, CURRENT_DATE + 40));
    IF position('SALARY_CHANGE_OPEN|FX228-OTHER' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D8 失败:第二张应当按名拒,实得 %', v_msg; END IF;
    -- 提单人批:u_fin 不持批的码 → 缺码;把批的码借给它(子块里)才看得到四眼那一腿
    PERFORM pg_temp.f228_as(u_fin);
    v_msg := pg_temp.f228_try(format('SELECT decide_salary_change_request(%L, true)', q));
    IF position('PERMISSION_DENIED|action.approve_review' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D9 失败:财务不持批的码,实得 %', v_msg; END IF;
    BEGIN
        INSERT INTO role_permissions (role_id, permission_code) VALUES (r_fin, 'action.approve_review');
        v_msg := pg_temp.f228_try(format('SELECT decide_salary_change_request(%L, true)', q));
        RAISE EXCEPTION 'F228_ROLLBACK_SUB|%', v_msg;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
    END;
    IF position('SELF_APPROVAL_FORBIDDEN|raiser' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D10 失败:提单人批应当按名拒,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_cco);
    v_msg := pg_temp.f228_try(format('SELECT decide_salary_change_request(%L, true)', q));
    IF position('PERMISSION_DENIED|action.approve_review' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D11 失败:CFO 不是当事人时 cco 批不了,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_cfo);
    v_msg := pg_temp.f228_try(format('SELECT decide_salary_change_request(%L, false, ''  '')', q));
    IF position('SALARY_CHANGE_REJECT_REASON_REQUIRED' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228D12 失败:驳回不给理由应当按名拒,实得 %', v_msg; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := decide_salary_change_request(q, false, 'not this year');
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM salary_change_requests WHERE id = q) <> 'rejected'
       OR (SELECT monthly_salary FROM employees WHERE id = e_other) <> 5000 THEN
        RAISE EXCEPTION 'FIXTURE 228D13 失败:驳回 → rejected、月薪没动'; END IF;
    rep := rep || jsonb_build_object('D_refusals', true);

    -- ══════════════ E · CFO 是当事人 → cco 批 ══════════════
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_salary_change_request(e_cfo, 7000, CURRENT_DATE + 40, 'fixture 228 E cfo raise');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'decided_via' <> 'action.hr_reviews' THEN
        RAISE EXCEPTION 'FIXTURE 228E1 失败:CFO 是主角 → 归 cco,实得 %', v_res; END IF;
    PERFORM pg_temp.f228_as(u_cfo);
    v_msg := pg_temp.f228_try(format('SELECT decide_salary_change_request(%L, true)', q));
    IF position('PERMISSION_DENIED|action.hr_reviews' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228E2 失败:CFO 批不了自己的调薪,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_cco);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := decide_salary_change_request(q, true, NULL);
    EXECUTE 'RESET ROLE';
    IF (SELECT monthly_salary FROM employees WHERE id = e_cfo) <> 7000
       OR (SELECT decided_via FROM salary_change_requests WHERE id = q) <> 'action.hr_reviews' THEN
        RAISE EXCEPTION 'FIXTURE 228E3 失败:cco 批 CFO 的调薪,decided_via = action.hr_reviews,实得 %', v_res; END IF;
    -- CFO 的另一个账号(财务角色)替员工提 → 仍归 cco
    PERFORM pg_temp.f228_as(u_cfo2);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_salary_change_request(e_staff, 5800, CURRENT_DATE + 40, 'fixture 228 E by cfo2');
    EXECUTE 'RESET ROLE';
    IF v_res->>'decided_via' <> 'action.hr_reviews' THEN
        RAISE EXCEPTION 'FIXTURE 228E4 失败:CFO 这个人提的 → 归 cco,实得 %', v_res; END IF;
    q2 := (v_res->>'request_id')::uuid;
    -- 替 cco 提:两条路都被当事人占了 → 没有别人,一行不落
    SELECT count(*) INTO v_n FROM salary_change_requests;
    v_msg := pg_temp.f228_try(format('SELECT submit_salary_change_request(%L, 5800, %L, ''e'')', e_cco, CURRENT_DATE + 40));
    IF position('SALARY_CHANGE_NO_OTHER_DECIDER|FX228-CCO' IN v_msg) = 0
       OR (SELECT count(*) FROM salary_change_requests) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 228E5 失败:CFO 替 cco 提应当按名拒且一行不落,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('E_cfo_party_routes_to_cco', true);

    -- ══════════════ F · fingerprint、撤回 ══════════════
    UPDATE employees SET monthly_salary = 5900 WHERE id = e_staff;   -- 属主路径(直连会被拒)
    PERFORM pg_temp.f228_as(u_cco);
    v_msg := pg_temp.f228_try(format('SELECT decide_salary_change_request(%L, true)', q2));
    IF position('SALARY_CHANGED_SINCE_REQUEST' IN v_msg) = 0
       OR (SELECT status FROM salary_change_requests WHERE id = q2) <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 228F1 失败:起点变了应当按名拒、申请仍在等,实得 %', v_msg; END IF;
    SELECT count(*) INTO v_log FROM approval_log WHERE subject_id = q2;
    PERFORM pg_temp.f228_as(u_fin);   -- 不是提单人,但持提单的两个码 → 撤得了
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM withdraw_salary_change_request(q2, 'fixture 228 F');
    EXECUTE 'RESET ROLE';
    IF (SELECT status FROM salary_change_requests WHERE id = q2) <> 'withdrawn'
       OR (SELECT count(*) FROM approval_log WHERE subject_id = q2) <> v_log THEN
        RAISE EXCEPTION 'FIXTURE 228F2 失败:撤回 → withdrawn,不写留痕'; END IF;
    PERFORM pg_temp.f228_as(u_none);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM salary_change_requests_visible();
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 228F3 失败:不持两个码的人读到 % 张调薪申请', v_n; END IF;
    rep := rep || jsonb_build_object('F_fingerprint_withdraw', true);

    -- ══════════════ G · 审批关着:调薪照样等 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_salary_change_request(e_staff, 6100, CURRENT_DATE + 40, 'fixture 228 G');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT monthly_salary FROM employees WHERE id = e_staff) <> 5900 THEN
        RAISE EXCEPTION 'FIXTURE 228G1 失败:审批关着,调薪申请仍生下来就在等,实得 %', v_res; END IF;
    PERFORM pg_temp.f228_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_salary_change_request(q, true, NULL);
    EXECUTE 'RESET ROLE';
    IF (SELECT monthly_salary FROM employees WHERE id = e_staff) <> 6100 THEN
        RAISE EXCEPTION 'FIXTURE 228G2 失败:审批关着时 CFO 照样批得了'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    rep := rep || jsonb_build_object('G_ignores_switch', true);

    -- ══════════════ H · 处置一整圈 ══════════════
    PERFORM pg_temp.f228_as(u_fin);
    v_msg := pg_temp.f228_try(format('SELECT dispose_fixed_asset(%L, CURRENT_DATE, 0, NULL, ''h'')', a1));
    IF position('ASSET_DISPOSAL_NEEDS_REQUEST|FX228-A1' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228H1 失败:旧门应当按名拒,实得 %', v_msg; END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM depreciate_fixed_assets((date_trunc('month', CURRENT_DATE) - interval '1 day')::date);
    v_res := submit_asset_disposal_request(a1, 1000, '1000', 'fixture 228 H sold');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT status FROM fixed_assets WHERE id = a1) <> 'active'
       OR (v_res->'estimate'->>'cost_relieved')::numeric <> 12000
       OR (v_res->'estimate'->>'gain_loss')::numeric
          <> round(1000 + (v_res->'estimate'->>'accum_relieved')::numeric - 12000, 2)
       OR (v_res->'estimate'->>'disposal_date')::date <> CURRENT_DATE
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'asset_disposal_request' AND subject_id = q
                       AND decision = 'submitted' AND level = 2)
       OR EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'asset_disposal' AND source_id = a1) THEN
        RAISE EXCEPTION 'FIXTURE 228H2 失败:提交 → 卡仍 active、estimate 有成本与损益、留痕 submitted 二级、没有分录,实得 %', v_res; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF position('APPROVALS_CANNOT_DISABLE_WITH_PENDING' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228H3 失败:处置在途时关不了审批,实得 %', v_msg; END IF;
    BEGIN
        UPDATE fixed_assets SET cost_base = 13000, cost_ccy = 13000 WHERE id = a1;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF position('ASSET_DISPOSAL_REQUESTED|FX228-A1' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228H4 失败:在途时卡上改成本(属主路径也算)应当按名拒,实得 %', v_msg; END IF;
    UPDATE fixed_assets SET planned_in_service_date = CURRENT_DATE WHERE id = a1;   -- 计划日照常
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := depreciate_fixed_assets((date_trunc('month', CURRENT_DATE) + interval '1 month - 1 day')::date);
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f228_as(u_cfo);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := decide_asset_disposal_request(q, true, 'ok');
    EXECUTE 'RESET ROLE';
    SELECT a.disposal_journal_id INTO v_je FROM fixed_assets a WHERE a.id = a1;
    IF (SELECT status FROM fixed_assets WHERE id = a1) <> 'disposed'
       OR (SELECT disposal_date FROM fixed_assets WHERE id = a1) <> CURRENT_DATE
       OR (SELECT source_type FROM journal_entries WHERE id = v_je) <> 'asset_disposal'
       OR (SELECT result_entry_id FROM asset_disposal_requests WHERE id = q) <> v_je
       OR (SELECT (result->>'accum_relieved')::numeric FROM asset_disposal_requests WHERE id = q)
          <> (SELECT sum(amount_base) FROM fixed_asset_depreciation WHERE asset_id = a1)
       OR (SELECT amount_base FROM asset_disposal_requests WHERE id = q)
          <> (SELECT round(sum(debit), 2) FROM journal_lines WHERE entry_id = v_je)
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'asset_disposal_request' AND subject_id = q
                       AND decision = 'approved' AND level = 2 AND actor_user_id = u_cfo)
       OR journal_entry_reversal_route(v_je) <> 'source_path' THEN
        RAISE EXCEPTION 'FIXTURE 228H5 失败:CFO 批 → disposed、处置日今天、分录 asset_disposal、result 按批准那一刻的累计折旧、留痕 approved 二级、凭证页冲它走源路径,实得 %', v_res; END IF;
    rep := rep || jsonb_build_object('H_disposal_lifecycle', true);

    -- ══════════════ I · 处置提不了 / 批不了 ══════════════
    SELECT count(*) INTO v_n FROM asset_disposal_requests;
    PERFORM pg_temp.f228_as(u_fin);
    v_msg := pg_temp.f228_try(format('SELECT submit_asset_disposal_request(%L, 0, NULL, ''i'')', a0));
    IF position('ASSET_HAS_NO_COST|FX228-A0' IN v_msg) = 0 OR (SELECT count(*) FROM asset_disposal_requests) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 228I1 失败:零成本的卡在提交的试跑里按名拒、一行不落,实得 %', v_msg; END IF;
    v_msg := pg_temp.f228_try(format('SELECT submit_asset_disposal_request(%L, 50, NULL, ''i'')', a2));
    IF position('BANK_INVALID' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228I2 失败:收款却没给银行科目,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_cfo2);
    v_msg := pg_temp.f228_try(format('SELECT submit_asset_disposal_request(%L, 0, NULL, ''i'')', a2));
    IF position('ASSET_DISPOSAL_NO_OTHER_DECIDER|FX228-A2' IN v_msg) = 0 OR (SELECT count(*) FROM asset_disposal_requests) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 228I3 失败:CFO 的另一个账号提 → 没有别人批,一行不落,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    q := (submit_asset_disposal_request(a2, 0, NULL, 'fixture 228 I scrap')->>'request_id')::uuid;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f228_as(u_fin2);
    v_msg := pg_temp.f228_try(format('SELECT submit_asset_disposal_request(%L, 0, NULL, ''i'')', a2));
    IF position('ASSET_DISPOSAL_OPEN|FX228-A2' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228I4 失败:第二张应当按名拒,实得 %', v_msg; END IF;
    BEGIN
        -- 把二级角色借给提单人(子块里,随后回滚)—— 缺的只剩四眼那一腿
        INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_l2);
        PERFORM pg_temp.f228_as(u_fin);
        v_msg := pg_temp.f228_try(format('SELECT decide_asset_disposal_request(%L, true)', q));
        RAISE EXCEPTION 'F228_ROLLBACK_SUB|%', v_msg;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
    END;
    IF position('SELF_APPROVAL_FORBIDDEN|raiser' IN v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 228I5 失败:提单人批应当按名拒,实得 %', v_msg; END IF;
    INSERT INTO fixed_asset_depreciation_anchors (asset_id, effective_from, pre_anchor_target_base, remaining_months, reason)
    VALUES (a2, date_trunc('month', CURRENT_DATE)::date, 0, 50, 'fixture 228 I');
    PERFORM pg_temp.f228_as(u_cfo);
    v_msg := pg_temp.f228_try(format('SELECT decide_asset_disposal_request(%L, true)', q));
    IF position('ASSET_CHANGED_SINCE_REQUEST|FX228-A2' IN v_msg) = 0
       OR (SELECT status FROM asset_disposal_requests WHERE id = q) <> 'submitted'
       OR (SELECT status FROM fixed_assets WHERE id = a2) <> 'active' THEN
        RAISE EXCEPTION 'FIXTURE 228I6 失败:等待中卡变了 → 按名拒、申请仍在等,实得 %', v_msg; END IF;
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM withdraw_asset_disposal_request(q, 'fixture 228 I');
    EXECUTE 'RESET ROLE';
    rep := rep || jsonb_build_object('I_disposal_refusals', true);

    -- ══════════════ J · 审批关着:处置当场生效 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM pg_temp.f228_as(u_fin);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_res := submit_asset_disposal_request(a2, 0, NULL, 'fixture 228 J');
    EXECUTE 'RESET ROLE';
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'approved' OR (SELECT status FROM fixed_assets WHERE id = a2) <> 'disposed'
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'asset_disposal_request' AND subject_id = q
                       AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 228J 失败:审批关着时处置生下来就 approved 并当场处置、留痕 auto_approved,实得 %', v_res; END IF;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    rep := rep || jsonb_build_object('J_approvals_off', true);

    -- ══════════════ K · 故障注入一:评估守卫是承重的 ══════════════
    ALTER TABLE performance_reviews DISABLE TRIGGER trg_performance_reviews_guard_write;
    rv := gen_random_uuid();
    PERFORM pg_temp.f228_as(u_cco);
    v_msg := pg_temp.f228_try(format(
        'INSERT INTO performance_reviews (id, employee_id, review_type, period_start, period_end, reviewer_employee_id, status, '
        'rating_code, summary_text, probation_outcome, new_monthly_salary, salary_effective_date, submitted_at, submitted_by) '
        'VALUES (%L, %L, ''probation'', ''2026-06-01'', ''2026-09-30'', %L, ''submitted'', %L, ''k'', ''not_confirm'', 9999, %L, now(), %L)',
        rv, e_other, e_fin, v_rating, CURRENT_DATE + 40, u_cfo));
    IF v_msg = 'OK' THEN
        v_msg := pg_temp.f228_try(format('SELECT approve_review(%L)', rv));
    END IF;
    ALTER TABLE performance_reviews ENABLE TRIGGER trg_performance_reviews_guard_write;
    IF v_msg <> 'OK' OR (SELECT monthly_salary FROM employees WHERE id = e_other) <> 9999 THEN
        RAISE EXCEPTION 'FIXTURE 228K 失败:摘掉守卫之后 Step 0 那条路应当回来(cco 自己批掉、月薪变 9999),实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('K_review_guard_is_load_bearing', true);

    -- ══════════════ L · 故障注入二:冻结守卫是承重的 ══════════════
    PERFORM pg_temp.f228_as(u_fin);
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date, in_service_date, cost_ccy, currency,
                              fx_rate, cost_base, useful_life_months, residual_base)
    VALUES (gen_random_uuid(), 'FX228-A3', 'fixture 228 lathe', 'equipment', DATE '2026-01-05', DATE '2026-01-10',
            3000, base_currency_code(), 1, 3000, 60, 0) RETURNING id INTO a2;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM submit_asset_disposal_request(a2, 0, NULL, 'fixture 228 L');
    EXECUTE 'RESET ROLE';
    ALTER TABLE fixed_assets DISABLE TRIGGER trg_fixed_assets_disposal_freeze;
    BEGIN
        UPDATE fixed_assets SET cost_base = 3100, cost_ccy = 3100 WHERE id = a2;
        v_msg := 'OK';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    ALTER TABLE fixed_assets ENABLE TRIGGER trg_fixed_assets_disposal_freeze;
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 228L 失败:摘掉冻结守卫之后改成本应当通过(守卫是唯一的一道),实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('L_freeze_guard_is_load_bearing', true);

    RAISE NOTICE 'FIXTURE 228 全部通过:A 登记 · B 评估侧门 · C 调薪一整圈 · D 提不了 / 批不了 · E CFO 当事人归 cco · F fingerprint 与撤回 · G 不看开关 · H 处置一整圈 · I 处置的拒绝 · J 审批关着 · K / L 注入 %', rep::text;
END;
$$;
ROLLBACK;

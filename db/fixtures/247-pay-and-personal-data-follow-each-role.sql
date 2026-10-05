-- 247 U1-A:工资与个人数据按角色收口(UNBLOCK-1 Q1–Q13,Tim 2026-10-05;v1.4.35)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】一臂一条裁定;每一臂都有一格故障注入(db/scripts/2026-10-05-u1a-fixture-injections.py)必须让它红。
--   JA  工资分录经 API(Q1 · Q2):不持 data.view_pay 的财务读者经 journal_lines 读不到工资分录的任何一行(过账、冲销、发薪、公积金);
--       持的人一行不少;一张非工资分录(费用)对两人一样
--   JM  遮蔽视图(Q1 · Q3):同一个读者经 journal_lines_masked 读得到每一行,三个金额是 null 且 amounts_restricted;
--       发薪那一行的行摘要(员工编号 + 姓名)两人都读得到;持 view_pay 的人金额照常
--   JT  挪走的读法(Q2):试算合计 · 关账预览 · 银行账面余额 · 科目明细合计 · 总账导出的行数 · 对账候选的行数 · 两张外币视图 ——
--       对 cto 形状、持薪的财务、只看变更记录的读者,与属主身份读的(或彼此之间)逐分相同;不持财务的读者被按名拒,不是 0
--   JR  审计记录(Q1 的"受限,不是 0.00"):cto 形状的读者在发薪分录的记录里读得到分录行(不是被藏的行),金额是 Restricted;
--       持薪的人读得到数;汇总页(change_log_rows)对一个持变更记录码、不持薪的读者同样是 Restricted
--   PT  工资期合计、工资申请与审批留痕(Q9 · Q10):不持薪的 HR 读者经遮蔽视图读到 null、经基表读那几列被拒(42501)、
--       审批留痕上工资申请那几行的金额 null;记录里同样 Restricted;持薪的人读得到
--   KP  KPI(Q5):员工本人经 kpi_entries 读不到自己的条目(那条自读策略拿掉了);经 my_kpi_entries 读得到条目,
--       分数在关轮之前是 null、关轮之后是那个分
--   EN  人事备注(Q6 · Q7):员工本人经基表读 notes / separation_notes 被拒(42501),经 employees_masked 读自己那一行是 null;
--       持 module.hr.view 的人读得到;个人数据导出里本人仍读得到写他的那段备注(Q7,刻意的例外)
--   HL  健康数据(Q8):不持 data.view_health 的 HR 读者读到的医疗事由 · 金额 · 请假事由 · 病假单号是 null(三张读法:
--       medical_claims_masked · medical_claim_status · leave_requests_masked),审批留痕上医疗那一行的金额 null,记录里 Restricted;
--       员工本人读自己的照常;持码的人照常
--   AN  匿名化(Q11):调薪申请 · 工资行 · 请假单 · 医疗报销上人写的字在表里与记录里都擦掉,金额一分不动,redacted_at 盖上
--   CU  工资单的币种(Q12):一期 USD 的工资,员工本人经 my_period_labels() 读到 USD
--   EQ  设备保养建议(Q13):只持加工权限的读者读得到记录与建议,读不到维修花费、机器成本与两者之比;持财务的人读得到
--
-- 自带数据(README 第 2 条):账号、角色、员工、考勤、工资期、申请、请假、医疗报销、资产、保养记录、KPI 轮次全部本支自建;
--   职位与 KPI 模板是稳定的引导数据(第 4 条)。月份是【找】出来的(fixture 141 · 218 · 246 的做法)。
-- 以 postgres 跑(绕过 RLS)—— 每一次读都切成 authenticated + 那个人的 JWT(fixture 26 的教训:不切角色,RLS 的那几臂是空的)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f247_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以某人的身份跑一句、取回一个 jsonb;出错时回 {"error": SQLSTATE, "msg": …}
CREATE FUNCTION pg_temp.f247_read(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f247_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLSTATE, 'msg', SQLERRM);
END;
$f$;

-- 一个数(读不出来就抛,带着臂名 —— 一次失败不许被读成 0)
CREATE FUNCTION pg_temp.f247_n(p_arm text, p_user uuid, p_sql text) RETURNS numeric
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := pg_temp.f247_read(p_user, 'SELECT to_jsonb((' || p_sql || '))');
BEGIN
    IF jsonb_typeof(v) = 'object' AND v ? 'error' THEN
        RAISE EXCEPTION 'FIXTURE 247 %: the read failed: % — %', p_arm, v ->> 'error', v ->> 'msg'; END IF;
    RETURN (v #>> '{}')::numeric;
END;
$f$;

-- 那一句必须以 42501(insufficient_privilege)被拒
CREATE FUNCTION pg_temp.f247_denied(p_arm text, p_user uuid, p_sql text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := pg_temp.f247_read(p_user, 'SELECT to_jsonb(x) FROM (' || p_sql || ') x LIMIT 1');
BEGIN
    -- COALESCE 是承重的:一次【成功】的读回来的是 {"<列>": …},它的 error 键是 NULL —— 不 COALESCE,NOT (… AND NULL) 是 NULL,
    --   IF NULL 不进分支,于是一次本该被拒却读到了数的读会被当成"被拒了"(注入 "grant back" 三格当场抓到过这一回)。
    IF COALESCE(v ->> 'error', '') <> '42501' THEN
        RAISE EXCEPTION 'FIXTURE 247 %: expected 42501, got %', p_arm, left(COALESCE(v::text, '(no row)'), 300); END IF;
END;
$f$;

CREATE FUNCTION pg_temp.f247_trail(p_user uuid, p_subject text, p_id text) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT pg_temp.f247_read(p_user, format(
        'SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST), ''[]''::jsonb) FROM record_trail(%L, %L, 500) r',
        p_subject, p_id))
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码(做事的人)
    u_cto  uuid := gen_random_uuid();   -- cto / gm 的形状:finance.view + hr.view + view_reviews,不持 view_pay、不持 view_health
    u_pay  uuid := gen_random_uuid();   -- 财务的形状:finance.view + hr.view + view_pay + view_health
    u_cl   uuid := gen_random_uuid();   -- 读汇总页的人:view_change_log + finance.view + hr.view,不持 view_pay / view_health
    u_proc uuid := gen_random_uuid();   -- 仓库的形状:只有 processing.view
    u_emp  uuid := gen_random_uuid();   -- 普通员工:一个码都没有,有员工档案
    u_hre  uuid := gen_random_uuid();   -- 有员工档案、持 module.hr.view、不持 view_health
    r_all uuid; r_cto uuid; r_pay uuid; r_cl uuid; r_proc uuid; r_hre uuid;
    e_emp uuid := gen_random_uuid(); e_hre uuid := gen_random_uuid(); e_other uuid := gen_random_uuid(); e_anon uuid := gen_random_uuid();
    v_m date; v_m2 date; v_d date; v_n int; v_x numeric; v_y numeric; v_r jsonb; v_j jsonb; v_txt text; r record;
    v_pos uuid; v_att uuid;
    pp uuid; pp_usd uuid; pp_anon uuid; v_lines jsonb; v_line_ids uuid[]; v_req uuid;
    je_post1 uuid; je_rev uuid; je_post2 uuid; je_payrun uuid; je_exp uuid; v_pay_ids text;
    v_asset uuid; v_sup uuid; v_exp uuid; v_mt uuid; v_ccy text;
    lv uuid; mc uuid; kc uuid; k1 uuid;
    lv_a uuid; mc_a uuid; scr_a uuid; pl_a uuid;
    u text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx247-all@test.local', now(), now()), (u_cto, 'fx247-cto@test.local', now(), now()),
        (u_pay, 'fx247-pay@test.local', now(), now()), (u_cl, 'fx247-cl@test.local', now(), now()),
        (u_proc, 'fx247-proc@test.local', now(), now()), (u_emp, 'fx247-emp@test.local', now(), now()),
        (u_hre, 'fx247-hre@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx247-all', 'FX247 All', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx247-cto', 'FX247 CTO shape', 'f', true) RETURNING id INTO r_cto;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx247-pay', 'FX247 Finance shape', 'f', true) RETURNING id INTO r_pay;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx247-cl', 'FX247 Change-log reader', 'f', true) RETURNING id INTO r_cl;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx247-proc', 'FX247 Processing only', 'f', true) RETURNING id INTO r_proc;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx247-hre', 'FX247 HR viewer', 'f', true) RETURNING id INTO r_hre;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_cto, 'module.finance.view'), (r_cto, 'module.hr.view'), (r_cto, 'data.view_reviews'),
        (r_pay, 'module.finance.view'), (r_pay, 'module.hr.view'), (r_pay, 'data.view_pay'), (r_pay, 'data.view_health'),
        (r_cl, 'data.view_change_log'), (r_cl, 'module.finance.view'), (r_cl, 'module.hr.view'),
        (r_proc, 'module.processing.view'),
        (r_hre, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_cto, r_cto), (u_pay, r_pay), (u_cl, r_cl), (u_proc, r_proc), (u_hre, r_hre);
    SELECT id INTO v_pos FROM positions WHERE code = 'CTO';
    IF v_pos IS NULL THEN RAISE EXCEPTION 'FIXTURE 247 setup: the CTO position (bootstrap) is missing'; END IF;

    v_m := NULL;
    FOR v_n IN 1..24 LOOP
        v_m2 := (date_trunc('month', CURRENT_DATE) - make_interval(months => v_n + 1))::date;
        IF NOT EXISTS (SELECT 1 FROM payroll_periods p2 WHERE date_trunc('month', p2.period_month)::date IN (v_m2, (v_m2 + interval '1 month')::date))
           AND NOT EXISTS (SELECT 1 FROM attendance_periods ap WHERE ap.period_month IN (v_m2, (v_m2 + interval '1 month')::date)) THEN
            v_m := (v_m2 + interval '1 month')::date;
            EXIT;
        END IF;
    END LOOP;
    IF v_m IS NULL THEN RAISE EXCEPTION 'FIXTURE 247 setup: no two empty months within 24 months'; END IF;

    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status, position_id, monthly_salary, user_id) VALUES
        (e_emp, 'FX247-EMP', 'FX247 Employee', 'full_time', 'office', v_m2 - 400, 'active', v_pos, 4000, u_emp),
        (e_hre, 'FX247-HRE', 'FX247 HR Viewer', 'full_time', 'office', v_m2 - 400, 'active', NULL, 5000, u_hre),
        (e_other, 'FX247-OTH', 'FX247 Other', 'full_time', 'office', v_m2 - 400, 'active', NULL, 7000, NULL);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;

    PERFORM pg_temp.f247_as(u_all);
    v_r := open_attendance_period(v_m2);
    v_att := (v_r ->> 'period_id')::uuid;
    FOR r IN SELECT id FROM attendance_lines WHERE period_id = v_att LOOP PERFORM record_attendance(r.id); END LOOP;
    PERFORM complete_attendance_period(v_att);

    -- 工资期:过账 → 撤销(冲销分录)→ 再过账 → 发薪(一人一行)→ 公积金
    v_lines := jsonb_build_array(
        jsonb_build_object('employee_id', e_emp, 'gross_pay', 3000, 'employee_cpf', 600, 'employer_cpf', 510, 'other_deductions', 0, 'net_pay', 2400),
        jsonb_build_object('employee_id', e_other, 'gross_pay', 9000, 'employee_cpf', 1200, 'employer_cpf', 1020, 'other_deductions', 0, 'net_pay', 7800));
    pp := (upsert_payroll_period(v_m2, v_m2 + 27, v_ccy, 1, 'fx247 provider file', 'FX247 month', v_lines) ->> 'payroll_period_id')::uuid;
    PERFORM submit_payroll_request(pp, 'post');
    PERFORM post_payroll_period(pp);
    SELECT journal_entry_id INTO je_post1 FROM payroll_periods WHERE id = pp;
    PERFORM submit_payroll_request(pp, 'reversal', 'FX247 wrong CPF');
    PERFORM unpost_payroll_period(pp);
    SELECT id INTO je_rev FROM journal_entries WHERE source_type = 'payroll' AND source_id = je_post1;
    PERFORM submit_payroll_request(pp, 'post');
    PERFORM post_payroll_period(pp);
    SELECT journal_entry_id INTO je_post2 FROM payroll_periods WHERE id = pp;
    SELECT array_agg(id) INTO v_line_ids FROM payroll_lines WHERE payroll_period_id = pp;
    PERFORM pay_payroll_lines(pp, v_line_ids, v_m2 + 27, NULL);
    SELECT DISTINCT paid_journal_entry_id INTO je_payrun FROM payroll_lines WHERE payroll_period_id = pp;
    PERFORM pay_payroll_cpf(pp, v_m2 + 40, NULL);
    IF je_post1 IS NULL OR je_rev IS NULL OR je_post2 IS NULL OR je_payrun IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 247 setup: payroll journals post1 % rev % post2 % payrun %', je_post1, je_rev, je_post2, je_payrun; END IF;
    SELECT string_agg(quote_literal(id), ',') INTO v_pay_ids FROM journal_entries
     WHERE source_type = 'payroll' AND (source_id = pp OR source_id IN (SELECT e.id FROM journal_entries e WHERE e.source_id = pp));
    -- 一张【非】工资分录:一台机器的发票(EQ 也用它)
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
        VALUES ('ZZFIX247-S', 'fixture 247 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    v_asset := (create_fixed_asset('fixture 247 press', 120, v_m2 - 60) ->> 'asset_id')::uuid;
    v_r := record_expense(v_m2 - 55, '1500', 100000, v_ccy, NULL, 'unpaid', NULL, v_sup, NULL, 'fixture 247 machine invoice',
                          jsonb_build_object('asset_id', v_asset), NULL);
    SELECT id INTO je_exp FROM journal_entries WHERE source_type = 'expense' AND source_id = (v_r ->> 'expense_id')::uuid;

    -- ══════════════ JA · 工资分录经 API(Q1 · Q2)══════════════
    v_n := pg_temp.f247_n('JA', u_cto, format('SELECT count(*) FROM journal_lines WHERE entry_id IN (%s)', v_pay_ids));
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 247 JA: a reader without data.view_pay reads % payroll journal line(s) through the API', v_n; END IF;
    v_x := (SELECT count(*) FROM journal_lines WHERE entry_id IN (SELECT id FROM journal_entries WHERE source_type = 'payroll'
                AND (source_id = pp OR source_id IN (SELECT e.id FROM journal_entries e WHERE e.source_id = pp))));
    IF v_x < 10 THEN RAISE EXCEPTION 'FIXTURE 247 JA setup: expected the four-plus payroll journals of this period, found % lines', v_x; END IF;
    v_n := pg_temp.f247_n('JA', u_pay, format('SELECT count(*) FROM journal_lines WHERE entry_id IN (%s)', v_pay_ids));
    IF v_n <> v_x THEN RAISE EXCEPTION 'FIXTURE 247 JA: a data.view_pay holder should read all % payroll lines, read %', v_x, v_n; END IF;
    IF pg_temp.f247_n('JA', u_cto, format('SELECT count(*) FROM journal_lines WHERE entry_id = %L AND debit + credit > 0', je_exp)) < 2 THEN
        RAISE EXCEPTION 'FIXTURE 247 JA: a non-payroll journal must stay fully readable to a finance reader'; END IF;
    IF pg_temp.f247_n('JA', u_cto, format('SELECT count(*) FROM journal_lines WHERE entry_id = %L', je_rev)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 JA: the reversal of a payroll journal is a payroll journal too'; END IF;

    -- ══════════════ JM · 遮蔽视图(Q1 · Q3)══════════════
    v_n := pg_temp.f247_n('JM', u_cto, format('SELECT count(*) FROM journal_lines_masked WHERE entry_id IN (%s)', v_pay_ids));
    IF v_n <> v_x THEN RAISE EXCEPTION 'FIXTURE 247 JM: the masked view should show all % payroll lines to a finance reader, showed %', v_x, v_n; END IF;
    v_n := pg_temp.f247_n('JM', u_cto, format('SELECT count(*) FROM journal_lines_masked WHERE entry_id IN (%s)
                                                AND debit IS NULL AND credit IS NULL AND amount_ccy IS NULL AND amounts_restricted', v_pay_ids));
    IF v_n <> v_x THEN RAISE EXCEPTION 'FIXTURE 247 JM: every payroll amount must be Restricted (null + amounts_restricted), % of %', v_n, v_x; END IF;
    FOREACH u IN ARRAY ARRAY[u_cto::text, u_pay::text] LOOP
        IF pg_temp.f247_n('JM', u::uuid, format('SELECT count(*) FROM journal_lines_masked WHERE entry_id = %L AND line_memo = %L',
                                                 je_payrun, 'FX247-EMP FX247 Employee')) <> 1 THEN
            RAISE EXCEPTION 'FIXTURE 247 JM (Q3): the pay-run line memo (employee code + name) must be visible to %', u; END IF;
    END LOOP;
    IF pg_temp.f247_n('JM', u_pay, format('SELECT count(*) FROM journal_lines_masked WHERE entry_id IN (%s) AND NOT amounts_restricted
                                            AND COALESCE(debit, 0) + COALESCE(credit, 0) > 0', v_pay_ids)) <> v_x THEN
        RAISE EXCEPTION 'FIXTURE 247 JM: a data.view_pay holder reads every payroll amount'; END IF;
    IF pg_temp.f247_n('JM', u_cto, format('SELECT count(*) FROM journal_lines_masked WHERE entry_id = %L AND amounts_restricted', je_exp)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 JM: a non-payroll journal is not restricted'; END IF;

    -- ══════════════ JT · 挪走的读法:合计对每一个读者都一样(Q2)══════════════
    FOREACH u IN ARRAY ARRAY[u_cto::text, u_pay::text, u_cl::text] LOOP
        v_r := pg_temp.f247_read(u::uuid, 'SELECT COALESCE(jsonb_agg(jsonb_build_array(t.account_id, t.debits, t.credits) ORDER BY t.account_id), ''[]''::jsonb) FROM trial_balance_totals() t');
        IF v_r IS DISTINCT FROM (SELECT COALESCE(jsonb_agg(jsonb_build_array(x.account_id, x.d, x.c) ORDER BY x.account_id), '[]'::jsonb)
                                   FROM (SELECT l.account_id, sum(l.debit) d, sum(l.credit) c FROM journal_lines l GROUP BY l.account_id) x) THEN
            RAISE EXCEPTION 'FIXTURE 247 JT: trial_balance_totals for % differs from the ledger', u; END IF;
        v_r := pg_temp.f247_read(u::uuid, format('SELECT to_jsonb(p) FROM journal_close_preview(%L::date) p', v_m2 + 60));
        IF v_r IS DISTINCT FROM (SELECT to_jsonb(x) FROM (SELECT count(DISTINCT l.entry_id) AS entry_count, COALESCE(sum(l.debit), 0) AS debits,
                                        COALESCE(sum(l.credit), 0) AS credits FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id
                                  WHERE e.entry_date <= v_m2 + 60) x) THEN
            RAISE EXCEPTION 'FIXTURE 247 JT: journal_close_preview for % differs from the ledger: %', u, v_r; END IF;
        v_x := pg_temp.f247_n('JT', u::uuid, 'SELECT bank_book_balance_asof(''1000'', DATE ''2999-12-31'')');
        v_y := (SELECT round(COALESCE(sum(CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END), 0), 2)
                  FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id WHERE a.code = '1000' AND jl.currency = bank_native_currency('1000'));
        IF v_x IS DISTINCT FROM v_y THEN RAISE EXCEPTION 'FIXTURE 247 JT: the 1000 bank book for % is % — the ledger says %', u, v_x, v_y; END IF;
        v_x := pg_temp.f247_n('JT', u::uuid, 'SELECT (account_ledger(''1000'', NULL, DATE ''2999-12-31'', true) ->> ''total'')::numeric');
        v_y := (SELECT round(sum(a.signed_base), 2) FROM journal_activity_lines(NULL, DATE '2999-12-31', true) a WHERE a.account_code = '1000');
        IF v_x IS DISTINCT FROM v_y THEN RAISE EXCEPTION 'FIXTURE 247 JT: the 1000 ledger total for % is % — expected %', u, v_x, v_y; END IF;
        v_x := pg_temp.f247_n('JT', u::uuid, format('SELECT count(*) FROM journal_export_lines(%L::date, %L::date, true)', v_m2 - 90, v_m2 + 60));
        v_y := (SELECT count(*) FROM journal_activity_lines(v_m2 - 90, v_m2 + 60, true));
        IF v_x <> v_y THEN RAISE EXCEPTION 'FIXTURE 247 JT: the export for % has % lines — the ledger has %', u, v_x, v_y; END IF;
    END LOOP;
    -- 只说日期与币种、或只说"有几行候选"的三张读法:三个读者读到的一样多
    FOREACH v_txt IN ARRAY ARRAY['SELECT count(*) FROM bank_unmatched_journal_lines', 'SELECT count(*) FROM fx_rate_gaps',
                                  'SELECT count(*) FROM fx_month_end_readiness'] LOOP
        IF pg_temp.f247_n('JT', u_cto, v_txt) IS DISTINCT FROM pg_temp.f247_n('JT', u_pay, v_txt)
           OR pg_temp.f247_n('JT', u_cl, v_txt) IS DISTINCT FROM pg_temp.f247_n('JT', u_pay, v_txt) THEN
            RAISE EXCEPTION 'FIXTURE 247 JT: % differs between readers', v_txt; END IF;
    END LOOP;
    IF pg_temp.f247_n('JT', u_cto, format('SELECT count(*) FROM bank_unmatched_journal_lines WHERE entry_id = %L AND amount_ccy IS NULL AND amounts_restricted', je_payrun)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 JT: the pay-run bank lines are reconciliation candidates for every finance reader, with the amount Restricted'; END IF;
    v_r := pg_temp.f247_read(u_proc, 'SELECT to_jsonb(count(*)) FROM trial_balance_totals()');
    IF COALESCE(v_r ->> 'msg', '') NOT LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 247 JT: a reader without finance must be refused by name, not shown zero — got %', v_r; END IF;

    -- ══════════════ JR · 审计记录与汇总页(Q1:受限,不是 0.00)══════════════
    v_j := pg_temp.f247_trail(u_cto, 'journal_entry', je_payrun::text);
    IF jsonb_typeof(v_j) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 247 JR: the cto-shaped reader was refused the journal trail: %', v_j; END IF;
    SELECT count(*), count(*) FILTER (WHERE e -> 'new' -> 'debit' = '{"$restricted": true}'::jsonb OR e -> 'new' -> 'credit' = '{"$restricted": true}'::jsonb)
      INTO v_n, v_x FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'journal_lines' AND NOT (e ->> 'row_hidden')::boolean;
    IF v_n = 0 OR v_x <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 247 JR: the pay-run lines must be on the trail (not hidden) with their amounts Restricted: % lines, % restricted', v_n, v_x; END IF;
    v_j := pg_temp.f247_trail(u_pay, 'journal_entry', je_payrun::text);
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'journal_lines' AND jsonb_typeof(e -> 'new' -> 'credit') = 'number' AND jsonb_typeof(e -> 'new' -> 'debit') = 'number';
    IF v_n = 0 THEN RAISE EXCEPTION 'FIXTURE 247 JR: a data.view_pay holder reads the pay-run amounts on the trail'; END IF;
    v_r := pg_temp.f247_read(u_cl, format(
        'SELECT jsonb_agg(jsonb_build_object(''restricted'', r.row_restricted, ''credit'', r.new -> ''credit'', ''debit'', r.new -> ''debit''))
           FROM change_log_rows(p_table => ''journal_lines'', p_limit => 500) r WHERE r.new ->> ''entry_id'' = %L', je_payrun));
    IF v_r IS NULL OR jsonb_typeof(v_r) <> 'array' OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_r) x
            WHERE (x ->> 'restricted')::boolean OR NOT (x -> 'debit' = '{"$restricted": true}'::jsonb AND x -> 'credit' = '{"$restricted": true}'::jsonb)) THEN
        RAISE EXCEPTION 'FIXTURE 247 JR: on the change history a reader without data.view_pay sees each pay-run line with Restricted amounts — got %', left(COALESCE(v_r::text, '(null)'), 400); END IF;

    -- ══════════════ PT · 工资期合计、工资申请与审批留痕(Q9 · Q10)══════════════
    IF pg_temp.f247_n('PT', u_cto, format('SELECT count(*) FROM payroll_periods_masked WHERE id = %L AND gross_total IS NULL AND employer_cpf_total IS NULL
                                            AND employee_cpf_total IS NULL AND other_deductions_total IS NULL AND net_pay_total IS NULL', pp)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 PT: the five period totals must be Restricted to a reader without data.view_pay'; END IF;
    PERFORM pg_temp.f247_denied('PT (base table totals)', u_cto, 'SELECT gross_total FROM payroll_periods');
    IF pg_temp.f247_n('PT', u_cto, format('SELECT count(*) FROM payroll_requests_masked WHERE payroll_period_id = %L
                                            AND snapshot IS NULL AND gross_total IS NULL AND amount_base IS NULL', pp))
       <> (SELECT count(*) FROM payroll_requests WHERE payroll_period_id = pp) THEN
        RAISE EXCEPTION 'FIXTURE 247 PT: the request snapshot and amounts must be Restricted to a reader without data.view_pay'; END IF;
    PERFORM pg_temp.f247_denied('PT (base table snapshot)', u_cto, 'SELECT snapshot FROM payroll_requests');
    PERFORM pg_temp.f247_denied('PT (approval amounts on the base table)', u_cto, 'SELECT amount_base FROM approval_log');
    IF pg_temp.f247_n('PT', u_cto, format('SELECT count(*) FROM approval_log_masked WHERE subject_type = ''payroll_request''
                                            AND subject_id IN (SELECT id FROM payroll_requests WHERE payroll_period_id = %L) AND amount_base IS NOT NULL', pp)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 PT: an approval row of a payroll request must not carry its amount to a reader without data.view_pay'; END IF;
    IF pg_temp.f247_n('PT', u_pay, format('SELECT count(*) FROM approval_log_masked WHERE subject_type = ''payroll_request''
                                            AND subject_id IN (SELECT id FROM payroll_requests WHERE payroll_period_id = %L) AND amount_base IS NOT NULL', pp)) = 0
       OR pg_temp.f247_n('PT', u_pay, format('SELECT count(*) FROM payroll_periods_masked WHERE id = %L AND gross_total = 12000', pp)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 PT: a data.view_pay holder reads the totals and the approval amounts'; END IF;
    v_j := pg_temp.f247_trail(u_cto, 'payroll_period', pp::text);
    IF jsonb_typeof(v_j) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 247 PT: the cto-shaped HR reader was refused the period trail: %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'payroll_periods' AND e -> 'new' -> 'gross_total' = '{"$restricted": true}'::jsonb)
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'payroll_requests' AND e -> 'new' -> 'snapshot' = '{"$restricted": true}'::jsonb) THEN
        RAISE EXCEPTION 'FIXTURE 247 PT: the period totals and the request snapshot read Restricted on the trail'; END IF;

    -- ══════════════ KP · KPI(Q5)══════════════
    INSERT INTO kpi_cycles (name, period_start, period_end, due_date, status) VALUES ('FX247 KPI month', v_m2, v_m2 + 27, v_m2 + 35, 'open') RETURNING id INTO kc;
    PERFORM assign_position_kpis(e_emp, kc);
    SELECT id INTO k1 FROM kpi_entries WHERE cycle_id = kc AND employee_id = e_emp ORDER BY kpi_ref LIMIT 1;
    IF k1 IS NULL THEN RAISE EXCEPTION 'FIXTURE 247 KP setup: no KPI entries were generated'; END IF;
    PERFORM score_kpi_entry(k1, 4, 'judged', 'FX247 counted');
    IF pg_temp.f247_n('KP', u_emp, format('SELECT count(*) FROM kpi_entries WHERE cycle_id = %L', kc)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 KP (Q5): the employee must not read their own KPI entries through the base table (no self-read policy)'; END IF;
    IF pg_temp.f247_n('KP', u_emp, format('SELECT count(*) FROM my_kpi_entries WHERE id = %L AND score IS NULL AND NOT score_visible', k1)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 KP: /me shows the entry with no score while the cycle is open'; END IF;
    UPDATE kpi_cycles SET status = 'closed' WHERE id = kc;
    IF pg_temp.f247_n('KP', u_emp, format('SELECT count(*) FROM my_kpi_entries WHERE id = %L AND score = 4 AND score_visible', k1)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 KP: /me shows the score once the cycle is closed'; END IF;
    IF pg_temp.f247_n('KP', u_emp, format('SELECT count(*) FROM kpi_entries WHERE cycle_id = %L', kc)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 KP: even closed, the only self path is my_kpi_entries'; END IF;

    -- ══════════════ EN · 人事备注(Q6 · Q7)══════════════
    UPDATE employees SET notes = 'FX247 HR note about the employee', separation_notes = 'FX247 separation note' WHERE id = e_emp;
    PERFORM pg_temp.f247_denied('EN (notes on the base table)', u_emp, format('SELECT notes FROM employees WHERE id = %L', e_emp));
    PERFORM pg_temp.f247_denied('EN (separation notes on the base table)', u_emp, format('SELECT separation_notes FROM employees WHERE id = %L', e_emp));
    IF pg_temp.f247_n('EN', u_emp, format('SELECT count(*) FROM employees_masked WHERE id = %L AND notes IS NULL AND separation_notes IS NULL', e_emp)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 EN (Q6): the employee reads their own row with HR''s notes withheld'; END IF;
    IF pg_temp.f247_n('EN', u_hre, format('SELECT count(*) FROM employees_masked WHERE id = %L AND notes = %L', e_emp, 'FX247 HR note about the employee')) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 EN: a module.hr.view holder reads HR''s notes'; END IF;
    v_r := pg_temp.f247_read(u_emp, 'SELECT export_my_personal_data()');
    IF v_r IS NULL OR v_r ? 'error' OR position('FX247 HR note about the employee' in v_r::text) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 EN (Q7): the personal-data export still gives the employee the notes about them — got %', left(COALESCE(v_r::text, '(null)'), 300); END IF;

    -- ══════════════ HL · 健康数据(Q8)══════════════
    v_d := v_m + 2;
    WHILE NOT is_business_day(v_d) LOOP v_d := v_d + 1; END LOOP;
    v_r := pg_temp.f247_read(u_emp, format($q$SELECT to_jsonb(submit_leave_request(%L::uuid, 'unpaid', %L::date, %L::date, false, false, 'FX247 hospital visit', 'FX247-MC-1'))$q$,
                                           e_emp, v_d, v_d));
    lv := (v_r ->> 'request_id')::uuid;
    IF lv IS NULL THEN RAISE EXCEPTION 'FIXTURE 247 HL setup: submit_leave_request returned %', v_r; END IF;
    v_r := pg_temp.f247_read(u_emp, format($q$SELECT to_jsonb(submit_medical_claim(%L::uuid, %L::date, 85, 'FX247 migraine', 'FX247-RC'))$q$, e_emp, v_m + 3));
    mc := (v_r ->> 'claim_id')::uuid;
    IF mc IS NULL THEN RAISE EXCEPTION 'FIXTURE 247 HL setup: submit_medical_claim returned %', v_r; END IF;
    PERFORM decide_medical_claim(mc, false, 'FX247 not covered');   -- 驳回也落一行带金额的审批留痕(批准要 system_start_date,不是这一臂的事)
    -- 不持 view_health 的 HR 读者
    FOREACH u IN ARRAY ARRAY[u_cto::text, u_hre::text] LOOP
        IF pg_temp.f247_n('HL', u::uuid, format('SELECT count(*) FROM medical_claims_masked WHERE id = %L AND description IS NULL AND amount_sgd IS NULL', mc)) <> 1
           OR pg_temp.f247_n('HL', u::uuid, format('SELECT count(*) FROM medical_claim_status WHERE claim_id = %L AND description IS NULL AND amount_sgd IS NULL', mc)) <> 1
           OR pg_temp.f247_n('HL', u::uuid, format('SELECT count(*) FROM leave_requests_masked WHERE id = %L AND reason IS NULL AND certificate_ref IS NULL', lv)) <> 1 THEN
            RAISE EXCEPTION 'FIXTURE 247 HL (Q8): health text must be Restricted to a reader without data.view_health (%)', u; END IF;
    END LOOP;
    PERFORM pg_temp.f247_denied('HL (medical description on the base table)', u_cto, 'SELECT description FROM medical_claims');
    -- 额度面板:已用额是金额之和 —— 不持 view_health 的 HR 读者被按名拒;本人照旧
    v_r := pg_temp.f247_read(u_cto, format('SELECT medical_claim_balance(%L::uuid, %s)', e_emp, extract(year from v_m + 3)::int));
    IF COALESCE(v_r ->> 'msg', '') NOT LIKE 'PERMISSION_DENIED|data.view_health%' THEN
        RAISE EXCEPTION 'FIXTURE 247 HL: the claim balance (the sum of the amounts) is refused by name to a reader without data.view_health — got %', v_r; END IF;
    PERFORM pg_temp.f247_denied('HL (leave reason on the base table)', u_cto, 'SELECT reason FROM leave_requests');
    IF pg_temp.f247_n('HL', u_cto, format('SELECT count(*) FROM approval_log_masked WHERE subject_type = ''medical_claim'' AND subject_id = %L AND amount_base IS NOT NULL', mc)) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 HL: the approval row of a medical claim must not carry its amount to a reader without data.view_health'; END IF;
    -- 本人照旧读得到自己的;持码的人读得到
    IF pg_temp.f247_n('HL', u_emp, format('SELECT count(*) FROM medical_claims_masked WHERE id = %L AND description = ''FX247 migraine'' AND amount_sgd = 85', mc)) <> 1
       OR pg_temp.f247_n('HL', u_emp, format('SELECT count(*) FROM leave_requests_masked WHERE id = %L AND reason = ''FX247 hospital visit''', lv)) <> 1
       OR pg_temp.f247_n('HL', u_emp, format('SELECT count(*) FROM medical_claim_status WHERE claim_id = %L AND description = ''FX247 migraine''', mc)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 HL (Q8): an employee keeps reading their own health text'; END IF;
    IF pg_temp.f247_n('HL', u_pay, format('SELECT count(*) FROM medical_claims_masked WHERE id = %L AND description = ''FX247 migraine''', mc)) <> 1
       OR pg_temp.f247_n('HL', u_pay, format('SELECT count(*) FROM leave_requests_masked WHERE id = %L AND certificate_ref = ''FX247-MC-1''', lv)) <> 1
       OR pg_temp.f247_n('HL', u_pay, format('SELECT count(*) FROM approval_log_masked WHERE subject_type = ''medical_claim'' AND subject_id = %L AND amount_base = 85', mc)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 247 HL: a data.view_health holder reads health text and the approval amount'; END IF;
    v_j := pg_temp.f247_trail(u_cto, 'medical_claim', mc::text);
    IF jsonb_typeof(v_j) <> 'array' OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
            WHERE e ->> 'table_name' = 'medical_claims' AND e ->> 'op' = 'INSERT' AND e -> 'new' -> 'description' = '{"$restricted": true}'::jsonb
              AND e -> 'new' -> 'amount_sgd' = '{"$restricted": true}'::jsonb) THEN
        RAISE EXCEPTION 'FIXTURE 247 HL: the medical claim''s description and amount read Restricted on its trail — got %', left(COALESCE(v_j::text, '(null)'), 300); END IF;
    v_j := pg_temp.f247_trail(u_cto, 'leave_request', lv::text);
    IF jsonb_typeof(v_j) <> 'array' OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e
            WHERE e ->> 'table_name' = 'leave_requests' AND e ->> 'op' = 'INSERT' AND e -> 'new' -> 'reason' = '{"$restricted": true}'::jsonb) THEN
        RAISE EXCEPTION 'FIXTURE 247 HL: the leave reason reads Restricted on its trail'; END IF;

    -- ══════════════ CU · 工资单的币种(Q12)══════════════
    pp_usd := (upsert_payroll_period(v_m, v_m + 27, 'USD', 1.35, 'fx247 usd', NULL,
               jsonb_build_array(jsonb_build_object('employee_id', e_emp, 'gross_pay', 2000, 'employee_cpf', 0, 'employer_cpf', 0,
                                                    'other_deductions', 0, 'net_pay', 2000))) ->> 'payroll_period_id')::uuid;
    v_r := pg_temp.f247_read(u_emp, format('SELECT to_jsonb(x.currency) FROM my_period_labels() x WHERE x.period_id = %L', pp_usd));
    IF v_r IS DISTINCT FROM to_jsonb('USD'::text) THEN
        RAISE EXCEPTION 'FIXTURE 247 CU (Q12): an employee without module.hr.view reads the payslip''s own currency (USD), got %', v_r; END IF;
    PERFORM pg_temp.f247_denied('CU (the period table itself stays closed to them)', u_emp, 'SELECT gross_total FROM payroll_periods');

    -- ══════════════ EQ · 设备保养建议(Q13)══════════════
    UPDATE maintenance_settings SET capitalise_pct_of_cost = 10, capitalise_floor_base = 1000;
    INSERT INTO equipment_maintenance (equipment_id, performed_on, kind, description, performed_by_supplier_id)
        VALUES (v_asset, v_m2 - 20, 'repair', 'fixture 247 bearing', v_sup) RETURNING id INTO v_mt;
    v_exp := (record_expense(v_m2 - 20, '6100', 12000, v_ccy, NULL, 'unpaid', NULL, v_sup, NULL, 'fixture 247 repair', NULL, NULL) ->> 'expense_id')::uuid;
    UPDATE equipment_maintenance SET expense_id = v_exp WHERE id = v_mt;
    IF pg_temp.f247_n('EQ', u_proc, format('SELECT count(*) FROM equipment_maintenance_advice WHERE maintenance_id = %L
                                             AND work_cost_base IS NULL AND equipment_cost_base IS NULL AND pct_of_equipment_cost IS NULL
                                             AND meets_threshold IS TRUE', v_mt)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 EQ (Q13): a processing-only reader reads the advice without the repair spend, the machine cost or their ratio'; END IF;
    IF pg_temp.f247_n('EQ', u_pay, format('SELECT count(*) FROM equipment_maintenance_advice WHERE maintenance_id = %L
                                            AND work_cost_base = 12000 AND equipment_cost_base = 100000 AND pct_of_equipment_cost = 12', v_mt)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 247 EQ: a module.finance.view holder reads the costs'; END IF;

    -- ══════════════ AN · 匿名化(Q11)══════════════
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, employment_status, separation_date, separation_type, monthly_salary)
        VALUES (e_anon, 'FX247-ANON', 'FX247 To Forget', 'full_time', 'office', v_m2 - 900, 'separated', v_m2 - 500, 'resignation', 3300);
    INSERT INTO salary_change_requests (employee_id, label, old_monthly_salary, new_monthly_salary, effective_date, reason, status, created_by, snapshot)
        VALUES (e_anon, 'FX247-SCR', 3000, 3300, v_m2 - 600, 'FX247-SECRET raise reason', 'submitted', u_all,
                '{"monthly_salary": 3000}') RETURNING id INTO scr_a;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE salary_change_requests SET status = 'withdrawn', withdrawn_at = now(), withdrawn_by = u_all, withdraw_reason = 'FX247-SECRET withdrawn' WHERE id = scr_a;
    pp_anon := (upsert_payroll_period((v_m2 - interval '20 months')::date, (v_m2 - interval '20 months')::date + 27, v_ccy, 1, 'fx247 anon', NULL,
                jsonb_build_array(jsonb_build_object('employee_id', e_anon, 'gross_pay', 3300, 'employee_cpf', 0, 'employer_cpf', 0,
                                                     'other_deductions', 0, 'net_pay', 3300, 'notes', 'FX247-SECRET pay note'))) ->> 'payroll_period_id')::uuid;
    SELECT id INTO pl_a FROM payroll_lines WHERE payroll_period_id = pp_anon AND employee_id = e_anon;
    UPDATE payroll_lines SET notes = 'FX247-SECRET pay note' WHERE id = pl_a;
    INSERT INTO leave_requests (code, employee_id, leave_type_code, start_date, end_date, days, reason, certificate_ref, status, decided_at, decided_by, decision_notes)
        VALUES ('FX247-LV-A', e_anon, 'unpaid', v_m2 - 700, v_m2 - 700, 1, 'FX247-SECRET leave reason', 'FX247-SECRET-CERT', 'approved', now(), u_all, 'FX247-SECRET leave note')
        RETURNING id INTO lv_a;
    UPDATE leave_requests SET reason = 'FX247-SECRET leave reason (amended)' WHERE id = lv_a;
    INSERT INTO medical_claims (code, employee_id, claim_date, claim_year, amount_sgd, description, receipt_ref, status, decided_at, decided_by, decision_notes)
        VALUES ('FX247-MC-A', e_anon, v_m2 - 700, extract(year from v_m2 - 700)::int, 120, 'FX247-SECRET diagnosis', 'FX247-SECRET-RC', 'approved', now(), u_all, 'FX247-SECRET claim note')
        RETURNING id INTO mc_a;
    UPDATE medical_claims SET description = 'FX247-SECRET diagnosis (amended)' WHERE id = mc_a;
    UPDATE hr_settings SET personal_data_retention_months = 12;
    PERFORM anonymise_employee(e_anon, 'fixture 247: retention elapsed');
    -- 表里:字擦掉,金额一分不动
    IF EXISTS (SELECT 1 FROM salary_change_requests WHERE id = scr_a AND (reason <> 'ANONYMISED' OR withdraw_reason IS NOT NULL OR decision_notes IS NOT NULL))
       OR NOT EXISTS (SELECT 1 FROM salary_change_requests WHERE id = scr_a AND old_monthly_salary = 3000 AND new_monthly_salary = 3300)
       OR EXISTS (SELECT 1 FROM payroll_lines WHERE id = pl_a AND notes IS NOT NULL)
       OR NOT EXISTS (SELECT 1 FROM payroll_lines WHERE id = pl_a AND gross_pay = 3300 AND net_pay = 3300)
       OR EXISTS (SELECT 1 FROM leave_requests WHERE id = lv_a AND (reason IS NOT NULL OR certificate_ref IS NOT NULL OR decision_notes IS NOT NULL))
       OR NOT EXISTS (SELECT 1 FROM leave_requests WHERE id = lv_a AND days = 1)
       OR EXISTS (SELECT 1 FROM medical_claims WHERE id = mc_a AND (description IS NOT NULL OR receipt_ref IS NOT NULL OR decision_notes IS NOT NULL))
       OR NOT EXISTS (SELECT 1 FROM medical_claims WHERE id = mc_a AND amount_sgd = 120) THEN
        RAISE EXCEPTION 'FIXTURE 247 AN (Q11): anonymisation erases the free text and keeps the amounts in the four tables'; END IF;
    -- 记录里:一个字都不剩,金额还在,每一行都盖了 redacted_at
    SELECT count(*) INTO v_n FROM change_log c
     WHERE (c.table_name, c.row_key ->> 'id') IN (('salary_change_requests', scr_a::text), ('payroll_lines', pl_a::text),
                                                  ('leave_requests', lv_a::text), ('medical_claims', mc_a::text))
       AND (position('FX247-SECRET' in COALESCE(c.old::text, '') || COALESCE(c.new::text, '')) > 0 OR c.redacted_at IS NULL);
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 247 AN (Q11): % change-log row(s) of the person still carry free text or were not redacted', v_n; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'medical_claims' AND c.row_key ->> 'id' = mc_a::text AND c.new ->> 'amount_sgd' = '120')
       OR NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'payroll_lines' AND c.row_key ->> 'id' = pl_a::text AND (c.new ->> 'gross_pay')::numeric = 3300)
       OR NOT EXISTS (SELECT 1 FROM change_log c WHERE c.table_name = 'salary_change_requests' AND c.row_key ->> 'id' = scr_a::text AND (c.new ->> 'new_monthly_salary')::numeric = 3300) THEN
        RAISE EXCEPTION 'FIXTURE 247 AN (Q11): the change log keeps the amounts'; END IF;
    SELECT count(*) INTO v_n FROM change_log c
     WHERE (c.table_name, c.row_key ->> 'id') IN (('salary_change_requests', scr_a::text), ('payroll_lines', pl_a::text),
                                                  ('leave_requests', lv_a::text), ('medical_claims', mc_a::text));
    IF v_n < 8 THEN RAISE EXCEPTION 'FIXTURE 247 AN setup: expected the inserts and edits of the four rows on the change log, found %', v_n; END IF;

    RAISE NOTICE 'FIXTURE 247 全部通过:JA(Q1 · Q2)· JM(Q1 · Q3)· JT(Q2)· JR(Q1)· PT(Q9 · Q10)· KP(Q5)· EN(Q6 · Q7)· HL(Q8)· CU(Q12)· EQ(Q13)· AN(Q11)';
END;
$$;

ROLLBACK;

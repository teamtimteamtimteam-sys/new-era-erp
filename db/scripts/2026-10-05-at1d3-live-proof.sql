-- db/scripts/2026-10-05-at1d3-live-proof.sql
-- AUDIT-TRAIL-1d-3 · 线上的证明(形状照 1d-2 的那一份)。以 postgres 跑,读者一律是【真账号】的会话(SET LOCAL ROLE authenticated + JWT)。
--   A  只读,以 admin@ 读:每一个工资期、每一份评审、每一轮评审、每一条 KPI 条目 · 评分刻度那一本集合。
--      不许被拒;每一条有它的建立(之前那一段的,或之后的 INSERT);一行只出现一次。
--   B  回滚:admin@ 建一个工资期(两行:Choo Er · Fu Sheng)再重导一次(Choo Er 一分没变,Fu Sheng 的工资变了 —— Q11);
--      admin@ 开那一个月的考勤;admin@ 建一轮评审、开它(每一名在职员工一份)、关它(Q6);在其中 Choo Er 那一份上,admin@ 指定
--      Fu Sheng 为审核人(线上唯一不持 module.hr.view 的账号 —— Q5 的读者)、加一个目标、写结论,Fu Sheng 送审,admin@ 批准(Q7);
--      admin@ 改评分刻度一档的说明。以签了名的账号读它们的审计记录:admin@(工资期 · 轮次 · 刻度 · 评审)、vince@(gm:持 hr.view 与
--      view_reviews,不持 view_pay —— Q7)、fusheng@(审核人那一份,M12 · Q5)、chooer@(被评审的本人 —— 进不了审核人那一份)。
--      Q19:以 fusheng@ 的身份读 /me 读的那几句 —— 自己的考勤行与工资单看得见,两张期间表直读仍是 0 行,my_period_labels() 给出编号与月份。
--   ★ 不建、不停、不删任何账号;不决定、不改、不删任何一张在这之前就在的单据(评分刻度是设置,改了一格,回滚之后原样 —— 前后读数为证;
--     批准的是本证明自己在这一笔里开出来的那一份评审;那一份没有新月薪 —— 线上没有一名员工有月薪,批准不会去改员工那一行)。
--   整个文件一笔事务,末尾 ROLLBACK —— 不留下任何东西。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f db/scripts/2026-10-05-at1d3-live-proof.sql > out.txt;  PROOF_OWN_EXIT=$?
BEGIN;
SET LOCAL statement_timeout = '600s';

CREATE TEMP TABLE p_out (label text, subject text, id text, grp text, rows jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp.p_trail(p_user uuid, p_subject text, p_id text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, 500) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE EXCEPTION 'PROOF|% % refused or failed: %', p_subject, p_id, SQLERRM;
END;
$f$;

-- 被拒才对的那一种读(M12):被拒返回 true,读到了返回 false
CREATE FUNCTION pg_temp.p_refused(p_user uuid, p_subject text, p_id text) RETURNS boolean
LANGUAGE plpgsql AS $f$
DECLARE v int;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v FROM record_trail(p_subject, p_id, 500);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN false;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLERRM LIKE 'TRAIL_NOT_PERMITTED%' THEN RETURN true; END IF;
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.p_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

CREATE FUNCTION pg_temp.p_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                    WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                      AND (p_col IS NULL OR e -> 'changed_columns' ? p_col))
$f$;

CREATE FUNCTION pg_temp.p_keep(p_label text, p_user uuid, p_subject text, p_id text, p_grp text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := pg_temp.p_trail(p_user, p_subject, p_id);
BEGIN
    INSERT INTO p_out VALUES (p_label, p_subject, p_id, p_grp, v);
    RETURN v;
END;
$f$;

-- ══════════════ A · 只读:线上的每一条 ══════════════
DO $a$
DECLARE
    adm uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@swm-os.test
    v jsonb; t record; n int := 0; p int := 0;
BEGIN
    FOR t IN SELECT 'payroll_period' AS s, id::text AS id, code AS c FROM payroll_periods
             UNION ALL SELECT 'performance_review', id::text, id::text FROM performance_reviews
             UNION ALL SELECT 'review_cycle', id::text, name FROM review_cycles
             UNION ALL SELECT 'kpi_entry', id::text, kpi_ref FROM kpi_entries LOOP
        v := pg_temp.p_keep('A ' || t.s, adm, t.s, t.id);
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'op' = 'INSERT'
                         AND e ->> 'table_name' = (SELECT root_table FROM trail_subjects() WHERE subject = t.s)) THEN
            RAISE EXCEPTION 'PROOF A|% % has no creation on its trail', t.s, t.c; END IF;
        p := p + (SELECT count(*) FROM jsonb_array_elements(v) e WHERE (e ->> 'prelog')::boolean)::int;
        n := n + 1;
    END LOOP;
    v := pg_temp.p_keep('A review_rating_scale', adm, 'review_rating_scale', 'all');
    IF (SELECT count(*) FROM jsonb_array_elements(v) e WHERE e ->> 'op' = 'INSERT' AND e ->> 'table_name' = 'review_rating_scale')
       < (SELECT count(*) FROM review_rating_scale) THEN
        RAISE EXCEPTION 'PROOF A|the rating scale lacks a creation for one of its ratings'; END IF;
    p := p + (SELECT count(*) FROM jsonb_array_elements(v) e WHERE (e ->> 'prelog')::boolean)::int;
    n := n + 1;
    IF EXISTS (SELECT 1 FROM p_out WHERE pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF A|a row shows twice: %', (SELECT string_agg(label || ' ' || id || ': ' || pg_temp.p_twice(rows), '; ') FROM p_out WHERE pg_temp.p_twice(rows) IS NOT NULL); END IF;
    RAISE NOTICE 'PROOF A passed: % records read as admin@, none refused, every one with its creation; % pre-log row(s); nothing twice', n, p;
END;
$a$;

-- ══════════════ B · 回滚:工资期 · 考勤 · 评审轮次 · 评审 · 评分刻度 ══════════════
DO $b$
DECLARE
    adm uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@(HR、批准人)
    fus uuid; vin uuid; cho uuid;
    e_fus uuid; e_cho uuid;
    v_month date := DATE '2026-09-01';                     -- 线上没有这一个月的工资期,也没有这一个月的考勤(前提,下面断言)。
                                                           -- 不是 08:Fu Sheng 2026-09-01 入职,8 月的考勤里没有那一行(第一跑实测 0 / 1)
    pp uuid; ap uuid; cyc uuid; rv uuid; v jsonb; r jsonb; lab jsonb; n int; n2 int; n3 int;
BEGIN
    SELECT id INTO fus FROM auth.users WHERE email LIKE 'fusheng@%';
    SELECT id INTO vin FROM auth.users WHERE email LIKE 'vince@%';
    SELECT id INTO cho FROM auth.users WHERE email LIKE 'chooer@%';
    SELECT id INTO e_fus FROM employees WHERE user_id = fus AND deleted_at IS NULL;
    SELECT id INTO e_cho FROM employees WHERE user_id = cho AND deleted_at IS NULL;
    IF fus IS NULL OR vin IS NULL OR cho IS NULL OR e_fus IS NULL OR e_cho IS NULL THEN RAISE EXCEPTION 'PROOF B|setup: an account or employee not found'; END IF;
    IF EXISTS (SELECT 1 FROM payroll_periods WHERE period_month = v_month) OR EXISTS (SELECT 1 FROM attendance_periods WHERE period_month = v_month) THEN
        RAISE EXCEPTION 'PROOF B|setup: % already has a payroll or attendance period', v_month; END IF;
    IF EXISTS (SELECT 1 FROM user_roles ur JOIN role_permissions rp ON rp.role_id = ur.role_id
                WHERE ur.user_id = fus AND ur.revoked_at IS NULL AND rp.permission_code = 'module.hr.view') THEN
        RAISE EXCEPTION 'PROOF B|setup: fusheng@ holds module.hr.view — the account is no longer the reader Q5 and Q19 need'; END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- 工资期:建(两行),再重导(Choo Er 一分没变,Fu Sheng 变了 —— Q11)
    r := upsert_payroll_period(v_month, v_month + 29, (SELECT code FROM currencies WHERE is_base), 1, 'ZZ AT1D3 proof file', NULL,
        jsonb_build_array(jsonb_build_object('employee_id', e_cho, 'gross_pay', 4000, 'employee_cpf', 800, 'employer_cpf', 680, 'other_deductions', 0, 'net_pay', 3200),
                          jsonb_build_object('employee_id', e_fus, 'gross_pay', 3000, 'employee_cpf', 600, 'employer_cpf', 510, 'other_deductions', 0, 'net_pay', 2400)));
    pp := (r ->> 'payroll_period_id')::uuid;
    PERFORM upsert_payroll_period(v_month, v_month + 29, (SELECT code FROM currencies WHERE is_base), 1, 'ZZ AT1D3 proof file', NULL,
        jsonb_build_array(jsonb_build_object('employee_id', e_cho, 'gross_pay', 4000, 'employee_cpf', 800, 'employer_cpf', 680, 'other_deductions', 0, 'net_pay', 3200),
                          jsonb_build_object('employee_id', e_fus, 'gross_pay', 3200, 'employee_cpf', 640, 'employer_cpf', 544, 'other_deductions', 0, 'net_pay', 2560)));
    -- 那一个月的考勤(每一名在职员工一行 —— Fu Sheng 也有一行)
    ap := (open_attendance_period(v_month) ->> 'period_id')::uuid;
    -- 一轮评审:建 · 开 · 关(Q6)
    INSERT INTO review_cycles (name, period_start, period_end, due_date) VALUES ('ZZ AT1D3 proof cycle', DATE '2026-01-01', DATE '2026-12-31', DATE '2027-01-31')
        RETURNING id INTO cyc;
    PERFORM open_review_cycle(cyc);
    UPDATE review_cycles SET status = 'closed' WHERE id = cyc;
    SELECT id INTO rv FROM performance_reviews WHERE cycle_id = cyc AND employee_id = e_cho;
    IF rv IS NULL THEN RAISE EXCEPTION 'PROOF B|opening the cycle made no review for Choo Er'; END IF;
    PERFORM set_review_reviewer(rv, e_fus);
    PERFORM add_review_goal(rv, 'ZZ AT1D3 close the month on time', 12, 'months');
    PERFORM set_review_conclusion(rv, 'MEETS', 'ZZ AT1D3 proof: a steady year');
    -- 评分刻度:改一档的说明
    UPDATE review_rating_scale SET description_en = description_en || ' (ZZ AT1D3 proof)' WHERE code = 'MEETS';
    EXECUTE 'RESET ROLE';
    -- 审核人送审(fusheng@),admin@ 批准
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fus), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM submit_review(rv);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM approve_review(rv);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);

    -- Q19:以 fusheng@(不持 hr.view)读 /me 读的那几句
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fus), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n FROM attendance_lines WHERE employee_id = current_user_employee();
    SELECT count(*) INTO n2 FROM payroll_lines_masked WHERE employee_id = current_user_employee();
    SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.kind), '[]'::jsonb) INTO lab FROM my_period_labels() x;
    SELECT count(*) INTO n3 FROM (SELECT 1 FROM attendance_periods UNION ALL SELECT 1 FROM payroll_periods) d;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF n < 1 OR n2 < 1 THEN RAISE EXCEPTION 'PROOF B Q19|setup: fusheng@ should read their own attendance line and payslip (% / %)', n, n2; END IF;
    IF NOT (lab @> jsonb_build_array(jsonb_build_object('kind', 'attendance', 'period_id', ap, 'period_month', v_month))
            AND lab @> jsonb_build_array(jsonb_build_object('kind', 'payroll', 'period_id', pp, 'period_month', v_month))) THEN
        RAISE EXCEPTION 'PROOF B Q19|my_period_labels() as fusheng@ should give the code and month of both periods, got %', lab; END IF;
    IF n3 <> 0 THEN RAISE EXCEPTION 'PROOF B Q19|the two period tables must stay unreadable directly, got % rows', n3; END IF;
    RAISE NOTICE 'PROOF B Q19: as fusheng@ (no module.hr.view), /me reads % own attendance line(s) and % payslip(s); my_period_labels() gives %; the period tables read directly: % rows',
        n, n2, (SELECT string_agg((x ->> 'kind') || ' ' || (x ->> 'code') || ' ' || (x ->> 'period_month'), ' · ') FROM jsonb_array_elements(lab) x), n3;

    -- 以签了名的账号读
    v := pg_temp.p_keep('B payroll period (admin@)', adm, 'payroll_period', pp::text);
    IF NOT pg_temp.p_has(v, 'payroll_lines', 'DELETE') OR NOT pg_temp.p_has(v, 'payroll_lines', 'INSERT') OR NOT pg_temp.p_has(v, 'payroll_periods', 'INSERT') THEN
        RAISE EXCEPTION 'PROOF B|the payroll save and re-save are incomplete on the trail'; END IF;
    PERFORM pg_temp.p_keep('B payroll period (vince@, no data.view_pay)', vin, 'payroll_period', pp::text);
    v := pg_temp.p_keep('B review cycle (admin@)', adm, 'review_cycle', cyc::text);
    IF NOT pg_temp.p_has(v, 'review_cycles', 'INSERT') OR NOT pg_temp.p_has(v, 'review_cycles', 'UPDATE', 'status')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'performance_reviews') THEN
        RAISE EXCEPTION 'PROOF B|the cycle trail is not created · opened · closed alone (Q6)'; END IF;
    v := pg_temp.p_keep('B review (admin@)', adm, 'performance_review', rv::text);
    IF NOT pg_temp.p_has(v, 'performance_reviews', 'INSERT') OR NOT pg_temp.p_has(v, 'approval_log', 'INSERT') OR NOT pg_temp.p_has(v, 'review_goals', 'INSERT') THEN
        RAISE EXCEPTION 'PROOF B|the review trail is incomplete'; END IF;
    PERFORM pg_temp.p_keep('B review (vince@, Q7)', vin, 'performance_review', rv::text);
    v := pg_temp.p_keep('B my review (fusheng@, the reviewer — M12 · Q5)', fus, 'my_review', rv::text);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'approval_log') THEN
        RAISE EXCEPTION 'PROOF B|the approval rows are readable by a reviewer without hr.view (Q5)'; END IF;
    IF NOT pg_temp.p_refused(cho, 'my_review', rv::text) THEN
        RAISE EXCEPTION 'PROOF B|the reviewed employee (chooer@) reads the reviewer''s trail (M12)'; END IF;
    IF NOT pg_temp.p_refused(fus, 'performance_review', rv::text) THEN
        RAISE EXCEPTION 'PROOF B|the reviewer without hr.view reads the HR page''s subject'; END IF;
    v := pg_temp.p_keep('B rating scale (admin@)', adm, 'review_rating_scale', 'all');
    IF NOT pg_temp.p_has(v, 'review_rating_scale', 'UPDATE', 'description_en') THEN RAISE EXCEPTION 'PROOF B|the rating change is missing'; END IF;
    IF EXISTS (SELECT 1 FROM p_out WHERE label LIKE 'B%' AND pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF B|a row shows twice'; END IF;
    RAISE NOTICE 'PROOF B passed: payroll % saved and re-saved, attendance % opened, cycle opened and closed, review of Choo Er approved, a rating changed',
        (SELECT code FROM payroll_periods WHERE id = pp), (SELECT code FROM attendance_periods WHERE id = ap);
END;
$b$;

-- 给造句器的那一份:每一条一行 JSON
\pset tuples_only on
\pset format unaligned
SELECT jsonb_build_object('label', label, 'subject', subject, 'id', id, 'grp', grp, 'rows', rows)::text FROM p_out ORDER BY label LIKE 'B%', label, subject, id;

ROLLBACK;

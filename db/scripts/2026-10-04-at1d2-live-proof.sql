-- db/scripts/2026-10-04-at1d2-live-proof.sql
-- AUDIT-TRAIL-1d-2 · 线上的证明(形状照 1d-1 的那一份)。以 postgres 跑,读者一律是【真账号】的会话(SET LOCAL ROLE authenticated + JWT)。
--   A  只读,以 admin@ 读:每一张请假、医疗报销、加班批、考勤期间、假期发放 · 假别与公共假期两本集合 · 付医疗报销的那张费用单(Q37)。
--      不许被拒;每一条有它的建立;一行只出现一次;请假记录开始之前的决定戳与审批留痕同一刻时同一个 op_key(Q12)。
--      外加以每一名挂着账号的员工本人读自己的请假与医疗报销(/me,M8)—— 读得到,审批留痕是 Restricted。
--   B  回滚:fusheng@(仓库,EMP-2026-0006)申请一天无薪假,admin@ 批;fusheng@ 提一张医疗报销,admin@ 改它的说明;
--      临时把 sandra(EMP-2026-0004)标成现场员工,admin@(overtime_enter)开一张上个月的加班批、加两行、送审,fusheng@(overtime_approve)退回;
--      改一个假别的标准天数、一个公共假期的备注,加一个 ZZ 假期再硬删它;开上个月的考勤(Q19:以 fusheng@ 读 /me 那两句 —— 自己的考勤行看得见,
--      期间看不见)。以签了名的账号读它们的审计记录。
--   ★ 不建、不停、不删任何账号;不决定、不改、不删任何一张在这之前就在的单据(假别与公共假期是设置,改了一格,回滚之后原样 —— 前后读数为证)。
--   整个文件一笔事务,末尾 ROLLBACK —— 不留下任何东西。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f db/scripts/2026-10-04-at1d2-live-proof.sql > out.txt;  PROOF_OWN_EXIT=$?
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
    v jsonb; t record; n int := 0; m int := 0; d jsonb; a jsonb;
BEGIN
    FOR t IN SELECT 'leave_request' AS s, id::text AS id, code AS c FROM leave_requests
             UNION ALL SELECT 'medical_claim', id::text, code FROM medical_claims
             UNION ALL SELECT 'overtime_batch', id::text, label FROM overtime_batches
             UNION ALL SELECT 'attendance_period', id::text, code FROM attendance_periods
             UNION ALL SELECT 'leave_grant', id::text, leave_year::text FROM leave_grants LOOP
        v := pg_temp.p_keep('A ' || t.s, adm, t.s, t.id);
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'op' = 'INSERT'
                         AND e ->> 'table_name' = (SELECT root_table FROM trail_subjects() WHERE subject = t.s)) THEN
            RAISE EXCEPTION 'PROOF A|% % has no creation on its trail', t.s, t.c; END IF;
        n := n + 1;
    END LOOP;
    -- Q12:请假记录开始之前的决定戳,与同一刻的审批留痕同一个 op_key(界面说一次)
    FOR t IN SELECT id::text AS id, code FROM leave_requests WHERE decided_at < change_log_began_at() LOOP
        v := (SELECT rows FROM p_out WHERE subject = 'leave_request' AND id = t.id);
        d := (SELECT e FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'leave_requests' AND (e ->> 'prelog')::boolean
                                                           AND e -> 'changed_columns' ? 'decided_at' LIMIT 1);
        a := (SELECT e FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'approval_log' AND (e ->> 'prelog')::boolean
                                                           AND e ->> 'occurred_at' = d ->> 'occurred_at' LIMIT 1);
        IF d IS NOT NULL AND a IS NOT NULL AND d ->> 'op_key' <> a ->> 'op_key' THEN
            RAISE EXCEPTION 'PROOF A|% (Q12): the decision stamp and its approval row are two operations', t.code; END IF;
        IF d IS NOT NULL AND a IS NOT NULL THEN m := m + 1; END IF;
    END LOOP;
    FOR t IN SELECT s.subject FROM trail_subjects() s WHERE s.subject IN ('leave_types', 'public_holidays') LOOP
        v := pg_temp.p_keep('A ' || t.subject, adm, t.subject, 'all');
        IF jsonb_array_length(v) = 0 THEN RAISE EXCEPTION 'PROOF A|% has an empty trail', t.subject; END IF;
        n := n + 1;
    END LOOP;
    -- Q37:付医疗报销的那张费用单
    FOR t IN SELECT expense_id::text AS id, code FROM medical_claims WHERE expense_id IS NOT NULL LOOP
        v := pg_temp.p_keep('A expense (Q37)', adm, 'expense', t.id);
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'medical_claims') THEN
            RAISE EXCEPTION 'PROOF A|the expense of % does not reach the claim (Q37)', t.code; END IF;
        n := n + 1;
    END LOOP;
    IF EXISTS (SELECT 1 FROM p_out WHERE pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF A|a row shows twice: %', (SELECT string_agg(label || ' ' || id || ': ' || pg_temp.p_twice(rows), '; ') FROM p_out WHERE pg_temp.p_twice(rows) IS NOT NULL); END IF;
    -- /me(M8):每一名挂着账号的员工读自己的请假与医疗报销 —— 读得到;审批留痕一行都读不到(Restricted)
    FOR t IN SELECT 'my_leave_request' AS s, l.id::text AS id, e.user_id AS u, l.code FROM leave_requests l JOIN employees e ON e.id = l.employee_id WHERE e.user_id IS NOT NULL
             UNION ALL SELECT 'my_medical_claim', mc.id::text, e.user_id, mc.code FROM medical_claims mc JOIN employees e ON e.id = mc.employee_id WHERE e.user_id IS NOT NULL LOOP
        v := pg_temp.p_keep('A ' || t.s, t.u, t.s, t.id);
        -- 审批留痕的读规则是 hr.view:本人不持它时是 Restricted;持它的本人(admin@ 的员工档案)照规矩读得到
        IF NOT EXISTS (SELECT 1 FROM user_roles ur JOIN role_permissions rp ON rp.role_id = ur.role_id
                        WHERE ur.user_id = t.u AND ur.revoked_at IS NULL AND rp.permission_code = 'module.hr.view')
           AND EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'approval_log') THEN
            RAISE EXCEPTION 'PROOF A|% %: the approval row is readable on /me by an employee without hr.view', t.s, t.code; END IF;
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'PROOF A passed: % records read, none refused; % pre-log leave decision(s) fold with their approval row', n, m;
END;
$a$;

-- ══════════════ B · 回滚:请假 · 医疗报销 · 加班 · 假别 · 公共假期 · 考勤 ══════════════
DO $b$
DECLARE
    adm uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@(决定、开批)
    fus uuid;                                             -- fusheng@(仓库:本人申请、退回加班)
    e_fus uuid; e_san uuid; lv uuid; mc uuid; ob uuid; hol uuid; ap uuid; v jsonb; r jsonb;
    v_month date := date_trunc('month', CURRENT_DATE - 31)::date;
    n_lines int; n_periods int;
BEGIN
    SELECT id INTO fus FROM auth.users WHERE email LIKE 'fusheng@%';
    SELECT id INTO e_fus FROM employees WHERE user_id = fus AND deleted_at IS NULL;
    SELECT id INTO e_san FROM employees WHERE code = 'EMP-2026-0004';
    IF fus IS NULL OR e_fus IS NULL OR e_san IS NULL THEN RAISE EXCEPTION 'PROOF B|setup: fusheng@ or EMP-2026-0004 not found'; END IF;

    -- 请假:本人申请,admin@ 批
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fus), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    r := submit_leave_request(e_fus, 'unpaid', CURRENT_DATE + 40, CURRENT_DATE + 40, false, false, 'ZZ AT1D2 proof');
    lv := (r ->> 'request_id')::uuid;
    r := submit_medical_claim(e_fus, CURRENT_DATE, 40, 'ZZ AT1D2 proof claim', 'ZZ-RC');
    mc := (r ->> 'claim_id')::uuid;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_leave_request(lv, true, 'ZZ proof approval');
    UPDATE medical_claims SET description = 'ZZ AT1D2 proof claim — changed' WHERE id = mc;
    -- 假别 · 公共假期:改一格;一个 ZZ 假期加上再硬删
    UPDATE leave_types SET default_days_per_year = default_days_per_year + 1 WHERE code = 'examination';
    UPDATE public_holidays SET notes = 'ZZ AT1D2 proof note' WHERE id = (SELECT id FROM public_holidays ORDER BY holiday_date DESC LIMIT 1);
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key) VALUES (DATE '2031-01-02', 'ZZ AT1D2 Day', '测试', 'zz-at1d2') RETURNING id INTO hol;
    DELETE FROM public_holidays WHERE id = hol;
    EXECUTE 'RESET ROLE';
    -- 加班:临时把 sandra 标成现场员工(postgres 写,回滚);admin@ 开批、加两行、送审;fusheng@ 退回
    UPDATE employees SET is_site_staff = true WHERE id = e_san;
    EXECUTE 'SET LOCAL ROLE authenticated';
    r := create_overtime_batch(v_month);
    ob := (r ->> 'batch_id')::uuid;
    PERFORM add_overtime_line(ob, e_san, v_month + 6, 3.5, 'ZZ proof line');
    PERFORM add_overtime_line(ob, e_san, v_month + 7, 2, NULL);
    PERFORM submit_overtime_batch(ob);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fus), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM decide_overtime_batch(ob, 'rejected', 'ZZ proof: Friday hours look doubled');
    EXECUTE 'RESET ROLE';
    -- 考勤:开上个月(admin@);Q19 —— fusheng@ 读 /me 的那两句
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', adm), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    r := open_attendance_period(v_month);
    ap := (r ->> 'period_id')::uuid;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', fus), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO n_lines FROM attendance_lines WHERE employee_id = current_user_employee();
    SELECT count(*) INTO n_periods FROM attendance_periods WHERE id IN (SELECT period_id FROM attendance_lines WHERE employee_id = current_user_employee());
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE NOTICE 'PROOF B Q19: as fusheng@ (no module.hr.view), /me reads % own attendance line(s) and % of their period(s)', n_lines, n_periods;

    -- 以签了名的账号读
    v := pg_temp.p_keep('B leave (admin@)', adm, 'leave_request', lv::text);
    IF NOT pg_temp.p_has(v, 'leave_requests', 'UPDATE', 'status') OR NOT pg_temp.p_has(v, 'approval_log', 'INSERT') THEN
        RAISE EXCEPTION 'PROOF B|the leave decision is incomplete on the trail'; END IF;
    v := pg_temp.p_keep('B my leave (fusheng@)', fus, 'my_leave_request', lv::text);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v) e WHERE e ->> 'table_name' = 'approval_log') THEN
        RAISE EXCEPTION 'PROOF B|the approval row is readable on /me'; END IF;
    v := pg_temp.p_keep('B claim (admin@)', adm, 'medical_claim', mc::text);
    IF NOT pg_temp.p_has(v, 'medical_claims', 'INSERT') OR NOT pg_temp.p_has(v, 'medical_claims', 'UPDATE', 'description') THEN
        RAISE EXCEPTION 'PROOF B|the claim and its change are not both on the trail'; END IF;
    PERFORM pg_temp.p_keep('B my claim (fusheng@)', fus, 'my_medical_claim', mc::text);
    v := pg_temp.p_keep('B overtime (admin@)', adm, 'overtime_batch', ob::text);
    IF NOT pg_temp.p_has(v, 'overtime_batches', 'UPDATE', 'status') OR NOT pg_temp.p_has(v, 'approval_log', 'INSERT') THEN
        RAISE EXCEPTION 'PROOF B|the send-back is incomplete on the trail'; END IF;
    PERFORM pg_temp.p_keep('B overtime (fusheng@, M1 · Q20)', fus, 'overtime_batch', ob::text);
    v := pg_temp.p_keep('B leave types', adm, 'leave_types', 'all');
    IF NOT pg_temp.p_has(v, 'leave_types', 'UPDATE', 'default_days_per_year') THEN RAISE EXCEPTION 'PROOF B|the leave type change is missing'; END IF;
    v := pg_temp.p_keep('B public holidays', adm, 'public_holidays', 'all');
    IF NOT pg_temp.p_has(v, 'public_holidays', 'UPDATE', 'notes') OR NOT pg_temp.p_has(v, 'public_holidays', 'DELETE') THEN
        RAISE EXCEPTION 'PROOF B|the holiday change or the hard delete is missing'; END IF;
    v := pg_temp.p_keep('B attendance', adm, 'attendance_period', ap::text);
    IF NOT pg_temp.p_has(v, 'attendance_periods', 'INSERT') THEN RAISE EXCEPTION 'PROOF B|the opened period is missing'; END IF;
    IF EXISTS (SELECT 1 FROM p_out WHERE label LIKE 'B%' AND pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF B|a row shows twice'; END IF;
    RAISE NOTICE 'PROOF B passed: leave % approved, claim % changed, overtime % sent back, a leave type and a holiday changed, a ZZ holiday added and deleted, period % opened',
        (SELECT code FROM leave_requests WHERE id = lv), (SELECT code FROM medical_claims WHERE id = mc), (SELECT label FROM overtime_batches WHERE id = ob),
        (SELECT code FROM attendance_periods WHERE id = ap);
END;
$b$;

-- 给造句器的那一份:每一条一行 JSON
\pset tuples_only on
\pset format unaligned
SELECT jsonb_build_object('label', label, 'subject', subject, 'id', id, 'grp', grp, 'rows', rows)::text FROM p_out ORDER BY label LIKE 'B%', label, subject, id;

ROLLBACK;

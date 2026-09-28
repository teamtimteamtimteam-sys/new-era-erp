-- db/scripts/2026-09-28-overtime1-live-proof.sql
-- OVERTIME-1 · 线上证明 —— 一笔事务,最后 ROLLBACK,线上什么都不留。
--
-- 身份:以 postgres 连接(rolbypassrls = t);每一格切到【真账号】的 JWT 并 SET LOCAL ROLE authenticated,
-- 并且先断言 auth.uid() 与 current_user 真的切过去了(AGENTS.md:一个读数先说它是谁读的)。
--
-- Tim 的五步(OVERTIME-1 build 委托书):
--   1. 临时把一个测试员工标为现场员工(EMP-2026-0005 Cheng Siong Phua —— 不是 Fu Sheng,Tim 裁定他不是现场员工);
--   2. 以 chooer@(finance)建一批、录行、交去批;
--   3. 以 fusheng@(warehouse)批准;
--   4. 完成那个月的考勤,确认小时冻进了底稿(正好一次,等于批过的行之和);
--   5. Q20:tim@ 决定自己的报销单,确认 self_decided 的标记(approval_log 与 my_document_decisions() 两处);
--   6. ROLLBACK。
-- 月份用 2026-09(本月):它不在未来、不早于系统起点(2026-08-01)、没有考勤底稿、工资没过账。
-- ★ 第一次跑用的是 2026-08,在第 2 格按名停下 —— OVERTIME_NO_SITE_STAFF|2026-08:EMP-2026-0005 的入职日是
--   2026-09-01,八月他不在职,而"那个月在职的现场员工"正是建批的判据。**错的是期望,不是规则**(那一次整笔回滚,
--   什么都没留下)。线上九月的假期表是空的,所以这里只证得出平日与星期日两类;公共假期那一类由 fixture 232 的 K 臂钉住。
--   9/6 与 9/13 是星期日(休息日),9/7 与 9/8 是星期一、二(平日)。
\set ON_ERROR_STOP on
\pset footer off
BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'OT1_LIVE|no such account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $f$;

-- 以某个账号跑一句,返回 'OK' 或那一句拒绝;切身份并自证
CREATE FUNCTION pg_temp.try_as(p_email text, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
    v := pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM v THEN
        RAISE EXCEPTION 'OT1_LIVE|identity did not switch (%, %)', current_user, auth.uid(); END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    IF SQLERRM LIKE 'OT1_LIVE|%' THEN RAISE; END IF;
    RETURN SQLERRM;
END $f$;

CREATE FUNCTION pg_temp.rows_as(p_email text, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v uuid; r jsonb;
BEGIN
    v := pg_temp.as_user(p_email);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM v THEN
        RAISE EXCEPTION 'OT1_LIVE|identity did not switch (%, %)', current_user, auth.uid(); END IF;
    EXECUTE 'SELECT COALESCE(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) FROM (' || p_sql || ') q' INTO r;
    EXECUTE 'RESET ROLE';
    RETURN r;
END $f$;

CREATE FUNCTION pg_temp.want(p_cell text, p_got text, p_want text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got IS DISTINCT FROM p_want THEN
        RAISE EXCEPTION 'OT1_LIVE|% expected %, got %', p_cell, p_want, COALESCE(p_got, '(NULL)'); END IF;
    RAISE NOTICE 'OT1_LIVE % ✓ %', p_cell, p_got;
END $f$;

DO $$
DECLARE
    e_phua uuid; e_tim uuid; v_base text; v_b uuid; v_att uuid; v_line uuid; v_clm uuid;
    v_r jsonb; v_msg text; v_n bigint; v_frozen numeric; v_approved numeric; v_row record;
    v_log_before bigint; v_je_before bigint;
BEGIN
    -- P0 · 身份与前提
    IF NOT (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user) THEN
        RAISE EXCEPTION 'OT1_LIVE|expected a bypassrls connection'; END IF;
    PERFORM pg_temp.want('P0 approvals on', (SELECT approvals_enabled::text FROM finance_settings), 'true');
    PERFORM pg_temp.want('P0 nobody flagged', (SELECT count(*)::text FROM employees WHERE is_site_staff), '0');
    PERFORM pg_temp.want('P0 no overtime batches', (SELECT count(*)::text FROM overtime_batches), '0');
    PERFORM pg_temp.want('P0 no attendance for 2026-09', (SELECT count(*)::text FROM attendance_periods WHERE period_month = DATE '2026-09-01'), '0');
    SELECT id INTO e_phua FROM employees WHERE code = 'EMP-2026-0005';
    SELECT id INTO e_tim  FROM employees WHERE code = 'EMP-2026-0002';
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT count(*) INTO v_log_before FROM approval_log;
    SELECT count(*) INTO v_je_before FROM journal_entries;

    -- P1 · 空态:一个现场员工都没有 —— chooer@ 读 0 行,建批按名拒
    v_r := pg_temp.rows_as('chooer@evoltrya.test', 'SELECT * FROM overtime_site_staff()');
    PERFORM pg_temp.want('P1 site staff (empty state)', jsonb_array_length(v_r)::text, '0');
    PERFORM pg_temp.want('P1 create refused', pg_temp.try_as('chooer@evoltrya.test', 'SELECT create_overtime_batch(''2026-09-01'')'),
                         'OVERTIME_NO_SITE_STAFF|2026-09');

    -- 1 · 临时把 EMP-2026-0005 标为现场员工(以 postgres;整笔事务最后回滚)
    UPDATE employees SET is_site_staff = true WHERE id = e_phua;
    v_r := pg_temp.rows_as('chooer@evoltrya.test', 'SELECT employee_code FROM overtime_site_staff()');
    PERFORM pg_temp.want('1 site staff', v_r->0->>'employee_code', 'EMP-2026-0005');

    -- 2 · chooer@ 建批、录四行、交去批
    PERFORM pg_temp.want('2 fusheng cannot create', pg_temp.try_as('fusheng@evoltrya.test', 'SELECT create_overtime_batch(''2026-09-01'')'),
                         'PERMISSION_DENIED|action.overtime_enter');
    PERFORM pg_temp.want('2 create', pg_temp.try_as('chooer@evoltrya.test', 'SELECT create_overtime_batch(''2026-09-01'')'), 'OK');
    SELECT id INTO v_b FROM overtime_batches WHERE label = 'OT 2026-09 #1';
    IF v_b IS NULL THEN RAISE EXCEPTION 'OT1_LIVE|batch OT 2026-09 #1 not created'; END IF;
    PERFORM pg_temp.want('2 line 09-06', pg_temp.try_as('chooer@evoltrya.test', format('SELECT add_overtime_line(%L, %L, %L, 3, %L)', v_b, e_phua, '2026-09-06', 'Sunday loading')), 'OK');
    PERFORM pg_temp.want('2 line 09-07', pg_temp.try_as('chooer@evoltrya.test', format('SELECT add_overtime_line(%L, %L, %L, 2.5)', v_b, e_phua, '2026-09-07')), 'OK');
    PERFORM pg_temp.want('2 line 09-08', pg_temp.try_as('chooer@evoltrya.test', format('SELECT add_overtime_line(%L, %L, %L, 1.75)', v_b, e_phua, '2026-09-08')), 'OK');
    PERFORM pg_temp.want('2 line 09-13', pg_temp.try_as('chooer@evoltrya.test', format('SELECT add_overtime_line(%L, %L, %L, 4)', v_b, e_phua, '2026-09-13')), 'OK');
    PERFORM pg_temp.want('2 duplicate refused', pg_temp.try_as('chooer@evoltrya.test', format('SELECT add_overtime_line(%L, %L, %L, 1)', v_b, e_phua, '2026-09-08')),
                         'OVERTIME_DUPLICATE_DAY|EMP-2026-0005|2026-09-08|OT 2026-09 #1');
    PERFORM pg_temp.want('2 non-site refused', pg_temp.try_as('chooer@evoltrya.test', format('SELECT add_overtime_line(%L, %L, %L, 1)', v_b,
                         (SELECT id FROM employees WHERE code = 'EMP-2026-0006'), '2026-09-08')), 'OVERTIME_NOT_SITE_STAFF|EMP-2026-0006');
    PERFORM pg_temp.want('2 future date refused', pg_temp.try_as('chooer@evoltrya.test', format('SELECT add_overtime_line(%L, %L, %L, 1)', v_b, e_phua, '2026-09-30')),
                         'OVERTIME_DATE_FUTURE|2026-09-30');
    SELECT string_agg(to_char(work_date, 'MM-DD') || '=' || day_kind, ' ' ORDER BY work_date) INTO v_msg FROM overtime_lines WHERE batch_id = v_b;
    PERFORM pg_temp.want('2 day kinds', v_msg, '09-06=rest_day 09-07=weekday 09-08=weekday 09-13=rest_day');
    PERFORM pg_temp.want('2 submit', pg_temp.try_as('chooer@evoltrya.test', format('SELECT submit_overtime_batch(%L)', v_b)), 'OK');
    SELECT subject_type || ':' || code || ':' || blocks_disable::text INTO v_msg
      FROM approval_pending_documents() WHERE subject_type = 'overtime_batch';
    PERFORM pg_temp.want('2 pending registry', v_msg, 'overtime_batch:OT 2026-09 #1:false');
    v_r := pg_temp.rows_as('fusheng@evoltrya.test', format('SELECT employee_code, hours FROM overtime_batch_lines(%L)', v_b));
    PERFORM pg_temp.want('2 fusheng reads the lines', jsonb_array_length(v_r)::text, '4');

    -- 3 · fusheng@ 批准(chooer@ 批不了;tim@ 没有批准码,也没有越级)
    PERFORM pg_temp.want('3 chooer cannot approve', pg_temp.try_as('chooer@evoltrya.test', format('SELECT decide_overtime_batch(%L, %L)', v_b, 'approved')),
                         'PERMISSION_DENIED|action.overtime_approve');
    PERFORM pg_temp.want('3 tim@ cannot approve', pg_temp.try_as('tim@evoltrya.test', format('SELECT decide_overtime_batch(%L, %L)', v_b, 'approved')),
                         'PERMISSION_DENIED|action.overtime_approve');
    PERFORM pg_temp.want('3 approve', pg_temp.try_as('fusheng@evoltrya.test', format('SELECT decide_overtime_batch(%L, %L)', v_b, 'approved')), 'OK');
    SELECT string_agg(decision || '/' || COALESCE(level::text, '-') || '/' || self_decided::text, ' ' ORDER BY seq) INTO v_msg
      FROM approval_log WHERE subject_type = 'overtime_batch' AND subject_id = v_b;
    PERFORM pg_temp.want('3 approval_log', v_msg, 'submitted/-/false approved/-/false');

    -- 4 · 完成 2026-09 的考勤:小时冻进底稿,正好一次
    PERFORM pg_temp.want('4 open attendance', pg_temp.try_as('chooer@evoltrya.test', 'SELECT open_attendance_period(''2026-09-01'')'), 'OK');
    SELECT id INTO v_att FROM attendance_periods WHERE period_month = DATE '2026-09-01';
    SELECT id INTO v_line FROM attendance_lines WHERE period_id = v_att AND employee_id = e_phua;
    PERFORM pg_temp.want('4 sheet refuses typed hours', pg_temp.try_as('chooer@evoltrya.test', format('SELECT record_attendance(%L, 1, 0, 0, NULL)', v_line)),
                         'ATTENDANCE_OT_THROUGH_OVERTIME|EMP-2026-0005');
    FOR v_line IN SELECT id FROM attendance_lines WHERE period_id = v_att LOOP
        v_msg := pg_temp.try_as('chooer@evoltrya.test', format('SELECT record_attendance(%L, 0, 0, 0, %L)', v_line, 'seen'));
        IF v_msg <> 'OK' THEN RAISE EXCEPTION 'OT1_LIVE|record_attendance: %', v_msg; END IF;
    END LOOP;
    v_r := pg_temp.rows_as('chooer@evoltrya.test', format('SELECT * FROM overtime_month_hours(%L) WHERE employee_id = %L', '2026-09-01', e_phua));
    PERFORM pg_temp.want('4 before completion (live)', (v_r->0->>'fixed') || ' ' || (v_r->0->>'total_hours'), 'false 11.25');
    PERFORM pg_temp.want('4 complete', pg_temp.try_as('chooer@evoltrya.test', format('SELECT complete_attendance_period(%L)', v_att)), 'OK');
    SELECT ot_normal_hours || '/' || ot_rest_day_hours || '/' || ot_public_holiday_hours INTO v_msg
      FROM attendance_lines WHERE period_id = v_att AND employee_id = e_phua;
    PERFORM pg_temp.want('4 fixed into the sheet (weekday/rest/PH)', v_msg, '4.25/7.00/0');
    SELECT sum(ot_normal_hours + ot_rest_day_hours + ot_public_holiday_hours) INTO v_frozen FROM attendance_lines WHERE period_id = v_att;
    SELECT sum(l.hours) INTO v_approved FROM overtime_lines l JOIN overtime_batches b ON b.id = l.batch_id
     WHERE b.period_month = DATE '2026-09-01' AND b.status = 'approved' AND l.voided_at IS NULL;
    PERFORM pg_temp.want('4 exactly once (sheet total = approved lines total)', v_frozen::text || ' = ' || v_approved::text, '11.25 = 11.25');
    v_r := pg_temp.rows_as('chooer@evoltrya.test', format('SELECT * FROM overtime_month_hours(%L) WHERE employee_id = %L', '2026-09-01', e_phua));
    PERFORM pg_temp.want('4 after completion (fixed)', (v_r->0->>'fixed') || ' ' || (v_r->0->>'total_hours'), 'true 11.25');
    PERFORM pg_temp.want('4 month now refuses a new batch', pg_temp.try_as('chooer@evoltrya.test', 'SELECT create_overtime_batch(''2026-09-01'')'),
                         'OVERTIME_MONTH_COMPLETE|ATT-2026-09|2026-09');
    PERFORM pg_temp.want('4 month now refuses reversal', pg_temp.try_as('chooer@evoltrya.test', format('SELECT reverse_overtime_batch(%L, %L)', v_b, 'x')),
                         'OVERTIME_MONTH_COMPLETE|ATT-2026-09|2026-09');
    -- 员工本人在 /me 上读到自己批过的四行,批的人是 Fu Sheng
    v_r := pg_temp.rows_as('phua@evolytra.test', 'SELECT approver FROM my_overtime_lines()');
    PERFORM pg_temp.want('4 phua reads own approved overtime', jsonb_array_length(v_r)::text || ' by ' || (v_r->0->>'approver'), '4 by Fu Sheng');

    -- 5 · Q20:tim@ 决定自己的报销单 —— 驳回(驳回不过账),标记两处都要是 t
    PERFORM pg_temp.want('5 tim@ submits own claim', pg_temp.try_as('tim@evoltrya.test',
        format('SELECT submit_expense_claim(%L, %L, 12.34, %L, %L, %L)', e_tim, '2026-09-25', v_base, 'OT1 live proof taxi', 'none')), 'OK');
    SELECT id INTO v_clm FROM expense_claims WHERE description = 'OT1 live proof taxi' AND employee_id = e_tim;
    PERFORM pg_temp.want('5 tim@ decides own claim', pg_temp.try_as('tim@evoltrya.test',
        format('SELECT decide_expense_claim(%L, false, NULL, NULL, NULL, %L)', v_clm, 'own claim, declined')), 'OK');
    PERFORM pg_temp.want('5 approval_log self_decided', (SELECT self_decided::text FROM approval_log
        WHERE subject_type = 'expense_claim' AND subject_id = v_clm AND decision = 'rejected'), 'true');
    v_r := pg_temp.rows_as('tim@evoltrya.test', format('SELECT decider, self_decided FROM my_document_decisions() WHERE doc_id = %L', v_clm));
    PERFORM pg_temp.want('5 my_document_decisions self_decided', (v_r->0->>'self_decided') || ' by ' || (v_r->0->>'decider'), 'true by Tim');

    -- 收尾读数(仍在事务里):分录一张没多(驳回与加班都不过账)
    PERFORM pg_temp.want('K journal entries unchanged', (SELECT count(*) FROM journal_entries)::text, v_je_before::text);
    RAISE NOTICE 'OT1_LIVE approval_log inside the transaction: % → % (all rolled back)', v_log_before, (SELECT count(*) FROM approval_log);
    RAISE NOTICE 'OT1_LIVE all cells passed';
END;
$$;

ROLLBACK;
SELECT 'rolled back' AS outcome, now() AS at;

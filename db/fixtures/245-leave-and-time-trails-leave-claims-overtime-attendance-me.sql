-- 245 AUDIT-TRAIL-1d-2:请假与考勤的审计记录 —— 请假 · 假期发放 · 假别 · 公共假期 · 医疗报销 · 加班 · 考勤 · /me(2026-10-04)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1d Step 0 的 Q1–Q38,Tim 2026-10-04 全部照建议;这是 1d-2 那一刀)
--   L   请假:提交(本人)· 决定(另一个人)—— 请假那一行的状态改动与审批留痕都在;一次字段编辑(证明编号)在;
--       不持 hr.view、又不是本人的人 → TRAIL_NOT_PERMITTED
--   P   请假,记录开始之前(Q12):决定那一对戳、审批留痕、扣减【同一刻】—— 三行同一个 op_key(界面并成一句),
--       与提交那一刻是两个 op_key
--   X   本人取消,记录开始之前(Q12):只剩决定那一对戳(取消改写它)—— 拼出来是一次 UPDATE,新状态 cancelled,
--       人是本人;HR 读者读得出名字
--   M   /me(M8 · Q14 · Q15):本人读自己的请假与医疗报销 —— 请假那一行看得见,审批留痕与扣减是 Restricted(row_hidden);
--       决定人照 ActorName 的规矩是 restricted(本人不持 hr.view),本人自己做的事是 person;别人读 → 被拒;
--       本人读带页面码的 leave_request → 被拒(不持 hr.view)
--   G   假期发放:一笔字段编辑与一次删除(deleted_at)在;记录开始之前同一刻发的两笔 → 同一个 op_key(一次结转是一条)
--   T   假别(M11 集合):改标准天数、停用一个假别 —— 两次改动都在;不持 hr.view → 被拒
--   H   公共假期(M11 集合):加一个、改日期、【硬删】—— 删掉之后三行都还在(从变更记录里那一份影像找回来)
--   C   医疗报销:提交 · 驳回(审批留痕在)· 字段编辑;Q37:付款那张费用单挂上之后,费用页的审计记录读得到报销单那一行,
--       报销单页读得到那张费用单(往上一跳);记录开始之前的撤回(Q12)—— 没有记人,actor 是 unknown("Not recorded")
--   O   加班(M1):开批 · 加行 · 送审(送审重盖 day_kind,同一笔)· 仓库退回(审批关着:留痕的说明带系统追加的中文 ——
--       数据层照原样,界面剥掉,见 check-trail-wording ⑫)· 删一行(硬删,从 DELETE 影像里找回来);
--       只持 overtime_approve 的人读得到这一批(M1),行里的员工对他是 restricted(Q20);一个码都没有的人被拒
--   D   加班,记录开始之前(Q12):丢弃那一戳与每一行的作废戳同一刻 → 同一个 op_key;冲销那一戳带着理由
--   A   考勤:开月(期间那一行与每人一行)· 记录一行;记录开始之前只剩【最近】那一次重开(一行,不是两行)、
--       完成那一戳与每一行的冻结戳同一刻 → 同一个 op_key
--   R   登记:Q12 的每一个戳在 trail_prelog_sources 里;document_types 的 medical_claim / attendance_period 是 detail(Q36);
--       加班批不进 document_types(没有 code 列),它的行的 Record 一栏仍落在 /hr/overtime(trail_row_record)
--
-- 自带数据(README 第 2 条):账号、角色、员工、请假、发放、假期、报销、费用、加班、考勤全部本支自建;假别是稳定的引导数据(第 4 条)。
-- 以 postgres 跑(绕过 RLS)—— 每一次读都切成 authenticated + 那个人的 JWT(fixture 26 的教训)。
-- 【一笔事务】本支的每一次写都在同一笔里(同一个 txid),所以记录开始【之后】的"同一次操作"在这里证不出来 —— 那一半由
--   check-trail-wording ⑫ 的金句证(造句器把一次操作里的几行并成一句);这里证的是【之前】那一段按时刻并,那是数据决定的。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f245_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f245_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f245_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, p_n) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

-- 以某人的身份跑一句;失败就把那一句的拒绝原样抛出(本支的写都必须成)
CREATE FUNCTION pg_temp.f245_run(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f245_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RAISE EXCEPTION 'FIXTURE 245 setup: % failed: %', p_sql, SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f245_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 245 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

CREATE FUNCTION pg_temp.f245_refused(p_arm text, p_trail jsonb) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF COALESCE(p_trail ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 245 %: expected TRAIL_NOT_PERMITTED, got %', p_arm, left(p_trail::text, 400); END IF;
END;
$f$;

-- 那一行(表 · 操作 · 可选:改了哪一列 · 新值包含 · 是否 prelog);返回第一行,找不到就 RAISE
CREATE FUNCTION pg_temp.f245_find(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL,
                                  p_prelog boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT e FROM jsonb_array_elements(p_trail) e
     WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
       AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
       AND (p_new IS NULL OR e -> 'new' @> p_new)
       AND (p_prelog IS NULL OR (e ->> 'prelog')::boolean = p_prelog)
     LIMIT 1
$f$;

CREATE FUNCTION pg_temp.f245_need(p_arm text, p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL,
                                  p_prelog boolean DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb := pg_temp.f245_find(p_trail, p_table, p_op, p_col, p_new, p_prelog);
BEGIN
    IF v IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 245 %: expected a % % row% in the trail, got %', p_arm, p_table, p_op,
            COALESCE(' changing ' || p_col, '') || COALESCE(' with ' || p_new::text, '') || COALESCE(' prelog=' || p_prelog::text, ''),
            left(p_trail::text, 1500);
    END IF;
    RETURN v;
END;
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 全部码(决定请假 / 报销的人;财务读者)
    u_hr   uuid := gen_random_uuid();   -- 人事:module.hr.view + module.hr.edit
    u_ent  uuid := gen_random_uuid();   -- 只持 action.overtime_enter(开批、加行、送审)
    u_wh   uuid := gen_random_uuid();   -- 只持 action.overtime_approve(仓库:退回 / 批准)—— 不持 hr.view(Q20)
    u_emp  uuid := gen_random_uuid();   -- 员工本人(一个码都没有 —— /me 的主角)
    u_oth  uuid := gen_random_uuid();   -- 另一个员工(一个码都没有)
    u_none uuid := gen_random_uuid();   -- 一个码都没有、也没有员工档案
    r_all uuid; r_hr uuid; r_ent uuid; r_wh uuid;
    e_emp uuid := gen_random_uuid(); e_oth uuid := gen_random_uuid();
    t0 timestamptz := TIMESTAMPTZ '2026-09-01 10:00:00+08';    -- 都早于 change_log_began_at()(2026-09-28 23:58)
    t1 timestamptz := TIMESTAMPTZ '2026-09-02 11:00:00+08';
    t2 timestamptz := TIMESTAMPTZ '2026-09-03 12:00:00+08';
    t3 timestamptz := TIMESTAMPTZ '2026-09-04 13:00:00+08';
    t4 timestamptz := TIMESTAMPTZ '2026-09-05 14:00:00+08';
    t5 timestamptz := TIMESTAMPTZ '2026-09-06 15:00:00+08';
    v_month date := date_trunc('month', CURRENT_DATE - 31)::date;   -- 上一个月:两行加班落在 1 号与 2 号,永远不在未来
    lv uuid; lv_pre uuid := gen_random_uuid(); lv_can uuid := gen_random_uuid(); al_pre uuid := gen_random_uuid();
    g1 uuid := gen_random_uuid(); g2 uuid := gen_random_uuid(); hol uuid;
    mc uuid; mc_w uuid := gen_random_uuid(); ex uuid;
    ob uuid; ol uuid; ol2 uuid; ob_d uuid := gen_random_uuid(); ob_r uuid := gen_random_uuid(); ol_d uuid := gen_random_uuid();
    ap uuid; ap_r uuid := gen_random_uuid(); ap_c uuid := gen_random_uuid(); al1 uuid := gen_random_uuid(); al2 uuid := gen_random_uuid();
    v_j jsonb; v_r jsonb; v_r2 jsonb; v_r3 jsonb; v_n int; v_txt text;
BEGIN
    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES
        (u_all, 'fx245-all@test.local', now(), now()), (u_hr, 'fx245-hr@test.local', now(), now()),
        (u_ent, 'fx245-ent@test.local', now(), now()), (u_wh, 'fx245-wh@test.local', now(), now()),
        (u_emp, 'fx245-emp@test.local', now(), now()), (u_oth, 'fx245-oth@test.local', now(), now()),
        (u_none, 'fx245-none@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx245-all', 'FX245 All', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx245-hr', 'FX245 HR', 'f', true) RETURNING id INTO r_hr;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx245-ent', 'FX245 OT entry', 'f', true) RETURNING id INTO r_ent;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx245-wh', 'FX245 OT approval', 'f', true) RETURNING id INTO r_wh;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_hr, 'module.hr.view'), (r_hr, 'module.hr.edit'),
        (r_ent, 'action.overtime_enter'), (r_wh, 'action.overtime_approve');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_hr, r_hr), (u_ent, r_ent), (u_wh, r_wh);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, employment_status, user_id, is_site_staff) VALUES
        (e_emp, 'FX245-EMP', 'FX245 Employee', 'Emp', 'full_time', 'shopfloor', DATE '2020-01-01', 'active', u_emp, true),
        (e_oth, 'FX245-OTH', 'FX245 Other', 'Oth', 'full_time', 'office', DATE '2020-01-01', 'active', u_oth, false);
    -- 审批开着关着,加班都要人按;关着时那一格多一截系统写的中文 —— 本支要那一截(R 臂与界面剥它的那一半对得上)
    UPDATE finance_settings SET approvals_enabled = false;

    -- ══════════════ L · 请假:提交(本人)· 决定(另一个人)· 字段编辑 ══════════════
    v_r := pg_temp.f245_run(u_emp, format($q$SELECT submit_leave_request(%L::uuid, 'unpaid', %L::date, %L::date, false, false, 'fixture 245 trip')$q$,
                                          e_emp, CURRENT_DATE + 30, CURRENT_DATE + 30));
    lv := (v_r ->> 'request_id')::uuid;
    IF lv IS NULL THEN RAISE EXCEPTION 'FIXTURE 245 L: submit_leave_request returned no id: %', v_r; END IF;
    PERFORM pg_temp.f245_run(u_all, format($q$SELECT decide_leave_request(%L::uuid, true, 'Enjoy')$q$, lv));
    UPDATE leave_requests SET certificate_ref = 'FX245-CERT' WHERE id = lv;
    v_j := pg_temp.f245_ok('L', pg_temp.f245_trail(u_hr, 'leave_request', lv::text));
    PERFORM pg_temp.f245_need('L (requested)', v_j, 'leave_requests', 'INSERT');
    PERFORM pg_temp.f245_need('L (approved — key event)', v_j, 'leave_requests', 'UPDATE', 'status', '{"status": "approved"}');
    PERFORM pg_temp.f245_need('L (the approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "leave_request", "decision": "approved"}');
    PERFORM pg_temp.f245_need('L (field edit)', v_j, 'leave_requests', 'UPDATE', 'certificate_ref');
    PERFORM pg_temp.f245_refused('L (no hr.view, not the employee)', pg_temp.f245_trail(u_none, 'leave_request', lv::text));

    -- ══════════════ P · 请假,记录开始之前:决定的戳 · 审批留痕 · 扣减同一刻 ══════════════
    -- 绕开变更记录造出来(与线上那几张同形:那时还没有变更记录)
    SET LOCAL session_replication_role = replica;
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, decided_at, decided_by, decision_notes,
                                created_at, created_by, updated_at)
        VALUES (lv_pre, 'FX245-LV-PRE', e_emp, 'annual', DATE '2026-09-10', DATE '2026-09-11', 2, 'approved', t1, u_all, 'Pre-log approval', t0, u_emp, t1);
    INSERT INTO approval_log (id, subject_type, subject_id, subject_code, decision, actor_user_id, decided_at, note)
        VALUES (al_pre, 'leave_request', lv_pre, 'FX245-LV-PRE', 'approved', u_all, t1, 'Pre-log approval');
    INSERT INTO leave_consumption (leave_request_id, entry_type, days, accrual_year, created_at, created_by)
        VALUES (lv_pre, 'draw', 2, 2026, t1, u_all);
    -- X · 本人取消:只剩决定那一对戳(取消改写它),没有审批留痕
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, decided_at, decided_by,
                                created_at, created_by, updated_at)
        VALUES (lv_can, 'FX245-LV-CAN', e_emp, 'unpaid', DATE '2026-09-15', DATE '2026-09-15', 1, 'cancelled', t3, u_emp, t2, u_emp, t3);
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f245_ok('P', pg_temp.f245_trail(u_hr, 'leave_request', lv_pre::text));
    v_r := pg_temp.f245_need('P (the decision stamp, before the log)', v_j, 'leave_requests', 'UPDATE', 'decided_at', '{"status": "approved"}', true);
    v_r2 := pg_temp.f245_need('P (the approval row, before the log)', v_j, 'approval_log', 'INSERT', NULL, '{"decision": "approved"}', true);
    v_r3 := pg_temp.f245_need('P (the draw, before the log)', v_j, 'leave_consumption', 'INSERT', NULL, '{"entry_type": "draw"}', true);
    IF NOT (v_r ->> 'op_key' = v_r2 ->> 'op_key' AND v_r ->> 'op_key' = v_r3 ->> 'op_key') THEN
        RAISE EXCEPTION 'FIXTURE 245 P (Q12): the stamp, the approval row and the draw must be one operation (one op_key): %, %, %',
            v_r ->> 'op_key', v_r2 ->> 'op_key', v_r3 ->> 'op_key'; END IF;
    IF (pg_temp.f245_need('P (requested, before the log)', v_j, 'leave_requests', 'INSERT', NULL, NULL, true)) ->> 'op_key' = v_r ->> 'op_key' THEN
        RAISE EXCEPTION 'FIXTURE 245 P: the request and its decision must be two operations'; END IF;
    v_j := pg_temp.f245_ok('X', pg_temp.f245_trail(u_hr, 'leave_request', lv_can::text));
    v_r := pg_temp.f245_need('X (Q12: the self-cancellation, read from the decision stamp)', v_j, 'leave_requests', 'UPDATE', 'decided_at',
                             '{"status": "cancelled"}', true);
    IF v_r -> 'actor' ->> 'state' <> 'person' OR v_r -> 'actor' ->> 'name' <> 'Emp' THEN
        RAISE EXCEPTION 'FIXTURE 245 X: the cancellation should read as the employee (Emp), got %', v_r -> 'actor'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'approval_log') THEN
        RAISE EXCEPTION 'FIXTURE 245 X: a self-cancellation has no approval row'; END IF;

    -- ══════════════ M · /me(M8 · Q14 · Q15)══════════════
    v_j := pg_temp.f245_ok('M', pg_temp.f245_trail(u_emp, 'my_leave_request', lv::text));
    v_r := pg_temp.f245_need('M (own request visible)', v_j, 'leave_requests', 'INSERT');
    IF v_r -> 'actor' ->> 'state' <> 'person' THEN RAISE EXCEPTION 'FIXTURE 245 M (Q15): what I did myself should name me, got %', v_r -> 'actor'; END IF;
    v_r := pg_temp.f245_need('M (own decision visible)', v_j, 'leave_requests', 'UPDATE', 'status', '{"status": "approved"}');
    IF v_r -> 'actor' ->> 'state' <> 'restricted' THEN
        RAISE EXCEPTION 'FIXTURE 245 M (Q15, the ActorName rule): the decider should be Restricted to an employee without hr.view, got %', v_r -> 'actor'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'approval_log') THEN
        RAISE EXCEPTION 'FIXTURE 245 M (Q14): the approval row must be Restricted on /me, not readable'; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 245 M (Q4): the approval row should keep its place as Restricted'; END IF;
    PERFORM pg_temp.f245_refused('M (another employee reads my leave)', pg_temp.f245_trail(u_oth, 'my_leave_request', lv::text));
    PERFORM pg_temp.f245_refused('M (the page subject needs hr.view)', pg_temp.f245_trail(u_emp, 'leave_request', lv::text));
    v_j := pg_temp.f245_ok('M (my self-cancellation)', pg_temp.f245_trail(u_emp, 'my_leave_request', lv_can::text));
    v_r := pg_temp.f245_need('M (the stamp on /me)', v_j, 'leave_requests', 'UPDATE', 'decided_at', '{"status": "cancelled"}', true);
    IF v_r -> 'actor' ->> 'state' <> 'person' THEN RAISE EXCEPTION 'FIXTURE 245 M: my own cancellation should name me, got %', v_r -> 'actor'; END IF;

    -- ══════════════ G · 假期发放 ══════════════
    SET LOCAL session_replication_role = replica;
    INSERT INTO leave_grants (id, employee_id, leave_type_code, leave_year, days, granted_on, expires_on, grant_type, created_at, created_by, updated_at) VALUES
        (g1, e_emp, 'annual', 2027, 4, DATE '2026-12-31', DATE '2027-12-31', 'carry_forward', t4, u_hr, t4),
        (g2, e_oth, 'annual', 2027, 1, DATE '2026-12-31', DATE '2027-12-31', 'carry_forward', t4, u_hr, t4);
    SET LOCAL session_replication_role = origin;
    UPDATE leave_grants SET notes = 'FX245 checked' WHERE id = g1;
    UPDATE leave_grants SET deleted_at = now() WHERE id = g2;
    v_j := pg_temp.f245_ok('G', pg_temp.f245_trail(u_hr, 'leave_grant', g1::text));
    v_r := pg_temp.f245_need('G (carried forward, before the log)', v_j, 'leave_grants', 'INSERT', NULL, NULL, true);
    PERFORM pg_temp.f245_need('G (field edit)', v_j, 'leave_grants', 'UPDATE', 'notes');
    v_j := pg_temp.f245_ok('G2', pg_temp.f245_trail(u_hr, 'leave_grant', g2::text));
    IF (pg_temp.f245_need('G2 (carried forward, before the log)', v_j, 'leave_grants', 'INSERT', NULL, NULL, true)) ->> 'op_key' <> v_r ->> 'op_key' THEN
        RAISE EXCEPTION 'FIXTURE 245 G (Q16): one carry-forward run must be one operation across the people it touched'; END IF;
    PERFORM pg_temp.f245_need('G2 (removed — key event)', v_j, 'leave_grants', 'UPDATE', 'deleted_at');

    -- ══════════════ T · 假别(M11)══════════════
    UPDATE leave_types SET default_days_per_year = 3 WHERE code = 'examination';
    UPDATE leave_types SET is_active = false WHERE code = 'marriage';
    v_j := pg_temp.f245_ok('T', pg_temp.f245_trail(u_hr, 'leave_types', 'all'));
    PERFORM pg_temp.f245_need('T (field edit)', v_j, 'leave_types', 'UPDATE', 'default_days_per_year', '{"default_days_per_year": 3}');
    PERFORM pg_temp.f245_need('T (deactivated — key event)', v_j, 'leave_types', 'UPDATE', 'is_active', '{"is_active": false}');
    PERFORM pg_temp.f245_refused('T (no hr.view)', pg_temp.f245_trail(u_none, 'leave_types', 'all'));

    -- ══════════════ H · 公共假期(M11 · 硬删)══════════════
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key) VALUES (DATE '2031-01-02', 'FX245 Day', '测试日', 'fx245-day')
        RETURNING id INTO hol;
    UPDATE public_holidays SET holiday_date = DATE '2031-01-03' WHERE id = hol;
    DELETE FROM public_holidays WHERE id = hol;
    v_j := pg_temp.f245_ok('H', pg_temp.f245_trail(u_hr, 'public_holidays', 'all'));
    PERFORM pg_temp.f245_need('H (added)', v_j, 'public_holidays', 'INSERT', NULL, '{"name_en": "FX245 Day"}');
    PERFORM pg_temp.f245_need('H (field edit)', v_j, 'public_holidays', 'UPDATE', 'holiday_date', '{"holiday_date": "2031-01-03"}');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'public_holidays' AND e ->> 'op' = 'DELETE'
                    AND e -> 'old' ->> 'name_en' = 'FX245 Day') THEN
        RAISE EXCEPTION 'FIXTURE 245 H: a hard-deleted holiday must stay on the trail with its last values'; END IF;
    IF EXISTS (SELECT 1 FROM public_holidays WHERE id = hol) THEN RAISE EXCEPTION 'FIXTURE 245 H: the holiday was not deleted'; END IF;

    -- ══════════════ C · 医疗报销 ══════════════
    v_r := pg_temp.f245_run(u_emp, format($q$SELECT submit_medical_claim(%L::uuid, CURRENT_DATE, 85, 'GP visit', 'RC-245')$q$, e_emp));
    mc := (v_r ->> 'claim_id')::uuid;
    IF mc IS NULL THEN RAISE EXCEPTION 'FIXTURE 245 C: submit_medical_claim returned no id: %', v_r; END IF;
    PERFORM pg_temp.f245_run(u_all, format($q$SELECT decide_medical_claim(%L::uuid, false, 'Dental is not covered')$q$, mc));
    UPDATE medical_claims SET description = 'GP visit — fever' WHERE id = mc;
    INSERT INTO expenses (code, expense_date, account_code, amount_ccy, currency, fx_rate, amount_base, payment_status, employee_id)
        VALUES ('FX245-EXP', CURRENT_DATE, '6100', 85, (SELECT code FROM currencies WHERE is_base), 1, 85, 'unpaid', e_emp) RETURNING id INTO ex;
    UPDATE medical_claims SET expense_id = ex WHERE id = mc;
    v_j := pg_temp.f245_ok('C', pg_temp.f245_trail(u_all, 'medical_claim', mc::text));
    PERFORM pg_temp.f245_need('C (submitted)', v_j, 'medical_claims', 'INSERT');
    PERFORM pg_temp.f245_need('C (rejected — key event)', v_j, 'medical_claims', 'UPDATE', 'status', '{"status": "rejected"}');
    PERFORM pg_temp.f245_need('C (the approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "medical_claim", "decision": "rejected"}');
    PERFORM pg_temp.f245_need('C (field edit)', v_j, 'medical_claims', 'UPDATE', 'description');
    PERFORM pg_temp.f245_need('C (the expense that pays it — one hop up)', v_j, 'expenses', 'INSERT', NULL, '{"code": "FX245-EXP"}');
    v_j := pg_temp.f245_ok('C · Q37', pg_temp.f245_trail(u_all, 'expense', ex::text));
    PERFORM pg_temp.f245_need('C · Q37 (the expense page reaches the claim)', v_j, 'medical_claims', 'UPDATE', 'expense_id');
    -- 撤回,记录开始之前:没有记人(withdraw_medical_claim 只写 updated_by)
    SET LOCAL session_replication_role = replica;
    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status, withdrawn_at, created_at, created_by, updated_at, updated_by)
        VALUES (mc_w, 'FX245-MC-W', e_emp, DATE '2026-09-01', 2026, 40, 'withdrawn', t5, t4, u_emp, t5, u_emp);
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f245_ok('C (withdrawn)', pg_temp.f245_trail(u_hr, 'medical_claim', mc_w::text));
    v_r := pg_temp.f245_need('C (Q12: withdrawn, before the log)', v_j, 'medical_claims', 'UPDATE', 'withdrawn_at', '{"status": "withdrawn"}', true);
    IF v_r -> 'actor' ->> 'state' <> 'unknown' THEN
        RAISE EXCEPTION 'FIXTURE 245 C (Q12): a withdrawal records no person — it must read "Not recorded" (unknown), never updated_by; got %', v_r -> 'actor'; END IF;
    v_j := pg_temp.f245_ok('C (my claim)', pg_temp.f245_trail(u_emp, 'my_medical_claim', mc::text));
    PERFORM pg_temp.f245_need('C (my claim on /me)', v_j, 'medical_claims', 'INSERT');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' IN ('approval_log', 'expenses')) THEN
        RAISE EXCEPTION 'FIXTURE 245 C (Q14): the approval and the expense must be Restricted to the claimant'; END IF;
    PERFORM pg_temp.f245_refused('C (another employee reads my claim)', pg_temp.f245_trail(u_oth, 'my_medical_claim', mc::text));

    -- ══════════════ O · 加班(M1 · Q35 · Q10 · Q20)══════════════
    v_r := pg_temp.f245_run(u_ent, format($q$SELECT create_overtime_batch(%L::date)$q$, v_month));
    ob := (v_r ->> 'batch_id')::uuid;
    IF ob IS NULL THEN RAISE EXCEPTION 'FIXTURE 245 O: create_overtime_batch returned no id: %', v_r; END IF;
    v_r := pg_temp.f245_run(u_ent, format($q$SELECT add_overtime_line(%L::uuid, %L::uuid, %L::date, 3.5, 'Container unloading')$q$, ob, e_emp, v_month));
    ol := (v_r ->> 'line_id')::uuid;
    v_r := pg_temp.f245_run(u_ent, format($q$SELECT add_overtime_line(%L::uuid, %L::uuid, %L::date, 2)$q$, ob, e_emp, v_month + 1));
    ol2 := (v_r ->> 'line_id')::uuid;
    PERFORM pg_temp.f245_run(u_ent, format($q$SELECT submit_overtime_batch(%L::uuid)$q$, ob));
    PERFORM pg_temp.f245_run(u_wh, format($q$SELECT decide_overtime_batch(%L::uuid, 'rejected', 'Fri hours look doubled')$q$, ob));
    PERFORM pg_temp.f245_run(u_ent, format($q$SELECT to_jsonb(delete_overtime_line(%L::uuid))$q$, ol2));
    v_j := pg_temp.f245_ok('O', pg_temp.f245_trail(u_hr, 'overtime_batch', ob::text));
    PERFORM pg_temp.f245_need('O (batch started)', v_j, 'overtime_batches', 'INSERT');
    PERFORM pg_temp.f245_need('O (line added)', v_j, 'overtime_lines', 'INSERT', NULL, '{"hours": 3.5}');
    PERFORM pg_temp.f245_need('O (sent for approval)', v_j, 'overtime_batches', 'UPDATE', 'status', '{"status": "submitted"}');
    PERFORM pg_temp.f245_need('O (sent back — Q35)', v_j, 'overtime_batches', 'UPDATE', 'status', '{"status": "rejected"}');
    v_r := pg_temp.f245_need('O (the send-back approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "overtime_batch", "decision": "rejected"}');
    v_txt := v_r -> 'new' ->> 'note';
    IF v_txt NOT LIKE 'Fri hours look doubled · %' OR v_txt NOT LIKE '%审批流未启用%' THEN
        RAISE EXCEPTION 'FIXTURE 245 O (Q10): with approvals off the approver note carries the machine suffix in the data (the renderer strips it), got %', v_txt; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'overtime_lines' AND e ->> 'op' = 'DELETE'
                    AND (e -> 'old' ->> 'hours')::numeric = 2) THEN
        RAISE EXCEPTION 'FIXTURE 245 O: a hard-deleted overtime line must stay on the trail with its last values'; END IF;
    -- M1:只持 overtime_approve 的仓库读得到这一批;行里的员工、做事的人对他是 restricted(ActorName,Q20)
    v_j := pg_temp.f245_ok('O (M1: the approver)', pg_temp.f245_trail(u_wh, 'overtime_batch', ob::text));
    v_r := pg_temp.f245_need('O (M1: the line, read by the approver)', v_j, 'overtime_lines', 'INSERT', NULL, '{"hours": 3.5}');
    IF v_r -> 'refs' -> 'employee_id' -> e_emp::text -> 'person' ->> 'state' IS DISTINCT FROM 'restricted' THEN
        RAISE EXCEPTION 'FIXTURE 245 O (Q20): the employee on a line must be Restricted to an approver without hr.view, got %', v_r -> 'refs'; END IF;
    v_r := pg_temp.f245_need('O (M1: started, read by the approver)', v_j, 'overtime_batches', 'INSERT');
    IF v_r -> 'actor' ->> 'state' <> 'restricted' THEN
        RAISE EXCEPTION 'FIXTURE 245 O (Q20): who started the batch must be Restricted to the approver, got %', v_r -> 'actor'; END IF;
    PERFORM pg_temp.f245_ok('O (M1: the entry clerk)', pg_temp.f245_trail(u_ent, 'overtime_batch', ob::text));
    PERFORM pg_temp.f245_refused('O (no overtime code, no hr.view)', pg_temp.f245_trail(u_none, 'overtime_batch', ob::text));

    -- ══════════════ D · 加班,记录开始之前:丢弃 · 冲销 ══════════════
    SET LOCAL session_replication_role = replica;
    INSERT INTO overtime_batches (id, label, period_month, seq, status, created_at, created_by, discarded_at, discarded_by)
        VALUES (ob_d, 'FX245 OT D', DATE '2026-08-01', 91, 'discarded', t1, u_ent, t2, u_ent);
    INSERT INTO overtime_lines (id, batch_id, employee_id, work_date, hours, day_kind, created_at, created_by, voided_at)
        VALUES (ol_d, ob_d, e_emp, DATE '2026-08-05', 2, 'weekday', t1, u_ent, t2);
    INSERT INTO overtime_batches (id, label, period_month, seq, status, created_at, created_by, submitted_at, submitted_by, decided_at, decided_by,
                                  reversed_at, reversed_by, reverse_reason)
        VALUES (ob_r, 'FX245 OT R', DATE '2026-08-01', 92, 'reversed', t1, u_ent, t2, u_ent, t3, u_wh, t4, u_ent, 'Entered against the wrong month');
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f245_ok('D', pg_temp.f245_trail(u_hr, 'overtime_batch', ob_d::text));
    v_r := pg_temp.f245_need('D (Q12: discarded, before the log)', v_j, 'overtime_batches', 'UPDATE', 'discarded_at', '{"status": "discarded"}', true);
    v_r2 := pg_temp.f245_need('D (the voided line, before the log)', v_j, 'overtime_lines', 'UPDATE', 'voided_at', NULL, true);
    IF v_r ->> 'op_key' <> v_r2 ->> 'op_key' THEN RAISE EXCEPTION 'FIXTURE 245 D: the discard and its voided lines must be one operation'; END IF;
    v_j := pg_temp.f245_ok('D (reversed)', pg_temp.f245_trail(u_hr, 'overtime_batch', ob_r::text));
    PERFORM pg_temp.f245_need('D (Q12: reversed, with its reason)', v_j, 'overtime_batches', 'UPDATE', 'reversed_at',
                              '{"reverse_reason": "Entered against the wrong month"}', true);

    -- ══════════════ A · 考勤 ══════════════
    v_r := pg_temp.f245_run(u_hr, format($q$SELECT to_jsonb(open_attendance_period(%L::date))$q$, v_month));
    SELECT id INTO ap FROM attendance_periods WHERE period_month = v_month;
    IF ap IS NULL THEN RAISE EXCEPTION 'FIXTURE 245 A: open_attendance_period made no period: %', v_r; END IF;
    UPDATE attendance_lines SET note = 'MC 2 days', recorded_at = now(), recorded_by = u_hr WHERE period_id = ap AND employee_id = e_emp;
    v_j := pg_temp.f245_ok('A', pg_temp.f245_trail(u_hr, 'attendance_period', ap::text));
    PERFORM pg_temp.f245_need('A (opened)', v_j, 'attendance_periods', 'INSERT');
    PERFORM pg_temp.f245_need('A (a line per staff member)', v_j, 'attendance_lines', 'INSERT', NULL, jsonb_build_object('employee_id', e_emp));
    PERFORM pg_temp.f245_need('A (a line recorded)', v_j, 'attendance_lines', 'UPDATE', 'recorded_at');
    -- 记录开始之前:重开过两次的一个月 —— 重开覆盖上一次,于是只剩最近那一次(一行)
    SET LOCAL session_replication_role = replica;
    INSERT INTO attendance_periods (id, code, period_month, status, opened_at, opened_by, reopened_at, reopened_by, reopen_reason)
        VALUES (ap_r, 'FX245-ATT-R', DATE '2026-06-01', 'open', t0, u_hr, t5, u_hr, 'Payroll query');
    INSERT INTO attendance_periods (id, code, period_month, status, opened_at, opened_by, completed_at, completed_by)
        VALUES (ap_c, 'FX245-ATT-C', DATE '2026-07-01', 'complete', t0, u_hr, t3, u_hr);
    INSERT INTO attendance_lines (id, period_id, employee_id, frozen_at, unpaid_days) VALUES (al1, ap_c, e_emp, t3, 0), (al2, ap_c, e_oth, t3, 1);
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f245_ok('A (reopened)', pg_temp.f245_trail(u_hr, 'attendance_period', ap_r::text));
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'attendance_periods' AND (e ->> 'prelog')::boolean AND e -> 'changed_columns' ? 'reopened_at';
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 245 A (Q12): before the log only the latest reopening survives — expected 1 row, got %', v_n; END IF;
    PERFORM pg_temp.f245_need('A (reopened, with its reason)', v_j, 'attendance_periods', 'UPDATE', 'reopened_at', '{"reopen_reason": "Payroll query"}', true);
    IF pg_temp.f245_find(v_j, 'attendance_periods', 'UPDATE', 'completed_at', NULL, true) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 245 A: a reopened month carries no completion stamp (reopen clears it)'; END IF;
    v_j := pg_temp.f245_ok('A (completed)', pg_temp.f245_trail(u_hr, 'attendance_period', ap_c::text));
    v_r := pg_temp.f245_need('A (completed, before the log)', v_j, 'attendance_periods', 'UPDATE', 'completed_at', '{"status": "complete"}', true);
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e
     WHERE e ->> 'table_name' = 'attendance_lines' AND e -> 'changed_columns' ? 'frozen_at' AND e ->> 'op_key' = v_r ->> 'op_key';
    IF v_n <> 2 THEN RAISE EXCEPTION 'FIXTURE 245 A: the completion and the two frozen lines must be one operation, got % lines', v_n; END IF;

    -- ══════════════ R · 登记 ══════════════
    SELECT count(*) INTO v_n FROM trail_prelog_sources() p
     WHERE (p.table_name, p.kind, p.at_column) IN (('leave_requests', 'stamp', 'decided_at'), ('overtime_batches', 'stamp', 'reversed_at'),
           ('overtime_batches', 'stamp', 'discarded_at'), ('attendance_periods', 'stamp', 'completed_at'), ('attendance_periods', 'stamp', 'reopened_at'),
           ('medical_claims', 'stamp', 'withdrawn_at'));
    IF v_n <> 6 THEN RAISE EXCEPTION 'FIXTURE 245 R (Q12): expected the six stamps registered, found %', v_n; END IF;
    IF EXISTS (SELECT 1 FROM trail_prelog_sources() p WHERE p.table_name = 'medical_claims' AND p.at_column = 'withdrawn_at' AND p.by_column IS NOT NULL) THEN
        RAISE EXCEPTION 'FIXTURE 245 R: the withdrawal stamp must not name a person column'; END IF;
    SELECT count(*) INTO v_n FROM document_types WHERE key IN ('medical_claim', 'attendance_period') AND link_mode = 'detail';
    IF v_n <> 2 THEN RAISE EXCEPTION 'FIXTURE 245 R (Q36): medical_claim and attendance_period must link to their detail pages'; END IF;
    IF EXISTS (SELECT 1 FROM document_types WHERE table_name = 'overtime_batches') THEN
        RAISE EXCEPTION 'FIXTURE 245 R: overtime_batches has no code column and must stay out of document_types (global search)'; END IF;
    v_r := trail_row_record('overtime_lines', jsonb_build_object('id', ol), NULL, NULL);
    IF v_r ->> 'route' IS DISTINCT FROM '/hr/overtime' OR v_r ->> 'table' <> 'overtime_batches' THEN
        RAISE EXCEPTION 'FIXTURE 245 R (Q36): an overtime line belongs to its batch, linked at /hr/overtime — got %', v_r; END IF;

    RAISE NOTICE 'FIXTURE 245 全部通过:L · P(Q12)· X(Q12)· M(M8 · Q14 · Q15)· G(Q16)· T(M11)· H(M11 · 硬删)· C(Q37 · Q12)· O(M1 · Q10 · Q20 · Q35)· D(Q12)· A(Q12)· R(Q12 · Q36)';
END;
$$;

ROLLBACK;

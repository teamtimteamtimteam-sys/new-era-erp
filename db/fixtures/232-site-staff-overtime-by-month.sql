-- 232 OVERTIME-1:现场员工的加班 —— 财务按月录,仓库整批批;批过的小时在那个月考勤完成时冻进底稿,只算一次(2026-09-28)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(OVERTIME-1 grilling Q1–Q23,Tim 2026-09-28 全部接受)
--   E  ★ 空态:一个现场员工都没标 → overtime_site_staff() 0 行,建批按名拒 OVERTIME_NO_SITE_STAFF|月
--   A  ★ 两个码:没有 action.overtime_enter 建不了批、加不了行、冲销不了;没有 action.overtime_approve 批不了
--   O  ★★ OVERTIME_NO_OTHER_APPROVER:除了提单人之外没有持批准码的真持有人 → 建批拒;
--        唯一的另一个持有人恰好是批里的员工(按人认)→ 提交拒
--   S  ★★ 只录得进现场员工;标记在【提交】与【批准】时各再判一次(OVERTIME_NOT_SITE_STAFF|编号)
--   K  ★ 日子分桶:公共假期 → public_holiday(先判)· 星期日 → rest_day · 其余 → weekday
--   V  ★ 行的校验:日期出了那个月 / 在未来 / 那天不在职,小时 0、超过 24、三位小数 → 各自按名拒
--   D  ★★ 同一个员工同一天只许一行活着的 —— 同一批里、跨到一张批过的批,都按名拒并点出那一批
--   M  ★ 一个月同一时刻只许一张开着的批;批过之后可以开补充批
--   F  ★★ 四眼:提交人批 → SELF_APPROVAL_FORBIDDEN|raiser;批里的员工批 → |subject(按人认)
--   R  ★ 整批驳回要备注;驳回之后可以改、再提;财务撤回 → draft;再撤 → OVERTIME_BATCH_NOT_SUBMITTED
--   X  ★ 冲销(要理由,行作废、日期腾出来)· 丢弃(draft / rejected → discarded)
--   L  ★ 留痕与在途:approval_log 记 submitted / rejected / approved;在途清单里 blocks_disable = false;
--        仓库读得到这一类留痕,普通员工读不到
--   C  ★★★ 考勤:开着的批挡住完成(OVERTIME_BATCH_OPEN_FOR_MONTH);record_attendance 拒非零小时;
--        完成时批过的小时冻进三个桶,【正好一次】—— 等于已批准、没作废的行之和,冲销与丢弃的不算,
--        重开再完成不翻倍;完成之后建、加行、提交、批、冲销一律 OVERTIME_MONTH_COMPLETE
--   Y  ★ /me:员工经 my_overtime_lines() 读到自己已批准的行与批的人;直读 overtime_lines 0 行;直连写被拒
--   Q  ★★ Q20 · R2:二级审批角色的持有人决定自己的报销单与医疗申报 → approval_log.self_decided = t,
--        而且 my_document_decisions() 读出来的也是 self_decided = t(/me 上那一句"由你自己决定(已标记)")
--
-- 故障注入不写在这份文件里:每一臂的注入由交回报告里那支脚本逐臂打进重建库,每一臂都必须把本 fixture 打红。
-- 自带数据(README 第 2 条);系统起始日、锁期、假期都自己设(README 第 4、5 条)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f232_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 以某人的身份跑一句,返回 'OK' 或那一句拒绝
CREATE FUNCTION pg_temp.f232_try(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f232_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

-- 以某人的身份数一句 SELECT 的行数(读的一侧;切了角色,RLS 真的生效)
CREATE FUNCTION pg_temp.f232_count(p_user uuid, p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.f232_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM p_user THEN
        RAISE EXCEPTION 'FIXTURE 232 布景失败:身份没有切过去(%, %)', current_user, auth.uid(); END IF;
    EXECUTE 'SELECT count(*) FROM (' || p_sql || ') q' INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END;
$f$;

-- 以某人的身份把一句 SELECT 的结果读成 jsonb 数组
CREATE FUNCTION pg_temp.f232_rows(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f232_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE 'SELECT COALESCE(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) FROM (' || p_sql || ') q' INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END;
$f$;

CREATE FUNCTION pg_temp.f232_expect(p_arm text, p_got text, p_want text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_got IS DISTINCT FROM p_want THEN
        RAISE EXCEPTION 'FIXTURE 232% 失败:期望 %,实得 %', p_arm, p_want, COALESCE(p_got, '(NULL)');
    END IF;
END;
$f$;

DO $$
DECLARE
    u_fin   uuid := gen_random_uuid();   -- 财务:action.overtime_enter + 考勤(module.hr.edit / view)
    u_wh    uuid := gen_random_uuid();   -- 仓库:action.overtime_approve(本人不是现场员工)
    u_wh2   uuid := gen_random_uuid();   -- 另一个持批准码的人 —— ★ 他【本人】是现场员工 SITE2
    u_both  uuid := gen_random_uuid();   -- 两个码都持:录的也是他、批的也想是他
    u_plain uuid := gen_random_uuid();   -- 没有任何码 —— ★ 他本人是现场员工 SITE1(/me 那一臂)
    u_cfo   uuid := gen_random_uuid();   -- 二级审批角色的持有人(Q20)
    r_fin uuid; r_wh uuid; r_wh2 uuid; r_both uuid; r_l2 uuid;
    e_fin uuid := gen_random_uuid(); e_wh uuid := gen_random_uuid(); e_both uuid := gen_random_uuid();
    e_site1 uuid := gen_random_uuid(); e_site2 uuid := gen_random_uuid(); e_office uuid := gen_random_uuid();
    e_late uuid := gen_random_uuid(); e_cfo uuid := gen_random_uuid();
    b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; b_forced uuid;
    x_cfo uuid := gen_random_uuid(); mc_cfo uuid := gen_random_uuid();
    v_base text; v_msg text; v_n bigint; v_r jsonb; v_row record; v_sum numeric; v_frozen numeric;
    v_att uuid; v_line uuid;
    M text := '2026-03-01';
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    IF v_base IS NULL THEN RAISE EXCEPTION 'FIXTURE 232 布景失败:currencies 里没有本位币'; END IF;

    -- ══════════════ 布景 ══════════════
    UPDATE finance_settings SET system_start_date = DATE '2026-01-01', locked_before = NULL;
    -- 这个月的假期自己设:先清掉窗口里的,再插一天星期二(README 第 4、5 条)
    DELETE FROM public_holidays WHERE holiday_date BETWEEN DATE '2026-03-01' AND DATE '2026-03-31';
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key, country, is_active)
    VALUES (DATE '2026-03-10', 'FX232 Holiday', '测试假日', 'fx232-holiday', 'SG', true);

    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_wh, now()), (u_wh2, now()), (u_both, now()), (u_plain, now()), (u_cfo, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx232-fin','f','f',true)  RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx232-wh','f','f',true)   RETURNING id INTO r_wh;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx232-wh2','f','f',true)  RETURNING id INTO r_wh2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx232-both','f','f',true) RETURNING id INTO r_both;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx232-l2','f','f',true)   RETURNING id INTO r_l2;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_fin, c FROM unnest(ARRAY['action.overtime_enter', 'module.hr.edit', 'module.hr.view']) c;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_wh, 'action.overtime_approve'), (r_wh2, 'action.overtime_approve'),
        (r_both, 'action.overtime_enter'), (r_both, 'action.overtime_approve');
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_l2, c FROM unnest(ARRAY['module.finance.view', 'data.view_prices', 'module.hr.view',
                                     'action.decide_hr_requests']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_wh, r_wh), (u_wh2, r_wh2), (u_both, r_both), (u_cfo, r_l2);

    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_fin,    'FX232-FIN',    'FX232 Finance',  NULL,      'full_time', 'office',    DATE '2020-01-01', u_fin),
        (e_wh,     'FX232-WH',     'FX232 Warehouse','Wally',   'full_time', 'shopfloor', DATE '2020-01-01', u_wh),
        (e_both,   'FX232-BOTH',   'FX232 Both',     NULL,      'full_time', 'office',    DATE '2020-01-01', u_both),
        (e_site1,  'FX232-SITE1',  'FX232 Site One', NULL,      'full_time', 'shopfloor', DATE '2020-01-01', u_plain),
        (e_site2,  'FX232-SITE2',  'FX232 Site Two', NULL,      'full_time', 'shopfloor', DATE '2020-01-01', u_wh2),
        (e_office, 'FX232-OFFICE', 'FX232 Office',   NULL,      'full_time', 'office',    DATE '2020-01-01', NULL),
        (e_late,   'FX232-LATE',   'FX232 Late',     NULL,      'full_time', 'shopfloor', DATE '2026-03-20', NULL),
        (e_cfo,    'FX232-CFO',    'FX232 CFO',      'Cee',     'full_time', 'office',    DATE '2020-01-01', u_cfo);
    -- ★ 标记的默认值是 false:没有一个人被标(Tim:迁移一个人都不标)
    IF EXISTS (SELECT 1 FROM employees WHERE code LIKE 'FX232-%' AND is_site_staff) THEN
        RAISE EXCEPTION 'FIXTURE 232 布景失败:is_site_staff 的默认值不是 false'; END IF;

    -- ══════════════ E · 空态:一个现场员工都没标 ══════════════
    v_n := pg_temp.f232_count(u_fin, 'SELECT * FROM overtime_site_staff() s WHERE s.employee_code LIKE ''FX232-%''');
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 232E1 失败:没有人被标时 overtime_site_staff() 应当是 0 行,实得 %', v_n; END IF;
    PERFORM pg_temp.f232_expect('E2', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', M)),
                                'OVERTIME_NO_SITE_STAFF|2026-03');

    -- ══════════════ A · 两个码 ══════════════
    PERFORM pg_temp.f232_expect('A1', pg_temp.f232_try(u_plain, format('SELECT create_overtime_batch(%L)', M)),
                                'PERMISSION_DENIED|action.overtime_enter');
    PERFORM pg_temp.f232_expect('A2', pg_temp.f232_try(u_wh, format('SELECT create_overtime_batch(%L)', M)),
                                'PERMISSION_DENIED|action.overtime_enter');

    -- 标三个人为现场员工(SITE1 · SITE2 · LATE);OFFICE 不标
    UPDATE employees SET is_site_staff = true WHERE id IN (e_site1, e_site2, e_late);
    v_n := pg_temp.f232_count(u_fin, 'SELECT * FROM overtime_site_staff() s WHERE s.employee_code LIKE ''FX232-%''');
    IF v_n <> 3 THEN RAISE EXCEPTION 'FIXTURE 232E3 失败:标了三个人,overtime_site_staff() 应当是 3 行,实得 %', v_n; END IF;
    v_msg := pg_temp.f232_try(u_plain, 'SELECT * FROM overtime_site_staff()');
    PERFORM pg_temp.f232_expect('E4', v_msg, 'PERMISSION_DENIED|action.overtime_enter');

    -- ══════════════ O · OVERTIME_NO_OTHER_APPROVER ══════════════
    -- O1 · 除了提单人(u_both)之外没有持批准码的真持有人 → 建批拒。在子块里删授权,子块回滚把它还回来。
    BEGIN
        DELETE FROM role_permissions WHERE permission_code = 'action.overtime_approve' AND role_id <> r_both;
        v_msg := pg_temp.f232_try(u_both, format('SELECT create_overtime_batch(%L)', M));
        RAISE EXCEPTION 'F232_UNDO';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'F232_UNDO' THEN RAISE; END IF;
    END;
    PERFORM pg_temp.f232_expect('O1', v_msg, 'OVERTIME_NO_OTHER_APPROVER|2026-03');
    -- O2 · 唯一的另一个持有人是 u_wh2 —— 而他本人是 SITE2。建批照走(那时批里还没有人),
    --      把 SITE2 放进批里之后提交 → 拒(按人认)。
    BEGIN
        DELETE FROM role_permissions WHERE permission_code = 'action.overtime_approve' AND role_id <> r_wh2;
        v_msg := pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', M));
        IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 232O2 失败:另一个持有人在时建批应当成功,实得 %', v_msg; END IF;
        SELECT id INTO b1 FROM overtime_batches WHERE label = 'OT 2026-03 #1';
        v_msg := pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 2)', b1, e_site2, '2026-03-03'));
        IF v_msg <> 'OK' THEN RAISE EXCEPTION 'FIXTURE 232O2 失败:加行应当成功,实得 %', v_msg; END IF;
        v_msg := pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b1));
        RAISE EXCEPTION 'F232_UNDO';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'F232_UNDO' THEN RAISE; END IF;
    END;
    PERFORM pg_temp.f232_expect('O2', v_msg, 'OVERTIME_NO_OTHER_APPROVER|OT 2026-03 #1');
    IF EXISTS (SELECT 1 FROM overtime_batches) THEN
        RAISE EXCEPTION 'FIXTURE 232O3 失败:子块回滚之后不该留下批次'; END IF;

    -- ══════════════ 第一批 B1(u_fin 录)══════════════
    PERFORM pg_temp.f232_expect('M1', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', M)), 'OK');
    SELECT id INTO b1 FROM overtime_batches WHERE label = 'OT 2026-03 #1';
    IF b1 IS NULL THEN RAISE EXCEPTION 'FIXTURE 232M1 失败:第一批的名字应当是 OT 2026-03 #1'; END IF;
    -- M2 · 同一个月再开一张 → 拒,点出开着的那一张
    PERFORM pg_temp.f232_expect('M2', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', '2026-03-17')),
                                'OVERTIME_BATCH_OPEN_EXISTS|OT 2026-03 #1');

    -- S1 · 不是现场员工录不进
    PERFORM pg_temp.f232_expect('S1', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 2)', b1, e_office, '2026-03-02')),
                                'OVERTIME_NOT_SITE_STAFF|FX232-OFFICE');
    -- A3 · 没有录入码加不了行
    PERFORM pg_temp.f232_expect('A3', pg_temp.f232_try(u_wh, format('SELECT add_overtime_line(%L, %L, %L, 2)', b1, e_site1, '2026-03-02')),
                                'PERMISSION_DENIED|action.overtime_enter');

    -- 四行:SITE1 星期一 2.5、星期日 3、公共假期(星期二)4;SITE2 星期二 1.25
    PERFORM pg_temp.f232_expect('K0', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 2.5, %L)', b1, e_site1, '2026-03-02', 'loading')), 'OK');
    PERFORM pg_temp.f232_expect('K0', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 3)', b1, e_site1, '2026-03-08')), 'OK');
    PERFORM pg_temp.f232_expect('K0', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 4)', b1, e_site1, '2026-03-10')), 'OK');
    PERFORM pg_temp.f232_expect('K0', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 1.25)', b1, e_site2, '2026-03-03')), 'OK');

    -- K · 分桶
    PERFORM pg_temp.f232_expect('K1', (SELECT day_kind FROM overtime_lines WHERE employee_id = e_site1 AND work_date = DATE '2026-03-02'), 'weekday');
    PERFORM pg_temp.f232_expect('K2', (SELECT day_kind FROM overtime_lines WHERE employee_id = e_site1 AND work_date = DATE '2026-03-08'), 'rest_day');
    PERFORM pg_temp.f232_expect('K3', (SELECT day_kind FROM overtime_lines WHERE employee_id = e_site1 AND work_date = DATE '2026-03-10'), 'public_holiday');
    PERFORM pg_temp.f232_expect('K4', overtime_day_kind(DATE '2026-03-10'), 'public_holiday');
    PERFORM pg_temp.f232_expect('K5', overtime_day_kind(DATE '2026-03-15'), 'rest_day');
    PERFORM pg_temp.f232_expect('K6', overtime_day_kind(DATE '2026-03-14'), 'weekday');   -- 星期六:不是休息日(Tim Q4)

    -- D1 · 同一个员工同一天,同一批里再来一行
    PERFORM pg_temp.f232_expect('D1', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 1)', b1, e_site1, '2026-03-02')),
                                'OVERTIME_DUPLICATE_DAY|FX232-SITE1|2026-03-02|OT 2026-03 #1');

    -- V · 行的校验
    PERFORM pg_temp.f232_expect('V1', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 1)', b1, e_site1, '2026-04-01')),
                                'OVERTIME_DATE_OUTSIDE_MONTH|2026-04-01|2026-03');
    PERFORM pg_temp.f232_expect('V2', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 1)', b1, e_late, '2026-03-05')),
                                'OVERTIME_EMPLOYEE_NOT_ACTIVE|FX232-LATE|2026-03-05');
    PERFORM pg_temp.f232_expect('V3', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 0)', b1, e_site1, '2026-03-11')),
                                'OVERTIME_HOURS_INVALID|0');
    PERFORM pg_temp.f232_expect('V4', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 24.5)', b1, e_site1, '2026-03-11')),
                                'OVERTIME_HOURS_INVALID|24.5');
    PERFORM pg_temp.f232_expect('V5', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 1.005)', b1, e_site1, '2026-03-11')),
                                'OVERTIME_HOURS_INVALID|1.005');
    PERFORM pg_temp.f232_expect('V6', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, NULL, 1)', b1, e_site1)),
                                'OVERTIME_DATE_REQUIRED');

    -- S2 · 标记在【提交】时再判一次
    UPDATE employees SET is_site_staff = false WHERE id = e_site2;
    PERFORM pg_temp.f232_expect('S2', pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b1)),
                                'OVERTIME_NOT_SITE_STAFF|FX232-SITE2');
    UPDATE employees SET is_site_staff = true WHERE id = e_site2;

    PERFORM pg_temp.f232_expect('R0', pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b1)), 'OK');

    -- L1 · 在途清单:一张加班批,blocks_disable = false,没有固定档位,提单人是交的人
    SELECT * INTO v_row FROM approval_pending_documents() d WHERE d.subject_type = 'overtime_batch' AND d.doc_id = b1;
    IF NOT FOUND OR v_row.blocks_disable OR v_row.fixed_level IS NOT NULL OR v_row.raiser_user_id <> u_fin THEN
        RAISE EXCEPTION 'FIXTURE 232L1 失败:在途清单里应当有 B1(blocks_disable=f、fixed_level NULL、raiser=u_fin),实得 %', to_jsonb(v_row); END IF;

    -- F1 · 批里的员工(u_wh2 本人是 SITE2)批 → |subject
    PERFORM pg_temp.f232_expect('F1', pg_temp.f232_try(u_wh2, format('SELECT decide_overtime_batch(%L, %L)', b1, 'approved')),
                                'SELF_APPROVAL_FORBIDDEN|subject');
    -- A4 · 没有批准码批不了
    PERFORM pg_temp.f232_expect('A4', pg_temp.f232_try(u_fin, format('SELECT decide_overtime_batch(%L, %L)', b1, 'approved')),
                                'PERMISSION_DENIED|action.overtime_approve');
    -- S3 · 标记在【批准】时再判一次
    UPDATE employees SET is_site_staff = false WHERE id = e_site1;
    PERFORM pg_temp.f232_expect('S3', pg_temp.f232_try(u_wh, format('SELECT decide_overtime_batch(%L, %L)', b1, 'approved')),
                                'OVERTIME_NOT_SITE_STAFF|FX232-SITE1');
    UPDATE employees SET is_site_staff = true WHERE id = e_site1;

    -- R · 驳回要备注;驳回之后可以改、再提;撤回
    PERFORM pg_temp.f232_expect('R1', pg_temp.f232_try(u_wh, format('SELECT decide_overtime_batch(%L, %L, %L)', b1, 'rejected', '  ')),
                                'OVERTIME_REJECT_NOTE_REQUIRED|OT 2026-03 #1');
    PERFORM pg_temp.f232_expect('R2', pg_temp.f232_try(u_wh, format('SELECT decide_overtime_batch(%L, %L, %L)', b1, 'rejected', 'the holiday hours look wrong')), 'OK');
    IF (SELECT status || '|' || decision_notes FROM overtime_batches WHERE id = b1) <> 'rejected|the holiday hours look wrong' THEN
        RAISE EXCEPTION 'FIXTURE 232R2 失败:驳回之后应当是 rejected 并带着备注'; END IF;
    SELECT id INTO v_line FROM overtime_lines WHERE employee_id = e_site1 AND work_date = DATE '2026-03-10';
    PERFORM pg_temp.f232_expect('R3', pg_temp.f232_try(u_fin, format('SELECT delete_overtime_line(%L)', v_line)), 'OK');
    PERFORM pg_temp.f232_expect('R3', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 3.5)', b1, e_site1, '2026-03-10')), 'OK');
    PERFORM pg_temp.f232_expect('R4', pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b1)), 'OK');
    IF (SELECT decided_at FROM overtime_batches WHERE id = b1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 232R4 失败:再提交之后这一轮还没有决定,decided_at 应当清空'; END IF;
    PERFORM pg_temp.f232_expect('R5', pg_temp.f232_try(u_fin, format('SELECT withdraw_overtime_batch(%L)', b1)), 'OK');
    PERFORM pg_temp.f232_expect('R5', (SELECT status FROM overtime_batches WHERE id = b1), 'draft');
    PERFORM pg_temp.f232_expect('R6', pg_temp.f232_try(u_fin, format('SELECT withdraw_overtime_batch(%L)', b1)),
                                'OVERTIME_BATCH_NOT_SUBMITTED|OT 2026-03 #1|draft');
    PERFORM pg_temp.f232_expect('R7', pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b1)), 'OK');
    PERFORM pg_temp.f232_expect('R8', pg_temp.f232_try(u_wh, format('SELECT decide_overtime_batch(%L, %L)', b1, 'approved')), 'OK');
    PERFORM pg_temp.f232_expect('R8', (SELECT status FROM overtime_batches WHERE id = b1), 'approved');

    -- L2 · 留痕:三次提交、一次驳回(带备注)、一次批准;仓库读得到,普通员工读不到
    -- (驳回那一行的备注以驳回理由开头;审批开关关着时后面多一句说明 —— 所以按前缀认)
    SELECT count(*) FILTER (WHERE decision = 'submitted') || '/'
           || count(*) FILTER (WHERE decision = 'rejected' AND note LIKE 'the holiday hours look wrong%') || '/'
           || count(*) FILTER (WHERE decision = 'approved' AND actor_user_id = u_wh AND level IS NULL AND NOT self_decided)
      INTO v_msg FROM approval_log WHERE subject_type = 'overtime_batch' AND subject_id = b1;
    PERFORM pg_temp.f232_expect('L2', v_msg, '3/1/1');
    v_n := pg_temp.f232_count(u_wh, format('SELECT 1 FROM approval_log WHERE subject_type = ''overtime_batch'' AND subject_id = %L', b1));
    IF v_n <> 5 THEN RAISE EXCEPTION 'FIXTURE 232L3 失败:仓库应当读得到 B1 的 5 行留痕,实得 %', v_n; END IF;
    v_n := pg_temp.f232_count(u_plain, format('SELECT 1 FROM approval_log WHERE subject_type = ''overtime_batch'' AND subject_id = %L', b1));
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 232L4 失败:没有码的员工不该读到加班批的留痕,实得 %', v_n; END IF;

    -- ══════════════ 补充批 B2(u_both 录、u_both 想批)══════════════
    PERFORM pg_temp.f232_expect('M3', pg_temp.f232_try(u_both, format('SELECT create_overtime_batch(%L)', M)), 'OK');
    SELECT id INTO b2 FROM overtime_batches WHERE label = 'OT 2026-03 #2';
    IF b2 IS NULL THEN RAISE EXCEPTION 'FIXTURE 232M3 失败:批过之后应当能开补充批 OT 2026-03 #2'; END IF;
    -- D2 · 跨到一张【批过的】批:同一个员工同一天照拒,点出那一批
    PERFORM pg_temp.f232_expect('D2', pg_temp.f232_try(u_both, format('SELECT add_overtime_line(%L, %L, %L, 1)', b2, e_site1, '2026-03-02')),
                                'OVERTIME_DUPLICATE_DAY|FX232-SITE1|2026-03-02|OT 2026-03 #1');
    PERFORM pg_temp.f232_expect('M4', pg_temp.f232_try(u_both, format('SELECT add_overtime_line(%L, %L, %L, 2)', b2, e_site1, '2026-03-04')), 'OK');
    PERFORM pg_temp.f232_expect('M4', pg_temp.f232_try(u_both, format('SELECT submit_overtime_batch(%L)', b2)), 'OK');
    -- F2 · 交的人自己批 → |raiser
    PERFORM pg_temp.f232_expect('F2', pg_temp.f232_try(u_both, format('SELECT decide_overtime_batch(%L, %L)', b2, 'approved')),
                                'SELF_APPROVAL_FORBIDDEN|raiser');
    PERFORM pg_temp.f232_expect('M5', pg_temp.f232_try(u_wh, format('SELECT decide_overtime_batch(%L, %L)', b2, 'approved')), 'OK');

    -- ══════════════ X · 冲销与丢弃 ══════════════
    PERFORM pg_temp.f232_expect('X0', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', M)), 'OK');
    SELECT id INTO b3 FROM overtime_batches WHERE label = 'OT 2026-03 #3';
    PERFORM pg_temp.f232_expect('X0', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 6)', b3, e_site2, '2026-03-05')), 'OK');
    PERFORM pg_temp.f232_expect('X0', pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b3)), 'OK');
    PERFORM pg_temp.f232_expect('X0', pg_temp.f232_try(u_wh, format('SELECT decide_overtime_batch(%L, %L)', b3, 'approved')), 'OK');
    PERFORM pg_temp.f232_expect('X1', pg_temp.f232_try(u_fin, format('SELECT reverse_overtime_batch(%L, %L)', b3, '')),
                                'OVERTIME_REVERSE_REASON_REQUIRED|OT 2026-03 #3');
    PERFORM pg_temp.f232_expect('X2', pg_temp.f232_try(u_wh, format('SELECT reverse_overtime_batch(%L, %L)', b3, 'x')),
                                'PERMISSION_DENIED|action.overtime_enter');
    PERFORM pg_temp.f232_expect('X3', pg_temp.f232_try(u_fin, format('SELECT reverse_overtime_batch(%L, %L)', b3, 'wrong day')), 'OK');
    IF (SELECT status FROM overtime_batches WHERE id = b3) <> 'reversed'
       OR EXISTS (SELECT 1 FROM overtime_lines WHERE batch_id = b3 AND voided_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 232X3 失败:冲销之后批应当是 reversed、行全部作废'; END IF;
    -- 日期腾出来了:同一个员工同一天可以进一张新批 —— 然后把那张丢掉
    PERFORM pg_temp.f232_expect('X4', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', M)), 'OK');
    SELECT id INTO b4 FROM overtime_batches WHERE label = 'OT 2026-03 #4';
    PERFORM pg_temp.f232_expect('X4', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 5)', b4, e_site2, '2026-03-05')), 'OK');
    PERFORM pg_temp.f232_expect('X5', pg_temp.f232_try(u_fin, format('SELECT discard_overtime_batch(%L)', b4)), 'OK');
    IF (SELECT status FROM overtime_batches WHERE id = b4) <> 'discarded'
       OR EXISTS (SELECT 1 FROM overtime_lines WHERE batch_id = b4 AND voided_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 232X5 失败:丢弃之后批应当是 discarded、行全部作废'; END IF;
    PERFORM pg_temp.f232_expect('X6', pg_temp.f232_try(u_fin, format('SELECT reverse_overtime_batch(%L, %L)', b4, 'x')),
                                'OVERTIME_BATCH_NOT_APPROVED|OT 2026-03 #4|discarded');

    -- ══════════════ C · 考勤:挡、拒、冻,正好一次 ══════════════
    PERFORM pg_temp.f232_expect('C0', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', M)), 'OK');
    SELECT id INTO b5 FROM overtime_batches WHERE label = 'OT 2026-03 #5';
    PERFORM pg_temp.f232_expect('C0', pg_temp.f232_try(u_fin, format('SELECT open_attendance_period(%L)', M)), 'OK');
    SELECT id INTO v_att FROM attendance_periods WHERE period_month = DATE '2026-03-01';
    -- C1 · record_attendance 不收小时
    SELECT id INTO v_line FROM attendance_lines WHERE period_id = v_att AND employee_id = e_site1;
    PERFORM pg_temp.f232_expect('C1', pg_temp.f232_try(u_fin, format('SELECT record_attendance(%L, 1, 0, 0, NULL)', v_line)),
                                'ATTENDANCE_OT_THROUGH_OVERTIME|FX232-SITE1');
    FOR v_line IN SELECT id FROM attendance_lines WHERE period_id = v_att LOOP
        PERFORM pg_temp.f232_expect('C1', pg_temp.f232_try(u_fin, format('SELECT record_attendance(%L, 0, 0, 0, %L)', v_line, 'seen')), 'OK');
    END LOOP;
    -- C2 · 开着的批挡住完成
    PERFORM pg_temp.f232_expect('C2', pg_temp.f232_try(u_fin, format('SELECT complete_attendance_period(%L)', v_att)),
                                'OVERTIME_BATCH_OPEN_FOR_MONTH|ATT-2026-03|OT 2026-03 #5|draft');
    PERFORM pg_temp.f232_expect('C2', pg_temp.f232_try(u_fin, format('SELECT discard_overtime_batch(%L)', b5)), 'OK');

    -- P · 完成之前屏幕读此刻批过的数(fixed = false)
    v_r := pg_temp.f232_rows(u_fin, format('SELECT * FROM overtime_month_hours(%L) WHERE employee_id = %L', M, e_site1));
    IF v_r->0->>'fixed' <> 'false' OR (v_r->0->>'weekday_hours')::numeric <> 4.5 OR (v_r->0->>'rest_day_hours')::numeric <> 3
       OR (v_r->0->>'public_holiday_hours')::numeric <> 3.5 THEN
        RAISE EXCEPTION 'FIXTURE 232P1 失败:SITE1 此刻批过的应当是 平日 4.5 · 休息日 3 · 公共假期 3.5(fixed=f),实得 %', v_r; END IF;

    PERFORM pg_temp.f232_expect('C3', pg_temp.f232_try(u_fin, format('SELECT complete_attendance_period(%L)', v_att)), 'OK');
    -- ★★ 正好一次:冻进来的 = 已批准、没作废的行之和(两份独立的数:底稿的三列 vs 加班行本身),逐人逐桶
    FOR v_row IN
        SELECT al.employee_id, al.ot_normal_hours, al.ot_rest_day_hours, al.ot_public_holiday_hours,
               COALESCE((SELECT sum(l.hours) FROM overtime_lines l JOIN overtime_batches b ON b.id = l.batch_id
                          WHERE l.employee_id = al.employee_id AND b.status = 'approved' AND l.voided_at IS NULL
                            AND l.day_kind = 'weekday'), 0) AS w,
               COALESCE((SELECT sum(l.hours) FROM overtime_lines l JOIN overtime_batches b ON b.id = l.batch_id
                          WHERE l.employee_id = al.employee_id AND b.status = 'approved' AND l.voided_at IS NULL
                            AND l.day_kind = 'rest_day'), 0) AS r,
               COALESCE((SELECT sum(l.hours) FROM overtime_lines l JOIN overtime_batches b ON b.id = l.batch_id
                          WHERE l.employee_id = al.employee_id AND b.status = 'approved' AND l.voided_at IS NULL
                            AND l.day_kind = 'public_holiday'), 0) AS p
          FROM attendance_lines al WHERE al.period_id = v_att
    LOOP
        IF v_row.ot_normal_hours <> v_row.w OR v_row.ot_rest_day_hours <> v_row.r OR v_row.ot_public_holiday_hours <> v_row.p THEN
            RAISE EXCEPTION 'FIXTURE 232C4 失败:员工 % 冻进来的 (%, %, %) ≠ 批过的 (%, %, %)', v_row.employee_id,
                v_row.ot_normal_hours, v_row.ot_rest_day_hours, v_row.ot_public_holiday_hours, v_row.w, v_row.r, v_row.p; END IF;
    END LOOP;
    -- 字面量本身也钉住(推导:B1 = SITE1 2.5 平日 + 3 星期日 + 3.5 公共假期,SITE2 1.25 平日;B2 = SITE1 2 平日;
    --   B3 被冲销、B4 与 B5 被丢弃 —— 都不算。所以 SITE1 = 4.5 / 3 / 3.5,SITE2 = 1.25 / 0 / 0,总 12.25)
    SELECT sum(ot_normal_hours + ot_rest_day_hours + ot_public_holiday_hours) INTO v_frozen
      FROM attendance_lines WHERE period_id = v_att;
    IF v_frozen <> 12.25
       OR (SELECT ot_normal_hours || '/' || ot_rest_day_hours || '/' || ot_public_holiday_hours FROM attendance_lines
            WHERE period_id = v_att AND employee_id = e_site1) <> '4.50/3.00/3.50'
       OR (SELECT ot_normal_hours FROM attendance_lines WHERE period_id = v_att AND employee_id = e_site2) <> 1.25 THEN
        RAISE EXCEPTION 'FIXTURE 232C5 失败:冻进来的应当是 SITE1 4.50/3.00/3.50、SITE2 1.25、合计 12.25,实得合计 %', v_frozen; END IF;
    -- 完成之后屏幕读冻住的数(fixed = true)
    v_r := pg_temp.f232_rows(u_fin, format('SELECT * FROM overtime_month_hours(%L) WHERE employee_id = %L', M, e_site1));
    IF v_r->0->>'fixed' <> 'true' OR (v_r->0->>'total_hours')::numeric <> 11 THEN
        RAISE EXCEPTION 'FIXTURE 232C6 失败:完成之后应当读冻住的数(SITE1 合计 11,fixed=t),实得 %', v_r; END IF;

    -- C7 · 完成之后一切改动按名拒
    PERFORM pg_temp.f232_expect('C7', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', M)),
                                'OVERTIME_MONTH_COMPLETE|ATT-2026-03|2026-03');
    PERFORM pg_temp.f232_expect('C7', pg_temp.f232_try(u_fin, format('SELECT reverse_overtime_batch(%L, %L)', b1, 'late fix')),
                                'OVERTIME_MONTH_COMPLETE|ATT-2026-03|2026-03');
    -- 一张开着的批在完成之后【走不到】(完成被它挡着)—— 所以直接写一行来问那道闸本身
    INSERT INTO overtime_batches (label, period_month, seq, status, created_by)
    VALUES ('FX232 forced', DATE '2026-03-01', 99, 'draft', u_fin) RETURNING id INTO b_forced;
    PERFORM pg_temp.f232_expect('C7', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 1)', b_forced, e_site1, '2026-03-12')),
                                'OVERTIME_MONTH_COMPLETE|ATT-2026-03|2026-03');
    PERFORM pg_temp.f232_expect('C7', pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b_forced)),
                                'OVERTIME_MONTH_COMPLETE|ATT-2026-03|2026-03');
    UPDATE overtime_batches SET status = 'submitted', submitted_at = now(), submitted_by = u_fin WHERE id = b_forced;
    PERFORM pg_temp.f232_expect('C7', pg_temp.f232_try(u_wh, format('SELECT decide_overtime_batch(%L, %L)', b_forced, 'approved')),
                                'OVERTIME_MONTH_COMPLETE|ATT-2026-03|2026-03');
    DELETE FROM overtime_batches WHERE id = b_forced;

    -- C8 · 重开再完成:重算,不翻倍
    PERFORM pg_temp.f232_expect('C8', pg_temp.f232_try(u_fin, format('SELECT reopen_attendance_period(%L, %L)', v_att, 'recheck')), 'OK');
    PERFORM pg_temp.f232_expect('C8', pg_temp.f232_try(u_fin, format('SELECT complete_attendance_period(%L)', v_att)), 'OK');
    SELECT sum(ot_normal_hours + ot_rest_day_hours + ot_public_holiday_hours) INTO v_sum FROM attendance_lines WHERE period_id = v_att;
    IF v_sum <> v_frozen THEN
        RAISE EXCEPTION 'FIXTURE 232C8 失败:重开再完成应当重算出同一个数 %,实得 %', v_frozen, v_sum; END IF;

    -- ══════════════ Y · /me 与直连 ══════════════
    v_r := pg_temp.f232_rows(u_plain, 'SELECT * FROM my_overtime_lines()');
    IF jsonb_array_length(v_r) <> 4 OR v_r->0->>'approver' <> 'Wally' THEN
        RAISE EXCEPTION 'FIXTURE 232Y1 失败:SITE1 应当读到自己 4 行已批准的加班、批的人显示成 Wally,实得 %', v_r; END IF;
    v_n := pg_temp.f232_count(u_plain, 'SELECT 1 FROM overtime_lines');
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 232Y2 失败:没有码的员工直读 overtime_lines 应当是 0 行,实得 %', v_n; END IF;
    v_n := pg_temp.f232_count(u_wh, 'SELECT 1 FROM overtime_batches');
    IF v_n < 5 THEN RAISE EXCEPTION 'FIXTURE 232Y3 失败:批的人(仓库)应当读得到批次,实得 %', v_n; END IF;
    v_msg := pg_temp.f232_try(u_fin, format('INSERT INTO overtime_batches (label, period_month, seq) VALUES (%L, %L, 50)', 'FX232 direct', '2026-04-01'));
    IF v_msg NOT LIKE '%row-level security%' AND v_msg NOT LIKE 'permission denied%' THEN
        RAISE EXCEPTION 'FIXTURE 232Y4 失败:直连写加班批应当被 RLS 拒,实得 %', v_msg; END IF;

    -- ══════════════ Q · Q20:R2 的标记经 my_document_decisions() 读出来 ══════════════
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false, approval_level2_role_code = 'fx232-l2';
    INSERT INTO expense_claims (id, code, employee_id, spend_date, amount_ccy, currency,
                                description, no_receipt_reason, status, created_by)
    VALUES (x_cfo, 'FX232-X-CFO', e_cfo, DATE '2026-03-02', 40.00, v_base, 'taxi', 'none', 'submitted', u_cfo);
    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status, created_by)
    VALUES (mc_cfo, 'FX232-MC-CFO', e_cfo, DATE '2026-03-02', 2026, 10, 'submitted', u_cfo);
    PERFORM pg_temp.f232_expect('Q1', pg_temp.f232_try(u_cfo, format('SELECT decide_expense_claim(%L, false, NULL, NULL, NULL, %L)', x_cfo, 'mine, declined')), 'OK');
    PERFORM pg_temp.f232_expect('Q2', pg_temp.f232_try(u_cfo, format('SELECT decide_medical_claim(%L, false, %L)', mc_cfo, 'mine, declined')), 'OK');
    IF (SELECT count(*) FROM approval_log WHERE subject_id IN (x_cfo, mc_cfo) AND self_decided) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 232Q3 失败:两张自己的单,approval_log 都应当 self_decided = t'; END IF;
    v_r := pg_temp.f232_rows(u_cfo, 'SELECT kind, doc_id, decider, self_decided FROM my_document_decisions() ORDER BY kind');
    IF jsonb_array_length(v_r) <> 2
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_r) e WHERE NOT (e->>'self_decided')::boolean OR e->>'decider' <> 'Cee') THEN
        RAISE EXCEPTION 'FIXTURE 232Q4 失败:my_document_decisions() 应当给出两行、都是 self_decided = t、决定人 Cee,实得 %', v_r; END IF;
    -- R2 永远不覆盖加班:同一个二级持有人拿到批准码、本人进了一张批 → 照拒 |subject
    UPDATE employees SET is_site_staff = true WHERE id = e_cfo;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_l2, 'action.overtime_approve');
    PERFORM pg_temp.f232_expect('Q5', pg_temp.f232_try(u_fin, format('SELECT create_overtime_batch(%L)', '2026-04-01')), 'OK');
    SELECT id INTO b5 FROM overtime_batches WHERE label = 'OT 2026-04 #1';
    PERFORM pg_temp.f232_expect('Q5', pg_temp.f232_try(u_fin, format('SELECT add_overtime_line(%L, %L, %L, 1)', b5, e_cfo, '2026-04-06')), 'OK');
    PERFORM pg_temp.f232_expect('Q5', pg_temp.f232_try(u_fin, format('SELECT submit_overtime_batch(%L)', b5)), 'OK');
    PERFORM pg_temp.f232_expect('Q5', pg_temp.f232_try(u_cfo, format('SELECT decide_overtime_batch(%L, %L)', b5, 'approved')),
                                'SELF_APPROVAL_FORBIDDEN|subject');

    RAISE NOTICE 'FIXTURE 232 全部通过:E · A · O · S · K · V · D · M · F · R · X · L · C · P · Y · Q';
END;
$$;

ROLLBACK;

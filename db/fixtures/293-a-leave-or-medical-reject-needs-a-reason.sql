-- 293 TABLE-FEATURES-3:驳回一张请假或一张医疗报销,要一句理由 —— 由库按名拒(Tim 2026-10-25 Q11)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   L  请假:理由 NULL / 空串 / 只有空白 → LEAVE_REJECT_REASON_REQUIRED|<编号>,状态仍是 pending、没有审批留痕;
--      带一句理由 → rejected,decision_notes 就是那一句,留痕一行
--   M  医疗报销:同上,MEDICAL_CLAIM_REJECT_REASON_REQUIRED|<编号>,状态仍是 submitted
--   O  ★ 判据只管驳回:本人驳自己的单仍然先撞四眼(SELF_APPROVAL_FORBIDDEN),理由那一格不抢在它前面改写拒绝的原因
--   I  ★ 故障注入:把 decide_leave_request 换回不查理由的函数体,空理由就驳得下去 —— 那几行是承重的
--
-- 自带数据(README 第 2 条);只走驳回那一支,不碰额度、锁期与系统起始日。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '120s';

CREATE FUNCTION pg_temp.f293_try(p_user uuid, p_sql text) RETURNS text
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

DO $$
DECLARE
    u_emp uuid := gen_random_uuid();   -- 提单的员工
    u_hr  uuid := gen_random_uuid();   -- HR:action.decide_hr_requests
    r_hr uuid;
    e_emp uuid := gen_random_uuid(); e_hr uuid := gen_random_uuid();
    lv uuid := gen_random_uuid(); lv_own uuid := gen_random_uuid(); lv_inj uuid := gen_random_uuid();
    mc uuid := gen_random_uuid();
    v_msg text; v_blank text; v_body text;
BEGIN
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_emp, now()), (u_hr, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx293-hr','f','f',true) RETURNING id INTO r_hr;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_hr, c FROM unnest(ARRAY['module.hr.view', 'module.hr.edit', 'action.decide_hr_requests']) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_hr, r_hr);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_emp, 'FX293-EMP', 'FX293 Employee', 'full_time', 'office', DATE '2020-01-01', u_emp),
        (e_hr,  'FX293-HR',  'FX293 HR',       'full_time', 'office', DATE '2020-01-01', u_hr);
    INSERT INTO leave_types (code, name_en, name_zh, is_accrued, is_active) VALUES ('fx293-lv', 'f', 'f', false, true);
    INSERT INTO leave_requests (id, code, employee_id, leave_type_code, start_date, end_date, days, status, created_by) VALUES
        (lv,     'FX293-LV',     e_emp, 'fx293-lv', DATE '2030-03-04', DATE '2030-03-04', 1, 'pending', u_emp),
        (lv_own, 'FX293-LV-OWN', e_hr,  'fx293-lv', DATE '2030-03-05', DATE '2030-03-05', 1, 'pending', u_hr),
        (lv_inj, 'FX293-LV-INJ', e_emp, 'fx293-lv', DATE '2030-03-06', DATE '2030-03-06', 1, 'pending', u_emp);
    INSERT INTO medical_claims (id, code, employee_id, claim_date, claim_year, amount_sgd, status, created_by) VALUES
        (mc, 'FX293-MC', e_emp, DATE '2030-03-04', 2030, 10, 'submitted', u_emp);

    -- ── L · 请假 ──
    -- 空白判据是库的 btrim(只剥空格),与十二条链同一条;只有制表符 / 换行的理由在浏览器那头已被 trim() 挡下(ConfirmButton)
    FOREACH v_blank IN ARRAY ARRAY['NULL', '''''', '''   '''] LOOP
        v_msg := pg_temp.f293_try(u_hr, format('SELECT decide_leave_request(%L, false, %s)', lv, v_blank));
        IF v_msg <> 'LEAVE_REJECT_REASON_REQUIRED|FX293-LV' THEN
            RAISE EXCEPTION 'FIXTURE 293L 失败:理由 % 应按名拒 LEAVE_REJECT_REASON_REQUIRED|FX293-LV,实为 %', v_blank, v_msg;
        END IF;
    END LOOP;
    IF (SELECT status FROM leave_requests WHERE id = lv) <> 'pending'
       OR EXISTS (SELECT 1 FROM approval_log WHERE subject_id = lv) THEN
        RAISE EXCEPTION 'FIXTURE 293L 失败:被拒的驳回改了单据或留了痕';
    END IF;
    v_msg := pg_temp.f293_try(u_hr, format('SELECT decide_leave_request(%L, false, %L)', lv, 'no cover that week'));
    IF v_msg <> 'OK' OR (SELECT status FROM leave_requests WHERE id = lv) <> 'rejected'
       OR (SELECT decision_notes FROM leave_requests WHERE id = lv) <> 'no cover that week'
       OR (SELECT count(*) FROM approval_log WHERE subject_id = lv) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 293L 失败:带理由的驳回应落下 rejected + 理由 + 一行留痕,实为 %', v_msg;
    END IF;
    RAISE NOTICE '  ✓ L 请假:空 / 空白理由按名拒(3 种),带理由驳回落下';

    -- ── M · 医疗报销 ──
    FOREACH v_blank IN ARRAY ARRAY['NULL', '''''', '''   '''] LOOP
        v_msg := pg_temp.f293_try(u_hr, format('SELECT decide_medical_claim(%L, false, %s)', mc, v_blank));
        IF v_msg <> 'MEDICAL_CLAIM_REJECT_REASON_REQUIRED|FX293-MC' THEN
            RAISE EXCEPTION 'FIXTURE 293M 失败:理由 % 应按名拒 MEDICAL_CLAIM_REJECT_REASON_REQUIRED|FX293-MC,实为 %', v_blank, v_msg;
        END IF;
    END LOOP;
    IF (SELECT status FROM medical_claims WHERE id = mc) <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 293M 失败:被拒的驳回改了单据';
    END IF;
    v_msg := pg_temp.f293_try(u_hr, format('SELECT decide_medical_claim(%L, false, %L)', mc, 'receipt unreadable'));
    IF v_msg <> 'OK' OR (SELECT status FROM medical_claims WHERE id = mc) <> 'rejected'
       OR (SELECT decision_notes FROM medical_claims WHERE id = mc) <> 'receipt unreadable' THEN
        RAISE EXCEPTION 'FIXTURE 293M 失败:带理由的驳回应落下 rejected + 理由,实为 %', v_msg;
    END IF;
    RAISE NOTICE '  ✓ M 医疗报销:空 / 空白理由按名拒(3 种),带理由驳回落下';

    -- ── O · 四眼仍在理由之前 ──
    v_msg := pg_temp.f293_try(u_hr, format('SELECT decide_leave_request(%L, false, NULL)', lv_own));
    IF v_msg NOT LIKE 'SELF_APPROVAL_FORBIDDEN%' THEN
        RAISE EXCEPTION 'FIXTURE 293O 失败:驳自己的单(空理由)应先撞四眼,实为 %', v_msg;
    END IF;
    RAISE NOTICE '  ✓ O 本人驳自己的单仍是 SELF_APPROVAL_FORBIDDEN(理由那一格不改写拒绝的原因)';

    -- ── I · 故障注入:拿掉理由那几行,空理由就驳得下去 ──
    v_body := pg_get_functiondef('public.decide_leave_request(uuid,boolean,text)'::regprocedure);
    IF position('LEAVE_REJECT_REASON_REQUIRED' IN v_body) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 293I 布景失败:函数体里找不到理由判据';
    END IF;
    EXECUTE regexp_replace(v_body, 'IF p_notes IS NULL OR btrim\(p_notes\) = '''' THEN\s+RAISE EXCEPTION ''LEAVE_REJECT_REASON_REQUIRED\|%'', v_req\.code;\s+END IF;', '', 'g');
    IF position('LEAVE_REJECT_REASON_REQUIRED' IN pg_get_functiondef('public.decide_leave_request(uuid,boolean,text)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'FIXTURE 293I 布景失败:注入没有拿掉理由判据';
    END IF;
    v_msg := pg_temp.f293_try(u_hr, format('SELECT decide_leave_request(%L, false, NULL)', lv_inj));
    IF v_msg <> 'OK' OR (SELECT status FROM leave_requests WHERE id = lv_inj) <> 'rejected' THEN
        RAISE EXCEPTION 'FIXTURE 293I 失败:拿掉理由判据之后空理由应驳得下去(证明那几行承重),实为 %', v_msg;
    END IF;
    EXECUTE v_body;
    RAISE NOTICE '  ✓ I 注入:拿掉理由判据 → 空理由驳下去了(那几行是承重的);已还原';

    RAISE NOTICE 'FIXTURE 293 全部通过: 请假与医疗报销的驳回要理由(按名拒,单据不动)· 四眼在前 · 注入证明判据承重';
END $$;

ROLLBACK;

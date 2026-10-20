-- 281 FIN-CHAIN-1:钱离开银行的另外六扇门也按名拒明天(APRECON1B-CASH-DOORS-DATE-RULE,2026-10-20)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Tim AP-RECON-1 Batch B Q6;FIN-CHAIN-1 Step 0 Q13)
--   AP-RECON-1 Batch B 让七扇门(费用 · 收付款 · 运费 · 出口运费 · sale 型发票 · 订单发票 · 加工应计转费用)按名拒
--   晚于今天的单据日(fixture 214);本支把剩下的六扇出钱的门一扇一扇撞一次:
--   A  pay_payroll_lines       明天 → DOCUMENT_DATE_IN_FUTURE|payroll_payment|明天|今天
--   B  pay_payroll_cpf         明天 → …|cpf_payment|…
--   C  pay_payroll_deductions  明天 → …|deductions_payment|…
--   D  remit_processing_costs  明天 → …|processing_cost_remittance|…
--   E  remit_wht_internal      明天 → …|wht_remittance|…
--   F  record_bank_transfer_internal 明天 → …|bank_transfer|…
--   每一扇再以【今天】撞一次:报的不再是 DOCUMENT_DATE_IN_FUTURE(它可以因为别的缘故被拒 —— 本支没有给它们备齐数据 ——
--   但拒它的不是日期这一条)。这一对把"今天放行、明天拒"两边都钉住。
--   G  ★ 请求那一侧(Tim Q13 认的副作用):一张计划日是明天的银行划转申请,在【提交】时就按名拒(试跑走的是同一个引擎)
--   H  ★ 故障注入:把 pay_payroll_cpf 里那一句换成恒假,B 臂那一句当场不再报 DOCUMENT_DATE_IN_FUTURE —— 证明 B 臂会咬人
--
-- 【为什么不备齐工资期 / 加工应计 / 代扣税的数据】六扇门的日期闸都在【读任何业务行之前】(紧跟"日期必填"那一句),
--   所以一张不存在的工资期也撞得到它 —— 而"今天"那一半证明的正是:过了日期这一关,拒它的是后面的东西。
-- 自带数据(README 第 2 条);审批关着(G 臂提交即试跑)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE FUNCTION pg_temp.f281_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END;
$f$;

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all  uuid;
    v_pp   uuid := gen_random_uuid();     -- 一张不存在的工资期:日期闸在读它之前
    d      date := CURRENT_DATE;
    d1     date := CURRENT_DATE + 1;
    v_msg  text;
    v_def  text;
    v_doors text[][] := ARRAY[
        ARRAY['A', 'payroll_payment',            'SELECT pay_payroll_lines(%L, ARRAY[]::uuid[], %L)'],
        ARRAY['B', 'cpf_payment',                'SELECT pay_payroll_cpf(%L, %L)'],
        ARRAY['C', 'deductions_payment',         'SELECT pay_payroll_deductions(%L, %L)'],
        ARRAY['D', 'processing_cost_remittance', 'SELECT remit_processing_costs(ARRAY[%L]::uuid[], %L)'],
        ARRAY['E', 'wht_remittance',             'SELECT remit_wht_internal(date_trunc(''month'', %L::date)::date, %L)'],
        ARRAY['F', 'bank_transfer',              'SELECT record_bank_transfer_internal(%2$L, ''1000'', ''1010'', 100, 75) WHERE %1$L IS NOT NULL']];
    i int;
    v_arg text;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_user);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx281-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════════ A–F · 六扇门,明天拒、今天过得了日期这一关 ══════════════
    FOR i IN 1 .. array_length(v_doors, 1) LOOP
        -- 第一个占位:A–C 是工资期,D 是加工应计(一张不存在的),E 是代扣税的月份,F 不用
        v_arg := CASE WHEN v_doors[i][1] = 'E' THEN d::text ELSE v_pp::text END;
        v_msg := pg_temp.f281_try(format(v_doors[i][3], v_arg, d1));
        IF v_msg <> format('DOCUMENT_DATE_IN_FUTURE|%s|%s|%s', v_doors[i][2], d1, d) THEN
            RAISE EXCEPTION 'FIXTURE 281%1 失败:% 收了明天的日子,应当按名拒 DOCUMENT_DATE_IN_FUTURE|%|…,实得 %',
                v_doors[i][1], v_doors[i][3], v_doors[i][2], v_msg; END IF;
        v_msg := pg_temp.f281_try(format(v_doors[i][3], v_arg, d));
        IF v_msg LIKE 'DOCUMENT_DATE_IN_FUTURE%' THEN
            RAISE EXCEPTION 'FIXTURE 281%2 失败:今天的日子不该被日期这一条拒,实得 %', v_doors[i][1], v_msg; END IF;
    END LOOP;

    -- ══════════════ G · 计划日是明天的银行划转申请,提交时就拒 ══════════════
    v_msg := pg_temp.f281_try(format('SELECT submit_bank_transfer_request(%L, %L, %L, 100, 75)', d1, '1000', '1010'));
    IF v_msg <> format('DOCUMENT_DATE_IN_FUTURE|bank_transfer|%s|%s', d1, d) THEN
        RAISE EXCEPTION 'FIXTURE 281G 失败:计划日是明天的划转申请应当在提交时按名拒,实得 %', v_msg; END IF;
    IF EXISTS (SELECT 1 FROM payment_requests WHERE planned_date = d1) THEN
        RAISE EXCEPTION 'FIXTURE 281G2 失败:被拒的提交不该留下一张申请'; END IF;

    -- ══════════════ H · 故障注入:把 B 那一句换成恒假 ══════════════
    v_def := pg_get_functiondef('public.pay_payroll_cpf(uuid, date, text)'::regprocedure);
    IF position('IF p_payment_date > CURRENT_DATE THEN' IN v_def) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 281H0 前提失败:函数体里找不到那一句'; END IF;
    EXECUTE replace(v_def, 'IF p_payment_date > CURRENT_DATE THEN', 'IF false THEN');
    v_msg := pg_temp.f281_try(format('SELECT pay_payroll_cpf(%L, %L)', v_pp, d1));
    IF v_msg LIKE 'DOCUMENT_DATE_IN_FUTURE%' THEN
        RAISE EXCEPTION 'FIXTURE 281H 失败:拿掉那一句之后仍然报 DOCUMENT_DATE_IN_FUTURE —— B 臂的断言没有在测它'; END IF;

    RAISE NOTICE 'FIXTURE 281 全部通过:六扇门明天拒、今天过日期这一关 · G 划转申请提交即拒 · H 注入';
END;
$$;
ROLLBACK;

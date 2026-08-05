-- 07 期间锁挡住回溯过账
--
-- 为什么值得常设:关账之后还能往回记一笔,报表就会在出具之后自己变 ——
-- 而且是静悄悄地变。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid; v_msg text; v_ok boolean := false;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-07', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);

    -- 自己设定锁位(不继承线上那一刻的值 —— 见 README 第 4 条)
    UPDATE finance_settings SET locked_before = '2026-06-01';

    -- 锁位【之前】的日期:必须被拒
    BEGIN
        PERFORM post_journal_entry('2026-05-31', 'fixture 07 back-dated', 'manual', NULL,
            jsonb_build_array(
                jsonb_build_object('account_code','1000','side','debit','currency','SGD',
                                   'amount_ccy',100,'fx_rate',1),
                jsonb_build_object('account_code','4000','side','credit','currency','SGD',
                                   'amount_ccy',100,'fx_rate',1)));
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'PERIOD_LOCKED%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 07 失败:锁位 2026-06-01 之前的分录应被 PERIOD_LOCKED 拒绝,实得:%',
            COALESCE(v_msg, '(没有报错,直接过账了)');
    END IF;

    -- 锁位【当天及之后】:必须放行。少了这一条,上面那句可能只是因为"什么都不能过账"而通过
    PERFORM post_journal_entry('2026-06-01', 'fixture 07 on-or-after', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code','1000','side','debit','currency','SGD',
                               'amount_ccy',100,'fx_rate',1),
            jsonb_build_object('account_code','4000','side','credit','currency','SGD',
                               'amount_ccy',100,'fx_rate',1)));
END $$;
ROLLBACK;

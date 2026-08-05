-- 02 同一期末重跑重估:第二次一行都不该发
--
-- 为什么值得常设:重估【自我修正】的口径全靠"承载额已含既往重估行"这一条。
-- 它一旦断了,重跑就会重复计提,而账面看起来仍然平 —— 没有任何东西会报错。
BEGIN;
DO $$
DECLARE
    v_uid uuid := gen_random_uuid(); v_role uuid;
    d date := '2026-06-30'; v1 jsonb; v2 jsonb; v_acct uuid; v_je uuid;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-02', 'fixture', 'fixture', true) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', d, 'mid', 1.35);

    -- 造一笔外币货币性余额:借 1100(应收,is_monetary)/ 贷 4000
    SELECT id INTO v_acct FROM accounts WHERE code = '1100';
    PERFORM post_journal_entry(d, 'fixture 02 seed', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1100','side','debit','currency','USD',
                           'amount_ccy',1000,'fx_rate',1.20),
        jsonb_build_object('account_code','4000','side','credit','currency','USD',
                           'amount_ccy',1000,'fx_rate',1.20)));

    v1 := revalue_foreign_balances(d);
    v2 := revalue_foreign_balances(d);

    -- 【不变量,不是字面量】第一次必须有调整(1.20 → 1.35 有差),
    -- 第二次必须一条都没有 —— 具体差多少不是这条断言关心的事。
    IF (v1->>'adjustments')::int = 0 THEN
        RAISE EXCEPTION 'FIXTURE 02 失败:首次重估应产生调整(入账 1.20、期末 1.35),实得 0 条';
    END IF;
    IF (v2->>'adjustments')::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 02 失败:同一期末重跑应【零调整】(自我修正),实得 % 条',
            (v2->>'adjustments')::int;
    END IF;
    IF v2->>'journal_code' IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 02 失败:重跑不该再发分录,却发了 %', v2->>'journal_code';
    END IF;
END $$;
ROLLBACK;

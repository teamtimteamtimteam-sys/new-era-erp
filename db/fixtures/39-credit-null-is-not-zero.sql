-- 39 信用管控:NULL 限额放行而 0 限额拒;越限在【本位币】那一侧判;冻结不看敞口;
--    变动留痕;敞口与 ar_open_items 同数;看板臂上下有据
--
-- 【判别臂是 A:NULL 放行、0 拒 —— 相反,不是相近】只测正数限额的 fixture,对一个
-- "把 NULL 当 0"的实现照样全绿 —— 而那个实现会拒掉全部既有客户(全是 NULL)的销售。
-- 注入方式:把 IF v_limit IS NOT NULL 改成 COALESCE(v_limit,0),本臂即红。
--
-- 【B 臂与审批阈值同形】(fixture 35A):外币销售在单据币种里低于限额、本位币里
-- 高于 —— 单据币种比较的实现会放行它。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_mat uuid; ob uuid;
    c_null uuid; c_zero uuid; c_lim uuid; c_hold uuid;
    v_base text;
    v_denied boolean; v_msg text;
    v_n int; v_row record;
    v_exposure numeric; v_view_sum numeric;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-39', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['module.output.edit','module.output.view',
                           'module.customers.view','module.customers.edit',
                           'module.finance.view','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX39-M', 'fixture 39 material', 'battery_material', true) RETURNING id INTO v_mat;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX39-OB', v_mat, 10000, 10000, '2027-07-01') RETURNING id INTO ob;

    -- 四个客户:没设限、现款现货、限一万、冻结(敞口为零)
    INSERT INTO customers (code, legal_name, country) VALUES ('ZZFIX39-C1', 'no limit set', 'SG') RETURNING id INTO c_null;
    INSERT INTO customers (code, legal_name, country, credit_limit_base) VALUES ('ZZFIX39-C2', 'cash only', 'SG', 0) RETURNING id INTO c_zero;
    INSERT INTO customers (code, legal_name, country, credit_limit_base) VALUES ('ZZFIX39-C3', 'limited 10k', 'SG', 10000) RETURNING id INTO c_lim;
    INSERT INTO customers (code, legal_name, country, credit_hold) VALUES ('ZZFIX39-C4', 'held', 'SG', true) RETURNING id INTO c_hold;

    -- 外币牌价(B 臂用):1 外币 = 1.26 本位币
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit)
    VALUES ('USD', '2027-07-05', 'tt_buy', 1.26);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. NULL 放行,0 拒 —— 同一笔销售,两种限额,相反的结果 ═════════
    PERFORM record_output_sale(ob, 10, 50, v_base, NULL, c_null, '2027-07-05'::date, NULL, 'manual', NULL);
    -- NULL 限额:过了 —— 没设限不是零限

    v_denied := false;
    BEGIN
        PERFORM record_output_sale(ob, 10, 50, v_base, NULL, c_zero, '2027-07-05'::date, NULL, 'manual', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 39A 失败:0 限额(现款现货)的客户赊销成功了 —— 0 被当成了"没设限"。NULL 与 0 相反:一个放行、一个全拒';
    END IF;
    IF v_msg NOT LIKE 'CREDIT_LIMIT_EXCEEDED|ZZFIX39-C2|0|0|%' THEN
        RAISE EXCEPTION 'FIXTURE 39A 失败:拒绝要把三个数说全(限额|敞口|这一单),实得「%」—— 只说"超限"等于让人手算系统已经知道的数', v_msg;
    END IF;

    -- ══════════ B. 越限在本位币那一侧判(与 fixture 35A 同形)═══════════════
    -- 限额 10,000 本位币;这一单 8,000 USD × 1.26 = 10,080 本位币 ——
    -- 单据币种里(8,000 < 10,000)低于限额,本位币里高于。
    v_denied := false;
    BEGIN
        PERFORM record_output_sale(ob, 8000, 1, 'USD', NULL, c_lim, '2027-07-05'::date, NULL, 'manual', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 39B 失败:外币 8,000(本位币 10,080,限额 10,000)的销售放行了 —— 限额是拿【单据币种】比的。同一个客户不能因为用哪种货币开票而多出一截信用';
    END IF;
    IF v_msg NOT LIKE 'CREDIT_LIMIT_EXCEEDED|ZZFIX39-C3|10000|0|10080%' THEN
        RAISE EXCEPTION 'FIXTURE 39B 失败:三个数应为 限额 10000|敞口 0|这一单 10080,实得「%」', v_msg;
    END IF;
    -- 而同客户 7,000 USD(本位币 8,820)【应当】过 —— 否则 B 臂只是"这客户什么都买不了"
    PERFORM record_output_sale(ob, 7000, 1, 'USD', NULL, c_lim, '2027-07-05'::date, NULL, 'manual', NULL);

    -- 有了 8,820 敞口之后,再来 2,000 本位币(合计 10,820 > 10,000)也要拒 ——
    -- 敞口是【累计的导出值】,不是只看本单
    v_denied := false;
    BEGIN
        PERFORM record_output_sale(ob, 40, 50, v_base, NULL, c_lim, '2027-07-05'::date, NULL, 'manual', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'CREDIT_LIMIT_EXCEEDED|ZZFIX39-C3|10000|8820%' THEN
        RAISE EXCEPTION 'FIXTURE 39B 失败:已有敞口 8,820 再加 2,000 应拒(合计越限),实得 denied=% msg=%', v_denied, v_msg;
    END IF;

    -- ══════════ C. 冻结不看敞口 ═════════════════════════════════════════════
    v_denied := false;
    BEGIN
        PERFORM record_output_sale(ob, 1, 1, v_base, NULL, c_hold, '2027-07-05'::date, NULL, 'manual', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'CREDIT_HOLD|ZZFIX39-C4' THEN
        RAISE EXCEPTION 'FIXTURE 39C 失败:冻结客户(敞口为零)的销售应被 CREDIT_HOLD 拒,实得 denied=% msg=% —— 冻结是人的决定,不是算术条件', v_denied, v_msg;
    END IF;

    -- ══════════ D. 变动留痕:旧值新值都在;留痕只增不改 ══════════════════════
    UPDATE customers SET credit_limit_base = 25000 WHERE id = c_lim;
    SELECT * INTO v_row FROM customer_credit_history
     WHERE customer_id = c_lim ORDER BY changed_at DESC LIMIT 1;
    IF v_row.old_credit_limit_base <> 10000 OR v_row.new_credit_limit_base <> 25000 THEN
        RAISE EXCEPTION 'FIXTURE 39D 失败:限额 10000→25000 应留痕旧值与新值,实得 %→%',
            v_row.old_credit_limit_base, v_row.new_credit_limit_base;
    END IF;
    UPDATE customers SET credit_hold = false WHERE id = c_hold;
    SELECT count(*) INTO v_n FROM customer_credit_history WHERE customer_id = c_hold
     AND old_credit_hold = true AND new_credit_hold = false;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 39D 失败:解除冻结应留痕一行(true→false),实得 % 行 —— 为推一单而解冻正是最该留痕的动作', v_n;
    END IF;
    v_denied := false;
    BEGIN
        UPDATE customer_credit_history SET new_credit_limit_base = 1 WHERE id = v_row.id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'CREDIT_HISTORY_APPEND_ONLY|update%' THEN
            RAISE EXCEPTION 'FIXTURE 39D 失败:留痕被拒但没报自己的名字:「%」', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 39D 失败:留痕被 UPDATE 成功 —— 能改写的留痕不是留痕';
    END IF;

    -- ══════════ E. 敞口与 ar_open_items 同数(重复定义的钉子,同 31E)═════════
    v_exposure := customer_ar_exposure_base(c_lim);
    SELECT COALESCE(sum(open_base), 0) INTO v_view_sum
    FROM ar_open_items WHERE customer_id = c_lim;
    IF v_exposure <> v_view_sum THEN
        RAISE EXCEPTION 'FIXTURE 39E 失败:customer_ar_exposure_base(%)与 ar_open_items 之和(%)不一致 —— 两份算术漂了,改一边要改两边',
            v_exposure, v_view_sum;
    END IF;
    IF v_exposure <> 8820 THEN
        RAISE EXCEPTION 'FIXTURE 39E 前置失败:敞口应为 8,820(7,000 USD × 1.26),实得 % —— 为零的话本臂在拿零比零,是空转的', v_exposure;
    END IF;

    -- ══════════ F. 看板臂:超限上牌、未超不上、NULL 永不上 ═══════════════════
    UPDATE customers SET credit_limit_base = 5000 WHERE id = c_lim;   -- 敞口 8,820 > 5,000
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'credit_over_limit' AND item_code = 'ZZFIX39-C3';
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 39F 失败:敞口 8,820 限额 5,000 的客户应上牌,实得 % 行', v_n;
    END IF;
    UPDATE customers SET credit_limit_base = 50000 WHERE id = c_lim;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'credit_over_limit' AND item_code IN ('ZZFIX39-C1','ZZFIX39-C3');
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 39F 失败:限额之内(C3)与没设限(C1)都不该上牌,实得 % 行 —— NULL 上了牌就是"没设限"被读成了"零限额"', v_n;
    END IF;
END $$;
ROLLBACK;

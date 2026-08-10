-- 46 信用状况:有限额就把三个数说全;无权【拿不到行】而不是拿到 0;必拒时说得出必拒
--
-- 【判别臂是 C:无权者拿到的是"没有行",不是 0】0 在信用面板上读作
-- "没有限额、余额充足"—— 这是这个管控最危险的一种失败,比不显示更坏。
-- 只断言"有权者数对"的 fixture,对一个把无权者放进来的实现照样全绿。
--
-- 【注入方式:拿掉视图 WHERE 里的 has_permission('module.customers.view')】—— C 臂即红
-- (实测"实得 4 行")。
-- 【先写错过一次,留着这句免得下一个人重蹈】最初这里写的是"把 exposure_base 外面
-- 套上 COALESCE(...,0) 即可让 C 臂变红"。跑出来【不红】:守住这一支的是视图的
-- WHERE 谓词(无权者【一行都拿不到】),不是外壳返回的 NULL —— 对有权的读者
-- 外壳本来就不会返回 NULL,那个 COALESCE 是个无操作。
-- 教训:注伤要注在【真正承担保护的那一处】;注错地方而 fixture 仍然绿,
-- 会被读成"这条断言没有判别力",而事实是那一刀根本没碰到它。
--
-- 【D:sales_blocked 只认"服务端保证会拒"的两种】冻结,或敞口已 ≥ 限额。
-- "这一单会不会顶过线"取决于金额与汇率,提交时才知道 —— 面板给余额,不假装算得出。
-- 把 D 写反(比如敞口 > 0 就算 blocked)会禁掉本来做得成的销售,那是把管控变成停业。
BEGIN;
DO $$
DECLARE
    u_ok uuid := gen_random_uuid();
    u_blind uuid := gen_random_uuid();
    r_ok uuid; r_blind uuid;
    v_mat uuid; ob uuid; v_base text;
    c_room uuid; c_over uuid; c_hold uuid; c_nolimit uuid;
    v_row record; v_n int;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    -- 看得见客户模块的读者
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-46-ok','f','f',true) RETURNING id INTO r_ok;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_ok, unnest(ARRAY['module.customers.view','module.output.edit','module.output.view',
                              'module.finance.view','module.finance.edit','data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_ok, r_ok);

    -- 【看不见客户模块】的读者 —— 销售面板上确实存在这种人(有 output.edit 无 customers.view)
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-46-blind','f','f',true) RETURNING id INTO r_blind;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_blind, unnest(ARRAY['module.output.edit','module.output.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u_blind, r_blind);

    INSERT INTO materials (code, name, category) VALUES ('ZZFIX46-M','f','other') RETURNING id INTO v_mat;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date)
    VALUES ('ZZFIX46-OB', v_mat, 10000, 10000, '2027-11-01') RETURNING id INTO ob;

    INSERT INTO customers (code, legal_name, country, credit_limit_base)
    VALUES ('ZZFIX46-ROOM','has room','SG',10000) RETURNING id INTO c_room;
    -- 【先有敞口,后设限额】—— 越限状态在真实世界里就是这么来的:限额是后来定的,
    -- 或者被调低了。SAL-C 之后,新销售【自己】就越限会当场被拒(fixture 44 A 臂),
    -- 所以不可能靠"直接卖一笔超额的"造出这个状态,那条路已经堵死了。
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX46-OVER','at the limit','SG') RETURNING id INTO c_over;
    INSERT INTO customers (code, legal_name, country, credit_hold)
    VALUES ('ZZFIX46-HOLD','frozen','SG',true) RETURNING id INTO c_hold;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZFIX46-NONE','no limit set','SG') RETURNING id INTO c_nolimit;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_ok), true);

    -- 各造一笔敞口:ROOM 2,000(限额 10,000 → 余额 8,000);OVER 1,500(限额 1,000 → 越限)
    PERFORM record_output_sale(ob, 100, 20, v_base, NULL, c_room, '2027-11-05'::date, NULL, 'manual', NULL);
    PERFORM record_output_sale(ob, 100, 15, v_base, NULL, c_over, '2027-11-05'::date, NULL, 'manual', NULL);
    UPDATE customers SET credit_limit_base = 1000 WHERE id = c_over;   -- 事后定下的限额

    -- ══════════ A. 有限额有余额:三个数都对得上 ═══════════════════════════════
    SELECT * INTO v_row FROM customer_credit_status WHERE customer_id = c_room;
    IF v_row.credit_limit_base <> 10000 OR v_row.exposure_base <> 2000 OR v_row.headroom_base <> 8000 THEN
        RAISE EXCEPTION 'FIXTURE 46A 失败:应为 限额 10,000 / 敞口 2,000 / 余额 8,000,实得 % / % / % —— 面板就是照这三个数说话的',
            v_row.credit_limit_base, v_row.exposure_base, v_row.headroom_base;
    END IF;
    IF v_row.sales_blocked THEN
        RAISE EXCEPTION 'FIXTURE 46A 失败:还有 8,000 余额的客户不该被禁 —— 把管控做成停业比没有管控更坏';
    END IF;

    -- ══════════ B. 敞口已够到限额:必拒,面板据此禁钮 ═════════════════════════
    SELECT * INTO v_row FROM customer_credit_status WHERE customer_id = c_over;
    IF v_row.exposure_base <> 1500 OR v_row.headroom_base <> -500 THEN
        RAISE EXCEPTION 'FIXTURE 46B 前置失败:应为 敞口 1,500 / 余额 −500,实得 % / %',
            v_row.exposure_base, v_row.headroom_base;
    END IF;
    IF NOT v_row.sales_blocked THEN
        RAISE EXCEPTION 'FIXTURE 46B 失败:敞口已 ≥ 限额时【任何】金额的销售都会被 record_output_sale 拒,面板必须禁钮 —— 给一个必定失败的按钮是谎话';
    END IF;
    -- 与真拒绝对齐:视图说必拒,服务端就真的拒(两边同一个答案)
    DECLARE v_denied boolean := false;
    BEGIN
        BEGIN
            PERFORM record_output_sale(ob, 1, 1, v_base, NULL, c_over, '2027-11-05'::date, NULL, 'manual', NULL);
        EXCEPTION WHEN OTHERS THEN v_denied := true;
        END;
        IF NOT v_denied THEN
            RAISE EXCEPTION 'FIXTURE 46B 失败:视图说必拒,服务端却放行了 —— 面板会禁一个本可以按的钮';
        END IF;
    END;

    -- 冻结:不看敞口,同样必拒
    SELECT * INTO v_row FROM customer_credit_status WHERE customer_id = c_hold;
    IF NOT v_row.credit_hold OR NOT v_row.sales_blocked THEN
        RAISE EXCEPTION 'FIXTURE 46B 失败:冻结客户(敞口为零)也必须 sales_blocked —— 冻结是人的决定,不是算术条件';
    END IF;

    -- 未设限额:不禁、也没有余额可言(NULL,不是 0)
    SELECT * INTO v_row FROM customer_credit_status WHERE customer_id = c_nolimit;
    IF v_row.sales_blocked OR v_row.headroom_base IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 46B 失败:未设限额 = 不设限(放行),余额应为 NULL 而不是 0,实得 blocked=% headroom=%',
            v_row.sales_blocked, v_row.headroom_base;
    END IF;

    -- ══════════ C.【判别臂】无 module.customers.view:一行都拿不到 ═════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_blind), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM customer_credit_status;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 46C 失败:没有 module.customers.view 的读者应当【拿不到行】,实得 % 行 —— 拿到 0 会在面板上读作"没有限额、余额充足",是这个管控最危险的失败', v_n;
    END IF;
END $$;
ROLLBACK;

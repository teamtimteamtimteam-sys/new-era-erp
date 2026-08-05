每个 fixture 开头都重复这一段(刻意不抽成共用函数:重建库里没有它,
而 fixture 不该给被测的库添任何东西):

    v_uid uuid := gen_random_uuid();
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-NN', ...) RETURNING id INTO v_role;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_role, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_uid, v_role);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_uid), true);
    UPDATE finance_settings SET locked_before = NULL;   -- 若用例涉及过账日期

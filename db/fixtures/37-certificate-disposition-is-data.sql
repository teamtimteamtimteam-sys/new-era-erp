-- 37 资质框架:block 过期挡收货、warn 不挡;【改一行数据就改行为】;
--    看板臂到 lead 上牌、过期不落牌(无下限)、续期即安静;未知类型码被拒
--
-- 【判别臂是 B:disposition 是数据】把某类型从 block 改成 warn(一条 UPDATE,不改
-- 任何代码),同一笔收货从被拒变成通过 —— 这正是"类型是表不是枚举"的全部意义
-- (CMP-1 第 1 条)。没有这一臂,disposition 完全可以是写死在守卫里的常量,
-- 表只是装饰。
--
-- 【无下限那一臂用两年前的日期】work_pass_expiry 的 -30 天下限对【拦截型】证书是
-- 错的:工作证过期 30 天人已走,证书过期两年而进场仍可能 —— live 那张 2024 年就
-- 过期的 Article 18 就是证据。
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid();
    r uuid;
    v_mat uuid;
    sup_block uuid; sup_warn uuid; sup_none uuid;
    v_cert uuid;
    v_denied boolean; v_msg text;
    v_n int; v_days int;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-37', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r, unnest(ARRAY['module.suppliers.view','module.suppliers.edit',
                           'module.inbound.edit','module.inbound.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);

    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZFIX37-M', 'fixture 37 material', 'battery_material', true) RETURNING id INTO v_mat;

    -- 三个供应商:持过期 block 证的、持过期 warn 证的、一张证都没有的
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX37-S1', 'fixture 37 blocked supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup_block;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX37-S2', 'fixture 37 warned supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup_warn;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX37-S3', 'fixture 37 bare supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO sup_none;

    -- 过期【两年】的 block 证(basel 引导默认 block)与过期的 warn 证(iso 默认 warn)。
    -- 两年是特意的:无下限那一臂靠它成立。
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (sup_block, 'basel', 'FIX37-B', CURRENT_DATE - 900, CURRENT_DATE - 730)
    RETURNING id INTO v_cert;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until)
    VALUES (sup_warn, 'iso', 'FIX37-W', CURRENT_DATE - 900, CURRENT_DATE - 10);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u), true);

    -- ══════════ A. block 过期 → 收货点名拒;warn 过期 → 照收 ═════════════════
    v_denied := false;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
        VALUES ('ZZFIX37-IB1', v_mat, sup_block, 1, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 37A 失败:block 类型证书过期两年的供应商收货成功了 —— 拦截规则没有生效';
    END IF;
    IF v_msg NOT LIKE 'SUPPLIER_QUALIFICATION_EXPIRED|ZZFIX37-S1|basel|%' THEN
        RAISE EXCEPTION 'FIXTURE 37A 失败:拒绝要点名【哪个供应商、哪张证、何时过期】,实得「%」', v_msg;
    END IF;

    -- warn 类型过期【不挡】—— 商业保证的过期是瑕疵,不是违法
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX37-IB2', v_mat, sup_warn, 1, 1, CURRENT_DATE);
    -- 没有证书也不挡:挡的是【过期】,不是【没有】(A3 的答复只到这里)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX37-IB3', v_mat, sup_none, 1, 1, CURRENT_DATE);

    -- ══════════ B. 改一行数据就改行为(本 fixture 的全部意义)═══════════════
    -- basel 从 block 改成 warn —— 同一个供应商、同一张过期证,现在收得进
    UPDATE certificate_types SET disposition = 'warn' WHERE code = 'basel';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX37-IB4', v_mat, sup_block, 1, 1, CURRENT_DATE);

    -- iso 从 warn 改成 block —— 反向也成立,排除"守卫只认 basel 这个码"的实现
    UPDATE certificate_types SET disposition = 'block' WHERE code = 'iso';
    v_denied := false;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
        VALUES ('ZZFIX37-IB5', v_mat, sup_warn, 1, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SUPPLIER_QUALIFICATION_EXPIRED|ZZFIX37-S2|iso|%' THEN
        RAISE EXCEPTION 'FIXTURE 37B 失败:iso 改成 block 后同一张过期证应当开始拦截,实得 denied=% msg=% —— 处置若不是从表里现读的,类型表就只是装饰',
            v_denied, v_msg;
    END IF;
    -- 复原,后面几臂用默认处置
    UPDATE certificate_types SET disposition = 'block' WHERE code = 'basel';
    UPDATE certificate_types SET disposition = 'warn'  WHERE code = 'iso';

    -- ══════════ C. 看板臂:到 lead 上牌、过期不落牌、续期即安静 ══════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- 过期两年的 block 证【仍在牌上】(无 -30 天下限 —— live 那张 Article 18 的教训)
    SELECT count(*), max(days_waiting) INTO v_n, v_days FROM operations_now
     WHERE item_type = 'qualification_expiring' AND item_code = 'ZZFIX37-S1';
    RESET ROLE;
    IF v_n <> 1 OR v_days < 700 THEN
        RAISE EXCEPTION 'FIXTURE 37C 失败:过期 730 天的 block 证应仍在牌上(无下限),实得 % 行 / days=% —— 落牌即是 work_pass 的 -30 天下限被错误搬到了拦截型证书上',
            v_n, v_days;
    END IF;

    -- lead 窗口内(iso lead 60:到期前 59 天)→ 上牌;窗口外(到期前 61 天)→ 不上
    UPDATE supplier_compliance SET valid_until = CURRENT_DATE + 59 WHERE supplier_id = sup_warn;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'qualification_expiring' AND item_code = 'ZZFIX37-S2';
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 37C 失败:iso(lead 60)到期前 59 天应上牌,实得 % 行', v_n;
    END IF;
    UPDATE supplier_compliance SET valid_until = CURRENT_DATE + 61 WHERE supplier_id = sup_warn;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'qualification_expiring' AND item_code = 'ZZFIX37-S2';
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 37C 失败:到期前 61 天(lead 60 之外)不该上牌,实得 % 行 —— 常亮的牌与没有牌是一回事', v_n;
    END IF;

    -- 续期即安静:过期两年的 basel 证续到明年 → 落牌
    UPDATE supplier_compliance SET valid_until = CURRENT_DATE + 365 WHERE id = v_cert;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'qualification_expiring' AND item_code = 'ZZFIX37-S1';
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 37C 失败:续期之后应落牌,实得 % 行 —— 清不掉的告警就是 OPS-14 那盏常亮灯', v_n;
    END IF;
    -- 续期之后收货也通了(拦的是过期,证续上了就没有过期)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
    VALUES ('ZZFIX37-IB6', v_mat, sup_block, 1, 1, CURRENT_DATE);

    -- ══════════ D. 缺席臂:一张证都没有的供应商上 missing 牌;补一张即落 ══════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'qualification_missing' AND item_code = 'ZZFIX37-S3';
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 37D 失败:无证供应商应上 qualification_missing,实得 % 行', v_n;
    END IF;
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, valid_until)
    VALUES (sup_none, 'other', CURRENT_DATE + 365);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'qualification_missing' AND item_code = 'ZZFIX37-S3';
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 37D 失败:补上证书后 missing 牌应落,实得 % 行', v_n;
    END IF;

    -- ══════════ E. 未知类型码被拒(外键)—— 迁移侧"映射不上就大声失败"的常设面 ══
    v_denied := false;
    BEGIN
        INSERT INTO supplier_compliance (supplier_id, cert_type_code)
        VALUES (sup_none, 'no_such_type');
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 37E 失败:未知的 cert_type_code 被接受了 —— 自由文本的病又回来了';
    END IF;

    -- ══════════ F. supplier_receiving_blocked 视图 ⇔ 触发器【同一个答案】(CMP-2)══
    -- 视图是表单"为什么点不动"的数据来源,谓词与触发器是各自写的两份 —— 会漂。
    -- 本臂钉:视图有行 ⇔ 收货被拒,且拒绝消息里的三个数【就是】视图行里的三个数。
    -- 注入方式:把视图谓词的 disposition='block' 删掉(warn 也上) → F1 的 S2 断言红;
    -- 把 valid_until < CURRENT_DATE 写成 <= → F2 边界臂红。
    DECLARE v_row record;
    BEGIN
        -- S1 重新过期(昨天),S2 的 warn 证也过期 —— 只有 block 的该上视图
        UPDATE supplier_compliance SET valid_until = CURRENT_DATE - 1 WHERE id = v_cert;
        UPDATE supplier_compliance SET valid_until = CURRENT_DATE - 10 WHERE supplier_id = sup_warn;

        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM supplier_receiving_blocked WHERE supplier_code = 'ZZFIX37-S2';
        RESET ROLE;
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 37F 失败:warn 类型过期不拦收货,也就不该上 blocked 视图,实得 % 行 —— 视图比触发器严,表单会灰掉一个服务端其实肯收的钮', v_n;
        END IF;

        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT * INTO v_row FROM supplier_receiving_blocked WHERE supplier_code = 'ZZFIX37-S1';
        RESET ROLE;
        IF v_row IS NULL OR v_row.cert_type_code <> 'basel' OR v_row.valid_until <> CURRENT_DATE - 1 THEN
            RAISE EXCEPTION 'FIXTURE 37F 失败:被拦供应商应在视图上且证书/日期对得上,实得 %', v_row;
        END IF;
        -- 触发器拒绝的三个数【就是】视图行的三个数 —— 两份谓词漂了,这里对不齐
        v_denied := false;
        BEGIN
            INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
            VALUES ('ZZFIX37-IB7', v_mat, sup_block, 1, 1, CURRENT_DATE);
        EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
        END;
        IF NOT v_denied OR v_msg <> format('SUPPLIER_QUALIFICATION_EXPIRED|%s|%s|%s',
                v_row.supplier_code, v_row.cert_type_code, v_row.valid_until) THEN
            RAISE EXCEPTION 'FIXTURE 37F 失败:拒绝消息应与视图行逐字段一致,实得 denied=% msg=%', v_denied, v_msg;
        END IF;
        -- warn 过期的 S2:视图不上(前断言),收货也真的收得进 —— 同一个答案的另一半
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
        VALUES ('ZZFIX37-IB8', v_mat, sup_warn, 1, 1, CURRENT_DATE);

        -- 边界:今天到期【还没过期】—— 视图无行,收货照收(两边同用 < CURRENT_DATE)
        UPDATE supplier_compliance SET valid_until = CURRENT_DATE WHERE id = v_cert;
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM supplier_receiving_blocked WHERE supplier_code = 'ZZFIX37-S1';
        RESET ROLE;
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, arrival_date)
        VALUES ('ZZFIX37-IB9', v_mat, sup_block, 1, 1, CURRENT_DATE);
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 37F 失败:今天才到期的证不算过期(< 不是 <=),视图应无行,实得 % 行 —— 收货刚刚都成功了,视图却说被拦:钮和触发器在边界日互相矛盾', v_n;
        END IF;

        -- 权限门:无 module.inbound.view 的读者从视图读到零行(属主视图,门在体内)
        UPDATE supplier_compliance SET valid_until = CURRENT_DATE - 1 WHERE id = v_cert;
        PERFORM set_config('request.jwt.claims',
            format('{"sub":"%s","role":"authenticated"}', gen_random_uuid()), true);
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM supplier_receiving_blocked;
        RESET ROLE;
        IF v_n <> 0 THEN
            RAISE EXCEPTION 'FIXTURE 37F 失败:无 inbound 权限的读者不该看到 blocked 视图的行,实得 % 行', v_n;
        END IF;
    END;
END $$;
ROLLBACK;

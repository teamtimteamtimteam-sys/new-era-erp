-- 65 建单只有一扇门(SO-2b 之一):而那扇门关上的,是一条从来没写进去过的留痕
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的三件事】
--   ① 建单写【三张表】:单头、单行、'created' 留痕 —— 在同一个事务里。
--      B 臂三样一起数。此前那条留痕【一次都没有写进去过】(客户端直插被 RLS
--      拒,而错误被丢弃),线上 SO-2026-0001 至今没有它。
--   ② 侧门是关着的:持 module.sales.edit 的 authenticated 【直插不进】单头与
--      单行。E 臂切库角色去撞(不切就是空话 —— fixture 26 的老课),
--      F 臂把策略【加回去】证明 E 臂真的靠那条策略在挡,而不是别的东西顺带挡住。
--   ③ 拒绝就是【什么都没写】。D 臂在一张多行的单上让第三行坏掉,然后断言
--      单头一张都没多 —— "整个事务"这句话必须被证明,而不是被相信。
--
-- 各臂:
--   A 前提:门在;两条 INSERT 策略确实【不存在】
--   B 建单:单头 + N 行 + 'created' 留痕,行号连号,返回的 code 与库里一致
--   C 六条拒绝各自按名 + 每条的正向对照
--   D 一行坏掉 = 一张单都不留(单头计数前后相等)
--   E 侧门:authenticated 直插单头 / 单行【都被拒】
--   F 注入:把 INSERT 策略加回去 → 侧门当场打开(证明 E 臂有牙)
--
-- 日期无关。自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_cust uuid; v_cust2 uuid; v_mat uuid; v_mat2 uuid; v_ccy text;
    v_res jsonb; v_id uuid; v_code text;
    v_n int; v_before int; v_after int; v_ok boolean; v_msg text;
    d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-65', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ65-C1', 'fixture 65 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO customers (code, legal_name, country, deleted_at)
    VALUES ('ZZ65-C2', 'fixture 65 deleted customer', 'SG', now()) RETURNING id INTO v_cust2;
    INSERT INTO materials (code, name, category, unit)
    VALUES ('ZZFIX65-A', 'f65 a', '产出-金属', 'kg') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, category, unit)
    VALUES ('ZZFIX65-B', 'f65 b', '产出-金属', 'kg') RETURNING id INTO v_mat2;

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    IF to_regprocedure('public.create_sales_order(uuid,date,text,numeric,jsonb,text,text)') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 65A 失败:create_sales_order 不在';
    END IF;
    -- 【那两条 INSERT 策略必须确实不存在】E 臂靠的就是它们不在;若哪天有人
    -- 把它们加回来,E 臂会因为"另一个理由"通过或失败,而这一条当场点名。
    SELECT count(*) INTO v_n FROM pg_policies
     WHERE schemaname = 'public' AND tablename IN ('sales_orders','sales_order_lines') AND cmd = 'INSERT';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 65A 失败:sales_orders/sales_order_lines 上不该有 INSERT 策略,实得 % 条 —— 侧门开着,那扇门就不是唯一的门', v_n;
    END IF;

    -- ══════════ B. 建单:三张表一起写 ═══════════════════════════════════════
    v_res := create_sales_order(v_cust, d, v_ccy, 1,
        jsonb_build_array(
            jsonb_build_object('material_id', v_mat,  'quantity', 10, 'unit_price', 5),
            jsonb_build_object('material_id', v_mat2, 'quantity', 20, 'unit_price', 7)),
        'fixture 65');
    v_id := (v_res->>'id')::uuid;
    v_code := v_res->>'code';

    SELECT count(*) INTO v_n FROM sales_orders WHERE id = v_id AND code = v_code AND status = 'draft';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 65B 失败:单头没写成(或返回的 code 与库里对不上)';
    END IF;
    SELECT count(*) INTO v_n FROM sales_order_lines WHERE sales_order_id = v_id;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 65B 失败:应当写出 2 行,实得 %', v_n;
    END IF;
    -- 行号连号,而且与传入顺序一致
    SELECT count(*) INTO v_n FROM sales_order_lines
     WHERE sales_order_id = v_id AND ((line_no = 1 AND material_id = v_mat AND quantity = 10)
                                   OR (line_no = 2 AND material_id = v_mat2 AND quantity = 20));
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 65B 失败:行号没有按传入顺序连号';
    END IF;
    -- 【这一条就是整支迁移的起因】
    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = v_id AND change_type = 'created';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 65B 失败:建单必须留下【恰好一行】created 留痕,实得 % —— 这正是 SO-1 漏掉、线上至今缺失的那一行', v_n;
    END IF;

    -- ══════════ C. 六条拒绝,各自按名,两个方向都走 ═══════════════════════════
    -- ① 客户无效(软删的客户同样不算)
    BEGIN
        PERFORM create_sales_order(v_cust2, d, v_ccy, 1,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1, 'unit_price', 1)));
        RAISE EXCEPTION 'FIXTURE 65C 失败:软删客户不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_CREATE_CUSTOMER_INVALID%' THEN RAISE; END IF;
    END;
    -- ② 订单日必填
    BEGIN
        PERFORM create_sales_order(v_cust, NULL, v_ccy, 1,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1, 'unit_price', 1)));
        RAISE EXCEPTION 'FIXTURE 65C 失败:订单日空着不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'ORDER_DATE_REQUIRED%' THEN RAISE; END IF;
    END;
    -- ③ 币种不认识
    BEGIN
        PERFORM create_sales_order(v_cust, d, 'ZZZ', 1,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1, 'unit_price', 1)));
        RAISE EXCEPTION 'FIXTURE 65C 失败:不存在的币种不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'CURRENCY_INVALID%' THEN RAISE; END IF;
    END;
    -- ④ 汇率(【0 与 NULL 都拒】—— FIN-35:汇率的默认值只能是一个假设)
    BEGIN
        PERFORM create_sales_order(v_cust, d, v_ccy, 0,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1, 'unit_price', 1)));
        RAISE EXCEPTION 'FIXTURE 65C 失败:汇率 0 不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_CREATE_FX_INVALID%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM create_sales_order(v_cust, d, v_ccy, NULL,
            jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1, 'unit_price', 1)));
        RAISE EXCEPTION 'FIXTURE 65C 失败:汇率 NULL 不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_CREATE_FX_INVALID%' THEN RAISE; END IF;
    END;
    -- ⑤ 没有行(空数组与 NULL 都算)
    BEGIN
        PERFORM create_sales_order(v_cust, d, v_ccy, 1, '[]'::jsonb);
        RAISE EXCEPTION 'FIXTURE 65C 失败:空行数组不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_CREATE_NO_LINES%' THEN RAISE; END IF;
    END;
    -- ⑥ 行不合法,而且【点名第几行、哪一格】
    BEGIN
        PERFORM create_sales_order(v_cust, d, v_ccy, 1,
            jsonb_build_array(
                jsonb_build_object('material_id', v_mat, 'quantity', 1, 'unit_price', 1),
                jsonb_build_object('material_id', v_mat, 'quantity', 0, 'unit_price', 1)));
        RAISE EXCEPTION 'FIXTURE 65C 失败:数量为 0 的行不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        IF v_msg NOT LIKE 'SO_CREATE_LINE_INVALID%' THEN RAISE; END IF;
        IF split_part(v_msg, '|', 2) <> '2' OR split_part(v_msg, '|', 3) <> 'quantity' THEN
            RAISE EXCEPTION 'FIXTURE 65C 失败:拒绝要点名【第 2 行的 quantity】,实得 %', v_msg;
        END IF;
    END;
    -- 正向对照:六条各自把那一个毛病改掉就通(否则"永远拒绝"也能通过本臂)
    PERFORM create_sales_order(v_cust, d, v_ccy, 1,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 1, 'unit_price', 1)));

    -- ══════════ D. 一行坏掉 = 一张单都不留 ══════════════════════════════════
    -- 【"同一个事务"这句话必须被证明】第三行坏掉时,前两行与单头都已经 INSERT
    -- 过了;函数抛异常回滚整个语句,于是单头计数前后必须相等。
    SELECT count(*) INTO v_before FROM sales_orders;
    BEGIN
        PERFORM create_sales_order(v_cust, d, v_ccy, 1,
            jsonb_build_array(
                jsonb_build_object('material_id', v_mat,  'quantity', 3, 'unit_price', 1),
                jsonb_build_object('material_id', v_mat2, 'quantity', 4, 'unit_price', 1),
                jsonb_build_object('material_id', gen_random_uuid(), 'quantity', 5, 'unit_price', 1)));
        RAISE EXCEPTION 'FIXTURE 65D 失败:第三行的物料不存在,不该建得出单';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'SO_CREATE_LINE_INVALID%' THEN RAISE; END IF;
    END;
    SELECT count(*) INTO v_after FROM sales_orders;
    IF v_after <> v_before THEN
        RAISE EXCEPTION 'FIXTURE 65D 失败:一行坏掉之后仍留下了单头(% → %)—— "整张单在一个事务里"这句话不成立', v_before, v_after;
    END IF;

    -- ══════════ E. 侧门:直插【进不去】════════════════════════════════════════
    -- README 第 6 条:fixture 以 postgres 跑,RLS 对超级用户不生效 ——
    -- 不切角色,下面这两条断言就是空话(fixture 26 的第一版正是这么空转的)。
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_ok := false;
    BEGIN
        INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
        VALUES ('ZZ65-SIDE', v_cust, d, v_ccy, 1);
        v_ok := true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_ok THEN
        RAISE EXCEPTION 'FIXTURE 65E 失败:持 sales.edit 的 authenticated 【直插进了】单头 —— 那扇门就不是唯一的门,可以再插出一张没有留痕的单';
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    v_ok := false;
    BEGIN
        INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
        VALUES (v_id, 99, v_mat, 1, 1);
        v_ok := true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_ok THEN
        RAISE EXCEPTION 'FIXTURE 65E 失败:authenticated 【直插进了】单行';
    END IF;

    -- ══════════ F. 注入:把 INSERT 策略加回去 → 侧门当场打开 ══════════════════
    -- 【为什么要这一臂】E 臂只证明"插不进去",没有证明【是那条策略缺席在挡】。
    -- 冻结守卫、外键、CHECK 都可能顺带挡住一次插入,而那样的话 E 臂就是在
    -- 为错的理由通过。加回策略之后必须【插得进去】,这一条才成立。
    EXECUTE $inj$
        CREATE POLICY "sales_orders insert by permission" ON public.sales_orders
            AS PERMISSIVE FOR INSERT TO authenticated
            WITH CHECK (has_permission('module.sales.edit'::text));
    $inj$;
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_ok := false;
    BEGIN
        INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
        VALUES ('ZZ65-SIDE2', v_cust, d, v_ccy, 1);
        v_ok := true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 65F 失败:把 INSERT 策略加回去之后【仍然】插不进(%)—— 说明 E 臂一直靠别的东西挡着,那两条断言在空转', v_msg;
    END IF;
    -- 而这张侧门插出来的单,正是这一刀要消灭的形状:【没有留痕】
    SELECT count(*) INTO v_n FROM sales_order_history h
      JOIN sales_orders o ON o.id = h.sales_order_id
     WHERE o.code = 'ZZ65-SIDE2';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 65F 失败:侧门插出来的单竟然有留痕 —— 那说明留痕不是由建单函数写的,本臂的推论不成立';
    END IF;
END $$;
ROLLBACK;

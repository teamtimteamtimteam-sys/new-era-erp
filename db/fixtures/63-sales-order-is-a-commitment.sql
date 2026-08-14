-- 63 销售订单(SO-1):确认之后就冻住,而【允许去哪里】是逐个状态写出来的
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的三件事】
--   ① 确认即冻结,而【冻结的守卫与编辑路径同时出生】—— 草稿随便改,确认之后
--      按名拒 SO_CONFIRMED_IMMUTABLE|<字段>。D 臂两个方向各走一次:冻的真冻,
--      没冻的真能改(只冻一半与全冻都是错的,而全冻会让备注也改不了)。
--   ② 状态机是【一张允许表】,不是一句"除了 X 都行"。E 臂逐条走:允许的通,
--      不允许的按名拒。终态就是终态。
--   ③ 对一个被信用冻结的客户【不能做承诺】。F 臂两个方向:冻结时拒,解冻后通 ——
--      只断言"拒"的实现,一个永远拒绝的函数也能通过。
--
-- 各臂:
--   A 前提:四张表在;编号连号;客户没有被冻结
--   B 建单 + 建行:行的出处按 FIN-26 成对(不成对当场被约束拒)
--   C 确认:空单不许确认;有行才通
--   D 冻结:确认后改商业字段按名拒;备注仍可改;草稿仍可改
--   E 状态机:closed/cancelled 是终态;作废必须带理由
--     (SO-3b:confirmed → closed 已改为【按名拒绝】—— closed 要求发完货;
--      closed 的可达性与终态性移到 fixture 68 J 臂,只有它走得到 shipped)
--   F 信用冻结:冻结时确认被拒,解冻后同一张单确认得了
--   G 签发:版本从 1 递增,sha256 记下;重新签发追加;UPDATE/DELETE 按名拒
--   I 权限:sales 读得到;无码读不到;【持 finance 而无 sales.view 也读不到】
--   H 注入:把冻结守卫上的 customer_id 那一条拿掉 → D 臂当场失守
--
-- 日期无关。自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    u_sales uuid := gen_random_uuid();   -- 只有 module.sales.view
    u_fin   uuid := gen_random_uuid();   -- 只有 module.finance.*(【没有】 sales.view)
    r_all uuid; r_sales uuid; r_fin uuid; v_cust uuid; v_cust2 uuid; v_mat uuid; v_ccy text;
    so1 uuid; so2 uuid; v_code text; v_code2 uuid;
    v_n int; v_ok boolean; v_msg text; v_ver int; d date := CURRENT_DATE;
    SHA text := repeat('a', 64);
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-63', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    -- SO-1-fu:两个【只读一种码】的读者,用来钉住权限真的切过去了
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-63-sales', 'f', 'f', true) RETURNING id INTO r_sales;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_sales, 'module.sales.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_sales, r_sales);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-63-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_fin, 'module.finance.view'), (r_fin, 'module.finance.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ63-C1', 'fixture 63 customer', 'SG') RETURNING id INTO v_cust;
    INSERT INTO customers (code, legal_name, country, credit_hold)
    VALUES ('ZZ63-C2', 'fixture 63 held customer', 'SG', true) RETURNING id INTO v_cust2;
    INSERT INTO materials (code, name, category, unit)
    VALUES ('ZZFIX63-M', 'f63 material', '产出-黑粉', 'kg') RETURNING id INTO v_mat;

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    v_code := next_sales_order_code(d);
    IF v_code NOT LIKE 'SO-' || EXTRACT(YEAR FROM d)::text || '-%' THEN
        RAISE EXCEPTION 'FIXTURE 63A 失败:编号格式应当是 SO-年份-序号,实得 %', v_code;
    END IF;
    IF (SELECT credit_hold FROM customers WHERE id = v_cust) THEN
        RAISE EXCEPTION 'FIXTURE 63A 失败:前提不成立 —— 主客户不该是冻结状态';
    END IF;

    -- ══════════ B. 建单 + 建行 ═══════════════════════════════════════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (v_code, v_cust, d, v_ccy, 1) RETURNING id INTO so1;

    -- 【连号】下一号必须比刚才那个大 1
    IF next_sales_order_code(d) <> 'SO-' || EXTRACT(YEAR FROM d)::text || '-'
                                  || LPAD((split_part(v_code,'-',3)::int + 1)::text, 4, '0') THEN
        RAISE EXCEPTION 'FIXTURE 63A 失败:编号不连号 —— 建了一张之后下一号应当 +1';
    END IF;

    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so1, 1, v_mat, 100, 12.5);

    -- 出处【成对或都不给】—— 只给一半当场被约束拒
    v_ok := false; v_msg := NULL;
    BEGIN
        INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price, price_source)
        VALUES (so1, 2, v_mat, 5, 1, 'manual');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE '%sales_order_lines_provenance_pairing%';
    END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63B 失败:只给 price_source 不给 provenance 应当被约束拒,实得:%',
            COALESCE(v_msg, '(写进去了)');
    END IF;

    -- ══════════ C. 确认 ═════════════════════════════════════════════════════
    -- 空单不许确认(先建一张空的试)
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust, d, v_ccy, 1) RETURNING id INTO so2;
    v_ok := false; v_msg := NULL;
    BEGIN PERFORM set_sales_order_status(so2, 'confirmed');
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT; v_ok := v_msg LIKE 'SO_NO_LINES|%'; END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63C 失败:没有行的单不该确认得了,实得:%', COALESCE(v_msg, '(确认成功了)');
    END IF;

    PERFORM set_sales_order_status(so1, 'confirmed');
    IF (SELECT status FROM sales_orders WHERE id = so1) <> 'confirmed' THEN
        RAISE EXCEPTION 'FIXTURE 63C 失败:有行的单应当确认得了';
    END IF;

    -- ══════════ D. 冻结:两个方向 ════════════════════════════════════════════
    v_ok := false; v_msg := NULL;
    BEGIN UPDATE sales_orders SET customer_id = v_cust2 WHERE id = so1;
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'SO_CONFIRMED_IMMUTABLE|customer_id|%'; END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63D 失败:确认之后改客户应当按名拒,实得:%', COALESCE(v_msg, '(改成功了)');
    END IF;

    -- 行也冻住(增删改都不行 —— 那是改单,归 SO-1b)
    v_ok := false; v_msg := NULL;
    BEGIN
        INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
        VALUES (so1, 9, v_mat, 1, 1);
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'SO_CONFIRMED_IMMUTABLE|lines|%'; END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63D 失败:确认之后加行应当按名拒,实得:%', COALESCE(v_msg, '(加成功了)');
    END IF;

    -- 【没冻的那一半真的能改】—— 备注不改变这笔交易是什么
    UPDATE sales_orders SET notes = 'still editable after confirm' WHERE id = so1;
    IF (SELECT notes FROM sales_orders WHERE id = so1) IS DISTINCT FROM 'still editable after confirm' THEN
        RAISE EXCEPTION 'FIXTURE 63D 失败:备注不在冻结之列,应当改得动 —— 全冻与只冻一半都是错的';
    END IF;

    -- 草稿仍然随便改
    UPDATE sales_orders SET order_date = d - 1 WHERE id = so2;
    IF (SELECT order_date FROM sales_orders WHERE id = so2) <> d - 1 THEN
        RAISE EXCEPTION 'FIXTURE 63D 失败:草稿的商业字段应当改得动';
    END IF;

    -- ══════════ E. 状态机 ═══════════════════════════════════════════════════
    -- 作废要理由
    v_ok := false; v_msg := NULL;
    BEGIN PERFORM set_sales_order_status(so2, 'cancelled');
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'SO_CANCEL_REASON_REQUIRED|%'; END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63E 失败:作废必须带理由,实得:%', COALESCE(v_msg, '(作废成功了)');
    END IF;
    PERFORM set_sales_order_status(so2, 'cancelled', '客户取消');

    -- 终态没有去处
    FOR v_msg IN SELECT unnest(ARRAY['draft','confirmed','closed']) LOOP
        v_ok := false;
        BEGIN PERFORM set_sales_order_status(so2, v_msg);
        EXCEPTION WHEN OTHERS THEN v_ok := SQLERRM LIKE 'SO_TRANSITION_NOT_ALLOWED|cancelled|%'; END;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'FIXTURE 63E 失败:cancelled 是终态,不该能去 %', v_msg;
        END IF;
    END LOOP;

    -- 【SO-3b 改了这一条 —— 过期,不是回归】此前 confirmed → closed 是允许的;
    -- 发货落地之后,"走完了"要求【发完货】,所以那条路关掉了(closed 只能从
    -- shipped 来)。一张还没发货的订单说自己"走完了",在选项 C 之下是说不通的。
    -- 【closed 可达且是终态】由 fixture 68 的 J 臂钉住 —— 只有它走得到 shipped。
    v_ok := false;
    BEGIN PERFORM set_sales_order_status(so1, 'closed');
    EXCEPTION WHEN OTHERS THEN v_ok := SQLERRM LIKE 'SO_TRANSITION_NOT_ALLOWED|confirmed|closed%'; END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63E 失败:SO-3b 之后 confirmed → closed 应当按名拒绝(closed 要求已发货)';
    END IF;

    -- ══════════ F. 信用冻结:两个方向 ════════════════════════════════════════
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate)
    VALUES (next_sales_order_code(d), v_cust2, d, v_ccy, 1) RETURNING id INTO v_code2;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (v_code2, 1, v_mat, 10, 3);

    v_ok := false; v_msg := NULL;
    BEGIN PERFORM set_sales_order_status(v_code2, 'confirmed');
    EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        v_ok := v_msg LIKE 'SO_CUSTOMER_ON_HOLD|%'; END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63F 失败:对被冻结的客户不该确认得了,实得:%', COALESCE(v_msg, '(确认成功了)');
    END IF;

    -- 【另一个方向】解冻之后同一张单确认得了 —— 否则一个永远拒绝的实现也能通过
    UPDATE customers SET credit_hold = false WHERE id = v_cust2;
    PERFORM set_sales_order_status(v_code2, 'confirmed');
    IF (SELECT status FROM sales_orders WHERE id = v_code2) <> 'confirmed' THEN
        RAISE EXCEPTION 'FIXTURE 63F 失败:解冻之后应当确认得了 —— 只断言"拒"的话,一个永远拒绝的实现也能通过';
    END IF;

    -- ══════════ G. 签发 ═════════════════════════════════════════════════════
    v_ver := (record_so_issue(v_code2, 'so-documents/x-v1.pdf', SHA) ->> 'version')::int;
    IF v_ver <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 63G 失败:第一次签发应当是第 1 版,实得 %', v_ver;
    END IF;
    v_ver := (record_so_issue(v_code2, 'so-documents/x-v2.pdf', SHA) ->> 'version')::int;
    IF v_ver <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 63G 失败:重新签发应当【追加】第 2 版,实得 %', v_ver;
    END IF;
    SELECT count(*) INTO v_n FROM so_issues WHERE sales_order_id = v_code2;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 63G 失败:旧版本必须原样留着(客户手里那份是某个具体版本),实得 % 行', v_n;
    END IF;
    IF (SELECT sha256 FROM so_issues WHERE sales_order_id = v_code2 AND version = 1) <> SHA THEN
        RAISE EXCEPTION 'FIXTURE 63G 失败:sha256 应当原样记下 —— 那是对着记录校验字节的唯一依据';
    END IF;

    FOR v_n IN 1..2 LOOP
        v_ok := false; v_msg := NULL;
        BEGIN
            IF v_n = 1 THEN UPDATE so_issues SET sha256 = repeat('b',64) WHERE sales_order_id = v_code2;
                       ELSE DELETE FROM so_issues WHERE sales_order_id = v_code2; END IF;
        EXCEPTION WHEN OTHERS THEN GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
            v_ok := v_msg = 'SO_ISSUE_IMMUTABLE'; END;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'FIXTURE 63G 失败:签发档只增不改,第 % 种改动应当按名拒,实得:%',
                v_n, COALESCE(v_msg, '(改成功了)');
        END IF;
    END LOOP;

    -- ══════════ I. 权限真的切到 module.sales.* 了(SO-1-fu)═══════════════════
    -- 【只断言"新码能读"是不够的】——那在旧码还留着的情况下同样通过。所以三个
    -- 方向一起钉:sales 读得到、无码读不到、【持 finance 但无 sales.view 也读不到】。
    -- 最后那一条才是"切换真的发生了"的证据。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_sales), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM sales_orders;
    RESET ROLE;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 63I 失败:持 module.sales.view 的读者应当读得到订单';
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM sales_orders;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 63I 失败:持 module.finance.* 但【没有】 module.sales.view 的读者不该读得到订单(实得 % 行)—— 说明策略还挂在 finance 上,切换没真的发生', v_n;
    END IF;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', gen_random_uuid()), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM sales_orders;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 63I 失败:没有任何权限的读者不该读得到订单(实得 % 行)', v_n;
    END IF;

    -- 回到全权限读者,后面的注入臂要用
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ H. 注入:把冻结守卫上的那一条拿掉 → D 臂当场失守 ═══════════════
    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.guard_sales_order_confirmed_immutable()
         RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
        AS $body$
        BEGIN
            IF OLD.status = 'draft' THEN RETURN NEW; END IF;
            IF current_setting('evoltrya.so_status_ctx', true) = '1' THEN RETURN NEW; END IF;
            -- 【被拿掉的那一条】: customer_id
            IF NEW.currency IS DISTINCT FROM OLD.currency THEN
                RAISE EXCEPTION 'SO_CONFIRMED_IMMUTABLE|currency|%', OLD.code;
            END IF;
            RETURN NEW;
        END $body$;
    $inj$;

    v_ok := true;
    BEGIN UPDATE sales_orders SET customer_id = v_cust WHERE id = v_code2;
    EXCEPTION WHEN OTHERS THEN v_ok := false; END;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 63H 失败:注入之后改客户【仍然被拒】—— 说明 D 臂并不依赖那一条,它一直在空转';
    END IF;
END $$;
ROLLBACK;

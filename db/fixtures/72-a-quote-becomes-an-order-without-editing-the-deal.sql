-- 72 报价(SO-4a):转换【逐列】等于报价 —— 转换不许悄悄改这笔交易
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西,以及为什么每一条都需要一个对照】
--
--   ① 【逐列相等,而不是"看起来对"】B 臂把建出来的订单与报价【一列一列】比:
--      客户、币种、汇率、以及每一行的数量、单价、出处两列。
--      **只比"行数对得上"是不够的** —— 一个把单价重算一遍、或者把 provenance
--      丢掉的实现,行数照样对。转换悄悄改了这笔交易,是这一刀唯一真正可怕的
--      失败方式,所以它是逐列断言,而不是一句总额。注入 1 把抄价那一步改成
--      "乘 1.1",B 臂必须当场红。
--   ② 【出处那两列是一个真的坑】create_sales_order 的配对检查问的是【键在不在】,
--      不是值是不是 NULL。无条件把两个键都递过去(值给 NULL)会让 provenance
--      以 jsonb 的 null 字面量写进去 —— 那不是 SQL NULL,于是订单行的配对约束
--      当场违约。C 臂用一条【没有出处】的报价行专门走这条路。
--   ③ 【过期的边界在当天】D 臂:valid_until = 今天【转得了】,= 昨天【拒】。
--      一个把 <= 写成 < 的实现在第一句上死,写反了在第二句上死。
--   ④ 【四条拒绝各自按名】E 臂,每条都配一个对照:拒绝之后【什么都没建】。
--      只断言"抛错了"会被一个"先建单再抛错"的实现骗过去。
--   ⑤ 【converted 之后整个冻住】F 臂,表头与行两边都试,而且走【直连】——
--      守卫必须是触发器,不是函数里的一句客气话(fixture 52 C 臂写过这条区别)。
--   ⑥ 【留痕不是"想写才写"】G 臂:直连插一张报价,'created' 那一行必须自己出现。
--      SO-1 的建单就是在这里栽的(留痕那条 insert 被 RLS 拒、错误被丢掉,
--      线上 SO-2026-0001 至今缺着那一行)。
--
-- 【注入臂放在最后】fixture 64/69/71 付过这笔账:注入种下的行会污染后面各臂。
--   注入 1:抄价那一步乘 1.1 → 逐列断言必须红(证明 B 臂不是空转)。
--   注入 2:把 quote_is_expired 换成恒 false → 过期的报价当场转得了单
--           (证明 D 臂那条拒绝读的确实是那一处推导)。
--
-- 自带数据(README 第 2 条)。期间锁显式设 NULL(第 5 条)—— 转换会调
-- create_sales_order,而它自己不过账,但订单日仍要落在一个没锁的期间里。
-- 汇率取【非 1】的 1.25:两边一致时"抄对了没有"这种断言什么都不证明。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_cust uuid; v_mat uuid; v_mat2 uuid;
    qB uuid; qC uuid; qD1 uuid; qD2 uuid; qE uuid; qF uuid; qG uuid;
    v_res jsonb; v_msg text; v_denied boolean; v_n int; v_before int;
    v_order uuid; v_ocode text;
    d date := CURRENT_DATE;
    FX constant numeric := 1.25;
    PROV constant jsonb := jsonb_build_object('basis','spot','metal','Ni','note','fixture 72');
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-72', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;

    -- 【一个"还没开户"的客户 —— 而这不是布景】customers 只强制 legal_name 与
    -- country,status 默认 'draft' 且全库没有一处按它把关。报价因此不逼人先
    -- 走完开户,而这一行就是那句话的断言。
    INSERT INTO customers (legal_name, country)
    VALUES ('fixture 72 prospect', 'SG') RETURNING id INTO v_cust;
    IF (SELECT status FROM customers WHERE id = v_cust) <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 72 前置失败:新客户应当是 draft —— 报价不该要求先开户';
    END IF;

    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZFIX72-M', 'f72 material', 'battery_material', true, 'kg') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, unit)
    VALUES ('ZZFIX72-M2', 'f72 material 2', 'battery_material', true, 'kg') RETURNING id INTO v_mat2;

    -- ══════════ A. 前提 + 目录 ═══════════════════════════════════════════════
    IF to_regprocedure('public.convert_quote(uuid,date)') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 72A 失败:convert_quote 不在';
    END IF;
    -- 【取号器靠调不到】而建报价走直连 —— 所以号必须由触发器填,不由客户端取
    IF has_function_privilege('authenticated', 'public.next_quote_code(date)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 72A 失败:next_quote_code 对 authenticated 可执行 —— 那等于任何登录用户都能烧号';
    END IF;
    -- 【一处推导:转换的拒绝与视图读的是同一个函数】抄一份过去,两边会在写下
    -- 的那天一致、此后各自漂移(CMP-1 的证书过期就是被写了两遍的那一对)。
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'convert_quote') NOT LIKE '%quote_is_expired(%' THEN
        RAISE EXCEPTION 'FIXTURE 72A 失败:convert_quote 没有读 quote_is_expired';
    END IF;
    IF pg_get_viewdef('public.quote_status'::regclass) NOT LIKE '%quote_is_expired(%' THEN
        RAISE EXCEPTION 'FIXTURE 72A 失败:quote_status 没有读 quote_is_expired';
    END IF;
    -- 【转换不重写建单,它调用那扇门】
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'convert_quote') NOT LIKE '%create_sales_order(%' THEN
        RAISE EXCEPTION 'FIXTURE 72A 失败:convert_quote 没有调用 create_sales_order —— 那意味着建单被重写了一遍';
    END IF;

    -- ══════════ B. 转换:逐列等于报价 ════════════════════════════════════════
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate, notes, terms_text)
    VALUES (v_cust, d, d + 30, 'USD', FX, 'quote notes', 'quote terms') RETURNING id INTO qB;
    -- 一行【带出处】,一行【不带】—— 两条路在同一张单上都走到
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price,
                             price_source, price_provenance, notes)
    VALUES (qB, 1, v_mat, 12, 34.5, 'computed', PROV, 'line one');
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
    VALUES (qB, 2, v_mat2, 7, 10.25);

    PERFORM record_qt_issue(qB, 'p1', repeat('a', 64));
    IF (SELECT status FROM quotes WHERE id = qB) <> 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 72B 前置失败:第一次签发应当把 draft 翻成 issued,实得 %',
            (SELECT status FROM quotes WHERE id = qB);
    END IF;

    v_res := convert_quote(qB, d + 1);
    v_order := (v_res->>'sales_order_id')::uuid;
    v_ocode := v_res->>'sales_order_code';

    -- 【表头逐列】客户、币种、汇率抄过来;订单日【不抄】,它是递进来的那一天。
    IF NOT EXISTS (
        SELECT 1 FROM sales_orders so JOIN quotes q ON q.id = qB
         WHERE so.id = v_order
           AND so.customer_id = q.customer_id
           AND so.currency    = q.currency
           AND so.fx_rate     = q.fx_rate
           AND so.notes       IS NOT DISTINCT FROM q.notes
           AND so.terms_text  IS NOT DISTINCT FROM q.terms_text) THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:订单表头没有逐列等于报价(客户/币种/汇率/备注/条款)—— 转换不许悄悄改这笔交易';
    END IF;
    IF (SELECT order_date FROM sales_orders WHERE id = v_order) <> d + 1 THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:订单日应当是【递进来的那一天】而不是报价日 —— 抄报价日就是把一次今天做出的承诺记到过去';
    END IF;

    -- 【明细逐列 —— 这一段是本 fixture 的心脏】
    -- 数量、单价、出处两列全部对上,而且【一行不多、一行不少】。
    SELECT count(*) INTO v_n
      FROM quote_lines ql
      JOIN sales_order_lines sol
        ON sol.sales_order_id = v_order AND sol.line_no = ql.line_no
     WHERE ql.quote_id = qB
       AND sol.material_id      = ql.material_id
       AND sol.quantity         = ql.quantity
       AND sol.unit_price       = ql.unit_price
       AND sol.price_source     IS NOT DISTINCT FROM ql.price_source
       AND sol.price_provenance IS NOT DISTINCT FROM ql.price_provenance
       AND sol.notes            IS NOT DISTINCT FROM ql.notes;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:两行都应当【逐列】等于报价行(数量/单价/出处两列/备注),实得 % 行对得上 —— 只对行数是不够的:重算过单价的实现行数照样对',
            v_n;
    END IF;
    IF (SELECT count(*) FROM sales_order_lines WHERE sales_order_id = v_order) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:订单不该多出行';
    END IF;

    -- 【那条没有出处的行:必须是两个 SQL NULL,不是 jsonb 的 null 字面量】
    -- 递键不递值会让 provenance 写成 jsonb null,而那不是 SQL NULL ——
    -- 订单行的配对约束会当场违约(这一句是那个坑的断言)。
    IF NOT EXISTS (SELECT 1 FROM sales_order_lines
                    WHERE sales_order_id = v_order AND line_no = 2
                      AND price_source IS NULL AND price_provenance IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 72C 失败:没有出处的行,两列都必须是 SQL NULL —— jsonb 的 null 字面量会让订单行的配对约束违约';
    END IF;

    -- 【两边各留一行痕】
    IF NOT EXISTS (SELECT 1 FROM quote_history WHERE quote_id = qB AND change_type = 'converted'
                     AND detail = v_ocode) THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:报价这一侧应当留下 converted 那一行,并点名订单号';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sales_order_history WHERE sales_order_id = v_order
                     AND change_type = 'converted_from_quote'
                     AND detail = (SELECT code FROM quotes WHERE id = qB)) THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:订单这一侧应当留下 converted_from_quote 那一行 —— 从订单看不出出处,正是三个月后有人会问的第一个问题';
    END IF;
    -- 【只写一次的那一列】
    IF (SELECT converted_order_id FROM quotes WHERE id = qB) <> v_order
       OR (SELECT status FROM quotes WHERE id = qB) <> 'converted' THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:报价应当 converted 并指着那张订单';
    END IF;
    -- 【建出来的订单与手工建的没有区别】它是 draft、有 created 留痕、没有任何
    -- 特殊标记 —— 后续的确认/开票/发货照常走,信用闸也照常在确认那一步。
    IF (SELECT status FROM sales_orders WHERE id = v_order) <> 'draft' THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:转换出来的应当是一张【草稿】订单 —— 确认是另一次动作,信用冻结的闸在那里';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sales_order_history
                    WHERE sales_order_id = v_order AND change_type = 'created') THEN
        RAISE EXCEPTION 'FIXTURE 72B 失败:转换出来的订单也该有 created 留痕(它是 create_sales_order 建的,不是另一条路)';
    END IF;

    -- ══════════ D. 过期:边界在当天 ══════════════════════════════════════════
    -- 【= 今天,转得了】"有效到 8 月 15 日"的字面意思就是 15 日当天还算数。
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cust, d - 5, d, 'USD', FX) RETURNING id INTO qD1;
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
    VALUES (qD1, 1, v_mat, 1, 1);
    PERFORM record_qt_issue(qD1, 'p1', repeat('b', 64));
    IF (SELECT expired FROM quote_status WHERE quote_id = qD1) THEN
        RAISE EXCEPTION 'FIXTURE 72D 失败:有效期【等于今天】的报价不该算过期';
    END IF;
    PERFORM convert_quote(qD1, d);

    -- 【= 昨天,拒】
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cust, d - 5, d - 1, 'USD', FX) RETURNING id INTO qD2;
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
    VALUES (qD2, 1, v_mat, 1, 1);
    PERFORM record_qt_issue(qD2, 'p1', repeat('c', 64));
    IF NOT (SELECT expired FROM quote_status WHERE quote_id = qD2) THEN
        RAISE EXCEPTION 'FIXTURE 72D 失败:有效期是昨天的报价应当算过期';
    END IF;
    IF (SELECT convertible FROM quote_status WHERE quote_id = qD2) THEN
        RAISE EXCEPTION 'FIXTURE 72D 失败:过期的报价 convertible 应当是 false —— 屏幕上禁用的理由要与服务端拒绝的名字对得上';
    END IF;
    v_before := (SELECT count(*) FROM sales_orders);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM convert_quote(qD2, d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'QT_EXPIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 72D 失败:过期的报价应当按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(转成功了)');
    END IF;
    -- 【拒了就是什么都没建】—— 只断言"抛错了"会被"先建单再抛错"骗过去
    IF (SELECT count(*) FROM sales_orders) <> v_before THEN
        RAISE EXCEPTION 'FIXTURE 72D 失败:被拒的转换不该留下一张订单';
    END IF;

    -- ══════════ E. 另外三条拒绝,各自按名 ═════════════════════════════════════
    -- ① 草稿(还没签发)
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cust, d, d + 30, 'USD', FX) RETURNING id INTO qE;
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
    VALUES (qE, 1, v_mat, 1, 1);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM convert_quote(qE, d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'QT_NOT_ISSUED|%|draft' THEN
        RAISE EXCEPTION 'FIXTURE 72E 失败:草稿转不了单(还没发给任何人),实得 %',
            COALESCE(v_msg, '(转成功了)');
    END IF;

    -- ② 已经转过 —— 而且消息要【点名转成了哪一张单】
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM convert_quote(qB, d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> format('QT_ALREADY_CONVERTED|%s|%s',
                                       (SELECT code FROM quotes WHERE id = qB), v_ocode) THEN
        RAISE EXCEPTION 'FIXTURE 72E 失败:已转过的报价应当按名拒【并点名那张订单】,实得 % —— 不点名的话人会再转一次去找它',
            COALESCE(v_msg, '(又转了一次)');
    END IF;

    -- ③ 谢绝了的:先试无理由(拒),再谢绝,再试转换(拒)
    PERFORM record_qt_issue(qE, 'p1', repeat('d', 64));
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decline_quote(qE, '   ');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'QT_DECLINE_REASON_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 72E 失败:谢绝要写理由,实得 %', COALESCE(v_msg, '(谢绝成功了)');
    END IF;
    PERFORM decline_quote(qE, '客户选了别家');
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM convert_quote(qE, d);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'QT_DECLINED|%' THEN
        RAISE EXCEPTION 'FIXTURE 72E 失败:谢绝了的报价转不了单,实得 %', COALESCE(v_msg, '(转成功了)');
    END IF;
    -- 谢绝了的也签发不了(那两个状态说的是"这件事结束了")
    v_denied := false;
    BEGIN PERFORM record_qt_issue(qE, 'p2', repeat('e', 64));
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 72E 失败:谢绝了的报价不该还能签发';
    END IF;

    -- ══════════ F. converted 之后整个冻住 —— 【走直连,证明守卫是触发器】═════
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE quotes SET notes = '偷偷改' WHERE id = qB;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'QT_CONVERTED_IMMUTABLE|row|%' THEN
        RAISE EXCEPTION 'FIXTURE 72F 失败:转过的报价表头应当被【触发器】按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE quote_lines SET unit_price = 1 WHERE quote_id = qB AND line_no = 1;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'QT_CONVERTED_IMMUTABLE|lines|%' THEN
        RAISE EXCEPTION 'FIXTURE 72F 失败:转过的报价【行】也应当冻住 —— 报价的内容全在行上,只冻表头等于没冻。实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;

    -- 【对照:没转过的报价改得动】否则这一臂只证明了"什么都改不动"
    UPDATE quotes SET notes = 'still negotiating' WHERE id = qD2;
    UPDATE quote_lines SET unit_price = 2 WHERE quote_id = qD2 AND line_no = 1;
    IF (SELECT unit_price FROM quote_lines WHERE quote_id = qD2 AND line_no = 1) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 72F 失败:没转过的报价应当改得动 —— 谈判中的东西上锁只会逼出"作废重开"那种假动作';
    END IF;

    -- ══════════ G. 留痕不是"想写才写";签发版本与"改过"的信号 ═════════════════
    -- 【直连插一张报价,created 那一行必须自己出现】SO-1 的建单就是在这里栽的。
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cust, d, d + 7, 'USD', FX) RETURNING id INTO qG;
    RESET ROLE;
    IF NOT EXISTS (SELECT 1 FROM quote_history WHERE quote_id = qG AND change_type = 'created') THEN
        RAISE EXCEPTION 'FIXTURE 72G 失败:直连插的报价也必须自己长出 created 留痕 —— 留痕不能是"想写才写"的(SO-2026-0001 至今缺着那一行)';
    END IF;
    IF (SELECT code FROM quotes WHERE id = qG) NOT LIKE 'QT-%' THEN
        RAISE EXCEPTION 'FIXTURE 72G 失败:单号应当由触发器填上 —— 客户端拿不到取号器';
    END IF;

    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
    VALUES (qG, 1, v_mat, 3, 5);
    PERFORM record_qt_issue(qG, 'p1', repeat('f', 64));
    -- 刚签发完,不该报"签发之后又改过"
    IF (SELECT amended_since_issue FROM quote_status WHERE quote_id = qG) THEN
        RAISE EXCEPTION 'FIXTURE 72G 失败:刚签发完不该报"签发之后又改过"';
    END IF;
    -- 【改一行明细,信号必须亮】—— 表头没动过,亮不亮全靠那个回 touch 触发器
    PERFORM pg_sleep(0.01);
    UPDATE quote_lines SET quantity = 4 WHERE quote_id = qG AND line_no = 1;
    IF NOT (SELECT amended_since_issue FROM quote_status WHERE quote_id = qG) THEN
        RAISE EXCEPTION 'FIXTURE 72G 失败:改了明细之后"签发之后又改过"必须亮 —— 只看表头 updated_at 会对最常见的一种改动视而不见';
    END IF;
    -- 重新签发:版本追加,状态不动
    PERFORM record_qt_issue(qG, 'p2', repeat('0', 64));
    IF (SELECT max(version) FROM qt_issues WHERE quote_id = qG) <> 2
       OR (SELECT status FROM quotes WHERE id = qG) <> 'issued' THEN
        RAISE EXCEPTION 'FIXTURE 72G 失败:重新签发应当追加第 2 版而状态不动';
    END IF;
    v_denied := false;
    BEGIN UPDATE qt_issues SET sha256 = repeat('9', 64) WHERE quote_id = qG AND version = 1;
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 72G 失败:签发档只增不改 —— 客户手里那份是某个具体版本';
    END IF;

    -- ══════════ 注入 1:抄价那一步乘 1.1 ═════════════════════════════════════
    -- B 臂的逐列断言必须能失败。把 convert_quote 换成一个"顺手把单价提 10%"的
    -- 版本 —— 那正是"转换悄悄改了这笔交易"的样子,而行数照样对得上。
    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.convert_quote(p_quote_id uuid, p_order_date date)
         RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
         SET search_path TO 'public', 'pg_temp'
        AS $f$
        DECLARE
            v_q quotes%ROWTYPE; v_lines jsonb := '[]'::jsonb; v_l record; v_res jsonb;
        BEGIN
            SELECT * INTO v_q FROM quotes WHERE id = p_quote_id;
            FOR v_l IN SELECT * FROM quote_lines WHERE quote_id = p_quote_id ORDER BY line_no
            LOOP
                -- 【被换掉的那一句】:单价乘 1.1
                v_lines := v_lines || jsonb_build_object(
                    'material_id', v_l.material_id, 'quantity', v_l.quantity,
                    'unit_price', round(v_l.unit_price * 1.1, 2));
            END LOOP;
            v_res := create_sales_order(v_q.customer_id, p_order_date, v_q.currency,
                                        v_q.fx_rate, v_lines, v_q.notes, v_q.terms_text);
            RETURN jsonb_build_object('sales_order_id', (v_res->>'id')::uuid,
                                      'sales_order_code', v_res->>'code');
        END;
        $f$;
    $inj$;

    INSERT INTO quotes (customer_id, quote_date, valid_until, currency, fx_rate)
    VALUES (v_cust, d, d + 30, 'USD', FX) RETURNING id INTO qF;
    INSERT INTO quote_lines (quote_id, line_no, material_id, quantity, unit_price)
    VALUES (qF, 1, v_mat, 10, 20);
    PERFORM record_qt_issue(qF, 'p1', repeat('1', 64));
    v_res := convert_quote(qF, d);
    v_order := (v_res->>'sales_order_id')::uuid;
    SELECT count(*) INTO v_n
      FROM quote_lines ql
      JOIN sales_order_lines sol
        ON sol.sales_order_id = v_order AND sol.line_no = ql.line_no
     WHERE ql.quote_id = qF AND sol.unit_price = ql.unit_price;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 72 注入1 失败:把抄价换成"乘 1.1"之后,单价【仍然】逐列对得上 —— 说明 B 臂那条逐列断言在空转';
    END IF;
    IF (SELECT count(*) FROM sales_order_lines WHERE sales_order_id = v_order) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 72 注入1 失败:注入之后订单行数应当仍然对得上 —— 这一句正是"只比行数是不够的"那句话的证据';
    END IF;

    -- ══════════ 注入 2:把过期判据换成恒 false ════════════════════════════════
    -- D 臂那条拒绝必须读的是那一处推导。换掉它之后,昨天到期的报价必须当场
    -- 转得了单 —— 转不了就说明 D 臂一直靠别的东西挡着。
    EXECUTE $inj2$
        CREATE OR REPLACE FUNCTION public.quote_is_expired(p_valid_until date)
         RETURNS boolean LANGUAGE sql STABLE
        AS $f$ SELECT false $f$;
    $inj2$;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM convert_quote(qD2, d);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 72 注入2 失败:把 quote_is_expired 换成恒 false 之后,昨天到期的报价【仍然】转不了(%)—— 说明 D 臂那条拒绝读的不是那一处推导',
            v_msg;
    END IF;
END $$;
ROLLBACK;

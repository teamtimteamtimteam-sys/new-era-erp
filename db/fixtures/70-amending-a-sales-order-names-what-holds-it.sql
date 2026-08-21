-- 70 销售订单改单(SO-1b):三条下限各自【按名】拒,而工作的那条路是当成一条路证明的
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的东西,以及为什么每一条都需要一个对照】
--
--   ① 每一条拒绝都【按名】给出,而且都配一个【正例】。只测拒绝的 fixture 会被
--      一个"什么都不许改"的实现全部通过 —— 那正是 SO-1b 之前的真实状态
--      (确认之后单行一律 SO_CONFIRMED_IMMUTABLE|lines)。所以 C/E/G 三臂各自
--      带着一次【成功的改动】,E 臂更是把"作废发票 → 再改"整条路走通:
--      一条出路只有真的走过一遍,才算得上是一条出路。
--   ② 【边界】F 臂:已发 8 的行,7 拒 SO_LINE_BELOW_SHIPPED、8 拒
--      SO_AMEND_LINE_INVOICED。两条【不同】的拒绝,证明下限确实落在 8 上 ——
--      一个把 < 写成 <= 的实现会在 8 上吐出 BELOW_SHIPPED,当场红。
--      (为什么 8 不是"通过":选项 C 先开票后发货,所以发过货的行必然坐在一张
--       在册发票上,而那张票发过货就作废不了 —— 短装收尾要的是【贷项凭证】,
--       它还不存在。系统该做的是按名拒并说出是哪张票挡着。见迁移抬头。)
--   ③ 【软下限绝不自动释放】G 臂在拒绝之后【断言那条预留还活着】。一个"顺手
--      释放掉再改"的实现会让前面每一条断言都通过,而它悄悄替操作员做掉了
--      "放弃这个承诺"这个决定 —— 与调高信用额度让告警安静同族。
--   ④ 【§0(b) 两个方向】D 臂:直连改 notes/terms_text 现在被【触发器】拒,
--      而走改单那条路成功【并且留下一行带理由的历史】。少了任何一个方向,
--      这一刀就只剩一半:只堵不开是把伤口缝上,只开不堵是给已经通着的路加门面。
--   ⑤ 【草稿的编辑不留改单历史】B 臂。它不是第二条规则,是同一个机制的推论
--      (草稿态不设上下文标记,而留痕触发器只在标记为 '1' 时写行)。
--   ⑥ 【一处推导,两个消费方】A 臂用目录断言 ship_order 与 amend_sales_order
--      读的是【同一个】sales_order_fulfilment_status,H 臂再从行为上走一遍。
--
-- 【注入臂放在最后】fixture 64 付过这笔账:注入种下的行会污染后面各臂的数字。
--   I 臂:上下文标记【设了不清】→ 随后一条直连 UPDATE 当场走通(D 臂那条
--         "标记用完即清"的断言因此不是空转)。这正是 PUR-2 fu2 的教训。
--   J 臂:摘掉行的留痕触发器 → 改单不再留下任何一行(C 臂的历史断言因此有牙)。
--
-- 期间锁显式设 NULL(README 第 5 条)。自带数据(第 2 条)。
-- 汇率取【非 1】的 1.25(两边一致时,涉及金额的断言什么都不证明)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_cust uuid; v_cust2 uuid; v_mat uuid;
    soB uuid; soC uuid; soD uuid; soE uuid; soF uuid; soG uuid; soH uuid; soI uuid; soJ uuid;
    LB uuid; LC uuid; LD uuid; LE uuid; LF uuid; LF2 uuid; LG uuid; LG2 uuid; LH uuid; LJ uuid;
    obF uuid; obG uuid; obH uuid;
    resF uuid; resG uuid; resH uuid;
    invE text; invF text; v_inv_id uuid;
    v_msg text; v_denied boolean; v_n int; v_res jsonb; v_txt text;
    d date := CURRENT_DATE;
    FX constant numeric := 1.25;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-70', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ70-C1', 'fixture 70 customer', 'SG') RETURNING id INTO v_cust;
    -- 【第二个客户是有意的】D 臂要试"把客户换成【另一个真实存在的】客户"。
    -- 拿一个随机 uuid 去试,外键会先一步拒绝 —— 那样即使守卫被拿掉这一臂也照样红,
    -- 于是它测的是外键,不是守卫(fixture 52 C 臂踩过、写过这一段)。
    INSERT INTO customers (code, legal_name, country)
    VALUES ('ZZ70-C2', 'fixture 70 other customer', 'SG') RETURNING id INTO v_cust2;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX70-M', 'f70 material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;

    -- ══════════ A. 前提 + 目录 ═══════════════════════════════════════════════
    IF to_regprocedure('public.amend_sales_order(uuid,text,jsonb,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 70A 失败:amend_sales_order 不在 —— 改单的唯一入口就是它';
    END IF;
    IF to_regprocedure('public.sales_order_fulfilment_status(uuid)') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 70A 失败:sales_order_fulfilment_status 不在';
    END IF;
    -- 【内层算子:靠调不到】没有调用者检查,它逐张吐露别人订单的履约进度
    IF has_function_privilege('authenticated', 'public.sales_order_fulfilment_status(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 70A 失败:sales_order_fulfilment_status 对 authenticated 可执行 —— 它没有调用者检查,靠的就是调不到';
    END IF;
    -- 【一处推导,两个消费方】—— 抄一份进改单,两边会在写下的那天一致、此后各自
    -- 漂移。这条断言是那句话本身:两个函数体里都必须出现【同一个】函数名。
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'ship_order') NOT LIKE '%sales_order_fulfilment_status(%' THEN
        RAISE EXCEPTION 'FIXTURE 70A 失败:ship_order 没有读 sales_order_fulfilment_status —— 状态推导又变回两份了';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'amend_sales_order') NOT LIKE '%sales_order_fulfilment_status(%' THEN
        RAISE EXCEPTION 'FIXTURE 70A 失败:amend_sales_order 没有读 sales_order_fulfilment_status';
    END IF;
    -- 软下限读的是 SO-3b fu5 的那一处推导,不另写一遍
    IF (SELECT prosrc FROM pg_proc WHERE proname = 'guard_sales_order_line_floors') NOT LIKE '%line_spoken_for(%' THEN
        RAISE EXCEPTION 'FIXTURE 70A 失败:行下限守卫没有读 line_spoken_for —— "已许出去"又成了两份推导';
    END IF;
    -- 留痕由【触发器】写,不由应用写:应用侧留痕是"想写才写"的
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_sales_orders_history', 'trg_sales_order_lines_history',
                      'trg_sales_order_lines_floors') AND NOT tgisinternal;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 70A 失败:三个触发器(表头留痕/明细留痕/行下限)应当都在,实得 %', v_n;
    END IF;

    -- ══════════ B. 草稿:自由编辑,不要理由,【不留改单历史】═══════════════════
    soB := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 10, 'unit_price', 5)),
        NULL, NULL) ->> 'id')::uuid;
    SELECT id INTO LB FROM sales_order_lines WHERE sales_order_id = soB;

    -- 【理由传 NULL】—— 草稿态不要它。这一句同时是"草稿编辑器"的引擎测试。
    PERFORM amend_sales_order(soB, NULL,
        jsonb_build_object('notes', '草稿随手改'),
        jsonb_build_array(
            jsonb_build_object('id', LB, 'quantity', 7, 'unit_price', 6),
            jsonb_build_object('material_id', v_mat, 'quantity', 3, 'unit_price', 9)));

    IF (SELECT quantity FROM sales_order_lines WHERE id = LB) <> 7
       OR (SELECT unit_price FROM sales_order_lines WHERE id = LB) <> 6 THEN
        RAISE EXCEPTION 'FIXTURE 70B 失败:草稿的行应当随便改得动,实得 % @ %',
            (SELECT quantity FROM sales_order_lines WHERE id = LB),
            (SELECT unit_price FROM sales_order_lines WHERE id = LB);
    END IF;
    IF (SELECT count(*) FROM sales_order_lines WHERE sales_order_id = soB) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 70B 失败:草稿应当加得了行';
    END IF;
    IF (SELECT notes FROM sales_orders WHERE id = soB) IS DISTINCT FROM '草稿随手改' THEN
        RAISE EXCEPTION 'FIXTURE 70B 失败:草稿的备注应当改得动';
    END IF;
    -- 【核心:一行改单历史都不该有】
    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = soB
       AND change_type IN ('header_update','line_update','line_add','line_remove');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 70B 失败:草稿的编辑不该进改单历史(它还不是承诺),实得 % 行 —— 草稿态不设上下文标记,而留痕触发器只在标记为 1 时写行',
            v_n;
    END IF;
    -- 而建单那一行仍然在(SO-2b 的那扇门)
    IF NOT EXISTS (SELECT 1 FROM sales_order_history WHERE sales_order_id = soB AND change_type = 'created') THEN
        RAISE EXCEPTION 'FIXTURE 70B 失败:建单的 created 那一行应当在';
    END IF;

    -- ══════════ C. 确认之后:理由必填,而正例留下一行带理由的历史 ══════════════
    soC := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 12, 'unit_price', 10)),
        NULL, NULL) ->> 'id')::uuid;
    SELECT id INTO LC FROM sales_order_lines WHERE sales_order_id = soC;
    PERFORM set_sales_order_status(soC, 'confirmed');

    v_denied := false;
    BEGIN
        PERFORM amend_sales_order(soC, NULL, NULL,
            jsonb_build_array(jsonb_build_object('id', LC, 'quantity', 10)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_AMEND_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 70C 失败:确认之后的改单必须写理由,实得 denied=% msg=% —— 没有理由,历史上就只是一行"数字变了"',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;
    -- 【拒了就是什么都没动】
    IF (SELECT quantity FROM sales_order_lines WHERE id = LC) <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 70C 失败:被拒的改单不该留下任何改动';
    END IF;

    -- 正例:带理由
    PERFORM amend_sales_order(soC, '客户把量砍到 10', NULL,
        jsonb_build_array(jsonb_build_object('id', LC, 'quantity', 10)));
    IF (SELECT quantity FROM sales_order_lines WHERE id = LC) <> 10 THEN
        RAISE EXCEPTION 'FIXTURE 70C 失败:带理由的改单应当改得动 —— 一个"什么都不许改"的实现在这里死掉';
    END IF;
    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = soC AND change_type = 'line_update'
       AND old_quantity = 12 AND new_quantity = 10 AND amend_reason = '客户把量砍到 10';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 70C 失败:应当恰有一行 line_update 记着 12 → 10 与那句理由,实得 % 行',
            v_n;
    END IF;

    -- ══════════ D. §0(b):条款直连改不了,走改单改得了、而且留痕 ═══════════════
    soD := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 5, 'unit_price', 4)),
        '原备注', '原条款:30 天付款') ->> 'id')::uuid;
    SELECT id INTO LD FROM sales_order_lines WHERE sales_order_id = soD;
    PERFORM set_sales_order_status(soD, 'confirmed');

    -- 【这一臂故意走直连的 UPDATE】RLS 今天就允许持 module.sales.edit 的人直接改
    -- (那两条策略是【有意】留着的:守卫挡得住直连,只有在直连还通着时才证明得了)。
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE sales_orders SET notes = '偷偷改的备注' WHERE id = soD;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_CONFIRMED_IMMUTABLE|notes|%' THEN
        RAISE EXCEPTION 'FIXTURE 70D 失败:确认之后直连改备注应被【触发器】按名拒,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE sales_orders SET terms_text = '偷偷改的条款' WHERE id = soD;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_CONFIRMED_IMMUTABLE|terms_text|%' THEN
        RAISE EXCEPTION 'FIXTURE 70D 失败:确认之后直连改【条款正文】应被按名拒,实得 denied=% msg=% —— 那正是印在客户手里那份 PDF 上的字,而它此前谁都改得动、不留痕迹',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;

    -- 【永久冻结的一列:换客户,不分路径】
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE sales_orders SET customer_id = v_cust2 WHERE id = soD;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_CONFIRMED_IMMUTABLE|customer_id|%' THEN
        RAISE EXCEPTION 'FIXTURE 70D 失败:换客户应被按名拒(应收、发票、签发档全挂在这一笔上),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(改成功了)');
    END IF;

    -- 【另一个方向:走改单那条路,改得动,而且留下一行带理由的历史】
    PERFORM amend_sales_order(soD, '付款方式谈成 60 天',
        jsonb_build_object('terms_text', '新条款:60 天付款'), NULL);
    IF (SELECT terms_text FROM sales_orders WHERE id = soD) <> '新条款:60 天付款' THEN
        RAISE EXCEPTION 'FIXTURE 70D 失败:走改单那条路应当改得动条款 —— 只堵不开是把伤口缝上';
    END IF;
    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = soD AND change_type = 'header_update'
       AND old_terms_text = '原条款:30 天付款' AND new_terms_text = '新条款:60 天付款'
       AND amend_reason = '付款方式谈成 60 天';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 70D 失败:应当恰有一行 header_update 记着条款的前后与理由,实得 % 行', v_n;
    END IF;

    -- 【标记用完即清】跑过一次改单 RPC 之后,同一个事务里直连改仍然必须被挡。
    -- set_config(..., true) 是【事务】局部而不是语句局部 —— PUR-2 fu2 的教训,
    -- I 臂用注入证明这一句不是空转。
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE sales_orders SET notes = '标记漏了就能改' WHERE id = soD;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 70D 失败:跑过一次改单 RPC 之后,同一事务里直连改备注仍然应当被挡 —— 上下文标记是事务局部的,设了不清等于把守卫关掉一整个事务';
    END IF;

    -- ══════════ E. 已开票:数量与单价冻住;作废之后【整条路走通】═══════════════
    soE := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 12, 'unit_price', 10)),
        NULL, NULL) ->> 'id')::uuid;
    SELECT id INTO LE FROM sales_order_lines WHERE sales_order_id = soE;
    PERFORM set_sales_order_status(soE, 'confirmed');
    invE := create_order_invoice(soE, d, NULL, NULL, NULL, ARRAY[LE]) ->> 'code';

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soE, '改数量', NULL,
            jsonb_build_array(jsonb_build_object('id', LE, 'quantity', 10)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> format('SO_AMEND_LINE_INVOICED|1|%s', invE) THEN
        RAISE EXCEPTION 'FIXTURE 70E 失败:开过票的行,数量应当按名冻住并说出是哪张票,期望 SO_AMEND_LINE_INVOICED|1|%,实得 denied=% msg=%',
            invE, v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soE, '改单价', NULL,
            jsonb_build_array(jsonb_build_object('id', LE, 'quantity', 12, 'unit_price', 11)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_AMEND_LINE_INVOICED|1|%' THEN
        RAISE EXCEPTION 'FIXTURE 70E 失败:开过票的行【单价】也应当冻住,实得 denied=% msg=% —— 那张票已经把这笔债按这个单价记进了账',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- 删行也拒,而且【报的是发票】,不是外键
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soE, '删掉这一行', NULL,
            jsonb_build_array(jsonb_build_object('id', LE, 'remove', true)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> format('SO_LINE_HAS_INVOICE|1|%s', invE) THEN
        RAISE EXCEPTION 'FIXTURE 70E 失败:开过票的行删不掉,而且应当报【是哪张票】而不是一句外键约束名,期望 SO_LINE_HAS_INVOICE|1|%,实得 %',
            invE, COALESCE(v_msg, '(删掉了)');
    END IF;

    -- 【出路真的走一遍】作废那张票 → 再改。一条出路只有走过一遍才算出路。
    SELECT id INTO v_inv_id FROM invoices WHERE code = invE;
    PERFORM void_invoice(v_inv_id, 'fixture 70 E:数字错了', d);
    PERFORM amend_sales_order(soE, '作废发票之后改回来', NULL,
        jsonb_build_array(jsonb_build_object('id', LE, 'quantity', 10, 'unit_price', 11)));
    IF (SELECT quantity FROM sales_order_lines WHERE id = LE) <> 10
       OR (SELECT unit_price FROM sales_order_lines WHERE id = LE) <> 11 THEN
        RAISE EXCEPTION 'FIXTURE 70E 失败:作废发票之后应当改得动 —— 那是消息里写着的两条出路之一,而一条没走通的出路等于没有';
    END IF;

    -- 【但它仍然【删】不掉 —— fu1】作废一张发票是把 invoice_voided 置真,
    -- 发票行【留着供审计】。那一行是"曾经发生过什么"的记录,而外键盯的是
    -- 订单行的存在、不是它活不活 —— 少了 fu1 那一支,这里吐的是一句
    -- "violates foreign key constraint invoice_lines_sales_order_line_id_fkey",
    -- 也就是这条守卫存在的全部理由当场失效。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soE, '作废之后干脆删掉', NULL,
            jsonb_build_array(jsonb_build_object('id', LE, 'remove', true)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SO_LINE_HAS_RECORD|1|1' THEN
        RAISE EXCEPTION 'FIXTURE 70E 失败:作废了的发票行仍然指着这一行,所以它删不掉,应当按名拒 SO_LINE_HAS_RECORD|1|1(而不是一句外键约束名),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(删掉了)');
    END IF;

    -- ══════════ F. 已发:硬下限,而【边界落在 8 上】由两条不同的拒绝证明 ═══════
    soF := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(
            jsonb_build_object('material_id', v_mat, 'quantity', 12, 'unit_price', 10),
            -- 【第二行永远不动】于是这张单停在 partially_shipped 而不是 shipped ——
            -- 那是改单闸认的状态。这不是布景,是前提。
            jsonb_build_object('material_id', v_mat, 'quantity', 20, 'unit_price', 10)),
        NULL, NULL) ->> 'id')::uuid;
    SELECT id INTO LF  FROM sales_order_lines WHERE sales_order_id = soF AND line_no = 1;
    SELECT id INTO LF2 FROM sales_order_lines WHERE sales_order_id = soF AND line_no = 2;
    PERFORM set_sales_order_status(soF, 'confirmed');
    obF := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    invF := create_order_invoice(soF, d, NULL, NULL, NULL, ARRAY[LF]) ->> 'code';
    resF := (reserve_stock(LF, obF, 12) ->> 'reservation_id')::uuid;
    -- 部分发货 8(预留 12):ship_order 先把预留拆开,4 回到 available
    PERFORM ship_order(soF, d, jsonb_build_array(
        jsonb_build_object('reservation_id', resF, 'qty', 8)));

    IF (SELECT status FROM sales_orders WHERE id = soF) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 70F 前置失败:这张单应当停在 partially_shipped,实得 %',
            (SELECT status FROM sales_orders WHERE id = soF);
    END IF;

    -- 7:落到已发之下 → 硬下限按名拒,三段都验
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soF, '砍到已发之下', NULL,
            jsonb_build_array(jsonb_build_object('id', LF, 'quantity', 7)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SO_LINE_BELOW_SHIPPED|1|8|7' THEN
        RAISE EXCEPTION 'FIXTURE 70F 失败:砍到已发(8)之下应当点名拒,期望 SO_LINE_BELOW_SHIPPED|1|8|7,实得 denied=% msg=% —— 货已经出去了,单据不能宣称我们答应的比发出去的还少',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- 8:【正好等于已发】—— 不再是这条下限在挡,而是那张在册发票。
    -- 两条【不同】的拒绝,正是"下限落在 8 上"的证据:一个把 < 写成 <= 的实现
    -- 会在这里继续吐 BELOW_SHIPPED,当场红。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soF, '短装收尾', NULL,
            jsonb_build_array(jsonb_build_object('id', LF, 'quantity', 8)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_AMEND_LINE_INVOICED|1|%' THEN
        RAISE EXCEPTION 'FIXTURE 70F 失败:改成【正好等于已发】不该再触发已发下限(边界在内),挡住它的应当是那张在册发票 SO_AMEND_LINE_INVOICED,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- 删行:报【已发】,而且它排在发票前面 —— 最不可逆的先说
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soF, '删掉发过货的行', NULL,
            jsonb_build_array(jsonb_build_object('id', LF, 'remove', true)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SO_LINE_HAS_SHIPMENTS|1|8' THEN
        RAISE EXCEPTION 'FIXTURE 70F 失败:发过货的行删不掉,期望 SO_LINE_HAS_SHIPMENTS|1|8,实得 %',
            COALESCE(v_msg, '(删掉了)');
    END IF;

    -- 【正例:没被咬住的那一行照样改得动】—— 否则这一臂只证明了"这张单全冻着"
    PERFORM amend_sales_order(soF, '第二行加量', NULL,
        jsonb_build_array(jsonb_build_object('id', LF2, 'quantity', 25)));
    IF (SELECT quantity FROM sales_order_lines WHERE id = LF2) <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 70F 失败:同一张单上没被咬住的行应当改得动 —— 下限是【逐行】的,不是整单的';
    END IF;

    -- ══════════ G. 已预留:软下限,说出数,而且【绝不替人释放】═════════════════
    soG := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(
            jsonb_build_object('material_id', v_mat, 'quantity', 12, 'unit_price', 10),
            jsonb_build_object('material_id', v_mat, 'quantity', 20, 'unit_price', 10)),
        NULL, NULL) ->> 'id')::uuid;
    SELECT id INTO LG  FROM sales_order_lines WHERE sales_order_id = soG AND line_no = 1;
    SELECT id INTO LG2 FROM sales_order_lines WHERE sales_order_id = soG AND line_no = 2;
    PERFORM set_sales_order_status(soG, 'confirmed');
    obG := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    -- 【不开票】—— 这一臂要的是预留在挡,不是发票在挡
    resG := (reserve_stock(LG, obG, 5) ->> 'reservation_id')::uuid;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soG, '砍到预留之下', NULL,
            jsonb_build_array(jsonb_build_object('id', LG, 'quantity', 3)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SO_LINE_BELOW_RESERVED|1|5|3' THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:砍到活预留之下应当点名拒并说出【还扣着多少】,期望 SO_LINE_BELOW_RESERVED|1|5|3,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;
    -- 【这一句是软下限的全部意义】拒绝之后,那条预留必须【原样还活着】。
    -- 一个"顺手释放掉再改"的实现会让上面每一条断言都通过,而它替操作员做掉了
    -- "放弃这个承诺"这个决定 —— 而释放是要留名字、留理由、进订单历史的。
    IF NOT EXISTS (SELECT 1 FROM sales_order_reservations
                    WHERE id = resG AND released_at IS NULL AND consumed_at IS NULL AND qty = 5) THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:被软下限拒之后,那条预留必须【原样还活着】—— 系统绝不替人释放:放弃一个承诺是一个要留名字的决定';
    END IF;

    -- 【边界在内】改到正好等于已许出去的 5:通过
    PERFORM amend_sales_order(soG, '砍到正好等于已预留', NULL,
        jsonb_build_array(jsonb_build_object('id', LG, 'quantity', 5)));
    IF (SELECT quantity FROM sales_order_lines WHERE id = LG) <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:改到【正好等于已许出去】应当放行(边界在内)';
    END IF;

    -- 删行:报【预留】,并说出扣着多少
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soG, '删掉扣着货的行', NULL,
            jsonb_build_array(jsonb_build_object('id', LG, 'remove', true)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SO_LINE_HAS_RESERVATIONS|1|5' THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:还扣着货的行删不掉,期望 SO_LINE_HAS_RESERVATIONS|1|5,实得 %',
            COALESCE(v_msg, '(删掉了)');
    END IF;

    -- 【出路走一遍】释放(留名、留理由)之后,砍得下去了
    PERFORM release_reservation(resG, NULL, 'fixture 70 G:客户改主意了');
    PERFORM amend_sales_order(soG, '释放之后砍到 3', NULL,
        jsonb_build_array(jsonb_build_object('id', LG, 'quantity', 3)));
    IF (SELECT quantity FROM sales_order_lines WHERE id = LG) <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:释放之后应当砍得下去 —— 一条没走通的出路等于没有';
    END IF;

    -- 【但仍然【删】不掉,而这正是 fu1 的由来】释放【不删那一行预留】:它写三列、
    -- 把那条预留作废,行本身留着,因为"某天许出去 5、又因为某个理由放回来了"
    -- 是一个事实。外键盯的是行的存在,不是它活不活 —— 第一版守卫只数【活预留】,
    -- 于是这一步吐的是 "violates foreign key constraint …_sales_order_line_id_fkey",
    -- 也就是这条守卫存在的全部理由,在它自己写下的那条出路上当场失效。
    -- 这一条【不可操作】,所以它是第四个名字而不是并进上面那条:没有任何动作
    -- 能让一件已经发生过的事情没发生过,而"请先释放预留"对一条已经释放过的
    -- 预留是一句无解的话。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soG, '释放之后删掉这一行', NULL,
            jsonb_build_array(jsonb_build_object('id', LG, 'remove', true)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg <> 'SO_LINE_HAS_RECORD|1|1' THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:释放过的预留仍然是一条指着这一行的记录,所以这一行删不掉,应当按名拒 SO_LINE_HAS_RECORD|1|1(而不是一句外键约束名),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(删掉了)');
    END IF;

    -- 【正例:一条没有过去的行,删得掉,而且留下一行 line_remove】
    -- 界面表达"这一行不要了"的方式就是【删掉它】,所以只记表头的历史会对最激烈的
    -- 那种编辑一言不发,而沉默读起来正好等于"什么都没改"(pricing_formula_history
    -- 的抬头写过这条,PUR-2 抄的也是它)。
    PERFORM amend_sales_order(soG, '第二行不要了', NULL,
        jsonb_build_array(jsonb_build_object('id', LG2, 'remove', true)));
    IF EXISTS (SELECT 1 FROM sales_order_lines WHERE id = LG2) THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:一条没有任何单据挂着的行应当删得掉 —— 否则这一臂只证明了"什么都删不掉"';
    END IF;
    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = soG AND change_type = 'line_remove'
       AND old_quantity = 20 AND amend_reason = '第二行不要了';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 70G 失败:删行应当留下一行 line_remove,记着它当初是多少与那句理由,实得 % 行', v_n;
    END IF;

    -- ══════════ H. shipped 只开一条缝:加行 → 状态由【共用推导】翻回去 ═════════
    soH := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 12, 'unit_price', 10)),
        NULL, NULL) ->> 'id')::uuid;
    SELECT id INTO LH FROM sales_order_lines WHERE sales_order_id = soH;
    PERFORM set_sales_order_status(soH, 'confirmed');
    obH := (create_output_batch(v_mat, 100, 'kg', d, '库存中', NULL, NULL, NULL, NULL) ->> 'batch_id')::uuid;
    PERFORM create_order_invoice(soH, d, NULL, NULL, NULL, ARRAY[LH]);
    resH := (reserve_stock(LH, obH, 12) ->> 'reservation_id')::uuid;
    PERFORM ship_order(soH, d, jsonb_build_array(jsonb_build_object('reservation_id', resH)));
    IF (SELECT status FROM sales_orders WHERE id = soH) <> 'shipped' THEN
        RAISE EXCEPTION 'FIXTURE 70H 前置失败:整单发完应当是 shipped,实得 %',
            (SELECT status FROM sales_orders WHERE id = soH);
    END IF;

    -- 表头:一个字都不能动
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soH, '改条款', jsonb_build_object('terms_text', 'x'), NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_NOT_AMENDABLE|%|shipped' THEN
        RAISE EXCEPTION 'FIXTURE 70H 失败:发完的单表头不该动得了,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;
    -- 既有的行:一条都不能动
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soH, '改行', NULL,
            jsonb_build_array(jsonb_build_object('id', LH, 'quantity', 15)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_NOT_AMENDABLE|%|shipped' THEN
        RAISE EXCEPTION 'FIXTURE 70H 失败:发完的单,既有的行不该动得了,实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- 【那条缝:加一行】—— 而状态由共用推导翻回 partially_shipped
    v_res := amend_sales_order(soH, '客户又要 5', NULL,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 5, 'unit_price', 10)));
    IF (SELECT status FROM sales_orders WHERE id = soH) <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 70H 失败:给一张发完的单加一行,它就不再是发完了 —— 状态应当由"已发 vs 已订"翻回 partially_shipped,实得 %',
            (SELECT status FROM sales_orders WHERE id = soH);
    END IF;
    IF v_res ->> 'status' <> 'partially_shipped' THEN
        RAISE EXCEPTION 'FIXTURE 70H 失败:返回值应当把新状态带回去(这次翻转【不另写一行历史】——状态在这里是推导出来的,不是一次动作),实得 %',
            v_res ->> 'status';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM sales_order_history
                    WHERE sales_order_id = soH AND change_type = 'line_add'
                      AND new_quantity = 5 AND amend_reason = '客户又要 5') THEN
        RAISE EXCEPTION 'FIXTURE 70H 失败:加行应当留下一行 line_add,带着数量与理由';
    END IF;

    -- ══════════ I. 终态:closed / cancelled 一律拒 ════════════════════════════
    soI := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 4, 'unit_price', 3)),
        NULL, NULL) ->> 'id')::uuid;
    PERFORM set_sales_order_status(soI, 'cancelled', 'fixture 70 I');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM amend_sales_order(soI, '改一改', jsonb_build_object('notes', 'x'), NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    IF NOT v_denied OR v_msg NOT LIKE 'SO_NOT_AMENDABLE|%|cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 70I 失败:作废的单改不了(终态 —— 要改就另开一张),实得 denied=% msg=%',
            v_denied, COALESCE(v_msg, '(放行了)');
    END IF;

    -- ══════════ 注入 1:上下文标记【设了不清】═════════════════════════════════
    -- D 臂最后那条断言("跑过一次改单之后直连仍然被挡")必须能失败,否则它在空转。
    -- 把 amend_sales_order 换成一个【只设不清】的版本:随后那条直连 UPDATE
    -- 当场走通 —— 这正是 PUR-2 fu2 修掉的那个洞。
    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.amend_sales_order(p_order_id uuid, p_reason text, p_header jsonb DEFAULT NULL::jsonb, p_lines jsonb DEFAULT NULL::jsonb)
         RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
         SET search_path TO 'public', 'pg_temp'
        AS $f$
        BEGIN
            -- 【被换掉的那一半】:设了标记,从不清掉
            PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
            UPDATE sales_orders SET notes = COALESCE(p_header->>'notes', notes)
             WHERE id = p_order_id;
            RETURN jsonb_build_object('sales_order_id', p_order_id);
        END;
        $f$;
    $inj$;

    soJ := (create_sales_order(v_cust, d, 'USD', FX,
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 6, 'unit_price', 2)),
        '注入前', NULL) ->> 'id')::uuid;
    SELECT id INTO LJ FROM sales_order_lines WHERE sales_order_id = soJ;
    PERFORM set_sales_order_status(soJ, 'confirmed');
    PERFORM amend_sales_order(soJ, '注入:设了不清', jsonb_build_object('notes', '注入后'), NULL);

    EXECUTE 'SET LOCAL ROLE authenticated';
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE sales_orders SET terms_text = '标记没清,于是我改成了' WHERE id = soJ;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true;
    END;
    RESET ROLE;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 70 注入1 失败:把标记换成【设了不清】之后,随后那条直连 UPDATE 【仍然】被挡(%)—— 说明 D 臂那条"标记用完即清"的断言一直靠别的东西成立,它在空转',
            v_msg;
    END IF;

    -- ══════════ 注入 2:摘掉明细的留痕触发器 ═════════════════════════════════
    -- C/G/H 三臂的历史断言必须能失败。摘掉触发器之后,一次改行不该再留下任何一行。
    -- 【这一臂不经 amend_sales_order】(注入 1 已经把它换掉了):它自己设标记、
    -- 自己发那条 UPDATE —— 被测的是【触发器写不写】,不是谁调的它。
    DROP TRIGGER trg_sales_order_lines_history ON public.sales_order_lines;

    PERFORM set_config('evoltrya.so_amend_ctx', '1', true);
    PERFORM set_config('evoltrya.so_amend_reason', '注入2', true);
    UPDATE sales_order_lines SET quantity = 99 WHERE id = LJ;
    PERFORM set_config('evoltrya.so_amend_ctx', '', true);
    PERFORM set_config('evoltrya.so_amend_reason', '', true);

    SELECT count(*) INTO v_n FROM sales_order_history
     WHERE sales_order_id = soJ AND change_type = 'line_update';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 70 注入2 失败:摘掉明细留痕触发器之后,一次改行【仍然】留下了 % 行 line_update —— 说明留痕不是那个触发器写的,C/G/H 三臂的历史断言在空转',
            v_n;
    END IF;
    -- 而正例证明这条通路本来是通的:改动【本身】确实发生了
    IF (SELECT quantity FROM sales_order_lines WHERE id = LJ) <> 99 THEN
        RAISE EXCEPTION 'FIXTURE 70 注入2 失败:注入之后那次改动本身没发生 —— 那这一臂测的不是留痕,是别的东西';
    END IF;
END $$;
ROLLBACK;

-- 87 收货差异【点名是哪一种】,而三个阈值是【现读的】,不是写死的
--
-- 【它守的是什么】GRN-1a 建的 grn_discrepancies 要同时成立六件事,而它们各自
-- 会以不同的方式坏掉,并且【坏了都不报错】—— 这张视图从头到尾没有一次拒绝,
-- 它的产物就是一句话,所以"说错了话"就是它唯一的失败模式:
--   ① 短交/超收比的是【采购行的累计】,不是单条收货 —— 否则分批到货会被报成短交;
--   ② short 只在 closed / cancelled 报,over 任何状态都报;
--   ③ 三个阈值现读 receiving_settings,【一个数都不许写死】;
--   ④ 没挂采购行的批次【整行缺席】,不是一行零;
--   ⑤ 申报量没记时 declared_delta_qty 是 NULL 而不是 0,化验缺一侧时
--      assay_beyond_tolerance 是 NULL 而不是 false;
--   ⑥ 收错料【被点名,但绝不被拒绝】。
--
-- 【为什么边界要取阈值 ±1、而且两个方向都取】
-- 这张视图的每一条断言都是一个不等号,而不等号有两种错法:方向反了(任何一个
-- 粗糙的用例都抓得到),以及【严格与不严格搞混了】(`<` 写成 `<=`)—— 后者只在
-- 【恰好等于阈值】那一个点上表现出来,而一个只测"明显短了 33%"的用例永远碰不到
-- 那个点。所以每个阈值都取三点:阈值 −1、阈值本身、阈值 +1。落在阈值【本身】
-- 上的那一点断言"不报",因为谓词是严格不等号 —— 这一条正是本文件最容易被
-- "顺手改对"的地方,所以写在这里。
--
-- 【③ 怎么证明"现读"—— 而不是"恰好相等"】
-- 一个把 5 写死在视图里的实现,与一个现读 receiving_settings 的实现,在引导值
-- 就是 5 的库上【给出完全相同的答案】。所以 D 臂不比对数字,它【在同一个事务里
-- 改掉 receiving_settings】,再断言【同一条收货的结论翻了面】。三列各翻一次,
-- 并且每次都断言【另外两列的结论不动】—— 只有这样才说明它读的是那一列,
-- 而不是碰巧跟着某个共用的数一起动了。
--
-- 【本 fixture 以 postgres 跑,K 臂不切数据库角色 —— 这是对的,理由要写下来】
-- grn_discrepancies 是【属主权限】视图,它的门是体内那句 has_permission(),
-- 而 has_permission() 是 SECURITY DEFINER、按 request.jwt.claims 里的 sub 解析,
-- 与当前数据库角色无关(README 第 6 条点名的正是这个区别)。K 臂换的是 claims,
-- 不是角色 —— 换角色反而测不到它。这张视图【没有任何一条断言依赖 RLS】,
-- 那正是 OPS-14 给跨模块视图开的药方本身:属主权限,谓词写回体内。
--
-- 【故障注入:这张视图是单层的,所以每一条结论都注过】
-- 没有第二道闸在它后面兜底 —— 视图说什么,页面就印什么。注入记录在切次报告里,
-- 基线在任何注入之前先跑过。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();   -- 全部权限
    v_none uuid := gen_random_uuid();   -- 【不持】module.purchasing.view
    r_all uuid; r_none uuid;
    sup uuid; mat_a uuid; mat_b uuid;
    po_closed uuid; po_open uuid; po_assay uuid; po_misc uuid; po_trans uuid;
    l_899 uuid; l_900 uuid; l_901 uuid;
    l_1101 uuid; l_1100 uuid; l_1099 uuid;
    l_trans uuid; l_split uuid;
    l_dnull uuid; l_dsame uuid; l_dgap uuid; l_mis uuid;
    l_as_eq uuid; l_as_hi uuid; l_as_lo uuid; l_as_loin uuid; l_noexp uuid; l_unap uuid;
    b_899 uuid; b_900 uuid; b_901 uuid;
    b_1101 uuid; b_1100 uuid; b_1099 uuid;
    b_trans uuid; b_split1 uuid; b_split2 uuid;
    b_dnull uuid; b_dsame uuid; b_dgap uuid;
    b_mis uuid; b_nopo uuid;
    b_as_eq uuid; b_as_hi uuid; b_as_lo uuid; b_as_loin uuid;
    b_noexp uuid; b_unap uuid;
    a uuid;
    v_kinds text[]; v_bool boolean; v_num numeric; v_int int; n int;
    v_msg text; v_denied boolean; v_found boolean;
BEGIN
    -- ══════════ 前提 ══════════════════════════════════════════════════════════
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-87-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-87-none', 'f', 'f', true) RETURNING id INTO r_none;
    -- 【给 inbound 而不给 purchasing】—— K 臂要证明的是 purchasing 那道门,
    -- 不是"什么权限都没有的人被拒"(那什么也证明不了)。
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_none, 'module.inbound.view'), (r_none, 'module.inbound.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all), (v_none, r_none);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【前提显式设定,哪怕默认值恰好合用】(README 第 5 条)。引导值就是 5/5/10,
    -- 但下一份 fixture 完全可能在同一个重建库里改掉它,而那时本文件会因为一个
    -- 与被测规则无关的理由红掉 —— 或者更坏,绿掉。
    UPDATE receiving_settings
       SET grn_short_pct = 10, grn_over_pct = 10, grn_assay_tolerance_pct = 10;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX87-SUP', 'fixture 87 supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('FX87-MA', 'fixture 87 material A', 'battery_material', true) RETURNING id INTO mat_a;
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('FX87-MB', 'fixture 87 material B', 'battery_material', true) RETURNING id INTO mat_b;

    -- 五张单。approval_status 必须 approved、status 必须可收(confirmed/receiving),
    -- 否则收货在触发器那一层就被拒了 —— 那测的是 APR-2,不是本视图。
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX87-PO-CLOSED', sup, '2026-05-01', 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po_closed;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX87-PO-OPEN', sup, '2026-05-01', 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po_open;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX87-PO-ASSAY', sup, '2026-05-01', 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po_assay;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX87-PO-MISC', sup, '2026-05-01', 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po_misc;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX87-PO-TRANS', sup, '2026-05-01', 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po_trans;

    -- ══════════════════════════════════════════════════════════════════════════
    -- A. 短交边界:阈值 10%,订 1000 → 门槛 900。谓词是【严格小于】,
    --    所以 899 报、900 不报、901 不报。三条【各自独立的采购行】(README 第 2 条:
    --    共享数据的用例会因为错的理由通过)。PO 收完之后置 closed —— short 只在
    --    关单之后才成立,那是 C 臂的事,这里先把状态摆对。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_closed, 1, mat_a, 1000, 'kg') RETURNING id INTO l_899;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_closed, 2, mat_a, 1000, 'kg') RETURNING id INTO l_900;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_closed, 3, mat_a, 1000, 'kg') RETURNING id INTO l_901;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-A899', mat_a, sup, 899, 'kg', 899, '2026-05-02', po_closed, l_899) RETURNING id INTO b_899;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-A900', mat_a, sup, 900, 'kg', 900, '2026-05-02', po_closed, l_900) RETURNING id INTO b_900;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-A901', mat_a, sup, 901, 'kg', 901, '2026-05-02', po_closed, l_901) RETURNING id INTO b_901;

    -- 关单。状态转换走 po_status_ctx —— guard_po_amendable 不许编辑表单碰 status。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'closed' WHERE id = po_closed;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_899;
    IF NOT ('short' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87A 阈值 −1(899/1000,门槛 900)必须报 short,实得 %', v_kinds;
    END IF;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_900;
    IF 'short' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87A 【恰好等于门槛】(900/1000)不许报 short —— 谓词是严格小于,写成 <= 就会在这里红。实得 %', v_kinds;
    END IF;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_901;
    IF 'short' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87A 阈值 +1(901/1000)不许报 short,实得 %', v_kinds;
    END IF;
    RAISE NOTICE '87A 短交边界 899/900/901 —— 报/不报/不报 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- B. 超收边界:阈值 10%,订 1000 → 门槛 1100。谓词【严格大于】,
    --    所以 1101 报、1100 不报、1099 不报。
    --    【单留在 receiving】—— 这一臂同时证明 over 不等关单(② 的一半)。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_open, 1, mat_a, 1000, 'kg') RETURNING id INTO l_1101;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_open, 2, mat_a, 1000, 'kg') RETURNING id INTO l_1100;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_open, 3, mat_a, 1000, 'kg') RETURNING id INTO l_1099;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-B1101', mat_a, sup, 1101, 'kg', 1101, '2026-05-02', po_open, l_1101) RETURNING id INTO b_1101;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-B1100', mat_a, sup, 1100, 'kg', 1100, '2026-05-02', po_open, l_1100) RETURNING id INTO b_1100;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-B1099', mat_a, sup, 1099, 'kg', 1099, '2026-05-02', po_open, l_1099) RETURNING id INTO b_1099;

    SELECT kinds, po_status INTO v_kinds, v_msg FROM grn_discrepancies WHERE batch_id = b_1101;
    IF v_msg <> 'receiving' THEN
        RAISE EXCEPTION 'FIXTURE 87B 无效:这一臂要证明 over 不等关单,单却是 % —— 前提没摆对', v_msg;
    END IF;
    IF NOT ('over' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87B 阈值 +1(1101/1000,门槛 1100)必须报 over,而且【单还开着就要报】,实得 %', v_kinds;
    END IF;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_1100;
    IF 'over' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87B 【恰好等于门槛】(1100/1000)不许报 over —— 谓词是严格大于。实得 %', v_kinds;
    END IF;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_1099;
    IF 'over' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87B 阈值 −1(1099/1000)不许报 over,实得 %', v_kinds;
    END IF;
    RAISE NOTICE '87B 超收边界 1101/1100/1099 —— 报/不报/不报,且单开着就报 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- C. short 只在 closed / cancelled 报 —— 【同一条收货,只翻状态】
    --    ② 的另一半。这一臂里的"转换"就是断言本身:同一行数据,一个字段变了,
    --    结论必须跟着变。分两条独立数据去比是比不出这件事的。
    --    并且它顺带守住 ①:两次到货 400 + 300 对着订 700,【按单条算会被报成
    --    短 43%】,而按累计算是不短。那正是 GRN-1a 决定用累计的理由。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_trans, 1, mat_a, 1000, 'kg') RETURNING id INTO l_trans;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-CTRANS', mat_a, sup, 500, 'kg', 500, '2026-05-02', po_trans, l_trans) RETURNING id INTO b_trans;

    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_trans;
    IF 'short' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87C 单还开着(receiving),500/1000 也【不许】报 short —— "少"只是"还没收完"。实得 %', v_kinds;
    END IF;
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'closed' WHERE id = po_trans;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_trans;
    IF NOT ('short' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87C 单一关,同一条收货(500/1000)就必须报 short,实得 %', v_kinds;
    END IF;

    -- ① 累计,不是单条:400 + 300 对着订 700。
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_trans, 2, mat_a, 700, 'kg') RETURNING id INTO l_split;
    -- 单已经 closed,收不进去了 —— 先开回 receiving 收货,再关回去。
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'receiving' WHERE id = po_trans;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-CSPL1', mat_a, sup, 400, 'kg', 400, '2026-05-03', po_trans, l_split) RETURNING id INTO b_split1;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-CSPL2', mat_a, sup, 300, 'kg', 300, '2026-05-04', po_trans, l_split) RETURNING id INTO b_split2;
    PERFORM set_config('evoltrya.po_status_ctx', '1', true);
    UPDATE purchase_orders SET status = 'closed' WHERE id = po_trans;
    PERFORM set_config('evoltrya.po_status_ctx', '', true);

    SELECT kinds, line_received_qty, line_receipt_count
      INTO v_kinds, v_num, v_int FROM grn_discrepancies WHERE batch_id = b_split1;
    IF v_num <> 700 OR v_int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 87C 累计必须是 700(两条收货),实得 % / % 条', v_num, v_int;
    END IF;
    IF 'short' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87C 分批到货 400+300 = 订量 700,【不是短交】—— 按单条算才会把那条 400 报成短 43%%。实得 %', v_kinds;
    END IF;
    -- 【同一行的每一条收货都带同一个结论】—— 让某几条静默地不带,会让"没说"
    -- 读起来像"这条没问题"。b_trans 那一行只有一条收货,所以拿 A 臂那条比。
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_split2;
    IF 'short' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87C 第二条收货也不许报 short,实得 %', v_kinds;
    END IF;
    RAISE NOTICE '87C short 只在关单后报;分批到货按累计算,不报短交 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- D. 三个阈值【现读 receiving_settings】—— ③
    --    不比数字:改配置,断言【同一条收货的结论翻面】,并且每次都断言
    --    【另外两列不动】。写死 5 的实现在引导值就是 5 的库上与现读的实现
    --    完全同答,只有翻面能把两者分开。
    -- ══════════════════════════════════════════════════════════════════════════
    -- D1 · short:901/1000 在 10% 下不短(门槛 900);把阈值收到 5% → 门槛 950 → 短。
    UPDATE receiving_settings SET grn_short_pct = 5;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_901;
    IF NOT ('short' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87D1 阈值改成 5%% 之后 901/1000(门槛 950)必须报 short —— 没翻面说明阈值是写死的。实得 %', v_kinds;
    END IF;
    -- 只动了 short 那一列 → over 的结论必须【原地不动】
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_1099;
    IF 'over' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87D1 只改了 grn_short_pct,1099/1000 的 over 结论不许跟着动 —— 两列读串了。实得 %', v_kinds;
    END IF;
    UPDATE receiving_settings SET grn_short_pct = 10;

    -- D2 · over:1099/1000 在 10% 下不超(门槛 1100);收到 5% → 门槛 1050 → 超。
    UPDATE receiving_settings SET grn_over_pct = 5;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_1099;
    IF NOT ('over' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87D2 阈值改成 5%% 之后 1099/1000(门槛 1050)必须报 over。实得 %', v_kinds;
    END IF;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_901;
    IF 'short' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87D2 只改了 grn_over_pct,901/1000 的 short 结论不许跟着动。实得 %', v_kinds;
    END IF;
    UPDATE receiving_settings SET grn_over_pct = 10;
    RAISE NOTICE '87D1/D2 short 与 over 各自现读自己那一列,互不牵连 ✓';
    -- D3(化验那一列)在 I 臂之后,因为它要用 I 臂建的数据。

    -- ══════════════════════════════════════════════════════════════════════════
    -- E. 申报量:【没记 ≠ 记了个相等的数】—— ⑤ 的一半
    --    三条收货,都走 RPC,因为"不传 p_declared_qty 时落 NULL 而不是订量"
    --    正是这一列最容易被"顺手预填"毁掉的地方。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_misc, 1, mat_a, 1000, 'kg') RETURNING id INTO l_dnull;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_misc, 2, mat_a, 1000, 'kg') RETURNING id INTO l_dsame;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_misc, 3, mat_a, 1000, 'kg') RETURNING id INTO l_dgap;

    -- E1 · 【不传】—— 必须是 NULL,【不许是订量 1000,也不许是实收 1000】
    SELECT (receive_inbound_batch_against_po(
                p_material_id => mat_a, p_supplier_id => sup, p_quantity => 1000,
                p_arrival_date => '2026-05-02', p_purchase_order_id => po_misc,
                p_purchase_order_line_id => l_dnull) ->> 'batch_id')::uuid
      INTO b_dnull;
    SELECT declared_qty INTO v_num FROM inbound_batches WHERE id = b_dnull;
    IF v_num IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 87E1 不传 p_declared_qty 就是【没记】—— 落库必须是 NULL,实得 %。一个被预填的申报量是系统替供应商说了话。', v_num;
    END IF;
    SELECT declared_delta_qty, kinds INTO v_num, v_kinds FROM grn_discrepancies WHERE batch_id = b_dnull;
    IF v_num IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 87E1 没记申报量时 declared_delta_qty 必须是 NULL,不是 0 —— 0 读起来是"申报与实收一致"。实得 %', v_num;
    END IF;
    IF 'declared_vs_actual' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87E1 没记申报量就【不下任何断言】,不许报 declared_vs_actual。实得 %', v_kinds;
    END IF;

    -- E2 · 记了、且相符 → delta 是【数字 0】(不是 NULL),不报 kind。
    --      这一条把"没记"与"记了个 0 差额"分开 —— 少了它,E1 可以靠
    --      "永远返回 NULL" 的实现通过。
    SELECT (receive_inbound_batch_against_po(
                p_material_id => mat_a, p_supplier_id => sup, p_quantity => 1000,
                p_arrival_date => '2026-05-02', p_purchase_order_id => po_misc,
                p_purchase_order_line_id => l_dsame, p_declared_qty => 1000) ->> 'batch_id')::uuid
      INTO b_dsame;
    SELECT declared_delta_qty, kinds INTO v_num, v_kinds FROM grn_discrepancies WHERE batch_id = b_dsame;
    IF v_num IS NULL OR v_num <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 87E2 记了申报量 1000、实收 1000 → delta 必须是数字 0,实得 %', v_num;
    END IF;
    IF 'declared_vs_actual' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87E2 申报与实收相符,不许报 declared_vs_actual。实得 %', v_kinds;
    END IF;

    -- E3 · 记了、且差得超阈值 → 报。申报 1000、实收 800(短 20% > 10%)。
    SELECT (receive_inbound_batch_against_po(
                p_material_id => mat_a, p_supplier_id => sup, p_quantity => 800,
                p_arrival_date => '2026-05-02', p_purchase_order_id => po_misc,
                p_purchase_order_line_id => l_dgap, p_declared_qty => 1000) ->> 'batch_id')::uuid
      INTO b_dgap;
    SELECT declared_delta_qty, kinds INTO v_num, v_kinds FROM grn_discrepancies WHERE batch_id = b_dgap;
    IF v_num <> -200 THEN
        RAISE EXCEPTION 'FIXTURE 87E3 实收 800 − 申报 1000 = −200,实得 %', v_num;
    END IF;
    IF NOT ('declared_vs_actual' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87E3 申报 1000 / 实收 800(差 20%% > 阈值 10%%)必须报 declared_vs_actual,实得 %', v_kinds;
    END IF;
    RAISE NOTICE '87E 申报量:没记=NULL(不是订量、不是 0)、相符=数字 0、超差=报 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- F. 收错料【被点名,但绝不被拒绝】—— ⑥
    --    换料是可以谈成的正当场景;拒绝会把它变成一次不可能完成的收货。
    --    但它也正是"谎报货物性质"在技术上的样子,所以必须【被点名】。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_misc, 4, mat_a, 1000, 'kg') RETURNING id INTO l_mis;
    v_denied := false; v_msg := NULL;
    BEGIN
        SELECT (receive_inbound_batch_against_po(
                    p_material_id => mat_b, p_supplier_id => sup, p_quantity => 1000,
                    p_arrival_date => '2026-05-02', p_purchase_order_id => po_misc,
                    p_purchase_order_line_id => l_mis) ->> 'batch_id')::uuid
          INTO b_mis;
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 87F 收错料【不许拒绝】—— 换料是可以谈成的场景。实得拒绝:%', v_msg;
    END IF;
    SELECT kinds, ordered_material_code, received_material_code
      INTO v_kinds, v_msg, v_msg FROM grn_discrepancies WHERE batch_id = b_mis;
    IF NOT ('material_mismatch' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87F 收错料必须【被点名】material_mismatch —— 不拒绝不等于不说。实得 %', v_kinds;
    END IF;
    -- 两个料号都要在行上,否则页面说得出"错了"却说不出"错成什么"
    SELECT ordered_material_code || '→' || received_material_code INTO v_msg
      FROM grn_discrepancies WHERE batch_id = b_mis;
    IF v_msg <> 'FX87-MA→FX87-MB' THEN
        RAISE EXCEPTION 'FIXTURE 87F 行上必须同时带订的料与收的料,实得 %', v_msg;
    END IF;
    RAISE NOTICE '87F 收错料:不拒绝,但按名点出 material_mismatch,并带两个料号 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- G. 没挂采购行 → 【整行缺席】,不是一行零 —— ④
    --    这是 work_order_fulfilment 的 has_plan 那一条:没估过 ≠ 估了零。
    --    一个 COALESCE(pol.quantity, 0) 的实现会让【每一次自采收货】都成为
    --    一次 100% 超收 —— 而那不会报错,只会多出一堆假差异。
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT (create_inbound_batch(
                p_material_id => mat_a, p_supplier_id => sup, p_quantity => 5000,
                p_arrival_date => '2026-05-02') ->> 'batch_id')::uuid
      INTO b_nopo;
    -- 前提自证:这一批确实【存在、有量、且真的没挂采购行】——
    -- 否则"视图里没有它"可能只是因为它根本没被建出来。
    SELECT (purchase_order_line_id IS NULL AND quantity = 5000) INTO v_bool
      FROM inbound_batches WHERE id = b_nopo;
    IF v_bool IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 87G 无效:自采批次没建出来、或它其实挂着采购行 —— 那样测不到缺席';
    END IF;
    SELECT EXISTS (SELECT 1 FROM grn_discrepancies WHERE batch_id = b_nopo) INTO v_found;
    IF v_found THEN
        SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_nopo;
        RAISE EXCEPTION 'FIXTURE 87G 没挂采购行的批次必须【整行不在视图里】,而不是带着一行零出现。实得 kinds = %', v_kinds;
    END IF;
    RAISE NOTICE '87G 自采收货(5000,无采购行)整行缺席,不是一行 100%% 超收 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- H. expected_assay 缺失 → 【不下断言】,是 NULL 不是 false —— ⑤ 的另一半
    --    false 的意思是"比过了,在容差内";NULL 的意思是"没得比"。
    --    页面据此印「未申报」而不是「合格」,那是两句完全不同的话。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, expected_assay)
    VALUES (po_assay, 1, mat_a, 1000, 'kg', NULL) RETURNING id INTO l_noexp;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-HNOEXP', mat_a, sup, 1000, 'kg', 1000, '2026-05-02', po_assay, l_noexp) RETURNING id INTO b_noexp;
    -- 【化验这一侧是齐的】—— 缺的只有预期。少了这一句,这一臂会因为"两侧都没有"
    -- 而空转通过,证明不了"缺预期时不下断言"。
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('FX87-AS-NOEXP', b_noexp, '2026-05-03', now()) RETURNING id INTO a;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 15);

    SELECT assay_beyond_tolerance, assay_metals_compared, kinds
      INTO v_bool, v_int, v_kinds FROM grn_discrepancies WHERE batch_id = b_noexp;
    IF v_bool IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 87H 没有 expected_assay 时 assay_beyond_tolerance 必须是 NULL(没得比),不是 %(那是"比过了"的意思)', v_bool;
    END IF;
    IF v_int IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 87H 一种金属都没比,metals_compared 必须是 NULL,实得 %', v_int;
    END IF;
    IF 'assay_beyond_tolerance' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87H 没得比就不许报超差,实得 %', v_kinds;
    END IF;

    -- H2 · 【录了但没 apply 的化验不算数】—— 一份没应用的化验还不是这批货的事实,
    --      它连计价都没参与。这一臂用【有预期】的行,所以缺的只有"已应用"。
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, expected_assay)
    VALUES (po_assay, 2, mat_a, 1000, 'kg', '[{"metal":"ni","content_pct":10}]'::jsonb)
    RETURNING id INTO l_unap;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-HUNAP', mat_a, sup, 1000, 'kg', 1000, '2026-05-02', po_assay, l_unap) RETURNING id INTO b_unap;
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('FX87-AS-UNAP', b_unap, '2026-05-03', NULL) RETURNING id INTO a;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 50);
    SELECT assay_beyond_tolerance INTO v_bool FROM grn_discrepancies WHERE batch_id = b_unap;
    IF v_bool IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 87H2 没应用的化验(ni 50%% vs 预期 10%%)不许产生断言,必须是 NULL,实得 %', v_bool;
    END IF;
    RAISE NOTICE '87H 缺预期 / 未应用 —— 都是 NULL(没得比),不是 false(比过了)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- I. 化验边界:【相对偏差】,阈值 10%,两个方向各取 ±1
    --    预期 10:实际 11 → 恰好 10%(不报,严格大于);实际 11.1 → 11%(报);
    --             实际 9  → 恰好 10%(不报,反方向);实际 8.9 → 11%(报,反方向)。
    --    【为什么两个方向都要】|实际 − 预期| 里的绝对值是一个极容易写丢的东西,
    --    写成 (实际 − 预期) 之后【所有偏低的化验都会静默地变成"在容差内"】——
    --    而偏低才是花了钱没买到东西的那一种。只测偏高的用例抓不到它。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, expected_assay)
    VALUES (po_assay, 3, mat_a, 1000, 'kg', '[{"metal":"ni","content_pct":10}]'::jsonb) RETURNING id INTO l_as_eq;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, expected_assay)
    VALUES (po_assay, 4, mat_a, 1000, 'kg', '[{"metal":"ni","content_pct":10}]'::jsonb) RETURNING id INTO l_as_hi;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, expected_assay)
    VALUES (po_assay, 5, mat_a, 1000, 'kg', '[{"metal":"ni","content_pct":10}]'::jsonb) RETURNING id INTO l_as_lo;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, expected_assay)
    VALUES (po_assay, 6, mat_a, 1000, 'kg', '[{"metal":"ni","content_pct":10}]'::jsonb) RETURNING id INTO l_as_loin;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-IEQ', mat_a, sup, 1000, 'kg', 1000, '2026-05-02', po_assay, l_as_eq) RETURNING id INTO b_as_eq;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-IHI', mat_a, sup, 1000, 'kg', 1000, '2026-05-02', po_assay, l_as_hi) RETURNING id INTO b_as_hi;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-ILOEQ', mat_a, sup, 1000, 'kg', 1000, '2026-05-02', po_assay, l_as_lo) RETURNING id INTO b_as_lo;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX87-ILO', mat_a, sup, 1000, 'kg', 1000, '2026-05-02', po_assay, l_as_loin) RETURNING id INTO b_as_loin;

    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('FX87-AS-EQ', b_as_eq, '2026-05-03', now()) RETURNING id INTO a;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 11);
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('FX87-AS-HI', b_as_hi, '2026-05-03', now()) RETURNING id INTO a;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 11.1);
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('FX87-AS-LOEQ', b_as_lo, '2026-05-03', now()) RETURNING id INTO a;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 9);
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, applied_at)
    VALUES ('FX87-AS-LO', b_as_loin, '2026-05-03', now()) RETURNING id INTO a;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a, 'ni', 8.9);

    SELECT assay_beyond_tolerance, assay_metals_compared INTO v_bool, v_int
      FROM grn_discrepancies WHERE batch_id = b_as_eq;
    IF v_int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 87I 无效:该比 1 种金属,实比 % 种 —— 前提没摆对', v_int;
    END IF;
    IF v_bool IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 87I 预期 10 / 实际 11 = 【恰好 10%%】相对偏差,不许报超差(谓词是严格大于)。实得 %', v_bool;
    END IF;
    SELECT assay_beyond_tolerance, kinds INTO v_bool, v_kinds
      FROM grn_discrepancies WHERE batch_id = b_as_hi;
    IF v_bool IS NOT TRUE OR NOT ('assay_beyond_tolerance' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87I 预期 10 / 实际 11.1 = 11%% 偏差,必须报超差。实得 % / %', v_bool, v_kinds;
    END IF;
    SELECT assay_beyond_tolerance INTO v_bool FROM grn_discrepancies WHERE batch_id = b_as_lo;
    IF v_bool IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 87I 预期 10 / 实际 9 = 恰好 10%%(偏【低】方向),不许报超差。实得 %', v_bool;
    END IF;
    SELECT assay_beyond_tolerance INTO v_bool FROM grn_discrepancies WHERE batch_id = b_as_loin;
    IF v_bool IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 87I 预期 10 / 实际 8.9 = 11%% 偏【低】,必须报超差 —— 丢了绝对值的实现会让所有偏低的化验静默合格,而偏低才是花了钱没买到东西的那一种。实得 %', v_bool;
    END IF;
    RAISE NOTICE '87I 化验边界 11 / 11.1 / 9 / 8.9(预期 10)—— 不报/报/不报/报,两个方向都守住 ✓';

    -- D3 · 化验那一列也现读 —— 把容差从 10 收到 5,恰好 10%% 的那两条都要翻面。
    UPDATE receiving_settings SET grn_assay_tolerance_pct = 5;
    SELECT assay_beyond_tolerance INTO v_bool FROM grn_discrepancies WHERE batch_id = b_as_eq;
    IF v_bool IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 87D3 容差改成 5%% 之后,10%% 的偏差必须报超差 —— 没翻面说明容差是写死的。实得 %', v_bool;
    END IF;
    SELECT assay_beyond_tolerance INTO v_bool FROM grn_discrepancies WHERE batch_id = b_as_lo;
    IF v_bool IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 87D3 偏低方向同样要跟着容差翻面,实得 %', v_bool;
    END IF;
    -- 只动了容差 → 数量那两个结论必须原地不动
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_901;
    IF 'short' = ANY (v_kinds) THEN
        RAISE EXCEPTION 'FIXTURE 87D3 只改了 grn_assay_tolerance_pct,901/1000 的 short 结论不许跟着动。实得 %', v_kinds;
    END IF;
    UPDATE receiving_settings SET grn_assay_tolerance_pct = 10;
    RAISE NOTICE '87D3 化验容差现读,且不牵动数量那两列 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- J. 一条收货可以【同时】几种 —— 数组不是装饰
    --    kinds 若是一个 text 列,装得下的那一种会把装不下的静默丢掉。
    --    这一条收货同时:超收、收错料、申报量对不上。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_open, 4, mat_a, 1000, 'kg') RETURNING id INTO l_dsame;   -- 变量复用,与 E2 无关
    SELECT (receive_inbound_batch_against_po(
                p_material_id => mat_b, p_supplier_id => sup, p_quantity => 2000,
                p_arrival_date => '2026-05-02', p_purchase_order_id => po_open,
                p_purchase_order_line_id => l_dsame, p_declared_qty => 1000) ->> 'batch_id')::uuid
      INTO b_dsame;
    SELECT kinds INTO v_kinds FROM grn_discrepancies WHERE batch_id = b_dsame;
    IF NOT ('over' = ANY (v_kinds) AND 'material_mismatch' = ANY (v_kinds)
            AND 'declared_vs_actual' = ANY (v_kinds)) THEN
        RAISE EXCEPTION 'FIXTURE 87J 一条收货同时超收 + 收错料 + 申报对不上,三种都必须在 kinds 里 —— 一个 text 列会静默丢掉两种。实得 %', v_kinds;
    END IF;
    IF cardinality(v_kinds) < 3 THEN
        RAISE EXCEPTION 'FIXTURE 87J kinds 至少三项,实得 %', v_kinds;
    END IF;
    RAISE NOTICE '87J 一条收货同时三种,一种都没丢 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- K. 属主权限 + module.purchasing.view —— 无权者【读不到】,而不是读到零差异
    --    OPS-14 的那一课:invoker 跨模块不是限制,是撒谎。这里换的是 claims
    --    不是数据库角色,理由见文件抬头。
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO n FROM grn_discrepancies;
    IF n < 10 THEN
        RAISE EXCEPTION 'FIXTURE 87K 无效:全权读者只看到 % 行,基线太小,证明不了"另一个读者看到 0 行"是权限而不是没数据', n;
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_none), true);
    SELECT count(*) INTO v_int FROM grn_discrepancies;
    IF v_int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 87K 不持 module.purchasing.view 的读者必须读到 0 行(订量本来就在那道门后面),实得 % 行', v_int;
    END IF;
    -- 前提自证:这个读者【看得见批次本身】—— 否则 0 行可能只是因为他什么都看不见
    SELECT count(*) INTO n FROM inbound_batches_masked WHERE supplier_id = sup;
    IF n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 87K 无效:这个读者连批次都看不见,那 0 行差异证明不了是 purchasing 那道门';
    END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    RAISE NOTICE '87K 无 purchasing.view 读到 0 行差异,而【同一个读者看得见 % 个批次】✓', n;

    RAISE NOTICE 'FIXTURE 87 全部通过';
END $$;
ROLLBACK;

-- db/fixtures/100-a-receiving-clerk-can-name-what-he-receives.sql
-- FIX-1 item 3 的行为断言。全部在一个事务里,结尾 RAISE 把报告带出来并回滚。
--
-- 【钉四件事,两个方向都要】
--   A 正对照:warehouse 现在【叫得出】供应商 / 物料 / 客户 / 可收货的采购单行;
--   B 反对照:hr 与一个零权限账号【仍然叫不出】—— 四张视图对他们都是 0 行;
--   C ★ 窄对照:warehouse 【仍然读不到】suppliers / materials / customers 基表。
--     没有这一条,A 就只证明了"他现在看得见",没有证明"他没有多看见"。
--     「A proof that passes by refusing everything is not a proof.」——
--     而它的对偶同样成立:一个只证明放行的证明,证明不了没有放宽。
--   D 一致对照:对持 purchasing.view 的读者,新旧两张采购单行视图给出【同一组 line_id】。
--     两份"可收货"的定义从此有两个实现,这一条是把它们钉在一起的东西。
--
-- 【收尾用 BEGIN/ROLLBACK + RAISE NOTICE,不是结尾 RAISE EXCEPTION】
-- 门(db/gate.py)把 fixture 跑在重建库上,并且【自己】数事务前后的行数来查泄漏 ——
-- 一支以 RAISE EXCEPTION 结尾的 fixture 在它眼里就是失败。★ 本文件第一版正是那样写的
-- (那是 Management API 单跑时的写法:要靠报错把报告带出来),而门当场判了它红。
-- 报告改走 NOTICE;RAISE EXCEPTION 从此【只表示断言真的没过】。
BEGIN;

DO $fix1$
DECLARE
    r  jsonb := '{}'::jsonb;
    n  bigint;
    u_wh   uuid := '00000000-0000-4000-8000-0000f1c10001';
    u_hr   uuid := '00000000-0000-4000-8000-0000f1c10002';
    u_none uuid := '00000000-0000-4000-8000-0000f1c10003';
    u_proc uuid := '00000000-0000-4000-8000-0000f1c10004';
    v_po   uuid;
    v_line uuid;
    v_mat  uuid;
    v_sup  uuid;
    v_cus  uuid;
    a text[]; b text[];
BEGIN
    -- ── 设置:四个合成账号。user_roles.user_id 是裸 uuid(没有 FK),
    --    所以不需要 auth.users 行 —— 本 fixture 不碰任何 employees。
    INSERT INTO user_roles (user_id, role_id) SELECT u_wh,   id FROM roles WHERE code = 'warehouse';
    INSERT INTO user_roles (user_id, role_id) SELECT u_hr,   id FROM roles WHERE code = 'hr';
    INSERT INTO user_roles (user_id, role_id) SELECT u_proc, id FROM roles WHERE code = 'procurement';
    -- u_none 刻意【不】授任何角色。

    -- ══ 设置:本 fixture 【自己造】它要的每一行 ═══════════════════════════
    -- ★ 这一段原本是 `SELECT … FROM suppliers … LIMIT 1`,而【门当场把它判红了】:
    --   gate 把 fixture 跑在【从镜像重建出来的库】上,那里只有引导种子 ——
    --   没有供应商、没有物料、没有客户。一支借线上数据的 fixture 在那里
    --   不是"失败",是【根本立不起来】。
    --   ★ 而更坏的一种可能是它【没有】立不起来:线上今天 confirmed/receiving
    --     的采购单本来就是 0 张,所以 D 条那个"新旧两张视图给出同一组行"的比较
    --     会靠【两边都是空集】假绿。所以 D 条里有一句非空断言(FIX1_D_VACUOUS)。
    --   自己造行,两个问题一起没有了:它在线上与在重建库上跑出同一个结论。
    -- supplies_goods 是【生成列】(= counterparty_type = 'goods_supplier'),写不得 ——
    -- 所以这里给的是 counterparty_type,供货这件事由库自己推出来。
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
        VALUES ('ZZ-FIX1-SUP', 'ZZ FIX1 Supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    -- materials_kind_stated:kind_code 与 may_be_processed 两个都要说出来。
    -- 取 consumable 而【不是】battery_material:后者被 guard_material_condition_axes
    -- 要求同时说出形态与来源(MATERIAL_CONDITION_AXES_REQUIRED),而本 fixture
    -- 问的是叫不叫得出名字,与那两条轴无关 —— 造一行最简单的合法物料就够。
    INSERT INTO materials (code, name, kind_code, may_be_processed)
        VALUES ('ZZ-FIX1-MAT', 'ZZ FIX1 Material', 'consumable', false) RETURNING id INTO v_mat;
    INSERT INTO customers (code, legal_name, country)
        VALUES ('ZZ-FIX1-CUS', 'ZZ FIX1 Customer', 'SG') RETURNING id INTO v_cus;
    -- fx_rate 是 NOT NULL 且没有默认值(实测,不是照抄别的 fixture 猜的)。
    INSERT INTO purchase_orders (code, supplier_id, order_date, status, currency, fx_rate)
        VALUES ('ZZ-FIX1-PO', v_sup, CURRENT_DATE, 'confirmed', 'SGD', 1) RETURNING id INTO v_po;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
        VALUES (v_po, 1, v_mat, 1000, 'kg') RETURNING id INTO v_line;

    -- ══ A · 正对照 —— warehouse 叫得出 ══════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', json_build_object('sub', u_wh, 'role', 'authenticated')::text, true);

    r := r || jsonb_build_object('A_wh_has_inbound_view', has_permission('module.inbound.view'));
    r := r || jsonb_build_object('A_wh_has_suppliers_view', has_permission('module.suppliers.view'));

    -- 【按 id 断言,不按"大于零"】—— 数一个我们没造的集合,等于把断言挂在
    --   线上今天恰好有多少行上面。这四条问的都是"我造的那一行,他看得见吗"。
    SELECT count(*) INTO n FROM supplier_lookup WHERE id = v_sup AND supplies_goods;
    r := r || jsonb_build_object('A_wh_supplier_lookup', n);
    IF n <> 1 THEN RAISE EXCEPTION 'FIX1_A_FAILED|warehouse still cannot name a goods supplier'; END IF;

    SELECT count(*) INTO n FROM material_lookup WHERE id = v_mat;
    r := r || jsonb_build_object('A_wh_material_lookup', n);
    IF n <> 1 THEN RAISE EXCEPTION 'FIX1_A_FAILED|warehouse still cannot name a material'; END IF;

    SELECT count(*) INTO n FROM customer_lookup WHERE id = v_cus;
    r := r || jsonb_build_object('A_wh_customer_lookup', n);
    IF n <> 1 THEN RAISE EXCEPTION 'FIX1_A_FAILED|warehouse still cannot name a customer'; END IF;

    SELECT count(*) INTO n FROM po_receivable_lines_lookup WHERE line_id = v_line;
    r := r || jsonb_build_object('A_wh_po_lookup_sees_our_line', n);
    IF n <> 1 THEN RAISE EXCEPTION 'FIX1_A_FAILED|warehouse cannot see the receivable PO line'; END IF;

    -- ══ C · 窄对照 —— 他【没有】因此读到基表 ════════════════════════════════
    -- ★ 这四条是"没有把任何人的数据面放宽到需要之外"的全部证据。
    SELECT count(*) INTO n FROM suppliers WHERE id = v_sup;   r := r || jsonb_build_object('C_wh_suppliers_base', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_C_FAILED|warehouse can now read the suppliers base table'; END IF;
    SELECT count(*) INTO n FROM materials WHERE id = v_mat;   r := r || jsonb_build_object('C_wh_materials_base', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_C_FAILED|warehouse can now read the materials base table'; END IF;
    SELECT count(*) INTO n FROM customers WHERE id = v_cus;   r := r || jsonb_build_object('C_wh_customers_base', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_C_FAILED|warehouse can now read the customers base table'; END IF;
    SELECT count(*) INTO n FROM po_receivable_lines; r := r || jsonb_build_object('C_wh_po_receivable_lines_old', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_C_FAILED|warehouse can now read the priced po_receivable_lines'; END IF;
    -- 而 grn_discrepancies 【刻意】没有跟着放宽(见迁移抬头)。
    SELECT count(*) INTO n FROM grn_discrepancies; r := r || jsonb_build_object('C_wh_grn_discrepancies', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_C_FAILED|grn_discrepancies widened as a side effect'; END IF;

    -- ══ B · 反对照 —— hr 与零权限账号仍然叫不出 ═════════════════════════════
    PERFORM set_config('request.jwt.claims', json_build_object('sub', u_hr, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO n FROM supplier_lookup WHERE id = v_sup;  r := r || jsonb_build_object('B_hr_supplier_lookup', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_B_FAILED|hr can name suppliers'; END IF;
    SELECT count(*) INTO n FROM material_lookup WHERE id = v_mat;  r := r || jsonb_build_object('B_hr_material_lookup', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_B_FAILED|hr can name materials'; END IF;
    SELECT count(*) INTO n FROM customer_lookup WHERE id = v_cus;  r := r || jsonb_build_object('B_hr_customer_lookup', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_B_FAILED|hr can name customers'; END IF;
    SELECT count(*) INTO n FROM po_receivable_lines_lookup; r := r || jsonb_build_object('B_hr_po_lookup', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_B_FAILED|hr can see receivable PO lines'; END IF;

    PERFORM set_config('request.jwt.claims', json_build_object('sub', u_none, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO n FROM supplier_lookup WHERE id = v_sup;  r := r || jsonb_build_object('B_none_supplier_lookup', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_B_FAILED|a role-less account can name suppliers'; END IF;
    SELECT count(*) INTO n FROM po_receivable_lines_lookup; r := r || jsonb_build_object('B_none_po_lookup', n);
    IF n <> 0 THEN RAISE EXCEPTION 'FIX1_B_FAILED|a role-less account can see receivable PO lines'; END IF;

    -- ══ D · 一致对照 —— 两份"可收货"的定义必须给出同一组行 ══════════════════
    PERFORM set_config('request.jwt.claims', json_build_object('sub', u_proc, 'role', 'authenticated')::text, true);
    SELECT array_agg(line_id::text ORDER BY line_id) INTO a FROM po_receivable_lines;
    SELECT array_agg(line_id::text ORDER BY line_id) INTO b FROM po_receivable_lines_lookup;
    r := r || jsonb_build_object('D_proc_old_rows', coalesce(array_length(a,1),0),
                                 'D_proc_new_rows', coalesce(array_length(b,1),0));
    IF coalesce(array_length(a,1),0) = 0 THEN
        RAISE EXCEPTION 'FIX1_D_VACUOUS|procurement saw no receivable lines — the comparison proves nothing';
    END IF;
    IF a IS DISTINCT FROM b THEN
        RAISE EXCEPTION 'FIX1_D_FAILED|po_receivable_lines and _lookup disagree on which lines are receivable';
    END IF;

    RESET ROLE;
    RAISE NOTICE 'FIXTURE 100 报告:%', r::text;
    RAISE NOTICE 'FIXTURE 100 全部通过 —— 收货的人叫得出他要收的东西,而没有多看见任何一行';
END
$fix1$;

ROLLBACK;

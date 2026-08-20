-- 98 一个箱子装两个客户的货 —— 而它【不改变任何一张订单的答案】
--
-- LOG-2a 的全部赌注就在这一句上。设计选的是"在 shipments 之上加一层",
-- 理由正是"那样一个既有读者都不用碰";若挂进箱子会让完成度判据变一个答案,
-- 这个理由当场作废。**所以这里对着 sales_order_fulfilment_status 前后各问一次。**
--
-- 【发货单在这里是直接 INSERT 的,不走 ship_order】。本 fixture 要证的是
-- 集装箱这一层,不是发货那一层(那是 fixture 68/69 的活)。走完整的 ship_order
-- 需要发票、预留、产出批、销售记录一整套 —— 它们与"装箱改不改答案"这句话无关。
-- 代价照实说:这里的两张订单都处在 partially_shipped,前后一致 ——
-- **本臂断言的是【前后相同】,不是那个值本身是什么。**
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u uuid := gen_random_uuid(); r uuid;
    cus_a uuid; cus_b uuid; so_a uuid; so_b uuid; mat uuid;
    ctr uuid; ctr2 uuid; shp_a uuid; shp_b uuid; shp_free uuid;
    fwd uuid; goods uuid; p1 uuid; p2 uuid; lane uuid; lane_empty uuid; lane_none uuid;
    before_a text; before_b text; after_a text; after_b text;
    v_msg text; v_denied boolean; v_n integer; v_res jsonb; v_ship_date date;
BEGIN
    INSERT INTO auth.users (id) VALUES (u);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-98','f98','f98',true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r,'module.purchasing.view'), (r,'module.purchasing.edit'),
        (r,'module.sales.view'), (r,'module.sales.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u), true);

    INSERT INTO materials (code, name, category) VALUES ('FX98-MAT','fixture 98','copper') RETURNING id INTO mat;
    INSERT INTO customers (code, legal_name, country) VALUES ('FX98-CA','fixture 98 customer A','SG') RETURNING id INTO cus_a;
    INSERT INTO customers (code, legal_name, country) VALUES ('FX98-CB','fixture 98 customer B','SG') RETURNING id INTO cus_b;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, status)
    -- 【留在 draft】:确认之后订单行就不可改了(guard_sales_order_line_confirmed_immutable),
    -- 而本 fixture 要的是有行可数,不是走完销售流程 —— 完成度判据不读 status。
    VALUES ('FX98-SOA', cus_a, CURRENT_DATE, 'USD', 1.35, 'draft') RETURNING id INTO so_a;
    INSERT INTO sales_orders (code, customer_id, order_date, currency, fx_rate, status)
    VALUES ('FX98-SOB', cus_b, CURRENT_DATE, 'USD', 1.35, 'draft') RETURNING id INTO so_b;
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_a, 1, mat, 100, 5);
    INSERT INTO sales_order_lines (sales_order_id, line_no, material_id, quantity, unit_price)
    VALUES (so_b, 1, mat, 200, 5);

    v_ship_date := CURRENT_DATE;
    INSERT INTO shipments (code, sales_order_id, ship_date) VALUES ('FX98-SHPA', so_a, v_ship_date) RETURNING id INTO shp_a;
    INSERT INTO shipments (code, sales_order_id, ship_date) VALUES ('FX98-SHPB', so_b, v_ship_date) RETURNING id INTO shp_b;
    INSERT INTO shipments (code, sales_order_id, ship_date) VALUES ('FX98-SHPF', so_a, v_ship_date) RETURNING id INTO shp_free;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX98-FWD','fixture 98 forwarder','SG','forwarder') RETURNING id INTO fwd;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX98-GDS','fixture 98 goods','SG','goods_supplier') RETURNING id INTO goods;
    INSERT INTO ports (code, name) VALUES ('FX98PA','port a') RETURNING id INTO p1;
    INSERT INTO ports (code, name) VALUES ('FX98PB','port b') RETURNING id INTO p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (p1, p2) RETURNING id INTO lane;

    INSERT INTO containers (code, container_number, departure_date, lane_id, forwarder_id)
    VALUES (next_container_code(CURRENT_DATE), 'MSCU0000001', CURRENT_DATE, lane, fwd) RETURNING id INTO ctr;

    -- ══════════ A. 两个客户装一个箱子,而两张订单的答案【一个字不变】 ═══════
    before_a := sales_order_fulfilment_status(so_a);
    before_b := sales_order_fulfilment_status(so_b);

    PERFORM attach_shipment_to_container(shp_a, ctr);
    PERFORM attach_shipment_to_container(shp_b, ctr);

    SELECT count(DISTINCT o.customer_id) INTO v_n
      FROM shipments s JOIN sales_orders o ON o.id = s.sales_order_id
     WHERE s.container_id = ctr;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 98A 前提不成立:这个箱子应当装着 2 个客户的货,实得 %', v_n;
    END IF;

    after_a := sales_order_fulfilment_status(so_a);
    after_b := sales_order_fulfilment_status(so_b);
    IF after_a IS DISTINCT FROM before_a OR after_b IS DISTINCT FROM before_b THEN
        RAISE EXCEPTION 'FIXTURE 98A 失败:装箱改变了订单的完成度答案(A:% → %,B:% → %)—— 整个"加一层"的理由就没了',
            before_a, after_a, before_b, after_b;
    END IF;
    RAISE NOTICE '98A 一箱两客户,两张订单的完成度一个字未变(A=% B=%)✓', after_a, after_b;

    -- ══════════ B. 没装箱的发货单,行为与从前一模一样 ═══════════════════════
    IF (SELECT container_id FROM shipments WHERE id = shp_free) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 98B 前提不成立:这一张本该没装箱';
    END IF;
    -- 只增不改仍然对它成立:改 ship_date 必须被拒
    v_denied := false;
    BEGIN
        UPDATE shipments SET ship_date = CURRENT_DATE + 1 WHERE id = shp_free;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('SHIPMENT_IMMUTABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 98B 失败:发货单的其它列仍然必须不可改 —— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '98B 未装箱的发货单照旧,而且只增不改仍然守着其它列 ✓';

    -- ══════════ C. 装箱的两种按名拒绝 ═══════════════════════════════════════
    INSERT INTO containers (code, departure_date) VALUES (next_container_code(CURRENT_DATE), CURRENT_DATE) RETURNING id INTO ctr2;
    PERFORM soft_delete_container(ctr2, '测试:注销过的箱子不能再装货');
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM attach_shipment_to_container(shp_free, ctr2);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('CONTAINER_NOT_FOUND' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 98C 失败:往一个已注销的箱子里装货没有按名拒绝 —— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO containers (code, departure_date, forwarder_id)
        VALUES (next_container_code(CURRENT_DATE), CURRENT_DATE, goods);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('CONTAINER_FORWARDER_NOT_A_FORWARDER' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 98C 失败:把供货商挂成箱子的承运方没有按名拒绝 —— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '98C 已注销的箱子、不是货代的承运方,两种都按名拒绝 ✓';

    -- ══════════ D. 里程碑:日期必填、只增不改 ═══════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO container_milestones (container_id, milestone) VALUES (ctr, 'departed');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 98D 失败:不给 event_date 竟然记得进里程碑 —— 那个默认值正是不该有的东西';
    END IF;

    INSERT INTO container_milestones (container_id, milestone, event_date, note)
    VALUES (ctr, 'departed', CURRENT_DATE, '船开了');
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE container_milestones SET note = '改一下' WHERE container_id = ctr AND milestone = 'departed';
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('CONTAINER_MILESTONE_IMMUTABLE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 98D 失败:里程碑竟然改得动 —— 更正必须靠追加。实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    -- 更正 = 追加一行
    INSERT INTO container_milestones (container_id, milestone, event_date, note)
    VALUES (ctr, 'departed', CURRENT_DATE - 1, '更正:实际是前一天开的');
    SELECT count(*) INTO v_n FROM container_milestones WHERE container_id = ctr AND milestone = 'departed';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 98D 失败:更正应当留下两行,实得 % 行', v_n;
    END IF;
    RAISE NOTICE '98D 日期必填、改不动、更正靠追加 ✓';

    -- ══════════ E. 单据清单:三种航段状态、n/a 要理由 ═══════════════════════
    INSERT INTO lane_document_requirements (lane_id, document_type, regime)
    VALUES (lane, 'fixture 98 movement doc', 'fixture 98 regime');
    UPDATE lanes SET checklist_reviewed_at = now() WHERE id = lane;
    v_res := instantiate_container_documents(ctr);
    IF (v_res->>'lane_state') <> 'defined' OR (v_res->>'created')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 98E 失败:有要求的航段应当实例化 1 条,实得 %', v_res::text;
    END IF;

    -- not_defined:【不能被答成"零条"】
    INSERT INTO ports (code, name) VALUES ('FX98PC','port c') RETURNING id INTO p1;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (p2, p1) RETURNING id INTO lane_none;
    INSERT INTO containers (code, departure_date, lane_id)
    VALUES (next_container_code(CURRENT_DATE), CURRENT_DATE, lane_none) RETURNING id INTO ctr2;
    v_res := instantiate_container_documents(ctr2);
    IF (v_res->>'lane_state') <> 'not_defined' THEN
        RAISE EXCEPTION 'FIXTURE 98E 失败:没人定过清单的航段必须原样说出 not_defined,实得 % —— 折叠成"零条"就是把"没人看过"说成"齐了"', v_res::text;
    END IF;

    -- defined_empty:一个【被记下来的决定】
    UPDATE lanes SET checklist_reviewed_at = now() WHERE id = lane_none;
    v_res := instantiate_container_documents(ctr2);
    IF (v_res->>'lane_state') <> 'defined_empty' THEN
        RAISE EXCEPTION 'FIXTURE 98E 失败:确认过且确实没有要求,应当是 defined_empty,实得 %', v_res::text;
    END IF;

    -- n/a 没有理由:按名拒绝
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE container_documents SET status = 'not_applicable'
         WHERE container_id = ctr AND document_type = 'fixture 98 movement doc';
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('CONTAINER_DOC_NA_REASON_REQUIRED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 98E 失败:判"不适用"不给理由没有按名拒绝 —— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '98E 三种航段状态分得开,n/a 没理由被按名拒绝 ✓';

    RAISE NOTICE 'FIXTURE 98 全部通过';
END $$;
ROLLBACK;

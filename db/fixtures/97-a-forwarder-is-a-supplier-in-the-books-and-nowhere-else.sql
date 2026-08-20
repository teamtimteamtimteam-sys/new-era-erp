-- 97 货代在【账上】就是一个供应商,在【名单上】哪儿都不是
--
-- LOG-1a。货代保留 supplier id,是为了让应付账龄、付款分摊、外币重估整条链
-- 一个字都不用改 —— **这正是本 fixture 要证明的那件事,而不是假设的那件事**。
-- 同时:supplies_goods 从一个可写的标记变成 counterparty_type 的【派生列】,
-- 于是"改类型 → 派生列跟着动"与"直接写派生列 → 被拒"两句话都要有断言。
--
-- ⚠ 每一条可见性断言都切 authenticated:fixture 以 postgres 跑,postgres 绕过 RLS。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_fin uuid := gen_random_uuid();
    r_fin uuid;
    s_goods uuid; s_fwd uuid;
    p_a uuid; p_b uuid; v_lane uuid;
    v_fd uuid; v_pay uuid;
    v_n integer; v_open numeric; v_state text; v_msg text; v_denied boolean;
    v_bool boolean; v_prev jsonb;
BEGIN
    INSERT INTO auth.users (id) VALUES (u_fin);
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-97', 'f97', 'f97', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.view'), (r_fin, 'module.purchasing.view'),
        (r_fin, 'module.purchasing.edit'), (r_fin, 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX97-GOODS', 'fixture 97 goods supplier', 'SG', 'goods_supplier') RETURNING id INTO s_goods;
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX97-FWD', 'fixture 97 forwarder', 'SG', 'forwarder') RETURNING id INTO s_fwd;

    -- ══════════ A. 派生列双向跟随,且不可直写 ═══════════════════════════════
    SELECT supplies_goods INTO v_bool FROM suppliers WHERE id = s_goods;
    IF v_bool IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 97A goods_supplier 的 supplies_goods 应当为 true,实得 %', v_bool;
    END IF;
    SELECT supplies_goods INTO v_bool FROM suppliers WHERE id = s_fwd;
    IF v_bool IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 97A forwarder 的 supplies_goods 应当为 false,实得 %', v_bool;
    END IF;

    -- 改类型 → 派生列必须跟着动(【两个方向都试】,单向会漏掉一个只在一边成立的表达式)
    UPDATE suppliers SET counterparty_type = 'forwarder' WHERE id = s_goods;
    SELECT supplies_goods INTO v_bool FROM suppliers WHERE id = s_goods;
    IF v_bool IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 97A 改成 forwarder 之后 supplies_goods 没跟着变 false,实得 %', v_bool;
    END IF;
    UPDATE suppliers SET counterparty_type = 'goods_supplier' WHERE id = s_goods;
    SELECT supplies_goods INTO v_bool FROM suppliers WHERE id = s_goods;
    IF v_bool IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 97A 改回 goods_supplier 之后 supplies_goods 没跟着变 true,实得 %', v_bool;
    END IF;

    -- 直写派生列必须被拒 —— 两处都能写就是两个真源
    v_denied := false;
    BEGIN
        UPDATE suppliers SET supplies_goods = true WHERE id = s_fwd;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 97A 竟然直接写得动 supplies_goods —— 那它就不是派生列,是第二个真源';
    END IF;
    RAISE NOTICE '97A 派生列双向跟随、且拒绝直写 ✓(%)', left(v_msg, 50);

    -- ══════════ B. 三处既有判据仍然开火(先证前提) ═══════════════════════════
    -- 【前提】同一行,typed 成 goods_supplier 时收货是【被接受】的。
    INSERT INTO materials (code, name, category) VALUES ('FX97-MAT', 'fixture 97 material', 'copper');
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    SELECT 'FX97-IB1', m.id, s_goods, 100, 100, 'kg', CURRENT_DATE FROM materials m WHERE m.code = 'FX97-MAT';
    SELECT count(*) INTO v_n FROM inbound_batches WHERE code = 'FX97-IB1';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 97B 前提不成立:供货商名下收货就该成功,实得 % 行 —— 后面那句拒绝证明不了任何事', v_n;
    END IF;

    -- 现在把它改成 forwarder,同一条路必须按名拒绝
    UPDATE suppliers SET counterparty_type = 'forwarder' WHERE id = s_goods;
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
        SELECT 'FX97-IB2', m.id, s_goods, 100, 100, 'kg', CURRENT_DATE FROM materials m WHERE m.code = 'FX97-MAT';
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RECEIPT_AGAINST_NON_GOODS_VENDOR' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 97B 收货守卫没有按名拒绝一个非供货往来户 —— 实得:%', COALESCE(v_msg, '(没有拒绝)');
    END IF;
    UPDATE suppliers SET counterparty_type = 'goods_supplier' WHERE id = s_goods;
    RAISE NOTICE '97B 收货守卫经由派生列仍然开火(前提已证)✓';

    -- ══════════ C. 货代的应付,和供应商的应付走同一条链 ═════════════════════
    -- LOG-4a:direction 是新的 NOT NULL 列,【没有 schema 默认值】(有意如此)——
    -- 所以直插必须自己说清是哪一个方向。本臂问的是"货代的应付挂在谁名下",
    -- 与方向无关,取 'inbound' 即可。
    INSERT INTO freight_documents (code, doc_date, supplier_id, amount_ccy, currency, fx_rate,
                                   amount_base, allocation_basis, payment_status, status,
                                   direction)
    VALUES ('FX97-FRT-1', CURRENT_DATE, s_fwd, 1000, 'USD', 1.35, 1350, 'weight', 'unpaid', 'posted',
            'inbound')
    RETURNING id INTO v_fd;

    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT open_ccy INTO v_open FROM ap_open_items WHERE doc_code = 'FX97-FRT-1';
    RESET ROLE;
    IF v_open IS DISTINCT FROM 1000 THEN
        RAISE EXCEPTION 'FIXTURE 97C 货代的运费没有进应付账龄(open_ccy 实得 %)—— 共用 id 的全部理由就是这一条', v_open;
    END IF;

    -- 分摊:一笔已过账的付款必须把开口减下去
    INSERT INTO payments (code, direction, counterparty_type, supplier_id, amount_ccy, currency,
                          fx_rate, amount_base, bank_account_code, payment_date, status)
    VALUES ('FX97-PAY-1', 'out', 'supplier', s_fwd, 400, 'USD', 1.35, 540, '1000', CURRENT_DATE, 'posted')
    RETURNING id INTO v_pay;
    INSERT INTO payment_allocations (payment_id, freight_document_id, allocated_ccy, allocated_base, allocated_pay)
    VALUES (v_pay, v_fd, 400, 540, 540);

    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT open_ccy INTO v_open FROM ap_open_items WHERE doc_code = 'FX97-FRT-1';
    RESET ROLE;
    IF v_open IS DISTINCT FROM 600 THEN
        RAISE EXCEPTION 'FIXTURE 97C 付款没有把货代的应付冲下去(open_ccy 实得 %,应为 600)', v_open;
    END IF;

    -- 重估:开口留在【外币】上,那正是重估的输入。预览函数必须跑得动。
    IF (SELECT currency FROM freight_documents WHERE id = v_fd) <> 'USD' THEN
        RAISE EXCEPTION 'FIXTURE 97C 前提不成立:这一臂要的是一笔外币应付';
    END IF;
    v_prev := preview_revalue_foreign_balances(CURRENT_DATE);
    IF v_prev IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 97C 期末重估预览对着一笔货代外币应付跑不出结果';
    END IF;
    RAISE NOTICE '97C 货代应付:入账龄 ✓ 可分摊 ✓ 外币开口进重估 ✓';

    -- ══════════ D. 同一货代同一航段,有效期重叠按名拒绝 ═══════════════════════
    INSERT INTO ports (code, name) VALUES ('FX97PA', 'port a') RETURNING id INTO p_a;
    INSERT INTO ports (code, name) VALUES ('FX97PB', 'port b') RETURNING id INTO p_b;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (p_a, p_b) RETURNING id INTO v_lane;

    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency, valid_from, valid_to)
    VALUES (s_fwd, v_lane, 900, 'USD', DATE '2026-01-01', DATE '2026-06-30');

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency, valid_from, valid_to)
        VALUES (s_fwd, v_lane, 950, 'USD', DATE '2026-06-01', DATE '2026-12-31');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('FORWARDER_RATE_QUOTE_OVERLAP' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 97D 重叠有效期的报价没有按名拒绝 —— 实得:%', COALESCE(v_msg, '(没有拒绝)');
    END IF;
    RAISE NOTICE '97D 重叠报价按名拒绝 ✓';

    -- ══════════ E. 空清单是一个具名状态,不是"零条要求" ═══════════════════════
    SELECT checklist_state INTO v_state FROM lane_checklist_status WHERE lane_id = v_lane;
    IF v_state <> 'not_defined' THEN
        RAISE EXCEPTION 'FIXTURE 97E 一条从没定过清单的航段应当是 not_defined,实得 %', v_state;
    END IF;

    UPDATE lanes SET checklist_reviewed_at = now() WHERE id = v_lane;
    SELECT checklist_state INTO v_state FROM lane_checklist_status WHERE lane_id = v_lane;
    IF v_state <> 'defined_empty' THEN
        RAISE EXCEPTION 'FIXTURE 97E 确认过、但确实没有要求的航段应当是 defined_empty,实得 %', v_state;
    END IF;

    INSERT INTO lane_document_requirements (lane_id, document_type, regime)
    VALUES (v_lane, 'fixture 97 movement document', 'fixture 97 regime');
    SELECT checklist_state INTO v_state FROM lane_checklist_status WHERE lane_id = v_lane;
    IF v_state <> 'defined' THEN
        RAISE EXCEPTION 'FIXTURE 97E 有要求的航段应当是 defined,实得 %', v_state;
    END IF;
    RAISE NOTICE '97E 未定义 / 定义过但为空 / 有要求 —— 三种状态分得开 ✓';

    -- ══════════ F. 两个方向的守卫 ═══════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        -- 【这一行必须除了"供应商是货代"之外【处处合法】】,否则守卫被拿掉时
        -- 它会因为别的原因失败,而这一臂就会【因为错的理由变红】——
        -- 注入 1 第一次跑正是这样:少了 fx_rate,红的是 NOT NULL,不是缺守卫。
        INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate)
        VALUES ('FX97-PO-1', s_fwd, CURRENT_DATE, 'USD', 1.35);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('PO_VENDOR_IS_A_FORWARDER' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 97F 货代竟然当得了采购单供应商 —— 实得:%', COALESCE(v_msg, '(没有拒绝)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO forwarder_details (supplier_id, main_routes) VALUES (s_goods, 'x');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('FORWARDER_DETAILS_NOT_A_FORWARDER' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 97F 供货商竟然挂得上货代物流属性 —— 实得:%', COALESCE(v_msg, '(没有拒绝)');
    END IF;
    RAISE NOTICE '97F 两个方向都按名拒绝 ✓';

    RAISE NOTICE 'FIXTURE 97 全部通过';
END $$;
ROLLBACK;

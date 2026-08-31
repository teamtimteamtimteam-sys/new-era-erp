-- 169 缺一侧是 NULL 而不是假阳性;而"未评估"与"没设"【分得开】 · PROC-1B-iii(2c)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉的那条区别,以及它为什么值一份单独的 fixture】
-- 一次差异需要【两次互相矛盾的主张】。而这条轴上有【三种】"没有主张":
--   ① 采购侧 NULL —— 这一行比这条轴还老(不回填,不拦人);
--   ② 到货侧 NULL —— 同上;
--   ③ not_assessed —— **有人打开了表单,并且没有下判断**。
-- 三种都必须给 **NULL,不是 false,更不是 true** —— 一个把缺席读成"不能"的
-- 实现,会把一整批【根本没人看过】的料报成"供应商谎报",而那是要拿去谈判的。
--
-- ★★【而 ③ 与 ①/② 必须【分得开】,尽管它们的布尔一模一样】★★
-- 三者的 contradicted 都是 NULL。所以分辨力【不在那个布尔上】——
-- 它在视图同时露出的那两列原始码上:没设是 NULL,看了没判是字面量
-- 'not_assessed'。**这正是本刀不把这条轴做成可空 boolean 的全部理由**,
-- 而 N6 就是那个理由的凭据。
--
-- 【每一臂钉什么】
-- N1 两侧都没设            → NULL,且 kinds 不点名。
-- N2 判断有、实际没设      → NULL。
-- N3 判断没设、实际有      → NULL。
-- N4 not_assessed vs cannot → NULL。**"我没看"不是一次主张。**
-- N5 cannot vs not_assessed → NULL(另一个方向,不许只做对一边)。
-- N6 ★ N3 与 N4 在屏幕上是【两个不同的字】:一个 NULL,一个 'not_assessed'。
-- N7 对照:can vs cannot   → true + 点名。**没有这一臂,一个恒返回 NULL 的
--    实现会全绿** —— 那才是最省事、也最坏的"修法"。
-- N8 对照:can vs can      → **false,不是 NULL**。"比过了、一致"是第三件事,
--    与"没得比"不许并成一句。
-- N9 ★ 故障注入:把 not_assessed 的 is_a_claim 翻成 true → N4/N5 必须【翻面】。
--    它一次证明两件事:判据是【现读字典的那一列】而不是视图里写死的字面量;
--    并且 N4/N5 不是空转。
--
-- 日期:自带。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; sup uuid; mat uuid; po uuid;
    l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; l6 uuid; l7 uuid;
    b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; b6 uuid; b7 uuid;
    v_c boolean; v_named boolean; v_j text; v_a text; n int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-169', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    UPDATE finance_settings SET locked_before = NULL;
    UPDATE receiving_settings
       SET grn_short_pct = 10, grn_over_pct = 10, grn_assay_tolerance_pct = 10;

    -- 【前提断言,不是设定 —— 而且写明为什么可以断言】(README 第 5 条例外分支)
    -- 本 fixture 全部七臂都建立在"字典里 can/cannot 是主张、not_assessed 不是"
    -- 之上。它由 db/tables/deep_discharge_judgements.sql 的引导行强制,
    -- 而 N9 恰恰要【故意】改它 —— 所以这里先断言起点,免得 N9 从一个已经
    -- 被别的 fixture 改过的值出发,把"翻面"测成"本来就是"。
    IF (SELECT is_a_claim FROM deep_discharge_judgements WHERE code='not_assessed') IS NOT FALSE
       OR (SELECT is_a_claim FROM deep_discharge_judgements WHERE code='can') IS NOT TRUE
       OR (SELECT is_a_claim FROM deep_discharge_judgements WHERE code='cannot') IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 169 前置失败:字典的 is_a_claim 起点不对 —— can/cannot 必须是主张,not_assessed 必须不是';
    END IF;

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX169-SUP', 'fixture 169 supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('FX169-M', 'fixture 169 pack', 'battery_material', true, 'whole_pack', 'end_of_life', 'ev_traction')
    RETURNING id INTO mat;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status)
    VALUES ('FX169-PO', sup, '2026-05-01', 'USD', 1.3, 'receiving', 'approved') RETURNING id INTO po;

    -- 【七条各自独立的采购行 + 七条收货】(README 第 2 条:共享数据的用例会
    -- 因为错的理由通过)。每行订 1000、收 100 —— 远离 short/over 两个阈值,
    -- 免得引进与本刀无关的 kind。
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, deep_discharge_judgement_code)
    VALUES (po, 1, mat, 1000, 'kg', NULL),           (po, 2, mat, 1000, 'kg', 'can'),
           (po, 3, mat, 1000, 'kg', NULL),           (po, 4, mat, 1000, 'kg', 'not_assessed'),
           (po, 5, mat, 1000, 'kg', 'cannot'),       (po, 6, mat, 1000, 'kg', 'can'),
           (po, 7, mat, 1000, 'kg', 'can');
    SELECT id INTO l1 FROM purchase_order_lines WHERE purchase_order_id=po AND line_no=1;
    SELECT id INTO l2 FROM purchase_order_lines WHERE purchase_order_id=po AND line_no=2;
    SELECT id INTO l3 FROM purchase_order_lines WHERE purchase_order_id=po AND line_no=3;
    SELECT id INTO l4 FROM purchase_order_lines WHERE purchase_order_id=po AND line_no=4;
    SELECT id INTO l5 FROM purchase_order_lines WHERE purchase_order_id=po AND line_no=5;
    SELECT id INTO l6 FROM purchase_order_lines WHERE purchase_order_id=po AND line_no=6;
    SELECT id INTO l7 FROM purchase_order_lines WHERE purchase_order_id=po AND line_no=7;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty,
                                 arrival_date, purchase_order_id, purchase_order_line_id, deep_discharge_actual_code)
    VALUES ('FX169-B1', mat, sup, 100, 'kg', 100, '2026-05-02', po, l1, NULL),
           ('FX169-B2', mat, sup, 100, 'kg', 100, '2026-05-02', po, l2, NULL),
           ('FX169-B3', mat, sup, 100, 'kg', 100, '2026-05-02', po, l3, 'cannot'),
           ('FX169-B4', mat, sup, 100, 'kg', 100, '2026-05-02', po, l4, 'cannot'),
           ('FX169-B5', mat, sup, 100, 'kg', 100, '2026-05-02', po, l5, 'not_assessed'),
           ('FX169-B6', mat, sup, 100, 'kg', 100, '2026-05-02', po, l6, 'cannot'),
           ('FX169-B7', mat, sup, 100, 'kg', 100, '2026-05-02', po, l7, 'can');
    SELECT id INTO b1 FROM inbound_batches WHERE code='FX169-B1';
    SELECT id INTO b2 FROM inbound_batches WHERE code='FX169-B2';
    SELECT id INTO b3 FROM inbound_batches WHERE code='FX169-B3';
    SELECT id INTO b4 FROM inbound_batches WHERE code='FX169-B4';
    SELECT id INTO b5 FROM inbound_batches WHERE code='FX169-B5';
    SELECT id INTO b6 FROM inbound_batches WHERE code='FX169-B6';
    SELECT id INTO b7 FROM inbound_batches WHERE code='FX169-B7';

    -- ══════════ N1–N5 · 五种"没有两次主张",全部必须 NULL ══════════════════
    RAISE NOTICE 'fixture 169 · 进入 N1–N5';
    FOR n IN 1..5 LOOP
        SELECT deep_discharge_contradicted, ('deep_discharge_contradicted' = ANY(kinds))
          INTO v_c, v_named
          FROM grn_discrepancies
         WHERE batch_id = (ARRAY[b1,b2,b3,b4,b5])[n];
        IF v_c IS NOT NULL THEN
            RAISE EXCEPTION 'FIXTURE 169N% 失败:没有【两次互相矛盾的主张】时,contradicted 必须是 NULL —— 不是 false,更不是 true。把缺席读成"不能",会把一整批没人看过的料报成供应商谎报。实得「%」', n, v_c::text;
        END IF;
        IF v_named THEN
            RAISE EXCEPTION 'FIXTURE 169N% 失败:kinds 不许点名一条【判不出来】的差异 —— 那正是假阳性本身', n;
        END IF;
    END LOOP;

    -- ══════════ N6 · ★ "未评估" 与 "没设" 在屏幕上是两个不同的字 ══════════
    RAISE NOTICE 'fixture 169 · 进入 N6';
    SELECT deep_discharge_judged INTO v_j FROM grn_discrepancies WHERE batch_id = b3;  -- 没设
    SELECT deep_discharge_actual INTO v_a FROM grn_discrepancies WHERE batch_id = b3;
    IF v_j IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 169N6 失败:"没设"必须露成 NULL,实得「%」', v_j;
    END IF;
    IF v_a IS DISTINCT FROM 'cannot' THEN
        RAISE EXCEPTION 'FIXTURE 169N6 失败:到货侧的原始码必须原样露出来,实得「%」', COALESCE(v_a,'(空)');
    END IF;
    SELECT deep_discharge_judged INTO v_j FROM grn_discrepancies WHERE batch_id = b4;  -- 看了没判
    IF v_j IS DISTINCT FROM 'not_assessed' THEN
        RAISE EXCEPTION 'FIXTURE 169N6 失败:**"看了但没下判断"是一个记下来的事实,必须露成 not_assessed** —— 它与"没设"的布尔一样(都是 NULL),所以分辨力只能来自这一列。实得「%」', COALESCE(v_j,'(空 —— 那就与"没设"并成一句了)');
    END IF;

    -- ══════════ N7 · 对照:机制真的会响 ══════════════════════════════════════
    RAISE NOTICE 'fixture 169 · 进入 N7';
    SELECT deep_discharge_contradicted, ('deep_discharge_contradicted' = ANY(kinds))
      INTO v_c, v_named FROM grn_discrepancies WHERE batch_id = b6;
    IF v_c IS NOT TRUE OR NOT v_named THEN
        RAISE EXCEPTION 'FIXTURE 169N7 失败:can vs cannot 是真差异,必须 true 且被点名 —— **没有这一臂,一个恒返回 NULL 的实现会全绿**。实得 contradicted=「%」 named=「%」', COALESCE(v_c::text,'NULL'), v_named;
    END IF;

    -- ══════════ N8 · 对照:一致是 false,不是 NULL ══════════════════════════
    RAISE NOTICE 'fixture 169 · 进入 N8';
    SELECT deep_discharge_contradicted, ('deep_discharge_contradicted' = ANY(kinds))
      INTO v_c, v_named FROM grn_discrepancies WHERE batch_id = b7;
    IF v_c IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 169N8 失败:**"比过了、一致"是第三件事**,与"没得比"不许并成一句 —— 必须 false,实得「%」', COALESCE(v_c::text,'NULL');
    END IF;
    IF v_named THEN
        RAISE EXCEPTION 'FIXTURE 169N8 失败:一致不该被点名';
    END IF;

    -- ══════════ N9 · ★★ 故障注入:判据是【现读的那一列】,而 N4/N5 不是空转 ══
    -- 【为什么这样注入】一个把 'not_assessed' 写死在 CASE 里的实现,与一个现读
    -- is_a_claim 的实现,在引导值下【给出完全相同的答案】。所以这一臂不比数字,
    -- 它【在同一个事务里把那一行翻面】,再断言 N4/N5 的结论跟着翻。
    -- 翻不动 = 判据被写死了(或者 N4/N5 本来就在空转)。
    RAISE NOTICE 'fixture 169 · 进入 N9(故障注入)';
    UPDATE deep_discharge_judgements SET is_a_claim = true WHERE code = 'not_assessed';

    SELECT deep_discharge_contradicted INTO v_c FROM grn_discrepancies WHERE batch_id = b4;
    IF v_c IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 169N9 失败(注入臂):把 not_assessed 翻成"算一次主张"之后,not_assessed vs cannot 就成了两次互相矛盾的主张 —— 本该 true。翻不动说明判据被写死在视图里了,于是 N4 是一句空话。实得「%」', COALESCE(v_c::text,'NULL');
    END IF;
    SELECT deep_discharge_contradicted INTO v_c FROM grn_discrepancies WHERE batch_id = b5;
    IF v_c IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 169N9 失败(注入臂,另一个方向):cannot vs not_assessed 同样该翻成 true。实得「%」', COALESCE(v_c::text,'NULL');
    END IF;

    -- 【两侧都是 NULL 的那些【不受影响】】—— 否则这一臂证明的就不是
    -- "is_a_claim 被读了",而是"什么东西一改全都变了"。
    SELECT deep_discharge_contradicted INTO v_c FROM grn_discrepancies WHERE batch_id = b2;
    IF v_c IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 169N9 失败(注入臂,不动的那一边):实际【没设】的那一条与 not_assessed 这一行毫无关系,不许跟着动。实得「%」', v_c::text;
    END IF;

    UPDATE deep_discharge_judgements SET is_a_claim = false WHERE code = 'not_assessed';
    SELECT deep_discharge_contradicted INTO v_c FROM grn_discrepancies WHERE batch_id = b4;
    IF v_c IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 169 失败(收尾):注入撤掉之后必须恢复 NULL,实得「%」', v_c::text;
    END IF;
END $$;
ROLLBACK;

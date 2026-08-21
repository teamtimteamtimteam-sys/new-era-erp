-- 59 分类落闸(IOD-2):【只有一次明确的人为排除才拒绝,缺失的决定一律告警】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 真正钉住的东西 —— C 臂】
-- 天真的谓词是这一句:
--     EXISTS (... WHERE location_id = ? AND classification_code = m.waste_classification_code)
-- 它在两处各撒一次谎,而【第二处是 IOD-1 的 survey 在本地重建上真的撞到过的】:
-- 物料 waste_classification_code IS NULL 时,等值比较得 NULL,EXISTS 为假,
-- 于是"没人分过类"被判成"不在允许清单里"——【一次没有任何人做过的拒绝】。
--
-- 所以 C 臂断言的是:**未分类物料落进一个配置齐全的库位,告警,并且写入成功**。
-- 这一臂存在的理由不是覆盖率,是【让任何人把天真谓词写回去时先弄红一个门】。
-- 它是这份 fixture 里唯一一条"看起来该拒、而正确答案是放行"的断言,也因此是
-- 最容易在一次"顺手收紧"的重构里被改掉的那一条。改它之前请先读这一段。
--
-- 【为什么"缺失的决定"不能拒绝】零行 = 没有人配置过;NULL 分类 = 没有人分过类。
-- 两者都是【系统的沉默】。拒绝一次沉默,就是把沉默说成人的意志 —— 而操作员
-- 拿到的会是一句"不允许",没有任何人做过那个决定。
--
-- 各臂:
--   A 前提:分类字典有 focused/non_focused;两个库位;三种物料(分类/另一类/未分类)
--   B 四态 × 建批次:未配置→告警放行 · 配了且含→静默 · 配了不含→拒 · 未分类→告警放行
--   C 【钉死】未分类 + 已配置库位 → 告警 IOD_MATERIAL_UNCLASSIFIED 且【批次建出来了】
--   D 拒绝【故障注入】:把 IOD_CLASS_EXCLUDED 那一臂反过来断言,证明它真的会红
--   E 告警【在返回值里】—— 断言"调用成功"不等于断言"告警到达了"
--   F 转移【入腿】两种批次都查(XOR 两边);出腿一个字不查
--   G 未指定库位一次都不查
--
-- 日期无关。自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    r_all   uuid;
    m_foc   uuid;   -- 分类 = focused
    m_non   uuid;   -- 分类 = non_focused
    m_null  uuid;   -- 【未分类】—— 本 fixture 的主角
    v_sup   uuid;
    loc_un  uuid;   -- 未配置任何分类的库位
    loc_foc uuid;   -- 只允许 focused
    loc_late uuid;  -- 【货先到、配置后到】的那一个(F4)
    v_res   jsonb;
    v_warn  jsonb;
    b       uuid; ob uuid; ib2 uuid; ib3 uuid; ib4 uuid;
    v_n     int; v_msg text; v_denied boolean; d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-59', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S59', 'Fixture Supplier 59', 'SG', 'goods_supplier') RETURNING id INTO v_sup;

    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit, waste_classification_code)
    VALUES ('ZZFIX59-F', 'fixture 59 focused', 'battery_material', true, 'black_mass', 'end_of_life', 'kg', 'focused') RETURNING id INTO m_foc;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit, waste_classification_code)
    VALUES ('ZZFIX59-N', 'fixture 59 non-focused', 'battery_material', true, 'black_mass', 'end_of_life', 'kg', 'non_focused') RETURNING id INTO m_non;
    -- 【不写 waste_classification_code】—— 未分类是"没有人分过类",不是某个值
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX59-U', 'fixture 59 unclassified', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO m_null;

    INSERT INTO storage_locations (code, name) VALUES ('ZZ59-UN', 'unconfigured rack') RETURNING id INTO loc_un;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ59-FOC', 'focused-only rack') RETURNING id INTO loc_foc;
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_foc, 'focused');

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    -- 【前提先立】否则后面每一条断言都可能因为地基不成立而"通过"。
    IF NOT EXISTS (SELECT 1 FROM waste_classifications WHERE code = 'focused' AND is_controlled) THEN
        RAISE EXCEPTION 'FIXTURE 59A 失败:前提不成立 —— 分类字典里应有受控的 focused';
    END IF;
    IF EXISTS (SELECT 1 FROM storage_location_allowed_classes WHERE location_id = loc_un) THEN
        RAISE EXCEPTION 'FIXTURE 59A 失败:前提不成立 —— loc_un 应当【零行】(未配置)';
    END IF;
    SELECT count(*) INTO v_n FROM storage_location_allowed_classes WHERE location_id = loc_foc;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 59A 失败:前提不成立 —— loc_foc 应当恰好配了一类,实际 %', v_n;
    END IF;
    IF (SELECT waste_classification_code FROM materials WHERE id = m_null) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 59A 失败:前提不成立 —— m_null 必须是【未分类】';
    END IF;

    -- ══════════ B1. 未配置的库位 → 告警,放行 ════════════════════════════════
    v_res := create_inbound_batch(m_foc, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_un);
    v_warn := v_res -> 'warnings';
    IF NOT (v_warn @> to_jsonb(ARRAY['IOD_CLASS_UNCONFIGURED_LOCATION|ZZ59-UN'])) THEN
        RAISE EXCEPTION 'FIXTURE 59B1 失败:未配置库位应当告警 IOD_CLASS_UNCONFIGURED_LOCATION,实际 %', v_warn::text;
    END IF;
    IF (v_res ->> 'batch_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 59B1 失败:告警【不是拒绝】—— 批次应当照样建出来';
    END IF;

    -- ══════════ B2. 配了、且含这一类 → 静默 ══════════════════════════════════
    v_res := create_inbound_batch(m_foc, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_foc);
    IF jsonb_array_length(v_res -> 'warnings') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 59B2 失败:配了且含这一类应当【一个字都不说】,实际 %', (v_res -> 'warnings')::text;
    END IF;
    IF (v_res ->> 'batch_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 59B2 失败:正常路径应当建得出批次';
    END IF;

    -- ══════════ B3. 配了、但不含这一类 → 【拒绝】═════════════════════════════
    -- 这是三态里唯一一态"有人做过决定":有人配了这个库位,并且没有把 non_focused
    -- 放进去。可判定 ⇒ 可以拒绝。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_inbound_batch(m_non, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_foc);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 59B3 失败:配了且不含这一类应当被拒 —— 闸没落下来';
    END IF;
    IF v_msg NOT LIKE 'IOD_CLASS_EXCLUDED|ZZ59-FOC|non_focused%' THEN
        RAISE EXCEPTION 'FIXTURE 59B3 失败:拒绝应当【按名】并带上库位与分类,实际 %', v_msg;
    END IF;
    -- 【什么都没发生】拒绝的语义必须是这个,而不是"回滚了一半"
    SELECT count(*) INTO v_n FROM inbound_batches WHERE material_id = m_non;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 59B3 失败:被拒之后不应留下任何批次,实际 %', v_n;
    END IF;

    -- ══════════ C. 【钉死】未分类 + 已配置库位 → 告警,并且【写入成功】════════
    -- 天真谓词在这里判拒。任何人把它写回去,这一臂先红。
    v_res := create_inbound_batch(m_null, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_foc);
    v_warn := v_res -> 'warnings';
    IF NOT (v_warn @> to_jsonb(ARRAY['IOD_MATERIAL_UNCLASSIFIED|ZZFIX59-U'])) THEN
        RAISE EXCEPTION 'FIXTURE 59C 失败:未分类物料应当告警 IOD_MATERIAL_UNCLASSIFIED,实际 %', v_warn::text;
    END IF;
    b := (v_res ->> 'batch_id')::uuid;
    IF b IS NULL OR NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = b) THEN
        RAISE EXCEPTION 'FIXTURE 59C 失败:【未分类不是被排除,是没人分过类】—— 它必须放行。批次没建出来';
    END IF;
    -- 而且【不能顺手也报一个"未配置"】:loc_foc 是配过的,那句话会是假的
    IF v_warn::text LIKE '%IOD_CLASS_UNCONFIGURED_LOCATION%' THEN
        RAISE EXCEPTION 'FIXTURE 59C 失败:loc_foc 配置过,不该报"未配置",实际 %', v_warn::text;
    END IF;

    -- 两个缺失的决定【同时】发生时,两条都要说 —— 压成一条会让人只去补一件
    v_res := create_inbound_batch(m_null, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_un);
    v_warn := v_res -> 'warnings';
    IF jsonb_array_length(v_warn) <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 59C 失败:未配置库位 + 未分类物料应当给出【两条】告警,实际 %', v_warn::text;
    END IF;

    -- ══════════ D. 拒绝的【故障注入】:证明这道门真的会红 ═════════════════════
    -- 【为什么要有这一臂】B3 断言"拒绝发生了"。但一个永远抛异常的实现也能让 B3
    -- 通过。这一臂反过来问:在【应当放行】的那一格上,它有没有乱拒?
    -- 两格合起来才说明闸装在了对的地方,而不是装了一个总是关着的门。
    v_denied := false;
    BEGIN
        PERFORM create_inbound_batch(m_non, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_un);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 59D 失败:non_focused 落在【未配置】库位上不该被拒 —— 门总是关着的';
    END IF;

    -- ══════════ E. 另外两个建批次 RPC:同一判词,同样回得来 ═══════════════════
    -- 【断言"成功"不是断言"告警到达了"】—— 所以这里逐个查 payload,而不是
    -- 只看调用有没有抛。IOD-1b 的教训:数据库那侧一直是对的,人却看不到。
    v_res := receive_inbound_batch_against_po(m_foc, v_sup, 10, d, NULL, NULL, NULL, loc_un);
    IF NOT ((v_res -> 'warnings') @> to_jsonb(ARRAY['IOD_CLASS_UNCONFIGURED_LOCATION|ZZ59-UN'])) THEN
        RAISE EXCEPTION 'FIXTURE 59E 失败:receive_inbound_batch_against_po 的告警没回到 payload,实际 %', v_res::text;
    END IF;
    IF (v_res ->> 'batch_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 59E 失败:receive_inbound_batch_against_po 应当仍然返回 batch_id';
    END IF;

    v_res := create_output_batch(m_null, 10, 'kg', d, '库存中', NULL, NULL, NULL, loc_foc);
    IF NOT ((v_res -> 'warnings') @> to_jsonb(ARRAY['IOD_MATERIAL_UNCLASSIFIED|ZZFIX59-U'])) THEN
        RAISE EXCEPTION 'FIXTURE 59E 失败:create_output_batch 的告警没回到 payload,实际 %', v_res::text;
    END IF;
    ob := (v_res ->> 'batch_id')::uuid;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_output_batch(m_non, 10, 'kg', d, '库存中', NULL, NULL, NULL, loc_foc);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'IOD_CLASS_EXCLUDED|%' THEN
        RAISE EXCEPTION 'FIXTURE 59E 失败:create_output_batch 也应当在明确排除上拒绝,实际 %', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    -- ══════════ F. 转移的【入腿】:两种批次都查(XOR 两边)════════════════════
    -- F1 产出批次:入腿落在明确排除它的库位上 → 拒
    -- ob 是未分类物料的产出批,先换一张 non_focused 的
    v_res := create_output_batch(m_non, 50, 'kg', d, '库存中', NULL, NULL, NULL, loc_un);
    ob := (v_res ->> 'batch_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_stock_transfer(p_qty => 10, p_to_location_id => loc_foc,
                                      p_output_batch_id => ob, p_from_location_id => loc_un);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'IOD_CLASS_EXCLUDED|ZZ59-FOC|non_focused%' THEN
        RAISE EXCEPTION 'FIXTURE 59F1 失败:转移【入腿】应当按名拒绝(产出批次),实际 %', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    -- F2 进料批次:同一条判词必须从另一边也够得到 material_id
    v_res := create_inbound_batch(m_non, v_sup, 50, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_un);
    ib2 := (v_res ->> 'batch_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_stock_transfer(p_qty => 10, p_to_location_id => loc_foc,
                                      p_inbound_batch_id => ib2, p_from_location_id => loc_un);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'IOD_CLASS_EXCLUDED|ZZ59-FOC|non_focused%' THEN
        RAISE EXCEPTION 'FIXTURE 59F2 失败:转移【入腿】应当按名拒绝(进料批次),实际 %', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    -- F3 入腿的告警也要回到 payload(转移这一侧不重定向,靠返回值)。
    -- 【不指定库位建批】→ 货落在 NULL 桶,再从 NULL 搬进未配置的库位。
    v_res := create_inbound_batch(m_foc, v_sup, 50, 'kg', d);
    ib3 := (v_res ->> 'batch_id')::uuid;
    v_res := create_stock_transfer(p_qty => 10, p_to_location_id => loc_un,
                                   p_inbound_batch_id => ib3, p_from_location_id => NULL);
    IF NOT ((v_res -> 'warnings') @> to_jsonb(ARRAY['IOD_CLASS_UNCONFIGURED_LOCATION|ZZ59-UN'])) THEN
        RAISE EXCEPTION 'FIXTURE 59F3 失败:转移入腿的告警没回到 payload,实际 %', v_res::text;
    END IF;

    -- F4 【出腿一个字都不查】—— 也就是"已经躺在那里的货"这件事本刀不处理。
    -- 【怎么造出这个状态,本身就是那个场景】:先把货正常收进一个还没配置的库位
    -- (那时没有任何理由拒绝它),【然后有人去配置了那个库位】,而配置里不含这
    -- 一类。于是货已经躺在一个现在不允许它的地方 —— 落地腿再也不会被调用一次,
    -- 没有任何东西会发现它(归告警那一刀)。
    -- 而把它【搬走】必须成功:拦住它离开,只会把它焊死在错的地方。
    INSERT INTO storage_locations (code, name) VALUES ('ZZ59-LATE', 'configured later') RETURNING id INTO loc_late;
    v_res := create_inbound_batch(m_non, v_sup, 30, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_late);
    ib4 := (v_res ->> 'batch_id')::uuid;
    IF ib4 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 59F4 失败:未配置的库位当时不该拒绝这次收货';
    END IF;
    -- 【配置在货之后才发生】
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_late, 'focused');
    -- 存量冲突现在成立:non_focused 躺在只允许 focused 的库位上,而【没有任何
    -- 东西告诉过任何人】。这一条是本刀明确的范围外,写在这里是为了让它可见。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_stock_transfer(p_qty => 5, p_to_location_id => loc_un,
                                      p_inbound_batch_id => ib4, p_from_location_id => loc_late);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 59F4 失败:出腿不该被检查 —— 拦住一批放错地方的货【离开】,只会把它焊死在那里(实际 %)', v_msg;
    END IF;

    -- ══════════ G. 未指定库位:一次都不查 ════════════════════════════════════
    -- 没有货落进任何"那里",也就没有任何关于"那里"的断言需要成立。
    v_res := create_inbound_batch(m_null, v_sup, 10, 'kg', d);
    IF jsonb_array_length(v_res -> 'warnings') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 59G 失败:未指定库位应当【一个字都不说】(未分类也不说),实际 %', (v_res -> 'warnings')::text;
    END IF;
    IF (v_res ->> 'batch_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 59G 失败:不指定库位是一等状态,必须建得出批次';
    END IF;
END $$;
ROLLBACK;

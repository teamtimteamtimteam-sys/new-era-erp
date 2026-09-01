-- 118 什么基准,谁的结果 —— 两件事后再也重建不出来的事实
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- F1 前提:既有的化验单与从它派生的数字【一个值都没变】。断言值,不是"查询跑通了"。
-- F2 没有基准的化验单被拒,**按具名码**,而且【只在 INSERT 上拒】——
--    历史行必须照样改得动(apply/unapply 会改它们)。这一臂同时钉住那个边界。
-- F3 水分没测过 = 【没测过】,不是 0。断言的是【两者可辨】,不是"某一列是 NULL"。
-- F4 出具方三个取值都记得下;而**对手方的结果【不取代】我们的** ——
--    两份都在、都读得出来。
--
-- 日期无关(assay_date 用一个固定的过去日期;函数拒绝未来日期)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_ib uuid;
    v_a1 uuid; v_a2 uuid; v_a3 uuid;
    v_res jsonb; v_n int; v_pct numeric;
    v_denied boolean; v_msg text;
    v_day date := DATE '2026-03-02';
    v_moist numeric; v_dry text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-118', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ118-S', 'fixture 118 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, chemistry)
    VALUES ('ZZ118-M', 'f118 feed', 'battery_material', true, 'black_mass', 'end_of_life', 'NMC')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ118-IB', v_mat, v_sup, 1000, 1000, 'kg', v_day, 'other', 'fixture 118 自带数据') RETURNING id INTO v_ib;

    -- ══════════ F1 · 前提:既有那条路一个值都没变 ═══════════════════════════
    RAISE NOTICE 'fixture 118 · 进入 F1';
    v_denied := false; v_msg := NULL;
    BEGIN
        v_res := record_assay_result(
            p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',12.5),
                                          jsonb_build_object('metal','co','content_pct',7.25)),
            p_lab_name => 'FRL', p_inbound_batch_id => v_ib,
            p_weight_basis => 'dry', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 118F1 失败:进入 F1 —— 带上基准与出具方之后,记一份化验单必须照旧走得通。实得「%」', v_msg;
    END IF;
    v_a1 := (v_res ->> 'assay_result_id')::uuid;

    -- 【断言【数字本身】,两个金属给不同的值】全填同一个数的话,
    -- 一个"把所有行都读成第一行"的实现也能过。
    IF (SELECT content_pct FROM assay_result_metals WHERE assay_result_id = v_a1 AND metal='ni')
       IS DISTINCT FROM 12.5
       OR (SELECT content_pct FROM assay_result_metals WHERE assay_result_id = v_a1 AND metal='co')
       IS DISTINCT FROM 7.25 THEN
        RAISE EXCEPTION 'FIXTURE 118F1 失败:进入 F1 —— 含量必须原样读得回来(ni 12.5 / co 7.25)';
    END IF;
    IF (v_res ->> 'metal_count')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 118F1 失败:进入 F1 —— 返回的 metal_count 应当是 2,实得 %', v_res ->> 'metal_count';
    END IF;
    -- 既有的具名拒绝【一条都没被改坏】——本刀在函数里加了判断,顺序不能踩到它们。
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_assay_result(p_assay_date => v_day, p_metals => '[]'::jsonb,
            p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'ours');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%NO_METALS%' THEN
        RAISE EXCEPTION 'FIXTURE 118F1 失败:进入 F1 —— 空金属数组仍应按 NO_METALS 拒(本刀不许踩坏既有的拒绝),实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ F2 · 没有基准就拒,而且【只在 INSERT 上】 ═══════════════════
    RAISE NOTICE 'fixture 118 · 进入 F2';
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_assay_result(p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',1)),
            p_inbound_batch_id => v_ib, p_result_party => 'ours');   -- 【故意不给基准】
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%ASSAY_BASIS_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 118F2 失败:进入 F2 —— 不说基准的化验单必须按 ASSAY_BASIS_REQUIRED 拒。**一份没说明基准的含量数字事后还原不出来**:干基 30%% 与湿基 30%% 是两个数,差多少取决于水分。实得 denied=%、msg「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- 【出具方也必须明说 —— 它走的是另一条(函数里的具名拒绝)】
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_assay_result(p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',1)),
            p_inbound_batch_id => v_ib, p_weight_basis => 'dry');    -- 【故意不给出具方】
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%ASSAY_RESULT_PARTY_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 118F2 失败:进入 F2 —— 不说出具方的化验单必须按 ASSAY_RESULT_PARTY_REQUIRED 拒(没有默认值:默认会让"忘了改"变成"这是我们测的")。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;

    -- 【这一臂是本刀设计的关键:那道闸【只看 INSERT】】
    -- 造一行【没有基准】的历史化验单(卸掉触发器 → 插 → 装回),然后 UPDATE 它。
    -- 必须【改得动】—— 因为 apply / unapply 会例行改历史行
    -- (`UPDATE assay_results SET superseded_by = … WHERE id = v_prior`),
    -- 而一条 NOT VALID 的约束会在第一次复检时把所有旧化验单冻死
    -- —— PROC-5 在 materials 上实测过那一幕,八行至今改不动。
    ALTER TABLE public.assay_results DISABLE TRIGGER trg_assay_results_basis_stated;
    INSERT INTO assay_results (code, assay_date, inbound_batch_id, result_party)
    VALUES ('ZZ118-LEGACY', v_day, v_ib, 'ours') RETURNING id INTO v_a2;
    ALTER TABLE public.assay_results ENABLE TRIGGER trg_assay_results_basis_stated;

    IF (SELECT weight_basis FROM assay_results WHERE id = v_a2) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 118F2 前置失败:这一行本应【没有基准】,那才是要测的历史形状';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE assay_results SET notes = 'f118 touched' WHERE id = v_a2;
        UPDATE assay_results SET superseded_by = v_a1 WHERE id = v_a2;   -- apply 走的就是这一句
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 118F2 失败:进入 F2 —— **没有基准的历史化验单必须照样改得动**。apply_assay_result 会 `UPDATE … WHERE id = v_prior`,也就是改上一份历史化验;若这道闸也管 UPDATE,第一次复检就会把所有旧化验单冻死(PROC-5 实测过)。实得「%」', v_msg;
    END IF;

    -- ══════════ F3 · 没测水分 ≠ 水分为零 ═══════════════════════════════════
    RAISE NOTICE 'fixture 118 · 进入 F3';
    -- 一份【测了水分且为 0】的,与一份【没测】的 —— 两者必须可辨。
    v_res := record_assay_result(p_assay_date => v_day,
        p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',10)),
        p_inbound_batch_id => v_ib, p_weight_basis => 'as_received',
        p_result_party => 'ours', p_moisture_pct => 0);
    v_a3 := (v_res ->> 'assay_result_id')::uuid;

    IF (SELECT moisture_pct FROM assay_results WHERE id = v_a3) IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 118F3 失败:进入 F3 —— 【测出来是 0】必须原样存成 0(那是一次测量)';
    END IF;
    IF (SELECT moisture_pct FROM assay_results WHERE id = v_a1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 118F3 失败:进入 F3 —— 【没测】必须留成 NULL,不能被补成 0';
    END IF;
    -- 【关键:两者在同一个查询里可辨】断言的是"分得开",不是"某一列是 NULL"。
    -- 一个把 NULL 读成 0 的实现,上面两条里的第二条也能过(它只看列),
    -- 而这一条过不了 —— 因为它要求两份化验单落进【不同的桶】。
    SELECT count(*) FILTER (WHERE moisture_pct IS NOT NULL),
           count(*) FILTER (WHERE moisture_pct IS NULL)
      INTO v_n, v_moist
      FROM assay_results WHERE id IN (v_a1, v_a3);
    IF v_n <> 1 OR v_moist <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 118F3 失败:进入 F3 —— 两份化验单应当【一份测过、一份没测】(1/1),实得 %/%。**一个乘数的单位元是看不见的**:把没测过的水分读成 0,1 − 0 会算出一个看起来完全合理的数,而没有任何东西会报错', v_n, v_moist;
    END IF;
    -- 【干重推导:推不出来就要说推不出来,不能当成"湿的等于干的"】
    v_dry := CASE WHEN (SELECT moisture_pct FROM assay_results WHERE id = v_a1) IS NULL
                  THEN '推不出来' ELSE '推得出来' END;
    IF v_dry <> '推不出来' THEN
        RAISE EXCEPTION 'FIXTURE 118F3 失败:进入 F3 —— 没有水分就【推不出干重】,那时正确的行为是说"推不出来",不是把湿重当成干重';
    END IF;

    -- ══════════ F4 · 出具方三个取值;对手方【不取代】我们的 ═════════════════
    RAISE NOTICE 'fixture 118 · 进入 F4';
    -- 三个取值都记得下
    v_res := record_assay_result(p_assay_date => v_day,
        p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',11.0)),
        p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'counterparty');
    v_a2 := (v_res ->> 'assay_result_id')::uuid;
    v_res := record_assay_result(p_assay_date => v_day,
        p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',11.8)),
        p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'umpire');
    IF (SELECT count(DISTINCT result_party) FROM assay_results WHERE inbound_batch_id = v_ib) < 3 THEN
        RAISE EXCEPTION 'FIXTURE 118F4 失败:进入 F4 —— 三个出具方取值都要记得下(ours / counterparty / umpire),实得 %',
            (SELECT count(DISTINCT result_party) FROM assay_results WHERE inbound_batch_id = v_ib);
    END IF;
    -- 编造的第四种要被拒
    v_denied := false;
    BEGIN
        PERFORM record_assay_result(p_assay_date => v_day,
            p_metals => jsonb_build_array(jsonb_build_object('metal','ni','content_pct',1)),
            p_inbound_batch_id => v_ib, p_weight_basis => 'dry', p_result_party => 'ZZ118-NOSUCH');
    EXCEPTION WHEN check_violation THEN v_denied := true; WHEN OTHERS THEN NULL; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 118F4 失败:进入 F4 —— 出具方只有三个取值,第四种必须被 CHECK 拒';
    END IF;

    -- 【D4:对手方的结果【不是】对我们结果的取代】
    -- 两份都在、都读得出来,而我们那一份【没有被标成 superseded】。
    IF (SELECT superseded_by FROM assay_results WHERE id = v_a1) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 118F4 失败:进入 F4 —— 记一份【对手方】的结果,绝不能顺手把我们那一份标成 superseded。**那会静静地把我们自己测到的东西盖掉**,而分歧本身正是要拿去谈的东西';
    END IF;
    SELECT count(*) INTO v_n FROM assay_results
     WHERE inbound_batch_id = v_ib AND result_party IN ('ours','counterparty')
       AND deleted_at IS NULL;
    IF v_n < 2 THEN
        RAISE EXCEPTION 'FIXTURE 118F4 失败:进入 F4 —— 我们的那份与对手方那份必须【并存且都读得出来】,实得 % 份', v_n;
    END IF;
    -- 两份的数字确实不同 —— 否则"并存"证明不了任何事
    IF (SELECT content_pct FROM assay_result_metals WHERE assay_result_id = v_a1 AND metal='ni')
       = (SELECT content_pct FROM assay_result_metals WHERE assay_result_id = v_a2 AND metal='ni') THEN
        RAISE EXCEPTION 'FIXTURE 118F4 前置失败:两份结果的数字本应不同(12.5 vs 11.0),否则"并存"这一臂什么都证明不了';
    END IF;
END $$;
ROLLBACK;

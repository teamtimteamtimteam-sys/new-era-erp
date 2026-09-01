-- 117 化学体系与实验室是【字典】—— F7 点名的最后两处自由文本分类
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- 【每一臂钉什么】
-- F1 前提,先于一切:**既有的物料与化验单读回来一个字没变**。断言【值】,
--    不是"查询跑通了" —— 一个把行删光的实现也能让查询跑通。
-- F2 两张宿主表各自按【外键名】拒一个不认识的码。
-- F3 **本刀的意义**:事务里加一行字典,新值当场可用,不动任何 schema。
-- F4 D1 两个动词:停用【不让已经记下的值失效】,而它从可选集合里消失。
-- F5 D4 顺序照字典,而且【与字母序不同】—— 并且先断言 sort_order 两两不同
--    (上一刀有一臂正是在并列时靠运气绿的)。
-- F6 **NOT VALID 那条边界**:线上那一行占位串留着不动,而【新行必须在字典里】。
--    这一臂钉的是 Tim 的裁定本身,而不是一个实现细节。
--
-- 日期无关。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_ib uuid; v_assay uuid;
    v_chem text; v_lab text; v_n int;
    v_denied boolean; v_msg text; v_con text;
    v_by_sort text; v_by_alpha text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-117', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ117-S', 'fixture 117 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;

    -- ══════════ F1 · 前提:既有的值一个字没变 ═══════════════════════════════
    RAISE NOTICE 'fixture 117 · 进入 F1';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, chemistry)
        VALUES ('ZZ117-M', 'f117 feed', 'battery_material', true, 'black_mass', 'end_of_life', 'NMC')
        RETURNING id INTO v_mat;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 117F1 失败:进入 F1 —— 既有的化学体系值(NMC)必须照旧存得下。字典少发一个值,既有的录入路径就当场断了,而那是这一刀最直接的伤害。实得「%」', v_msg;
    END IF;
    IF (SELECT chemistry FROM materials WHERE id = v_mat) IS DISTINCT FROM 'NMC' THEN
        RAISE EXCEPTION 'FIXTURE 117F1 失败:进入 F1 —— 化学体系应当原样读得回来(NMC),实得「%」', (SELECT chemistry FROM materials WHERE id = v_mat);
    END IF;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('ZZ117-IB', v_mat, v_sup, 100, 100, 'kg', DATE '2027-04-01', 'other', 'fixture 117 自带数据') RETURNING id INTO v_ib;
    -- 化验单带实验室 —— 用引导里那一家(FRL),它是线上唯一真实存在的一家。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO assay_results (code, assay_date, inbound_batch_id, lab_name, weight_basis, result_party)
        VALUES ('ZZ117-AR', DATE '2027-04-01', v_ib, 'FRL', 'as_received', 'ours') RETURNING id INTO v_assay;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 117F1 失败:进入 F1 —— 线上唯一在用的实验室(FRL)必须照旧记得下。实得「%」', v_msg;
    END IF;
    IF (SELECT lab_name FROM assay_results WHERE id = v_assay) IS DISTINCT FROM 'FRL' THEN
        RAISE EXCEPTION 'FIXTURE 117F1 失败:进入 F1 —— 实验室应当原样读得回来(FRL)';
    END IF;

    -- ══════════ F2 · 两张宿主表按【外键名】拒未知码 ═════════════════════════
    RAISE NOTICE 'fixture 117 · 进入 F2';
    v_denied := false; v_msg := NULL; v_con := NULL;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, chemistry)
        VALUES ('ZZ117-MBAD', 'f117 bad chem', 'battery_material', true, 'black_mass', 'end_of_life', 'ZZ117-NOSUCH');
    EXCEPTION
        WHEN foreign_key_violation THEN v_denied := true; GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_con <> 'materials_chemistry_fkey' THEN
        RAISE EXCEPTION 'FIXTURE 117F2 失败:进入 F2 —— 一个不认识的化学体系必须被 materials_chemistry_fkey 拒。**这一臂是"自由文本口关上了"的证明** —— 从前这里会静静存下任何字符串(线上就有一个)。实得 denied=%、约束「%」、msg「%」', v_denied, COALESCE(v_con,'(空)'), COALESCE(v_msg,'(插进去了)');
    END IF;

    v_denied := false; v_msg := NULL; v_con := NULL;
    BEGIN
        INSERT INTO assay_results (code, assay_date, inbound_batch_id, lab_name, weight_basis, result_party)
        VALUES ('ZZ117-ARBAD', DATE '2027-04-01', v_ib, 'ZZ117-NOLAB', 'as_received', 'ours');
    EXCEPTION
        WHEN foreign_key_violation THEN v_denied := true; GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF NOT v_denied OR v_con <> 'assay_results_lab_name_fkey' THEN
        RAISE EXCEPTION 'FIXTURE 117F2 失败:进入 F2 —— 一个不认识的实验室必须被 assay_results_lab_name_fkey 拒。实得 denied=%、约束「%」、msg「%」', v_denied, COALESCE(v_con,'(空)'), COALESCE(v_msg,'(插进去了)');
    END IF;

    -- ══════════ F3 · 加一行,新值当场可用(两张字典各一次)══════════════════
    RAISE NOTICE 'fixture 117 · 进入 F3';
    -- 【这一臂就是"它是不是一张字典"的定义】不建表、不改约束、不跑迁移。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO battery_chemistries (code, name_en, name_zh, sort_order)
        VALUES ('ZZ117_LNMO', 'LNMO (fixture)', '镍锰酸锂(fixture)', 98);
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, chemistry)
        VALUES ('ZZ117-MNEW', 'f117 new chem', 'battery_material', true, 'black_mass', 'end_of_life', 'ZZ117_LNMO');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 117F3 失败:进入 F3 —— 【加一行字典就该能用】。做不成,这就不是一张字典,只是一处换了写法的自由文本。实得「%」', v_msg;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO laboratories (code, name_en, name_zh, sort_order)
        VALUES ('ZZ117_LAB', 'Umpire Lab (fixture)', '仲裁实验室(fixture)', 98);
        INSERT INTO assay_results (code, assay_date, inbound_batch_id, lab_name, weight_basis, result_party)
        VALUES ('ZZ117-AR2', DATE '2027-04-02', v_ib, 'ZZ117_LAB', 'as_received', 'ours');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 117F3 失败:进入 F3 —— 加一家实验室也必须是加一行就能用。**这一半是这张字典今天唯一的实测理由**:线上只有一家实验室,所以它防的是"第二家出现那天"。实得「%」', v_msg;
    END IF;

    -- ══════════ F4 · D1 两个动词 ═══════════════════════════════════════════
    RAISE NOTICE 'fixture 117 · 进入 F4';
    UPDATE battery_chemistries SET is_active = false WHERE code = 'ZZ117_LNMO';
    -- 方向一:已经记下的值一个字不变,而且照样读得出来
    IF (SELECT chemistry FROM materials WHERE code = 'ZZ117-MNEW') IS DISTINCT FROM 'ZZ117_LNMO' THEN
        RAISE EXCEPTION 'FIXTURE 117F4 失败:进入 F4 —— 停用一种化学体系【绝不能】让已经记下的值失效或读不出来。那是当时有人做出的判断,不因为今天不再选它而变成假的';
    END IF;
    -- 而且那一行还【改得动】(录错了要能更正)——外键读了 is_active 的实现在这里会拒
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE materials SET notes = 'f117 touched' WHERE code = 'ZZ117-MNEW';
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 117F4 失败:进入 F4 —— 带着已停用化学体系的那一行必须【改得动】。一个"连 is_active 一起看"的实现会在这里拒,而它同时会让每一条历史行变成非法 —— 一条无痕迹、且一次性对所有单据生效的破坏路径。实得「%」', v_msg;
    END IF;
    -- 方向二:它从【可选集合】里消失(那正是 app 的 loadBatteryChemistries 跑的查询)
    IF EXISTS (SELECT 1 FROM battery_chemistries WHERE is_active AND code = 'ZZ117_LNMO') THEN
        RAISE EXCEPTION 'FIXTURE 117F4 失败:进入 F4 —— 停用之后它必须从可选集合里消失。两个动词:is_active 管"还能不能【新选】",不管"已经记下的还算不算数"';
    END IF;
    UPDATE battery_chemistries SET is_active = true WHERE code = 'ZZ117_LNMO';

    -- ══════════ F5 · D4 顺序照字典,且不是字母序 ═══════════════════════════
    RAISE NOTICE 'fixture 117 · 进入 F5';
    -- 【先钉 sort_order 两两不同】并列时 ORDER BY 的结果是【未定义的】,
    -- 而它可能恰好排成期望的样子 —— 上一刀(PROC-4)就有一臂是这么靠运气绿的。
    SELECT count(DISTINCT sort_order), count(*) INTO v_n, v_by_alpha
      FROM battery_chemistries WHERE code IN ('NMC','NCA','LFP','LCO','LMO','LTO','钠离子','混合');
    IF v_n <> 8 THEN
        RAISE EXCEPTION 'FIXTURE 117F5 失败:进入 F5 —— 八个引导化学体系的 sort_order 必须两两不同,实得 % 个不同值。并列时排序未定义,而"恰好排对了"证明不了顺序来自字典', v_n;
    END IF;
    SELECT string_agg(code, ',' ORDER BY sort_order) INTO v_by_sort
      FROM battery_chemistries WHERE code IN ('NMC','NCA','LFP','LCO','LMO','LTO','钠离子','混合');
    SELECT string_agg(code, ',' ORDER BY code) INTO v_by_alpha
      FROM battery_chemistries WHERE code IN ('NMC','NCA','LFP','LCO','LMO','LTO','钠离子','混合');
    IF v_by_sort = v_by_alpha THEN
        RAISE EXCEPTION 'FIXTURE 117F5 前置失败:进入 F5 —— 字典序与字母序必须不同,否则这一臂证明不了顺序来自字典。实得两者都是「%」', v_by_sort;
    END IF;
    IF v_by_sort <> 'NMC,NCA,LFP,LCO,LMO,LTO,钠离子,混合' THEN
        RAISE EXCEPTION 'FIXTURE 117F5 失败:进入 F5 —— 显示顺序应当由 sort_order 决定,实得「%」', v_by_sort;
    END IF;

    -- ══════════ F6 · 没有【历史逃生门】—— 这一臂钉的是那个裁定 ═══════════
    RAISE NOTICE 'fixture 117 · 进入 F6';
    -- 【本臂原本要钉的是 NOT VALID,而那个方案被实测推翻了 —— 经过写在这里】
    -- 原计划:用 NOT VALID 外键把线上那个占位串「Special Chemistry Structure」
    -- 原样留着,理由是"外键只在外键列变动时校验"。**实测那句话是错的**:
    --     SELECT tgattr FROM pg_trigger WHERE tgisinternal  →  空
    -- RI 触发器不带列清单,于是带着字典外值的那一行【任何字段都改不动】。
    -- 而 MAT-2026-0002 是在册、八个批次在用的真物料。
    -- 裁定因此改成:**把那一行置为 NULL,外键正常生效**——
    -- NULL 在这一列上早就有定义(「没有人记过」),而那正是事实。
    --
    -- 所以这一臂断言的是那个裁定的两半:**没有豁免**,以及 **NULL 是合法的**。

    -- (a) 外键必须是【已验证】的 —— 一条 NOT VALID 的外键意味着"某些旧行不受管",
    --     而那正是本刀决定不留的东西。
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'materials_chemistry_fkey' AND convalidated) THEN
        RAISE EXCEPTION 'FIXTURE 117F6 失败:进入 F6 —— materials_chemistry_fkey 必须是【已验证】的外键。NOT VALID 会留下一批"不受管的旧行",而实测表明那些行【任何字段都改不动】—— 两头都不划算,所以裁定是把那一行置空而不是给它一张豁免票';
    END IF;

    -- (b) 全表不变量:【没有任何一行】的化学体系在字典之外。
    --     这比"插一个坏值会被拒"更强 —— 它断言的是【结果】,不是【闸的存在】。
    SELECT count(*) INTO v_n FROM materials m
     WHERE m.chemistry IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM battery_chemistries c WHERE c.code = m.chemistry);
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 117F6 失败:进入 F6 —— 不该有任何一行物料的化学体系落在字典之外,实得 % 行。**这是本刀真正买到的东西**:自由文本口关上之后,这一列的取值集合是【可枚举的】', v_n;
    END IF;

    -- (c) 而【留空仍然合法】—— 那是"没有人记过",不是一个要被消灭的状态。
    --     少了这一半,一个"chemistry 改成 NOT NULL"的实现也能让上面两条通过,
    --     而它会逼着每个人为一批还没化验的料编一个化学体系出来。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ117-MNULL', 'f117 nobody said', 'battery_material', true, 'black_mass', 'end_of_life');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 117F6 失败:进入 F6 —— 【不填化学体系必须仍然合法】。那是"没有人记过",而这个仓库反复付账的正是把它读成别的东西。实得「%」', v_msg;
    END IF;
    IF (SELECT chemistry FROM materials WHERE code = 'ZZ117-MNULL') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 117F6 失败:进入 F6 —— 没填的化学体系必须【留成 NULL】,不能被默认成任何值';
    END IF;

    -- (d) 实验室那一侧同样:留空合法(没有人记过是哪家出的)
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO assay_results (code, assay_date, inbound_batch_id, weight_basis, result_party)
        VALUES ('ZZ117-ARNULL', DATE '2027-04-03', v_ib, 'as_received', 'ours');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 117F6 失败:进入 F6 —— 不填实验室必须仍然合法(线上 3 行就是这样)。实得「%」', v_msg;
    END IF;
END $$;
ROLLBACK;

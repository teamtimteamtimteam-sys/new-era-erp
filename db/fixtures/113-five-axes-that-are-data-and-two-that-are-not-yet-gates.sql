-- 113 五条进料状态轴:它们是【数据】,而其中两条驱动的规则【还没有闸】
--
-- PROC-2。臂:
--   F1 前提 —— 既有的物料读法与进料读法【照旧】。在任何新东西之前先断言。
--   F2 五条轴各自【按外键】拒掉一个不存在的取值。自由文本的分类会长出四种拼法
--      (materials.category 实测长过),外键是唯一挡得住它的东西。
--   F3 多值那一条:同一批料收得下两个状态,而【同一个状态收第二次要被拒】。
--   F4 has_condition_axes 驱动"要不要说出形态与来源" —— 【两个方向】。
--   F5 implies_dismantling 驱动"要不要说出规格尺寸" —— 【两个方向,而且两头都拦】:
--      该说没说要拒,不适用却说了也要拒。
--   F6 **另外两条规则列现在【真的拦人】** —— PROC-3 建了那道闸,这一臂被【翻过来】了。
--
-- 【F6 的来历,留在这里是因为它本身就是一条方法】
-- 写这一臂的时候闸【还不存在】。当时它断言的是一个"还没建":带着不可投料状态的
-- 一批货【投得进去】。理由是 **一个没有被断言的"还没建",与一个"建了但坏了",
-- 在这里长得一模一样** —— 而且那一臂在文件里写明了 PROC-3 落地那天要
-- 【把它翻过来,不要把它删掉】。
--
-- PROC-3(2026-08-22)落地,于是照那句话翻了过来:现在它断言那一炉【被按名拒】。
-- **一条被删掉的臂与一条从来没写过的臂长得一模一样**,而这份文件现在同时留着
-- 两件事:闸保证了什么,以及在它存在之前这里断言过什么。
-- 【F6 现在保证的】has_condition_axes 的种类,带着 may_be_fed = false 的安全状态时,
-- guard_processing_input 按 INPUT_SAFETY_STATE_NOT_FEEDABLE 拒,并把【那一条状态的
-- 名字】写进消息里(而不是只说"不可投料")。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_sup uuid; v_mat uuid; v_matB uuid; v_ib uuid; v_run uuid;
    v_n int; v_denied boolean; v_msg text; v_b boolean;
    v_process date := CURRENT_DATE - 2;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-113', 'f113', 'f113', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ F1 前提:既有读法照旧 ═══════════════════════════════════════
    -- 五张字典各自播了几行 —— 数目本身是断言:少一行说明引导被动过。
    SELECT count(*) INTO v_n FROM material_forms;
    IF v_n <> 6 THEN RAISE EXCEPTION 'FIXTURE 113F1 失败:进入 F1 —— 形态应当播 6 行,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM material_sources;
    IF v_n <> 3 THEN RAISE EXCEPTION 'FIXTURE 113F1 失败:进入 F1 —— 来源应当播 3 行,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM material_size_formats;
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 113F1 失败:进入 F1 —— 规格尺寸应当播【5】行。medical_aerospace 是【被考虑过并且划掉的】,不是漏了 —— 它断言的是这个厂不处理的一类货,而返回条件是"第一次真的收到医疗或航空电池"。实得 %', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM inbound_safety_states;
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 113F1 失败:进入 F1 —— 安全状态应当播【5】行。**热失控历史不在里面,而那是 Tim 的一个决定,不是一次遗漏** —— 理由写在 inbound_safety_states 的表注上。看到"少了一个"就补,会推翻一个已经做过的决定。实得 %', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM inbound_chemistry_certainties;
    IF v_n <> 3 THEN RAISE EXCEPTION 'FIXTURE 113F1 失败:进入 F1 —— 化学体系确定度应当播 3 行,实得 %', v_n; END IF;

    -- 既有的物料路径照旧:PROC-1 的两列仍在,而八行历史仍然留空
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='materials'
       AND column_name IN ('kind_code','may_be_processed','form_code','source_code','size_format_code');
    IF v_n <> 5 THEN RAISE EXCEPTION 'FIXTURE 113F1 失败:进入 F1 —— materials 应当有那五列,实得 %', v_n; END IF;

    -- 【遮蔽表加一列 = 三件事】第三件正面钉住:新列必须在 _masked 视图里。
    -- gate 的 colgrant 判据是「一张表一旦有 _masked 伴生,每一列都必须在那张视图里」,
    -- 而这一臂让它在【行为】上也成立,不只在结构上。
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='inbound_batches_masked'
       AND column_name='chemistry_certainty_code';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 113F1 失败:进入 F1 —— 新列必须出现在 inbound_batches_masked 里。遮蔽表加一列是【三件事一支迁移】(WO-1a 那一课:列 + 列级授权 + 遮蔽视图),缺第三件闸门的 colgrant 判词会红,而那已经让三刀各付过一次账';
    END IF;

    -- ══════════ F2 五条轴各自按外键拒掉不存在的取值 ═════════════════════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ113-S','f113 supplier','SG','goods_supplier') RETURNING id INTO v_sup;

    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ113-BADFORM','f113','battery_material', true, 'no_such_form', 'end_of_life');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%form_code%' THEN
        RAISE EXCEPTION 'FIXTURE 113F2 失败:进入 F2 —— 形态必须按【外键】拒掉一个不存在的取值,实得 denied=%、msg=「%」。**这一条是这五条轴做成字典的全部理由**:materials.category 是自由文本,线上实测长出了四种命名法而没有任何东西察觉', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ113-BADSRC','f113','battery_material', true, 'black_mass', 'no_such_source');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%source_code%' THEN
        RAISE EXCEPTION 'FIXTURE 113F2 失败:进入 F2 —— 来源必须按外键拒,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
        VALUES ('ZZ113-BADSZ','f113','battery_material', true, 'whole_pack', 'end_of_life', 'no_such_size');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%size_format_code%' THEN
        RAISE EXCEPTION 'FIXTURE 113F2 失败:进入 F2 —— 规格尺寸必须按外键拒,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- 立一个正常的物料,后面几臂都用它
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ113-M','f113 feed','battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ113-MB','f113 output','battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ113-IB', v_mat, v_sup, 100, 100, 'kg', v_process - 1) RETURNING id INTO v_ib;

    v_denied := false;
    BEGIN
        UPDATE inbound_batches SET chemistry_certainty_code = 'no_such_certainty' WHERE id = v_ib;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%chemistry_certainty_code%' THEN
        RAISE EXCEPTION 'FIXTURE 113F2 失败:进入 F2 —— 化学体系确定度必须按外键拒,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    v_denied := false;
    BEGIN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        VALUES (v_ib, 'no_such_state');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%safety_state_code%' THEN
        RAISE EXCEPTION 'FIXTURE 113F2 失败:进入 F2 —— 安全状态必须按外键拒,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ F3 多值:两个收得下,重复要拒 ═══════════════════════════════
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'water_exposed'), (v_ib, 'damaged_deformed');
    SELECT count(*) INTO v_n FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 113F3 失败:进入 F3 —— 一批料要收得下【两个】状态(进过水【并且】破损),实得 % 行。这正是它单独成表而不是做成一列的全部理由', v_n;
    END IF;
    v_denied := false;
    BEGIN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        VALUES (v_ib, 'water_exposed');
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 113F3 失败:进入 F3 —— 同一个状态在同一批上只能记一次。重复不是"更确定",它只会让任何按状态计数的读法开始骗人';
    END IF;

    -- ══════════ F4 has_condition_axes 驱动必填 —— 两个方向 ══════════════════
    -- 方向一:包装类【不许】填这三列(它们对它不适用)
    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ113-PKG','f113 bulk bag','packaging', false, 'black_mass', 'end_of_life');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_KIND_HAS_NO_CONDITION_AXES%' THEN
        RAISE EXCEPTION 'FIXTURE 113F4 失败:进入 F4 —— 一箱吨袋没有"形态/来源"可言,填了要按名拒。**只拦"该填没填"是不够的**:允许在不适用的行上填值,"空"就再也不只有一种意思了,而把空的两种意思分开正是这三条轴存在的理由之一。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 方向二:电池料【必须】填
    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed)
        VALUES ('ZZ113-NOAX','f113 battery no axes','battery_material', true);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_CONDITION_AXES_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 113F4 失败:进入 F4 —— 电池料必须说出形态与来源,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 【改字典就改行为】把 battery_material 的 has_condition_axes 翻掉 →
    -- 同一条 INSERT 立刻通过。这一步证的是"适用条件是【数据】",不是写死的 code。
    UPDATE material_kinds SET has_condition_axes = false WHERE code = 'battery_material';
    -- 【包一层,好让这一臂【按名】报错】不包的话,一个把 battery_material 写死在
    -- 守卫里的实现会让这条 INSERT 直接抛出 MATERIAL_CONDITION_AXES_REQUIRED,
    -- 整个 DO 块当场中止 —— fixture 确实红了,但下面那句解释一个字都印不出来。
    -- **一条抓到了却说不出话的断言,只比没抓到好一点点。**
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed)
        VALUES ('ZZ113-NOAX','f113 battery no axes','battery_material', true);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 113F4 失败:进入 F4 —— 翻掉 has_condition_axes 之后同一条 INSERT 必须【通过】,实得被拒:「%」。**只验一个方向,一个把 battery_material 写死在守卫里的实现照样全绿** —— 而写死就等于把 PROC-1 刚做成数据的东西又变回了代码', v_msg;
    END IF;
    SELECT count(*) INTO v_n FROM materials WHERE code = 'ZZ113-NOAX';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 113F4 失败:进入 F4 —— 翻掉 has_condition_axes 之后那一行应当在,实得 % 行', v_n;
    END IF;
    DELETE FROM materials WHERE code = 'ZZ113-NOAX';
    UPDATE material_kinds SET has_condition_axes = true WHERE code = 'battery_material';

    -- ══════════ F5 implies_dismantling 驱动规格尺寸 —— 两个方向,两头都拦 ════
    -- 要拆解的形态:不说规格尺寸要拒
    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ113-PACK','f113 whole pack','battery_material', true, 'whole_pack', 'end_of_life');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_SIZE_FORMAT_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 113F5 失败:进入 F5 —— 整包要拆解,所以必须说出它来自哪一类应用,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 不拆解的形态:说了规格尺寸【也要拒】
    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
        VALUES ('ZZ113-BM','f113 black mass','battery_material', true, 'black_mass', 'end_of_life', 'ev_traction');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_SIZE_FORMAT_NOT_APPLICABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 113F5 失败:进入 F5 —— 黑粉没有"来自哪一类应用"可言,填了要拒。**黑粉的 size_format 留空是"不适用"** —— 允许填,那一列就会长出一堆没人能依据的值,而空与非空再也分不清含义。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 【改字典就改行为,两个方向】把 black_mass 改成"要拆解" → 同一条 INSERT 通过
    UPDATE material_forms SET implies_dismantling = true WHERE code = 'black_mass';
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('ZZ113-BM','f113 black mass','battery_material', true, 'black_mass', 'end_of_life', 'ev_traction');
    SELECT count(*) INTO v_n FROM materials WHERE code = 'ZZ113-BM';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 113F5 失败:进入 F5 —— 把 black_mass 的 implies_dismantling 翻成 true 之后,同一条 INSERT 必须通过';
    END IF;
    -- 翻回去 → 那一行现在【改不动了】(它带着一个不再适用的规格尺寸)
    UPDATE material_forms SET implies_dismantling = false WHERE code = 'black_mass';
    v_denied := false;
    BEGIN
        UPDATE materials SET notes = 'touched' WHERE code = 'ZZ113-BM';
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_SIZE_FORMAT_NOT_APPLICABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 113F5 失败:进入 F5 —— 规则翻回去之后,那一行【改不动】才是对的:它带着一个不再适用的规格尺寸。**这一头才证明规则是现读的** —— 只在 INSERT 上读一次的实现会让这一步安静通过。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    DELETE FROM materials WHERE code = 'ZZ113-BM';

    -- ══════════ F6 那两条规则列【现在真的拦人】—— 这一臂是被翻过来的 ══════════
    -- 【它原本断言的是"还没有闸"】原文与它留给下一个人的那句话都在文件抬头,
    -- 照抄在这里没有意义 —— 但【它是被翻过来而不是被删掉的】这件事有意义,
    -- 所以写在这里,而不是只写在提交信息里(提交信息改不了,文件读得到)。
    SELECT may_be_fed INTO v_b FROM inbound_safety_states WHERE code = 'charged_not_discharged';
    IF v_b IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 113F6 失败:进入 F6 —— 带电未放电的引导默认应当是"不许投料"(may_be_fed = false),实得 %', v_b;
    END IF;
    -- 给那一批料贴上"带电未放电",然后投 —— **现在应当被按名拒**。
    DELETE FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    VALUES (v_ib, 'charged_not_discharged');
    UPDATE inbound_batches SET chemistry_certainty_code = 'unknown_pending' WHERE id = v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'f113 price');
    v_denied := false; v_msg := NULL;
    BEGIN
        v_run := commit_processing_run(v_process, 'f113 gate exists now', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INPUT_SAFETY_STATE_NOT_FEEDABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 113F6 失败:进入 F6 —— PROC-3 之后,带着「带电未放电」的一批货必须按 INPUT_SAFETY_STATE_NOT_FEEDABLE 拒,实得 denied=%、msg=「%」。**这一臂是从"还没有闸"翻过来的**(见文件抬头),它绿的意思是那道闸真的在读 may_be_fed', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 【消息里要有那一条状态的【名字】,不是只说"不可投料"】
    -- 只报一个码,人得自己去翻是哪一条;而这一批身上可以同时挂着好几条。
    IF v_msg NOT LIKE '%带电未放电%' THEN
        RAISE EXCEPTION 'FIXTURE 113F6 失败:进入 F6 —— 拒绝消息里要点名那一条安全状态(「带电未放电」),否则人得自己去翻是哪一条。实得「%」', v_msg;
    END IF;
    -- 【这一批【同时】还带着一个不可投料的确定度(待识别),而它没有被报出来】
    -- 那不是漏报:安全状态那一条【先】拒,而两条拒绝是分开的两个码(D1)——
    -- 它们的下一步动作不同,所以不合并。清掉安全状态之后才轮得到确定度那一条,
    -- fixture 115 的 F2 正面走那条路。
END $$;
ROLLBACK;

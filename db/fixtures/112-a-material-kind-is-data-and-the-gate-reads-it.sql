-- 112 物料种类是【一张字典】,而投料那道闸【现读它】
--
-- PROC-1。臂与它们要钉的东西:
--   F1 前提 —— 既有的一切【照旧】。在任何推导之前先断言。
--   F2 字典驱动规则:一种【永远不可能被投料】的物料,建不出 may_be_processed = true。
--      **按守卫的【名字】断言,而且走【直插】** —— 要证的是【数据库】拒绝,不是表单拒绝。
--   F3 两列必须同时说出来,各自按名拒。
--   F4 一炉只吃得下 may_be_processed = true 的物料。**先按【码】断言拒绝,
--      再断言反面(可投料的那一个成功)** —— 这样这一臂证的是一个【铰链】,不是一堵墙。
--   F5 **改字典就改行为**:在同一笔事务里翻 may_ever_be_processed,看拒绝【两个方向都动】。
--      这一条才是"它是数据,不是一条乔装的规则"的证明。
--
-- 【为什么 F2/F3 必须走直插】D3 要的性质是"直插也说不出不可能的话"。
-- 经由任何函数或表单去测,证的是那条路,不是那道闸。
--
-- 【README 第 5/6 条】前提显式设定;可见性无关(本刀的判据全是约束与守卫,
-- 不是 RLS),所以不切库角色 —— 但仍自建角色配全权限,因为 record_* 那一族要它。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    v_sup uuid; v_mat uuid; v_matB uuid; v_bad uuid; v_ib uuid; v_run uuid;
    v_n int; v_txt text; v_b boolean; v_denied boolean; v_msg text;
    v_process date := CURRENT_DATE - 3;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-112', 'f112', 'f112', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ F1 前提:既有的一切照旧 ═══════════════════════════════════
    -- 【在任何推导之前】—— 一份改了主档的 fixture,最容易在"别的地方也跟着变了"
    -- 这件事上空转。三条,各查一个不同的既有事实。
    SELECT count(*) INTO v_n FROM material_kinds;
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 112F1 失败:进入 F1 —— 引导应当播下【五】种物料种类(battery_material / ewaste / packaging / consumable / spare_part),实得 %。**没有 other、没有 reagent**:前者看起来像决定而行为上是"我不知道",后者要等第一次真的买工艺药剂(docs/proc-reality.md 的 U1)', v_n;
    END IF;
    -- category 真的走了 —— 而"列还在"与"列没了"在一份只测新列的 fixture 里长得一样
    SELECT count(*) INTO v_n FROM information_schema.columns
     WHERE table_schema='public' AND table_name='materials' AND column_name='category';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 112F1 失败:进入 F1 —— materials.category 应当【已经退役】,实得该列仍在。两列互相重叠的分类、其中一列还是没有 CHECK 的自由文本,正是这套系统长出一个没人信得过的字段的方式(它线上已经长出过四种命名法)';
    END IF;
    -- 【那条约束必须是 NOT VALID —— 而这一条只能在【约束自己】身上断言】
    -- 想断言的是"线上八行历史物料留空不动",但**重建库里一行业务数据都没有**
    -- (README:重建库没有客户、供应商、批次),所以那个断言在这里【只会空转】。
    -- 留下历史不动的【机制】就是 NOT VALID 本身,所以按它断言:
    -- convalidated = false 意味着这条 CHECK 对 INSERT/UPDATE 生效、对既有行不回溯。
    SELECT convalidated INTO v_b FROM pg_constraint
     WHERE conrelid = 'public.materials'::regclass AND conname = 'materials_kind_stated';
    IF v_b IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 112F1 失败:进入 F1 —— materials_kind_stated 必须是 NOT VALID(convalidated = false),实得 %。**做成 VALID 就等于要求为八行历史物料编造八个值** —— 而它们一行都删不掉(每一行都被批次引用着,删物料要一路串进总账)。回填一个没人决定过的值,正是 MAT-1 在本表上明确拒绝过的那件事', COALESCE(v_b::text,'NULL(约束不存在)');
    END IF;

    -- ══════════ F2 字典驱动规则(直插,按守卫的名字)═══════════════════════
    -- consumable.may_ever_be_processed = false → 这一行建不出来。
    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed)
        VALUES ('ZZ112-BAD', 'f112 consumable that claims to be feed', 'consumable', true);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 112F2 失败:进入 F2 —— 一个 consumable 被标成可投料,【数据库必须拒】。这句话是 schema 存得下、而没有任何人能照着做的那一种';
    END IF;
    IF v_msg NOT LIKE '%MATERIAL_KIND_NOT_PROCESSABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 112F2 失败:进入 F2 —— 要按【守卫的名字】拒(MATERIAL_KIND_NOT_PROCESSABLE),实得「%」。一条外键错或一条 CHECK 错都能让上面那半条断言变绿,而它们证的不是这件事', v_msg;
    END IF;

    -- ══════════ F3 两列各自按名拒 ═════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO materials (code, name, may_be_processed) VALUES ('ZZ112-NK', 'f112 no kind', true);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%materials_kind_stated%' THEN
        RAISE EXCEPTION 'FIXTURE 112F3 失败:进入 F3 —— 不说种类的新行必须被 materials_kind_stated 拦下,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        -- 【PROC-2:补上形态与来源】它们不是这一臂要测的东西,但不给就会先撞上
        -- 状态轴那道守卫 —— 一条撞在别的守卫上的断言,证不了它自己说的那件事。
        INSERT INTO materials (code, name, kind_code, form_code, source_code)
        VALUES ('ZZ112-NP', 'f112 no flag', 'battery_material', 'black_mass', 'end_of_life');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%materials_kind_stated%' THEN
        RAISE EXCEPTION 'FIXTURE 112F3 失败:进入 F3 —— 不说【能不能投料】的新行同样必须被拦(默认某一侧就是一个没人做过的决定),实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ F4 那道闸:先拒,再放 —— 证的是铰链不是墙 ═══════════════════
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ112-S','f112 supplier','SG','goods_supplier') RETURNING id INTO v_sup;
    -- 【不可投料的那一个】它是一种合法的电池料,只是我们决定不投它 ——
    -- 也就是说这一臂测的不是"种类不对",而是【这一件的判断】。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ112-NO','f112 battery material we do not feed','battery_material', false, 'black_mass', 'end_of_life') RETURNING id INTO v_bad;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ112-YES','f112 feed','battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ112-OUT','f112 output','battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_matB;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ112-IBNO', v_bad, v_sup, 100, 100, 'kg', v_process - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'f112 price');
    v_denied := false; v_msg := NULL;
    BEGIN
        -- PROC-3:这一支要投料,所以它的电池料批次得带一条【可投料】的安全状态。
        -- 【为什么是一条带 JOIN 的 SELECT,而不是逐个批次写死】本支里哪些批次【吃】
        -- 状态轴,由 material_kinds 回答 —— 实测 ewaste 可加工却【没有】状态轴,
        -- 所以"可加工"并不蕴含"有状态轴"。而没有状态轴的批次插安全状态会被
        -- PROC-2c 的适用性守卫按名拒,所以这个过滤不是优化,是正确性。
        -- 【它出现在每一次投料之前,而不是只在开头一次】批次是各臂【边跑边造】的,
        -- 开头那一次覆盖不到后面才出生的批次。NOT EXISTS 让它重复执行也不撞主键。
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        SELECT ib.id, 'discharged_verified'
          FROM inbound_batches ib
          JOIN materials m       ON m.id   = ib.material_id
          JOIN material_kinds mk ON mk.code = m.kind_code
         WHERE mk.has_condition_axes
           AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                            WHERE s.inbound_batch_id = ib.id);
        v_run := commit_processing_run(v_process, 'f112 must refuse', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_NOT_PROCESSABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 112F4 失败:进入 F4 —— 一批【声明了不投料】的物料不许进加工,而且要按码拒(MATERIAL_NOT_PROCESSABLE),实得 denied=%、msg=「%」。**没有这道闸,may_be_processed 就是一个没有门的库**(D8 亲口说的那个缺陷)', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- 【反面:可投料的那一个必须【成功】】少了这一半,一个"永远拒绝"的实现照样全绿。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ112-IBOK', v_mat, v_sup, 100, 100, 'kg', v_process - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'f112 price');
    -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT ib.id, 'discharged_verified'
      FROM inbound_batches ib
      JOIN materials m       ON m.id   = ib.material_id
      JOIN material_kinds mk ON mk.code = m.kind_code
     WHERE mk.has_condition_axes
       AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = ib.id);
    v_run := commit_processing_run(v_process, 'f112 must pass', 0,
        jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
        jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    IF v_run IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 112F4 失败:进入 F4 —— 可投料的那一个必须走得通。**这一半是那个铰链**:只测拒绝,一个把所有人都拦住的实现会全绿';
    END IF;

    -- 【F4 的第三支:空【不是】"可以"】—— 而这一支只能用历史造出它的那个办法来造。
    -- materials_kind_stated 拦得住任何把 may_be_processed 写成 NULL 的 INSERT/UPDATE,
    -- 所以在重建库里【没有别的路】能得到这个状态;线上那八行是在这条约束存在【之前】
    -- 落下的。这里如实复现那个顺序:去掉约束 → 插入 → 把约束原样加回来。
    -- (整支 fixture 回滚,schema 不留痕。)
    -- **少了这一支,守卫里 `IS NOT TRUE` 与 `IS FALSE` 的区别就没有任何东西验过** ——
    -- 而那正是"没人决定过"被读成"可以"的那一个错(METAL-1 的 no_reference)。
    ALTER TABLE public.materials DROP CONSTRAINT materials_kind_stated;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ112-UND','f112 nobody decided','battery_material', NULL, 'black_mass', 'end_of_life') RETURNING id INTO v_bad;
    ALTER TABLE public.materials ADD CONSTRAINT materials_kind_stated
        CHECK (kind_code IS NOT NULL AND may_be_processed IS NOT NULL) NOT VALID;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date)
    VALUES ('ZZ112-IBUND', v_bad, v_sup, 100, 100, 'kg', v_process - 1) RETURNING id INTO v_ib;
    PERFORM reprice_inbound_batch(v_ib, 1, 'SGD', NULL, 'f112 price');
    v_denied := false; v_msg := NULL;
    BEGIN
        -- PROC-3:同上 —— 这一臂之前又造了新批次,补上可投料的安全状态。
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        SELECT ib.id, 'discharged_verified'
          FROM inbound_batches ib
          JOIN materials m       ON m.id   = ib.material_id
          JOIN material_kinds mk ON mk.code = m.kind_code
         WHERE mk.has_condition_axes
           AND NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                            WHERE s.inbound_batch_id = ib.id);
        v_run := commit_processing_run(v_process, 'f112 undecided must refuse', 0,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', v_ib, 'quantity_consumed', 100)),
            jsonb_build_array(jsonb_build_object('material_id', v_matB, 'quantity', 100)), 'weight', NULL, NULL, 'manual_disassembly');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_NOT_PROCESSABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 112F4 失败:进入 F4 —— 【没有人决定过】的物料同样不许进加工。把空读成"可以",正是本仓库反复付账的那个错(METAL-1 的 no_reference、SS-1 的阈值为 NULL)。实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    IF v_msg NOT LIKE '%undecided%' THEN
        RAISE EXCEPTION 'FIXTURE 112F4 失败:进入 F4 —— 拒绝要说得出是【没人决定过】还是【决定了不投】,实得「%」。两种情形的下一步不一样:一个要人去做决定,一个要人去改决定', v_msg;
    END IF;

    -- ══════════ F5 改字典就改行为 —— 【两个方向】 ═════════════════════════
    -- 方向一:把 battery_material 那一类关掉 → 新建一个可投料的电池料立刻被拒。
    UPDATE material_kinds SET may_ever_be_processed = false WHERE code = 'battery_material';
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
        VALUES ('ZZ112-F5A', 'f112 after flip', 'battery_material', true, 'black_mass', 'end_of_life');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%MATERIAL_KIND_NOT_PROCESSABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 112F5 失败:进入 F5 —— 在同一笔事务里把 battery_material 的 may_ever_be_processed 翻成 false 之后,一个可投料的电池料必须【当场】建不出来。实得 denied=%、msg=「%」。这一步测的是"规则【现读】字典",而不是"规则写死在某处而字典只是装饰"', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    -- 方向二:翻回去 → 同一条 INSERT 必须【成功】
    -- 【单向测试对一个"永远拒绝"的实现是绿的】—— fixture 76 与 111 立的同一条判据。
    UPDATE material_kinds SET may_ever_be_processed = true WHERE code = 'battery_material';
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ112-F5B', 'f112 flipped back', 'battery_material', true, 'black_mass', 'end_of_life');
    SELECT count(*) INTO v_n FROM materials WHERE code = 'ZZ112-F5B';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 112F5 失败:进入 F5 —— 把规则翻回来之后,同一条 INSERT 必须成功。只验一个方向,一个恒拒的实现照样通过';
    END IF;
    -- 而 consumable 那一类【没有被这一轮翻动】—— 证明改的是【那一行】,不是全局开关
    v_denied := false;
    BEGIN
        INSERT INTO materials (code, name, kind_code, may_be_processed)
        VALUES ('ZZ112-F5C', 'f112 consumable still refused', 'consumable', true);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 112F5 失败:进入 F5 —— 翻 battery_material 那一行【不该】影响 consumable。两者一起动,说明判据读的不是那一行而是别的什么';
    END IF;
END $$;
ROLLBACK;

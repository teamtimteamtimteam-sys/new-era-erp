-- 114 门口就记得下来,而一次失败的整组写【不会把已有的那一组抹成空】
--
-- PROC-2c。臂:
--   F1 前提 —— 两条建批次的路【不带新参数】调用时,行为与从前逐字一致:
--      同样的拒绝顺序、同样的行。在任何新东西之前先断言。
--   F2 带上两条轴建批次:记下来了,而且【集合就是集合】—— 两个进、两个出,重复被拒。
--   F3 **原子性,这是 D1 的全部意义**:一次半路失败的整组写,留下的是【前一组】,
--      不是一个空集。**而且把旧写法的那个洞【并排造出来】** —— 不然读的人没法
--      判断这条断言拦住的到底是什么。
--   F4 D4 两个方向:不吃状态轴的种类上填一个值 → 按名拒;
--      吃状态轴的种类什么都没记 → **仍然合法,因为缺席是一个状态**(D3)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_sup uuid; v_mat uuid; v_pkg uuid; v_loc uuid;
    v_res jsonb; v_ib uuid; v_ib2 uuid; v_pkgib uuid;
    v_n int; v_denied boolean; v_msg text; v_codes text[];
    v_arr date := CURRENT_DATE - 1;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-114', 'f114', 'f114', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ114-S','f114 supplier','SG','goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ114-M','f114 feed','battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    -- 【一种不吃状态轴的物料】F4 的另一头要用它
    INSERT INTO materials (code, name, kind_code, may_be_processed)
    VALUES ('ZZ114-PKG','f114 bulk bag','packaging', false) RETURNING id INTO v_pkg;

    -- ══════════ F1 前提:不带新参数 = 从前那样 ══════════════════════════════
    -- 【拒绝顺序也要一样】到货日为空必须先按名拒,而且【什么都不落库】——
    -- 一个先建了行再拒绝的实现,回滚之后看不出区别,但错误的语义已经变了。
    v_denied := false; v_msg := NULL;
    BEGIN
        v_res := create_inbound_batch(v_mat, v_sup, 100);   -- 到货日缺省 NULL
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%ARRIVAL_DATE_REQUIRED%' THEN
        RAISE EXCEPTION 'FIXTURE 114F1 失败:进入 F1 —— 不带新参数时,到货日为空仍应按名拒(ARRIVAL_DATE_REQUIRED),实得 denied=%、msg=「%」。**尾部加默认参数【不许】改变任何既有调用的行为**', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    SELECT count(*) INTO v_n FROM inbound_batches WHERE material_id = v_mat;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 114F1 失败:进入 F1 —— 被拒的那一次【什么都不该落库】,实得 % 行', v_n;
    END IF;

    -- 老调用点的形状:12 个位置参数,一个不多。它必须原样跑通。
    v_res := create_inbound_batch(v_mat, v_sup, 100, 'kg', v_arr, '待加工', NULL, 'f114 legacy call', NULL, NULL, NULL, NULL);
    v_ib := (v_res->>'batch_id')::uuid;
    IF v_ib IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 114F1 失败:进入 F1 —— 既有的 12 参调用必须原样跑通';
    END IF;
    -- 【不给参数 ≠ 给空集】不提这件事的调用,一行安全状态都不该被碰
    SELECT count(*) INTO v_n FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 114F1 失败:进入 F1 —— 没提安全状态的调用不该写任何一行,实得 %', v_n;
    END IF;
    SELECT chemistry_certainty_code IS NULL INTO v_denied FROM inbound_batches WHERE id = v_ib;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 114F1 失败:进入 F1 —— 没提确定度的调用,那一列必须留空';
    END IF;
    -- 第二条路同样
    v_res := receive_inbound_batch_against_po(v_mat, v_sup, 50, v_arr, 'f114 legacy receive');
    IF (v_res->>'batch_id') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 114F1 失败:进入 F1 —— 收货那条路的既有调用必须原样跑通';
    END IF;

    -- ══════════ F2 带上两条轴建批次 ═══════════════════════════════════════
    v_res := create_inbound_batch(v_mat, v_sup, 100, 'kg', v_arr, '待加工', NULL, 'f114 with axes',
                                  NULL, NULL, NULL, NULL,
                                  ARRAY['water_exposed','damaged_deformed'], 'unknown_pending');
    v_ib2 := (v_res->>'batch_id')::uuid;
    SELECT array_agg(safety_state_code ORDER BY safety_state_code) INTO v_codes
      FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib2;
    IF v_codes IS DISTINCT FROM ARRAY['damaged_deformed','water_exposed'] THEN
        RAISE EXCEPTION 'FIXTURE 114F2 失败:进入 F2 —— 门口给的两个状态要原样记下来(一批货可以同时是进过水【和】破损),实得 %', COALESCE(v_codes::text,'NULL');
    END IF;
    SELECT chemistry_certainty_code INTO v_msg FROM inbound_batches WHERE id = v_ib2;
    IF v_msg IS DISTINCT FROM 'unknown_pending' THEN
        RAISE EXCEPTION 'FIXTURE 114F2 失败:进入 F2 —— 确定度应当是 unknown_pending,实得 %', COALESCE(v_msg,'NULL');
    END IF;
    -- 重复不许收 —— 去重会把一个输入错误静悄悄地藏起来
    v_denied := false;
    BEGIN
        PERFORM set_inbound_safety_states(v_ib2, ARRAY['water_exposed','water_exposed']);
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 114F2 失败:进入 F2 —— 同一个状态给两次必须被拒(主键)。**去重会把"记了两次"变成"记了一次"** —— 那是把输入错误藏起来,不是处理掉';
    END IF;

    -- ══════════ F3 原子性 —— 并排造出旧写法的那个洞 ═════════════════════════
    PERFORM set_inbound_safety_states(v_ib2, ARRAY['water_exposed','damaged_deformed']);

    -- 【先把旧写法的洞造出来】PostgREST 一次一条语句,所以 DELETE 与 INSERT
    -- 各自是一个单元。这里用两个独立的子块【逐字复现】那个形状。
    BEGIN
        DELETE FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib2;
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN
        INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
        VALUES (v_ib2, 'no_such_code');
    EXCEPTION WHEN OTHERS THEN NULL; END;
    SELECT count(*) INTO v_n FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib2;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 114F3 前置失败:进入 F3 —— 旧写法(先删后插,两条独立语句)本应留下一个【空集】,实得 % 行。**这一步不是在测新代码,是在证明那个洞真的存在** —— 没有它,下面那条断言拦住的是什么就说不清了', v_n;
    END IF;

    -- 【现在换成 RPC:同样的半路失败,前一组必须原样还在】
    PERFORM set_inbound_safety_states(v_ib2, ARRAY['water_exposed','damaged_deformed']);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_inbound_safety_states(v_ib2, ARRAY['discharged_verified','no_such_code']);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 114F3 失败:进入 F3 —— 数组里带一个不存在的状态码必须被拒';
    END IF;
    SELECT array_agg(safety_state_code ORDER BY safety_state_code) INTO v_codes
      FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib2;
    IF v_codes IS DISTINCT FROM ARRAY['damaged_deformed','water_exposed'] THEN
        RAISE EXCEPTION 'FIXTURE 114F3 失败:进入 F3 —— 一次半路失败的整组写,留下的必须是【前一组】,不是空集。实得 %。**空集在这套系统里是一句有含义的话:"没有人记过"** —— 一次失败的保存把"有人记过"改写成"没有人记过",是一个静默的、方向明确的谎', COALESCE(v_codes::text,'NULL(空集 —— 正是那个洞)');
    END IF;

    -- ══════════ F4 适用性两个方向(D4 / D3)═══════════════════════════════
    -- 方向一:不吃状态轴的种类上填一个值 → 按名拒
    v_res := create_inbound_batch(v_pkg, v_sup, 10, 'kg', v_arr, '待加工', NULL, 'f114 pkg', NULL, NULL, NULL, NULL);
    v_pkgib := (v_res->>'batch_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_inbound_safety_states(v_pkgib, ARRAY['water_exposed']);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INBOUND_CONDITION_NOT_APPLICABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 114F4 失败:进入 F4 —— 一箱吨袋没有"安全状态"可言,填了要按名拒(INBOUND_CONDITION_NOT_APPLICABLE),实得 denied=%、msg=「%」。**规矩放在库里而不是只放在那两条建批次的路上** —— 只放在路上,批次页面就是一条现成的绕行通道', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        UPDATE inbound_batches SET chemistry_certainty_code = 'single_known' WHERE id = v_pkgib;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INBOUND_CONDITION_NOT_APPLICABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 114F4 失败:进入 F4 —— 确定度那一半同样要拒,实得 denied=%、msg=「%」', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- 【建批次那条路上同样要拒 —— 这一臂是故障注入抓出来的】
    -- 守卫第一版按 NEW.id 回头查 inbound_batches,而 BEFORE INSERT 时那一行还不在表里,
    -- 于是它【只在 UPDATE 上有效,在 INSERT 上一声不吭地失效】。
    -- 只测 UPDATE 那一头,这个洞会一直活着。
    v_denied := false; v_msg := NULL;
    BEGIN
        v_res := create_inbound_batch(v_pkg, v_sup, 10, 'kg', v_arr, '待加工', NULL, 'f114 pkg gate',
                                      NULL, NULL, NULL, NULL, NULL, 'single_known');
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE '%INBOUND_CONDITION_NOT_APPLICABLE%' THEN
        RAISE EXCEPTION 'FIXTURE 114F4 失败:进入 F4 —— 在【建批次】那条路上给一箱吨袋填确定度,同样要按名拒,实得 denied=%、msg=「%」。**守卫在 INSERT 与 UPDATE 两条路上都要有效** —— 第一版只在 UPDATE 上有效,而只测一头就永远看不见', v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- 方向二:吃状态轴的种类【什么都没记】—— 仍然合法(D3:缺席是一个状态)
    SELECT count(*) INTO v_n FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 114F4 前置失败:进入 F4 —— 那一批本来就该是零行';
    END IF;
    -- 它必须【存在且可用】,而不是被某处当成"没填完"拦下来
    UPDATE inbound_batches SET notes = 'f114 still editable' WHERE id = v_ib;
    SELECT count(*) INTO v_n FROM inbound_batches WHERE id = v_ib AND notes = 'f114 still editable';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 114F4 失败:进入 F4 —— 一批【吃得下状态轴、却什么都没记】的货必须【仍然合法】。**缺席是一个有名字的状态,不是一个待填的空**(D3)—— 把它做成必填,等于逼着门口的人在不知道的时候编一个答案';
    END IF;
    -- 明说的空集也合法,而且与"没提"结果一致
    PERFORM set_inbound_safety_states(v_ib, ARRAY[]::text[]);
    SELECT count(*) INTO v_n FROM inbound_batch_safety_states WHERE inbound_batch_id = v_ib;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 114F4 失败:进入 F4 —— 明说的空集应当留下零行,实得 %', v_n;
    END IF;
END $$;
ROLLBACK;

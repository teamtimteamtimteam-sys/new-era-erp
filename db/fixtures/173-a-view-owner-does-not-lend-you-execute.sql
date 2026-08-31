-- 173 属主权限【借不到】函数的 EXECUTE —— 而这条规矩仓库里早就写着(INV-VAL-1-fu6)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 存在的理由:一次线上整页失效,三道闸同时看不见】
--   inbound_batch_valuation 是 security_invoker = off 的视图,体内调
--   inbound_batch_landed_unit_cost —— 那支函数【刻意】没有授给 authenticated。
--   视图的属主权限【不改变 current_user】,所以那次函数调用仍按调用者判:
--   任何真实用户 SELECT 到它的计算列就 42501,/inventory 整页渲染成红框。
--   db/functions/aging_bucket.sql 的抬头把这条规矩写得一字不差,而它还是发生了。
--
--   **三道闸为什么都是绿的:**
--     ① INV-VAL-1 的探针是 `SELECT count(*)` —— 计划器把用不到的列剪掉了,
--        那次函数根本没被调用;
--     ② gate 跑 fixture 以 postgres 身份,postgres 有 EXECUTE;
--     ③ 冒烟判 2xx,而那一页把错误画成红框,HTTP 200。
--   本 fixture 专治第 ②:**它自己 SET LOCAL ROLE authenticated**,
--   于是它站在真实用户的位置上问那个问题。
--
-- ★★【四个陷阱,逐个躲开】★★
--   ① **以 postgres 身份断言 = 什么都没断言**:每一臂都在 SET LOCAL ROLE
--      authenticated 之下跑;A 臂先证明【postgres 身份下它本来就是绿的】,
--      好让"换成 authenticated 仍然绿"这句话有分量。
--   ② **count(*) 剪列**:B 臂【明确 SELECT 那几个计算列】,不用 count(*)。
--      写成 count(*) 的话这份 fixture 在缺陷仍然存在时也会通过 —— 实测如此。
--   ③ **注入必须能让它变红**:C 臂把包装函数的 EXECUTE 从 authenticated 收掉,
--      断言视图当场失败,再授回来断言恢复。不做这一步,B 臂可能只是
--      "碰巧没人拦"而不是"包装函数在起作用"。
--   ④ **别把缺陷"修"成一句放宽**:D 臂钉住那条禁令 ——
--      inbound_batch_landed_unit_cost **不许**授给 authenticated。
--      给它授权同样能让 B 臂变绿,而那是把采购单价发给每一个用户。
--      两条一起钉,才排除掉那个错误的修法。
--
-- 自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    v_ops   uuid := gen_random_uuid();
    r_all   uuid; r_ops uuid;
    v_sup   uuid; v_mat uuid; v_ib uuid;
    v_res   jsonb;
    v_cost  numeric; v_val numeric; v_unpriced boolean; v_bucket text;
    v_msg   text; v_denied boolean;
    d_arr   date := DATE '2026-03-10';
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user), (v_ops);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-173', 'f173', 'f173', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- 【受限读者】有 module.inventory.view,【没有】data.view_prices
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-173-ops', 'f173o', 'f173o', true) RETURNING id INTO r_ops;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_ops, code FROM permissions WHERE code IN ('module.inventory.view', 'module.inbound.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_ops, r_ops);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('ZZ173-S', 'f173 supplier', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ173-M', 'f173 feed', 'battery_material', true, 'black_mass', 'end_of_life')
    RETURNING id INTO v_mat;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    v_res := create_inbound_batch(v_mat, v_sup, 100, 'kg', d_arr, '待加工');
    v_ib  := (v_res->>'batch_id')::uuid;
    PERFORM set_inbound_unit_price(v_ib, 50, (SELECT code FROM currencies WHERE is_base));

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 基线:以 postgres 身份读得到(陷阱①的前半 —— 证明数据本身在)
    -- ══════════════════════════════════════════════════════════════════════
    SELECT landed_unit_cost, unpriced INTO v_cost, v_unpriced
      FROM inbound_batch_valuation WHERE id = v_ib;
    IF v_cost IS DISTINCT FROM 50 OR v_unpriced THEN
        RAISE EXCEPTION 'FIXTURE 173A 失败:postgres 身份下应当读到 50.00 且 unpriced=false,实得 %/%',
            COALESCE(v_cost::text,'NULL'), v_unpriced;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · ★**真实用户身份下,读【计算列】不许 42501**★(那次线上故障本身)
    -- ══════════════════════════════════════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    v_denied := false; v_msg := NULL;
    BEGIN
        -- ★ 陷阱②:【明确取那几个计算列】。写 count(*) 会被计划器剪掉列,
        --   于是缺陷还在的时候这一臂照样通过 —— 那正是 INV-VAL-1 漏掉它的方式。
        SELECT landed_unit_cost, landed_value_base, unpriced, aging_bucket
          INTO v_cost, v_val, v_unpriced, v_bucket
          FROM inbound_batch_valuation WHERE id = v_ib;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;

    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 173B 失败:真实用户读 inbound_batch_valuation 的计算列被拒 ——「%」。视图的属主权限【替不了函数的 EXECUTE】,取数必须发生在一支已授权的 SECURITY DEFINER 函数里(那才改变 current_user)',
            v_msg;
    END IF;
    IF v_cost IS DISTINCT FROM 50 OR v_val IS DISTINCT FROM 5000.00 THEN
        RAISE EXCEPTION 'FIXTURE 173B 失败:全权限用户应当读到 50.00 / 5,000.00,实得 %/%',
            COALESCE(v_cost::text,'NULL'), COALESCE(v_val::text,'NULL');
    END IF;

    -- 受限读者:金额 NULL、而 unpriced 仍是 false(「你看不到」≠「它没有价」)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_ops), true);
    SELECT landed_unit_cost, landed_value_base, unpriced
      INTO v_cost, v_val, v_unpriced
      FROM inbound_batch_valuation WHERE id = v_ib;
    IF v_cost IS NOT NULL OR v_val IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 173B 失败:没有 data.view_prices 的读者不该拿到金额,实得 %/%', v_cost, v_val;
    END IF;
    IF v_unpriced THEN
        RAISE EXCEPTION 'FIXTURE 173B 失败:受限读者的 unpriced 必须仍是 false —— 「你看不到这个价」不是「这批货没有价」';
    END IF;
    RESET ROLE;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · ★【注入:把包装函数的 EXECUTE 收掉,视图必须当场失败】★
    --   不做这一步,B 臂证明不了"是那支包装函数在起作用"。
    -- ══════════════════════════════════════════════════════════════════════
    REVOKE EXECUTE ON FUNCTION public.inbound_batch_valuation_rows() FROM authenticated;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    v_denied := false; v_msg := NULL;
    BEGIN
        SELECT landed_unit_cost INTO v_cost FROM inbound_batch_valuation WHERE id = v_ib;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    RESET ROLE;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 173C 失败:收掉 inbound_batch_valuation_rows 的 EXECUTE 之后,视图仍然读得出来 —— 那说明 B 臂的绿灯不是这支包装函数给的,这份 fixture 什么都没证明';
    END IF;
    GRANT EXECUTE ON FUNCTION public.inbound_batch_valuation_rows() TO authenticated;

    -- 授回来必须恢复 —— 否则上面那次"失败"可能是别的原因
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    SELECT landed_unit_cost INTO v_cost FROM inbound_batch_valuation WHERE id = v_ib;
    RESET ROLE;
    IF v_cost IS DISTINCT FROM 50 THEN
        RAISE EXCEPTION 'FIXTURE 173C 失败:授权还回去之后应当恢复成 50.00,实得 %', COALESCE(v_cost::text,'NULL');
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂 · ★【那支成本函数【不许】授给 authenticated】★(排除错误的修法)
    -- ══════════════════════════════════════════════════════════════════════
    -- 给它授权同样能让 B 臂变绿 —— 而它是 definer、直接读基表 unit_price、
    -- 绕过 data.view_prices 遮蔽、且自己不判权限。授出去 = 把采购单价发给
    -- 每一个 authenticated 用户(operations 与 warehouse 正是没有该权限的角色)。
    -- 它排在开账前的权限清理里;在那之前,这一条钉死它。
    IF has_function_privilege('authenticated',
           'public.inbound_batch_landed_unit_cost(uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 173D 失败:inbound_batch_landed_unit_cost 被授给了 authenticated —— 它绕过价格遮蔽且自己不判权限,授出去就是把采购单价发给每一个用户。视图要能读,靠的是 inbound_batch_valuation_rows 那层已授权的 definer 包装,不是给它开口子';
    END IF;

    RAISE NOTICE 'FIXTURE 173 通过:真实用户读得到计算列(50.00 / 5,000.00)、受限读者拿 NULL 而 unpriced 仍 false、收掉包装函数的 EXECUTE 会当场变红、而那支成本函数仍未授权给 authenticated';
END $$;
ROLLBACK;

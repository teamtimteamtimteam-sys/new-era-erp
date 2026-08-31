-- 164 一个【看不见】的断言必须按名拒绝,绝不静默通过 —— PROC-WIRE-1B-ii(SALE-BLIND)
--
-- 【这份 fixture 自带全部数据】重建库里没有业务数据(README 第 2 条)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉的那条原则,以及它为什么必须【两帧分别】钉】
-- 可售性断言此前是 SECURITY INVOKER,而它体内三个依赖各有各的 RLS:
--   output_batches(output.view)· materials(materials.view)· processing_outputs(processing.view)
-- 于是一个部分权限的读者会【静默丢行】,四条拒绝一条都不响 —— 一次
-- **因为看不见而通过**的销售。实测过两处,不是推理:
--   · 只有 processing.view 的读者,对着一批已指定为工序投料的货 → 一条拒绝都没有;
--   · 线上真角色 **warehouse**(无 materials.view)→ 连【法律那条】拒绝都不响。
--
-- ★【两帧分别立臂,理由写在这里】★ 病在两支函数上:
--   assert_output_batch_saleable(外) 与 assert_material_form_saleable(内)。
--   合成一臂,将来把其中一帧重新捅漏的改动,**可以躲在另一帧还绿的后面**。
--
-- ★【为什么药方是"抛",而不是"返回 NULL"】★ 这两支函数 RETURNS void。
--   "无权返回 NULL"是【有返回值】的读取器的药方(PROC-COST-1 fu2 / PROC-COST-2);
--   对一个 void 断言,"返回 NULL"拼出来就是【不抛异常地返回】—— **那正是这个
--   bug 本身**。照抄那条已经成功两次的先例,会把 bug 重新发布一遍。
--   H3/H5 两臂就是拿那个"照抄版"当故障注入,证明本 fixture 抓得住它。
--
-- 【每一臂钉什么】
-- H1 对照:全权读者对着被指定的批次,拿到【第四条】拒绝(证明场景本身是活的)。
-- H2 ★ 外帧:看不见的读者拿到【第五条】拒绝,而不是通过。
-- H3 ★ 注入,证明 H2 不是空转:换回 INVOKER 版,同一个读者【真的会通过】。
--    这一臂若红,说明那个"看不见的读者"其实看得见 —— H2 就是一句空话。
-- H4 ★ 内帧:直接调 assert_material_form_saleable,同样拿到第五条拒绝。
-- H5 ★ 注入,证明 H4 不是空转(同 H3,对内帧)。
-- H6 ★★ **合法卖家不许被这个火警拦住** —— 白名单三把钥匙各一个用户,
--    每一个都必须拿到【真正的】那条拒绝,而不是第五条。
--    这里的危险与 PROC-COST-2 的 Q7 【方向相反】:不是毒 NULL 让数字变小,
--    是一个响在合法卖家头上的火警把线停掉。**没有这一臂,一个"谁都拒"的
--    实现会全绿。**
-- H7 五条拒绝互不相同,一条都没有被并掉。
-- H8 两帧在载荷里分得开(output_batch / material_form)。
--
-- 【本文件按 README 第 6 条写】靠 RLS 的臂(H3/H5 的注入版)【必须】切数据库
-- 角色,否则 postgres 是超级用户、RLS 完全不生效,注入臂会假绿。
-- 靠 has_permission 的臂(受众判据)不需要切 —— 它按 jwt claims 解析。
--
-- 日期:自带。
BEGIN;
DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 全部权限
    u_blind uuid := gen_random_uuid();   -- 只有 processing.view —— 那个盲读者
    u_sale  uuid := gen_random_uuid();   -- 只有 sales.edit
    u_fin   uuid := gen_random_uuid();   -- 只有 finance.edit
    u_out   uuid := gen_random_uuid();   -- 只有 output.view
    r_all uuid; r_blind uuid; r_sale uuid; r_fin uuid; r_out uuid;
    v_mat uuid; v_ano uuid; v_ob uuid; v_ob_ano uuid;
    v_d date := DATE '2027-10-11';
    v_msg text; v_denied boolean;
    v_m5_out text; v_m5_mat text; v_m_earmark text; v_m_legal text;
BEGIN
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-164-all','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all);

    -- 【那个盲读者:只有 processing.view】它【不在】白名单里,而这是刻意的 ——
    -- 持有它并不使人成为卖家;收了它就会让这个读者通过受众判据,
    -- 却依旧看不见 output_batches,等于把闸原样修回成一个哑闸。
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-164-blind','f','f',true) RETURNING id INTO r_blind;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_blind, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_blind, r_blind);

    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-164-sale','f','f',true) RETURNING id INTO r_sale;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_sale, 'module.sales.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_sale, r_sale);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-164-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_fin, 'module.finance.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fixture-164-out','f','f',true) RETURNING id INTO r_out;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_out, 'module.output.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_out, r_out);

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);

    -- 【被测的是【正极片】:形态可售,却又要往下走】拿一个本来就不可售的形态
    -- 来测工序指定那一条,会因为错的理由通过(fixture 157 同一条)。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ164-CAT','f160 cathode','battery_material', true, 'cathode_sheet','end_of_life') RETURNING id INTO v_mat;
    -- 内帧要一个【法律上不许卖】的形态。
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZ164-ANO','f160 anode','battery_material', true, 'anode_sheet','end_of_life') RETURNING id INTO v_ano;
    IF (SELECT may_be_sold FROM material_forms WHERE code='anode_sheet') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 164 前置失败:内帧要的是一个【法律上不许卖】的形态,而负极片竟然可售 —— 换一个 may_be_sold = false 的形态,不要删这一臂';
    END IF;

    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ164-OB', v_mat, 100, 100, 'kg', v_d, '库存中') RETURNING id INTO v_ob;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, unit, output_date, state)
    VALUES ('ZZ164-OBA', v_ano, 100, 100, 'kg', v_d, '库存中') RETURNING id INTO v_ob_ano;

    PERFORM set_output_batch_purpose(v_ob, 'process_feed');
    -- 【先证明场景是活的】指定真的落到了那一行上,否则后面每一句都是空的。
    IF (SELECT purpose_code FROM output_batches WHERE id = v_ob) <> 'process_feed' THEN
        RAISE EXCEPTION 'FIXTURE 164 前置失败:指定没有落到那一行上 —— 后面每一句断言都是空的';
    END IF;

    -- ══════════ H1 · 对照:全权读者拿到【第四条】拒绝 ══════════
    RAISE NOTICE 'fixture 164 · 进入 H1';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assert_output_batch_saleable(v_ob); EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 164H1 失败:全权读者对着一批已指定为工序投料的货,必须拿到第四条拒绝。**这是整份 fixture 的铰链** —— 场景本身若不成立,后面每一臂都在测空气。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;
    v_m_earmark := v_msg;

    -- ══════════ H2 · ★ 外帧:看不见的读者拿到【第五条】拒绝 ★ ══════════
    RAISE NOTICE 'fixture 164 · 进入 H2';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_blind), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assert_output_batch_saleable(v_ob); EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_CANNOT_ESTABLISH_SALEABILITY|%' THEN
        RAISE EXCEPTION 'FIXTURE 164H2 失败:**一个断言绝不许因为看不见而通过。** 看不见这一批的读者必须拿到【第五条】拒绝(SALE_CANNOT_ESTABLISH_SALEABILITY),而不是静默放行。实得「%」', COALESCE(v_msg,'*** 通过了 —— 这正是 SALE-BLIND ***');
    END IF;
    IF v_msg NOT LIKE '%|output_batch' THEN
        RAISE EXCEPTION 'FIXTURE 164H2 失败:第五条拒绝必须说出【是哪一帧】—— 外帧的载荷末段应是 output_batch。实得「%」', v_msg;
    END IF;
    v_m5_out := v_msg;

    -- ══════════ H4 · ★ 内帧:法律那条拒绝也不许因为看不见而不响 ★ ══════════
    RAISE NOTICE 'fixture 164 · 进入 H4';
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assert_material_form_saleable(v_ano); EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF NOT v_denied OR v_msg NOT LIKE 'SALE_CANNOT_ESTABLISH_SALEABILITY|%|material_form' THEN
        RAISE EXCEPTION 'FIXTURE 164H4 失败:内帧(assert_material_form_saleable)扛的是【法律】那条拒绝 —— 没有旁路的那一条。它看不见 materials 时同样必须按名拒,并标出 material_form 这一帧。**只修外面那一支,等于发布一道下一层还漏着的闸。** 实得「%」', COALESCE(v_msg,'*** 通过了 ***');
    END IF;
    v_m5_mat := v_msg;

    -- ══════════ H6 · ★★ 合法卖家不许被这个火警拦住 ★★ ══════════
    -- 【白名单三把钥匙各一个用户】每一个都必须拿到【真正的】那条拒绝。
    -- **没有这一臂,一个"谁都拒"的实现会全绿** —— 而那是一个把线停掉的实现。
    RAISE NOTICE 'fixture 164 · 进入 H6';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_sale), true);
    v_msg := NULL;
    BEGIN PERFORM assert_output_batch_saleable(v_ob); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 164H6 失败(module.sales.edit):合法卖家必须拿到【真正的】那条拒绝,而不是"你没资格判断"。第五条拒绝是一个火警,响在合法卖家头上就是把线停掉。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_msg := NULL;
    BEGIN PERFORM assert_output_batch_saleable(v_ob); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 164H6 失败(module.finance.edit):**这一把是那条唯一可达路径的钥匙**(sales_records 面向客户端的 INSERT 策略要的就是它)。它被第五条拒绝挡住,等于把唯一能走的那条路堵死。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_out), true);
    v_msg := NULL;
    BEGIN PERFORM assert_output_batch_saleable(v_ob); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE 'SALE_BATCH_EARMARKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 164H6 失败(module.output.view):在批次页上合法看这一批的人,该拿到【真正的】那条拒绝。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;

    -- 内帧的法律拒绝,对一个合法卖家仍然要响(不是被受众判据吃掉)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_sale), true);
    v_msg := NULL;
    BEGIN PERFORM assert_material_form_saleable(v_ano); EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg IS NULL OR v_msg NOT LIKE 'SALE_FORM_NOT_SALEABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 164H6 失败:合法卖家对着一个【法律不许卖】的形态,必须拿到法律那条拒绝 —— 受众判据不许把它吃掉。实得「%」', COALESCE(v_msg,'(通过了)');
    END IF;
    v_m_legal := v_msg;

    -- ══════════ H7 · 五条拒绝互不相同 ══════════
    RAISE NOTICE 'fixture 164 · 进入 H7';
    IF split_part(v_m5_out,'|',1) = split_part(v_m_earmark,'|',1)
       OR split_part(v_m5_out,'|',1) = split_part(v_m_legal,'|',1) THEN
        RAISE EXCEPTION 'FIXTURE 164H7 失败:第五条拒绝【不许】与前四条中任何一条同码。四条各自对应一个明确的下一步动作,第五条对应的是【去要权限】—— 并成一句,操作员就不知道该做什么。实得 5=「%」 4=「%」 法律=「%」', v_m5_out, v_m_earmark, v_m_legal;
    END IF;

    -- ══════════ H8 · 两帧在载荷里分得开 ══════════
    RAISE NOTICE 'fixture 164 · 进入 H8';
    IF split_part(v_m5_out,'|',3) = split_part(v_m5_mat,'|',3) THEN
        RAISE EXCEPTION 'FIXTURE 164H8 失败:两帧必须分得开(output_batch / material_form)—— 否则将来把其中一帧重新捅漏的改动,可以躲在另一帧还绿的后面。实得 外=「%」 内=「%」', v_m5_out, v_m5_mat;
    END IF;

    -- ══════════ H3 / H5 · ★ 故障注入:证明 H2 / H4 不是空转 ★ ══════════
    -- 【把两支函数换回 INVOKER 版(受众判据一并去掉)】—— 也就是"照抄那条
    -- 有返回值的读取器的药方"会写出来的东西:无权时【不抛异常地返回】。
    -- 这两臂断言:那个版本【真的会让盲读者通过】。
    -- 若它红了,说明那个"看不见的读者"其实看得见,H2/H4 就是两句空话。
    --
    -- ★【README 第 6 条:这两臂靠 RLS,必须切数据库角色】★ postgres 是超级
    -- 用户,RLS 对它完全不生效 —— 不切角色,注入版照样看得见,这两臂会假绿。
    RAISE NOTICE 'fixture 164 · 进入 H3/H5(故障注入)';
    CREATE OR REPLACE FUNCTION public.assert_output_batch_saleable(p_output_batch_id uuid)
     RETURNS void LANGUAGE plpgsql AS $inj$
    DECLARE v_material uuid; v_code text; v_purpose text; v_zh text; v_en text;
    BEGIN
        SELECT ob.material_id, ob.code, ob.purpose_code INTO v_material, v_code, v_purpose
          FROM public.output_batches ob JOIN public.materials m ON m.id = ob.material_id
         WHERE ob.id = p_output_batch_id;
        IF NOT FOUND THEN RETURN; END IF;
        SELECT p.name_zh, p.name_en INTO v_zh, v_en FROM public.output_batch_purposes p
         WHERE p.code = v_purpose AND p.is_saleable_stock IS FALSE;
        IF FOUND THEN RAISE EXCEPTION 'SALE_BATCH_EARMARKED|%|%|%', v_code, v_zh, v_en; END IF;
    END; $inj$;
    CREATE OR REPLACE FUNCTION public.assert_material_form_saleable(p_material_id uuid)
     RETURNS void LANGUAGE plpgsql AS $inj$
    DECLARE v_form text; v_zh text; v_en text;
    BEGIN
        SELECT f.code, f.name_zh, f.name_en INTO v_form, v_zh, v_en
          FROM public.materials m JOIN public.material_forms f ON f.code = m.form_code
         WHERE m.id = p_material_id AND f.may_be_sold IS FALSE;
        IF FOUND THEN RAISE EXCEPTION 'SALE_FORM_NOT_SALEABLE|%|%|%', v_form, v_zh, v_en; END IF;
    END; $inj$;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_blind), true);

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assert_output_batch_saleable(v_ob); EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 164H3 失败(注入臂):换回 INVOKER 版之后,那个盲读者【本该通过】—— 它没通过,说明这个读者其实看得见那一批,于是 H2 是一句空话。实得「%」', v_msg;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM assert_material_form_saleable(v_ano); EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM; END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 164H5 失败(注入臂):换回 INVOKER 版之后,内帧对那个盲读者【本该通过】—— 它没通过,说明 H4 是一句空话。实得「%」', v_msg;
    END IF;

    RESET ROLE;
END $$;
ROLLBACK;

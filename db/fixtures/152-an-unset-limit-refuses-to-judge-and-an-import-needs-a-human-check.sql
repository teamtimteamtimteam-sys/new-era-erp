-- 152 CMPL-1:【没录上限就拒绝作判断】,而三种"缺"给三条不同的话;
--            进口尽调是【记录 + 告警】,不是第二道拒绝
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   A ★ 三种缺法【三条不同的码】★ —— 合成一句就是 CHAIN-BUILD-1 刚修好的病
--       A1 两样都缺(**今天线上就是这一种**)
--       A2 只缺吨数(上限录了)
--       A3 只缺上限(吨数算得出来 —— 靠注入把它变成算得出来)
--   B  ★【会成功】的对照★ 两样都在时它【真的作判断】,而且两个方向都验
--       (在限内 true / 超限 false)—— 少了它,一个"永远抛"的实现能让 A 全绿
--   C  在场危废吨数【今天返回 NULL,而 NULL 不是 0】
--   D  进口尽调的三个状态【分得开】,而空白【不等于】"不是进口货"
--   E  约束:不是进口货就不许有核验记录;核验人与核验时刻同生同灭
--   F  告警臂 import_permit_unverified 只对【是进口且未核】的那一票上牌
--   G  公司执照到期臂复用 certificate_types 自带的 warn_lead_days
--
-- 【躲开的陷阱】
--  (a) 两份实现碰巧一致 —— B 臂两个方向都断言具体的布尔值,不是"没抛"
--  (b) 目录断言命中注释 —— 一律走行为与 pg_catalog
--  (c) definer 无调用者检查 —— licence_storage_within_limit 自己查权限,G2 断言它拒
--  (d) 空集通过 —— 每一处都断言【具体的码】或【具体的行数】
--  (e) 什么都没注入的注入 —— 三处注入都先断言定义真的变了
--  (f) 断言为真却没有管辖权 —— A 臂不满足于"抛了",它断言**抛的是哪一条码**;
--      注入③把三分支合并成一条,断言 A2/A3 当场退化成同一句话
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_sup    uuid; v_mat uuid; v_ib uuid; v_ib2 uuid;
    v_msg    text; v_denied boolean; v_n integer; v_b boolean;
    v_def    text; v_inj text;
    v_lic    uuid;
BEGIN
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (v_user, now());
    INSERT INTO roles (code,name_en,name_zh,is_active)
      VALUES ('fixture-152','f','f',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
      SELECT r_all, unnest(ARRAY['module.suppliers.view','module.suppliers.edit',
                                 'module.inbound.view','module.inbound.edit',
                                 'module.purchasing.view','module.materials.view']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ C 在场危废吨数今天【算不出来】(NULL ≠ 0)══════════
    IF hazardous_qty_on_hand_tonnes() IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 152C 失败:今天它应当返回 NULL(算不出来),实得 %',
            hazardous_qty_on_hand_tonnes(); END IF;

    -- ══════════ A1 两样都缺 —— 今天线上的真实状态 ══════════
    -- 【先确认前提】公司一张带上限的执照都没有,否则这一臂验的不是"都缺"
    SELECT count(*) INTO v_n FROM company_compliance
     WHERE deleted_at IS NULL AND approved_storage_limit_tonnes IS NOT NULL;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 152A1 失败:前提不成立 —— 已经有 % 张带上限的执照', v_n; END IF;

    v_denied := false;
    BEGIN PERFORM licence_storage_within_limit();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 152A1 失败:★两样输入都缺,它却给出了一个判断★ —— 一个"没录上限就一律通过"的检查比没有检查更坏,它制造出信心'; END IF;
    IF v_msg <> 'LICENCE_STORAGE_INPUTS_BOTH_MISSING' THEN
        RAISE EXCEPTION 'FIXTURE 152A1 失败:应报【两样都缺】那一条,实得「%」', v_msg; END IF;

    -- ══════════ A2 只缺【吨数】—— 录一张带上限的执照 ══════════
    -- 【这里的值是明显的测试值,不是样本值】样本执照属于另一家公司,
    -- 它的任何一个数字都没有、也不会进到这个仓库里来。
    INSERT INTO company_compliance (cert_type_code, cert_no, approved_storage_limit_tonnes, status)
    VALUES ('gwdf', 'ZZ-FIX152', 100, 'active') RETURNING id INTO v_lic;

    v_denied := false;
    BEGIN PERFORM licence_storage_within_limit();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'HAZARDOUS_QTY_NOT_COMPUTABLE' THEN
        RAISE EXCEPTION 'FIXTURE 152A2 失败:上限录了、吨数算不出来时,应报【吨数算不出来】那一条,实得「%」—— 报成"没录上限"会把人送去录一个【已经录了】的东西', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ A3 只缺【上限】—— 注入①让吨数变得算得出来 ══════════
    v_def := pg_get_functiondef('public.hazardous_qty_on_hand_tonnes()'::regprocedure);
    v_inj := replace(v_def, 'RETURN NULL;', 'RETURN 5;');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 152 注入① 失败:没找到 RETURN NULL —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    IF hazardous_qty_on_hand_tonnes() IS DISTINCT FROM 5 THEN
        RAISE EXCEPTION 'FIXTURE 152 注入① 失败:注入之后吨数应当算得出来'; END IF;

    UPDATE company_compliance SET approved_storage_limit_tonnes = NULL WHERE id = v_lic;
    v_denied := false;
    BEGIN PERFORM licence_storage_within_limit();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'LICENCE_STORAGE_LIMIT_NOT_SET' THEN
        RAISE EXCEPTION 'FIXTURE 152A3 失败:吨数算得出、没录上限时,应报【没录上限】那一条,实得「%」', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ B ★【会成功】的对照,两个方向都验★ ══════════
    -- 少了它,一个"永远抛"的实现能让 A1/A2/A3 全绿。
    UPDATE company_compliance SET approved_storage_limit_tonnes = 10 WHERE id = v_lic;
    v_b := licence_storage_within_limit();
    IF v_b IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 152B 失败:5 吨在 10 吨上限【之内】,应当判 true,实得 %', v_b; END IF;
    UPDATE company_compliance SET approved_storage_limit_tonnes = 4 WHERE id = v_lic;
    v_b := licence_storage_within_limit();
    IF v_b IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 152B 失败:5 吨【超过】4 吨上限,应当判 false,实得 % —— 一个永远返回 true 的实现会在这里被抓住', v_b; END IF;

    -- 【过期/中止的执照不该再管着它】—— 上限只从【在效】的执照上取
    UPDATE company_compliance SET status='revoked', approved_storage_limit_tonnes=10 WHERE id=v_lic;
    v_denied := false;
    BEGIN PERFORM licence_storage_within_limit();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg <> 'LICENCE_STORAGE_LIMIT_NOT_SET' THEN
        RAISE EXCEPTION 'FIXTURE 152B 失败:一张【已吊销】执照上的上限不该还算数,应当退回"没录上限",实得「%」', COALESCE(v_msg,'(没有报错)'); END IF;
    UPDATE company_compliance SET status='active' WHERE id=v_lic;

    -- ══════════ 注入③(陷阱 f)把三分支合并成一条,断言 A 臂当场瞎掉 ══════════
    -- A 臂宣称的是「三种缺法给三条【不同】的话」。光断言"抛了"管不住这件事。
    v_def := pg_get_functiondef('public.licence_storage_within_limit()'::regprocedure);
    v_inj := replace(v_def, 'RAISE EXCEPTION ''LICENCE_STORAGE_LIMIT_NOT_SET'';',
                            'RAISE EXCEPTION ''LICENCE_STORAGE_INPUTS_BOTH_MISSING'';');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 152 注入③ 失败:没找到那条码 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    UPDATE company_compliance SET approved_storage_limit_tonnes = NULL WHERE id = v_lic;
    v_msg := NULL;
    BEGIN PERFORM licence_storage_within_limit();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'LICENCE_STORAGE_INPUTS_BOTH_MISSING' THEN
        RAISE EXCEPTION 'FIXTURE 152 注入③ 失败:合并之后它应当退化成【两样都缺】那一句,实得「%」—— 说明 A3 断的不是那条码', COALESCE(v_msg,'(没有报错)'); END IF;
    EXECUTE v_def;
    v_msg := NULL;
    BEGIN PERFORM licence_storage_within_limit();
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    IF v_msg <> 'LICENCE_STORAGE_LIMIT_NOT_SET' THEN
        RAISE EXCEPTION 'FIXTURE 152 注入③ 失败:恢复定义之后应当又报【没录上限】,实得「%」', COALESCE(v_msg,'(没有报错)'); END IF;

    -- 恢复吨数函数,回到"今天算不出来"
    EXECUTE (SELECT replace(pg_get_functiondef('public.hazardous_qty_on_hand_tonnes()'::regprocedure),
                            'RETURN 5;', 'RETURN NULL;'));
    IF hazardous_qty_on_hand_tonnes() IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 152 失败:吨数函数没有恢复成 NULL'; END IF;

    -- ══════════ G2(陷阱 c)它是 definer,所以自己查权限 —— 换个没权限的人 ══════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', gen_random_uuid()), true);
    v_denied := false;
    BEGIN PERFORM licence_storage_within_limit();
    EXCEPTION WHEN OTHERS THEN v_denied := (SQLERRM LIKE 'PERMISSION_DENIED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 152G2 失败:它是 SECURITY DEFINER,属主权限绕过 RLS,那句权限检查不是礼节'; END IF;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ D/E 进口尽调:三个状态分得开,空白不等于"不是进口" ══════════
    INSERT INTO suppliers (code, legal_name, country, supplier_types, counterparty_type)
    VALUES ('ZZFIX152-S','fixture 152 supplier','SG',ARRAY['recycler'],'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX152-M','fixture 152 material','battery_material',true,'black_mass','end_of_life') RETURNING id INTO v_mat;

    -- 状态一:【还没有人说】—— imported 是 NULL。**这不等于"不是进口货"。**
    v_ib := (create_inbound_batch(v_mat, v_sup, 100, 'kg', DATE '2027-05-01')->>'batch_id')::uuid;
    IF (SELECT imported FROM inbound_batches WHERE id=v_ib) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 152D 失败:新收的批次 imported 应当是 NULL(还没有人说),而不是被默认成 false —— 一个空白读成"不是进口"正是本仓库反复付账的那种沉默'; END IF;

    -- 状态二:【是进口、还没核】→ 告警臂应当上牌
    UPDATE inbound_batches SET imported = true WHERE id = v_ib;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type='import_permit_unverified' AND item_id = v_ib;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 152F 失败:是进口且未核的批次应当上牌一次,实得 %', v_n; END IF;

    -- 状态三:【是进口、已核】→ 牌应当落下
    UPDATE inbound_batches
       SET import_permit_ref = 'ZZ-FIX152-PERMIT',
           import_permit_verified_by = v_user,
           import_permit_verified_at = now()
     WHERE id = v_ib;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type='import_permit_unverified' AND item_id = v_ib;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 152F 失败:核过之后不该再上牌,实得 %', v_n; END IF;

    -- 【而"不是进口货"的那一张从来不上牌】—— 与"已核"是两回事,但结果同为不上牌;
    -- 分得开靠的是 imported 这一列本身,而 D 臂已经钉了 NULL ≠ false。
    v_ib2 := (create_inbound_batch(v_mat, v_sup, 50, 'kg', DATE '2027-05-02')->>'batch_id')::uuid;
    UPDATE inbound_batches SET imported = false WHERE id = v_ib2;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type='import_permit_unverified' AND item_id = v_ib2;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 152F 失败:明确不是进口货的批次不该上牌,实得 %', v_n; END IF;

    -- E 约束:不是进口货却填核验记录 → 拒
    v_denied := false;
    BEGIN
        UPDATE inbound_batches SET import_permit_ref = 'ZZ-NOPE' WHERE id = v_ib2;
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 152E 失败:不是进口货的批次不该有核验记录 —— 那一行自相矛盾'; END IF;

    -- E 约束:核验人与核验时刻同生同灭
    v_denied := false;
    BEGIN
        UPDATE inbound_batches SET import_permit_verified_at = NULL WHERE id = v_ib;
    EXCEPTION WHEN OTHERS THEN v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 152E 失败:只留核验人不留核验时刻,说不出"什么时候核的"'; END IF;

    -- ══════════ G 公司执照到期臂:复用 certificate_types 自带的 lead days ══════════
    UPDATE company_compliance
       SET valid_until = CURRENT_DATE + 10, status='active'   -- gwdf 的 warn_lead_days 是 90
     WHERE id = v_lic;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type='company_licence_expiring' AND item_id = v_lic;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 152G 失败:十天后到期的执照应当在到期臂上,实得 %', v_n; END IF;

    -- 【会落牌的对照】把到期日推到 lead days 之外 → 安静(证明它读的是 lead days,
    -- 而不是"只要有 valid_until 就上牌")
    UPDATE company_compliance SET valid_until = CURRENT_DATE + 400 WHERE id = v_lic;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type='company_licence_expiring' AND item_id = v_lic;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 152G 失败:远未到期的执照不该上牌,实得 % —— 说明它没在读 warn_lead_days', v_n; END IF;
END $$;
ROLLBACK;

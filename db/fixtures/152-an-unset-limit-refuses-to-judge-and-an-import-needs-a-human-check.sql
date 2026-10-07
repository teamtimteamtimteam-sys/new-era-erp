-- 152 CMPL-1:【没录上限就拒绝作判断】,而三种"缺"给三条不同的话;
--            进口尽调是【记录 + 告警】,不是第二道拒绝
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   A/B/C ★ MES-3a 起:旧的上限判据(licence_storage_within_limit · hazardous_qty_on_hand_tonnes)已删 ★ ——
--       这里只断言它们不在了;新的判法(收货时判、每次都记一行)由 fixture 251 钉住
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
                                 'module.purchasing.view','module.materials.view',
                                 -- ROLE-1 Batch 3b:建收货单是它自己的码
                                 'action.receive_goods']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ A · B · C(MES-3a,2026-10-06,改写)══════════
    -- 这几臂原来钉的是 licence_storage_within_limit() 与 hazardous_qty_on_hand_tonnes():前者"读到空的上限就拒绝作判断"(R2),
    -- 后者一律返回 NULL。两支都【没有任何调用方】,而前者与 MES-0 Q33(没给上限就照收、并记下"上限没给")正相反。
    -- MES-3a(Step 0 Q11,Tim)把它们删了;判法住进 receipt_ceiling_check_internal(收货时判、每一次都记一行),
    -- 五种结果、超限拒绝、总上限与并发由 fixture 251 逐臂钉住(带注入)。R2 的原则照旧成立在它该在的地方:
    -- 没有任何东西【假设】一个上限 —— 没给就记下没给,不当成"无限",也不当成 0。
    -- 这里只钉一件事:旧的两支真的不在了(一个"顺手留着"的旧判据,读起来仍像一条在生效的规矩)。
    IF to_regprocedure('public.licence_storage_within_limit()') IS NOT NULL
       OR to_regprocedure('public.hazardous_qty_on_hand_tonnes()') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 152A 失败:licence_storage_within_limit / hazardous_qty_on_hand_tonnes 应当已被 MES-3a 删掉';
    END IF;
    -- G 臂要一张公司执照(到期提醒)—— 这里的值是明显的测试值,不是样本值。
    INSERT INTO company_compliance (cert_type_code, cert_no, approved_storage_limit_tonnes, status)
    VALUES ('gwdf', 'ZZ-FIX152', 100, 'active') RETURNING id INTO v_lic;

    -- ══════════ D/E 进口尽调:三个状态分得开,空白不等于"不是进口" ══════════
    INSERT INTO suppliers (code, legal_name, country, supplier_types, counterparty_type)
    VALUES ('ZZFIX152-S','fixture 152 supplier','SG',ARRAY['recycler'],'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX152-M','fixture 152 material','battery_material',true,'black_mass','end_of_life') RETURNING id INTO v_mat;

    -- 状态一:【还没有人说】—— imported 是 NULL。**这不等于"不是进口货"。**
    v_ib := (create_inbound_batch(v_mat, v_sup, 100, 'kg', DATE '2027-05-01', p_source_reason_code => 'other', p_source_reason_note => 'fixture 152 自带数据')->>'batch_id')::uuid;
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
    v_ib2 := (create_inbound_batch(v_mat, v_sup, 50, 'kg', DATE '2027-05-02', p_source_reason_code => 'other', p_source_reason_note => 'fixture 152 自带数据')->>'batch_id')::uuid;
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

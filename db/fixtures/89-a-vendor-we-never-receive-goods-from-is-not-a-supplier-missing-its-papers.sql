-- 89 一个我们从不收货的往来户,【不是】一个缺证的供应商
--
-- 【它守的是什么】SUP-TYPE-1a 之前,suppliers 这张表把两件不同的事混在一起:
-- 会送货来的供应商,和只收钱的往来户(房东、水电、保险、专业服务、承包商)。
-- 混同的代价是实测过的:把一个只收钱的往来户推到 status='active',
-- operations_now 的 qualification_missing 支当场亮起,days_waiting 一路长下去,
-- **而它永远不会灭** —— 房东不会去办一张危废证。
--
-- 【这份 fixture 的每一臂都要能分辨"收窄"与"关掉"】
-- 把那一支整个删掉,永久亮灯也会消失 —— 所以每一条"不该亮"的断言旁边,
-- 都必须有一条"该亮的仍然亮"。少了后者,一个把整支注释掉的实现就能全绿。
-- A/B 是这一对,E/F 是 supplier_receipt_pattern 上的同一对。
--
-- 【本 fixture 以 postgres 跑】
-- operations_now 与 supplier_receipt_pattern 都是属主权限视图,门是体内的
-- has_permission()(按 claims 解析,与数据库角色无关,README 第 6 条)。
-- 收货那两臂测的是【触发器】,它对任何角色都开火,所以也不需要切角色。
--
-- 【故障注入:每一处判据都是单层的】
-- 收窄谓词、触发器、以及"只在换供应商时管 UPDATE"那一条,各自没有第二道闸。
-- 注入记录在切次报告里,基线在任何注入之前先跑过。
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();
    r_all uuid;
    sup_goods uuid; sup_vendor uuid;
    mat uuid; b uuid; po uuid; l uuid;
    v_msg text; v_denied boolean; n int;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-89', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_all, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);

    INSERT INTO materials (code, name, category)
    VALUES ('FX89-M', 'fixture 89 material', 'other') RETURNING id INTO mat;

    -- 【两家,只差一个标记】—— 其余字段完全一致,于是任何差异都只能来自 supplies_goods。
    -- 两家都【没有任何合规证书】,这是 A/B 这一对的前提:证书不是变量,标记才是。
    INSERT INTO suppliers (code, legal_name, country, supplies_goods)
    VALUES ('FX89-GOODS', 'fixture 89 goods supplier', 'SG', true) RETURNING id INTO sup_goods;
    INSERT INTO suppliers (code, legal_name, country, supplies_goods)
    VALUES ('FX89-VENDOR', 'fixture 89 landlord', 'SG', false) RETURNING id INTO sup_vendor;

    -- 两家都推到 active —— 那正是 SUP-TYPE-0 用来证明永久亮灯的那条合法路径。
    -- 【状态机一个字没动】(本刀明确不碰它),所以必须逐级走。
    UPDATE suppliers SET status='pending_review' WHERE id IN (sup_goods, sup_vendor);
    UPDATE suppliers SET status='approved'       WHERE id IN (sup_goods, sup_vendor);
    UPDATE suppliers SET status='active'         WHERE id IN (sup_goods, sup_vendor);
    -- 前提自证:两家确实都到了 active、且都没有证书 —— 否则 A/B 比的不是标记
    SELECT count(*) INTO n FROM suppliers
     WHERE id IN (sup_goods, sup_vendor) AND status='active';
    IF n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 89 无效:两家都该是 active,实得 % 家', n;
    END IF;
    SELECT count(*) INTO n FROM supplier_compliance
     WHERE supplier_id IN (sup_goods, sup_vendor) AND deleted_at IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 89 无效:两家都该一张证都没有,实得 % 张', n;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════════
    -- A. 【不供货的往来户:即使 active、即使一张证都没有,也不许亮】
    --    这一臂就是那盏永久亮灯,收窄之后应当消失。
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO n FROM operations_now
     WHERE item_type = 'qualification_missing' AND item_id = sup_vendor;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 89A 不供货的往来户不许进 qualification_missing —— 它永远不会去办一张危废证,那盏灯永远不会灭。实得 % 行', n;
    END IF;
    RAISE NOTICE '89A 不供货的往来户(active、无证):qualification_missing 里【缺席】✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- B. 【供货的供应商:同样 active、同样无证,必须照亮】
    --    没有这一臂,"把整支删掉"也能让 A 通过 —— 那是收窄与关掉的区别。
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO n FROM operations_now
     WHERE item_type = 'qualification_missing' AND item_id = sup_goods;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 89B 供货的供应商没有证书就【必须】亮 —— 这一臂与 A 合起来才分得出"收窄"与"整支关掉"。实得 % 行', n;
    END IF;
    RAISE NOTICE '89B 供货的供应商(active、无证):qualification_missing 里【在场】✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- C. 收货【按名拒绝】—— 而且拒的是 RPC 这条路(应用真正走的门)
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM create_inbound_batch(p_material_id => mat, p_supplier_id => sup_vendor,
                                     p_quantity => 1, p_arrival_date => CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 89C 往一个不供货的往来户名下收货必须被拒,却成功了';
    END IF;
    IF position('RECEIPT_AGAINST_NON_GOODS_VENDOR' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 89C 拒绝必须【按名】—— 期望 RECEIPT_AGAINST_NON_GOODS_VENDOR,实得:%', v_msg;
    END IF;
    -- 【点名是哪一家】一句"不允许"让操作员无从下手
    IF position('FX89-VENDOR' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 89C 拒绝里必须带上供应商代码,实得:%', v_msg;
    END IF;
    RAISE NOTICE '89C 收货按名拒:% ✓', v_msg;

    -- ══════════════════════════════════════════════════════════════════════════
    -- D. 【裸 INSERT 也拒】—— 这一臂是"为什么是触发器而不是写进 RPC"的证据
    --    实测:authenticated 裸 INSERT 被 RLS 拒(本表没有 INSERT 策略),
    --    但 service_role / postgres 都 rolbypassrls —— 服务密钥绕得过 RLS。
    --    写进两个 RPC 的实现【会让这一臂变绿】(因为它根本没走 RPC),
    --    所以这一臂正是把"触发器"与"RPC 里各写一遍"分开的那个判据。
    -- ══════════════════════════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit,
                                     remaining_qty, arrival_date)
        VALUES ('FX89-BARE', mat, sup_vendor, 1, 'kg', 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('RECEIPT_AGAINST_NON_GOODS_VENDOR' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 89D 裸 INSERT(绕过 RLS 的那条路)也必须被按名拒 —— 把判据写进两个 RPC 的实现会在这里漏掉。实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    RAISE NOTICE '89D 裸 INSERT 同样按名拒(服务密钥那条路盖住了)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- E. 供货的供应商收得进去 —— 守卫不许误伤
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT (create_inbound_batch(p_material_id => mat, p_supplier_id => sup_goods,
                                 p_quantity => 100, p_arrival_date => CURRENT_DATE - 1)
            ->> 'batch_id')::uuid INTO b;
    IF b IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 89E 供货的供应商必须收得进去';
    END IF;
    RAISE NOTICE '89E 供货的供应商收货正常 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- F. 【历史收货仍然软删得掉】—— 守卫写宽一格就会把这一臂锁死
    --    把一家【已经有收货】的供应商改成不供货(现实里会发生:一家供应商
    --    转成纯服务商),那些历史收货必须还能维护。软删是一次 UPDATE,
    --    而一个在任意 UPDATE 上开火的守卫会让它再也删不掉。
    --    本刀清理 IN-2026-0267 时撞的就是这堵墙,所以它被写成一臂。
    -- ══════════════════════════════════════════════════════════════════════════
    UPDATE suppliers SET supplies_goods = false WHERE id = sup_goods;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM soft_delete_inbound_batch(b, '测试:供应商转为不供货之后,历史收货仍可注销');
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
    END;
    IF v_denied THEN
        RAISE EXCEPTION 'FIXTURE 89F 供应商改成不供货之后,它的【历史】收货必须仍然软删得掉 —— 守卫只该在 INSERT 与【换供应商】的 UPDATE 上开火。实得拒绝:%', v_msg;
    END IF;
    SELECT count(*) INTO n FROM inbound_batches
     WHERE id = b AND deleted_at IS NOT NULL AND deleted_by IS NOT NULL
       AND delete_reason IS NOT NULL;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 89F 软删应当记下人与理由,实得 % 行', n;
    END IF;
    UPDATE suppliers SET supplies_goods = true WHERE id = sup_goods;
    RAISE NOTICE '89F 供应商转为不供货后,历史收货仍软删得掉(且记下了人与理由)✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- G/H. supplier_receipt_pattern:不供货的【缺席】,供货的【在场】
    --      同样是一对 —— 少了 H,把整张视图清空也能让 G 通过。
    -- ══════════════════════════════════════════════════════════════════════════
    SELECT count(*) INTO n FROM supplier_receipt_pattern WHERE supplier_id = sup_vendor;
    IF n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 89G 不供货的往来户不该出现在收货模式里 —— 它一次货都不会收,那块面板会对它永远说"没有可比对的收货",而那是在回答一个对它不成立的问题。实得 % 行', n;
    END IF;
    SELECT count(*) INTO n FROM supplier_receipt_pattern WHERE supplier_id = sup_goods;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 89H 供货的供应商必须【仍然】出现在收货模式里(哪怕它一次货都没收过,GRN-2 的 G/J 臂钉的就是这个)。实得 % 行', n;
    END IF;
    RAISE NOTICE '89G/H 收货模式:不供货缺席、供货在场 ✓';

    -- ══════════════════════════════════════════════════════════════════════════
    -- I. 【默认是供货】—— 不写这一列建出来的供应商必须是 true
    --    默认 false 会把每一家新供应商一建出来就挡在收货门外。
    -- ══════════════════════════════════════════════════════════════════════════
    INSERT INTO suppliers (code, legal_name, country)
    VALUES ('FX89-DEFAULT', 'fixture 89 default supplier', 'SG');
    SELECT count(*) INTO n FROM suppliers
     WHERE code = 'FX89-DEFAULT' AND supplies_goods;
    IF n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 89I 不指定时必须默认【供货】—— 默认 false 会把每一家新供应商挡在收货门外';
    END IF;
    RAISE NOTICE '89I 新供应商默认供货 ✓';

    RAISE NOTICE 'FIXTURE 89 全部通过';
END $$;
ROLLBACK;

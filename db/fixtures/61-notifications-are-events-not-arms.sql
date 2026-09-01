-- 61 通知是【事件】(NTF-1):留得下来、只能被读过,而且伪造不出来
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的三件事,各自防一种退化】
--   ① 事件真的【留下来了】—— IOD-2 的告警此前渲染一次就没了,连响过的痕迹都
--      没有。C 臂断言【沉默也是断言】:配了且允许的那一次不许写通知,否则这个
--      收件箱会被每一次正常收货填满,而一个全是噪声的收件箱等于没有收件箱。
--   ② 事后违规的判据与 IOD-2 【逐字同形】:三态里只有"配了、且不含这一类"算
--      违规;未分类与未配置都不算(F 臂钉住"清空 ≠ 违规")。
--   ③ 通知【伪造不出来】。它可信的全部依据是"只有属主身份的函数写得进" ——
--      J 臂用 authenticated 身份直插,必须被 RLS 拒。
--
-- 各臂:
--   A 前提:两张表在、干净;两个读者的权限各自成立
--   B 落地告警 → 事件落库,payload 够渲染(码、库位、物料)
--   C 配了且允许 → 【一条都不写】(沉默是断言,不是假设)
--   D 分类改变把存量变成违规 → 事件带对了数量与库位
--   E 库位许可改变 → 同上,主体是库位
--   F 清空到零行 → 【不发】(那是未配置 = 告警态,不是违规)
--   G 原样再存一次 → 去重(第一条未读时,第二条不出现)
--   H 已读是【每个读者自己的】:A 标了已读,未读数落下去
--   I RLS:没有那个模块的读者【看不见】(缺席,不是零);未知 subject_type 一律不可见
--   J 注入:只增不改的守卫按名拒;客户端直插被拒;去重拿掉 → 重复出现(证明 G 有牙)
--
-- 日期无关。自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_all   uuid := gen_random_uuid();   -- 全权限读者
    u_inv   uuid := gen_random_uuid();   -- 只有 module.inventory.view
    r_all uuid; r_inv uuid;
    v_sup uuid; m_foc uuid; m_null uuid; loc_un uuid; loc_foc uuid;
    v_n int; v_p jsonb; v_id uuid; v_ok boolean; v_msg text; d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-61-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-61-inv', 'f', 'f', true) RETURNING id INTO r_inv;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_inv, 'module.inventory.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_inv, r_inv);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_all), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S61', 'Fixture Supplier 61', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit, waste_classification_code)
    VALUES ('ZZFIX61-F', 'fixture 61 focused', 'battery_material', true, 'black_mass', 'end_of_life', 'kg', 'focused') RETURNING id INTO m_foc;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX61-U', 'fixture 61 unclassified', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO m_null;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ61-UN', 'unconfigured') RETURNING id INTO loc_un;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ61-FOC', 'focused only') RETURNING id INTO loc_foc;
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_foc, 'focused');

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM notifications;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 61A 失败:前提不成立 —— 建库位许可那一步不该发出任何通知(loc_foc 上没有存量),实得 % 条', v_n;
    END IF;

    -- ══════════ B. 落地告警 → 事件落库 ═══════════════════════════════════════
    PERFORM create_inbound_batch(m_foc, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_un, p_source_reason_code => 'other', p_source_reason_note => 'fixture 61 自带数据');
    SELECT count(*) INTO v_n FROM notifications
     WHERE event_type = 'iod_class_unconfigured_location' AND subject_id = loc_un;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 61B 失败:收进未配置库位应当留下 1 条事件,实得 %', v_n;
    END IF;
    SELECT payload INTO v_p FROM notifications
     WHERE event_type = 'iod_class_unconfigured_location' AND subject_id = loc_un;
    -- 【payload 要够渲染】—— 列表不该为了写一句话去 join 五张表
    IF v_p ->> 'location_code' IS DISTINCT FROM 'ZZ61-UN'
       OR v_p ->> 'material_code' IS DISTINCT FROM 'ZZFIX61-F' THEN
        RAISE EXCEPTION 'FIXTURE 61B 失败:payload 应当自带库位码与物料码,实得 %', v_p::text;
    END IF;
    IF (SELECT subject_type FROM notifications WHERE subject_id = loc_un) <> 'storage_location' THEN
        RAISE EXCEPTION 'FIXTURE 61B 失败:未配置库位的主体应当是库位(补救在那张页面上)';
    END IF;

    -- 未分类物料落进已配置库位 → 主体是【物料】
    PERFORM create_inbound_batch(m_null, v_sup, 7, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_foc, p_source_reason_code => 'other', p_source_reason_note => 'fixture 61 自带数据');
    SELECT count(*) INTO v_n FROM notifications
     WHERE event_type = 'iod_material_unclassified' AND subject_id = m_null AND subject_type = 'material';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 61B 失败:未分类物料应当留下 1 条以物料为主体的事件,实得 %', v_n;
    END IF;

    -- ══════════ C. 配了且允许 → 一条都不写(沉默是断言)══════════════════════
    SELECT count(*) INTO v_n FROM notifications;
    PERFORM create_inbound_batch(m_foc, v_sup, 5, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_foc, p_source_reason_code => 'other', p_source_reason_note => 'fixture 61 自带数据');
    IF (SELECT count(*) FROM notifications) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 61C 失败:配了且允许的那一次收货【不该】写任何通知 —— 否则收件箱会被每一次正常收货填满';
    END IF;

    -- ══════════ D. 分类改变把存量变成违规 ════════════════════════════════════
    -- m_null 有 7kg 躺在 loc_foc(只允许 focused)。把它分类成 non_focused:
    -- 那 7kg 从这一刻起违规,而【它不会再落地一次】给 IOD-2 的闸机会。
    UPDATE materials SET waste_classification_code = 'non_focused' WHERE id = m_null;
    SELECT count(*) INTO v_n FROM notifications
     WHERE event_type = 'class_violation_after_reclassify' AND subject_id = m_null;
    SELECT payload INTO v_p FROM notifications
     WHERE event_type = 'class_violation_after_reclassify' AND subject_id = m_null LIMIT 1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 61D 失败:分类改变应当留下 1 条违规事件,实得 %', v_n;
    END IF;
    IF (v_p ->> 'qty')::numeric <> 7 OR v_p ->> 'location_code' IS DISTINCT FROM 'ZZ61-FOC'
       OR v_p ->> 'class' IS DISTINCT FROM 'non_focused' THEN
        RAISE EXCEPTION 'FIXTURE 61D 失败:payload 要说清【多少货、在哪、哪一类】,实得 %', v_p::text;
    END IF;

    -- ══════════ E. 库位许可改变 → 主体是库位 ═════════════════════════════════
    -- loc_un 上有 10kg 的 focused 货。给它配上"只允许 non_focused":那 10kg 违规。
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_un, 'non_focused');
    SELECT count(*) INTO v_n FROM notifications
     WHERE event_type = 'class_violation_after_config' AND subject_id = loc_un;
    SELECT payload INTO v_p FROM notifications
     WHERE event_type = 'class_violation_after_config' AND subject_id = loc_un LIMIT 1;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 61E 失败:库位许可改变应当留下 1 条违规事件,实得 %', v_n;
    END IF;
    IF (v_p ->> 'qty')::numeric <> 10 OR v_p ->> 'material_code' IS DISTINCT FROM 'ZZFIX61-F' THEN
        RAISE EXCEPTION 'FIXTURE 61E 失败:payload 的数量/物料不对,实得 %', v_p::text;
    END IF;

    -- ══════════ F. 清空到零行 → 不发 ════════════════════════════════════════
    -- 【清空 = 未配置 = 没人做过决定】,那是告警态,不是违规。给它发违规,
    -- 就是把"没人想过"说成"想过、结论是不行"。
    SELECT count(*) INTO v_n FROM notifications;
    DELETE FROM storage_location_allowed_classes WHERE location_id = loc_foc;
    IF (SELECT count(*) FROM notifications) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 61F 失败:把一个库位清空到零行【不是违规】—— 不该发事件';
    END IF;

    -- ══════════ G. 原样再存一次 → 去重 ══════════════════════════════════════
    -- 界面那一侧是"整体删掉再插回去",于是每一次保存都长得像一次改变。
    DELETE FROM storage_location_allowed_classes WHERE location_id = loc_un;
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_un, 'non_focused');
    SELECT count(*) INTO v_n FROM notifications
     WHERE event_type = 'class_violation_after_config' AND subject_id = loc_un;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 61G 失败:同一个违规在【第一条还没被读过】时不该再写一条,实得 % 条', v_n;
    END IF;

    -- ══════════ H. 已读是每个读者自己的 ══════════════════════════════════════
    SELECT id INTO v_id FROM notifications
     WHERE event_type = 'class_violation_after_config' AND subject_id = loc_un;
    INSERT INTO notification_reads (notification_id, user_id) VALUES (v_id, u_all);
    SELECT count(*) INTO v_n FROM notifications n
     WHERE NOT EXISTS (SELECT 1 FROM notification_reads nr
                        WHERE nr.notification_id = n.id AND nr.user_id = u_all);
    IF EXISTS (SELECT 1 FROM notification_reads nr WHERE nr.notification_id = v_id AND nr.user_id = u_inv) THEN
        RAISE EXCEPTION 'FIXTURE 61H 失败:一个人读过不该让另一个人也变成已读';
    END IF;

    -- ══════════ I. RLS:缺席,不是零 ═════════════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_inv), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- 只有 module.inventory.view:库位主体看得见,物料主体【看不见】
    SELECT count(*) INTO v_n FROM notifications WHERE subject_type = 'material';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 61I 失败:没有 module.materials.view 的读者不该看见物料主体的事件,实得 % 条 —— 缺席不是零,但这里连缺席都没做到', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM notifications WHERE subject_type = 'storage_location';
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 61I 失败:持有 module.inventory.view 的读者应当看得见库位主体的事件';
    END IF;
    RESET ROLE;

    -- 未知 subject_type:policy 的 ELSE false。CHECK 拦着它,所以先把 CHECK 摘掉
    -- (整支 fixture 回滚)—— 断言的是【策略】那一半,不是约束那一半。
    ALTER TABLE notifications DROP CONSTRAINT notifications_subject_type_known;
    INSERT INTO notifications (event_type, subject_type, subject_id, subject_code)
    VALUES ('iod_material_unclassified', 'zz_unknown_subject', gen_random_uuid(), 'ZZ');
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM notifications WHERE subject_type = 'zz_unknown_subject';
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 61I 失败:未知 subject_type 必须【不可见】(policy 的 ELSE false)—— 全权限读者也看见了 % 条。默认公开正是这条策略要防的', v_n;
    END IF;

    -- ══════════ J. 注入 ═════════════════════════════════════════════════════
    -- J1 只增不改:UPDATE / DELETE 各按名拒一次
    FOR v_n IN 1..2 LOOP
        v_ok := false; v_msg := NULL;
        BEGIN
            IF v_n = 1 THEN
                UPDATE notifications SET subject_code = 'tampered' WHERE id = v_id;
            ELSE
                DELETE FROM notifications WHERE id = v_id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
            v_ok := v_msg = 'NOTIFICATION_IMMUTABLE';
        END;
        IF NOT v_ok THEN
            RAISE EXCEPTION 'FIXTURE 61J1 失败:第 % 种改动应当按名拒 NOTIFICATION_IMMUTABLE,实得:%',
                v_n, COALESCE(v_msg, '(改成功了)');
        END IF;
    END LOOP;

    -- J2 伪造:以 authenticated 身份直插 —— 通知可信的全部依据就是这一条
    v_ok := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO notifications (event_type, subject_type, subject_id, subject_code)
        VALUES ('iod_material_unclassified', 'material', gen_random_uuid(), 'FORGED');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_ok := true; END;
    RESET ROLE;
    IF NOT v_ok THEN
        RAISE EXCEPTION 'FIXTURE 61J2 失败:客户端直插 notifications 必须被 RLS 拒 —— 能伪造的通知不值得被相信';
    END IF;

    -- J3 把去重拿掉 → 重复必须出现(证明 G 臂不是空转)
    EXECUTE $inj$
        CREATE OR REPLACE FUNCTION public.notify_class_violations(p_cause text, p_material_ids uuid[], p_location_ids uuid[])
         RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
        AS $body$
        DECLARE r record; v_fp text; v_actor uuid := auth.uid();
        BEGIN
            FOR r IN
                WITH avail AS (
                    SELECT mv.location_id, COALESCE(ib.material_id, ob.material_id) AS material_id,
                           sum(mv.qty_delta) AS qty
                      FROM inventory_movements mv
                           LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
                           LEFT JOIN output_batches  ob ON ob.id = mv.output_batch_id
                     WHERE mv.stock_status = 'available' AND mv.location_id IS NOT NULL
                     GROUP BY 1,2 HAVING sum(mv.qty_delta) > 0)
                SELECT a.location_id, a.material_id, a.qty, m.code AS material_code,
                       m.waste_classification_code AS class_code, sl.code AS location_code
                  FROM avail a JOIN materials m ON m.id = a.material_id
                       JOIN storage_locations sl ON sl.id = a.location_id
                 WHERE (p_location_ids IS NULL OR a.location_id = ANY (p_location_ids))
                   AND m.deleted_at IS NULL AND m.waste_classification_code IS NOT NULL
                   AND EXISTS (SELECT 1 FROM storage_location_allowed_classes c WHERE c.location_id = a.location_id)
                   AND NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                                    WHERE c.location_id = a.location_id
                                      AND c.classification_code = m.waste_classification_code)
            LOOP
                v_fp := r.material_id::text || '|' || r.location_id::text || '|' || r.class_code;
                INSERT INTO notifications (event_type, subject_type, subject_id, subject_code, payload, actor_user_id)
                VALUES ('class_violation_after_config', 'storage_location', r.location_id, r.location_code,
                        jsonb_build_object('fingerprint', v_fp, 'class', r.class_code, 'qty', trim_scale(r.qty),
                                           'material_id', r.material_id, 'material_code', r.material_code,
                                           'location_id', r.location_id, 'location_code', r.location_code),
                        v_actor);
            END LOOP;
        END $body$;
    $inj$;

    DELETE FROM storage_location_allowed_classes WHERE location_id = loc_un;
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_un, 'non_focused');
    SELECT count(*) INTO v_n FROM notifications
     WHERE event_type = 'class_violation_after_config' AND subject_id = loc_un;
    IF v_n < 2 THEN
        RAISE EXCEPTION 'FIXTURE 61J3 失败:把去重拿掉之后【重复没有出现】(仍是 % 条)—— 说明 G 臂并不依赖去重那一段,它一直在空转', v_n;
    END IF;
END $$;
ROLLBACK;

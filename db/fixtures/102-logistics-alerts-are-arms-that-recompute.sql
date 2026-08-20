-- 102 物流的四支告警:算出来的【臂】,而不是存下来的事件
--
-- 【这份 fixture 的头号断言是"自愈"】臂的全部好处就在这一条:它每次被读都重算,
-- 所以一条更正【不需要任何人去把告警关掉】—— 下一次读它自己就不在了。
-- 里程碑是只增不改的,更正的写法是【再记一条】;算数的是【最后被录入】的那一条。
--
-- 【LOG-5d:此前这里只测了一个方向,而那个盲区上了线】
-- B 臂测"把日期改【晚】",B2 臂测"把日期改【早】"。旧实现按 event_date DESC 排,
-- 改晚的碰巧排到前面、碰巧生效 —— 于是 B 臂一直绿着,而改早的更正
-- 【一次都没有生效过】(线上 CTR-2026-0009 就是这么躺着的)。
-- **一个只覆盖一个方向的断言,读起来与一个覆盖两个方向的断言一模一样。**
-- 注入把锚点退回 event_date DESC 时【只有 B2 红、B 仍然绿】——
-- 那正是这两臂必须分开存在的证明。
--
-- 【第二头号断言:NULL ≠ 0,两个方向都钉】
-- free_days 为 NULL = "这份报价没写免柜期" → 沉默;
-- free_days = 0     = "零个免费天"         → 一到港就响。
-- 只钉一半的 fixture 挡不住那个最贵的实现:把 NULL 当成 0
-- (每个到港的箱子从第一天起报警 = 喊狼来了 = 等于没有告警)。
--
-- 【为什么这里不切数据库角色】operations_now 是属主权限视图,它的把关全在
-- has_permission 上 —— 那是 SECURITY DEFINER、按 request.jwt.claims 里的 sub 解析,
-- 与数据库角色无关(README 第 6 条把这条区别写得很清楚:靠 has_permission 的臂
-- 不切角色也是真的,靠 RLS 的臂不切就是假的)。本文件的可见性断言全部属于前者。
--
-- 日期【全部相对 CURRENT_DATE】—— 被测的判据本身就是"今天减去某一天",
-- 写死日期会在明天变成另一个用例(README 第 4 条的同一条理由)。
BEGIN;
DO $$
DECLARE
    v_log   uuid := gen_random_uuid();   -- 只有 module.purchasing.*(暂借的物流码)
    v_fin   uuid := gen_random_uuid();   -- 只有 module.finance.view
    r_log uuid; r_fin uuid;
    v_fwd uuid;
    v_p1 uuid; v_p2 uuid;
    ln_a uuid; ln_b uuid; ln_c uuid; ln_d uuid; ln_e uuid;
    c_r2 uuid; c_r3 uuid; c_neg uuid; c_null uuid; c_zero uuid;
    c_heal uuid; c_noarr uuid; c_eta uuid; c_etanull uuid;
    c_docs uuid; c_nodocs uuid; c_del1 uuid; c_del2 uuid;
    c_early uuid; c_depearly uuid;
    v_res jsonb; v_n int; v_subject text; v_denied boolean; v_msg text;
    v_doc uuid;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-102-log', 'f', 'f', true) RETURNING id INTO r_log;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_log, 'module.purchasing.view'), (r_log, 'module.purchasing.edit');
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-102-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code)
    VALUES (r_fin, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_log, r_log), (v_fin, r_fin);

    -- 建数据以物流身份做(create_container 要 module.purchasing.edit)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_log), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX102-FWD', 'fixture 102 forwarder', 'SG', 'active', 'forwarder')
    RETURNING id INTO v_fwd;
    INSERT INTO ports (code, name, country) VALUES ('ZZF102A', 'origin', 'SG') RETURNING id INTO v_p1;
    -- 【每个用例自己一条航段,而航段的 (起,讫) 是唯一的】(lanes_unique_pair),
    -- 所以要五个不同的目的港,不能拿同一对港口建五条。
    -- 为什么每个用例要自己一条:guard_forwarder_rate_quote 不许同一家货代在同一
    -- 航段上有有效期重叠的两份报价,而这些用例的 departure_date 都在同一个窗口里。
    INSERT INTO ports (code, name, country) VALUES ('ZZF102B1', 'destination 1', 'CN') RETURNING id INTO v_p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_p1, v_p2) RETURNING id INTO ln_a;
    INSERT INTO ports (code, name, country) VALUES ('ZZF102B2', 'destination 2', 'CN') RETURNING id INTO v_p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_p1, v_p2) RETURNING id INTO ln_b;
    INSERT INTO ports (code, name, country) VALUES ('ZZF102B3', 'destination 3', 'CN') RETURNING id INTO v_p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_p1, v_p2) RETURNING id INTO ln_c;
    INSERT INTO ports (code, name, country) VALUES ('ZZF102B4', 'destination 4', 'CN') RETURNING id INTO v_p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_p1, v_p2) RETURNING id INTO ln_d;
    INSERT INTO ports (code, name, country) VALUES ('ZZF102B5', 'destination 5', 'CN') RETURNING id INTO v_p2;
    INSERT INTO lanes (origin_port_id, destination_port_id) VALUES (v_p1, v_p2) RETURNING id INTO ln_e;

    -- ══════════ A. 免柜期:2 响 / 3 不响 / 负数响且带着负号 ═══════════════════
    -- remaining = free_days − (today − arrival)
    -- free_days = 10, arrival = today−8  → remaining = 2  → 响
    v_res := create_container(ln_a, CURRENT_DATE - 30, 'ZZ102R2', NULL, NULL, v_fwd, NULL, NULL);
    c_r2 := (v_res->>'id')::uuid;
    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency,
        valid_from, valid_to, free_days, notes)
    VALUES (v_fwd, ln_a, 1000, (SELECT code FROM currencies WHERE is_base),
        CURRENT_DATE - 60, CURRENT_DATE + 60, 10, 'fixture 102 A');
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_r2, 'arrived', CURRENT_DATE - 8);

    -- free_days = 10, arrival = today−7  → remaining = 3  → 不响(同一航段不行,另起一条)
    v_res := create_container(ln_b, CURRENT_DATE - 30, 'ZZ102R3', NULL, NULL, v_fwd, NULL, NULL);
    c_r3 := (v_res->>'id')::uuid;
    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency,
        valid_from, valid_to, free_days, notes)
    VALUES (v_fwd, ln_b, 1000, (SELECT code FROM currencies WHERE is_base),
        CURRENT_DATE - 60, CURRENT_DATE + 60, 10, 'fixture 102 A3');
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_r3, 'arrived', CURRENT_DATE - 7);

    -- free_days = 5, arrival = today−9 → remaining = −4 → 响,且 subject 带着 −4
    v_res := create_container(ln_c, CURRENT_DATE - 30, 'ZZ102NEG', NULL, NULL, v_fwd, NULL, NULL);
    c_neg := (v_res->>'id')::uuid;
    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency,
        valid_from, valid_to, free_days, notes)
    VALUES (v_fwd, ln_c, 1000, (SELECT code FROM currencies WHERE is_base),
        CURRENT_DATE - 60, CURRENT_DATE + 60, 5, 'fixture 102 neg');
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_neg, 'arrived', CURRENT_DATE - 9);

    -- free_days = NULL(报价没写免柜期)→ 沉默,哪怕到港已久
    v_res := create_container(ln_d, CURRENT_DATE - 30, 'ZZ102NULL', NULL, NULL, v_fwd, NULL, NULL);
    c_null := (v_res->>'id')::uuid;
    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency,
        valid_from, valid_to, free_days, notes)
    VALUES (v_fwd, ln_d, 1000, (SELECT code FROM currencies WHERE is_base),
        CURRENT_DATE - 60, CURRENT_DATE + 60, NULL, 'fixture 102 null');
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_null, 'arrived', CURRENT_DATE - 100);

    -- free_days = 0(零个免费天)→ 到港第二天就响
    v_res := create_container(ln_e, CURRENT_DATE - 30, 'ZZ102ZERO', NULL, NULL, v_fwd, NULL, NULL);
    c_zero := (v_res->>'id')::uuid;
    INSERT INTO forwarder_rate_quotes (supplier_id, lane_id, amount_ccy, currency,
        valid_from, valid_to, free_days, notes)
    VALUES (v_fwd, ln_e, 1000, (SELECT code FROM currencies WHERE is_base),
        CURRENT_DATE - 60, CURRENT_DATE + 60, 0, 'fixture 102 zero');
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_zero, 'arrived', CURRENT_DATE - 1);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_log), true);

    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_r2;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102A 失败:剩余 2 天时免柜期告警应当响,实得 % 行', v_n;
    END IF;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_r3;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102A 失败:剩余 3 天时【不该】响,实得 % 行 —— 阈值是 <= 2,写成 <= 3 这一条会红', v_n;
    END IF;

    SELECT count(*), max(subject) INTO v_n, v_subject FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_neg;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102A 失败:已超期(负数)时应当响,实得 % 行 —— 一个写成 BETWEEN 0 AND 2 的实现会在这里哑掉,而那正是最该说话的时刻', v_n;
    END IF;
    IF v_subject NOT LIKE '-4 left of 5%' THEN
        RAISE EXCEPTION 'FIXTURE 102A 失败:subject 要把【负的剩余天数】带出来(期望以 "-4 left of 5" 开头),实得 %', v_subject;
    END IF;

    -- 【NULL ≠ 0,方向一】NULL 沉默
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_null;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102A 失败:报价没写免柜期(free_days IS NULL)时应当【沉默】,实得 % 行 —— 把 NULL 当成 0,每一个到港的箱子都会从第一天起报警,而喊狼来了的告警等于没有告警', v_n;
    END IF;
    -- 【NULL ≠ 0,方向二】0 到港第二天就响
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_zero;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102A 失败:free_days = 0(零个免费天)时,到港第二天就该响,实得 % 行 —— 把 0 当成 NULL,一个真的从第一天起就在烧钱的箱子会一声不吭', v_n;
    END IF;

    -- ══════════ B. 自愈:更正是【再记一条】,而臂下一次读就变了 ═══════════════
    -- 【本文件的头号断言】。同一个箱子先响,追加一条【更晚】的 arrived 之后不响。
    v_res := create_container(ln_a, CURRENT_DATE - 31, 'ZZ102HEAL', NULL, NULL, v_fwd, NULL, NULL);
    c_heal := (v_res->>'id')::uuid;   -- 复用 ln_a 的那份报价(free_days = 10)
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_heal, 'arrived', CURRENT_DATE - 8);          -- remaining = 2 → 响
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_heal;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102B 失败:更正之前应当响(remaining = 2),实得 % 行', v_n;
    END IF;

    -- 更正:其实是晚三天才到 —— 只增不改,所以【再记一条】
    INSERT INTO container_milestones (container_id, milestone, event_date, note)
    VALUES (c_heal, 'arrived', CURRENT_DATE - 5, 'fixture 102:更正,实际晚三天到');

    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_heal;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102B 失败(自愈):追加一条【更晚】的 arrived 之后,这一支下一次被读到就该不在了(remaining 变成 5),实得 % 行 —— 锚点取的若是【最早】那一条,更正就永远不生效,而没有人会去把一个算出来的告警手动关掉',
            v_n;
    END IF;
    -- 而且两条 arrived 确实都还在(只增不改,更正不抹掉原记录)
    SELECT count(*) INTO v_n FROM container_milestones
     WHERE container_id = c_heal AND milestone = 'arrived';
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 102B 失败:两条 arrived 都该留着(只增不改),实得 % 条', v_n;
    END IF;

    -- ══════════ B2. 【缺的那个方向】更正把日期改【早】,也必须生效 ═════════
    -- 【LOG-5d:这一臂是本文件此前的盲区】上面 B 臂测的是"改晚" ——
    -- 而在 event_date DESC 的旧排序下,改晚的更正碰巧排到前面、碰巧生效,
    -- 所以 B 臂一直是绿的,而【改早的更正一次都没生效过】。
    -- 一个只覆盖一个方向的断言,读起来与一个覆盖两个方向的断言一模一样。
    --
    -- 【Tim 在线上撞到的形状,原样搬过来】CTR-2026-0009:
    --     arrived event=08-16 recorded=18:22:38
    --     arrived event=08-14 recorded=18:25:13   ← 录得更晚、日期更早
    -- 这里用相对日期复现同一件事,并且让它【跨过阈值】——
    -- 只断言"锚点变了"不够,要断言这一支的【答案】跟着变。
    v_res := create_container(ln_a, CURRENT_DATE - 32, 'ZZ102EARLY', NULL, NULL, v_fwd, NULL, NULL);
    c_early := (v_res->>'id')::uuid;      -- ln_a 那份报价:free_days = 10
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_early, 'arrived', CURRENT_DATE - 3);        -- remaining = 10 − 3 = 7 → 不响
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_early;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102B2 前提失败:更正之前应当【不响】(remaining = 7),实得 % 行', v_n;
    END IF;

    -- 更正:其实是九天前就到了 —— 只增不改,所以再记一条(日期【更早】)
    INSERT INTO container_milestones (container_id, milestone, event_date, note)
    VALUES (c_early, 'arrived', CURRENT_DATE - 9, 'fixture 102:更正,实际早六天到');

    SELECT count(*), max(subject) INTO v_n, v_subject FROM operations_now
     WHERE item_type = 'free_time_expiring' AND item_id = c_early;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102B2 失败(改【早】的更正):追加一条日期更早的 arrived 之后,锚点应当移到它身上(remaining 变成 1),这一支应当【开始响】,实得 % 行 —— 锚点若按 event_date 排,更早的那条永远排不到前面,这条更正一次都不会生效,而【没有任何东西会报错】',
            v_n;
    END IF;
    IF v_subject NOT LIKE '1 left of 10%' THEN
        RAISE EXCEPTION 'FIXTURE 102B2 失败:锚点应当是被更正后的那一天(剩余 1),实得 subject = %', v_subject;
    END IF;

    -- 【同一条规则对 departed 也成立】—— 无到港那一支的钟
    v_res := create_container(ln_b, CURRENT_DATE - 42, 'ZZ102DEPEARLY', NULL, NULL, v_fwd, NULL, NULL);
    c_depearly := (v_res->>'id')::uuid;
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_depearly, 'departed', CURRENT_DATE - 10);   -- 10 < 14 → 不响
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_no_arrival' AND item_id = c_depearly;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102B2 前提失败:开走 10 天时无到港那一支不该响,实得 % 行', v_n;
    END IF;
    INSERT INTO container_milestones (container_id, milestone, event_date, note)
    VALUES (c_depearly, 'departed', CURRENT_DATE - 20, 'fixture 102:更正,其实早十天就开了');
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_no_arrival' AND item_id = c_depearly;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102B2 失败(departed 侧):把开航日改早到 20 天前之后,无到港那一支应当开始响,实得 % 行', v_n;
    END IF;

    -- ══════════ C. 走了 14 天没人说到了 ═════════════════════════════════════
    v_res := create_container(ln_a, CURRENT_DATE - 40, 'ZZ102NOARR', NULL, NULL, v_fwd, NULL, NULL);
    c_noarr := (v_res->>'id')::uuid;
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_noarr, 'departed', CURRENT_DATE - 14);
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_no_arrival' AND item_id = c_noarr;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102C 失败:开走满 14 天且无人录到港,应当响,实得 % 行', v_n;
    END IF;
    -- 录一条到港 → 这一支消失(同样是自愈,不需要谁去关掉它)
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_noarr, 'arrived', CURRENT_DATE - 2);
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_no_arrival' AND item_id = c_noarr;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102C 失败:录了到港之后这一支应当消失,实得 % 行', v_n;
    END IF;

    -- ══════════ D. ETA 过了而箱子没到 ═══════════════════════════════════════
    v_res := create_container(ln_a, CURRENT_DATE - 20, 'ZZ102ETA', NULL, NULL, v_fwd, NULL, NULL);
    c_eta := (v_res->>'id')::uuid;
    UPDATE containers SET expected_arrival_date = CURRENT_DATE - 1 WHERE id = c_eta;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_eta_overdue' AND item_id = c_eta;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102D 失败:ETA 已过且未到港,应当响,实得 % 行', v_n;
    END IF;
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_eta, 'arrived', CURRENT_DATE);
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_eta_overdue' AND item_id = c_eta;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102D 失败:到港之后 ETA 那一支应当消失,实得 % 行', v_n;
    END IF;
    -- ETA 为 NULL:沉默(【已知的局限】,与 work_order_overdue 同形)
    v_res := create_container(ln_a, CURRENT_DATE - 20, 'ZZ102ETANULL', NULL, NULL, v_fwd, NULL, NULL);
    c_etanull := (v_res->>'id')::uuid;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_eta_overdue' AND item_id = c_etanull;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102D 失败:没有填 ETA 的箱子,这一支应当沉默,实得 % 行', v_n;
    END IF;

    -- ══════════ E. 开走 7 天,单据还欠着 ════════════════════════════════════
    v_res := create_container(ln_a, CURRENT_DATE - 7, 'ZZ102DOCS', NULL, NULL, v_fwd, NULL, NULL);
    c_docs := (v_res->>'id')::uuid;
    INSERT INTO container_documents (container_id, document_type, status)
    VALUES (c_docs, 'bill_of_lading', 'pending') RETURNING id INTO v_doc;
    INSERT INTO container_documents (container_id, document_type, status)
    VALUES (c_docs, 'packing_list', 'pending');
    SELECT count(*), max(subject) INTO v_n, v_subject FROM operations_now
     WHERE item_type = 'container_documents_late' AND item_id = c_docs;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 102E 失败:开走满 7 天且有 pending 单据,应当响,实得 % 行', v_n;
    END IF;
    IF v_subject <> '2 pending' THEN
        RAISE EXCEPTION 'FIXTURE 102E 失败:subject 要带着 pending 的条数(期望 "2 pending"),实得 %', v_subject;
    END IF;
    -- 收齐:一份改 received、另一份改 not_applicable(带理由)→ 这一支消失
    UPDATE container_documents SET status = 'received' WHERE id = v_doc;
    UPDATE container_documents SET status = 'not_applicable', na_reason = 'fixture 102:这条航段不要'
     WHERE container_id = c_docs AND status = 'pending';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_documents_late' AND item_id = c_docs;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102E 失败:最后一份 pending 被收掉之后这一支应当消失,实得 % 行', v_n;
    END IF;
    -- 【从没实例化过清单的箱子:沉默】—— 那种"空"与"都收齐了"在库里长得一样,
    -- 把它们在屏幕上分开是 5b 的事;这里断言的是它【不响】。
    v_res := create_container(ln_a, CURRENT_DATE - 7, 'ZZ102NODOCS', NULL, NULL, v_fwd, NULL, NULL);
    c_nodocs := (v_res->>'id')::uuid;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'container_documents_late' AND item_id = c_nodocs;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102E 失败:从没实例化过清单的箱子这一支应当沉默,实得 % 行', v_n;
    END IF;

    -- ══════════ F. 已软删的箱子,四支里一支都不出现 ═════════════════════════
    -- 【两个箱子,因为四支不可能同时成立】:免柜期与单据迟到要"到过港/有单据",
    -- 而无到港与 ETA 逾期要"没到过港"。所以一个覆盖前两支,一个覆盖后两支。
    v_res := create_container(ln_a, CURRENT_DATE - 30, 'ZZ102DEL1', NULL, NULL, v_fwd, NULL, NULL);
    c_del1 := (v_res->>'id')::uuid;
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_del1, 'arrived', CURRENT_DATE - 9);              -- remaining = 1 → 会响
    INSERT INTO container_documents (container_id, document_type, status)
    VALUES (c_del1, 'bill_of_lading', 'pending');              -- 开走 30 天 → 会响
    v_res := create_container(ln_a, CURRENT_DATE - 40, 'ZZ102DEL2', NULL, NULL, v_fwd, NULL, NULL);
    c_del2 := (v_res->>'id')::uuid;
    UPDATE containers SET expected_arrival_date = CURRENT_DATE - 3 WHERE id = c_del2;
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES (c_del2, 'departed', CURRENT_DATE - 20);            -- 两支都会响

    -- 先证明【删之前确实响】,否则删之后的 0 行证明不了任何事
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_id IN (c_del1, c_del2)
       AND item_type IN ('free_time_expiring','container_no_arrival',
                         'container_eta_overdue','container_documents_late');
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 102F 前提失败:软删之前这两个箱子应当在四支里各响一次(共 4 行),实得 % 行 —— 前提不成立的话,下面那个 0 是空转', v_n;
    END IF;

    PERFORM soft_delete_container(c_del1, 'fixture 102:验证软删');
    PERFORM soft_delete_container(c_del2, 'fixture 102:验证软删');

    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_id IN (c_del1, c_del2)
       AND item_type IN ('free_time_expiring','container_no_arrival',
                         'container_eta_overdue','container_documents_late');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102F 失败:已软删的箱子在四支里一支都不该出现,实得 % 行 —— 漏写一句 deleted_at IS NULL,注销掉的箱子会继续在看板上叫', v_n;
    END IF;

    -- ══════════ G. 谁看得见哪一支 ═══════════════════════════════════════════
    -- 【先造三个【此刻正在响】的箱子】—— 上面每一支都被【故意清掉】过
    -- (录到港、收单据),那是自愈那几条断言要的;但可见性断言需要四支同时有行,
    -- 否则"财务看不见另外三支"会因为【根本没有那三支】而空转通过。
    -- 第一版就是这么写的,当场红在"实得 1 支"上 —— 红的是断言不是视图。
    v_res := create_container(ln_b, CURRENT_DATE - 40, 'ZZ102G1', NULL, NULL, v_fwd, NULL, NULL);
    INSERT INTO container_milestones (container_id, milestone, event_date)
    VALUES ((v_res->>'id')::uuid, 'departed', CURRENT_DATE - 20);        -- → no_arrival
    v_res := create_container(ln_b, CURRENT_DATE - 20, 'ZZ102G2', NULL, NULL, v_fwd, NULL, NULL);
    UPDATE containers SET expected_arrival_date = CURRENT_DATE - 2
     WHERE id = (v_res->>'id')::uuid;                                    -- → eta_overdue
    v_res := create_container(ln_b, CURRENT_DATE - 10, 'ZZ102G3', NULL, NULL, v_fwd, NULL, NULL);
    INSERT INTO container_documents (container_id, document_type, status)
    VALUES ((v_res->>'id')::uuid, 'bill_of_lading', 'pending');          -- → documents_late

    -- 【物流身份:四支全见】
    SELECT count(DISTINCT item_type) INTO v_n FROM operations_now
     WHERE item_type IN ('free_time_expiring','container_no_arrival',
                         'container_eta_overdue','container_documents_late');
    IF v_n <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 102G 失败:持 module.purchasing.view 的读者应当看得见四支,实得 % 支', v_n;
    END IF;

    -- 【财务身份:只见免柜期那一支】
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_fin), true);
    SELECT count(*) INTO v_n FROM operations_now WHERE item_type = 'free_time_expiring';
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 102G 失败:只持 module.finance.view 的读者【应当】看得见免柜期那一支 —— 滞港费是钱的事。arm_permission_any 是【相与】的,只会收窄;放宽要靠 arm_permission_widen';
    END IF;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type IN ('container_no_arrival','container_eta_overdue','container_documents_late');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102G 失败:财务【不该】看得见另外三支(它们只声明了物流的码),实得 % 行 —— 放宽算子写宽了,这一条会红', v_n;
    END IF;

    -- 【放宽算子对其余每一支都是无操作 —— 可证,不是相信】
    IF arm_permission_widen('free_time_expiring') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 102G 失败:免柜期那一支应当有放宽码集';
    END IF;
    SELECT count(*) INTO v_n FROM (
        SELECT DISTINCT x FROM unnest(ARRAY[
            'awaiting_assay','assay_unapplied','batch_unpriced','allocation_stale',
            'po_awaiting_receipt','stocktake_open','qualification_expiring',
            'qualification_missing','credit_over_limit','output_unsold_aging',
            'safety_stock_below','leave_pending','claim_pending','review_submitted',
            'invoice_overdue','fx_rate_gap','bank_unmatched','margin_cost_not_allocated',
            'metal_quote_stale','orders_unfulfilled','work_order_overdue',
            'work_order_variance_beyond','container_no_arrival',
            'container_eta_overdue','container_documents_late']) x
         WHERE arm_permission_widen(x) IS NOT NULL) z;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 102G 失败:放宽算子对除免柜期以外的每一支都必须返回 NULL(否则那一支就被悄悄放宽了),实得 % 支非空', v_n;
    END IF;
END $$;
ROLLBACK;

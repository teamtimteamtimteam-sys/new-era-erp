-- 82 化验做了一半就是没做完 —— 而料耗尽之后那盏灯必须自己灭掉
--
-- 【它守的是什么】ASY-P1 之前,awaiting_assay 那一支写的是 `assay_count = 0`:
-- 【这个批次一份化验都没有】。两个毛病,都是线上量出来的:
--   ① 看不见"做了一半"—— IN-2026-0001 只有一份覆盖 cu 的已应用化验,不亮;
--   ② 点着两盏灭不掉的灯 —— IN-2026-0011 与 IN-2026-0153 的 remaining_qty 都是 0,
--      料没了就取不到样,那份化验永远做不出来。
--
-- 现在这一支问的是:物料【声明了】要化验哪些金属,其中至少一种还没有被一份
-- 【已应用的】化验覆盖,并且【还取得到样】。行上点名缺哪几种。
--
-- 【没有阈值,所以注入打的是单层的那几处】本 fixture 一个可调的数都没有:
-- 断言的是"哪些金属缺"这个集合本身。因此每一臂都直接钉住一处没有第二层的判断:
--   A 覆盖判据(已应用化验 ⋈ 金属)· B 有没有要求(INNER JOIN)
--   C 取不取得到样(remaining_qty > 0)· D 应用之后当场清零
--
-- 【前提全部自建】自己的物料、供应商、批次与台账行 —— 不借任何引导或既有业务数据。
-- 库存恒等式由 DEFERRABLE 约束触发器强制(remaining_qty = Σ qty_delta),
-- 所以每个批次都自带配套的 inventory_movements 行,不是"凑一个数"。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid;
    m_req uuid;      -- 有化验要求的物料(cu + li)
    m_free uuid;     -- 没有要求的物料
    sup uuid;
    b_partial uuid;  -- 有要求、cu 已验、li 没验、还有料
    b_free uuid;     -- 没有要求的物料的批次
    b_spent uuid;    -- 有要求、什么都没验、料已耗尽
    asy uuid;
    v_rec jsonb;
    rec record;
    v_missing text[];
    v_denied boolean;
    v_qty numeric := 100;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-82', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【前提显式设定,哪怕默认值恰好合用】(README 第 5 条)
    -- 期间锁是操作员随月结推进的【运行时状态】;应用化验可能重估价并过账,
    -- 撞上锁就会以一个与被测规则【无关】的理由红掉。
    UPDATE finance_settings SET locked_before = NULL;
    -- 化验日必须 <= CURRENT_DATE(record_assay_result 的 ASSAY_DATE_INVALID),
    -- 所以这里用的是过去的固定日期,不是未来的年份。

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FX82-SUP', 'fixture 82 supplier', 'SG', 'goods_supplier') RETURNING id INTO sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX82-REQ', 'fixture 82 material WITH requirement', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_req;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX82-FREE', 'fixture 82 material WITHOUT requirement', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO m_free;

    -- ── 要求:cu 与 li。【经由函数写入】,不是直接插表 ──────────────────────
    v_rec := set_material_required_metals(m_req, ARRAY['cu','li']);
    IF NOT (v_rec->>'has_requirement')::boolean OR (v_rec->>'metal_count')::int <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 82 前置失败:写入要求之后应报 2 种金属,实得 %', v_rec;
    END IF;
    -- m_free 【刻意不调用】—— 没有行就是没有要求,那正是被测的默认。

    -- ── 三个批次 + 配套台账行 ───────────────────────────────────────────────
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX82-IN-PARTIAL', m_req, sup, v_qty, 'kg', v_qty, '2026-05-01') RETURNING id INTO b_partial;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (b_partial, 'receipt', v_qty, '2026-05-01');

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX82-IN-FREE', m_free, sup, v_qty, 'kg', v_qty, '2026-05-01') RETURNING id INTO b_free;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (b_free, 'receipt', v_qty, '2026-05-01');

    -- 耗尽的那个:收进来再全部耗掉,恒等式因此成立(remaining_qty = 0 = +q −q)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date)
    VALUES ('FX82-IN-SPENT', m_req, sup, v_qty, 'kg', 0, '2026-05-01') RETURNING id INTO b_spent;
    INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date)
    VALUES (b_spent, 'receipt', v_qty, '2026-05-01'),
           (b_spent, 'processing_consume', -v_qty, '2026-05-01');

    -- ── 半份化验:只验 cu,应用它 ───────────────────────────────────────────
    -- 【走真路径】record_assay_result → apply_assay_result,不是直接把 applied_at
    -- 敲进表里:被测的判据读的正是 applied_at 与 assay_result_metals,而"应用"
    -- 这个动作到底写了什么,只有那个函数说了算。
    v_rec := record_assay_result('2026-05-02'::date,
                jsonb_build_array(jsonb_build_object('metal','cu','content_pct',12.5)),
                NULL, NULL, NULL, true, NULL, b_partial, NULL, p_weight_basis => 'as_received', p_result_party => 'ours');
    asy := (v_rec->>'assay_result_id')::uuid;
    PERFORM apply_assay_result(asy);

    -- ══════════ A. 做了一半的化验【会亮】,而且点名缺的是 li ═════════════════
    -- 这正是旧那一支瞎掉的那个用例:它有一份化验,assay_count = 1,所以旧写法不亮。
    SELECT * INTO rec FROM batch_required_assay_gaps g WHERE g.inbound_batch_id = b_partial;
    IF rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 82A 失败:cu 验了、li 没验的批次不在缺口视图里 —— "做了一半"又一次被当成"做完了"';
    END IF;
    IF rec.missing_metals <> ARRAY['li'::text] THEN
        RAISE EXCEPTION 'FIXTURE 82A 失败:应当只缺 {li},实得 % —— 若含 cu,说明【已应用化验的覆盖】没有被认出来;若为空,说明"缺"的判据反了',
            rec.missing_metals;
    END IF;
    IF rec.required_metals <> ARRAY['cu'::text,'li'::text] THEN
        RAISE EXCEPTION 'FIXTURE 82A 失败:要求应为 {cu,li},实得 %', rec.required_metals;
    END IF;
    IF NOT rec.sampleable THEN
        RAISE EXCEPTION 'FIXTURE 82A 失败:还有 % kg 料的批次应当 sampleable', v_qty;
    END IF;
    -- 看板那一支也要真的点亮它,并且 subject 就是缺的那几种
    IF NOT EXISTS (SELECT 1 FROM operations_now o
                   WHERE o.item_type = 'awaiting_assay' AND o.item_id = b_partial
                     AND o.subject = 'li') THEN
        RAISE EXCEPTION 'FIXTURE 82A 失败:看板上没有这一行,或 subject 不是 li —— 实得 %',
            (SELECT o.subject FROM operations_now o WHERE o.item_type='awaiting_assay' AND o.item_id=b_partial);
    END IF;

    -- ══════════ B. 没有要求的物料:安静 ═══════════════════════════════════════
    -- 【没有行 = 没有要求】。这一臂钉的是那条默认本身 —— 它是个假设,而假设
    -- 至少要有一处断言说明它此刻是什么。
    IF EXISTS (SELECT 1 FROM batch_required_assay_gaps g WHERE g.inbound_batch_id = b_free) THEN
        RAISE EXCEPTION 'FIXTURE 82B 失败:没有声明任何化验要求的物料,它的批次却进了缺口视图';
    END IF;
    IF EXISTS (SELECT 1 FROM operations_now o WHERE o.item_type='awaiting_assay' AND o.item_id=b_free) THEN
        RAISE EXCEPTION 'FIXTURE 82B 失败:没有要求的批次却上了看板';
    END IF;

    -- ══════════ C. 料耗尽:视图里【看得见】,看板上【不点灯】═══════════════════
    -- 两件事必须分开断言。灭掉那盏灯的办法不是"把这个批次从系统里藏起来"——
    -- 缺口仍然是事实(ASY-P2 的批次页要显示它),只是没有人补救得了,
    -- 所以它不该占着一块"等人处理"的看板。
    SELECT * INTO rec FROM batch_required_assay_gaps g WHERE g.inbound_batch_id = b_spent;
    IF rec IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 82C 失败:耗尽的批次整行消失了 —— 缺口仍然是事实,消失掉它就没人说得清那批货当初验没验';
    END IF;
    IF rec.missing_metals <> ARRAY['cu'::text,'li'::text] THEN
        RAISE EXCEPTION 'FIXTURE 82C 失败:耗尽批次应当缺 {cu,li},实得 %', rec.missing_metals;
    END IF;
    IF rec.sampleable THEN
        RAISE EXCEPTION 'FIXTURE 82C 失败:remaining_qty = 0 的批次不该是 sampleable —— 料没了,样取不到';
    END IF;
    IF EXISTS (SELECT 1 FROM operations_now o WHERE o.item_type='awaiting_assay' AND o.item_id=b_spent) THEN
        RAISE EXCEPTION 'FIXTURE 82C 失败:耗尽的批次仍然点着灯 —— 那盏灯【永远灭不掉】,而灭不掉的灯会教人别看这块看板';
    END IF;

    -- ══════════ D. 边界:把最后那种金属验掉,当场清零 ═════════════════════════
    -- 【同一个事务里】—— 不靠"下次刷新就好了"。
    v_rec := record_assay_result('2026-05-03'::date,
                jsonb_build_array(jsonb_build_object('metal','li','content_pct',3.25)),
                NULL, NULL, NULL, true, NULL, b_partial, NULL, p_weight_basis => 'as_received', p_result_party => 'ours');
    PERFORM apply_assay_result((v_rec->>'assay_result_id')::uuid);

    IF EXISTS (SELECT 1 FROM batch_required_assay_gaps g WHERE g.inbound_batch_id = b_partial) THEN
        SELECT g.missing_metals INTO v_missing FROM batch_required_assay_gaps g WHERE g.inbound_batch_id = b_partial;
        RAISE EXCEPTION 'FIXTURE 82D 失败:补上最后一种金属之后仍在缺口视图里,还缺 % —— 应用之后必须当场清零',
            v_missing;
    END IF;
    IF EXISTS (SELECT 1 FROM operations_now o WHERE o.item_type='awaiting_assay' AND o.item_id=b_partial) THEN
        RAISE EXCEPTION 'FIXTURE 82D 失败:缺口没了,看板那一行还在';
    END IF;

    -- ══════════ E. 写入口的拒绝,逐条按名 ═════════════════════════════════════
    v_denied := false;
    BEGIN PERFORM set_material_required_metals(gen_random_uuid(), ARRAY['cu']);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'MATERIAL_NOT_FOUND%' THEN
            RAISE EXCEPTION 'FIXTURE 82E 失败:不存在的物料应报 MATERIAL_NOT_FOUND,实得 %', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 82E 失败:给一个不存在的物料设要求竟然成功了 —— 打错的 id 被当成了一个正当的答案';
    END IF;

    -- 【下面两条拒绝打在 m_req 上,而 m_req 此刻【有】{cu,li}】—— 这一点是被
    -- 故障注入逼出来的:第一版打在 m_free 上,而 m_free 本来就没有要求行,
    -- 于是"被拒之后旧的还在吗"这个断言【无论如何都成立】。把校验挪到 DELETE
    -- 之后的注入照样通过 —— 一条从来没有观察到它失败过的检查,只是安静而已。
    v_denied := false;
    BEGIN PERFORM set_material_required_metals(m_req, ARRAY['cu','zz']);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'METAL_UNKNOWN%' THEN
            RAISE EXCEPTION 'FIXTURE 82E 失败:未知金属应报 METAL_UNKNOWN,实得 %', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 82E 失败:zz 这种金属竟然被接受了';
    END IF;

    v_denied := false;
    BEGIN PERFORM set_material_required_metals(m_req, ARRAY['cu','cu']);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'METAL_DUPLICATED%' THEN
            RAISE EXCEPTION 'FIXTURE 82E 失败:重复金属应报 METAL_DUPLICATED,实得 %', SQLERRM;
        END IF;
        v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 82E 失败:重复的金属被悄悄去重了 —— 调用方对自己要什么是糊涂的,而去重让它以为说清楚了';
    END IF;

    -- 【被拒之后,m_req 原来那一套必须【原样还在】—— 而这一条是【结构上保证的】,
    --   不是这个函数的功劳,写清楚免得被当成证据】
    -- 两次故障注入把它逼出来了:把 METAL_DUPLICATED 的校验挪到 DELETE 之后,
    -- 本臂【照样全绿】。原因是 plpgsql 的 BEGIN…EXCEPTION 块自带一个隐式保存点:
    -- 异常一抛,那次 DELETE 当场回滚,校验在删之前还是删之后都看不出来。
    -- (第一版更弱:它打在 m_free 上,而 m_free 本来就没有要求行,连"有东西可失去"
    --  都不成立。改打 m_req 之后至少断言了正确的对象,但那条恒等式仍然是
    --  AGENTS.md 说的【guaranteed-true】那一类 —— 它不花什么代价,也证明不了什么。)
    -- 真正保证"被拒 = 什么都没写"的是事务语义,不是检查顺序。
    SELECT array_agg(metal ORDER BY metal) INTO v_missing
      FROM material_required_metals WHERE material_id = m_req;
    IF v_missing IS DISTINCT FROM ARRAY['cu'::text,'li'::text] THEN
        RAISE EXCEPTION 'FIXTURE 82E 失败:两次被拒之后 m_req 的要求应当原样是 {cu,li},实得 % —— 校验发生在 DELETE 之后,拒绝顺手毁掉了原来那一套',
            v_missing;
    END IF;
    -- 而 m_free 从头到尾没有被写过,仍然是"没有要求"
    IF EXISTS (SELECT 1 FROM material_required_metals WHERE material_id = m_free) THEN
        RAISE EXCEPTION 'FIXTURE 82E 失败:m_free 从来没有被成功写入过,却有了要求行';
    END IF;

    -- ══════════ F. 空数组【是】一个动作:清空,而不是"什么都不做" ═════════════
    v_rec := set_material_required_metals(m_req, ARRAY[]::text[]);
    IF (v_rec->>'has_requirement')::boolean OR (v_rec->>'metal_count')::int <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 82F 失败:清空之后应报 has_requirement=false / metal_count=0,实得 %', v_rec;
    END IF;
    IF EXISTS (SELECT 1 FROM material_required_metals WHERE material_id = m_req) THEN
        RAISE EXCEPTION 'FIXTURE 82F 失败:传空数组没有把要求清掉 —— "取消全部要求"这个动作静默失败了';
    END IF;
    -- 清空之后,连耗尽那个批次也退出缺口视图(它靠的是 INNER JOIN)
    IF EXISTS (SELECT 1 FROM batch_required_assay_gaps g WHERE g.material_id = m_req) THEN
        RAISE EXCEPTION 'FIXTURE 82F 失败:要求清空了,缺口行还在';
    END IF;

    -- ══════════ G. 权限:改要求要 module.materials.edit ═══════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', gen_random_uuid()), true);
    v_denied := false;
    BEGIN PERFORM set_material_required_metals(m_free, ARRAY['cu']);
    EXCEPTION WHEN OTHERS THEN v_denied := true;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 82G 失败:没有 module.materials.edit 的主体改掉了化验要求';
    END IF;
END $$;
ROLLBACK;

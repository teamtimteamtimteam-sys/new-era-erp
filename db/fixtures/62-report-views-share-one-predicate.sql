-- 62 报表视图(RPT-1):三态判据【全库一处】,而未指定库位是一个格子
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉住的两件事】
--   ① 违规判据【只有一处】:stock_class_violations_all(基视图)。报表与
--      NTF-1 的发射器读的是同一处。G 臂把那一处打坏,然后断言【两个消费者
--      同时失守】—— 一处实现、两个消费者,注入必须两边都咬到,否则"同一处"
--      只是一句注释。
--   ② 快照里【未指定库位是一行普通的行】。线上 85 行流水里 79 行没有库位;
--      把这一格丢掉,这张报表会悄悄漏掉绝大多数台账。E 臂钉住它。
--
-- 各臂:
--   A 前提:两张视图在;判据基视图对 authenticated 不可读(门在报表视图上)
--   B 【未配置】库位上的存量:不是违规(没人做过决定)
--   C 【未分类】物料的存量:不是违规(同上)—— 即使落在已配置库位上
--   D 【配了且不含这一类】:是违规,数量报得对
--   E 快照:未指定库位那一格【在】,且数量对
--   F 快照与 remaining_qty 对得上(STK-1 的不变量,报表粒度上再验一次)
--   G 注入:把判据里"未分类不算"那一句拿掉 → 视图多报一行【且】发射器多发
--     一条事件 —— 两个消费者同时失守,证明它们真的读同一处
--
-- 【SO-2(2026-08-14)】判据放宽成【所有库存状态一起算】(违规讲的是货待在
-- 哪里,与它扣没扣住、许给了谁无关),G 臂的注入体同步改掉那一行。本文件其余
-- 各臂一个字没动:B/C/D 造的都是 available 的存量,数字不受影响。
-- 【"预留不让违规消失"那一条钉在 fixture 64 G 臂】—— 它需要一张确认了的
-- 销售订单才造得出 committed 的货,而那套装置属于预留那一刀。
--
-- 日期无关。自带数据(README 第 2 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all uuid; v_sup uuid;
    m_foc uuid; m_non uuid; m_null uuid;
    loc_un uuid; loc_foc uuid;
    v_n int; v_qty numeric; v_snap numeric; v_rem numeric;
    v_before int; v_after int; d date := CURRENT_DATE;
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-62', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIXT-S62', 'Fixture Supplier 62', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit, waste_classification_code)
    VALUES ('ZZFIX62-F', 'f62 focused', 'battery_material', true, 'black_mass', 'end_of_life', 'kg', 'focused') RETURNING id INTO m_foc;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit, waste_classification_code)
    VALUES ('ZZFIX62-N', 'f62 non-focused', 'battery_material', true, 'black_mass', 'end_of_life', 'kg', 'non_focused') RETURNING id INTO m_non;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZFIX62-U', 'f62 unclassified', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO m_null;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ62-UN', 'unconfigured') RETURNING id INTO loc_un;
    INSERT INTO storage_locations (code, name) VALUES ('ZZ62-FOC', 'focused only') RETURNING id INTO loc_foc;
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_foc, 'focused');

    -- ══════════ A. 前提 ═════════════════════════════════════════════════════
    IF has_table_privilege('authenticated', 'public.stock_class_violations_all', 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 62A 失败:判据基视图【不该】对 authenticated 可读 —— 它不带 has_permission,门在 stock_class_violations 上;读得到基视图就等于绕开那道门直接读全库违规';
    END IF;
    -- 发射器必须【引用那一处判据】。这是一条目录断言:将来有人把谓词抄回
    -- 函数体里(再分叉一次),这一条当场红,而不是等两边的答案漂开之后才被发现。
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'notify_class_violations'
           AND p.prosrc LIKE '%stock_class_violations_all%')
    THEN
        RAISE EXCEPTION 'FIXTURE 62A 失败:notify_class_violations 不再引用 stock_class_violations_all —— 判据被抄回去了,报表与通知从此会各说各话';
    END IF;

    -- ══════════ B. 未配置库位上的存量:不是违规 ═══════════════════════════════
    PERFORM create_inbound_batch(m_foc, v_sup, 10, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_un, p_source_reason_code => 'other', p_source_reason_note => 'fixture 62 自带数据');
    SELECT count(*) INTO v_n FROM stock_class_violations WHERE location_id = loc_un;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 62B 失败:【未配置】的库位上有货不是违规(没人做过决定),实得 % 行', v_n;
    END IF;

    -- ══════════ C. 未分类物料:不是违规,即使在已配置库位上 ════════════════════
    PERFORM create_inbound_batch(m_null, v_sup, 7, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_foc, p_source_reason_code => 'other', p_source_reason_note => 'fixture 62 自带数据');
    SELECT count(*) INTO v_n FROM stock_class_violations WHERE material_id = m_null;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 62C 失败:【未分类】物料不是违规 —— 未分类是没人分过类,不是被排除;实得 % 行', v_n;
    END IF;

    -- ══════════ D. 配了、且不含这一类:是违规,数量对 ═════════════════════════
    -- non_focused 的货【不能】经 IOD-2 的门收进 loc_foc(那会被拒),所以先收进
    -- 未配置的 loc_un,再把 loc_un 配成只允许 non_focused —— 与真实世界一致:
    -- 违规是【配置后来改了】造出来的,不是收货收出来的。
    PERFORM create_inbound_batch(m_non, v_sup, 25, 'kg', d, '待加工', NULL, NULL, NULL, NULL, loc_un, p_source_reason_code => 'other', p_source_reason_note => 'fixture 62 自带数据');
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_un, 'focused');   -- 只允许 focused ⇒ 那 25kg non_focused 违规,10kg focused 不违规

    SELECT count(*), max(qty) INTO v_n, v_qty
      FROM stock_class_violations WHERE location_id = loc_un;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 62D 失败:loc_un 上应当恰好一行违规(non_focused 那 25kg),实得 %', v_n;
    END IF;
    IF v_qty <> 25 THEN
        RAISE EXCEPTION 'FIXTURE 62D 失败:违规数量应当是 25,实得 %', v_qty;
    END IF;

    -- ══════════ E. 快照:未指定库位是一行普通的行 ════════════════════════════
    -- 不指定库位收一批 —— 它必须在快照里【有自己的一格】,而不是消失。
    PERFORM create_inbound_batch(m_foc, v_sup, 40, 'kg', d, p_source_reason_code => 'other', p_source_reason_note => 'fixture 62 自带数据');
    SELECT count(*), max(qty) INTO v_n, v_qty
      FROM stock_snapshot
     WHERE material_id = m_foc AND location_id IS NULL AND stock_status = 'available';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 62E 失败:【未指定库位】必须是快照里的一行普通的行(一等状态,不是缺失数据),实得 % 行', v_n;
    END IF;
    IF v_qty <> 40 THEN
        RAISE EXCEPTION 'FIXTURE 62E 失败:未指定库位那一格的数量应当是 40,实得 %', v_qty;
    END IF;

    -- ══════════ F. 快照与 remaining_qty 对得上(STK-1 的不变量)═══════════════
    -- 【两个独立的侧】快照是流水的和;remaining_qty 是批次自己维护的余量。
    -- 它们从两条不同的路走到同一个数,所以对得上才有意义。
    SELECT COALESCE(sum(qty), 0) INTO v_snap FROM stock_snapshot WHERE material_id = m_foc;
    SELECT COALESCE(sum(remaining_qty), 0) INTO v_rem
      FROM inbound_batches WHERE material_id = m_foc AND deleted_at IS NULL;
    IF v_snap <> v_rem THEN
        RAISE EXCEPTION 'FIXTURE 62F 失败:快照合计 % 与批次 remaining_qty 合计 % 对不上 —— 两条独立的路走出两个数,其中一条错了', v_snap, v_rem;
    END IF;

    -- ══════════ G. 注入:打坏那一处判据,两个消费者必须【同时】失守 ═══════════
    SELECT count(*) INTO v_before FROM notifications;

    EXECUTE $inj$
        CREATE OR REPLACE VIEW public.stock_class_violations_all WITH (security_invoker = off) AS
            WITH avail AS (
                SELECT mv.location_id, COALESCE(ib.material_id, ob.material_id) AS material_id,
                       sum(mv.qty_delta) AS qty
                  FROM inventory_movements mv
                       LEFT JOIN inbound_batches ib ON ib.id = mv.inbound_batch_id
                       LEFT JOIN output_batches  ob ON ob.id = mv.output_batch_id
                 -- SO-2:判据不再按状态过滤(违规讲的是货待在哪里)。注入体
                 -- 必须跟着改,否则它注入的就不止"拿掉未分类那一句"这一处 ——
                 -- 一次注入若同时改了两件事,它证明不了任何一件。
                 WHERE mv.location_id IS NOT NULL
                 GROUP BY 1,2 HAVING sum(mv.qty_delta) > 0)
            SELECT a.material_id, m.code AS material_code, m.waste_classification_code AS class_code,
                   a.location_id, sl.code AS location_code, a.qty
              FROM avail a JOIN materials m ON m.id = a.material_id
                   JOIN storage_locations sl ON sl.id = a.location_id
             WHERE m.deleted_at IS NULL
               -- 【被拿掉的那一句】: AND m.waste_classification_code IS NOT NULL
               AND EXISTS (SELECT 1 FROM storage_location_allowed_classes c WHERE c.location_id = a.location_id)
               AND NOT EXISTS (SELECT 1 FROM storage_location_allowed_classes c
                                WHERE c.location_id = a.location_id
                                  AND c.classification_code = m.waste_classification_code);
    $inj$;

    -- 消费者一:视图。未分类的那 7kg 现在被误报成违规。
    SELECT count(*) INTO v_n FROM stock_class_violations WHERE material_id = m_null;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'FIXTURE 62G 失败:拿掉"未分类不算"那一句之后,视图【仍然】不报它 —— 说明 C 臂并不依赖那一句,它一直在空转';
    END IF;

    -- 消费者二:发射器。同一次注入必须让它也多发事件 —— 这才证明"同一处"。
    INSERT INTO storage_location_allowed_classes (location_id, classification_code)
    VALUES (loc_foc, 'non_focused');   -- 触发 loc_foc 的重算
    SELECT count(*) INTO v_after FROM notifications;
    IF v_after <= v_before THEN
        RAISE EXCEPTION 'FIXTURE 62G 失败:注入之后发射器【没有】跟着多发事件(% → %)—— 两个消费者没有读同一处判据,"一处实现"只是一句注释', v_before, v_after;
    END IF;
END $$;
ROLLBACK;

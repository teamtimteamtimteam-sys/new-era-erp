-- 189 一张【取消掉】的采购单不再占着它没买成的那台机器 —— 而那条链接【留着】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这一份存在 —— 一次 Tim 走出来的缺陷,两个症状一个根】
-- 他为一台机器(FA-2026-0002)开了采购单 PO-2026-0008,没付款,然后【取消】了它。
-- 症状一:资产卡片页照旧写着「由 PO-2026-0008 第 1 行买下」—— 一句已经不成立的断言。
-- 症状二:再开一张新单时,那台机器在下拉里是【灰的】,写着"已在采购单上"。
--
-- 【根】cancel_purchase_order 只动 purchase_orders 那一行和一条历史记录。
-- 它【从来没有看过 purchase_order_lines】—— 那条链接不是被有意保留的,
-- 是从来没有被考虑过。而挑机器的那个下拉收的是【全部】带 asset_id 的行,
-- 不问它挂在哪张单上。两边合起来,一张死单永久占着一台机器。
--
-- 【本 fixture 钉的是哪一半 —— 说清楚,不冒充】
-- 修复本身在【应用层】(两个页面的查询各加一条"这张单还活着吗")。
-- 数据库这一侧没有、也【不该由本刀】新加任何约束(见文末「刻意没做的事」)。
-- 所以这一份钉的是修复所依赖的那几条【数据库事实】,外加【那两条查询本身】——
-- 后者照 fixture 110 的先例办:**表单够不到,查询够得到**,于是直接跑查询。
--
-- 【每一臂钉什么】
-- A 前提【先立】:取消【之前】,那个下拉的查询确实把这台机器算作"被占着"。
--   少了这一条,B 臂可能因为一个完全无关的理由变绿(比如这台机器根本没挂上去)。
-- B 取消【之后】:①那条行【还在】(历史不抹掉);②下拉的查询不再把它算作被占;
--   ③资产卡片页的那条查询仍然读得到它,而它挂着的单是 cancelled —— 页面因此
--   说得出「这张单已取消」,而不是留白。
-- C 【真的能再挂一次】:为同一台机器开第二张单,create_purchase_order 收下它。
--   于是这台机器身上有【两条】行 —— 而那正是 .maybeSingle() 会炸掉的形状,
--   所以这一臂同时是资产卡片页那处改动的理由。
-- D 【软删的单同样不占】—— 与取消是同一个缺陷的第二个实例:
--   purchase_order_lines_masked 不 JOIN 表头,软删的单一样会占着机器。
--
-- 【注入放在最后】两次,各打一条断言的要害:
--   注入1 让取消【不改状态】→ B② 必须变红(证明 B② 看的真是状态);
--   注入2 让取消【删掉那条行】→ B① 必须变红(证明 B① 真在守"历史留着")。
--
-- 【自带数据】重建库里没有业务数据:自己建供应商 + 资产卡 + 采购单。
-- 日期全部落在 2027,与引导数据和随月末移动的状态无关(README 第 4 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user  uuid := gen_random_uuid();
    r_all   uuid;
    v_ccy   text;
    v_sup   uuid;
    v_asset uuid; v_asset2 uuid; v_asset3 uuid;
    v_res   jsonb;
    v_po    uuid; v_po2 uuid; v_po3 uuid; v_po4 uuid;
    v_line  uuid;
    v_n     integer;
    v_status text;
    v_def_cancel text; v_inj text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-189', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 【原样定义在任何注入之前取齐】临用临取会取到已经被上一个注入改过的那一份
    -- (fixture 74/75 的教训,fixture 77 抬头照抄过一遍)。
    v_def_cancel := pg_get_functiondef('public.cancel_purchase_order(uuid, text)'::regprocedure);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX189-S', 'fixture 189 supplier', 'SG', 'active', 'goods_supplier')
    RETURNING id INTO v_sup;

    v_res := create_fixed_asset('fixture 189 machine', 120, DATE '2027-01-01');
    v_asset := (v_res->>'asset_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'fixture 189 first order',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100000)));
    v_po := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po;
    IF v_line IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 189 前提失败:设备采购单没建出来 —— 后面每一臂都会空转';
    END IF;

    -- ══════════ A · 前提:取消【之前】,这台机器确实被算作"已在采购单上" ═════
    RAISE NOTICE 'fixture 189 · 进入 A';
    -- 【这就是 app/purchasing/orders/new/page.tsx 那个下拉的判据】——
    -- 行来自 purchase_order_lines_masked,表头单独查一次,在应用里拼。
    -- 这里把它写成一条 JOIN:问的是同一个问题,而 fixture 够得到两边。
    SELECT count(*) INTO v_n
      FROM purchase_order_lines_masked pol
      JOIN purchase_orders_masked po ON po.id = pol.purchase_order_id
     WHERE pol.asset_id = v_asset
       AND po.deleted_at IS NULL
       AND po.status <> 'cancelled';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 189A 前提失败:取消之前这台机器应当【正被一张活着的单占着】(1 条),实得 % —— 若这里就是 0,B② 会因为一个无关的理由变绿', v_n;
    END IF;

    -- ══════════ B · 取消之后 ═══════════════════════════════════════════════
    RAISE NOTICE 'fixture 189 · 进入 B';
    PERFORM cancel_purchase_order(v_po, 'fixture 189: not paid, cancelled');

    -- B① 那条行【还在】—— 本仓库偏好历史而不是抹掉(AUDEL 那一族)。
    SELECT count(*) INTO v_n FROM purchase_order_lines WHERE id = v_line;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 189B① 失败:取消不该【删掉】那条采购单行,实得 % 行 —— 一台机器曾经被开过一张单、那张单又被取消,是它履历的一部分', v_n;
    END IF;
    SELECT asset_id INTO v_asset2 FROM purchase_order_lines WHERE id = v_line;
    IF v_asset2 IS DISTINCT FROM v_asset THEN
        RAISE EXCEPTION 'FIXTURE 189B① 失败:取消不该把那条行上的 asset_id 抹掉,实得 %', COALESCE(v_asset2::text, 'NULL');
    END IF;

    -- B② 下拉不再把它算作被占 —— 【这一条就是"机器又挑得动了"】
    SELECT count(*) INTO v_n
      FROM purchase_order_lines_masked pol
      JOIN purchase_orders_masked po ON po.id = pol.purchase_order_id
     WHERE pol.asset_id = v_asset
       AND po.deleted_at IS NULL
       AND po.status <> 'cancelled';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 189B② 失败:取消之后不该再有【活着的】单占着这台机器,实得 % —— 这正是 Tim 撞上的那一条:机器在下拉里是灰的,而占着它的那张单已经取消了', v_n;
    END IF;

    -- B③ 资产卡片页仍然读得到那条行,而它挂着的单是 cancelled ——
    -- 页面因此说得出「这张单已取消」。留白会把"曾经有过、被取消了"读成"从来没有过"。
    SELECT po.status INTO v_status
      FROM purchase_order_lines_masked pol
      JOIN purchase_orders_masked po ON po.id = pol.purchase_order_id
     WHERE pol.asset_id = v_asset;
    IF v_status IS DISTINCT FROM 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 189B③ 失败:资产卡片页应当仍然读得到那条行、并读出 status=cancelled,实得 % —— 读不到就只能留白,而留白是另一句假话', COALESCE(v_status, 'NULL');
    END IF;

    -- ══════════ C · 真的能再挂一次,而这台机器于是有【两条】行 ═══════════════
    RAISE NOTICE 'fixture 189 · 进入 C';
    v_res := create_purchase_order(v_sup, DATE '2027-02-10', DATE '2027-04-01', v_ccy, NULL,
        NULL, NULL, 'fixture 189 replacement order',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100000)));
    v_po2 := (v_res->>'purchase_order_id')::uuid;
    IF v_po2 IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 189C 失败:取消之后应当能为同一台机器再开一张单';
    END IF;
    -- ★ 两条行 —— 这正是 app/finance/assets/[id]/page.tsx 那句 .maybeSingle()
    --   会当场报错的形状。它此前碰不到,是因为机器永远挂不上第二张单;
    --   修好"挑得动"的那一刻,这一页就会开始 500。**两个缺陷是连着的。**
    SELECT count(*) INTO v_n FROM purchase_order_lines WHERE asset_id = v_asset;
    IF v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 189C 失败:这台机器现在应当挂着两条行(一条取消掉的 + 一条新的),实得 % —— 这一臂同时是资产卡片页放弃 .maybeSingle() 的理由', v_n;
    END IF;
    -- 而【活着的】那一条恰好一条 —— 新单占着它,旧单不占。
    SELECT count(*) INTO v_n
      FROM purchase_order_lines_masked pol
      JOIN purchase_orders_masked po ON po.id = pol.purchase_order_id
     WHERE pol.asset_id = v_asset
       AND po.deleted_at IS NULL
       AND po.status <> 'cancelled';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 189C 失败:两条行里应当【恰好一条】是活着的,实得 %', v_n;
    END IF;

    -- ══════════ D · 软删的单同样不占(同一个缺陷的第二个实例)══════════════
    RAISE NOTICE 'fixture 189 · 进入 D';
    v_res := create_fixed_asset('fixture 189 machine 2', 120, DATE '2027-01-01');
    v_asset3 := (v_res->>'asset_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-03-10', DATE '2027-05-01', v_ccy, NULL,
        NULL, NULL, 'fixture 189 soft-deleted order',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset3, 'quantity', 1,
                                             'estimated_unit_price', 90000)));
    v_po3 := (v_res->>'purchase_order_id')::uuid;
    -- 【软删要走那扇门】purchase_orders 上挂着 guard_soft_delete_provenance:
    -- 直连 UPDATE 会被 SOFT_DELETE_NO_DIRECT_UPDATE 按名拒(本 fixture 第一版
    -- 就是这么红的 —— 而红得对:那道守卫正是这样存在的)。
    -- 今天【没有】soft_delete_purchase_order 这扇门,所以照 fixture 85 的先例
    -- 手动设标记并把两列填齐 —— 那正是那道守卫要求的全部。
    PERFORM set_config('evoltrya.soft_delete_ctx', '1', true);
    UPDATE purchase_orders
       SET deleted_at = now(), deleted_by = v_user, delete_reason = 'fixture 189 soft delete'
     WHERE id = v_po3;
    PERFORM set_config('evoltrya.soft_delete_ctx', '', true);
    SELECT count(*) INTO v_n
      FROM purchase_order_lines_masked pol
      JOIN purchase_orders_masked po ON po.id = pol.purchase_order_id
     WHERE pol.asset_id = v_asset3
       AND po.deleted_at IS NULL
       AND po.status <> 'cancelled';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 189D 失败:一张【软删掉】的单同样不该占着机器,实得 % —— purchase_order_lines_masked 不 JOIN 表头,所以这一条与取消是同一个缺陷的两个实例', v_n;
    END IF;

    -- ══════════ 注入 1:让取消【不改状态】→ B② 必须变红 ═════════════════════
    RAISE NOTICE 'fixture 189 · 注入 1';
    -- 【注入点选的是那条 UPDATE 的赋值,不是那句 RAISE】—— 与 fixture 77 同一条理由。
    v_inj := replace(v_def_cancel,
        'SET status = ''cancelled'', cancelled_at = now()',
        'SET status = ''confirmed'', cancelled_at = now()');
    IF v_inj = v_def_cancel THEN
        RAISE EXCEPTION 'FIXTURE 189 注入1 失败:在 cancel_purchase_order 里没找到那条 SET status = ''cancelled'' 的原文 —— 这个注入什么也没改,下面那句"应当仍被占着"会变成空转';
    END IF;
    EXECUTE v_inj;
    v_res := create_fixed_asset('fixture 189 machine 3', 120, DATE '2027-01-01');
    v_asset2 := (v_res->>'asset_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-04-10', DATE '2027-06-01', v_ccy, NULL,
        NULL, NULL, 'fixture 189 injection 1 order',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset2, 'quantity', 1,
                                             'estimated_unit_price', 80000)));
    v_po4 := (v_res->>'purchase_order_id')::uuid;
    PERFORM cancel_purchase_order(v_po4, 'fixture 189 injection 1');
    SELECT count(*) INTO v_n
      FROM purchase_order_lines_masked pol
      JOIN purchase_orders_masked po ON po.id = pol.purchase_order_id
     WHERE pol.asset_id = v_asset2
       AND po.deleted_at IS NULL
       AND po.status <> 'cancelled';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 189 注入1 失败:把"取消"改成不写 cancelled 之后,这台机器应当【仍然被占着】(1 条),实得 % —— 说明 B② 放行它的不是那个状态', v_n;
    END IF;
    EXECUTE v_def_cancel;   -- 还原

    -- ══════════ 注入 2:让取消【删掉那条行】→ B① 必须变红 ═══════════════════
    RAISE NOTICE 'fixture 189 · 注入 2';
    v_inj := replace(v_def_cancel,
        '    -- AUDEL-1b:写一行历史',
        '    DELETE FROM purchase_order_lines WHERE purchase_order_id = p_id;' || chr(10)
        || '    -- AUDEL-1b:写一行历史');
    IF v_inj = v_def_cancel THEN
        RAISE EXCEPTION 'FIXTURE 189 注入2 失败:在 cancel_purchase_order 里没找到写历史那一段的锚点 —— 这个注入什么也没加';
    END IF;
    EXECUTE v_inj;
    v_res := create_fixed_asset('fixture 189 machine 4', 120, DATE '2027-01-01');
    v_asset2 := (v_res->>'asset_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-05-10', DATE '2027-07-01', v_ccy, NULL,
        NULL, NULL, 'fixture 189 injection 2 order',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset2, 'quantity', 1,
                                             'estimated_unit_price', 70000)));
    v_po4 := (v_res->>'purchase_order_id')::uuid;
    SELECT id INTO v_line FROM purchase_order_lines WHERE purchase_order_id = v_po4;
    PERFORM cancel_purchase_order(v_po4, 'fixture 189 injection 2');
    SELECT count(*) INTO v_n FROM purchase_order_lines WHERE id = v_line;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 189 注入2 失败:注入了一句 DELETE 之后那条行应当【真的没了】,实得 % —— 说明 B① 看的不是那条行本身', v_n;
    END IF;
    EXECUTE v_def_cancel;   -- 还原
END $$;
ROLLBACK;

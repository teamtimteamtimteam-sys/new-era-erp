-- 110 那几个下拉读的是【遮蔽视图】,不是表 —— 一次只有人点得出来的缺陷,做成断言
--
-- 【为什么这一份存在】EQP-1c-c 给开支表单加了一个采购行下拉,它【查了表】。
-- purchase_order_lines 是遮蔽表(REVOKE SELECT + 列清单授权),而那个下拉要的
-- estimated_amount_ccy 正是被扣住的三列之一 —— 于是页面对每一个登录用户都是
-- 「Load failed / 42501」。**闸门全绿,冒烟 0 FAILED,是 Tim 用手点出来的。**
-- 冒烟看不见它的原因写在 scripts/smoke-routes.mjs 的抬头(页面把错误自己渲染成
-- 一个 200 的红框,而冒烟断言的是 2xx)。
--
-- **表单够不到,查询够得到。** 所以这一份 fixture 直接跑那几条查询本身。
--
-- 【每一臂钉什么】
-- A 前提【先立】:同一组列【对着表】在 authenticated 身份下【必须被拒】。
--   少了这一条,B 臂可能因为一个完全无关的理由变绿(比如那几列其实早就授权了),
--   而那时它证明的就不是"视图在干活"。
-- B 那几条查询【对着遮蔽视图】必须跑得出行来 —— 逐条,按它们在 app/ 里的原样。
-- C 视图【确实在遮蔽】:没有 data.view_prices 的读者拿到的金额列是 NULL,
--   而不是一个 42501,也不是一个真数字。否则"改读视图"就成了一次绕过。
--
-- 【自带数据】重建库里没有业务数据:自己建供应商 + 资产卡 + 一张设备采购单。
BEGIN;
DO $$
DECLARE
    v_all uuid := gen_random_uuid();     -- 全权限读者
    v_noprice uuid := gen_random_uuid(); -- 不持 data.view_prices 的读者
    r_all uuid; r_np uuid; v_ccy text;
    v_sup uuid; v_asset uuid; v_res jsonb; v_po uuid;
    v_n int; v_msg text; v_denied boolean; v_amt numeric;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-110', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_all, r_all);
    -- 第二个读者:什么都有,【就是没有 data.view_prices】
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-110-np', 'f', 'f', true) RETURNING id INTO r_np;
    INSERT INTO role_permissions (role_id, permission_code)
        SELECT r_np, code FROM permissions WHERE code <> 'data.view_prices';
    INSERT INTO user_roles (user_id, role_id) VALUES (v_noprice, r_np);

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX110-S', 'fixture 110 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    v_res := create_fixed_asset('fixture 110 machine', 120, DATE '2027-01-01');
    v_asset := (v_res->>'asset_id')::uuid;
    v_res := create_purchase_order(v_sup, DATE '2027-01-10', DATE '2027-03-01', v_ccy, NULL,
        NULL, NULL, 'fixture 110 equipment PO',
        jsonb_build_array(jsonb_build_object('asset_id', v_asset, 'quantity', 1,
                                             'estimated_unit_price', 100000)));
    v_po := (v_res->>'purchase_order_id')::uuid;

    -- ══════════ A · 前提:对着【表】必须被拒 ════════════════════════════════
    RAISE NOTICE 'fixture 110 · 进入 A';
    v_denied := false; v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        -- 【这就是 EQP-1c-c 写下的那一组列】—— estimated_amount_ccy 是被扣住的三列之一。
        PERFORM id, line_no, asset_id, purchase_order_id, estimated_amount_ccy
          FROM purchase_order_lines WHERE asset_id IS NOT NULL;
        RESET ROLE;
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM; RESET ROLE;
    END;
    IF NOT v_denied OR position('permission denied' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 110A 前提失败:这一组列【对着表】本该被拒(42501),实得 denied=% msg=% —— 若它现在通得过,说明有人把表的 SELECT 授回去了,而那会把金额列敞给每一个登录用户。**PostgreSQL 的报错提示正是这么建议的,而那条建议不能听。**',
            v_denied, COALESCE(v_msg,'(通过了)');
    END IF;

    -- ══════════ B · 对着【遮蔽视图】必须跑得出行 ═══════════════════════════
    RAISE NOTICE 'fixture 110 · 进入 B';
    -- 【这里【必须】把那几列真的选出来,不能用 count(*)】——
    -- 列级授权之下,只要读者对【任何一列】有 SELECT,count(*) 就通得过。
    -- 第一版这几臂写的就是 count(*),于是把查询指回【表】之后它们照样全绿:
    -- 一次【证明不了任何事】的断言。故障注入当场抓到了它,记在这里。
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- B1:开支表单的采购行下拉(EQP-1c-c)—— 逐列照抄 page.tsx 里那一行 select
    SELECT count(*) INTO v_n FROM (
        SELECT id, line_no, asset_id, purchase_order_id, estimated_amount_ccy
          FROM purchase_order_lines_masked WHERE asset_id IS NOT NULL) q;
    RESET ROLE;
    IF v_n < 1 THEN
        RAISE EXCEPTION 'FIXTURE 110B 失败:开支表单那个下拉的查询对着遮蔽视图应当读得到行,实得 % —— 这正是 Tim 走查撞上的那一条', v_n;
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- B2:资产卡片页的「由哪张单买的」(EQP-1c-a)—— 【同一个缺陷的第二个实例】
    SELECT count(*) INTO v_n FROM (
        SELECT id, line_no, purchase_order_id, estimated_amount_ccy
          FROM purchase_order_lines_masked WHERE asset_id = v_asset) q;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 110B 失败:资产卡片页那一条查询应当读到恰好 1 行,实得 % —— 它没有被走查报出来,是这一刀数出来的', v_n;
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    -- B3:下单表单与 PDF 路由那两条(只选 asset_id —— 它们【碰巧】直接查表也不炸,
    -- 而那正是陷阱:判据不该是"我这次只选了安全的列")
    SELECT count(*) INTO v_n FROM (
        SELECT asset_id FROM purchase_order_lines_masked WHERE asset_id IS NOT NULL) q;
    RESET ROLE;
    IF v_n < 1 THEN
        RAISE EXCEPTION 'FIXTURE 110B 失败:下单表单/PDF 路由那两条查询应当读得到行,实得 %', v_n;
    END IF;

    -- ══════════ C · 视图确实在遮蔽,而不是被绕开了 ══════════════════════════
    RAISE NOTICE 'fixture 110 · 进入 C';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_noprice), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT estimated_amount_ccy INTO v_amt FROM purchase_order_lines_masked WHERE asset_id = v_asset;
    RESET ROLE;
    IF v_amt IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 110C 失败:不持 data.view_prices 的读者拿到的金额应当是 NULL(遮蔽),实得 % —— 若它是个真数字,那"改读视图"就成了一次绕过遮蔽,而不是一次修复', v_amt;
    END IF;
    -- 而持有它的读者拿得到真数字(否则上面那个 NULL 可能只是因为这一行本来就是空的)
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT estimated_amount_ccy INTO v_amt FROM purchase_order_lines_masked WHERE asset_id = v_asset;
    RESET ROLE;
    IF v_amt IS DISTINCT FROM 100000 THEN
        RAISE EXCEPTION 'FIXTURE 110C 失败:持 data.view_prices 的读者应当拿到 100,000,实得 % —— 两侧都要断言,否则上一条的 NULL 证明不了是遮蔽在起作用', COALESCE(v_amt::text,'(null)');
    END IF;

    RAISE NOTICE 'fixture 110:A/B/C 通过';
END $$;
ROLLBACK;

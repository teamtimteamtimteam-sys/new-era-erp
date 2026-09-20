-- 200 一个【计划】可以在未来,而一个没有编辑权的人【设不了】它 —— 且它会被告知
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉住的那三句话】
--   ① `set_asset_planned_in_service()` 让一个【有 module.finance.edit 的人】
--      真的改得动 `planned_in_service_date` —— 那扇门从 FIX-1 落地那天起就是死的
--      (`fixed_assets` 开着 RLS 而全表只有一条 SELECT 策略,直连 UPDATE 零行)。
--   ② ★ 它【接受一个未来的日期】。这是这一列存在的全部理由,也是
--      **一次从 set_asset_in_service 复制粘贴会当场毁掉的那一件事**:
--      那一支管的是【事件】,而事件不能发生在明天(fixture 120 钉的就是它)。
--   ③ ★ 一个【没有】 module.finance.edit 的人被**按名拒**,而不是拿到一句
--      静默的零行。这半件事这张表从来没有过 —— 它上面没有
--      enforce_write_permission 触发器,两支守卫触发器都不管权限。
--
-- ⚠️★★【每一臂都必须 SET LOCAL ROLE authenticated —— 而这支 fixture 还【证明】了它】★★
--   fixture 以 postgres 跑,`rolbypassrls = t`。不切角色的话,反面对照那一臂
--   **按构造**也会通过(postgres 绕过 RLS、而 require_permission 在
--   一个没有 claims 的会话里…… 恰恰会拒 —— 于是它会因为【错的理由】变绿)。
--   这是 AGENTS.md 记着的 fixture 26 那一课。
--   ★★ 所以本文件多了一格 **G 臂**:在同一个切过角色的会话里,**老那条直连
--      UPDATE 仍然改零行**。G 绿 = 角色切换真的生效了,A 臂的成功只可能来自
--      那支函数。没有 G,「切了角色」只是一句声明。
--
-- ── 七臂 ────────────────────────────────────────────────────────────────────
--   前提 · 函数是 DEFINER、authenticated 调得到、而这张表【仍然】没有 UPDATE 策略
--   A · 有 finance.edit ⇒ 一个【过去】的计划日真的落了地
--   B · ★ 一个【未来】的计划日**被接受**(C4 的全部要害)
--   C · NULL ⇒ 撤掉计划,这是一个正当动作,不是一个要被拦的状态
--   D · ★ 反面对照:没有 finance.edit ⇒ **RAISE `PERMISSION_DENIED|module.finance.edit`**
--        且那一行**一个字节都没变**
--   E · ★ 两件事没有合流:同一张卡、同一个未来日期,`set_asset_in_service`
--        **照旧按名拒**(ASSET_IN_SERVICE_IN_FUTURE),而 `in_service_date` 仍是 NULL
--   F · 不存在的卡 ⇒ **RAISE `ASSET_NOT_FOUND`**,不是静默成功
--   G · ★ 同一个会话里,老那条直连 UPDATE 仍然 **0 行**(见上)
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_edit  uuid := gen_random_uuid();   -- module.finance.view + module.finance.edit
    u_view  uuid := gen_random_uuid();   -- ★ 只有 view,【没有】 edit  → D 臂
    r_edit  uuid; r_view uuid;
    v_ccy   text;
    v_asset uuid;
    v_future date := CURRENT_DATE + 180;
    v_past   date := CURRENT_DATE - 30;
    v_got    date;
    v_svc    date;
    v_rows   bigint;
    v_raised boolean; v_msg text;
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;

    INSERT INTO auth.users (id) VALUES (u_edit), (u_view);

    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-200-edit','f200','f200',true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_edit,'module.finance.view'), (r_edit,'module.finance.edit');

    -- ★ view 仍然持 module.finance.view —— 于是 D 臂被拒的原因【只能是】没有
    --   编辑权,不能是"连这张卡都读不到"。一臂一件事。
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-200-view','f200','f200',true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_view,'module.finance.view');

    INSERT INTO user_roles (user_id, role_id) VALUES (u_edit,r_edit), (u_view,r_view);

    -- 成本 > 0:E 臂要走到那条 not-future 的守卫触发器上,而 set_asset_in_service
    -- 在它【之前】就会为一张零成本卡按名拒(ASSET_HAS_NO_COST)。那样 E 会
    -- 因为错的理由变绿。
    INSERT INTO fixed_assets (code, description, category, acquisition_date,
                              cost_base, currency, cost_ccy, fx_rate, status,
                              useful_life_months, residual_base)
    VALUES ('ZZ200-FA1','f200 machine','equipment', CURRENT_DATE - 400,
            1000, v_ccy, 1000, 1, 'active', 120, 0)
    RETURNING id INTO v_asset;

    -- ══════════ 前提 ═══════════════════════════════════════════════════════
    -- 【前提一】函数必须是 SECURITY DEFINER。它要是 INVOKER,A 臂会因为
    --   "没有 UPDATE 策略" 而红,而那是在测别的东西。
    IF NOT (SELECT p.prosecdef FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' AND p.proname='set_asset_planned_in_service') THEN
        RAISE EXCEPTION 'FIXTURE 200 前提不成立:set_asset_planned_in_service 不是 SECURITY DEFINER';
    END IF;
    -- 【前提二】authenticated 调得到它,否则每一臂都会因为错的理由变红。
    IF NOT has_function_privilege('authenticated',
            'public.set_asset_planned_in_service(uuid,date)','EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 200 前提不成立:authenticated 没有这支函数的 EXECUTE';
    END IF;
    -- 【前提三】★ 这张表【仍然】没有 UPDATE 策略。
    --   有人哪天补上一条,G 臂就不再是"老门是关的"的证据,而 A 臂的成功
    --   也不再只能来自这支函数 —— 那时这份文件要重写,而不是继续绿着。
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
                AND tablename='fixed_assets' AND cmd IN ('UPDATE','ALL')) THEN
        RAISE EXCEPTION 'FIXTURE 200 前提不成立:fixed_assets 上出现了 UPDATE 策略 '
                        '—— 这支 fixture 的 A 臂与 G 臂从此都证不出原来那句话,请重写它';
    END IF;

    -- ══════════ A · 有 finance.edit ⇒ 过去的计划日落得了地 ═══════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_planned_in_service(v_asset, v_past);
    RESET ROLE;

    SELECT planned_in_service_date INTO v_got FROM fixed_assets WHERE id = v_asset;
    IF v_got IS DISTINCT FROM v_past THEN
        RAISE EXCEPTION 'FIXTURE 200A 失败:有 module.finance.edit 的会话设了 %,表里是 % '
                        '—— 那扇门还是死的', v_past, v_got;
    END IF;

    -- ══════════ B · ★ 未来的计划日【被接受】 ════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_planned_in_service(v_asset, v_future);
    RESET ROLE;

    SELECT planned_in_service_date INTO v_got FROM fixed_assets WHERE id = v_asset;
    IF v_got IS DISTINCT FROM v_future THEN
        RAISE EXCEPTION 'FIXTURE 200B 失败:一个【未来】的计划投用日 % 没有落地(表里是 %)。'
                        '★ 这一列可以在未来,那是它存在的全部理由 —— 若这一臂红了,'
                        '多半是有人把 set_asset_in_service 的 not-future 守卫抄了过来', v_future, v_got;
    END IF;

    -- ══════════ C · NULL ⇒ 撤掉计划 ════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_planned_in_service(v_asset, NULL);
    RESET ROLE;

    SELECT planned_in_service_date INTO v_got FROM fixed_assets WHERE id = v_asset;
    IF v_got IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 200C 失败:撤计划(NULL)之后表里仍然是 % '
                        '—— 计划会变,撤计划是一个正当的动作', v_got;
    END IF;

    -- 给 D 臂一个【可被看见的】起点:先放回那个未来日期。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_asset_planned_in_service(v_asset, v_future);
    RESET ROLE;

    -- ══════════ D · ★★ 反面对照:没有 edit ⇒ 按名拒,且一个字节都没变 ═══════
    v_raised := false; v_msg := NULL;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        PERFORM set_asset_planned_in_service(v_asset, v_past);
    EXCEPTION WHEN OTHERS THEN
        v_raised := true; v_msg := SQLERRM;
    END;
    RESET ROLE;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'FIXTURE 200D 失败:一个【没有 module.finance.edit】的会话没有被拒 '
                        '—— 这支 fixture 的全部意义就是这一格';
    END IF;
    IF v_msg NOT LIKE 'PERMISSION_DENIED|module.finance.edit%' THEN
        RAISE EXCEPTION 'FIXTURE 200D 失败:拒了,但【没有按名拒】。拿到的是「%」。'
                        '★ 屏幕上那句话逐字依赖这个码(refuseFromCoded → refusePermission),'
                        '换一个码就等于把那句拒绝变成一句读不懂的机器话', v_msg;
    END IF;

    SELECT planned_in_service_date INTO v_got FROM fixed_assets WHERE id = v_asset;
    IF v_got IS DISTINCT FROM v_future THEN
        RAISE EXCEPTION 'FIXTURE 200D 失败:被拒的那一次【改动了数据】(现在是 %,应当还是 %)', v_got, v_future;
    END IF;

    -- ══════════ E · ★ 两件事没有合流 ═══════════════════════════════════════
    -- 同一张卡、同一个未来日期:【计划】收了它(B 臂),【事件】必须照旧拒。
    v_raised := false; v_msg := NULL;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        PERFORM set_asset_in_service(v_asset, v_future);
    EXCEPTION WHEN OTHERS THEN
        v_raised := true; v_msg := SQLERRM;
    END;
    RESET ROLE;

    IF NOT v_raised OR v_msg NOT LIKE '%ASSET_IN_SERVICE_IN_FUTURE%' THEN
        RAISE EXCEPTION 'FIXTURE 200E 失败:set_asset_in_service 收下了一个未来的日期(raised=%,「%」)。'
                        '★ 投用是【已经发生的事】。两支函数合流了,而它们是两件事', v_raised, v_msg;
    END IF;

    SELECT in_service_date, planned_in_service_date INTO v_svc, v_got
      FROM fixed_assets WHERE id = v_asset;
    IF v_svc IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 200E 失败:in_service_date 被写成了 % '
                        '—— set_asset_planned_in_service 一个字节都不许写它', v_svc;
    END IF;
    IF v_got IS DISTINCT FROM v_future THEN
        RAISE EXCEPTION 'FIXTURE 200E 失败:计划日被 set_asset_in_service 那一次连累了(现在 %)', v_got;
    END IF;

    -- ══════════ F · 不存在的卡 ⇒ 按名拒 ════════════════════════════════════
    v_raised := false; v_msg := NULL;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        PERFORM set_asset_planned_in_service(gen_random_uuid(), v_past);
    EXCEPTION WHEN OTHERS THEN
        v_raised := true; v_msg := SQLERRM;
    END;
    RESET ROLE;

    IF NOT v_raised OR v_msg NOT LIKE 'ASSET_NOT_FOUND%' THEN
        RAISE EXCEPTION 'FIXTURE 200F 失败:一张不存在的卡没有按名拒(raised=%,「%」)', v_raised, v_msg;
    END IF;

    -- ══════════ G · ★★ 老那条直连 UPDATE 仍然 0 行 ═════════════════════════
    -- 这一臂【不是】在测旧代码,它是在测【这支 fixture 自己】:
    -- 角色切换若没生效,这里会是 1 行,而上面每一臂的绿都没有意义。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_edit), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE fixed_assets SET planned_in_service_date = v_past WHERE id = v_asset;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;

    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 200G 失败:直连 UPDATE 改了 % 行。'
                        '★ 要么 SET LOCAL ROLE authenticated 没有生效(于是本文件每一臂都是'
                        '按构造变绿的,什么都没证),要么有人给 fixed_assets 补了一条 UPDATE 策略', v_rows;
    END IF;

    SELECT planned_in_service_date INTO v_got FROM fixed_assets WHERE id = v_asset;
    IF v_got IS DISTINCT FROM v_future THEN
        RAISE EXCEPTION 'FIXTURE 200G 失败:那条 0 行的 UPDATE 居然改了数据(现在 %)', v_got;
    END IF;

    RAISE NOTICE 'FIXTURE 200 全部通过:A 有 finance.edit 则过去的计划日落地 · '
                 'B ★未来的计划日被接受(计划≠事件)· C NULL 撤计划 · '
                 'D ★反面对照 无 edit 者拿到 PERMISSION_DENIED|module.finance.edit 且数据未动 · '
                 'E set_asset_in_service 照旧拒未来日、in_service_date 仍为 NULL · '
                 'F 不存在的卡按名拒 ASSET_NOT_FOUND · '
                 'G ★直连 UPDATE 仍 0 行(角色切换确实生效,以上各臂才算数)';
END $$;
ROLLBACK;

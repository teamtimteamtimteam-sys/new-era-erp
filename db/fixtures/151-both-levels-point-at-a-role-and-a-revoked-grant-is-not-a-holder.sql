-- 151 CHAIN-BUILD-1:两级都指向【角色】,而【一份撤销掉的授权不算一个持有人】
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   A ★ 撤销掉的授权【不算持有人】★ —— 本刀顺手修掉的那个缺陷,单独一臂
--   B 二级按【角色】授权:不在那个角色里的人被拒,在的人能批(两边都要)
--   C 二级角色【没有人持有】→ 开关按名拒
--   D ★ 三种状态必须分得开 ★:没人持有 / 有人但登录不了 / 有能干活的人
--   E R4:角色【看不见金额】→ 开关按名拒(而看得见的那个能开起来)
--   F 两级【互不代顶】(R2):一级的人批不了二级的单,反过来也不行
--
-- 【躲开的陷阱,逐条】
--  (a) 两份实现碰巧一致 —— A/C/E 每一条拒绝都配一条【会成功】的对照,
--      于是"拒了"与"这条路根本走不通"分得开。
--  (b) 目录断言命中注释 —— 不 grep 源码,一律走行为与 pg_catalog。
--  (c) definer 无调用者检查 —— G 臂断言两支新内层函数【authenticated 调不到】。
--  (d) 空集通过 —— 每一处计数都断言【具体的数】,不是"非空"。
--  (e) 什么都没注入的注入 —— 三处注入都先断言【定义真的变了】。
--  (f) 断言为真却没有管辖权 —— D 臂不满足于"计数是 0",它断言
--      **两种 0 给出两条不同的拒绝码**;注入②把中间态那条分支短路掉,
--      断言它退化成"没人持有",而那正是 3c 要防的那次误导。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_live   uuid := gen_random_uuid();   -- 确认过的账号:登录得了
    u_unconf uuid := gen_random_uuid();   -- 【没确认】的账号:登录不了(Choo 的形状)
    u_rev    uuid := gen_random_uuid();   -- 授权被撤销的账号
    r_l1     uuid; r_l2 uuid; r_rev uuid; r_revctl uuid; r_unconf uuid; r_blind uuid; r_empty uuid;
    v_n      integer;
    v_msg    text; v_denied boolean;
    v_def    text; v_inj text;
    v_rdy    jsonb;
BEGIN
    -- ══════════ 布景 ══════════
    -- confirmed_at 是【生成列】(LEAST(email,phone)),所以要设的是 email_confirmed_at。
    INSERT INTO auth.users (id, email_confirmed_at)
      VALUES (u_live, now()), (u_rev, now());
    INSERT INTO auth.users (id) VALUES (u_unconf);      -- ★ 刻意不确认 ★

    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx151-l1','f','f',true) RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx151-l2','f','f',true) RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx151-rev','f','f',true) RETURNING id INTO r_rev;
    -- 【对照角色】与 fx151-rev 只差一件事:这一份授权【没有被撤销】。
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx151-revctl','f','f',true) RETURNING id INTO r_revctl;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx151-unconf','f','f',true) RETURNING id INTO r_unconf;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx151-blind','f','f',true) RETURNING id INTO r_blind;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx151-empty','f','f',true) RETURNING id INTO r_empty;

    -- 看得见金额的四个;fx151-blind 【故意】不给 data.view_prices
    INSERT INTO role_permissions (role_id, permission_code)
      SELECT r, p FROM unnest(ARRAY[r_l1,r_l2,r_rev,r_revctl,r_unconf]) r,
                        unnest(ARRAY['module.purchasing.view','data.view_prices']) p;
    -- 就绪面板要 module.finance.view(它自己查权限)—— 给一级角色带上,
    -- 这样下面那一句 approvals_readiness() 读的是【这个人真的看得到的东西】。
    INSERT INTO role_permissions (role_id, permission_code)
      SELECT r_l1, 'module.finance.view';
    INSERT INTO role_permissions (role_id, permission_code)
      SELECT r_blind, unnest(ARRAY['module.purchasing.view']);
    INSERT INTO role_permissions (role_id, permission_code)
      SELECT r_empty, unnest(ARRAY['module.purchasing.view','data.view_prices']);

    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_live, r_l1), (u_live, r_blind),          -- 能登录的人持有 l1 与 blind
        (u_unconf, r_unconf),                        -- 登录不了的人持有 unconf
        (u_live, r_l2);                              -- 二级也由他持有(分工由 F 臂验)
    -- ★ 一份【已经撤销】的授权 —— A 臂的主角。**它自始至终保持撤销状态。**
    INSERT INTO user_roles (user_id, role_id, revoked_at) VALUES (u_rev, r_rev, now());
    -- ★ 对照:【同一个人】的另一份授权,没有被撤销。两者只差 revoked_at 一件事。
    -- 【为什么用第二个角色,而不是把上面那份改来改去】user_roles 上有
    -- trg_user_roles_last_admin,它在【未撤销 → 已撤销】那一次转换上开火;
    -- 而重建出来的库里【一条 user_roles 都没有】(引导不建授权),
    -- 于是那次转换会撞上 LAST_ADMIN_PROTECTED —— 实测撞到了,gate 因此红过一次。
    -- 换成两份授权就完全不需要那次转换,而且对照更硬:同一个人、同一套权限,
    -- 唯一的差别就是这一份没被撤销。
    INSERT INTO user_roles (user_id, role_id) VALUES (u_rev, r_revctl);

    -- ══════════ A ★ 撤销掉的授权不算持有人(本刀的缺陷修复)★ ══════════
    SELECT count(*) INTO v_n FROM real_role_holders('fx151-rev');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 151A 失败:★ 一份【已撤销】的授权被算成了 % 个持有人 ★ —— 撤销授权的人以为自己已经把这条路关上了,而闸还认它', v_n; END IF;

    -- 【对照:同一个人的另一份【未撤销】授权,必须算 1】——
    -- 没有这一条,上面那个 "0" 可能只是因为这条路根本不通(陷阱 a)。
    SELECT count(*) INTO v_n FROM real_role_holders('fx151-revctl');
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 151A 失败:同一个人的【未撤销】授权应当正好算 1 个持有人,实得 % —— 那说明上面那个 0 证明不了"撤销"这件事,只说明这条路不通', v_n; END IF;

    -- 【而开关也必须为它按名拒】—— 计数对了不等于闸用了它
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_level1_role_code='fx151-rev',
            approval_threshold_base=10000, approval_level2_role_code='fx151-l2', approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_LEVEL1_ROLE_UNHELD|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 151A 失败:只有一份【已撤销】授权的角色不该让开关开起来(实得 %)', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ C 二级角色【没有人持有】→ 按名拒(与一级同形)══════════
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_level1_role_code='fx151-l1',
            approval_threshold_base=10000, approval_level2_role_code='fx151-empty', approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_LEVEL2_ROLE_UNHELD|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 151C 失败:无人持有的【二级】角色不该让开关开起来(实得 %)', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ D ★★ 三种状态必须分得开 ★★ ══════════
    -- 【中间态:角色【有人】,但那个人【登录不了】】
    -- 报成"没有持有人"会把操作的人送去【再授一次权】,而那个角色已经授过了 ——
    -- 再授一次不会改变任何事。这一臂钉的就是那次误导。
    SELECT count(*) INTO v_n FROM real_role_holders('fx151-unconf');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 151D 失败:没确认的账号不该算真持有人,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM user_roles ur JOIN roles r ON r.id=ur.role_id
      WHERE r.code='fx151-unconf' AND ur.revoked_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 151D 失败:这个角色【确实有】一个持有人,总数应当是 1,实得 % —— 没有它,下面那条"两种 0 不一样"就是一句空话', v_n; END IF;

    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_level1_role_code='fx151-unconf',
            approval_threshold_base=10000, approval_level2_role_code='fx151-l2', approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 151D 失败:持有人登录不了时开关不该开起来'; END IF;
    -- ★ 关键:它必须是【中间态那条码】,不是"没人持有"那条 ★
    IF v_msg NOT LIKE 'APPROVALS_LEVEL1_HOLDER_CANNOT_SIGN_IN|%' THEN
        RAISE EXCEPTION 'FIXTURE 151D 失败:★ 两种 0 给出了同一句话 ★ 应报"有人持有但登录不了",实得「%」—— 报成"没有持有人"会把人送去再授一次权,而那不会改变任何事', v_msg; END IF;
    -- 而且它要【点名角色】并带上总数,否则操作的人不知道去看谁
    IF v_msg NOT LIKE '%fx151-unconf%1' THEN
        RAISE EXCEPTION 'FIXTURE 151D 失败:中间态那条拒绝要点名角色并给出持有人总数,实得「%」', v_msg; END IF;

    -- ══════════ E R4:角色看不见金额 → 按名拒 ══════════
    -- fx151-blind 【有】一个能登录的持有人(u_live),所以它过得了零持有人那一关,
    -- 于是这一臂验的确实是金额可见性那一条,不是被前一条挡下来的。
    SELECT count(*) INTO v_n FROM real_role_holders('fx151-blind');
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 151E 失败:fx151-blind 应当有 1 个真持有人(否则这一臂验的是零持有人那条,不是金额那条),实得 %', v_n; END IF;
    IF role_can_see_amounts('fx151-blind') THEN
        RAISE EXCEPTION 'FIXTURE 151E 失败:fx151-blind 不该看得见金额'; END IF;
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_level1_role_code='fx151-blind',
            approval_threshold_base=10000, approval_level2_role_code='fx151-l2', approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVALS_LEVEL1_ROLE_CANNOT_SEE_AMOUNTS|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 151E 失败:看不见金额的角色不该当审批人(实得 %)', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ B/F 【会成功】的那一臂 —— 少了它,一个"永远不许开"的实现全绿 ══════════
    UPDATE finance_settings SET approval_level1_role_code='fx151-l1',
        approval_threshold_base=10000, approval_level2_role_code='fx151-l2', approvals_enabled=true;
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'FIXTURE 151B 失败:两级都配好、都有真持有人、都看得见金额时,开关应当开得起来'; END IF;

    -- 二级【按角色】授权:在角色里的人过得了
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_live), true);
    PERFORM require_approver_for(2::smallint);   -- u_live 在 fx151-l2 里 → 不该抛

    -- 不在那个角色里的人【被拒】,而且拒绝要点名级别与角色
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_unconf), true);
    v_denied := false;
    BEGIN PERFORM require_approver_for(2::smallint);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVAL_NOT_AUTHORISED|2|fx151-l2'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 151B 失败:不在二级角色里的人不该批得了二级(实得 %)', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ★ F(R2):一份【已撤销】的授权也批不了 —— 授权那一侧此前同样没滤 revoked_at
    INSERT INTO user_roles (user_id, role_id, revoked_at) VALUES (u_unconf, r_l2, now());
    v_denied := false;
    BEGIN PERFORM require_approver_for(2::smallint);
    EXCEPTION WHEN OTHERS THEN v_denied := (SQLERRM LIKE 'APPROVAL_NOT_AUTHORISED|2|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 151F 失败:★ 一份【已撤销】的授权批得了单 ★ —— 授权那一侧也必须读同一份持有人定义'; END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_live), true);

    -- ══════════ G(陷阱 c)两支新内层函数,authenticated 必须【调不到】══════════
    IF has_function_privilege('authenticated', 'public.real_role_holders(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 151G 失败:real_role_holders 对 authenticated 仍可执行 —— 它是 definer 且没有调用者检查,靠的就是调不到'; END IF;
    IF has_function_privilege('authenticated', 'public.role_can_see_amounts(text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 151G 失败:role_can_see_amounts 对 authenticated 仍可执行'; END IF;

    -- ══════════ 就绪面板读的是同一份判据(屏幕与闸不许各说各话)══════════
    v_rdy := approvals_readiness();
    IF (v_rdy->>'level2_role_code') <> 'fx151-l2'
       OR (v_rdy->>'level2_real_holders')::int <> 1
       OR (v_rdy->>'level1_real_holders')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 151 失败:就绪面板与闸对不上 —— %', v_rdy; END IF;

    -- ══════════ 注入① 撤销那一条判据(证明 A 臂有管辖权)══════════
    UPDATE finance_settings SET approvals_enabled=false, approval_level1_role_code=NULL,
        approval_threshold_base=NULL, approval_level2_role_code=NULL;
    v_def := pg_get_functiondef('public.real_role_holders(text)'::regprocedure);
    v_inj := replace(v_def, 'AND ur.revoked_at IS NULL', 'AND (ur.revoked_at IS NULL OR true)');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 151 注入① 失败:没找到 revoked_at 那一句 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    SELECT count(*) INTO v_n FROM real_role_holders('fx151-rev');
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 151 注入① 失败:短路掉撤销判据之后,那个角色应当【又】变成 1 个持有人,实得 % —— 说明 A 臂断的不是这一条', v_n; END IF;
    EXECUTE v_def;
    SELECT count(*) INTO v_n FROM real_role_holders('fx151-rev');
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 151 注入① 失败:恢复定义之后应当又是 0'; END IF;

    -- ══════════ 注入② 中间态那条分支(证明 D 臂有管辖权,陷阱 f)══════════
    -- 把"有人持有但登录不了"那条分支短路掉,断言它退化成"没有持有人" ——
    -- 一条只断言"开关开不起来"的 D 臂,是察觉不到这次退化的。
    v_def := pg_get_functiondef('public.guard_approvals_switch()'::regprocedure);
    v_inj := replace(v_def, 'IF v_total > 0 THEN', 'IF false THEN');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 151 注入② 失败:没找到中间态那条分支 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_level1_role_code='fx151-unconf',
            approval_threshold_base=10000, approval_level2_role_code='fx151-l2', approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'APPROVALS_LEVEL1_ROLE_UNHELD|%' THEN
        RAISE EXCEPTION 'FIXTURE 151 注入② 失败:短路掉中间态之后,它应当退化成"没有持有人"那条码,实得「%」—— 说明 D 臂断的不是那条分支', COALESCE(v_msg,'(没有报错)'); END IF;
    EXECUTE v_def;

    -- 恢复之后必须【又】说得出中间态 —— 否则"放回去了"只是一句话
    v_denied := false;
    BEGIN
        UPDATE finance_settings SET approval_level1_role_code='fx151-unconf',
            approval_threshold_base=10000, approval_level2_role_code='fx151-l2', approvals_enabled=true;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'APPROVALS_LEVEL1_HOLDER_CANNOT_SIGN_IN|%' THEN
        RAISE EXCEPTION 'FIXTURE 151 注入② 失败:恢复定义之后应当又报中间态,实得「%」', COALESCE(v_msg,'(没有报错)'); END IF;

    -- ══════════ 注入③ 金额可见性(证明 E 臂有管辖权)══════════
    v_def := pg_get_functiondef('public.role_can_see_amounts(text)'::regprocedure);
    v_inj := replace(v_def, 'SELECT EXISTS (', 'SELECT true OR EXISTS (');
    IF v_inj = v_def THEN
        RAISE EXCEPTION 'FIXTURE 151 注入③ 失败:没找到那一句 —— 这个注入什么也没删'; END IF;
    EXECUTE v_inj;
    IF NOT role_can_see_amounts('fx151-blind') THEN
        RAISE EXCEPTION 'FIXTURE 151 注入③ 失败:注入之后它应当对任何角色都说"看得见"'; END IF;
    EXECUTE v_def;
    IF role_can_see_amounts('fx151-blind') THEN
        RAISE EXCEPTION 'FIXTURE 151 注入③ 失败:恢复定义之后 fx151-blind 应当又是看不见'; END IF;

    -- 收尾:把链恢复成【没有配】的样子(本刀不配置任何东西)
    UPDATE finance_settings SET approvals_enabled=false, approval_level1_role_code=NULL,
        approval_threshold_base=NULL, approval_level2_role_code=NULL;
END $$;
ROLLBACK;

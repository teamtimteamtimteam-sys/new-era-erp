-- 27 只有一个模块权限的人,恰好看见那一个模块 —— 不多,不少
--
-- 为什么值得常设(OPS-15):导航条与首页卡片从 lib/modules.ts 过滤,过滤读的是
-- current_user_permissions()。这份 fixture 钉住那个函数【逐码精确】:多给一个码,
-- 那个人就看见一个他进不去的入口;少给一个码,他就丢掉一个本该属于他的模块,
-- 而丢掉的样子与"这个模块还没建"一模一样。
--
-- 【这是可见性断言,所以每次读都切数据库角色】(README 第 6 条)。
-- current_user_permissions() 走 user_roles → role_permissions 两张【开了 RLS】的表,
-- 而 fixture 以 postgres 跑、绕过 RLS —— 不切角色的话,一个"看得见什么"的断言
-- 会在两种实现下都通过。fixture 26 的 A/C 两臂正是这么空转过。
--
-- 【为什么断言的是权限码而不是页面】页面是 TSX,fixture 够不着。但界面的过滤谓词
-- 就是这一个函数的返回值(lib/moduleAccess.ts:perms.includes(m.permission)),
-- 所以钉住函数,就钉住了"他看见几个入口"。UI 那一侧由 npm run build + 路由冒烟守。
BEGIN;
DO $$
DECLARE
    v_one  uuid := gen_random_uuid();   -- 只有 module.inbound.view
    v_none uuid := gen_random_uuid();   -- 一个模块权限都没有(live 的 employee 就是这样)
    r_one uuid; r_none uuid;
    v_perms text[];
    v_modules text[];
    v_n int;
BEGIN
    -- ── 角色:自建,不借引导角色(README)────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-27-one', 'f', 'f', true) RETURNING id INTO r_one;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_one, 'module.inbound.view');

    -- 【空角色是有意义的用例,不是退化用例】live 的 employee 角色恰好是零模块权限,
    -- 而 OPS-15 之前他看得见全部 13 个入口、每一页都渲染成空表。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-27-none', 'f', 'f', true) RETURNING id INTO r_none;

    INSERT INTO user_roles (user_id, role_id) VALUES (v_one, r_one), (v_none, r_none);

    -- ══════════ A. 一个模块权限 → 恰好一个模块入口 ══════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_one), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_perms := current_user_permissions();
    RESET ROLE;

    -- 只留 module.<x>.view —— 界面的过滤谓词就是拿这些码去比对 lib/modules.ts
    SELECT COALESCE(array_agg(p ORDER BY p), '{}')
      INTO v_modules
      FROM unnest(v_perms) p
     WHERE p LIKE 'module.%.view';

    IF v_modules <> ARRAY['module.inbound.view'] THEN
        RAISE EXCEPTION 'FIXTURE 27A 失败:只授了 module.inbound.view,模块码应恰为 {module.inbound.view},实得 % —— 多一个就是多一个进不去的入口,少一个就是丢了一个本该看见的模块',
            v_modules::text;
    END IF;

    -- 断言【它确实什么都没多给】:整份权限码就只有这一个
    IF array_length(v_perms, 1) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 27A 失败:整份权限码应只有 1 个,实得 % 个(%)',
            array_length(v_perms, 1), v_perms::text;
    END IF;

    -- ══════════ B. 零模块权限 → 零入口(而不是"全部入口 + 空表")═══════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_perms := current_user_permissions();
    RESET ROLE;

    SELECT count(*) INTO v_n FROM unnest(v_perms) p WHERE p LIKE 'module.%.view';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 27B 失败:没有任何授权的角色应得到 0 个模块码,实得 % 个(%)',
            v_n, v_perms::text;
    END IF;

    -- ══════════ C. 授第二个码 → 恰好多出那一个,别的不动 ═════════════════════
    -- 【为什么要这一臂】A 单独看,一个"永远只返回第一个码"的实现也能通过。
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_one, 'module.finance.view');

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_one), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    v_perms := current_user_permissions();
    RESET ROLE;

    SELECT COALESCE(array_agg(p ORDER BY p), '{}')
      INTO v_modules
      FROM unnest(v_perms) p
     WHERE p LIKE 'module.%.view';

    IF v_modules <> ARRAY['module.finance.view', 'module.inbound.view'] THEN
        RAISE EXCEPTION 'FIXTURE 27C 失败:再授 module.finance.view 后应恰为 {finance, inbound} 两个,实得 %',
            v_modules::text;
    END IF;
END $$;
ROLLBACK;

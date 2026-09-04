-- 191 一条不属于任何人的授权,顶替不了最后一个管理员
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这一份存在】guard_last_admin 防的是【一次点击造成的不可逆状态】:
-- 撤到零个管理员,从此谁也改不了权限,包括系统的主人,只能直连数据库救。
-- 而 C-1 之前,那个守卫数"还剩几个管理员"时只 JOIN 了 user_roles × roles ——
-- **它从不看 auth.users**。于是一条【幽灵授权】(user_id 在 auth.users 里
-- 根本不存在)可以顶替最后一个真管理员:撤销真人的那一刻守卫说"还有一个",
-- 而那一个谁也解析不出来。
--
-- 【这不是假想的形状】docs/known-issues.md 的 GHOST-GRANTS 记着三次复发,
-- 66 → 21 → 8 条,产地(smoke-routes.mjs:1313)今天仍然开着。
--
-- 【为什么必须造一个幽灵来证明,而不能等它自己出现】线上此刻幽灵授权 0 条
-- (实测 2026-09-04),所以这个缺陷在今天的数据上【不会触发】——
-- 一条"今天不会红"的修复,如果没有一份自带案发现场的断言,
-- 与没有修是分不清的。所以这里【自己造一个幽灵】。
--
-- 【每一臂钉什么】
-- A 【旧判据会放行】用旧判据(user_roles × roles,不看 auth.users)当场算一遍:
--   排除掉真人那一行之后,幽灵顶上了 → 它回答"还有管理员" → 撤销会被放行。
--   ★ 这一臂就是故障注入:它证明这个缺陷【真的存在过】,
--     而不是让人相信一句"修好了"。两个判据【在同一份数据上】各算一次,
--     答案相反 —— 那个相反,就是这一刀改掉的全部东西。
-- B 【新判据拒绝】同一份数据,real_role_grants 数不上幽灵 → "没有别的管理员"。
-- C 【守卫真的抛】不是只比较两个布尔量,而是真的去撤一次那条真授权,
--   断言它抛 LAST_ADMIN_PROTECTED。**判据与守卫是两回事,两个都要钉。**
-- D 【未确认的账号同样顶不上】Tim 的裁定(Q9)是采用 real_role_holders 的
--   【四条】判据,而不是只问"有没有 auth.users 行"。这一臂钉的正是那个差别:
--   一个【存在但未确认】的账号 —— 线上 chef1949@126.com 就是这个形状 ——
--   在"有没有行"的弱判据下算数,在四条判据下不算数。
-- E 【守卫没有变成"永远拒绝"】一道只会拒的闸,与一道拦不住的闸一样坏。
--   给出第二个【真的】管理员之后,同一次撤销必须成功。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
    r_admin      uuid;
    v_real       uuid := gen_random_uuid();   -- 真人:有 auth.users 行且已确认
    v_real2      uuid := gen_random_uuid();   -- 第二个真人,E 臂用
    v_ghost      uuid := gen_random_uuid();   -- 幽灵:【没有】auth.users 行
    v_unconf     uuid := gen_random_uuid();   -- 存在但【未确认】的账号
    g_real       uuid;
    old_says_safe  boolean;
    new_says_safe  boolean;
    unconf_counts  boolean;
    v_err        text;
BEGIN
    SELECT id INTO r_admin FROM roles
     WHERE code = 'admin' AND is_system AND is_active AND deleted_at IS NULL;
    IF r_admin IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 191 前提不成立:重建库里没有在册启用的 is_system 角色 admin';
    END IF;

    -- 真人一名,持 admin。这是"最后一个管理员"。
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (v_real, now());
    INSERT INTO user_roles (user_id, role_id) VALUES (v_real, r_admin)
        RETURNING id INTO g_real;

    -- ══════════ 前提:让 g_real 成为【唯一】的真管理员 ═══════════════════
    -- 【为什么需要这一步,而它一开始不在这里】本 fixture 由 db/gate.py 跑在
    -- 【重建库】上,那里 user_roles 是空的,所以"g_real 是唯一的管理员"自动成立。
    -- 但同一份文件对着【线上】跑时不成立:线上已经有 Tim 的 admin 授权,
    -- 于是撤销 g_real 【真的】是安全的,B/C/D 三臂会全部失败 ——
    -- **而那是 fixture 的前提没建好,不是守卫坏了**。实测撞到过一次(2026-09-04)。
    -- 所以把前提【显式建出来】:把其它所有在册的 admin 授权先撤掉。
    -- 这一步本身走的就是守卫(此刻 g_real 在场,是个真管理员,所以放行)——
    -- 顺带证明了守卫不是"永远拒绝"。整段事务最后回滚,线上一行不动。
    PERFORM 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id
      WHERE r.is_system AND ur.revoked_at IS NULL AND ur.id <> g_real;
    UPDATE user_roles ur SET revoked_at = now(), revoke_reason = 'fixture 191 precondition'
      FROM roles r
     WHERE r.id = ur.role_id AND r.is_system
       AND ur.revoked_at IS NULL AND ur.id <> g_real;

    -- 幽灵一条:授权指向 admin,而 user_id 在 auth.users 里【不存在】。
    -- (user_roles.user_id 没有指向 auth.users 的外键 —— 那正是幽灵长得出来的原因,
    --  见 GHOST-GRANTS;所以这一行插得进去。)
    INSERT INTO user_roles (user_id, role_id) VALUES (v_ghost, r_admin);

    -- ══════════ A:旧判据在同一份数据上会【放行】—— 缺陷的案发现场 ══════════
    SELECT EXISTS (
        SELECT 1
          FROM user_roles ur
          JOIN roles r ON r.id = ur.role_id
         WHERE ur.id <> g_real
           AND ur.revoked_at IS NULL
           AND r.is_system AND r.is_active AND r.deleted_at IS NULL
    ) INTO old_says_safe;

    IF NOT old_says_safe THEN
        RAISE EXCEPTION 'FIXTURE 191 A 臂失败:旧判据【应当】在这份数据上回答"还有管理员"(那正是缺陷)。它没有 —— 说明这份 fixture 没有真的重建出案发现场,后面几臂因此证不了任何事';
    END IF;

    -- ══════════ B:新判据在【同一份数据】上拒绝 ═══════════════════════════
    SELECT EXISTS (
        SELECT 1
          FROM roles r
          CROSS JOIN LATERAL real_role_grants(r.code) g
         WHERE r.is_system AND r.is_active AND r.deleted_at IS NULL
           AND g.grant_id <> g_real
    ) INTO new_says_safe;

    IF new_says_safe THEN
        RAISE EXCEPTION 'FIXTURE 191 B 臂失败:新判据仍然把幽灵数成了一个管理员 —— real_role_grants 没有起作用';
    END IF;

    -- ══════════ C:守卫【真的】抛,不只是判据算得对 ════════════════════════
    BEGIN
        UPDATE user_roles SET revoked_at = now(), revoke_reason = 'fixture 191'
         WHERE id = g_real;
        v_err := 'NO_EXCEPTION';
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLERRM;
    END;

    IF v_err <> 'LAST_ADMIN_PROTECTED' THEN
        RAISE EXCEPTION 'FIXTURE 191 C 臂失败:撤销最后一个【真】管理员时,守卫应当抛 LAST_ADMIN_PROTECTED,实得「%」—— 幽灵仍然顶得上最后一个管理员', v_err;
    END IF;

    -- ══════════ D:【存在但未确认】的账号同样顶不上 ═════════════════════════
    -- 弱判据("有没有 auth.users 行")在这里会算数,四条判据不算数。
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (v_unconf, NULL);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_unconf, r_admin);

    SELECT EXISTS (
        SELECT 1
          FROM roles r
          CROSS JOIN LATERAL real_role_grants(r.code) g
         WHERE r.is_system AND r.is_active AND r.deleted_at IS NULL
           AND g.grant_id <> g_real
    ) INTO unconf_counts;

    IF unconf_counts THEN
        RAISE EXCEPTION 'FIXTURE 191 D 臂失败:一个【未确认】的账号被数成了管理员。Tim 的裁定是采用 real_role_holders 的四条判据(未撤销/已确认/未封禁/未删除),而不是只问"有没有 auth.users 行"';
    END IF;

    BEGIN
        UPDATE user_roles SET revoked_at = now(), revoke_reason = 'fixture 191 D'
         WHERE id = g_real;
        v_err := 'NO_EXCEPTION';
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLERRM;
    END;

    IF v_err <> 'LAST_ADMIN_PROTECTED' THEN
        RAISE EXCEPTION 'FIXTURE 191 D 臂失败:一个未确认账号 + 一个幽灵在场时,守卫仍应抛 LAST_ADMIN_PROTECTED,实得「%」', v_err;
    END IF;

    -- ══════════ E:守卫没有变成"永远拒绝" ══════════════════════════════════
    -- 第二个【真的】管理员到场,同一次撤销必须成功。
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (v_real2, now());
    INSERT INTO user_roles (user_id, role_id) VALUES (v_real2, r_admin);

    BEGIN
        UPDATE user_roles SET revoked_at = now(), revoke_reason = 'fixture 191 E'
         WHERE id = g_real;
        v_err := 'REVOKED';
    EXCEPTION WHEN OTHERS THEN
        v_err := SQLERRM;
    END;

    IF v_err <> 'REVOKED' THEN
        RAISE EXCEPTION 'FIXTURE 191 E 臂失败:在场还有第二个【真的】管理员时,撤销应当成功,实得「%」—— 一道只会拒的闸与一道拦不住的闸一样坏', v_err;
    END IF;

    RAISE NOTICE 'fixture 191 ✓ 幽灵与未确认账号都顶不上最后一个管理员;第二个真管理员在场时撤销照常放行';
END $$;

ROLLBACK;

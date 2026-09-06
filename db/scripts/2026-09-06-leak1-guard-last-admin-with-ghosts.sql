-- db/scripts/2026-09-06-leak1-guard-last-admin-with-ghosts.sql
-- LEAK-1:【28 条幽灵授权在场时,guard_last_admin 还拦得住吗】—— 整支回滚,一行都不留。
--
-- 跑法(ON_ERROR_STOP=1 是判据的一半,不能省):
--     psql "$DSN" -X -v ON_ERROR_STOP=1 -f db/scripts/2026-09-06-leak1-guard-last-admin-with-ghosts.sql
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★【为什么要问这一句,而且是【现在】问】★
--
-- LEAK-1 实测(2026-09-06):线上 **28 条未撤销的 admin 授权,其中 27 条是幽灵**
-- (user_id 在 auth.users 里不存在)。**真的管理员只有一个:admin@swm-os.test。**
-- 也就是说,原始表上的"管理员数量"这个数字,今天比事实【大 28 倍】,
-- 而 C-1b 之前的 guard_last_admin 数的正是那个原始数字。
--
-- 于是这道闸此刻是【唯一】站在"撤掉最后一个真管理员"与"没有人改得了权限"之间的东西。
-- 而这正是它必须被【当场实测】而不是被推理的理由:C-1b 的 fixture 191 证明的是
-- **重建库上**的行为,本脚本问的是 **今天的线上、带着这 28 条** 还成不成立。
--
-- ★【判据必须是一次 RAISE,不是一个返回值】★ 被闸挡住的写不会"返回 false" ——
--   它抛异常。所以 A 臂用 BEGIN/EXCEPTION 捕获,并且【没抛才算失败】:
--   一个"读返回值"的写法在这里只会拿到 NULL,而 NULL 与通过在屏幕上一模一样。
--
-- ★【两臂,因为一道只会拒的闸与一道拦不住的闸一样坏】★
--   A:只有一个真管理员时,撤销【必须】被拒(证明 27 条幽灵顶不上)。
--   B:在场第二个【真】管理员时,同一次撤销【必须】成功(证明它不是逢撤必拒)。
--   只跑 A 的话,一个 `RAISE EXCEPTION 'LAST_ADMIN_PROTECTED'` 写死在函数头上
--   也能让它变绿 —— 那种闸挡住的是所有人,包括正当的撤销。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
    v_ghosts      int;
    v_real        int;
    v_grant       uuid;
    v_admin_role  uuid;
    v_fake_user   uuid := gen_random_uuid();
    v_raised      boolean := false;
BEGIN
    SELECT id INTO v_admin_role FROM roles WHERE code = 'admin';

    SELECT count(*) INTO v_ghosts
      FROM user_roles ur
     WHERE ur.revoked_at IS NULL
       AND ur.role_id = v_admin_role
       AND NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = ur.user_id);

    SELECT count(*) INTO v_real FROM real_role_grants('admin') g;
    RAISE NOTICE '现场:admin 授权里幽灵 % 条,真的数得上 % 条', v_ghosts, v_real;
    IF v_ghosts = 0 THEN
        RAISE EXCEPTION '本脚本【无效】:一条幽灵都没有,那么 A 臂证明不了"幽灵顶不上" —— 它会因为别的原因通过';
    END IF;

    -- ★【为什么这里要先【收敛到一个】,而不是断言"本来就只有一个"】★
    --   第一版写的是 `IF v_real <> 1 THEN RAISE`,而它当场红了:实测 3 个。
    --   查明原因不是缺陷,是【测量口径】—— real_role_grants 把**一次性探针账号**
    --   也数了进去(当时线上有一个 survey-* 的遗留,外加一支正在跑的 probe-button-tiers)。
    --   也就是说这个数会随"此刻有没有探针在跑"而变,把它写成前提,
    --   这个脚本就只在没有探针跑的时候才跑得起来 —— 那是一条会被绕过去的判据。
    --
    --   ★ 真正持久的那一个是 admin@swm-os.test;其余都是用完即删的。
    --     所以本脚本【自己把局面收敛成"只剩一个真管理员"】:按 granted_at 最早的
    --     那一条留下(持久的那个),其余真授权全部撤掉。整支回滚,线上一行不变。
    SELECT g.grant_id INTO v_grant
      FROM real_role_grants('admin') g
      JOIN user_roles ur ON ur.id = g.grant_id
     ORDER BY ur.granted_at ASC LIMIT 1;

    UPDATE user_roles SET revoked_at = now()
     WHERE id IN (SELECT g.grant_id FROM real_role_grants('admin') g WHERE g.grant_id <> v_grant);

    SELECT count(*) INTO v_real FROM real_role_grants('admin') g;
    IF v_real <> 1 THEN
        RAISE EXCEPTION '收敛失败:本该只剩 1 个真管理员,实际 %', v_real;
    END IF;
    RAISE NOTICE '已收敛到 1 个真管理员(其余真授权在本事务内撤掉,回滚后原样)';

    -- ── A 臂:唯一的真管理员,撤销必须被拒 ─────────────────────────────────
    BEGIN
        UPDATE user_roles SET revoked_at = now() WHERE id = v_grant;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%LAST_ADMIN_PROTECTED%' THEN
            v_raised := true;
        ELSE
            RAISE;                      -- 别的错误不算通过,原样抛出去
        END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'A 臂【红】:在 % 条幽灵在场的情况下,撤销唯一的真管理员被【放行】了 —— 幽灵顶上了最后一个管理员', v_ghosts;
    END IF;
    RAISE NOTICE 'A 臂 ✓ 撤销唯一的真管理员被拒(LAST_ADMIN_PROTECTED)—— % 条幽灵一条都没顶上', v_ghosts;

    -- ── B 臂:补一个【真】管理员之后,同一次撤销必须成功 ───────────────────
    -- 判据「真」= real_role_grants 的四条(未撤销 / 已确认 / 未封禁 / 未删除),
    -- 所以这个账号要 email_confirmed_at 有值。整支事务会回滚,它不会留下。
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at, updated_at,
                            instance_id, aud, role)
    VALUES (v_fake_user, 'leak1-probe@test.invalid', now(), now(), now(),
            '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated');
    INSERT INTO user_roles (user_id, role_id) VALUES (v_fake_user, v_admin_role);

    SELECT count(*) INTO v_real FROM real_role_grants('admin') g;
    IF v_real <> 2 THEN
        RAISE EXCEPTION 'B 臂设置失败:补了一个真管理员之后应当是 2 个,实际 %', v_real;
    END IF;

    UPDATE user_roles SET revoked_at = now() WHERE id = v_grant;     -- 这一次必须过
    RAISE NOTICE 'B 臂 ✓ 第二个【真】管理员在场时,同一次撤销照常成功 —— 这道闸不是逢撤必拒';

    RAISE NOTICE '两臂都过 —— guard_last_admin 在 28 条幽灵在场时仍然只数真的持有人(C-1b 成立)';
END $$;

-- ★ 一行都不留。本脚本【只读结论,不改线上】。
ROLLBACK;

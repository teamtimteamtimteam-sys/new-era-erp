-- 192 没有编辑权的角色,是被【数据库】拒绝的,不是被一个藏起来的按钮拒绝的
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么这一份存在】C-1b 把 Tim 裁定的设置权限矩阵落到了实处。而一份"应用了"
-- 的矩阵有两种,长得一模一样:
--   ① 界面不画那个按钮,而数据库照样让写 —— **一次直连 REST 就穿过去了**;
--   ② 数据库真的拒。
-- 委托书的原话:「PROVE IT, DO NOT ASSERT IT ... not merely that a button is
-- hidden」。所以这一份【不碰界面】,它以某个角色的身份直接对库动手。
--
-- ★【它必须两个方向都断言,否则它证不了任何事】★
--   一份只断言"被拒"的证明,可以靠【拒绝一切】通过 —— 比如策略写错成永远 false,
--   或者 fixture 忘了给会话装上 claims。所以每一格都配一个【正对照】:
--   同一次写入,换成【持有那个码】的角色,必须成功。
--   Tim 的裁定:「A proof that passes by refusing everything is not a proof.」
--
-- 【四张"会静默弄坏数据"的屏,逐个钉】(委托书点名的那四张)
--   A 角色本身      roles 表的 RLS —— action.manage_permissions
--   B 角色的授权    set_role_permissions() —— action.manage_permissions
--   C 批量导入      master_import_apply() —— action.bulk_import
--   D 字典          laboratories / inbound_source_reasons 的 RLS
--                   ★ 这一格正是 C-1b 那支迁移改的东西:
--                     从 module.inbound.edit 抬到 module.materials.edit。
--
-- 【会话怎么造】set_config('request.jwt.claims', …) + SET LOCAL ROLE authenticated。
-- 【为什么每个角色都要一个 auth.users 行】employees.user_id 有指向 auth.users 的
--   外键,而 has_permission() 走 auth.uid() → user_roles;造一个真的账号行最稳。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
    r_editor uuid;   -- 持有全部相关编辑码的角色(正对照)
    r_weak   uuid;   -- 一个码都不持有的角色(负对照)
    u_editor uuid := gen_random_uuid();
    u_weak   uuid := gen_random_uuid();
    v_err    text;
    v_n      int;
BEGIN
    -- ── 两个角色、两个账号 ─────────────────────────────────────────────
    INSERT INTO auth.users (id, email_confirmed_at) VALUES (u_editor, now()), (u_weak, now());

    INSERT INTO roles (code, name_en, name_zh, is_active)
      VALUES ('fixture-192-editor', 'f', 'f', true) RETURNING id INTO r_editor;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_editor, unnest(ARRAY[
        'action.manage_permissions', 'action.bulk_import',
        'module.materials.edit', 'module.materials.view']);

    -- 【负对照【刻意】持有 module.inbound.edit】—— 这正是 warehouse 的形状。
    -- 迁移之前,这个角色【写得进】那两张字典;迁移之后它必须被拒。
    INSERT INTO roles (code, name_en, name_zh, is_active)
      VALUES ('fixture-192-weak', 'f', 'f', true) RETURNING id INTO r_weak;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_weak, unnest(ARRAY[
        'module.inbound.edit', 'module.inbound.view']);

    INSERT INTO user_roles (user_id, role_id) VALUES (u_editor, r_editor), (u_weak, r_weak);

    -- ══════════════ D 字典 —— 负:inbound.edit 【不再】够 ══════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_weak), true);
    SET LOCAL ROLE authenticated;

    v_err := NULL;
    BEGIN
        INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order)
        VALUES ('FX192-LAB', 'f', 'f', true, 999);
        v_err := 'NO_EXCEPTION';
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err <> '42501' THEN
        RAISE EXCEPTION 'FIXTURE 192 D-负 失败:只持 module.inbound.edit 的角色【仍然】建得出实验室(得到「%」,期望 42501)—— C-1b 的迁移没有真的生效,界面上的只读就只是一个藏起来的按钮', v_err;
    END IF;

    v_err := NULL;
    BEGIN
        UPDATE inbound_source_reasons SET requires_explanation = NOT requires_explanation;
        -- UPDATE 命中 0 行【不算被拒】:USING 假会让它安静地改 0 行。
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_err := CASE WHEN v_n = 0 THEN 'ZERO_ROWS' ELSE 'NO_EXCEPTION' END;
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err NOT IN ('42501', 'ZERO_ROWS') THEN
        RAISE EXCEPTION 'FIXTURE 192 D-负 失败:只持 module.inbound.edit 的角色【仍然】翻得动 requires_explanation(得到「%」)', v_err;
    END IF;

    RESET ROLE;

    -- ══════════════ D 字典 —— 正:materials.edit 够 ═══════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_editor), true);
    SET LOCAL ROLE authenticated;

    v_err := NULL;
    BEGIN
        INSERT INTO laboratories (code, name_en, name_zh, is_active, sort_order)
        VALUES ('FX192-LAB', 'f', 'f', true, 999);
        v_err := 'OK';
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 192 D-正 失败:持 module.materials.edit 的角色【应当】建得出实验室,实得「%」—— 一道只会拒的闸与一道拦不住的闸一样坏', v_err;
    END IF;

    RESET ROLE;

    -- ══════════════ A roles 表 —— 负 / 正 ════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_weak), true);
    SET LOCAL ROLE authenticated;
    v_err := NULL;
    BEGIN
        INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-192-sneak', 'f', 'f', true);
        v_err := 'NO_EXCEPTION';
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE;
    END;
    IF v_err <> '42501' THEN
        RAISE EXCEPTION 'FIXTURE 192 A-负 失败:没有 action.manage_permissions 的角色建得出一个新角色(得到「%」)', v_err;
    END IF;
    RESET ROLE;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_editor), true);
    SET LOCAL ROLE authenticated;
    v_err := NULL;
    BEGIN
        INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-192-ok', 'f', 'f', true);
        v_err := 'OK';
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 192 A-正 失败:持 action.manage_permissions 的角色【应当】建得出角色,实得「%」', v_err;
    END IF;
    RESET ROLE;

    -- ══════════════ B set_role_permissions —— 负 / 正 ════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_weak), true);
    SET LOCAL ROLE authenticated;
    v_err := NULL;
    BEGIN
        PERFORM set_role_permissions(r_weak, ARRAY['module.finance.view']);
        v_err := 'NO_EXCEPTION';
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err NOT LIKE 'PERMISSION_DENIED|action.manage_permissions%' THEN
        RAISE EXCEPTION 'FIXTURE 192 B-负 失败:set_role_permissions 应当按名拒 PERMISSION_DENIED|action.manage_permissions,实得「%」', v_err;
    END IF;
    RESET ROLE;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_editor), true);
    SET LOCAL ROLE authenticated;
    v_err := NULL;
    BEGIN
        PERFORM set_role_permissions(r_weak, ARRAY['module.finance.view']);
        v_err := 'OK';
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 192 B-正 失败:持码的角色【应当】改得动授权,实得「%」', v_err;
    END IF;
    RESET ROLE;

    -- ══════════════ C master_import_apply —— 负 / 正 ═════════════════
    -- 【只钉那道门】不喂真数据:这里要证的是"没有 action.bulk_import 的人进不了这扇门",
    -- 而不是导入本身对不对(那是 IMPORT-1 的 fixture 的事)。
    -- 所以正对照断言的是【不是权限错】,而不是"导入成功"。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_weak), true);
    SET LOCAL ROLE authenticated;
    v_err := NULL;
    BEGIN
        PERFORM master_import_apply('materials', '[]'::jsonb);
        v_err := 'NO_EXCEPTION';
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err NOT LIKE 'PERMISSION_DENIED|action.bulk_import%' THEN
        RAISE EXCEPTION 'FIXTURE 192 C-负 失败:master_import_apply 应当按名拒 PERMISSION_DENIED|action.bulk_import,实得「%」', v_err;
    END IF;
    RESET ROLE;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', u_editor), true);
    SET LOCAL ROLE authenticated;
    v_err := NULL;
    BEGIN
        PERFORM master_import_apply('materials', '[]'::jsonb);
        v_err := 'OK';
    EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
    END;
    IF v_err LIKE 'PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 192 C-正 失败:持 action.bulk_import 的角色【不该】撞上权限错,实得「%」—— 这一格证明上面那次拒是【因为码】,不是因为这扇门对谁都关着', v_err;
    END IF;
    RESET ROLE;

    RAISE NOTICE 'fixture 192 ✓ 四扇门各钉两个方向:没有码的被库拒,有码的照常通过';
END $$;

ROLLBACK;

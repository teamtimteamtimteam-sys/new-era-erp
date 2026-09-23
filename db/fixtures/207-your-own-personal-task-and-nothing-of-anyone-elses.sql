-- 207 自己的私人任务,以及【别人的一样都碰不到】(APR-4,Tim 2026-09-23 · Q4–Q7)
--
-- 裁定:没有 module.tasks.edit 的人(今天是 gm 只读的 Vince)可以建、改【自己的私人任务】;
-- 自己的任务 = task_type = 'personal' AND owner_id = current_user_employee()(task_is_own)。
-- 例外允许:建(被强制为自己的私人任务)· 改表头与状态 · 步骤增改勾删 · 软删。
-- 例外不允许:升级为团队任务 · 加参与者 · 改归属人;仍然要 module.tasks.view。
-- 对【每一个人】:新建任务的归属人必须是自己;归属人不许改。
--
-- ⚠ 每一次读写都在 SET LOCAL ROLE authenticated 之下,并且【同一块里】先证明
--   current_user = authenticated 且 auth.uid() 就是那个人 —— fixture 以 postgres 跑,
--   而 postgres 绕过 RLS,也让三支守卫(row_security_active)整个让路。
--   不切角色,下面每一条"被拒"都是空的(fixture 26 的教训)。
--
-- 臂:
--   P  前提:只读者真的【只】持 view(持码的并集按人算,APR-3 §5.1)
--   O1–O4 例外走得通:建 · 改表头与状态 · 步骤增改勾删 · 软删
--   X1–X6 例外之外一律按名拒:建团队任务 · 升级 · 加参与者 · 改归属人 ·
--         改别人的团队任务(他【是】参与者)与它的步骤 · 替别人建任务
--   E1–E3 对编辑人也成立:替别人建 → 拒;改归属人 → 拒;
--         不在上面的团队任务 → TASK_NOT_EDITABLE,【不是】静默零行
--   E4 对照:完整编辑人一样都没丢(建团队任务 · 升级 · 加参与者)
--   N  连 view 都不持的人:建与改都按名拒
--   V  看板那两列(may_write / may_manage)与守卫同一个判据
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_view uuid := gen_random_uuid();   -- 只持 module.tasks.view(Vince 的形状)
    u_ed   uuid := gen_random_uuid();   -- view + edit
    u_ed2  uuid := gen_random_uuid();   -- view + edit,不在 u_ed 的团队任务上
    u_none uuid := gen_random_uuid();   -- 任务模块一个码都没有
    r_view uuid; r_ed uuid;
    e_view uuid; e_ed uuid; e_ed2 uuid; e_none uuid;
    v_own uuid; v_own2 uuid; v_team uuid; v_edpriv uuid; v_node uuid; v_tmp uuid;
    v_n integer; v_msg text; v_b1 boolean; v_b2 boolean;
BEGIN
    -- ── 账号 / 角色 / 员工 ────────────────────────────────────────────────
    INSERT INTO auth.users (id) VALUES (u_view),(u_ed),(u_ed2),(u_none);

    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-207-view','f207','f207',true) RETURNING id INTO r_view;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_view,'module.tasks.view');
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-207-edit','f207','f207',true) RETURNING id INTO r_ed;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_ed,'module.tasks.view'), (r_ed,'module.tasks.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_view,r_view), (u_ed,r_ed), (u_ed2,r_ed);

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ207-VIEW','Fixture 207 Viewer','full_time','office','2025-01-01', u_view) RETURNING id INTO e_view;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ207-ED','Fixture 207 Editor','full_time','office','2025-01-01', u_ed) RETURNING id INTO e_ed;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ207-ED2','Fixture 207 Editor Two','full_time','office','2025-01-01', u_ed2) RETURNING id INTO e_ed2;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ207-NONE','Fixture 207 Nobody','full_time','office','2025-01-01', u_none) RETURNING id INTO e_none;

    -- ══════════ P 前提 ══════════════════════════════════════════════════════
    SELECT count(*) INTO v_n FROM user_roles WHERE user_id = u_view AND revoked_at IS NULL;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 207P 前提不成立:只读者持 % 个角色 —— 按人求并集,他可能从别处拿到了 edit', v_n; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_view), true);
    IF has_permission('module.tasks.edit') OR NOT has_permission('module.tasks.view') THEN
        RAISE EXCEPTION 'FIXTURE 207P 前提不成立:只读者的权限不是"只有 view"';
    END IF;

    -- 编辑人的团队任务(只读者【是】参与者 —— Vince 在 TASK-2026-0006 上的形状)
    -- 与编辑人的私人任务。以 postgres + 编辑人的 claims 建:这是【布景】,不是被测对象。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ed), true);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ207 editor team', 'team') RETURNING id INTO v_team;
    INSERT INTO task_participants (task_id, employee_id, added_by) VALUES (v_team, e_view, e_ed);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ207 editor private', 'personal') RETURNING id INTO v_edpriv;
    INSERT INTO task_nodes (task_id, title, sort_order) VALUES (v_team, 'ZZ207 team step', 1024);

    -- ══════════ O1 只读者建自己的私人任务 ═══════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN
        RAISE EXCEPTION 'FIXTURE 207 对照失败:角色切换没有生效(current_user=%)', current_user;
    END IF;
    v_msg := NULL;
    BEGIN
        INSERT INTO tasks (title, task_type) VALUES ('ZZ207 my todo', 'personal') RETURNING id INTO v_own;
        INSERT INTO tasks (title) VALUES ('ZZ207 my todo 2') RETURNING id INTO v_own2;   -- 类型取默认值
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 207O1 失败:只读者建自己的私人任务被拒:%', v_msg; END IF;
    IF (SELECT owner_id FROM tasks WHERE id = v_own) IS DISTINCT FROM e_view THEN
        RAISE EXCEPTION 'FIXTURE 207O1 失败:新建的任务没有归到只读者自己名下';
    END IF;

    -- ══════════ O2 改表头与状态 ═════════════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'FIXTURE 207 对照失败'; END IF;
    v_msg := NULL; v_n := 0;
    BEGIN
        UPDATE tasks SET title = 'ZZ207 my todo edited', status = 'in_progress', priority = 'high' WHERE id = v_own;
        GET DIAGNOSTICS v_n = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 207O2 失败:只读者改自己的私人任务被拒:%', v_msg; END IF;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 207O2 失败:只读者改不动自己的私人任务(实改 % 行)', v_n; END IF;

    -- ══════════ O3 步骤:增 · 改 · 勾 · 删 ══════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'FIXTURE 207 对照失败'; END IF;
    v_msg := NULL;
    BEGIN
        INSERT INTO task_nodes (task_id, title, sort_order) VALUES (v_own, 'ZZ207 step', 1024) RETURNING id INTO v_node;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    IF v_msg IS NOT NULL THEN RESET ROLE; RAISE EXCEPTION 'FIXTURE 207O3 失败:只读者往自己的任务加步骤被拒:%', v_msg; END IF;
    UPDATE task_nodes SET title = 'ZZ207 step renamed' WHERE id = v_node;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 1 THEN RESET ROLE; RAISE EXCEPTION 'FIXTURE 207O3 失败:改不动自己任务上的步骤'; END IF;
    UPDATE task_nodes SET done = true WHERE id = v_node;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 1 THEN RESET ROLE; RAISE EXCEPTION 'FIXTURE 207O3 失败:勾不了自己任务上的步骤'; END IF;
    DELETE FROM task_nodes WHERE id = v_node;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RESET ROLE;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 207O3 失败:删不了自己任务上的步骤(实删 % 行)', v_n; END IF;

    -- ══════════ O4 软删 ═════════════════════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'FIXTURE 207 对照失败'; END IF;
    UPDATE tasks SET deleted_at = now() WHERE id = v_own2;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RESET ROLE;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 207O4 失败:只读者软删不了自己的私人任务(实改 % 行)', v_n; END IF;

    -- ══════════ X1 建团队任务 ═══════════════════════════════════════════════
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        INSERT INTO tasks (title, task_type) VALUES ('ZZ207 x1', 'team');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207X1 失败:只读者建团队任务,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;

    -- ══════════ X2 升级自己的私人任务 ═══════════════════════════════════════
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        PERFORM promote_task_to_team(v_own);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207X2 失败:只读者升级自己的任务,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;
    IF (SELECT task_type FROM tasks WHERE id = v_own) <> 'personal' THEN
        RAISE EXCEPTION 'FIXTURE 207X2 失败:任务类型变了';
    END IF;

    -- ══════════ X3 往自己的私人任务上加参与者 ═══════════════════════════════
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        INSERT INTO task_participants (task_id, employee_id, added_by) VALUES (v_own, e_ed2, e_view);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207X3 失败:只读者加参与者,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;

    -- ══════════ X4 改自己任务的归属人 ═══════════════════════════════════════
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        UPDATE tasks SET owner_id = e_ed2 WHERE id = v_own;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS NULL OR v_msg NOT LIKE 'TASK_OWNER_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 207X4 失败:只读者改归属人,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;

    -- ══════════ X5 别人的团队任务(他【是】参与者):表头与步骤都按名拒,【不是】零行 ═══
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        UPDATE tasks SET status = 'done' WHERE id = v_team;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207X5 失败:只读者改别人的团队任务,实得 %', COALESCE(v_msg, '(没有被拒 —— 静默零行?)');
    END IF;
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        INSERT INTO task_nodes (task_id, title, sort_order) VALUES (v_team, 'ZZ207 x5', 2048);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207X5b 失败:只读者往别人的团队任务加步骤,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        UPDATE task_nodes SET done = true WHERE task_id = v_team;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207X5c 失败:只读者勾别人团队任务上的步骤,实得 %', COALESCE(v_msg, '(没有被拒 —— 静默零行?)');
    END IF;

    -- ══════════ X6 替别人建任务 ═════════════════════════════════════════════
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'CONTROL'; END IF;
        INSERT INTO tasks (title, task_type, owner_id) VALUES ('ZZ207 x6', 'personal', e_ed);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'TASK_OWNER_NOT_SELF' THEN
        RAISE EXCEPTION 'FIXTURE 207X6 失败:只读者替别人建任务,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;

    -- ══════════ E1 编辑人替别人建任务(Q6-i:对每一个人) ═══════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ed), true);
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_ed THEN RAISE EXCEPTION 'CONTROL'; END IF;
        INSERT INTO tasks (title, task_type, owner_id) VALUES ('ZZ207 e1', 'personal', e_ed2);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'TASK_OWNER_NOT_SELF' THEN
        RAISE EXCEPTION 'FIXTURE 207E1 失败:编辑人替别人建任务,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;

    -- ══════════ E2 编辑人改自己私人任务的归属人(Q6-ii:对每一个人) ═══════════
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_ed THEN RAISE EXCEPTION 'CONTROL'; END IF;
        UPDATE tasks SET owner_id = e_ed2 WHERE id = v_edpriv;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS NULL OR v_msg NOT LIKE 'TASK_OWNER_IMMUTABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 207E2 失败:编辑人把私人任务转给别人,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;
    IF (SELECT owner_id FROM tasks WHERE id = v_edpriv) IS DISTINCT FROM e_ed THEN
        RAISE EXCEPTION 'FIXTURE 207E2 失败:归属人变了';
    END IF;

    -- ══════════ E3 编辑人改一张【不在上面】的团队任务:具名拒,不是零行 ═══════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ed2), true);
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_ed2 THEN RAISE EXCEPTION 'CONTROL'; END IF;
        UPDATE tasks SET status = 'done' WHERE id = v_team;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS NULL OR v_msg NOT LIKE 'TASK_NOT_EDITABLE|%' THEN
        RAISE EXCEPTION 'FIXTURE 207E3 失败:不在上面的编辑人改团队任务,实得 %', COALESCE(v_msg, '(没有被拒 —— 静默零行?)');
    END IF;

    -- ══════════ E4 对照:完整编辑人一样都没丢 ═══════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_ed2 THEN RAISE EXCEPTION 'FIXTURE 207 对照失败'; END IF;
    INSERT INTO tasks (title, task_type) VALUES ('ZZ207 e4 team', 'team') RETURNING id INTO v_tmp;
    INSERT INTO task_participants (task_id, employee_id, added_by) VALUES (v_tmp, e_ed, e_ed2);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ207 e4 personal', 'personal') RETURNING id INTO v_tmp;
    PERFORM promote_task_to_team(v_tmp);
    RESET ROLE;
    IF (SELECT task_type FROM tasks WHERE id = v_tmp) <> 'team' THEN
        RAISE EXCEPTION 'FIXTURE 207E4 失败:完整编辑人升级不了自己的任务';
    END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ed), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_ed THEN RAISE EXCEPTION 'FIXTURE 207 对照失败'; END IF;
    UPDATE tasks SET status = 'in_progress' WHERE id = v_team;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RESET ROLE;
    IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 207E4 失败:参与者编辑人改不动自己的团队任务(实改 % 行)', v_n; END IF;

    -- ══════════ N 连 view 都不持的人 ════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_none), true);
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_none THEN RAISE EXCEPTION 'CONTROL'; END IF;
        INSERT INTO tasks (title, task_type) VALUES ('ZZ207 n', 'personal');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207N1 失败:无任务权限的人建任务,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;
    v_msg := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_none THEN RAISE EXCEPTION 'CONTROL'; END IF;
        UPDATE tasks SET status = 'done' WHERE id = v_own;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
    END;
    RESET ROLE;
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.tasks.edit' THEN
        RAISE EXCEPTION 'FIXTURE 207N2 失败:无任务权限的人改任务,实得 %', COALESCE(v_msg, '(没有被拒)');
    END IF;

    -- ══════════ V 看板那两列与守卫同一个判据 ═════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_view), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_view THEN RAISE EXCEPTION 'FIXTURE 207 对照失败'; END IF;
    SELECT may_write, may_manage INTO v_b1, v_b2 FROM task_board_rows WHERE id = v_own;
    IF v_b1 IS DISTINCT FROM true OR v_b2 IS DISTINCT FROM false THEN
        RESET ROLE; RAISE EXCEPTION 'FIXTURE 207V1 失败:只读者自己的任务 may_write=% may_manage=%', v_b1, v_b2;
    END IF;
    SELECT may_write, may_manage INTO v_b1, v_b2 FROM task_board_rows WHERE id = v_team;
    IF v_b1 IS DISTINCT FROM false OR v_b2 IS DISTINCT FROM false THEN
        RESET ROLE; RAISE EXCEPTION 'FIXTURE 207V2 失败:别人的团队任务 may_write=% may_manage=%', v_b1, v_b2;
    END IF;
    -- 别人的私人任务:读都读不到(隐私没有因为这一刀变宽)
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_edpriv;
    RESET ROLE;
    IF v_n <> 0 THEN RAISE EXCEPTION 'FIXTURE 207V3 失败:只读者读得到别人的私人任务'; END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ed), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF current_user <> 'authenticated' OR auth.uid() IS DISTINCT FROM u_ed THEN RAISE EXCEPTION 'FIXTURE 207 对照失败'; END IF;
    SELECT may_write, may_manage INTO v_b1, v_b2 FROM task_board_rows WHERE id = v_team;
    RESET ROLE;
    IF v_b1 IS DISTINCT FROM true OR v_b2 IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 207V4 失败:参与者编辑人 may_write=% may_manage=%', v_b1, v_b2;
    END IF;

    RAISE NOTICE 'FIXTURE 207 全部通过: 自己的私人任务建得了改得了(O1–O4) · 例外之外一律按名拒(X1–X6) · '
                 '归属人只能是自己且不许改,对编辑人同样成立(E1–E2) · 不在上面的编辑人得到具名拒绝而不是零行(E3) · '
                 '完整编辑人一样都没丢(E4) · 无权限的人按名拒(N) · 看板两列与守卫同一判据(V)';
END $$;
ROLLBACK;

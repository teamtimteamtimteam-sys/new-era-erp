-- 95 归属在员工空间,而【隐私是在生效的,不是在场的】
--
-- TASK-1c-a 把 tasks.owner_id 从账号空间搬进员工空间,并把 tasks 自己的
-- select/update/delete 三条策略从 has_permission 换成 can_view_task / can_edit_task。
-- 在这一刀之前,任何持 module.tasks.view 的人都读得到【别人的私人任务】——
-- 谓词装在三张子表上,父行没有。所以本 fixture 断言的对象是 `tasks` 自己。
--
-- ⚠️ 每一条可见性断言都 SET LOCAL ROLE authenticated:fixture 以 postgres 跑,
--    而 postgres 绕过 RLS。不切角色,"读不到"这句话是空的(fixture 26 的教训)。
--
-- 【前提先证,否则臂会因为错的理由通过】
--   * authenticated 有这些表的表级权限 —— 否则"0 行"只是没权限;
--   * 那个"另一个人"【确实存在】,而且持有一个【在这一刀之前读得到】的角色 ——
--     所以 B 臂开头把 select 策略临时换回 has_permission,证明他那时读得到,
--     再换回来。少了这一句,"读不到"可能只是"这个人本来就什么都读不到"。
--
-- 臂:
--   A 归属人读得到、改得动自己的私人任务  ← 抓"谓词还在比 auth.uid()"的那一臂
--   B 另一个人【读不到】(B1)、【改不动】(B2),两件事分开断言
--   C 团队任务:非参与者读得到、改不动;参与者改得动
--   D TASK_CREATOR_NOT_AN_EMPLOYEE:INSERT 与 UPDATE 各一次
--   E owner_id 为空的行对【所有人,包括 view_all】不可见不可改
--   F 升级→降级→升级,三个来回,归属人始终【恰好一行】活跃参与者
--   G 重新加入:已退出的归属人行被【复活】,不是插第二行
--   H 生来就是 team 的任务,归属人当场改得动(创建门 c2)
--   I 没有 42P17 策略递归
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_own uuid := gen_random_uuid();
    u_oth uuid := gen_random_uuid();
    u_all uuid := gen_random_uuid();
    u_nob uuid := gen_random_uuid();          -- 有 tasks.edit,没有员工档案
    r_edit uuid; r_all uuid;
    e_own uuid; e_oth uuid;
    v_priv uuid; v_team uuid; v_born uuid; v_null uuid;
    v_n integer; v_rows integer; v_active integer; v_total integer;
    v_pid uuid; v_pid2 uuid; v_what text; v_msg text;
    v_caught boolean; i integer; v_qual text;
    r jsonb := '{}'::jsonb;
BEGIN
    -- ── 账号 / 角色 / 员工 ────────────────────────────────────────────────
    INSERT INTO auth.users (id) VALUES (u_own),(u_oth),(u_all),(u_nob);

    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-95-edit','f95','f95',true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_edit,'module.tasks.view'), (r_edit,'module.tasks.edit');

    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-95-viewall','f95','f95',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_all,'module.tasks.view'), (r_all,'module.tasks.edit'), (r_all,'module.tasks.view_all');

    INSERT INTO user_roles (user_id, role_id)
        VALUES (u_own,r_edit), (u_oth,r_edit), (u_nob,r_edit), (u_all,r_all);

    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ95-OWN','Fixture 95 Owner','full_time','office','2025-01-01', u_own) RETURNING id INTO e_own;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ95-OTH','Fixture 95 Other','full_time','office','2025-01-01', u_oth) RETURNING id INTO e_oth;
    -- u_nob 【故意没有】员工档案 —— D 臂用它
    -- u_all 也没有,但它只做读,不建任务

    -- ══════════ 前提 0:表级权限在 ══════════════════════════════════════════
    IF NOT (has_table_privilege('authenticated','public.tasks','SELECT')
        AND has_table_privilege('authenticated','public.tasks','UPDATE')
        AND has_table_privilege('authenticated','public.tasks','INSERT')) THEN
        RAISE EXCEPTION 'FIXTURE 95 前提不成立:authenticated 缺少 tasks 的表级权限 —— 那样每一条"读不到"都会因为错的理由通过';
    END IF;
    r := r || jsonb_build_object('P0_table_privs', 'ok');

    -- ── 建一张私人任务(归属人自己建)──────────────────────────────────────
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ95 private', 'personal') RETURNING id INTO v_priv;

    IF (SELECT owner_id FROM tasks WHERE id = v_priv) <> e_own THEN
        RAISE EXCEPTION 'FIXTURE 95 前提不成立:owner_id 的默认值没有解析成员工 id —— 用例没搭对';
    END IF;
    r := r || jsonb_build_object('P1_default_is_employee_space', 'ok');

    -- ══════════ A. 归属人读得到、改得动自己的私人任务 ═══════════════════════
    -- 【这一臂是专门抓"谓词还在比 auth.uid()"的】:owner_id 已经是员工 id,
    -- 谓词若仍写 t.owner_id = auth.uid(),这里当场变成 0 行。
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_priv;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95A1 失败:归属人读不到自己的私人任务(实得 % 行)—— 谓词多半还在比 auth.uid()', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE tasks SET title = 'ZZ95 private edited' WHERE id = v_priv;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95A2 失败:归属人改不动自己的私人任务(实改 % 行)', v_rows;
    END IF;
    r := r || jsonb_build_object('A_owner_sees_and_edits_own_private', 'ok');

    -- ══════════ B 的前提:这个"另一个人"【在这一刀之前读得到】 ═══════════════
    -- 临时把 select 策略换回 has_permission(= 1c-a 之前那条),证明他那时读得到。
    -- 少了这一句,B1 的"读不到"可能只是"他本来就什么都读不到"。
    SELECT pg_get_expr(polqual, polrelid) INTO v_qual FROM pg_policy
     WHERE polrelid = 'public.tasks'::regclass AND polname = 'tasks select by predicate';
    IF v_qual IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 95 前提不成立:取不到 select 策略的原始定义 —— 无法原样还原';
    END IF;
    DROP POLICY "tasks select by predicate" ON public.tasks;
    CREATE POLICY "tasks select by permission" ON public.tasks
        FOR SELECT USING (has_permission('module.tasks.view'));

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_oth), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_priv;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95B 前提不成立:换回旧策略后另一个人仍读不到(实得 % 行)—— 那 B1 证明不了任何事', v_n;
    END IF;
    r := r || jsonb_build_object('B_premise_other_could_read_before', 'ok');

    -- 【把原来那条【原样】装回去,不是照一份写死的定义重建】。
    -- 第一版就是重建的,于是这段"搭前提"的代码把注入进来的坏策略【修好了】——
    -- 注入 1 因此没有咬住,fixture 绿着放它过去。一段会修好被测对象的前提代码,
    -- 让这条臂【永远不可能失败】,那正是本仓库反复点名的那种假绿。
    DROP POLICY "tasks select by permission" ON public.tasks;
    EXECUTE format('CREATE POLICY %I ON public.tasks FOR SELECT USING (%s)',
                   'tasks select by predicate', v_qual);

    -- ══════════ B1. 另一个人【读不到】 ══════════════════════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_priv;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 95B1 失败:别人的私人任务【读得到】(实得 % 行)', v_n;
    END IF;

    -- ══════════ B2. 另一个人【改不动】 —— 与 B1 分开断言 ════════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE tasks SET title = 'ZZ95 hijacked' WHERE id = v_priv;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 95B2 失败:别人的私人任务【改得动】(实改 % 行)', v_rows;
    END IF;
    r := r || jsonb_build_object('B_other_cannot_see_or_edit', 'ok');

    -- ══════════ C. 团队任务:非参与者读得到、改不动;参与者改得动 ════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ95 team', 'team') RETURNING id INTO v_team;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_oth), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_team;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95C1 失败:非参与者读不到团队任务(实得 % 行)', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE tasks SET title = 'ZZ95 team hijacked' WHERE id = v_team;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 95C2 失败:非参与者改得动团队任务(实改 % 行)', v_rows;
    END IF;

    -- 归属人是参与者(创建门补的),他改得动
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE tasks SET title = 'ZZ95 team edited by participant' WHERE id = v_team;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95C3 失败:参与者改不动团队任务(实改 % 行)', v_rows;
    END IF;
    r := r || jsonb_build_object('C_team_visible_to_all_editable_by_participant', 'ok');

    -- ══════════ D. TASK_CREATOR_NOT_AN_EMPLOYEE:INSERT 与 UPDATE 各一次 ═════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_nob), true);
    v_caught := false;
    BEGIN
        INSERT INTO tasks (title, task_type) VALUES ('ZZ95 no employee', 'personal');
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_caught := true;
    END;
    IF NOT v_caught OR v_msg NOT LIKE 'TASK_CREATOR_NOT_AN_EMPLOYEE%' THEN
        RAISE EXCEPTION 'FIXTURE 95D1 失败:没有员工档案的人建任务没有按名拒绝(caught=%,msg=%)', v_caught, v_msg;
    END IF;

    -- UPDATE 那一侧:把一行的 owner_id 打成 NULL,同样要按名拒绝
    v_caught := false;
    BEGIN
        UPDATE tasks SET owner_id = NULL WHERE id = v_priv;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_caught := true;
    END;
    IF NOT v_caught OR v_msg NOT LIKE 'TASK_CREATOR_NOT_AN_EMPLOYEE%' THEN
        RAISE EXCEPTION 'FIXTURE 95D2 失败:把 owner_id 改成 NULL 没有按名拒绝(caught=%,msg=%)', v_caught, v_msg;
    END IF;
    r := r || jsonb_build_object('D_named_refusal_on_insert_and_update', 'ok');

    -- ══════════ E. owner_id 为空的行:对所有人不可见不可改,含 view_all ══════
    -- 【只能这样搭】:守卫现在拦住任何写出 NULL 归属的路,所以先临时摘掉它,
    -- 造一行遗留形状,再装回来 —— 整个 fixture 回滚,线上一刻也不处于这个状态。
    DROP TRIGGER trg_tasks_owner_required ON public.tasks;
    INSERT INTO tasks (title, task_type, owner_id) VALUES ('ZZ95 orphan', 'personal', NULL) RETURNING id INTO v_null;
    CREATE TRIGGER trg_tasks_owner_required
        BEFORE INSERT OR UPDATE ON public.tasks
        FOR EACH ROW EXECUTE FUNCTION public.trg_tasks_owner_required();

    -- 【前提】在这一刀之前,一个普通的高权限读者读得到它 —— 换回旧策略证一次。
    SELECT pg_get_expr(polqual, polrelid) INTO v_qual FROM pg_policy
     WHERE polrelid = 'public.tasks'::regclass AND polname = 'tasks select by predicate';
    IF v_qual IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 95 前提不成立:取不到 select 策略的原始定义 —— 无法原样还原';
    END IF;
    DROP POLICY "tasks select by predicate" ON public.tasks;
    CREATE POLICY "tasks select by permission" ON public.tasks
        FOR SELECT USING (has_permission('module.tasks.view'));
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_oth), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_null;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95E 前提不成立:换回旧策略后仍读不到无主任务(实得 % 行)', v_n;
    END IF;
    -- 【把原来那条【原样】装回去,不是照一份写死的定义重建】。
    -- 第一版就是重建的,于是这段"搭前提"的代码把注入进来的坏策略【修好了】——
    -- 注入 1 因此没有咬住,fixture 绿着放它过去。一段会修好被测对象的前提代码,
    -- 让这条臂【永远不可能失败】,那正是本仓库反复点名的那种假绿。
    DROP POLICY "tasks select by permission" ON public.tasks;
    EXECUTE format('CREATE POLICY %I ON public.tasks FOR SELECT USING (%s)',
                   'tasks select by predicate', v_qual);

    -- E1:普通高权限读者(view+edit,【不持】view_all)读不到、改不动。
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_null;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 95E1 失败:无主任务对普通高权限读者仍然可见(实得 % 行)', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE tasks SET title = 'ZZ95 orphan touched' WHERE id = v_null;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 95E1 失败:无主任务被改动了(实改 % 行)', v_rows;
    END IF;

    -- E2:【持 view_all 的人读得到 —— 这是有意的,把它钉住而不是假装它不存在】。
    -- view_all 是一把点名的钥匙(默认没有任何角色持有),它在 can_view_task 里
    -- 是一条 OR;它【不在】can_edit_task 里,所以读得到仍然改不动。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM tasks WHERE id = v_null;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95E2 失败:view_all 是一把读的钥匙,它应当读得到无主任务(实得 % 行)', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE tasks SET title = 'ZZ95 orphan touched by viewall' WHERE id = v_null;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 95E2 失败:持 view_all 的人改动了无主任务(实改 % 行)—— view_all 只是读的钥匙', v_rows;
    END IF;
    r := r || jsonb_build_object('E_null_owner_unreadable_without_viewall_and_uneditable_by_all', 'ok');

    -- ══════════ F. 升级→降级→升级,三个来回,始终恰好一行活跃 ═══════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);
    FOR i IN 1..3 LOOP
        UPDATE tasks SET task_type = 'team'     WHERE id = v_priv;
        UPDATE tasks SET task_type = 'personal' WHERE id = v_priv;
    END LOOP;
    UPDATE tasks SET task_type = 'team' WHERE id = v_priv;

    SELECT count(*) INTO v_active FROM task_participants
     WHERE task_id = v_priv AND employee_id = e_own AND removed_at IS NULL;
    SELECT count(*) INTO v_total FROM task_participants
     WHERE task_id = v_priv AND employee_id = e_own;
    IF v_active <> 1 OR v_total <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95F 失败:三个来回之后归属人的参与者行 活跃=% 总数=%(都应为 1)', v_active, v_total;
    END IF;
    r := r || jsonb_build_object('F_promote_demote_promote_reentrant', 'ok');

    -- ══════════ G. 重新加入:已退出的那一行被【复活】,不是插第二行 ══════════
    -- 【搭法说明】:用 INSERT 直接造一行 removed_at 非空的记录,而不是把活跃行
    -- 改成已退出 —— 后者正好命中 TASK_OWNER_CANNOT_LEAVE(归属人不能退出自己的
    -- 任务),那条守卫是对的,不该为了搭用例去动它。
    INSERT INTO tasks (title, task_type) VALUES ('ZZ95 rejoin', 'personal') RETURNING id INTO v_born;
    INSERT INTO task_participants (task_id, employee_id, added_by, removed_at, removed_by)
        VALUES (v_born, e_own, e_own, now(), e_own) RETURNING id INTO v_pid;

    UPDATE tasks SET task_type = 'team' WHERE id = v_born;

    SELECT count(*) INTO v_total FROM task_participants WHERE task_id = v_born AND employee_id = e_own;
    SELECT id INTO v_pid2 FROM task_participants
     WHERE task_id = v_born AND employee_id = e_own AND removed_at IS NULL;
    IF v_total <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95G 失败:重新加入插了第二行(总数 %)—— 应当复活原来那一行', v_total;
    END IF;
    IF v_pid2 IS DISTINCT FROM v_pid THEN
        RAISE EXCEPTION 'FIXTURE 95G 失败:活跃的那一行不是原来那一行(原 %,现 %)', v_pid, v_pid2;
    END IF;
    r := r || jsonb_build_object('G_removed_owner_is_reactivated_not_duplicated', 'ok');

    -- ══════════ H. 创建门:生来就是 team,归属人当场改得动 ═══════════════════
    -- 【前提先证】摘掉 (c2) 之后,同样的插入产生一张【归属人写不进 task_nodes】
    -- 的任务 —— 那正是 TASK-2026-0007 在线上的样子。用嵌套 savepoint,
    -- 不能用外层 EXCEPTION:那会把整个块结束掉,后面的臂与报告全部不跑。
    DROP TRIGGER trg_tasks_team_owner_participant ON public.tasks;
    INSERT INTO tasks (title, task_type) VALUES ('ZZ95 born team no door', 'team') RETURNING id INTO v_born;

    v_caught := false;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        INSERT INTO task_nodes (task_id, title, sort_order) VALUES (v_born, 'ZZ95 step', 1024);
        RESET ROLE;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_caught := true;
        RESET ROLE;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'FIXTURE 95H 前提不成立:摘掉创建门之后归属人竟然写得进 task_nodes —— 那 H 证明不了任何事';
    END IF;
    -- 【拒绝必须是 RLS 那一种】,不是别的错。行级策略拒插入时 PostgreSQL 抛
    -- 42501 "new row violates row-level security policy"。
    IF v_msg NOT LIKE '%row-level security%' THEN
        RAISE EXCEPTION 'FIXTURE 95H 前提可疑:拒绝不是 RLS 那一种,而是:%', v_msg;
    END IF;
    r := r || jsonb_build_object('H_premise_without_door_owner_is_rls_refused', 'ok');

    -- 装回创建门,再来一次:这一次必须写得进去。
    CREATE TRIGGER trg_tasks_team_owner_participant
        AFTER INSERT ON public.tasks
        FOR EACH ROW EXECUTE FUNCTION public.trg_tasks_team_owner_participant();

    INSERT INTO tasks (title, task_type) VALUES ('ZZ95 born team with door', 'team') RETURNING id INTO v_born;
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO task_nodes (task_id, title, sort_order) VALUES (v_born, 'ZZ95 step ok', 1024);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95H 失败:生来就是 team 的任务,归属人写不进步骤(实写 % 行)', v_rows;
    END IF;
    SELECT count(*) INTO v_active FROM task_participants
     WHERE task_id = v_born AND employee_id = e_own AND removed_at IS NULL;
    IF v_active <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 95H 失败:创建门没有把归属人置为活跃参与者(活跃 % 行)', v_active;
    END IF;
    r := r || jsonb_build_object('H_born_team_is_immediately_editable_by_owner', 'ok');

    -- ══════════ I. 没有 42P17 策略递归 ══════════════════════════════════════
    -- tasks 自己的策略现在调 can_view_task/can_edit_task,而它们的函数体又读 tasks。
    -- 之所以不递归:两个函数是 SECURITY DEFINER、属主是 postgres(表属主),
    -- 而 tasks 没有 FORCE ROW LEVEL SECURITY —— 属主读表不过策略。
    -- 这里【实测】它,而不是只把道理写下来。
    v_caught := false;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        SELECT count(*) INTO v_n FROM tasks;
        PERFORM 1 FROM task_board_rows LIMIT 1;
        RESET ROLE;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM; v_caught := true;
        RESET ROLE;
    END;
    IF v_caught THEN
        RAISE EXCEPTION 'FIXTURE 95I 失败:读 tasks/task_board_rows 报错(可能是 42P17 策略递归):%', v_msg;
    END IF;
    r := r || jsonb_build_object('I_no_policy_recursion', 'ok');

    -- 【gate 跑的 fixture 只在【失败】时抛】:成功必须以 exit 0 收尾。
    -- FIXTURE_REPORT 那套是 Management API 探针的写法,放在这里会让每一次成功都被读成失败。
    RAISE NOTICE 'FIXTURE 95 全部通过:%', r::text;
END $$;
ROLLBACK;

-- 93 步骤:一层嵌套是【表达不出来】的、一次拖动只写一行、看板的派生值只有一处实现、
--    删掉一个步骤之后那条"它被删了"的记录仍然说得出它叫什么
--
-- 五臂,各自钉住 TASK-1a 的一个决定:
--   A 两层以上的嵌套:由【约束】拒绝(不是触发器)——直接插也插不进去
--   B 跨任务认父:同一条复合外键顺手挡掉的另一半,而它正是写触发器的人会漏的那一半
--   C 一次拖动写【一行】历史;整段重排(rebalance)写【零行】
--   D 3/5 只有一处实现:视图给的数与直接数出来的一致;没有截止日/没有带日期的步骤时
--     "步骤排到截止日之后"是 NULL(什么都不说),不是 false(读起来像"一切正常")
--   E 任务硬删按名拒绝;有子步骤的父步骤按名拒绝(绝不 CASCADE);
--     步骤删掉之后,node_removed 那一行仍然记得它的标题
--
-- 【A/B 只有约束这一臂,没有"具名拒绝"那一臂 —— 这是有意的,不是漏了】
-- 具名拒绝住在服务端 action 里,而 action 属于 TASK-1b。1a 只能证明
-- 【底下那道是拦得住的】。1b 落地时补另一臂,那时才分得清是哪一层答的。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_own uuid := gen_random_uuid();
    r_edit uuid; e_own uuid;
    t_team uuid; t_two uuid; t_bare uuid;
    n_top uuid; n_sub uuid; n_a uuid; n_b uuid; n_c uuid; n_plain uuid;
    v_denied boolean; v_msg text; v_n integer; v_hist integer; v_before integer;
    v_cnt integer; v_done integer; v_over boolean;
BEGIN
    INSERT INTO auth.users (id) VALUES (u_own);
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-93','f93','f93',true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_edit,'module.tasks.view'), (r_edit,'module.tasks.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_own, r_edit);
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ93-OWN','Fixture 93 Owner','full_time','office','2025-01-01', u_own) RETURNING id INTO e_own;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);

    INSERT INTO tasks (title, task_type, due_date) VALUES ('ZZ93 team','team', DATE '2026-09-30') RETURNING id INTO t_team;
    -- 【TASK-1c-a 起,归属人这一行由创建门自动补】(trg_tasks_team_owner_participant
    --  → ensure_task_owner_participant)。这里再插一次会撞 uq_task_participants_active。
    INSERT INTO tasks (title, task_type) VALUES ('ZZ93 other team','team') RETURNING id INTO t_two;
    -- 【TASK-1c-a 起,归属人这一行由创建门自动补】(trg_tasks_team_owner_participant
    --  → ensure_task_owner_participant)。这里再插一次会撞 uq_task_participants_active。

    INSERT INTO task_nodes (task_id, title, sort_order) VALUES (t_team,'ZZ93 top',1024) RETURNING id INTO n_top;
    INSERT INTO task_nodes (task_id, parent_id, depth, title, sort_order)
        VALUES (t_team, n_top, 1, 'ZZ93 sub', 1024) RETURNING id INTO n_sub;

    -- ══════════ A. 第三层:插不进去(约束,不是触发器)═════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO task_nodes (task_id, parent_id, depth, title, sort_order)
        VALUES (t_team, n_sub, 1, 'ZZ93 grandchild', 1024);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 93A 失败:建出了第三层 —— 一层嵌套本该是【表达不出来】的,不是靠谁记得拒绝';
    END IF;
    -- depth=1 的父找不到 depth=0 的靶子,所以撞的是那条复合外键
    IF position('foreign key' in lower(v_msg)) = 0 AND position('task_nodes' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 93A 失败:拒绝了,但不是那条复合外键拦的 —— 实得:%', v_msg;
    END IF;

    -- 换一种写法再试一次:depth 谎报成 0(冒充顶层)也不行,
    -- 因为 CHECK((parent_id IS NULL) = (depth = 0)) 管着这一半
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO task_nodes (task_id, parent_id, depth, title, sort_order)
        VALUES (t_team, n_sub, 0, 'ZZ93 liar', 1024);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 93A 失败:把 depth 谎报成 0 就挂到了子步骤下面 —— 两条约束要合起来才封得死';
    END IF;

    -- ══════════ B. 跨任务认父:同一条外键的另一半 ══════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO task_nodes (task_id, parent_id, depth, title, sort_order)
        VALUES (t_two, n_top, 1, 'ZZ93 cross-task child', 1024);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 93B 失败:一个步骤认了【另一张任务】上的父步骤 —— 这一半正是写触发器的人最容易漏掉的';
    END IF;

    -- ══════════ C. 一次拖动写一行;整段重排写零行 ══════════════════════════
    -- 三个【带日期】的步骤,序号故意不是 1024 的倍数,好让 rebalance 真的改动它们
    INSERT INTO task_nodes (task_id, title, target_date, sort_order) VALUES (t_team,'ZZ93 c-a', DATE '2026-09-01', 1) RETURNING id INTO n_a;
    INSERT INTO task_nodes (task_id, title, target_date, sort_order) VALUES (t_team,'ZZ93 c-b', DATE '2026-09-02', 2) RETURNING id INTO n_b;
    INSERT INTO task_nodes (task_id, title, target_date, sort_order) VALUES (t_team,'ZZ93 c-c', DATE '2026-09-03', 3) RETURNING id INTO n_c;
    -- 一个【没有日期】的步骤:挪它不该留下任何记录(顺序只是显示偏好)
    INSERT INTO task_nodes (task_id, title, sort_order) VALUES (t_team,'ZZ93 c-plain', 4) RETURNING id INTO n_plain;

    SELECT count(*) INTO v_before FROM task_history WHERE task_id = t_team AND change_type = 'node_reordered';
    UPDATE task_nodes SET sort_order = 9 WHERE id = n_a;          -- 拖动一个【带日期】的
    SELECT count(*) INTO v_hist FROM task_history WHERE task_id = t_team AND change_type = 'node_reordered';
    IF v_hist - v_before <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 93C 失败:一次拖动写了 % 行 node_reordered —— 稀疏序号的全部用意,就是让那一条陈述【一个动作】,而不是一串被顺带挤动的副作用', v_hist - v_before;
    END IF;

    v_before := v_hist;
    UPDATE task_nodes SET sort_order = 10 WHERE id = n_plain;      -- 拖动一个【没有日期】的
    SELECT count(*) INTO v_hist FROM task_history WHERE task_id = t_team AND change_type = 'node_reordered';
    IF v_hist <> v_before THEN
        RAISE EXCEPTION 'FIXTURE 93C 失败:挪一个没有日期的步骤也记了账 —— 没有日期时顺序只是显示偏好,记下来会把这份记录淹掉';
    END IF;

    -- rebalance:它确实改动了序号(下面自证),但【一行历史都不写】
    SELECT count(*) INTO v_before FROM task_history WHERE task_id = t_team;
    PERFORM rebalance_task_nodes(t_team, NULL);
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = t_team AND parent_id IS NULL AND sort_order % 1024 <> 0;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 93C 前提不成立:rebalance 之后还有 % 个同级步骤的序号不是 1024 的倍数 —— 它没真的重排,那下面那句"零行"证明不了什么', v_n;
    END IF;
    SELECT count(*) INTO v_hist FROM task_history WHERE task_id = t_team;
    IF v_hist <> v_before THEN
        RAISE EXCEPTION 'FIXTURE 93C 失败:整段重排写了 % 行历史 —— 按 1024 重新编号不是对计划的改动,记下来会淹掉它本该保护的东西', v_hist - v_before;
    END IF;

    -- ══════════ D. 派生值只有一处实现 ══════════════════════════════════════
    UPDATE task_nodes SET done = true WHERE id = n_b;
    SELECT node_count, done_count, steps_overrun_due_date INTO v_cnt, v_done, v_over
      FROM task_board_rows WHERE id = t_team;
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = t_team;
    IF v_cnt <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 93D 失败:视图数出 % 个步骤,直接数是 % —— 3/5 必须只有一处实现,否则看板与详情页从写下的第二天开始漂移', v_cnt, v_n;
    END IF;
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = t_team AND done;
    IF v_done <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 93D 失败:视图数出 % 个已完成,直接数是 %', v_done, v_n;
    END IF;
    -- 截止日 2026-09-30,未完成的步骤最晚 09-03 → 没有超出
    IF v_over IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 93D 失败:步骤都在截止日之前,却报出 % —— 这一列是一句陈述,要说得准', COALESCE(v_over::text,'NULL');
    END IF;

    -- 没有截止日的任务:这一列必须是 NULL(什么都不说),不是 false
    INSERT INTO tasks (title, task_type) VALUES ('ZZ93 no due','personal') RETURNING id INTO t_bare;
    INSERT INTO task_nodes (task_id, title, target_date, sort_order) VALUES (t_bare,'ZZ93 dated', DATE '2026-12-31', 1024);
    SELECT steps_overrun_due_date INTO v_over FROM task_board_rows WHERE id = t_bare;
    IF v_over IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 93D 失败:没有截止日的任务报出了 % —— 应当什么都不说;false 在屏幕上读起来像"一切正常"', v_over;
    END IF;

    -- ══════════ E. 删除 ════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        DELETE FROM tasks WHERE id = t_team;
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('TASK_HARD_DELETE_REFUSED' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 93E 失败:任务硬删没有【按名】拒绝 —— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        DELETE FROM task_nodes WHERE id = n_top;      -- 它下面还有 n_sub
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('TASK_NODE_HAS_CHILDREN' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 93E 失败:删一个还有子步骤的父步骤,没有按名拒绝 —— 而 CASCADE 顺手带走一串子步骤正是 AUDEL-1a 堵过的那个洞。实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    -- 子步骤还在(拒绝意味着什么都没动)
    SELECT count(*) INTO v_n FROM task_nodes WHERE id = n_sub;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 93E 失败:拒绝之后子步骤没了 —— "拒绝"必须意味着什么都没写';
    END IF;

    -- 删一个没有子步骤的:成功,而且那条记录记得住它叫什么
    DELETE FROM task_nodes WHERE id = n_c;
    SELECT count(*) INTO v_n FROM task_history
     WHERE task_id = t_team AND change_type = 'node_removed'
       AND node_id = n_c AND old_node_title = 'ZZ93 c-c' AND old_node_target_date = DATE '2026-09-03';
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 93E 失败:步骤删掉之后,那条"它被删了"的记录说不出它叫什么(实得 % 行)—— node_id 特意不加外键,就是为了让这条记录活得比步骤久', v_n;
    END IF;
END $$;
ROLLBACK;

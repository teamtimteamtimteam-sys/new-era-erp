-- 94 类型迁移:升级把归属人【同一个事务】写成参与者;而【排空】一张团队任务
--    永远不会把它变回私人 —— 那条判据取自 task_participants,不取自历史
--
-- 四臂:
--   A 升级:参与者行 + promoted_from_personal 同事务落下;升级后【归属人改得动】
--     (少了那一步,就是一张谁都改不了的行 —— 空集那个老毛病)
--   B 归属人不是在册员工(或没有登录账号)→ 升级按名拒绝,而不是造出一张死任务
--   C 建的时候选错类型:没有别人来过 → 改得回去
--   D 【排空】:加过一个人、又让他退出 → 改不回去,按名拒绝
--
-- 【D 是这份 fixture 存在的理由】。C 与 D 的现场在"当前参与者只剩归属人一个"
-- 这一点上【完全一样】—— 分得开它们的只有"有没有人来过",而那个事实只存在于
-- task_participants 的软删行里。若判据写成"历史为零",C 会因为建表时那条
-- participant_added 而【永远打不开】,D 又会在有人修剪历史之后【重新打开】。
-- 一条建立在"某一行不存在"上的规则,两个方向都会坏。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_own uuid := gen_random_uuid();
    u_p2  uuid := gen_random_uuid();
    u_ghost uuid := gen_random_uuid();      -- 有登录账号,但没有员工档案
    r_edit uuid; e_own uuid; e_p2 uuid;
    t_a uuid; t_b uuid; t_c uuid; t_d uuid;
    v_n integer; v_rows integer; v_msg text; v_denied boolean; v_type text;
BEGIN
    INSERT INTO auth.users (id) VALUES (u_own), (u_p2), (u_ghost);
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-94','f94','f94',true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_edit,'module.tasks.view'), (r_edit,'module.tasks.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_own,r_edit), (u_p2,r_edit), (u_ghost,r_edit);
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ94-OWN','Fixture 94 Owner','full_time','office','2025-01-01', u_own) RETURNING id INTO e_own;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ94-P2','Fixture 94 Second','full_time','shopfloor','2025-01-01', u_p2) RETURNING id INTO e_p2;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);

    -- ══════════ A. 升级 ════════════════════════════════════════════════════
    INSERT INTO tasks (title, task_type) VALUES ('ZZ94 promote me','personal') RETURNING id INTO t_a;
    PERFORM promote_task_to_team(t_a);

    SELECT task_type INTO v_type FROM tasks WHERE id = t_a;
    IF v_type <> 'team' THEN
        RAISE EXCEPTION 'FIXTURE 94A 失败:升级之后 task_type 还是 %', v_type;
    END IF;

    SELECT count(*) INTO v_n FROM task_participants
     WHERE task_id = t_a AND employee_id = e_own AND removed_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 94A 失败:升级没有把归属人写成参与者(% 行)—— 那样这张任务【谁都改不了】,而且不报错', v_n;
    END IF;

    SELECT count(*) INTO v_n FROM task_history
     WHERE task_id = t_a AND change_type = 'promoted_from_personal' AND employee_id = e_own;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 94A 失败:没有写下 promoted_from_personal(% 行)—— 少了它,升级前的沉默读起来像一段缺失的记录', v_n;
    END IF;
    -- 归属人那一行【不】写历史(变更记录记的是改动,不是初始状态)
    SELECT count(*) INTO v_n FROM task_history WHERE task_id = t_a AND change_type = 'participant_added';
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 94A 失败:归属人自己那一行也写了 participant_added(% 行)—— 初始状态不是一次改动', v_n;
    END IF;

    -- 【最要紧的一句】升级完,归属人真的改得动它
    INSERT INTO task_nodes (task_id, title, sort_order) VALUES (t_a,'ZZ94 step',1024);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE task_nodes SET title = 'ZZ94 step edited' WHERE task_id = t_a;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 94A 失败:刚升级的任务连归属人都改不动(实改 % 行)—— 这正是"参与者为零"会造成的那张死任务', v_rows;
    END IF;

    -- ══════════ B. 归属人不再是【在册】员工 → 按名拒绝 ═════════════════════
    -- 【这一臂的搭法被 TASK-1c-a 改了,原因值得写下来】:原来它让一个【没有员工
    -- 档案】的账号去建任务。那条路现在走不通了 —— owner_id 有了外键,而
    -- trg_tasks_owner_required 会在建的时候就按名拒绝(TASK_CREATOR_NOT_AN_EMPLOYEE)。
    -- 于是 TASK_OWNER_NOT_AN_EMPLOYEE 只剩下一条可达路径:**归属人的员工档案
    -- 后来被软删了**(Site A 过滤 e.deleted_at IS NULL)。臂改成那一条 ——
    -- 一个再也到不了的拒绝,断言它就是在断言一句空话。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ94 owner later removed','personal') RETURNING id INTO t_b;
    UPDATE employees SET deleted_at = now() WHERE id = e_own;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM promote_task_to_team(t_b);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('TASK_OWNER_NOT_AN_EMPLOYEE' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 94B 失败:归属人的员工档案已软删时,升级没有按名拒绝 —— 实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    SELECT task_type INTO v_type FROM tasks WHERE id = t_b;
    IF v_type <> 'personal' THEN
        RAISE EXCEPTION 'FIXTURE 94B 失败:拒绝之后类型还是变了(%)—— "拒绝"必须意味着什么都没写', v_type;
    END IF;
    -- 把档案恢复回来:后面几臂还要用同一个人。
    UPDATE employees SET deleted_at = NULL WHERE id = e_own;

    -- ══════════ C. 选错类型:没有别人来过 → 改得回去 ═══════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_own), true);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ94 mis-set','team') RETURNING id INTO t_c;
    -- 【TASK-1c-a 起,归属人这一行由创建门自动补】(trg_tasks_team_owner_participant
    --  → ensure_task_owner_participant)。这里再插一次会撞 uq_task_participants_active。
    PERFORM correct_task_type(t_c);
    SELECT task_type INTO v_type FROM tasks WHERE id = t_c;
    IF v_type <> 'personal' THEN
        RAISE EXCEPTION 'FIXTURE 94C 失败:一张没有别人来过的团队任务改不回私人(现为 %)—— 选错类型发生在建的时候,而"删掉重建"不是一个下拉框敲错的答案', v_type;
    END IF;

    -- ══════════ D. 排空 ≠ 私人 ═════════════════════════════════════════════
    INSERT INTO tasks (title, task_type) VALUES ('ZZ94 drained','team') RETURNING id INTO t_d;
    -- 【TASK-1c-a 起,归属人这一行由创建门自动补】(trg_tasks_team_owner_participant
    --  → ensure_task_owner_participant)。这里再插一次会撞 uq_task_participants_active。
    INSERT INTO task_participants (task_id, employee_id, added_by) VALUES (t_d, e_p2, e_own);
    UPDATE task_participants SET removed_at = now(), removed_by = e_own
     WHERE task_id = t_d AND employee_id = e_p2;

    -- 现在的现场与 C 【一模一样】:当前参与者只剩归属人一个
    SELECT count(*) INTO v_n FROM task_participants
     WHERE task_id = t_d AND removed_at IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 94D 前提不成立:当前参与者应当只剩 1 个(实得 %)—— 用例没搭成"与 C 同样的现场"', v_n;
    END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM correct_task_type(t_d);
    EXCEPTION WHEN OTHERS THEN v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied OR position('TASK_TYPE_LOCKED_PARTICIPANTS' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 94D 失败:一张【被排空的】团队任务改回了私人 —— 那会让来过的人读不到自己参与过的东西。实得:%', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    SELECT task_type INTO v_type FROM tasks WHERE id = t_d;
    IF v_type <> 'team' THEN
        RAISE EXCEPTION 'FIXTURE 94D 失败:拒绝之后类型还是变了(%)', v_type;
    END IF;
END $$;
ROLLBACK;

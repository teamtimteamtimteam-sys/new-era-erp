-- 92 任务的两个谓词:私人任务只有本人写得了、只有本人(或一把点名的钥匙)读得到;
--    团队任务大家读得到、只有【当前】参与者写得了
--
-- TASK-1a 建的东西里,这两个谓词是最重要的一件 —— 在它们之前,任何持
-- module.tasks.edit 的人(线上八个角色)都能读、改、删【别人的私人任务】,
-- 而 owner_id / visibility 这些列名承诺了相反的事。
--
-- 【断言的对象是 task_nodes,不是 tasks —— 这不是取巧,是 1a 的实际边界】
-- TASK-1a 只在【三张新表】上装了这两个谓词;`tasks` 自己的四条策略仍然是
-- has_permission('module.tasks.view'/'edit'),要到 TASK-1c 才换。
-- 本 fixture 第一版直接断言"另一个人读不到那张私人任务",当场红了 ——
-- **而它红得对**:那句话今天还不成立。把它写成绿的唯一诚实办法,是断言
-- 谓词【实际装在哪里】。
-- 顺带,这也是本 fixture 挣到的第一件事:它逼出了一条计划里漏写的活 ——
-- 1c 除了搬 owner_id,还必须把 tasks 的四条策略指到这两个谓词上,
-- 否则谓词写得再对,父行仍然人人可读可改。
--
-- ⚠️【每一条可见性断言都必须 SET LOCAL ROLE authenticated】
-- fixture 以 postgres 跑,而 postgres 绕过 RLS。不切角色的话,"别人读不到"
-- 这句话是空的 —— fixture 26 第一版正是这么绿着放走了一个 xmodule 故障。
-- 本文件里【每一次】读写都切。
--
-- 【一个必须先证的前提:0 行意味着 RLS,不是"没有表权限"】
-- 如果 authenticated 压根没有这张表的 SELECT 权限,读出来也是 0 行,而那会让
-- 这些臂【因为错的理由通过】。所以 A 臂开头先断言表权限在。
--
-- 四臂:
--   A 私人:本人读得到写得了;另一个持 view+edit 的人【读不到】(RLS 拒绝)
--   B view_all:是一把【读】的钥匙,不是写的 —— 读得到,改不动
--   C 团队:非参与者【读得到、改不了】;参与者改得了;前参与者【读得到、改不了】
--   D 没有登录账号的员工,加进参与者按名拒绝
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_owner uuid := gen_random_uuid();
    u_other uuid := gen_random_uuid();
    u_all   uuid := gen_random_uuid();
    u_p2    uuid := gen_random_uuid();
    r_edit uuid; r_all uuid;
    e_owner uuid; e_other uuid; e_p2 uuid; e_nologin uuid;
    v_task uuid; v_team uuid;
    v_n integer; v_rows integer; v_msg text; v_denied boolean;
BEGIN
    -- ── 登录账号(prelude 的 auth.users 只要 id)──────────────────────────
    INSERT INTO auth.users (id) VALUES (u_owner), (u_other), (u_all), (u_p2);

    -- ── 角色:自建,不借引导角色(README)────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-92-edit','f92','f92',true) RETURNING id INTO r_edit;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_edit,'module.tasks.view'), (r_edit,'module.tasks.edit');

    -- 【故意也给 edit】:这样 B 臂的"改不动"证明的是【不是归属人】,
    -- 而不是"少了 module.tasks.edit" —— 两者在结果上都是 0 行。
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-92-viewall','f92','f92',true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_all,'module.tasks.view'), (r_all,'module.tasks.edit'), (r_all,'module.tasks.view_all');

    INSERT INTO user_roles (user_id, role_id)
        VALUES (u_owner,r_edit), (u_other,r_edit), (u_p2,r_edit), (u_all,r_all);

    -- ── 员工:任务这一侧说员工空间,登录账号只在谓词内部解析一次 ──────────
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ92-OWN','Fixture 92 Owner','full_time','office','2025-01-01', u_owner) RETURNING id INTO e_owner;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ92-OTH','Fixture 92 Other','full_time','office','2025-01-01', u_other) RETURNING id INTO e_other;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ92-P2','Fixture 92 Participant','full_time','shopfloor','2025-01-01', u_p2) RETURNING id INTO e_p2;
    -- 车间技工,还没有登录账号 —— D 臂用它
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date)
        VALUES ('ZZ92-NOL','Fixture 92 No Login','full_time','shopfloor','2025-01-01') RETURNING id INTO e_nologin;

    -- ══════════ 前提:authenticated 【有】这些表的权限 ══════════════════════
    -- 少了这一句,下面每一条 "0 行" 都可能只是"没有表权限",而不是 RLS 在挡。
    IF NOT (has_table_privilege('authenticated','public.task_nodes','SELECT')
        AND has_table_privilege('authenticated','public.task_nodes','UPDATE')
        AND has_table_privilege('authenticated','public.task_participants','INSERT')) THEN
        RAISE EXCEPTION 'FIXTURE 92 前提不成立:authenticated 缺少任务表的表级权限 —— 那样下面每一条"读不到"都会因为错的理由通过';
    END IF;

    -- ══════════ A. 私人任务:本人可读可写,另一个人读不到 ═══════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_owner), true);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ92 personal', 'personal') RETURNING id INTO v_task;

    INSERT INTO task_nodes (task_id, title, sort_order) VALUES (v_task, 'ZZ92 personal step', 1024);

    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = v_task;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 92A 前提不成立:归属人自己都读不到自己私人任务的步骤(实得 % 行)—— 用例没搭对', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE task_nodes SET title = 'ZZ92 personal step edited' WHERE task_id = v_task;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 92A 失败:归属人改不了自己私人任务的步骤(实改 % 行)', v_rows;
    END IF;

    -- 另一个人:持 module.tasks.view + edit,但这是【别人的】私人任务
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = v_task;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 92A 失败:另一个持 module.tasks.edit 的人读到了别人私人任务的步骤(% 行)—— 这正是 TASK-1a 之前 tasks 上的实况,八个角色都能读改删', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE task_nodes SET title = 'ZZ92 hijacked' WHERE task_id = v_task;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 92A 失败:另一个人改动了别人私人任务的步骤(实改 % 行)', v_rows;
    END IF;

    -- ══════════ B. view_all 是【读】的钥匙,不是写的 ════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = v_task;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 92B 失败:持 module.tasks.view_all 的人读不到别人私人任务的步骤(% 行)—— 这把钥匙就是为离职者的任务这类事留的', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE task_nodes SET title = 'ZZ92 viewall wrote' WHERE task_id = v_task;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 92B 失败:view_all 让人【写】了别人私人任务的步骤(实改 % 行)—— 它只该是一把读的钥匙;这个读者持有 module.tasks.edit,所以挡住他的必须是"不是归属人"', v_rows;
    END IF;

    -- ══════════ C. 团队任务:大家读得到,只有【当前】参与者写得了 ═══════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_owner), true);
    INSERT INTO tasks (title, task_type) VALUES ('ZZ92 team', 'team') RETURNING id INTO v_team;
    -- 归属人自己那一行(不写历史:变更记录记的是改动,不是初始状态)
    -- 【TASK-1c-a 起,归属人这一行由创建门自动补】(trg_tasks_team_owner_participant
    --  → ensure_task_owner_participant)。这里再插一次会撞 uq_task_participants_active。
    INSERT INTO task_participants (task_id, employee_id, added_by) VALUES (v_team, e_p2, e_owner);
    INSERT INTO task_nodes (task_id, title, sort_order) VALUES (v_team, 'ZZ92 team step', 1024);

    -- 非参与者:读得到
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_other), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = v_team;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 92C 失败:团队任务的步骤对一个非参与者不可见(% 行)—— 私人=只有我看得见,团队=大家看得见、参与者能改', v_n;
    END IF;
    -- 非参与者:改不了
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE task_nodes SET title = 'ZZ92 outsider wrote' WHERE task_id = v_team;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 92C 失败:非参与者改动了团队任务的步骤(实改 % 行)', v_rows;
    END IF;

    -- 参与者:改得了
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_p2), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE task_nodes SET title = 'ZZ92 participant wrote' WHERE task_id = v_team;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 92C 失败:参与者改不了团队任务的步骤(实改 % 行)', v_rows;
    END IF;

    -- 让 p2 退出,再看:读【还在】,写【没了】
    UPDATE task_participants SET removed_at = now(), removed_by = e_owner
     WHERE task_id = v_team AND employee_id = e_p2;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_p2), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM task_nodes WHERE task_id = v_team;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 92C 失败:前参与者读不到自己参与过的任务的步骤(% 行)—— 把他贡献过的东西藏起来读起来像抹掉', v_n;
    END IF;

    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE task_nodes SET title = 'ZZ92 ex-participant wrote' WHERE task_id = v_team;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 92C 失败:已退出的人还改得动这张任务的步骤(实改 % 行)—— 读是,写不是', v_rows;
    END IF;

    -- ══════════ D. 没有登录账号的员工,按名拒绝 ════════════════════════════
    -- 一个在屏幕上"在这件事上"、却打不开它的参与者,是这个仓库已经付过学费的形状
    -- (employees.user_id 那条外键买的是同一件事)。
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO task_participants (task_id, employee_id, added_by)
        VALUES (v_team, e_nologin, e_owner);
    EXCEPTION WHEN OTHERS THEN
        v_denied := true; v_msg := SQLERRM;
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 92D 失败:把一个没有登录账号的员工加成了参与者 —— 他会在屏幕上在这件事上,却永远打不开它';
    END IF;
    IF position('TASK_PARTICIPANT_NO_LOGIN' in v_msg) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 92D 失败:拒绝了,但不是【按名】拒绝的 —— 实得:%', v_msg;
    END IF;
END $$;
ROLLBACK;

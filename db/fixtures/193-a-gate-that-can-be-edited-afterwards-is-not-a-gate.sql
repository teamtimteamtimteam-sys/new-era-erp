-- 193 C-2:【锁 ≠ 关】,而一道过后还能改的关口不是关口
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】
--   A ★ locked_at 冻结打分 ★ —— 被锁住的月份抛 KPI_CYCLE_LOCKED,
--     而【同一条路在解锁之后走得通】(否则"拒了"与"这条路本来就不通"分不开)
--   B ★ 锁与关是【两件事】★ —— 一个 locked 但没 closed 的周期:
--       · 打分被拒(冻结了)
--       · 而分数【仍然】对本人不可见(揭晓归 status,不归锁)
--     这一臂正是这一刀存在的理由:原本一个 flag 干两件事,表达不了 Tim 的裁定
--   C feedback_note 与 evidence_note 是【两格】,各存各的,不互相顶替
--   D 封顶仍然要理由,而原始分仍然留着(C-2 换了签名,这两条不许跟着掉)
--   E ★ holiday_key 是【身份】不是显示名 ★ —— 补假与被补的那天共用一个键,
--     而 is_in_lieu 把它们分开;工作日计算读的是日期,不受键影响
--
-- 【躲开的陷阱,逐条】
--  (a) **拒绝与"这条路本来就不通"分不开** —— A/D 每一条拒绝都配一条
--      【会成功】的对照(解锁后能打分、给了理由能封顶)。
--  (b) **空集通过** —— 每一处都断言【具体的数】,不是"非空"。
--  (c) **两边其实是一边** —— B 臂断言的两件事读的是【两个不同的字段】
--      (score_kpi_entry 的 RAISE vs my_kpi_entries 的 score_visible),
--      所以它们能各自动。
--  (d) **fixture 以 postgres 跑会绕过 RLS** —— 这一条在本支【不适用】,而那正是
--      要写下来的:`my_kpi_entries` 是属主权限视图(security_invoker = off),
--      它的谓词写在【视图体里】(employee_id = current_user_employee()),
--      而 current_user_employee() 读的是 `request.jwt.claims` —— 不是 RLS。
--      所以本支【不切角色】,而 B 臂仍然有管辖权。★写下这一句是因为照抄
--      fixture 26 那条"记得 SET LOCAL ROLE"会让人以为这里少了一步。★
--  (e) **依赖时间敏感的引导数据** —— 本支自己建周期与假日,不借用线上的任何一年。
--
-- 【它【不】断言什么,写下来免得被读成更强的保证】
--   ★ 「M3 关口锁住第 1–3 个月」是 Tim 的【运营规矩】,不是一条数据库约束。★
--   数据库只知道"这个周期锁了没有";一次锁三个月是**人按三次**,或将来某支
--   函数的事。本支断言的是**锁这个机制本身**,不是锁的范围 —— 把没实现的东西
--   断言成实现了,比没有断言更坏。

BEGIN;

DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    r_all    uuid;
    v_pos    uuid;
    v_emp    uuid;
    v_cycle  uuid;
    v_entry  uuid;
    v_r      jsonb;
    v_msg    text;
    v_denied boolean;
    v_n      integer;
    v_vis    boolean;
    v_score  integer;
BEGIN
    -- ── 一个什么权限都有的角色,和一个挂着它的人 ────────────────────────────
    -- ★ employees.user_id 有指向 auth.users 的外键,而 B 臂要 current_user_employee()
    --   解析得出这个人 —— 所以这个账号必须真的存在(fixture 78 / 94 / 192 同一条路)。
    INSERT INTO auth.users (id) VALUES (v_user);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-193', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    SELECT id INTO v_pos FROM positions ORDER BY sort_order LIMIT 1;
    IF v_pos IS NULL THEN RAISE EXCEPTION 'FIXTURE 193 前提失败:一个职位都没有'; END IF;

    INSERT INTO employees (code, legal_name, hire_date, employment_type, work_category,
                           employment_status, position_id, user_id)
    VALUES ('ZZ193-E1', 'ZZ 193 Subject', '2026-09-01', 'full_time', 'office',
            'active', v_pos, v_user)
    RETURNING id INTO v_emp;

    INSERT INTO kpi_cycles (name, period_start, period_end, due_date, status)
    VALUES ('ZZ193-2026-09', '2026-09-01', '2026-09-30', '2026-10-31', 'open')
    RETURNING id INTO v_cycle;

    PERFORM assign_position_kpis(v_emp, v_cycle);
    SELECT count(*) INTO v_n FROM kpi_entries WHERE cycle_id = v_cycle AND employee_id = v_emp;
    IF v_n <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 193 前提失败:应当生成 5 条,实得 %', v_n; END IF;
    SELECT id INTO v_entry FROM kpi_entries
     WHERE cycle_id = v_cycle AND employee_id = v_emp ORDER BY kpi_ref LIMIT 1;

    -- ══════════ C. 证据与反馈是【两格】,各存各的 ═══════════════════════════
    -- 先做 C,因为它顺便证明"这条路在锁之前是通的"—— A 臂的对照。
    v_r := score_kpi_entry(v_entry, 4, 'judged',
                           p_evidence_note => '看了九月的三张盘点表',
                           p_feedback_note => '下个月把复核提前到 25 号');
    IF (v_r->>'score')::int <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 193C 失败:应当收下 4 分,实得 %', v_r; END IF;
    -- ★ 两格【各是各的】—— 一个把两句话挤进一格的实现在这里就红
    PERFORM 1 FROM kpi_entries
     WHERE id = v_entry
       AND evidence_note = '看了九月的三张盘点表'
       AND feedback_note = '下个月把复核提前到 25 号';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FIXTURE 193C 失败:★证据与反馈应当各存各的★,实得 evidence=% feedback=%',
            (SELECT coalesce(evidence_note,'(null)') FROM kpi_entries WHERE id = v_entry),
            (SELECT coalesce(feedback_note,'(null)') FROM kpi_entries WHERE id = v_entry); END IF;

    -- ══════════ D. 封顶要理由;原始分留着(C-2 换了签名,这两条不许掉)═══════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM score_kpi_entry(v_entry, 4, 'judged', p_override_cap => 2);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'KPI_OVERRIDE_NEEDS_REASON|%' THEN
        RAISE EXCEPTION 'FIXTURE 193D 失败:没有理由的封顶应当被拒,实得 %',
            COALESCE(v_msg, '(收下了)'); END IF;
    -- 【对照:给了理由就该成功】—— 否则上面那次拒绝可能只是"这条路不通"
    v_r := score_kpi_entry(v_entry, 5, 'judged',
                           p_override_cap => 2,
                           p_override_reason => 'unauthorized operation observed');
    IF (v_r->>'effective_score')::int <> 2 OR (v_r->>'capped')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 193D 失败:5 分封到 2,生效分应当 2 且 capped,实得 %', v_r; END IF;
    SELECT score INTO v_score FROM kpi_entries WHERE id = v_entry;
    IF v_score <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 193D 失败:★封顶不该覆盖原始判断★,原始分应当还是 5,实得 %', v_score; END IF;

    -- ══════════ A. locked_at 冻结打分 ══════════════════════════════════════
    UPDATE kpi_cycles SET locked_at = now(), locked_by = v_user WHERE id = v_cycle;

    v_denied := false; v_msg := NULL;
    BEGIN PERFORM score_kpi_entry(v_entry, 3, 'judged');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'KPI_CYCLE_LOCKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 193A 失败:锁住的月份不该改得动分数,实得 %',
            COALESCE(v_msg, '(改动了)'); END IF;
    -- ★ 分数真的没变(拒绝不是"报了错但还是写进去了")
    SELECT score INTO v_score FROM kpi_entries WHERE id = v_entry;
    IF v_score <> 5 THEN
        RAISE EXCEPTION 'FIXTURE 193A 失败:被拒之后分数不该变,应当还是 5,实得 %', v_score; END IF;

    -- ══════════ B. ★锁 ≠ 关★ —— 这一臂是这一刀存在的理由 ═══════════════════
    -- 周期现在是 locked 但【没有 closed】。两件事必须【同时】成立:
    --   ① 打分被拒(上面 A 已证);
    --   ② 分数对本人【仍然不可见】—— 揭晓归 status,不归锁。
    -- ★ my_kpi_entries 是属主权限视图,谓词写在视图体里(employee_id =
    --   current_user_employee()),而 current_user_employee() 读的是 auth.uid() ——
    --   claims 已经设成 v_user,所以这里读得到自己那五条。
    SELECT score_visible, score INTO v_vis, v_score
      FROM my_kpi_entries WHERE id = v_entry;
    IF v_vis IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FIXTURE 193B 失败:★锁住 ≠ 揭晓★ —— 周期没 closed,score_visible 应当是 false,实得 %', v_vis; END IF;
    IF v_score IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 193B 失败:★锁住 ≠ 揭晓★ —— 周期没 closed,分数应当压成 NULL,实得 %', v_score; END IF;

    -- 【对照:解锁之后同一条路走得通】—— 于是 A 的拒绝是一次测量,不是一堵墙
    UPDATE kpi_cycles SET locked_at = NULL, locked_by = NULL WHERE id = v_cycle;
    v_r := score_kpi_entry(v_entry, 3, 'judged');
    IF (v_r->>'score')::int <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 193A 失败:解锁之后应当又打得了分 —— 上面那次拒绝因此不是一次测量,实得 %', v_r; END IF;

    -- 【关掉之后才揭晓】—— 与锁那一半分开动,证明两者【真的是两个字段】
    UPDATE kpi_cycles SET status = 'closed' WHERE id = v_cycle;
    SELECT score_visible, score INTO v_vis, v_score FROM my_kpi_entries WHERE id = v_entry;
    IF v_vis IS NOT TRUE OR v_score <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 193B 失败:关掉之后分数应当对本人可见且为 3,实得 visible=% score=%',
            v_vis, v_score; END IF;
    -- 而关掉的月份也不许再改(这条是 KPI-1 就有的,C-2 不许把它弄丢)
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM score_kpi_entry(v_entry, 1, 'judged');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied OR v_msg NOT LIKE 'KPI_CYCLE_CLOSED|%' THEN
        RAISE EXCEPTION 'FIXTURE 193B 失败:关掉的月份不该改得动,实得 %', COALESCE(v_msg,'(改动了)'); END IF;

    -- ══════════ E. holiday_key 是身份,is_in_lieu 把补假分出来 ═══════════════
    DELETE FROM public_holidays WHERE holiday_date BETWEEN '2029-03-01' AND '2029-03-31';
    INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key, is_in_lieu, country, is_active) VALUES
        ('2029-03-04', 'ZZ193 Festival',          'ZZ193 节',     'zz193-festival', false, 'SG', true),  -- 周日
        ('2029-03-05', 'ZZ193 Festival (in lieu)', 'ZZ193 节补假', 'zz193-festival', true,  'SG', true);  -- 周一

    -- ★ 同一个节日的两行【共用一个键】—— 那正是 UI-1 每年要问的那个身份
    SELECT count(DISTINCT holiday_key) INTO v_n FROM public_holidays
     WHERE holiday_date IN (DATE '2029-03-04', DATE '2029-03-05');
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 193E 失败:补假与被补的那天应当共用一个 holiday_key,实得 % 个', v_n; END IF;
    -- ★ 而 is_in_lieu 把它们分得开(只看键分不出来 —— 那正是这一列存在的理由)
    SELECT count(*) INTO v_n FROM public_holidays
     WHERE holiday_key = 'zz193-festival' AND is_in_lieu;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 193E 失败:两行里应当正好一行是补假,实得 %', v_n; END IF;
    -- ★ 工作日计算读的是【日期】,不受键影响:那个周一因此不是工作日
    IF is_business_day(DATE '2029-03-05') THEN
        RAISE EXCEPTION 'FIXTURE 193E 失败:2029-03-05 是补假,不该被算成工作日'; END IF;
    -- 【对照:同一周的普通日子仍然是工作日】—— 否则上面那句可能只是"全都不是工作日"
    IF NOT is_business_day(DATE '2029-03-06') THEN
        RAISE EXCEPTION 'FIXTURE 193E 失败:2029-03-06 是普通周二,应当是工作日 —— 上面那条断言因此不是一次测量'; END IF;
    -- ★ 键的形状是被守着的:大写/下划线写不进去
    v_denied := false; v_msg := NULL;
    BEGIN
        INSERT INTO public_holidays (holiday_date, name_en, name_zh, holiday_key, country, is_active)
        VALUES ('2029-03-07', 'ZZ193 Bad Key', 'ZZ193 坏键', 'ZZ193_Festival', 'SG', true);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := true; END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 193E 失败:★一个大写下划线的键应当被拒★ —— 键的全部价值是每年写出同一串字,而 `ZZ193_Festival` 与 `zz193-festival` 对 UI-1 是两个节日'; END IF;
END $$;

ROLLBACK;

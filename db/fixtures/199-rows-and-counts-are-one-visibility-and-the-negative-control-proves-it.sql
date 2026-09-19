-- 199 取行与计数是【同一份可见性】—— 而没有反面对照,这句话证不出来
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【它钉住的那一句话】
--   `search_related()` 数「你看得见几条」,`search_related_rows()` 取「你看得见
--   哪几条」。两支函数是【分开写的】,而它们必须是同一个答案。
--   ☞ 两份文本长得一样**不是**判据 —— 本仓库为"两份实现在写下来那天一致、
--     之后悄悄分开"付过四次账。判据是这一支 fixture。
--
-- ⚠️★★【每一条都必须 SET LOCAL ROLE authenticated,而这一条是这支 fixture 的全部】
--   fixture 以 postgres 跑,`rolbypassrls = t`。不切角色的话,两个数【按构造】
--   相等 —— 因为两支函数都返回了全部。**那样这支 fixture 是绿的,而它什么都没证。**
--   这是 AGENTS.md 记着的 fixture 26 那一课,SEARCH-5 的停止闸自己也点名了它。
--
-- ★★【所以它必须有一格【反面对照】】★★
--   光有"两个数一样"不够:两支都返回全部时它们也一样。C 臂换一个【看不见任务
--   的会话】,要求**两个数一起掉到 0**。一个只会动一边的缺陷,只有这一格抓得住。
--
-- ── 五臂 ────────────────────────────────────────────────────────────────────
--   A 前提 + 同一会话里 行数 == 计数(employee → task,**三条边**:
--     owner_id 的 in 边 + task_history / task_participants 两条桥边;
--     其中一条桥故意指向一张【已经被 in 边数过】的任务 ⇒ 顺带钉住 DISTINCT)
--   B 分页:keyset 翻两页取到的是同一批行,不重不漏;`total` 两页相同
--   C ★ 反面对照:换一个【没有 module.tasks.view】的会话 ⇒ **两个数一起变 0**
--   D 主语读不到(有 tasks.view、没有 hr.view)⇒ **函数一行都不返回**
--   E 拼错的 target_key ⇒ **RAISE**,不是空集;半个主语 ⇒ **RAISE**
--   F ★ 本刀自己长出来的那一条:这一支比 search_related() 多读一列(label),
--     而 6 张单据表对 authenticated 【没有表级 SELECT】,只有列级授权 ——
--     所以逐个单据种类断言 `code` 与 `label_column` 真的读得到
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    u_see    uuid := gen_random_uuid();   -- hr.view + tasks.view
    u_blind  uuid := gen_random_uuid();   -- hr.view 【没有】 tasks.view  → C 臂
    u_nosubj uuid := gen_random_uuid();   -- tasks.view 【没有】 hr.view  → D 臂
    -- ★ 团队任务有一支触发器会把【归属人】自动加进参与者,而参与者那一条
    --   按名拒绝没有登录账号的员工(trg_task_participants_guard)。
    --   ☞ 所以这两个员工必须各有一个登录账号 —— 这不是防御性的,是实测撞出来的。
    u_oth    uuid := gen_random_uuid();
    r_see uuid; r_blind uuid; r_nosubj uuid;
    e_subj uuid; e_other uuid;
    t1 uuid; t2 uuid; t3 uuid; t4 uuid;
    v_rows bigint; v_cnt bigint; v_total bigint;
    v_p1 text[]; v_p2 text[]; v_last text;
    v_raised boolean; v_msg text;
    d record; v_bad text := '';
BEGIN
    -- ── 登录账号(prelude 的 auth.users 只要 id)──────────────────────────
    INSERT INTO auth.users (id) VALUES (u_see), (u_blind), (u_nosubj), (u_oth);

    -- ── 角色:自建,不借引导角色(README)────────────────────────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-199-see','f199','f199',true) RETURNING id INTO r_see;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_see,'module.hr.view'), (r_see,'module.tasks.view');

    -- ★ blind 仍然持 module.hr.view —— 于是 C 臂掉到 0 的原因【只能是】
    --   看不见任务,不能是"连主语都读不到"(那是 D 臂的事)。两臂各测一件。
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-199-blind','f199','f199',true) RETURNING id INTO r_blind;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_blind,'module.hr.view');

    -- ★ nosubj 持 module.tasks.view —— 于是 D 臂的 0 行【不是】因为任务看不见。
    INSERT INTO roles (code, name_en, name_zh, is_active)
        VALUES ('fixture-199-nosubj','f199','f199',true) RETURNING id INTO r_nosubj;
    INSERT INTO role_permissions (role_id, permission_code)
        VALUES (r_nosubj,'module.tasks.view');

    INSERT INTO user_roles (user_id, role_id)
        VALUES (u_see,r_see), (u_blind,r_blind), (u_nosubj,r_nosubj);

    -- ── 主语与一个旁人 ──────────────────────────────────────────────────
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ199-SUBJ','Fixture 199 Subject','full_time','office','2025-01-01', u_see)
        RETURNING id INTO e_subj;
    INSERT INTO employees (code, legal_name, employment_type, work_category, hire_date, user_id)
        VALUES ('ZZ199-OTH','Fixture 199 Other','full_time','office','2025-01-01', u_oth)
        RETURNING id INTO e_other;

    -- ── 任务:全部 team(于是可见性只由 module.tasks.view 决定,C 臂才干净)──
    INSERT INTO tasks (title, task_type, owner_id) VALUES ('ZZ199 a','team',e_subj) RETURNING id INTO t1;
    INSERT INTO tasks (title, task_type, owner_id) VALUES ('ZZ199 b','team',e_subj) RETURNING id INTO t2;
    INSERT INTO tasks (title, task_type, owner_id) VALUES ('ZZ199 c','team',e_subj) RETURNING id INTO t3;
    -- 第四张【不属于】主语,只由一条桥边(task_history)带进来
    INSERT INTO tasks (title, task_type, owner_id) VALUES ('ZZ199 d','team',e_other) RETURNING id INTO t4;
    INSERT INTO task_history (task_id, employee_id, change_type) VALUES (t4, e_subj, 'header_update');
    -- ★ 而这一条桥指向【已经被 in 边数过】的 t1 —— 它一个数都不许多加。
    --   没有这一行,DISTINCT 掉了也没有任何东西会红。
    INSERT INTO task_history (task_id, employee_id, change_type) VALUES (t1, e_subj, 'header_update');

    -- ══════════ A. 前提 + 行数 == 计数(同一个会话)════════════════════════
    -- 【前提一】少了表权限,下面每一条 "0 行" 都会因为错的理由通过。
    IF NOT (has_table_privilege('authenticated','public.tasks','SELECT')
        AND has_table_privilege('authenticated','public.task_history','SELECT')) THEN
        RAISE EXCEPTION 'FIXTURE 199 前提不成立:authenticated 缺少 tasks/task_history 的表级 SELECT '
                        '—— 那样 C 臂与 D 臂都会因为错的理由变绿';
    END IF;
    -- 【前提二】两支函数都必须是 INVOKER。任何一支变成 DEFINER,本文件全部作废。
    IF (SELECT bool_or(p.prosecdef) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
         WHERE n.nspname='public' AND p.proname IN ('search_related','search_related_rows')) THEN
        RAISE EXCEPTION 'FIXTURE 199 前提不成立:search_related / search_related_rows 里有 SECURITY DEFINER '
                        '—— 「你看得见几条」只能由 RLS 回答,借了身份这支 fixture 就什么都不证';
    END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_see), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT coalesce((SELECT sr.n FROM public.search_related('employee', e_subj) sr
                      WHERE sr.target_key = 'task'), 0) INTO v_cnt;
    SELECT count(*), max(r.total) INTO v_rows, v_total
      FROM public.search_related_rows('employee', e_subj, 'task', 100, NULL) r;
    RESET ROLE;

    IF v_cnt <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 199A 前提不成立:search_related 数出 % 组任务,应当是 4 '
                        '(3 张自己的 + 1 张只由桥边带进来的;另有一条桥指向已数过的那张)'
                        ' —— 用例没搭对,不是产品坏了', v_cnt;
    END IF;
    IF v_rows <> v_cnt THEN
        RAISE EXCEPTION 'FIXTURE 199A 失败:同一个会话里,计数 % ≠ 行数 % '
                        '—— 取行与计数不是同一份可见性', v_cnt, v_rows;
    END IF;
    IF v_total <> v_cnt THEN
        RAISE EXCEPTION 'FIXTURE 199A 失败:函数自报的 total=% ≠ 计数 % '
                        '—— total 是分页那一行要显示的数,它错了没有别的东西会红', v_total, v_cnt;
    END IF;

    -- ══════════ B. keyset 翻页:不重、不漏、total 不随页变 ═══════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_see), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT array_agg(r.code ORDER BY r.code DESC), min(r.code), max(r.total)
      INTO v_p1, v_last, v_total
      FROM public.search_related_rows('employee', e_subj, 'task', 3, NULL) r;
    SELECT array_agg(r.code ORDER BY r.code DESC), max(r.total) INTO v_p2, v_cnt
      FROM public.search_related_rows('employee', e_subj, 'task', 3, v_last) r;
    RESET ROLE;

    IF cardinality(v_p1) <> 3 OR cardinality(v_p2) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 199B 失败:每页 3 条、共 4 条,两页应当是 3 + 1,实得 % + %',
                        cardinality(v_p1), cardinality(v_p2);
    END IF;
    IF v_p1 && v_p2 THEN
        RAISE EXCEPTION 'FIXTURE 199B 失败:两页有重复的行 % / % —— keyset 的边界算错了',
                        v_p1::text, v_p2::text;
    END IF;
    IF (SELECT count(DISTINCT x) FROM unnest(v_p1 || v_p2) x) <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 199B 失败:两页合起来不是 4 个不同的号(%)—— 翻页漏了行',
                        (v_p1 || v_p2)::text;
    END IF;
    IF v_total <> 4 OR v_cnt <> 4 THEN
        RAISE EXCEPTION 'FIXTURE 199B 失败:total 随页变了(第一页 %,第二页 %)—— '
                        '一个会变小的 total 读起来像"记录在减少"', v_total, v_cnt;
    END IF;

    -- ══════════ C. ★ 反面对照:两个数【一起】变 ═══════════════════════════
    --   没有这一格,A 臂可能只是"两支函数都返回了全部"。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_blind), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT coalesce((SELECT sr.n FROM public.search_related('employee', e_subj) sr
                      WHERE sr.target_key = 'task'), 0) INTO v_cnt;
    SELECT count(*) INTO v_rows
      FROM public.search_related_rows('employee', e_subj, 'task', 100, NULL) r;
    RESET ROLE;

    IF v_cnt <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 199C 失败:一个【没有 module.tasks.view】的会话数出 % 条任务 '
                        '—— 计数那一侧漏了 RLS', v_cnt;
    END IF;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 199C 失败:一个【没有 module.tasks.view】的会话取回 % 行任务 '
                        '—— ★ 而 A 臂照样是绿的:这正是这一格存在的全部理由', v_rows;
    END IF;

    -- ══════════ D. 主语读不到 ⇒ 一行都不返回 ═══════════════════════════════
    --   这个会话【看得见任务】(持 module.tasks.view),它缺的只是 module.hr.view。
    --   所以 0 行证明的是:主语那一层【在函数里】就是真的,不是页面上补的。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_nosubj), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_rows FROM public.employees WHERE id = e_subj;
    IF v_rows <> 0 THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 199D 前提不成立:这个会话本来就该读不到那个员工,却读到了 % 行', v_rows;
    END IF;
    SELECT count(*) INTO v_rows FROM public.tasks WHERE id = t1;
    IF v_rows <> 1 THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 199D 前提不成立:这个会话应当【看得见任务】(它持 module.tasks.view),'
                        '实得 % 行 —— 否则下面那个 0 行是因为错的理由', v_rows;
    END IF;
    SELECT count(*) INTO v_rows
      FROM public.search_related_rows('employee', e_subj, 'task', 100, NULL) r;
    RESET ROLE;
    IF v_rows <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 199D 失败:主语读不到,函数却返回了 % 行 —— '
                        '一张「某人的任务」的列表,主语读不到时【一行都不许给】', v_rows;
    END IF;

    -- ══════════ E. 拼错的 key 与半个主语 ⇒ RAISE,不是空集 ═══════════════════
    v_raised := false;
    BEGIN
        PERFORM * FROM public.search_related_rows('employee', e_subj, 'no_such_type', 20, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_raised := true; v_msg := SQLERRM;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'FIXTURE 199E 失败:拼错的 target_key 静默返回了空集 —— '
                        '一个拼错的 key 与一张真的没有关联的单据在屏幕上分不开';
    END IF;
    IF v_msg NOT LIKE 'SEARCH_UNKNOWN_DOCUMENT_TYPE|%' THEN
        RAISE EXCEPTION 'FIXTURE 199E 失败:响了,而响的不是那一句(%)', v_msg;
    END IF;

    v_raised := false;
    BEGIN
        PERFORM * FROM public.search_related_rows('employee', NULL, 'task', 20, NULL);
    EXCEPTION WHEN OTHERS THEN
        v_raised := true; v_msg := SQLERRM;
    END;
    IF NOT v_raised OR v_msg NOT LIKE 'SEARCH_RELATED_HALF_SUBJECT|%' THEN
        RAISE EXCEPTION 'FIXTURE 199E 失败:只给了一半主语,而它没有按名拒绝(raised=% msg=%)—— '
                        '静默地当成"无主语"会把【某人的任务】画成【全部任务】', v_raised, coalesce(v_msg,'(none)');
    END IF;

    -- ══════════ F. ★ 多读的那一列,真的读得到吗 ═════════════════════════════
    --   search_related() 只取 id + code;这一支还要取 label_column。
    --   而 6 张单据表对 authenticated 【没有表级 SELECT】,只有列级授权 ——
    --   一次撤掉某个 label 列授权的改动,会让这一支对那一类单据【当场报错】。
    --   AGENTS.md「给遮蔽表加一列要连授权一起加」的另一半。
    FOR d IN SELECT dt.key, dt.table_name, dt.label_column
               FROM public.document_types dt ORDER BY dt.key
    LOOP
        IF NOT has_column_privilege('authenticated', ('public.'||d.table_name)::regclass, 'code', 'SELECT') THEN
            v_bad := v_bad || format('%s.code ', d.table_name);
        END IF;
        IF d.label_column IS NOT NULL
           AND NOT has_column_privilege('authenticated', ('public.'||d.table_name)::regclass, d.label_column, 'SELECT') THEN
            v_bad := v_bad || format('%s.%s ', d.table_name, d.label_column);
        END IF;
    END LOOP;
    IF v_bad <> '' THEN
        RAISE EXCEPTION 'FIXTURE 199F 失败:authenticated 读不到这些列 —— % '
                        '而 search_related_rows() 每一次都要 SELECT 它们,'
                        '所以那不是"少显示一列",是那一类单据的关联页【整页报错】', v_bad;
    END IF;

    RAISE NOTICE 'FIXTURE 199 全部通过:A 计数==行数==total(4,三条边两条桥,DISTINCT 钉住)· '
                 'B keyset 两页 3+1 不重不漏且 total 不变 · '
                 'C ★反面对照 两个数一起变 0 · D 主语读不到则一行不给 · '
                 'E 拼错的 key 与半个主语都按名 RAISE · F 40 个种类的 code/label 列授权齐全';
END $$;
ROLLBACK;

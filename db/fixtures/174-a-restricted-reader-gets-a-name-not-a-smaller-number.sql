-- db/fixtures/174 —— CLEANUP-A:受限的读者拿到【一个名字】,不是一个更小的数字。
--
-- 五臂,每一臂都【先注入旧版本、断言错数字真的回来了】,再换回新版本断言对的行为。
-- 顺序是刻意的:**一份没有先证明"注入改变了什么"的 fixture,可能整份都在空转**
-- (fixture 26 与 FIN-30 的教训,README 第 6 条)。
--
-- 【哪几臂需要 SET LOCAL ROLE】(README 第 6 条)
--   本文件的判据【全部】是 has_permission / require_permission,按
--   request.jwt.claims 解析,与数据库角色无关 —— 所以严格说都不需要切角色。
--   **但 C 臂与 D 臂仍然切**,因为它们要同时证明"合法读者拿得到真数字",
--   而那一半是靠 RLS 的:不切角色,那一半就是空话。
--
-- 【自带数据】重建库里没有任何业务数据(README 第 2、4 条)。

BEGIN;
DO $$
DECLARE
    v_all uuid; v_ops uuid; v_hronly uuid; v_invonly uuid; v_stk uuid;
    u_all  uuid := gen_random_uuid();   -- 全部权限
    u_ops  uuid := gen_random_uuid();   -- 只有产出/库存那一侧,没有 finance / hr
    u_hr   uuid := gen_random_uuid();   -- 只有 module.hr.view
    u_inv  uuid := gen_random_uuid();   -- 只有 module.inventory.view(没有价格、没有盘点)
    u_stku uuid := gen_random_uuid();   -- 盘点/注销那条路:stocktakes.edit + inventory.view,【没有】价格
    u_self uuid := gen_random_uuid();   -- 零权限,但他【就是】那名员工
    a_bank uuid; a_rev uuid; e1 uuid;
    d_par uuid; d_chi uuid; e_mgr uuid; e_emp uuid;
    b_priced uuid; b_unpriced uuid; v_mat uuid; v_sup uuid;
    v_num numeric; v_uuid uuid; v_bool boolean; v_txt text; v_n int;
    v_base numeric; v_want numeric;
    r jsonb := '{}'::jsonb;
BEGIN
    -- ══════════════════════════════════════════════════════════════════════
    -- 角色(README:自建角色,不借引导角色)
    -- ══════════════════════════════════════════════════════════════════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-174-all','a','a',true) RETURNING id INTO v_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT v_all, code FROM permissions;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-174-ops','o','o',true) RETURNING id INTO v_ops;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (v_ops,'module.output.view'), (v_ops,'module.inventory.view');
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-174-hr','h','h',true) RETURNING id INTO v_hronly;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (v_hronly,'module.hr.view');
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-174-inv','i','i',true) RETURNING id INTO v_invonly;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (v_invonly,'module.inventory.view');
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-174-stk','s','s',true) RETURNING id INTO v_stk;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (v_stk,'module.inventory.view'), (v_stk,'module.stocktakes.edit');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_all,v_all), (u_ops,v_ops), (u_hr,v_hronly), (u_inv,v_invonly), (u_stku,v_stk);
    -- u_self 【刻意不授任何角色】—— 他是那个"合法的部分权限读者"。

    -- ══════════════════════════════════════════════════════════════════════
    -- A · bank_book_balance_asof:受限 → NULL,不是 0.00
    -- ══════════════════════════════════════════════════════════════════════
    SELECT id INTO a_bank FROM accounts WHERE code = '1010';
    SELECT id INTO a_rev  FROM accounts WHERE code = '4000';
    IF a_bank IS NULL OR a_rev IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 174 前提失败:引导科目表里没有 1010 或 4000';
    END IF;
    UPDATE finance_settings SET locked_before = NULL;   -- README 第 5 条:前提显式设定
    -- 【断言增量,不断言字面量】(README 第 1 条)重建库里 1010 是空的,线上却已经
    -- 有 −29,753.70。写死 500.00 会让这份 fixture 只在重建库上成立 —— 而它同时是
    -- 本刀在线上做验证时跑的那一份。所以先量基线,再断言"基线 + 500"。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    v_base := COALESCE(bank_book_balance_asof('1010', NULL), 0);
    v_want := v_base + 500;
    INSERT INTO journal_entries (code, entry_date, memo, source_type)
    VALUES ('FIX174-BANK','2026-08-15','fixture 174 bank','manual') RETURNING id INTO e1;
    INSERT INTO journal_lines (entry_id, account_id, debit, credit, currency, amount_ccy, fx_rate)
    VALUES (e1, a_bank, 500, 0, 'USD', 500, 1),
           (e1, a_rev,  0, 500, 'USD', 500, 1);

    -- 【真值:一个【不是零】的数】否则"受限读成 0"与"真的就是 0"分不开,
    -- 而那正是本刀要区分的两件事。
    v_num := bank_book_balance_asof('1010', NULL);
    IF v_num IS DISTINCT FROM v_want THEN
        RAISE EXCEPTION 'FIXTURE 174A 前提失败:全权限读者读 1010 应得 %(基线 % + 500),实得 %',
            v_want, v_base, COALESCE(v_num::text,'NULL');
    END IF;
    r := r || jsonb_build_object('A_truth', v_num);

    -- ── 注入旧版本(没有判据的那一支)────────────────────────────────────
    CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
     RETURNS numeric LANGUAGE sql STABLE AS $inj$
        SELECT round(COALESCE(sum(
                   CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END), 0), 2)
        FROM journal_activity_lines(NULL, p_as_of, true) act
        JOIN journal_lines jl ON jl.id = act.line_id
        WHERE act.account_code = p_account_code
          AND jl.currency = bank_native_currency(p_account_code);
    $inj$;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
    v_num := bank_book_balance_asof('1010', NULL);
    RESET ROLE;
    -- ★【先证明注入确实改变了什么】★ 旧版本必须把 500.00 读成 0.00。
    IF v_num IS DISTINCT FROM 0.00 THEN
        RAISE EXCEPTION 'FIXTURE 174A 注入无效:旧版本对无 finance.view 的读者应当读出 0.00(把 % 读没),实得 % —— 注入没生效,下面那条断言就是空转',
            v_want, COALESCE(v_num::text,'NULL');
    END IF;
    r := r || jsonb_build_object('A_injected_old_gives', v_num);

    -- ── 换回新版本 ────────────────────────────────────────────────────────
    CREATE OR REPLACE FUNCTION public.bank_book_balance_asof(p_account_code text, p_as_of date)
     RETURNS numeric LANGUAGE sql STABLE AS $fix$
        SELECT CASE WHEN has_permission('module.finance.view'::text) THEN (
            SELECT round(COALESCE(sum(
                       CASE WHEN jl.debit > 0 THEN jl.amount_ccy ELSE -jl.amount_ccy END), 0), 2)
            FROM journal_activity_lines(NULL, p_as_of, true) act
            JOIN journal_lines jl ON jl.id = act.line_id
            WHERE act.account_code = p_account_code
              AND jl.currency = bank_native_currency(p_account_code)
        ) END;
    $fix$;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
    v_num := bank_book_balance_asof('1010', NULL);
    RESET ROLE;
    IF v_num IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174A 失败:没有 module.finance.view 的读者应当得到 NULL(受限),实得 % —— 一个数字与"受限"不是一回事', v_num;
    END IF;
    -- 而合法读者仍然拿到真数字(这一半靠 RLS,所以上面切了角色)
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    v_num := bank_book_balance_asof('1010', NULL);
    RESET ROLE;
    IF v_num IS DISTINCT FROM v_want THEN
        RAISE EXCEPTION 'FIXTURE 174A 失败:有权限的读者应当仍得 %,实得 % —— 判据把合法的路也拦掉了', v_want, COALESCE(v_num::text,'NULL');
    END IF;
    r := r || jsonb_build_object('A_fixed_restricted','NULL', 'A_fixed_authorised', v_num);

    -- ══════════════════════════════════════════════════════════════════════
    -- B · 修好的函数【穿过】修好的视图 —— 这一臂是本文件存在的头号理由
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 两处分开看都"修好了",合起来仍然说谎 ★
    --   旧视图写着 COALESCE(led.balance, 0::numeric)。A 臂让函数对受限读者返回
    --   NULL —— 而那个 COALESCE 会把 NULL **变回 0.00**。于是只钉 A 臂、
    --   只钉视图,两条都能通过,而屏幕上仍然是一个假的零。
    --   所以这一臂注入的是【旧视图】,而函数保持修好的样子。
    --   而且这张视图给的不是空列表,是**两行假零** —— 比 R1 描述的形状更坏。

    -- 先确认修好的这一对是对的:合法读者拿到真数字
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    SELECT ledger_balance INTO v_num FROM bank_reconciliation_status WHERE account_code='1010';
    RESET ROLE;
    IF v_num IS DISTINCT FROM v_want THEN
        RAISE EXCEPTION 'FIXTURE 174B 前提失败:全权限读者从视图应得 %,实得 %', v_want, COALESCE(v_num::text,'NULL');
    END IF;

    -- 受限读者:必须是【按名拒绝】,不是两行零
    v_txt := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
        SELECT count(*) INTO v_n FROM bank_reconciliation_status;
        RESET ROLE;
        v_txt := 'NO REFUSAL, rows=' || v_n;
    EXCEPTION WHEN OTHERS THEN
        RESET ROLE;
        v_txt := SQLERRM;
    END;
    IF v_txt NOT LIKE '%module.finance.view%' THEN
        RAISE EXCEPTION 'FIXTURE 174B 失败:受限读者读对账总览应当撞上一条【点名 module.finance.view】的拒绝,实得 % —— 若是"NO REFUSAL, rows=2"就是那两行假零又回来了', v_txt;
    END IF;
    r := r || jsonb_build_object('B_restricted_gets', v_txt);

    -- ── 注入【旧视图】(带 COALESCE 的那一版,直接读底表)──────────────────
    CREATE OR REPLACE VIEW public.bank_reconciliation_status
    WITH (security_invoker = on) AS
     SELECT b.account_code,
        bank_native_currency(b.account_code) AS currency,
        COALESCE(led.balance, 0::numeric) AS ledger_balance,
        ls.code AS latest_statement_code,
        ls.period_end AS latest_statement_period_end,
        ls.closing_balance AS latest_closing_balance,
        COALESCE(sl.unmatched, 0::bigint) AS unmatched_statement_lines,
        COALESCE(sl.ignored, 0::bigint) AS ignored_statement_lines,
        COALESCE(jl.unmatched_count, 0::bigint) AS unmatched_journal_lines,
        round(COALESCE(jl.unmatched_net, 0::numeric), 2) AS unmatched_journal_amount,
        round(COALESCE(led.balance, 0::numeric) - ls.closing_balance, 2) AS difference
       FROM ( VALUES ('1000'::text), ('1010'::text)) b(account_code)
         LEFT JOIN LATERAL ( SELECT bank_book_balance_asof(b.account_code, NULL::date) AS balance) led ON true
         LEFT JOIN LATERAL ( SELECT s.code, s.period_end, s.closing_balance
               FROM bank_statements s
              WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL
              ORDER BY s.period_end DESC, s.created_at DESC LIMIT 1) ls ON true
         LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE l.match_status='unmatched') AS unmatched,
                count(*) FILTER (WHERE l.match_status='ignored') AS ignored
               FROM bank_statement_lines l JOIN bank_statements s ON s.id = l.statement_id
              WHERE s.bank_account_code = b.account_code AND s.deleted_at IS NULL) sl ON true
         LEFT JOIN LATERAL ( SELECT count(*) AS unmatched_count,
                sum(CASE WHEN l.debit > 0 THEN l.amount_ccy ELSE -l.amount_ccy END) AS unmatched_net
               FROM journal_lines l
                 JOIN accounts a ON a.id = l.account_id AND a.code = b.account_code
                 JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
              WHERE l.currency = bank_native_currency(b.account_code)
                AND NOT (EXISTS (SELECT 1 FROM bank_line_matches m WHERE m.journal_line_id = l.id))) jl ON true;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
    SELECT ledger_balance INTO v_num FROM bank_reconciliation_status WHERE account_code='1010';
    SELECT count(*) INTO v_n FROM bank_reconciliation_status;
    RESET ROLE;
    -- ★【注入必须改变些什么】★ 旧视图 + 【已经修好的】函数 = 仍然是 0.00,
    --   而且仍然是两行 —— 这就是"两处分开看都好、合起来仍然说谎"。
    IF v_num IS DISTINCT FROM 0.00 OR v_n <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 174B 注入无效:旧视图应当把修好的函数返回的 NULL 用 COALESCE 变回 0.00 并给出 2 行,实得 % / % 行 —— 注入没生效,上面那条断言就是空转',
            COALESCE(v_num::text,'NULL'), v_n;
    END IF;
    r := r || jsonb_build_object('B_injected_old_view_gives', v_num, 'B_injected_old_view_rows', v_n);

    -- ── 换回壳 ────────────────────────────────────────────────────────────
    CREATE OR REPLACE VIEW public.bank_reconciliation_status
    WITH (security_invoker = on) AS
     SELECT r2.account_code, r2.currency, r2.ledger_balance,
            r2.latest_statement_code, r2.latest_statement_period_end, r2.latest_closing_balance,
            r2.unmatched_statement_lines, r2.ignored_statement_lines,
            r2.unmatched_journal_lines, r2.unmatched_journal_amount, r2.difference
       FROM bank_reconciliation_rows() r2;

    -- ══════════════════════════════════════════════════════════════════════
    -- C · attendance_unpaid_days:受限 → NULL,而【本人仍然读得到自己的】
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 旧行为的后果是【多发工资】★ 这个数是工资的扣减项,读成 0 就是全额发出去。
    --
    -- ★★ 这一臂有【两次】注入,而第二次才是本刀最要紧的那一条 ★★
    --   C-inj-1:旧版本(没有判据)→ 受限读者把真值读成 0。
    --   C-inj-2:**一个"太窄"的白名单**(只写 module.hr.view,去掉 OR 本人)
    --           → 一个【零权限但就是本人】的员工被新打断。
    --   R2 说这条危险【两个方向都是失败】,而第二个方向只有真的注入才看得见。
    INSERT INTO departments (code,name_en,name_zh) VALUES ('FIX174-P','p','p') RETURNING id INTO d_par;
    INSERT INTO employees (code,legal_name,department_id,employment_type,hire_date,employment_status,work_category)
      VALUES ('FIX174-MGR','Fix174 Mgr',d_par,'full_time','2026-01-01','active','office') RETURNING id INTO e_mgr;
    UPDATE departments SET manager_employee_id = e_mgr WHERE id = d_par;
    INSERT INTO departments (code,name_en,name_zh,parent_department_id)
      VALUES ('FIX174-C','c','c',d_par) RETURNING id INTO d_chi;

    -- 【employees.user_id 自 EXEC-2 起有指向 auth.users 的外键】所以"本人"这个身份
    -- 必须真的存在(fixture 126 的先例)。u_self 【不授任何角色】—— 他的可见性
    -- 完全来自"他就是这一行的主人"。
    INSERT INTO auth.users (id) VALUES (u_self);
    INSERT INTO employees (code,legal_name,department_id,employment_type,hire_date,
                           employment_status,work_category,user_id)
      VALUES ('FIX174-EMP','Fix174 Emp',d_chi,'full_time','2026-01-01','active','office',u_self)
      RETURNING id INTO e_emp;
    INSERT INTO leave_requests (code,employee_id,leave_type_code,start_date,end_date,status,
                                start_half_day,end_half_day,days)
      VALUES ('FIX174-LV', e_emp, 'unpaid', '2026-08-10', '2026-08-12', 'approved', false, false, 3);

    -- C0 真值。【不写死天数】它受 public_holidays 影响,而那份引导数据会过期
    -- (README 第 4 条)。断言的是"是个正数",以及后面每一臂与它【相等】。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    v_num := attendance_unpaid_days(e_emp, '2026-08-01');
    IF v_num IS NULL OR v_num <= 0 THEN
        RAISE EXCEPTION 'FIXTURE 174C 前提失败:全权限读者应当读出一个正的无薪假天数,实得 %', COALESCE(v_num::text,'NULL');
    END IF;
    r := r || jsonb_build_object('C_truth', v_num);

    -- 【先钉住"本人"这条路今天是通的】—— 这是 C-inj-2 要保护的东西
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_self), true);
    IF current_user_employee() IS DISTINCT FROM e_emp THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 174C 前提失败:u_self 应当解析成 FIX174-EMP,否则"本人"那一臂测的不是本人';
    END IF;
    v_num := attendance_unpaid_days(e_emp, '2026-08-01');
    RESET ROLE;
    IF v_num IS DISTINCT FROM (r->>'C_truth')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 174C 失败:一个【零权限但就是本人】的员工应当读到自己的真值 %,实得 % —— leave_requests 的 select own rows 策略让这条路合法,判据不该打断它',
            r->>'C_truth', COALESCE(v_num::text,'NULL');
    END IF;
    r := r || jsonb_build_object('C_self_zero_perms_reads_own', v_num);

    -- ── C-inj-1:注入旧版本(没有判据)────────────────────────────────────
    CREATE OR REPLACE FUNCTION public.attendance_unpaid_days(p_employee_id uuid, p_month date)
     RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $inj$
        SELECT COALESCE(round(sum(
            calculate_leave_days(
                GREATEST(lr.start_date, date_trunc('month', p_month)::date),
                LEAST(lr.end_date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date),
                lr.start_half_day AND lr.start_date >= date_trunc('month', p_month)::date,
                lr.end_half_day   AND lr.end_date   <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
            )), 2), 0)
          FROM leave_requests lr
         WHERE lr.employee_id = p_employee_id
           AND lr.leave_type_code = 'unpaid' AND lr.status = 'approved' AND lr.deleted_at IS NULL
           AND lr.start_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
           AND lr.end_date   >= date_trunc('month', p_month)::date;
    $inj$;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
    v_num := attendance_unpaid_days(e_emp, '2026-08-01');
    RESET ROLE;
    IF v_num IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'FIXTURE 174C-inj1 注入无效:旧版本对无 hr.view 的读者应当读出 0(真值是正数),实得 % —— 注入没生效,下面的断言就是空转', COALESCE(v_num::text,'NULL');
    END IF;
    r := r || jsonb_build_object('C_inj1_old_gives', v_num);

    -- ── C-inj-2:注入一个【太窄】的白名单(去掉 OR 本人)★ R2 的反方向 ★ ──
    CREATE OR REPLACE FUNCTION public.attendance_unpaid_days(p_employee_id uuid, p_month date)
     RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $narrow$
        SELECT CASE WHEN has_permission('module.hr.view'::text) THEN (
            SELECT COALESCE(round(sum(
                calculate_leave_days(
                    GREATEST(lr.start_date, date_trunc('month', p_month)::date),
                    LEAST(lr.end_date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date),
                    lr.start_half_day AND lr.start_date >= date_trunc('month', p_month)::date,
                    lr.end_half_day   AND lr.end_date   <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
                )), 2), 0)
              FROM leave_requests lr
             WHERE lr.employee_id = p_employee_id
               AND lr.leave_type_code = 'unpaid' AND lr.status = 'approved' AND lr.deleted_at IS NULL
               AND lr.start_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
               AND lr.end_date   >= date_trunc('month', p_month)::date
        ) END;
    $narrow$;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_self), true);
    v_num := attendance_unpaid_days(e_emp, '2026-08-01');
    RESET ROLE;
    -- ★ 太窄的白名单必须【看得见地】打断本人这条路 ★ 若这里仍是真值,
    --   说明 OR 本人那一支根本没起作用,而上面那条"本人读得到"的断言是空转。
    IF v_num IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174C-inj2 注入无效:只写 module.hr.view 的白名单本应把【零权限但就是本人】的读者打断(得 NULL),实得 % —— 说明 OR 本人那一支没有被真的用到,上面那条断言是空转', v_num;
    END IF;
    r := r || jsonb_build_object('C_inj2_narrow_breaks_self','NULL(这正是不能只写 hr.view 的证据)');

    -- ── 换回新版本,并重新钉住三个读者 ────────────────────────────────────
    CREATE OR REPLACE FUNCTION public.attendance_unpaid_days(p_employee_id uuid, p_month date)
     RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public','pg_temp' AS $fix$
        SELECT CASE WHEN has_permission('module.hr.view'::text)
                      OR p_employee_id = current_user_employee() THEN (
            SELECT COALESCE(round(sum(
                calculate_leave_days(
                    GREATEST(lr.start_date, date_trunc('month', p_month)::date),
                    LEAST(lr.end_date, (date_trunc('month', p_month) + interval '1 month - 1 day')::date),
                    lr.start_half_day AND lr.start_date >= date_trunc('month', p_month)::date,
                    lr.end_half_day   AND lr.end_date   <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
                )), 2), 0)
              FROM leave_requests lr
             WHERE lr.employee_id = p_employee_id
               AND lr.leave_type_code = 'unpaid' AND lr.status = 'approved' AND lr.deleted_at IS NULL
               AND lr.start_date <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date
               AND lr.end_date   >= date_trunc('month', p_month)::date
        ) END;
    $fix$;

    -- C1 只有 module.hr.view 的读者:真值
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    v_num := attendance_unpaid_days(e_emp, '2026-08-01');
    RESET ROLE;
    IF v_num IS DISTINCT FROM (r->>'C_truth')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 174C1 失败:只有 module.hr.view 的读者应当读得到真值 %,实得 %', r->>'C_truth', COALESCE(v_num::text,'NULL');
    END IF;
    -- C2 既无 hr.view、也不是本人:NULL,不是 0
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
    v_num := attendance_unpaid_days(e_emp, '2026-08-01');
    RESET ROLE;
    IF v_num IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174C2 失败:无权限读者应得 NULL(受限),实得 % —— 0 与"受限"不是一回事,而这个数是工资的扣减项', v_num;
    END IF;
    -- C3 本人(零权限):真值 —— 合法的那条路没有被判据打断
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_self), true);
    v_num := attendance_unpaid_days(e_emp, '2026-08-01');
    RESET ROLE;
    IF v_num IS DISTINCT FROM (r->>'C_truth')::numeric THEN
        RAISE EXCEPTION 'FIXTURE 174C3 失败:本人应当仍然读得到自己的 %,实得 %', r->>'C_truth', COALESCE(v_num::text,'NULL');
    END IF;
    -- C4 本人【读别人】:仍然是 NULL —— OR 那一支是有范围的,不是一个口子
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_self), true);
    v_num := attendance_unpaid_days(e_mgr, '2026-08-01');
    RESET ROLE;
    IF v_num IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174C4 失败:本人读【别人】的无薪假应得 NULL,实得 % —— OR 本人那一支开成了口子', v_num;
    END IF;
    r := r || jsonb_build_object('C_fixed','hr=真值 / 无权限=NULL / 本人=真值 / 本人读别人=NULL');

    -- ══════════════════════════════════════════════════════════════════════
    -- D · resolve_review_reviewer:NULL 【已经有主】,所以拒绝只能 RAISE
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 这一臂是本刀那条判据的活证据 ★
    --   注入的"旧版本"不是"没有判据",而是**一个照委托书原话写的、返回 NULL 的
    --   判据版本** —— 它看起来完全像一次修复。而断言要说明的正是:
    --   **它与"解析不出评估人"在结果上一个字都不差**,于是没有人会看见它。
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    v_uuid := resolve_review_reviewer(e_emp);
    IF v_uuid IS DISTINCT FROM e_mgr THEN
        RAISE EXCEPTION 'FIXTURE 174D 前提失败:全权限读者应当解析到上级部门经理,实得 %', COALESCE(v_uuid::text,'NULL');
    END IF;
    r := r || jsonb_build_object('D_truth','上级部门经理');

    -- 【一个真的"解析不出来"的人】—— 它就是 NULL 的合法含义,而 hr_alerts 等着它。
    -- e_mgr 自己在 FIX174-P,而 FIX174-P 的经理【就是他自己】,上面又没有父部门,
    -- 于是三级解析每一级都排除本人 → NULL。
    v_uuid := resolve_review_reviewer(e_mgr);
    IF v_uuid IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174D 前提失败:部门经理自己应当解析不出评估人(NULL),实得 % —— 没有这个对照,下面那条"分不开"就无从说起', v_uuid;
    END IF;
    r := r || jsonb_build_object('D_legit_null','部门经理自己 → NULL(hr_alerts 的 review_no_reviewer 等的就是它)');

    -- ── 注入【照委托书写的那种"修复"】:无权限也返回 NULL ──────────────────
    CREATE OR REPLACE FUNCTION public.resolve_review_reviewer(p_employee_id uuid)
     RETURNS uuid LANGUAGE sql STABLE AS $inj$
        SELECT CASE WHEN has_permission('module.hr.view'::text) THEN (
            SELECT COALESCE(NULLIF(d.manager_employee_id, e.id), NULLIF(pd.manager_employee_id, e.id))
              FROM employees e
              LEFT JOIN departments d  ON d.id = e.department_id
              LEFT JOIN departments pd ON pd.id = d.parent_department_id
             WHERE e.id = p_employee_id
        ) END;
    $inj$;

    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
    v_uuid := resolve_review_reviewer(e_emp);      -- 一个【有】经理的人
    RESET ROLE;
    -- ★★ 这就是那件事:一个有经理的人,被无权限的读者读成了 NULL,
    --    而 NULL 的意思是"没有评估人" —— 两件完全不同的事,同一个字节。★★
    IF v_uuid IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174D 注入无效:返回 NULL 的那种"修复"应当把一个【有经理的人】读成 NULL,实得 % —— 注入没生效', v_uuid;
    END IF;
    r := r || jsonb_build_object('D_injected_null_cure','NULL —— 与"解析不出评估人"一个字都不差');

    -- ── 换回 RAISE 版本 ───────────────────────────────────────────────────
    CREATE OR REPLACE FUNCTION public.resolve_review_reviewer(p_employee_id uuid)
     RETURNS uuid LANGUAGE plpgsql STABLE AS $fix$
    DECLARE v_reviewer uuid;
    BEGIN
        IF NOT has_permission('module.hr.view'::text) THEN
            RAISE EXCEPTION 'REVIEWER_RESOLUTION_PERMISSION_DENIED|%', 'module.hr.view';
        END IF;
        SELECT COALESCE(NULLIF(d.manager_employee_id, e.id), NULLIF(pd.manager_employee_id, e.id))
          INTO v_reviewer
          FROM employees e
          LEFT JOIN departments d  ON d.id = e.department_id
          LEFT JOIN departments pd ON pd.id = d.parent_department_id
         WHERE e.id = p_employee_id;
        RETURN v_reviewer;
    END $fix$;

    v_txt := NULL;
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_ops), true);
        v_uuid := resolve_review_reviewer(e_emp);
        RESET ROLE;
        v_txt := 'NO REFUSAL: ' || COALESCE(v_uuid::text,'NULL');
    EXCEPTION WHEN OTHERS THEN
        RESET ROLE; v_txt := SQLERRM;
    END;
    IF v_txt NOT LIKE 'REVIEWER_RESOLUTION_PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 174D 失败:无 hr.view 的读者应当撞上按名拒绝,实得 % —— 返回 NULL 会与"解析不出评估人"混成一件事', v_txt;
    END IF;
    -- 而合法读者仍然解析得到,并且【真的解析不出来时仍然是 NULL】——
    -- 拒绝没有把那个合法含义吃掉。
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_hr), true);
    v_uuid := resolve_review_reviewer(e_emp);
    IF v_uuid IS DISTINCT FROM e_mgr THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 174D 失败:有 hr.view 的读者应当仍解析到经理,实得 %', COALESCE(v_uuid::text,'NULL');
    END IF;
    v_uuid := resolve_review_reviewer(e_mgr);
    RESET ROLE;
    IF v_uuid IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174D 失败:真的解析不出来时仍然必须是 NULL(hr_alerts 等着它),实得 %', v_uuid;
    END IF;
    r := r || jsonb_build_object('D_fixed','受限=按名拒绝 / 有权限=经理 / 真的没有=NULL(三者分得开)');

    -- ══════════════════════════════════════════════════════════════════════
    -- E · inbound_batch_landed_unit_cost —— R3:授权不是控制
    -- ══════════════════════════════════════════════════════════════════════
    -- ★【本臂【刻意】以一个【拿得到 EXECUTE】的调用者身份去问】★
    --   线上这支函数没有授给 authenticated,所以"调不到"。R3 说的正是:
    --   那是一条授权,不是一道检查。所以本臂不切数据库角色 —— 身份仍然由
    --   request.jwt.claims 决定,而 EXECUTE 是有的。**问的是:如果它被授权了,
    --   它自己拦不拦得住?** 这与 README 第 6 条不冲突:本臂的判据是
    --   has_permission,不是 RLS。
    INSERT INTO suppliers (code, legal_name, country, counterparty_type)
    VALUES ('FIX174-SUP','fixture 174 supplier','SG','goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, size_format_code)
    VALUES ('FIX174-M','fixture 174 pack','battery_material', true,'whole_pack','end_of_life','ev_traction')
    RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('FIX174-PRICED', v_mat, v_sup, 100, 100, 'kg', '2026-08-01', 7, 'other', 'fixture 174 自带数据')
    RETURNING id INTO b_priced;
    -- 一批【真的没有金额】的货 —— 它的 landed cost 合法地是 NULL,而 unpriced 为真。
    -- 这就是"本支的 NULL 已经有主"的那个主。
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('FIX174-UNPRICED', v_mat, v_sup, 100, 100, 'kg', '2026-08-01', NULL, 'other', 'fixture 174 自带数据')
    RETURNING id INTO b_unpriced;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    v_num := inbound_batch_landed_unit_cost(b_priced);
    IF v_num IS DISTINCT FROM 7 THEN
        RAISE EXCEPTION 'FIXTURE 174E 前提失败:全权限读者应得 7,实得 %', COALESCE(v_num::text,'NULL');
    END IF;
    IF inbound_batch_landed_unit_cost(b_unpriced) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 174E 前提失败:一批真的没有金额的货,landed cost 必须是 NULL —— 那是本支 NULL 的合法含义';
    END IF;
    r := r || jsonb_build_object('E_truth', v_num, 'E_legit_null','没有金额的批次 → NULL');

    -- ── E-inj-1:注入旧版本(没有任何判据)★ R3 的那件事 ★ ────────────────
    CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
     RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER
     SET search_path TO 'public','pg_temp' AS $inj$
        SELECT CASE
            WHEN ib.unit_price IS NULL
             AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0
            THEN NULL
            ELSE COALESCE(ib.unit_price, 0)
                 + CASE WHEN ib.quantity > 0
                        THEN (batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id)) / ib.quantity
                        ELSE 0 END
        END
        FROM inbound_batches ib WHERE ib.id = p_inbound_batch_id;
    $inj$;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_inv), true);
    v_num := inbound_batch_landed_unit_cost(b_priced);
    -- ★ 旧版本对一个【只有库存查看权、没有价格权】的调用者,原样交出价格。
    IF v_num IS DISTINCT FROM 7 THEN
        RAISE EXCEPTION 'FIXTURE 174E-inj1 注入无效:旧版本本应把价格原样交给一个没有 data.view_prices 的调用者(7),实得 % —— 注入没生效', COALESCE(v_num::text,'NULL');
    END IF;
    r := r || jsonb_build_object('E_inj1_old_hands_out_price', v_num);

    -- ── E-inj-2:注入一个【太窄】的判据(只写 data.view_prices)★ R2 ★ ──────
    CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
     RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
     SET search_path TO 'public','pg_temp' AS $narrow$
    DECLARE v numeric;
    BEGIN
        IF NOT has_permission('data.view_prices'::text) THEN
            RAISE EXCEPTION 'LANDED_COST_PERMISSION_DENIED|%', 'data.view_prices';
        END IF;
        SELECT CASE
            WHEN ib.unit_price IS NULL
             AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0
            THEN NULL
            ELSE COALESCE(ib.unit_price, 0)
                 + CASE WHEN ib.quantity > 0
                        THEN (batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id)) / ib.quantity
                        ELSE 0 END
        END INTO v FROM inbound_batches ib WHERE ib.id = p_inbound_batch_id;
        RETURN v;
    END $narrow$;

    v_txt := NULL;
    BEGIN
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_stku), true);
        v_num := inbound_batch_landed_unit_cost(b_priced);
        v_txt := 'NO REFUSAL: ' || COALESCE(v_num::text,'NULL');
    EXCEPTION WHEN OTHERS THEN v_txt := SQLERRM;
    END;
    -- ★ 太窄的判据会当场打死盘点/注销那条路 —— 而 operations 与 warehouse
    --   这两个【真的在做盘点的角色】都没有 data.view_prices(线上实测)。
    IF v_txt NOT LIKE 'LANDED_COST_PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 174E-inj2 注入无效:只写 data.view_prices 的判据本应把持 module.stocktakes.edit 的读者也拒掉,实得 % —— 说明 OR stocktakes.edit 那一支没有被真的用到', v_txt;
    END IF;
    r := r || jsonb_build_object('E_inj2_narrow_breaks_stocktake', v_txt);

    -- ── 换回新版本 ────────────────────────────────────────────────────────
    CREATE OR REPLACE FUNCTION public.inbound_batch_landed_unit_cost(p_inbound_batch_id uuid)
     RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER
     SET search_path TO 'public','pg_temp' AS $fix$
    DECLARE v_cost numeric;
    BEGIN
        IF NOT (has_permission('data.view_prices'::text)
                OR has_permission('module.stocktakes.edit'::text)) THEN
            RAISE EXCEPTION 'LANDED_COST_PERMISSION_DENIED|%', 'data.view_prices';
        END IF;
        SELECT CASE
            WHEN ib.unit_price IS NULL
             AND batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id) = 0
            THEN NULL
            ELSE COALESCE(ib.unit_price, 0)
                 + CASE WHEN ib.quantity > 0
                        THEN (batch_freight_base_all(ib.id) + batch_processing_cost_base_all(ib.id)) / ib.quantity
                        ELSE 0 END
        END INTO v_cost FROM inbound_batches ib WHERE ib.id = p_inbound_batch_id;
        RETURN v_cost;
    END $fix$;

    -- E1 只有 module.inventory.view 的调用者:【按名拒绝】,不是 NULL
    v_txt := NULL;
    BEGIN
        PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_inv), true);
        v_num := inbound_batch_landed_unit_cost(b_priced);
        v_txt := 'NO REFUSAL: ' || COALESCE(v_num::text,'NULL');
    EXCEPTION WHEN OTHERS THEN v_txt := SQLERRM;
    END;
    IF v_txt NOT LIKE 'LANDED_COST_PERMISSION_DENIED%' THEN
        RAISE EXCEPTION 'FIXTURE 174E1 失败:没有价格权也没有盘点权的调用者应当撞上按名拒绝,实得 % —— 返回 NULL 会与"这批货没有金额"混成一件事', v_txt;
    END IF;
    -- E2 盘点/注销那条路:仍然算得出全额(R2 的"太窄"那一半被挡住了)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_stku), true);
    v_num := inbound_batch_landed_unit_cost(b_priced);
    IF v_num IS DISTINCT FROM 7 THEN
        RAISE EXCEPTION 'FIXTURE 174E2 失败:持 module.stocktakes.edit 但【没有】data.view_prices 的读者应当仍算得出 7,实得 % —— 注销与盘点要拿这个数过账', COALESCE(v_num::text,'NULL');
    END IF;
    -- E3 有价格权的读者:全额
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_all), true);
    IF inbound_batch_landed_unit_cost(b_priced) IS DISTINCT FROM 7 THEN
        RAISE EXCEPTION 'FIXTURE 174E3 失败:有 data.view_prices 的读者应得 7';
    END IF;
    r := r || jsonb_build_object('E_fixed','inventory-only=按名拒绝 / stocktakes=7 / prices=7');

    -- ══════════════════════════════════════════════════════════════════════
    -- F · 「有没有价」是事实,不是价 —— 价格被遮蔽的读者【没有被新打断】
    -- ══════════════════════════════════════════════════════════════════════
    -- ★ 这一臂钉住的是【反方向的失败】★ E 臂让价格函数会拒绝了,而
    --   inbound_batch_valuation 的 unpriced 一列本来就该给"看得见库存、看不见价格"
    --   的读者看(INV-VAL-1)。如果那一列还调价格函数,整页会当场变红。
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_inv), true);
    SELECT count(*) INTO v_n FROM inbound_batch_valuation;
    RESET ROLE;
    IF v_n < 2 THEN
        RAISE EXCEPTION 'FIXTURE 174F 失败:价格被遮蔽的库存读者应当仍看得到两行批次,实得 % 行 —— 判据把一条合法的路整页打断了', v_n;
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_inv), true);
    SELECT bool_and(landed_unit_cost IS NULL) INTO v_bool FROM inbound_batch_valuation;
    IF NOT v_bool THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 174F 失败:没有 data.view_prices 的读者不该看到任何金额';
    END IF;
    SELECT unpriced INTO v_bool FROM inbound_batch_valuation WHERE code = 'FIX174-PRICED';
    IF v_bool IS DISTINCT FROM false THEN
        RESET ROLE;
        RAISE EXCEPTION 'FIXTURE 174F 失败:有价的批次对被遮蔽的读者也必须显示 unpriced=false —— "有没有价"是事实,不是价;实得 %', COALESCE(v_bool::text,'NULL');
    END IF;
    SELECT unpriced INTO v_bool FROM inbound_batch_valuation WHERE code = 'FIX174-UNPRICED';
    RESET ROLE;
    IF v_bool IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FIXTURE 174F 失败:没有金额的批次必须显示 unpriced=true,实得 %', COALESCE(v_bool::text,'NULL');
    END IF;
    r := r || jsonb_build_object('F_masked_reader','两行都在 / 金额全 NULL / unpriced 仍然分得出真假');

    -- 【NOTICE 不是 EXCEPTION】gate 逐个跑本目录的 fixture,任何错误都算失败 ——
    -- 报告要印出来,但不能把整份 fixture 变成"失败"(FIXTURE_REPORT 那个抛出式
    -- 只用于 Management API 那种交互式取回)。回滚由文件末尾的 ROLLBACK 负责。
    RAISE NOTICE 'FIXTURE 174 通过:%', jsonb_pretty(r);
END $$;
ROLLBACK;

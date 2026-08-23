-- 111 保养间隔:到期与将到期是【两件事】,而「未监控」既不是零也不是「未到期」
--
-- EQP-2c。臂与它们要钉的东西:
--   F1 前提 —— 既有的支【一支不多、一支不少、一行不多】。本刀只往末尾加两支。
--   F2 公斤那一支的边界:恰好等于间隔 = 到期;差一个单位 = 不到期。两头都断言。
--   F3 天数那一支【独立于】公斤那一支:各自单独够用。两个方向。
--   F4 没有间隔行的机器【一支都不响】,而且它在状态视图里读到的是 NULL,不是零。
--   F5 从未保养过的机器,基线【就是】取得日 —— 断言那个【数】,不只是"有一行"。
--      并且断言那个数看不见的部分:取得日【之前】的加工一公斤都不算,
--      而窗口里没人归属的炉数由 unattributed_runs_in_window 说出来。
--   F6 提前量是【现读】的:同一笔事务里改它,那一支两个方向都动。
--
-- 【F1 有两半,写清楚哪一半在哪里 —— 因为只做一半会看起来像做全了】
-- * 【文本那一半】"其余二十八支逐字节未动"由拼接脚本在【构建时】反证:把新块原样
--   从镜像里拿掉,必须还原成拼之前那份文件的每一个字节(见本刀报告 S2)。
--   **一份 SQL fixture 做不到这件事** —— 它手上没有"拼之前"那份文本,而把五百行
--   viewdef 抄成一个常量只会造出第三份会漂开的副本。
-- * 【行为那一半】在这里:支的清单是【恰好】那三十支(多、少、改名都按名报红),
--   而且本 fixture 立起一台【到期的】机器之后,除了新的那两支,其余每一支仍然是
--   **0 行**。少了这一半,一支新臂完全可能顺手把别人的行也吐出来。
--
-- 【README 第 6 条:切数据库角色】operations_now 与 equipment_service_status 都是
-- 属主权限视图,判据在 has_permission(读 request.jwt.claims,与库角色无关)——
-- 也就是说不切角色也拿得到"像是对的"结果。仍然切,理由有两条:走的是与真实读者
-- 相同的那扇门,并且顺带验掉两张视图的 GRANT SELECT TO authenticated。
--
-- 【README 第 4/5 条】全部业务日期由本 fixture 自己相对 CURRENT_DATE 算出,不依赖
-- 任何会随日历过期的引导数据;locked_before 开头显式清空(本 fixture 不过账,
-- 但第 5 条说的正是"哪怕默认值恰好是对的也要写下来")。
--
-- 【重建库里没有任何业务数据】每一台机器、每一炉加工、每一条保养都是本文件自己插的,
-- 用例之间不共享(README 第 2 条)。资产与加工用直接 INSERT 而不走 RPC:被测的是
-- 【推导】,而 commit_processing_run 要一整条物料/批次链,那条链与本刀的判据无关,
-- 借它只会让失败的原因变多、而不是让断言变强。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all  uuid;
    v_ccy  text;
    a_kg_due uuid := gen_random_uuid(); a_kg_under uuid := gen_random_uuid();
    a_day_due uuid := gen_random_uuid(); a_day_under uuid := gen_random_uuid();
    a_none uuid := gen_random_uuid(); a_fresh uuid := gen_random_uuid();
    a_lead uuid := gen_random_uuid();
    r_fin uuid; r_prc uuid; r_oth uuid;
    u_fin uuid := gen_random_uuid(); u_prc uuid := gen_random_uuid(); u_oth uuid := gen_random_uuid();
    v_types text[]; v_n int; v_n2 int; v_num numeric; v_big bigint;
    v_noint uuid; v_kg numeric;   -- FIX-2 的 A3 半臂
    v_b boolean; v_b2 boolean; v_b3 boolean; v_d date; v_d2 date; v_txt text;
    v_expected text[] := ARRAY['allocation_stale','ap_over_90','ar_over_90',
        'assay_unapplied','awaiting_assay','bank_unmatched','batch_unpriced',
        'claim_pending','container_documents_late','container_eta_overdue',
        'container_no_arrival','credit_over_limit','equipment_service_approaching',
        'equipment_service_due','free_time_expiring','fx_rate_gap','invoice_overdue',
        'leave_pending','margin_cost_not_allocated','metal_quote_stale',
        'orders_unfulfilled','output_unsold_aging','po_awaiting_receipt',
        'qualification_expiring','qualification_missing','review_submitted',
        'safety_stock_below','stocktake_open','work_order_overdue',
        'work_order_variance_beyond'];
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;

    -- ── 角色:自建、授全部权限(README「自建角色,不借引导角色」)────────────
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-111', 'f111', 'f111', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);

    -- ── 七台机器,每一台只为一条判据存在 ──────────────────────────────────
    -- 取得日一律 CURRENT_DATE - 400:早于本文件插的每一炉加工,于是"归属得了"
    -- 这个前提对每一台都成立 —— 被测的是推导,不是归属那条守卫(它是 EQP-2a 的)。
    INSERT INTO fixed_assets (id, code, description, category, acquisition_date,
        cost_ccy, currency, fx_rate, cost_base, useful_life_months, residual_base,
        depreciation_account_code, status)
    SELECT x.id, x.code, x.descr, 'equipment', CURRENT_DATE - 400,
           1000, v_ccy, 1, 1000, 120, 0, '6000', x.st
      FROM (VALUES
        (a_kg_due,    'ZZF111-KGDUE',   'F2 kg exactly at interval', 'active'),
        (a_kg_under,  'ZZF111-KGUNDER', 'F2 kg one unit below',      'active'),
        (a_day_due,   'ZZF111-DAYDUE',  'F3 days exactly at interval','active'),
        (a_day_under, 'ZZF111-DAYUND',  'F3 days one day below',     'active'),
        (a_none,      'ZZF111-NONE',    'F4 no interval row at all', 'active'),
        (a_fresh,     'ZZF111-FRESH',   'F5 never serviced',         'active'),
        (a_lead,      'ZZF111-LEAD',    'F6 lead read live',         'active')
      ) AS x(id, code, descr, st);

    -- ── 间隔 ────────────────────────────────────────────────────────────────
    -- 每一行只配它那一条判据要的那个量度,另一个留空 —— F3 要证的正是
    -- 【各自单独够用】,而两个都配上会让"是哪一个让它到期的"变得说不清。
    INSERT INTO equipment_service_intervals
        (equipment_id, kind, interval_kg, lead_kg, interval_days, lead_days, disposition)
    VALUES
        (a_kg_due,    'service', 1000, 0,    NULL, NULL, 'warn'),
        (a_kg_under,  'service', 1000, 0,    NULL, NULL, 'warn'),
        (a_day_due,   'service', NULL, NULL, 30,   0,    'warn'),
        (a_day_under, 'service', NULL, NULL, 30,   0,    'warn'),
        (a_fresh,     'service', 5000, 0,    NULL, NULL, 'warn'),
        (a_lead,      'service', 1000, 100,  NULL, NULL, 'warn');
    -- a_none 【故意】没有间隔行 —— 那就是 F4 的全部内容。

    -- ── 保养记录:四台有(基线 = 上一次保养),a_fresh 与 a_none 一条都没有 ──
    INSERT INTO equipment_maintenance
        (equipment_id, performed_on, kind, description, performed_by_name)
    VALUES
        (a_kg_due,    CURRENT_DATE - 100, 'service', 'f111 baseline', 'ZZ-F111'),
        (a_kg_under,  CURRENT_DATE - 100, 'service', 'f111 baseline', 'ZZ-F111'),
        (a_day_due,   CURRENT_DATE - 30,  'service', 'f111 baseline', 'ZZ-F111'),
        (a_day_under, CURRENT_DATE - 29,  'service', 'f111 baseline', 'ZZ-F111'),
        (a_lead,      CURRENT_DATE - 100, 'service', 'f111 baseline', 'ZZ-F111'),
        -- 【一条 repair,专为"按 kind 逐一匹配"这条】它落在 a_day_under 上、
        -- 而且比那台机器的 service 更晚:如果推导忘了按 kind 过滤,基线会被它
        -- 拉到今天,a_day_under 会从"差一天"变成"刚保养过" —— 而两者都是"不到期",
        -- 于是【那个 bug 不会让任何断言变红】。所以另外单独断言 last_service_date。
        (a_day_under, CURRENT_DATE - 1,   'repair',  'f111 wrong-kind decoy', 'ZZ-F111');

    -- ── 加工:公斤那一半 ────────────────────────────────────────────────────
    INSERT INTO processing_runs (code, process_date, total_input, status, allocation_basis, equipment_id)
    VALUES
        -- F2 恰好到线:600 + 400 = 1000
        ('ZZF111-R01', CURRENT_DATE - 90, 600, 'committed', 'weight', a_kg_due),
        ('ZZF111-R02', CURRENT_DATE - 80, 400, 'committed', 'weight', a_kg_due),
        -- F2 差一个单位:600 + 399 = 999
        ('ZZF111-R03', CURRENT_DATE - 90, 600, 'committed', 'weight', a_kg_under),
        ('ZZF111-R04', CURRENT_DATE - 80, 399, 'committed', 'weight', a_kg_under),
        -- F6 提前量:850
        ('ZZF111-R05', CURRENT_DATE - 90, 850, 'committed', 'weight', a_lead),
        -- F5 基线:取得日【之后】的两炉 = 750
        ('ZZF111-R06', CURRENT_DATE - 100, 300, 'committed', 'weight', a_fresh),
        ('ZZF111-R07', CURRENT_DATE - 80,  450, 'committed', 'weight', a_fresh),
        -- F5 取得日【之前】的一炉,7777 公斤,而且【归给了这台机器】。
        -- 【这一行经由那扇门是造不出来的】commit_processing_run 会按名拒
        -- (EQUIPMENT_NOT_ACQUIRED)。这里直插,为的是正面钉住【窗口的下沿】:
        -- 少了 process_date >= baseline_date 那一句,kg_since 会读成 8527。
        ('ZZF111-R08', CURRENT_DATE - 500, 7777, 'committed', 'weight', a_fresh),
        -- F5「看不见的磨损」:窗口【之内】、谁都没归属的一炉
        ('ZZF111-R09', CURRENT_DATE - 50, 999, 'committed', 'weight', NULL);
    -- 已冲销的一炉【不算数】(EQP-2a 那条"status 与 deleted_at 两标记同源"),
    -- 归给 a_kg_under —— 算进去它就从 999 变成 1999,当场越过 F2 的下沿。
    -- 【直接带着 deleted_at 插】软删守卫只管 UPDATE 那一刻(从在册变成已删),
    -- 而本 fixture 要的是一行"生来就是已冲销"的状态,不是走一遍删除流程。
    INSERT INTO processing_runs (code, process_date, total_input, status, allocation_basis,
        equipment_id, deleted_at, deleted_by, delete_reason)
    VALUES ('ZZF111-R10', CURRENT_DATE - 70, 1000, 'reversed', 'weight',
            a_kg_under, now(), v_user, 'f111 reversed run must not count');

    -- ══════════ 读回一律切角色(README 第 6 条)══════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ F2 公斤:恰好等于间隔 = 到期;差一个单位 = 不到期 ════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT kg_since, is_due INTO v_num, v_b
      FROM equipment_service_status WHERE equipment_id = a_kg_due;
    RESET ROLE;
    IF v_num <> 1000 THEN
        RAISE EXCEPTION 'FIXTURE 111F2 失败:进入 F2 —— 恰好到线那台的 kg_since 应当是 1000(600+400),实得 % —— 若是 2000,说明已冲销的那一炉被算了进去', v_num;
    END IF;
    IF v_b IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 111F2 失败:进入 F2 —— kg_since 恰好等于 interval_kg 时【就是】到期(判据是 >=,不是 >)。保养间隔是一条约定:到 1000 公斤那一刻它就该做了;这与 metal_quote_stale 的 > 刻意不同(那里量的是【年龄】,"恰好 14 天"还在窗口内),两者不要顺手统一';
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT kg_since, is_due, is_approaching INTO v_num, v_b, v_b2
      FROM equipment_service_status WHERE equipment_id = a_kg_under;
    RESET ROLE;
    IF v_num <> 999 THEN
        RAISE EXCEPTION 'FIXTURE 111F2 失败:进入 F2 —— 差一个单位那台的 kg_since 应当是 999,实得 %', v_num;
    END IF;
    IF v_b IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 111F2 失败:进入 F2 —— 差一个单位(999 / 1000)必须【不到期】。只断言"到期"那一头,一个恒真的实现照样通过';
    END IF;

    -- ══════════ F3 天数:独立于公斤,各自单独够用,两个方向 ══════════════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT days_since, is_due, due_reason, interval_kg IS NULL, last_service_date
      INTO v_n, v_b, v_txt, v_b2, v_d
      FROM equipment_service_status WHERE equipment_id = a_day_due;
    RESET ROLE;
    IF v_n <> 30 OR v_b IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 111F3 失败:进入 F3 —— 上一次保养正好 30 天前、间隔 30 天,必须到期(days_since=%,is_due=%)', v_n, v_b;
    END IF;
    IF v_txt IS DISTINCT FROM 'days' OR v_b2 IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 111F3 失败:进入 F3 —— 这台机器【一条公斤间隔都没配、一炉加工都没有】,却到期了,理由必须是 days(实得 %)。这一条与 F2 那台(只配公斤、没配天数)合起来才是"各自单独够用";只留一台,一个把两个量度【相与】的实现会全绿', v_txt;
    END IF;
    IF v_d <> CURRENT_DATE - 30 THEN
        RAISE EXCEPTION 'FIXTURE 111F3 失败:进入 F3 —— 基线读错了(%)', v_d;
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT days_since, is_due, last_service_date
      INTO v_n, v_b, v_d FROM equipment_service_status WHERE equipment_id = a_day_under;
    RESET ROLE;
    IF v_n <> 29 OR v_b IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 111F3 失败:进入 F3 —— 差一天(29 / 30)必须不到期(days_since=%,is_due=%)', v_n, v_b;
    END IF;
    IF v_d <> CURRENT_DATE - 29 THEN
        RAISE EXCEPTION 'FIXTURE 111F3 失败:进入 F3 —— 基线必须只看【同一种】活。这台机器一天前有一条 repair,而它配的是 service 的间隔;把 repair 也算进基线,last_service_date 会变成昨天(实得 %)。**注意这个 bug 不会让上面那条 is_due 变红** —— 昨天保养过与差一天到期都是"不到期",所以它必须被单独断言', v_d;
    END IF;

    -- ══════════ F4 没有间隔行 =【未监控】,而它不是零、也不是「未到期」════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM equipment_service_status WHERE equipment_id = a_none;
    SELECT monitored, is_due, kg_since, days_since, baseline_date, never_serviced
      INTO v_b, v_b2, v_num, v_n2, v_d, v_b3
      FROM equipment_service_status WHERE equipment_id = a_none;
    RESET ROLE;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 111F4 失败:进入 F4 —— 没有间隔行的机器【仍然要在状态视图里有一行】,实得 % 行。整台机器消失,与"它没事"在屏幕上一模一样(equipment_usage 那句 LEFT JOIN 是刻意的,同源)', v_n;
    END IF;
    IF v_b IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 111F4 失败:进入 F4 —— monitored 必须是 false(实得 %)', v_b;
    END IF;
    IF v_b2 IS NOT NULL OR v_num IS NOT NULL OR v_n2 IS NOT NULL
       OR v_d IS NOT NULL OR v_b3 IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 111F4 失败:进入 F4 —— 「未监控」的每一个量度都必须是 NULL,不是 0 / false。is_due=%、kg_since=%、days_since=%、baseline_date=%、never_serviced=%。**is_due = false 读起来就是「查过了,不到期」,而真相是"没有人决定要盯它"** —— 这正是 METAL-1 的 no_reference 与 SS-1 那条安全库存阈值的同一课', v_b2, v_num, v_n2, v_d, v_b3;
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type IN ('equipment_service_due','equipment_service_approaching')
       AND item_id = a_none;
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 111F4 失败:进入 F4 —— 未监控的机器一支都不许响,实得 % 行', v_n;
    END IF;

    -- ══════════ F5 从未保养过:基线【就是】取得日,而那个 0 有两种意思 ════════
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT never_serviced, baseline_date, last_service_date, kg_since,
           unattributed_runs_in_window, days_since
      INTO v_b, v_d, v_d2, v_num, v_big, v_n
      FROM equipment_service_status WHERE equipment_id = a_fresh;
    RESET ROLE;
    IF v_b IS NOT TRUE OR v_d2 IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 111F5 失败:进入 F5 —— 一条保养都没有的机器,never_serviced 必须是 true 且 last_service_date 必须是 NULL(实得 %、%)', v_b, v_d2;
    END IF;
    IF v_d <> CURRENT_DATE - 400 THEN
        RAISE EXCEPTION 'FIXTURE 111F5 失败:进入 F5 —— 从未保养过的机器,基线【就是取得日】(应 %,实得 %)。用投用日会静默出事:线上那台的 in_service_date 是 2027-01-01,一个【未来】日期,天数量度会变成负数而永不到期;而投用日还可空,NULL 会让整个天数量度消失', CURRENT_DATE - 400, v_d;
    END IF;
    IF v_n <> 400 THEN
        RAISE EXCEPTION 'FIXTURE 111F5 失败:进入 F5 —— days_since 应当从取得日起算 = 400,实得 %', v_n;
    END IF;
    -- 【断言那个数本身,不只是"有一行"】750 = 300 + 450,取得日之后的两炉。
    IF v_num <> 750 THEN
        RAISE EXCEPTION 'FIXTURE 111F5 失败:进入 F5 —— 基线窗口内的投料应当恰好是 750(300 + 450),实得 %。**若是 8527,说明窗口的下沿丢了** —— 那一炉 7777 公斤的加工日期早于取得日,而 EQP-2a 明写着那天这台机器还不是我们的(commit_processing_run 会按名拒 EQUIPMENT_NOT_ACQUIRED,这一行是直插进来的,正为了钉住这条边)', v_num;
    END IF;
    -- 【看不见的那一半:窗口里有一炉谁都没归属】
    IF v_big <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 111F5 失败:进入 F5 —— unattributed_runs_in_window 应当是 1(窗口里那一炉 equipment_id 为空的加工),实得 %。这一列是"低读数有两种意思"里【量得到】的那一半:它 > 0 时,一个低 kg_since 不构成"磨损得少"的证据。它 = 0 也不证明记全了 —— 取得日左边的历史根本不在窗口里,而那正是线上那台机器今天的处境', v_big;
    END IF;

    -- ══════════ F6 提前量是【现读】的 —— 同一笔事务里改,两个方向都要动 ══════
    -- 850 公斤 / 间隔 1000。lead=100 → 门槛 900,850 < 900,不响。
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT is_approaching, is_due, kg_since INTO v_b, v_b2, v_num
      FROM equipment_service_status WHERE equipment_id = a_lead;
    RESET ROLE;
    IF v_num <> 850 OR v_b2 IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:进入 F6 —— 前提没立住(kg_since=%,is_due=%)', v_num, v_b2;
    END IF;
    IF v_b IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:进入 F6 —— lead_kg = 100 时门槛是 900,850 【不该】报将到期';
    END IF;
    -- lead=200 → 门槛 800,850 >= 800,该响
    UPDATE equipment_service_intervals SET lead_kg = 200 WHERE equipment_id = a_lead;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT is_approaching, is_due, approaching_reason INTO v_b, v_b2, v_txt
      FROM equipment_service_status WHERE equipment_id = a_lead;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'equipment_service_approaching' AND item_id = a_lead;
    RESET ROLE;
    IF v_b IS NOT TRUE OR v_n <> 1 OR v_txt IS DISTINCT FROM 'kg' THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:进入 F6 —— 把 lead_kg 从 100 改到 200(门槛 900 → 800),那一支【必须当场亮起】。is_approaching=%、臂上 % 行、reason=%。这一步测的是"提前量是现读的数据,不是写死的数"', v_b, v_n, v_txt;
    END IF;
    IF v_b2 IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:进入 F6 —— 将到期【不等于】到期,850 < 1000 不许报到期';
    END IF;
    -- 【反方向】改回去必须灭。单向的测试对一个"永远返回 true"的实现照样是绿的。
    UPDATE equipment_service_intervals SET lead_kg = 100 WHERE equipment_id = a_lead;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT is_approaching INTO v_b FROM equipment_service_status WHERE equipment_id = a_lead;
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type = 'equipment_service_approaching' AND item_id = a_lead;
    RESET ROLE;
    IF v_b IS NOT FALSE OR v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:进入 F6 —— 把 lead_kg 改回 100,那一支必须【灭】(is_approaching=%,臂上 % 行)。**只验一个方向,一个把阈值写死、或者干脆恒真的实现都会通过** —— fixture 76 立的就是这条判据', v_b, v_n;
    END IF;

    -- ══════════ F1 前提(行为那一半)—— 放在最后,因为它要两支都有行 ══════════
    -- README 第 5 条:前提显式设定。把 a_lead 推回"将到期",于是两支各有行。
    UPDATE equipment_service_intervals SET lead_kg = 200 WHERE equipment_id = a_lead;

    -- ① 支的清单【从线上的视图定义现读】,不从行里数 —— 重建库里绝大多数支
    --    一行数据都没有,按行数只能数到本 fixture 自己立起来的那两支。
    SELECT COALESCE(array_agg(DISTINCT m[1] ORDER BY m[1]), '{}') INTO v_types
      FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass),
                          '''([a-z_0-9]+)''::text AS item_type', 'g') m;
    IF array_length(v_types, 1) IS NULL OR array_length(v_types, 1) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 111F1 失败:进入 F1 —— 解析器一支都没解出来。**这是"解析器坏了",不是"没有支"** —— 空集不许被读成答案(check-i18n 后缀解析、mustRows、restRows 是同一条规矩)';
    END IF;
    IF v_types <> v_expected THEN
        RAISE EXCEPTION 'FIXTURE 111F1 失败:进入 F1 —— 支的清单应当【恰好】是这三十支 %,实得 %。多一支 = 有人加了臂而没有加规格行(docs/dashboard-arm-inventory.md 的规矩);少一支或改了名 = 本刀的拼接动了不该动的地方;而 dashboard.item.* 的 i18n 键集合【现读同一份清单】,所以两边必须一起动', v_expected::text, v_types::text;
    END IF;

    -- ② 隔离:本 fixture 立起来的数据只该点亮【新的那两支】。
    --    少了这一条,一支新臂完全可能顺手把别人的行也吐出来,而 ① 看不见。
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(array_agg(DISTINCT item_type ORDER BY item_type), '{}'), count(*)
      INTO v_types, v_n FROM operations_now;
    RESET ROLE;
    IF v_types <> ARRAY['equipment_service_approaching','equipment_service_due'] THEN
        RAISE EXCEPTION 'FIXTURE 111F1 失败:进入 F1 —— 本 fixture 只立了设备的数据,所以看板上只该有新的那两支,实得 %。**其余二十八支必须一行都不多** —— 这是"既有的支在内容上没有变"的行为那一半(文本那一半由拼接脚本在构建时反证:把新块原样拿掉必须逐字节还原)', v_types::text;
    END IF;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 111F1 失败:进入 F1 —— 应当恰好 3 行(到期 2:公斤那台 + 天数那台;将到期 1:提前量那台),实得 %。**到期的机器不许同时出现在"将到期"里** —— 那是同一件事数两遍,正是 fixture 30 那句话要抓的东西', v_n;
    END IF;

    -- ③ 门牌与日期(S5 的规矩:item_id 指向【承载补救动作】的那张页面对应的行)
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now o
     WHERE o.item_type IN ('equipment_service_due','equipment_service_approaching')
       AND NOT EXISTS (SELECT 1 FROM fixed_assets fa WHERE fa.id = o.item_id);
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 111F1 失败:进入 F1 —— 这两支的 item_id 必须落在 fixed_assets 上(补救动作"给这台机器记一次保养"发生在机器那一页 /finance/assets/[id]);间隔行今天没有自己的页面,所以指的是【父】—— 与 bank_unmatched / margin_cost_not_allocated 同一条。实得 % 行解析不到', v_n;
    END IF;
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT o.item_date, o.days_waiting INTO v_d, v_n FROM operations_now o
     WHERE o.item_type = 'equipment_service_due' AND o.item_id = a_kg_due;
    RESET ROLE;
    IF v_d <> CURRENT_DATE - 100 OR v_n <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 111F1 失败:进入 F1 —— item_date 必须是【基线日】(上一次那一种保养,没有就是取得日),于是 days_waiting 读出来就是"距上一次保养多少天",【正好就是两个量度里的天数那一个】,不是第三个数。实得 %、%', v_d, v_n;
    END IF;

    -- ══════════ G 放宽:财务与加工两边都看得见,别人一行都没有 ════════════════
    -- 本刀改了 arm_permission_widen,所以三种读者各钉一次。
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-111-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_fin, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_fin, r_fin);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-111-prc', 'f', 'f', true) RETURNING id INTO r_prc;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_prc, 'module.processing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_prc, r_prc);

    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-111-oth', 'f', 'f', true) RETURNING id INTO r_oth;
    INSERT INTO role_permissions (role_id, permission_code) VALUES (r_oth, 'module.hr.view');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_oth, r_oth);

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_prc), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type IN ('equipment_service_due','equipment_service_approaching');
    RESET ROLE;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 111G 失败:进入 G —— 只持 module.processing.view 的读者(这两支自己声明的码)应当看见全部 3 行,实得 %', v_n;
    END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type IN ('equipment_service_due','equipment_service_approaching');
    RESET ROLE;
    IF v_n <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 111G 失败:进入 G —— 只持 module.finance.view 的读者【也】应当看见这两支(机器卡在财务,而它们底下每一张表/视图的读者都是这两个码的 OR),实得 % 行。arm_permission_any 是【相与】的、只会收窄 —— 放宽必须走 arm_permission_widen(LOG-5a 那一整段)。**这一条钉的是"看得见数据却在首页读到「受限」"那个反向的谎**', v_n;
    END IF;

    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_oth), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM operations_now
     WHERE item_type IN ('equipment_service_due','equipment_service_approaching');
    RESET ROLE;
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 111G 失败:进入 G —— 两个码都没有的读者一行都不许看见(缺席,不是零),实得 %。放宽写宽了这一条会红', v_n;
    END IF;

    -- ══════════ F6(FIX-2 的 A3 半臂)· 没有间隔行时,那两个数【也在】 ══════════
    -- 【这一臂只能钉住数据那一半,渲染那一半进手走清单 —— 理由写在这里】
    -- FIX-2(A)把"取得日以来多少公斤"与那句诚实话搬到了【机器】身上:
    -- 没有间隔行时也要显示。**fixture 到不了渲染层**,但它到得了那两个数的来源 ——
    -- 而此前页面【根本不查】它们(那段代码写着"没有间隔行的机器根本不显示读数,
    -- 这个数也就没有用处"—— 把缺陷写成了意图)。
    -- 所以这里钉:一台【没有任何间隔行】的机器,
    --   ① equipment_service_status 一行都没有(所以旧写法什么都画不出来);
    --   ② 而 equipment_usage 仍然给得出公斤数 —— 那正是新写法的取数处。
    -- 【先把身份换回全权那个用户】上一臂结束时会话停在一个只有 module.hr.view
    -- 的用户上(那是它自己要测的东西)。equipment_usage 带
    -- `has_permission(finance.view) OR has_permission(processing.view)` 的谓词,
    -- 不换回来的话这里读到的是【没权限】,而不是【没有数】—— 两者在结果上
    -- 长得一模一样,而它们是两回事(README 第 6 条正是这一课)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO fixed_assets (code, description, category, acquisition_date,
                              cost_base, currency, cost_ccy, fx_rate, status,
                              useful_life_months, residual_base)
    VALUES ('ZZ111-NOINT', 'f111 unmonitored machine', 'equipment', CURRENT_DATE - 300,
            0, v_ccy, 0, 1, 'active', 100, 0)
    RETURNING id INTO v_noint;

    -- 【实测更正:这张视图【会】给一行,只是 monitored = false】
    -- 我先断言的是"一行都没有",跑起来红了 —— 红的是断言不是系统。
    -- 屏幕那一侧的判据本来就是 rows.filter(r => r.monitored).length === 0,
    -- 所以这里钉的应当是【没有一行是 monitored】,那才是"未监控"那一块的前提。
    IF EXISTS (SELECT 1 FROM equipment_service_status
                WHERE equipment_id = v_noint AND monitored) THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:没有间隔行的机器不该有任何 monitored = true 的行 —— 那正是"未监控"那一块的触发条件';
    END IF;

    SELECT input_kg INTO v_kg FROM equipment_usage WHERE equipment_id = v_noint;
    IF v_kg IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:**没有间隔行的机器,公斤数仍然要取得到** —— 那是 FIX-2(A)那块屏幕的取数处。取不到,未监控那一块就又只剩两句空话了(实得 NULL,而它应当是 0 或更多)';
    END IF;
    IF v_kg <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 111F6 失败:这台新机器还没跑过任何一炉,公斤数应当是 0(而【0 是一次测量】,不是"没有数")—— 实得 %', v_kg;
    END IF;
END $$;
ROLLBACK;

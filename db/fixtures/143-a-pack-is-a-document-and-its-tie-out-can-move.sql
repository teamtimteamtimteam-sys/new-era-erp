-- 143 报表包:一份【文书】,以及一条【动得开】的勾稽(GLEXPORT-1)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这份 fixture 钉八件事】
--   · **存档只受理已关账的月份** —— 开放月份按名拒;而这条裁定同时被表上的
--     CHECK 钉着,不只是函数里的一句 IF(A 臂)。
--   · **重出 = 新行 + 旧行 superseded + 必填理由**,而且【任何时刻只有一份在册】
--     (B 臂;那条部分唯一索引正是它的机制)。
--   · **包里的数是【调用】来的,不是算来的** —— 目录断言钉在【那几次调用】上,
--     而且先剥注释(C 臂)。
--   · ★**勾稽动得开**★ —— 往控制科目打一笔手工分录,未解释余额当场不为零(D 臂)。
--   · **三个分项真的在解释差额** —— 挂账付款让结算差异动,而余额仍然是 0(E 臂)。
--   · **跨月冲销对被认出来**,而且先证它本来是空的(F 臂)。
--   · **看不见什么要说出来** —— 未关账、账龄被封顶,两条都断言(G 臂)。
--   · **三支 SECURITY DEFINER 各自问过调用者是谁**(H 臂),**存档不可改**(I 臂)。
--
-- ★★【四个陷阱,逐个躲开,并写明躲法】★★
--   ① **靠"两个实现碰巧一致"通过**:C 臂【不】比两个数相等 —— 那正是
--      pnl_statement 与 balance_sheet 的关系(同一份推导两个开关),比了也证明不了
--      独立性。它比的是【调用形状确实在函数体里】。而真正的独立性由 D 臂承担:
--      账面侧与明细侧来自两套表,注入只动其中一侧,余额就动。
--   ② **目录断言匹配到注释**:C 臂先【剥掉注释行】再匹配,而且匹配的是带参数的
--      调用形状(`pnl_statement(v_start, v_end)`),不是 'pnl_statement' 这个子串 ——
--      那个子串在函数体的注释里出现好几次(fixture 136 与 CHASE-1 都栽过)。
--   ③ **一支没有权限检查的 SECURITY DEFINER 函数**:H 臂【行为性地】证它,
--      不写"函数体里有 require_permission"那种目录断言 —— 那只守措辞。
--      这个形状在本仓库上线过两次、两次都由闸抓住。
--   ④ ★**一条因为集合是空的而通过的断言**★ —— 这是本 fixture 最要小心的一个,
--      因为重建库【什么业务数据都没有】,所以"勾稽上了"在空库里是【恒真】的。
--      处置:每一条勾稽断言之前,先断言【两边都非零】(D/E 臂),
--      而 F 臂先断言跨月对子【本来是空的】再注入一对。
--      一条在空集上也成立的断言什么都没证明。
--
-- 自带数据(README 第 2 条);期间锁与 GST 开关自己设(第 4/5 条)。
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;
DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_nobody uuid := gen_random_uuid();
    -- 【关账的人不能是过账的人】SOD-1 的控制①(assert_segregated /
    -- guard_finance_settings_sod):在本期过过账的人不得关掉本期。
    -- 第一版用同一个人做两件事,gate 当场抛 SOD_POST_AND_CLOSE —— 那是对的,
    -- 而它正是 fixture 140 用 claimant/approver 两个人的同一个理由。
    v_closer uuid := gen_random_uuid();
    r_all    uuid;
    v_sup    uuid;
    v_base   text; v_bank text;
    -- 【自己造一个月,不借今天】用一个【过去的、可以关账的】月份;
    -- 借"上个月"会让这份 fixture 在月初/月末给出不同的答案。
    d_month  date := DATE '2026-03-01';
    d_in     date := DATE '2026-03-10';
    d_next   date := DATE '2026-04-05';   -- F 臂:冲销落在【下个月】
    v_res    jsonb; v_pack jsonb; v_recon jsonb; v_side jsonb;
    v_exp    uuid; v_je jsonb; v_je2 jsonb;
    v_led    numeric; v_sub numeric; v_unexp0 numeric; v_unexp1 numeric;
    v_sv0    numeric; v_sv1 numeric;
    v_n int; v_msg text; v_def text; v_body text;
    v_p1 jsonb; v_p2 jsonb; v_live int; v_total int;
    v_lock_at date;   -- 存下来的那一行上的关账线(A 臂;别拿 numeric 装日期)
BEGIN
    -- ══════════════════ 布景 ══════════════════
    INSERT INTO auth.users (id) VALUES (v_user), (v_nobody), (v_closer);
    INSERT INTO roles (code, name_en, name_zh, is_active)
    VALUES ('fixture-143', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all), (v_closer, r_all);
    -- v_nobody 【故意不给任何角色】—— H 臂要的就是"有账号、没权限"。

    -- 【前提显式设定,不继承】(README 第 4/5 条)
    --   · 期间锁 —— A 臂两个方向都要用它,所以自己开合;
    --   · GST 开关 —— 设成 false(重建库的引导默认值就是它),因为本刀与 GST 无关;
    --     写出来是为了让它是一个决定而不是一次继承。
    UPDATE finance_settings SET locked_before = NULL, gst_registered = false;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    v_bank := bank_account_for_currency(v_base);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F143-S', 'fixture 143 supplier', 'SG', 'active', 'service_vendor')
    RETURNING id INTO v_sup;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- 一笔【挂账】费用:它同时进 AP 明细账(单据)与总账 2000 —— 于是
    -- 勾稽的两边都非空,而这正是躲开陷阱④的前提。
    v_res := record_expense(
        p_expense_date := d_in, p_account_code := '6400', p_amount := 10000,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup);
    v_exp := (v_res->>'expense_id')::uuid;

    -- ══════════════════════════════════════════════════════════════════════
    -- D 臂(先跑,因为它建立后面几臂的基线)· ★**勾稽动得开**★
    -- ══════════════════════════════════════════════════════════════════════
    v_recon := gl_control_reconciliation(DATE '2026-03-31');
    SELECT s INTO v_side FROM jsonb_array_elements(v_recon->'sides') s
     WHERE s->>'side' = 'ap';
    v_led  := (v_side->>'ledger_base')::numeric;
    v_sub  := (v_side->>'subledger_base')::numeric;
    v_unexp0 := (v_side->>'unexplained_base')::numeric;
    v_sv0    := (v_side->>'settlement_variance_base')::numeric;

    -- ★ 躲开陷阱④:【先证两边都不是空的】。在一个什么都没有的库里,
    --   "勾稽上了"是恒真的,而一条恒真的断言什么都没证明。
    IF v_led = 0 OR v_sub = 0 THEN
        RAISE EXCEPTION 'FIXTURE 143D 失败(空转):账面 %、明细 % —— 有一边是零,这条勾稽在空集上恒真,证明不了任何事',
            v_led, v_sub;
    END IF;
    IF v_unexp0 <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 143D 失败:注入之前未解释余额就已经是 %,基线不干净', v_unexp0;
    END IF;

    -- ★【注入:一笔【手工分录】直接打进控制科目】★
    --   这正是现实中把明细账与总账弄散的头号原因,而 source_type='manual'
    --   【不在】三个被分类的来源里 —— 于是它必须原样落进未解释余额。
    --   一个给账面侧留了"其他"兜底桶的实现,在这里会报 0,当场红。
    v_je := post_journal_entry(d_in, 'fixture 143 manual into the control account',
        'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '6900', 'side', 'debit',
                'currency', v_base, 'amount_ccy', 777),
            jsonb_build_object('account_code', '2000', 'side', 'credit',
                'currency', v_base, 'amount_ccy', 777)));

    v_recon := gl_control_reconciliation(DATE '2026-03-31');
    SELECT s INTO v_side FROM jsonb_array_elements(v_recon->'sides') s WHERE s->>'side' = 'ap';
    v_unexp1 := (v_side->>'unexplained_base')::numeric;
    IF v_unexp1 = v_unexp0 THEN
        RAISE EXCEPTION 'FIXTURE 143D 失败:往控制科目打了一笔 777 的手工分录,而未解释余额没有动(仍是 %)—— 这条勾稽是装饰,不是检查',
            v_unexp1;
    END IF;
    IF v_unexp1 <> -777 THEN
        RAISE EXCEPTION 'FIXTURE 143D 失败:未解释余额应当【恰好】等于那笔没有人解释过的分录(−777),实得 %', v_unexp1;
    END IF;
    IF (v_side->>'reconciled')::boolean THEN
        RAISE EXCEPTION 'FIXTURE 143D 失败:未解释余额是 % 而 reconciled 仍然是 true', v_unexp1;
    END IF;
    -- 收场:冲掉它,后面几臂要一个干净的基线。
    PERFORM reverse_journal_entry((v_je->>'entry_id')::uuid, d_in, 'fixture 143 undo');

    -- ══════════════════════════════════════════════════════════════════════
    -- E 臂 · **三个分项真的在解释差额**(挂账付款让结算差异动,而余额仍是 0)
    -- ══════════════════════════════════════════════════════════════════════
    -- 付 5,000,只核销 3,000 —— 多出来的 2,000 挂账:它在总账里冲了 2000,
    -- 却没有冲任何一张单据。于是结算差异必须动,而【未解释余额不许动】。
    --
    -- ★【为什么【不】把这张单付清 —— 第一版就是这么写的,gate 当场抓住】★
    --   原本写的是"付 12,000、核销 10,000",以为结算差异会是那 2,000。
    --   **不会**:付清之后 `expenses.payment_status` 变成 'paid',这张单
    --   **整行离开 ap_open_items** —— 于是单据侧的面值与已冲额【一起消失】,
    --   结算差异变成 12,000(总账冲了 12,000,单据侧冲了 0)。
    --   那个 12,000 并不是错的,勾稽的未解释余额照样是 0;错的是我的期望值。
    --   **留一笔敞口,这个分项才量得到它要量的那件事。**
    PERFORM record_payment(
        p_direction := 'out', p_counterparty_id := v_sup, p_amount := 5000,
        p_currency := v_base, p_payment_date := d_in,
        p_allocations := jsonb_build_array(
            jsonb_build_object('expense_id', v_exp, 'amount_doc', 3000)));

    v_recon := gl_control_reconciliation(DATE '2026-03-31');
    SELECT s INTO v_side FROM jsonb_array_elements(v_recon->'sides') s WHERE s->>'side' = 'ap';
    v_sv1 := (v_side->>'settlement_variance_base')::numeric;
    IF v_sv1 = v_sv0 THEN
        RAISE EXCEPTION 'FIXTURE 143E 失败(空转):挂了 2,000 的账,而结算差异没有动(仍是 %)—— 这个分项没有在解释任何东西',
            v_sv1;
    END IF;
    IF v_sv1 <> 2000 THEN
        RAISE EXCEPTION 'FIXTURE 143E 失败:结算差异应当【恰好】是挂账的那 2000,实得 %', v_sv1;
    END IF;
    IF (v_side->>'unexplained_base')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 143E 失败:挂账是一件【解释得清】的事,余额不该动,实得 %',
            (v_side->>'unexplained_base')::numeric;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- F 臂 · **跨月冲销对被认出来** —— 先证它本来是空的(陷阱④)
    -- ══════════════════════════════════════════════════════════════════════
    v_pack := management_pack_data(d_month);
    IF jsonb_array_length(v_pack->'split_reversal_pairs') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 143F 失败(空转):注入之前就已经有 % 对跨月冲销 —— 基线不干净,下面那条断言证明不了是注入造成的',
            jsonb_array_length(v_pack->'split_reversal_pairs');
    END IF;
    -- 三月的一张分录,四月才冲销它 —— 于是三月带着一条没有对手的腿。
    v_je2 := post_journal_entry(d_in, 'fixture 143 march entry reversed in april',
        'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '6900', 'side', 'debit',
                'currency', v_base, 'amount_ccy', 55),
            jsonb_build_object('account_code', '2200', 'side', 'credit',
                'currency', v_base, 'amount_ccy', 55)));
    PERFORM reverse_journal_entry((v_je2->>'entry_id')::uuid, d_next, 'fixture 143 next-month reversal');

    v_pack := management_pack_data(d_month);
    IF jsonb_array_length(v_pack->'split_reversal_pairs') <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 143F 失败:三月那张分录的冲销落在四月,报表包应当认出【一对】,实得 %',
            jsonb_array_length(v_pack->'split_reversal_pairs');
    END IF;
    IF (v_pack->'caveats'->>'split_reversal_pairs_n')::int <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 143F 失败:认出来了却没有写进「看不见什么」那一段';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- G 臂 · **看不见什么要说出来**
    -- ══════════════════════════════════════════════════════════════════════
    IF (v_pack->'caveats'->>'month_not_locked')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 143G 失败:这个月还没关账,而包里没有说';
    END IF;
    -- 一个【未来的】月份:账龄取不到月末,必须被封顶并说出来。
    -- ★【用 +2 个月,不用"本月"】★ 本月在【月末那一天】会让
    --   LEAST(period_end, CURRENT_DATE) 恰好等于 period_end —— 于是封顶不发生,
    --   这一臂在每个月的最后一天变红,而代码一个字没改。
    --   这正是 README 第 4 条说的「绝不依赖随时间过期的东西」;
    --   往后推两个月,期末【永远】在未来,判据与日历无关。
    v_pack := management_pack_data((date_trunc('month', CURRENT_DATE) + INTERVAL '2 months')::date);
    IF (v_pack->'caveats'->>'aging_capped_at_today')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 143G 失败:当月的账龄必然取不到月末,而包里没有说它被封顶了';
    END IF;
    IF (v_pack->>'aging_as_of')::date >= (v_pack->>'period_end')::date THEN
        RAISE EXCEPTION 'FIXTURE 143G 失败(空转):账龄截止日 % 没有早于期末 % —— 这一臂没有测到封顶',
            v_pack->>'aging_as_of', v_pack->>'period_end';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · **存档只受理已关账的月份**(两个方向)
    -- ══════════════════════════════════════════════════════════════════════
    BEGIN
        PERFORM freeze_management_pack(d_month);
        RAISE EXCEPTION 'FIXTURE 143A 失败:一个【还没关账】的月份被存档了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PACK_MONTH_NOT_LOCKED%' THEN RAISE; END IF;
    END;

    -- 关账,再来一次。【换一个人来关】—— 见 v_closer 的声明处:
    -- 在本期过过账的人不得关掉本期(SOD-1 控制①)。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_closer), true);
    UPDATE finance_settings SET locked_before = DATE '2026-04-01';
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    v_p1 := freeze_management_pack(d_month, 'fixture 143');
    IF (v_p1->>'code') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 143A 失败:关账之后仍然存不下来';
    END IF;
    -- ★ 存下来的那一行必须带着【产出时的关账线】,而且它必须晚于期末 ——
    --   那正是"一份存档的包意味着那个月当时已经关账"由数据库保证的地方。
    SELECT locked_before_at_production INTO v_lock_at FROM management_packs
     WHERE id = (v_p1->>'pack_id')::uuid;
    IF v_lock_at IS NULL OR v_lock_at <= DATE '2026-03-31' THEN
        RAISE EXCEPTION 'FIXTURE 143A 失败:存下来的关账线是 %,它没有晚于期末', v_lock_at;
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · **重出 = 新行 + 旧行 superseded + 必填理由,且只有一份在册**
    -- ══════════════════════════════════════════════════════════════════════
    BEGIN
        PERFORM freeze_management_pack(d_month);
        RAISE EXCEPTION 'FIXTURE 143B 失败:这个月已经有一份在册的包,再出一份却不用给理由';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PACK_SUPERSEDE_REASON_REQUIRED%' THEN RAISE; END IF;
    END;
    v_p2 := freeze_management_pack(d_month, NULL, 'fixture 143 reissue');
    SELECT count(*) FILTER (WHERE superseded_at IS NULL), count(*)
      INTO v_live, v_total FROM management_packs WHERE period_month = d_month;
    IF v_live <> 1 OR v_total <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 143B 失败:重出之后应当是【一份在册、两份合计】,实得 % / %', v_live, v_total;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM management_packs
                    WHERE id = (v_p1->>'pack_id')::uuid
                      AND superseded_by = (v_p2->>'pack_id')::uuid
                      AND superseded_reason = 'fixture 143 reissue') THEN
        RAISE EXCEPTION 'FIXTURE 143B 失败:旧那一份没有指向新那一份,或者没有留下理由';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- I 臂 · **存档不可改**
    -- ══════════════════════════════════════════════════════════════════════
    BEGIN
        UPDATE management_packs SET notes = 'tampered' WHERE id = (v_p2->>'pack_id')::uuid;
        RAISE EXCEPTION 'FIXTURE 143I 失败:一份存档的包被改掉了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PACK_IMMUTABLE%' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM management_packs WHERE id = (v_p2->>'pack_id')::uuid;
        RAISE EXCEPTION 'FIXTURE 143I 失败:一份存档的包被删掉了';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PACK_IMMUTABLE%' THEN RAISE; END IF;
    END;

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · **包里的数是【调用】来的**(目录断言,先剥注释,匹配调用形状)
    -- ══════════════════════════════════════════════════════════════════════
    SELECT pg_get_functiondef(p.oid) INTO v_def
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'management_pack_data';
    SELECT string_agg(ln, E'\n') INTO v_body
      FROM (SELECT ln FROM regexp_split_to_table(v_def, E'\n') AS ln
             WHERE btrim(ln) NOT LIKE '--%') s;
    -- ★ 自证非空转:证明剥注释这一步真的做了事。
    IF v_def = v_body THEN
        RAISE EXCEPTION 'FIXTURE 143C 失败(空转):剥注释前后一模一样 —— 这条断言的防线没有生效';
    END IF;
    -- 【匹配带参数的调用形状,不是函数名这个子串】—— 名字在注释里出现好几次。
    IF v_body NOT LIKE '%pnl_statement(v_start, v_end)%'
       OR v_body NOT LIKE '%balance_sheet(v_end)%'
       OR v_body NOT LIKE '%cash_flow_statement(v_start, v_end)%'
       OR v_body NOT LIKE '%ar_aging_asof(v_aging)%'
       OR v_body NOT LIKE '%ap_aging_asof(v_aging)%'
       OR v_body NOT LIKE '%gl_control_reconciliation(v_aging)%' THEN
        RAISE EXCEPTION 'FIXTURE 143C 失败:报表包没有【调用】那几支函数 —— 它在自己算,而那就是第二份实现';
    END IF;

    -- ══════════════════════════════════════════════════════════════════════
    -- H 臂 · **三支 SECURITY DEFINER 各自问过调用者是谁**(行为性)
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_nobody), true);
    BEGIN
        PERFORM gl_control_reconciliation(DATE '2026-03-31');
        RAISE EXCEPTION 'FIXTURE 143H 失败:gl_control_reconciliation 对无权调用者放行';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PERMISSION_DENIED%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM management_pack_data(d_month);
        RAISE EXCEPTION 'FIXTURE 143H 失败:management_pack_data 对无权调用者放行';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PERMISSION_DENIED%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM freeze_management_pack(d_month, NULL, 'x');
        RAISE EXCEPTION 'FIXTURE 143H 失败:freeze_management_pack 对无权调用者放行';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        IF v_msg NOT LIKE 'PERMISSION_DENIED%' THEN RAISE; END IF;
    END;
    -- ★ 自证非空转:换回有权限的人必须【成功】,否则上面三条只是参数错了。
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    IF gl_control_reconciliation(DATE '2026-03-31') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 143H 失败(空转):有权限的调用者也拿不到勾稽 —— 上面三条证明不了是权限在起作用';
    END IF;

    RAISE NOTICE 'fixture 143 OK — 八臂全过';
END $$;
ROLLBACK;

-- 133 期末重估把冲销的【两边都数】—— 两处过滤各一条臂,外加一条【收回】的证明(FXREV-1)
--
-- 【为什么是三条臂而不是一条】preview_revalue_foreign_balances 里有【两处】
-- status='posted',而它们坏的方向不同:
--   ① 主聚合 —— 污染外币净额 native 与它的本位币承载额 carry_fx;
--   ② 承载额子查询 —— 只污染【既往重估调整】那一项。
-- 一份只注入普通分录的 fixture **会漏掉 ②**:要踩到它,得注入一张
-- 【被冲销的重估分录】。所以 B 臂用一个【没有任何冲销普通分录】的科目,
-- 于是 ① 那一处即使坏着也影响不到它 —— 能让 B 臂红的只有 ② 自己。
--
-- ★【每一条臂都自证非空,形状抄自 fixture 132 的 G 臂】★
--   臂内先用【旧口径(只数 posted)】自己算一遍,断言它与正确答案【确实不同】。
--   于是:场景真的踩到了那个机制。如果哪天冲销不再是"翻状态 + 反向分录",
--   两个口径会相等,这些臂会**当场失败而不是安静地绿掉**。
--
-- 【C 臂证明的是一件此前只被【断言】过、没被【证明】过的事】
-- FXREV-1 的测量阶段曾指出:"下一次重估会自我修正"这句话当时不成立,
-- 因为承载额子查询带着同一个缺陷。两处都修好之后,它到底成不成立?
-- **C 臂真的跑两次重估来回答,而不是推理。**
--
-- 自带数据(README 第 2 条)。牌价、期间锁、GST 开关全部自己设(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_fin uuid;
    v_maxyc date; d1 date; d2 date;
    v_base text; v_exp text;
    r1 numeric := 1.25; r2 numeric := 1.30; r0 numeric := 1.20;
    v_e1 jsonb; v_e2 jsonb; v_r1 jsonb; v_c1 jsonb;
    nat_old numeric; nat_new numeric; car_old numeric; car_new numeric;
    v_prev jsonb; v_row jsonb;
    v_target numeric; v_carry_after numeric; v_adj_wrong numeric; v_adj_right numeric;
    rep jsonb := '{}'::jsonb;
BEGIN
    -- ══════════ 布景 ══════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-133','f','f',true)
      RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_fin, unnest(ARRAY['module.finance.view','module.finance.edit']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_fin);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;
    d1 := GREATEST(DATE '2025-09-30', v_maxyc + 400);
    d2 := d1 + 31;
    SELECT code INTO v_exp FROM accounts WHERE account_type='expense' AND is_active ORDER BY code LIMIT 1;

    UPDATE finance_settings SET locked_before = NULL,
                                gst_registered = false, gst_registration_no = NULL;

    -- 【牌价自己插】README 第 4 条:绝不依赖会过期的引导数据
    UPDATE fx_rates SET deleted_at = now() WHERE currency='USD' AND rate_type='mid' AND rate_date IN (d1-1, d1, d2);
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit, source)
    VALUES ('USD', d1-1, 'mid', r0, 'fixture-133'),
           ('USD', d1,   'mid', r1, 'fixture-133'),
           ('USD', d2,   'mid', r2, 'fixture-133');

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════════════════════════════════════════════════════════════════
    -- A 臂 · 主聚合:一笔【被冲销的普通分录】不许改变外币净额
    -- 注入方向:在 1010/USD 上记一笔,再冲销掉。净影响必须是 0。
    -- ══════════════════════════════════════════════════════════════════════
    v_e1 := post_journal_entry(d1-10, 'f133 A 底账', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1010','side','debit', 'currency','USD','amount_ccy',10000,'fx_rate',r0),
        jsonb_build_object('account_code','4000','side','credit','currency','USD','amount_ccy',10000,'fx_rate',r0)));
    v_e2 := post_journal_entry(d1-8, 'f133 A 记错了的一笔', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1010','side','debit', 'currency','USD','amount_ccy',3000,'fx_rate',r0),
        jsonb_build_object('account_code','4000','side','credit','currency','USD','amount_ccy',3000,'fx_rate',r0)));
    PERFORM reverse_journal_entry((v_e2->>'entry_id')::uuid, d1-7, 'f133 A 冲销');

    -- 旧口径(只数 posted)—— 在 fixture 里自己算一遍
    SELECT round(sum(CASE WHEN l.debit>0 THEN l.amount_ccy ELSE -l.amount_ccy END),2)
      INTO nat_old FROM journal_lines l
      JOIN accounts a ON a.id=l.account_id AND a.code='1010'
      JOIN journal_entries e ON e.id=l.entry_id AND e.status='posted'
     WHERE l.currency='USD' AND e.entry_date <= d1;
    SELECT round(sum(CASE WHEN l.debit>0 THEN l.amount_ccy ELSE -l.amount_ccy END),2)
      INTO nat_new FROM journal_lines l
      JOIN accounts a ON a.id=l.account_id AND a.code='1010'
      JOIN journal_entries e ON e.id=l.entry_id
     WHERE l.currency='USD' AND e.entry_date <= d1;

    -- ★ 自证非空:两个口径【必须】不同,否则这一臂什么都没测到
    IF nat_old = nat_new THEN
        RAISE EXCEPTION 'FIXTURE 133 A 失败(空转):旧口径(%)与正确答案(%)相等 —— 这个场景没有踩到那个机制。冲销的形状变了吗?', nat_old, nat_new;
    END IF;
    IF nat_new <> 10000 THEN
        RAISE EXCEPTION 'FIXTURE 133 A 前提失败:正确的外币净额应为 10000,实得 %', nat_new;
    END IF;

    v_prev := preview_revalue_foreign_balances(d1);
    SELECT x INTO v_row FROM jsonb_array_elements(v_prev->'rows') x
     WHERE x->>'account'='1010' AND x->>'currency'='USD';
    IF v_row IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 133 A 失败:预览里应当有 1010/USD 这一行';
    END IF;
    IF (v_row->>'native')::numeric <> 10000 THEN
        RAISE EXCEPTION 'FIXTURE 133 A 失败:重估看到的外币净额必须是 10000(冲销两边都数),实得 % —— 只数 posted 会得到 %',
            v_row->>'native', nat_old;
    END IF;
    rep := rep || jsonb_build_object('A_main_aggregate',
        jsonb_build_object('correct', nat_new, 'posted_only_would_have_said', nat_old));

    -- ══════════════════════════════════════════════════════════════════════
    -- B 臂 · 承载额子查询:一张【被冲销的重估分录】不许改变承载额
    -- 【隔离】本臂用 2000/USD,而 2000 上【没有任何被冲销的普通分录】——
    -- 于是主聚合那一处即使坏着也影响不到这里,能让 B 臂红的只有子查询自己。
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM post_journal_entry(d1-10, 'f133 B 底账', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','2000','side','credit','currency','USD','amount_ccy',8000,'fx_rate',r0),
        jsonb_build_object('account_code',v_exp,'side','debit', 'currency','USD','amount_ccy',8000,'fx_rate',r0)));
    -- 一张既往重估调整,随即冲销 —— 净影响必须是 0
    v_r1 := post_journal_entry(d1-5, 'f133 B 记错了的重估', 'revaluation', NULL, jsonb_build_array(
        jsonb_build_object('account_code','2000','side','debit', 'currency',v_base,'amount_ccy',1500),
        jsonb_build_object('account_code','7110','side','credit','currency',v_base,'amount_ccy',1500)));
    PERFORM reverse_journal_entry((v_r1->>'entry_id')::uuid, d1-4, 'f133 B 冲销那张重估');

    SELECT COALESCE(round(sum(l.debit-l.credit),2),0) INTO car_old
      FROM journal_lines l JOIN accounts a ON a.id=l.account_id AND a.code='2000'
      JOIN journal_entries e ON e.id=l.entry_id AND e.status='posted'
     WHERE l.currency=v_base AND e.source_type='revaluation' AND e.entry_date<=d1;
    SELECT COALESCE(round(sum(l.debit-l.credit),2),0) INTO car_new
      FROM journal_lines l JOIN accounts a ON a.id=l.account_id AND a.code='2000'
      JOIN journal_entries e ON e.id=l.entry_id
     WHERE l.currency=v_base AND e.source_type='revaluation' AND e.entry_date<=d1;

    -- ★ 自证非空 —— 而这一条【只有】子查询那一处坏了才会不同
    IF car_old = car_new THEN
        RAISE EXCEPTION 'FIXTURE 133 B 失败(空转):既往重估调整的旧口径(%)与正确答案(%)相等 —— 本臂没有踩到承载额子查询那一处过滤', car_old, car_new;
    END IF;
    IF car_new <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 133 B 前提失败:一张被冲销的重估分录净影响应为 0,实得 %', car_new;
    END IF;

    v_prev := preview_revalue_foreign_balances(d1);
    SELECT x INTO v_row FROM jsonb_array_elements(v_prev->'rows') x
     WHERE x->>'account'='2000' AND x->>'currency'='USD';
    -- carry_base = 外币行的本位币净额 + 既往重估调整(应为 0)
    -- 底账:贷 8000 USD @1.20 → 本位币 -9600
    IF (v_row->>'carry_base')::numeric <> -9600 THEN
        RAISE EXCEPTION 'FIXTURE 133 B 失败:承载额必须是 -9600(被冲销的那张重估净影响为 0),实得 % —— 只数 posted 会把它算成 %',
            v_row->>'carry_base', -9600 + car_old;
    END IF;
    rep := rep || jsonb_build_object('B_carry_subquery',
        jsonb_build_object('correct', car_new, 'posted_only_would_have_said', car_old));

    -- ══════════════════════════════════════════════════════════════════════
    -- C 臂 · 【收回】:上一期算错了,下一期的重估把它收回来吗?
    -- 这不是推理,是真的跑一次重估再看承载余额。
    -- 用 2200(应计费用,货币性)—— 与 A、B 两臂互不干扰。
    -- ══════════════════════════════════════════════════════════════════════
    PERFORM post_journal_entry(d1-10, 'f133 C 底账', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','2200','side','credit','currency','USD','amount_ccy',20000,'fx_rate',r0),
        jsonb_build_object('account_code',v_exp,'side','debit', 'currency','USD','amount_ccy',20000,'fx_rate',r0)));
    -- 底账本位币承载额 = -24000(贷 20000 × 1.20)
    -- d1 正确的调整额应当是:target(-20000×1.25 = -25000) - (-24000) = -1000
    v_adj_right := -1000;
    -- 【注入】把上一期的重估【故意记错】:贷 3000 而不是贷 1000
    v_adj_wrong := -3000;
    v_c1 := post_journal_entry(d1, 'f133 C 上一期算错了的重估', 'revaluation', NULL, jsonb_build_array(
        jsonb_build_object('account_code','2200','side','credit','currency',v_base,'amount_ccy',3000),
        jsonb_build_object('account_code','7110','side','debit', 'currency',v_base,'amount_ccy',3000)));

    -- ★ 自证非空:注入的那个"错"必须真的与正确值不同
    IF v_adj_wrong = v_adj_right THEN
        RAISE EXCEPTION 'FIXTURE 133 C 失败(空转):注入的调整额与正确值相等,本臂证明不了"收回"这件事';
    END IF;

    -- 现在跑 d2 的重估(修好之后的函数)
    PERFORM revalue_foreign_balances(d2);

    -- 目标:外币净额 × d2 中间价 = -20000 × 1.30 = -26000
    v_target := round(-20000 * r2, 2);
    -- 实际承载余额 = 该科目外币行的本位币净额 + 全部重估调整行(两侧都数)
    SELECT round(sum(l.debit-l.credit),2) INTO v_carry_after
      FROM journal_lines l JOIN accounts a ON a.id=l.account_id AND a.code='2200'
      JOIN journal_entries e ON e.id=l.entry_id
     WHERE e.entry_date <= d2;

    IF v_carry_after <> v_target THEN
        RAISE EXCEPTION 'FIXTURE 133 C 失败:d2 重估之后,2200 的本位币承载余额应当【正好】等于目标 %(= -20000 × %),实得 % —— 也就是说上一期那 % 的错【没有】被收回',
            v_target, r2, v_carry_after, v_adj_wrong - v_adj_right;
    END IF;
    rep := rep || jsonb_build_object('C_carry_forward_recovery',
        jsonb_build_object('injected_wrong_prior_adj', v_adj_wrong,
                           'correct_prior_adj', v_adj_right,
                           'target_at_d2', v_target,
                           'carrying_after_d2_run', v_carry_after,
                           'recovered', true));

    RAISE NOTICE 'FIXTURE 133 全部通过 %', rep::text;
END $$;
ROLLBACK;

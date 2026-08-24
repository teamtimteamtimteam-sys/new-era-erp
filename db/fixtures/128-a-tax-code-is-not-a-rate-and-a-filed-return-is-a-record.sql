-- 128 税码不是税率,而一份报出去的申报是一条记录(GST-1)
--
-- 【这份 fixture 要钉住的四件事】
--   (P) 税率按【生效期间】解析,历史单据拿得到当时那一个;没有就【拒绝】,不回退;
--   (S) 开关【关着】的时候,行为与今天一模一样 —— 而"一模一样"要用不变量说出来,
--       不能靠一句断言:没有任何分录行带税码,没有任何一行碰 1400 / 2100;
--   (F) 【GST-2 2026-08-25 改写了这一条】F5 的**进项侧**从总账推导,而
--       **销项侧从单据推导** —— 所以这里守的是反向的一半:**一笔没有发票
--       撑着的手工分录变不出一笔供应**。销项侧的正向断言在 fixture 129。
--       勾稽从"两处比一次"变成"三处比两次"(单据 / 法令 / 总账),两条都会响;
--   (G) GST 期间与会计锁的关系:那一季没关完账就不许申报;
--       报出去的那一份【不动】;更正是新的一行,不是一次编辑。
--
-- 自带数据(README 第 2 条)。不继承 locked_before —— 自己设(README 第 4 条)。
-- 日期算出来、不写死:要落在既有年结之后(fixture 122 的先例)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_fin uuid;
    v_maxyc date; v_q_start date; v_q_end date; v_mid date;
    a_rev uuid; a_out uuid; a_in uuid; a_cash uuid; a_exp uuid;
    c_rev text; c_cash text; c_exp text;
    v_base text; v_e uuid; v_p jsonb; v_pid uuid; v_pid2 uuid; v_r jsonb;
    v_denied boolean; v_msg text; v_n numeric; v_v numeric;
    v_boxes jsonb; v_box jsonb;
    rep jsonb := '{}'::jsonb;
BEGIN
    -- ══════════ 布景 ══════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-128','f','f',true)
      RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_fin, unnest(ARRAY['module.finance.view','module.finance.edit']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_fin);
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;
    -- 一个整季,落在既有年结之后
    v_q_start := date_trunc('quarter', GREATEST(DATE '2025-01-01', v_maxyc + 400))::date;
    v_q_end   := (v_q_start + interval '3 months - 1 day')::date;
    v_mid     := v_q_start + 20;

    SELECT id, code INTO a_rev, c_rev  FROM accounts WHERE account_type='revenue' AND is_active ORDER BY code LIMIT 1;
    SELECT id, code INTO a_cash, c_cash FROM accounts WHERE is_cash AND is_active ORDER BY code LIMIT 1;
    SELECT id, code INTO a_exp, c_exp  FROM accounts WHERE account_type='expense' AND is_active ORDER BY code LIMIT 1;
    SELECT id INTO a_out FROM accounts WHERE code='2100';
    SELECT id INTO a_in  FROM accounts WHERE code='1400';
    IF a_out IS NULL OR a_in IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 128 前提失败:1400 / 2100 两个税科目必须在册';
    END IF;

    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════ P1 · 税率按生效期间解析,历史拿得到当时那一个 ══════════
    -- **这一臂是 4.1 的全部内容。** 一个标量税率表达不了它。
    IF tax_rate_for('SR', DATE '2022-06-30') <> 7.000 THEN
        RAISE EXCEPTION 'P1 失败:2022 年的标准税率应当是 7%%,实得 %', tax_rate_for('SR', DATE '2022-06-30');
    END IF;
    IF tax_rate_for('SR', DATE '2023-06-30') <> 8.000 THEN
        RAISE EXCEPTION 'P1 失败:2023 年应当是 8%%,实得 %', tax_rate_for('SR', DATE '2023-06-30');
    END IF;
    IF tax_rate_for('SR', DATE '2024-06-30') <> 9.000 THEN
        RAISE EXCEPTION 'P1 失败:2024 年起应当是 9%%,实得 %', tax_rate_for('SR', DATE '2024-06-30');
    END IF;
    rep := rep || jsonb_build_object('P1_rate_history_resolves', true);

    -- ══════════ P2 · 没有生效税率的那一天:【拒绝】,不回退 ══════════
    v_denied := false;
    BEGIN PERFORM tax_rate_for('SR', DATE '2000-01-01');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'TAX_RATE_NOT_FOUND|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'P2 失败:没有生效税率的日期应当按名拒绝,而不是取最近的一条(实得 %)', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    rep := rep || jsonb_build_object('P2_no_rate_refuses', v_msg);

    -- ══════════ P3 · 不认识的税码 ══════════
    v_denied := false;
    BEGIN PERFORM tax_rate_for('ZZZ', v_mid);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'TAX_CODE_UNKNOWN|%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'P3 失败:不认识的税码应当按名拒绝'; END IF;
    rep := rep || jsonb_build_object('P3_unknown_code_refuses', v_msg);

    -- ══════════ S · 开关【关着】时,行为与今天一模一样 ══════════
    -- 【"一模一样"用不变量说,不用一句断言】今天:没有任何分录行带税码,
    -- 没有任何一行碰 1400 / 2100。开关关着时这两条必须仍然成立。
    UPDATE finance_settings SET gst_registered = false;
    IF gst_registered() THEN RAISE EXCEPTION 'S 前提失败:开关应当是关着的'; END IF;

    v_e := (post_journal_entry(v_mid, 'fixture 128 开关关着', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code',c_cash,'side','debit','amount_ccy',1000,'currency',v_base,'fx_rate',1),
        jsonb_build_object('account_code',c_rev,'side','credit','amount_ccy',1000,'currency',v_base,'fx_rate',1)
    ))->>'entry_id')::uuid;

    SELECT count(*) INTO v_n FROM journal_lines WHERE entry_id = v_e AND tax_code IS NOT NULL;
    IF v_n <> 0 THEN RAISE EXCEPTION 'S 失败:开关关着时不该有任何一行带税码,实得 % 行', v_n; END IF;

    -- 【更硬的一句:开关关着时,带税码的行【写不进去】】
    -- "没有出现"可能只是碰巧没人传;"传了会被拒"才是一条规矩。
    v_denied := false;
    BEGIN
        PERFORM post_journal_entry(v_mid, 'fixture 128 未注册却盖税码', 'manual', NULL, jsonb_build_array(
            jsonb_build_object('account_code',c_cash,'side','debit','amount_ccy',100,'currency',v_base,'fx_rate',1),
            jsonb_build_object('account_code',c_rev,'side','credit','amount_ccy',100,'currency',v_base,'fx_rate',1,'tax_code','SR')));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_NOT_REGISTERED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'S 失败:未注册时盖税码应当按名拒绝(实得 %)', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    SELECT count(*) INTO v_n FROM journal_lines jl JOIN accounts a ON a.id=jl.account_id
      WHERE jl.entry_id = v_e AND a.code IN ('1400','2100');
    IF v_n <> 0 THEN RAISE EXCEPTION 'S 失败:开关关着时不该有任何一行碰税科目,实得 % 行', v_n; END IF;

    v_p := f5_return(v_q_start, v_q_end);
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_p->'boxes') b WHERE b->>'box'='box6';
    IF v_v <> 0 THEN RAISE EXCEPTION 'S 失败:开关关着时销项税应当是 0,实得 %', v_v; END IF;
    rep := rep || jsonb_build_object('S_switch_off_is_todays_behaviour', true);

    -- ══════════ F1 · 打开开关,按税码过账,F5 逐格分得开 ══════════
    -- 【这一臂同时是 S 臂的正对照】没有它,一个"永远不给任何行盖税码"的实现
    -- 会让 S 臂全绿 —— 那正是为了错的理由通过。
    UPDATE finance_settings SET gst_registered = true;

    -- 标准税率销售 1000 + 9% 税 90
    v_e := (post_journal_entry(v_mid, 'fixture 128 SR 销售', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code',c_cash,'side','debit','amount_ccy',1090,'currency',v_base,'fx_rate',1),
        jsonb_build_object('account_code',c_rev,'side','credit','amount_ccy',1000,'currency',v_base,'fx_rate',1,'tax_code','SR'),
        jsonb_build_object('account_code','2100','side','credit','amount_ccy',90,'currency',v_base,'fx_rate',1)
    ))->>'entry_id')::uuid;

    -- 零税率出口 500
    v_e := (post_journal_entry(v_mid, 'fixture 128 ZR 出口', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code',c_cash,'side','debit','amount_ccy',500,'currency',v_base,'fx_rate',1),
        jsonb_build_object('account_code',c_rev,'side','credit','amount_ccy',500,'currency',v_base,'fx_rate',1,'tax_code','ZR')
    ))->>'entry_id')::uuid;

    -- 应税采购 200 + 进项税 18
    v_e := (post_journal_entry(v_mid, 'fixture 128 TX 采购', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code',c_exp,'side','debit','amount_ccy',200,'currency',v_base,'fx_rate',1,'tax_code','TX'),
        jsonb_build_object('account_code','1400','side','debit','amount_ccy',18,'currency',v_base,'fx_rate',1),
        jsonb_build_object('account_code',c_cash,'side','credit','amount_ccy',218,'currency',v_base,'fx_rate',1)
    ))->>'entry_id')::uuid;

    v_p := f5_return(v_q_start, v_q_end);
    v_boxes := v_p->'boxes';

    -- ════════════════════════════════════════════════════════════════════
    -- ★【GST-2(2026-08-25)把这一臂的答案【改了】,而改的是【对的那一半】】★
    --
    -- 这一臂原本断言:上面那三笔【手工分录】会让 box1=1000 / box2=500 / box6=90。
    -- 那在 GST-1 的形状下是对的 —— 那时 F5 九格【全部】从总账推导。
    -- Tim 2026-08-25 裁定供应报在【开票】那一期(新加坡的供应时点是开票与收款
    -- 孰早),于是 F5 的**销项侧改从发票推导**。这三笔手工分录背后【没有发票】,
    -- 所以它们【不再】进 box1/box2/box6 —— 而这正是新形状要的行为。
    --
    -- 【所以这一臂改成断言它的【后继不变量】,不是删掉它】
    -- 新不变量比旧的更值钱:**一笔手工分录变不出一笔供应。** 谁都可以往总账里
    -- 记一行带 'SR' 的贷方,而在 GST-2 之后那一行【报不进 F5 的销项格】——
    -- 报进去的东西必须有一张开给某个客户的发票在后面撑着。
    -- 销项侧从单据推导的正向断言在 **fixture 129**(它开真发票),这里守的是
    -- 反向的那一半:没有单据就没有供应额。
    -- ════════════════════════════════════════════════════════════════════
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_boxes) b WHERE b->>'box'='box1';
    IF v_v <> 0 THEN
        RAISE EXCEPTION 'F1 失败:没有发票撑着的手工分录【不该】进 box1(GST-2 起销项侧从发票推导),实得 % —— 若它是 1000,说明销项侧还在读总账',
            v_v;
    END IF;
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_boxes) b WHERE b->>'box'='box2';
    IF v_v <> 0 THEN
        RAISE EXCEPTION 'F1 失败:手工分录不该进 box2,实得 %', v_v;
    END IF;
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_boxes) b WHERE b->>'box'='box4';
    IF v_v <> 0 THEN
        RAISE EXCEPTION 'F1 失败:box4 是 1+2+3 的合计,三格皆零时它也应当是 0,实得 %', v_v;
    END IF;

    -- 【进项侧【没有变】,而它必须继续被钉住】进项的税点是供应商税务发票的日期,
    -- 而分录的过账日记的就是那一天 —— 总账口径与法定口径在这一侧本来就重合。
    -- 这两格仍然从总账推导,所以上面那笔 TX 采购照旧要出现。
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_boxes) b WHERE b->>'box'='box5';
    IF v_v <> 200 THEN RAISE EXCEPTION 'F1 失败:box5(应税采购)应当是 200 —— 进项侧仍从总账推导,实得 %', v_v; END IF;
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_boxes) b WHERE b->>'box'='box7';
    IF v_v <> 18 THEN RAISE EXCEPTION 'F1 失败:box7(进项税)应当是 18,实得 %', v_v; END IF;
    -- box8 = box6 − box7,而 box6 现在是 0(没有发票)⇒ 0 − 18 = −18(应退)
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_boxes) b WHERE b->>'box'='box8';
    IF v_v <> -18 THEN
        RAISE EXCEPTION 'F1 失败:box8 应当是 box6−box7 = 0−18 = −18(这一季只有进项),实得 %', v_v;
    END IF;
    rep := rep || jsonb_build_object('F1_input_side_from_ledger_output_side_needs_documents', true);

    -- 【零税率与豁免必须分得开 —— 税率分不开它们,税码分得开】
    IF (SELECT (b->>'value')::numeric FROM jsonb_array_elements(v_boxes) b WHERE b->>'box'='box3') <> 0 THEN
        RAISE EXCEPTION 'F1 失败:没有豁免供应时 box3 应当是 0';
    END IF;

    -- ══════════ F2 · 勾稽的两边【真的会分开】 ══════════
    -- 【GST-2:勾稽从"两处比一次"变成"三处比两次"】—— 单据 / 法令 / 总账。
    -- 此刻单据侧是 0(没有发票),法令侧也是 0(它也读发票),而总账侧【不是 0】:
    -- 上面那笔手工分录往 2100 上贷了 90。**所以这一臂现在断言的是它会响** ——
    -- 而这恰恰是"单据 vs 总账"那一条存在的理由:有人手工动过税科目。
    IF (v_p->'ties'->>'agrees_documents_vs_statute')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'F2 失败:单据侧与法令侧都读发票,此刻都应当是 0 而一致,实得 % vs %',
            v_p->'ties'->>'box6_from_documents', v_p->'ties'->>'box6_recomputed_from_statute';
    END IF;
    IF (v_p->'ties'->>'agrees_documents_vs_ledger')::boolean THEN
        RAISE EXCEPTION 'F2 失败:2100 上有一笔 90 而单据侧没有,"单据 vs 总账"必须报分开 —— 它却说一致(% vs %)',
            v_p->'ties'->>'box6_from_documents', v_p->'ties'->>'box6_from_tax_account';
    END IF;
    IF (v_p->'ties'->>'agrees')::boolean THEN
        RAISE EXCEPTION 'F2 失败:两条比较有一条不成立时,总判词 agrees 必须是 false';
    END IF;
    rep := rep || jsonb_build_object('F2b_tie_can_actually_break',
        (v_p->'ties'->>'box6_from_documents') || ' vs ' || (v_p->'ties'->>'box6_from_tax_account'));

    -- 【把那笔手工的税冲掉,勾稽回到一致】—— 收尾与原来同形:一个只会变红、
    -- 再也回不了绿的检查,与一个永远为真的检查一样没有判别力。
    PERFORM post_journal_entry(v_mid, 'fixture 128 冲掉手工那笔税', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','2100','side','debit','amount_ccy',90,'currency',v_base,'fx_rate',1),
        jsonb_build_object('account_code',c_cash,'side','credit','amount_ccy',90,'currency',v_base,'fx_rate',1)
    ));
    v_p := f5_return(v_q_start, v_q_end);
    v_boxes := v_p->'boxes';
    IF NOT (v_p->'ties'->>'agrees')::boolean THEN
        RAISE EXCEPTION 'F2 收尾失败:冲掉之后勾稽应当回到一致,实得 单据=% 法令=% 总账=%',
            v_p->'ties'->>'box6_from_documents', v_p->'ties'->>'box6_recomputed_from_statute',
            v_p->'ties'->>'box6_from_tax_account';
    END IF;

    -- ══════════ F3 · 钻取:能钻的钻得进去,不能钻的【说出来】 ══════════
    -- 【判据是"钻出来的加起来 = 那一格"】—— 那才是"钻得进去"的意思。
    -- 只数行数证明不了完整性:漏掉一条,行数照样是一个说得通的数字。
    -- 【GST-2:这里钻的是【进项】两格】销项两格在这一份 fixture 里是空的
    -- (它没有开过发票),而"空格钻出来是 0"证明不了钻取完整 —— 一个坏掉的
    -- 钻取器对空格也返回 0。销项侧钻取的正向断言在 fixture 129,那里有真发票。
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_p->'boxes') b WHERE b->>'box'='box5';
    SELECT COALESCE(round(sum(d.amount_base),2),0) INTO v_n FROM f5_box_detail(v_q_start, v_q_end, 'box5') d;
    IF v_n <> v_v THEN
        RAISE EXCEPTION 'F3 失败:box5 钻出来的合计(%)与那一格的数字(%)对不上 —— 钻取不完整', v_n, v_v;
    END IF;
    SELECT (b->>'value')::numeric INTO v_v FROM jsonb_array_elements(v_p->'boxes') b WHERE b->>'box'='box7';
    SELECT COALESCE(round(sum(d.amount_base),2),0) INTO v_n FROM f5_box_detail(v_q_start, v_q_end, 'box7') d;
    IF v_n <> v_v THEN
        RAISE EXCEPTION 'F3 失败:box7 钻出来的合计(%)与那一格的数字(%)对不上', v_n, v_v;
    END IF;
    v_denied := false;
    BEGIN PERFORM count(*) FROM f5_box_detail(v_q_start, v_q_end, 'box4');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_BOX_NOT_DRILLABLE|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'F3 失败:合计格钻不进去这件事要【说出来】,不能返回空集';
    END IF;
    rep := rep || jsonb_build_object('F3_drilldown_and_named_refusal', v_msg);

    -- ══════════ G1 · 期间必须是一个整季 ══════════
    v_denied := false;
    BEGIN PERFORM open_gst_period(v_q_start, v_q_start + 10);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_PERIOD_NOT_A_QUARTER|%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'G1 失败:不是整季应当按名拒绝'; END IF;
    rep := rep || jsonb_build_object('G1_quarter_shape_enforced', v_msg);

    v_pid := (open_gst_period(v_q_start, v_q_end)->>'gst_period_id')::uuid;

    -- ══════════ G2 · ★那一季没关完账,就不许申报★ ══════════
    -- **这是 6.2 的规矩本身。** GST 期间与会计锁不是同一件事,但一份底下还能改的
    -- 申报是一句假话。
    v_denied := false;
    BEGIN PERFORM file_gst_return(v_pid, v_q_end + 30, 'ACK-TEST-1');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_PERIOD_NOT_LOCKED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'G2 失败:会计期间还没锁到季末就申报,应当按名拒绝(实得 %)', COALESCE(v_msg,'(没有拒绝)');
    END IF;
    rep := rep || jsonb_build_object('G2_cannot_file_before_books_closed', v_msg);

    -- ══════════ G3 · 关完账之后,申报成功并【把当时的数字抄下来】 ══════════
    -- SOD-1:设锁是【布景】,没有主语 —— 与 fixture 17 / 122 同一个处置。
    -- (本 fixture 以 v_user 记过手工凭证,而 SOD_POST_AND_CLOSE 拦的正是
    --  "记过手工凭证的人来关那个期间"。这里要的是把账关掉这件【事实】,
    --  不是"某个人关了账"这件动作。)
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = v_q_end + 1;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);
    v_r := file_gst_return(v_pid, v_q_end + 30, 'ACK-TEST-1');
    SELECT count(*) INTO v_n FROM gst_return_boxes WHERE period_id = v_pid;
    IF v_n < 8 THEN RAISE EXCEPTION 'G3 失败:申报应当把每一格都抄下来,实得 % 格', v_n; END IF;
    -- 【GST-2:这里改抄【进项】那一格,而这不是退让】抄下来的必须是一个
    -- **非零**的数,否则这一臂对一个"把每一格都写 0"的坏快照照样全绿。
    -- box6 在这一份 fixture 里是 0(它没有开过发票,而销项侧从发票推导),
    -- 所以判别力挪到 box7 —— 那一格是 18,而且它仍然是从总账推导的。
    -- **两个方向都钉住**:该是 18 的抄成 18,该是 0 的抄成 0。
    SELECT value_base INTO v_v FROM gst_return_boxes WHERE period_id=v_pid AND box='box7';
    IF v_v <> 18 THEN RAISE EXCEPTION 'G3 失败:抄下来的 box7 应当是 18,实得 % —— 一份把每一格都写成 0 的快照会在这里变红', v_v; END IF;
    SELECT value_base INTO v_v FROM gst_return_boxes WHERE period_id=v_pid AND box='box6';
    IF v_v <> 0 THEN RAISE EXCEPTION 'G3 失败:这一季没有发票,抄下来的 box6 应当是 0,实得 %', v_v; END IF;
    rep := rep || jsonb_build_object('G3_filing_snapshots_the_boxes', true);

    -- ══════════ G4 · 报出去的那一份【不动】 ══════════
    v_denied := false;
    BEGIN UPDATE gst_return_boxes SET value_base = 999 WHERE period_id=v_pid AND box='box6';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_RETURN_IMMUTABLE|%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'G4 失败:报出去的申报不许被改写'; END IF;
    v_denied := false;
    BEGIN DELETE FROM gst_return_boxes WHERE period_id=v_pid AND box='box6';
    EXCEPTION WHEN OTHERS THEN v_denied := (SQLERRM LIKE 'GST_RETURN_IMMUTABLE|%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'G4 失败:报出去的申报不许被删'; END IF;
    rep := rep || jsonb_build_object('G4_filed_return_is_immutable', v_msg);

    -- ══════════ G5 · 同一期不许申报两次 ══════════
    v_denied := false;
    BEGIN PERFORM file_gst_return(v_pid, v_q_end + 31, 'ACK-TEST-2');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_PERIOD_ALREADY_FILED|%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'G5 失败:同一期申报两次应当按名拒绝'; END IF;
    rep := rep || jsonb_build_object('G5_no_double_filing', v_msg);

    -- ══════════ G7 · 申报日没填,要够得着它【自己那条具名拒绝】 ══════════
    -- 【为什么这一臂值得单列】GST-1-fu2 之前,file_gst_return 的 p_filed_on 没有
    -- DEFAULT,生成出来的 TS 类型是必填的 string —— 页面根本没有办法把"没填"
    -- 送到这条拒绝面前:送 '' 会先在 cast 成 date 时炸成一个没有名字的 22007。
    -- 一条【够不着的拒绝】等于不存在,所以这里从数据库这一侧证明它够得着。
    v_pid2 := (open_gst_period((v_q_start + INTERVAL '3 months')::date,
                          (v_q_start + INTERVAL '6 months' - INTERVAL '1 day')::date)->>'gst_period_id')::uuid;
    v_denied := false;
    BEGIN PERFORM file_gst_return(v_pid2);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_FILED_DATE_REQUIRED|%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'G7 失败:不填申报日应当按名拒绝,实得 %', v_msg; END IF;
    rep := rep || jsonb_build_object('G7_filed_date_refusal_is_reachable', v_msg);

    -- ══════════ G6 · 更正是【一个新事件】,不是一次编辑 ══════════
    v_r := correct_gst_return(v_pid, 'fixture 128:少报了一笔零税率出口');
    IF (v_r->>'code') NOT LIKE '%-F7-1' THEN
        RAISE EXCEPTION 'G6 失败:更正应当是一份新的 F7,实得 %', v_r->>'code';
    END IF;
    SELECT count(*) INTO v_n FROM gst_periods WHERE corrects_period_id = v_pid;
    IF v_n <> 1 THEN RAISE EXCEPTION 'G6 失败:更正应当指着被更正的那一期'; END IF;
    -- 原来那一期【原样还在】,状态仍是 filed
    IF (SELECT status FROM gst_periods WHERE id=v_pid) <> 'filed' THEN
        RAISE EXCEPTION 'G6 失败:更正不该动原来那一期';
    END IF;
    -- 没申报过的期间不能"更正"
    v_denied := false;
    BEGIN PERFORM correct_gst_return((v_r->>'gst_period_id')::uuid, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'GST_CANNOT_CORRECT_UNFILED|%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'G6 失败:没报过的期间不该"更正"得了'; END IF;
    -- 理由必填
    v_denied := false;
    BEGIN PERFORM correct_gst_return(v_pid, '   ');
    EXCEPTION WHEN OTHERS THEN v_denied := (SQLERRM LIKE 'GST_CORRECTION_REASON_REQUIRED%'); END;
    IF NOT v_denied THEN RAISE EXCEPTION 'G6 失败:更正理由必填'; END IF;
    rep := rep || jsonb_build_object('G6_correction_is_a_new_event', v_r->>'code');

    RAISE NOTICE 'FIXTURE 128 全部通过 %', rep::text;
END $$;
ROLLBACK;

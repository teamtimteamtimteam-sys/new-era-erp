-- 132 账面余额把冲销的【两边都数】,而一次对账是一份【记录】(BANK-REC)
--
-- 【这份 fixture 钉住的三件事】
--   (G) **一笔被冲销的分录,对现金余额的净影响是 0。** 冲销的形状是:原分录翻成
--       status='reversed',另发一张【等额反向的 posted 冲销分录】。只数 posted
--       就是【丢掉原分录、留下冲销分录】,净额刚好错成 −原分录 ——
--       一张不报错、只是少(或多)了一笔的报表。
--       **这一条不是假想的:BANK-REC 之前 bank_reconciliation_status.ledger_balance
--       就是这么算的,银行首页上那个现金余额一直是错的。** 同一个机制在本仓库
--       此前已经出现两次(cash_flow_statement / f5_return),都已修。
--   (F) **对账那一刻的数字是【抄下来的】,底下的分录再动它也不动。**
--       与 GST 已申报的那一份同一条规矩。而"今天重算是多少"另算一个数,
--       两者【并排】,不一致本身就是要给人看的信息。
--   (I) **重开报表不删记录**,只把它标成被取代;再对一次是【一行新记录】。
--
-- ★【故障注入的方向,以及这几臂为什么不可能空转】★
--   (G) 本臂在断言之前,先在 fixture 里【自己算一遍旧口径(只数 posted)】,
--       并断言它与正确口径【确实不同】。于是:场景真的踩到了那个机制 ——
--       如果哪天冲销不再是"翻状态 + 反向分录",两个口径会相等,这一臂会
--       当场失败而不是安静地绿掉。**一个自证非空的断言,而不是一个空集。**
--   (F) 注入的是一笔【日期落在 period_end 当天或之前】的补记分录 ——
--       正是"事后有人补了一张上个月的单据"那个现实情形。若快照没有生效,
--       冻结值会跟着动,本臂立刻红。同时断言 drift ≠ 0:如果注入根本没有
--       改变账面余额,这一臂也会失败,不会因为"没事发生"而通过。
--
-- 自带数据(README 第 2 条)。locked_before 与 GST 开关自己设(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_fin uuid;
    v_maxyc date; d0 date; e1 date;
    v_base text;
    v_je_x jsonb; v_je_seed jsonb; v_je_late jsonb;
    v_jl_seed uuid;
    v_before numeric; v_after numeric; v_posted_only numeric;
    v_s jsonb; v_s_id uuid; v_l uuid;
    v_res jsonb; v_recon1 uuid; v_recon2 uuid;
    v_frozen numeric; v_now numeric; v_drift numeric;
    v_cnt integer;
    v_denied boolean; v_msg text;
    rep jsonb := '{}'::jsonb;
BEGIN
    -- ══════════ 布景 ══════════
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-132','f','f',true)
      RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_fin, unnest(ARRAY['module.finance.view','module.finance.edit']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_fin);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT COALESCE(MAX(year_end), DATE '2000-12-31') INTO v_maxyc
      FROM year_closes WHERE reopened_at IS NULL;
    d0 := GREATEST(DATE '2025-06-02', v_maxyc + 400);
    e1 := d0 + 27;

    UPDATE finance_settings SET locked_before = NULL,
                                gst_registered = false, gst_registration_no = NULL;

    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ G · 冲销的两边都要数 ══════════
    -- 先记一笔底账,让这个账户上有个非零余额(不然"净影响 0"与"什么都没有"分不开)
    v_je_seed := post_journal_entry(d0, 'fixture132 底账', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1000','side','debit', 'currency',v_base,'amount_ccy',2000),
        jsonb_build_object('account_code','4000','side','credit','currency',v_base,'amount_ccy',2000)));
    SELECT l.id INTO v_jl_seed FROM journal_lines l JOIN accounts a ON a.id=l.account_id
     WHERE l.entry_id = (v_je_seed->>'entry_id')::uuid AND a.code='1000';

    v_before := bank_book_balance_asof('1000', e1);
    IF v_before <> 2000 THEN
        RAISE EXCEPTION 'FIXTURE 132 G 前提失败:底账之后账面应为 2000,实得 %', v_before;
    END IF;

    -- 【注入】一笔 800 的分录,随即冲销掉
    v_je_x := post_journal_entry(d0+2, 'fixture132 记错了的一笔', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1000','side','debit', 'currency',v_base,'amount_ccy',800),
        jsonb_build_object('account_code','4000','side','credit','currency',v_base,'amount_ccy',800)));
    PERFORM reverse_journal_entry((v_je_x->>'entry_id')::uuid, d0+3, 'fixture132 冲销');

    -- 【旧口径:只数 posted】—— 在这里【自己算一遍】,用来证明这个场景确实踩到了那个机制。
    SELECT round(COALESCE(sum(CASE WHEN l.debit > 0 THEN l.amount_ccy ELSE -l.amount_ccy END),0),2)
      INTO v_posted_only
      FROM journal_lines l
      JOIN accounts a ON a.id = l.account_id AND a.code = '1000'
      JOIN journal_entries e ON e.id = l.entry_id AND e.status = 'posted'
     WHERE l.currency = bank_native_currency('1000') AND e.entry_date <= e1;

    -- ★ 自证非空:两个口径【必须】不同,否则本臂什么都没测到 ★
    IF v_posted_only = v_before THEN
        RAISE EXCEPTION 'FIXTURE 132 G 失败(空转):旧口径(只数 posted,%)与正确答案(%)相等 —— 这个场景没有踩到那个机制,本臂证明不了任何事。冲销的形状变了吗?',
            v_posted_only, v_before;
    END IF;

    v_after := bank_book_balance_asof('1000', e1);
    IF v_after <> 2000 THEN
        RAISE EXCEPTION 'FIXTURE 132 G 失败:一笔被冲销的分录对现金余额的净影响必须是 0(期望 2000),实得 % —— 只数 posted 会丢掉原分录、留下冲销分录,净额错成 −原分录', v_after;
    END IF;
    rep := rep || jsonb_build_object('G_reversal_nets_to_zero',
        jsonb_build_object('correct', v_after, 'posted_only_would_have_said', v_posted_only));

    -- ══════════ F · 冻下来的那一份不跟着分录动 ══════════
    v_s := import_bank_statement('1000', d0, e1, 0, 2000, 'fixture132.csv', jsonb_build_array(
        jsonb_build_object('line_date', d0, 'description','底账收款','reference','S1','amount',2000)));
    v_s_id := (v_s->>'statement_id')::uuid;
    SELECT id INTO v_l FROM bank_statement_lines WHERE statement_id=v_s_id AND line_no=1;
    PERFORM match_bank_line(v_l, ARRAY[v_jl_seed]);

    v_res := reconcile_statement(v_s_id);
    IF (v_res->>'difference')::numeric <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 132 F 前提失败:此时两个数字应当相等,实得差额 %', v_res->>'difference';
    END IF;
    SELECT id, book_balance INTO v_recon1, v_frozen
      FROM bank_reconciliations WHERE statement_id=v_s_id AND superseded_at IS NULL;

    -- 【注入】事后补一张【日期落在 period_end 之前】的分录 —— 现实里就是
    -- "有人补记了上个月的一笔"。冻结值必须【纹丝不动】。
    v_je_late := post_journal_entry(d0+10, 'fixture132 事后补记', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','1000','side','debit', 'currency',v_base,'amount_ccy',75),
        jsonb_build_object('account_code','4000','side','credit','currency',v_base,'amount_ccy',75)));

    SELECT book_balance, book_balance_now, book_balance_drift
      INTO v_frozen, v_now, v_drift
      FROM bank_reconciliation_record WHERE reconciliation_id = v_recon1;

    IF v_frozen <> 2000 THEN
        RAISE EXCEPTION 'FIXTURE 132 F 失败:签下的账面余额必须原样保留(2000),实得 % —— 一份会被后来的分录悄悄改写的记录,等于没有记录', v_frozen;
    END IF;
    -- 自证非空:注入若没有真的改变账面余额,本臂什么都没测到
    IF v_drift = 0 THEN
        RAISE EXCEPTION 'FIXTURE 132 F 失败(空转):补记之后重算值应当与冻结值不同,实得 drift = 0 —— 注入没有生效,本臂证明不了快照起了作用';
    END IF;
    IF v_now <> 2075 OR v_drift <> 75 THEN
        RAISE EXCEPTION 'FIXTURE 132 F 失败:重算值应为 2075、偏移应为 75,实得 % / %', v_now, v_drift;
    END IF;
    rep := rep || jsonb_build_object('F_frozen_holds_while_live_moves',
        jsonb_build_object('frozen', v_frozen, 'now', v_now, 'drift', v_drift));

    -- ══════════ I · 重开不删记录;再对一次是一行新记录 ══════════
    PERFORM unreconcile_statement(v_s_id, '发现补记的一笔要重对');
    SELECT count(*) INTO v_cnt FROM bank_reconciliations WHERE id = v_recon1;
    IF v_cnt <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 132 I 失败:重开报表【不许删掉】已经签过的那一份记录';
    END IF;
    IF (SELECT superseded_at FROM bank_reconciliations WHERE id=v_recon1) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 132 I 失败:被掀掉的那一份应当带上 superseded_at';
    END IF;
    IF (SELECT superseded_reason FROM bank_reconciliations WHERE id=v_recon1) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 132 I 失败:掀掉它的理由必须记下来';
    END IF;

    -- 再对一次:现在账面 2075、银行 2000,差 75 —— 必须说得清才过得去
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM reconcile_statement(v_s_id);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'BALANCE_DISAGREES|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 132 I 失败:补记之后账面(2075)与银行(2000)已经不等,必须按名拒,实得 %',
            COALESCE(v_msg,'(对账成功了)');
    END IF;

    v_res := reconcile_statement(v_s_id, jsonb_build_array(
        jsonb_build_object('kind','timing','amount','75','note','补记的一笔,银行下期才出现')));
    SELECT id INTO v_recon2 FROM bank_reconciliations
     WHERE statement_id=v_s_id AND superseded_at IS NULL;
    IF v_recon2 = v_recon1 THEN
        RAISE EXCEPTION 'FIXTURE 132 I 失败:再对一次必须是【一行新记录】,不是把旧的改掉';
    END IF;
    SELECT count(*) INTO v_cnt FROM bank_reconciliations WHERE statement_id = v_s_id;
    IF v_cnt <> 2 THEN
        RAISE EXCEPTION 'FIXTURE 132 I 失败:这张报表应当留下两份记录(一份被取代、一份现行),实得 %', v_cnt;
    END IF;
    rep := rep || jsonb_build_object('I_unreconcile_supersedes_and_keeps', v_cnt);

    RAISE NOTICE 'FIXTURE 132 全部通过 %', rep::text;
END $$;
ROLLBACK;

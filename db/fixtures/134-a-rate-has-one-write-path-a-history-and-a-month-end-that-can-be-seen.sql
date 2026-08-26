-- 134 牌价:一个写入口、一份变更史,以及一个【看得见的】月末(FX-RATES-1)
--
-- 【八条臂,每条自证非空 —— 逐条说清它为什么不可能在空场景下变绿】
--   A 新建会留一行 'created' 史        · 断言史从 0 变成 1(不是"存在 ≥ 0 行")
--   B 已有牌价、不给理由 → 按名拒       · 先断言那条牌价【确实在册】,再断言拒完【值没变】
--   C 给了理由 → 改成,并留 prev_rate   · 断言 prev_rate 与新值【确实不同】
--   D 直接 UPDATE 金额 → 拒            · 同时断言【改 notes 仍然成功】—— 证明这道闸窄,不是一刀切
--   E 直接 DELETE → 拒                 · 断言那一行【还在】
--   F 未来日期 → 拒                    · 断言用的日期【确实晚于】CURRENT_DATE
--   G 月末就绪表看得见月末              · 断言 blocks_close 【从 true 翻成 false】—— 两种状态都观察到
--   H 撤销必须给理由,并留 'withdrawn'  · 断言撤销后 fx_rate_asof 【真的找不到】它
--
-- 【G 臂是这一刀的理由本身】fx_rate_gaps 的日期只来自【过账日】与【报价日】,
-- 所以一个没有过账、没有报价的月末对它是【结构性不可见】的 —— 而月末重估
-- 非要那天的中间价不可。这张视图就是为那个盲区建的,G 臂盯的就是它。
--
-- 自带数据(README 第 2 条)。期间锁、GST 开关自己设(README 第 4/5 条)。
BEGIN;
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); r_fin uuid;
    v_base text; v_exp text;
    d_past date; m_end date; d_in_month date;
    v_res jsonb; v_id uuid;
    n0 integer; n1 integer;
    v_rate numeric; v_prev numeric; v_notes text;
    v_denied boolean; v_msg text;
    v_blocks boolean; v_seen integer;
    rep jsonb := '{}'::jsonb;
BEGIN
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fixture-134','f','f',true)
      RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id,permission_code)
      SELECT r_fin, unnest(ARRAY['module.finance.view','module.finance.edit']);
    INSERT INTO user_roles (user_id,role_id) VALUES (v_user,r_fin);

    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_exp FROM accounts WHERE account_type='expense' AND is_active ORDER BY code LIMIT 1;
    -- 【上一个月的最后一天】—— 一定在过去,且一定落在视图的范围内(首月…当月)
    m_end     := (date_trunc('month', CURRENT_DATE) - INTERVAL '1 day')::date;
    d_in_month:= date_trunc('month', m_end)::date + 2;
    d_past    := m_end - 1;

    UPDATE finance_settings SET locked_before = NULL,
                                gst_registered = false, gst_registration_no = NULL;
    PERFORM set_config('request.jwt.claims',
        format('{"sub":"%s","role":"authenticated"}', v_user), true);

    -- ══════════ A · 新建留一行 'created' ══════════
    SELECT count(*) INTO n0 FROM fx_rate_history;
    v_res := record_fx_rate('USD', d_past, 'tt_buy', 1.30, 'fixture-134');
    v_id := (v_res->>'id')::uuid;
    SELECT count(*) INTO n1 FROM fx_rate_history WHERE fx_rate_id = v_id AND action='created';
    IF (v_res->>'action') <> 'created' THEN
        RAISE EXCEPTION 'FIXTURE 134 A 失败:第一次录入应当是 created,实得 %', v_res->>'action';
    END IF;
    -- 【从 0 变成 1】不是"至少有一行" —— 后者在一张有历史数据的表上永远为真
    IF n1 <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 134 A 失败:新建必须【正好】留下一行 created 史,实得 %', n1;
    END IF;
    rep := rep || jsonb_build_object('A_created_writes_history', n1);

    -- ══════════ B · 已在册 + 没给理由 → 按名拒,且值不许动 ══════════
    IF NOT EXISTS (SELECT 1 FROM fx_rates WHERE id=v_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 134 B 前提失败:那条牌价应当在册,否则本臂测的是"新建"而不是"已存在"';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_fx_rate('USD', d_past, 'tt_buy', 9.99, 'fixture-134');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'FX_RATE_EXISTS|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 134 B 失败:覆盖一条已在册的牌价必须按名拒(FX_RATE_EXISTS)—— 批量表格只填空、不覆盖。实得 %',
            COALESCE(v_msg,'(覆盖成功了)');
    END IF;
    SELECT rate_sgd_per_unit INTO v_rate FROM fx_rates WHERE id=v_id;
    IF v_rate <> 1.30 THEN
        RAISE EXCEPTION 'FIXTURE 134 B 失败:被拒之后金额必须原封不动(1.30),实得 %', v_rate;
    END IF;
    rep := rep || jsonb_build_object('B_refuses_silent_overwrite', v_msg);

    -- ══════════ C · 给了理由 → 改成,并留下【改之前是什么】 ══════════
    v_res := record_fx_rate('USD', d_past, 'tt_buy', 1.42, 'fixture-134', NULL, '打错了一位,DBS 单子上是 1.42');
    IF (v_res->>'action') <> 'corrected' THEN
        RAISE EXCEPTION 'FIXTURE 134 C 失败:带理由的重录应当是 corrected,实得 %', v_res->>'action';
    END IF;
    SELECT prev_rate, rate_sgd_per_unit INTO v_prev, v_rate
      FROM fx_rate_history WHERE fx_rate_id=v_id AND action='corrected';
    IF v_prev IS NULL OR v_prev = v_rate THEN
        RAISE EXCEPTION 'FIXTURE 134 C 失败(空转):prev_rate(%)必须存在且与新值(%)不同,否则这一臂没有证明"改之前是什么"还答得出来',
            v_prev, v_rate;
    END IF;
    IF v_prev <> 1.30 THEN
        RAISE EXCEPTION 'FIXTURE 134 C 失败:改之前那个数应当是 1.30,实得 %', v_prev;
    END IF;
    rep := rep || jsonb_build_object('C_correction_keeps_the_old_number', v_prev);

    -- ══════════ D · 直接 UPDATE 金额 → 拒;而改 notes 仍然可以 ══════════
    v_denied := false; v_msg := NULL;
    BEGIN UPDATE fx_rates SET rate_sgd_per_unit = 7.77 WHERE id = v_id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'FX_RATE_VIA_FUNCTION|UPDATE%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 134 D 失败:直接改金额必须被拒 —— 那是唯一一种"一次提交就毁掉审计线索"的操作。实得 %',
            COALESCE(v_msg,'(改成功了)');
    END IF;
    -- 【这道闸必须【窄】】不改金额的 UPDATE 不该被拦,否则撤销、改备注全都做不了
    UPDATE fx_rates SET notes = 'fixture-134 narrow-guard probe' WHERE id = v_id;
    SELECT notes, rate_sgd_per_unit INTO v_notes, v_rate FROM fx_rates WHERE id=v_id;
    IF v_notes <> 'fixture-134 narrow-guard probe' THEN
        RAISE EXCEPTION 'FIXTURE 134 D 失败:不动金额的 UPDATE 应当放行(闸要窄),实得 %', COALESCE(v_notes,'(null)');
    END IF;
    IF v_rate <> 1.42 THEN
        RAISE EXCEPTION 'FIXTURE 134 D 失败:被拒之后金额应当仍是 1.42,实得 %', v_rate;
    END IF;
    rep := rep || jsonb_build_object('D_value_change_blocked_notes_allowed', true);

    -- ══════════ E · 直接 DELETE → 拒(硬删是唯一真正不可追的操作) ══════════
    v_denied := false; v_msg := NULL;
    BEGIN DELETE FROM fx_rates WHERE id = v_id;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'FX_RATE_VIA_FUNCTION|DELETE%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 134 E 失败:硬删必须被拒,实得 %', COALESCE(v_msg,'(删成功了)');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM fx_rates WHERE id=v_id) THEN
        RAISE EXCEPTION 'FIXTURE 134 E 失败:被拒之后那一行必须还在';
    END IF;
    rep := rep || jsonb_build_object('E_hard_delete_blocked', v_msg);

    -- ══════════ F · 未来日期 → 拒(牌价是【已经发生的】世界事实) ══════════
    IF NOT (CURRENT_DATE + 3 > CURRENT_DATE) THEN
        RAISE EXCEPTION 'FIXTURE 134 F 失败(空转):用来测的日期必须真的是未来';
    END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_fx_rate('USD', CURRENT_DATE + 3, 'mid', 1.31, 'fixture-134');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'FX_RATE_DATE_IN_FUTURE|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 134 F 失败:给一个还没到的日子录牌价 = 发明一个牌价,必须按名拒。实得 %',
            COALESCE(v_msg,'(收下了)');
    END IF;
    rep := rep || jsonb_build_object('F_future_date_refused', v_msg);

    -- ══════════ G · 月末【看得见】,而且状态会翻 ══════════
    -- 造一笔上个月的外币货币性分录 —— 于是那个月末进入视图范围
    PERFORM post_journal_entry(d_in_month, 'f134 外币应付', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code','2000','side','credit','currency','USD','amount_ccy',5000,'fx_rate',1.30),
        jsonb_build_object('account_code',v_exp,'side','debit','currency','USD','amount_ccy',5000,'fx_rate',1.30)));

    SELECT count(*) INTO v_seen FROM fx_month_end_readiness
     WHERE month_end = m_end AND currency = 'USD';
    IF v_seen <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 134 G 前提失败:月末 % 应当在就绪表里出现【正好一次】,实得 % —— 这正是 fx_rate_gaps 看不见的那种日子',
            m_end, v_seen;
    END IF;
    SELECT blocks_close INTO v_blocks FROM fx_month_end_readiness
     WHERE month_end = m_end AND currency = 'USD';
    IF NOT v_blocks THEN
        RAISE EXCEPTION 'FIXTURE 134 G 失败:还没有中间价时,月末 % 必须报 blocks_close', m_end;
    END IF;

    -- 录上那天的中间价,状态必须翻过来
    PERFORM record_fx_rate('USD', m_end, 'mid', 1.33, 'fixture-134');
    SELECT blocks_close INTO v_blocks FROM fx_month_end_readiness
     WHERE month_end = m_end AND currency = 'USD';
    -- 【两种状态都观察到了】所以这一臂不可能因为"视图恒为空"或"恒为 true"而通过
    IF v_blocks THEN
        RAISE EXCEPTION 'FIXTURE 134 G 失败:录入中间价之后 % 必须不再挡住月结', m_end;
    END IF;
    rep := rep || jsonb_build_object('G_month_end_visible_and_flips', true);

    -- ══════════ H · 撤销要理由,留 'withdrawn',而且真的查不到了 ══════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM withdraw_fx_rate(v_id, '   ');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'FX_REASON_REQUIRED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 134 H 失败:撤销必须填理由,实得 %', COALESCE(v_msg,'(撤销成功了)');
    END IF;
    PERFORM withdraw_fx_rate(v_id, '这一天银行根本没挂牌,录错了');
    IF NOT EXISTS (SELECT 1 FROM fx_rate_history WHERE fx_rate_id=v_id AND action='withdrawn') THEN
        RAISE EXCEPTION 'FIXTURE 134 H 失败:撤销必须留下一行 withdrawn 史';
    END IF;
    IF EXISTS (SELECT 1 FROM fx_rate_asof('USD', d_past, 'tt_buy')) THEN
        RAISE EXCEPTION 'FIXTURE 134 H 失败:撤销之后 fx_rate_asof 不该再找得到它';
    END IF;
    rep := rep || jsonb_build_object('H_withdraw_needs_reason_and_hides', true);

    RAISE NOTICE 'FIXTURE 134 全部通过 %', rep::text;
END $$;
ROLLBACK;

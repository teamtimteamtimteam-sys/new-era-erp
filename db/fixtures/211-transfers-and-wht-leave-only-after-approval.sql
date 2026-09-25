-- fixture 211 —— 银行转账与代扣税缴纳,钱离开之前也要先批(PAY-REQ-1 · Batch B,2026-09-23)
-- ★ AP-RECON-1 Batch B(2026-09-24):本 fixture 的日期从 2030 挪到 2025(真实的过去)。三条日期规矩落地之后,晚于今天的单据与晚于本月末的分录都按名拒,而且【没有测试开关】(Tim AP-RECON-1 Q7 / Batch B Q8)—— 所以挪的是 fixture,不是闸。
--
-- Tim 的裁定(Q15,Batch B grilling Q2–Q4):行内转账与其冲销、代扣税缴纳与其冲销 ——
-- 财务提,CFO 批每一张,财务执行;分录只在执行那一刻过账;提单人永远不能批。
--
-- 各臂:
--   A  门:三支旧入口按名拒并指路(没有权限的人先听到 PERMISSION_DENIED);四支内层引擎
--      authenticated 调不到;通用冲销口对代扣税缴纳的分录也关门
--   B  转账:提 → 不碰总账、留痕二级、没有收款人 · 提单人批不了 · 一级持有人批不了 ·
--      CFO 批 · 没日期 / 带汇率 / 审批人自己 都付不了 · 财务付 → 一张分录、一行转账、结果记在申请上
--   C  转账冲销:理由必填 · 一笔一张 · 批 → 执行要日期 → 原转账 reversed
--   D  代扣税缴纳:冻结提交那一刻的推导值 · 推导值变了批不了(按名)· 同一个月一张 ·
--      撤回重提 → 批 → 付 → 这个月欠款归零
--   E  代扣税缴纳冲销:执行后这个月的欠款原样回来
--   F  ★ 故障注入:一张不认识的种类,试跑与执行都按名拒 —— 而不是被当成付款冲销
--   G  RLS:同一会话、同一张表,两个身份两个答案(SET LOCAL ROLE authenticated)
BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_fin  uuid := gen_random_uuid();   -- 财务:提、付
    u_cfo  uuid := gen_random_uuid();   -- 二级审批角色
    u_cfo2 uuid := gen_random_uuid();   -- ★ 二级审批角色,同时持 finance.edit —— 自己提、自己批的那一臂
    u_l1   uuid := gen_random_uuid();   -- 一级审批角色
    u_none uuid := gen_random_uuid();   -- 什么码都没有
    r_fin uuid; r_l1 uuid; r_l2 uuid; r_none uuid;
    v_base text; v_acct text; v_usd text;
    d date := DATE '2025-04-01';
    d_pay date := DATE '2025-04-10';
    v_month date := DATE '2025-04-01';
    v_res jsonb; v_req uuid; v_req2 uuid; v_req3 uuid; v_req4 uuid; v_req5 uuid; v_req6 uuid;
    v_tid uuid; v_wid uuid; v_eid uuid;
    v_je integer; v_je2 integer; v_n integer; v_m integer; v_amt numeric; v_unrem numeric;
    v_msg text; v_denied boolean; v_st text;
    rep jsonb := '{}'::jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    v_usd := CASE WHEN bank_native_currency('1010') <> v_base THEN '1010' END;
    IF v_base IS NULL OR v_acct IS NULL OR v_usd IS NULL OR bank_native_currency('1000') <> v_base THEN
        RAISE EXCEPTION 'FIXTURE 211 布景失败:要本位币户 1000、外币户 1010 与一个费用科目(依赖种子数据)';
    END IF;

    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_none, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx211-fin','f','f',true)  RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx211-l1','f','f',true)   RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx211-l2','f','f',true)   RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx211-none','f','f',true) RETURNING id INTO r_none;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.view'), (r_fin, 'module.finance.edit'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices'),
        (r_l1,  'module.finance.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'), (r_l1, 'module.purchasing.view'),
        (r_l2,  'module.finance.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'), (r_l2, 'module.purchasing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_cfo, r_l2), (u_cfo2, r_l2), (u_cfo2, r_fin), (u_l1, r_l1), (u_none, r_none);

    -- 期间开着;策略:一级 fx211-l1、二级 fx211-l2、门槛 1000;审批打开
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    -- ★ PAYROLL-APR-1(2026-09-24):工资过账申请这条链的门是 module.hr.view + data.view_pay(Tim 的 Q8)。
    --   二级角色不持这两个码,开审批就会按名拒 APPROVALS_CHAIN_HAS_NO_APPROVER|decide_payroll_request —— 本 fixture 测的不是它。
    -- ★ ROLE-1 Batch 4b(2026-09-25):收货定价申请这条链的门是 module.inbound.view + data.view_purchase_prices
    --   (Tim 的 Q2),同一个理由一并给上 —— 否则 …|decide_receipt_price_request。
    -- ★ APR-5b(2026-09-25):发货放行这条链的门是 module.sales.view + data.view_prices —— 二级补上 module.sales.view,否则开不了审批。
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, c FROM roles r CROSS JOIN unnest(ARRAY['module.hr.view', 'data.view_pay', 'module.inbound.view', 'data.view_purchase_prices', 'module.sales.view']) c
     WHERE r.code = 'fx211-l2'
    ON CONFLICT (role_id, permission_code) DO NOTHING;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx211-l1',
                                approval_level2_role_code = 'fx211-l2',
                                approval_threshold_base   = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════ A · 门 ══════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_bank_transfer(d, v_usd, '1000', 10, 13, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_REQUIRED|bank_transfer'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211A1 失败:行内转账应当按名拒 PAYMENT_REQUEST_REQUIRED|bank_transfer,实得 %', COALESCE(v_msg, '(直接转了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM reverse_bank_transfer(gen_random_uuid(), d, 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_REQUIRED|bank_transfer_reversal'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211A2 失败:转账冲销应当按名拒,实得 %', COALESCE(v_msg, '(没有拒)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM remit_wht(v_month, d_pay, 'X', '1000', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_REQUIRED|wht_remittance'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211A3 失败:代扣税缴纳应当按名拒,实得 %', COALESCE(v_msg, '(直接缴了)'); END IF;
    -- 没有权限的人先听到"没有权限",不是"去提申请"
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_none), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_bank_transfer(d, v_usd, '1000', 10, 13, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PERMISSION_DENIED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211A4 失败:没有权限的调用者应当先撞 PERMISSION_DENIED,实得 %', COALESCE(v_msg, '(放行了)'); END IF;
    IF has_function_privilege('authenticated', 'public.record_bank_transfer_internal(date, text, text, numeric, numeric, text, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.reverse_bank_transfer_internal(uuid, date, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.remit_wht_internal(date, date, text, text, text, numeric)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.reverse_wht_remittance_internal(uuid, date, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 211A5 失败:authenticated 能直接调转账 / 代扣税引擎 —— 申请这道闸形同虚设'; END IF;
    IF NOT has_function_privilege('authenticated', 'public.submit_bank_transfer_request(date, text, text, numeric, numeric, text, text)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.submit_wht_remittance_request(date, date, text, text, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 211A5 失败(对照):提交函数应当对 authenticated 可执行'; END IF;
    rep := rep || jsonb_build_object('A_doors', true);

    -- ══════════ B · 转账 ════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    SELECT count(*) INTO v_je FROM journal_entries;
    SELECT count(*) INTO v_n FROM bank_transfers;
    v_res := submit_bank_transfer_request(d_pay, v_usd, '1000', 100, 135, 'FX211-REF', 'fx211 B');
    v_req := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'amount_base')::numeric <> 135 THEN
        RAISE EXCEPTION 'FIXTURE 211B1 失败:转账申请应当落 submitted、本位币额 135(转入本位币户的那一边),实得 %', v_res; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je OR (SELECT count(*) FROM bank_transfers) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 211B1 失败:提交转账申请碰了总账或转账表'; END IF;
    IF (SELECT counterparty_type FROM payment_requests WHERE id = v_req) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 211B1 失败:转账申请不该有收款人'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_id = v_req AND decision = 'submitted' AND level = 2) THEN
        RAISE EXCEPTION 'FIXTURE 211B1 失败:留痕应当有一行 submitted / 二级'; END IF;
    -- 同币种金额不等:在提交时就按引擎原话拒
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_bank_transfer_request(d_pay, '1000', '1000', 5, 5, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'TRANSFER_SAME_ACCOUNT|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211B2 失败:同一个账户的转账应当在提交时按引擎原话拒,实得 %', COALESCE(v_msg, '(提上去了)'); END IF;

    -- ★ 二级持有人自己提的,自己批不了(没有例外)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo2), true);
    v_req2 := (submit_bank_transfer_request(d_pay, v_usd, '1000', 1, 1.35, NULL, 'fx211 self')->>'request_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decide_payment_request(v_req2, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'SELF_APPROVAL_FORBIDDEN|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211B3 失败:提单人批了自己的转账申请,实得 %', COALESCE(v_msg, '(批了)'); END IF;
    -- 一级持有人批不了(不分档)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decide_payment_request(v_req, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVAL_NOT_AUTHORISED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211B4 失败:一级持有人批了一张转账申请(应当只有二级),实得 %', COALESCE(v_msg, '(批了)'); END IF;
    -- 没批不许付
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req, d_pay, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REQUEST_NOT_APPROVED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211B5 失败:没批的转账申请被执行了,实得 %', COALESCE(v_msg, '(转了)'); END IF;
    -- CFO 批
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payment_request(v_req, true, NULL);
    IF (SELECT count(*) FROM journal_entries) <> v_je THEN
        RAISE EXCEPTION 'FIXTURE 211B6 失败:批准一张转账申请碰了总账'; END IF;
    -- 审批人自己执行不了
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req, d_pay, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PERMISSION_DENIED%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211B7 失败:审批人执行了转账,实得 %', COALESCE(v_msg, '(转了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_DATE_REQUIRED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211B8 失败:不给转账日也执行了(日期决定期间,不许默认今天),实得 %', COALESCE(v_msg, '(转了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req, d_pay, 1.5);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REQUEST_TAKES_NO_RATE|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211B9 失败:转账执行时收了一个汇率(两边金额申请上就定了),实得 %', COALESCE(v_msg, '(转了)'); END IF;
    -- AP-RECON-1 Batch B(Tim Q10):B8/B10 的"不默认今天"只有在转账日【不是今天】时才证得出来。
    IF d_pay = CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 211B10 失败(空转):转账日恰好是今天 —— 分不开"用了给的日子"与"默认成今天"';
    END IF;
    v_res := pay_payment_request(v_req, d_pay, NULL);
    SELECT status, result_transfer_id, result_journal_entry_id INTO v_st, v_tid, v_eid FROM payment_requests WHERE id = v_req;
    IF v_st <> 'paid' OR v_tid IS NULL OR v_eid IS NULL
       OR (SELECT count(*) FROM journal_entries) <> v_je + 1
       OR (SELECT journal_entry_id FROM bank_transfers WHERE id = v_tid) <> v_eid
       OR (SELECT transfer_date FROM bank_transfers WHERE id = v_tid) <> d_pay THEN
        RAISE EXCEPTION 'FIXTURE 211B10 失败:执行转账应当恰好一张分录、一行转账(日期 = 执行时给的那一天),结果记在申请上'; END IF;
    rep := rep || jsonb_build_object('B_transfer', true);

    -- ══════════ C · 转账冲销 ════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_bank_transfer_reversal_request(v_tid, '  ');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'REVERSAL_REASON_REQUIRED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211C1 失败:没有理由的转账冲销申请提上去了,实得 %', COALESCE(v_msg, '(提了)'); END IF;
    v_req3 := (submit_bank_transfer_reversal_request(v_tid, 'fx211 wrong account')->>'request_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_bank_transfer_reversal_request(v_tid, 'again');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'TRANSFER_REVERSAL_ALREADY_REQUESTED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211C2 失败:同一笔转账挂了两张冲销申请,实得 %', COALESCE(v_msg, '(提了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payment_request(v_req3, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    SELECT count(*) INTO v_je2 FROM journal_entries;
    PERFORM pay_payment_request(v_req3, d_pay, NULL);
    IF (SELECT reversed_at FROM bank_transfers WHERE id = v_tid) IS NULL
       OR (SELECT count(*) FROM journal_entries) <> v_je2 + 1
       OR (SELECT status FROM journal_entries WHERE id = v_eid) <> 'reversed'
       OR (SELECT result_journal_entry_id FROM payment_requests WHERE id = v_req3) IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 211C3 失败:执行转账冲销应当恰好一张冲销分录、原转账与原分录都标为已冲'; END IF;
    rep := rep || jsonb_build_object('C_transfer_reversal', true);

    -- ══════════ D · 代扣税缴纳 ══════════════════════════════════════════════
    -- 布景:这个月在 2150 上记 70 的代扣(手工分录;视图把一切非缴纳的 2150 活动都算作代扣)
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM post_journal_entry(d, 'fx211 withheld', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit',  'currency', v_base, 'amount_ccy', 70),
        jsonb_build_object('account_code', '2150', 'side', 'credit', 'currency', v_base, 'amount_ccy', 70)));
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := submit_wht_remittance_request(v_month, d_pay, 'ZZ-F211-IRAS', NULL, 'fx211 D');
    v_req4 := (v_res->>'request_id')::uuid;
    SELECT amount_ccy INTO v_amt FROM payment_requests WHERE id = v_req4;
    IF v_amt <> 70 OR (v_res->>'amount_base')::numeric <> 70 THEN
        RAISE EXCEPTION 'FIXTURE 211D1 失败:缴纳申请应当冻结提交那一刻的推导值 70,实得 % / %', v_amt, v_res; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_wht_remittance_request(v_month, d_pay, 'ZZ-F211-IRAS-2', NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'WHT_REMITTANCE_ALREADY_REQUESTED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211D2 失败:同一个代扣月挂了两张缴纳申请(合起来会汇两遍),实得 %', COALESCE(v_msg, '(提了)'); END IF;
    -- 推导值变了:又记了 5 的代扣 → CFO 批不了,按名拒(批的必须是会汇出去的那个数)
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM post_journal_entry(d, 'fx211 withheld more', 'manual', NULL, jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit',  'currency', v_base, 'amount_ccy', 5),
        jsonb_build_object('account_code', '2150', 'side', 'credit', 'currency', v_base, 'amount_ccy', 5)));
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decide_payment_request(v_req4, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (split_part(SQLERRM, '|', 1) = 'WHT_REMIT_AMOUNT_CHANGED'
                     AND split_part(SQLERRM, '|', 3)::numeric = 70 AND split_part(SQLERRM, '|', 4)::numeric = 75); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211D3 失败:推导值从 70 变成 75,批准应当按名拒 WHT_REMIT_AMOUNT_CHANGED,实得 %', COALESCE(v_msg, '(批了)'); END IF;
    -- 撤回、按新数重提、批、付
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    PERFORM withdraw_payment_request(v_req4);
    v_req5 := (submit_wht_remittance_request(v_month, d_pay, 'ZZ-F211-IRAS', NULL, 'fx211 D2')->>'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payment_request(v_req5, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    SELECT count(*) INTO v_je2 FROM journal_entries;
    v_res := pay_payment_request(v_req5, d_pay, NULL);
    SELECT unremitted_base INTO v_unrem FROM wht_liability_by_month WHERE period_month = v_month;
    SELECT id INTO v_wid FROM wht_remittances
     WHERE journal_entry_id = (SELECT result_journal_entry_id FROM payment_requests WHERE id = v_req5);
    IF v_wid IS NULL OR COALESCE(v_unrem, -1) <> 0 OR (SELECT count(*) FROM journal_entries) <> v_je2 + 1
       OR (SELECT amount_base FROM wht_remittances WHERE id = v_wid) <> 75 THEN
        RAISE EXCEPTION 'FIXTURE 211D4 失败:执行缴纳之后应当一行缴纳 75、一张分录、这个月欠款归零,实得欠款 %', v_unrem; END IF;
    rep := rep || jsonb_build_object('D_wht_remittance', true);

    -- ══════════ E · 代扣税缴纳冲销 ══════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_journal_entry((SELECT journal_entry_id FROM wht_remittances WHERE id = v_wid), d_pay, 'fx211');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|wht_remittance'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211E1 失败:代扣税缴纳的分录从通用冲销口冲掉了,实得 %', COALESCE(v_msg, '(冲了)'); END IF;
    v_req6 := (submit_wht_remittance_reversal_request(v_wid, 'fx211 filed twice')->>'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payment_request(v_req6, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    PERFORM pay_payment_request(v_req6, d_pay, NULL);
    SELECT unremitted_base INTO v_unrem FROM wht_liability_by_month WHERE period_month = v_month;
    IF v_unrem <> 75 THEN
        RAISE EXCEPTION 'FIXTURE 211E2 失败:冲销缴纳之后这个月的欠款应当回到 75,实得 %', v_unrem; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_wht_remittance_reversal_request(v_wid, 'again');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'WHT_REMITTANCE_ALREADY_REVERSED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211E3 失败:已冲过的缴纳又提了一张冲销申请,实得 %', COALESCE(v_msg, '(提了)'); END IF;
    rep := rep || jsonb_build_object('E_wht_reversal', true);

    -- ══════════ F · ★ 故障注入:一张不认识的种类 ═════════════════════════════
    -- Batch A 的试跑与执行用一个裸 ELSE 当"付款冲销" —— 一种新申请会被悄悄拿去冲一笔
    -- payment_id 为 NULL 的付款。这里把形状约束临时拿掉(整支 fixture 最后回滚),
    -- 塞一行不认识的种类,两扇门都必须按名拒。
    PERFORM set_config('request.jwt.claims', '', true);
    ALTER TABLE payment_requests DROP CONSTRAINT payment_requests_kind_check;
    ALTER TABLE payment_requests DROP CONSTRAINT payment_requests_kind_shape;
    INSERT INTO payment_requests (id, code, kind, status, counterparty_type, amount_ccy, currency,
                                  amount_base, notes, created_by)
    VALUES (gen_random_uuid(), 'FX211-ZZ', 'zz_unknown', 'approved', NULL, 1, v_base, 1, 'x', u_fin)
    RETURNING id INTO v_req;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM payment_request_dry_run(v_req);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_KIND_UNKNOWN|FX211-ZZ|zz_unknown'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211F1 失败:试跑一张不认识的种类没有按名拒,实得 %', COALESCE(v_msg, '(跑了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req, d_pay, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_KIND_UNKNOWN|FX211-ZZ|zz_unknown'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 211F2 失败:执行一张不认识的种类没有按名拒,实得 %', COALESCE(v_msg, '(执行了)'); END IF;
    rep := rep || jsonb_build_object('F_unknown_kind', true);

    -- ══════════ G · RLS:两个身份,同一会话同一张表 ═══════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM payment_requests WHERE kind <> 'payment_out';
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_m FROM payment_requests
     WHERE kind IN ('bank_transfer', 'bank_transfer_reversal', 'wht_remittance', 'wht_remittance_reversal')
       AND created_by IN (u_fin, u_cfo2);
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 OR v_m < 6 THEN
        RAISE EXCEPTION 'FIXTURE 211G 失败:没有财务码的人读到 % 行(应为 0);CFO 读到 % 行(应至少 6)', v_n, v_m; END IF;
    rep := rep || jsonb_build_object('G_rls', true);

    RAISE NOTICE 'FIXTURE 211 全部通过 %', rep::text;
END $$;
ROLLBACK;

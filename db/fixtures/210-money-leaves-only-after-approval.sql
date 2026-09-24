-- fixture 210 —— 钱离开之前要先批(PAY-REQ-1 · Batch A,2026-09-23)
-- ★ AP-RECON-1 Batch B(2026-09-24):本 fixture 的日期从 2030 挪到 2025(真实的过去)。三条日期规矩落地之后,晚于今天的单据与晚于本月末的分录都按名拒,而且【没有测试开关】(Tim AP-RECON-1 Q7 / Batch B Q8)—— 所以挪的是 fixture,不是闸。
--
-- Tim 的裁定:付款申请 → CFO 批准 → 付款。付款与冲销付款:财务提,CFO 批,每一张都批、
-- 不分档;提单人永远不能批(按人认);收款不批;整笔付已批准的报销 / 医疗申报不批(Q1)。
--
-- 各臂:
--   A  门:出款与冲销不许直走(record_payment / reverse_payment 按名拒);内层引擎
--      authenticated 调不到;豁免的判据两个方向都答对(Q1)
--   B  提:落 submitted、留痕 submitted/二级、不碰总账;同一张单据不许挂两张申请
--   C  批:★ 二级持有人自己提的申请【自己批不了】(没有 R2 例外)· 一级持有人批不了
--      一张 100 块的申请(不分档)· 另一位二级持有人批得了
--   D  付:没批不许付 · 不给日期不许付 · 审批人付不了 · 财务付 → 分录一张、单据结清
--   E  冲销申请:理由必填 · 一笔一张 · 批 → 执行 → 原付款 reversed
--   F  驳回要理由 · G 撤回(approved 也可以撤)
--   H  审批关着:有 submitted 的申请关不掉(点名);关着时提 → 生下来 approved + auto_approved
--   I  收款人被拉黑 → 批与付都按名拒
--   J  Q2 的侧门:费用 / 运费不许生下来已付;费用默认值是挂账;付款的分录不许从通用冲销口冲
--   K  WOULD_STRAND 读 fixed_level:门槛抬高也不会把它错分到一级;二级换成没人批得动的角色 → 点名
--   L  RLS:同一会话、同一张表,两个身份两个答案(SET LOCAL ROLE authenticated)
BEGIN;
SET LOCAL statement_timeout = '180s';
DO $$
DECLARE
    u_fin   uuid := gen_random_uuid();   -- 财务:提、付
    u_fin2  uuid := gen_random_uuid();   -- 另一位财务:建供应商(付款人不能是建户人,SOD_PAYEE_AND_PAY)
    u_cfo   uuid := gen_random_uuid();   -- 二级审批角色
    u_cfo2  uuid := gen_random_uuid();   -- ★ 二级审批角色,同时持 finance.edit —— 自己提、自己批的那一臂
    u_l1    uuid := gen_random_uuid();   -- 一级审批角色
    u_none  uuid := gen_random_uuid();   -- 什么码都没有
    r_fin uuid; r_l1 uuid; r_l2 uuid; r_none uuid; r_l2bad uuid;
    e_emp uuid := gen_random_uuid();
    v_sup uuid; v_sup2 uuid;
    v_base text; v_acct text;
    d date := DATE '2025-03-01';
    d_pay date := DATE '2025-03-10';
    v_exp1 uuid; v_exp2 uuid; v_exp3 uuid; v_exp4 uuid; v_exp5 uuid; v_exp_emp uuid; v_exp6 uuid;
    v_req1 uuid; v_req2 uuid; v_req3 uuid; v_req4 uuid; v_req5 uuid; v_req6 uuid; v_req7 uuid;
    v_res jsonb; v_pay uuid; v_je_before integer; v_n integer; v_m integer;
    v_msg text; v_denied boolean; v_code text; v_st text;
    rep jsonb := '{}'::jsonb;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    IF v_base IS NULL OR v_acct IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 210 布景失败:缺本位币或费用科目(依赖种子数据)';
    END IF;

    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_fin2, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_none, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx210-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx210-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx210-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx210-none','f','f',true) RETURNING id INTO r_none;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx210-l2bad','f','f',true) RETURNING id INTO r_l2bad;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.view'), (r_fin, 'module.finance.edit'), (r_fin, 'data.view_prices'),
        (r_fin, 'module.suppliers.view'), (r_fin, 'module.suppliers.edit'),
        (r_l1,  'module.finance.view'), (r_l1,  'data.view_prices'), (r_l1, 'module.purchasing.view'),
        (r_l2,  'module.finance.view'), (r_l2,  'data.view_prices'), (r_l2, 'module.purchasing.view'),
        -- 看得见金额、进得了采购,但进不了财务 —— 付款申请这条链在它手里没人批得动
        (r_l2bad, 'data.view_prices'), (r_l2bad, 'module.purchasing.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_fin2, r_fin), (u_cfo, r_l2), (u_cfo2, r_l2), (u_cfo2, r_fin),
        (u_l1, r_l1), (u_none, r_none);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date)
    VALUES (e_emp, 'FX210-E', 'FX210 Employee', 'full_time', 'office', DATE '2020-01-01');

    -- 期间开着;策略:一级 fx210-l1、二级 fx210-l2、门槛 1000;审批打开
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx210-l1',
                                approval_level2_role_code = 'fx210-l2',
                                approval_threshold_base   = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- 供应商由 u_fin2 建(u_fin 付款给它不撞 SOD)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin2), true);
    -- ROLE-1 Batch 2a:新采购单 / 付款申请要一家【已批准】的供应商(approved / active)。
    -- 属主路径直接生成 active —— 直连 INSERT 必须是 draft 那条只管客户端会话。
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
      VALUES ('active', 'FX210-SUP', 'FX210 Supplier', 'SG', 'service_vendor') RETURNING id INTO v_sup;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
      VALUES ('active', 'FX210-SUP2', 'FX210 Supplier 2', 'SG', 'service_vendor') RETURNING id INTO v_sup2;

    -- 挂账的费用单(五张给供应商、一张给员工)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_exp1 := (record_expense(d, v_acct, 100, v_base, NULL, 'unpaid', NULL, v_sup)->>'expense_id')::uuid;
    v_exp2 := (record_expense(d, v_acct, 200, v_base, NULL, 'unpaid', NULL, v_sup)->>'expense_id')::uuid;
    v_exp3 := (record_expense(d, v_acct, 300, v_base, NULL, 'unpaid', NULL, v_sup)->>'expense_id')::uuid;
    v_exp4 := (record_expense(d, v_acct, 400, v_base, NULL, 'unpaid', NULL, v_sup)->>'expense_id')::uuid;
    v_exp5 := (record_expense(d, v_acct, 500, v_base, NULL, 'unpaid', NULL, v_sup2)->>'expense_id')::uuid;
    v_exp6 := (record_expense(d, v_acct, 600, v_base, NULL, 'unpaid', NULL, v_sup)->>'expense_id')::uuid;
    v_exp_emp := (record_expense(p_expense_date := d, p_account_code := v_acct, p_amount := 50,
                                 p_currency := v_base, p_payment_status := 'unpaid',
                                 p_employee_id := e_emp)->>'expense_id')::uuid;

    -- ══════════ A · 门 ══════════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM record_payment('out', v_sup, 100, v_base, NULL, NULL, d_pay, NULL,
            jsonb_build_array(jsonb_build_object('expense_id', v_exp1, 'amount_doc', 100)));
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_REQUIRED|payment_out'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210A1 失败:给供应商的出款应当按名拒 PAYMENT_REQUEST_REQUIRED|payment_out,实得 %', COALESCE(v_msg, '(直接付了)'); END IF;

    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_payment(gen_random_uuid(), 'x');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_REQUIRED|payment_reversal'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210A2 失败:冲销应当一律走申请,实得 %', COALESCE(v_msg, '(没有拒)'); END IF;

    -- 内层引擎与试跑:authenticated 调不到(重建库里 zzz_function_grants 已经跑过)
    IF has_function_privilege('authenticated', 'public.record_payment_internal(text, uuid, numeric, text, numeric, text, date, text, jsonb, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.reverse_payment_internal(uuid, text)', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.payment_request_dry_run(uuid, date, numeric)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 210A3 失败:authenticated 能直接调付款引擎 —— 申请这道闸形同虚设'; END IF;
    -- 对照:外门本身调得到
    IF NOT has_function_privilege('authenticated', 'public.pay_payment_request(uuid, date, numeric)', 'EXECUTE') THEN
        RAISE EXCEPTION 'FIXTURE 210A3 失败(对照):pay_payment_request 应当对 authenticated 可执行'; END IF;

    -- 豁免判据(Q1):收款 false · 供应商 true · 员工付普通费用 true
    IF payment_request_required('in', NULL, gen_random_uuid(), 1, v_base, '[]'::jsonb) THEN
        RAISE EXCEPTION 'FIXTURE 210A4 失败:收款不该要申请'; END IF;
    IF NOT payment_request_required('out', 'employee', e_emp, 50, v_base,
            jsonb_build_array(jsonb_build_object('expense_id', v_exp_emp, 'amount_doc', 50))) THEN
        RAISE EXCEPTION 'FIXTURE 210A4 失败:付员工一张【不是报销单生成】的费用,应当要申请'; END IF;
    -- 把它变成一张已批准报销单生成的费用 → 整笔付它不要申请
    INSERT INTO expense_claims (code, employee_id, spend_date, amount_ccy, currency, description,
                                no_receipt_reason, status, decided_at, decided_by, account_code,
                                posting_date, expense_id, created_by)
    VALUES ('FX210-CLM', e_emp, d, 50, v_base, 'fx210', 'none', 'approved', now(), u_cfo, v_acct,
            d, v_exp_emp, u_fin);
    IF payment_request_required('out', 'employee', e_emp, 50, v_base,
            jsonb_build_array(jsonb_build_object('expense_id', v_exp_emp, 'amount_doc', 50))) THEN
        RAISE EXCEPTION 'FIXTURE 210A4 失败:整笔付一张已批准报销单生成的费用,不该要申请(Tim 的 Q1)'; END IF;
    -- 不是整笔(带挂账余额)→ 要申请
    IF NOT payment_request_required('out', 'employee', e_emp, 60, v_base,
            jsonb_build_array(jsonb_build_object('expense_id', v_exp_emp, 'amount_doc', 50))) THEN
        RAISE EXCEPTION 'FIXTURE 210A4 失败:带挂账余额的员工出款应当要申请(豁免只给"整笔")'; END IF;
    -- 豁免的那一笔:不许走申请,直接付得出去
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM submit_payment_request(e_emp, 50, v_base, NULL, NULL, d_pay, NULL,
            jsonb_build_array(jsonb_build_object('expense_id', v_exp_emp, 'amount_doc', 50)), 'employee');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_NOT_REQUIRED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210A5 失败:豁免的出款不该排进 CFO 的队,实得 %', COALESCE(v_msg, '(收下了)'); END IF;
    v_res := record_payment('out', e_emp, 50, v_base, NULL, NULL, d_pay, NULL,
        jsonb_build_array(jsonb_build_object('expense_id', v_exp_emp, 'amount_doc', 50)), 'employee');
    IF v_res->>'payment_id' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 210A5 失败:整笔付已批准的报销,应当直接记得了付款'; END IF;
    rep := rep || jsonb_build_object('A_doors', true);

    -- ══════════ B · 提 ══════════════════════════════════════════════════════
    SELECT count(*) INTO v_je_before FROM journal_entries;
    v_res := submit_payment_request(v_sup, 100, v_base, NULL, NULL, d_pay, 'fx210 B',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp1, 'amount_doc', 100)), 'supplier');
    v_req1 := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (v_res->>'amount_base')::numeric <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 210B1 失败:审批开着时应当 submitted、本位币 100,实得 %', v_res; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je_before THEN
        RAISE EXCEPTION 'FIXTURE 210B1 失败:提申请碰了总账(试跑没有回滚干净)'; END IF;
    IF (SELECT count(*) FROM payments WHERE notes LIKE '%fx210 B%') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 210B1 失败:提申请留下了付款行'; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type = 'payment_request' AND subject_id = v_req1 AND decision = 'submitted' AND level = 2
       AND amount_base = 100 AND NOT self_decided;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 210B1 失败:留痕应当有一行 submitted / 二级 / 100,实得 %', v_n; END IF;
    SELECT count(*) INTO v_n FROM approval_pending_documents() p
     WHERE p.subject_type = 'payment_request' AND p.doc_id = v_req1 AND p.blocks_disable AND p.fixed_level = 2;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 210B2 失败:在途清单里应当有它,blocks_disable = true、fixed_level = 2'; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM submit_payment_request(v_sup, 100, v_base, NULL, NULL, d_pay, NULL,
            jsonb_build_array(jsonb_build_object('expense_id', v_exp1, 'amount_doc', 100)), 'supplier');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REQUEST_TARGET_RESERVED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210B3 失败:同一张单据挂第二张申请应当按名拒,实得 %', COALESCE(v_msg, '(收下了)'); END IF;
    -- 试跑的规矩就是引擎的规矩:超付在【提】的时候就拒
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM submit_payment_request(v_sup, 999, v_base, NULL, NULL, d_pay, NULL,
            jsonb_build_array(jsonb_build_object('expense_id', v_exp2, 'amount_doc', 999)), 'supplier');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'ALLOC_EXCEEDS|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210B4 失败:超付应当在提交时按引擎原话拒 ALLOC_EXCEEDS,实得 %', COALESCE(v_msg, '(收下了)'); END IF;
    rep := rep || jsonb_build_object('B_submit', true);

    -- ══════════ C · 批 ══════════════════════════════════════════════════════
    -- ★ C1:二级持有人自己提的申请,自己批不了 —— 付款没有 R2 例外
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo2), true);
    v_req2 := (submit_payment_request(v_sup, 200, v_base, NULL, NULL, d_pay, 'fx210 C1',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp2, 'amount_doc', 200)), 'supplier')->>'request_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM decide_payment_request(v_req2, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'SELF_APPROVAL_FORBIDDEN|raiser'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210C1 失败:★ 二级持有人批了自己提的付款申请 —— 提单人永远不能批,实得 %', COALESCE(v_msg, '(批了)'); END IF;
    -- C2:一级持有人批不了一张 100 块的申请(不分档:每一张都要二级)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_l1), true);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM decide_payment_request(v_req1, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'APPROVAL_NOT_AUTHORISED|2|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210C2 失败:一级持有人批了一张付款申请 —— 这条链不分档,实得 %', COALESCE(v_msg, '(批了)'); END IF;
    -- C3:另一位二级持有人批得了;留痕 approved / 二级 / 非自批
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payment_request(v_req1, true, NULL);
    PERFORM decide_payment_request(v_req2, true, NULL);   -- u_cfo 替 u_cfo2 批:对照臂,证明 C1 拒的是"自己"
    IF (SELECT status FROM payment_requests WHERE id = v_req1) <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 210C3 失败:二级持有人批了,状态却不是 approved'; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_type = 'payment_request' AND subject_id = v_req1 AND decision = 'approved'
       AND level = 2 AND actor_user_id = u_cfo AND NOT self_decided;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 210C3 失败:留痕应当有一行 approved / 二级 / u_cfo / 非自批,实得 %', v_n; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je_before THEN
        RAISE EXCEPTION 'FIXTURE 210C3 失败:批准碰了总账 —— 分录只该在付款那一刻过'; END IF;
    rep := rep || jsonb_build_object('C_decide', true);

    -- ══════════ D · 付 ══════════════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_req3 := (submit_payment_request(v_sup, 300, v_base, NULL, NULL, d_pay, 'fx210 D',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp3, 'amount_doc', 300)), 'supplier')->>'request_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req3, d_pay, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REQUEST_NOT_APPROVED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210D1 失败:没批的申请付出去了,实得 %', COALESCE(v_msg, '(付了)'); END IF;
    v_denied := false; v_msg := NULL;
    -- AP-RECON-1 Batch B(Tim Q10):"不默认今天"只有在付款日【不是今天】时才证得出来。
    IF d_pay = CURRENT_DATE THEN
        RAISE EXCEPTION 'FIXTURE 210D2 失败(空转):付款日恰好是今天 —— 分不开"用了给的日子"与"默认成今天"';
    END IF;
    BEGIN PERFORM pay_payment_request(v_req1, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_DATE_REQUIRED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210D2 失败:不给付款日应当按名拒(不默认今天),实得 %', COALESCE(v_msg, '(付了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req1, d_pay, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PERMISSION_DENIED|module.finance.edit'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210D3 失败:审批人自己把钱付了出去,实得 %', COALESCE(v_msg, '(付了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := pay_payment_request(v_req1, d_pay, NULL);
    v_pay := (v_res->>'result_payment_id')::uuid;
    IF (SELECT count(*) FROM journal_entries) <> v_je_before + 1 THEN
        RAISE EXCEPTION 'FIXTURE 210D4 失败:付款应当恰好过一张分录'; END IF;
    SELECT status, result_payment_id::text INTO v_st, v_msg FROM payment_requests WHERE id = v_req1;
    IF v_st <> 'paid' OR v_msg IS DISTINCT FROM v_pay::text THEN
        RAISE EXCEPTION 'FIXTURE 210D4 失败:申请应当 paid 并指着那一笔付款,实得 % / %', v_st, v_msg; END IF;
    SELECT count(*), COALESCE(sum(pa.allocated_ccy), 0) INTO v_n, v_m FROM payment_allocations pa
      JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted' WHERE pa.expense_id = v_exp1;
    IF v_n <> 1 OR v_m <> 100 THEN
        RAISE EXCEPTION 'FIXTURE 210D4 失败:那张费用单应当被结掉 100,实得 % 行 / %', v_n, v_m; END IF;
    IF (SELECT created_by FROM payments WHERE id = v_pay) <> u_fin THEN
        RAISE EXCEPTION 'FIXTURE 210D4 失败:付款行的 created_by 应当是付款人'; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req1, d_pay, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REQUEST_NOT_APPROVED|%|paid'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210D5 失败:同一张申请付了两次,实得 %', COALESCE(v_msg, '(又付了)'); END IF;
    rep := rep || jsonb_build_object('D_pay', true);

    -- ══════════ E · 冲销申请 ════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_payment_reversal_request(v_pay, '  ');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REVERSAL_REASON_REQUIRED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210E1 失败:冲销申请不写理由也收下了,实得 %', COALESCE(v_msg, '(收下了)'); END IF;
    v_req4 := (submit_payment_reversal_request(v_pay, 'fx210 E wrong supplier')->>'request_id')::uuid;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM submit_payment_reversal_request(v_pay, 'again');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REVERSAL_ALREADY_REQUESTED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210E2 失败:同一笔付款挂了两张冲销申请,实得 %', COALESCE(v_msg, '(收下了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payment_request(v_req4, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := pay_payment_request(v_req4, NULL, NULL);
    IF (SELECT status FROM payments WHERE id = v_pay) <> 'reversed' THEN
        RAISE EXCEPTION 'FIXTURE 210E3 失败:执行冲销申请之后原付款应当 reversed'; END IF;
    IF (SELECT status FROM payment_requests WHERE id = v_req4) <> 'paid' THEN
        RAISE EXCEPTION 'FIXTURE 210E3 失败:冲销申请执行后应当 paid'; END IF;
    rep := rep || jsonb_build_object('E_reversal', true);

    -- ══════════ F · 驳回 · G · 撤回 ═════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decide_payment_request(v_req3, false, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REQUEST_REJECT_REASON_REQUIRED|%'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210F 失败:驳回不写理由也收下了,实得 %', COALESCE(v_msg, '(驳了)'); END IF;
    PERFORM decide_payment_request(v_req3, false, 'fx210 wrong amount');
    IF (SELECT count(*) FROM approval_log WHERE subject_id = v_req3 AND decision = 'rejected' AND level = 2) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 210F 失败:驳回应当落一行 rejected / 二级'; END IF;
    -- 驳回之后那张单据不再被占着:可以再提一张
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_req5 := (submit_payment_request(v_sup, 300, v_base, NULL, NULL, d_pay, 'fx210 G',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp3, 'amount_doc', 300)), 'supplier')->>'request_id')::uuid;
    -- G:approved 的也撤得回(一张付不出去的申请不许永远占着单据)
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    PERFORM decide_payment_request(v_req5, true, NULL);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    PERFORM withdraw_payment_request(v_req5);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM pay_payment_request(v_req5, d_pay, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'PAYMENT_REQUEST_NOT_APPROVED|%|withdrawn'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210G 失败:撤回的申请还付得出去,实得 %', COALESCE(v_msg, '(付了)'); END IF;
    rep := rep || jsonb_build_object('FG_reject_withdraw', true);

    -- ══════════ I · 收款人被拉黑 ════════════════════════════════════════════
    v_req6 := (submit_payment_request(v_sup2, 500, v_base, NULL, NULL, d_pay, 'fx210 I',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp5, 'amount_doc', 500)), 'supplier')->>'request_id')::uuid;
    PERFORM set_config('request.jwt.claims', '', true);
    -- ROLE-1 Batch 2a:FX210-SUP2 生下来就是 active(未批准的供应商连提交都提不了),
    -- 所以这里只走 active → blacklisted 这一步(属主路径,跳转触发器照样把关)。
    UPDATE suppliers SET status = 'blacklisted' WHERE id = v_sup2;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM decide_payment_request(v_req6, true, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'PAYMENT_REQUEST_SUPPLIER_BLOCKED|FX210-SUP2|blacklisted'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210I 失败:给被拉黑的供应商付款的申请批过了,实得 %', COALESCE(v_msg, '(批了)'); END IF;
    PERFORM decide_payment_request(v_req6, false, 'fx210 blacklisted');   -- 驳回不核:驳回正是出路
    rep := rep || jsonb_build_object('I_blocked_payee', true);

    -- ══════════ J · Q2 的侧门 ═══════════════════════════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_expense(d, v_acct, 10, v_base, NULL, 'paid', NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'EXPENSE_PAID_AT_CREATION_REFUSED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210J1 失败:费用单生下来就已付,实得 %', COALESCE(v_msg, '(记了)'); END IF;
    -- 默认值走的是挂账(一个走默认值就撞拒绝的参数是 WHT-1 记过的坑)
    v_res := record_expense(p_expense_date := d, p_account_code := v_acct, p_amount := 10,
                            p_currency := v_base, p_supplier_id := v_sup);
    IF (SELECT payment_status FROM expenses WHERE id = (v_res->>'expense_id')::uuid) <> 'unpaid' THEN
        RAISE EXCEPTION 'FIXTURE 210J2 失败:record_expense 不给状态时应当挂账'; END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_freight_document(d, v_sup, 10, v_base, 'weight', 'paid', NULL, NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'FREIGHT_PAID_AT_CREATION_REFUSED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210J3 失败:运费单生下来就已付,实得 %', COALESCE(v_msg, '(记了)'); END IF;
    v_denied := false; v_msg := NULL;
    BEGIN PERFORM record_export_freight_document(d, v_sup, 10, v_base, 'paid', NULL, NULL, NULL);
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM = 'FREIGHT_PAID_AT_CREATION_REFUSED'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210J4 失败:出口运费单生下来就已付,实得 %', COALESCE(v_msg, '(记了)'); END IF;
    -- 付款的分录不许从通用冲销口冲(那会让钱回来而付款行仍是 posted)
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM reverse_journal_entry((SELECT journal_entry_id FROM payments WHERE id = (
            SELECT result_payment_id FROM payment_requests WHERE id = v_req4)), d_pay, 'fx210');
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; v_denied := (SQLERRM LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|payment'); END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210J5 失败:付款的分录从通用冲销口冲掉了,实得 %', COALESCE(v_msg, '(冲了)'); END IF;
    rep := rep || jsonb_build_object('J_side_doors', true);

    -- ══════════ K · WOULD_STRAND 读 fixed_level ═════════════════════════════
    v_req7 := (submit_payment_request(v_sup, 400, v_base, NULL, NULL, d_pay, 'fx210 K',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp4, 'amount_doc', 400)), 'supplier')->>'request_id')::uuid;
    SELECT code INTO v_code FROM payment_requests WHERE id = v_req7;
    PERFORM set_config('request.jwt.claims', '', true);
    -- 门槛抬到 100 万:按金额它会落到一级 —— 而它不分档,所以这次编辑无害、必须放行
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_threshold_base = 1000000;
    -- 二级换成一个进不了财务的角色(给它一个真人,免得先撞"角色没人"那道闸)
    INSERT INTO user_roles (user_id, role_id) VALUES (u_none, r_l2bad);
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approval_level2_role_code = 'fx210-l2bad';
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'APPROVALS_POLICY_WOULD_STRAND|' || v_code || '|2|fx210-l2bad|decide_payment_request|%');
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210K 失败:二级换成批不动付款申请的角色,应当点名 % 拒 WOULD_STRAND(二级,不是一级),实得 %', v_code, COALESCE(v_msg, '(放行了)'); END IF;
    rep := rep || jsonb_build_object('K_fixed_level', true);

    -- ══════════ H · 审批关着 ════════════════════════════════════════════════
    v_denied := false; v_msg := NULL;
    BEGIN
        PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
        UPDATE finance_settings SET approvals_enabled = false;
    EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM;
        v_denied := (SQLERRM LIKE 'APPROVALS_CANNOT_DISABLE_WITH_PENDING|%' AND position(v_code IN SQLERRM) > 0);
    END;
    IF NOT v_denied THEN
        RAISE EXCEPTION 'FIXTURE 210H1 失败:有一张 submitted 的付款申请时关得掉审批(它会被搁死),实得 %', COALESCE(v_msg, '(关掉了)'); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    PERFORM withdraw_payment_request(v_req7);
    PERFORM withdraw_payment_request(v_req3) FROM payment_requests WHERE id = v_req3 AND status IN ('submitted','approved');
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_fin), true);
    v_res := submit_payment_request(v_sup, 400, v_base, NULL, NULL, d_pay, 'fx210 H',
        jsonb_build_array(jsonb_build_object('expense_id', v_exp4, 'amount_doc', 400)), 'supplier');
    IF v_res->>'status' <> 'approved' THEN
        RAISE EXCEPTION 'FIXTURE 210H2 失败:审批关着时申请应当生下来就是 approved,实得 %', v_res; END IF;
    SELECT count(*) INTO v_n FROM approval_log
     WHERE subject_id = (v_res->>'request_id')::uuid AND decision = 'auto_approved' AND level IS NULL;
    IF v_n <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 210H2 失败:应当落一行 auto_approved,实得 %', v_n; END IF;
    rep := rep || jsonb_build_object('H_switch_off', true);

    -- ══════════ L · RLS:两个身份,同一会话同一张表 ═══════════════════════════
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_none), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM payment_requests;
    SELECT count(*) INTO v_m FROM approval_log WHERE subject_type = 'payment_request';
    EXECUTE 'RESET ROLE';
    IF v_n <> 0 OR v_m <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 210L 失败:没有财务码的人读到了付款申请(% 行)或它的留痕(% 行)', v_n, v_m; END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', u_cfo), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM payment_requests WHERE created_by IN (u_fin, u_cfo2);
    SELECT count(*) INTO v_m FROM approval_log WHERE subject_type = 'payment_request';
    EXECUTE 'RESET ROLE';
    IF v_n < 7 OR v_m < 7 THEN
        RAISE EXCEPTION 'FIXTURE 210L 失败(对照):CFO 应当读得到付款申请与它的留痕,实得 % / %', v_n, v_m; END IF;
    rep := rep || jsonb_build_object('L_rls', true);

    RAISE NOTICE 'FIXTURE 210 全部通过 %', rep::text;
END $$;
ROLLBACK;

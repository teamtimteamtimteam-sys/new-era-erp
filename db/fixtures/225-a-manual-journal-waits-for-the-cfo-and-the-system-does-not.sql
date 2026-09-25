-- 225 APR-6:手工凭证与它的冲销要 CFO 批准才过账;系统生成的分录不经这里(2026-09-25)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(APR-6 grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   A  引擎登记:链的名册只有二级一行,门 = module.finance.view + data.view_prices;operations_now 有
--        journal_request_pending;post_journal_entry 与三支内层算子 authenticated 调不到 —— 一个持
--        module.finance.edit 的真实用户直调 post_journal_entry(任何 source_type)被拒
--   B  ★★ 提一张手工凭证(审批开着):申请 submitted;分录【一张都没多】;留痕 submitted、二级、
--        金额 = 试跑出的借方合计;在途清单那一支 blocks_disable、fixed_level = 2、主角 NULL;看板有它
--   C  提交就拒(引擎原话,一行不落):借贷不平 JOURNAL_UNBALANCED · 1100 JE_MANUAL_CONTROL_ACCOUNT ·
--        没有摘要 JE_MEMO_REQUIRED · 没有 finance.edit PERMISSION_DENIED · 锁定期 PERIOD_LOCKED
--   D  谁批不了:提单人 → SELF_APPROVAL_FORBIDDEN|raiser;一级 → APPROVAL_NOT_AUTHORISED|2;
--        驳回不给理由 → JOURNAL_REQUEST_REJECT_REASON_REQUIRED
--   E  ★★ 提单人之外没人批得动:CFO 那个人的另一个账号提 → JOURNAL_REQUEST_NO_OTHER_DECIDER,一行不落
--   F  ★★ CFO 批准:当场过账,日期 = 冻结的凭证日;source_type = 'manual'、source_id = 申请;
--        分录的 created_by 是 CFO,而职责分离读的是【提单人】(Q5)
--   G  贷银行科目:准许,申请上 credits_bank = true(Q7)
--   H  ★★ 期间锁永远赢(Q4):提单人锁不了那个月(SOD_POST_AND_CLOSE,认的是提单人);批准的 CFO 锁得了,
--        而且一张在等的申请挡不住锁;锁上之后批准按引擎原话拒 PERIOD_LOCKED,整笔回滚,申请仍在等
--   I  撤回:既不是提单人、又不持 finance.edit → PERMISSION_DENIED;另一个财务撤得了;撤回不写留痕
--   J  ★★ 冲销(Q6):冲一张手工凭证走申请;同一张第二张 → JOURNAL_REQUEST_OPEN;凭证页的门按名拒
--        JOURNAL_NEEDS_APPROVED_REQUEST;有自己路径的(expense)两边都按名拒 JE_REVERSE_USE_SOURCE_PATH;
--        冲一张碰 1100 的 sale 分录 → JE_MANUAL_CONTROL_ACCOUNT,冲一张重估 → 准许;CFO 批准那一刻才冲
--   K  驳回:要理由;驳回之后什么都没过账,留痕 rejected
--   S  ★★ N5:系统路径不经审批 —— 审批开着时 record_expense 照样当场过账(source_type 'expense')
--   L  审批关着:生下来 approved、当场过账、留痕 auto_approved
--   N  ★ 故障注入:摘掉 trg_journal_entries_direct_write,直连插分录头仍然被拒(拿掉写策略才是那道墙),
--        只是报的不再是那个名字 —— 名字是守卫给的
--
-- 自带数据(README 第 2 条);锁期自己设(README 第 4 条)。全部本位币、汇率 1。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '180s';

CREATE FUNCTION pg_temp.f225_try(p_sql text, p_auth boolean DEFAULT false) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    IF p_auth THEN EXECUTE 'SET LOCAL ROLE authenticated'; END IF;
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f225_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

-- 一张两行的凭证:借 p_dr / 贷 p_cr,各 p_amt(本位币)
CREATE FUNCTION pg_temp.f225_lines(p_dr text, p_cr text, p_amt numeric, p_amt_cr numeric DEFAULT NULL) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT jsonb_build_array(
        jsonb_build_object('account_code', p_dr, 'side', 'debit', 'currency', (SELECT code FROM currencies WHERE is_base),
                           'amount_ccy', p_amt, 'line_memo', 'f225 dr'),
        jsonb_build_object('account_code', p_cr, 'side', 'credit', 'currency', (SELECT code FROM currencies WHERE is_base),
                           'amount_ccy', COALESCE(p_amt_cr, p_amt), 'line_memo', 'f225 cr'))
$f$;

DO $$
DECLARE
    u_fin   uuid := gen_random_uuid();   -- 财务:module.finance.edit + 看得见 —— 提单人
    u_fin2  uuid := gen_random_uuid();   -- 另一个财务(撤回那一臂)
    u_cfo   uuid := gen_random_uuid();   -- 二级:CFO 的形状 —— 看得见、【没有】finance.edit;在册员工 e_cfo 的主账号
    u_cfo2  uuid := gen_random_uuid();   -- ★ e_cfo 的另一个账号,持财务角色 —— "同一个人提的"那一臂
    u_l1    uuid := gen_random_uuid();   -- 一级
    u_wh    uuid := gen_random_uuid();   -- 不持 finance.edit
    r_fin uuid; r_l1 uuid; r_l2 uuid; r_wh uuid;
    e_cfo uuid := gen_random_uuid();
    v_base text;
    q uuid; q2 uuid; qb uuid; qr uuid; v_res jsonb; v_msg text; v_n int; v_je0 int; v_je uuid; v_rev uuid;
    v_exp uuid; v_sale uuid; v_reval uuid; v_label text; v_sup uuid;
    d  date := CURRENT_DATE;
    d0 date := CURRENT_DATE - 3;   -- 冻结的凭证日:与批准那一天不同,才证得出"按冻结的日期"
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL;

    -- ══════════════ 布景 ══════════════
    INSERT INTO auth.users (id, email_confirmed_at) VALUES
        (u_fin, now()), (u_fin2, now()), (u_cfo, now()), (u_cfo2, now()), (u_l1, now()), (u_wh, now());
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx225-fin','f','f',true) RETURNING id INTO r_fin;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx225-l1','f','f',true)  RETURNING id INTO r_l1;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx225-l2','f','f',true)  RETURNING id INTO r_l2;
    INSERT INTO roles (code,name_en,name_zh,is_active) VALUES ('fx225-wh','f','f',true)  RETURNING id INTO r_wh;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.edit'), (r_fin, 'module.finance.view'), (r_fin, 'data.view_prices'),
        -- 一级:审批开得了(每条分档链的门它都持)—— 批不了手工凭证申请只能因为【级别】
        (r_l1, 'module.purchasing.view'), (r_l1, 'data.view_prices'), (r_l1, 'data.view_purchase_prices'),
        (r_l1, 'module.finance.view'), (r_l1, 'module.hr.view'), (r_l1, 'data.view_pay'), (r_l1, 'module.inbound.view'),
        -- 二级:CFO 的形状 —— 读得到、看得见,【没有】module.finance.edit
        (r_l2, 'module.purchasing.view'), (r_l2, 'data.view_prices'), (r_l2, 'data.view_purchase_prices'),
        (r_l2, 'module.finance.view'), (r_l2, 'module.hr.view'), (r_l2, 'data.view_pay'), (r_l2, 'module.inbound.view'),
        (r_l2, 'module.sales.view'),
        (r_wh, 'module.inventory.view'), (r_wh, 'module.finance.view');
    INSERT INTO user_roles (user_id, role_id) VALUES
        (u_fin, r_fin), (u_fin2, r_fin), (u_cfo, r_l2), (u_cfo2, r_fin), (u_l1, r_l1), (u_wh, r_wh);
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (e_cfo, 'FX225-CFO', 'FX225 CFO', 'full_time', 'office', d - 400, u_cfo);
    INSERT INTO employee_accounts (user_id, employee_id) VALUES (u_cfo2, e_cfo);

    -- 策略:一级 fx225-l1、二级 fx225-l2;审批打开
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx225-l1', approval_level2_role_code = 'fx225-l2',
                                approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;

    -- ══════════════ A · 引擎登记与关上的门 ══════════════
    IF (SELECT array_agg(level::int ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'journal_request')
         IS DISTINCT FROM ARRAY[2]
       OR (SELECT gate_permissions FROM approval_chain_gates() WHERE subject_type = 'journal_request')
         IS DISTINCT FROM ARRAY['module.finance.view', 'data.view_prices']::text[] THEN
        RAISE EXCEPTION 'FIXTURE 225A1 失败:journal_request 的名册应当只有二级一行,门 = finance.view + view_prices'; END IF;
    IF position('journal_request_pending' IN pg_get_viewdef('public.operations_now'::regclass)) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 225A2 失败:operations_now 没有 journal_request_pending 那一支'; END IF;
    SELECT string_agg(s, ', ') INTO v_msg FROM unnest(ARRAY[
        'public.post_journal_entry(date, text, text, uuid, jsonb)',
        'public.journal_request_submit_internal(text, date, text, jsonb, uuid)',
        'public.journal_request_post_internal(uuid)', 'public.journal_request_dry_run(uuid)']) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_msg IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 225A3 失败:authenticated 仍调得到 %', v_msg; END IF;
    -- 一个持 module.finance.edit 的真实用户,直调过账核心:'purchase'(ROLE1B4A-PURCHASE-JOURNAL-FORGEABLE)
    -- 与一笔贷银行的 'manual'(PAYREQ1-MANUAL-JOURNAL-CREDITS-BANK)都进不去
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f225_as(u_fin);
    v_msg := pg_temp.f225_try(format('SELECT post_journal_entry(%L::date, %L, %L, NULL, %L::jsonb)',
        d0, 'f225 forged purchase', 'purchase', pg_temp.f225_lines('1200', '2000', 5)), true);
    IF v_msg NOT LIKE 'permission denied for function post_journal_entry%' THEN
        RAISE EXCEPTION 'FIXTURE 225A4 失败:直调 post_journal_entry 伪造一张 purchase 分录应当被拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f225_try(format('SELECT post_journal_entry(%L::date, %L, %L, NULL, %L::jsonb)',
        d0, 'f225 bank out', 'manual', pg_temp.f225_lines('6200', '1000', 5)), true);
    IF v_msg NOT LIKE 'permission denied for function post_journal_entry%' THEN
        RAISE EXCEPTION 'FIXTURE 225A5 失败:直调 post_journal_entry 贷银行应当被拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f225_try(format('INSERT INTO journal_entries (code, entry_date, memo, source_type) VALUES (%L, %L::date, %L, %L)',
        'ZZF225-DIRECT', d0, 'f225 direct', 'manual'), true);
    IF v_msg <> 'JOURNAL_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 225A6 失败:直连插分录头应当按名拒 JOURNAL_THROUGH_FUNCTION_ONLY,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 225A7 失败:被拒的直调 / 直连不该留下分录'; END IF;

    -- ══════════════ B · 提一张手工凭证(审批开着)══════════════
    PERFORM pg_temp.f225_as(u_fin);
    v_res := submit_journal_request(d0, 'fixture 225 B', pg_temp.f225_lines('6200', '1300', 100));
    q := (v_res->>'request_id')::uuid; v_label := v_res->>'label';
    IF v_res->>'status' <> 'submitted' OR (SELECT status FROM journal_requests WHERE id = q) <> 'submitted'
       OR (SELECT count(*) FROM journal_entries) <> v_je0
       OR (SELECT amount_base FROM journal_requests WHERE id = q) <> 100
       OR (SELECT credits_bank FROM journal_requests WHERE id = q) THEN
        RAISE EXCEPTION 'FIXTURE 225B1 失败:提交只落一张 submitted 申请,分录一张不多,金额 = 借方合计 100,不贷银行;实得 %', v_res; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'journal_request' AND subject_id = q
                    AND decision = 'submitted' AND level = 2 AND amount_base = 100) THEN
        RAISE EXCEPTION 'FIXTURE 225B2 失败:留痕应当有 submitted、二级、金额 100'; END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_pending_documents() p WHERE p.subject_type = 'journal_request'
                    AND p.doc_id = q AND p.blocks_disable AND p.fixed_level = 2 AND p.subject_employee_id IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 225B3 失败:在途清单那一支应当 blocks_disable、fixed_level = 2、主角 NULL'; END IF;
    IF NOT EXISTS (SELECT 1 FROM operations_now WHERE item_type = 'journal_request_pending' AND item_id = q) THEN
        RAISE EXCEPTION 'FIXTURE 225B4 失败:看板上应当有这张在等的申请'; END IF;

    -- ══════════════ C · 提交就拒 ══════════════
    SELECT count(*) INTO v_n FROM journal_requests;
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d0, 'f225 C unbalanced', pg_temp.f225_lines('6200', '1300', 100, 90)));
    IF v_msg NOT LIKE 'JOURNAL_UNBALANCED|%' THEN
        RAISE EXCEPTION 'FIXTURE 225C1 失败:借贷不平应当在提交时就按引擎原话拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d0, 'f225 C control', pg_temp.f225_lines('1100', '4000', 10)));
    IF v_msg NOT LIKE 'JE_MANUAL_CONTROL_ACCOUNT|%|1100' THEN
        RAISE EXCEPTION 'FIXTURE 225C2 失败:手工凭证碰 1100 应当按名拒 JE_MANUAL_CONTROL_ACCOUNT,实得 %', v_msg; END IF;
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d0, 'f225 C control AP', pg_temp.f225_lines('6200', '2000', 10)));
    IF v_msg NOT LIKE 'JE_MANUAL_CONTROL_ACCOUNT|%|2000' THEN
        RAISE EXCEPTION 'FIXTURE 225C3 失败:手工凭证碰 2000 应当按名拒 JE_MANUAL_CONTROL_ACCOUNT,实得 %', v_msg; END IF;
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d0, '  ', pg_temp.f225_lines('6200', '1300', 10)));
    IF v_msg <> 'JE_MEMO_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 225C4 失败:没有摘要应当按名拒 JE_MEMO_REQUIRED,实得 %', v_msg; END IF;
    PERFORM pg_temp.f225_as(u_wh);
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d0, 'f225 C wh', pg_temp.f225_lines('6200', '1300', 10)));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN
        RAISE EXCEPTION 'FIXTURE 225C5 失败:不持 finance.edit 提不了,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = d0 + 1;
    PERFORM pg_temp.f225_as(u_fin);
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d0, 'f225 C locked', pg_temp.f225_lines('6200', '1300', 10)));
    IF v_msg NOT LIKE 'PERIOD_LOCKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 225C6 失败:锁定期的日期应当在提交时就按引擎原话拒,实得 %', v_msg; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;
    IF (SELECT count(*) FROM journal_requests) <> v_n OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 225C7 失败:被拒的提交不该留下申请或分录'; END IF;

    -- ══════════════ D · 谁批不了 ══════════════
    PERFORM pg_temp.f225_as(u_fin);
    v_msg := pg_temp.f225_try(format('SELECT decide_journal_request(%L, true)', q));
    IF v_msg <> 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'FIXTURE 225D1 失败:提单人批不了自己的申请,实得 %', v_msg; END IF;
    PERFORM pg_temp.f225_as(u_l1);
    v_msg := pg_temp.f225_try(format('SELECT decide_journal_request(%L, true)', q));
    IF v_msg NOT LIKE 'APPROVAL_NOT_AUTHORISED|2|%' THEN
        RAISE EXCEPTION 'FIXTURE 225D2 失败:一级批不了手工凭证申请(CFO 批每一张),实得 %', v_msg; END IF;
    PERFORM pg_temp.f225_as(u_cfo);
    v_msg := pg_temp.f225_try(format('SELECT decide_journal_request(%L, false, %L)', q, '  '));
    IF v_msg NOT LIKE 'JOURNAL_REQUEST_REJECT_REASON_REQUIRED|%' THEN
        RAISE EXCEPTION 'FIXTURE 225D3 失败:驳回要理由,实得 %', v_msg; END IF;

    -- ══════════════ E · 提单人之外没人批得动 ══════════════
    SELECT count(*) INTO v_n FROM journal_requests;
    PERFORM pg_temp.f225_as(u_cfo2);
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_request(%L::date, %L, %L::jsonb)',
        d0, 'f225 E', pg_temp.f225_lines('6200', '1300', 10)));
    IF v_msg NOT LIKE 'JOURNAL_REQUEST_NO_OTHER_DECIDER|manual journal #%' THEN
        RAISE EXCEPTION 'FIXTURE 225E1 失败:CFO 那个人的另一个账号提,应当按名拒,实得 %', v_msg; END IF;
    IF (SELECT count(*) FROM journal_requests) <> v_n THEN
        RAISE EXCEPTION 'FIXTURE 225E2 失败:被拒的提交不该留下一行'; END IF;

    -- ══════════════ F · CFO 批准:当场过账 ══════════════
    PERFORM pg_temp.f225_as(u_cfo);
    v_res := decide_journal_request(q, true, 'fixture 225 F ok');
    v_je := (v_res->>'entry_id')::uuid;
    IF v_res->>'status' <> 'approved' OR v_je IS NULL
       OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR (SELECT result_journal_entry_id FROM journal_requests WHERE id = q) IS DISTINCT FROM v_je THEN
        RAISE EXCEPTION 'FIXTURE 225F1 失败:批准应当当场过一张分录并挂在申请上,实得 %', v_res; END IF;
    IF (SELECT row(source_type, source_id, entry_date, created_by)::text FROM journal_entries WHERE id = v_je)
         IS DISTINCT FROM row('manual', q, d0, u_cfo)::text THEN
        RAISE EXCEPTION 'FIXTURE 225F2 失败:分录应当是 manual、source_id = 申请、日期 = 冻结的 %、created_by = 批准的 CFO;实得 %',
            d0, (SELECT row(source_type, source_id, entry_date, created_by)::text FROM journal_entries WHERE id = v_je); END IF;
    IF NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'journal_request' AND subject_id = q
                    AND decision = 'approved' AND level = 2 AND actor_user_id = u_cfo) THEN
        RAISE EXCEPTION 'FIXTURE 225F3 失败:留痕应当有 approved、二级、CFO'; END IF;
    IF NOT (u_fin = ANY (sod_manual_posters_in(d0, d0))) OR u_cfo = ANY (sod_manual_posters_in(d0, d0)) THEN
        RAISE EXCEPTION 'FIXTURE 225F4 失败:职责分离应当认提单人(u_fin),不认批准的 CFO;实得 %', sod_manual_posters_in(d0, d0); END IF;

    -- ══════════════ G · 贷银行:准许,标出来 ══════════════
    PERFORM pg_temp.f225_as(u_fin2);
    v_res := submit_journal_request(d0, 'fixture 225 G bank fee', pg_temp.f225_lines('6200', '1000', 12));
    qb := (v_res->>'request_id')::uuid;
    IF NOT (SELECT credits_bank FROM journal_requests WHERE id = qb) OR (v_res->>'credits_bank')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 225G1 失败:贷 1000 的申请应当标 credits_bank,实得 %', v_res; END IF;

    -- ══════════════ H · 期间锁永远赢 ══════════════
    -- H1 提单人锁不了他记过手工凭证的那个月(Q5:认提单人)
    PERFORM pg_temp.f225_as(u_fin);
    v_msg := pg_temp.f225_try(format('UPDATE finance_settings SET locked_before = %L::date', d0 + 1));
    IF v_msg NOT LIKE 'SOD_POST_AND_CLOSE|%' THEN
        RAISE EXCEPTION 'FIXTURE 225H1 失败:提单人锁那个月应当按名拒 SOD_POST_AND_CLOSE,实得 %', v_msg; END IF;
    -- H2 批准的 CFO 锁得了 —— 而且 G 那张申请还在等,锁不因为它被拒(Q4)
    PERFORM pg_temp.f225_as(u_cfo);
    v_msg := pg_temp.f225_try(format('UPDATE finance_settings SET locked_before = %L::date', d0 + 1));
    IF v_msg <> 'OK' OR (SELECT locked_before FROM finance_settings) IS DISTINCT FROM d0 + 1 THEN
        RAISE EXCEPTION 'FIXTURE 225H2 失败:CFO 不是记手工凭证的人,且一张在等的申请挡不住锁;实得 %', v_msg; END IF;
    -- H3 锁上之后批准:引擎原话拒,整笔回滚,申请仍在等
    SELECT count(*) INTO v_je0 FROM journal_entries;
    v_msg := pg_temp.f225_try(format('SELECT decide_journal_request(%L, true)', qb));
    IF v_msg NOT LIKE 'PERIOD_LOCKED|%' THEN
        RAISE EXCEPTION 'FIXTURE 225H3 失败:锁上之后批准应当按引擎原话拒 PERIOD_LOCKED,实得 %', v_msg; END IF;
    IF (SELECT status FROM journal_requests WHERE id = qb) <> 'submitted' OR (SELECT count(*) FROM journal_entries) <> v_je0 THEN
        RAISE EXCEPTION 'FIXTURE 225H4 失败:被拒的批准应当整笔回滚,申请仍在等'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE finance_settings SET locked_before = NULL;

    -- ══════════════ I · 撤回 ══════════════
    PERFORM pg_temp.f225_as(u_wh);
    v_msg := pg_temp.f225_try(format('SELECT withdraw_journal_request(%L)', qb));
    IF v_msg <> 'PERMISSION_DENIED|module.finance.edit' THEN
        RAISE EXCEPTION 'FIXTURE 225I1 失败:不是提单人、不持 finance.edit 撤不了,实得 %', v_msg; END IF;
    PERFORM pg_temp.f225_as(u_fin);
    v_res := withdraw_journal_request(qb, 'fixture 225 I');
    IF (SELECT status FROM journal_requests WHERE id = qb) <> 'withdrawn'
       OR (SELECT withdrawn_by FROM journal_requests WHERE id = qb) IS DISTINCT FROM u_fin THEN
        RAISE EXCEPTION 'FIXTURE 225I2 失败:另一个财务撤得了,撤回记在本行上'; END IF;
    IF EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'journal_request' AND subject_id = qb
                AND decision NOT IN ('submitted')) THEN
        RAISE EXCEPTION 'FIXTURE 225I3 失败:撤回不是一次决定,不写 approval_log'; END IF;

    -- ══════════════ J · 冲销 ══════════════
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f225_as(u_fin);
    v_res := submit_journal_reversal_request(v_je, d, 'fixture 225 J wrong account');
    qr := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' OR (SELECT count(*) FROM journal_entries) <> v_je0
       OR (SELECT status FROM journal_entries WHERE id = v_je) <> 'posted' THEN
        RAISE EXCEPTION 'FIXTURE 225J1 失败:冲销申请提交时什么都不冲,实得 %', v_res; END IF;
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_reversal_request(%L, %L::date, %L)', v_je, d, 'again'));
    IF v_msg NOT LIKE 'JOURNAL_REQUEST_OPEN|%' THEN
        RAISE EXCEPTION 'FIXTURE 225J2 失败:同一张分录第二张冲销申请应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f225_try(format('SELECT reverse_journal_entry(%L, %L::date, %L)', v_je, d, 'door'));
    IF v_msg NOT LIKE 'JOURNAL_NEEDS_APPROVED_REQUEST|%' THEN
        RAISE EXCEPTION 'FIXTURE 225J3 失败:凭证页的门对一张手工凭证应当按名拒 JOURNAL_NEEDS_APPROVED_REQUEST,实得 %', v_msg; END IF;
    -- 有自己路径的:一张 expense 分录(以属主身份造出来 —— 本臂的主语是判据,不是 record_expense)
    PERFORM set_config('request.jwt.claims', '', true);
    v_exp := (post_journal_entry(d0, 'f225 expense-shaped', 'expense', gen_random_uuid(),
                                 pg_temp.f225_lines('6200', '1300', 7))->>'entry_id')::uuid;
    v_sale := (post_journal_entry(d0, 'f225 sale-shaped', 'sale', gen_random_uuid(),
                                  pg_temp.f225_lines('1100', '4000', 9))->>'entry_id')::uuid;
    v_reval := (post_journal_entry(d0, 'f225 revaluation-shaped', 'revaluation', NULL,
                                   pg_temp.f225_lines('1100', '7110', 3))->>'entry_id')::uuid;
    PERFORM pg_temp.f225_as(u_fin);
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_reversal_request(%L, %L::date, %L)', v_exp, d, 'exp'));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|expense' THEN
        RAISE EXCEPTION 'FIXTURE 225J4 失败:expense 分录有自己的冲销路径,申请应当按名拒,实得 %', v_msg; END IF;
    v_msg := pg_temp.f225_try(format('SELECT reverse_journal_entry(%L, %L::date, %L)', v_exp, d, 'exp'));
    IF v_msg NOT LIKE 'JE_REVERSE_USE_SOURCE_PATH|%|expense' THEN
        RAISE EXCEPTION 'FIXTURE 225J5 失败:凭证页的门对 expense 分录应当指路 JE_REVERSE_USE_SOURCE_PATH,实得 %', v_msg; END IF;
    IF journal_entry_reversal_route(v_sale) <> 'request' OR journal_entry_reversal_route(v_exp) <> 'source_path' THEN
        RAISE EXCEPTION 'FIXTURE 225J6 失败:判据 —— sale 走申请,expense 走自己的路'; END IF;
    v_msg := pg_temp.f225_try(format('SELECT submit_journal_reversal_request(%L, %L::date, %L)', v_sale, d, 'sale'));
    IF v_msg NOT LIKE 'JE_MANUAL_CONTROL_ACCOUNT|%|1100' THEN
        RAISE EXCEPTION 'FIXTURE 225J7 失败:冲一张碰 1100 的 sale 分录应当按名拒(清单那一半不会动),实得 %', v_msg; END IF;
    v_res := submit_journal_reversal_request(v_reval, d, 'fixture 225 J revaluation');
    IF v_res->>'status' <> 'submitted' THEN
        RAISE EXCEPTION 'FIXTURE 225J8 失败:冲一张重估准许(核对按 source_type 点名重估),实得 %', v_res; END IF;
    PERFORM withdraw_journal_request((v_res->>'request_id')::uuid, 'f225 J done');
    -- CFO 批准那一刻才冲
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f225_as(u_cfo);
    v_res := decide_journal_request(qr, true);
    v_rev := (v_res->>'entry_id')::uuid;
    IF (SELECT status FROM journal_entries WHERE id = v_je) <> 'reversed'
       OR (SELECT reversed_by FROM journal_entries WHERE id = v_je) IS DISTINCT FROM v_rev
       OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR (SELECT row(source_type, entry_date)::text FROM journal_entries WHERE id = v_rev) IS DISTINCT FROM row('manual', d)::text THEN
        RAISE EXCEPTION 'FIXTURE 225J9 失败:批准应当冲掉原分录(冲销件 manual、日期 = 冻结的冲销日),实得 %', v_res; END IF;
    IF NOT (u_fin = ANY (sod_manual_posters_in(d, d))) OR u_cfo = ANY (sod_manual_posters_in(d, d)) THEN
        RAISE EXCEPTION 'FIXTURE 225J10 失败:冲销件的职责分离同样认提单人,实得 %', sod_manual_posters_in(d, d); END IF;

    -- ══════════════ K · 驳回 ══════════════
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f225_as(u_fin);
    q2 := (submit_journal_request(d0, 'fixture 225 K', pg_temp.f225_lines('6400', '1300', 40))->>'request_id')::uuid;
    PERFORM pg_temp.f225_as(u_cfo);
    PERFORM decide_journal_request(q2, false, 'wrong period');
    IF (SELECT row(status, decision_notes)::text FROM journal_requests WHERE id = q2) IS DISTINCT FROM row('rejected', 'wrong period')::text
       OR (SELECT count(*) FROM journal_entries) <> v_je0
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'journal_request' AND subject_id = q2
                       AND decision = 'rejected' AND level = 2) THEN
        RAISE EXCEPTION 'FIXTURE 225K 失败:驳回之后什么都不过账,留痕 rejected,理由在本行上'; END IF;

    -- ══════════════ S · N5:系统路径不经审批 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX225-SUP', 'fixture 225 supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f225_as(u_fin);
    v_res := record_expense(d0, '6200', 25, v_base, NULL, 'unpaid', NULL, v_sup);
    IF (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR NOT EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'expense' AND created_by = u_fin
                       AND entry_date = d0) THEN
        RAISE EXCEPTION 'FIXTURE 225S 失败:审批开着时 record_expense 应当照样当场过账(N5:系统路径不经审批),实得 %', v_res; END IF;

    -- ══════════════ L · 审批关着 ══════════════
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    SELECT count(*) INTO v_je0 FROM journal_entries;
    PERFORM pg_temp.f225_as(u_fin);
    v_res := submit_journal_request(d0, 'fixture 225 L', pg_temp.f225_lines('6200', '1300', 5));
    q := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'approved' OR (SELECT status FROM journal_requests WHERE id = q) <> 'approved'
       OR (SELECT count(*) FROM journal_entries) <> v_je0 + 1
       OR NOT EXISTS (SELECT 1 FROM approval_log WHERE subject_type = 'journal_request' AND subject_id = q
                       AND decision = 'auto_approved' AND level IS NULL) THEN
        RAISE EXCEPTION 'FIXTURE 225L 失败:审批关着时申请生下来就是 approved、当场过账、留痕 auto_approved,实得 %', v_res; END IF;

    -- ══════════════ N · 故障注入:摘掉直连守卫 ══════════════
    DROP TRIGGER trg_journal_entries_direct_write ON public.journal_entries;
    PERFORM pg_temp.f225_as(u_fin);
    v_msg := pg_temp.f225_try(format('INSERT INTO journal_entries (code, entry_date, memo, source_type) VALUES (%L, %L::date, %L, %L)',
        'ZZF225-NOGUARD', d0, 'f225 no guard', 'manual'), true);
    IF v_msg = 'OK' OR v_msg = 'JOURNAL_THROUGH_FUNCTION_ONLY' THEN
        RAISE EXCEPTION 'FIXTURE 225N 失败:摘掉守卫之后直连插入仍应被拒(没有写策略才是那道墙),而名字应当不在了;实得 %', v_msg; END IF;

    RAISE NOTICE 'FIXTURE 225 全部通过:A 登记与门 · B 提凭证 · C 提交就拒 · D 谁批不了 · E 没有别人 · F 批准过账 · G 贷银行 · H 锁永远赢 · I 撤回 · J 冲销 · K 驳回 · S 系统不经审批 · L 审批关着 · N 注入';
END;
$$;
ROLLBACK;

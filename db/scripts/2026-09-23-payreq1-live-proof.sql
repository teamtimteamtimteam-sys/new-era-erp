-- db/scripts/2026-09-23-payreq1-live-proof.sql
-- PAY-REQ-1 · Batch A 的线上证明 —— 拒绝、读回,以及一次【整支回滚】的对照生命周期。
-- 整支一笔事务,最后 ROLLBACK:线上一行都不留(申请、分录、付款、留痕)。
--
-- 为什么不在 db/fixtures/:它要的是【线上真账号】在【线上真数据】上被拒。fixture 210 在重建库上
-- 证同一批规矩的形状;这一支证的是"线上此刻,这几个人,真的被拒了 / 真的走得通"。
--
-- 身份:以 postgres 连接(rolbypassrls = t),每一格用 set_config('request.jwt.claims') 换成那个
-- 真账号,并在 SET LOCAL ROLE authenticated 之下跑 —— RLS、列权限、函数 EXECUTE 按那个人判。
-- 失败 = RAISE(退出码非零);成功 = 最后一行 NOTICE 'PAYREQ1 LIVE PROOF: n cells passed'。
--
-- 用到的线上数据(以 postgres 读基表实测,2026-09-23 21:00 CST):
--   EXP-2026-0001  5.00 SGD 未付、其中 1.30 仍开着(第一次跑撞上 ALLOC_EXCEEDS|EXP-2026-0001|5|1.30 —— 面额不是敞口),
--                  供应商 SUP-2026-0002(created_by 为空 → 不撞 SOD)。本支付 1.00。
--   EXP-2026-0007  100.00 SGD 未付,员工 Choo Er —— 已批准报销单 CLM-2026-0002 生成的(Q1 豁免)
--   PMT-2026-0009  posted 的出款(冲销拒绝那一格用它)
BEGIN;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no such account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $$;

-- 以 authenticated 跑一句 SQL,读回它的报错(没有报错 → NULL)
CREATE FUNCTION pg_temp.try_sql(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    BEGIN
        EXECUTE 'SET LOCAL ROLE authenticated';
        EXECUTE p_sql;
        EXECUTE 'RESET ROLE';
        RETURN NULL;
    EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        EXECUTE 'RESET ROLE';
        RETURN v_msg;
    END;
END $$;

-- 以 authenticated 跑一句返回 jsonb 的 SQL,把结果带回来(失败就 RAISE —— 对照臂必须通)
CREATE FUNCTION pg_temp.run_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

CREATE FUNCTION pg_temp.count_as(p_sql text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v bigint;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

DO $proof$
DECLARE
    c record;
    v_msg text;
    v_cells int := 0;
    v_exp1 uuid; v_sup uuid; v_exp7 uuid; v_emp_choo uuid; v_pmt9 uuid; v_je9 uuid; v_acct text;
    v_alloc1 text; v_alloc7 text;
    v_res jsonb; v_req uuid; v_je_before bigint; v_n bigint; v_m bigint;
BEGIN
    SELECT e.id, e.supplier_id INTO v_exp1, v_sup FROM expenses e WHERE e.code = 'EXP-2026-0001';
    SELECT e.id, e.employee_id INTO v_exp7, v_emp_choo FROM expenses e WHERE e.code = 'EXP-2026-0007';
    SELECT p.id, p.journal_entry_id INTO v_pmt9, v_je9 FROM payments p WHERE p.code = 'PMT-2026-0009' AND p.status = 'posted';
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    IF v_exp1 IS NULL OR v_exp7 IS NULL OR v_pmt9 IS NULL OR v_acct IS NULL THEN
        RAISE EXCEPTION 'PROOF_SETUP|the live rows this proof names are not all there';
    END IF;
    v_alloc1 := jsonb_build_array(jsonb_build_object('expense_id', v_exp1, 'amount_doc', 1))::text;
    v_alloc7 := jsonb_build_array(jsonb_build_object('expense_id', v_exp7, 'amount_doc', 100))::text;

    FOR c IN SELECT * FROM (VALUES
      ('chooer@evoltrya.test', 'finance 直接出款给供应商 → 要申请',
         format('SELECT record_payment(''out'', %L::uuid, 1, ''SGD'', NULL, NULL, DATE ''2026-09-23'', ''proof'', %L::jsonb)', v_sup, v_alloc1),
         'PAYMENT_REQUEST_REQUIRED|payment_out'),
      ('chooer@evoltrya.test', 'finance 直接冲销付款 → 要冲销申请',
         format('SELECT reverse_payment(%L::uuid, ''proof'')', v_pmt9), 'PAYMENT_REQUEST_REQUIRED|payment_reversal'),
      ('chooer@evoltrya.test', 'finance 记一张生下来就已付的费用 → 按名拒(Q2(c))',
         format('SELECT record_expense(DATE ''2026-09-23'', %L, 1, ''SGD'', NULL, ''paid'', ''1000'')', v_acct),
         'EXPENSE_PAID_AT_CREATION_REFUSED'),
      ('chooer@evoltrya.test', 'finance 从通用冲销口冲付款的分录 → 按名拒(Q2(b))',
         format('SELECT reverse_journal_entry(%L::uuid, DATE ''2026-09-23'', ''proof'')', v_je9), 'JE_REVERSE_USE_SOURCE_PATH|%|payment'),
      ('chooer@evoltrya.test', 'finance 直连往 payments 插一行 → RLS 拒(Q2(a))',
         format('INSERT INTO payments (code,direction,counterparty_type,supplier_id,amount_ccy,currency,fx_rate,amount_base,bank_account_code,payment_date) VALUES (''ZZ-PAYREQ1-P'',''out'',''supplier'',%L::uuid,1,''SGD'',1,1,''1000'',DATE ''2026-09-23'')', v_sup),
         '%row-level security%'),
      ('chooer@evoltrya.test', 'finance 直接调内层引擎 → 调不到',
         format('SELECT record_payment_internal(''out'', %L::uuid, 1, ''SGD'', NULL, NULL, DATE ''2026-09-23'', ''proof'', %L::jsonb, ''supplier'')', v_sup, v_alloc1),
         'permission denied for function record_payment_internal'),
      ('chooer@evoltrya.test', '【对照】finance 整笔付已批准报销 CLM-2026-0002 → 不要申请,直接记得了(Q1)',
         format('SELECT record_payment(''out'', %L::uuid, 100, ''SGD'', NULL, NULL, DATE ''2026-09-23'', ''proof'', %L::jsonb, ''employee'')', v_emp_choo, v_alloc7),
         NULL),
      ('tim@evoltrya.test', 'CFO 提不了付款申请(提单归财务)',
         format('SELECT submit_payment_request(%L::uuid, 1, ''SGD'', NULL, NULL, DATE ''2026-09-23'', ''proof'', %L::jsonb, ''supplier'')', v_sup, v_alloc1),
         'PERMISSION_DENIED|module.finance.edit'),
      ('tim@evoltrya.test', '【对照】CFO 问得了"这一笔要不要申请"(收款 → 不要)',
         'SELECT payment_request_required(''in'', NULL, gen_random_uuid(), 1, ''SGD'', ''[]''::jsonb)', NULL),
      ('admin@swm-os.test', 'admin 批不了付款申请(只做系统管理)',
         'SELECT decide_payment_request(gen_random_uuid(), true, NULL)', 'PERMISSION_DENIED|module.finance.view'),
      ('tim@evoltrya.test', '【对照】CFO 过得了批准那扇门(撞上的是申请不存在)',
         'SELECT decide_payment_request(gen_random_uuid(), true, NULL)', 'PAYMENT_REQUEST_NOT_FOUND|%')
    ) AS t(who, what, sql, expect) LOOP
        PERFORM pg_temp.as_user(c.who);
        v_msg := pg_temp.try_sql(c.sql);
        IF c.expect IS NULL THEN
            IF v_msg IS NOT NULL THEN
                RAISE EXCEPTION 'PAYREQ1_PROOF|% | %: expected success, got %', c.who, c.what, v_msg;
            END IF;
        ELSIF v_msg IS NULL OR v_msg NOT LIKE c.expect THEN
            RAISE EXCEPTION 'PAYREQ1_PROOF|% | %: expected %, got %', c.who, c.what, c.expect, COALESCE(v_msg, '(no error)');
        END IF;
        v_cells := v_cells + 1;
        RAISE NOTICE 'cell % | % | % → %', v_cells, c.who, c.what, COALESCE(v_msg, 'OK');
    END LOOP;

    -- ── 对照生命周期(整支回滚):提 → 自批被拒 → 未批不能付 → CFO 付不了 → CFO 批 → 财务付 ──
    SELECT count(*) INTO v_je_before FROM journal_entries;
    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_res := pg_temp.run_json(format('SELECT submit_payment_request(%L::uuid, 1, ''SGD'', NULL, NULL, DATE ''2026-09-23'', ''PAY-REQ-1 live proof'', %L::jsonb, ''supplier'')', v_sup, v_alloc1));
    v_req := (v_res->>'request_id')::uuid;
    IF v_res->>'status' <> 'submitted' THEN RAISE EXCEPTION 'PAYREQ1_PROOF|lifecycle submit: %', v_res; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 提申请 → %', v_cells, v_res;

    v_msg := pg_temp.try_sql(format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req));
    IF v_msg IS DISTINCT FROM 'SELF_APPROVAL_FORBIDDEN|raiser' THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|raiser approving own: %', COALESCE(v_msg, '(approved)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 批自己提的 → %', v_cells, v_msg;

    v_msg := pg_temp.try_sql(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req));
    IF v_msg NOT LIKE 'PAYMENT_REQUEST_NOT_APPROVED|%|submitted' THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|paying unapproved: %', COALESCE(v_msg, '(paid)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 付一张没批的 → %', v_cells, v_msg;

    PERFORM pg_temp.as_user('tim@evoltrya.test');
    v_msg := pg_temp.try_sql(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req));
    IF v_msg IS DISTINCT FROM 'PERMISSION_DENIED|module.finance.edit' THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|CFO paying: %', COALESCE(v_msg, '(paid)'); END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | tim@ | CFO 自己付 → %', v_cells, v_msg;

    v_res := pg_temp.run_json(format('SELECT decide_payment_request(%L::uuid, true, NULL)', v_req));
    IF v_res->>'status' <> 'approved' THEN RAISE EXCEPTION 'PAYREQ1_PROOF|CFO approve: %', v_res; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | tim@ | CFO 批准 → %', v_cells, v_res;
    -- v_je_before 是在【豁免对照】那一笔之后取的,所以提与批之后它应当【一张都不多】
    -- (第一次跑这里写成了 +1,把那一笔算了两遍 —— 读数 83 → 83 本身就是对的)
    IF (SELECT count(*) FROM journal_entries) <> v_je_before THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|submit/approve touched the ledger: % → %', v_je_before, (SELECT count(*) FROM journal_entries);
    END IF;

    PERFORM pg_temp.as_user('chooer@evoltrya.test');
    v_res := pg_temp.run_json(format('SELECT pay_payment_request(%L::uuid, DATE ''2026-09-23'', NULL)', v_req));
    IF (SELECT status FROM payment_requests WHERE id = v_req) <> 'paid' OR v_res->>'result_payment_id' IS NULL THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|pay: %', v_res; END IF;
    IF (SELECT count(*) FROM journal_entries) <> v_je_before + 1 THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|pay should post exactly one entry'; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | chooer@ | 付款 → % (%)', v_cells, v_res->>'code', v_res->>'journal_code';

    -- ── 读回:同一会话、同一张表、两个身份 ──
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    v_n := pg_temp.count_as('SELECT count(*) FROM payment_requests');
    v_m := pg_temp.count_as('SELECT count(*) FROM approval_log WHERE subject_type = ''payment_request''');
    PERFORM pg_temp.as_user('admin@swm-os.test');
    IF v_n <> 1 OR v_m <> 2 THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|tim@ should read 1 request and 2 log rows, got % / %', v_n, v_m; END IF;
    IF pg_temp.count_as('SELECT count(*) FROM payment_requests') <> 0
       OR pg_temp.count_as('SELECT count(*) FROM approval_log WHERE subject_type = ''payment_request''') <> 0 THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|admin@ should read nothing'; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | tim@ 读到 % 张申请 / % 行留痕;admin@ 读到 0 / 0', v_cells, v_n, v_m;

    -- ── CFO 的码:每一个 view 码 + 三个既有的决定码,一个写码都没有 ──
    PERFORM pg_temp.as_user('tim@evoltrya.test');
    SELECT count(*) INTO v_n FROM unnest(current_user_permissions()) x;  -- 它返回 text[],不是集合
    IF v_n <> 26 THEN RAISE EXCEPTION 'PAYREQ1_PROOF|tim@ should hold 26 codes, got %', v_n; END IF;
    IF EXISTS (SELECT 1 FROM unnest(current_user_permissions()) x(code) WHERE x.code LIKE '%.edit') THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|tim@ holds an edit code'; END IF;
    IF EXISTS (SELECT 1 FROM permissions p WHERE (p.code LIKE 'module.%.view' OR p.code LIKE 'data.view_%')
                AND p.code NOT IN (SELECT x.code FROM unnest(current_user_permissions()) x(code))) THEN
        RAISE EXCEPTION 'PAYREQ1_PROOF|tim@ misses a view code'; END IF;
    v_cells := v_cells + 1; RAISE NOTICE 'cell % | tim@ 持 26 码:每一个 module.*.view 与 data.view_*,零个 .edit', v_cells;

    RAISE NOTICE 'PAYREQ1 LIVE PROOF: % cells passed', v_cells;
END;
$proof$;

ROLLBACK;

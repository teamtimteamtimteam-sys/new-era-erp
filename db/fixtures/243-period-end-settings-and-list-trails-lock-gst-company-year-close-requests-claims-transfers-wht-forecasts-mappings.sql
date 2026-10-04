-- 243 AUDIT-TRAIL-1c-3:期末、设置与清单页上的审计记录 —— 锁期面板与 GST 面板(同一行设置,各看各的列)· 公司资料 · 年结 ·
--     人工分录申请 · 报销单与报销人自己(M8)· 行内转账 · 代扣税缴纳 · 现金预测与常设行 · 银行导入映射 · 折旧的分录(2026-10-04)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(AT-1c Step 0 §a 的登记表与 Q3 · Q4 · Q16 · Q17 · Q18 · Q20 · Q25 · Q29 · Q30,Tim 2026-10-03 全部照建议)
--   每一个主语一次字段编辑与一次关键事件(能改的照常改;不能改的 —— 年结、缴纳 —— 证它【按名拒】,那就是它没有"字段编辑"
--   这一样的原因;读者直接改落不了地的 —— 分录申请、报销单、预测 —— 证【落不了地】,再证一次系统写入在记录里是一次字段编辑)。
--   L   锁期(Q25 · Q29 · M6 · M7):设置页那一格挪锁(字段编辑)· 月结(关键事件:period_closes 一行 + 挪锁,同一个 op_key)·
--       反结(盖反结的戳 + 把锁挪回);同一行上的 GST 改动与没有面板的那一列(system_start_date,Q4)【一个都不】进锁期那一段;
--       记录开始之前的那一次关账(只有 period_closes 那一行)拼得回来;/settings/change-history 的 Record:关账那一行归财务设置
--   G   GST(Q25 · M6):改注册号(字段编辑)· 注册开关(关键事件);锁期的改动、月结、没有面板的那一列一个都不进 GST 那一段
--   O   公司资料(M5):改地址(字段编辑 —— 这一行只有编辑,没有别的事);不持 data.view_banking 的读者:银行账号那一列是遮着的
--   Y   年结:年结(关键事件,结转分录往上一跳够得到)· 反结(盖戳 + 冲销分录)· 年结不可改(按名拒 YEAR_CLOSE_IMMUTABLE)
--   J   人工分录申请(Q17):送去批 · CFO 批准(审批留痕 + 过账的分录同一笔)· 另一张撤回;读者直接改落不了地;
--       Record 一栏:申请与它的审批都归【申请自己】(一张还没批的申请没有分录 —— 它是根了)
--   E   报销单(Q20 · M8):提交(报销人自己)· 财务批准(审批留痕 + 记下的费用单同一笔)· 字段编辑(一次系统写入);
--       报销人在 /me 上读 my_expense_claim(没有任何码):读得到自己那一张,审批留痕与费用单是 Restricted(Q4);
--       另一个员工读这一张 → TRAIL_NOT_PERMITTED;一个没有码、又配了 'page' 的临时主语 → 对谁都 TRAIL_NOT_PERMITTED(M8 的边)
--   T   行内转账:转账(关键事件,分录往上)· 改备注(字段编辑)· 冲销(盖戳 + 冲销分录)
--   W   代扣税缴纳(Q30):缴纳(关键事件,分录往上)· 冲销(原分录翻 reversed、冲销分录往上一跳)· 缴纳不可改(按名拒)
--   F   现金预测(Q16):冻结 · 同一周再冻结一张(旧那一张被取代,同一个 op_key)· 读者直接改落不了地;
--       记录开始之前冻结的两张:各自一刻(两个 op_key),取代那一戳与新一张的冻结同一刻(同一个 op_key)—— 清单块据此并成一条
--   C   常设行:新增(关键事件)· 改金额(字段编辑)· 关掉
--   M   导入映射:新建 · 改名(字段编辑)· 删掉(盖戳);删掉的那一份照样读得到
--   D   折旧的分录(/finance/assets 的批次一块):一张 source_type = 'depreciation' 的分录带着它记到每一张资产卡上的那几行
--   X   批量汇率(Q16):一次录入的几条汇率,各自的记录里那一行带同一个 op_key
-- 【整支是一笔事务】措辞(每一句英文)不在这里证 —— 它在 scripts/check-trail-wording.mjs 的 ⑩ 期末、设置与清单页那一臂。
-- 自带数据(README 第 2 条):账号、角色、员工、资产、映射、预测全部本支自建;科目、币种是稳定的引导数据。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '240s';

CREATE FUNCTION pg_temp.f243_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f243_trail(p_user uuid, p_subject text, p_id text, p_n int DEFAULT 500) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb; v_back text := current_setting('request.jwt.claims', true);
BEGIN
    PERFORM pg_temp.f243_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, p_n) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', COALESCE(v_back, ''), true);
    RETURN jsonb_build_object('error', SQLERRM);
END;
$f$;

CREATE FUNCTION pg_temp.f243_ok(p_arm text, p_trail jsonb) RETURNS jsonb
LANGUAGE plpgsql AS $f$
BEGIN
    IF jsonb_typeof(p_trail) <> 'array' THEN RAISE EXCEPTION 'FIXTURE 243 %: the reader was refused: %', p_arm, p_trail; END IF;
    RETURN p_trail;
END;
$f$;

CREATE FUNCTION pg_temp.f243_has(p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT jsonb_typeof(p_trail) = 'array' AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                   WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND NOT (e ->> 'row_hidden')::boolean
                     AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
                     AND (p_new IS NULL OR e -> 'new' @> p_new))
$f$;

CREATE FUNCTION pg_temp.f243_need(p_arm text, p_trail jsonb, p_table text, p_op text, p_col text DEFAULT NULL, p_new jsonb DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF NOT pg_temp.f243_has(p_trail, p_table, p_op, p_col, p_new) THEN
        RAISE EXCEPTION 'FIXTURE 243 %: expected a % % row% in the trail, got %', p_arm, p_table, p_op,
            COALESCE(' changing ' || p_col, '') || COALESCE(' with ' || p_new::text, ''), p_trail;
    END IF;
END;
$f$;

-- 一行在一条记录里只出现一次
CREATE FUNCTION pg_temp.f243_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

-- 这一段里出现过的 finance_settings 的每一列(新旧两侧都算)—— M6 的判据:一块面板只该看见它自己那几列
CREATE FUNCTION pg_temp.f243_settings_cols(p_trail jsonb) RETURNS text[]
LANGUAGE sql AS $f$
    SELECT COALESCE(array_agg(DISTINCT c ORDER BY c), ARRAY[]::text[]) FROM (
        SELECT jsonb_array_elements_text(COALESCE(e -> 'changed_columns', '[]'::jsonb)) AS c
          FROM jsonb_array_elements(p_trail) e WHERE e ->> 'table_name' = 'finance_settings'
        UNION SELECT jsonb_object_keys(COALESCE(e -> 'new', '{}'::jsonb)) FROM jsonb_array_elements(p_trail) e WHERE e ->> 'table_name' = 'finance_settings'
        UNION SELECT jsonb_object_keys(COALESCE(e -> 'old', '{}'::jsonb)) FROM jsonb_array_elements(p_trail) e WHERE e ->> 'table_name' = 'finance_settings') x
$f$;

DO $$
DECLARE
    u_all  uuid := gen_random_uuid();   -- 持全部码:设置、建单、提申请
    u_cfo  uuid := gen_random_uuid();   -- 二级审批角色(人工分录申请的决定人)
    u_l1   uuid := gen_random_uuid();   -- 一级审批角色
    u_fin  uuid := gen_random_uuid();   -- 只有 module.finance.view + 价格码,不持 data.view_banking(O:银行那几列遮着)
    u_emp  uuid := gen_random_uuid();   -- 报销人:一个码都没有(E:M8)
    u_oth  uuid := gen_random_uuid();   -- 另一个员工:一个码都没有
    r_all uuid; r_l1 uuid; r_l2 uuid; r_fin uuid;
    e_emp uuid := gen_random_uuid(); e_oth uuid := gen_random_uuid();
    v_base text; v_acct text; v_began timestamptz := change_log_began_at(); t0 timestamptz;
    d date := CURRENT_DATE - 1;
    m_end date := (date_trunc('month', CURRENT_DATE) - interval '1 day')::date;
    v_res jsonb; v_j jsonb; v_j2 jsonb; v_x text; v_n int; v_k text; v_k2 text; v_rec jsonb; v_cols text[];
    pc uuid; yc uuid; yje uuid; yrj uuid; jr uuid; jr2 uuid; jje uuid; cl uuid; cexp uuid;
    bt uuid; btj uuid; wr uuid; wj uuid; f1 uuid; f2 uuid; p1 uuid; p2 uuid; cfl uuid; bp uuid;
    fa1 uuid; fa2 uuid; dj uuid; fxa uuid; fxb uuid; v_ws date;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    SELECT code INTO v_acct FROM accounts WHERE account_type = 'expense' AND is_active ORDER BY code LIMIT 1;
    IF v_base IS NULL OR v_acct IS NULL THEN RAISE EXCEPTION 'FIXTURE 243 布景失败:缺本位币或费用科目'; END IF;
    t0 := v_began - interval '10 days';

    -- ══════════════ 布景 ══════════════
    -- 以 postgres 改设置(没有会话:锁的两道守卫只问持会话的直连写)—— 这几次改动进了变更记录,是"System (automatic)"
    UPDATE finance_settings SET locked_before = NULL, system_start_date = NULL, gst_registered = false, gst_registration_no = NULL;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES
        (u_all, 'fx243-all@test.local', now()), (u_cfo, 'fx243-cfo@test.local', now()), (u_l1, 'fx243-l1@test.local', now()),
        (u_fin, 'fx243-fin@test.local', now()), (u_emp, 'fx243-emp@test.local', now()), (u_oth, 'fx243-oth@test.local', now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx243-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx243-l1', 'f', 'f', true) RETURNING id INTO r_l1;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx243-l2', 'f', 'f', true) RETURNING id INTO r_l2;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx243-fin', 'f', 'f', true) RETURNING id INTO r_fin;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, code FROM permissions, unnest(ARRAY[r_all, r_l1, r_l2]) r;
    INSERT INTO role_permissions (role_id, permission_code) VALUES
        (r_fin, 'module.finance.view'), (r_fin, 'data.view_prices'), (r_fin, 'data.view_purchase_prices');
    INSERT INTO user_roles (user_id, role_id) VALUES (u_all, r_all), (u_cfo, r_l2), (u_l1, r_l1), (u_fin, r_fin);
    INSERT INTO employees (id, code, legal_name, preferred_name, employment_type, work_category, hire_date, user_id) VALUES
        (e_emp, 'FX243-E1', 'FX243 Claimant', 'Claimant', 'full_time', 'office', DATE '2020-01-01', u_emp),
        (e_oth, 'FX243-E2', 'FX243 Other', 'Other', 'full_time', 'office', DATE '2020-01-01', u_oth);
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approval_level1_role_code = 'fx243-l1', approval_level2_role_code = 'fx243-l2', approval_threshold_base = 1000;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = true;
    -- 外币户的那一条腿要一个汇率(转账的入款户是 USD)
    INSERT INTO fx_rates (currency, rate_date, rate_type, rate_sgd_per_unit, source)
    SELECT 'USD', d, t, 1.35, 'fixture 243' FROM unnest(ARRAY['tt_buy', 'tt_sell', 'mid']) t
    ON CONFLICT DO NOTHING;

    -- ══════════════ G · GST(M6:只看注册开关与注册号)══════════════
    PERFORM pg_temp.f243_as(u_all);
    PERFORM set_finance_settings(jsonb_build_object('gst_registration_no', 'FX243-GST-1'));
    PERFORM set_finance_settings(jsonb_build_object('gst_registered', true));
    PERFORM set_finance_settings(jsonb_build_object('system_start_date', DATE '2024-01-01'));   -- Q4:没有面板的那一列
    PERFORM set_finance_settings(jsonb_build_object('gst_registered', false));                    -- 再关掉(下面的报销单不带税码)
    v_j := pg_temp.f243_ok('G', pg_temp.f243_trail(u_all, 'finance_gst', 'true'));
    PERFORM pg_temp.f243_need('G (field edit: the registration number)', v_j, 'finance_settings', 'UPDATE', 'gst_registration_no', '{"gst_registration_no": "FX243-GST-1"}');
    PERFORM pg_temp.f243_need('G (key event: registration switched on)', v_j, 'finance_settings', 'UPDATE', 'gst_registered', '{"gst_registered": true}');
    PERFORM pg_temp.f243_need('G (key event: registration switched off)', v_j, 'finance_settings', 'UPDATE', 'gst_registered', '{"gst_registered": false}');
    v_cols := pg_temp.f243_settings_cols(v_j);
    IF NOT v_cols <@ ARRAY['gst_registered', 'gst_registration_no'] THEN
        RAISE EXCEPTION 'FIXTURE 243 G (M6): the GST panel''s trail shows columns it does not own: %', v_cols; END IF;
    IF pg_temp.f243_has(v_j, 'period_closes', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 243 G: a month close reached the GST panel (M7 belongs to the lock)'; END IF;

    -- ══════════════ L · 锁期(M6 · M7 · Q25 · Q29)══════════════
    UPDATE finance_settings SET locked_before = DATE '2020-01-01' WHERE id;                   -- 设置页那一格(直连写)
    PERFORM close_period(m_end, 'fixture 243 close');
    SELECT id INTO pc FROM period_closes WHERE period_end = m_end AND reopened_at IS NULL;
    IF pc IS NULL THEN RAISE EXCEPTION 'FIXTURE 243 布景:月结没有落下'; END IF;
    PERFORM reopen_period(m_end, 'fixture 243 late invoice');
    -- 记录开始之前的那一次关账:只有 period_closes 那一行(绕开变更记录造出来 —— 与线上那一次同形)
    SET LOCAL session_replication_role = replica;
    INSERT INTO period_closes (period_end, closed_at, closed_by, entries_count, total_debits, total_credits, notes)
    VALUES (DATE '2019-12-31', t0, u_all, 3, 30, 30, 'fixture 243 before the log');
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f243_ok('L', pg_temp.f243_trail(u_all, 'finance_lock', 'true'));
    PERFORM pg_temp.f243_need('L (field edit: the lock moved on the settings page)', v_j, 'finance_settings', 'UPDATE', 'locked_before', '{"locked_before": "2020-01-01"}');
    PERFORM pg_temp.f243_need('L (key event: month closed — the close row)', v_j, 'period_closes', 'INSERT', NULL, jsonb_build_object('period_end', m_end));
    PERFORM pg_temp.f243_need('L (key event: month closed — the lock moved with it)', v_j, 'finance_settings', 'UPDATE', 'locked_before', jsonb_build_object('locked_before', m_end + 1));
    PERFORM pg_temp.f243_need('L (key event: month reopened — the stamp)', v_j, 'period_closes', 'UPDATE', 'reopened_at');
    PERFORM pg_temp.f243_need('L (Q9-style: the close before the log, from the close row)', v_j, 'period_closes', 'INSERT', NULL, '{"period_end": "2019-12-31"}');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'prelog')::boolean AND e ->> 'table_name' = 'period_closes') THEN
        RAISE EXCEPTION 'FIXTURE 243 L: the pre-log close should come back as a pre-log row: %', v_j; END IF;
    v_cols := pg_temp.f243_settings_cols(v_j);
    IF NOT v_cols <@ ARRAY['locked_before'] THEN
        RAISE EXCEPTION 'FIXTURE 243 L (M6 · Q4): the lock panel''s trail shows columns it does not own: %', v_cols; END IF;
    -- 月结那一笔:关账那一行与挪锁那一行是一次操作(同一个 op_key)
    IF (SELECT count(DISTINCT e ->> 'op_key') FROM jsonb_array_elements(v_j) e
         WHERE (e ->> 'table_name' = 'period_closes' AND e ->> 'op' = 'INSERT' AND e -> 'new' ->> 'period_end' = m_end::text)
            OR (e ->> 'table_name' = 'finance_settings' AND e -> 'new' ->> 'locked_before' = (m_end + 1)::text)) <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 243 L: the close row and its lock move should be one operation (one op_key): %', v_j; END IF;
    v_x := pg_temp.f243_twice(v_j);
    IF v_x IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 243 L: rows shown twice: %', v_x; END IF;
    -- 回头再读 GST 那一段:锁期的每一次改动、月结、system_start_date 一个都不在
    v_j2 := pg_temp.f243_ok('G (after L)', pg_temp.f243_trail(u_all, 'finance_gst', 'true'));
    v_cols := pg_temp.f243_settings_cols(v_j2);
    IF NOT v_cols <@ ARRAY['gst_registered', 'gst_registration_no'] OR pg_temp.f243_has(v_j2, 'period_closes', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 243 G (M6): after the lock moved, the GST panel shows %', v_cols; END IF;
    -- /settings/change-history 的 Record:关账那一行归财务设置(M7 的家)
    v_rec := trail_row_record('period_closes', jsonb_build_object('id', pc), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'finance_settings' OR v_rec ->> 'label' IS DISTINCT FROM 'Finance settings' THEN
        RAISE EXCEPTION 'FIXTURE 243 L: the summary page''s Record for a month close should be "Finance settings", got %', v_rec; END IF;

    -- ══════════════ O · 公司资料(M5;银行那几列按 data.view_banking 遮)══════════════
    PERFORM pg_temp.f243_as(u_all);
    UPDATE company_profile SET address_lines = 'fixture 243 street', bank_account_no = 'FX243-ACCT-0001' WHERE id;
    v_j := pg_temp.f243_ok('O', pg_temp.f243_trail(u_all, 'company_profile', 'true'));
    PERFORM pg_temp.f243_need('O (field edit: the address)', v_j, 'company_profile', 'UPDATE', 'address_lines', '{"address_lines": "fixture 243 street"}');
    PERFORM pg_temp.f243_need('O (the banking holder sees the account number)', v_j, 'company_profile', 'UPDATE', 'bank_account_no', '{"bank_account_no": "FX243-ACCT-0001"}');
    v_j := pg_temp.f243_ok('O (finance without data.view_banking)', pg_temp.f243_trail(u_fin, 'company_profile', 'true'));
    PERFORM pg_temp.f243_need('O (the address is still there)', v_j, 'company_profile', 'UPDATE', 'address_lines', '{"address_lines": "fixture 243 street"}');
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'company_profile' AND e::text LIKE '%FX243-ACCT-0001%') THEN
        RAISE EXCEPTION 'FIXTURE 243 O: a reader without data.view_banking saw the bank account number'; END IF;

    -- ══════════════ Y · 年结(年结不可改;结转与冲销的分录往上一跳)══════════════
    PERFORM pg_temp.f243_as(NULL);
    yje := (post_journal_entry(d, 'fixture 243 year close', 'year_close', NULL, jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 10),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 10))) ->> 'entry_id')::uuid;
    INSERT INTO year_closes (year_end, closing_journal_id, net_result, notes, closed_by)
    VALUES (DATE '2019-12-31', yje, 10, 'fixture 243', u_all) RETURNING id INTO yc;
    yrj := (post_journal_entry(d, 'fixture 243 year reopen', 'year_close', NULL, jsonb_build_array(
        jsonb_build_object('account_code', '1000', 'side', 'debit', 'currency', v_base, 'amount_ccy', 10),
        jsonb_build_object('account_code', v_acct, 'side', 'credit', 'currency', v_base, 'amount_ccy', 10))) ->> 'entry_id')::uuid;
    UPDATE year_closes SET reopened_at = now(), reopened_by = u_all, reopen_reason = 'fixture 243 audit', reversal_journal_id = yrj WHERE id = yc;
    BEGIN
        UPDATE year_closes SET notes = 'fixture 243 edited' WHERE id = yc;
        RAISE EXCEPTION 'FIXTURE 243 Y: a year close could be edited';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FIXTURE 243%' THEN RAISE; END IF;
        IF SQLERRM NOT LIKE 'YEAR_CLOSE_IMMUTABLE%' THEN RAISE EXCEPTION 'FIXTURE 243 Y: a year-close edit should be refused by name, got %', SQLERRM; END IF;
    END;
    v_j := pg_temp.f243_ok('Y', pg_temp.f243_trail(u_fin, 'year_close', yc::text));
    PERFORM pg_temp.f243_need('Y (key event: year closed)', v_j, 'year_closes', 'INSERT');
    PERFORM pg_temp.f243_need('Y (the closing journal, one hop up)', v_j, 'journal_entries', 'INSERT', NULL, jsonb_build_object('id', yje));
    PERFORM pg_temp.f243_need('Y (key event: reopened)', v_j, 'year_closes', 'UPDATE', 'reopened_at');
    PERFORM pg_temp.f243_need('Y (the reversal journal, one hop up)', v_j, 'journal_entries', 'INSERT', NULL, jsonb_build_object('id', yrj));

    -- ══════════════ J · 人工分录申请(Q17;它与它的审批的家是它自己)══════════════
    PERFORM pg_temp.f243_as(u_all);
    v_res := submit_journal_request(d, 'fixture 243 accrual', jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 120, 'line_memo', 'f243 dr'),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 120, 'line_memo', 'f243 cr')));
    jr := (v_res ->> 'request_id')::uuid;
    IF jr IS NULL THEN RAISE EXCEPTION 'FIXTURE 243 布景:人工分录申请没有提出来:%', v_res; END IF;
    PERFORM pg_temp.f243_as(u_cfo);
    PERFORM decide_journal_request(jr, true, 'fixture 243 ok');
    SELECT result_journal_entry_id INTO jje FROM journal_requests WHERE id = jr;
    IF jje IS NULL THEN RAISE EXCEPTION 'FIXTURE 243 布景:批准之后没有分录'; END IF;
    PERFORM pg_temp.f243_as(u_all);
    jr2 := (submit_journal_request(d, 'fixture 243 second', jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 5, 'line_memo', 'f243 dr'),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 5, 'line_memo', 'f243 cr'))) ->> 'request_id')::uuid;
    PERFORM withdraw_journal_request(jr2, 'fixture 243 wrong month');
    -- 读者直接改它落不了地(没有 UPDATE 的策略:零行,不报错)
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        UPDATE journal_requests SET memo = 'fixture 243 edited' WHERE id = jr2;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    EXECUTE 'RESET ROLE';
    IF (SELECT memo FROM journal_requests WHERE id = jr2) IS DISTINCT FROM 'fixture 243 second' THEN
        RAISE EXCEPTION 'FIXTURE 243 J: a reader''s direct edit of a journal request landed'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE journal_requests SET memo = 'fixture 243 second (corrected)' WHERE id = jr2;                -- 一次系统写入
    v_j := pg_temp.f243_ok('J', pg_temp.f243_trail(u_fin, 'journal_request', jr::text));
    PERFORM pg_temp.f243_need('J (key event: sent for approval)', v_j, 'journal_requests', 'INSERT');
    PERFORM pg_temp.f243_need('J (key event: approved)', v_j, 'journal_requests', 'UPDATE', 'status', '{"status": "approved"}');
    PERFORM pg_temp.f243_need('J (the approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "journal_request"}');
    PERFORM pg_temp.f243_need('J (the journal it posted, one hop up)', v_j, 'journal_entries', 'INSERT', NULL, jsonb_build_object('id', jje));
    v_j2 := pg_temp.f243_ok('J (withdrawn)', pg_temp.f243_trail(u_fin, 'journal_request', jr2::text));
    PERFORM pg_temp.f243_need('J (key event: withdrawn)', v_j2, 'journal_requests', 'UPDATE', 'status', '{"status": "withdrawn"}');
    PERFORM pg_temp.f243_need('J (field edit: a system write)', v_j2, 'journal_requests', 'UPDATE', 'memo');
    IF pg_temp.f243_has(v_j2, 'journal_entries', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 243 J: a withdrawn request reached a journal: %', v_j2; END IF;
    -- Record 一栏:申请与它的审批都归申请自己
    v_rec := trail_row_record('journal_requests', jsonb_build_object('id', jr), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'journal_requests' THEN RAISE EXCEPTION 'FIXTURE 243 J: the request''s own Record should be itself, got %', v_rec; END IF;
    v_rec := trail_row_record('approval_log', jsonb_build_object('id', (SELECT id FROM approval_log WHERE subject_type = 'journal_request' AND subject_id = jr LIMIT 1)), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'journal_requests' OR v_rec ->> 'id' IS DISTINCT FROM jr::text THEN
        RAISE EXCEPTION 'FIXTURE 243 J: the approval''s Record should be the request, got %', v_rec; END IF;

    -- ══════════════ E · 报销单(Q20)与报销人自己(M8)══════════════
    PERFORM pg_temp.f243_as(u_emp);
    cl := (submit_expense_claim(e_emp, d, 42.5, v_base, 'fixture 243 taxi', 'fixture 243 lost the slip') ->> 'claim_id')::uuid;
    IF cl IS NULL THEN RAISE EXCEPTION 'FIXTURE 243 布景:报销单没有提出来'; END IF;
    PERFORM pg_temp.f243_as(u_l1);    -- 一级审批角色(金额在门槛之下)
    PERFORM decide_expense_claim(cl, true, v_acct, NULL, NULL, 'fixture 243 fine');
    SELECT expense_id INTO cexp FROM expense_claims WHERE id = cl;
    IF cexp IS NULL THEN RAISE EXCEPTION 'FIXTURE 243 布景:批准之后没有费用单'; END IF;
    PERFORM set_config('request.jwt.claims', '', true);
    UPDATE expense_claims SET description = 'fixture 243 taxi to the port' WHERE id = cl;              -- 一次系统写入
    v_j := pg_temp.f243_ok('E (finance)', pg_temp.f243_trail(u_fin, 'expense_claim', cl::text));
    PERFORM pg_temp.f243_need('E (key event: submitted)', v_j, 'expense_claims', 'INSERT');
    PERFORM pg_temp.f243_need('E (key event: approved)', v_j, 'expense_claims', 'UPDATE', 'status', '{"status": "approved"}');
    PERFORM pg_temp.f243_need('E (the approval row)', v_j, 'approval_log', 'INSERT', NULL, '{"subject_type": "expense_claim"}');
    PERFORM pg_temp.f243_need('E (the expense it recorded, one hop up)', v_j, 'expenses', 'INSERT', NULL, jsonb_build_object('id', cexp));
    PERFORM pg_temp.f243_need('E (field edit: the description)', v_j, 'expense_claims', 'UPDATE', 'description');
    -- 报销人自己(M8:没有任何码 —— 根行的读规则是门)
    v_j := pg_temp.f243_ok('E (the claimant, M8)', pg_temp.f243_trail(u_emp, 'my_expense_claim', cl::text));
    PERFORM pg_temp.f243_need('E (M8: the claimant sees the claim)', v_j, 'expense_claims', 'UPDATE', 'status', '{"status": "approved"}');
    IF pg_temp.f243_has(v_j, 'approval_log', 'INSERT') OR pg_temp.f243_has(v_j, 'expenses', 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 243 E (Q4): the claimant saw the approval row or the expense: %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_j) e WHERE (e ->> 'row_hidden')::boolean) THEN
        RAISE EXCEPTION 'FIXTURE 243 E (Q4): the decision should read Restricted to the claimant (hidden rows), not disappear: %', v_j; END IF;
    v_j := pg_temp.f243_trail(u_oth, 'my_expense_claim', cl::text);
    IF jsonb_typeof(v_j) IS DISTINCT FROM 'object' OR COALESCE(v_j ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 243 E (M8): another employee should be refused someone else''s claim, got %', v_j; END IF;
    v_j := pg_temp.f243_trail(u_emp, 'expense_claim', cl::text);
    IF jsonb_typeof(v_j) IS DISTINCT FROM 'object' OR COALESCE(v_j ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 243 E: the finance page''s subject needs module.finance.view, the claimant got %', v_j; END IF;
    -- M8 的边:一个没有码、又配了 'page' 的主语对谁都不敞开(临时把登记表换成多一行的那一份;随事务消失)
    ALTER FUNCTION public.trail_subjects() RENAME TO trail_subjects_f243;
    CREATE FUNCTION public.trail_subjects()
     RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
     LANGUAGE sql IMMUTABLE SET search_path TO 'public', 'pg_temp'
    AS $fn$ SELECT * FROM public.trail_subjects_f243()
           UNION ALL SELECT 'fx243_open', ARRAY[]::text[], 'expense_claims', 'id', 'page', NULL::text[] $fn$;
    v_j := pg_temp.f243_trail(u_emp, 'fx243_open', cl::text);
    v_j2 := pg_temp.f243_trail(u_all, 'fx243_open', cl::text);
    DROP FUNCTION public.trail_subjects();
    ALTER FUNCTION public.trail_subjects_f243() RENAME TO trail_subjects;
    -- ★ 一个读回来的数组上 ->> 'error' 是 NULL,而 NULL NOT LIKE … 也是 NULL —— 判据必须先问"它是不是一次拒绝"
    --   (第一版没问,于是注入"'page' 不再被拒"那一格没有咬人 —— 2026-10-04 实测)
    IF jsonb_typeof(v_j) IS DISTINCT FROM 'object' OR jsonb_typeof(v_j2) IS DISTINCT FROM 'object'
       OR COALESCE(v_j ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED%' OR COALESCE(v_j2 ->> 'error', '') NOT LIKE 'TRAIL_NOT_PERMITTED%' THEN
        RAISE EXCEPTION 'FIXTURE 243 E (M8): a subject with no page code and root rule ''page'' must refuse everyone, got % / %', v_j, v_j2; END IF;

    -- ══════════════ T · 行内转账 ══════════════
    PERFORM pg_temp.f243_as(u_all);
    v_res := record_bank_transfer_internal(d, '1000', '1010', 135, 100, 'FX243-REF', 'fixture 243 transfer');
    bt := (v_res ->> 'transfer_id')::uuid; btj := (v_res ->> 'entry_id')::uuid;
    IF bt IS NULL THEN RAISE EXCEPTION 'FIXTURE 243 布景:转账没有记下:%', v_res; END IF;
    UPDATE bank_transfers SET notes = 'fixture 243 transfer (bank slip filed)' WHERE id = bt;
    PERFORM reverse_bank_transfer_internal(bt, d, 'fixture 243 wrong account');
    v_j := pg_temp.f243_ok('T', pg_temp.f243_trail(u_fin, 'bank_transfer', bt::text));
    PERFORM pg_temp.f243_need('T (key event: transfer made)', v_j, 'bank_transfers', 'INSERT');
    PERFORM pg_temp.f243_need('T (its journal, one hop up)', v_j, 'journal_entries', 'INSERT', NULL, jsonb_build_object('id', btj));
    PERFORM pg_temp.f243_need('T (field edit: the notes)', v_j, 'bank_transfers', 'UPDATE', 'notes');
    PERFORM pg_temp.f243_need('T (key event: reversed)', v_j, 'bank_transfers', 'UPDATE', 'reversed_at');
    PERFORM pg_temp.f243_need('T (the reversal journal, one hop up)', v_j, 'journal_entries', 'INSERT', NULL,
        jsonb_build_object('id', (SELECT reversal_entry_id FROM bank_transfers WHERE id = bt)));
    v_rec := trail_row_record('bank_transfers', jsonb_build_object('id', bt), NULL, NULL);
    -- ★ 名字为 NULL 时 NULL NOT LIKE … 是 NULL —— COALESCE 之后才判得出(第一版的注入没有咬人,2026-10-04 实测)
    IF v_rec ->> 'table' IS DISTINCT FROM 'bank_transfers' OR COALESCE(v_rec ->> 'label', '') NOT LIKE 'Transfer %' THEN
        RAISE EXCEPTION 'FIXTURE 243 T: the summary page''s Record for a transfer should be the transfer, named, got %', v_rec; END IF;

    -- ══════════════ W · 代扣税缴纳(Q30)══════════════
    PERFORM pg_temp.f243_as(NULL);
    wj := (post_journal_entry(d, 'fixture 243 WHT', 'wht_remittance', NULL, jsonb_build_array(
        jsonb_build_object('account_code', '2150', 'side', 'debit', 'currency', v_base, 'amount_ccy', 30),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 30))) ->> 'entry_id')::uuid;
    INSERT INTO wht_remittances (code, period_month, remitted_on, amount_base, filed_reference, journal_entry_id, created_by)
    VALUES ('FX243-WHT-1', date_trunc('month', d)::date, d, 30, 'FX243-IRAS', wj, u_all) RETURNING id INTO wr;
    BEGIN
        UPDATE wht_remittances SET filed_reference = 'FX243-EDITED' WHERE id = wr;
        RAISE EXCEPTION 'FIXTURE 243 W: a WHT remittance could be edited';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'FIXTURE 243%' THEN RAISE; END IF;
        IF SQLERRM NOT LIKE 'WHT_REMITTANCE_IMMUTABLE%' THEN RAISE EXCEPTION 'FIXTURE 243 W: a remittance edit should be refused by name, got %', SQLERRM; END IF;
    END;
    PERFORM pg_temp.f243_as(u_all);
    PERFORM reverse_wht_remittance_internal(wr, d, 'fixture 243 wrong month');
    v_j := pg_temp.f243_ok('W', pg_temp.f243_trail(u_fin, 'wht_remittance', wr::text));
    PERFORM pg_temp.f243_need('W (key event: remitted)', v_j, 'wht_remittances', 'INSERT');
    PERFORM pg_temp.f243_need('W (its journal, one hop up)', v_j, 'journal_entries', 'INSERT', NULL, jsonb_build_object('id', wj));
    PERFORM pg_temp.f243_need('W (Q30: its journal flipped to reversed)', v_j, 'journal_entries', 'UPDATE', 'reversed_by');
    PERFORM pg_temp.f243_need('W (Q30: the reversal journal, through the original''s reversed_by)', v_j, 'journal_entries', 'INSERT', NULL,
        jsonb_build_object('id', (SELECT reversed_by FROM journal_entries WHERE id = wj)));

    -- ══════════════ F · 现金预测(Q16)══════════════
    PERFORM pg_temp.f243_as(u_all);
    v_ws := (date_trunc('week', CURRENT_DATE))::date;
    f1 := (freeze_cash_forecast(v_ws, NULL) ->> 'id')::uuid;
    IF f1 IS NULL THEN SELECT id INTO f1 FROM cash_forecasts WHERE week_start = v_ws AND superseded_at IS NULL; END IF;
    PERFORM freeze_cash_forecast(v_ws, 'fixture 243 customer paid early');
    SELECT id INTO f2 FROM cash_forecasts WHERE week_start = v_ws AND superseded_at IS NULL;
    IF f1 IS NULL OR f2 IS NULL OR f1 = f2 THEN RAISE EXCEPTION 'FIXTURE 243 布景:两次冻结没有造出新旧两张'; END IF;
    v_j := pg_temp.f243_ok('F (the newer)', pg_temp.f243_trail(u_fin, 'cash_forecast', f2::text));
    v_j2 := pg_temp.f243_ok('F (the older)', pg_temp.f243_trail(u_fin, 'cash_forecast', f1::text));
    PERFORM pg_temp.f243_need('F (key event: frozen)', v_j, 'cash_forecasts', 'INSERT');
    PERFORM pg_temp.f243_need('F (key event: the older one replaced)', v_j2, 'cash_forecasts', 'UPDATE', 'superseded_at', jsonb_build_object('superseded_by', f2));
    -- Q16:取代旧的那一下与冻结新的那一张是同一次操作 —— 两条记录各自读回来,op_key 相同(清单块据此并成一条)
    IF (SELECT e ->> 'op_key' FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'cash_forecasts' AND e ->> 'op' = 'INSERT')
       IS DISTINCT FROM (SELECT e ->> 'op_key' FROM jsonb_array_elements(v_j2) e WHERE e ->> 'table_name' = 'cash_forecasts' AND e -> 'changed_columns' ? 'superseded_at') THEN
        RAISE EXCEPTION 'FIXTURE 243 F (Q16): the freeze and the supersede should carry one op_key'; END IF;
    -- 读者直接改它落不了地(没有 UPDATE 的策略)
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
        UPDATE cash_forecasts SET superseded_reason = 'fixture 243 edited' WHERE id = f1;
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    EXECUTE 'RESET ROLE';
    IF (SELECT superseded_reason FROM cash_forecasts WHERE id = f1) IS DISTINCT FROM 'fixture 243 customer paid early' THEN
        RAISE EXCEPTION 'FIXTURE 243 F: a reader''s direct edit of a frozen forecast landed'; END IF;
    -- 记录开始之前冻结的两张:各一刻(两个 op_key);取代那一戳与新那一张同一刻(同一个 op_key)
    SET LOCAL session_replication_role = replica;
    INSERT INTO cash_forecasts (code, week_start, horizon_weeks, opening, buckets, lines, undated, promises_memo, buffer, base_currency, frozen_at, frozen_by)
    VALUES ('FX243-FC-P1', DATE '2019-01-07', 13, '[]', '[]', '[]', '[]', '[]', '{}', v_base, t0, u_all) RETURNING id INTO p1;
    INSERT INTO cash_forecasts (code, week_start, horizon_weeks, opening, buckets, lines, undated, promises_memo, buffer, base_currency, frozen_at, frozen_by)
    VALUES ('FX243-FC-P2', DATE '2019-01-07', 13, '[]', '[]', '[]', '[]', '[]', '{}', v_base, t0 + interval '1 day', u_all) RETURNING id INTO p2;
    UPDATE cash_forecasts SET superseded_at = t0 + interval '1 day', superseded_by = p2, superseded_reason = 'fixture 243 before the log' WHERE id = p1;
    SET LOCAL session_replication_role = origin;
    v_j := pg_temp.f243_ok('F (pre-log newer)', pg_temp.f243_trail(u_fin, 'cash_forecast', p2::text));
    v_j2 := pg_temp.f243_ok('F (pre-log older)', pg_temp.f243_trail(u_fin, 'cash_forecast', p1::text));
    v_k := (SELECT e ->> 'op_key' FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'cash_forecasts' AND e ->> 'op' = 'INSERT');
    v_k2 := (SELECT e ->> 'op_key' FROM jsonb_array_elements(v_j2) e WHERE e ->> 'table_name' = 'cash_forecasts' AND e -> 'changed_columns' ? 'superseded_at');
    IF v_k IS NULL OR v_k IS DISTINCT FROM v_k2 THEN
        RAISE EXCEPTION 'FIXTURE 243 F (Q16, before the log): the supersede stamp and the newer freeze should share an op_key: % / %', v_k, v_k2; END IF;
    IF v_k = (SELECT e ->> 'op_key' FROM jsonb_array_elements(v_j2) e WHERE e ->> 'table_name' = 'cash_forecasts' AND e ->> 'op' = 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 243 F (Q16, before the log): two freezes a day apart should be two operations'; END IF;

    -- ══════════════ C · 常设行 ══════════════
    PERFORM pg_temp.f243_as(u_all);
    INSERT INTO cash_forecast_lines (label, direction, amount_ccy, currency, cadence, start_date, created_by)
    VALUES ('fixture 243 rent', 'out', 4200, v_base, 'monthly', d, u_all) RETURNING id INTO cfl;
    UPDATE cash_forecast_lines SET amount_ccy = 4400 WHERE id = cfl;
    UPDATE cash_forecast_lines SET is_active = false WHERE id = cfl;
    v_j := pg_temp.f243_ok('C', pg_temp.f243_trail(u_fin, 'cash_forecast_line', cfl::text));
    PERFORM pg_temp.f243_need('C (key event: added)', v_j, 'cash_forecast_lines', 'INSERT');
    PERFORM pg_temp.f243_need('C (field edit: the amount)', v_j, 'cash_forecast_lines', 'UPDATE', 'amount_ccy', '{"amount_ccy": 4400}');
    PERFORM pg_temp.f243_need('C (key event: switched off)', v_j, 'cash_forecast_lines', 'UPDATE', 'is_active', '{"is_active": false}');

    -- ══════════════ M · 导入映射(删掉的也读得到)══════════════
    INSERT INTO bank_import_profiles (bank_account_code, name, mapping) VALUES ('1000', 'fixture 243 DBS', '{"date": 0, "amount": 3}') RETURNING id INTO bp;
    UPDATE bank_import_profiles SET name = 'fixture 243 DBS business' WHERE id = bp;
    UPDATE bank_import_profiles SET deleted_at = now() WHERE id = bp;
    v_j := pg_temp.f243_ok('M (a deleted mapping is still readable)', pg_temp.f243_trail(u_fin, 'bank_import_profile', bp::text));
    PERFORM pg_temp.f243_need('M (key event: saved)', v_j, 'bank_import_profiles', 'INSERT');
    PERFORM pg_temp.f243_need('M (field edit: renamed)', v_j, 'bank_import_profiles', 'UPDATE', 'name', '{"name": "fixture 243 DBS business"}');
    PERFORM pg_temp.f243_need('M (key event: deleted)', v_j, 'bank_import_profiles', 'UPDATE', 'deleted_at');

    -- ══════════════ D · 折旧的分录(/finance/assets 的批次一块:journal_entry ord 7)══════════════
    PERFORM pg_temp.f243_as(u_all);
    fa1 := (create_fixed_asset('fixture 243 shredder', 60, d, 'equipment', '6700', 'fixture 243') ->> 'asset_id')::uuid;
    fa2 := (create_fixed_asset('fixture 243 forklift', 60, d, 'equipment', '6700', 'fixture 243') ->> 'asset_id')::uuid;
    PERFORM pg_temp.f243_as(NULL);
    dj := (post_journal_entry(d, 'fixture 243 depreciation', 'depreciation', NULL, jsonb_build_array(
        jsonb_build_object('account_code', v_acct, 'side', 'debit', 'currency', v_base, 'amount_ccy', 7),
        jsonb_build_object('account_code', '1000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 7))) ->> 'entry_id')::uuid;
    INSERT INTO fixed_asset_depreciation (asset_id, period_end, amount_base, journal_entry_id, created_by) VALUES
        (fa1, m_end, 4, dj, u_all), (fa2, m_end, 3, dj, u_all);
    v_j := pg_temp.f243_ok('D', pg_temp.f243_trail(u_fin, 'journal_entry', dj::text));
    PERFORM pg_temp.f243_need('D (the run''s journal)', v_j, 'journal_entries', 'INSERT');
    SELECT count(*) INTO v_n FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'fixed_asset_depreciation' AND e ->> 'op' = 'INSERT';
    IF v_n <> 2 THEN RAISE EXCEPTION 'FIXTURE 243 D: the depreciation journal should carry both assets'' charges, got %: %', v_n, v_j; END IF;
    -- 每一张资产卡自己的页上也有它那一行;家仍是资产
    v_rec := trail_row_record('fixed_asset_depreciation', jsonb_build_object('id', (SELECT id FROM fixed_asset_depreciation WHERE asset_id = fa1 AND journal_entry_id = dj)), NULL, NULL);
    IF v_rec ->> 'table' IS DISTINCT FROM 'fixed_assets' THEN RAISE EXCEPTION 'FIXTURE 243 D: a depreciation charge''s Record should stay the asset, got %', v_rec; END IF;

    -- ══════════════ X · 批量汇率(Q16)══════════════
    PERFORM pg_temp.f243_as(u_all);
    PERFORM record_fx_rates_bulk(jsonb_build_array(
        jsonb_build_object('currency', 'USD', 'rate_date', d - 1, 'rate_type', 'tt_buy', 'rate', 1.31, 'source', 'fixture 243'),
        jsonb_build_object('currency', 'USD', 'rate_date', d - 1, 'rate_type', 'tt_sell', 'rate', 1.33, 'source', 'fixture 243')));
    SELECT id INTO fxa FROM fx_rates WHERE currency = 'USD' AND rate_date = d - 1 AND rate_type = 'tt_buy' AND deleted_at IS NULL;
    SELECT id INTO fxb FROM fx_rates WHERE currency = 'USD' AND rate_date = d - 1 AND rate_type = 'tt_sell' AND deleted_at IS NULL;
    v_j := pg_temp.f243_ok('X (rate 1)', pg_temp.f243_trail(u_fin, 'fx_rate', fxa::text));
    v_j2 := pg_temp.f243_ok('X (rate 2)', pg_temp.f243_trail(u_fin, 'fx_rate', fxb::text));
    IF (SELECT e ->> 'op_key' FROM jsonb_array_elements(v_j) e WHERE e ->> 'table_name' = 'fx_rates' AND e ->> 'op' = 'INSERT')
       IS DISTINCT FROM (SELECT e ->> 'op_key' FROM jsonb_array_elements(v_j2) e WHERE e ->> 'table_name' = 'fx_rates' AND e ->> 'op' = 'INSERT') THEN
        RAISE EXCEPTION 'FIXTURE 243 X (Q16): one bulk save should carry one op_key across its rates'; END IF;

    RAISE NOTICE 'FIXTURE 243 全部通过:G(M6)· L(M6 · M7 · Q4 · Q25 · Q29)· O(M5)· Y · J(Q17)· E(Q20 · M8 · Q4)· T · W(Q30)· F(Q16)· C · M · D · X(Q16)';
END;
$$;

ROLLBACK;

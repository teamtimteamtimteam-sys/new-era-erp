-- 282 FIN-CHAIN-1:清单 ↔ 总账有未解释的差,这个月关不了;管理包的「未解释」读同一支勾稽(2026-10-20)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(Tim AP-RECON-1 Q11 的裁定 = FIN-CHAIN-1 Step 0 Q2;AP-RECON-1 Q8 的改基 = Step 0 Q3)
--   A  基线:一张挂账费用让应付清单与 2000 两边都非空(躲开"空集上恒真"),勾稽两边未解释 0
--   B  ★ C3:一笔手工分录直接打进 2000(−777 没有人解释)→ close_period 按名拒
--        CLOSE_LEDGER_LIST_UNEXPLAINED|ap|-777.00,封账日原样
--   C  ★ C2:同一时刻的管理包 —— 「未解释」改由 list_ledger_reconciliation 答:
--        control_unexplained_basis = list_ledger_reconciliation · control_unexplained = true · 点名 ap ·
--        control_unexplained_base = −777 · 包里带着 list_ledger_reconciliation 与它被读的时刻;旧的按机制分解原样还在
--   D  ★ 答不上来不是对得上:一个看不见进货价格(没有 data.view_purchase_prices)的关账人 → CLOSE_RECON_UNANSWERABLE|ap|PRICES_RESTRICTED;
--        管理包对这样的读者把 ap 记进 list_ledger_refused_sides
--   E  冲掉那一笔,两边回到 0 → 同一个月关得了(这条新闸不挡一个干净的月份)
--   F  ★ 故障注入:把 close_period 里那条判据换成恒假,B 臂那一句当场关得了 —— 证明 B 臂的拒绝来自这条判据
--
-- 自带数据(README 第 2 条);期间锁自己设(第 4 条);审批关着;GST 关着。
-- 【关账的人不是过账的人】SOD-1 控制①:在本期过过账的人不得关掉本期 —— 所以过账与关账各用一个人(fixture 143 的先例)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE FUNCTION pg_temp.f282_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f282_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true)
$f$;

DO $$
DECLARE
    v_user    uuid := gen_random_uuid();   -- 过账的人:全部码
    v_closer  uuid := gen_random_uuid();   -- 关账的人:全部码
    v_closer2 uuid := gen_random_uuid();   -- 关账的人:全部码,【除了】data.view_purchase_prices
    r_all uuid; r_noap uuid;
    v_sup uuid; v_base text;
    d_month date := DATE '2026-02-01';
    d_in    date := DATE '2026-02-10';
    d_end   date := DATE '2026-02-28';
    v_je jsonb; v_recon jsonb; v_pack jsonb; v_msg text; v_def text;
BEGIN
    INSERT INTO auth.users (id) VALUES (v_user), (v_closer), (v_closer2);
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx282-all', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx282-noap', 'f', 'f', true) RETURNING id INTO r_noap;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r_all, code FROM permissions;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_noap, code FROM permissions WHERE code <> 'data.view_purchase_prices';
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all), (v_closer, r_all), (v_closer2, r_noap);
    UPDATE finance_settings SET locked_before = NULL, gst_registered = false;
    PERFORM set_config('evoltrya.approvals_policy_ctx', '1', true);
    UPDATE finance_settings SET approvals_enabled = false;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZ-F282-S', 'fixture 282 supplier', 'SG', 'active', 'service_vendor') RETURNING id INTO v_sup;

    -- ══════════════ A · 基线 ══════════════
    PERFORM pg_temp.f282_as(v_user);
    PERFORM record_expense(p_expense_date := d_in, p_account_code := '6400', p_amount := 1000,
        p_currency := v_base, p_payment_status := 'unpaid', p_supplier_id := v_sup);
    v_recon := list_ledger_reconciliation();
    IF (SELECT (s->>'list_base')::numeric FROM jsonb_array_elements(v_recon->'sides') s WHERE s->>'side' = 'ap') = 0
       OR (SELECT (s->>'ledger_base')::numeric FROM jsonb_array_elements(v_recon->'sides') s WHERE s->>'side' = 'ap') = 0 THEN
        RAISE EXCEPTION 'FIXTURE 282A 失败(空转):应付清单或 2000 是零 —— 这条勾稽在空集上恒真,证明不了任何事'; END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon->'sides') s WHERE (s->>'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'FIXTURE 282A 失败:注入之前两边未解释就不是 0,基线不干净:%', v_recon; END IF;

    -- ══════════════ B · 一笔没人解释的手工分录 → 关不了 ══════════════
    v_je := post_journal_entry(d_in, 'fixture 282 manual into the control account', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '6900', 'side', 'debit',  'currency', v_base, 'amount_ccy', 777),
            jsonb_build_object('account_code', '2000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 777)));
    PERFORM pg_temp.f282_as(v_closer);
    v_msg := pg_temp.f282_try(format('SELECT close_period(%L)', d_end));
    IF v_msg <> 'CLOSE_LEDGER_LIST_UNEXPLAINED|ap|-777.00' THEN
        RAISE EXCEPTION 'FIXTURE 282B 失败:带着 −777 的未解释关账应当按名拒,实得 %', v_msg; END IF;
    IF (SELECT locked_before FROM finance_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 282B2 失败:被拒的关账不该动封账日'; END IF;

    -- ══════════════ C · 管理包读同一支勾稽 ══════════════
    PERFORM pg_temp.f282_as(v_user);
    v_pack := management_pack_data(d_month);
    IF v_pack->'caveats'->>'control_unexplained_basis' IS DISTINCT FROM 'list_ledger_reconciliation'
       OR (v_pack->'caveats'->>'control_unexplained')::boolean IS NOT TRUE
       OR NOT (v_pack->'caveats'->'control_unexplained_sides') ? 'ap'
       OR (v_pack->'caveats'->>'control_unexplained_base')::numeric <> -777
       OR v_pack->'caveats'->'list_ledger_read_at' IS NULL OR jsonb_typeof(v_pack->'caveats'->'list_ledger_read_at') = 'null'
       OR jsonb_array_length(v_pack->'caveats'->'list_ledger_refused_sides') <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 282C1 失败:包的「未解释」应当来自 list_ledger_reconciliation(−777,点名 ap,带读取时刻),实得 %', v_pack->'caveats'; END IF;
    IF v_pack->'list_ledger_reconciliation'->'sides' IS NULL
       OR (SELECT (s->>'unexplained_base')::numeric FROM jsonb_array_elements(v_pack->'list_ledger_reconciliation'->'sides') s
            WHERE s->>'side' = 'ap') <> -777
       OR v_pack->'control_reconciliation'->'sides' IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 282C2 失败:包里应当带着新勾稽(ap −777),旧的按机制分解原样还在'; END IF;

    -- ══════════════ D · 答不上来不是对得上 ══════════════
    PERFORM pg_temp.f282_as(v_closer2);
    v_msg := pg_temp.f282_try(format('SELECT close_period(%L)', d_end));
    IF v_msg <> 'CLOSE_RECON_UNANSWERABLE|ap|PRICES_RESTRICTED' THEN
        RAISE EXCEPTION 'FIXTURE 282D1 失败:看不见进货价格的关账人应当按名拒(答不上来不是 0),实得 %', v_msg; END IF;
    v_pack := management_pack_data(d_month);
    IF NOT (v_pack->'caveats'->'list_ledger_refused_sides') ? 'ap' THEN
        RAISE EXCEPTION 'FIXTURE 282D2 失败:管理包应当把答不上来的 ap 点名,实得 %', v_pack->'caveats'; END IF;

    -- ══════════════ E · 冲掉它,同一个月关得了 ══════════════
    PERFORM reverse_journal_entry_internal((v_je->>'entry_id')::uuid, d_in, 'fixture 282 undo');
    PERFORM pg_temp.f282_as(v_closer);
    v_msg := pg_temp.f282_try(format('SELECT close_period(%L)', d_end));
    IF v_msg <> 'OK' OR (SELECT locked_before FROM finance_settings) <> d_end + 1 THEN
        RAISE EXCEPTION 'FIXTURE 282E 失败:两边回到 0 之后这个月应当关得了,实得 %', v_msg; END IF;

    -- ══════════════ F · 故障注入:拿掉那条判据 ══════════════
    -- 下一个月(三月):再打一笔没人解释的进 2000,然后拿掉判据去关三月 —— 不去重开二月(重开有它自己的门)。
    PERFORM pg_temp.f282_as(v_user);
    PERFORM post_journal_entry(DATE '2026-03-10', 'fixture 282 manual again', 'manual', NULL,
        jsonb_build_array(
            jsonb_build_object('account_code', '6900', 'side', 'debit',  'currency', v_base, 'amount_ccy', 5),
            jsonb_build_object('account_code', '2000', 'side', 'credit', 'currency', v_base, 'amount_ccy', 5)));
    v_def := pg_get_functiondef('public.close_period(date, text)'::regprocedure);
    IF position('IF (v_side ->> ''unexplained_base'')::numeric <> 0 THEN' IN v_def) = 0 THEN
        RAISE EXCEPTION 'FIXTURE 282F0 前提失败:函数体里找不到那条判据'; END IF;
    EXECUTE replace(v_def, 'IF (v_side ->> ''unexplained_base'')::numeric <> 0 THEN', 'IF false THEN');
    PERFORM pg_temp.f282_as(v_closer);
    v_msg := pg_temp.f282_try(format('SELECT close_period(%L)', DATE '2026-03-31'));
    IF v_msg <> 'OK' THEN
        RAISE EXCEPTION 'FIXTURE 282F 失败:拿掉判据之后带差额也应当关得了 —— 否则 B 臂是被别的东西拒的,实得 %', v_msg; END IF;

    RAISE NOTICE 'FIXTURE 282 全部通过:A 基线 · B 未解释挡关账 · C 管理包读同一支 · D 答不上来按名拒 · E 干净的月关得了 · F 注入';
END;
$$;
ROLLBACK;

-- 283 FIN-CHAIN-1:运费单的冲销日由人选 —— 必填、不早于原分录、不默认(APR4-FREIGHT-REVERSAL-DATED-TODAY,2026-10-20)
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【本支钉住的东西】(FIN-CHAIN-1 Step 0 Q7,Tim 2026-10-20)
--   此前 reverse_freight_document 先是盖 CURRENT_DATE,AP-RECON-1 之后盖 reversal_date_for(今天与原分录日里较晚的那个)——
--   两种都没有人选得了。现在第三个参数 p_reversal_date:
--   A  不给 → REVERSAL_DATE_REQUIRED,单据仍是 posted(不默认成任何一天)
--   B  早于原分录 → REVERSAL_BEFORE_ORIGINAL|…(冲销不许早于原件)
--   C  落在已关账的期间 → PERIOD_LOCKED(锁永远赢 —— 选了原单据那个已关的月也一样)
--   D  ★ 选一个【既不是今天、也不是原单据日】的日子 → 冲销分录就落在那一天,单据 reversed、冲销件挂上
--        (旧实现会把它落在今天:这一句就是会咬人的那一句 —— 今天 ≠ 那一天)
--   E  目录:函数体里不再有 reversal_date_for,也不递 CURRENT_DATE
--
-- 自带数据(README 第 2 条);期间锁自己设(第 4 条)。全部本位币。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE FUNCTION pg_temp.f283_try(p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    EXECUTE p_sql;
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    RETURN SQLERRM;
END;
$f$;

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    r_all  uuid;
    v_ccy text; v_fwd uuid; v_sup uuid; v_mat uuid; v_b uuid; v_fd uuid; v_code text; v_je_code text;
    v_res jsonb; v_msg text; v_def text; v_rev_date date;
    d_doc  date := DATE '2025-05-05';
    d_pick date := DATE '2025-06-10';
BEGIN
    SELECT code INTO v_ccy FROM currencies WHERE is_base;
    UPDATE finance_settings SET locked_before = NULL;
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx283', 'f', 'f', true) RETURNING id INTO r_all;
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r_all, unnest(ARRAY['module.finance.edit', 'module.finance.view', 'module.inbound.view', 'module.inbound.edit', 'data.view_prices']);
    INSERT INTO user_roles (user_id, role_id) VALUES (v_user, r_all);
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', v_user), true);

    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX283-MAT', 'fixture 283 material supplier', 'SG', 'active', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type)
    VALUES ('ZZFIX283-FWD', 'fixture 283 forwarder', 'SG', 'active', 'forwarder') RETURNING id INTO v_fwd;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('ZZFIX283-M', 'fixture 283 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty,
        arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZFIX283-IB1', v_mat, v_sup, 100, 100, DATE '2025-05-01', 10, 'other', 'fixture 283 自带数据') RETURNING id INTO v_b;
    v_res := record_freight_document(d_doc, v_fwd, 500, v_ccy, 'weight',
        'unpaid', NULL, jsonb_build_array(jsonb_build_object('inbound_batch_id', v_b)), 'fixture 283', NULL);
    v_fd := (v_res->>'freight_document_id')::uuid;
    v_code := v_res->>'code';
    SELECT je.code INTO v_je_code FROM freight_documents f JOIN journal_entries je ON je.id = f.journal_entry_id WHERE f.id = v_fd;

    -- A · 不给日期
    v_msg := pg_temp.f283_try(format('SELECT reverse_freight_document(%L, %L)', v_fd, 'billed twice'));
    IF v_msg <> 'REVERSAL_DATE_REQUIRED' THEN
        RAISE EXCEPTION 'FIXTURE 283A 失败:不给冲销日应当按名拒(不默认成任何一天),实得 %', v_msg; END IF;
    IF (SELECT status FROM freight_documents WHERE id = v_fd) <> 'posted' THEN
        RAISE EXCEPTION 'FIXTURE 283A2 失败:被拒的冲销不该动单据'; END IF;

    -- B · 早于原分录
    v_msg := pg_temp.f283_try(format('SELECT reverse_freight_document(%L, %L, %L)', v_fd, 'billed twice', d_doc - 4));
    IF v_msg NOT LIKE 'REVERSAL_BEFORE_ORIGINAL|' || v_je_code || '|%' THEN
        RAISE EXCEPTION 'FIXTURE 283B 失败:早于原分录的冲销日应当按名拒,实得 %', v_msg; END IF;

    -- C · 落在已关账的期间(选原单据那个已关的月)
    UPDATE finance_settings SET locked_before = DATE '2025-06-01';
    v_msg := pg_temp.f283_try(format('SELECT reverse_freight_document(%L, %L, %L)', v_fd, 'billed twice', DATE '2025-05-20'));
    IF v_msg NOT LIKE 'PERIOD_LOCKED%' THEN
        RAISE EXCEPTION 'FIXTURE 283C 失败:落在已关账期间的冲销日应当按名拒 PERIOD_LOCKED,实得 %', v_msg; END IF;
    IF (SELECT status FROM freight_documents WHERE id = v_fd) <> 'posted' THEN
        RAISE EXCEPTION 'FIXTURE 283C2 失败:被拒的冲销不该动单据'; END IF;

    -- D · 人选的那一天(既不是今天,也不是原单据日)
    IF d_pick = CURRENT_DATE OR d_pick = d_doc THEN
        RAISE EXCEPTION 'FIXTURE 283D0 前提失败:选的那一天必须与今天、与原单据日都不同,这一臂才分得开新旧实现'; END IF;
    v_res := reverse_freight_document(v_fd, 'billed twice', d_pick);
    SELECT je.entry_date INTO v_rev_date FROM freight_documents f JOIN journal_entries je ON je.id = f.reversal_entry_id WHERE f.id = v_fd;
    IF (SELECT status FROM freight_documents WHERE id = v_fd) <> 'reversed' OR v_rev_date IS DISTINCT FROM d_pick THEN
        RAISE EXCEPTION 'FIXTURE 283D 失败:冲销分录应当落在人选的 %,实得 %(状态 %)', d_pick, v_rev_date,
            (SELECT status FROM freight_documents WHERE id = v_fd); END IF;

    -- E · 目录
    v_def := pg_get_functiondef('public.reverse_freight_document(uuid, text, date)'::regprocedure);
    IF v_def ~ 'reverse_journal_entry_internal\([^,]*,\s*(CURRENT_DATE|reversal_date_for)' THEN
        RAISE EXCEPTION 'FIXTURE 283E 失败:运费冲销仍然由系统代填冲销日'; END IF;
    IF to_regprocedure('public.reverse_freight_document(uuid, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 283E2 失败:两参的旧签名还在 —— 那是一个重载,不是替换'; END IF;

    RAISE NOTICE 'FIXTURE 283 全部通过:A 必填 · B 不早于原件 · C 锁赢 · D 落在人选的那一天 · E 目录';
END;
$$;
ROLLBACK;

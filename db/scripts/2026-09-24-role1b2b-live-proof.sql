-- db/scripts/2026-09-24-role1b2b-live-proof.sql
-- ROLE-1 · Batch 2b 的线上证明 —— 拒绝、读回,以及几次【整支回滚】的对照。
-- 整支一笔事务,最后 ROLLBACK:线上一行都不留(合同、条款、行情、阈值、公式、化验、分录)。
--
-- 为什么不在 db/fixtures/:它要的是【线上真账号】在【线上真数据】上被拒 / 走得通。
-- fixture 217 在重建库上证同一批规矩的形状;这一支证的是"线上此刻,这几个人,真的是这样"。
--
-- 身份:以 postgres 连接(rolbypassrls = t),每一格用 set_config('request.jwt.claims') 换成那个
-- 真账号,并在 SET LOCAL ROLE authenticated 之下跑 —— RLS、列权限、函数 EXECUTE 按那个人判。
-- 失败 = RAISE(退出码非零);成功 = 最后一行 NOTICE 'ROLE1B2B LIVE PROOF: n cells passed'。
--
-- 用到的线上数据(以 postgres 读基表,2026-09-24 20:4x CST):
--   SUP-2026-0003(approved)—— 合同挂它
--   ASY-2026-0004 · IN-2026-0181:已应用、链上最新、有承诺副本 → phua@ 撤销再应用(回滚);重算价要今天的
--   USD tt_sell 牌价,线上没有 —— 于是它在汇率那一步按名停下,本支不编汇率
--   journal_entries 编号是 MAX+1(post_journal_entry),回滚不留空号
BEGIN;

CREATE FUNCTION pg_temp.as_user(p_email text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
    SELECT id INTO v FROM auth.users WHERE email = p_email;
    IF v IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|no such account %', p_email; END IF;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v, 'role', 'authenticated')::text, true);
    RETURN v;
END $$;

-- 以 authenticated 跑一句 SQL,读回它的报错(没有报错 → NULL)。成功的那一句【留在事务里】。
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

CREATE FUNCTION pg_temp.run_json(p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN v;
END $$;

-- 一格:谁、说什么、跑哪句、期望(NULL = 必须通过;否则 LIKE 模式)
CREATE FUNCTION pg_temp.cell(p_who text, p_label text, p_sql text, p_expect text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_msg text;
BEGIN
    PERFORM pg_temp.as_user(p_who);
    v_msg := pg_temp.try_sql(p_sql);
    IF p_expect IS NULL THEN
        IF v_msg IS NOT NULL THEN
            RAISE EXCEPTION 'PROOF_FAILED|% | % | expected success, got %', p_who, p_label, v_msg;
        END IF;
        RAISE NOTICE 'CELL ok  | % | % | passes', p_who, p_label;
    ELSE
        IF v_msg IS NULL OR v_msg NOT LIKE p_expect THEN
            RAISE EXCEPTION 'PROOF_FAILED|% | % | expected %, got %', p_who, p_label, p_expect, COALESCE(v_msg, '(passed)');
        END IF;
        RAISE NOTICE 'CELL ok  | % | % | %', p_who, p_label, v_msg;
    END IF;
END $$;

DO $proof$
DECLARE
    v_cells int := 0;
    v_sup uuid; v_assay uuid; v_batch uuid; v_c uuid; v_rep jsonb; v_je_before bigint; v_n bigint;
    v_rls text := 'new row violates row-level security policy%';
    v_contract_sql text; v_formula_sql text; v_quote_sql text; v_msg text;
BEGIN
    SELECT id INTO v_sup FROM suppliers WHERE code = 'SUP-2026-0003';
    SELECT a.id, a.inbound_batch_id INTO v_assay, v_batch FROM assay_results a WHERE a.code = 'ASY-2026-0004';
    SELECT count(*) INTO v_je_before FROM journal_entries;
    IF v_sup IS NULL OR v_assay IS NULL THEN RAISE EXCEPTION 'PROOF_SETUP|a named live row is missing'; END IF;
    RAISE NOTICE 'IDENTITY | % | rolbypassrls = % | cells run as each account under SET LOCAL ROLE authenticated',
        current_user, (SELECT rolbypassrls FROM pg_roles WHERE rolname = current_user);

    v_contract_sql := format($q$INSERT INTO contracts (supplier_id, kind, title, effective_from, status)
                                VALUES (%L::uuid, 'supply', 'ZZ-B2B proof', CURRENT_DATE, 'draft')$q$, v_sup);
    v_formula_sql := $q$INSERT INTO pricing_formulas (code, name, direction, price_basis, treatment_charge_usd_per_tonne, flat_discount_pct)
                        VALUES ('ZZ-B2B-PF-' || substr(md5(random()::text), 1, 6), 'ZZ-B2B proof', 'purchase', 'spot', 0, 0)$q$;
    v_quote_sql := $q$SELECT upsert_metal_prices(CURRENT_DATE, '[{"metal":"ni","price_usd_per_tonne":15000}]'::jsonb, NULL, 'broker_quote')$q$;

    -- ══════════ K · 合同条款(Q12 · Q1)══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance creates a contract', v_contract_sql, v_rls); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('phua@evolytra.test', 'cto creates a contract', v_contract_sql, v_rls); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse creates a contract', v_contract_sql, v_rls); v_cells := v_cells + 1;
    PERFORM pg_temp.as_user('sandra@evoltrya.test');
    v_rep := pg_temp.run_json(v_contract_sql || ' RETURNING jsonb_build_object(''id'', id)');
    v_c := (v_rep->>'id')::uuid;
    RAISE NOTICE 'CELL ok  | sandra@evoltrya.test | cco creates a contract | passes (%)', (SELECT code FROM contracts WHERE id = v_c);
    v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco writes a grade term on it',
        format('INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (%L::uuid, %L, 18)', v_c, 'ni'), NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance writes a grade term on that contract',
        format('INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (%L::uuid, %L, 18)', v_c, 'co'), v_rls); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse edits that contract',
        format('UPDATE contracts SET notes = %L WHERE id = %L::uuid', 'x', v_c), 'PERMISSION_DENIED|action.contract_terms'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('admin@swm-os.test', 'admin@ creates a contract (admin keeps every code)', v_contract_sql, NULL); v_cells := v_cells + 1;

    -- ══════════ P · 金属行情(Q13)══════════
    PERFORM pg_temp.cell('phua@evolytra.test', 'cto enters a metal price', v_quote_sql, 'PERMISSION_DENIED|action.metal_prices'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco enters a metal price', v_quote_sql, 'PERMISSION_DENIED|action.metal_prices'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco changes the stale-quote threshold',
        'UPDATE pricing_settings SET metal_price_change_warn_pct = metal_price_change_warn_pct', 'PERMISSION_DENIED|action.metal_prices'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance enters a metal price', v_quote_sql, NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance changes the threshold',
        'UPDATE pricing_settings SET metal_price_change_warn_pct = metal_price_change_warn_pct', NULL); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance creates a pricing formula', v_formula_sql, v_rls); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('phua@evolytra.test', 'cto creates a pricing formula', v_formula_sql, v_rls); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco creates a pricing formula', v_formula_sql, NULL); v_cells := v_cells + 1;

    -- ══════════ S · 直接销售(Q14 · Q3)══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance sells from an output batch',
        $q$SELECT record_output_sale(gen_random_uuid(), 1, 1, 'USD', NULL, NULL, CURRENT_DATE)$q$, 'PERMISSION_DENIED|action.direct_sale'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('phua@evolytra.test', 'cto sells from an output batch',
        $q$SELECT record_output_sale(gen_random_uuid(), 1, 1, 'USD', NULL, NULL, CURRENT_DATE)$q$, 'PERMISSION_DENIED|action.direct_sale'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse sells from an output batch',
        $q$SELECT record_output_sale(gen_random_uuid(), 1, 1, 'USD', NULL, NULL, CURRENT_DATE)$q$, 'PERMISSION_DENIED|action.direct_sale'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'control: cco passes the gate (unknown batch → data refusal)',
        $q$SELECT record_output_sale(gen_random_uuid(), 1, 1, 'USD', NULL, NULL, CURRENT_DATE)$q$, 'OUTPUT_%'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance inserts a sales record directly',
        $q$INSERT INTO sales_records (output_batch_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date)
           VALUES (gen_random_uuid(), 1, 1, 'USD', 1, 1, CURRENT_DATE)$q$, 'SALE_THROUGH_FUNCTION_ONLY'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance updates sales records directly (zero rows must still refuse)',
        'UPDATE sales_records SET notes = notes WHERE false', 'SALE_THROUGH_FUNCTION_ONLY'); v_cells := v_cells + 1;

    -- ══════════ A · 化验(Q15 · Q4)══════════
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance unapplies ASY-2026-0004',
        format('SELECT unapply_assay_result(%L::uuid, %L)', v_assay, 'B2b proof'), 'PERMISSION_DENIED|action.apply_assay'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('sandra@evoltrya.test', 'cco unapplies ASY-2026-0004',
        format('SELECT unapply_assay_result(%L::uuid, %L)', v_assay, 'B2b proof'), 'PERMISSION_DENIED|action.apply_assay'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse unapplies ASY-2026-0004',
        format('SELECT unapply_assay_result(%L::uuid, %L)', v_assay, 'B2b proof'), 'PERMISSION_DENIED|action.apply_assay'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('chooer@evoltrya.test', 'finance previews an assay price',
        format('SELECT preview_assay_price(%L::uuid, %L::jsonb, CURRENT_DATE)', v_batch, '[{"metal":"ni","content_pct":40}]'), 'PERMISSION_DENIED|action.apply_assay'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse previews an output assay',
        'SELECT preview_apply_output_assay(gen_random_uuid())', 'PERMISSION_DENIED|action.apply_assay'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse marks the assay applied directly',
        format('UPDATE assay_results SET applied_at = now() WHERE id = %L::uuid', v_assay), 'ASSAY_APPLY_THROUGH_FUNCTION_ONLY'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'warehouse writes assay-sourced metal content directly',
        format('INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct, content_source, source_assay_id) VALUES (%L::uuid, %L, 5, %L, %L::uuid)',
               v_batch, 'mn', 'assay', v_assay), 'ASSAY_CONTENT_THROUGH_FUNCTION_ONLY'); v_cells := v_cells + 1;
    PERFORM pg_temp.cell('fusheng@evoltrya.test', 'control: warehouse still records a lab result',
        format('SELECT record_assay_result(p_inbound_batch_id => %L::uuid, p_assay_date => CURRENT_DATE, p_metals => %L::jsonb, p_weight_basis => %L, p_result_party => %L)',
               v_batch, '[{"metal":"ni","content_pct":41}]', 'as_received', 'ours'), NULL); v_cells := v_cells + 1;
    -- cto 撤销再应用 ASY-2026-0004:真的重算价、真的过一张分录(整支回滚)
    PERFORM pg_temp.cell('phua@evolytra.test', 'cto unapplies ASY-2026-0004',
        format('SELECT unapply_assay_result(%L::uuid, %L)', v_assay, 'B2b proof'), NULL); v_cells := v_cells + 1;
    -- 应用:过 action.apply_assay 的门,再过 reprice_inbound_batch 里那道嵌套的 inbound.edit(第 30 行),
    -- 然后才走到汇率(第 45 行)。线上 2026-09-24 没有 USD tt_sell 牌价(测试数据),所以它可能在那里
    -- 按名停下 —— 那是一次【数据】拒绝,证明两道权限都已经过了。本支【不】为此编一个汇率。
    PERFORM pg_temp.as_user('phua@evolytra.test');
    v_msg := pg_temp.try_sql(format('SELECT apply_assay_result(%L::uuid)', v_assay));
    SELECT count(*) INTO v_n FROM journal_entries;
    IF v_msg IS NULL THEN
        IF (SELECT applied_by FROM assay_results WHERE id = v_assay) IS DISTINCT FROM (SELECT id FROM auth.users WHERE email = 'phua@evolytra.test') THEN
            RAISE EXCEPTION 'PROOF_FAILED|ASY-2026-0004 should now be applied by phua@';
        END IF;
        RAISE NOTICE 'CELL ok  | phua@evolytra.test | cto re-applies ASY-2026-0004 | passes · journal_entries % → % (inside the proof)', v_je_before, v_n;
    ELSIF v_msg LIKE 'FX_RATE_MISSING|%' THEN
        RAISE NOTICE 'CELL ok  | phua@evolytra.test | cto re-applies ASY-2026-0004 | past both permission checks, stops on data: % · journal_entries % → %', v_msg, v_je_before, v_n;
    ELSE
        RAISE EXCEPTION 'PROOF_FAILED|phua@ | cto re-applies ASY-2026-0004 | expected success or FX_RATE_MISSING, got %', v_msg;
    END IF;
    v_cells := v_cells + 1;

    -- ══════════ R · 读回:每个真账号的码 ══════════
    DECLARE r record; v_codes text[];
    BEGIN
        FOR r IN SELECT email FROM auth.users WHERE email IN ('admin@swm-os.test','tim@evoltrya.test','chooer@evoltrya.test',
                 'sandra@evoltrya.test','phua@evolytra.test','fusheng@evoltrya.test','vince@evoltrya.test') ORDER BY email LOOP
            PERFORM pg_temp.as_user(r.email);
            v_codes := current_user_permissions();
            RAISE NOTICE 'READ ok  | % | current_user_permissions() | % codes · of interest: %', r.email, cardinality(v_codes),
                COALESCE((SELECT string_agg(c, ',' ORDER BY c) FROM unnest(v_codes) c WHERE c IN ('action.contract_terms',
                    'action.metal_prices','action.direct_sale','action.apply_assay','module.pricing.edit',
                    'action.finance_settings','action.customer_credit','action.supplier_approve')), '-');
        END LOOP;
    END;

    RAISE NOTICE 'ROLE1B2B LIVE PROOF: % cells passed', v_cells;
END;
$proof$;

ROLLBACK;

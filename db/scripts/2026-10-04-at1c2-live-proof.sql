-- db/scripts/2026-10-04-at1c2-live-proof.sql
-- AUDIT-TRAIL-1c-2 · 线上的证明(形状照 1c-1 的那一份)。以 postgres 跑,读者一律是【真账号】的会话(SET LOCAL ROLE authenticated + JWT)。
--   A  只读:八个新主语在线上的【每一条】记录(销售 · 运费单 · 资产 · 对账单 · GST 期间 · 汇率 · 管理包 · 合同),以 tim@(cfo)读 ——
--      不许被拒;根行自己的建立在(线上每一行都早于记录,所以是拼回来的那一条);Q9 的两个戳在(冲销了的运费单 · 对过账却没有
--      对账记录的 BS-2026-0002);删掉的那一张对账单的删除戳在;资产卡修改史的那两行在;一行只出现一次。
--      读出来的行写进临时表,末尾一并吐成 JSON(给造句器 —— 它在两种界面里逐字相同,由 scripts/probe-at1c2.mjs 在页面上量)。
--   B  回滚:chooer@(finance)提与做、tim@(cfo)批、sandra@(cco)建供应商 / 货代与合同(建户人不能是付款人或批准人,SOD;
--      admin@ 与 tim@ 是同一个人的两个账号 —— 所以 admin@ 只做不需要审批的布景),每一种主单据建一张、改一次:
--      一笔销售(→ 归属客户)· 一张运费单(→ 改备注 → 冲销)· 一台资产(→ 改使用年限 → 追加成本 → 投用 → 处置申请 → tim@ 批)·
--      一张对账单(→ 改备注 → 忽略两行 → 对账 → 撤销对账)与一张删掉的 · 一个 GST 期间(2026 年第二季:已锁、线上没有这一期 →
--      改备注 → 申报申请 → tim@ 批 → 记下申报 → 开一张更正)· 一条汇率(→ 更正 → 撤回)· 一份管理包(2026-07:已关账、线上一份
--      都没有 → 再产出一份取代它,Q25)· 一份合同(→ 改标题 → 加一条成分规格 → 生效申请 → tim@ 批);以 tim@ 读它们的审计记录。
--   整个文件一笔事务,末尾 ROLLBACK —— 不留下任何东西(前后两份读数逐字相同为证)。
--   ★ 不碰任何一张在这之前就在的单据(委托书的常设规矩:连回滚的事务里也不碰)—— 改的每一行都是本文件自己建的。
-- 线上登记了 GST:测试用的费用走范围外(OP)—— 只为让它们开得出来,税不是本证明证的东西。
-- 跑法:psql "$DSN" -X -q -v ON_ERROR_STOP=1 -f db/scripts/2026-10-04-at1c2-live-proof.sql > out.txt;  PROOF_OWN_EXIT=$?
BEGIN;
SET LOCAL statement_timeout = '600s';

CREATE TEMP TABLE p_out (label text, subject text, id text, rows jsonb) ON COMMIT DROP;

CREATE FUNCTION pg_temp.p_trail(p_user uuid, p_subject text, p_id text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', p_user), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.entry_no, r.seq NULLS LAST, r.occurred_at), '[]'::jsonb) INTO v
      FROM record_trail(p_subject, p_id, 500) r;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE EXCEPTION 'PROOF|% % refused or failed: %', p_subject, p_id, SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.p_twice(p_trail jsonb) RETURNS text
LANGUAGE sql AS $f$
    SELECT string_agg(k, ', ') FROM (
        SELECT COALESCE(e ->> 'seq', 'P') || ':' || (e ->> 'table_name') || ':' || (e ->> 'row_key') || ':' || (e ->> 'op') || ':' ||
               COALESCE(e ->> 'changed_columns', '') AS k
          FROM jsonb_array_elements(p_trail) e WHERE NOT (e ->> 'row_hidden')::boolean
         GROUP BY 1 HAVING count(*) > 1) d
$f$;

CREATE FUNCTION pg_temp.p_has(p_trail jsonb, p_table text, p_op text, p_id text, p_col text DEFAULT NULL, p_prelog boolean DEFAULT NULL) RETURNS boolean
LANGUAGE sql AS $f$
    SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_trail) e
                    WHERE e ->> 'table_name' = p_table AND e ->> 'op' = p_op AND (p_id IS NULL OR e -> 'row_key' ->> 'id' = p_id)
                      AND (p_col IS NULL OR e -> 'changed_columns' ? p_col)
                      AND (p_prelog IS NULL OR (e ->> 'prelog')::boolean = p_prelog))
$f$;

-- ══════════════ A · 只读:线上的每一条 ══════════════
DO $a$
DECLARE
    tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';
    t record; v jsonb; x text; n int := 0;
BEGIN
    FOR t IN SELECT 'sale' AS s, 'sales_records' AS tbl, id::text AS id, NULL::text AS code FROM sales_records
             UNION ALL SELECT 'freight', 'freight_documents', id::text, code FROM freight_documents
             UNION ALL SELECT 'fixed_asset', 'fixed_assets', id::text, code FROM fixed_assets
             UNION ALL SELECT 'bank_statement', 'bank_statements', id::text, code FROM bank_statements
             UNION ALL SELECT 'gst_period', 'gst_periods', id::text, code FROM gst_periods
             UNION ALL SELECT 'fx_rate', 'fx_rates', id::text, NULL FROM fx_rates
             UNION ALL SELECT 'management_pack', 'management_packs', id::text, code FROM management_packs
             UNION ALL SELECT 'contract', 'contracts', id::text, code FROM contracts LOOP
        v := pg_temp.p_trail(tim, t.s, t.id);
        IF NOT pg_temp.p_has(v, t.tbl, 'INSERT', t.id) THEN RAISE EXCEPTION 'PROOF A|% % has no creation on its trail: %', t.s, COALESCE(t.code, t.id), v; END IF;
        x := pg_temp.p_twice(v);
        IF x IS NOT NULL THEN RAISE EXCEPTION 'PROOF A|% % shows a row twice: %', t.s, COALESCE(t.code, t.id), x; END IF;
        INSERT INTO p_out VALUES ('A ' || t.s || ' ' || COALESCE(t.code, t.id), t.s, t.id, v);
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'PROOF A read % live records as tim@', n;
    -- Q9:冲销了的运费单 —— 那一戳拼回来(线上四张,全部早于记录)
    FOR t IN SELECT id, code FROM freight_documents WHERE status = 'reversed' LOOP
        v := (SELECT rows FROM p_out WHERE subject = 'freight' AND id = t.id::text);
        IF NOT pg_temp.p_has(v, 'freight_documents', 'UPDATE', t.id::text, 'reversed_at', true) THEN
            RAISE EXCEPTION 'PROOF A|% (Q9): the reversal before the log did not come back from its stamp: %', t.code, v; END IF;
    END LOOP;
    -- Q9:对过账的对账单(BS-2026-0002 没有一行对账记录)—— 那一戳拼回来;删掉的那一张 —— 删除戳拼回来
    FOR t IN SELECT id, code, status, deleted_at FROM bank_statements LOOP
        v := (SELECT rows FROM p_out WHERE subject = 'bank_statement' AND id = t.id::text);
        IF t.status = 'reconciled' AND NOT pg_temp.p_has(v, 'bank_statements', 'UPDATE', t.id::text, 'reconciled_at', true) THEN
            RAISE EXCEPTION 'PROOF A|% (Q9): the reconciliation before the log did not come back from its stamp: %', t.code, v; END IF;
        IF t.deleted_at IS NOT NULL AND NOT pg_temp.p_has(v, 'bank_statements', 'UPDATE', t.id::text, 'deleted_at', true) THEN
            RAISE EXCEPTION 'PROOF A|% (Q6): the deletion before the log did not come back from its stamp: %', t.code, v; END IF;
    END LOOP;
    -- Q10:资产卡修改史(线上两行,都早于记录)—— 每一行都在它那台资产的记录里
    FOR t IN SELECT h.id, h.fixed_asset_id FROM fixed_asset_history h LOOP
        v := (SELECT rows FROM p_out WHERE subject = 'fixed_asset' AND id = t.fixed_asset_id::text);
        IF NOT pg_temp.p_has(v, 'fixed_asset_history', 'INSERT', t.id::text) THEN
            RAISE EXCEPTION 'PROOF A (Q10): asset history row % is not on its asset''s trail', t.id; END IF;
    END LOOP;
    RAISE NOTICE 'PROOF A passed';
END;
$a$;

-- ══════════════ B · 回滚:建 · 改 · 读(chooer@ 提与做,tim@ 批,sandra@ 建户与合同,admin@ 布景;审批开着)══════════════
DO $b$
DECLARE
    adm uuid := '321f1819-8449-48f7-9ae0-78b2c4b50f35';   -- admin@swm-os.test(admin;与 tim@ 是同一个人)
    fin uuid := '476bf8c8-c248-4352-9a75-945bf52ca390';   -- chooer@evoltrya.test(finance)
    tim uuid := '634c00f9-c3a9-4444-9eed-b624cb6a2a93';   -- tim@evoltrya.test(cfo,二级审批)
    san uuid := '01ae00e4-306f-4527-8537-10291e4750c7';   -- sandra@evoltrya.test(cco;持 action.contract_terms)
    d date := CURRENT_DATE - 2;
    v_base text; v_acct text := '6100'; v_x text;
    v_sup uuid; v_fwd uuid; v_cust uuid; v_mat uuid; ob uuid; sale uuid; ib uuid; frt uuid; fa uuid; adr uuid;
    bs uuid; bs_del uuid; bl uuid; gp uuid; gp_c uuid; gfr uuid; fx uuid; pk1 uuid; pk2 uuid; con uuid; tr uuid;
    as_ text := 'SELECT set_config(''request.jwt.claims'', format(''{"sub":"%s","role":"authenticated"}'', $1), true)';
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'PROOF B|approvals must be ON'; END IF;
    -- 下面"录 · 更正 · 撤回"的那条汇率、那一期 GST、那一个月的管理包,都必须是本事务自己造的 ——
    -- 线上已有一条,第二次 record_fx_rate 就会去【更正一条会话之前就在的记录】,哪怕事务最后回滚也不许。所以先拒,不靠注释。
    IF EXISTS (SELECT 1 FROM fx_rates WHERE rate_date = DATE '2026-10-02' AND rate_type = 'tt_sell') THEN
        RAISE EXCEPTION 'PROOF B|a tt_sell rate for 02/10/2026 (any currency) already exists on live — pick another date'; END IF;
    IF EXISTS (SELECT 1 FROM gst_periods WHERE period_start <= DATE '2026-06-30' AND period_end >= DATE '2026-04-01') THEN
        RAISE EXCEPTION 'PROOF B|a GST period overlapping 2026 Q2 already exists on live'; END IF;
    IF EXISTS (SELECT 1 FROM management_packs WHERE period_month = DATE '2026-07-01') THEN
        RAISE EXCEPTION 'PROOF B|a management pack for 07/2026 already exists on live'; END IF;
    SELECT code INTO v_base FROM currencies WHERE is_base;
    EXECUTE as_ USING san;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ-AT1C2-PROOF-SUP', 'AT-1c-2 live proof supplier — rolled back', 'SG', 'goods_supplier') RETURNING id INTO v_sup;
    INSERT INTO suppliers (status, code, legal_name, country, counterparty_type)
    VALUES ('active', 'ZZ-AT1C2-PROOF-FWD', 'AT-1c-2 live proof forwarder — rolled back', 'SG', 'forwarder') RETURNING id INTO v_fwd;
    EXECUTE as_ USING adm;
    INSERT INTO customers (code, legal_name, country, payment_terms_days) VALUES ('ZZ-AT1C2-PROOF-C', 'AT-1c-2 live proof customer — rolled back', 'SG', 30) RETURNING id INTO v_cust;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code, unit)
    VALUES ('ZZ-AT1C2-PROOF-M', 'AT-1c-2 live proof material', 'battery_material', true, 'black_mass', 'end_of_life', 'kg') RETURNING id INTO v_mat;
    INSERT INTO output_batches (code, material_id, quantity, remaining_qty, output_date) VALUES ('ZZ-AT1C2-PROOF-OB', v_mat, 500, 500, d) RETURNING id INTO ob;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, unit_price, source_reason_code, source_reason_note)
    VALUES ('ZZ-AT1C2-PROOF-IB', v_mat, v_sup, 100, 100, 'kg', d, 3, 'other', 'AT-1c-2 live proof') RETURNING id INTO ib;

    -- 销售:记一笔无主的 → 归属客户。admin@ 记 —— action.direct_sale 线上只在 admin / cco 两个角色上(实测 role_permissions,
    -- postgres 读),finance 没有;第一次跑时用 chooer@ 撞了 PERMISSION_DENIED|action.direct_sale,整笔事务因此回滚。
    sale := (record_output_sale(ob, 40, 12, v_base, NULL, NULL, d, 'AT-1c-2 live proof walk-in sale', 'manual', NULL) ->> 'sale_id')::uuid;
    PERFORM attribute_sale_customer(sale, v_cust, 'AT-1c-2 live proof: it was this customer');

    -- 运费单:记账(分摊到那一批)→ 改备注 → 冲销
    EXECUTE as_ USING fin;
    frt := (record_freight_document(d, v_fwd, 120, v_base, 'weight', 'unpaid', NULL,
            jsonb_build_array(jsonb_build_object('inbound_batch_id', ib)), 'AT-1c-2 live proof freight', NULL) ->> 'freight_document_id')::uuid;
    UPDATE freight_documents SET notes = 'AT-1c-2 live proof freight (port to yard)' WHERE id = frt;
    PERFORM reverse_freight_document(frt, 'AT-1c-2 live proof: billed twice');

    -- 资产:建卡 → 改使用年限 → 追加成本 → 投用 → 处置申请 → tim@ 批
    fa := (create_fixed_asset('AT-1c-2 live proof shredder', 60, d, 'equipment', '6700', 'AT-1c-2 live proof') ->> 'asset_id')::uuid;
    UPDATE fixed_assets SET useful_life_months = 84 WHERE id = fa;
    PERFORM record_expense(p_expense_date := d, p_account_code := '1500', p_amount := 900, p_currency := v_base, p_supplier_id := v_sup,
                           p_notes := 'AT-1c-2 live proof installation', p_asset := jsonb_build_object('asset_id', fa), p_tax_code := 'OP');
    PERFORM set_asset_in_service(fa, d);
    adr := (submit_asset_disposal_request(fa, 0, NULL, 'AT-1c-2 live proof: scrapped') ->> 'request_id')::uuid;
    EXECUTE as_ USING tim;
    PERFORM decide_asset_disposal_request(adr, true, 'proof');

    -- 对账单:导入 → 改备注 → 两行都忽略 → 对账(差额写成一项说明)→ 撤销对账;另一张导入后删掉
    EXECUTE as_ USING fin;
    bs := (import_bank_statement('1000', d - 3, d, 100, 160, 'at1c2-proof.csv', jsonb_build_array(
            jsonb_build_object('line_date', d - 2, 'amount', 40, 'description', 'AT-1c-2 live proof in'),
            jsonb_build_object('line_date', d - 1, 'amount', 20, 'description', 'AT-1c-2 live proof in 2'))) ->> 'statement_id')::uuid;
    UPDATE bank_statements SET notes = 'AT-1c-2 live proof statement' WHERE id = bs;
    FOR bl IN SELECT id FROM bank_statement_lines WHERE statement_id = bs ORDER BY line_no LOOP
        PERFORM ignore_bank_line(bl, 'AT-1c-2 live proof: not ours');
    END LOOP;
    BEGIN
        PERFORM reconcile_statement(bs, NULL);
        RAISE EXCEPTION 'PROOF B|the proof statement should not agree with the books on its own';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'BALANCE_DISAGREES|%' THEN RAISE; END IF;
        v_x := split_part(SQLERRM, '|', 4);
    END;
    PERFORM reconcile_statement(bs, jsonb_build_array(jsonb_build_object('kind', 'timing', 'amount', v_x::numeric, 'note', 'AT-1c-2 live proof: the whole difference')));
    PERFORM unreconcile_statement(bs, 'AT-1c-2 live proof: wrong period');
    bs_del := (import_bank_statement('1000', d - 3, d, 160, 170, 'at1c2-proof-bad.csv', jsonb_build_array(
            jsonb_build_object('line_date', d - 1, 'amount', 10, 'description', 'AT-1c-2 live proof bad import'))) ->> 'statement_id')::uuid;
    UPDATE bank_statements SET deleted_at = now() WHERE id = bs_del;

    -- GST:开 2026 年第二季(已锁,线上没有这一期)→ 改备注 → 申报申请 → tim@ 批 → 记下申报 → 开一张更正
    gp := (open_gst_period(DATE '2026-04-01', DATE '2026-06-30') ->> 'gst_period_id')::uuid;
    UPDATE gst_periods SET notes = 'AT-1c-2 live proof period' WHERE id = gp;
    gfr := (submit_gst_filing_request(gp, 'AT-1c-2 live proof: ready to file') ->> 'request_id')::uuid;
    EXECUTE as_ USING tim;
    PERFORM decide_gst_filing_request(gfr, true, NULL);
    EXECUTE as_ USING fin;
    PERFORM record_gst_filing(gp, d, 'AT-1C2-PROOF-ACK');
    gp_c := (correct_gst_return(gp, 'AT-1c-2 live proof: a late supplier invoice') ->> 'gst_period_id')::uuid;

    -- 汇率:录一条(那一天那一边线上没有)→ 更正(带理由)→ 撤回
    fx := (record_fx_rate('USD', DATE '2026-10-02', 'tt_sell', 1.2871, 'DBS', 'AT-1c-2 live proof') ->> 'id')::uuid;
    PERFORM record_fx_rate('USD', DATE '2026-10-02', 'tt_sell', 1.2817, 'DBS', 'AT-1c-2 live proof', 'AT-1c-2 live proof: typed the buy rate');
    PERFORM withdraw_fx_rate(fx, 'AT-1c-2 live proof: bank holiday');

    -- 管理包(Q25):2026-07(已关账,线上一份都没有)→ 再产出一份取代它
    pk1 := (freeze_management_pack(DATE '2026-07-01', 'AT-1c-2 live proof pack') ->> 'pack_id')::uuid;
    pk2 := (freeze_management_pack(DATE '2026-07-01', 'AT-1c-2 live proof pack v2', 'AT-1c-2 live proof: a late accrual') ->> 'pack_id')::uuid;

    -- 合同:sandra@ 建(买方)→ 改标题 → 加一条成分规格 → 生效申请 → tim@ 批
    EXECUTE as_ USING san;
    INSERT INTO contracts (supplier_id, kind, title, effective_from, currency) VALUES (v_sup, 'supply', 'AT-1c-2 live proof supply', d, v_base) RETURNING id INTO con;
    UPDATE contracts SET title = 'AT-1c-2 live proof supply (revised)' WHERE id = con;
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (con, (SELECT code FROM substances WHERE is_active ORDER BY code LIMIT 1), 10);
    tr := (submit_contract_activation_request(con, 'AT-1c-2 live proof: signed') ->> 'request_id')::uuid;
    EXECUTE as_ USING tim;
    PERFORM decide_terms_request(tr, true, NULL);
    PERFORM set_config('request.jwt.claims', '', true);

    INSERT INTO p_out VALUES
        ('B sale', 'sale', sale::text, pg_temp.p_trail(tim, 'sale', sale::text)),
        ('B freight', 'freight', frt::text, pg_temp.p_trail(tim, 'freight', frt::text)),
        ('B fixed asset', 'fixed_asset', fa::text, pg_temp.p_trail(tim, 'fixed_asset', fa::text)),
        ('B bank statement', 'bank_statement', bs::text, pg_temp.p_trail(tim, 'bank_statement', bs::text)),
        ('B bank statement (deleted)', 'bank_statement', bs_del::text, pg_temp.p_trail(tim, 'bank_statement', bs_del::text)),
        ('B GST period', 'gst_period', gp::text, pg_temp.p_trail(tim, 'gst_period', gp::text)),
        ('B GST period (correction)', 'gst_period', gp_c::text, pg_temp.p_trail(tim, 'gst_period', gp_c::text)),
        ('B FX rate', 'fx_rate', fx::text, pg_temp.p_trail(tim, 'fx_rate', fx::text)),
        ('B management pack (replaced)', 'management_pack', pk1::text, pg_temp.p_trail(tim, 'management_pack', pk1::text)),
        ('B management pack (newer)', 'management_pack', pk2::text, pg_temp.p_trail(tim, 'management_pack', pk2::text)),
        ('B contract', 'contract', con::text, pg_temp.p_trail(tim, 'contract', con::text));
    IF EXISTS (SELECT 1 FROM p_out WHERE label LIKE 'B %' AND pg_temp.p_twice(rows) IS NOT NULL) THEN
        RAISE EXCEPTION 'PROOF B|a row shows twice: %', (SELECT string_agg(label || ': ' || pg_temp.p_twice(rows), '; ') FROM p_out WHERE label LIKE 'B %' AND pg_temp.p_twice(rows) IS NOT NULL); END IF;
    PERFORM set_config('request.jwt.claims', format('{"sub":"%s","role":"authenticated"}', tim), true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    IF NOT EXISTS (SELECT 1 FROM deleted_records WHERE record_kind = 'bank_statement' AND record_id = bs_del AND deleted_by = fin) THEN
        EXECUTE 'RESET ROLE';
        RAISE EXCEPTION 'PROOF B|the deleted statement is not listed in deleted_records with chooer@ as the person (Q6)'; END IF;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE NOTICE 'PROOF B passed: sale of %, freight %, asset %, statements %/%, GST %/%, packs %/%, contract %',
        'ZZ-AT1C2-PROOF-OB', (SELECT code FROM freight_documents WHERE id = frt), (SELECT code FROM fixed_assets WHERE id = fa),
        (SELECT code FROM bank_statements WHERE id = bs), (SELECT code FROM bank_statements WHERE id = bs_del),
        (SELECT code FROM gst_periods WHERE id = gp), (SELECT code FROM gst_periods WHERE id = gp_c),
        (SELECT code FROM management_packs WHERE id = pk1), (SELECT code FROM management_packs WHERE id = pk2), (SELECT code FROM contracts WHERE id = con);
END;
$b$;

-- 给造句器的那一份:每一条一行 JSON
\pset tuples_only on
\pset format unaligned
SELECT jsonb_build_object('label', label, 'subject', subject, 'id', id, 'rows', rows)::text FROM p_out ORDER BY label LIKE 'B%', label, subject, id;

ROLLBACK;

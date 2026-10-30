-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 269 —— 一家供应商的评分卡是现算的计数,一次评审把它算出等级的一切都抄下来,等级只会警告、从不拒绝;F17
--   (MES-8a,2026-10-16;MES-0 Q77 · Q78 · Q91 · Q93;MES-8 Step 0 Q2–Q6 · Q21–Q25 · Q27,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REG     四张新表都在;设定那一行在、四样全空(Q4:什么都不猜);评审与对账单空;单据登记 SST;码 action.supplier_review 声明
--           module.suppliers.view;审计主语 supplier_scorecard_review(集合)· supplier_score_settings · supplier_statement 与成员;四张新表进变更记录,
--           豁免仍是 8 —— MES-9b 起是 9;没有遮蔽的列(规则仍 119);新视图 authenticated 读得到,底视图 grn_discrepancies_all 读不到;F16 仍是 0;
--           计分项的名字正好是那十一项
--   MEAS    计数:短交(按行,只在关了的单上比)· 超交 · 不合格报告按处置 · 化验争议(撤回的只显示)· 放电判断矛盾 · 证书断档的天数 ——
--           每一项的 compared / not_compared;窗口之外的不算;别家的不算
--   NOTCMP  一家什么都没有的供应商:没比过的那几项读 null("not compared"),从不是 0;不合格报告那几项是真的 0
--   BREACH  等级超标只显示(scored = false,caveat CONTRACT-1),不进分(没有它的权重键 —— 设定按名拒 SCORE_WEIGHT_UNKNOWN|grade_breaches);
--           它的有无不改分
--   WINDOW  窗口必填 / 不倒置 / 不在未来 / 供应商不在 —— 各自按名拒;门 module.suppliers.view
--   GATE    记评审与改设定要 action.supplier_review;只持 module.suppliers.view 的人读得到计数、记不了;动作码蕴含查看码(持动作码的角色都持声明的查看码)
--   NOTGR   V23 空着:评审照记,等级空、not_graded_reason V23_NOT_SET,权重 / 线为空,计数照原样抄下;等级建议 graded = false,采购单没有警告
--   V23     设定空着时 V23 一行(只给持 suppliers.view 的人);权重与线同进同出 · 缺一项 · 多一项 · 负数 · 等级名空 / 重复 · 线不递增 ·
--           最后一条有上限 · 周期 ≤ 0 · 上限对不上等级 · 上限超出 0–100 —— 各自按名拒;给全之后 V23 没有行
--   V24     有了等级线之后,每一个缺上限或抽样级别的等级一行;给全之后没有行
--   GRADED  评审抄下计数、权重、线、上限与得出的分与等级;分 = Σ 权重 × 计数(没比过的不计);等级照线;之后改设定不改写这一次评审
--   CORR    更正:没理由 / 有理由没引用 / 引用别家的 / 引用一次已被更正过的 —— 按名拒;更正之后旧的被取代、最近的一次是更正;
--           评审改与删对谁都按名拒
--   LATEST  同一笔事务里先后两次评审 —— 最近的按 seq 认,不按 recorded_at(两次 recorded_at 相同)
--   PO      create_purchase_order:下单时付 50% 而等级上限 30% → 一条 PREPAYMENT_ABOVE_GRADE_CAP 警告、单照样建好;20% → 没有警告;
--           表单那一支(supplier_grade_advice)说的与建单返回的是同一条;一家最近一次评审没评级的 → 没有警告
--   SAMPLE  抽样建议读那一次评审抄下的级别;它不加任何一项必须的化验(material_required_metals 一行不多)
--   DUE     V23 的周期空着:supplier_review_due 一行都不出;给了周期:从没评过的批准 / 在用进货供应商一行(never_reviewed),
--           评过而过了周期的一行(due),刚评过的没有;草稿、货代不列;只给持 action.supplier_review 的人
--   F17     record_cod_issue:路径不在证书目录下 → COD_ISSUE_PATH_INVALID;大写的哈希存成小写;再记一次 → COD_BYTES_ALREADY_RECORDED
--
-- 自带数据(README 第 2 条);以 postgres 跑;员工的调用切成 authenticated + JWT(AGENTS.md:RLS 断言必须切角色)。
-- 全部判定写成 IF (…) IS NOT FALSE —— 一个 NULL 也是红(fixture 268 的那一课)。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f269_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

CREATE FUNCTION pg_temp.f269_do(p_user uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM pg_temp.f269_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f269_as(NULL);
    RETURN 'OK';
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f269_as(NULL);
    RETURN SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f269_get(p_user uuid, p_sql text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
    PERFORM pg_temp.f269_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f269_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f269_as(NULL);
    RAISE;
END;
$f$;

CREATE FUNCTION pg_temp.f269_user(p_label text, p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE u uuid := gen_random_uuid(); r uuid;
BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at, created_at) VALUES (u, 'fx269-' || p_label || '@test.local', now(), now());
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx269-' || p_label, 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

CREATE FUNCTION pg_temp.f269_expect(p_arm text, p_got text, p_like text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
    IF (p_got IS NULL OR p_got NOT LIKE p_like) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 % expected % got %', p_arm, p_like, COALESCE(p_got, '<null>');
    END IF;
END;
$f$;

-- 一份完整的、合法的 V23 权重(每一项都给)
CREATE FUNCTION pg_temp.f269_weights(p_over jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
LANGUAGE sql AS $f$
    SELECT jsonb_object_agg(k, CASE k WHEN 'short_lines' THEN 3 WHEN 'over_lines' THEN 1 WHEN 'ncr_reject' THEN 5 WHEN 'ncr_open' THEN 2
                                      WHEN 'disputes' THEN 2 WHEN 'discharge_mismatches' THEN 1 WHEN 'certificate_lapse_days' THEN 0.1 ELSE 0 END) || p_over
      FROM unnest(supplier_scorecard_measure_keys()) k
$f$;

DO $$
DECLARE
    u_all uuid; u_rev uuid; u_vw uuid; u_none uuid;
    v_base text;
    D0 date := DATE '2026-07-01'; D1 date := DATE '2026-07-31';
    s1 uuid; s2 uuid; s3 uuid; s4 uuid; s_draft uuid; s_fwd uuid; v_mat uuid;
    po_a uuid; po_b uuid; l_a uuid; l_b uuid; b1 uuid; b2 uuid; b3 uuid; b_out uuid; b_s4 uuid;
    a_ours uuid; a_cp uuid; a_br uuid; v_con uuid;
    v_m jsonb; v_m2 jsonb; v_p jsonb; v_j jsonb; v_r jsonb; v_msg text; v_n bigint; v_n2 bigint; v_txt text;
    rv1 uuid; rv2 uuid; rv3 uuid; rv_g uuid; v_score numeric; v_po jsonb;
    v_cod uuid; v_ib_cod uuid; v_req_before bigint;
BEGIN
    SELECT code INTO v_base FROM currencies WHERE is_base;
    PERFORM pg_temp.f269_as(NULL);
    UPDATE finance_settings SET locked_before = NULL;
    -- 收货差异的三个阈值自己设(README 第 4 条:不继承)
    UPDATE receiving_settings SET grn_short_pct = 5, grn_over_pct = 5, grn_assay_tolerance_pct = 10;

    -- ══════════════ REG ══════════════
    RAISE NOTICE 'fixture 269 · REG';
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['supplier_score_settings', 'supplier_scorecard_reviews', 'supplier_statements', 'supplier_statement_issues']) t
                WHERE to_regclass('public.' || t) IS NULL)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: the four new tables'; END IF;
    IF ((SELECT count(*) FROM supplier_score_settings) <> 1
        OR EXISTS (SELECT 1 FROM supplier_score_settings WHERE weights IS NOT NULL OR grade_lines IS NOT NULL OR review_window_days IS NOT NULL OR grade_caps IS NOT NULL)
        OR EXISTS (SELECT 1 FROM supplier_scorecard_reviews) OR EXISTS (SELECT 1 FROM supplier_statements)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: one settings row with V23 and V24 empty, no review, no statement (Q4 — nothing is guessed)'; END IF;
    IF (document_type_prefix('supplier_statement') <> 'SST' OR (SELECT route FROM document_types WHERE key = 'supplier_statement') <> '/finance/supplier-statements'
       OR (SELECT view_permission FROM document_types WHERE key = 'supplier_statement') <> ARRAY['module.finance.view']) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: document type SST'; END IF;
    IF ((SELECT requires_view_any FROM permissions WHERE code = 'action.supplier_review') IS DISTINCT FROM ARRAY['module.suppliers.view']) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: action.supplier_review declares module.suppliers.view'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'supplier_scorecard_review' AND s.root_table = 'supplier_scorecard_reviews' AND s.root_rule = 'collection'
                                                     AND s.view_codes = ARRAY['module.suppliers.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'supplier_score_settings' AND s.root_table = 'supplier_score_settings')
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'supplier_statement' AND s.root_table = 'supplier_statements' AND s.view_codes = ARRAY['module.finance.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'supplier_statement' AND m.table_name = 'supplier_statement_issues' AND m.home)
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'supplier' AND m.table_name = 'supplier_scorecard_reviews' AND NOT m.home)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: trail subjects supplier_scorecard_review / supplier_score_settings / supplier_statement and their members'; END IF;
    v_j := change_log_coverage_gaps();
    IF (jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 10) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: change-log coverage (gaps 0, exclusions 9): %', v_j; END IF;
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['supplier_score_settings', 'supplier_scorecard_reviews', 'supplier_statements', 'supplier_statement_issues']) t
                WHERE NOT EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgname = 'zzz_change_log' AND g.tgrelid = ('public.' || t)::regclass))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: every new table is change-logged'; END IF;
    IF (EXISTS (SELECT 1 FROM change_log_mask_rules() WHERE table_name LIKE 'supplier_score%' OR table_name LIKE 'supplier_statement%')
       OR (SELECT count(*) FROM change_log_mask_rules()) <> 132) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: no masked column in MES-8a (rules stay 119 from that cut; 129 since GOLIVE-1 row 12 added the settlement and contract-term prices; 132 since GOLIVE-2 added the frozen contract copy (2) and the terms-request snapshot (1))'; END IF;
    IF (EXISTS (SELECT 1 FROM unnest(ARRAY['supplier_latest_reviews', 'supplier_scorecard_rows', 'supplier_statement_rows', 'grn_discrepancies']) v
                WHERE NOT has_table_privilege('authenticated', ('public.' || v)::regclass, 'SELECT'))
       OR has_table_privilege('authenticated', 'public.grn_discrepancies_all'::regclass, 'SELECT')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: the new views are readable by staff, the base view grn_discrepancies_all is not'; END IF;
    SELECT string_agg(c.relname || ':' || g.r || ':' || p.priv, ', ') INTO v_txt
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r) CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
     WHERE n.nspname = 'public' AND c.relkind = 'v' AND has_table_privilege(g.r, c.oid, p.priv);
    IF (v_txt IS NOT NULL) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 REG: F16 — no view may carry a write grant: %', v_txt; END IF;
    IF (supplier_scorecard_measure_keys() <> ARRAY['short_lines', 'over_lines', 'ncr_open', 'ncr_accept', 'ncr_accept_with_penalty', 'ncr_reject',
                                                  'ncr_rework', 'ncr_downgrade', 'disputes', 'discharge_mismatches', 'certificate_lapse_days']) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 REG: the scored measures are exactly the eleven named (grade breaches are not among them)'; END IF;

    -- ══════════════ 布景 ══════════════
    u_all  := pg_temp.f269_user('all', ARRAY(SELECT code FROM permissions));
    u_rev  := pg_temp.f269_user('rev', ARRAY['module.suppliers.view', 'action.supplier_review']);
    u_vw   := pg_temp.f269_user('vw', ARRAY['module.suppliers.view']);
    u_none := pg_temp.f269_user('none', ARRAY['module.inbound.view', 'module.finance.view']);
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX269-M', 'fixture 269 material', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES
        ('FX269-S1', 'fixture 269 measured supplier', 'SG', 'active', 'goods_supplier'),
        ('FX269-S2', 'fixture 269 empty supplier', 'SG', 'active', 'goods_supplier'),
        ('FX269-S3', 'fixture 269 approved never reviewed', 'SG', 'approved', 'goods_supplier'),
        ('FX269-S4', 'fixture 269 old review', 'SG', 'active', 'goods_supplier'),
        ('FX269-SD', 'fixture 269 draft supplier', 'SG', 'draft', 'goods_supplier'),
        ('FX269-SF', 'fixture 269 forwarder', 'SG', 'active', 'forwarder');
    SELECT id INTO s1 FROM suppliers WHERE code = 'FX269-S1';
    SELECT id INTO s2 FROM suppliers WHERE code = 'FX269-S2';
    SELECT id INTO s3 FROM suppliers WHERE code = 'FX269-S3';
    SELECT id INTO s4 FROM suppliers WHERE code = 'FX269-S4';
    SELECT id INTO s_draft FROM suppliers WHERE code = 'FX269-SD';
    SELECT id INTO s_fwd FROM suppliers WHERE code = 'FX269-SF';
    -- 两张单:A 关了(短交在它上面才判),B 还在收(超交照判、短交不判);A 那一行的采购时判断是 can,到货记成 cannot(矛盾)
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category) VALUES
        ('FX269-POA', s1, D0 - 10, v_base, 1, 'receiving', 'approved', 'equipment_goods'),
        ('FX269-POB', s1, D0 - 10, v_base, 1, 'receiving', 'approved', 'equipment_goods');
    SELECT id INTO po_a FROM purchase_orders WHERE code = 'FX269-POA';
    SELECT id INTO po_b FROM purchase_orders WHERE code = 'FX269-POB';
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit, deep_discharge_judgement_code)
    VALUES (po_a, 1, v_mat, 100, 'kg', 'can') RETURNING id INTO l_a;
    INSERT INTO purchase_order_lines (purchase_order_id, line_no, material_id, quantity, unit)
    VALUES (po_b, 1, v_mat, 100, 'kg') RETURNING id INTO l_b;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, purchase_order_id, purchase_order_line_id,
                                 deep_discharge_actual_code)
    VALUES ('FX269-B1', v_mat, s1, 80, 80, 'kg', D0 + 5, po_a, l_a, 'cannot') RETURNING id INTO b1;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, purchase_order_id, purchase_order_line_id)
    VALUES ('FX269-B2', v_mat, s1, 120, 120, 'kg', D0 + 6, po_b, l_b) RETURNING id INTO b2;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX269-B3', v_mat, s1, 50, 50, 'kg', D0 + 7, 'other', 'fixture 269 自带数据') RETURNING id INTO b3;
    -- A 单收了 80 之后关掉(短交只在关了的单上判 —— 开着的单"少"只是还没收完)
    PERFORM pg_temp.f269_as(u_all);
    PERFORM close_purchase_order(po_a, 'f269 short delivery accepted');
    PERFORM pg_temp.f269_as(NULL);
    -- 窗口之外的一张收货(不该算进任何一项)
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX269-BOUT', v_mat, s1, 50, 50, 'kg', D1 + 10, 'other', 'fixture 269 自带数据') RETURNING id INTO b_out;
    -- 不合格报告:B1 上一张开着的,B2 上一张决定为拒收的,窗口外一张(不算)
    INSERT INTO nonconformance_reports (code, inbound_batch_id, source, description, opened_by, opened_at) VALUES
        ('FX269-NCR1', b1, 'manual', 'f269 open', u_all, (D0 + 8)::timestamptz + interval '4 hours');
    INSERT INTO nonconformance_reports (code, inbound_batch_id, source, description, opened_by, opened_at, status, disposition, decision_note, decided_at, decided_by) VALUES
        ('FX269-NCR2', b2, 'manual', 'f269 rejected', u_all, (D0 + 9)::timestamptz + interval '4 hours', 'decided', 'reject', 'f269 reject', now(), u_rev),
        ('FX269-NCR3', b_out, 'manual', 'f269 outside', u_all, (D1 + 11)::timestamptz + interval '4 hours', 'decided', 'reject', 'f269 reject', now(), u_rev);
    -- 化验争议:B2 上一件开着的,一件撤回的(只显示)
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final, weight_basis, result_party) VALUES
        ('FX269-A-OURS', b2, D0 + 10, true, 'dry', 'ours'), ('FX269-A-CP', b2, D0 + 10, true, 'dry', 'counterparty');
    SELECT id INTO a_ours FROM assay_results WHERE code = 'FX269-A-OURS';
    SELECT id INTO a_cp FROM assay_results WHERE code = 'FX269-A-CP';
    INSERT INTO assay_disputes (inbound_batch_id, our_assay_id, counterparty_assay_id, opening_reason, created_at)
    VALUES (b2, a_ours, a_cp, 'f269 disagree', (D0 + 11)::timestamptz + interval '4 hours');
    INSERT INTO assay_disputes (inbound_batch_id, our_assay_id, counterparty_assay_id, opening_reason, created_at, status, withdrawn_at, withdrawn_by, withdraw_reason)
    VALUES (b2, a_cp, a_ours, 'f269 withdrawn', (D0 + 12)::timestamptz + interval '4 hours', 'withdrawn', now(), u_all, 'f269 not needed');
    -- 证书:basel(block)7-01 起有效到 7-10 —— 窗口 31 天里 21 天没有有效的一张
    INSERT INTO supplier_compliance (supplier_id, cert_type_code, cert_no, valid_from, valid_until) VALUES (s1, 'basel', 'F269-1', D0, D0 + 9);

    -- ══════════════ MEAS ══════════════
    RAISE NOTICE 'fixture 269 · MEAS';
    v_m := pg_temp.f269_get(u_vw, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, s1, D0, D1));
    IF ((v_m ->> 'receipts')::int <> 3 OR (v_m ->> 'receipts_without_po_line')::int <> 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 MEAS: 3 receipts in the window, 1 without a PO line (the one outside the window does not count), got %', v_m; END IF;
    IF ((v_m -> 'scored' -> 'short_lines') <> '{"count": 1, "compared": 1, "not_compared": 2}'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 MEAS: short — 1 line on the closed order, the open order''s line and the PO-less receipt not compared, got %', v_m -> 'scored' -> 'short_lines'; END IF;
    IF ((v_m -> 'scored' -> 'over_lines') <> '{"count": 1, "compared": 2, "not_compared": 1}'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 MEAS: over — 1 of 2 lines, the PO-less receipt not compared, got %', v_m -> 'scored' -> 'over_lines'; END IF;
    IF ((v_m -> 'scored' -> 'discharge_mismatches') <> '{"count": 1, "compared": 1, "not_compared": 2}'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 MEAS: discharge — can vs cannot is one mismatch; B2 has no judgement and B3 no line, got %', v_m -> 'scored' -> 'discharge_mismatches'; END IF;
    IF ((v_m -> 'scored' -> 'ncr_open' ->> 'count')::int <> 1 OR (v_m -> 'scored' -> 'ncr_reject' ->> 'count')::int <> 1
        OR (v_m -> 'scored' -> 'ncr_accept' ->> 'count')::int <> 0 OR (v_m -> 'scored' -> 'ncr_rework' ->> 'count')::int <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 MEAS: NCRs by disposition — 1 open, 1 rejected (the one outside the window does not count), got %', v_m -> 'scored'; END IF;
    IF ((v_m -> 'scored' -> 'disputes' ->> 'count')::int <> 1 OR (v_m -> 'shown' -> 'disputes_withdrawn' ->> 'count')::int <> 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 MEAS: one open dispute scored, the withdrawn one shown only, got %', v_m; END IF;
    IF ((v_m -> 'scored' -> 'certificate_lapse_days') <> '{"count": 21, "compared": 1, "not_compared": 0}'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 MEAS: the Basel certificate is valid 1–10 July, so 21 of 31 days lapse, got %', v_m -> 'scored' -> 'certificate_lapse_days'; END IF;
    -- 一家只有窗口外收货的:窗口内一张都没有
    v_m2 := pg_temp.f269_get(u_vw, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, s1, D1 + 20, D1 + 25));
    IF ((v_m2 ->> 'receipts')::int <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 MEAS: the window bounds the receipts'; END IF;

    -- ══════════════ NOTCMP ══════════════
    RAISE NOTICE 'fixture 269 · NOTCMP';
    v_m2 := pg_temp.f269_get(u_vw, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, s2, D0, D1));
    IF (jsonb_typeof(v_m2 -> 'scored' -> 'short_lines' -> 'count') <> 'null' OR jsonb_typeof(v_m2 -> 'scored' -> 'over_lines' -> 'count') <> 'null'
        OR jsonb_typeof(v_m2 -> 'scored' -> 'discharge_mismatches' -> 'count') <> 'null'
        OR jsonb_typeof(v_m2 -> 'scored' -> 'certificate_lapse_days' -> 'count') <> 'null') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 NOTCMP: a comparison never made reads null ("not compared"), never 0, got %', v_m2 -> 'scored'; END IF;
    IF ((v_m2 -> 'scored' -> 'ncr_open' -> 'count') <> '0'::jsonb OR (v_m2 -> 'scored' -> 'disputes' -> 'count') <> '0'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 NOTCMP: counting NCRs and disputes is always a measurement — a real 0, got %', v_m2 -> 'scored'; END IF;

    -- ══════════════ BREACH ══════════════
    RAISE NOTICE 'fixture 269 · BREACH';
    IF ((v_m -> 'shown' -> 'grade_breaches') <> '{"count": 0, "scored": false, "caveat": "CONTRACT-1"}'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 BREACH: before the breach, shown with count 0, scored false, caveat CONTRACT-1, got %', v_m -> 'shown'; END IF;
    -- 一份买方合同,Ni 下限 18;A 单挂上去;B1 上一份化验 Ni 12 → 一条超标
    PERFORM pg_temp.f269_as(u_all);
    INSERT INTO contracts (supplier_id, kind, title, effective_from, effective_to, status, currency)
    VALUES (s1, 'supply', 'fixture 269 supply', D0 - 30, D1 + 300, 'active', v_base) RETURNING id INTO v_con;
    INSERT INTO contract_grade_specs (contract_id, metal, min_pct) VALUES (v_con, 'ni', 18);
    PERFORM link_document_to_contract('purchase_order', po_a, v_con);
    INSERT INTO assay_results (code, inbound_batch_id, assay_date, is_final, weight_basis, result_party)
    VALUES ('FX269-A-BR', b1, D0 + 13, true, 'dry', 'ours') RETURNING id INTO a_br;
    INSERT INTO assay_result_metals (assay_result_id, metal, content_pct) VALUES (a_br, 'ni', 12);
    PERFORM pg_temp.f269_as(NULL);
    v_m2 := pg_temp.f269_get(u_vw, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, s1, D0, D1));
    IF ((v_m2 -> 'shown' -> 'grade_breaches') <> '{"count": 1, "scored": false, "caveat": "CONTRACT-1"}'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 BREACH: the breach is shown (count 1, not scored, CONTRACT-1), got %', v_m2 -> 'shown'; END IF;
    IF ((v_m2 -> 'scored') <> (v_m -> 'scored')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 BREACH: a breach changes nothing that is scored'; END IF;
    v_msg := pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":null}]', NULL, NULL)$q$,
                                         pg_temp.f269_weights('{"grade_breaches": 1}')));
    PERFORM pg_temp.f269_expect('BREACH', v_msg, 'SCORE_WEIGHT_UNKNOWN|grade_breaches');
    v_m := v_m2;   -- 从这里起的计数含那一条超标(只显示)

    -- ══════════════ WINDOW ══════════════
    RAISE NOTICE 'fixture 269 · WINDOW';
    PERFORM pg_temp.f269_expect('WINDOW', pg_temp.f269_do(u_vw, format($q$SELECT supplier_scorecard_measures(%L, NULL, %L)$q$, s1, D1)), 'SCORECARD_WINDOW_REQUIRED');
    PERFORM pg_temp.f269_expect('WINDOW', pg_temp.f269_do(u_vw, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, s1, D1, D0)), 'SCORECARD_WINDOW_INVALID|%');
    PERFORM pg_temp.f269_expect('WINDOW', pg_temp.f269_do(u_vw, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, s1, D0, CURRENT_DATE + 30)), 'SCORECARD_WINDOW_FUTURE|%');
    PERFORM pg_temp.f269_expect('WINDOW', pg_temp.f269_do(u_vw, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, gen_random_uuid(), D0, D1)), 'SUPPLIER_NOT_FOUND|%');
    PERFORM pg_temp.f269_expect('WINDOW', pg_temp.f269_do(u_none, format($q$SELECT supplier_scorecard_measures(%L, %L, %L)$q$, s1, D0, D1)), 'PERMISSION_DENIED|module.suppliers.view');
    PERFORM pg_temp.f269_expect('WINDOW', pg_temp.f269_do(u_none, format($q$SELECT supplier_scorecard_preview(%L, %L, %L)$q$, s1, D0, D1)), 'PERMISSION_DENIED|module.suppliers.view');

    -- ══════════════ GATE ══════════════
    RAISE NOTICE 'fixture 269 · GATE';
    PERFORM pg_temp.f269_expect('GATE', pg_temp.f269_do(u_vw, format($q$SELECT record_supplier_review(%L, %L, %L)$q$, s1, D0, D1)), 'PERMISSION_DENIED|action.supplier_review');
    PERFORM pg_temp.f269_expect('GATE', pg_temp.f269_do(u_vw, $q$SELECT set_supplier_score_settings(NULL, NULL, 30, NULL)$q$), 'PERMISSION_DENIED|action.supplier_review');
    PERFORM pg_temp.f269_expect('GATE', pg_temp.f269_do(u_vw, format($q$SELECT supplier_grade_advice(%L)$q$, s1)), 'OK');
    PERFORM pg_temp.f269_expect('GATE', pg_temp.f269_do(u_none, format($q$SELECT supplier_grade_advice(%L)$q$, s1)), 'PERMISSION_DENIED|module.suppliers.view');
    PERFORM pg_temp.f269_expect('GATE', pg_temp.f269_do(u_rev, format($q$INSERT INTO supplier_scorecard_reviews (supplier_id, window_from, window_to, measures, not_graded_reason) VALUES (%L, %L, %L, '{}', 'V23_NOT_SET')$q$, s1, D0, D1)), '%row-level security%');
    IF (EXISTS (SELECT 1 FROM role_permissions rp JOIN permissions p ON p.code = rp.permission_code
                 WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
                   AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any)))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 GATE: an action code is held without its declared view (action implies view)'; END IF;

    -- ══════════════ NOTGR ══════════════
    RAISE NOTICE 'fixture 269 · NOTGR';
    v_r := pg_temp.f269_get(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, 'f269 first look')$q$, s1, D0, D1));
    rv1 := (v_r ->> 'review_id')::uuid;
    IF (v_r ->> 'not_graded_reason' <> 'V23_NOT_SET' OR jsonb_typeof(v_r -> 'grade') <> 'null') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 NOTGR: with V23 unset the review reads "Not graded — V23 not set", got %', v_r; END IF;
    IF ((SELECT grade IS NULL AND score IS NULL AND weights IS NULL AND grade_lines IS NULL AND grade_caps IS NULL AND not_graded_reason = 'V23_NOT_SET'
                AND measures = v_m AND note = 'f269 first look' AND recorded_by = u_rev
           FROM supplier_scorecard_reviews WHERE id = rv1)) IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 269 NOTGR: the review copies the measures as they were and nothing it was not given'; END IF;
    v_j := pg_temp.f269_get(u_vw, format($q$SELECT supplier_grade_advice(%L, '[{"trigger_event":"on_order","percentage":90}]', 1000)$q$, s1));
    IF ((v_j ->> 'reviewed')::boolean IS NOT TRUE OR (v_j ->> 'graded')::boolean IS NOT FALSE OR jsonb_array_length(v_j -> 'warnings') <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 NOTGR: an ungraded review has no effect — reviewed, not graded, no warning, got %', v_j; END IF;

    -- ══════════════ V23 ══════════════
    RAISE NOTICE 'fixture 269 · V23';
    v_n := pg_temp.f269_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V23'$q$)::bigint;
    IF (v_n <> 1) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 V23: with the settings empty, V23 is one row (got %)', v_n; END IF;
    v_n := pg_temp.f269_get(u_none, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V23', 'V24')$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 V23: V23 / V24 are behind module.suppliers.view (got %)', v_n; END IF;
    v_n := pg_temp.f269_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V24'$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 V24: no grade lines → no grades → no V24 row (got %)', v_n; END IF;
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, NULL, NULL, NULL)$q$, pg_temp.f269_weights())), 'SCORE_WEIGHTS_AND_LINES_TOGETHER');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":null}]', NULL, NULL)$q$, pg_temp.f269_weights() - 'disputes')), 'SCORE_WEIGHT_MISSING|disputes');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":null}]', NULL, NULL)$q$, pg_temp.f269_weights('{"bribes": 1}'))), 'SCORE_WEIGHT_UNKNOWN|bribes');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":null}]', NULL, NULL)$q$, pg_temp.f269_weights('{"over_lines": -1}'))), 'SCORE_WEIGHT_INVALID|over_lines');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":" ","max_score":null}]', NULL, NULL)$q$, pg_temp.f269_weights())), 'SCORE_GRADE_NAME_INVALID|1');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":5},{"grade":"A","max_score":null}]', NULL, NULL)$q$, pg_temp.f269_weights())), 'SCORE_GRADE_DUPLICATE|A');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":5},{"grade":"B","max_score":5},{"grade":"C","max_score":null}]', NULL, NULL)$q$, pg_temp.f269_weights())), 'SCORE_GRADE_LINE_INVALID|2');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":5},{"grade":"B","max_score":9}]', NULL, NULL)$q$, pg_temp.f269_weights())), 'SCORE_GRADE_LAST_LINE_OPEN');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":null}]', 0, NULL)$q$, pg_temp.f269_weights())), 'SCORE_REVIEW_WINDOW_INVALID|0');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":null}]', NULL, '{"Z":{"prepayment_cap_pct":10}}')$q$, pg_temp.f269_weights())), 'SCORE_CAP_GRADE_UNKNOWN|Z');
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":null}]', NULL, '{"A":{"prepayment_cap_pct":150}}')$q$, pg_temp.f269_weights())), 'SCORE_CAP_PCT_INVALID|A');
    IF (EXISTS (SELECT 1 FROM supplier_score_settings WHERE weights IS NOT NULL OR grade_lines IS NOT NULL)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 V23: a refused setting wrote nothing'; END IF;
    -- 权重与线给了、周期还空着;A 两样都给了,B 只给了上限(没有抽样级别 —— V24 两样都要),C 两样都没给
    PERFORM pg_temp.f269_expect('V23', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":5},{"grade":"B","max_score":10},{"grade":"C","max_score":null}]', NULL, '{"A":{"prepayment_cap_pct":30,"sampling_level":"Every 10th bag"},"B":{"prepayment_cap_pct":20}}')$q$, pg_temp.f269_weights())), 'OK');
    v_n := pg_temp.f269_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code = 'V23'$q$)::bigint;
    IF (v_n <> 1) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 V23: the review window is still empty, so V23 is still one row (got %)', v_n; END IF;

    -- ══════════════ V24 ══════════════
    RAISE NOTICE 'fixture 269 · V24';
    v_j := pg_temp.f269_get(u_vw, $q$SELECT jsonb_agg(item_code ORDER BY item_code) FROM pending_values WHERE value_code = 'V24'$q$);
    IF (v_j <> '["B", "C"]'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 V24: one row per grade lacking a cap or a sampling level — B (a cap, no sampling level) and C (neither); A has both, got %', v_j; END IF;

    -- ══════════════ GRADED ══════════════
    RAISE NOTICE 'fixture 269 · GRADED';
    v_r := pg_temp.f269_get(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L)$q$, s1, D0, D1));
    rv_g := (v_r ->> 'review_id')::uuid;
    -- 分 = 3×短交 1 + 1×超交 1 + 2×开着的 1 + 5×拒收 1 + 2×争议 1 + 1×放电矛盾 1 + 0.1×断档 21 = 3+1+2+5+2+1+2.1 = 16.1 → C(B 的上限是 10)
    IF ((v_r ->> 'score')::numeric <> 16.1 OR v_r ->> 'grade' <> 'C') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 GRADED: score 16.1 → grade C, got %', v_r; END IF;
    IF ((SELECT weights = pg_temp.f269_weights() AND grade_lines = '[{"grade":"A","max_score":5},{"grade":"B","max_score":10},{"grade":"C","max_score":null}]'::jsonb
                AND grade_caps = '{"A":{"prepayment_cap_pct":30,"sampling_level":"Every 10th bag"},"B":{"prepayment_cap_pct":20,"sampling_level":null}}'::jsonb AND measures = v_m AND not_graded_reason IS NULL
           FROM supplier_scorecard_reviews WHERE id = rv_g)) IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 269 GRADED: the review copies the measures, the V23 weights and lines and the V24 caps in force'; END IF;
    -- 没比过的不计分:S2 一项都没比过的计数 → 分只来自真的 0
    v_p := pg_temp.f269_get(u_vw, format($q$SELECT supplier_scorecard_preview(%L, %L, %L)$q$, s2, D0, D1));
    IF ((v_p ->> 'score')::numeric <> 0 OR v_p ->> 'grade' <> 'A') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 GRADED: measures not compared add nothing — score 0, grade A, got %', v_p; END IF;
    -- 之后改设定:那一次评审一个字不动
    PERFORM pg_temp.f269_expect('GRADED', pg_temp.f269_do(u_rev, format($q$SELECT set_supplier_score_settings(%L, '[{"grade":"A","max_score":50},{"grade":"B","max_score":100},{"grade":"C","max_score":null}]', 90, '{"A":{"prepayment_cap_pct":30,"sampling_level":"Every 10th bag"},"B":{"prepayment_cap_pct":20,"sampling_level":"Every 5th bag"},"C":{"prepayment_cap_pct":0,"sampling_level":"Every bag"}}')$q$, pg_temp.f269_weights('{"short_lines": 9}'))), 'OK');
    IF ((SELECT grade = 'C' AND score = 16.1 AND weights = pg_temp.f269_weights() AND (grade_lines -> 0 ->> 'max_score')::numeric = 5
           FROM supplier_scorecard_reviews WHERE id = rv_g)) IS NOT TRUE THEN
        RAISE EXCEPTION 'FIXTURE 269 GRADED: changing the settings must not rewrite a past review'; END IF;
    v_n := pg_temp.f269_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM pending_values WHERE value_code IN ('V23', 'V24')$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 V23/V24: everything given → no row (got %)', v_n; END IF;

    -- ══════════════ CORR ══════════════
    RAISE NOTICE 'fixture 269 · CORR';
    PERFORM pg_temp.f269_expect('CORR', pg_temp.f269_do(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, NULL, %L)$q$, s1, D0, D1, rv_g)), 'SUPPLIER_REVIEW_CORRECTION_REASON_REQUIRED');
    PERFORM pg_temp.f269_expect('CORR', pg_temp.f269_do(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, NULL, NULL, 'why')$q$, s1, D0, D1)), 'SUPPLIER_REVIEW_REASON_WITHOUT_CORRECTION');
    PERFORM pg_temp.f269_expect('CORR', pg_temp.f269_do(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, NULL, %L, 'why')$q$, s2, D0, D1, rv_g)), 'SUPPLIER_REVIEW_OTHER_SUPPLIER');
    PERFORM pg_temp.f269_expect('CORR', pg_temp.f269_do(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, NULL, %L, 'why')$q$, s1, D0, D1, gen_random_uuid())), 'SUPPLIER_REVIEW_NOT_FOUND|%');
    v_r := pg_temp.f269_get(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, NULL, %L, 'Weights changed after the first review')$q$, s1, D0, D1, rv_g));
    rv2 := (v_r ->> 'review_id')::uuid;
    -- 新的权重:9×1 + 1 + 2 + 5 + 2 + 1 + 2.1 = 22.1 → A(A 的上限现在是 50)
    IF ((v_r ->> 'grade') <> 'A' OR (v_r ->> 'corrects_review_id')::uuid <> rv_g) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 CORR: the correcting review is graded under the settings now in force and cites the one it corrects, got %', v_r; END IF;
    IF ((SELECT correction_reason FROM supplier_scorecard_reviews WHERE id = rv2) <> 'Weights changed after the first review'
        OR (SELECT grade FROM supplier_scorecard_reviews WHERE id = rv_g) <> 'C') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 CORR: the reason is kept and the corrected review is unchanged'; END IF;
    IF ((SELECT id FROM supplier_latest_reviews WHERE supplier_id = s1) <> rv2) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 CORR: the latest review that has not been superseded is the correction'; END IF;
    PERFORM pg_temp.f269_expect('CORR', pg_temp.f269_do(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, NULL, %L, 'again')$q$, s1, D0, D1, rv_g)), 'SUPPLIER_REVIEW_ALREADY_CORRECTED|%');
    v_msg := NULL; BEGIN UPDATE supplier_scorecard_reviews SET note = 'x' WHERE id = rv2; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f269_expect('CORR', v_msg, 'SUPPLIER_REVIEW_IMMUTABLE|update');
    v_msg := NULL; BEGIN DELETE FROM supplier_scorecard_reviews WHERE id = rv1; EXCEPTION WHEN OTHERS THEN v_msg := SQLERRM; END;
    PERFORM pg_temp.f269_expect('CORR', v_msg, 'SUPPLIER_REVIEW_IMMUTABLE|delete');

    -- ══════════════ LATEST ══════════════
    RAISE NOTICE 'fixture 269 · LATEST';
    -- 同一笔事务里三次评审的 recorded_at 一模一样(now() 是事务开始的时刻)—— 排出先后的只能是 seq
    IF ((SELECT count(DISTINCT recorded_at) FROM supplier_scorecard_reviews WHERE supplier_id = s1) <> 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 LATEST: the precondition is that the reviews share one recorded_at'; END IF;
    IF ((SELECT seq FROM supplier_scorecard_reviews WHERE id = rv2) <= (SELECT seq FROM supplier_scorecard_reviews WHERE id = rv_g)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 LATEST: seq records the order'; END IF;
    v_r := pg_temp.f269_get(u_rev, format($q$SELECT record_supplier_review(%L, %L, %L, 'a later look')$q$, s1, D0, D1));
    rv3 := (v_r ->> 'review_id')::uuid;
    IF ((SELECT id FROM supplier_latest_reviews WHERE supplier_id = s1) <> rv3) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 LATEST: the newest review (by seq) that has not been superseded is the one PO effects read'; END IF;

    -- ══════════════ PO ══════════════
    RAISE NOTICE 'fixture 269 · PO';
    -- 最近那一次(rv3)是 A:上限 30%,抽样 Every 10th bag
    PERFORM pg_temp.f269_as(u_all);
    v_po := create_purchase_order(s1, CURRENT_DATE, CURRENT_DATE + 30, v_base, NULL, NULL, NULL, 'f269 50 pct on order',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg', 'estimated_unit_price', 10)),
        '[{"seq":1,"label":"Deposit","percentage":50,"trigger_event":"on_order"},{"seq":2,"label":"Balance","percentage":50,"trigger_event":"on_arrival"}]'::jsonb,
        p_category => 'equipment_goods');
    PERFORM pg_temp.f269_as(NULL);
    IF ((v_po -> 'warnings') <> jsonb_build_array(jsonb_build_object('code', 'PREPAYMENT_ABOVE_GRADE_CAP', 'grade', 'A', 'cap_pct', 30, 'on_order_pct', 50.00, 'review_id', rv3))) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 PO: 50%% on order against grade A''s 30%% cap is one warning, got %', v_po -> 'warnings'; END IF;
    IF (NOT EXISTS (SELECT 1 FROM purchase_orders WHERE id = (v_po ->> 'purchase_order_id')::uuid)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 PO: a warning never refuses — the order exists'; END IF;
    v_j := pg_temp.f269_get(u_vw, format($q$SELECT supplier_grade_advice(%L, '[{"seq":1,"label":"Deposit","percentage":50,"trigger_event":"on_order"}]', 1000)$q$, s1));
    IF ((v_j -> 'warnings') <> (v_po -> 'warnings')) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 PO: the form''s preview says what creating the order says (one implementation), got % vs %', v_j -> 'warnings', v_po -> 'warnings'; END IF;
    PERFORM pg_temp.f269_as(u_all);
    v_po := create_purchase_order(s1, CURRENT_DATE, CURRENT_DATE + 30, v_base, NULL, NULL, NULL, 'f269 20 pct on order',
        jsonb_build_array(jsonb_build_object('material_id', v_mat, 'quantity', 100, 'unit', 'kg', 'estimated_unit_price', 10)),
        '[{"seq":1,"label":"Deposit","percentage":20,"trigger_event":"on_order"}]'::jsonb, p_category => 'equipment_goods');
    PERFORM pg_temp.f269_as(NULL);
    IF ((v_po -> 'warnings') <> '[]'::jsonb) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 PO: 20%% is within the cap — no warning, got %', v_po -> 'warnings'; END IF;
    -- 定额也折成百分比:预估总额 1,000 里下单时付 400 = 40% > 30%
    v_j := pg_temp.f269_get(u_vw, format($q$SELECT supplier_grade_advice(%L, '[{"trigger_event":"on_order","fixed_amount_ccy":400}]', 1000)$q$, s1));
    IF ((v_j ->> 'on_order_pct')::numeric <> 40 OR jsonb_array_length(v_j -> 'warnings') <> 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 PO: a fixed on-order amount is a share of the estimated total (400 of 1,000 = 40%%), got %', v_j; END IF;
    v_j := pg_temp.f269_get(u_vw, format($q$SELECT supplier_grade_advice(%L, '[{"trigger_event":"on_order","fixed_amount_ccy":400}]', 0)$q$, s1));
    IF ((v_j ->> 'on_order_not_computable')::boolean IS NOT TRUE OR jsonb_typeof(v_j -> 'on_order_pct') <> 'null' OR jsonb_array_length(v_j -> 'warnings') <> 0) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 PO: with no estimated total a fixed amount is not a percentage — not computable, no warning, nothing guessed, got %', v_j; END IF;

    -- ══════════════ SAMPLE ══════════════
    RAISE NOTICE 'fixture 269 · SAMPLE';
    SELECT count(*) INTO v_req_before FROM material_required_metals;
    v_j := pg_temp.f269_get(u_vw, format($q$SELECT supplier_grade_advice(%L)$q$, s1));
    IF (v_j ->> 'sampling_level' <> 'Every 10th bag' OR v_j ->> 'grade' <> 'A') IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 SAMPLE: the sampling advice is the level copied onto the latest review, got %', v_j; END IF;
    IF ((SELECT count(*) FROM material_required_metals) <> v_req_before
        OR EXISTS (SELECT 1 FROM material_required_metals WHERE material_id = v_mat)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 SAMPLE: a sampling level adds no required assay'; END IF;

    -- ══════════════ DUE ══════════════
    RAISE NOTICE 'fixture 269 · DUE';
    UPDATE supplier_score_settings SET review_window_days = NULL;
    v_n := pg_temp.f269_get(u_rev, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'supplier_review_due'$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 DUE: with no review window set the arm is silent (Q27), got %', v_n; END IF;
    UPDATE supplier_score_settings SET review_window_days = 90;
    -- S4:一次 120 天之前的评审(直写 —— 函数只记"现在")
    INSERT INTO supplier_scorecard_reviews (supplier_id, window_from, window_to, measures, not_graded_reason, recorded_at)
    VALUES (s4, D0, D1, '{}'::jsonb, 'V23_NOT_SET', now() - interval '120 days');
    v_j := pg_temp.f269_get(u_rev, $q$SELECT jsonb_agg(jsonb_build_object('code', item_code, 'kind', doc_kind) ORDER BY item_code) FROM operations_now WHERE item_type = 'supplier_review_due' AND item_code LIKE 'FX269-%'$q$);
    IF (v_j <> '[{"code": "FX269-S2", "kind": "never_reviewed"}, {"code": "FX269-S3", "kind": "never_reviewed"}, {"code": "FX269-S4", "kind": "due"}]'::jsonb) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 DUE: S2 and S3 never reviewed, S4 reviewed 120 days ago; S1 just reviewed, the draft and the forwarder not listed, got %', v_j; END IF;
    v_n := pg_temp.f269_get(u_vw, $q$SELECT to_jsonb(count(*)) FROM operations_now WHERE item_type = 'supplier_review_due'$q$)::bigint;
    IF (v_n <> 0) IS NOT FALSE THEN RAISE EXCEPTION 'FIXTURE 269 DUE: the reminder is for whoever records reviews (action.supplier_review), got %', v_n; END IF;

    -- ══════════════ F17 ══════════════
    RAISE NOTICE 'fixture 269 · F17';
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES ('FX269-BCOD', v_mat, s2, 10, 0, 'kg', D1 + 40, 'other', 'fixture 269 自带数据') RETURNING id INTO v_ib_cod;
    INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at)
    VALUES (v_ib_cod, D0, 'issued', 'FX269-COD', gen_random_uuid(), '{}'::jsonb, now()) RETURNING id INTO v_cod;
    PERFORM pg_temp.f269_expect('F17', pg_temp.f269_do(u_all, format($q$SELECT record_cod_issue(%L, 'cod/%s/x.pdf', %L)$q$, v_cod, v_cod, repeat('A', 64))), 'COD_ISSUE_PATH_INVALID|FX269-COD');
    PERFORM pg_temp.f269_expect('F17', pg_temp.f269_do(u_all, format($q$SELECT record_cod_issue(%L, '%s/y.pdf', %L)$q$, gen_random_uuid(), v_cod, repeat('a', 64))), 'COD_NOT_FOUND|%');
    PERFORM pg_temp.f269_expect('F17', pg_temp.f269_do(u_all, format($q$SELECT record_cod_issue(%L, '%s/x.pdf', %L)$q$, v_cod, v_cod, repeat('AB', 32))), 'OK');
    IF ((SELECT sha256 FROM cod_issues WHERE cod_id = v_cod) <> repeat('ab', 32)) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 F17: an upper-case digest is stored lower-case'; END IF;
    PERFORM pg_temp.f269_expect('F17', pg_temp.f269_do(u_all, format($q$SELECT record_cod_issue(%L, '%s/z.pdf', %L)$q$, v_cod, v_cod, repeat('c', 64))), 'COD_BYTES_ALREADY_RECORDED|FX269-COD');
    IF ((SELECT count(*) FROM cod_issues WHERE cod_id = v_cod) <> 1) IS NOT FALSE THEN
        RAISE EXCEPTION 'FIXTURE 269 F17: one set of bytes per certificate'; END IF;

    RAISE NOTICE 'FIXTURE 269 全部通过: REG · MEAS · NOTCMP · BREACH · WINDOW · GATE · NOTGR · V23 · V24 · GRADED · CORR · LATEST · PO · SAMPLE · DUE · F17';
END
$$;

ROLLBACK;

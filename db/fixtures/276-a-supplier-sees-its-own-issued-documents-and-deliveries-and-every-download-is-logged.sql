-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 276 —— 一个供应商门户账号只看得见自己那一家的签发档(只以存下的 PDF)与收货 / 地磅单(没有一个价钱);
--   每一次取档都先写一行下载记录,存储只放行刚记过的那一个对象(MES-9b,2026-10-19;MES-9 Step 0 Q14 · Q15 · Q22 · §3 · Q27,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   DOCS     portal_documents:A 只见 A 的采购单(签发过的、批了没签发的、取消了的)· 对账单(最新的、被取代的、没有存档的)·
--            销毁证书(签发的、作废的、没签发的);草稿 / 待批 / 软删的单不出现;没签发的回 issues = [];作废的 issue = null;
--            B 的一个号都没有;一个价钱都没有(单头估计额、对账单金额、单价的那几个数一个字都不出现)
--   DELIV    portal_deliveries:A 的收货(单号 · 到货日 · 物料 · 数量 · 单位 · 采购单号)与记在上面的地磅单;一张两家共用的地磅单只回分给 A 的那一份;
--            没有单价、计价状态、备注、车牌;软删的收货不出现;作废的地磅单标 voided
--   OPEN     portal_document_open:三种签发档各取一份 → 回桶 · 路径 · 哈希 · 文件名,写一行下载记录;B 的 → PORTAL_DOCUMENT_NOT_FOUND
--            (与不存在的同一句);作废的证书 → PORTAL_DOCUMENT_VOID;软删的采购单 → NOT_FOUND;种类不认识 → KIND_UNKNOWN;被取代的对账单照样取得到
--   STORE    storage.objects 上门户那条策略(真的 RLS,门户角色):只看得见【两分钟内刚记过】的那一个自己的对象;没记过的、记过但过了两分钟的、
--            B 的 → 看不见;写 / 改 / 删 storage.objects 一律 42501;员工会话不受这条策略影响
--   LOG      下载记录:只经那支函数写(员工与门户会话直接写 → 42501);改 / 删 / 清空 → PORTAL_DOWNLOAD_LOG_APPEND_ONLY;
--            员工 module.suppliers.view 读得到、没有码的读 0 行、门户会话直接读 → 42501
--   EXCL     变更记录的豁免是 10(第九张是 portal_document_downloads,理由写着 Q22;第十张 saved_views 是 TABLE-FEATURES-3),零缺口;它一行变更记录都不写
--   EVERY    supplier_portal 能执行的【每一支】public 函数(从目录里枚举):MES-9b 的四支在这里各有两家供应商的用例,MES-9a 的两支在 fixture 275,
--            MES-9c 的五支在 fixture 277(按名交过去,名单与目录对不上也红);
--            两支 fixture 合起来必须正好覆盖目录,多一支没有用例就红。每一支:A 只见 A、B 只见 B;员工会话 42501;令牌声明不对 / 会话结束 /
--            不是门户账号 / 被封 → 各自按名拒(portal_can_read_object 是 RLS 判据,绝不抛 —— 那几种一律回 false)
--   WRITES   门户会话跑遍四支函数之后:变更记录里没有一行出自 supplier_portal,唯一多出来的行在下载记录里(每一次取档一行);
--            它对任何 public 关系都没有写权限,对 storage.objects 只有 SELECT(与 MES-9c 起的 INSERT,行由 277 的那条策略筛)
--   GRANTS   四支只授 supplier_portal(authenticated · anon 调不到);基线里的 storage 授权在(USAGE · SELECT)
-- 前提:db/platform-prelude.sql 建了 supplier_portal 与 auth.sessions;db/gate.py 在 fixture 之前装好了 storage 桩与 db/storage/buckets-and-policies.sql。
--   自带数据(README 第 2 条)。注入(故障注入的记录在 docs/handbacks/MES-9b.md):db/scripts/2026-10-19-mes9b-fixture-injections.py。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f276_claims(p_user uuid, p_role text, p_sid uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN ''
                           ELSE jsonb_build_object('sub', p_user, 'role', p_role, 'session_id', p_sid)::text END, true)
$f$;

-- 以 (账号, 数据库角色, 令牌里的 role 声明, 会话) 跑一句,回结果的文字;出错回 'ERR|<sqlstate>|<消息>'
CREATE FUNCTION pg_temp.f276_call(p_user uuid, p_dbrole text, p_claim text, p_sid uuid, p_sql text) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v text;
BEGIN
    PERFORM pg_temp.f276_claims(p_user, p_claim, p_sid);
    EXECUTE format('SET LOCAL ROLE %I', p_dbrole);
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f276_claims(NULL, NULL, NULL);
    RETURN COALESCE(v, '<null>');
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f276_claims(NULL, NULL, NULL);
    RETURN 'ERR|' || SQLSTATE || '|' || SQLERRM;
END;
$f$;

CREATE FUNCTION pg_temp.f276_who(p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE r uuid; u uuid := gen_random_uuid();
BEGIN
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx276-' || left(u::text, 8), 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT DISTINCT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

-- 一家供应商的全套:采购单(签发两版 · 批了没签发 · 草稿 · 待批 · 取消了签发过 · 软删签发过)· 对账单(最新带档 · 被取代带档 · 没有档)·
--   收货(带价、带备注 · 软删)· 销毁证书(签发带档 · 作废带档 · 没签发)· 地磅单(只分给自己 · 作废)。回一份 id 的清单。
CREATE FUNCTION pg_temp.f276_supplier(p_tag text, p_sup uuid, p_mat uuid, p_base text) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE
    po1 uuid; po2 uuid; po3 uuid; po4 uuid; po5 uuid; po6 uuid; po7 uuid;
    st1 uuid; st2 uuid; st3 uuid; b1 uuid; b2 uuid; b3 uuid; c1 uuid; c2 uuid; c3 uuid; t1 uuid; t2 uuid;
    i_po1v1 uuid; i_po1v2 uuid; i_po5 uuid; i_po6 uuid; i_st1 uuid; i_st2 uuid; i_c1 uuid; i_c2 uuid;
    k text := 'FX276-' || p_tag;
BEGIN
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category, estimated_total_ccy) VALUES
        (k || '-PO1', p_sup, DATE '2026-09-01', p_base, 1, 'confirmed', 'approved', 'equipment_goods', 987654.32) RETURNING id INTO po1;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category, estimated_total_ccy) VALUES
        (k || '-PO2', p_sup, DATE '2026-09-02', p_base, 1, 'confirmed', 'approved', 'equipment_goods', 987654.32) RETURNING id INTO po2;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category) VALUES
        (k || '-PO3', p_sup, DATE '2026-09-03', p_base, 1, 'draft', 'approved', 'equipment_goods') RETURNING id INTO po3;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category) VALUES
        (k || '-PO4', p_sup, DATE '2026-09-04', p_base, 1, 'confirmed', 'pending', 'equipment_goods') RETURNING id INTO po4;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category, cancelled_at, cancel_reason) VALUES
        (k || '-PO5', p_sup, DATE '2026-09-05', p_base, 1, 'cancelled', 'approved', 'equipment_goods', now(), 'f276') RETURNING id INTO po5;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category, deleted_at, delete_reason) VALUES
        (k || '-PO6', p_sup, DATE '2026-09-06', p_base, 1, 'confirmed', 'approved', 'equipment_goods', now(), 'f276') RETURNING id INTO po6;
    INSERT INTO purchase_orders (code, supplier_id, order_date, currency, fx_rate, status, approval_status, category) VALUES
        (k || '-PO7', p_sup, DATE '2026-09-07', p_base, 1, 'confirmed', 'rejected', 'equipment_goods') RETURNING id INTO po7;
    INSERT INTO po_issues (purchase_order_id, version, file_path, sha256) VALUES (po1, 1, po1 || '/v1.pdf', repeat('1', 64)) RETURNING id INTO i_po1v1;
    INSERT INTO po_issues (purchase_order_id, version, file_path, sha256) VALUES (po1, 2, po1 || '/v2.pdf', repeat('2', 64)) RETURNING id INTO i_po1v2;
    INSERT INTO po_issues (purchase_order_id, version, file_path, sha256) VALUES (po5, 1, po5 || '/v1.pdf', repeat('5', 64)) RETURNING id INTO i_po5;
    INSERT INTO po_issues (purchase_order_id, version, file_path, sha256) VALUES (po6, 1, po6 || '/v1.pdf', repeat('6', 64)) RETURNING id INTO i_po6;

    INSERT INTO supplier_statements (code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency,
                                     opening_base, charges_base, credits_base, payments_base, prepayments_base, closing_base,
                                     list_base, on_account_base, residue_base, lines, open_items, on_account, unpriced, by_currency)
    VALUES (k || '-ST2', p_sup, k, k, '{"legal_name":"fixture 276 co"}', DATE '2026-09-01', DATE '2026-09-30', p_base,
            4242.42, 0, 0, 0, 0, 4242.42, 4242.42, 0, 0, '[]', '[]', '[]', '[]', '[]') RETURNING id INTO st2;
    INSERT INTO supplier_statements (code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency,
                                     opening_base, charges_base, credits_base, payments_base, prepayments_base, closing_base,
                                     list_base, on_account_base, residue_base, lines, open_items, on_account, unpriced, by_currency,
                                     superseded_at, superseded_by, superseded_reason)
    VALUES (k || '-ST1', p_sup, k, k, '{"legal_name":"fixture 276 co"}', DATE '2026-09-01', DATE '2026-09-30', p_base,
            4242.42, 0, 0, 0, 0, 4242.42, 4242.42, 0, 0, '[]', '[]', '[]', '[]', '[]', now(), st2, 'f276') RETURNING id INTO st1;
    INSERT INTO supplier_statements (code, supplier_id, supplier_code, supplier_name, company, period_start, period_end, base_currency,
                                     opening_base, charges_base, credits_base, payments_base, prepayments_base, closing_base,
                                     list_base, on_account_base, residue_base, lines, open_items, on_account, unpriced, by_currency)
    VALUES (k || '-ST3', p_sup, k, k, '{"legal_name":"fixture 276 co"}', DATE '2026-08-01', DATE '2026-08-31', p_base,
            4242.42, 0, 0, 0, 0, 4242.42, 4242.42, 0, 0, '[]', '[]', '[]', '[]', '[]') RETURNING id INTO st3;
    INSERT INTO supplier_statement_issues (statement_id, version, file_path, sha256) VALUES (st1, 1, st1 || '/' || repeat('7', 64) || '.pdf', repeat('7', 64)) RETURNING id INTO i_st1;
    INSERT INTO supplier_statement_issues (statement_id, version, file_path, sha256) VALUES (st2, 1, st2 || '/' || repeat('8', 64) || '.pdf', repeat('8', 64)) RETURNING id INTO i_st2;

    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 unit_price, notes)
    VALUES (k || '-B1', p_mat, p_sup, 777, 777, 'kg', DATE '2026-09-10', 'other', 'fixture 276 自带数据', 999.99, 'FX276-INTERNAL-NOTE') RETURNING id INTO b1;
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note,
                                 deleted_at, deleted_by, delete_reason)
    VALUES (k || '-B2', p_mat, p_sup, 55, 55, 'kg', DATE '2026-09-11', 'other', 'fixture 276 自带数据', now(), gen_random_uuid(), 'f276') RETURNING id INTO b2;

    INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at)
    VALUES (b1, DATE '2026-09-12', 'issued', k || '-COD1', gen_random_uuid(), '{}', now()) RETURNING id INTO c1;
    INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on, status, code, verification_token, snapshot, issued_at,
                                             void_reason, voided_at, replaced_by_cod_id)
    VALUES (b1, DATE '2026-09-11', 'void', k || '-COD0', gen_random_uuid(), '{}', now(), 'f276 wrong weight', now(), c1) RETURNING id INTO c2;
    -- one live certificate per receipt (uq_cod_live_per_batch): the pending one is on a receipt of its own
    INSERT INTO inbound_batches (code, material_id, supplier_id, quantity, remaining_qty, unit, arrival_date, source_reason_code, source_reason_note)
    VALUES (k || '-B3', p_mat, p_sup, 33, 33, 'kg', DATE '2026-09-13', 'other', 'fixture 276 自带数据') RETURNING id INTO b3;
    INSERT INTO certificates_of_destruction (inbound_batch_id, completed_on, status) VALUES (b3, DATE '2026-09-13', 'pending') RETURNING id INTO c3;
    INSERT INTO cod_issues (cod_id, file_path, sha256) VALUES (c1, c1 || '/x.pdf', repeat('9', 64)) RETURNING id INTO i_c1;
    INSERT INTO cod_issues (cod_id, file_path, sha256) VALUES (c2, c2 || '/x.pdf', repeat('a', 64)) RETURNING id INTO i_c2;

    INSERT INTO weighbridge_tickets (code, direction, vehicle_reg, notes, completed_at) VALUES (k || '-WB1', 'inbound', 'FX276-VAN', 'FX276-TICKET-NOTE', now()) RETURNING id INTO t1;
    INSERT INTO weighbridge_tickets (code, direction, vehicle_reg, completed_at, voided_at, voided_by, void_reason)
    VALUES (k || '-WB2', 'inbound', 'FX276-VAN', now(), now(), gen_random_uuid(), 'f276') RETURNING id INTO t2;
    INSERT INTO weighbridge_ticket_shares (ticket_id, inbound_batch_id, kg) VALUES (t1, b1, 701), (t2, b1, 702);

    RETURN jsonb_build_object('po1', po1, 'i_po1v1', i_po1v1, 'i_po1v2', i_po1v2, 'i_po5', i_po5, 'i_po6', i_po6,
                              'i_st1', i_st1, 'i_st2', i_st2, 'i_c1', i_c1, 'i_c2', i_c2, 'b1', b1, 'c1', c1, 'st1', st1, 'st2', st2);
END;
$f$;

DO $f276$
DECLARE
    v_base text; v_mat uuid; s_a uuid; s_b uuid; c_a uuid; c_b uuid;
    u_a uuid := gen_random_uuid(); u_b uuid := gen_random_uuid(); u_x uuid := gen_random_uuid();
    sid_a uuid := gen_random_uuid(); sid_b uuid := gen_random_uuid(); sid_x uuid := gen_random_uuid();
    l_a uuid; l_b uuid; da jsonb; db jsonb; u_view uuid; u_none uuid; u_mgr uuid;
    t_shared uuid; v text; v_j jsonb; v_n bigint; v_n2 int; v_m bigint; v_log0 bigint; v_cl0 bigint; r record; v_fn text; v_other text;
    v_cases jsonb; v_275 text[] := ARRAY['portal_me()', 'portal_export_my_data()'];
    -- MES-9c(2026-10-20):这五支的两家供应商用例在 fixture 277 的 EVERY 臂;277 断言三支 fixture 合起来正好覆盖目录。
    v_277 text[] := ARRAY['portal_certificates()',
                          'portal_submission_begin(p_cert_type text, p_file_name text, p_file_type text, p_file_size bigint, p_cert_no text, p_valid_from date, p_valid_until date)',
                          'portal_submission_finish(p_submission_id uuid)', 'portal_submission_abandon(p_submission_id uuid)',
                          'portal_can_upload_object(p_bucket text, p_name text)'];
    v_k bigint := 0;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') OR to_regclass('auth.sessions') IS NULL
       OR to_regclass('storage.objects') IS NULL THEN
        RAISE EXCEPTION 'FIXTURE 276 SETUP: the prelude / storage stub did not create supplier_portal / auth.sessions / storage.objects on this rebuild';
    END IF;

    -- ── data of its own ─────────────────────────────────────────────────────
    SELECT code INTO v_base FROM currencies WHERE is_base;
    INSERT INTO materials (code, name, kind_code, may_be_processed, form_code, source_code)
    VALUES ('FX276-M', 'fixture 276 black mass', 'battery_material', true, 'black_mass', 'end_of_life') RETURNING id INTO v_mat;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('FX276-SA', 'fixture 276 supplier A', 'SG', 'active', 'goods_supplier') RETURNING id INTO s_a;
    INSERT INTO suppliers (code, legal_name, country, status, counterparty_type) VALUES ('FX276-SB', 'fixture 276 supplier B', 'SG', 'active', 'goods_supplier') RETURNING id INTO s_b;
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (s_a, 'Ada FX276', 'ada.fx276@a.test') RETURNING id INTO c_a;
    INSERT INTO counterparty_contacts (supplier_id, name, email) VALUES (s_b, 'Bea FX276', 'bea.fx276@b.test') RETURNING id INTO c_b;
    INSERT INTO auth.users (id, email, email_confirmed_at) VALUES (u_a, 'ada.fx276@a.test', now()), (u_b, 'bea.fx276@b.test', now()),
                                                                  (u_x, 'x.fx276@test.local', now());
    INSERT INTO auth.sessions (id, user_id) VALUES (sid_a, u_a), (sid_b, u_b), (sid_x, u_x);
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (u_a, s_a, c_a) RETURNING id INTO l_a;
    INSERT INTO supplier_portal_users (user_id, supplier_id, contact_id) VALUES (u_b, s_b, c_b) RETURNING id INTO l_b;
    da := pg_temp.f276_supplier('SA', s_a, v_mat, v_base);
    db := pg_temp.f276_supplier('SB', s_b, v_mat, v_base);
    -- one ticket shared between A's receipt and B's receipt: each must see only its own share
    INSERT INTO weighbridge_tickets (code, direction, vehicle_reg, completed_at) VALUES ('FX276-WB-SHARED', 'inbound', 'FX276-VAN', now()) RETURNING id INTO t_shared;
    INSERT INTO weighbridge_ticket_shares (ticket_id, inbound_batch_id, kg) VALUES (t_shared, (da ->> 'b1')::uuid, 311), (t_shared, (db ->> 'b1')::uuid, 422);
    -- the stored objects (the stub's storage.objects): one per issue
    INSERT INTO storage.objects (bucket_id, name)
    SELECT 'po-documents', file_path FROM po_issues WHERE purchase_order_id IN (SELECT id FROM purchase_orders WHERE code LIKE 'FX276-%')
    UNION ALL SELECT 'supplier-statement-documents', file_path FROM supplier_statement_issues WHERE statement_id IN (SELECT id FROM supplier_statements WHERE code LIKE 'FX276-%')
    UNION ALL SELECT 'cod-documents', file_path FROM cod_issues WHERE cod_id IN (SELECT c.id FROM certificates_of_destruction c JOIN inbound_batches b ON b.id = c.inbound_batch_id WHERE b.code LIKE 'FX276-%');
    u_view := pg_temp.f276_who(ARRAY['module.suppliers.view']);
    u_none := pg_temp.f276_who(ARRAY['module.finance.view', 'module.purchasing.view', 'module.inbound.view']);
    u_mgr  := pg_temp.f276_who(ARRAY(SELECT code FROM permissions));
    SELECT count(*) INTO v_log0 FROM portal_document_downloads;
    SELECT COALESCE(max(seq), 0) INTO v_cl0 FROM change_log;

    -- ── DOCS ───────────────────────────────────────────────────────────────
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, 'SELECT public.portal_documents()::text');
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 276 DOCS: %', v; END IF;
    v_j := v::jsonb;
    IF (SELECT string_agg(x ->> 'code', ',' ORDER BY x ->> 'code') FROM jsonb_array_elements(v_j -> 'purchase_orders') x) IS DISTINCT FROM 'FX276-SA-PO1,FX276-SA-PO2,FX276-SA-PO5' THEN
        RAISE EXCEPTION 'FIXTURE 276 DOCS: purchase orders listed → % (expected PO1 issued, PO2 approved-unissued, PO5 cancelled-issued; no draft, pending, rejected or deleted)', v_j -> 'purchase_orders'; END IF;
    IF (SELECT jsonb_array_length(x -> 'issues') FROM jsonb_array_elements(v_j -> 'purchase_orders') x WHERE x ->> 'code' = 'FX276-SA-PO2') <> 0
       OR (SELECT string_agg((i ->> 'version') || ':' || (i ->> 'current'), ',' ORDER BY i ->> 'version')
             FROM jsonb_array_elements(v_j -> 'purchase_orders') x, jsonb_array_elements(x -> 'issues') i WHERE x ->> 'code' = 'FX276-SA-PO1') IS DISTINCT FROM '1:false,2:true'
       OR (SELECT x ->> 'state' FROM jsonb_array_elements(v_j -> 'purchase_orders') x WHERE x ->> 'code' = 'FX276-SA-PO5') IS DISTINCT FROM 'cancelled' THEN
        RAISE EXCEPTION 'FIXTURE 276 DOCS: issue versions / states of the purchase orders → %', v_j -> 'purchase_orders'; END IF;
    IF (SELECT string_agg((x ->> 'code') || ':' || (x ->> 'state') || ':' || COALESCE(x ->> 'superseded_by_code', '-') || ':' || jsonb_array_length(x -> 'issues'),
                          ',' ORDER BY x ->> 'code') FROM jsonb_array_elements(v_j -> 'statements') x)
       IS DISTINCT FROM 'FX276-SA-ST1:superseded:FX276-SA-ST2:1,FX276-SA-ST2:current:-:1,FX276-SA-ST3:current:-:0' THEN
        RAISE EXCEPTION 'FIXTURE 276 DOCS: statements → %', v_j -> 'statements'; END IF;
    IF (SELECT string_agg(COALESCE(x ->> 'code', '<none>') || ':' || (x ->> 'state') || ':' || (x -> 'issue' IS NOT NULL AND jsonb_typeof(x -> 'issue') = 'object')::text
                          || ':' || COALESCE(x ->> 'replaced_by_code', '-'), ',' ORDER BY x ->> 'completed_on') FROM jsonb_array_elements(v_j -> 'cods') x)
       IS DISTINCT FROM 'FX276-SA-COD0:void:false:FX276-SA-COD1,FX276-SA-COD1:issued:true:-,<none>:pending:false:-' THEN
        RAISE EXCEPTION 'FIXTURE 276 DOCS: certificates → % (void: no document; pending: no number, no document)', v_j -> 'cods'; END IF;
    IF v ~ '(FX276-SB|supplier B|987654\.32|4242\.42|999\.99|estimated_total|amount|price|closing|opening|fx_rate|currency|notes|cancel_reason|void_reason|wrong weight)' THEN
        RAISE EXCEPTION 'FIXTURE 276 DOCS: A''s documents carry B''s data, a price or an internal note: %', left(v, 400); END IF;

    -- ── DELIV ──────────────────────────────────────────────────────────────
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, 'SELECT public.portal_deliveries()::text');
    IF v LIKE 'ERR|%' THEN RAISE EXCEPTION 'FIXTURE 276 DELIV: %', v; END IF;
    v_j := v::jsonb;
    IF (SELECT string_agg((x ->> 'code') || ':' || (x ->> 'quantity') || (x ->> 'unit') || ':' || (x ->> 'material') || ':' || (x ->> 'arrival_date'), ',' ORDER BY x ->> 'code')
          FROM jsonb_array_elements(v_j -> 'receipts') x)
       IS DISTINCT FROM 'FX276-SA-B1:777kg:fixture 276 black mass:2026-09-10,FX276-SA-B3:33kg:fixture 276 black mass:2026-09-13' THEN
        RAISE EXCEPTION 'FIXTURE 276 DELIV: receipts → % (the soft-deleted one must not appear)', v_j -> 'receipts'; END IF;
    IF (SELECT string_agg((x ->> 'code') || ':' || (x ->> 'voided') || ':' || (SELECT string_agg((s ->> 'receipt_code') || '=' || (s ->> 'kg'), ';') FROM jsonb_array_elements(x -> 'shares') s),
                          ',' ORDER BY x ->> 'code') FROM jsonb_array_elements(v_j -> 'tickets') x)
       IS DISTINCT FROM 'FX276-SA-WB1:false:FX276-SA-B1=701,FX276-SA-WB2:true:FX276-SA-B1=702,FX276-WB-SHARED:false:FX276-SA-B1=311' THEN
        RAISE EXCEPTION 'FIXTURE 276 DELIV: tickets → % (a shared ticket must carry only A''s share; a void one is marked)', v_j -> 'tickets'; END IF;
    IF v ~ '(FX276-SB|999\.99|unit_price|pricing|price|FX276-INTERNAL|FX276-TICKET-NOTE|FX276-VAN|vehicle|notes|stage|remaining)' THEN
        RAISE EXCEPTION 'FIXTURE 276 DELIV: A''s deliveries carry B''s data, a price, a plate or an internal note: %', left(v, 400); END IF;
    IF v_j ->> 'as_of' IS NULL THEN RAISE EXCEPTION 'FIXTURE 276 DELIV: no as_of moment ("as recorded today")'; END IF;

    -- ── OPEN ───────────────────────────────────────────────────────────────
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_document_open(''purchase_order'', %L)::text', da ->> 'i_po1v2'));
    IF v LIKE 'ERR|%' OR v::jsonb ->> 'bucket' <> 'po-documents' OR v::jsonb ->> 'file_path' <> (da ->> 'po1') || '/v2.pdf'
       OR v::jsonb ->> 'sha256' <> repeat('2', 64) OR v::jsonb ->> 'filename' <> 'FX276-SA-PO1-v2.pdf' THEN
        RAISE EXCEPTION 'FIXTURE 276 OPEN: purchase order v2 → %', v; END IF;
    IF NOT EXISTS (SELECT 1 FROM portal_document_downloads d WHERE d.id = (v::jsonb ->> 'log_id')::uuid AND d.portal_user_id = l_a AND d.user_id = u_a
                    AND d.supplier_id = s_a AND d.document_kind = 'purchase_order' AND d.issue_id = (da ->> 'i_po1v2')::uuid
                    AND d.document_code = 'FX276-SA-PO1' AND d.version = 2 AND d.sha256 = repeat('2', 64)) THEN
        RAISE EXCEPTION 'FIXTURE 276 OPEN: the download log row is missing or wrong'; END IF;
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_document_open(''supplier_statement'', %L)::text', da ->> 'i_st1'));
    IF v LIKE 'ERR|%' OR v::jsonb ->> 'filename' <> 'FX276-SA-ST1-v1.pdf' OR v::jsonb ->> 'bucket' <> 'supplier-statement-documents' THEN
        RAISE EXCEPTION 'FIXTURE 276 OPEN: a superseded statement''s stored PDF → %', v; END IF;
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_document_open(''cod'', %L)::text', da ->> 'i_c1'));
    IF v LIKE 'ERR|%' OR v::jsonb ->> 'filename' <> 'FX276-SA-COD1.pdf' OR v::jsonb ->> 'bucket' <> 'cod-documents' THEN
        RAISE EXCEPTION 'FIXTURE 276 OPEN: an issued certificate → %', v; END IF;
    IF (SELECT version FROM portal_document_downloads WHERE id = (v::jsonb ->> 'log_id')::uuid) IS NOT NULL THEN
        RAISE EXCEPTION 'FIXTURE 276 OPEN: a certificate''s log row carries a version'; END IF;
    FOREACH v_fn IN ARRAY ARRAY[format('purchase_order|%s', db ->> 'i_po1v2'), format('supplier_statement|%s', db ->> 'i_st2'),
                                format('cod|%s', db ->> 'i_c1'), format('purchase_order|%s', gen_random_uuid()),
                                format('purchase_order|%s', da ->> 'i_st2'), format('purchase_order|%s', da ->> 'i_po6')] LOOP
        v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
                               format('SELECT public.portal_document_open(%L, %L)::text', split_part(v_fn, '|', 1), split_part(v_fn, '|', 2)));
        IF v NOT LIKE 'ERR|%PORTAL_DOCUMENT_NOT_FOUND%' THEN
            RAISE EXCEPTION 'FIXTURE 276 OPEN: A opened % (B''s, missing, wrong kind or a deleted order) → %', v_fn, v; END IF;
    END LOOP;
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_document_open(''cod'', %L)::text', da ->> 'i_c2'));
    IF v NOT LIKE 'ERR|%PORTAL_DOCUMENT_VOID|FX276-SA-COD0%' THEN RAISE EXCEPTION 'FIXTURE 276 OPEN: a void certificate → %', v; END IF;
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, format('SELECT public.portal_document_open(''invoice'', %L)::text', da ->> 'i_po1v1'));
    IF v NOT LIKE 'ERR|%PORTAL_DOCUMENT_KIND_UNKNOWN|invoice%' THEN RAISE EXCEPTION 'FIXTURE 276 OPEN: an unknown kind → %', v; END IF;
    IF (SELECT count(*) FROM portal_document_downloads) - v_log0 <> 3 THEN
        RAISE EXCEPTION 'FIXTURE 276 OPEN: % log rows written (expected exactly the 3 successful opens — a refusal writes nothing)',
            (SELECT count(*) FROM portal_document_downloads) - v_log0; END IF;

    -- ── STORE ──────────────────────────────────────────────────────────────
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a,
        'SELECT string_agg(bucket_id || '':'' || name, '','' ORDER BY bucket_id, name) FROM storage.objects');
    IF v IS DISTINCT FROM format('cod-documents:%s/x.pdf,po-documents:%s/v2.pdf,supplier-statement-documents:%s/%s.pdf',
                                 da ->> 'c1', da ->> 'po1', da ->> 'st1', repeat('7', 64)) THEN
        RAISE EXCEPTION 'FIXTURE 276 STORE: A sees in storage → % (expected exactly the three objects it has just logged)', v; END IF;
    v := pg_temp.f276_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, 'SELECT count(*)::text FROM storage.objects');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 276 STORE: B, who logged nothing, sees % object(s)', v; END IF;
    -- a log row older than two minutes opens nothing
    INSERT INTO portal_document_downloads (portal_user_id, user_id, supplier_id, document_kind, issue_id, document_code, version, bucket_id, file_path, sha256, downloaded_at)
    VALUES (l_b, u_b, s_b, 'purchase_order', (db ->> 'i_po1v1')::uuid, 'FX276-SB-PO1', 1, 'po-documents', (db ->> 'po1') || '/v1.pdf', repeat('1', 64), now() - interval '3 minutes');
    v := pg_temp.f276_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, 'SELECT count(*)::text FROM storage.objects');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 276 STORE: a log row three minutes old still opened % object(s)', v; END IF;
    -- A's fresh log rows open nothing for B, and a revoked / ended session opens nothing for A
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', gen_random_uuid(), 'SELECT count(*)::text FROM storage.objects');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 276 STORE: an ended session still sees % object(s) (the predicate must not raise either)', v; END IF;
    FOREACH v_fn IN ARRAY ARRAY[
        'INSERT INTO storage.objects (bucket_id, name) VALUES (''po-documents'', ''fx276-upload.pdf'') RETURNING name',
        'UPDATE storage.objects SET name = name RETURNING name',
        'DELETE FROM storage.objects RETURNING name'] LOOP
        v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 276 STORE: a portal session wrote storage (%) → %', v_fn, v; END IF;
    END LOOP;
    -- the portal policy does not apply to a staff session (it is TO supplier_portal): a staff reader without module.purchasing.view sees no PO object
    v := pg_temp.f276_call(u_view, 'authenticated', 'authenticated', NULL, 'SELECT count(*)::text FROM storage.objects WHERE bucket_id = ''po-documents''');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 276 STORE: a suppliers viewer reads % PO object(s) through the portal policy', v; END IF;

    -- ── LOG ────────────────────────────────────────────────────────────────
    FOREACH v_other IN ARRAY ARRAY['authenticated', 'supplier_portal'] LOOP
        v := pg_temp.f276_call(CASE WHEN v_other = 'authenticated' THEN u_mgr ELSE u_a END, v_other, v_other, sid_a,
            format('INSERT INTO public.portal_document_downloads (portal_user_id, user_id, supplier_id, document_kind, issue_id, document_code, version, bucket_id, file_path, sha256) VALUES (%L, %L, %L, ''purchase_order'', %L, ''x'', 1, ''po-documents'', ''x'', %L) RETURNING id::text',
                   l_a, u_a, s_a, da ->> 'i_po1v1', repeat('1', 64)));
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 276 LOG: a direct insert by % → %', v_other, v; END IF;
    END LOOP;
    v := pg_temp.f276_call(u_a, 'supplier_portal', 'supplier_portal', sid_a, 'SELECT count(*)::text FROM public.portal_document_downloads');
    IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 276 LOG: a portal session reads the log table directly → %', v; END IF;
    v := pg_temp.f276_call(u_view, 'authenticated', 'authenticated', NULL,
        format('SELECT count(*)::text FROM public.portal_document_downloads WHERE supplier_id = %L', s_a));
    IF v <> '3' THEN RAISE EXCEPTION 'FIXTURE 276 LOG: a suppliers viewer reads % of A''s 3 log rows', v; END IF;
    v := pg_temp.f276_call(u_none, 'authenticated', 'authenticated', NULL, 'SELECT count(*)::text FROM public.portal_document_downloads');
    IF v <> '0' THEN RAISE EXCEPTION 'FIXTURE 276 LOG: a reader without module.suppliers.view reads % log row(s)', v; END IF;
    FOREACH v_fn IN ARRAY ARRAY['UPDATE portal_document_downloads SET document_code = ''x''', 'DELETE FROM portal_document_downloads',
                                'TRUNCATE portal_document_downloads'] LOOP
        BEGIN
            EXECUTE v_fn;
            RAISE EXCEPTION 'FIXTURE 276 LOG: % went through', v_fn;
        EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'PORTAL_DOWNLOAD_LOG_APPEND_ONLY|%' THEN RAISE; END IF; END;
    END LOOP;

    -- ── EXCL ───────────────────────────────────────────────────────────────
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 12 THEN
        RAISE EXCEPTION 'FIXTURE 276 EXCL: change-log coverage %', v_j; END IF;
    IF NOT EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = 'portal_document_downloads' AND x.reason LIKE '%Q22%append-only%') THEN
        RAISE EXCEPTION 'FIXTURE 276 EXCL: portal_document_downloads is not the ninth exclusion with its reason'; END IF;
    IF EXISTS (SELECT 1 FROM change_log WHERE table_name = 'portal_document_downloads') THEN
        RAISE EXCEPTION 'FIXTURE 276 EXCL: the download log wrote change-log rows'; END IF;

    -- ── EVERY ──────────────────────────────────────────────────────────────
    v_cases := jsonb_build_object(
        'portal_documents()', jsonb_build_array('SELECT public.portal_documents()::text', 'SELECT public.portal_documents()::text'),
        'portal_deliveries()', jsonb_build_array('SELECT public.portal_deliveries()::text', 'SELECT public.portal_deliveries()::text'),
        'portal_document_open(p_kind text, p_issue_id uuid)',
            jsonb_build_array(format('SELECT public.portal_document_open(''purchase_order'', %L)::text', da ->> 'i_po1v1'),
                              format('SELECT public.portal_document_open(''purchase_order'', %L)::text', db ->> 'i_po1v1')),
        'portal_can_read_object(p_bucket text, p_name text)',
            jsonb_build_array(format('SELECT public.portal_can_read_object(''po-documents'', %L)::text', (da ->> 'po1') || '/v2.pdf'),
                              format('SELECT public.portal_can_read_object(''po-documents'', %L)::text', (db ->> 'po1') || '/v1.pdf')));
    v_n := 0; v_m := 0;
    FOR r IN SELECT p.oid::regprocedure::text AS sig, p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS key
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE') ORDER BY 1 LOOP
        IF r.key = ANY (v_275) THEN v_m := v_m + 1; CONTINUE; END IF;
        IF r.key = ANY (v_277) THEN v_k := v_k + 1; CONTINUE; END IF;
        IF NOT v_cases ? r.key THEN
            RAISE EXCEPTION 'FIXTURE 276 EVERY: % is executable by supplier_portal and has no two-supplier case here or in fixture 275', r.sig; END IF;
        v_n := v_n + 1;
        -- A, then B; each sees its own, nothing of the other (A logged its v2 in OPEN; B logs its v1 here, its earlier row having expired)
        FOR k IN 0..1 LOOP
            v := pg_temp.f276_call(CASE k WHEN 0 THEN u_a ELSE u_b END, 'supplier_portal', 'supplier_portal', CASE k WHEN 0 THEN sid_a ELSE sid_b END,
                                   v_cases -> r.key ->> k);
            IF r.key LIKE 'portal_can_read_object%' THEN
                -- B logged its own v1 above only three minutes ago (expired): open it now so the predicate has a fresh row
                IF k = 0 AND v <> 'true' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % as A on its own logged object → %', r.sig, v; END IF;
                IF k = 1 THEN
                    IF v <> 'false' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % as B before it logged → %', r.sig, v; END IF;
                    PERFORM pg_temp.f276_call(u_b, 'supplier_portal', 'supplier_portal', sid_b,
                                              format('SELECT public.portal_document_open(''purchase_order'', %L)::text', db ->> 'i_po1v1'));
                    v := pg_temp.f276_call(u_b, 'supplier_portal', 'supplier_portal', sid_b, v_cases -> r.key ->> 1);
                    IF v <> 'true' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % as B on its own logged object → %', r.sig, v; END IF;
                END IF;
                -- the other's object is never readable, logged or not
                v := pg_temp.f276_call(CASE k WHEN 0 THEN u_a ELSE u_b END, 'supplier_portal', 'supplier_portal', CASE k WHEN 0 THEN sid_a ELSE sid_b END,
                                       v_cases -> r.key ->> (1 - k));
                IF v <> 'false' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % — % reads the other supplier''s object → %', r.sig, k, v; END IF;
            ELSE
                IF v LIKE 'ERR|%' OR v NOT LIKE (CASE k WHEN 0 THEN '%FX276-SA%' ELSE '%FX276-SB%' END)
                   OR v LIKE (CASE k WHEN 0 THEN '%FX276-SB%' ELSE '%FX276-SA%' END) THEN
                    RAISE EXCEPTION 'FIXTURE 276 EVERY: % as % → %', r.sig, CASE k WHEN 0 THEN 'A' ELSE 'B' END, left(v, 300); END IF;
                -- the other's case, called by this supplier
                IF r.key LIKE 'portal_document_open%' THEN
                    v := pg_temp.f276_call(CASE k WHEN 0 THEN u_a ELSE u_b END, 'supplier_portal', 'supplier_portal', CASE k WHEN 0 THEN sid_a ELSE sid_b END,
                                           v_cases -> r.key ->> (1 - k));
                    IF v NOT LIKE 'ERR|%PORTAL_DOCUMENT_NOT_FOUND%' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % — the other''s document → %', r.sig, v; END IF;
                END IF;
            END IF;
        END LOOP;
        -- refusals: a staff session · a staff code holder · a wrong claim · an ended session · no session · not a portal account · banned
        v_fn := v_cases -> r.key ->> 0;
        v := pg_temp.f276_call(u_a, 'authenticated', 'authenticated', sid_a, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % as authenticated — %', r.sig, left(v, 200); END IF;
        v := pg_temp.f276_call(u_mgr, 'authenticated', 'authenticated', NULL, v_fn);
        IF v NOT LIKE 'ERR|42501|%' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % as a staff code holder — %', r.sig, left(v, 200); END IF;
        FOR v_other, v_n2 IN SELECT * FROM (VALUES ('claim', 1), ('ended', 2), ('nosession', 3), ('notportal', 4), ('banned', 5)) t LOOP
            IF v_other = 'banned' THEN UPDATE auth.users SET banned_until = now() + interval '1 day' WHERE id = u_a; END IF;
            v := pg_temp.f276_call(CASE v_other WHEN 'notportal' THEN u_x ELSE u_a END, 'supplier_portal',
                                   CASE v_other WHEN 'claim' THEN 'authenticated' ELSE 'supplier_portal' END,
                                   CASE v_other WHEN 'ended' THEN gen_random_uuid() WHEN 'nosession' THEN NULL WHEN 'notportal' THEN sid_x ELSE sid_a END, v_fn);
            IF v_other = 'banned' THEN UPDATE auth.users SET banned_until = NULL WHERE id = u_a; END IF;
            IF r.key LIKE 'portal_can_read_object%' THEN
                IF v <> 'false' THEN RAISE EXCEPTION 'FIXTURE 276 EVERY: % (%) must answer false, never raise → %', r.sig, v_other, v; END IF;
            ELSIF v NOT LIKE '%' || (CASE v_other WHEN 'claim' THEN 'PORTAL_ROLE_REQUIRED' WHEN 'ended' THEN 'PORTAL_SESSION_ENDED'
                                                  WHEN 'nosession' THEN 'PORTAL_SESSION_ENDED' WHEN 'notportal' THEN 'PORTAL_NOT_A_PORTAL_ACCOUNT'
                                                  ELSE 'PORTAL_ACCESS_REVOKED' END) || '%' THEN
                RAISE EXCEPTION 'FIXTURE 276 EVERY: % (%) → %', r.sig, v_other, left(v, 200); END IF;
        END LOOP;
    END LOOP;
    IF v_k <> cardinality(v_277) THEN
        RAISE EXCEPTION 'FIXTURE 276 EVERY: % of the % MES-9c functions are executable by supplier_portal — the name list here is stale', v_k, cardinality(v_277); END IF;
    IF v_n <> 4 OR v_m <> cardinality(v_275) THEN
        RAISE EXCEPTION 'FIXTURE 276 EVERY: % MES-9b function(s) here (expected 4) and % MES-9a function(s) in fixture 275 (expected %) — the catalogue and the two fixtures disagree',
            v_n, v_m, cardinality(v_275); END IF;

    -- ── WRITES ─────────────────────────────────────────────────────────────
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > v_cl0 AND c.db_role = 'supplier_portal') THEN
        RAISE EXCEPTION 'FIXTURE 276 WRITES: a portal session wrote a change-logged row: %',
            (SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') FROM change_log c WHERE c.seq > v_cl0 AND c.db_role = 'supplier_portal'); END IF;
    SELECT string_agg(n.nspname || '.' || c.relname, ', ') INTO v FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('public', 'storage') AND c.relkind IN ('r', 'v', 'm', 'p')
       AND (has_table_privilege('supplier_portal', c.oid, 'UPDATE,DELETE,TRUNCATE')
            -- MES-9c(2026-10-20):storage.objects 的 INSERT 是门户交证书要的(行由 portal_can_upload_object 那条策略筛;fixture 277 STORE)
            OR (has_table_privilege('supplier_portal', c.oid, 'INSERT') AND (n.nspname, c.relname) <> ('storage', 'objects')));
    IF v IS NOT NULL THEN RAISE EXCEPTION 'FIXTURE 276 WRITES: supplier_portal can write %', v; END IF;
    SELECT string_agg(n.nspname || '.' || c.relname, ', ') INTO v FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname IN ('public', 'storage') AND c.relkind IN ('r', 'v', 'm', 'p') AND has_table_privilege('supplier_portal', c.oid, 'SELECT');
    IF v IS DISTINCT FROM 'storage.objects' THEN RAISE EXCEPTION 'FIXTURE 276 WRITES: supplier_portal reads relations %', v; END IF;

    -- ── GRANTS ─────────────────────────────────────────────────────────────
    FOREACH v IN ARRAY ARRAY['public.portal_documents()', 'public.portal_deliveries()', 'public.portal_document_open(text,uuid)',
                             'public.portal_can_read_object(text,text)'] LOOP
        IF NOT has_function_privilege('supplier_portal', v::regprocedure, 'EXECUTE')
           OR has_function_privilege('authenticated', v::regprocedure, 'EXECUTE')
           OR has_function_privilege('anon', v::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'FIXTURE 276 GRANTS: % must be executable by supplier_portal only', v; END IF;
    END LOOP;
    IF NOT has_schema_privilege('supplier_portal', 'storage', 'USAGE') OR has_schema_privilege('supplier_portal', 'storage', 'CREATE') THEN
        RAISE EXCEPTION 'FIXTURE 276 GRANTS: supplier_portal must hold USAGE (only) on schema storage'; END IF;
    -- MES-9c(2026-10-20):1 → 3(门户往 portal-uploads 传 / 读回它自己申请的那一条路径,fixture 277);MES-9b 的那一条按名在
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND 'supplier_portal' = ANY (roles)) <> 3
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = 'portal reads its own logged issued documents'
                       AND roles = ARRAY['supplier_portal']::name[] AND cmd = 'SELECT') THEN
        RAISE EXCEPTION 'FIXTURE 276 GRANTS: exactly three storage policies apply to supplier_portal, the MES-9b read among them'; END IF;

    RAISE NOTICE 'FIXTURE 276 全部通过: DOCS · DELIV · OPEN · STORE · LOG · EXCL · EVERY · WRITES · GRANTS';
END
$f276$;
ROLLBACK;

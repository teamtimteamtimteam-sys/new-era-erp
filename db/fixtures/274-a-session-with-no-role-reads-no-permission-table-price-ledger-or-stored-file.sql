-- ═══════════════════════════════════════════════════════════════════════════
-- fixture 274 —— 一个没有角色的会话读不到权限表、行情、科目表、催收承诺,也看不见任何一份存下的文件;
--   有码的人一样不少(NOROLE-SURFACE,2026-10-19;Step 0 Q1–Q10 · Q13 · Q20,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 臂:
--   REL      九个对象(user_roles · roles · role_permissions · permissions · metal_prices · metal_price_indices · pricing_settings ·
--            accounts · collection_promise_status)对 norole 与 display(只挂 floor_display)都是 0 行(user_roles:只有自己那一行);
--            谓词里的【每一个码】单独持有时读得到全部行(= postgres 读到的行数,每个对象自带至少一行);不在谓词里的码(module.tasks.view)读 0;
--            ★ Tim 2026-10-19(施工中的 Q21):权限四张表的谓词也认审计记录的读者 —— module.hr.view(员工页)· data.view_change_log(变更记录)
--   OWN      任何会话都读得到自己那几行 user_roles,也照旧经 current_user_permissions() / has_permission() 拿到自己的码 —— 哪怕它读不到 role_permissions
--   TRAIL    一个没有码的员工读不到 accounts,但它自己那张报销单的审计记录照旧说出那个科目的名字(trail_ref_label 经 SECURITY DEFINER 走到);
--            角色授予那一行:对只持 data.view_change_log 的读者在变更记录里不受限,对持 module.hr.view 的读者在员工页的审计记录里不受限
--   PROMISE  一条承诺:没有 module.finance.view 读 0,持它读 1
--   BUCKET   14 个桶的读 / 上传:每一个码单独持有放行,norole · display · 一个不相干的码被拒;company-assets 由 8 个 PDF 路由码【各自】读得到
--   NOUPDATE 四个附件桶的 UPDATE:连上传码都改不动一个文件(0 行)
--   DELETE   七个删孤儿的桶:上传码删得掉一个没有记录指着的文件;只读码删不掉;一个有记录指着的文件(customer_attachments)上传码也删不掉;
--            另 6 个文档桶与 company-assets 之外,没有一个桶对谁开着删;七条删除策略各自指着对的那张表、那一列
--   SHAPE    存储策略一共 56 条(MES-9b 起第 53 条是门户那一条,判据 portal_can_read_object;MES-9c 起第 54–56 条:门户传 / 读回自己
--            申请的那一条路径两条,判据 portal_can_upload_object,与员工读 portal-uploads 一条),没有一条不带判据;UPDATE 只剩 avatars 与 company-assets
--
-- 前提:db/gate.py 已把 db/storage/platform-storage-stub.sql 与 db/storage/buckets-and-policies.sql 装进了这个重建库
--   (没有 storage 架构 → 本 fixture 按名红,而不是空转)。自带数据(README 第 2 条);读者那几臂切成 authenticated + JWT。
-- 注入(故障注入的记录在 docs/handbacks/NOROLE-SURFACE.md):把任一对象的读策略放回 USING (true) → REL 那一臂红并点名它。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;
SET LOCAL statement_timeout = '300s';

CREATE FUNCTION pg_temp.f274_as(p_user uuid) RETURNS void
LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims',
                      CASE WHEN p_user IS NULL THEN '' ELSE format('{"sub":"%s","role":"authenticated"}', p_user) END, true)
$f$;

-- 以 p_user 跑一句,回【影响 / 读到的行数】;被拒(抛错)回 -1
CREATE FUNCTION pg_temp.f274_rc(p_user uuid, p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.f274_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f274_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f274_as(NULL);
    RETURN -1;
END;
$f$;

CREATE FUNCTION pg_temp.f274_n(p_user uuid, p_sql text) RETURNS bigint
LANGUAGE plpgsql AS $f$
DECLARE v bigint;
BEGIN
    PERFORM pg_temp.f274_as(p_user);
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f274_as(NULL);
    RETURN v;
EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f274_as(NULL);
    RETURN -1;
END;
$f$;

CREATE FUNCTION pg_temp.f274_who(p_codes text[]) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE r uuid; u uuid := gen_random_uuid();
BEGIN
    IF p_codes IS NULL THEN RETURN u; END IF;      -- no role at all
    INSERT INTO roles (code, name_en, name_zh, is_active) VALUES ('fx274-' || left(u::text, 8), 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO role_permissions (role_id, permission_code) SELECT DISTINCT r, c FROM unnest(p_codes) c;
    INSERT INTO user_roles (user_id, role_id) VALUES (u, r);
    RETURN u;
END;
$f$;

DO $f274$
DECLARE
    u_norole uuid; u_display uuid; u_other uuid; u_log uuid; u uuid;
    v_obj text; v_code text; v_total bigint; v_n bigint; v_b text; v_cus uuid; v_chase uuid; v_acct uuid; v_lab text;
    v_rec record;
    -- object → the codes its predicate names (Step 0 Q2–Q6, Tim)
    v_rel jsonb := jsonb_build_object(
        'user_roles', jsonb_build_array('action.manage_permissions', 'module.hr.view', 'data.view_change_log'),
        'roles', jsonb_build_array('action.manage_permissions', 'data.view_change_log'),
        'role_permissions', jsonb_build_array('action.manage_permissions', 'data.view_change_log'),
        'permissions', jsonb_build_array('action.manage_permissions', 'data.view_change_log'),
        'metal_prices', jsonb_build_array('module.pricing.view', 'module.suppliers.view', 'module.inventory.view', 'module.materials.view'),
        'metal_price_indices', jsonb_build_array('module.pricing.view', 'module.suppliers.view', 'action.metal_prices'),
        'pricing_settings', jsonb_build_array('module.pricing.view', 'module.inventory.view'),
        'accounts', jsonb_build_array('module.finance.view'),
        'collection_promise_status', jsonb_build_array('module.finance.view'));
    -- bucket → [read codes], [upload codes] (Step 0 §3, Q7–Q10)
    v_bk jsonb := jsonb_build_object(
        'cn-documents', jsonb_build_array(jsonb_build_array('module.finance.view'), jsonb_build_array('module.finance.edit')),
        'cod-documents', jsonb_build_array(jsonb_build_array('action.issue_cod'), jsonb_build_array('action.issue_cod')),
        'customer-attachments', jsonb_build_array(jsonb_build_array('module.customers.view'), jsonb_build_array('module.customers.edit')),
        'finance-attachments', jsonb_build_array(jsonb_build_array('module.finance.view'), jsonb_build_array('module.finance.edit')),
        'invoice-documents', jsonb_build_array(jsonb_build_array('module.finance.view'), jsonb_build_array('module.finance.edit')),
        'material-attachments', jsonb_build_array(jsonb_build_array('module.materials.view'), jsonb_build_array('module.materials.edit')),
        'po-documents', jsonb_build_array(jsonb_build_array('module.purchasing.view'), jsonb_build_array('module.purchasing.edit')),
        'qt-documents', jsonb_build_array(jsonb_build_array('module.sales.view'), jsonb_build_array('module.sales.edit')),
        'shipment-documents', jsonb_build_array(jsonb_build_array('module.sales.view', 'action.ship_goods'), jsonb_build_array('action.ship_goods')),
        'so-documents', jsonb_build_array(jsonb_build_array('module.sales.view'), jsonb_build_array('module.sales.edit')),
        'statement-documents', jsonb_build_array(jsonb_build_array('module.finance.view'), jsonb_build_array('module.finance.edit')),
        'supplier-attachments', jsonb_build_array(jsonb_build_array('module.suppliers.view'), jsonb_build_array('module.suppliers.edit')),
        -- MES-9c(2026-10-20):门户交上来的证书 —— 员工读 module.suppliers.view;员工【没有】上传码(只有门户会话按它自己的申请传),没有删除
        'portal-uploads', jsonb_build_array(jsonb_build_array('module.suppliers.view'), jsonb_build_array()),
        'traceability-documents', jsonb_build_array(jsonb_build_array('module.sales.view', 'module.processing.view'),
                                                    jsonb_build_array('module.sales.edit', 'module.processing.edit')),
        'company-assets', jsonb_build_array(jsonb_build_array('module.finance.view', 'module.purchasing.view', 'module.sales.view',
                              'action.ship_goods', 'action.issue_cod', 'module.processing.view', 'module.output.view', 'module.compliance.view'),
                              jsonb_build_array('action.finance_settings')));
    v_del jsonb := jsonb_build_object(        -- delete-orphan buckets → record table · column
        'cod-documents', 'cod_issues.file_path', 'po-documents', 'po_issues.file_path',
        'traceability-documents', 'traceability_report_issues.file_path', 'customer-attachments', 'customer_attachments.storage_path',
        'finance-attachments', 'finance_attachments.file_path', 'material-attachments', 'material_attachments.storage_path',
        'supplier-attachments', 'supplier_attachments.storage_path');
BEGIN
    IF to_regclass('storage.objects') IS NULL OR (SELECT count(*) FROM storage.buckets) < 20 THEN
        RAISE EXCEPTION 'FIXTURE 274 SETUP: no storage stub with the 20 buckets on this rebuild — db/gate.py installs db/storage/* before the fixtures';
    END IF;

    -- ── data of its own: one row in every object (as postgres) ──────────────
    INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, source) VALUES ('ni', 20000, CURRENT_DATE, 'broker_quote');
    IF NOT EXISTS (SELECT 1 FROM metal_price_indices) THEN
        INSERT INTO metal_price_indices (code, name_en, name_zh) VALUES ('F274', 'fixture 274 index', 'fixture 274 index');
    END IF;
    INSERT INTO customers (code, legal_name, country) VALUES ('F274-CUS', 'fixture 274 customer', 'SG') RETURNING id INTO v_cus;
    INSERT INTO collection_chases (code, customer_id, chased_on, channel, reached, summary, base_currency, owed_base, on_account_base,
                                   net_due_base, owed_by_currency, owed_buckets)
    VALUES ('F274-CH1', v_cus, CURRENT_DATE - 3, 'phone', true, 'fixture 274 chase', 'SGD', 1000, 0, 1000, '{}'::jsonb, '{}'::jsonb)
    RETURNING id INTO v_chase;
    INSERT INTO collection_promises (chase_id, promised_amount_ccy, currency, fx_rate, promised_amount_base, promised_date)
    VALUES (v_chase, 1000, 'SGD', 1, 1000, CURRENT_DATE - 1);

    u_norole := pg_temp.f274_who(NULL);
    u_display := gen_random_uuid();
    INSERT INTO user_roles (user_id, role_id) SELECT u_display, id FROM roles WHERE code = 'floor_display';
    IF NOT FOUND THEN RAISE EXCEPTION 'FIXTURE 274 SETUP: no floor_display role on the rebuild'; END IF;
    u_other := pg_temp.f274_who(ARRAY['module.tasks.view']);

    -- ── REL ────────────────────────────────────────────────────────────────
    FOR v_obj IN SELECT jsonb_object_keys(v_rel) LOOP
        -- the total as owner: collection_promise_status asks has_permission() of its READER, so postgres (no JWT) reads 0 —
        -- its total is the base table's
        EXECUTE CASE WHEN v_obj = 'collection_promise_status' THEN 'SELECT count(*) FROM public.collection_promises'
                     ELSE format('SELECT count(*) FROM public.%I', v_obj) END INTO v_total;
        IF v_total < 1 THEN RAISE EXCEPTION 'FIXTURE 274 REL: % has no row to read — the arm would be vacuous', v_obj; END IF;
        FOREACH u IN ARRAY ARRAY[u_norole, u_display, u_other] LOOP
            v_n := pg_temp.f274_n(u, format('SELECT count(*) FROM public.%I t %s', v_obj,
                     CASE WHEN v_obj = 'user_roles' THEN 'WHERE t.user_id IS DISTINCT FROM auth.uid()' ELSE '' END));
            IF v_n IS DISTINCT FROM 0::bigint THEN
                RAISE EXCEPTION 'FIXTURE 274 REL: a session without the code reads % row(s) of % (who %)', v_n, v_obj,
                    CASE u WHEN u_norole THEN 'norole' WHEN u_display THEN 'display' ELSE 'module.tasks.view' END;
            END IF;
        END LOOP;
        FOR v_code IN SELECT jsonb_array_elements_text(v_rel -> v_obj) LOOP
            u := pg_temp.f274_who(ARRAY[v_code]);
            EXECUTE CASE WHEN v_obj = 'collection_promise_status' THEN 'SELECT count(*) FROM public.collection_promises'
                         ELSE format('SELECT count(*) FROM public.%I', v_obj) END INTO v_total;   -- re-read: the new grant row is in user_roles / role_permissions
            v_n := pg_temp.f274_n(u, format('SELECT count(*) FROM public.%I', v_obj));
            IF v_n IS DISTINCT FROM v_total THEN
                RAISE EXCEPTION 'FIXTURE 274 REL: % alone reads % of % row(s) of %', v_code, v_n, v_total, v_obj;
            END IF;
        END LOOP;
    END LOOP;

    -- ── OWN ────────────────────────────────────────────────────────────────
    u := pg_temp.f274_who(ARRAY['module.tasks.view', 'module.sales.view']);
    IF pg_temp.f274_n(u, 'SELECT count(*) FROM public.user_roles WHERE user_id = auth.uid()') IS DISTINCT FROM 1::bigint THEN
        RAISE EXCEPTION 'FIXTURE 274 OWN: a session does not read its own user_roles row'; END IF;
    IF pg_temp.f274_n(u, 'SELECT count(*) FROM public.role_permissions') IS DISTINCT FROM 0::bigint THEN
        RAISE EXCEPTION 'FIXTURE 274 OWN: the arm is vacuous — this session reads role_permissions'; END IF;
    IF pg_temp.f274_n(u, 'SELECT count(*) FROM unnest(current_user_permissions())') IS DISTINCT FROM 2::bigint
       OR pg_temp.f274_n(u, 'SELECT count(*) FROM (SELECT 1 WHERE has_permission(''module.sales.view'') AND NOT has_permission(''module.finance.view'')) x')
          IS DISTINCT FROM 1::bigint THEN
        RAISE EXCEPTION 'FIXTURE 274 OWN: a session that cannot read the permission tables no longer gets its own codes'; END IF;
    IF pg_temp.f274_n(u_norole, 'SELECT count(*) FROM unnest(current_user_permissions())') IS DISTINCT FROM 0::bigint THEN
        RAISE EXCEPTION 'FIXTURE 274 OWN: a no-role session holds a code'; END IF;

    -- ── TRAIL ──────────────────────────────────────────────────────────────
    -- ① an employee with no code, on its own expense claim: the claim's account is still named in its trail (trail_ref_label runs
    --    under record_trail's SECURITY DEFINER) although the employee reads no row of accounts
    INSERT INTO accounts (code, name_en, name_zh, account_type, is_monetary) VALUES ('9274', 'ZZ fixture 274 account', 'ZZ fixture 274', 'expense', false)
    RETURNING id INTO v_acct;
    u_log := gen_random_uuid();
    INSERT INTO auth.users (id, email) VALUES (u_log, 'fx274-emp@test.local');
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (gen_random_uuid(), 'FX274-E', 'FX274 Employee', 'full_time', 'office', DATE '2020-01-01', u_log) RETURNING id INTO v_chase;
    INSERT INTO expense_claims (id, code, employee_id, spend_date, amount_ccy, currency, description, no_receipt_reason, status, account_code)
    VALUES (v_cus, 'FX274-CLAIM', v_chase, CURRENT_DATE, 10, 'SGD', 'fixture 274 claim', 'none', 'submitted', '9274');
    IF pg_temp.f274_n(u_log, 'SELECT count(*) FROM public.accounts') IS DISTINCT FROM 0::bigint THEN
        RAISE EXCEPTION 'FIXTURE 274 TRAIL: the arm is vacuous — the employee reads accounts'; END IF;
    PERFORM pg_temp.f274_as(u_log);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT COALESCE(jsonb_agg(to_jsonb(r)), '[]'::jsonb)::text INTO v_lab FROM record_trail('my_expense_claim', v_cus::text, 200) r;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f274_as(NULL);
    IF v_lab NOT LIKE '%ZZ fixture 274 account%' THEN
        RAISE EXCEPTION 'FIXTURE 274 TRAIL: the claim''s trail does not name its account (%)', left(v_lab, 300); END IF;
    -- ② the audit trails are readers of the permission tables (Tim's build Q21): a role grant in the change log is shown — not
    --    Restricted — to a data.view_change_log reader that holds no manage_permissions (who holds no data.view_change_log cannot open it)
    u := pg_temp.f274_who(ARRAY['module.sales.view']);              -- its grant row was just written to the change log
    u_log := pg_temp.f274_who(ARRAY['data.view_change_log']);
    PERFORM pg_temp.f274_as(u_log);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_total FROM change_log_rows(p_table := 'user_roles', p_limit := 200) r
     WHERE r.new ->> 'user_id' = u::text AND NOT r.row_restricted;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f274_as(NULL);
    IF v_total <> 1 THEN
        RAISE EXCEPTION 'FIXTURE 274 TRAIL: the change-log reader sees the role grant % time(s) unrestricted (expected 1)', v_total; END IF;
    -- ③ the employee page's trail shows the linked account's role grants to an HR viewer (AUDIT-TRAIL Q21/Q24)
    INSERT INTO auth.users (id, email) VALUES (u, 'fx274-acc@test.local');
    INSERT INTO employees (id, code, legal_name, employment_type, work_category, hire_date, user_id)
    VALUES (gen_random_uuid(), 'FX274-H', 'FX274 Linked', 'full_time', 'office', DATE '2020-01-01', u) RETURNING id INTO v_acct;
    u_log := pg_temp.f274_who(ARRAY['module.hr.view']);
    PERFORM pg_temp.f274_as(u_log);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_total FROM record_trail('employee', v_acct::text, 500) r
     WHERE to_jsonb(r) ->> 'table_name' = 'user_roles' AND COALESCE((to_jsonb(r) ->> 'row_hidden')::boolean, false) = false;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.f274_as(NULL);
    IF v_total < 1 THEN
        RAISE EXCEPTION 'FIXTURE 274 TRAIL: the employee page trail hides the linked account''s role grant from an HR viewer'; END IF;

    -- ── PROMISE ────────────────────────────────────────────────────────────
    u := pg_temp.f274_who(ARRAY['module.customers.view', 'module.sales.view']);
    IF pg_temp.f274_n(u, 'SELECT count(*) FROM public.collection_promise_status') IS DISTINCT FROM 0::bigint THEN
        RAISE EXCEPTION 'FIXTURE 274 PROMISE: a reader without module.finance.view sees a promise'; END IF;
    u := pg_temp.f274_who(ARRAY['module.finance.view']);
    IF pg_temp.f274_n(u, 'SELECT count(*) FROM public.collection_promise_status WHERE chase_code = ''F274-CH1''') IS DISTINCT FROM 1::bigint THEN
        RAISE EXCEPTION 'FIXTURE 274 PROMISE: a finance viewer does not see the promise'; END IF;

    -- ── BUCKET / NOUPDATE / DELETE ─────────────────────────────────────────
    INSERT INTO storage.objects (bucket_id, name) SELECT b, 'f274/' || b || '/orphan.pdf' FROM jsonb_object_keys(v_bk) b;
    FOR v_b IN SELECT jsonb_object_keys(v_bk) LOOP
        FOREACH u IN ARRAY ARRAY[u_norole, u_display, u_other] LOOP
            IF pg_temp.f274_n(u, format('SELECT count(*) FROM storage.objects WHERE bucket_id = %L', v_b)) IS DISTINCT FROM 0::bigint THEN
                RAISE EXCEPTION 'FIXTURE 274 BUCKET: a session without the code sees a file in %', v_b; END IF;
            IF pg_temp.f274_rc(u, format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', v_b, 'f274/' || gen_random_uuid())) <> -1 THEN
                RAISE EXCEPTION 'FIXTURE 274 BUCKET: a session without the code uploads into %', v_b; END IF;
        END LOOP;
        FOR v_code IN SELECT jsonb_array_elements_text(v_bk -> v_b -> 0) LOOP
            u := pg_temp.f274_who(ARRAY[v_code]);
            IF pg_temp.f274_n(u, format('SELECT count(*) FROM storage.objects WHERE bucket_id = %L', v_b)) IS DISTINCT FROM 1::bigint THEN
                RAISE EXCEPTION 'FIXTURE 274 BUCKET: % alone does not read %', v_code, v_b; END IF;
            IF v_b <> 'company-assets' AND NOT (v_bk -> v_b -> 1) ? v_code
               AND pg_temp.f274_rc(u, format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', v_b, 'f274/' || gen_random_uuid())) <> -1 THEN
                RAISE EXCEPTION 'FIXTURE 274 BUCKET: the read code % alone uploads into %', v_code, v_b; END IF;
            IF pg_temp.f274_rc(u, format('DELETE FROM storage.objects WHERE bucket_id = %L', v_b)) > 0
               AND NOT ((v_del ? v_b) AND (v_bk -> v_b -> 1) ? v_code) THEN
                RAISE EXCEPTION 'FIXTURE 274 DELETE: the read code % alone deletes from %', v_code, v_b; END IF;
        END LOOP;
        INSERT INTO storage.objects (bucket_id, name) VALUES (v_b, 'f274/' || v_b || '/orphan.pdf') ON CONFLICT DO NOTHING;
        FOR v_code IN SELECT jsonb_array_elements_text(v_bk -> v_b -> 1) LOOP
            -- the upload code holds its read code too (an action code is granted with its page's view code — MES-5b-1)
            u := pg_temp.f274_who(ARRAY[v_code] || ARRAY(SELECT jsonb_array_elements_text(v_bk -> v_b -> 0)));
            IF pg_temp.f274_rc(u, format('INSERT INTO storage.objects (bucket_id, name) VALUES (%L, %L)', v_b, 'f274/' || gen_random_uuid())) <> 1 THEN
                RAISE EXCEPTION 'FIXTURE 274 BUCKET: % does not upload into %', v_code, v_b; END IF;
            IF v_b IN ('customer-attachments', 'finance-attachments', 'material-attachments', 'supplier-attachments')
               AND pg_temp.f274_rc(u, format('UPDATE storage.objects SET metadata = ''{}''::jsonb WHERE bucket_id = %L', v_b)) <> 0 THEN
                RAISE EXCEPTION 'FIXTURE 274 NOUPDATE: % updates a file in %', v_code, v_b; END IF;
            IF v_del ? v_b THEN
                v_n := pg_temp.f274_rc(u, format('DELETE FROM storage.objects WHERE bucket_id = %L AND name = %L', v_b, 'f274/' || v_b || '/orphan.pdf'));
                IF v_n <> 1 THEN RAISE EXCEPTION 'FIXTURE 274 DELETE: % does not delete an orphan in % (rc %)', v_code, v_b, v_n; END IF;
                INSERT INTO storage.objects (bucket_id, name) VALUES (v_b, 'f274/' || v_b || '/orphan.pdf') ON CONFLICT DO NOTHING;   -- back for the next code
            ELSIF v_b <> 'company-assets' AND pg_temp.f274_rc(u, format('DELETE FROM storage.objects WHERE bucket_id = %L', v_b)) > 0 THEN
                RAISE EXCEPTION 'FIXTURE 274 DELETE: % deletes from %, a bucket whose route never removes', v_code, v_b;
            END IF;
        END LOOP;
    END LOOP;
    -- a file a record points at: the upload code cannot delete it
    INSERT INTO storage.objects (bucket_id, name) VALUES ('customer-attachments', v_cus || '/recorded.pdf');
    INSERT INTO customer_attachments (customer_id, storage_path, file_name) VALUES (v_cus, v_cus || '/recorded.pdf', 'recorded.pdf');
    u := pg_temp.f274_who(ARRAY['module.customers.edit', 'module.customers.view']);
    IF pg_temp.f274_rc(u, format('DELETE FROM storage.objects WHERE bucket_id = %L AND name = %L', 'customer-attachments', v_cus || '/recorded.pdf')) <> 0 THEN
        RAISE EXCEPTION 'FIXTURE 274 DELETE: a recorded attachment was deleted through storage'; END IF;
    -- each delete policy names the right record table and column
    FOR v_rec IN SELECT key AS b, value #>> '{}' AS tc FROM jsonb_each(v_del) LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'DELETE' AND qual LIKE '%''' || v_rec.b || '''%'
                          AND qual LIKE '%' || split_part(v_rec.tc, '.', 1) || ' i%' AND qual LIKE '%i.' || split_part(v_rec.tc, '.', 2) || ' = objects.name%') THEN
            RAISE EXCEPTION 'FIXTURE 274 DELETE: the delete policy of % does not check %', v_rec.b, v_rec.tc; END IF;
    END LOOP;

    -- ── SHAPE ──────────────────────────────────────────────────────────────
    -- MES-9b(2026-10-19):第 53 条是门户那一条读策略(TO supplier_portal,判据 portal_can_read_object —— 门户会话的判据,它不持任何码)
    -- MES-9c(2026-10-20):54–56 —— 门户往 portal-uploads 传 / 读回自己申请的那一条路径(TO supplier_portal,判据 portal_can_upload_object)与员工读它
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 56 THEN
        RAISE EXCEPTION 'FIXTURE 274 SHAPE: % storage policies (expected 56)', (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage'); END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage'
                AND COALESCE(qual, '') || COALESCE(with_check, '') !~ '(has_permission|has_any_permission|auth\.uid)'
                AND NOT (policyname = 'portal reads its own logged issued documents' AND roles = ARRAY['supplier_portal']::name[]
                         AND cmd = 'SELECT' AND qual ~ 'portal_can_read_object\(bucket_id, name\)')
                AND NOT (policyname = 'portal uploads its own pending submission file' AND roles = ARRAY['supplier_portal']::name[]
                         AND cmd = 'INSERT' AND with_check ~ 'portal_can_upload_object\(bucket_id, name\)')
                AND NOT (policyname = 'portal reads its own pending submission file' AND roles = ARRAY['supplier_portal']::name[]
                         AND cmd = 'SELECT' AND qual ~ 'portal_can_upload_object\(bucket_id, name\)')) THEN
        RAISE EXCEPTION 'FIXTURE 274 SHAPE: a storage policy without a judge'; END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'UPDATE'
                AND policyname NOT IN ('own avatar update', 'finance settings update company-assets')) THEN
        RAISE EXCEPTION 'FIXTURE 274 SHAPE: an UPDATE storage policy outside avatars and company-assets'; END IF;

    RAISE NOTICE 'FIXTURE 274 全部通过: REL · OWN · TRAIL · PROMISE · BUCKET · NOUPDATE · DELETE · SHAPE';
END
$f274$;
ROLLBACK;

-- db/migrations/2026-10-19-norole-surface.sql — NOROLE-SURFACE (v1.4.59): close what a signed-in session holding no role can reach.
-- Tim's rulings: docs/surveys/NOROLE-SURFACE/STEP0-HANDBACK.md §12, accepted 2026-10-19 (Q1–Q20; Q4 ruled: warehouse keeps raw metal prices).
--
-- What it does — ONE migration, no app code, no function change, no back-fill, no data touched:
--   ① 8 SELECT policies stop being USING (true): user_roles (manage_permissions · hr.view · view_change_log OR own rows) · roles ·
--      role_permissions · permissions (manage_permissions · view_change_log — Tim's Q21 of 2026-10-19: the audit trails are readers too) · metal_prices · metal_price_indices · pricing_settings (the codes of the pages that read them) · accounts
--      (module.finance.view). Every session still gets its own codes through current_user_permissions() (SECURITY DEFINER).
--   ② collection_promise_status gains WHERE has_permission('module.finance.view') (its base tables' code). Columns identical; grants
--      unchanged (CREATE OR REPLACE keeps them; db/apply_migration.sh replays the F16 view-write revoke in this transaction).
--   ③ storage.objects: the 35 bucket-only policies (any signed-in session reads 14 private buckets, uploads into 13, updates and deletes
--      in 4) are dropped; 34 created — read and upload by bucket + the record's own code, delete only for files no record points at
--      (4 attachment buckets + cod / po / traceability), no UPDATE on the attachment buckets. company-assets read = the PDF routes' codes.
--   The repo mirror of ③ is db/storage/buckets-and-policies.sql (new, this cut); verdict 7 (db/check_norole.py) compares it with live.
--
-- Self-proof at the end (inside this transaction): no bucket-only storage policy remains; 52 storage policies; every one of the 9 objects
-- and every stored file outside an own avatar reads 0 for a no-role session and for a floor_display-only session. The per-role reading
-- (7 role copies) runs in the dry run: docs/surveys/NOROLE-SURFACE/per-role-readings.sql.
BEGIN;

-- ── 0 · preconditions: live is the state Step 0 measured ────────────────────────
DO $pre$
DECLARE v_n int; v_missing text;
BEGIN
    SELECT string_agg(n, ', ') INTO v_missing FROM unnest(ARRAY['authenticated delete customer-attachments',
        'authenticated delete finance-attachments',
        'authenticated delete material-attachments',
        'authenticated delete supplier-attachments',
        'authenticated read cn-documents',
        'authenticated read cod-documents',
        'authenticated read company-assets',
        'authenticated read customer-attachments',
        'authenticated read finance-attachments',
        'authenticated read invoice-documents',
        'authenticated read material-attachments',
        'authenticated read po-documents',
        'authenticated read qt-documents',
        'authenticated read shipment-documents',
        'authenticated read so-documents',
        'authenticated read statement-documents',
        'authenticated read supplier-attachments',
        'authenticated read traceability-documents',
        'authenticated update customer-attachments',
        'authenticated update finance-attachments',
        'authenticated update material-attachments',
        'authenticated update supplier-attachments',
        'authenticated upload cn-documents',
        'authenticated upload cod-documents',
        'authenticated upload customer-attachments',
        'authenticated upload finance-attachments',
        'authenticated upload invoice-documents',
        'authenticated upload material-attachments',
        'authenticated upload po-documents',
        'authenticated upload qt-documents',
        'authenticated upload shipment-documents',
        'authenticated upload so-documents',
        'authenticated upload statement-documents',
        'authenticated upload supplier-attachments',
        'authenticated upload traceability-documents']) n
     WHERE NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'storage' AND p.tablename = 'objects' AND p.policyname = n);
    IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'NOROLE_PRE|bucket-only storage policy missing: %', v_missing; END IF;
    SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'storage';
    IF v_n <> 53 THEN RAISE EXCEPTION 'NOROLE_PRE|expected 53 storage policies, found %', v_n; END IF;
    SELECT string_agg(x, ', ') INTO v_missing FROM unnest(ARRAY['user_roles:user_roles select by permission', 'roles:roles select by permission', 'role_permissions:role_permissions select by permission', 'permissions:permissions select by permission', 'metal_prices:metal_prices select by permission', 'metal_price_indices:metal_price_indices select', 'pricing_settings:pricing_settings select', 'accounts:accounts select by permission']) x
     WHERE NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'public' AND p.tablename = split_part(x, ':', 1)
                          AND p.policyname = split_part(x, ':', 2) AND p.cmd = 'SELECT' AND p.qual = 'true');
    IF v_missing IS NOT NULL THEN RAISE EXCEPTION 'NOROLE_PRE|not a USING (true) SELECT policy: %', v_missing; END IF;
    IF EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'storage' AND p.policyname LIKE '% read by %' AND p.policyname NOT IN
               ('capture-photos read by inbound or logistics view', 'coa-documents read by output view',
                'compliance-documents read by compliance view', 'supplier-statement-documents read by finance view')) THEN
        RAISE EXCEPTION 'NOROLE_PRE|a storage policy with this cut''s names already exists';
    END IF;
    IF (SELECT count(*) FROM auth.users) <> 7 THEN RAISE EXCEPTION 'NOROLE_PRE|expected the 7 live accounts'; END IF;
END
$pre$;

-- ── 1 · eight SELECT policies (Q1–Q5) ──────────────────────────────────────────
DROP POLICY "user_roles select by permission" ON public.user_roles;
CREATE POLICY "user_roles select by permission"
    ON public.user_roles
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['action.manage_permissions'::text, 'module.hr.view'::text, 'data.view_change_log'::text]) OR (user_id = auth.uid()));

DROP POLICY "roles select by permission" ON public.roles;
CREATE POLICY "roles select by permission"
    ON public.roles
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['action.manage_permissions'::text, 'data.view_change_log'::text]));

DROP POLICY "role_permissions select by permission" ON public.role_permissions;
CREATE POLICY "role_permissions select by permission"
    ON public.role_permissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['action.manage_permissions'::text, 'data.view_change_log'::text]));

DROP POLICY "permissions select by permission" ON public.permissions;
CREATE POLICY "permissions select by permission"
    ON public.permissions
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['action.manage_permissions'::text, 'data.view_change_log'::text]));

DROP POLICY "metal_prices select by permission" ON public.metal_prices;
CREATE POLICY "metal_prices select by permission"
    ON public.metal_prices
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.pricing.view'::text, 'module.suppliers.view'::text, 'module.inventory.view'::text, 'module.materials.view'::text]));

DROP POLICY "metal_price_indices select" ON public.metal_price_indices;
CREATE POLICY "metal_price_indices select"
    ON public.metal_price_indices
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.pricing.view'::text, 'module.suppliers.view'::text, 'action.metal_prices'::text]));

DROP POLICY "pricing_settings select" ON public.pricing_settings;
CREATE POLICY "pricing_settings select"
    ON public.pricing_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.pricing.view'::text, 'module.inventory.view'::text]));

DROP POLICY "accounts select by permission" ON public.accounts;
CREATE POLICY "accounts select by permission"
    ON public.accounts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ── 2 · collection_promise_status (Q6) ─────────────────────────────────────────
CREATE OR REPLACE VIEW public.collection_promise_status WITH (security_invoker = off) AS
SELECT pr.id AS promise_id,
    ch.id AS chase_id,
    ch.code AS chase_code,
    ch.customer_id,
    cu.code AS customer_code,
    cu.legal_name AS customer_name,
    ch.chased_on,
    ch.channel,
    pr.promised_amount_ccy,
    pr.currency,
    pr.promised_amount_base,
    pr.promised_date,
    pr.outcome,
    pr.outcome_recorded_at,
    pr.outcome IS NULL AND ch.superseded_at IS NULL AND pr.promised_date <= CURRENT_DATE AS is_overdue,
    pr.outcome IS NULL AND ch.superseded_at IS NULL AS is_open,
    ch.superseded_at IS NOT NULL AS chase_superseded,
    ch.superseded_reason
   FROM collection_promises pr
     JOIN collection_chases ch ON ch.id = pr.chase_id
     JOIN customers cu ON cu.id = ch.customer_id
  WHERE has_permission('module.finance.view'::text);

COMMENT ON VIEW public.collection_promise_status IS
    'CHASE-1：每个承诺一行 —— 它是什么、逾期了没有、它那条催收还活着没有。★【逾期就在承诺日【当天】(`<=`)】★ —— Tim 2026-08-28 裁定，fu2 改的。理由是一件关于这门生意的事实：**货款通常在下午中段到账**，所以承诺日当天有人来看这张单子时，一笔还没到的款已经是那天要处理的那件事；推到第二天，单子就恰好在它最有用的那一天保持沉默。**不要把这个 `<=` 改回 `<`** —— 它不是差一天的笔误。仍然不设宽限期：一个没人调的旋钮会让「逾期」在不同时候意思不同。【这条边界全库只有这一处】customer_collection_context 原先又算了一遍同样的比较，fu2 把它改成读这张视图 —— 一条写在两个地方的规矩迟早会在两个地方不一致。属主权限（security_invoker = off）：它横跨 finance 与 customers，invoker 会让 RLS 把读者无权的那一侧静默丢掉，而行消失在这里意味着「少了一个逾期承诺」而不是报错（OPS-14 修法 (a)）。★【它只调一个函数:has_permission】★ NOROLE-SURFACE(2026-10-19,Tim 的 Q6)给 body 加了 WHERE has_permission(''module.finance.view'') —— 与两张基表的读策略同一个码;has_permission 对 authenticated 可执行、从不 RAISE,所以首页不会报错,没有财务码的读者读到 0 行(operations_now 那一支本来就按 module.finance.view 裁决)。仍然不放 require_permission 或 ar_aging_asof:前者会让没有 finance 权限的读者整个仪表盘报错,后者每行要跑两次,那是对账页的活。';

-- ── 3 · storage.objects: drop the 35 bucket-only policies (Q7–Q10) ─────────────
DROP POLICY "authenticated delete customer-attachments" ON storage.objects;
DROP POLICY "authenticated delete finance-attachments" ON storage.objects;
DROP POLICY "authenticated delete material-attachments" ON storage.objects;
DROP POLICY "authenticated delete supplier-attachments" ON storage.objects;
DROP POLICY "authenticated read cn-documents" ON storage.objects;
DROP POLICY "authenticated read cod-documents" ON storage.objects;
DROP POLICY "authenticated read company-assets" ON storage.objects;
DROP POLICY "authenticated read customer-attachments" ON storage.objects;
DROP POLICY "authenticated read finance-attachments" ON storage.objects;
DROP POLICY "authenticated read invoice-documents" ON storage.objects;
DROP POLICY "authenticated read material-attachments" ON storage.objects;
DROP POLICY "authenticated read po-documents" ON storage.objects;
DROP POLICY "authenticated read qt-documents" ON storage.objects;
DROP POLICY "authenticated read shipment-documents" ON storage.objects;
DROP POLICY "authenticated read so-documents" ON storage.objects;
DROP POLICY "authenticated read statement-documents" ON storage.objects;
DROP POLICY "authenticated read supplier-attachments" ON storage.objects;
DROP POLICY "authenticated read traceability-documents" ON storage.objects;
DROP POLICY "authenticated update customer-attachments" ON storage.objects;
DROP POLICY "authenticated update finance-attachments" ON storage.objects;
DROP POLICY "authenticated update material-attachments" ON storage.objects;
DROP POLICY "authenticated update supplier-attachments" ON storage.objects;
DROP POLICY "authenticated upload cn-documents" ON storage.objects;
DROP POLICY "authenticated upload cod-documents" ON storage.objects;
DROP POLICY "authenticated upload customer-attachments" ON storage.objects;
DROP POLICY "authenticated upload finance-attachments" ON storage.objects;
DROP POLICY "authenticated upload invoice-documents" ON storage.objects;
DROP POLICY "authenticated upload material-attachments" ON storage.objects;
DROP POLICY "authenticated upload po-documents" ON storage.objects;
DROP POLICY "authenticated upload qt-documents" ON storage.objects;
DROP POLICY "authenticated upload shipment-documents" ON storage.objects;
DROP POLICY "authenticated upload so-documents" ON storage.objects;
DROP POLICY "authenticated upload statement-documents" ON storage.objects;
DROP POLICY "authenticated upload supplier-attachments" ON storage.objects;
DROP POLICY "authenticated upload traceability-documents" ON storage.objects;

-- ── 4 · storage.objects: the 34 that replace them ──────────────────────────────
CREATE POLICY "cn-documents read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'cn-documents'::text AND public.has_permission('module.finance.view'::text));

CREATE POLICY "cn-documents upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'cn-documents'::text AND public.has_permission('module.finance.edit'::text));

CREATE POLICY "cod-documents read by issue_cod"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'cod-documents'::text AND public.has_permission('action.issue_cod'::text));

CREATE POLICY "cod-documents upload by issue_cod"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'cod-documents'::text AND public.has_permission('action.issue_cod'::text));

CREATE POLICY "cod-documents remove unrecorded by issue_cod"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'cod-documents'::text AND public.has_permission('action.issue_cod'::text)
           AND NOT EXISTS (SELECT 1 FROM public.cod_issues i WHERE i.file_path = objects.name));

CREATE POLICY "company-assets read by PDF route codes"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'company-assets'::text AND public.has_any_permission(ARRAY['module.finance.view'::text, 'module.purchasing.view'::text, 'module.sales.view'::text, 'action.ship_goods'::text, 'action.issue_cod'::text, 'module.processing.view'::text, 'module.output.view'::text, 'module.compliance.view'::text]));

CREATE POLICY "customer-attachments read by customers.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'customer-attachments'::text AND public.has_permission('module.customers.view'::text));

CREATE POLICY "customer-attachments upload by customers.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'customer-attachments'::text AND public.has_permission('module.customers.edit'::text));

CREATE POLICY "customer-attachments remove unrecorded by customers.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'customer-attachments'::text AND public.has_permission('module.customers.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.customer_attachments i WHERE i.storage_path = objects.name));

CREATE POLICY "finance-attachments read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'finance-attachments'::text AND public.has_permission('module.finance.view'::text));

CREATE POLICY "finance-attachments upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'finance-attachments'::text AND public.has_permission('module.finance.edit'::text));

CREATE POLICY "finance-attachments remove unrecorded by finance.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'finance-attachments'::text AND public.has_permission('module.finance.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.finance_attachments i WHERE i.file_path = objects.name));

CREATE POLICY "invoice-documents read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'invoice-documents'::text AND public.has_permission('module.finance.view'::text));

CREATE POLICY "invoice-documents upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'invoice-documents'::text AND public.has_permission('module.finance.edit'::text));

CREATE POLICY "material-attachments read by materials.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'material-attachments'::text AND public.has_permission('module.materials.view'::text));

CREATE POLICY "material-attachments upload by materials.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'material-attachments'::text AND public.has_permission('module.materials.edit'::text));

CREATE POLICY "material-attachments remove unrecorded by materials.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'material-attachments'::text AND public.has_permission('module.materials.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.material_attachments i WHERE i.storage_path = objects.name));

CREATE POLICY "po-documents read by purchasing.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'po-documents'::text AND public.has_permission('module.purchasing.view'::text));

CREATE POLICY "po-documents upload by purchasing.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'po-documents'::text AND public.has_permission('module.purchasing.edit'::text));

CREATE POLICY "po-documents remove unrecorded by purchasing.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'po-documents'::text AND public.has_permission('module.purchasing.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.po_issues i WHERE i.file_path = objects.name));

CREATE POLICY "qt-documents read by sales.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'qt-documents'::text AND public.has_permission('module.sales.view'::text));

CREATE POLICY "qt-documents upload by sales.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'qt-documents'::text AND public.has_permission('module.sales.edit'::text));

CREATE POLICY "shipment-documents read by sales.view or ship_goods"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'shipment-documents'::text AND public.has_any_permission(ARRAY['module.sales.view'::text, 'action.ship_goods'::text]));

CREATE POLICY "shipment-documents upload by ship_goods"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'shipment-documents'::text AND public.has_permission('action.ship_goods'::text));

CREATE POLICY "so-documents read by sales.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'so-documents'::text AND public.has_permission('module.sales.view'::text));

CREATE POLICY "so-documents upload by sales.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'so-documents'::text AND public.has_permission('module.sales.edit'::text));

CREATE POLICY "statement-documents read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'statement-documents'::text AND public.has_permission('module.finance.view'::text));

CREATE POLICY "statement-documents upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'statement-documents'::text AND public.has_permission('module.finance.edit'::text));

CREATE POLICY "supplier-attachments read by suppliers.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'supplier-attachments'::text AND public.has_permission('module.suppliers.view'::text));

CREATE POLICY "supplier-attachments upload by suppliers.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'supplier-attachments'::text AND public.has_permission('module.suppliers.edit'::text));

CREATE POLICY "supplier-attachments remove unrecorded by suppliers.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'supplier-attachments'::text AND public.has_permission('module.suppliers.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.supplier_attachments i WHERE i.storage_path = objects.name));

CREATE POLICY "traceability-documents read by sales or processing view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'traceability-documents'::text AND public.has_any_permission(ARRAY['module.sales.view'::text, 'module.processing.view'::text]));

CREATE POLICY "traceability-documents upload by sales or processing edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'traceability-documents'::text AND public.has_any_permission(ARRAY['module.sales.edit'::text, 'module.processing.edit'::text]));

CREATE POLICY "traceability-documents remove unrecorded by upload code"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'traceability-documents'::text AND public.has_any_permission(ARRAY['module.sales.edit'::text, 'module.processing.edit'::text])
           AND NOT EXISTS (SELECT 1 FROM public.traceability_report_issues i WHERE i.file_path = objects.name));

-- ── 5 · self-proof ─────────────────────────────────────────────────────────────
DO $proof$
DECLARE
    v_n bigint; v_bad text; v_obj text; v_who text; v_uid uuid;
    v_objs text[] := ARRAY['user_roles','roles','role_permissions','permissions','metal_prices','metal_price_indices',
                           'pricing_settings','accounts','collection_promise_status'];
BEGIN
    -- no storage policy without a code or an own-row judge
    SELECT string_agg(policyname, ', ') INTO v_bad FROM pg_policies
     WHERE schemaname = 'storage' AND COALESCE(qual, '') || COALESCE(with_check, '') !~ '(has_permission|has_any_permission|auth\.uid)';
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'NOROLE_PROOF|storage policy without a judge: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'storage';
    IF v_n <> 52 THEN RAISE EXCEPTION 'NOROLE_PROOF|expected 52 storage policies, found %', v_n; END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'UPDATE' AND policyname NOT IN ('own avatar update', 'finance settings update company-assets')) THEN
        RAISE EXCEPTION 'NOROLE_PROOF|an UPDATE storage policy outside avatars / company-assets';
    END IF;
    -- a no-role and a floor_display-only session read nothing of the 9 objects and no stored file but its own avatar
    FOREACH v_who IN ARRAY ARRAY['norole', 'display'] LOOP
        BEGIN
            v_uid := gen_random_uuid();
            IF v_who = 'display' THEN
                INSERT INTO user_roles (user_id, role_id) SELECT v_uid, id FROM roles WHERE code = 'floor_display';
            END IF;
            PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
            EXECUTE 'SET LOCAL ROLE authenticated';
            IF v_who = 'display' AND NOT has_permission('data.view_floor_board') THEN
                RAISE EXCEPTION 'NOROLE_PROOF|the display identity does not hold data.view_floor_board — the arm would be vacuous';
            END IF;
            FOREACH v_obj IN ARRAY v_objs LOOP
                -- user_roles: its OWN grant row stays readable (Q3) — only somebody else's row is a leak
                EXECUTE format('SELECT count(*) FROM public.%I t %s', v_obj,
                               CASE WHEN v_obj = 'user_roles' THEN 'WHERE t.user_id IS DISTINCT FROM auth.uid()' ELSE '' END) INTO v_n;
                IF v_n <> 0 THEN RAISE EXCEPTION 'NOROLE_PROOF|% reads % row(s) of %', v_who, v_n, v_obj; END IF;
            END LOOP;
            SELECT count(*) INTO v_n FROM storage.objects;
            IF v_n <> 0 THEN RAISE EXCEPTION 'NOROLE_PROOF|% sees % stored file(s)', v_who, v_n; END IF;
            EXECUTE 'RESET ROLE';
            RAISE EXCEPTION 'zz_undo';
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM <> 'zz_undo' THEN RAISE; END IF;
        END;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE NOTICE 'NOROLE_PROOF ok: 52 storage policies, none bucket-only, no-role and display read 0 of 9 objects (beyond the own grant row) and 0 stored files';
END
$proof$;

COMMIT;

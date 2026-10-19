-- db/storage/buckets-and-policies.sql —— 存储桶与 storage.objects 上的每一条策略(NOROLE-SURFACE,2026-10-19,Step 0 Q11,Tim)
--
-- 【为什么有这个文件】此前 19 个桶与 53 条存储策略只活在各自的迁移文件里:db/platform-prelude.sql、db/check_mirrors.py、db/gate.py
--   里 storage 出现 0 次,docs/fresh-install-checklist.md 一个桶都不建 —— 一次从仓库出发的全新安装【一个桶、一条存储策略都没有】。
--   本文件是那一半的镜像:全新安装照 docs/fresh-install-checklist.md 那一步在 SQL editor 里跑它一次;db/gate.py 的判词七
--   (db/check_norole.py)把它装进重建库旁边的一个 storage 桩里,逐条与线上比(桶的五列 · 每条策略的名字 · 命令 · 角色 · 表达式)。
-- 【它不进重建本身】重建(verify_rebuild)照旧不造 storage 架构(prelude 不变);那个桩只是一张形状对得上的 storage.objects /
--   storage.buckets(db/storage/platform-storage-stub.sql),为的是让这份文件能被【跑一遍】并被比对 —— 而不是只被读一遍。
-- 【幂等】桶 ON CONFLICT DO UPDATE;每条策略先 DROP IF EXISTS 再 CREATE。对着线上再跑一遍不改任何东西的含义
--   (★ 但不要对着线上跑它:线上由迁移改,本文件由同一刀跟着改 —— 与表镜像同一条规矩)。
-- 【改的规矩】一支迁移动了一个桶或一条存储策略,同一个提交里改本文件;判词七会因为线上 ≠ 本文件而红。
--
-- 读、上传按【桶 + 那份单据自己的码】判(Q7);路径只在【删除】里读:只有没有任何记录指着的孤儿才删得掉(Q9,coa-documents 的形状)。
-- 四个附件桶不再有 UPDATE(Q8);company-assets 的读 = 印标志的那几条 PDF 路由的码之一(Q10)。


SET client_min_messages = warning;   -- DROP POLICY IF EXISTS 在全新安装上每一条都会说一句 skipping


-- ── 桶(19)────────────────────────────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', false, 262144, ARRAY['image/webp'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('capture-photos', 'capture-photos', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('cn-documents', 'cn-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('coa-documents', 'coa-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('cod-documents', 'cod-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('company-assets', 'company-assets', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('compliance-documents', 'compliance-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('customer-attachments', 'customer-attachments', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('finance-attachments', 'finance-attachments', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('invoice-documents', 'invoice-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('material-attachments', 'material-attachments', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('po-documents', 'po-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('qt-documents', 'qt-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('shipment-documents', 'shipment-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('so-documents', 'so-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('statement-documents', 'statement-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('supplier-attachments', 'supplier-attachments', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('supplier-statement-documents', 'supplier-statement-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('traceability-documents', 'traceability-documents', false, NULL, NULL)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit, allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ── 策略(53)—— NOROLE-SURFACE 的 34 条在前,其余 18 条(本刀之前就带着码)照线上原文在后,MES-9b 的门户那一条在文末 ─────────────────

DROP POLICY IF EXISTS "cn-documents read by finance.view" ON storage.objects;
CREATE POLICY "cn-documents read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'cn-documents'::text AND public.has_permission('module.finance.view'::text));

DROP POLICY IF EXISTS "cn-documents upload by finance.edit" ON storage.objects;
CREATE POLICY "cn-documents upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'cn-documents'::text AND public.has_permission('module.finance.edit'::text));

DROP POLICY IF EXISTS "cod-documents read by issue_cod" ON storage.objects;
CREATE POLICY "cod-documents read by issue_cod"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'cod-documents'::text AND public.has_permission('action.issue_cod'::text));

DROP POLICY IF EXISTS "cod-documents upload by issue_cod" ON storage.objects;
CREATE POLICY "cod-documents upload by issue_cod"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'cod-documents'::text AND public.has_permission('action.issue_cod'::text));

DROP POLICY IF EXISTS "cod-documents remove unrecorded by issue_cod" ON storage.objects;
CREATE POLICY "cod-documents remove unrecorded by issue_cod"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'cod-documents'::text AND public.has_permission('action.issue_cod'::text)
           AND NOT EXISTS (SELECT 1 FROM public.cod_issues i WHERE i.file_path = objects.name));

DROP POLICY IF EXISTS "company-assets read by PDF route codes" ON storage.objects;
CREATE POLICY "company-assets read by PDF route codes"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'company-assets'::text AND public.has_any_permission(ARRAY['module.finance.view'::text, 'module.purchasing.view'::text, 'module.sales.view'::text, 'action.ship_goods'::text, 'action.issue_cod'::text, 'module.processing.view'::text, 'module.output.view'::text, 'module.compliance.view'::text]));

DROP POLICY IF EXISTS "customer-attachments read by customers.view" ON storage.objects;
CREATE POLICY "customer-attachments read by customers.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'customer-attachments'::text AND public.has_permission('module.customers.view'::text));

DROP POLICY IF EXISTS "customer-attachments upload by customers.edit" ON storage.objects;
CREATE POLICY "customer-attachments upload by customers.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'customer-attachments'::text AND public.has_permission('module.customers.edit'::text));

DROP POLICY IF EXISTS "customer-attachments remove unrecorded by customers.edit" ON storage.objects;
CREATE POLICY "customer-attachments remove unrecorded by customers.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'customer-attachments'::text AND public.has_permission('module.customers.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.customer_attachments i WHERE i.storage_path = objects.name));

DROP POLICY IF EXISTS "finance-attachments read by finance.view" ON storage.objects;
CREATE POLICY "finance-attachments read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'finance-attachments'::text AND public.has_permission('module.finance.view'::text));

DROP POLICY IF EXISTS "finance-attachments upload by finance.edit" ON storage.objects;
CREATE POLICY "finance-attachments upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'finance-attachments'::text AND public.has_permission('module.finance.edit'::text));

DROP POLICY IF EXISTS "finance-attachments remove unrecorded by finance.edit" ON storage.objects;
CREATE POLICY "finance-attachments remove unrecorded by finance.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'finance-attachments'::text AND public.has_permission('module.finance.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.finance_attachments i WHERE i.file_path = objects.name));

DROP POLICY IF EXISTS "invoice-documents read by finance.view" ON storage.objects;
CREATE POLICY "invoice-documents read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'invoice-documents'::text AND public.has_permission('module.finance.view'::text));

DROP POLICY IF EXISTS "invoice-documents upload by finance.edit" ON storage.objects;
CREATE POLICY "invoice-documents upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'invoice-documents'::text AND public.has_permission('module.finance.edit'::text));

DROP POLICY IF EXISTS "material-attachments read by materials.view" ON storage.objects;
CREATE POLICY "material-attachments read by materials.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'material-attachments'::text AND public.has_permission('module.materials.view'::text));

DROP POLICY IF EXISTS "material-attachments upload by materials.edit" ON storage.objects;
CREATE POLICY "material-attachments upload by materials.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'material-attachments'::text AND public.has_permission('module.materials.edit'::text));

DROP POLICY IF EXISTS "material-attachments remove unrecorded by materials.edit" ON storage.objects;
CREATE POLICY "material-attachments remove unrecorded by materials.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'material-attachments'::text AND public.has_permission('module.materials.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.material_attachments i WHERE i.storage_path = objects.name));

DROP POLICY IF EXISTS "po-documents read by purchasing.view" ON storage.objects;
CREATE POLICY "po-documents read by purchasing.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'po-documents'::text AND public.has_permission('module.purchasing.view'::text));

DROP POLICY IF EXISTS "po-documents upload by purchasing.edit" ON storage.objects;
CREATE POLICY "po-documents upload by purchasing.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'po-documents'::text AND public.has_permission('module.purchasing.edit'::text));

DROP POLICY IF EXISTS "po-documents remove unrecorded by purchasing.edit" ON storage.objects;
CREATE POLICY "po-documents remove unrecorded by purchasing.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'po-documents'::text AND public.has_permission('module.purchasing.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.po_issues i WHERE i.file_path = objects.name));

DROP POLICY IF EXISTS "qt-documents read by sales.view" ON storage.objects;
CREATE POLICY "qt-documents read by sales.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'qt-documents'::text AND public.has_permission('module.sales.view'::text));

DROP POLICY IF EXISTS "qt-documents upload by sales.edit" ON storage.objects;
CREATE POLICY "qt-documents upload by sales.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'qt-documents'::text AND public.has_permission('module.sales.edit'::text));

DROP POLICY IF EXISTS "shipment-documents read by sales.view or ship_goods" ON storage.objects;
CREATE POLICY "shipment-documents read by sales.view or ship_goods"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'shipment-documents'::text AND public.has_any_permission(ARRAY['module.sales.view'::text, 'action.ship_goods'::text]));

DROP POLICY IF EXISTS "shipment-documents upload by ship_goods" ON storage.objects;
CREATE POLICY "shipment-documents upload by ship_goods"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'shipment-documents'::text AND public.has_permission('action.ship_goods'::text));

DROP POLICY IF EXISTS "so-documents read by sales.view" ON storage.objects;
CREATE POLICY "so-documents read by sales.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'so-documents'::text AND public.has_permission('module.sales.view'::text));

DROP POLICY IF EXISTS "so-documents upload by sales.edit" ON storage.objects;
CREATE POLICY "so-documents upload by sales.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'so-documents'::text AND public.has_permission('module.sales.edit'::text));

DROP POLICY IF EXISTS "statement-documents read by finance.view" ON storage.objects;
CREATE POLICY "statement-documents read by finance.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'statement-documents'::text AND public.has_permission('module.finance.view'::text));

DROP POLICY IF EXISTS "statement-documents upload by finance.edit" ON storage.objects;
CREATE POLICY "statement-documents upload by finance.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'statement-documents'::text AND public.has_permission('module.finance.edit'::text));

DROP POLICY IF EXISTS "supplier-attachments read by suppliers.view" ON storage.objects;
CREATE POLICY "supplier-attachments read by suppliers.view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'supplier-attachments'::text AND public.has_permission('module.suppliers.view'::text));

DROP POLICY IF EXISTS "supplier-attachments upload by suppliers.edit" ON storage.objects;
CREATE POLICY "supplier-attachments upload by suppliers.edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'supplier-attachments'::text AND public.has_permission('module.suppliers.edit'::text));

DROP POLICY IF EXISTS "supplier-attachments remove unrecorded by suppliers.edit" ON storage.objects;
CREATE POLICY "supplier-attachments remove unrecorded by suppliers.edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'supplier-attachments'::text AND public.has_permission('module.suppliers.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.supplier_attachments i WHERE i.storage_path = objects.name));

DROP POLICY IF EXISTS "traceability-documents read by sales or processing view" ON storage.objects;
CREATE POLICY "traceability-documents read by sales or processing view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'traceability-documents'::text AND public.has_any_permission(ARRAY['module.sales.view'::text, 'module.processing.view'::text]));

DROP POLICY IF EXISTS "traceability-documents upload by sales or processing edit" ON storage.objects;
CREATE POLICY "traceability-documents upload by sales or processing edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'traceability-documents'::text AND public.has_any_permission(ARRAY['module.sales.edit'::text, 'module.processing.edit'::text]));

DROP POLICY IF EXISTS "traceability-documents remove unrecorded by upload code" ON storage.objects;
CREATE POLICY "traceability-documents remove unrecorded by upload code"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'traceability-documents'::text AND public.has_any_permission(ARRAY['module.sales.edit'::text, 'module.processing.edit'::text])
           AND NOT EXISTS (SELECT 1 FROM public.traceability_report_issues i WHERE i.file_path = objects.name));

DROP POLICY IF EXISTS "capture-photos read by inbound or logistics view" ON storage.objects;
CREATE POLICY "capture-photos read by inbound or logistics view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'capture-photos'::text) AND (has_permission('module.inbound.view'::text) OR has_permission('module.logistics.view'::text))));

DROP POLICY IF EXISTS "capture-photos upload by confirm_capture" ON storage.objects;
CREATE POLICY "capture-photos upload by confirm_capture"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'capture-photos'::text) AND has_permission('action.confirm_capture'::text)));

DROP POLICY IF EXISTS "coa-documents read by output view" ON storage.objects;
CREATE POLICY "coa-documents read by output view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'coa-documents'::text) AND has_permission('module.output.view'::text)));

DROP POLICY IF EXISTS "coa-documents remove unrecorded by issue_coa" ON storage.objects;
CREATE POLICY "coa-documents remove unrecorded by issue_coa"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (((bucket_id = 'coa-documents'::text) AND has_permission('action.issue_coa'::text) AND (NOT (EXISTS ( SELECT 1
   FROM coa_issues i
  WHERE (i.file_path = objects.name))))));

DROP POLICY IF EXISTS "coa-documents upload by issue_coa" ON storage.objects;
CREATE POLICY "coa-documents upload by issue_coa"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'coa-documents'::text) AND has_permission('action.issue_coa'::text)));

DROP POLICY IF EXISTS "compliance-documents read by compliance view" ON storage.objects;
CREATE POLICY "compliance-documents read by compliance view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'compliance-documents'::text) AND has_permission('module.compliance.view'::text)));

DROP POLICY IF EXISTS "compliance-documents remove unrecorded by compliance pack" ON storage.objects;
CREATE POLICY "compliance-documents remove unrecorded by compliance pack"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (((bucket_id = 'compliance-documents'::text) AND has_permission('action.compliance_pack'::text) AND (NOT (EXISTS ( SELECT 1
   FROM compliance_pack_issues i
  WHERE (i.file_path = objects.name))))));

DROP POLICY IF EXISTS "compliance-documents upload by compliance pack" ON storage.objects;
CREATE POLICY "compliance-documents upload by compliance pack"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'compliance-documents'::text) AND has_permission('action.compliance_pack'::text)));

DROP POLICY IF EXISTS "finance settings delete company-assets" ON storage.objects;
CREATE POLICY "finance settings delete company-assets"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (((bucket_id = 'company-assets'::text) AND has_permission('action.finance_settings'::text)));

DROP POLICY IF EXISTS "finance settings update company-assets" ON storage.objects;
CREATE POLICY "finance settings update company-assets"
    ON storage.objects AS PERMISSIVE FOR UPDATE TO authenticated
    USING (((bucket_id = 'company-assets'::text) AND has_permission('action.finance_settings'::text)))
    WITH CHECK (((bucket_id = 'company-assets'::text) AND has_permission('action.finance_settings'::text)));

DROP POLICY IF EXISTS "finance settings upload company-assets" ON storage.objects;
CREATE POLICY "finance settings upload company-assets"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'company-assets'::text) AND has_permission('action.finance_settings'::text)));

DROP POLICY IF EXISTS "own avatar delete" ON storage.objects;
CREATE POLICY "own avatar delete"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (((bucket_id = 'avatars'::text) AND (name = ((auth.uid())::text || '.webp'::text))));

DROP POLICY IF EXISTS "own avatar read" ON storage.objects;
CREATE POLICY "own avatar read"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'avatars'::text) AND (name = ((auth.uid())::text || '.webp'::text))));

DROP POLICY IF EXISTS "own avatar update" ON storage.objects;
CREATE POLICY "own avatar update"
    ON storage.objects AS PERMISSIVE FOR UPDATE TO authenticated
    USING (((bucket_id = 'avatars'::text) AND (name = ((auth.uid())::text || '.webp'::text))))
    WITH CHECK (((bucket_id = 'avatars'::text) AND (name = ((auth.uid())::text || '.webp'::text))));

DROP POLICY IF EXISTS "own avatar upload" ON storage.objects;
CREATE POLICY "own avatar upload"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'avatars'::text) AND (name = ((auth.uid())::text || '.webp'::text))));

DROP POLICY IF EXISTS "supplier-statement-documents read by finance view" ON storage.objects;
CREATE POLICY "supplier-statement-documents read by finance view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (((bucket_id = 'supplier-statement-documents'::text) AND has_permission('module.finance.view'::text)));

DROP POLICY IF EXISTS "supplier-statement-documents remove unrecorded by finance edit" ON storage.objects;
CREATE POLICY "supplier-statement-documents remove unrecorded by finance edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (((bucket_id = 'supplier-statement-documents'::text) AND has_permission('module.finance.edit'::text) AND (NOT (EXISTS ( SELECT 1
   FROM supplier_statement_issues i
  WHERE (i.file_path = objects.name))))));

DROP POLICY IF EXISTS "supplier-statement-documents upload by finance edit" ON storage.objects;
CREATE POLICY "supplier-statement-documents upload by finance edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (((bucket_id = 'supplier-statement-documents'::text) AND has_permission('module.finance.edit'::text)));


-- ── 供应商门户(MES-9b,2026-10-19,MES-9 Step 0 §3 · Q14 · Q22 · Q27,Tim)—— 第 53 条策略,与它要的两条授权 ─────────────────
-- 门户会话(数据库角色 supplier_portal,由 access token hook 写进令牌)经 Storage API 只读得到【三个单据桶里、它两分钟内刚为之写下过
--   一行下载记录的那一个对象】(portal_can_read_object;那一行只由 portal_document_open 为调用者自己那一家的、没作废的签发档写)。
--   于是每一次取字节前面都有一行下载记录(Q22),而一个别家的、没签发的、作废的对象它连"存在"都看不见。不能写、不能删、不能列别的。
-- 授权只给干跑与线上证明需要的(Q27):storage 架构的 USAGE 与 storage.objects 的 SELECT(行由下面这条策略筛)。storage.buckets 不授 ——
--   Storage API 以它自己的身份查桶。这两条授权与这条策略都按名列在 db/portal-grants-baseline.tsv(判词八)。
GRANT USAGE ON SCHEMA storage TO supplier_portal;
GRANT SELECT ON storage.objects TO supplier_portal;

DROP POLICY IF EXISTS "portal reads its own logged issued documents" ON storage.objects;
CREATE POLICY "portal reads its own logged issued documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO supplier_portal
    USING (((bucket_id = ANY (ARRAY['po-documents'::text, 'cod-documents'::text, 'supplier-statement-documents'::text])) AND public.portal_can_read_object(bucket_id, name)));

-- db/migrations/2026-08-15-so3b-fu2-shipment-documents-bucket.sql
-- SO-3b 续:shipment-documents 桶 + 它的两条门
--
-- 【为什么桶和门在同一支迁移里】SO-1 那次桶先建、门后补,签发当场 500
-- (Upload failed: new row violates row-level security policy),是手走才发现的。
-- 那条教训写在 2026-08-14-so1-fu2 的抬头 —— 这里不再重演:一起建。
--
-- 形状逐字取自 so-documents(它取自 po-documents):
--     SELECT   bucket_id = '…'
--     INSERT   bucket_id = '…'
-- 【为什么不更严】桶里放的是【已经签发出去的单据字节】,而能读到发货单的人
-- 本来就该能取回他签发过的那一份;真正的门在 shipment_issues 那张表上
-- (module.sales.view),路由也只按表里记着的 file_path 去取 —— 桶里没有
-- 可枚举的入口。【没有 UPDATE / DELETE 策略】签发档只增不改。

BEGIN;

INSERT INTO storage.buckets (id, name, public)
VALUES ('shipment-documents', 'shipment-documents', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read shipment-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'shipment-documents'::text);

CREATE POLICY "authenticated upload shipment-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'shipment-documents'::text);

COMMIT;

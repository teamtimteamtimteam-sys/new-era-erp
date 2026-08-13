-- db/migrations/2026-08-14-so1-fu2-so-documents-bucket.sql
-- SO-1 续:so-documents 桶的存取策略 —— 桶建出来了,门没装
--
-- 【手走查出来的】签发当场 500:
--     Upload failed: new row violates row-level security policy
-- 桶是新建的,而 storage.objects 上没有任何一条针对它的策略 —— 于是 authenticated
-- 既传不上也读不到。形状逐字取自 po-documents 那两条(PUR-1 建的):
--     SELECT   bucket_id = '…'
--     INSERT   bucket_id = '…'
-- 【为什么不更严】桶里放的是【已经签发出去的单据字节】,而能读到订单的人本来
-- 就该能取回他签发过的那一份;真正的门在 so_issues 那张表上(module.sales.view),
-- 路由也只按 so_issues 里记着的 file_path 去取 —— 桶里没有可枚举的入口。
-- 【没有 UPDATE / DELETE 策略】签发档只增不改:桶这一侧也不给改和删的路。

BEGIN;

CREATE POLICY "authenticated read so-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'so-documents'::text);

CREATE POLICY "authenticated upload so-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'so-documents'::text);

COMMIT;

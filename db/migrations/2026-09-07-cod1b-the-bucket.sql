-- db/migrations/2026-09-07-cod1b-the-bucket.sql
-- COD-1b:销毁证书的字节桶。形状与 AUD-1 的 traceability-documents 逐字相同。
--
-- 【为什么是第二支迁移而不是并进第一支】第一支已经落库并且事务内自检通过了;
-- 把桶补在后面是【加一支】,不是回头改一支已经跑过的。仓库的规矩是迁移不可变。
--
-- 【私有】现有 14 个桶里 13 个是私有的,只有 UI-1d 的 avatars 是公开的。
-- 销毁证书的字节【不公开】—— 核验页将来读的是快照那一行(数据),不是这个桶。
-- 那正是 COD-1 两样都冻的理由:桶证明纸没被改过,快照才渲染得出网页。

BEGIN;

INSERT INTO storage.buckets (id, name, public)
VALUES ('cod-documents', 'cod-documents', false)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "authenticated read cod-documents"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'cod-documents'::text);

CREATE POLICY "authenticated upload cod-documents"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'cod-documents'::text);

COMMIT;

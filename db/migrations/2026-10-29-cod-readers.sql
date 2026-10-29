-- db/migrations/2026-10-29-cod-readers.sql
-- COD-READERS(v1.4.81,docs/forward-queue.md 64d-5)—— Tim 2026-10-29 的裁定(10:49 之后的 COD-READERS 块;12:49 Step 0 的 Q1 与 grilling 1–8):
--   cfo · cco · cto · finance · gm 读得到销毁证书 —— /compliance/cod 清单、批次页上那一张(只读)与它存下的 PDF。
--   签发、作废与每一种写一个字不动(action.issue_cod:admin · warehouse);两张已签发的证书逐字节不变(本迁移不碰一个存储对象)。
--
-- 做了什么(一个码,读它的地方同一个提交改完):
--   ① 新码 data.view_cod(category data),授 admin · warehouse · cfo · cco · cto · finance · gm;
--   ② certificates_of_destruction 与 cod_issues 的读策略换成它(PDF 路由从 cod_issues 取存档的路径与哈希 —— grilling 第 1 条);
--   ③ cod-documents 桶的读策略换成它,写成按语句求一次的形状(新名「read by view_cod」,旧名删掉);上传与删除仍是 action.issue_cod;
--   ④ document_types 里 cod 那一行的 view_permission 换成它(全局搜索、搜索的「另有 N 条」、关联记录与 /documents/cod —— grilling 第 2 条)。
-- 不动:四支 SECURITY DEFINER 写函数、cod_certificate_data(仍只归签发人,Q1 (a))、submit_cod_void_request、portal 那一条读策略。
-- 镜像:db/tables/permissions.sql · role_permissions.sql · certificates_of_destruction.sql · cod_issues.sql · document_types.sql ·
--       db/storage/buckets-and-policies.sql(同一个提交)。
BEGIN;

INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    ('data.view_cod', 'data', 'View certificates of destruction', '查看销毁证书', 'The certificates of destruction: the list, each certificate on its delivery''s page and the stored PDF of an issued or voided one. Issuing and voiding need Issue certificate of destruction.', '销毁证书:清单、进料批页上的那一张与已签发或已作废证书存下的 PDF。签发与作废要「签发销毁证书」。', 285);

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_cod' FROM public.roles r
 WHERE r.code IN ('admin', 'warehouse', 'cfo', 'cco', 'cto', 'finance', 'gm')
ON CONFLICT (role_id, permission_code) DO NOTHING;

DROP POLICY "certificates_of_destruction select by permission" ON public.certificates_of_destruction;
CREATE POLICY "certificates_of_destruction select by permission"
    ON public.certificates_of_destruction
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('data.view_cod'::text)));

DROP POLICY "cod_issues select by permission" ON public.cod_issues;
CREATE POLICY "cod_issues select by permission"
    ON public.cod_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('data.view_cod'::text)));

DROP POLICY "cod-documents read by issue_cod" ON storage.objects;
CREATE POLICY "cod-documents read by view_cod"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'cod-documents'::text AND (SELECT public.has_permission('data.view_cod'::text)));

UPDATE public.document_types SET view_permission = ARRAY['data.view_cod']::text[] WHERE key = 'cod';

-- ── 事务内自证:任何一条不成立,整支回滚 ────────────────────────────────────
DO $proof$
DECLARE v text; n int;
BEGIN
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'data.view_cod';
    IF v IS DISTINCT FROM 'admin,cco,cfo,cto,finance,gm,warehouse' THEN
        RAISE EXCEPTION 'COD_READERS_PROOF holders: %', v;
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.issue_cod';
    IF v IS DISTINCT FROM 'admin,warehouse' THEN
        RAISE EXCEPTION 'COD_READERS_PROOF issuers changed: %', v;
    END IF;
    SELECT count(*) INTO n FROM pg_policies
     WHERE ((schemaname = 'public' AND tablename IN ('certificates_of_destruction', 'cod_issues') AND cmd = 'SELECT')
         OR (schemaname = 'storage' AND tablename = 'objects' AND policyname = 'cod-documents read by view_cod'))
       AND qual LIKE '%data.view_cod%' AND qual NOT LIKE '%issue_cod%';
    IF n <> 3 THEN
        RAISE EXCEPTION 'COD_READERS_PROOF read policies: % of 3 read data.view_cod', n;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = 'cod-documents read by issue_cod') THEN
        RAISE EXCEPTION 'COD_READERS_PROOF the old storage read policy is still there';
    END IF;
    SELECT count(*) INTO n FROM pg_policies
     WHERE schemaname = 'storage' AND policyname IN ('cod-documents upload by issue_cod', 'cod-documents remove unrecorded by issue_cod')
       AND coalesce(qual, '') || coalesce(with_check, '') LIKE '%action.issue_cod%';
    IF n <> 2 THEN
        RAISE EXCEPTION 'COD_READERS_PROOF storage write policies: % of 2 still on action.issue_cod', n;
    END IF;
    IF (SELECT view_permission FROM public.document_types WHERE key = 'cod') IS DISTINCT FROM ARRAY['data.view_cod']::text[] THEN
        RAISE EXCEPTION 'COD_READERS_PROOF document_types.cod';
    END IF;
    RAISE NOTICE 'COD_READERS_PROOF ok';
END
$proof$;

COMMIT;

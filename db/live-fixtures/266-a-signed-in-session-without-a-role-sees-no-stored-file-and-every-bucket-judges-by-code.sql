-- ═══════════════════════════════════════════════════════════════════════════
-- live fixture 266 —— 线上:一个没有角色的会话看不见任何一份存下的文件,每一个桶都按码判(NOROLE-SURFACE,2026-10-19;Step 0 Q7–Q11 · Q13,Tim)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么它不在 db/fixtures/】存储只活在线上:重建库旁那个 storage 桩(db/storage/platform-storage-stub.sql)证得了策略的【逻辑】
--   (fixture 274),证不了线上【真的】是那几条 —— 平台自己的 storage.objects、平台给的授权、40 份真文件在不在任何一个人的视野里。
--   这一支对着线上跑,只读(BEGIN READ ONLY … ROLLBACK),以 postgres 读目录,并以一个随机 uuid 的 JWT(没有账号、没有角色)读 storage.objects。
--   它不建任何身份(只读事务里建不了):有码那一半(每一个码读得到 / 传得进 / 删得掉孤儿)由 fixture 274 在重建库上以真的 RLS 证,
--   并由交回报告里的线上 HTTP 证明(一次性账号,list · download · upload · remove)证;线上策略 == 仓库镜像由判词七逐条比。
-- 断言:
--   NOROLE      一个没有角色的会话在 storage.objects 里一行都看不见(40 份文件、20 个桶)、在 storage.buckets 里一个桶都看不见
--   JUDGE       storage.objects 上每一条策略都带判据(has_permission / has_any_permission / 自己的头像 auth.uid();门户那一条是 portal_can_read_object;门户传 / 读回自己申请的那两条是 portal_can_upload_object);56 条(MES-9c 起)
--   NOUPDATE    UPDATE 只剩 avatars(自己的)与 company-assets(action.finance_settings);四个附件桶没有
--   DELETE      会删的桶恰好是:avatars(自己的)· company-assets · coa · compliance · supplier-statement · cod · po · traceability ·
--               四个附件桶 —— 除 avatars 与 company-assets 之外每一条删除都带 NOT EXISTS(记录表.列 = objects.name)
--   BUCKETS     20 个桶,全部私有(MES-9c 起多一个 portal-uploads)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
DO $live$
DECLARE
    v_n bigint; v_bad text;
BEGIN
    SELECT count(*) INTO v_n FROM storage.buckets;
    IF v_n <> 20 OR EXISTS (SELECT 1 FROM storage.buckets WHERE public) THEN
        RAISE EXCEPTION 'LIVE FIXTURE 266 BUCKETS: % buckets, or one is public (ruled: 20, all private)', v_n;
    END IF;
    IF (SELECT count(*) FROM storage.objects) = 0 THEN
        RAISE EXCEPTION 'LIVE FIXTURE 266 NOROLE: live holds no stored file at all — the arm below would be vacuous';
    END IF;

    PERFORM set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-000000000266","role":"authenticated"}', true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    SELECT count(*) INTO v_n FROM storage.objects;
    IF v_n <> 0 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION 'LIVE FIXTURE 266 NOROLE: a no-role session sees % stored file(s)', v_n; END IF;
    SELECT count(*) INTO v_n FROM storage.buckets;
    IF v_n <> 0 THEN EXECUTE 'RESET ROLE'; RAISE EXCEPTION 'LIVE FIXTURE 266 NOROLE: a no-role session sees % bucket(s)', v_n; END IF;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);

    SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects';
    -- MES-9b(2026-10-19):第 53 条是门户那一条读策略(TO supplier_portal,判据 portal_can_read_object —— 门户会话的判据,它不持任何码)
    SELECT string_agg(policyname, ', ') INTO v_bad FROM pg_policies
     WHERE schemaname = 'storage' AND COALESCE(qual, '') || COALESCE(with_check, '') !~ '(has_permission|has_any_permission|auth\.uid\(\))'
       AND NOT (policyname = 'portal reads its own logged issued documents' AND roles = ARRAY['supplier_portal']::name[]
                AND cmd = 'SELECT' AND qual ~ 'portal_can_read_object\(bucket_id, name\)')
       -- MES-9c(2026-10-20):门户往 portal-uploads 传 / 读回它自己申请的那一条路径(判据 portal_can_upload_object)
       AND NOT (policyname = 'portal uploads its own pending submission file' AND roles = ARRAY['supplier_portal']::name[]
                AND cmd = 'INSERT' AND with_check ~ 'portal_can_upload_object\(bucket_id, name\)')
       AND NOT (policyname = 'portal reads its own pending submission file' AND roles = ARRAY['supplier_portal']::name[]
                AND cmd = 'SELECT' AND qual ~ 'portal_can_upload_object\(bucket_id, name\)');
    IF v_n <> 56 OR v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'LIVE FIXTURE 266 JUDGE: % storage policies (ruled 56); without a judge: %', v_n, COALESCE(v_bad, '-');
    END IF;
    SELECT string_agg(policyname, ', ') INTO v_bad FROM pg_policies WHERE schemaname = 'storage' AND cmd IN ('UPDATE', 'ALL')
       AND policyname NOT IN ('own avatar update', 'finance settings update company-assets');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'LIVE FIXTURE 266 NOUPDATE: %', v_bad; END IF;
    SELECT string_agg(b, ', ') INTO v_bad FROM (
        SELECT DISTINCT substring(qual FROM 'bucket_id = ''([a-z-]+)''') AS b FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'DELETE') x
     WHERE b NOT IN ('avatars', 'company-assets', 'coa-documents', 'compliance-documents', 'supplier-statement-documents', 'cod-documents',
                     'po-documents', 'traceability-documents', 'customer-attachments', 'finance-attachments', 'material-attachments',
                     'supplier-attachments');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'LIVE FIXTURE 266 DELETE: a bucket whose route never removes has a delete policy: %', v_bad; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'DELETE') <> 12 THEN
        RAISE EXCEPTION 'LIVE FIXTURE 266 DELETE: % delete policies (ruled 12)', (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'DELETE');
    END IF;
    SELECT string_agg(policyname, ', ') INTO v_bad FROM pg_policies WHERE schemaname = 'storage' AND cmd = 'DELETE'
       AND policyname NOT IN ('own avatar delete', 'finance settings delete company-assets') AND qual !~ 'NOT \(EXISTS \( SELECT 1\s+FROM \w+ i\s+WHERE \(i\.\w+ = objects\.name\)\)\)';
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'LIVE FIXTURE 266 DELETE: a delete without the unrecorded-only check: %', v_bad; END IF;
    RAISE NOTICE 'LIVE FIXTURE 266 全部通过: BUCKETS · NOROLE · JUDGE · NOUPDATE · DELETE';
END
$live$;
ROLLBACK;

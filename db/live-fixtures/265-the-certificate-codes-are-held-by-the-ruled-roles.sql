-- ═══════════════════════════════════════════════════════════════════════════
-- live fixture 265 —— 两个证书与质量的动作码,线上恰好由裁定的那几个角色持有(MES-7a-1 · F11,Tim 2026-10-15;MES-6b-2 close-out 的 W2)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么它不在 db/fixtures/】那些 fixture 跑在【重建库】上,而重建库的引导里【没有】cco / cto 这两个角色
--   (db/tables/role_permissions.sql 只引导 admin · gm · finance · procurement · sales · operations · warehouse · hr · auditor;
--   cco · cto · cfo 只活在线上)。于是"cco 持 action.issue_coa"在重建库上没有可以断言的主语 —— 一支在那里跑的 fixture 只能空转,
--   而一条空转的断言与没有断言是同一个退出码。这条授权此前由 MES-6b-2 迁移的事务内自证与一次读数钉着,不由任何可重复的检查钉着(W2)。
-- 【它住在这里,由 db/gate.py 的整门对着【线上】跑】只读(BEGIN READ ONLY … ROLLBACK),以 postgres 读基表 role_permissions
--   (rolbypassrls = true,基表 —— 读到的是真行数,不是一次权限答复)。--offline 那一相不跑它(够不到线上),并在收尾里点名说没跑。
-- 断言:
--   ISSUE_COA   action.issue_coa 的持有角色恰好是 admin · cco(MES-0 Q90 · MES-6b Step 0 Q30)
--   NCR_DECIDE  action.ncr_decide 的持有角色恰好是 admin · cco · cto(MES-0 Q90 · MES-6b Step 0 Q9)
--   VIEWS       持这两个码的每一个角色也持它们各自声明的查看码之一(动作码蕴含查看码,MES-5b-1 的常设规矩)
--   SUBJECT     线上确实有一个代码为 cco 的角色,而且它有一个启用着的账号(否则 ISSUE_COA 的"cco"是一个空名字)
--   VIEW_COD    ★ COD-READERS(Tim 2026-10-29,64d-5):data.view_cod 的持有角色恰好是 admin · cco · cfo · cto · finance · gm · warehouse;
--               action.issue_cod 仍恰好是 admin · warehouse,而且每一个签发的角色也持 data.view_cod(签发的人读得到他签的那一张)
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN READ ONLY;
DO $live$
DECLARE
    v text;
BEGIN
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.issue_coa';
    IF v IS DISTINCT FROM 'admin,cco' THEN
        RAISE EXCEPTION 'LIVE FIXTURE 265 ISSUE_COA: action.issue_coa is held by % (ruled: admin,cco)', COALESCE(v, '<nobody>');
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.ncr_decide';
    IF v IS DISTINCT FROM 'admin,cco,cto' THEN
        RAISE EXCEPTION 'LIVE FIXTURE 265 NCR_DECIDE: action.ncr_decide is held by % (ruled: admin,cco,cto)', COALESCE(v, '<nobody>');
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE rp.permission_code IN ('action.issue_coa', 'action.ncr_decide')
       AND NOT EXISTS (SELECT 1 FROM role_permissions w WHERE w.role_id = rp.role_id AND w.permission_code = ANY (p.requires_view_any));
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'LIVE FIXTURE 265 VIEWS: a holder lacks the declared view code: %', v;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id JOIN auth.users u ON u.id = ur.user_id
                    WHERE r.code = 'cco' AND ur.revoked_at IS NULL AND (u.banned_until IS NULL OR u.banned_until < now())
                      AND u.email NOT LIKE '%@test.local') THEN
        RAISE EXCEPTION 'LIVE FIXTURE 265 SUBJECT: no enabled account holds the cco role';
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'data.view_cod';
    IF v IS DISTINCT FROM 'admin,cco,cfo,cto,finance,gm,warehouse' THEN
        RAISE EXCEPTION 'LIVE FIXTURE 265 VIEW_COD: data.view_cod is held by % (ruled: admin,cco,cfo,cto,finance,gm,warehouse)', COALESCE(v, '<nobody>');
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.issue_cod';
    IF v IS DISTINCT FROM 'admin,warehouse' THEN
        RAISE EXCEPTION 'LIVE FIXTURE 265 VIEW_COD: action.issue_cod is held by % (ruled: admin,warehouse)', COALESCE(v, '<nobody>');
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.issue_cod'
       AND NOT EXISTS (SELECT 1 FROM role_permissions w WHERE w.role_id = rp.role_id AND w.permission_code = 'data.view_cod');
    IF v IS NOT NULL THEN
        RAISE EXCEPTION 'LIVE FIXTURE 265 VIEW_COD: % issue certificates of destruction but cannot read them', v;
    END IF;
    RAISE NOTICE 'LIVE FIXTURE 265 全部通过: ISSUE_COA · NCR_DECIDE · VIEWS · SUBJECT · VIEW_COD';
END
$live$;
ROLLBACK;

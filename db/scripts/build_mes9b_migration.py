#!/usr/bin/env python3
"""MES-9b(v1.4.61):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数与换掉的函数原样从 db/ 下抽出,存储那两条授权与
一条策略原样从 db/storage/buckets-and-policies.sql 抽出,所以迁移建出来的与门重建出来的是同一串字。照抄 build_mes9a_migration.py 的形状。
跑法:python3 db/scripts/build_mes9b_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql"

GUARD_FUNC = "guard_portal_document_download_append_only"
NEW_TABLES = ["portal_document_downloads"]
NEW_FUNCS = ["portal_documents", "portal_deliveries", "portal_document_open", "portal_can_read_object"]
REPLACED_FUNCS = ["change_log_exclusions"]
PORTAL_SIGS = ["public.portal_documents()", "public.portal_deliveries()", "public.portal_document_open(text, uuid)",
               "public.portal_can_read_object(text, text)"]
POLICY = "portal reads its own logged issued documents"
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]

# 前后比对的表(既有的行逐字未变)
DIGEST_TABLES = {
    "suppliers": ("", []), "counterparty_contacts": ("", []), "supplier_portal_users": ("", []), "account_settings": ("", []),
    "inbound_batches": ("", []), "purchase_orders": ("", []), "po_issues": ("", []), "cod_issues": ("", []),
    "certificates_of_destruction": ("", []), "supplier_statements": ("", []), "supplier_statement_issues": ("", []),
    "weighbridge_tickets": ("", []), "weighbridge_ticket_shares": ("", []), "journal_entries": ("", []),
    "journal_lines": ("", []), "payments": ("", []), "expenses": ("", []), "approval_log": ("", []),
    "permissions": ("", []), "role_permissions": ("", []), "roles": ("", []), "user_roles": ("", []),
    "finance_settings": ("", []), "ingest_settings": ("", []), "floor_board_settings": ("", []), "document_types": ("", []),
}


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    assert body.count("CREATE OR REPLACE FUNCTION") == 1, name
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def digest(t, where, drop):
    j = "to_jsonb(t)" + "".join(f" - '{k}'" for k in drop)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t {where})"


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
storage = mirror("db/storage/buckets-and-policies.sql")
m = re.search(r"GRANT USAGE ON SCHEMA storage TO supplier_portal;\nGRANT SELECT ON storage\.objects TO supplier_portal;\n", storage)
assert m, "storage grants for supplier_portal"
STORAGE_GRANTS = m.group(0)
m = re.search(rf'DROP POLICY IF EXISTS "{POLICY}" ON storage\.objects;\nCREATE POLICY "{POLICY}"\n.*?;\n', storage, re.S)
assert m, "portal storage policy"
STORAGE_POLICY = m.group(0)
grants = mirror("db/views/zzz_function_grants.sql")
for sig in ["public.portal_documents()", "public.portal_deliveries()", "public.portal_document_open(text, uuid)",
            "public.portal_can_read_object(text, text)"]:
    assert f"GRANT EXECUTE ON FUNCTION {sig} TO supplier_portal;" in grants, sig
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated, service_role;" in grants, sig
assert "('portal_document_downloads', " in mirror("db/functions/change_log_exclusions.sql")
assert "zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.portal_document_downloads" not in mirror("db/views/zzz_change_log_triggers.sql")
base = mirror("db/portal-grants-baseline.tsv")
for line in ("policy\tstorage.objects\t" + POLICY, "relation\tstorage.objects\tSELECT", "schema\tstorage\tUSAGE",
             "function\tpublic.portal_document_open(p_kind text, p_issue_id uuid)\tEXECUTE"):
    assert line in base, line

HEADER = """-- db/migrations/2026-10-19-mes9b-what-a-supplier-sees.sql
-- MES-9b —— 供应商在门户里看得见什么:一位门户账号现在能打开它自己那一家的采购单、对账单与销毁证书【签发时存下的那一份 PDF】
--   (取的时候对着签发记录重算 sha256,对不上就 409),并看见它自己的收货与地磅单(按今天记着的样子,没有一个价钱);别家的、内部的、
--   活的价钱一样都看不见,每一次下载都记下来。(MES 组的第二十四刀,v1.4.61;发布那一行在 docs/handbacks/MES-9b.md 的抬头。)
--   由 db/scripts/build_mes9b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-19:MES-9 Step 0 §15 —— Q14 · Q15 · Q16–Q18 · Q22 照推荐;委托书把 Q14 / Q15 / Q22 逐字重述)
--   ① 一张新表 portal_document_downloads(门户下载记录,Q22):只追加;只经 portal_document_open 写;员工 module.suppliers.view 读;
--      变更记录的第九张豁免(它本身就是一份只追加的日志)—— change_log_exclusions() 换成九行。
--   ② 四支门户函数,只授 supplier_portal:portal_documents(单据清单)· portal_deliveries(收货与地磅单)·
--      portal_document_open(写调用者自己的一行下载记录,交出桶 · 路径 · 哈希)· portal_can_read_object(下面那条存储策略的判据)。
--   ③ 存储:supplier_portal 得到 storage 架构的 USAGE 与 storage.objects 的 SELECT;一条 TO supplier_portal 的读策略 —— 三个单据桶里、
--      这位门户账号两分钟内刚为之写下过下载记录的那一个对象(所以每一次取字节前面都有一行记录)。不能写、不能删、不能看别的。
--   门户角色够得着的每一样新东西都按名进了 db/portal-grants-baseline.tsv(判词八):四支函数 · 一个架构 · 一张表 · 一条策略,以及
--   storage 架构里对 PUBLIC 开着 EXECUTE 的 19 支平台函数(调用者权限;读到的行仍由那条策略筛)。
--
-- 【不做什么】不碰 hook、登录、刷新、空闲登出与大屏的豁免;不建任何门户账号;不建、不停、不改七个账号中的任何一个;不碰审批开关;
--   不改任何既有的行;不改任何既有的存储对象、桶或别的策略(存储策略 52 → 53,多的只有门户那一条);授权表一行不动;不回填;
--   require_calibrated_since 保持空。没有交货通知、争议回复、争议页、评分卡(Q16–Q18)。
--
-- 【破窗】这一窗什么都不坏:旧应用不读任何新东西;线上没有门户账号(供应商那一侧没有人调得到这四支);员工的令牌与读写一样都不变。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变,hook 对它们每一个仍逐字节原样返回;没有任何门户
--   账号;supplier_portal 能执行的 public 函数恰好是六支、能读的关系恰好是 storage.objects、能写的一样都没有;存储策略 53 条、作用于门户的恰好
--   那一条;存储对象一个字节不动(两张 COD 在内);在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;既有的行逐字未变;
--   本事务一行变更记录都没写;变更记录覆盖零缺口、豁免 9;324 张表;没有一张视图对 anon / authenticated 带写授权。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

VIEW_WRITE_SQL = """(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')))"""

acct_list = ", ".join(f"'{a}'" for a in REAL_ACCOUNTS)

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES9B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.portal_document_downloads') IS NOT NULL OR to_regprocedure('public.portal_documents()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = '{POLICY}') THEN
        RAISE EXCEPTION 'MES9B_PRE|MES-9b objects already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') OR to_regprocedure('public.portal_require_link()') IS NULL THEN
        RAISE EXCEPTION 'MES9B_PRE|MES-9a (supplier_portal, portal_require_link) is expected on live';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected the 7 real accounts';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN
        RAISE EXCEPTION 'MES9B_PRE|no portal account is expected on live';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 323 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected 323 public tables';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 52 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected 52 storage policies';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected 8 change-log exclusions';
    END IF;
    IF has_schema_privilege('supplier_portal', 'storage', 'USAGE') THEN
        RAISE EXCEPTION 'MES9B_PRE|supplier_portal already reaches schema storage';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9B_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES9B_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes9b_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes9b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes9b_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes9b_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE mes9b_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE mes9b_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 守卫(镜像原样):下载记录只追加 ──\n")
parts.append(fn(GUARD_FUNC))
parts.append("\n-- ── 2 · 新表(镜像原样):门户下载记录(Q22)──\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))
parts.append("\n-- ── 3 · 新函数(镜像原样):四支门户函数 ──\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 4 · 换掉的函数(镜像原样,同签名):变更记录的豁免 8 → 9 ──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append(f"""
-- ── 5 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):两条授权 + 一条策略 ──
{STORAGE_GRANTS}
{STORAGE_POLICY}""")

acl = ["""
-- ── 6 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in PORTAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon, authenticated, service_role;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO supplier_portal;\n")
acl.append(f"REVOKE EXECUTE ON FUNCTION public.{GUARD_FUNC}() FROM PUBLIC, anon;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes9b_pending_decider_check")
parts.append("\n-- ── 7 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes9b_rows_before)" for t, (w, d) in DIGEST_TABLES.items())

parts.append(f"""
CREATE TEMP TABLE mes9b_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_ev    jsonb;
    k       text;
    a       record;
BEGIN
    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变;没有任何门户账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES9B_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes9b_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes9b_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES9B_PROOF|an account or its roles changed';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN RAISE EXCEPTION 'MES9B_PROOF|no portal account may exist'; END IF;

    -- ② hook 不变:七个真账号的 event 逐字节原样返回(本刀不碰 hook —— 这一句证它)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ({acct_list}) ORDER BY email LOOP
        v_ev := jsonb_build_object('user_id', a.id, 'authentication_method', 'password',
                    'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', a.id, 'email', a.email,
                                                 'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', gen_random_uuid(),
                                                 'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                                 'user_metadata', '{{}}'::jsonb, 'amr', '[]'::jsonb));
        v_j := portal_access_token_hook(v_ev);
        IF v_j IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'MES9B_PROOF|the hook changed the claims of %', a.email;
        END IF;
    END LOOP;

    -- ③ 门户角色的可达面:public 函数恰好六支;能读的关系恰好 storage.objects;能写的一样都没有;作用于它的存储策略恰好一条;
    --    storage 架构只有 USAGE;仍不是任何角色的成员
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me' THEN
        RAISE EXCEPTION 'MES9B_PROOF|supplier_portal executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY 1), '') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_schema_privilege('supplier_portal', n.oid, 'USAGE') AND has_table_privilege('supplier_portal', c.oid, 'SELECT');
    IF v_bad <> 'storage.objects' THEN RAISE EXCEPTION 'MES9B_PROOF|supplier_portal reads: %', v_bad; END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname, ', '), '') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_table_privilege('supplier_portal', c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE');
    IF v_bad <> '' THEN RAISE EXCEPTION 'MES9B_PROOF|supplier_portal can write: %', v_bad; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE 'supplier_portal' = ANY (roles)) <> 1
       OR NOT has_schema_privilege('supplier_portal', 'storage', 'USAGE') OR has_schema_privilege('supplier_portal', 'storage', 'CREATE')
       OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = 'supplier_portal'::regrole) THEN
        RAISE EXCEPTION 'MES9B_PROOF|supplier_portal: one policy, USAGE on storage only, a member of nothing';
    END IF;
    IF has_table_privilege('authenticated', 'public.portal_document_downloads', 'INSERT,UPDATE,DELETE,TRUNCATE')
       OR has_table_privilege('anon', 'public.portal_document_downloads', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
       OR NOT has_table_privilege('authenticated', 'public.portal_document_downloads', 'SELECT') THEN
        RAISE EXCEPTION 'MES9B_PROOF|portal_document_downloads grants: authenticated SELECT only, anon nothing';
    END IF;

    -- ④ 存储:策略 53 条,既有的 52 条逐字未变;存储对象一个字节不动(两张 COD 在内)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 53
       OR EXISTS (SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM mes9b_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage') THEN
        RAISE EXCEPTION 'MES9B_PROOF|storage policies: expected the 52 unchanged plus the portal one';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM mes9b_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM mes9b_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'MES9B_PROOF|a stored object changed';
    END IF;

    -- ⑤ 在途单据一张不少、一张不多;既有的行逐字未变;本事务一行变更记录都没写
    IF EXISTS ((SELECT b.k, b.id FROM mes9b_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes9b_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes9b_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes9b_pending_before b)) THEN
        RAISE EXCEPTION 'MES9B_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES9B_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes9b_log_before), 0) AND c.txid = txid_current()) THEN
        RAISE EXCEPTION 'MES9B_PROOF|this migration wrote change_log rows';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9B_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:324 张表;变更记录覆盖零缺口、豁免 9(第九张带理由);遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 324 THEN
        RAISE EXCEPTION 'MES9B_PROOF|expected 324 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9
       OR NOT EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = 'portal_document_downloads' AND x.reason LIKE '%Q22%') THEN
        RAISE EXCEPTION 'MES9B_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'MES9B_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES9B_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面不变;四支门户函数 authenticated · anon 都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES9B_PROOF|anon executes: %', v_bad;
    END IF;
    FOREACH k IN ARRAY ARRAY['{"', '".join(PORTAL_SIGS)}'] LOOP
        IF has_function_privilege('authenticated', k::regprocedure, 'EXECUTE') OR has_function_privilege('anon', k::regprocedure, 'EXECUTE')
           OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = k::regprocedure) THEN
            RAISE EXCEPTION 'MES9B_PROOF|%: expected SECURITY DEFINER, executable by supplier_portal only', k;
        END IF;
    END LOOP;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes9b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES9B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes9b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES9B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes9b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

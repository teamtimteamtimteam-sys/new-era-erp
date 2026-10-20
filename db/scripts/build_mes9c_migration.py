#!/usr/bin/env python3
"""MES-9c(v1.4.62):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数与换掉的函数原样从 db/ 下抽出,存储的桶、
一条授权与三条策略原样从 db/storage/buckets-and-policies.sql 抽出,所以迁移建出来的与门重建出来的是同一串字。照抄 build_mes9b_migration.py 的形状。
跑法:python3 db/scripts/build_mes9c_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-20-mes9c-certificate-uploads.sql"

NEW_TABLES = ["portal_certificate_submissions"]
NEW_FUNCS = ["portal_certificates", "portal_submission_begin", "portal_submission_finish", "portal_submission_abandon",
             "portal_can_upload_object", "portal_submission_accept", "portal_submission_reject"]
REPLACED_FUNCS = ["trail_subject_members"]            # 同签名
RESIGNED_FUNCS = {                                    # 签名变了:先 DROP 旧签名,再按镜像建(F19)
    "change_log_rows": "public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[])",
}
PORTAL_SIGS = ["public.portal_certificates()", "public.portal_submission_begin(text, text, text, bigint, text, date, date)",
               "public.portal_submission_finish(uuid)", "public.portal_submission_abandon(uuid)", "public.portal_can_upload_object(text, text)"]
STAFF_SIGS = ["public.portal_submission_accept(uuid, text, text, text, date, date)", "public.portal_submission_reject(uuid, text)"]
POLICIES = ["portal uploads its own pending submission file", "portal reads its own pending submission file", "portal-uploads read by suppliers.view"]
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]

# 前后比对的表(既有的行逐字未变;account_settings 去掉本刀加的两列再比)
DIGEST_TABLES = {
    "suppliers": ("", []), "counterparty_contacts": ("", []), "supplier_portal_users": ("", []),
    "account_settings": ("", ["portal_upload_max_bytes", "portal_upload_types"]),
    "supplier_compliance": ("", []), "supplier_attachments": ("", []), "certificate_types": ("", []),
    "inbound_batches": ("", []), "purchase_orders": ("", []), "po_issues": ("", []), "cod_issues": ("", []),
    "certificates_of_destruction": ("", []), "supplier_statements": ("", []), "supplier_statement_issues": ("", []),
    "portal_document_downloads": ("", []), "journal_entries": ("", []), "journal_lines": ("", []), "payments": ("", []),
    "expenses": ("", []), "approval_log": ("", []), "permissions": ("", []), "role_permissions": ("", []), "roles": ("", []),
    "user_roles": ("", []), "finance_settings": ("", []), "ingest_settings": ("", []), "floor_board_settings": ("", []),
    "document_types": ("", []),
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
m = re.search(r"INSERT INTO storage\.buckets \(id, name, public, file_size_limit, allowed_mime_types\)\nVALUES \('portal-uploads'.*?;\n", storage, re.S)
assert m, "portal-uploads bucket"
STORAGE_BUCKET = m.group(0)
m = re.search(r"GRANT INSERT ON storage\.objects TO supplier_portal;\n", storage)
assert m, "storage INSERT grant for supplier_portal"
STORAGE_GRANT = m.group(0)
STORAGE_POLICIES = ""
for pol in POLICIES:
    m = re.search(rf'DROP POLICY IF EXISTS "{re.escape(pol)}" ON storage\.objects;\nCREATE POLICY "{re.escape(pol)}"\n.*?;\n', storage, re.S)
    assert m, pol
    STORAGE_POLICIES += m.group(0) + "\n"
grants = mirror("db/views/zzz_function_grants.sql")
for sig in PORTAL_SIGS:
    assert f"GRANT EXECUTE ON FUNCTION {sig} TO supplier_portal;" in grants, sig
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated, service_role;" in grants, sig
triggers = mirror("db/views/zzz_change_log_triggers.sql")
m = re.search(r"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.portal_certificate_submissions\n.*?\n"
              r"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.portal_certificate_submissions\n.*?\n", triggers)
assert m, "change-log triggers for portal_certificate_submissions"
CL_TRIGGERS = m.group(0)
assert "('portal_certificate_submissions'" not in mirror("db/functions/change_log_exclusions.sql")
base = mirror("db/portal-grants-baseline.tsv")
for line in ("relation\tstorage.objects\tINSERT", "policy\tstorage.objects\tportal uploads its own pending submission file",
             "policy\tstorage.objects\tportal reads its own pending submission file",
             "function\tpublic.portal_can_upload_object(p_bucket text, p_name text)\tEXECUTE"):
    assert line in base, line
acct = mirror("db/tables/account_settings.sql")
m1 = re.search(r"^    portal_upload_max_bytes .*?,\n", acct, re.M)
m2 = re.search(r"^    portal_upload_types .*?\n(?:^ {30,}.*\n)*", acct, re.M)
assert m1 and m2, "V39 columns in the account_settings mirror"
COL1 = m1.group(0).strip().rstrip(",")
COL2 = " ".join(x.strip() for x in m2.group(0).splitlines())
m = re.search(r"COMMENT ON TABLE public\.account_settings IS\n.*?;\n", acct, re.S)
assert m, "account_settings comment"
ACCT_COMMENT = m.group(0)
pv = mirror("db/views/pending_values.sql")
assert "'V39'::text AS value_code" in pv

HEADER = """-- db/migrations/2026-10-20-mes9c-certificate-uploads.sql
-- MES-9c —— 供应商门户交证书与员工审核,连同变更记录页的超时修法(F19)。一位门户账号现在能为它自己那一家传一份合规证书或资质文件
--   (PDF、JPEG 或 PNG,每份至多 10 MB —— V39),它等员工接受或驳回(驳回的理由供应商看得见);在员工接受之前,供应商传上来的东西什么都不改。
--   变更记录页在一次几百行的批量操作之后也打得开了。(MES 组的第二十五刀、最后一刀,v1.4.62;发布那一行在 docs/handbacks/MES-9c.md 的抬头。)
--   由 db/scripts/build_mes9c_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-20 委托书:V39 = 10 MB · PDF / JPEG / PNG;MES-9 Step 0 §5 · Q19 · Q25 照推荐;F19)
--   ① account_settings 加两列 V39(portal_upload_max_bytes · portal_upload_types),以 Tim 定的值作默认 —— ADD COLUMN … DEFAULT 让线上那一行
--      当场得到它,不经一次 UPDATE(于是本事务一行变更记录都不写);待补的值 pending_values 加一支 V39(设着时 0 行)。
--   ② 一张新表 portal_certificate_submissions(门户交上来的证书;只经函数写;员工 module.suppliers.view 读;被变更记录记 —— 豁免仍是 9)。
--   ③ 五支门户函数,只授 supplier_portal:portal_certificates · portal_submission_begin(先按 V39 拒,任何字节存下之前)· _finish · _abandon ·
--      portal_can_upload_object(两条存储策略的判据);两支员工函数 portal_submission_accept · _reject(module.suppliers.edit,Q19)。
--   ④ 存储:一个新桶 portal-uploads(10 MB · PDF / JPEG / PNG)、门户角色得到 storage.objects 的 INSERT、三条策略(门户传 / 读回它自己一行
--      uploading 申请登记的那一条路径;员工 module.suppliers.view 读)。没有删除、没有改的策略。存储策略 53 → 56,桶 19 → 20。
--   ⑤ 审计记录:申请表挂在供应商主语下(trail_subject_members 换成多一行的那一份)。
--   ⑥ F19:change_log_rows 多两个参数(p_row_before · p_row_limit)—— 同一组事务里的行按 seq 分页取,一次调用的行数有上界;不给它们 = 原样。
--      签名变了,所以先 DROP 旧签名(函数权限由 apply_migration.sh 随后整份重放 zzz_function_grants.sql 恢复)。
--   门户角色够得着的每一样新东西都按名进了 db/portal-grants-baseline.tsv(判词八):五支函数 · storage.objects 的 INSERT · 两条策略。
--
-- 【不做什么】不碰 hook、登录、刷新、空闲登出与大屏的豁免;不建任何门户账号;不建、不停、不改七个账号中的任何一个;不碰审批开关;
--   不改任何既有的行;不改任何既有的存储对象、桶或别的策略;授权表一行不动;不回填;require_calibrated_since 保持空。
--
-- 【破窗】这一窗什么都不坏:旧应用不读任何新东西;线上没有门户账号;旧的变更记录页不传那两个新参数,读到的与之前逐行相同。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变,hook 对它们每一个仍逐字节原样返回;没有任何门户
--   账号;supplier_portal 能执行的 public 函数恰好十一支、能读的关系恰好 storage.objects、能写的只有 storage.objects 的 INSERT;作用于它的存储策略
--   恰好三条;存储策略 56 条、既有 53 条逐字未变;桶 20 个、既有 19 个逐字未变;存储对象一个字节不动(两张 COD 在内);V39 是 Tim 的值;
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;既有的行逐字未变;本事务一行变更记录都没写;变更记录覆盖零缺口、豁免 9;
--   325 张表;没有一张视图对 anon / authenticated 带写授权。断言失败 = 整笔回滚。

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
        RAISE EXCEPTION 'MES9C_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.portal_certificate_submissions') IS NOT NULL OR to_regprocedure('public.portal_certificates()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'portal-uploads')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'account_settings' AND column_name = 'portal_upload_max_bytes') THEN
        RAISE EXCEPTION 'MES9C_PRE|MES-9c objects already exist';
    END IF;
    IF to_regprocedure('public.portal_document_open(text,uuid)') IS NULL
       OR to_regprocedure('{RESIGNED_FUNCS["change_log_rows"]}') IS NULL THEN
        RAISE EXCEPTION 'MES9C_PRE|MES-9b and the twelve-argument change_log_rows are expected on live';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected the 7 real accounts';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN
        RAISE EXCEPTION 'MES9C_PRE|no portal account is expected on live';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 324 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected 324 public tables';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 53 OR (SELECT count(*) FROM storage.buckets) <> 19 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected 53 storage policies and 19 buckets';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected 9 change-log exclusions';
    END IF;
    IF has_table_privilege('supplier_portal', 'storage.objects', 'INSERT') THEN
        RAISE EXCEPTION 'MES9C_PRE|supplier_portal already inserts into storage.objects';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9C_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES9C_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes9c_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes9c_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes9c_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes9c_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE mes9c_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE mes9c_buckets_before ON COMMIT DROP AS
SELECT id, name, public, file_size_limit, allowed_mime_types::text AS mimes FROM storage.buckets;
CREATE TEMP TABLE mes9c_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append(f"""
-- ── 1 · V39(Tim 2026-10-20):account_settings 加两列,Tim 的值作默认 —— ADD COLUMN … DEFAULT 填上线上那一行,不经 UPDATE ──
ALTER TABLE public.account_settings ADD COLUMN {COL1};
ALTER TABLE public.account_settings ADD COLUMN {COL2};
{ACCT_COMMENT}""")
parts.append("\n-- ── 2 · 新表(镜像原样):门户交上来的证书 ──\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))
parts.append("\n-- 变更记录的两条触发器(与 db/views/zzz_change_log_triggers.sql 同一串字)\n" + CL_TRIGGERS)
parts.append("\n-- ── 3 · 新函数(镜像原样):五支门户函数 · 两支员工审核函数 ──\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 4 · 换掉的函数(镜像原样,同签名):审计记录的主语成员多一行 ──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 5 · F19:change_log_rows 多两个参数 —— 签名变了,先 DROP 旧签名,再按镜像建 ──\n")
for f, old in RESIGNED_FUNCS.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))
parts.append("\n-- ── 6 · 待补的值多一支 V39(镜像原样)──\n\n" + mirror("db/views/pending_values.sql").split("\n", 1)[1].split("CREATE VIEW", 1)[0].rstrip("\n").replace("\n--", "\n--") + "\n")
parts[-1] = "\n-- ── 6 · 待补的值多一支 V39(镜像原样)──\n"
pv_body = pv[pv.index("CREATE VIEW public.pending_values"):]
parts.append("CREATE OR REPLACE VIEW public.pending_values" + pv_body[len("CREATE VIEW public.pending_values"):])
parts.append(f"""
-- ── 7 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):一个桶 · 一条授权 · 三条策略 ──
{STORAGE_BUCKET}
{STORAGE_GRANT}
{STORAGE_POLICIES}""")

acl = ["""
-- ── 8 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in PORTAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon, authenticated, service_role;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO supplier_portal;\n")
for sig in STAFF_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
acl.append("REVOKE EXECUTE ON FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[], bigint, integer) FROM PUBLIC, anon;\n")
acl.append("GRANT EXECUTE ON FUNCTION public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[], bigint, integer) TO authenticated, service_role;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes9c_pending_decider_check")
parts.append("\n-- ── 9 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes9c_rows_before)" for t, (w, d) in DIGEST_TABLES.items())

parts.append(f"""
CREATE TEMP TABLE mes9c_pending_after ON COMMIT DROP AS
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
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES9C_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes9c_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes9c_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES9C_PROOF|an account or its roles changed';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) OR EXISTS (SELECT 1 FROM portal_certificate_submissions) THEN
        RAISE EXCEPTION 'MES9C_PROOF|no portal account and no submission may exist';
    END IF;

    -- ② hook 不变:七个真账号的 event 逐字节原样返回(本刀不碰 hook —— 这一句证它)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ({acct_list}) ORDER BY email LOOP
        v_ev := jsonb_build_object('user_id', a.id, 'authentication_method', 'password',
                    'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', a.id, 'email', a.email,
                                                 'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', gen_random_uuid(),
                                                 'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                                 'user_metadata', '{{}}'::jsonb, 'amr', '[]'::jsonb));
        v_j := portal_access_token_hook(v_ev);
        IF v_j IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'MES9C_PROOF|the hook changed the claims of %', a.email;
        END IF;
    END LOOP;

    -- ③ 门户角色的可达面:public 函数恰好十一支;能读的关系恰好 storage.objects;能写的只有 storage.objects 的 INSERT;作用于它的存储策略恰好三条;
    --    storage 架构只有 USAGE;仍不是任何角色的成员
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'MES9C_PROOF|supplier_portal executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname, ', ' ORDER BY 1), '') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_schema_privilege('supplier_portal', n.oid, 'USAGE') AND has_table_privilege('supplier_portal', c.oid, 'SELECT');
    IF v_bad <> 'storage.objects' THEN RAISE EXCEPTION 'MES9C_PROOF|supplier_portal reads: %', v_bad; END IF;
    SELECT COALESCE(string_agg(n.nspname || '.' || c.relname || ':' || p.priv, ', ' ORDER BY 1), '') INTO v_bad
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
     WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
       AND has_table_privilege('supplier_portal', c.oid, p.priv);
    IF v_bad <> 'storage.objects:INSERT' THEN RAISE EXCEPTION 'MES9C_PROOF|supplier_portal can write: %', v_bad; END IF;
    IF (SELECT count(*) FROM pg_policies WHERE 'supplier_portal' = ANY (roles)) <> 3
       OR NOT has_schema_privilege('supplier_portal', 'storage', 'USAGE') OR has_schema_privilege('supplier_portal', 'storage', 'CREATE')
       OR EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = 'supplier_portal'::regrole) THEN
        RAISE EXCEPTION 'MES9C_PROOF|supplier_portal: three policies, USAGE on storage only, a member of nothing';
    END IF;
    IF has_table_privilege('authenticated', 'public.portal_certificate_submissions', 'INSERT,UPDATE,DELETE,TRUNCATE')
       OR has_table_privilege('anon', 'public.portal_certificate_submissions', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
       OR NOT has_table_privilege('authenticated', 'public.portal_certificate_submissions', 'SELECT') THEN
        RAISE EXCEPTION 'MES9C_PROOF|portal_certificate_submissions grants: authenticated SELECT only, anon nothing';
    END IF;

    -- ④ 存储:策略 56 条,既有的 53 条逐字未变;桶 20 个,既有的 19 个逐字未变;存储对象一个字节不动(两张 COD 在内)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 56
       OR EXISTS (SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM mes9c_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage') THEN
        RAISE EXCEPTION 'MES9C_PROOF|storage policies: expected the 53 unchanged plus three';
    END IF;
    IF (SELECT count(*) FROM storage.buckets) <> 20
       OR EXISTS (SELECT id, name, public, file_size_limit, mimes FROM mes9c_buckets_before
                  EXCEPT SELECT id, name, public, file_size_limit, allowed_mime_types::text FROM storage.buckets)
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'portal-uploads' AND NOT public AND file_size_limit = 10485760
                       AND allowed_mime_types = ARRAY['application/pdf', 'image/jpeg', 'image/png']) THEN
        RAISE EXCEPTION 'MES9C_PROOF|buckets: expected the 19 unchanged plus a private portal-uploads (10 MB · PDF / JPEG / PNG)';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM mes9c_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM mes9c_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'MES9C_PROOF|a stored object changed';
    END IF;

    -- ⑤ V39 是 Tim 的值;它的待补那一支是空的
    IF (SELECT portal_upload_max_bytes FROM account_settings WHERE id) IS DISTINCT FROM 10485760
       OR (SELECT portal_upload_types FROM account_settings WHERE id) IS DISTINCT FROM ARRAY['application/pdf', 'image/jpeg', 'image/png'] THEN
        RAISE EXCEPTION 'MES9C_PROOF|V39 is not 10 MB · PDF / JPEG / PNG';
    END IF;

    -- ⑥ 在途单据一张不少、一张不多;既有的行逐字未变;本事务一行变更记录都没写
    IF EXISTS ((SELECT b.k, b.id FROM mes9c_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes9c_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes9c_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes9c_pending_before b)) THEN
        RAISE EXCEPTION 'MES9C_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES9C_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes9c_log_before), 0) AND c.txid = txid_current()) THEN
        RAISE EXCEPTION 'MES9C_PROOF|this migration wrote change_log rows';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9C_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:325 张表;变更记录覆盖零缺口、豁免 9、新表被记录;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'MES9C_PROOF|expected 325 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9
       OR EXISTS (SELECT 1 FROM change_log_exclusions() x WHERE x.table_name = 'portal_certificate_submissions') THEN
        RAISE EXCEPTION 'MES9C_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'MES9C_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES9C_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑧ 匿名面不变;五支门户函数 authenticated · anon 都调不到;两支员工函数门户 · anon 调不到;change_log_rows 只有新签名那一支
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES9C_PROOF|anon executes: %', v_bad;
    END IF;
    FOREACH k IN ARRAY ARRAY['{"', '".join(PORTAL_SIGS)}'] LOOP
        IF has_function_privilege('authenticated', k::regprocedure, 'EXECUTE') OR has_function_privilege('anon', k::regprocedure, 'EXECUTE')
           OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = k::regprocedure) THEN
            RAISE EXCEPTION 'MES9C_PROOF|%: expected SECURITY DEFINER, executable by supplier_portal only', k;
        END IF;
    END LOOP;
    FOREACH k IN ARRAY ARRAY['{"', '".join(STAFF_SIGS)}'] LOOP
        IF has_function_privilege('supplier_portal', k::regprocedure, 'EXECUTE') OR has_function_privilege('anon', k::regprocedure, 'EXECUTE')
           OR NOT has_function_privilege('authenticated', k::regprocedure, 'EXECUTE') THEN
            RAISE EXCEPTION 'MES9C_PROOF|%: expected executable by authenticated, not by the portal or anon', k;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'change_log_rows') <> 1
       OR to_regprocedure('public.change_log_rows(date,date,text,text,uuid,boolean,bigint,integer,text[],boolean,boolean,text[],bigint,integer)') IS NULL THEN
        RAISE EXCEPTION 'MES9C_PROOF|change_log_rows: expected exactly the fourteen-argument signature';
    END IF;

    -- ⑨ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes9c_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES9C pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes9c_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES9C_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes9c_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

#!/usr/bin/env python3
"""CLAIM-RECEIPTS-1(v1.4.65):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表与它的守卫、新函数、换掉的函数、视图、
存储的桶与两条策略,原样从 db/tables · db/functions · db/views · db/storage 抽出。照抄 build_expense_multiline1_migration.py 的形状。
跑法:python3 db/scripts/build_claim_receipts1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-21-claim-receipts-1.sql"

NEW_FUNCS = ["claim_receipt_begin", "claim_receipt_finish", "claim_receipt_abandon", "claim_receipt_remove",
             "claim_receipt_can_upload", "claim_receipt_can_read", "claim_receipt_limits"]
NEW_SIGS = {
    "claim_receipt_begin": "public.claim_receipt_begin(uuid, text, text, bigint)",
    "claim_receipt_finish": "public.claim_receipt_finish(uuid)",
    "claim_receipt_abandon": "public.claim_receipt_abandon(uuid)",
    "claim_receipt_remove": "public.claim_receipt_remove(uuid)",
    "claim_receipt_can_upload": "public.claim_receipt_can_upload(text, text)",
    "claim_receipt_can_read": "public.claim_receipt_can_read(text, text)",
    "claim_receipt_limits": "public.claim_receipt_limits()",
}
REPLACED_FUNCS = [
    "decide_expense_claim_items",     # Q13:凭据按笔查收据,整张单的附件那条路退役
    "submit_expense_claim_items",     # Q12:回每一笔的 id,表单紧接着传收据
    "trail_subject_members",          # 收据进报销单的审计记录(取代 finance_attachments 那一条)
]
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]
TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"          # tim@evoltrya.test(cfo)—— 只拿来【读】勾稽

DIGEST_TABLES = {
    "finance_attachments": ("", ["claim_id"]),
    "expense_claims": ("", []), "expense_claim_items": ("", []), "expenses": ("", []), "expense_lines": ("", []),
    "accounts": ("", []), "journal_entries": ("", []), "journal_lines": ("", []), "payments": ("", []),
    "payment_allocations": ("", []), "payment_requests": ("", []), "medical_claims": ("", []),
    "approval_log": ("", []), "permissions": ("", []), "role_permissions": ("", []), "roles": ("", []),
    "user_roles": ("", []), "finance_settings": ("", []), "ingest_settings": ("", []), "account_settings": ("", []),
    "cod_issues": ("", []), "employees": ("", []), "suppliers": ("", []), "portal_certificate_submissions": ("", []),
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


def grab(text, pattern, what):
    m = re.search(pattern, text, re.S)
    assert m, what
    return m.group(0)


TABLE_DDL = mirror("db/tables/expense_claim_receipts.sql")
VIEW_DDL = mirror("db/views/expense_claim_status.sql")
assert "has_receipt" not in VIEW_DDL.split("CREATE VIEW", 1)[1]
fa = mirror("db/tables/finance_attachments.sql")
assert "claim_id" not in fa.split("CREATE TABLE", 1)[1]
ONE_PARENT = grab(fa, r"CHECK \(num_nonnulls\(sales_record_id, inbound_batch_id, payment_id, expense_id\) = 1\)", "one_parent")
zzz = mirror("db/views/zzz_change_log_triggers.sql")
CL_BIND = grab(zzz, r"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.expense_claim_receipts\n.*?;\n", "row binding")
CL_BIND += grab(zzz, r"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.expense_claim_receipts\n.*?;\n", "truncate binding")
st = mirror("db/storage/buckets-and-policies.sql")
BUCKET = grab(st, r"INSERT INTO storage\.buckets \(id, name, public, file_size_limit, allowed_mime_types\)\nVALUES \('claim-receipts'.*?;\n", "bucket")
POL_UP = grab(st, r'DROP POLICY IF EXISTS "claim receipts upload own registered path" ON storage\.objects;\nCREATE POLICY .*?;\n', "upload policy")
POL_RD = grab(st, r'DROP POLICY IF EXISTS "claim receipts read by finance\.view or own claim" ON storage\.objects;\nCREATE POLICY .*?;\n', "read policy")
for f in NEW_FUNCS + REPLACED_FUNCS:
    assert (ROOT / f"db/functions/{f}.sql").exists(), f

HEADER = """-- db/migrations/2026-10-21-claim-receipts-1.sql
-- CLAIM-RECEIPTS-1 —— 员工给报销单的【每一笔】传收据。(v1.4.65;发布那一行在 docs/handbacks/CLAIM-RECEIPTS-1.md 的抬头。)
--   由 db/scripts/build_claim_receipts1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-21 的裁定:Step 0 Q1–Q14)
--   ① 新表 expense_claim_receipts:一份文件一行(哪张单 · 哪一笔 · 文件名 / 类型 / 大小 · 桶里的路径 · uploading → attached | abandoned;
--      attached → removed,谁、何时)。只经函数写;财务读全部,员工与替他提单的人读自己那张单的(Q6 · Q7)。
--   ② 函数:claim_receipt_begin(先判:调用者是这张单说的员工或替他提单的人 · 单仍 submitted · 与门户同一个上限 10 MB · PDF / JPEG / PNG ·
--      整个项目的存储不到 900 MB —— 过了才登记一行、给出路径;Q1 · Q4 · Q10)· claim_receipt_finish(字节到了、大小与类型对得上)·
--      claim_receipt_abandon(没传成)· claim_receipt_remove(只在 submitted 时拿掉一份,对象留在桶里;Q5)·
--      claim_receipt_can_upload / claim_receipt_can_read(两条存储策略的判据)· claim_receipt_limits(把上限说出来)。
--   ③ 私有桶 claim-receipts(10 MB · PDF / JPEG / PNG)与 storage.objects 上两条策略:传 = 只有自己登记过、还在 uploading 的那一条路径;
--      读 = finance.view,或自己那张单的。没有 UPDATE、没有 DELETE(Q5:没有任何员工持存储的删除权限)。
--   ④ 批准时凭据【按笔】查收据(decide_expense_claim_items);整张单的附件那条路退役:finance_attachments.claim_id 删掉(线上 0 行,Q13),
--      expense_claim_status 拿掉 has_receipt(那是整张单一个布尔值)。submit_expense_claim_items 回每一笔的 id(Q12)。
--      收据取代 finance_attachments 进报销单的两条审计记录。
--
-- 【不做什么】不碰审批开关、hook、portal-uploads 与它的策略、任何账号与角色;不建任何单据;不改任何分录;require_calibrated_since 保持空。
--   上限读的是门户那两列(account_settings V39,Q1:与门户同一个数)—— 那两列与它们的引导值一个字没改。
--
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):旧的 /me 与 /finance/claims 读 expense_claim_status 用的是 select('*'),has_receipt 不在了
--   就是 undefined —— 每一笔印"无收据"(本来也是:线上 0 份);审批照旧调 decide_expense_claim_items(签名未变),逐笔凭据今天只可能是理由
--   (线上 0 份收据)—— 判词与迁移之前相同。没有一条旧路会撞 42703。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;既有的行逐字未变
--   (finance_attachments 比拿掉 claim_id 之后的);存储:58 条策略 = 之前的 56 条原样 + 两条、21 个桶 = 之前的 20 个原样 + claim-receipts、
--   每一个对象逐字未变;本事务没有写变更记录;清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;两张 COD 原样;328 张表;
--   变更记录覆盖零缺口、豁免 9;匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权;在途单据一张不少、每一张仍有一个决定人。
--   断言失败 = 整笔回滚。

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
RECON_READ = f"""PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);"""

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
CREATE TEMP TABLE cr1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'CR1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.expense_claim_receipts') IS NOT NULL OR to_regprocedure('{NEW_SIGS["claim_receipt_begin"]}') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'claim-receipts') THEN
        RAISE EXCEPTION 'CR1_PRE|the receipts table, its functions or its bucket already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'finance_attachments' AND column_name = 'claim_id') THEN
        RAISE EXCEPTION 'CR1_PRE|expected finance_attachments.claim_id';
    END IF;
    IF EXISTS (SELECT 1 FROM finance_attachments WHERE claim_id IS NOT NULL) THEN
        RAISE EXCEPTION 'CR1_PRE|finance_attachments carries claim attachments (Step 0 measured 0; Tim Q13 retires the column on that measurement)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '{TIM}' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'CR1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 327 THEN
        RAISE EXCEPTION 'CR1_PRE|expected 327 public tables';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 56 OR (SELECT count(*) FROM storage.buckets) <> 20 THEN
        RAISE EXCEPTION 'CR1_PRE|expected 56 storage policies and 20 buckets';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'CR1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'CR1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CR1_PRE|expected the two recorded COD byte strings';
    END IF;
    IF (SELECT portal_upload_max_bytes FROM account_settings WHERE id) IS DISTINCT FROM 10485760
       OR (SELECT portal_upload_types FROM account_settings WHERE id) IS DISTINCT FROM ARRAY['application/pdf', 'image/jpeg', 'image/png']::text[] THEN
        RAISE EXCEPTION 'CR1_PRE|V39 is expected at 10 MB · PDF / JPEG / PNG (Tim Q1: the receipts limit is the same number)';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00 —— 以 tim@(cfo)身份【读】,读完即清
    {RECON_READ}
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'CR1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO cr1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE cr1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE cr1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE cr1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE cr1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
CREATE TEMP TABLE cr1_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE cr1_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE cr1_buckets_before ON COMMIT DROP AS
SELECT id, name, public, file_size_limit, allowed_mime_types::text AS mimes FROM storage.buckets;
""")

parts.append("\n-- ── 1 · 新表(建表脚本原样:db/tables/expense_claim_receipts.sql)──\n")
parts.append(TABLE_DDL)
parts.append("\n-- 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)\n" + CL_BIND)

parts.append(f"""
-- ── 2 · 整张单的附件那条路退役(Q13):视图先拆(它读 claim_id),再删那一列,一个父亲的不变量少一个父亲 ──
DROP VIEW public.expense_claim_status;
ALTER TABLE public.finance_attachments DROP CONSTRAINT finance_attachments_one_parent;
DROP INDEX public.idx_finance_attachments_claim;
ALTER TABLE public.finance_attachments DROP COLUMN claim_id;
ALTER TABLE public.finance_attachments ADD CONSTRAINT finance_attachments_one_parent
        {ONE_PARENT};
""")

parts.append("\n-- ── 3 · 新函数(镜像原样)──\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 4 · 换掉的函数(镜像原样,同签名)──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 5 · expense_claim_status 重建(镜像原样:拿掉 has_receipt)—— 视图的写授权由 apply_migration.sh 随后重放 zzz_function_grants.sql 的 F16 那一段收回;\n--   本事务里的自证要先看到它收回,所以这里也收一次(同一句话)──\n")
parts.append(VIEW_DDL)
parts.append("REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.expense_claim_status FROM anon, authenticated, PUBLIC;\n")

parts.append("\n-- ── 6 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):一个桶 · 两条策略 ──\n")
parts.append(BUCKET + "\n" + POL_UP + "\n" + POL_RD)

grants = "".join(
    f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\nGRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n"
    for sig in NEW_SIGS.values())
grants += ("REVOKE EXECUTE ON FUNCTION public.guard_expense_claim_receipt_mutation() FROM PUBLIC, anon;\n"
           "GRANT EXECUTE ON FUNCTION public.guard_expense_claim_receipt_mutation() TO authenticated, service_role;\n")
parts.append(f"""
-- ── 7 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
{grants}""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "cr1_pending_decider_check")
assert dec.count("'decide_expense_claim'") == 1
dec = dec.replace("'decide_expense_claim'", "'decide_expense_claim_items'")   # 名册登记的是真正把关的那一支
parts.append("\n-- ── 8 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

digest_checks = "\n       OR ".join(
    f"{digest(t, w, [])} IS DISTINCT FROM (SELECT {t} FROM cr1_rows_before)" for t, (w, d) in DIGEST_TABLES.items())

parts.append(f"""
CREATE TEMP TABLE cr1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_recon jsonb;
    k       text;
BEGIN
    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'CR1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM cr1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM cr1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'CR1_PROOF|an account or its roles changed';
    END IF;

    -- ② 在途单据一张不少、一张不多;既有的行逐字未变(finance_attachments 比拿掉 claim_id 之后的);本事务一行变更记录都没写
    IF EXISTS ((SELECT b.k, b.id FROM cr1_pending_before b EXCEPT SELECT a2.k, a2.id FROM cr1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM cr1_pending_after a2 EXCEPT SELECT b.k, b.id FROM cr1_pending_before b)) THEN
        RAISE EXCEPTION 'CR1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'CR1_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS (SELECT 1 FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM cr1_log_before), 0) AND c.txid = txid_current()) THEN
        RAISE EXCEPTION 'CR1_PROOF|this migration wrote change_log rows';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CR1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;

    -- ③ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    {RECON_READ}
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM cr1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'CR1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ④ 结构:新函数在;claim_id 不在;新表开着 RLS、anon 一个权限都没有、authenticated 只读;收据 0 行
    IF to_regprocedure('{NEW_SIGS["claim_receipt_begin"]}') IS NULL OR to_regprocedure('{NEW_SIGS["claim_receipt_finish"]}') IS NULL
       OR to_regprocedure('{NEW_SIGS["claim_receipt_abandon"]}') IS NULL OR to_regprocedure('{NEW_SIGS["claim_receipt_remove"]}') IS NULL
       OR to_regprocedure('{NEW_SIGS["claim_receipt_can_upload"]}') IS NULL OR to_regprocedure('{NEW_SIGS["claim_receipt_can_read"]}') IS NULL
       OR to_regprocedure('{NEW_SIGS["claim_receipt_limits"]}') IS NULL THEN
        RAISE EXCEPTION 'CR1_PROOF|a receipt function is missing';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'finance_attachments' AND column_name = 'claim_id')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expense_claim_status' AND column_name = 'has_receipt') THEN
        RAISE EXCEPTION 'CR1_PROOF|the claim-wide attachment route is still there';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.expense_claim_receipts'::regclass)
       OR has_table_privilege('anon', 'public.expense_claim_receipts', 'SELECT')
       OR has_table_privilege('authenticated', 'public.expense_claim_receipts', 'INSERT')
       OR has_table_privilege('authenticated', 'public.expense_claim_receipts', 'UPDATE')
       OR has_table_privilege('authenticated', 'public.expense_claim_receipts', 'DELETE')
       OR NOT has_table_privilege('authenticated', 'public.expense_claim_receipts', 'SELECT')
       OR (SELECT count(*) FROM expense_claim_receipts) <> 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|the receipts table is not read-only-under-RLS for authenticated, closed to anon, and empty';
    END IF;

    -- ⑤ 存储:之前的 56 条策略原样 + 两条;之前的 20 个桶原样 + claim-receipts(私有 · 10 MB · PDF / JPEG / PNG);每一个对象逐字未变
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 58
       OR EXISTS (SELECT policyname, cmd, roles, qual, with_check FROM cr1_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage')
       OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND policyname IN ('claim receipts upload own registered path',
              'claim receipts read by finance.view or own claim') AND roles = ARRAY['authenticated']::name[]) <> 2
       OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND cmd IN ('UPDATE', 'DELETE', 'ALL')
                   AND COALESCE(qual, '') || COALESCE(with_check, '') LIKE '%claim-receipts%') THEN
        RAISE EXCEPTION 'CR1_PROOF|storage policies: expected the 56 unchanged plus the two receipt policies, and no update / delete on claim-receipts';
    END IF;
    IF (SELECT count(*) FROM storage.buckets) <> 21
       OR EXISTS (SELECT id, name, public, file_size_limit, mimes FROM cr1_buckets_before
                  EXCEPT SELECT id, name, public, file_size_limit, allowed_mime_types::text FROM storage.buckets)
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'claim-receipts' AND NOT public AND file_size_limit = 10485760
                       AND allowed_mime_types = ARRAY['application/pdf', 'image/jpeg', 'image/png']) THEN
        RAISE EXCEPTION 'CR1_PROOF|buckets: expected the 20 unchanged plus a private claim-receipts (10 MB · PDF / JPEG / PNG)';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM cr1_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM cr1_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'CR1_PROOF|a stored object changed';
    END IF;

    -- ⑥ 328 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 328 THEN
        RAISE EXCEPTION 'CR1_PROOF|expected 328 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'CR1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'CR1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'CR1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.cr1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'CR1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.cr1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'CR1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.cr1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

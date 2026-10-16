#!/usr/bin/env python3
"""MES-8a(v1.4.56):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数、新视图与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(权限目录一行与它声明的查看码、单据登记一行、两行授权)在这里逐句写出,
并先断言镜像里那几行真的是这个样子。照抄 build_mes7b2_migration.py 的形状。
跑法:python3 db/scripts/build_mes8a_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql"

NEW_TABLES = ["supplier_score_settings", "supplier_scorecard_reviews", "supplier_statements", "supplier_statement_issues"]
# 先于新表:三支触发器函数
NEW_FUNCS_EARLY = ["guard_supplier_scorecard_review_write", "guard_supplier_statement_write", "guard_supplier_statement_issue_write"]
NEW_FUNCS_LATE = ["supplier_scorecard_measure_keys", "supplier_scorecard_grade", "supplier_scorecard_measures", "supplier_scorecard_preview",
                  "record_supplier_review", "set_supplier_score_settings", "supplier_grade_advice_internal", "supplier_grade_advice",
                  "supplier_statement_data", "next_supplier_statement_code", "issue_supplier_statement", "record_supplier_statement_issue"]
# 同签名替换:采购单多一个返回键 · F17 · 审计主语与成员
REPLACED_FUNCS = ["create_purchase_order", "record_cod_issue", "trail_subjects", "trail_subject_members"]
NEW_VIEWS = ["grn_discrepancies_all", "supplier_latest_reviews", "supplier_scorecard_rows", "supplier_statement_rows"]
REPLACED_VIEWS = ["grn_discrepancies", "operations_now", "pending_values"]

STAFF_SIGS = ["public.supplier_scorecard_measures(uuid, date, date)",
              "public.supplier_scorecard_preview(uuid, date, date)",
              "public.record_supplier_review(uuid, date, date, text, uuid, text)",
              "public.set_supplier_score_settings(jsonb, jsonb, integer, jsonb)",
              "public.supplier_grade_advice(uuid, jsonb, numeric)",
              "public.supplier_statement_data(uuid, date, date)",
              "public.issue_supplier_statement(uuid, date, date, text)",
              "public.record_supplier_statement_issue(uuid, text, text)"]
PLAIN_SIGS = ["public.supplier_scorecard_measure_keys()", "public.supplier_scorecard_grade(jsonb, jsonb, jsonb)",
              "public.next_supplier_statement_code(date)"]
INTERNAL_SIGS = ["public.guard_supplier_scorecard_review_write()", "public.guard_supplier_statement_write()",
                 "public.guard_supplier_statement_issue_write()",
                 "public.supplier_grade_advice_internal(uuid, jsonb, numeric)"]

# 前后比对的表(既有的行逐字未变)。授权比对时减掉本刀那两行;权限目录与单据登记只比本刀那一行以外的。
DIGEST_TABLES = {
    "suppliers": ("", []), "purchase_orders": ("", []), "purchase_order_lines": ("", []), "purchase_order_payment_terms": ("", []),
    "inbound_batches": ("", []), "output_batches": ("", []), "inventory_movements": ("", []), "journal_entries": ("", []),
    "journal_lines": ("", []), "payments": ("", []), "payment_allocations": ("", []), "expenses": ("", []),
    "freight_documents": ("", []), "prepayment_applications": ("", []), "supplier_compliance": ("", []),
    "nonconformance_reports": ("", []), "assay_disputes": ("", []), "assay_results": ("", []), "customer_statements": ("", []),
    "statement_issues": ("", []), "certificates_of_destruction": ("", []), "cod_issues": ("", []),
    "certificates_of_analysis": ("", []), "coa_issues": ("", []), "materials": ("", []), "employees": ("", []),
    "approval_log": ("", []), "accounts": ("", []), "list_ledger_residue": ("", []), "receiving_settings": ("", []),
    "certificate_types": ("", []), "contract_document_terms": ("", []),
    "permissions": ("WHERE code <> 'action.supplier_review'", []),
    "role_permissions": ("WHERE permission_code <> 'action.supplier_review'", []),
    "roles": ("", []), "user_roles": ("", []),
    "document_types": ("WHERE key <> 'supplier_statement'", []), "ingest_settings": ("", []), "finance_settings": ("", []),
    "tasks": ("", []), "incidents": ("", []),
}


def fn(name, create=False):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    if create:
        assert body.count("CREATE OR REPLACE FUNCTION") == 1, name
        body = body.replace("CREATE OR REPLACE FUNCTION", "CREATE FUNCTION")
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def view(name, replace=False):
    text = mirror(f"db/views/{name}.sql")
    assert text.count(f"CREATE VIEW public.{name} ") == 1, name
    if replace:
        text = text.replace(f"CREATE VIEW public.{name} ", f"CREATE OR REPLACE VIEW public.{name} ")
    return "\n" + text


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


def digest(t, where, drop):
    j = "to_jsonb(t)" + "".join(f" - '{k}'" for k in drop)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t {where})"


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
DOC = "db/tables/document_types.sql"
DOC_ROW = must(DOC, "    ('supplier_statement', 'SST', 'supplier_statements', 'gapless', NULL, '/finance/supplier-statements', 'detail', 'superseded_reason', ARRAY['superseded_reason']::text[], ARRAY['module.finance.view']::text[]);")
PERM = "db/tables/permissions.sql"
m = re.search(r"    \('action\.supplier_review', 'action', .*?, 1260\)", mirror(PERM), re.S)
assert m, "permission row"
PERM_ROW = m.group(0)
must(PERM, "    ('action.supplier_review',          ARRAY['module.suppliers.view']),\n")

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m2 = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                   rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m2, t
    bind_sql.append(m2.group(0))
grants = mirror("db/views/zzz_function_grants.sql")
for sig in INTERNAL_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" in grants, sig
for sig in STAFF_SIGS + PLAIN_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" not in grants, sig
assert "'V23'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "'V24'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "'supplier_review_due'::text AS item_type" in mirror("db/views/operations_now.sql")
assert "('supplier_statement',     ARRAY['module.finance.view'],   'supplier_statements'" in mirror("db/functions/trail_subjects.sql")
assert "('supplier_statement',  1, 'supplier_statement_issues'" in mirror("db/functions/trail_subject_members.sql")
assert "COD_BYTES_ALREADY_RECORDED" in mirror("db/functions/record_cod_issue.sql")
assert "'warnings', supplier_grade_advice_internal(" in mirror("db/functions/create_purchase_order.sql")

HEADER = """-- db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql
-- MES-8a —— 供应商评分卡与供应商对账单:每一家供应商有了一张计数的评分卡(短交与超交、质量问题、化验争议、放电判断不一致、证书断档),
--   一次记下的评审在权重给了之后给它一个等级 —— 等级显示在采购单上,预付超过那一等级的上限时给一条警告;财务可以签发一份必须对得上应付总账的
--   供应商对账单(SST-…),下载的 PDF 定格在签发那一刻。顺带(F17)销毁证书的字节档补齐分析证书那一侧的三条检查。
--   (MES 组的第二十刀,v1.4.56;发布那一行在 docs/handbacks/MES-8a.md 的抬头。)由 db/scripts/build_mes8a_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-16:三刀而不是五刀(Q1);MES-8 Step 0 的 Q2–Q9 · Q21–Q25 · Q27 照推荐裁定,8a 那一半)
--   ① 四张新表:supplier_score_settings(单行;V23 权重 · 等级线 · 评审周期,V24 每一等级的预付上限与抽样级别 —— 全空引导)·
--      supplier_scorecard_reviews(只追加;计数、V23 / V24 与等级【抄进来】;更正 = 引用它、带理由的新评审)·
--      supplier_statements(SST- 按年无洞、不截 4 位;六个本位币数、明细、期末未结、挂账、尚未计价的收货【冻下来】;取代带理由)·
--      supplier_statement_issues(PDF 的每一版:路径与 sha256,只追加)。
--   ② 函数:supplier_scorecard_measures(现算的计数,"not compared" 永远不是 0;等级超标只显示)· supplier_scorecard_grade · _measure_keys ·
--      _preview · record_supplier_review · set_supplier_score_settings · supplier_grade_advice(_internal)(预付警告与抽样建议)·
--      supplier_statement_data(总账 2000 归到这一家 vs 期末未结 − 挂账 − 残留)· issue_supplier_statement(对不上按名拒)·
--      next_supplier_statement_code · record_supplier_statement_issue · 两支守卫。
--   ③ create_purchase_order 返回值末尾多一个 warnings 键(PREPAYMENT_ABOVE_GRADE_CAP —— 从不拒绝);同签名替换。
--   ④ F17:record_cod_issue 补 record_coa_issue 的三条(哈希小写 · 路径前缀 · 已记过的字节按名拒);同签名替换。
--   ⑤ grn_discrepancies 拆成底视图 grn_discrepancies_all + 外壳(列集一字未变,门照旧 module.purchasing.view)—— 评分卡以 suppliers.view 读同一份定义。
--   ⑥ 新码 action.supplier_review(声明 module.suppliers.view),授 admin · cco —— 本刀唯一的授权改动(Q6);单据登记 SST(61 → 62);
--      提醒一支 supplier_review_due(V23 的周期空着时一行都不出,Q27;70 → 71);待补的值两支 V23 · V24(29 → 31);审计主语三个与成员;
--      四张新表进变更记录(豁免仍是 8);没有遮蔽的列(规则仍 119)。
--   ⑦ 私有桶 supplier-statement-documents 与它的三条策略(读 module.finance.view;传 module.finance.edit;删 module.finance.edit 且那个对象还没被记)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多 action.supplier_review 那两行;不写、不改任何一家供应商、一张采购单、收货、付款、
--   费用、运费单、预付冲抵、分录、不合格报告、争议、证书、对账单或销毁证书(两张已签发的 COD 的字节与档案一个字不动);不建任何评审、设定、对账单;
--   不回填(Q94);require_calibrated_since 保持空。线上由本迁移造出的只有:四张表(设定那一行四样全空)、目录一行与两行授权、单据登记一行、一个空桶。
--
-- 【破窗】(Q23:这一窗什么都不坏)旧应用不读新表;create_purchase_order 只在返回值末尾多一个键(旧应用不认它);record_cod_issue 多的三条拒绝,
--   旧应用的路由本来就只传 <证书 id>/… 的路径、小写的哈希、每张证书一次;grn_discrepancies 列集一字未变;operations_now 只多一支(V23 周期空着,
--   一行都不出);pending_values 只多两支(旧应用的待补值页认不得 V23 / V24 两个值码,会画成键名,直到部署)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了 action.supplier_review 的两行(admin · cco),admin 持目录里每一个码(82),
--   每一个持动作码的角色也持它声明的查看码;在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的行逐字未变
--   (见 DIGEST_TABLES);评审与对账单表空、设定那一行四样全空;anon 能执行的【恰好】两支;员工函数 DEFINER、调得到,守卫与内层调不到;那 44 条开着的
--   读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 119);提醒臂 71、待补的值 31 支;单据登记 62 行;317 张表;没有一张视图对 anon /
--   authenticated 带写授权;桶私有、空、三条策略。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

VIEW_WRITE_SQL = """(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')))"""

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-8a/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES8A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.supplier_scorecard_reviews') IS NOT NULL OR to_regclass('public.supplier_statements') IS NOT NULL
       OR to_regclass('public.supplier_score_settings') IS NOT NULL OR to_regclass('public.grn_discrepancies_all') IS NOT NULL
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'supplier_statement' OR prefix = 'SST')
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.supplier_review')
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'supplier-statement-documents') THEN
        RAISE EXCEPTION 'MES8A_PRE|MES-8a objects already exist';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES8A_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 81
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8A_PRE|expected a catalogue of 81 codes, all held by admin';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM roles WHERE code = 'cco' AND is_active) OR NOT EXISTS (SELECT 1 FROM roles WHERE code = 'admin' AND is_active) THEN
        RAISE EXCEPTION 'MES8A_PRE|the roles admin and cco must exist (action.supplier_review goes to them, Q6)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'cco' AND rp.permission_code = 'module.suppliers.view') THEN
        RAISE EXCEPTION 'MES8A_PRE|cco must hold module.suppliers.view (the code action.supplier_review declares)';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 61 THEN
        RAISE EXCEPTION 'MES8A_PRE|expected 61 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8A_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8A_PRE|expected 119 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 70 THEN
        RAISE EXCEPTION 'MES8A_PRE|operations_now should have 70 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 29 THEN
        RAISE EXCEPTION 'MES8A_PRE|pending_values should have 29 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 313 THEN
        RAISE EXCEPTION 'MES8A_PRE|expected 313 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8A_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES8A_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes8a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes8a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes8a_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes8a_cod_objects_before ON COMMIT DROP AS
SELECT name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects WHERE bucket_id = 'cod-documents';
CREATE TEMP TABLE mes8a_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新函数(镜像原样),先于新表:三支守卫(评审只追加 · 签发了的对账单只许被取代 · 签发档只追加)──\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append("\n-- ── 2 · 新表(镜像原样):评分的设定 · 评审 · 供应商对账单 · 它的签发档 ─────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 3 · 权限目录一行 + 它声明的查看码(与 db/tables/permissions.sql 逐字同一份)· 单据登记 SST(与 db/tables/document_types.sql 那一行同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROW};
UPDATE public.permissions SET requires_view_any = ARRAY['module.suppliers.view'] WHERE code = 'action.supplier_review';
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}

-- ── 4 · 授权(MES-0 Q90 · MES-8 Step 0 Q6):action.supplier_review → admin · cco —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.supplier_review' FROM roles r WHERE r.code IN ('admin', 'cco')
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append("\n-- ── 5 · 新函数(镜像原样),新表之后 ──────────────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 6 · 换掉的函数(镜像原样,同签名):采购单多一个返回键 · F17 · 审计主语与成员 ──────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 7 · 视图(镜像原样):收货差异的底视图 · 最近的评审 · 评分卡清单 · 对账单清单;收货差异的外壳(列集未变)· 提醒 +1 支 · 待补的值 +V23 +V24 ──\n")
for v in NEW_VIEWS:
    parts.append(view(v))
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append("\n-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + PLAIN_SIGS + INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

parts.append("""
-- ── 10 · 私有桶 supplier-statement-documents 与它的三条策略(桶不在镜像里 —— AGENTS.md;它的证明是
--   db/scripts/2026-10-16-mes8a-live-proof.mjs 的 PDF 一段)。只收 PDF、≤ 10 MB。读:module.finance.view(对账单的读码)。
--   传:module.finance.edit(签发的那一个码)。删:module.finance.edit【并且】那个对象还没被记进 supplier_statement_issues —— 记哈希失败留下的孤儿
--   可以由签发的人清掉;记下了的字节谁都删不掉。改:一条策略都不给(覆盖一份已存的字节,就是改一份寄出去过的对账单)。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('supplier-statement-documents', 'supplier-statement-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "supplier-statement-documents read by finance view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'supplier-statement-documents'::text AND public.has_permission('module.finance.view'::text));

CREATE POLICY "supplier-statement-documents upload by finance edit"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'supplier-statement-documents'::text AND public.has_permission('module.finance.edit'::text));

CREATE POLICY "supplier-statement-documents remove unrecorded by finance edit"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'supplier-statement-documents'::text AND public.has_permission('module.finance.edit'::text)
           AND NOT EXISTS (SELECT 1 FROM public.supplier_statement_issues i WHERE i.file_path = objects.name));
""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes8a_pending_decider_check")
parts.append("\n-- ── 11 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8A_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
plain_checks = "\n".join(
    f"""    IF NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8A_PROOF|{sig}: expected authenticated yes, anon no';
    END IF;""" for sig in PLAIN_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8A_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes8a_rows_before)" for t, (w, d) in DIGEST_TABLES.items())
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)
empty_checks = "\n       OR ".join(f"EXISTS (SELECT 1 FROM {t})" for t in NEW_TABLES if t != "supplier_score_settings")

parts.append(f"""
CREATE TEMP TABLE mes8a_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权:恰好多了 action.supplier_review 的两行(admin · cco);目录 82 个码,admin 持每一个;持动作码的角色也持它声明的查看码
    IF (SELECT count(*) FROM permissions) <> 82
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8A_PROOF|admin does not hold every one of the 82 codes';
    END IF;
    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = 'action.supplier_review';
    IF v_bad IS DISTINCT FROM 'admin,cco' THEN
        RAISE EXCEPTION 'MES8A_PROOF|action.supplier_review is held by % (ruled: admin,cco)', COALESCE(v_bad, '<nobody>');
    END IF;
    IF (SELECT requires_view_any FROM permissions WHERE code = 'action.supplier_review') IS DISTINCT FROM ARRAY['module.suppliers.view'] THEN
        RAISE EXCEPTION 'MES8A_PROOF|action.supplier_review must declare module.suppliers.view';
    END IF;
    SELECT string_agg(r.code || ':' || p.code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES8A_PROOF|an action code is held without its declared view: %', v_bad;
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES8A_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes8a_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes8a_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES8A_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变;两张 COD 的存储对象一个字节不动
    IF EXISTS ((SELECT b.k, b.id FROM mes8a_pending_before b EXCEPT SELECT a.k, a.id FROM mes8a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes8a_pending_after a EXCEPT SELECT b.k, b.id FROM mes8a_pending_before b)) THEN
        RAISE EXCEPTION 'MES8A_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES8A_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS ((SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents'
                EXCEPT SELECT name, size, etag FROM mes8a_cod_objects_before)
               UNION ALL
               (SELECT name, size, etag FROM mes8a_cod_objects_before
                EXCEPT SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents')) THEN
        RAISE EXCEPTION 'MES8A_PROOF|a COD object changed';
    END IF;

    -- ④ 评审与对账单一行都没有;设定那一行在、四样全空
    IF {empty_checks} THEN
        RAISE EXCEPTION 'MES8A_PROOF|no review, statement or issue may be created';
    END IF;
    IF (SELECT count(*) FROM supplier_score_settings) <> 1
       OR EXISTS (SELECT 1 FROM supplier_score_settings WHERE weights IS NOT NULL OR grade_lines IS NOT NULL
                                                           OR review_window_days IS NOT NULL OR grade_caps IS NOT NULL) THEN
        RAISE EXCEPTION 'MES8A_PROOF|the settings row must exist with V23 and V24 empty (Q4: nothing is guessed)';
    END IF;

    -- ⑤ 本事务往变更记录只写了:目录一行(+ 它的查看码)、两行授权、单据登记一行、设定那一行(按 txid 认)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes8a_log_before), 0) AND c.txid = txid_current()
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types', 'supplier_score_settings'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8A_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes8a_log_before), 0) AND c.txid = txid_current()
          AND c.table_name = 'role_permissions') <> 2 THEN
        RAISE EXCEPTION 'MES8A_PROOF|expected exactly two role_permissions rows written';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8A_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:守卫在;单据登记 62 行,SST 一行;317 张表;审计主语在册;F17 的三条在
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_supplier_scorecard_reviews_immutable' AND tgrelid = 'public.supplier_scorecard_reviews'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_supplier_statements_write' AND tgrelid = 'public.supplier_statements'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_supplier_statement_issues_append_only' AND tgrelid = 'public.supplier_statement_issues'::regclass) THEN
        RAISE EXCEPTION 'MES8A_PROOF|a guard trigger is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 62 OR document_type_prefix('supplier_statement') <> 'SST' THEN
        RAISE EXCEPTION 'MES8A_PROOF|document_types should be 62 with SST';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 317 THEN
        RAISE EXCEPTION 'MES8A_PROOF|expected 317 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'supplier_statement' AND s.view_codes = ARRAY['module.finance.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'supplier_scorecard_review' AND s.root_rule = 'collection')
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'supplier_score_settings')
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'supplier_statement' AND m.table_name = 'supplier_statement_issues' AND m.home) THEN
        RAISE EXCEPTION 'MES8A_PROOF|the supplier trail subjects or members are missing';
    END IF;
    IF position('COD_ISSUE_PATH_INVALID' IN pg_get_functiondef('public.record_cod_issue(uuid, text, text)'::regprocedure)) = 0
       OR position('COD_BYTES_ALREADY_RECORDED' IN pg_get_functiondef('public.record_cod_issue(uuid, text, text)'::regprocedure)) = 0
       OR position('lower(p_sha256)' IN pg_get_functiondef('public.record_cod_issue(uuid, text, text)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'MES8A_PROOF|F17: record_cod_issue lacks one of its three checks';
    END IF;

    -- ⑦ 匿名面与函数面
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES8A_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{plain_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8A_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.grn_discrepancies_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES8A_PROOF|the base view grn_discrepancies_all must not be readable by authenticated';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8A_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(四张新表记,豁免仍是 8);遮蔽零缺口(规则仍 119 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES8A_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8A_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 提醒臂 71(supplier_review_due 一行都不出 —— 周期空着)、待补的值 31 支(V23 一行;V24 没有等级线 → 0 行)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 71
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 31 THEN
        RAISE EXCEPTION 'MES8A_PROOF|reminder arms 71 / pending-value arms 31 expected';
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES8A_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑫ 桶:私有、空、三条策略
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'supplier-statement-documents' AND NOT public)
       OR EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'supplier-statement-documents')
       OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
             AND policyname LIKE 'supplier-statement-documents %') <> 3 THEN
        RAISE EXCEPTION 'MES8A_PROOF|bucket supplier-statement-documents must exist, be private, be empty and carry exactly three policies';
    END IF;

    -- ⑬ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes8a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES8A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes8a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES8A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes8a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

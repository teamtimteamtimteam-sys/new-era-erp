#!/usr/bin/env python3
"""MES-8b-1(v1.4.57):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数、新视图与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(权限目录两行与动作码声明的查看码、单据登记一行、八行授权)在这里逐句写出,
并先断言镜像里那几行真的是这个样子。照抄 build_mes8a_migration.py 的形状。
跑法:python3 db/scripts/build_mes8b1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql"

NEW_TABLES = ["compliance_settings", "compliance_packs", "compliance_pack_issues"]
# 先于新表:两支触发器函数
NEW_FUNCS_EARLY = ["guard_compliance_pack_write", "guard_compliance_pack_issue_write"]
NEW_FUNCS_LATE = ["inbound_batch_margin", "inventory_metal_exposure", "compliance_pack_data", "freeze_compliance_pack",
                  "record_compliance_pack_issue", "set_compliance_settings", "compliance_pack_month_status"]
# 同签名替换:审计主语与成员
REPLACED_FUNCS = ["trail_subjects", "trail_subject_members"]
NEW_VIEWS = []
REPLACED_VIEWS = ["operations_now", "pending_values"]

STAFF_SIGS = ["public.inbound_batch_margin(uuid)",
              "public.inventory_metal_exposure()",
              "public.compliance_pack_data(date)",
              "public.freeze_compliance_pack(date, text, text)",
              "public.record_compliance_pack_issue(uuid, text, text)",
              "public.set_compliance_settings(text, text, text, text)",
              "public.compliance_pack_month_status(date)"]
PLAIN_SIGS = []
INTERNAL_SIGS = ["public.guard_compliance_pack_write()", "public.guard_compliance_pack_issue_write()"]

NEW_CODES = ("module.compliance.view", "action.compliance_pack")
GRANTS = {"module.compliance.view": ["admin", "auditor", "cco", "cfo", "cto", "gm"], "action.compliance_pack": ["admin", "cto"]}

# 前后比对的表(既有的行逐字未变)。授权比对时减掉本刀那八行;权限目录与单据登记只比本刀那几行以外的。
DIGEST_TABLES = {
    "inbound_batches": ("", []), "output_batches": ("", []), "inventory_movements": ("", []), "processing_runs": ("", []),
    "processing_inputs": ("", []), "processing_outputs": ("", []), "sales_records": ("", []), "sales_settlements": ("", []),
    "metal_prices": ("", []), "metal_price_indices": ("", []), "inbound_batch_metals": ("", []), "output_batch_metals": ("", []),
    "substances": ("", []), "materials": ("", []), "material_kinds": ("", []),
    "journal_entries": ("", []), "journal_lines": ("", []), "payments": ("", []), "payment_allocations": ("", []), "expenses": ("", []),
    "suppliers": ("", []), "purchase_orders": ("", []), "customers": ("", []),
    "company_compliance": ("", []), "licence_storage_limits": ("", []), "nea_waste_categories": ("", []), "receipt_ceiling_checks": ("", []),
    "incidents": ("", []), "incident_updates": ("", []), "environmental_results": ("", []), "environmental_parameters": ("", []),
    "inspection_templates": ("", []), "inspection_runs": ("", []), "inspection_results": ("", []), "inspection_findings": ("", []),
    "inspection_finding_closures": ("", []), "management_packs": ("", []), "company_profile": ("", []),
    "supplier_statements": ("", []), "supplier_statement_issues": ("", []), "certificates_of_destruction": ("", []), "cod_issues": ("", []),
    "certificates_of_analysis": ("", []), "coa_issues": ("", []), "customer_statements": ("", []), "statement_issues": ("", []),
    "approval_log": ("", []), "accounts": ("", []), "employees": ("", []), "tasks": ("", []),
    "permissions": ("WHERE code NOT IN ('module.compliance.view', 'action.compliance_pack')", []),
    "role_permissions": ("WHERE permission_code NOT IN ('module.compliance.view', 'action.compliance_pack')", []),
    "roles": ("", []), "user_roles": ("", []),
    "document_types": ("WHERE key <> 'compliance_pack'", []), "ingest_settings": ("", []), "finance_settings": ("", []),
    "safety_settings": ("", []), "supplier_score_settings": ("", []),
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
DOC_ROW = must(DOC, "    ('compliance_pack', 'CPK', 'compliance_packs', 'gapless', NULL, '/compliance/packs', 'detail', 'superseded_reason', ARRAY['superseded_reason']::text[], ARRAY['module.compliance.view']::text[]);")
PERM = "db/tables/permissions.sql"
m = re.search(r"    \('module\.compliance\.view', 'module', .*?, 154\)", mirror(PERM), re.S)
assert m, "permission row module.compliance.view"
PERM_ROW_VIEW = m.group(0)
m = re.search(r"    \('action\.compliance_pack', 'action', .*?, 1270\)", mirror(PERM), re.S)
assert m, "permission row action.compliance_pack"
PERM_ROW_ACTION = m.group(0)
must(PERM, "    ('action.compliance_pack',          ARRAY['module.compliance.view']),\n")

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
assert "'V26'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "'V27'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "'compliance_pack_not_frozen'::text AS item_type" in mirror("db/views/operations_now.sql")
assert "('compliance_pack',        ARRAY['module.compliance.view'], 'compliance_packs'" in mirror("db/functions/trail_subjects.sql")
assert "('compliance_pack',     1, 'compliance_pack_issues'" in mirror("db/functions/trail_subject_members.sql")

HEADER = """-- db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql
-- MES-8b-1 —— 进料毛利、库存敞口与月度合规包:每一批进料看得到它到今天为止经由用它做出来、卖出去的每一样赚了多少(没卖的按成本在库);
--   价格敞口页多一节「还在库的可计价金属按最新的价值多少」;一个关了账的月份可以冻成一份合规包(CPK-…),带那个月的物料平衡、库存变动、
--   执照位置、事故、环境监测与巡检,下载的 PDF 定格在冻下来那一刻。
--   (MES 组的第二十一刀,v1.4.57;发布那一行在 docs/handbacks/MES-8b-1.md 的抬头。)由 db/scripts/build_mes8b1_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-17:MES-8 Step 0 的 Q10–Q18 · Q28,以及 Q21–Q24 里 8b-1 那一半,照推荐裁定)
--   ① 三张新表:compliance_settings(单行;V26 NEA 申报的格式与频率,V27 欧盟回收效率的方法与目标 —— 全空引导)·
--      compliance_packs(CPK-YYYY-MM,重出 -2;payload 冻下来;只许被取代)· compliance_pack_issues(PDF 的每一版:路径与 sha256,只追加)。
--   ② 函数:inbound_batch_margin(按投入质量的份额逐层乘下去;收入只取 sales_records;任一条腿没价 → not computable,永远不是 0)·
--      inventory_metal_exposure(可计价金属 × 在库 × 含量 × 今天或之前最新的价,带价的日子;not measured · no price · price ambiguous)·
--      compliance_pack_data(八节)· freeze_compliance_pack(只冻关了账的月份)· record_compliance_pack_issue · set_compliance_settings ·
--      compliance_pack_month_status(月结那一行)· 两支守卫。两支读者的门都是常设决定 2:data.view_prices AND (finance.view OR processing.view)。
--   ③ 新码 module.compliance.view → admin · auditor · cco · cfo · cto · gm;action.compliance_pack(声明 module.compliance.view)→ admin · cto
--      —— 本刀唯一的授权改动(Q17,八行);单据登记 CPK(62 → 63);提醒一支 compliance_pack_not_frozen(71 → 72);待补的值两支 V26 · V27(31 → 33);
--      审计主语两个与成员一个;三张新表进变更记录(豁免仍是 8);没有遮蔽的列(规则仍 119)。
--   ④ 私有桶 compliance-documents 与它的三条策略(读 module.compliance.view;传 action.compliance_pack;删 action.compliance_pack 且那个对象还没被记)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多上面那八行;不写、不改任何一批进料、产出、流水、销售、结算、价、含量、执照、
--   事故、监测、巡检、分录、对账单、证书或销毁证书(两张已签发的 COD 的字节与档案一个字不动);不冻任何一份包、不给 V26 / V27;不锁也不开任何一个月;
--   不回填;require_calibrated_since 保持空。线上由本迁移造出的只有:三张表(设定那一行四样全空)、目录两行与八行授权、单据登记一行、一个空桶。
--
-- 【破窗】(Q23:这一窗什么都不坏)旧应用不读新表与新函数;operations_now 只多一支(线上 locked_before = system_start_date = 2026-08-01,
--   没有一个已关账的月 → 一行都不出);pending_values 只多两支(V26 · V27 各一行;旧应用的待补值页认不得这两个值码,会画成键名,直到部署);
--   trail_subjects / trail_subject_members 只多三行(旧应用不认这两个主语,从不问它们)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那八行,admin 持目录里每一个码(84),每一个持动作码的角色也持它声明的
--   查看码;在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的行逐字未变(见 DIGEST_TABLES);
--   包与签发档空、设定那一行四样全空;anon 能执行的【恰好】两支;员工函数 DEFINER、调得到,守卫调不到;那 44 条开着的读策略还是 44 条;
--   变更记录覆盖与遮蔽零缺口(豁免 8、规则 119);提醒臂 72(新那一支一行都不出)、待补的值 33 支;单据登记 63 行;320 张表;没有一张视图对 anon /
--   authenticated 带写授权;桶私有、空、三条策略;两张 COD 的存储对象一个字节不动。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

VIEW_WRITE_SQL = """(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')))"""

ROLE_LIST = sorted({r for rs in GRANTS.values() for r in rs})
role_sql = ", ".join(f"'{r}'" for r in ROLE_LIST)

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-8b-1/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES8B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.compliance_settings') IS NOT NULL OR to_regclass('public.compliance_packs') IS NOT NULL
       OR to_regclass('public.compliance_pack_issues') IS NOT NULL
       OR to_regprocedure('public.inbound_batch_margin(uuid)') IS NOT NULL OR to_regprocedure('public.inventory_metal_exposure()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'compliance_pack' OR prefix = 'CPK')
       OR EXISTS (SELECT 1 FROM permissions WHERE code IN ('module.compliance.view', 'action.compliance_pack'))
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'compliance-documents') THEN
        RAISE EXCEPTION 'MES8B1_PRE|MES-8b-1 objects already exist';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 82
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected a catalogue of 82 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ({role_sql}) AND is_active) <> {len(ROLE_LIST)} THEN
        RAISE EXCEPTION 'MES8B1_PRE|the roles {", ".join(ROLE_LIST)} must exist and be active (Q17)';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 62 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 62 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 119 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 71 THEN
        RAISE EXCEPTION 'MES8B1_PRE|operations_now should have 71 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 31 THEN
        RAISE EXCEPTION 'MES8B1_PRE|pending_values should have 31 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 317 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected 317 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES8B1_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes8b1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes8b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes8b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes8b1_cod_objects_before ON COMMIT DROP AS
SELECT name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects WHERE bucket_id = 'cod-documents';
CREATE TEMP TABLE mes8b1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新函数(镜像原样),先于新表:两支守卫(冻下来的包只许被取代 · 签发档只追加)──\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append("\n-- ── 2 · 新表(镜像原样):合规包的设定 · 合规包 · 它的签发档 ─────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

grant_sql = "".join(
    f"""INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, '{code}' FROM roles r WHERE r.code IN ({", ".join(f"'{x}'" for x in roles)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
""" for code, roles in GRANTS.items())
parts.append(f"""
-- ── 3 · 权限目录两行 + 动作码声明的查看码(与 db/tables/permissions.sql 逐字同一份)· 单据登记 CPK(与 db/tables/document_types.sql 那一行同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROW_VIEW},
{PERM_ROW_ACTION};
UPDATE public.permissions SET requires_view_any = ARRAY['module.compliance.view'] WHERE code = 'action.compliance_pack';
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}

-- ── 4 · 授权(MES-8 Step 0 Q17):module.compliance.view → admin · auditor · cco · cfo · cto · gm;action.compliance_pack → admin · cto
--   —— 本刀唯一的授权改动(八行)──
{grant_sql}""")

parts.append("\n-- ── 5 · 新函数(镜像原样),新表之后 ──────────────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 6 · 换掉的函数(镜像原样,同签名):审计主语与成员 ──────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 7 · 视图(镜像原样):提醒 +1 支(compliance_pack_not_frozen)· 待补的值 +V26 +V27 ──\n")
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
-- ── 10 · 私有桶 compliance-documents 与它的三条策略(桶不在镜像里 —— AGENTS.md;它的证明是
--   db/scripts/2026-10-17-mes8b1-live-proof.mjs 的 PDF 一段)。只收 PDF、≤ 10 MB。读:module.compliance.view(合规包的读码)。
--   传:action.compliance_pack(存档的那一个码)。删:action.compliance_pack【并且】那个对象还没被记进 compliance_pack_issues —— 记哈希失败留下的孤儿
--   可以由存档的人清掉;记下了的字节谁都删不掉。改:一条策略都不给(覆盖一份已存的字节,就是改一份交出去过的包)。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('compliance-documents', 'compliance-documents', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "compliance-documents read by compliance view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'compliance-documents'::text AND public.has_permission('module.compliance.view'::text));

CREATE POLICY "compliance-documents upload by compliance pack"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'compliance-documents'::text AND public.has_permission('action.compliance_pack'::text));

CREATE POLICY "compliance-documents remove unrecorded by compliance pack"
    ON storage.objects AS PERMISSIVE FOR DELETE TO authenticated
    USING (bucket_id = 'compliance-documents'::text AND public.has_permission('action.compliance_pack'::text)
           AND NOT EXISTS (SELECT 1 FROM public.compliance_pack_issues i WHERE i.file_path = objects.name));
""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes8b1_pending_decider_check")
parts.append("\n-- ── 11 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B1_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes8b1_rows_before)" for t, (w, d) in DIGEST_TABLES.items())
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)
holder_checks = "\n".join(
    f"""    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = '{code}';
    IF v_bad IS DISTINCT FROM '{",".join(sorted(roles))}' THEN
        RAISE EXCEPTION 'MES8B1_PROOF|{code} is held by % (ruled: {",".join(sorted(roles))})', COALESCE(v_bad, '<nobody>');
    END IF;""" for code, roles in GRANTS.items())
n_grants = sum(len(v) for v in GRANTS.values())

parts.append(f"""
CREATE TEMP TABLE mes8b1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权:恰好多了那八行;目录 84 个码,admin 持每一个;持动作码的角色也持它声明的查看码
    IF (SELECT count(*) FROM permissions) <> 84
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|admin does not hold every one of the 84 codes';
    END IF;
{holder_checks}
    IF (SELECT requires_view_any FROM permissions WHERE code = 'action.compliance_pack') IS DISTINCT FROM ARRAY['module.compliance.view'] THEN
        RAISE EXCEPTION 'MES8B1_PROOF|action.compliance_pack must declare module.compliance.view';
    END IF;
    SELECT string_agg(r.code || ':' || p.code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B1_PROOF|an action code is held without its declared view: %', v_bad;
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES8B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes8b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes8b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变;两张 COD 的存储对象一个字节不动
    IF EXISTS ((SELECT b.k, b.id FROM mes8b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes8b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes8b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes8b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS ((SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents'
                EXCEPT SELECT name, size, etag FROM mes8b1_cod_objects_before)
               UNION ALL
               (SELECT name, size, etag FROM mes8b1_cod_objects_before
                EXCEPT SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents')) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a COD object changed';
    END IF;

    -- ④ 包与签发档一行都没有;设定那一行在、四样全空
    IF EXISTS (SELECT 1 FROM compliance_packs) OR EXISTS (SELECT 1 FROM compliance_pack_issues) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|no pack or issue may be created';
    END IF;
    IF (SELECT count(*) FROM compliance_settings) <> 1
       OR EXISTS (SELECT 1 FROM compliance_settings WHERE nea_return_format IS NOT NULL OR nea_return_frequency IS NOT NULL
                                                       OR eu_efficiency_method IS NOT NULL OR eu_efficiency_targets IS NOT NULL) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|the settings row must exist with V26 and V27 empty (Q18: nothing is guessed)';
    END IF;

    -- ⑤ 本事务往变更记录只写了:目录两行(+ 动作码的查看码)、八行授权、单据登记一行(按 txid 认)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes8b1_log_before), 0) AND c.txid = txid_current()
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types', 'compliance_settings'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8B1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes8b1_log_before), 0) AND c.txid = txid_current()
          AND c.table_name = 'role_permissions') <> {n_grants} THEN
        RAISE EXCEPTION 'MES8B1_PROOF|expected exactly {n_grants} role_permissions rows written';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:守卫在;单据登记 63 行,CPK 一行;320 张表;审计主语在册
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_compliance_packs_write' AND tgrelid = 'public.compliance_packs'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_compliance_pack_issues_append_only' AND tgrelid = 'public.compliance_pack_issues'::regclass) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|a guard trigger is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 63 OR document_type_prefix('compliance_pack') <> 'CPK' THEN
        RAISE EXCEPTION 'MES8B1_PROOF|document_types should be 63 with CPK';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 320 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|expected 320 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'compliance_pack' AND s.view_codes = ARRAY['module.compliance.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'compliance_settings')
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'compliance_pack' AND m.table_name = 'compliance_pack_issues' AND m.home) THEN
        RAISE EXCEPTION 'MES8B1_PROOF|the compliance trail subjects or members are missing';
    END IF;

    -- ⑦ 匿名面与函数面
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES8B1_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8B1_PROOF|anon can read %', v_bad; END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(三张新表记,豁免仍是 8);遮蔽零缺口(规则仍 119 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 提醒臂 72(compliance_pack_not_frozen 一行都不出 —— 没有一个已关账的月)、待补的值 33 支(V26 · V27 各一行)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 72
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 33 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|reminder arms 72 / pending-value arms 33 expected';
    END IF;
    IF (SELECT locked_before FROM finance_settings) > (SELECT system_start_date FROM finance_settings) THEN
        RAISE NOTICE 'MES8B1 a month is locked on live — compliance_pack_not_frozen will list it';
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑫ 桶:私有、空、三条策略
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'compliance-documents' AND NOT public)
       OR EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = 'compliance-documents')
       OR (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
             AND policyname LIKE 'compliance-documents %') <> 3 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|bucket compliance-documents must exist, be private, be empty and carry exactly three policies';
    END IF;

    -- ⑬ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes8b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES8B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes8b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES8B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes8b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

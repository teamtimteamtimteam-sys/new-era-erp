#!/usr/bin/env python3
"""MES-7b-2(v1.4.55):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数、新视图与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(不合格报告多一列与一条约束、单据登记一行与两行例外)在这里逐句写出,
并先断言镜像里那几行真的是这个样子。F16(视图一律不可写)那一段从 db/views/zzz_function_grants.sql 里抽 —— 同一段字。
照抄 build_mes7b1_migration.py 的形状。
跑法:python3 db/scripts/build_mes7b2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql"

# 外键顺序:清单 → 检查项 → 巡检 → 结果 → 发现(指任务)→ 关闭;参数 → 结果(指实验室与事故)
NEW_TABLES = ["inspection_templates", "inspection_template_items", "inspection_runs", "inspection_results", "inspection_findings",
              "inspection_finding_closures", "environmental_parameters", "environmental_results"]
# 先于新表:四支触发器函数(plpgsql 的体建的时候不解析表名)
NEW_FUNCS_EARLY = ["guard_inspection_template_write", "guard_inspection_record_write", "guard_environmental_parameter_code",
                   "guard_environmental_result_write"]
# 新表之后(record_inspection_run 调 record_inspection_finding —— plpgsql 不在建的时候解析,先后都行;这里照调用的先后排)
NEW_FUNCS_LATE = ["next_inspection_code", "save_inspection_template", "record_inspection_finding", "record_inspection_run",
                  "close_inspection_finding", "raise_inspection_finding_task", "record_environmental_result"]
# 换签名(末尾多一个带默认的参数):DROP 旧的,CREATE 新的
RESIGNED = [
    ("ncr_open_internal", "public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid)"),
    ("open_ncr", "public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid)"),
]
NEW_SIGS = {
    "ncr_open_internal": "public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid, uuid)",
    "open_ncr": "public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid, uuid)",
}
REPLACED_FUNCS = ["trail_subjects", "trail_subject_members"]
NEW_VIEWS = ["inspection_template_due_all", "inspection_template_rows", "inspection_run_rows", "inspection_finding_rows",
             "environmental_result_rows"]
REPLACED_VIEWS = ["ncr_rows", "operations_now", "pending_values"]

STAFF_SIGS = ["public.save_inspection_template(uuid, text, text, text, jsonb, integer, boolean, text)",
              "public.record_inspection_run(uuid, timestamp with time zone, uuid, jsonb, uuid, uuid, text, jsonb, uuid, text)",
              "public.record_inspection_finding(uuid, integer, text, uuid, date)",
              "public.close_inspection_finding(uuid, text)",
              "public.raise_inspection_finding_task(uuid)",
              "public.record_environmental_result(text, text, date, text, text, numeric, boolean, text, uuid, text)",
              NEW_SIGS["open_ncr"]]
PLAIN_SIGS = ["public.next_inspection_code(date)"]
INTERNAL_SIGS = ["public.guard_inspection_template_write()", "public.guard_inspection_record_write()",
                 "public.guard_environmental_parameter_code()", "public.guard_environmental_result_write()", NEW_SIGS["ncr_open_internal"]]

# 前后比对的表(既有的行逐字未变)。不合格报告比对时减掉新加的那一列;单据登记只比 inspection 以外的行。
DIGEST_TABLES = {
    "inbound_batches": ("", []), "output_batches": ("", []), "inventory_movements": ("", []), "journal_entries": ("", []),
    "journal_lines": ("", []), "materials": ("", []), "material_kinds": ("", []),
    "equipment_downtime": ("", []), "equipment_maintenance": ("", []), "processing_runs": ("", []), "processing_inputs": ("", []),
    "processing_outputs": ("", []), "processing_run_events": ("", []), "nonconformance_reports": ("", ["inspection_finding_id"]),
    "inbound_batch_safety_states": ("", []), "output_batch_safety_states": ("", []), "shift_handovers": ("", []),
    "shift_handover_items": ("", []), "shift_handover_equipment_refs": ("", []), "storage_locations": ("", []),
    "employees": ("", []), "public_holidays": ("", []), "certificates_of_destruction": ("", []), "cod_issues": ("", []),
    "certificates_of_analysis": ("", []), "coa_issues": ("", []), "warehouse_requests": ("", []), "expenses": ("", []),
    "payments": ("", []), "approval_log": ("", []), "fixed_assets": ("", []), "accounts": ("", []),
    "permissions": ("", []), "role_permissions": ("", []), "roles": ("", []), "user_roles": ("", []),
    "document_types": ("WHERE key <> 'inspection'", []), "ingest_settings": ("", []), "ingest_data_classes": ("", []),
    "incidents": ("", []), "incident_updates": ("", []), "incident_batches": ("", []), "incident_kinds": ("", []),
    "safety_settings": ("", []), "shift_handover_incident_refs": ("", []), "tasks": ("", []), "laboratories": ("", []),
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


def between(path, start, end_marker):
    text = mirror(path)
    i = text.index(start)
    j = text.index(end_marker, i) + len(end_marker)
    return text[i:j]


def comment_stmt(path, head):
    m = re.search(re.escape(head) + r"\s*'(?:[^']|'')*';\n", mirror(path))
    assert m, (path, head)
    return m.group(0)


def digest(t, where, drop):
    j = "to_jsonb(t)" + "".join(f" - '{k}'" for k in drop)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t {where})"


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
DOC = "db/tables/document_types.sql"
DOC_ROW = must(DOC, "    ('inspection', 'INS', 'inspection_runs', 'gapless', NULL, '/safety/inspections', 'detail', 'template_name', ARRAY['template_name']::text[], ARRAY['module.safety.view']::text[]);")
EXC = "db/tables/document_type_exceptions.sql"
EXC_ROWS = [must(EXC, "    ('environmental_parameters',      '监测参数目录(MES-7b-2):code 是参数代号,环境监测结果引用它'),"),
            must(EXC, "    ('inspection_templates',          '巡检清单(MES-7b-2):code 是清单代号,巡检把它抄下来;巡检本身(inspection_runs,INS)才是单据'),")]

NCR = "db/tables/nonconformance_reports.sql"
must(NCR, "    inspection_finding_id       uuid REFERENCES public.inspection_findings (id),\n")
NCR_INS_CHECK = must(NCR, "    CONSTRAINT nonconformance_reports_inspection_source CHECK ((source = 'inspection') = (inspection_finding_id IS NOT NULL))\n")
NCR_INS_INDEX = must(NCR, "CREATE INDEX nonconformance_reports_inspection_finding_id_rel ON public.nonconformance_reports (inspection_finding_id);\n")
NCR_COMMENT_TABLE = comment_stmt(NCR, "COMMENT ON TABLE public.nonconformance_reports IS")
NCR_COMMENT_COL = comment_stmt(NCR, "COMMENT ON COLUMN public.nonconformance_reports.inspection_finding_id IS")
assert "必须引用那条发现 —— MES-7b-2" in NCR_COMMENT_TABLE

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
# F16:那一段原样从授权文件里抽 —— 迁移里跑的与每一次 apply_migration / 每一次重建跑的是同一串字
F16_BLOCK = grants[grants.index("DO $f16$"):grants.index("$f16$;", grants.index("DO $f16$")) + len("$f16$;")]
assert "REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON %s FROM PUBLIC, anon, authenticated" in F16_BLOCK
assert "'V18'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "'V20'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "'inspection_due'::text AS item_type" in mirror("db/views/operations_now.sql")
assert "'inspection_finding_open'::text AS item_type" in mirror("db/views/operations_now.sql")
assert "('inspection_run',         ARRAY['module.safety.view'],    'inspection_runs'" in mirror("db/functions/trail_subjects.sql")
assert "('inspection_run',      1, 'inspection_results'" in mirror("db/functions/trail_subject_members.sql")

HEADER = """-- db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql
-- MES-7b-2 —— 安全巡检与环境监测:「安全」区多了巡检清单、一次一次的巡检(INS-…,每一项合格 / 不合格 / 不适用)与跟到关闭为止的发现;
--   环境监测结果对着它的限值记下,一条超标的结果自动开一件事故;顺带(F16)数据库的视图从此一律不可写。
--   (MES 组的第十九刀,v1.4.55;发布那一行在 docs/handbacks/MES-7b-2.md 的抬头。)由 db/scripts/build_mes7b2_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-16:MES-7b Step 0 的 Q13–Q16 与 Q17 · Q19–Q22 · Q27 的 7b-2 那一半照推荐;F16 是 Tim 新加的)
--   ① 八张新表:inspection_templates · inspection_template_items(清单与按顺序的检查项;一张都不引导 —— V18)· inspection_runs
--      (INS- 按年无洞;清单的代号 / 名字 / 片区抄进来)· inspection_results(每一项 pass / fail / na,字抄进来,不合格要说明)·
--      inspection_findings(纠正措施、负责的人、人选的到期日、它那张任务)· inspection_finding_closures(关闭一行)·
--      environmental_parameters(监测参数字典,一个都不引导 —— V20)· environmental_results(只追加;单位与限值抄进来;超标 ⇔ 一件事故)。
--   ② 函数:save_inspection_template · record_inspection_run · record_inspection_finding · close_inspection_finding ·
--      raise_inspection_finding_task(给按下的人建一张私人任务 —— 任务模块一行不改)· record_environmental_result(超标在同一笔事务里
--      经 record_incident 开一件 emission_exceedance)· next_inspection_code · 四支守卫。
--   ③ 不合格报告的来源 inspection 不再保留(Q15):多一列 inspection_finding_id 与一条约束(inspection ⇔ 引用一条发现);open_ncr /
--      ncr_open_internal 末尾多一个带默认的参数(换签名:DROP + CREATE);ncr_rows 末尾多四列。
--   ④ 提醒两支(inspection_due · inspection_finding_open)· 待补的值两个(V18 · V20,字典空着时各一行)· 审计主语四个(inspection_run ·
--      inspection_template · dictionary_environmental_parameters · safety_environment)与它们的成员 · 单据登记 INS(60 → 61)与两行例外 ·
--      八张新表进变更记录(豁免仍是 8)· 没有遮蔽的列(规则仍 119)。
--   ⑤ F16:收回 anon / authenticated(与 PUBLIC)在 public 里每一张视图上的 INSERT / UPDATE / DELETE / TRUNCATE(与
--      db/views/zzz_function_grants.sql 那一段逐字同一份 —— 以后的每一支迁移都会在自己的事务里再跑它)。
--
-- 【不做什么】不加任何码、不改任何授权(角色的码一行都不动);不建、不停、不删任何账号;不碰审批开关;不写、不改任何一件既有的批次、流水、
--   分录、物料、停机、加工单、事件、不合格报告、交接班、证书、事故、任务、员工、实验室;不建任何清单、巡检、发现、参数、结果或事故;不回填(Q94);
--   require_calibrated_since 保持空。线上由本迁移造出的只有:八张空表、单据登记那一行与两行例外、F16 的收权。
--
-- 【破窗】(Q21:这一窗什么都不坏)旧应用不读新表;它调 open_ncr 按具名参数、不带新参数 → 默认值,照旧走得通;ncr_rows 只多四列、
--   operations_now 只多两支(旧应用的提醒清单不认得这两种类型,不画)、pending_values 只多两个值(旧应用的待补值页按值码取文案 —— 认不得的
--   两个值码会画成键名,直到部署)。F16 收回的视图写授权:应用里没有一处写穿视图(F16 第 2 步的勘察),所以旧应用一处都不受影响。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权与角色【逐字未变】,admin 持目录里每一个码(81);在途单据一张不少、一张不多,
--   每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的行逐字未变(见 DIGEST_TABLES);八张新表空;本事务往变更记录只写了
--   单据登记那三行;anon 能执行的【恰好】两支;员工函数 DEFINER、调得到,守卫与内层调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与
--   遮蔽零缺口(豁免 8、规则 119);提醒臂 70、待补的值 29 支;单据登记 61 行;313 张表;【没有一张视图对 anon / authenticated 带写授权】。
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

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-7b-2/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES7B2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.inspection_runs') IS NOT NULL OR to_regclass('public.inspection_templates') IS NOT NULL
       OR to_regclass('public.environmental_parameters') IS NOT NULL OR to_regclass('public.environmental_results') IS NOT NULL
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'inspection' OR prefix = 'INS') THEN
        RAISE EXCEPTION 'MES7B2_PRE|MES-7b-2 objects already exist';
    END IF;
    IF to_regprocedure('{RESIGNED[1][1]}') IS NULL OR to_regprocedure('{RESIGNED[0][1]}') IS NULL THEN
        RAISE EXCEPTION 'MES7B2_PRE|open_ncr / ncr_open_internal do not have the signatures this migration replaces';
    END IF;
    IF EXISTS (SELECT 1 FROM nonconformance_reports WHERE source = 'inspection') THEN
        RAISE EXCEPTION 'MES7B2_PRE|an NCR with the reserved source inspection exists — the new CHECK would refuse it';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES7B2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 81
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7B2_PRE|expected a catalogue of 81 codes, all held by admin';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM incident_kinds WHERE code = 'emission_exceedance' AND is_active) THEN
        RAISE EXCEPTION 'MES7B2_PRE|the incident kind emission_exceedance must exist and be active (an exceedance opens one)';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 60 THEN
        RAISE EXCEPTION 'MES7B2_PRE|expected 60 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7B2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES7B2_PRE|expected 119 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 68 THEN
        RAISE EXCEPTION 'MES7B2_PRE|operations_now should have 68 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 25 THEN
        RAISE EXCEPTION 'MES7B2_PRE|pending_values should have 25 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 305 THEN
        RAISE EXCEPTION 'MES7B2_PRE|expected 305 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7B2_PRE|require_calibrated_since must be empty';
    END IF;
    RAISE NOTICE 'MES7B2 F16 before: % (view, role) pairs carry a write grant', {VIEW_WRITE_SQL};
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes7b2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes7b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes7b2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes7b2_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新函数(镜像原样),先于新表:四支守卫(清单只经函数写 · 巡检交了就不改 · 参数的限值成对、代号冻住 · 结果只追加)──\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append("\n-- ── 2 · 新表(镜像原样):清单 · 检查项 · 巡检 · 结果 · 发现 · 关闭 · 监测参数 · 监测结果 ─────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 3 · 不合格报告:来源 inspection 引用一条巡检发现(与 db/tables/nonconformance_reports.sql 逐字同一份)────────
ALTER TABLE public.nonconformance_reports ADD COLUMN inspection_finding_id uuid REFERENCES public.inspection_findings (id);
ALTER TABLE public.nonconformance_reports ADD CONSTRAINT
{NCR_INS_CHECK.strip().replace('CONSTRAINT ', '', 1)};
{NCR_INS_INDEX}{NCR_COMMENT_TABLE}{NCR_COMMENT_COL}
-- ── 4 · 单据登记:INS(与 db/tables/document_types.sql 那一行逐字同一份)· 两行例外(清单代号与参数代号不是单据号)──────────────
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
{chr(10).join(EXC_ROWS).rstrip().rstrip(',')}
ON CONFLICT (table_name) DO NOTHING;
""")

parts.append("\n-- ── 5 · 新函数(镜像原样),新表之后:取号 · 存清单 · 记发现 · 交巡检 · 关发现 · 建任务 · 记监测结果 ──────────────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 6 · 换签名(末尾多一个带默认的参数):DROP 旧的,CREATE 新的 —— 两支并存是一次镜像看不见的重载 ─────────────\n")
for name, old_sig in RESIGNED:
    parts.append(f"DROP FUNCTION {old_sig};\n")
for name, _ in RESIGNED:
    parts.append(fn(name, create=True))

parts.append("\n-- ── 7 · 换掉的函数(镜像原样,同签名):审计主语与成员 ──────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 8 · 视图(镜像原样):到期的底视图 · 清单 · 巡检 · 发现 · 监测结果;ncr_rows 末尾 +4 列 · 提醒 +2 支 · 待补的值 +V18 +V20 ──\n")
for v in NEW_VIEWS:
    parts.append(view(v))
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append("\n-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

parts.append(f"""
-- ── 10 · F16:视图一律不可写(与 db/views/zzz_function_grants.sql 那一段逐字同一份;apply_migration.sh 之后还会整份重放)──────────
{F16_BLOCK}
""")

acl = ["""
-- ── 11 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + PLAIN_SIGS + INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes7b2_pending_decider_check")
parts.append("\n-- ── 12 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B2_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
plain_checks = "\n".join(
    f"""    IF NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B2_PROOF|{sig}: expected authenticated yes, anon no';
    END IF;""" for sig in PLAIN_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B2_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes7b2_rows_before)" for t, (w, d) in DIGEST_TABLES.items())
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)
empty_checks = "\n       OR ".join(f"EXISTS (SELECT 1 FROM {t})" for t in NEW_TABLES)
old_sig_checks = "\n       OR ".join(f"to_regprocedure('{old}') IS NOT NULL" for _, old in RESIGNED)
new_sig_checks = "\n       OR ".join(f"to_regprocedure('{NEW_SIGS[n]}') IS NULL" for n, _ in RESIGNED)

parts.append(f"""
CREATE TEMP TABLE mes7b2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权、角色、账号:逐字未变(DIGEST 里的 permissions · role_permissions · roles · user_roles);admin 持目录里每一个码(81)
    IF (SELECT count(*) FROM permissions) <> 81
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7B2_PROOF|admin does not hold every one of the 81 codes';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES7B2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes7b2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes7b2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES7B2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(不合格报告减掉新加的那一列)
    IF EXISTS ((SELECT b.k, b.id FROM mes7b2_pending_before b EXCEPT SELECT a.k, a.id FROM mes7b2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes7b2_pending_after a EXCEPT SELECT b.k, b.id FROM mes7b2_pending_before b)) THEN
        RAISE EXCEPTION 'MES7B2_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES7B2_PROOF|a pre-existing row changed (batch, movement, journal, material, kind, downtime, maintenance, run, event, NCR, safety state, handover, location, employee, holiday, certificate, request, expense, payment, approval, asset, account, permission, grant, role, account role, document type, ingestion, incident, task or laboratory)';
    END IF;

    -- ④ 新表一行都没有(不引导清单、参数;不建巡检、发现、结果、事故)
    IF {empty_checks} THEN
        RAISE EXCEPTION 'MES7B2_PROOF|the new tables must be empty (no template, item, run, result, finding, closure, parameter or result is created)';
    END IF;

    -- ⑤ 本事务往变更记录只写了单据登记那三行(按 txid 认 —— 同一时刻同事们在线上的写不算在本刀头上)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes7b2_log_before), 0) AND c.txid = txid_current()
       AND NOT (c.op = 'INSERT' AND c.table_name IN ('document_types', 'document_type_exceptions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B2_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7B2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:两支换了签名的只剩新签名;守卫都在;NCR 的来源约束认 inspection;单据登记 61 行,INS 一行;313 张表;审计主语在册
    IF {old_sig_checks}
       OR {new_sig_checks} THEN
        RAISE EXCEPTION 'MES7B2_PROOF|open_ncr / ncr_open_internal must exist only with their new signatures';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inspection_runs_insert' AND tgrelid = 'public.inspection_runs'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inspection_runs_immutable' AND tgrelid = 'public.inspection_runs'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inspection_findings_row' AND tgrelid = 'public.inspection_findings'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_inspection_templates_write' AND tgrelid = 'public.inspection_templates'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_environmental_results_insert' AND tgrelid = 'public.environmental_results'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_environmental_parameters_guard' AND tgrelid = 'public.environmental_parameters'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'nonconformance_reports_inspection_source') THEN
        RAISE EXCEPTION 'MES7B2_PROOF|a guard trigger or the NCR inspection-source check is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 61 OR document_type_prefix('inspection') <> 'INS' THEN
        RAISE EXCEPTION 'MES7B2_PROOF|document_types should be 61 with INS';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 313 THEN
        RAISE EXCEPTION 'MES7B2_PROOF|expected 313 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'inspection_run' AND s.view_codes = ARRAY['module.safety.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'inspection_run' AND m.table_name = 'inspection_findings' AND m.home)
       OR NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'safety_environment' AND s.root_rule = 'collection') THEN
        RAISE EXCEPTION 'MES7B2_PROOF|the inspection / environment trail subjects or members are missing';
    END IF;

    -- ⑦ 匿名面与函数面:anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;取号函数调得到;守卫与内层调不到;新表与视图 anon 读不到;
    --    底视图 authenticated 也读不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES7B2_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{plain_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B2_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.inspection_template_due_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES7B2_PROOF|the base view must not be readable by authenticated';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7B2_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(八张新表记,豁免仍是 8);遮蔽零缺口(规则仍 119 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES7B2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES7B2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 提醒臂 70、待补的值 29 支(V18 与 V20 那两行从第一天起就在:两本字典都是空的)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 70
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 29 THEN
        RAISE EXCEPTION 'MES7B2_PROOF|reminder arms 70 / pending-value arms 29 expected';
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES7B2_PROOF|F16: % (view, role) pairs still carry a write grant', v_n;
    END IF;
    RAISE NOTICE 'MES7B2 F16 after: 0 (view, role) pairs carry a write grant (% views)',
        (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relkind = 'v');

    -- ⑫ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes7b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES7B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes7b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES7B2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes7b2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

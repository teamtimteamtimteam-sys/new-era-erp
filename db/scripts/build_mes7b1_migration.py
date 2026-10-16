#!/usr/bin/env python3
"""MES-7b-1(v1.4.54):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数、新视图与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(不合格报告多一种来源与一列、权限目录两行与一处描述、单据登记一行与一行例外、
交接班两句表注释、十二行授权、线上那一行备件说明 F12)在这里逐句写出,并先断言镜像里那几行真的是这个样子。
照抄 build_mes6a1_migration.py(新码与授权)与 build_mes7a2_migration.py(换签名、守卫、自证)的形状。
跑法:python3 db/scripts/build_mes7b1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-16-mes7b1-incidents.sql"

NEW_TABLES = ["incident_kinds", "safety_settings", "incidents", "incident_updates", "incident_batches", "shift_handover_incident_refs"]
# 先于新表:四支触发器函数(plpgsql 的体建的时候不解析表名)
NEW_FUNCS_EARLY = ["guard_incident_kind_code", "guard_incident_write", "guard_incident_update_write", "guard_incident_batch_write"]
# 新表之后
NEW_FUNCS_LATE = ["next_incident_code", "business_days_after", "record_incident", "record_incident_update", "suggest_incident_batches",
                  "link_incident_batch", "unlink_incident_batch", "set_safety_settings"]
# 换签名(末尾多一个带默认的参数):DROP 旧的,CREATE 新的
RESIGNED = [
    ("ncr_open_internal", "public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid)"),
    ("open_ncr", "public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)"),
    ("submit_shift_handover", "public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[])"),
]
NEW_SIGS = {
    "ncr_open_internal": "public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid, uuid)",
    "open_ncr": "public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid)",
    "submit_shift_handover": "public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[], uuid[])",
}
# 同签名换掉
REPLACED_FUNCS = ["trail_subjects", "trail_subject_members", "change_log_mask_rules"]
NEW_VIEWS = ["incident_current_all", "incidents_masked", "incident_rows", "incident_batch_rows", "incident_people"]
REPLACED_VIEWS = ["ncr_rows", "operations_now", "pending_values"]

STAFF_SIGS = ["public.record_incident(text, timestamp with time zone, text, text, boolean, uuid, text, uuid, uuid, numeric, uuid, bigint, uuid, text, text, text, numeric, text)",
              "public.record_incident_update(uuid, text, timestamp with time zone, text, text, text, text, text)",
              "public.suggest_incident_batches(uuid)",
              "public.link_incident_batch(uuid, text, uuid, uuid)",
              "public.unlink_incident_batch(bigint, text)",
              "public.set_safety_settings(integer, boolean, text)",
              NEW_SIGS["open_ncr"], NEW_SIGS["submit_shift_handover"]]
PLAIN_SIGS = ["public.next_incident_code(date)", "public.business_days_after(date, integer)"]
INTERNAL_SIGS = ["public.guard_incident_kind_code()", "public.guard_incident_write()", "public.guard_incident_update_write()",
                 "public.guard_incident_batch_write()", NEW_SIGS["ncr_open_internal"]]

S_VIEW_ROLES = ["admin", "auditor", "cco", "cfo", "cto", "finance", "gm", "operations", "warehouse"]   # Q2:每一个持 module.processing.view 的角色(开场读数)
S_EDIT_ROLES = ["admin", "cto", "warehouse"]                                                            # Q2 · Q28

# 前后比对的表(既有的行逐字未变)。不合格报告比对时减掉新加的那一列(减一个不存在的键是空操作);权限目录只比两行新码以外、且不比 data.view_health
# 那一行的描述(本刀改了它的两句描述);物料种类只比备件以外的行(F12 改的就是那一行)。
DIGEST_TABLES = {
    "inbound_batches": ("", []), "output_batches": ("", []), "inventory_movements": ("", []), "journal_entries": ("", []),
    "journal_lines": ("", []), "materials": ("", []), "material_kinds": ("WHERE code <> 'spare_part'", []),
    "equipment_downtime": ("", []), "equipment_maintenance": ("", []), "processing_runs": ("", []), "processing_inputs": ("", []),
    "processing_outputs": ("", []), "processing_run_events": ("", []), "nonconformance_reports": ("", ["incident_id"]),
    "inbound_batch_safety_states": ("", []), "output_batch_safety_states": ("", []), "shift_handovers": ("", []),
    "shift_handover_items": ("", []), "shift_handover_equipment_refs": ("", []), "storage_locations": ("", []),
    "employees": ("", []), "public_holidays": ("", []), "certificates_of_destruction": ("", []), "cod_issues": ("", []),
    "certificates_of_analysis": ("", []), "coa_issues": ("", []), "warehouse_requests": ("", []), "expenses": ("", []),
    "payments": ("", []), "approval_log": ("", []), "fixed_assets": ("", []), "accounts": ("", []),
    "permissions": ("WHERE code NOT IN ('module.safety.view', 'module.safety.edit', 'data.view_health')", []),
    "document_types": ("WHERE key <> 'incident'", []), "ingest_settings": ("", []), "ingest_data_classes": ("", []),
}


def fn(name, create=False):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    if create:
        # 换了签名的那一支:DROP 之后 CREATE(preflight 不许 CREATE OR REPLACE 换签名 —— 那会是一次镜像看不见的重载)
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
    """一句 COMMENT ... IS '…'; —— 字面量里的 '' 是转义,不是结尾(按"下一个 ';"切会切在 ''x''; 上)。"""
    m = re.search(re.escape(head) + r"\s*'(?:[^']|'')*';\n", mirror(path))
    assert m, (path, head)
    return m.group(0)


def digest(t, where, drop):
    j = "to_jsonb(t)" + "".join(f" - '{k}'" for k in drop)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t {where})"


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
PERM = "db/tables/permissions.sql"
PERM_ROWS = between(PERM, "    ('module.safety.view', 'module', 'Safety (view)'", "153),\n")
assert PERM_ROWS.count("\n    ('module.safety.") == 1 and PERM_ROWS.startswith("    ('module.safety.view'")
HEALTH_ROW = between(PERM, "    ('data.view_health', 'data', 'View health details', '查看健康信息', ", ", 215),")
m = re.match(r"    \('data\.view_health', 'data', 'View health details', '查看健康信息', ('(?:[^']|'')*'), ('(?:[^']|'')*'), 215\),", HEALTH_ROW)
assert m, HEALTH_ROW[:120]
HEALTH_DESC_EN, HEALTH_DESC_ZH = m.group(1), m.group(2)
assert "injury details of an incident" in HEALTH_DESC_EN

DOC = "db/tables/document_types.sql"
DOC_ROW = must(DOC, "    ('incident', 'INC', 'incidents', 'gapless', NULL, '/safety/incidents', 'detail', 'what_happened', ARRAY['what_happened']::text[], ARRAY['module.safety.view']::text[]);")
REL_EXC = between("db/tables/document_relation_exceptions.sql", "    ('incidents', 'injured_employee_id', '',", "')\n")
assert REL_EXC.count("('incidents'") == 1
EXC_ROW = must("db/tables/document_type_exceptions.sql",
               "    ('incident_kinds',                '事故种类目录(MES-7b-1):code 是种类代号(没有 other),事故引用它'),")

NCR = "db/tables/nonconformance_reports.sql"
NCR_SOURCE_CHECK = "CHECK (source IN ('manual', 'customer_complaint', 'quality_limit', 'inspection', 'incident'))"
must(NCR, "    source                      text NOT NULL " + NCR_SOURCE_CHECK + ",\n")
must(NCR, "    incident_id                 uuid REFERENCES public.incidents (id),\n")
NCR_INC_CHECK = must(NCR, "    CONSTRAINT nonconformance_reports_incident_source CHECK ((source = 'incident') = (incident_id IS NOT NULL))\n")
NCR_INC_INDEX = must(NCR, "CREATE INDEX nonconformance_reports_incident_id_rel ON public.nonconformance_reports (incident_id);\n")
NCR_COMMENT_TABLE = comment_stmt(NCR, "COMMENT ON TABLE public.nonconformance_reports IS")
NCR_COMMENT_COL = comment_stmt(NCR, "COMMENT ON COLUMN public.nonconformance_reports.incident_id IS")
HO_COMMENT = comment_stmt("db/tables/shift_handovers.sql", "COMMENT ON TABLE public.shift_handovers IS")
HIT_COMMENT = comment_stmt("db/tables/handover_item_types.sql", "COMMENT ON TABLE public.handover_item_types IS")
assert "shift_handover_incident_refs" in HO_COMMENT and "shift_handover_incident_refs" in HIT_COMMENT

# F12:线上那一行备件说明改成镜像里那一句(一份文本,从镜像里抽 —— 抽出来的就是镜像里那个 SQL 表达式本身)
MK = mirror("db/tables/material_kinds.sql")
i = MK.index("    ('spare_part', 'Spare part', '备件', false, 5, false,\n")
j = MK.index("\n", i) + 1
# 那一行以 `…');` 收尾:`'` 是表达式的最后一个字符,`)` 收的是 VALUES 那一组 —— 只取到 `'`(dry run 抓到第一版多取了那个 `)`)
k = MK.index("');\n", j) + 1
SPARE_NOTE_EXPR = MK[j:k].strip()
assert SPARE_NOTE_EXPR.startswith("'机器的备件。按进料批收货") and SPARE_NOTE_EXPR.endswith("。'")
assert SPARE_NOTE_EXPR.count("(") == SPARE_NOTE_EXPR.count(")"), "unbalanced parentheses in the extracted note expression"
for phrase in ("received as lots so stock and cost are counted", "issued against a maintenance record", "no per-piece traceability"):
    assert phrase in SPARE_NOTE_EXPR, phrase

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
assert "'V19'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "'incident_nea_notify_due'::text AS item_type" in mirror("db/views/operations_now.sql")
assert "'incident_report_due'::text AS item_type" in mirror("db/views/operations_now.sql")
assert "('incidents', 'days_lost', 'code_or_self:data.view_health:injured_employee_id')" in mirror("db/functions/change_log_mask_rules.sql")
assert "('incident',               ARRAY['module.safety.view'],    'incidents'" in mirror("db/functions/trail_subjects.sql")
assert "('incident',           1, 'incident_updates'" in mirror("db/functions/trail_subject_members.sql")
RP = mirror("db/tables/role_permissions.sql")
assert "'module.safety.view', 'module.safety.edit'\n) WHERE r.code = 'warehouse';" in RP

HEADER = """-- db/migrations/2026-10-16-mes7b1-incidents.sql
-- MES-7b-1 —— 事故登记簿:一个新的「安全」区记事故(INC-…)—— 热失控、起火、气体与粉尘释放、工伤、未遂与排放超标 —— 发生了什么、当场做了什么;
--   受伤的细节只给读得到健康数据的人与受伤的那名员工本人;一件事故可以链上它碰过的批次、一段停机、一条异常事件与一次交接班;
--   一件要向 NEA 通报的事故挂着提醒直到记下通报,并显示书面报告的期限(V19,仍标"未确认")。
--   (MES 组的第十八刀,v1.4.54;发布那一行在 docs/handbacks/MES-7b-1.md 的抬头。)由 db/scripts/build_mes7b1_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-16:MES-7b Step 0 —— Q1 拆两刀,本刀是 7b-1;Q6 · Q11 · Q12 · Q25 Tim 自己的话;其余属于本刀的照推荐)
--   ① 码(Q2):module.safety.view → 每一个持 module.processing.view 的角色;module.safety.edit → admin · cto · warehouse。没有新的动作码。
--      data.view_health 的描述多一句"事故的受伤细节";它【不】授给任何新角色(Q6)。
--   ② 六张新表:incident_kinds(七种,没有 other;用过的代号冻住)· incidents(INC- 按年无洞;写下就不改;受伤的四样细节 + 受伤的人
--      列授权收回、只经 incidents_masked 读)· incident_updates(通报 / 书面报告 / 关闭 / 带理由的更正,只追加)· incident_batches(人确认的
--      批次链接,解链接要理由)· safety_settings(单行:V19 = 2,未确认 —— Q11)· shift_handover_incident_refs(交接班指着事故,Q12)。
--   ③ 函数:record_incident · record_incident_update · suggest_incident_batches · link_ / unlink_incident_batch · set_safety_settings ·
--      business_days_after(工作日,读公共假期表;缺日历返回空)· next_incident_code · 四支守卫;来源 device 保留并按名拒(Q5)。
--   ④ 不合格报告多一种来源 incident 与一列 incident_id(Q8):open_ncr / ncr_open_internal 末尾多一个带默认的参数(换签名:DROP + CREATE);
--      ncr_rows 末尾多两列。submit_shift_handover 末尾多一个 p_incident_ids(换签名)。
--   ⑤ 提醒两支(incident_nea_notify_due · incident_report_due)· 待补的值一支(V19)· 审计主语三个(incident · safety_settings ·
--      dictionary_incident_kinds)与它们的成员 · 遮蔽规则 +5(114 → 119)· 单据登记 INC(59 → 60)与一行例外 · 六张新表进变更记录(豁免仍是 8)。
--   ⑥ F12(Q23):线上 material_kinds 备件那一行的说明改成镜像里那一句(received as lots so stock and cost are counted; issued against a
--      maintenance record; no per-piece traceability),本事务的自证把它读回来与镜像逐字比对。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;除了上面那十二行安全码的授权,不加任何码、不改任何授权;不写、不改任何一件既有的批次、流水、
--   分录、物料、停机、保养、加工单、异常事件、不合格报告、交接班、证书、安全状态、员工、公共假期;不建任何事故、更新、链接或交接班引用;不回填(Q94);
--   require_calibrated_since 保持空。线上由本迁移造出的只有:七种事故种类、V19(2,未确认)、十二行授权与两个码、F12 那一句说明。
--
-- 【破窗】(Q21:这一窗什么都不坏)旧应用不读新表;它调 open_ncr 与 submit_shift_handover 都按具名参数、不带新参数 → 默认值,照旧走得通;
--   ncr_rows 只多两列、operations_now 只多两支(旧应用的提醒清单不认得这两种类型,不画);角色页上多出两个它没有菜单的码(名字从目录读)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那十二行、别的一行没动,admin 持目录里每一个码(81);每一个角色仍满足
--   "编辑码蕴含查看码"与"动作码蕴含查看码";data.view_health 的持有人一个没变(cto 与仓库不在其中);在途单据一张不少、一张不多,每一张仍有
--   一个不是它当事人的决定人;七个账号一个都没被停;既有的行逐字未变(见 DIGEST_TABLES);六张新表空(种类七行、设定一行 V19 = 2 未确认);
--   备件那一行说明 = 镜像那一句;本事务往变更记录只写了本刀种的那几行;anon 能执行的【恰好】两支;员工函数 DEFINER、调得到,守卫与内层调不到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 119);提醒臂 68、待补的值 25;单据登记 60 行;305 张表。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-7b-1/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES7B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.incidents') IS NOT NULL OR to_regclass('public.incident_kinds') IS NOT NULL
       OR to_regclass('public.safety_settings') IS NOT NULL OR to_regclass('public.shift_handover_incident_refs') IS NOT NULL
       OR EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'module.safety.%')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'incident' OR prefix = 'INC') THEN
        RAISE EXCEPTION 'MES7B1_PRE|MES-7b-1 objects already exist';
    END IF;
    IF to_regprocedure('public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)') IS NULL
       OR to_regprocedure('public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid)') IS NULL
       OR to_regprocedure('public.submit_shift_handover(text, date, uuid, uuid, text, jsonb, uuid[])') IS NULL THEN
        RAISE EXCEPTION 'MES7B1_PRE|open_ncr / ncr_open_internal / submit_shift_handover do not have the signatures this migration replaces';
    END IF;
    IF EXISTS (SELECT 1 FROM nonconformance_reports) THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected no NCR on live (opening reading)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected a catalogue of 79 codes, all held by admin';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'module.processing.view') IS DISTINCT FROM 'admin,auditor,cco,cfo,cto,finance,gm,operations,warehouse' THEN
        RAISE EXCEPTION 'MES7B1_PRE|the holders of module.processing.view are not the nine of the opening reading';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'data.view_health') IS DISTINCT FROM 'admin,cco,cfo,finance,hr' THEN
        RAISE EXCEPTION 'MES7B1_PRE|the holders of data.view_health are not the five of the opening reading';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 59 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 59 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66 THEN
        RAISE EXCEPTION 'MES7B1_PRE|operations_now should have 66 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 24 THEN
        RAISE EXCEPTION 'MES7B1_PRE|pending_values should have 24 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 299 THEN
        RAISE EXCEPTION 'MES7B1_PRE|expected 299 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7B1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes7b1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes7b1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes7b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes7b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes7b1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append(f"""
-- ── 1 · 权限目录:两个安全码(与 db/tables/permissions.sql 逐字同一份);data.view_health 的描述多一句事故的受伤细节 ──────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROWS.rstrip().rstrip(',')};
UPDATE public.permissions SET description_en = {HEALTH_DESC_EN}, description_zh = {HEALTH_DESC_ZH}
 WHERE code = 'data.view_health';
""")

parts.append("\n-- ── 2 · 新函数(镜像原样),先于新表:四支守卫(种类代号冻住 · 事故写下就不改 · 更新只追加 · 链接只在解链接那一次改)──\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append("\n-- ── 3 · 新表(镜像原样):事故种类 · 安全的设定(V19)· 事故 · 之后的事实 · 批次链接 · 交接班的引用 ─────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 4 · 不合格报告:多一种来源 incident 与一列 incident_id(与 db/tables/nonconformance_reports.sql 逐字同一份;约束名是线上那一个)────────
ALTER TABLE public.nonconformance_reports DROP CONSTRAINT nonconformance_reports_source_check;
ALTER TABLE public.nonconformance_reports ADD CONSTRAINT nonconformance_reports_source_check
    {NCR_SOURCE_CHECK};
ALTER TABLE public.nonconformance_reports ADD COLUMN incident_id uuid REFERENCES public.incidents (id);
ALTER TABLE public.nonconformance_reports ADD CONSTRAINT
{NCR_INC_CHECK.strip().replace('CONSTRAINT ', '', 1)};
{NCR_INC_INDEX}{NCR_COMMENT_TABLE}{NCR_COMMENT_COL}
-- ── 5 · 交接班两句表注释(WSH 登记簿建好了;与各自的表镜像逐字同一份)────────────────────────────────────────────
{HO_COMMENT}{HIT_COMMENT}
-- ── 6 · 单据登记:INC(与 db/tables/document_types.sql 那一行逐字同一份)· 一行例外(事故种类的 code 不是单据号)──────────────
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
{EXC_ROW.rstrip().rstrip(',')}
ON CONFLICT (table_name) DO NOTHING;
-- 受伤的那一列不当关联边(与 db/tables/document_relation_exceptions.sql 那一行逐字同一份)
INSERT INTO public.document_relation_exceptions (owner_table, column_a, column_b, reason) VALUES
{REL_EXC.rstrip()}
ON CONFLICT (owner_table, column_a, column_b) DO NOTHING;
""")

parts.append("\n-- ── 7 · 新函数(镜像原样),新表之后:取号 · 工作日 · 记事故 · 记之后的事实 · 批次建议 · 链 / 解链 · V19 ──────────────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 8 · 换签名(末尾多一个带默认的参数):DROP 旧的,CREATE 新的 —— 两支并存是一次镜像看不见的重载 ─────────────\n")
for name, old_sig in RESIGNED:
    parts.append(f"DROP FUNCTION {old_sig};\n")
for name, _ in RESIGNED:
    parts.append(fn(name, create=True))

parts.append("\n-- ── 9 · 换掉的函数(镜像原样,同签名):审计主语与成员 · 遮蔽规则 +5 ──────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 10 · 视图(镜像原样):事故现在的样子(底视图)· 遮蔽伴生 · 事故一行 · 批次链接 · 人选框;ncr_rows 末尾 +2 列 · 提醒 +2 支 · 待补的值 +V19 ──\n")
for v in NEW_VIEWS:
    parts.append(view(v))
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append("\n-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

parts.append(f"""
-- ── 12 · 授权(MES-0 Q90 · MES-7b Step 0 Q2):查看 → {' · '.join(S_VIEW_ROLES)};编辑 → {' · '.join(S_EDIT_ROLES)} —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.safety.view' FROM roles r WHERE r.code IN ({", ".join(f"'{c}'" for c in S_VIEW_ROLES)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.safety.edit' FROM roles r WHERE r.code IN ({", ".join(f"'{c}'" for c in S_EDIT_ROLES)})
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 13 · F12(Q23):线上 material_kinds 备件那一行的说明改成镜像里那一句(幂等;按普通的改动进变更记录)──────────────────
UPDATE public.material_kinds
   SET notes = {SPARE_NOTE_EXPR}
 WHERE code = 'spare_part' AND notes IS DISTINCT FROM {SPARE_NOTE_EXPR};
""")

acl = ["""
-- ── 14 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + PLAIN_SIGS + INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes7b1_pending_decider_check")
parts.append("\n-- ── 15 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

expected_grants = sorted([f"{r}:module.safety.view" for r in S_VIEW_ROLES] + [f"{r}:module.safety.edit" for r in S_EDIT_ROLES])
staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
plain_checks = "\n".join(
    f"""    IF NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|{sig}: expected authenticated yes, anon no';
    END IF;""" for sig in PLAIN_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes7b1_rows_before)" for t, (w, d) in DIGEST_TABLES.items())
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)
old_sig_checks = "\n       OR ".join(f"to_regprocedure('{old}') IS NOT NULL" for _, old in RESIGNED)
new_sig_checks = "\n       OR ".join(f"to_regprocedure('{NEW_SIGS[n]}') IS NULL" for n, _ in RESIGNED)

parts.append(f"""
CREATE TEMP TABLE mes7b1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权:恰好多了那十二行安全码,别的一行没动;admin 持目录里每一个码(81);编辑码蕴含查看码、动作码蕴含查看码;data.view_health 的持有人没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes7b1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes7b1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM '{", ".join(expected_grants)}' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|grant change is not exactly the twelve safety grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 81
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|admin does not hold every one of the 81 codes';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code LIKE '%.edit'
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = replace(rp.permission_code, '.edit', '.view'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|edit-implies-view violated: %', v_bad; END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|action-implies-view violated: %', v_bad; END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'data.view_health') IS DISTINCT FROM 'admin,cco,cfo,finance,hr' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|data.view_health holders changed';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code LIKE 'module.safety.%' AND requires_view_any IS NOT NULL) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|module codes do not declare requires_view_any (only action codes do)';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES7B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes7b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes7b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(不合格报告减掉新加的那一列)
    IF EXISTS ((SELECT b.k, b.id FROM mes7b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes7b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes7b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes7b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES7B1_PROOF|a pre-existing batch, movement, journal, material, kind, downtime, maintenance, run, event, NCR, safety state, handover, location, employee, holiday, certificate, request, expense, payment, approval, asset, account, permission, document type or ingestion row changed';
    END IF;

    -- ④ 新表:事故 / 更新 / 链接 / 交接班引用一行都没有;种类恰好那七种(没有 other);设定一行,V19 = 2,未确认,带出处
    IF EXISTS (SELECT 1 FROM incidents) OR EXISTS (SELECT 1 FROM incident_updates) OR EXISTS (SELECT 1 FROM incident_batches)
       OR EXISTS (SELECT 1 FROM shift_handover_incident_refs) OR EXISTS (SELECT 1 FROM nonconformance_reports WHERE incident_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|no incident, update, link, handover reference or incident NCR may exist';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM incident_kinds WHERE is_active)
         IS DISTINCT FROM 'thermal_runaway,fire_smoke,gas_release,dust_concentration,injury,near_miss,emission_exceedance'
       OR (SELECT count(*) FROM incident_kinds) <> 7 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|incident kinds are not the seven ruled (Q4)';
    END IF;
    IF (SELECT count(*) FROM safety_settings) <> 1
       OR (SELECT nea_report_working_days FROM safety_settings) IS DISTINCT FROM 2
       OR (SELECT nea_report_days_confirmed_at FROM safety_settings) IS NOT NULL
       OR (SELECT nea_report_days_source FROM safety_settings) NOT LIKE '%docs/forward-queue.md:2402%' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|V19 must be stored as 2 working days, unconfirmed, with its source (Q11)';
    END IF;

    -- ⑤ F12:备件那一行的说明读回来 = 镜像那一句
    IF (SELECT notes FROM material_kinds WHERE code = 'spare_part') IS DISTINCT FROM {SPARE_NOTE_EXPR} THEN
        RAISE EXCEPTION 'MES7B1_PROOF|F12: the spare_part note is not the mirror sentence: %', (SELECT notes FROM material_kinds WHERE code = 'spare_part');
    END IF;
    RAISE NOTICE 'MES7B1 F12 spare_part note read back: %', (SELECT notes FROM material_kinds WHERE code = 'spare_part');

    -- ⑥ 本事务往变更记录只写了本刀种的那几行(按 txid 认 —— 同一时刻同事们在线上的写不算在本刀头上):
    --    权限目录 2 插 1 改 · 授权 12 插 · 物料种类 1 改(F12)· 单据登记 / 例外 ≤ 1 插
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes7b1_log_before), 0) AND c.txid = txid_current()
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'incident_kinds', 'safety_settings',
                                                      'document_types', 'document_type_exceptions', 'document_relation_exceptions'))
                OR (c.op = 'UPDATE' AND c.table_name IN ('permissions', 'material_kinds')));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    -- 种类与设定的引导行在表建起来的那一刻插进去,而它们的变更记录绑定在第 11 步才挂上 —— 所以它们不在记录里(与每一本引导过的字典同一个样子)
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes7b1_log_before), 0) AND c.txid = txid_current()
       AND c.table_name IN ('role_permissions', 'material_kinds');
    IF v_n <> 13 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|change_log rows for grants + F12 = % (expected 12 + 1)', v_n;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:三支换了签名的只剩新签名;守卫都在;NCR 的来源认 incident;单据登记 60 行,INC 一行;305 张表;审计主语在册
    IF {old_sig_checks}
       OR {new_sig_checks} THEN
        RAISE EXCEPTION 'MES7B1_PROOF|open_ncr / ncr_open_internal / submit_shift_handover must exist only with their new signatures';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incidents_insert' AND tgrelid = 'public.incidents'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incidents_immutable' AND tgrelid = 'public.incidents'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incident_updates_immutable' AND tgrelid = 'public.incident_updates'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incident_batches_row' AND tgrelid = 'public.incident_batches'::regclass)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_incident_kinds_code_locked' AND tgrelid = 'public.incident_kinds'::regclass)
       OR pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'nonconformance_reports_source_check')) NOT LIKE '%incident%' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|a guard trigger or the NCR source check is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 60 OR document_type_prefix('incident') <> 'INC' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|document_types should be 60 with INC';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 305 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|expected 305 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'incident' AND s.view_codes = ARRAY['module.safety.view'])
       OR NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'incident' AND m.table_name = 'incident_updates' AND m.home) THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the incident trail subject or its members are missing';
    END IF;

    -- ⑧ 匿名面与函数面:anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;两支只读的算术调得到;守卫与内层调不到;
    --    新表与视图 anon 读不到;底视图 authenticated 也读不到;受伤的四样细节与受伤的人不在 authenticated 的列授权里
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES7B1_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{plain_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.incident_current_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the base view must not be readable by authenticated';
    END IF;
    SELECT string_agg(col, ', ') INTO v_bad FROM unnest(ARRAY['injured_employee_id', 'injured_person_name', 'injury_nature',
                                                             'injury_treatment', 'days_lost']) col
     WHERE has_column_privilege('authenticated', 'public.incidents'::regclass, col, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES7B1_PROOF|authenticated can read the injury column(s) % directly', v_bad; END IF;
    IF NOT has_column_privilege('authenticated', 'public.incidents'::regclass, 'what_happened', 'SELECT') THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the column-list grant on incidents is missing its ordinary columns';
    END IF;

    -- ⑨ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(六张新表记,豁免仍是 8);遮蔽零缺口(规则 119 —— 多了事故的五列受伤细节)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑪ 提醒臂 68、待补的值 25(V19 那一行从第一天起就在:未确认)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 68
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 25 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|reminder arms 68 / pending-value arms 25 expected';
    END IF;

    -- ⑫ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes7b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES7B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes7b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES7B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes7b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

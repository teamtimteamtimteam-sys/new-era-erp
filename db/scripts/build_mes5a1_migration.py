#!/usr/bin/env python3
"""MES-5a-1(v1.4.43):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表的改动(加列、加行、换函数体)在这里逐句写出,并先断言镜像里那几行真的是这个样子
(check_mirrors 在重建侧对照)。照抄 build_mes4b_migration.py 的形状。
跑法:python3 db/scripts/build_mes5a1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-08-mes5a1-discharge-by-module.sql"

NEW_TABLES = ["discharge_module_results", "discharge_channel_assignments", "discharge_module_splits"]
NEW_FUNCS = ["set_batch_module_count", "discharge_verify_batch", "discharge_result_internal", "record_discharge_module_result",
             "correct_discharge_module_result", "discharge_channel_internal", "assign_discharge_channel", "correct_discharge_channel",
             "create_stock_transfer_internal", "split_failed_modules_to_quarantine"]
REPLACED_FUNCS = ["commit_processing_run", "rollback_processing_run_internal", "create_stock_transfer", "trail_subject_members"]
# 签名变了(末尾多一个可缺省的参数)—— CREATE OR REPLACE 换不了签名,所以 DROP 旧的、CREATE 新的(preflight 认这一对)
RESIGNED = {
    "create_inbound_batch": ("public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, "
                             "text[], text, text, text, text, uuid, numeric, text, text)"),
    "receive_inbound_batch_against_po": ("public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, "
                                         "text[], text, text, text, uuid, numeric, text, text)"),
}
NEW_VIEWS = ["discharge_module_current_all", "discharge_batch_status_all", "discharge_module_rows", "discharge_status_by_batch"]

STAFF_SIGS = ["public.set_batch_module_count(text, uuid, integer)",
              ("public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, "
               "numeric, numeric, uuid, text, text)"),
              ("public.correct_discharge_module_result(bigint, numeric, text, timestamp with time zone, text, integer, numeric, numeric, numeric, "
               "uuid, text, text, text)"),
              "public.assign_discharge_channel(uuid, text, uuid, integer, text)",
              "public.correct_discharge_channel(bigint, integer, text, boolean, text)",
              ("public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, "
               "text, uuid, numeric, uuid, text)"),
              ("public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, "
               "text, text, uuid, numeric, text, text, integer)"),
              ("public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, "
               "numeric, text, text, integer)")]
INTERNAL_SIGS = [("public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, "
                  "numeric, numeric, uuid, text, text, bigint, text)"),
                 "public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text)",
                 "public.discharge_verify_batch(text, uuid, uuid, text)",
                 "public.create_stock_transfer_internal(numeric, uuid, uuid, uuid, uuid, text, text)"]
TRIGGER_SIGS = ["public.guard_batch_module_count()"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name, replace):
    body = (ROOT / f"db/views/{name}.sql").read_text().rstrip("\n") + "\n"
    if replace:
        assert "CREATE VIEW public." in body, name
        body = body.replace("CREATE VIEW public.", "CREATE OR REPLACE VIEW public.", 1)
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def comment_on(path, target):
    """镜像里 COMMENT ON <target> IS '...'; 那一句,原样。"""
    m = re.search(rf"COMMENT ON {re.escape(target)} IS\n(?:    )?'.*?';\n", mirror(path), re.S)
    assert m, (path, target)
    return m.group(0)


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


HEADER = """-- db/migrations/2026-10-08-mes5a1-discharge-by-module.sql
-- MES-5a-1 —— 逐模组的放电结果、按结果核实、失效模组拆去隔离、放电的三处老毛病(MES 组的第七刀,v1.4.43;发布那一行在
-- docs/handbacks/MES-5a-1.md 的抬头)。由 db/scripts/build_mes5a1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-08:MES-5a Step 0 的放电那一半 —— Q3–Q18 与 Q1 · Q29–Q34 · Q36 的放电部分 —— 全部照建议裁定;
--   Q2 拆成两刀,能量那一半(Q19–Q28 · Q35 · V25)是 MES-5a-2;docs/surveys/MES-5a/STEP0-HANDBACK.md)
--   ① 模组数(Q4):两张批次表 + module_count(进料批是遮蔽表:列 + 列级授权 + _masked 视图,一支迁移)· guard_batch_module_count
--      (只对装电芯的形态成立;不许低于已有结论的模组数;核实之后锁住)· set_batch_module_count · 两支收货函数末尾一个可缺省的参数。
--   ② 逐模组结果(Q3 · Q5–Q8 · Q12):discharge_module_results(只追加;判失败处置必填;V9 抄进行里、矛盾只标出)·
--      discharge_channel_assignments(只追加)· record / correct_discharge_module_result(action.confirm_capture)·
--      assign / correct_discharge_channel(action.processing_aftercare)· 内层两支。设备转换器【没有建】(Bosch 的逐模组导出格式没人给过 ——
--      MES-3b Q25 · MES-4a Q14);结果行的来源 / 收件箱 / 草稿 / 现场数据那几列已经在。
--   ③ 按结果核实(Q5 · Q6):operation_types.verifies_by_unit(引导:只有 deep_discharge)—— 提交不再改状态;discharge_verify_batch
--      (每一个计数的模组都有一条当前的通过、或已被拆去隔离 → 已放电并核实,记下是哪一炉;不再成立 → 撤回)。
--   ④ 拆去隔离(Q11):discharge_quarantine_split(转化型工序;只从加工单页上起 —— started_from_run_page)· discharge_module_splits ·
--      split_failed_modules_to_quarantine · create_stock_transfer 拆成判码的外壳 + 内层(拆分的门是 aftercare,不是库存编辑码)。
--   ⑤ 三处老毛病(Q14 · Q15 · Q6):P3 产出批这一侧的放电不再扣库存;P2 回滚只在工序吃料时还原库存;P1 由 ③ 关掉。
--   ⑥ 读者与登记(Q18 · Q29–Q32):两张核实视图 + 两张带门的读法 · operations_now +2 支 · pending_values +1 支(V9,materials 上一列)·
--      审计记录(加工单 · 两种批次 · 设备)· 变更记录绑三张新表 · 关系图例外 +2 行(原批 ↔ 拆出来的那一批走拆分那一炉,两跳)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据、批次、加工单或
--   安全状态(PROC-2026-0494 与线上开着的两个状态原样);不给任何批次记模组数;不给任何物料通过电压(V9);不标任何隔离库位;不记任何通道;
--   require_calibrated_since 保持空。只播:deep_discharge 的 verifies_by_unit、一道新工序 discharge_quarantine_split 与它的受理 / 形态信息行、
--   关系图例外的两行。
--
-- 【破窗】见 docs/surveys/MES-5a/STEP0-HANDBACK.md §8:部署之前,旧表单记的一炉深度放电照样提交,但【不再核实】那一批(状态由结果改,
--   而旧应用没有记结果的地方)—— 部署之后在那一炉的页面上补记结果。线上没有 MES-4a 起记的加工单。其余照旧。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的每一张加工单与它的腿、每一批进料与产出(除了多出来的那一列,而它全是空的)、每一条安全状态、每一个物料、每一个库位逐字未变;
--   变更记录只在引导的那几张表上动了、恰好 15 行;新的数据表是空的;开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口;提醒臂 59 支;待补的值 18 支;每一张在途单据仍有一个不是它当事人的决定人。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))

# ── 既有表镜像里那几行,与下面逐句写出的改动逐字同义 —— 先断言镜像真的是这个样子 ──────────────────────────────
OT = "db/tables/operation_types.sql"
must(OT, "    verifies_by_unit            boolean NOT NULL DEFAULT false,\n")
must(OT, "    started_from_run_page       boolean NOT NULL DEFAULT false\n);")
ot_row = re.search(r"    \('discharge_quarantine_split', 'Quarantine split of failed modules'.*?'\);\n", mirror(OT), re.S).group(0)
ot_upd = must(OT, "UPDATE public.operation_types SET verifies_by_unit = true WHERE code = 'deep_discharge';\n"
                  "UPDATE public.operation_types SET started_from_run_page = true WHERE code = 'discharge_quarantine_split';\n")
SS = "db/tables/operation_type_safety_states.sql"
ss_rows = [r.rstrip(",;") for r in re.findall(r"^    \('discharge_quarantine_split', '[a-z_]+', false,\n     '.*?'\)[,;]$", mirror(SS), re.M | re.S)]
assert len(ss_rows) == 2, ss_rows
IFM = "db/tables/operation_type_input_forms.sql"
if_rows = [r.rstrip(",;") for r in re.findall(r"^    \('discharge_quarantine_split', '[a-z_]+', NULL\)[,;]$", mirror(IFM), re.M)]
assert len(if_rows) == 4, if_rows
OFM = "db/tables/operation_type_output_forms.sql"
of_rows = [r.rstrip(",;") for r in re.findall(r"^    \('discharge_quarantine_split', '[a-z_]+', '.*?'\)[,;]$", mirror(OFM), re.M)]
assert len(of_rows) == 4, of_rows
MT = "db/tables/materials.sql"
must(MT, "    discharge_pass_voltage_v numeric CHECK (discharge_pass_voltage_v IS NULL OR discharge_pass_voltage_v > 0)\n);")
IB = "db/tables/inbound_batches.sql"
must(IB, "    module_count              integer CHECK (module_count IS NULL OR module_count > 0),\n")
ib_grant = re.search(r"GRANT SELECT \(id, code, material_id.*?\)\n    ON public\.inbound_batches TO authenticated;\n", mirror(IB), re.S).group(0)
assert "module_count)" in ib_grant
ib_trg = must(IB, """CREATE TRIGGER trg_inbound_batches_module_count
    BEFORE INSERT OR UPDATE OF module_count, material_id ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_module_count();
""")
OB = "db/tables/output_batches.sql"
must(OB, "    module_count  integer CHECK (module_count IS NULL OR module_count > 0)\n);")
ob_trg = must(OB, """CREATE TRIGGER trg_output_batches_module_count
    BEFORE INSERT OR UPDATE OF module_count, material_id ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_module_count();
""")
DRE = "db/tables/document_relation_exceptions.sql"
dre_rows = [re.search(rf"^    (\('discharge_module_splits', '{a}', '{b}',\n     '.*?'\))[,]?$", mirror(DRE), re.M | re.S).group(1)
            for a, b in (("inbound_batch_id", "new_output_batch_id"), ("new_output_batch_id", "output_batch_id"))]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5A1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.discharge_module_results') IS NOT NULL OR to_regclass('public.discharge_channel_assignments') IS NOT NULL
       OR to_regclass('public.discharge_module_splits') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PRE|MES-5a-1 tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name IN ('inbound_batches', 'output_batches') AND column_name = 'module_count')
                      OR (table_name = 'materials' AND column_name = 'discharge_pass_voltage_v')
                      OR (table_name = 'operation_types' AND column_name IN ('verifies_by_unit', 'started_from_run_page')))) THEN
        RAISE EXCEPTION 'MES5A1_PRE|MES-5a-1 columns already exist';
    END IF;
    IF (SELECT count(*) FROM operation_types) <> 7 OR EXISTS (SELECT 1 FROM operation_types WHERE code = 'discharge_quarantine_split') THEN
        RAISE EXCEPTION 'MES5A1_PRE|operation types are not the MES-4b shape (7, no split operation)';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5A1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES5A1_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 57 THEN
        RAISE EXCEPTION 'MES5A1_PRE|operations_now should have 57 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 17 THEN
        RAISE EXCEPTION 'MES5A1_PRE|pending_values should have 17 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT transform_function FROM ingest_data_classes WHERE code = 'discharge_module') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PRE|the discharge_module class already has a transform';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5a1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes5a1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5a1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5a1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5a1_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) AS runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) AS inputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) AS outputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batches t) AS inbound,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batches t) AS output,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM materials t) AS materials,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batch_safety_states t) AS ib_states,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batch_safety_states t) AS ob_states,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM storage_locations t) AS locations,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inventory_movements t) AS movements;
""")

parts.append("\n-- ── 1 · 先建的函数:两张批次表上要挂的触发器(镜像原样)──────────────────────────\n")
parts.append(fn("guard_batch_module_count"))

parts.append(f"""
-- ── 2 · 工序(Q5 · Q11):按结果核实的标志 · 只从加工单页上起的标志 · 一道新工序(拆去隔离)与它的受理 / 形态信息行 ──────────
ALTER TABLE public.operation_types
    ADD COLUMN verifies_by_unit boolean NOT NULL DEFAULT false,
    ADD COLUMN started_from_run_page boolean NOT NULL DEFAULT false;
INSERT INTO public.operation_types (code, name_en, name_zh, kind_code, resulting_safety_state_code, sort_order, notes) VALUES
{ot_row.rstrip().rstrip(';').rstrip(',')};
{ot_upd}""")
for c in ("verifies_by_unit", "started_from_run_page"):
    parts.append(comment_on(OT, f"COLUMN public.operation_types.{c}"))
parts.append("INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES\n"
             + ",\n".join(ss_rows) + ";\n")
parts.append("INSERT INTO public.operation_type_input_forms (operation_type_code, form_code, notes) VALUES\n" + ",\n".join(if_rows) + ";\n")
parts.append("INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES\n" + ",\n".join(of_rows) + ";\n")

parts.append("""
-- ── 3 · V9(Q8):物料的放电通过电压 ──────────────────────────
ALTER TABLE public.materials ADD COLUMN discharge_pass_voltage_v numeric CHECK (discharge_pass_voltage_v IS NULL OR discharge_pass_voltage_v > 0);
""")
parts.append(comment_on(MT, "COLUMN public.materials.discharge_pass_voltage_v"))

parts.append(f"""
-- ── 4 · 进料批的模组数(Q4):一列 + 列级授权 + 遮蔽视图(三件事一起)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.inbound_batches ADD COLUMN module_count integer CHECK (module_count IS NULL OR module_count > 0);
{ib_grant}{ib_trg}""")
parts.append(comment_on(IB, "COLUMN public.inbound_batches.module_count"))
parts.append(view("inbound_batches_masked", True))

parts.append(f"""
-- ── 5 · 产出批的模组数(Q4;不是遮蔽表)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.output_batches ADD COLUMN module_count integer CHECK (module_count IS NULL OR module_count > 0);
{ob_trg}""")
parts.append(comment_on(OB, "COLUMN public.output_batches.module_count"))

parts.append("\n-- ── 5b · 更正一句过期的列注释(MES-5a Step 0 §10.4 · Q36):processing_runs.equipment_id 说\"没有工序 ↔ 资产的关联\",MES-4a 之后不成立 ──\n")
parts.append(comment_on("db/tables/processing_runs.sql", "COLUMN public.processing_runs.equipment_id"))

parts.append("\n-- ── 6 · 三张新表(镜像原样:结果 · 通道分配 · 拆去隔离的模组)──────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))
parts.append(f"""
-- 关系图例外:原批 ↔ 拆出来的那一批走拆分那一炉加工单(两跳),与进料批 ↔ 产出批不进图同一条裁定(fixture 103 A)。镜像原样。
INSERT INTO public.document_relation_exceptions (owner_table, column_a, column_b, reason) VALUES
    {dre_rows[0]},
    {dre_rows[1]};
""")

parts.append("\n-- ── 7a · 四张新视图(镜像原样)—— 排在函数【之前】:discharge_verify_batch 用 discharge_batch_status_all%ROWTYPE,\n"
             "--        迁移里 check_function_bodies 是开着的,声明在建函数那一刻就要解析(重建侧关着它,所以那边看不见这个先后)──────\n")
for v in NEW_VIEWS:
    parts.append(view(v, False))
parts.append("\n-- ── 7 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 8 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 9 · 签名变了的两支:DROP 旧的、CREATE 新的(末尾一个可缺省的参数 p_module_count)────────────────────────\n")
for f, old in RESIGNED.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))

parts.append("\n-- ── 10 · 视图(镜像原样):待补的值与提醒 ──────────────────────\n")
for v in ["pending_values", "operations_now"]:
    parts.append(view(v, True))

parts.append("\n-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──────────────────────────\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS + TRIGGER_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS + TRIGGER_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes5a1_pending_decider_check")
parts.append("\n-- ── 13 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS + TRIGGER_SIGS)
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)

parts.append(f"""
CREATE TEMP TABLE mes5a1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行都没动(本刀不加码、不改授权)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5a1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes5a1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5A1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5a1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5a1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的加工单与它的腿、安全状态、库位、库存流水逐字未变(PROC-2026-0494 在加工单那一份里);
    --   批次与物料除了多出来的那一列(全空)逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes5a1_pending_before b EXCEPT SELECT a.k, a.id FROM mes5a1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5a1_pending_after a EXCEPT SELECT b.k, b.id FROM mes5a1_pending_before b)) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT runs FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) IS DISTINCT FROM (SELECT inputs FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) IS DISTINCT FROM (SELECT outputs FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batch_safety_states t) IS DISTINCT FROM (SELECT ib_states FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batch_safety_states t) IS DISTINCT FROM (SELECT ob_states FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM storage_locations t) IS DISTINCT FROM (SELECT locations FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inventory_movements t) IS DISTINCT FROM (SELECT movements FROM mes5a1_rows_before) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a pre-existing run, leg, safety state, location or stock movement changed';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'module_count')::text, '|' ORDER BY t.id), '')) FROM inbound_batches t)
           IS DISTINCT FROM (SELECT inbound FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'module_count')::text, '|' ORDER BY t.id), '')) FROM output_batches t)
           IS DISTINCT FROM (SELECT output FROM mes5a1_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'discharge_pass_voltage_v')::text, '|' ORDER BY t.id), '')) FROM materials t)
           IS DISTINCT FROM (SELECT materials FROM mes5a1_rows_before)
       OR EXISTS (SELECT 1 FROM inbound_batches WHERE module_count IS NOT NULL)
       OR EXISTS (SELECT 1 FROM output_batches WHERE module_count IS NOT NULL)
       OR EXISTS (SELECT 1 FROM materials WHERE discharge_pass_voltage_v IS NOT NULL) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a pre-existing batch or material changed, or a module count / V9 was set';
    END IF;

    -- ④ 变更记录只在引导的那几张表上动了,恰好 15 行:工序 1 + 2(两个标志)· 受理 2 · 投料形态 4 · 产出形态 4 · 关系图例外 2。
    --   三张新表的绑定在建表之后(第 11 段),它们都是空的,所以不进变更记录。
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes5a1_log_before), 0)
       AND c.table_name NOT IN ('operation_types', 'operation_type_safety_states', 'operation_type_input_forms',
                                'operation_type_output_forms', 'document_relation_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5a1_log_before), 0)) <> 15 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|expected 15 change-log rows, got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5a1_log_before), 0));
    END IF;

    -- ⑤ 引导恰好是引导;新的数据表是空的;没有隔离库位被标;开关空着;设备转换器没有建
    IF (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types WHERE verifies_by_unit) IS DISTINCT FROM 'deep_discharge'
       OR (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types WHERE started_from_run_page) IS DISTINCT FROM 'discharge_quarantine_split'
       OR (SELECT kind_code FROM operation_types WHERE code = 'discharge_quarantine_split') IS DISTINCT FROM 'transforming'
       OR (SELECT count(*) FROM operation_types) <> 8 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|the operation flags are not exactly deep_discharge / the split operation (8 operations)';
    END IF;
    IF EXISTS (SELECT 1 FROM discharge_module_results) OR EXISTS (SELECT 1 FROM discharge_channel_assignments)
       OR EXISTS (SELECT 1 FROM discharge_module_splits) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a new data table is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine) THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a quarantine location exists (none was expected and none may be set by this cut)';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PROOF|require_calibrated_since was set';
    END IF;
    IF (SELECT transform_function FROM ingest_data_classes WHERE code = 'discharge_module') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a discharge_module transform appeared';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到;旧签名不在了
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5A1_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|anon can read %', v_bad; END IF;
    IF to_regprocedure('{RESIGNED["create_inbound_batch"]}') IS NOT NULL
       OR to_regprocedure('{RESIGNED["receive_inbound_batch_against_po"]}') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A1_PROOF|an old receipt-function signature survived';
    END IF;
    IF has_column_privilege('authenticated', 'public.inbound_batches'::regclass, 'module_count', 'SELECT') IS NOT TRUE THEN
        RAISE EXCEPTION 'MES5A1_PROOF|inbound_batches.module_count is not readable by authenticated (the grant is missing)';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;三张新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('discharge_module_results', 'discharge_channel_assignments', 'discharge_module_splits') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES5A1_PROOF|a write policy exists on a new discharge table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表都记,豁免仍是 8);遮蔽零缺口(仍是 105 条);每一张被记录的表的绑定键都是它的主键
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    SELECT string_agg(t.relname, ', ') INTO v_bad
      FROM (SELECT c.relname, substring(pg_get_triggerdef(tg.oid) FROM 'change_log_capture\\((.*)\\)') AS args
              FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND tg.tgname = 'zzz_change_log') t
      LEFT JOIN (SELECT c.relname, string_agg(quote_literal(a.attname), ', ' ORDER BY array_position(i.indkey::int2[], a.attnum)) AS cols
                   FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey)
                  WHERE n.nspname = 'public' AND i.indisprimary GROUP BY c.relname) pk ON pk.relname = t.relname
     WHERE t.args IS DISTINCT FROM pk.cols;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A1_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑨ 提醒臂 57 → 59;待补的值 17 → 18 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|operations_now should have 59 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 18 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|pending_values should have 18 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5a1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5A1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5a1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5A1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5a1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

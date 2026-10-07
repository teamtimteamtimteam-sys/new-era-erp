#!/usr/bin/env python3
"""MES-4a(v1.4.41):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表的改动(加列、换策略、换触发器、损耗表改成只追加)在这里逐句写出,
并先断言镜像里那几行真的是这个样子(check_mirrors 在重建侧对照)。照抄 build_mes3b_migration.py 的形状。
跑法:python3 db/scripts/build_mes4a_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-07-mes4a-processing-record.sql"

# 先建:新表的触发器要用的、以及改造既有表时要挂的触发器函数(函数体不引用还不存在的类型)
EARLY_FUNCS = ["assert_run_header", "guard_processing_run_header", "guard_processing_run_losses", "guard_processing_direct_write"]
# 新表(按依赖顺序;镜像原样 —— 带它们自己的守卫函数、引导行、策略与触发器)
NEW_TABLES = ["operation_type_fields", "operation_type_equipment", "process_recipes", "process_recipe_versions",
              "processing_event_types", "processing_run_values", "processing_run_events", "processing_run_closures",
              "processing_run_corrections"]
NEW_FUNCS = ["assert_run_equipment", "record_manual_weighing_internal", "record_run_value_internal", "record_run_value",
             "correct_run_value", "run_event_check", "record_run_event", "correct_run_event", "record_run_loss", "correct_run_loss",
             "create_recipe_version", "close_run_balance", "correct_run_header", "processing_runs_unclosed_balance"]
REPLACED_FUNCS = ["correct_weighing", "trail_subjects", "trail_subject_members", "record_trail", "trail_refs", "trail_ref_label"]
# 参数表变了(末尾多六个可缺省的参数)—— CREATE OR REPLACE 换不了签名,所以 DROP 旧的、CREATE 新的(preflight 认这一对)
RESIGNED = {"commit_processing_run": "public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text)"}
REPLACED_VIEWS = ["processing_runs_masked", "processing_outputs_masked", "processing_run_loss_breakdown", "equipment_usage",
                  "pending_values", "operations_now"]
NEW_VIEWS = ["processing_run_balance_all", "processing_run_balance", "run_weighing_options", "processing_run_values_current"]

STAFF_SIGS = ["public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)",
              "public.record_run_value(uuid, text, jsonb)", "public.correct_run_value(bigint, jsonb, text)",
              "public.record_run_event(uuid, text, timestamp with time zone, numeric, text, text, text)",
              "public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text)",
              "public.record_run_loss(uuid, text, numeric, text)", "public.correct_run_loss(bigint, numeric, text)",
              "public.create_recipe_version(uuid, jsonb, text)", "public.close_run_balance(uuid, text)",
              "public.correct_run_header(uuid, text, text, text)", "public.processing_runs_unclosed_balance(date)"]
INTERNAL_SIGS = ["public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text)",
                 "public.assert_run_equipment(text, uuid, date)", "public.record_manual_weighing_internal(numeric, uuid)",
                 "public.record_run_value_internal(uuid, text, jsonb, text, bigint, text)",
                 "public.run_event_check(text, timestamp with time zone, numeric, text, text)"]
TRIGGER_SIGS = ["public.guard_processing_run_header()", "public.guard_operation_type_field()",
                "public.guard_operation_type_equipment()", "public.guard_process_recipe()"]
APPEND_ONLY = ["process_recipe_versions", "processing_run_values", "processing_run_events", "processing_run_closures",
               "processing_run_corrections", "processing_run_losses"]


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


HEADER = """-- db/migrations/2026-10-07-mes4a-processing-record.sql
-- MES-4a —— 加工记录:参数、配方与物料平衡结平(MES 组的第五刀,v1.4.41;发布那一行在 docs/handbacks/MES-4a.md 的抬头)。
-- 由 db/scripts/build_mes4a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-07:MES-4a Step 0 的 Q1–Q36 全部照建议裁定;docs/surveys/MES-4a/STEP0-HANDBACK.md §15)
--   ① 表头(Q7 · Q8 · Q9):processing_runs 加 started_at · ended_at · shift_code(MES-4a 起必填 —— INSERT 触发器 + 提交函数里同一支
--      assert_run_header,只管新行)· recipe_version_id · corrects_run_id。工序 ↔ 机器(operation_type_equipment):挂着没处置的机器的
--      工序必须选挂着的那一台(assert_run_equipment)。一条都不预挂。
--   ② 参数与指标(Q10–Q15):operation_type_fields(配置是数据;引导规格书点名的计数与指标,全部不必填、没有范围)·
--      processing_run_values(只追加,越界照记标出来)· processing_event_types(三种,没有 other)· processing_run_events(只追加)。
--      不建任何设备转换器(Q14)。
--   ③ 配方(Q16):process_recipes · process_recipe_versions(一版写了不改);加工单记它用的那一版,预填参数。
--   ④ 称重(Q24–Q26):processing_outputs.weighing_id —— MES-4a 起每一条转化型产出腿都挂一次称重(挑一条,或在提交时敲重量经正常路径落一条
--      手工称重);不在校准期内的拒;挂上之后那条称重不再更正(WEIGHING_IN_USE)。
--   ⑤ 损耗与结平(Q17–Q23 · Q28):loss_qty = 投入 − 产出(敲一个不同的数按名拒);processing_run_losses 改成只追加(id 主键、更正链、
--      撤回 = 更正成 0;只经两支函数写);processing_run_closures(只追加,按 id 水位线重开)· close_run_balance · 两张平衡视图;
--      operation_types.balance_tolerance_pct(V1)。三类新损耗(取样消耗 · 留在设备里的料 · 回收的扫地料)。
--   ⑥ 更正(Q29–Q32):processing_run_corrections + correct_run_header(六个字段);三张加工表的 UPDATE 策略拿掉(ROLE1B3B 关闭),
--      直连改按名拒。
--   ⑦ 两道新工序(Q3):casing_removal · electrode_separation(只受理已放电并核实的料)。
--   ⑧ 读者:operations_now +1 支(processing_balance_unclosed)· pending_values +2 支(V1 · V36),V6 的去处搬到班次字典 ·
--      月末的一行警告(processing_runs_unclosed_balance,不挡关账)· 审计记录(加工单 +4 成员;新主语 operation_type;两本字典)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据或加工单;
--   不挂任何机器、不建任何配方、不给任何容差、范围或班次时刻;不碰 MES-3a / 3b 的任何设定;require_calibrated_since 保持空。
--   只播:两道工序(连同它们的形态与安全状态行)、27 个字段、三类损耗、三种异常事件,与例外表的两行。
--
-- 【破窗】见 docs/surveys/MES-4a/STEP0-HANDBACK.md §13:旧的加工单表单照名调 commit_processing_run,而它现在要开始、结束、班次
--   与称重 —— 部署之前,从页面记一张加工单按名拒(RUN_TIMES_REQUIRED);旧的损耗面板直连写,写策略已拿掉 —— 部署之前分类损耗被拒。
--   读的一侧只多了列。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的每一张加工单、每一条产出腿与投入腿逐字未变;变更记录只在引导的那几张字典与例外表上动了;新的数据表全是空的;
--   没有一台机器被挂、没有一个配方、容差、范围或班次时刻;开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;
--   那 44 条开着的读策略还是 44 条;三张加工表的写策略恰好拿掉;变更记录覆盖与遮蔽零缺口;每一张被记录的表的绑定键都是它的主键;
--   提醒臂 56 支;待补的值 15 支;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

RUN_COLS = ("id, code, process_date, total_input, total_output, loss_qty, notes, status, deleted_at, created_at, created_by, updated_at, "
            "updated_by, allocation_basis, material_cost_base, process_cost_base, total_cost_base, allocation_snapshot, allocated_at, "
            "allocated_by, capitalized_cost_base, capitalization_entry_id, allocation_basis_changed_at, work_order_id, deleted_by, "
            "delete_reason, equipment_id, operation_type_code")

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))
loss_bind = re.search(r"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.processing_run_losses\n.*?\n", bindings).group(0)
assert "change_log_capture('id')" in loss_bind

# ── 既有表镜像里那几行,与下面逐句写出的改动逐字同义 —— 先断言镜像真的是这个样子 ──────────────────────────────
PR = "db/tables/processing_runs.sql"
must(PR, "    started_at          timestamptz,\n    ended_at            timestamptz,\n    shift_code          text REFERENCES public.shifts (code),\n")
must(PR, "    recipe_version_id   uuid REFERENCES public.process_recipe_versions (id),\n")
must(PR, "    corrects_run_id     uuid UNIQUE REFERENCES public.processing_runs (id),\n")
must(PR, "    CONSTRAINT processing_runs_end_after_start CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at > started_at)\n);")
pr_grant = re.search(r"GRANT SELECT \(id, code, process_date.*?\)\n    ON public\.processing_runs TO authenticated;\n", mirror(PR), re.S).group(0)
assert "corrects_run_id)" in pr_grant
pr_trg = must(PR, """CREATE TRIGGER trg_processing_runs_direct_write
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_direct_write();
CREATE TRIGGER trg_processing_runs_direct_change
    BEFORE UPDATE OR DELETE ON public.processing_runs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();
""")
pr_hdr = must(PR, """CREATE TRIGGER trg_processing_runs_header
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_header();
""")
assert '"processing_runs update by permission"' not in mirror(PR)

PO = "db/tables/processing_outputs.sql"
must(PO, "    weighing_id     uuid UNIQUE REFERENCES public.weighings (id)\n);")
po_grant = must(PO, """GRANT SELECT (id, run_id, output_batch_id, quantity_produced, created_at, cost_incomplete, weighing_id)
    ON public.processing_outputs TO authenticated;""")
po_trg = must(PO, """CREATE TRIGGER trg_processing_outputs_direct_change
    BEFORE UPDATE OR DELETE ON public.processing_outputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();""")
assert '"processing_outputs update by permission"' not in mirror(PO)

PI = "db/tables/processing_inputs.sql"
pi_trg = must(PI, """CREATE TRIGGER trg_processing_inputs_direct_change
    BEFORE UPDATE OR DELETE ON public.processing_inputs
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_processing_direct_write();""")
assert '"processing_inputs update by permission"' not in mirror(PI)

PL = "db/tables/processing_run_losses.sql"
must(PL, "    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n"
         "    corrects_id        bigint UNIQUE REFERENCES public.processing_run_losses (id),\n"
         "    correction_reason  text,\n")
pl_qty = must(PL, """    CONSTRAINT processing_run_losses_quantity_shape
        CHECK (quantity > 0 OR (quantity = 0 AND corrects_id IS NOT NULL)),""")
pl_corr = must(PL, """    CONSTRAINT processing_run_losses_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''))""")
pl_idx = must(PL, """CREATE UNIQUE INDEX processing_run_losses_one_original ON public.processing_run_losses (run_id, loss_category_code)
    WHERE corrects_id IS NULL;""")
pl_ctrg = must(PL, """CREATE CONSTRAINT TRIGGER trg_processing_run_losses_within_total
    AFTER INSERT ON public.processing_run_losses
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_losses();""")
pl_ao = must(PL, """CREATE TRIGGER trg_processing_run_losses_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.processing_run_losses
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();""")
assert "insert by permission" not in mirror(PL)

OT = "db/tables/operation_types.sql"
must(OT, "    balance_tolerance_pct       numeric CHECK (balance_tolerance_pct IS NULL OR balance_tolerance_pct >= 0)\n);")
ot_rows = re.findall(r"^    \('(casing_removal|electrode_separation)', .*?'\)[,;]$", mirror(OT), re.M | re.S)
assert ot_rows == ["casing_removal", "electrode_separation"], ot_rows
ot_seed = re.search(r"    \('casing_removal', 'Casing removal'.*?的料。'\);\n", mirror(OT), re.S).group(0)


def seed_rows(path, keys):
    """镜像引导里以这些键开头的那几行(逐字)。"""
    out = []
    for line in mirror(path).splitlines():
        if any(line.startswith(f"    ('{k}'") for k in keys):
            out.append(line.rstrip(",;").rstrip())
    return out


in_rows = seed_rows("db/tables/operation_type_input_forms.sql", ["casing_removal", "electrode_separation"])
out_rows = seed_rows("db/tables/operation_type_output_forms.sql", ["casing_removal", "electrode_separation"])
ss_rows = seed_rows("db/tables/operation_type_safety_states.sql", ["casing_removal", "electrode_separation"])
assert len(in_rows) == 2 and len(out_rows) == 5 and len(ss_rows) == 2, (in_rows, out_rows, ss_rows)
lc = mirror("db/tables/loss_categories.sql")
lc_rows = re.search(r"    \('sampling_consumption',\n.*?留着。'\);\n", lc, re.S).group(0).rstrip().rstrip(";")
assert lc_rows.count("\n    ('") == 2

dte = mirror("db/tables/document_type_exceptions.sql")
dte_rows = [re.search(rf"^    (\('{t}',.*?\))[,;]?$", dte, re.M).group(1) for t in ("process_recipes", "processing_event_types")]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES4A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.operation_type_fields') IS NOT NULL OR to_regclass('public.processing_run_values') IS NOT NULL
       OR to_regclass('public.processing_run_closures') IS NOT NULL OR to_regclass('public.process_recipes') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4A_PRE|MES-4a tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name = 'processing_runs' AND column_name IN ('started_at', 'ended_at', 'shift_code', 'recipe_version_id', 'corrects_run_id'))
                      OR (table_name = 'processing_outputs' AND column_name = 'weighing_id')
                      OR (table_name = 'processing_run_losses' AND column_name IN ('id', 'corrects_id'))
                      OR (table_name = 'operation_types' AND column_name = 'balance_tolerance_pct'))) THEN
        RAISE EXCEPTION 'MES4A_PRE|MES-4a columns already exist';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types)
       IS DISTINCT FROM 'battery_powder_line,deep_discharge,electrode_line,electrode_powder_line,manual_disassembly' THEN
        RAISE EXCEPTION 'MES4A_PRE|operation_types are not the five expected';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4A_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4A_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES4A_PRE|operations_now should have 55 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 13 THEN
        RAISE EXCEPTION 'MES4A_PRE|pending_values should have 13 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES4A_PRE|require_calibrated_since must be empty';
    END IF;
    IF EXISTS (SELECT 1 FROM shifts WHERE starts_at IS NOT NULL OR ends_at IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PRE|shift times are expected empty';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes4a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes4a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes4a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes4a_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes4a_runs_before ON COMMIT DROP AS
SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t.id), '')) AS digest, count(*) AS n
  FROM (SELECT {RUN_COLS} FROM processing_runs) t;
CREATE TEMP TABLE mes4a_legs_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(i::text, '|' ORDER BY i.id), '')) FROM (SELECT id, run_id, inbound_batch_id, quantity_consumed, created_at, output_batch_id FROM processing_inputs) i) AS inputs,
       (SELECT md5(COALESCE(string_agg(o::text, '|' ORDER BY o.id), '')) FROM (SELECT id, run_id, output_batch_id, quantity_produced, created_at, allocated_cost_base, unit_cost_base, cost_incomplete FROM processing_outputs) o) AS outputs,
       (SELECT count(*) FROM processing_run_losses) AS losses;
""")

parts.append("\n-- ── 1 · 先建的函数:改造既有表时要挂的触发器(镜像原样)──────────────────────────\n")
for f in EARLY_FUNCS:
    parts.append(fn(f))

parts.append("""
-- ── 2 · 工序字典:两道新工序(Q3)与它们的形态、安全状态行;容差列(V1);三类新损耗(Q2 · Q56)──────────
ALTER TABLE public.operation_types ADD COLUMN balance_tolerance_pct numeric CHECK (balance_tolerance_pct IS NULL OR balance_tolerance_pct >= 0);
""")
parts.append(comment_on(OT, "COLUMN public.operation_types.balance_tolerance_pct"))
parts.append("INSERT INTO public.operation_types (code, name_en, name_zh, kind_code, resulting_safety_state_code, sort_order, notes) VALUES\n"
             + ot_seed)
parts.append("INSERT INTO public.operation_type_input_forms (operation_type_code, form_code, notes) VALUES\n"
             + ",\n".join(in_rows) + ";\n")
parts.append("INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES\n"
             + ",\n".join(out_rows) + ";\n")
parts.append("INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES\n"
             + ",\n".join(ss_rows) + ";\n")
parts.append("INSERT INTO public.loss_categories (code, name_en, name_zh, metal_fate, is_true_loss, sort_order, notes) VALUES\n"
             + lc_rows + ";\n")

parts.append("\n-- ── 3 · 九张新表(镜像原样,带它们的守卫、引导、策略与触发器)──────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    {dte_rows[0]},
    {dte_rows[1]};
""")

parts.append(f"""
-- ── 4 · 加工单表头(Q7 · Q16 · Q31 · Q32):五列 + 授权 + 遮蔽视图(三件事一起);UPDATE 策略拿掉;直连改按名拒;新单的表头闸 ──
ALTER TABLE public.processing_runs
    ADD COLUMN started_at timestamptz,
    ADD COLUMN ended_at timestamptz,
    ADD COLUMN shift_code text REFERENCES public.shifts (code),
    ADD COLUMN recipe_version_id uuid REFERENCES public.process_recipe_versions (id),
    ADD COLUMN corrects_run_id uuid UNIQUE REFERENCES public.processing_runs (id),
    ADD CONSTRAINT processing_runs_end_after_start CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at > started_at);
DROP POLICY "processing_runs update by permission" ON public.processing_runs;
{pr_grant}
DROP TRIGGER trg_processing_runs_direct_write ON public.processing_runs;
DROP TRIGGER trg_processing_runs_direct_delete ON public.processing_runs;
{pr_trg}{pr_hdr}""")
for c in ("started_at", "shift_code", "corrects_run_id"):
    parts.append(comment_on(PR, f"COLUMN public.processing_runs.{c}"))
parts.append(view("processing_runs_masked", True))

parts.append(f"""
-- ── 5 · 产出腿的称重(Q24):一列 + 授权 + 遮蔽视图;UPDATE 策略拿掉;直连改按名拒 ──────────────────────────
ALTER TABLE public.processing_outputs ADD COLUMN weighing_id uuid UNIQUE REFERENCES public.weighings (id);
DROP POLICY "processing_outputs update by permission" ON public.processing_outputs;
{po_grant}
DROP TRIGGER trg_processing_outputs_direct_delete ON public.processing_outputs;
{po_trg}
""")
parts.append(comment_on(PO, "COLUMN public.processing_outputs.weighing_id"))
parts.append(view("processing_outputs_masked", True))

parts.append(f"""
-- ── 6 · 投入腿:UPDATE 策略拿掉;直连改按名拒 ──────────────────────────────────────────
DROP POLICY "processing_inputs update by permission" ON public.processing_inputs;
DROP TRIGGER trg_processing_inputs_direct_delete ON public.processing_inputs;
{pi_trg}

-- ── 7 · 损耗改成只追加(Q28):id 主键 · 更正链 · 撤回 = 更正成 0 · 只经两支函数写 · 绑定键跟着换 ──────────────────
DROP POLICY "processing_run_losses insert by permission" ON public.processing_run_losses;
DROP POLICY "processing_run_losses update by permission" ON public.processing_run_losses;
DROP POLICY "processing_run_losses delete by permission" ON public.processing_run_losses;
DROP TRIGGER enforce_write_permission ON public.processing_run_losses;
DROP TRIGGER trg_processing_run_losses_within_total ON public.processing_run_losses;
ALTER TABLE public.processing_run_losses DROP CONSTRAINT processing_run_losses_pkey;
ALTER TABLE public.processing_run_losses DROP CONSTRAINT processing_run_losses_quantity_check;
ALTER TABLE public.processing_run_losses
    ADD COLUMN id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ADD COLUMN corrects_id bigint UNIQUE REFERENCES public.processing_run_losses (id),
    ADD COLUMN correction_reason text,
    ADD CONSTRAINT processing_run_losses_quantity_shape
        CHECK (quantity > 0 OR (quantity = 0 AND corrects_id IS NOT NULL)),
    ADD CONSTRAINT processing_run_losses_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> ''));
{pl_idx}
{pl_ctrg}
{pl_ao}
REVOKE ALL ON public.processing_run_losses FROM authenticated, anon;
GRANT SELECT ON public.processing_run_losses TO authenticated;
DROP TRIGGER zzz_change_log ON public.processing_run_losses;
{loss_bind}""")
parts.append(comment_on(PL, "TABLE public.processing_run_losses"))
parts.append(comment_on(PL, "COLUMN public.processing_run_losses.quantity"))

parts.append("\n-- ── 8 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 9 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 10 · 签名变了的一支:DROP 旧的、CREATE 新的(末尾六个可缺省的参数)────────────────────────\n")
for f, old in RESIGNED.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))

parts.append("\n-- ── 11 · 视图(镜像原样):改过的 CREATE OR REPLACE(列只在末尾加)· 新的三张 ──────────────────────\n")
for v in ["processing_run_loss_breakdown", "equipment_usage"]:
    parts.append(view(v, True))
for v in NEW_VIEWS:
    parts.append(view(v, False))
for v in ["pending_values", "operations_now"]:
    parts.append(view(v, True))

parts.append("\n-- ── 12 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──────────────────────────\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 13 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS + TRIGGER_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes4a_pending_decider_check")
parts.append("\n-- ── 14 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4A_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure) THEN
        RAISE EXCEPTION 'MES4A_PROOF|{sig} must be an internal function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)
ao_list = ", ".join(f"'{r}'" for r in APPEND_ONLY)

parts.append(f"""
CREATE TEMP TABLE mes4a_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM mes4a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes4a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES4A_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes4a_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes4a_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES4A_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有加工单与它们的腿、损耗逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes4a_pending_before b EXCEPT SELECT a.k, a.id FROM mes4a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes4a_pending_after a EXCEPT SELECT b.k, b.id FROM mes4a_pending_before b)) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t.id), '')) FROM (SELECT {RUN_COLS} FROM processing_runs) t)
       IS DISTINCT FROM (SELECT digest FROM mes4a_runs_before) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pre-existing processing run changed';
    END IF;
    IF EXISTS (SELECT 1 FROM processing_runs WHERE started_at IS NOT NULL OR ended_at IS NOT NULL OR shift_code IS NOT NULL
                 OR recipe_version_id IS NOT NULL OR corrects_run_id IS NOT NULL)
       OR EXISTS (SELECT 1 FROM processing_outputs WHERE weighing_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pre-existing run or leg got a MES-4a value';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(i::text, '|' ORDER BY i.id), '')) FROM (SELECT id, run_id, inbound_batch_id, quantity_consumed, created_at, output_batch_id FROM processing_inputs) i)
           IS DISTINCT FROM (SELECT inputs FROM mes4a_legs_before)
       OR (SELECT md5(COALESCE(string_agg(o::text, '|' ORDER BY o.id), '')) FROM (SELECT id, run_id, output_batch_id, quantity_produced, created_at, allocated_cost_base, unit_cost_base, cost_incomplete FROM processing_outputs) o)
           IS DISTINCT FROM (SELECT outputs FROM mes4a_legs_before)
       OR (SELECT count(*) FROM processing_run_losses) <> (SELECT losses FROM mes4a_legs_before)
       OR EXISTS (SELECT 1 FROM processing_run_losses WHERE corrects_id IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a pre-existing input leg, output leg or loss row changed';
    END IF;

    -- ④ 变更记录只在引导的那几张字典与例外表上动了(两道工序 2 · 投料形态 2 · 产出形态 5 · 安全状态 2 · 损耗类别 3 · 例外表 2 = 16);
    --   新表的引导在它们的绑定之前插入(第 3 段 → 第 12 段),所以不进变更记录
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes4a_log_before)
       AND c.table_name NOT IN ('operation_types', 'operation_type_input_forms', 'operation_type_output_forms',
                                'operation_type_safety_states', 'loss_categories', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4a_log_before)) <> 16 THEN
        RAISE EXCEPTION 'MES4A_PROOF|expected 16 change-log rows, got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4a_log_before));
    END IF;

    -- ⑤ 引导恰好是引导;新的数据表全是空的;一台机器都没挂;容差、范围、班次时刻、开关都空着
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM operation_types)
       IS DISTINCT FROM 'deep_discharge,manual_disassembly,electrode_line,electrode_powder_line,battery_powder_line,casing_removal,electrode_separation'
       OR EXISTS (SELECT 1 FROM operation_types WHERE balance_tolerance_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|operation_types are not the seven expected, or a tolerance was set';
    END IF;
    IF (SELECT count(*) FROM operation_type_fields) <> 27
       OR EXISTS (SELECT 1 FROM operation_type_fields WHERE is_required OR has_range OR range_min IS NOT NULL OR range_max IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|the fields are not exactly their bootstrap (27, none required, no range)';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM processing_event_types) IS DISTINCT FROM 'unplanned_stop,equipment_alarm,safety_alarm' THEN
        RAISE EXCEPTION 'MES4A_PROOF|the event types are not exactly their bootstrap';
    END IF;
    IF (SELECT count(*) FROM loss_categories) <> 7 THEN
        RAISE EXCEPTION 'MES4A_PROOF|expected 7 loss categories';
    END IF;
    IF EXISTS (SELECT 1 FROM operation_type_equipment) OR EXISTS (SELECT 1 FROM process_recipes) OR EXISTS (SELECT 1 FROM process_recipe_versions)
       OR EXISTS (SELECT 1 FROM processing_run_values) OR EXISTS (SELECT 1 FROM processing_run_events)
       OR EXISTS (SELECT 1 FROM processing_run_closures) OR EXISTS (SELECT 1 FROM processing_run_corrections) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a new data table is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM shifts WHERE starts_at IS NOT NULL OR ends_at IS NOT NULL)
       OR (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL
       OR EXISTS (SELECT 1 FROM nea_waste_categories) OR EXISTS (SELECT 1 FROM licence_storage_limits)
       OR EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine)
       OR EXISTS (SELECT 1 FROM materials WHERE dg_code IS NOT NULL OR hs_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4A_PROOF|a shift time, the calibration switch or a MES-3a / 3b setting was set';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES4A_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|anon can read %', v_bad; END IF;
    IF to_regprocedure('public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4A_PROOF|the old commit_processing_run signature survived';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;只追加的表上没有写策略;三张加工表与损耗表的写策略恰好是这样
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4A_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ({ao_list}) AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES4A_PROOF|a write policy exists on an append-only table';
    END IF;
    SELECT string_agg(tablename || ':' || cmd, ',' ORDER BY tablename, cmd) INTO v_bad FROM pg_policies
     WHERE schemaname = 'public' AND tablename IN ('processing_runs', 'processing_inputs', 'processing_outputs', 'processing_run_losses');
    IF v_bad IS DISTINCT FROM 'processing_inputs:INSERT,processing_inputs:SELECT,processing_outputs:SELECT,processing_run_losses:SELECT,processing_runs:SELECT' THEN
        RAISE EXCEPTION 'MES4A_PROOF|processing policies are %', v_bad;
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(九张新表都记,豁免仍是 8);遮蔽零缺口(仍是 105 条);每一张被记录的表的绑定键都是它的主键
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES4A_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4A_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
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
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4A_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑨ 提醒臂 55 → 56;待补的值 13 → 15 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 56 THEN
        RAISE EXCEPTION 'MES4A_PROOF|operations_now should have 56 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 15 THEN
        RAISE EXCEPTION 'MES4A_PROOF|pending_values should have 15 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes4a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES4A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes4a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES4A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes4a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

#!/usr/bin/env python3
"""MES-4b(v1.4.42):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表的改动(加列、加行、换函数体)在这里逐句写出,并先断言镜像里那几行真的是这个样子
(check_mirrors 在重建侧对照)。照抄 build_mes4a_migration.py 的形状。
跑法:python3 db/scripts/build_mes4b_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-07-mes4b-fields-and-products.sql"

NEW_DICTS = ["cell_constructions", "contamination_streams"]
NEW_FUNCS = ["set_batch_cell_construction", "record_derived_electrolyte_loss", "rederive_electrolyte_loss",
             "contamination_check_internal", "record_contamination_check", "correct_contamination_check"]
REPLACED_FUNCS = ["commit_processing_run", "record_run_loss", "correct_run_loss", "trail_subjects", "trail_subject_members",
                  "generate_device_code", "generate_weighbridge_ticket_code"]
# 签名变了(末尾多一个可缺省的参数)—— CREATE OR REPLACE 换不了签名,所以 DROP 旧的、CREATE 新的(preflight 认这一对)
RESIGNED = {
    "create_inbound_batch": "public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text)",
    "receive_inbound_batch_against_po": "public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text)",
}
# 写在表镜像里的取号函数(CODE-WIDTH-4:11 支有洞的里的 8 支 + 产出那一支;另两支在 db/functions)
TABLE_FUNCS = [("db/tables/inbound_batches.sql", "generate_inbound_code"), ("db/tables/materials.sql", "generate_material_code"),
               ("db/tables/suppliers.sql", "generate_supplier_code"), ("db/tables/customers.sql", "generate_customer_code"),
               ("db/tables/contracts.sql", "assign_contract_code"), ("db/tables/stocktakes.sql", "generate_stocktake_code"),
               ("db/tables/processing_runs.sql", "generate_processing_code"), ("db/tables/tasks.sql", "generate_task_code"),
               ("db/tables/output_batches.sql", "generate_output_code")]
NEW_VIEWS = ["contamination_shift_status_all", "contamination_shift_status", "contamination_check_rows"]

STAFF_SIGS = ["public.set_batch_cell_construction(text, uuid, text)",
              "public.record_derived_electrolyte_loss(uuid, text)", "public.rederive_electrolyte_loss(bigint, text)",
              "public.record_contamination_check(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text)",
              "public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text)",
              "public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text, uuid, numeric, text, text)",
              "public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text, uuid, numeric, text, text)"]
INTERNAL_SIGS = ["public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text)"]
TRIGGER_SIGS = ["public.guard_batch_cell_construction()"]
OUTPUT_SEQS = ["cpw", "apw", "cuf", "alf", "sep", "dst", "cel", "csg", "str", "hbb", "cts", "ans"]


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


def table_func(path, name):
    """表镜像里那一支 CREATE OR REPLACE FUNCTION public.<name>() … $tag$;,原样。"""
    m = re.search(rf"CREATE OR REPLACE FUNCTION public\.{name}\(\)\n.*?\n\$(fn|function)\$;\n", mirror(path), re.S)
    assert m, (path, name)
    body = m.group(0)
    assert "LPAD(nextval" not in body and "lpad(nextval" not in body, (path, name, "still truncating")
    return "\n" + body


HEADER = """-- db/migrations/2026-10-07-mes4b-fields-and-products.sql
-- MES-4b —— 电芯结构、新的产出产品与编号、损耗的依据与电解液、交叉污染抽检(MES 组的第六刀,v1.4.42;发布那一行在 docs/handbacks/MES-4b.md 的抬头)。
-- 由 db/scripts/build_mes4b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-07:MES-4b Step 0 的 Q1–Q34 全部照建议裁定,Q9 与 Q17 两条按 Tim 改过的;docs/surveys/MES-4b/STEP0-HANDBACK.md)
--   ① 电芯结构(Q3–Q8):cell_constructions(wound · stacked · unknown;is_determined)· 两张批次表 + cell_construction_code
--      (进料批是遮蔽表:列 + 列级授权 + _masked 视图,一支迁移)· guard_batch_cell_construction(只对装电芯的形态成立;喂过一张已提交的
--      加工单之后锁住)· set_batch_cell_construction · 两支收货函数末尾一个可缺省的参数 · operation_types.requires_cell_construction
--      (引导 electrode_separation · electrode_line)· commit_processing_run 在这两道工序上要求投料带确定的结构,并让装电芯的产出继承它。
--   ② 产品与编号(Q9–Q15):六种新形态(正极粉 · 负极粉 · 铜箔 · 铝箔 · 收集的粉尘 · 线束/BMS/汇流排;可售性按 Tim 改过的 Q9)·
--      material_forms.output_document_key · document_types +12 行与 12 条序列 · generate_output_code 按形态取前缀(新前缀五位、有洞、不按年重置)·
--      11 支有洞的取号函数不再截断(超过 9,999 照实长出去;低于 10,000 的号逐字不变)· 工序 ↔ 形态的信息行 +7。
--   ③ 损耗的依据与电解液(Q16–Q20):processing_run_losses.basis(measured | derived,必填)+ derived_share_pct · loss_categories.may_be_derived ·
--      operation_types.electrolyte_share_pct(V10)与 electrolyte_loss_applies(「Electrolyte evaporates in this step」,引导全部为假)·
--      record_derived_electrolyte_loss · rederive_electrolyte_loss · record_run_loss / correct_run_loss 明写 measured · 平衡视图多一列算出来的那一截。
--   ④ 交叉污染(Q21–Q26):contamination_streams(正极 · 负极;警戒线 V11 引导为空)· contamination_checks(只追加)· 记 / 更正两支 + 一支内层 ·
--      contamination_shift_status(_all) · contamination_check_rows · 提醒臂 contamination_check_missing。
--   ⑤ 读者与登记(Q28–Q30):pending_values +2 支(V10 · V11)· operations_now +1 支 · 审计记录(加工单与产出批 + 抽检;两本字典)·
--      变更记录绑三张新表 · 例外表 +2 行 · check_mirrors 的 RUNTIME CONFIG 清单 +4 张。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据、批次或加工单;
--   不建任何物料;不给任何批次记结构;不勾任何工序的电解液挥发、不给份额、不给警戒线;require_calibrated_since 保持空;
--   不碰 MES-3a / 3b / 4a 的任何设定。只播:三种结构、两条流、六种形态(可售性按 Q9)、它们的映射、7 行工序 ↔ 形态、12 行单据种类与序列、
--   两道工序的 requires_cell_construction、电解液挥发那一类的 may_be_derived 与说明、例外表的两行;既有的损耗行记成 measured(线上 0 行)。
--
-- 【破窗】见 docs/surveys/MES-4b/STEP0-HANDBACK.md §10:部署之前,极片分离与自动极片线的一炉提交不了(线上没有一批记着结构,而旧应用
--   没有地方记它 —— 旧页面上是一句原样的码);新产出批在映射了的形态上铸新前缀;旧的搜索页把 12 个新单据种类的标签印成键。其余照旧。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的每一张加工单、每一批进料与产出(除了多出来的那一列,而它全是空的)、每一条损耗行逐字未变;变更记录只在引导的那几张表上动了、
--   恰好 43 行;新的数据表是空的;没有一道工序勾了电解液挥发、给了份额;没有一条流给了警戒线;开关是空的;anon 能执行的【恰好】两支;
--   内层谁都调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口;每一张被记录的表的绑定键都是它的主键;
--   提醒臂 57 支;待补的值 17 支;单据种类 55 行(有洞 23);每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in ["cell_constructions", "contamination_streams", "contamination_checks"]:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))

# ── 既有表镜像里那几行,与下面逐句写出的改动逐字同义 —— 先断言镜像真的是这个样子 ──────────────────────────────
DT = "db/tables/document_types.sql"
dt_rows = re.findall(r"^    \('output_[a-z_]+', '[A-Z]{3}', 'output_batches', 'gapped', 'output_[a-z]{3}_code_seq'.*?\)[,;]$", mirror(DT), re.M)
assert len(dt_rows) == 12, len(dt_rows)
dt_rows = [r.rstrip(",;") for r in dt_rows]
OB = "db/tables/output_batches.sql"
for q in OUTPUT_SEQS:
    must(OB, f"CREATE SEQUENCE public.output_{q}_code_seq;\n")
must(OB, "    cell_construction_code text\n                  REFERENCES public.cell_constructions (code)\n);")
ob_trg = must(OB, """CREATE TRIGGER trg_output_batches_cell_construction
    BEFORE INSERT OR UPDATE OF cell_construction_code, material_id ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_cell_construction();
""")
IB = "db/tables/inbound_batches.sql"
must(IB, "    cell_construction_code    text REFERENCES public.cell_constructions (code),\n")
ib_grant = re.search(r"GRANT SELECT \(id, code, material_id.*?\)\n    ON public\.inbound_batches TO authenticated;\n", mirror(IB), re.S).group(0)
assert "cell_construction_code)" in ib_grant
ib_trg = must(IB, """CREATE TRIGGER trg_inbound_batches_cell_construction
    BEFORE INSERT OR UPDATE OF cell_construction_code, material_id ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_cell_construction();""")
MF = "db/tables/material_forms.sql"
must(MF, "ALTER TABLE public.material_forms ADD COLUMN output_document_key text REFERENCES public.document_types (key);\n")
mf_rows = re.search(r"    \('cathode_powder',.*?'\);\n", mirror(MF), re.S).group(0)
assert mf_rows.count("\n    ('") == 5, mf_rows
mf_upd = re.findall(r"^UPDATE public\.material_forms SET output_document_key = .*;$", mirror(MF), re.M)
assert len(mf_upd) == 12, len(mf_upd)
OF = "db/tables/operation_type_output_forms.sql"
of_rows = [r.rstrip(",;") for r in re.findall(r"^    \('[a-z_]+', '(?:cathode_powder|anode_powder|copper_foil|aluminium_foil|collected_dust|harness_bms_busbar)', .*?\)[,;]$",
                                              mirror(OF), re.M)]
assert len(of_rows) == 7, of_rows
LC = "db/tables/loss_categories.sql"
must(LC, "    may_be_derived boolean NOT NULL DEFAULT false\n);")
lc_notes = re.search(r"'Electrolyte evaporation', '电解液挥发', 'unknown', true, 4,\n     ('.*?')\),\n", mirror(LC), re.S).group(1)
assert "抽风气流" in lc_notes
OT = "db/tables/operation_types.sql"
must(OT, "    electrolyte_share_pct       numeric CHECK (electrolyte_share_pct IS NULL OR (electrolyte_share_pct >= 0 AND electrolyte_share_pct <= 100)),\n"
         "    -- 「Electrolyte evaporates in this step」")
must(OT, "    electrolyte_loss_applies    boolean NOT NULL DEFAULT false,\n")
must(OT, "    requires_cell_construction  boolean NOT NULL DEFAULT false\n);")
ot_upd = must(OT, "UPDATE public.operation_types SET requires_cell_construction = true WHERE code IN ('electrode_separation', 'electrode_line');\n")
PL = "db/tables/processing_run_losses.sql"
must(PL, "    basis              text NOT NULL CHECK (basis IN ('measured', 'derived')),\n")
must(PL, "    derived_share_pct  numeric,\n    CONSTRAINT processing_run_losses_basis_shape\n        CHECK ((basis = 'derived') = (derived_share_pct IS NOT NULL)),\n")
DTE = "db/tables/document_type_exceptions.sql"
dte_rows = [re.search(rf"^    (\('{t}',.*?\))[,;]?$", mirror(DTE), re.M).group(1) for t in ("cell_constructions", "contamination_streams")]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES4B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.cell_constructions') IS NOT NULL OR to_regclass('public.contamination_streams') IS NOT NULL
       OR to_regclass('public.contamination_checks') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PRE|MES-4b tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name IN ('inbound_batches', 'output_batches') AND column_name = 'cell_construction_code')
                      OR (table_name = 'processing_run_losses' AND column_name IN ('basis', 'derived_share_pct'))
                      OR (table_name = 'loss_categories' AND column_name = 'may_be_derived')
                      OR (table_name = 'material_forms' AND column_name = 'output_document_key')
                      OR (table_name = 'operation_types' AND column_name IN ('electrolyte_share_pct', 'electrolyte_loss_applies', 'requires_cell_construction')))) THEN
        RAISE EXCEPTION 'MES4B_PRE|MES-4b columns already exist';
    END IF;
    IF (SELECT count(*) FROM material_forms) <> 13 OR (SELECT count(*) FROM document_types) <> 43
       OR (SELECT count(*) FROM loss_categories) <> 7 OR (SELECT count(*) FROM operation_types) <> 7 THEN
        RAISE EXCEPTION 'MES4B_PRE|dictionaries are not the MES-4a shape (forms 13, document types 43, loss categories 7, operations 7)';
    END IF;
    IF EXISTS (SELECT 1 FROM document_types WHERE prefix IN ('CPW', 'APW', 'CUF', 'ALF', 'SEP', 'DST', 'CEL', 'CSG', 'STR', 'HBB', 'CTS', 'ANS')) THEN
        RAISE EXCEPTION 'MES4B_PRE|a new output prefix is already registered';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4B_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4B_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 56 THEN
        RAISE EXCEPTION 'MES4B_PRE|operations_now should have 56 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 15 THEN
        RAISE EXCEPTION 'MES4B_PRE|pending_values should have 15 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes4b_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes4b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes4b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes4b_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes4b_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) AS runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) AS inputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) AS outputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_run_losses t) AS losses,
       (SELECT count(*) FROM processing_run_losses) AS loss_n,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM inbound_batches t) AS inbound,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM output_batches t) AS output,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM materials t) AS materials;
""")

parts.append("\n-- ── 1 · 先建的函数:两张批次表上要挂的触发器(镜像原样)──────────────────────────\n")
parts.append(fn("guard_batch_cell_construction"))

parts.append("\n-- ── 2 · 两本新字典(镜像原样,带它们的引导、策略与触发器)──────────────────────────\n")
for t in NEW_DICTS:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append("\n-- ── 3 · 产出批的编号(Q12–Q15):12 条序列 + 12 行单据种类(OUT 那一行留着)──────────────────────────\n")
for q in OUTPUT_SEQS:
    parts.append(f"CREATE SEQUENCE public.output_{q}_code_seq;\n")
parts.append("INSERT INTO public.document_types\n    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)\nVALUES\n"
             + ",\n".join(dt_rows) + ";\n")

parts.append("""
-- ── 4 · 物料形态(Q9 · Q12):产出号的映射列;六种新形态(可售性按 Tim 改过的 Q9);映射 ──────────────────────────
ALTER TABLE public.material_forms ADD COLUMN output_document_key text REFERENCES public.document_types (key);
""")
parts.append(comment_on(MF, "COLUMN public.material_forms.output_document_key"))
parts.append("INSERT INTO public.material_forms (code, name_en, name_zh, implies_dismantling, may_be_sold, sort_order, notes) VALUES\n" + mf_rows)
parts.append("\n".join(mf_upd) + "\n")
parts.append("""
-- ── 5 · 工序 ↔ 形态的信息行(Q10:不在提交时校验,选择器也不过滤)──────────────────────────
INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES
""" + ",\n".join(of_rows) + ";\n")

parts.append(f"""
-- ── 6 · 损耗类别(Q16 · Q17 · Q18):may_be_derived;电解液挥发那一类可以算出来,说明写上 Tim 的工厂事实 ──────────────────────────
ALTER TABLE public.loss_categories ADD COLUMN may_be_derived boolean NOT NULL DEFAULT false;
UPDATE public.loss_categories SET may_be_derived = true,
       notes = {lc_notes}
 WHERE code = 'electrolyte_evaporation';
""")
parts.append(comment_on(LC, "COLUMN public.loss_categories.may_be_derived"))

parts.append(f"""
-- ── 7 · 工序(Q5 · Q17):电解液份额(V10)· 「Electrolyte evaporates in this step」(引导全部为假)· 要求投料带结构 ──────────────────────────
ALTER TABLE public.operation_types
    ADD COLUMN electrolyte_share_pct numeric CHECK (electrolyte_share_pct IS NULL OR (electrolyte_share_pct >= 0 AND electrolyte_share_pct <= 100)),
    ADD COLUMN electrolyte_loss_applies boolean NOT NULL DEFAULT false,
    ADD COLUMN requires_cell_construction boolean NOT NULL DEFAULT false;
{ot_upd}""")
for c in ("electrolyte_share_pct", "electrolyte_loss_applies", "requires_cell_construction"):
    parts.append(comment_on(OT, f"COLUMN public.operation_types.{c}"))

parts.append(f"""
-- ── 8 · 进料批的电芯结构(Q4):一列 + 列级授权 + 遮蔽视图(三件事一起)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.inbound_batches ADD COLUMN cell_construction_code text REFERENCES public.cell_constructions (code);
{ib_grant}{ib_trg}
""")
parts.append(comment_on(IB, "COLUMN public.inbound_batches.cell_construction_code"))
parts.append(view("inbound_batches_masked", True))

parts.append(f"""
-- ── 9 · 产出批的电芯结构(Q4 · Q6;不是遮蔽表)+ 守卫触发器 ──────────────────────────
ALTER TABLE public.output_batches ADD COLUMN cell_construction_code text REFERENCES public.cell_constructions (code);
{ob_trg}""")
parts.append(comment_on(OB, "COLUMN public.output_batches.cell_construction_code"))

parts.append("""
-- ── 10 · 损耗的依据(Q16):必填、没有默认值 —— 既有行(线上 0 行)记成 measured,随后拿掉默认值,每一扇门明写自己是哪一种 ──────────────
ALTER TABLE public.processing_run_losses
    ADD COLUMN basis text NOT NULL DEFAULT 'measured' CHECK (basis IN ('measured', 'derived')),
    ADD COLUMN derived_share_pct numeric;
ALTER TABLE public.processing_run_losses ALTER COLUMN basis DROP DEFAULT;
ALTER TABLE public.processing_run_losses
    ADD CONSTRAINT processing_run_losses_basis_shape CHECK ((basis = 'derived') = (derived_share_pct IS NOT NULL));
""")
parts.append(comment_on(PL, "COLUMN public.processing_run_losses.basis"))

parts.append("\n-- ── 11 · 交叉污染抽检(镜像原样)──────────────────────────────────────────────────────\n")
parts.append("\n" + mirror("db/tables/contamination_checks.sql"))
parts.append(f"""
-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    {dte_rows[0]},
    {dte_rows[1]};
""")

parts.append("\n-- ── 12 · 取号函数(CODE-WIDTH-4,Q13 · Q14):不再截断;产出那一支按形态取前缀(表镜像里的那几支,原样)──────────────\n")
for path, name in TABLE_FUNCS:
    parts.append(table_func(path, name))

parts.append("\n-- ── 13 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 14 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 15 · 签名变了的两支:DROP 旧的、CREATE 新的(末尾一个可缺省的参数)────────────────────────\n")
for f, old in RESIGNED.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))

parts.append("\n-- ── 16 · 视图(镜像原样):平衡视图末尾加一列 · 交叉污染三张新的 · 待补的值与提醒 ──────────────────────\n")
for v in ["processing_run_balance_all", "processing_run_balance", "material_lookup"]:
    parts.append(view(v, True))
for v in NEW_VIEWS:
    parts.append(view(v, False))
for v in ["pending_values", "operations_now"]:
    parts.append(view(v, True))

parts.append("\n-- ── 17 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──────────────────────────\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 18 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS + TRIGGER_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes4b_pending_decider_check")
parts.append("\n-- ── 19 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES4B_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure) THEN
        RAISE EXCEPTION 'MES4B_PROOF|{sig} must be an internal function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
rel_list = ", ".join(f"'{r}'" for r in NEW_DICTS + ["contamination_checks"] + NEW_VIEWS)

parts.append(f"""
CREATE TEMP TABLE mes4b_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM mes4b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes4b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES4B_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes4b_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes4b_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES4B_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的加工单与它的腿逐字未变;批次与物料除了多出来的那一列(全空)逐字未变;损耗行全是 measured
    IF EXISTS ((SELECT b.k, b.id FROM mes4b_pending_before b EXCEPT SELECT a.k, a.id FROM mes4b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes4b_pending_after a EXCEPT SELECT b.k, b.id FROM mes4b_pending_before b)) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT runs FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_inputs t) IS DISTINCT FROM (SELECT inputs FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_outputs t) IS DISTINCT FROM (SELECT outputs FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM materials t) IS DISTINCT FROM (SELECT materials FROM mes4b_rows_before) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pre-existing run, leg or material changed';
    END IF;
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'cell_construction_code')::text, '|' ORDER BY t.id), '')) FROM inbound_batches t)
           IS DISTINCT FROM (SELECT inbound FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'cell_construction_code')::text, '|' ORDER BY t.id), '')) FROM output_batches t)
           IS DISTINCT FROM (SELECT output FROM mes4b_rows_before)
       OR EXISTS (SELECT 1 FROM inbound_batches WHERE cell_construction_code IS NOT NULL)
       OR EXISTS (SELECT 1 FROM output_batches WHERE cell_construction_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pre-existing batch changed, or a batch got a cell construction';
    END IF;
    IF (SELECT count(*) FROM processing_run_losses) <> (SELECT loss_n FROM mes4b_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'basis' - 'derived_share_pct')::text, '|' ORDER BY t.id), '')) FROM processing_run_losses t)
           IS DISTINCT FROM (SELECT losses FROM mes4b_rows_before)
       OR EXISTS (SELECT 1 FROM processing_run_losses WHERE basis <> 'measured' OR derived_share_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4B_PROOF|a pre-existing loss row changed, or is not marked measured';
    END IF;

    -- ④ 变更记录只在引导的那几张表上动了,恰好 43 行:单据种类 12 · 物料形态 6 + 13(映射)· 工序 ↔ 形态 7 · 损耗类别 1 · 工序 2 · 例外表 2。
    --   两本新字典与抽检表的引导在它们的绑定之前插入(第 2 段 → 第 17 段),所以不进变更记录。
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes4b_log_before)
       AND c.table_name NOT IN ('document_types', 'material_forms', 'operation_type_output_forms', 'loss_categories',
                                'operation_types', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4b_log_before)) <> 43 THEN
        RAISE EXCEPTION 'MES4B_PROOF|expected 43 change-log rows, got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes4b_log_before));
    END IF;

    -- ⑤ 引导恰好是引导;新的数据表是空的;一道工序都没勾电解液、没给份额;一条流都没给警戒线;开关空着
    IF (SELECT string_agg(code || ':' || is_determined::text, ',' ORDER BY sort_order) FROM cell_constructions)
           IS DISTINCT FROM 'wound:true,stacked:true,unknown:false'
       OR (SELECT string_agg(code || ':' || sheet_form_code || ':' || foreign_form_code, ',' ORDER BY sort_order) FROM contamination_streams)
           IS DISTINCT FROM 'cathode:cathode_sheet:anode_sheet,anode:anode_sheet:cathode_sheet'
       OR EXISTS (SELECT 1 FROM contamination_streams WHERE warning_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES4B_PROOF|the two new dictionaries are not exactly their bootstrap (or a warning level was set)';
    END IF;
    IF (SELECT string_agg(code || ':' || may_be_sold::text, ',' ORDER BY sort_order) FROM material_forms WHERE sort_order >= 14)
           IS DISTINCT FROM 'cathode_powder:true,anode_powder:true,copper_foil:true,aluminium_foil:true,collected_dust:false,harness_bms_busbar:true'
       OR EXISTS (SELECT 1 FROM material_forms WHERE code IN ('cathode_powder', 'anode_powder', 'copper_foil', 'aluminium_foil', 'collected_dust', 'harness_bms_busbar')
                    AND implies_dismantling)
       OR (SELECT count(*) FROM material_forms) <> 19
       OR (SELECT count(*) FROM material_forms WHERE output_document_key IS NOT NULL) <> 13 THEN
        RAISE EXCEPTION 'MES4B_PROOF|material forms are not the 19 expected with the Q9 saleability and 13 mapped';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 55 OR (SELECT count(*) FROM document_types WHERE numbering = 'gapped') <> 23
       OR (SELECT count(*) FROM document_types WHERE table_name = 'output_batches') <> 13
       OR NOT EXISTS (SELECT 1 FROM document_types WHERE key = 'output_batch' AND prefix = 'OUT') THEN
        RAISE EXCEPTION 'MES4B_PROOF|document types are not 55 (23 gapped, 13 on output_batches, OUT kept)';
    END IF;
    IF (SELECT count(*) FROM operation_type_output_forms) <> 21 THEN
        RAISE EXCEPTION 'MES4B_PROOF|expected 21 operation-output-form rows';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY code) FROM loss_categories WHERE may_be_derived) IS DISTINCT FROM 'electrolyte_evaporation' THEN
        RAISE EXCEPTION 'MES4B_PROOF|only electrolyte_evaporation may be derived';
    END IF;
    IF EXISTS (SELECT 1 FROM operation_types WHERE electrolyte_loss_applies OR electrolyte_share_pct IS NOT NULL)
       OR (SELECT string_agg(code, ',' ORDER BY code) FROM operation_types WHERE requires_cell_construction)
           IS DISTINCT FROM 'electrode_line,electrode_separation' THEN
        RAISE EXCEPTION 'MES4B_PROOF|an electrolyte flag or share was set, or the cell-construction operations are not the two';
    END IF;
    IF EXISTS (SELECT 1 FROM contamination_checks) THEN
        RAISE EXCEPTION 'MES4B_PROOF|contamination_checks is not empty';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到;旧签名不在了
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES4B_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|anon can read %', v_bad; END IF;
    IF to_regprocedure('{RESIGNED["create_inbound_batch"]}') IS NOT NULL
       OR to_regprocedure('{RESIGNED["receive_inbound_batch_against_po"]}') IS NOT NULL THEN
        RAISE EXCEPTION 'MES4B_PROOF|an old receipt-function signature survived';
    END IF;
    IF has_column_privilege('authenticated', 'public.inbound_batches'::regclass, 'cell_construction_code', 'SELECT') IS NOT TRUE THEN
        RAISE EXCEPTION 'MES4B_PROOF|inbound_batches.cell_construction_code is not readable by authenticated (the grant is missing)';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;抽检表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES4B_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'contamination_checks' AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES4B_PROOF|a write policy exists on contamination_checks';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表都记,豁免仍是 8);遮蔽零缺口(仍是 105 条);每一张被记录的表的绑定键都是它的主键
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES4B_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES4B_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
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
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES4B_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑨ 提醒臂 56 → 57;待补的值 15 → 17 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 57 THEN
        RAISE EXCEPTION 'MES4B_PROOF|operations_now should have 57 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 17 THEN
        RAISE EXCEPTION 'MES4B_PROOF|pending_values should have 17 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes4b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES4B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes4b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES4B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes4b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

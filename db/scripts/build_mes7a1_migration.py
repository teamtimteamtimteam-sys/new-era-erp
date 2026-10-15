#!/usr/bin/env python3
"""MES-7a-1(v1.4.52):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数与换掉的函数原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有三张设备表上的改动(停机多两列、三张表各拿掉 INSERT 与 UPDATE 两条策略、
各挂一支"只经函数"的守卫、停机多一支原因守卫、三句表/列注释更正)在这里逐句写出,并先断言镜像里那几行真的是这个样子。
照抄 build_mes6b2_migration.py 的形状。跑法:python3 db/scripts/build_mes7a1_migration.py(在仓库根目录)。
应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-15-mes7a1-equipment-reliability.sql"

NEW_TABLES = ["downtime_causes"]
# 先于新表与新列:新表的触发器函数、停机的两支守卫(plpgsql 的体建的时候不解析表名)
NEW_FUNCS_EARLY = ["guard_downtime_cause_class", "guard_downtime_cause", "guard_equipment_direct_write"]
# 新表与新列之后
NEW_FUNCS_LATE = ["equipment_record_target", "downtime_cause_check", "open_equipment_downtime", "close_equipment_downtime",
                  "correct_equipment_downtime", "record_equipment_maintenance", "save_equipment_service_interval",
                  "equipment_reliability", "coa_issuer"]
# 同签名换掉:签发分析证书改调 coa_issuer · 签发销毁证书多返回 snapshot · 审计主语多一本字典 · 一句过时的注释(提交加工单)
REPLACED_FUNCS = ["issue_coa", "issue_cod", "trail_subjects", "commit_processing_run"]

PUBLIC_SIGS = ["public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text)",
               "public.close_equipment_downtime(uuid, timestamp with time zone)",
               "public.correct_equipment_downtime(uuid, timestamp with time zone, timestamp with time zone, text, text)",
               "public.record_equipment_maintenance(uuid, date, text, text, uuid, uuid, text, uuid, uuid, boolean, text, text)",
               "public.save_equipment_service_interval(uuid, uuid, text, numeric, numeric, integer, integer, text, text)",
               "public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone)",
               "public.coa_issuer()"]
INTERNAL_SIGS = ["public.guard_downtime_cause()", "public.guard_downtime_cause_class()", "public.guard_equipment_direct_write()",
                 "public.equipment_record_target(uuid)", "public.downtime_cause_check(text)"]

# 前后比对的表(既有的行逐字未变)。停机减掉两列新列(新列在旧行上是 NULL 与 'manual' —— 比对它们之前的样子)
DIGEST_TABLES = {
    "equipment_downtime": ["cause_code", "source"], "equipment_maintenance": [], "equipment_service_intervals": [],
    "fixed_assets": [], "fixed_asset_cost_entries": [], "shift_handover_equipment_refs": [], "operation_type_equipment": [],
    "processing_runs": [], "processing_run_events": [], "certificates_of_destruction": [], "cod_issues": [],
    "certificates_of_analysis": [], "coa_issues": [], "warehouse_requests": [], "employees": [], "positions": [],
    "company_profile": [], "inbound_batches": [], "output_batches": [], "expenses": [], "approval_log": [],
    "journal_entries": [], "journal_lines": [], "payments": [], "inventory_movements": [], "maintenance_settings": [],
}


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


def digest(t, minus):
    j = "to_jsonb(t)" + "".join(f" - '{c}'" for c in minus)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t)"


def comment_stmt(path, head):
    """一句 COMMENT ... IS '…'; —— 字面量里的 '' 是转义,不是结尾。"""
    m = re.search(re.escape(head) + r"\s*'(?:[^']|'')*';\n", mirror(path))
    assert m, (path, head)
    return m.group(0)


def trigger_stmt(path, name):
    m = re.search(r"CREATE TRIGGER " + re.escape(name) + r"\n.*?;\n", mirror(path), re.S)
    assert m, (path, name)
    return m.group(0)


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
DT = "db/tables/equipment_downtime.sql"
DT_CAUSE = must(DT, "    cause_code   text REFERENCES public.downtime_causes (code),\n")
DT_SOURCE = must(DT, "    source       text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'device'))\n")
DT_COMMENT = comment_stmt(DT, "COMMENT ON TABLE public.equipment_downtime IS")
assert "MES-7a-1(2026-10-15)" in DT_COMMENT
DT_COMMENT_CAUSE = comment_stmt(DT, "COMMENT ON COLUMN public.equipment_downtime.cause_code IS")
DT_COMMENT_SOURCE = comment_stmt(DT, "COMMENT ON COLUMN public.equipment_downtime.source IS")
DT_TRG_CAUSE = trigger_stmt(DT, "trg_equipment_downtime_cause")
DT_TRG_DIRECT = trigger_stmt(DT, "trg_equipment_downtime_direct")
assert 'equipment_downtime insert by permission' not in mirror(DT) and 'equipment_downtime update by permission' not in mirror(DT)

EM = "db/tables/equipment_maintenance.sql"
EM_COMMENT = comment_stmt(EM, "COMMENT ON TABLE public.equipment_maintenance IS")
assert "MES-7a-1 起它才是真的" in EM_COMMENT
EM_TRG_DIRECT = trigger_stmt(EM, "trg_equipment_maintenance_direct")
assert 'equipment_maintenance insert by permission' not in mirror(EM) and 'equipment_maintenance update by permission' not in mirror(EM)

ESI = "db/tables/equipment_service_intervals.sql"
ESI_COMMENT_KG = comment_stmt(ESI, "COMMENT ON COLUMN public.equipment_service_intervals.interval_kg IS")
assert "MES-7a-1 更正" in ESI_COMMENT_KG
ESI_TRG_DIRECT = trigger_stmt(ESI, "trg_equipment_service_intervals_direct")
assert 'equipment_service_intervals insert by permission' not in mirror(ESI)
assert 'equipment_service_intervals delete by permission' in mirror(ESI)

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))
grants = mirror("db/views/zzz_function_grants.sql")
for sig in INTERNAL_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" in grants, sig
for sig in PUBLIC_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" not in grants, sig
EXC_ROW = must("db/tables/document_type_exceptions.sql",
               "    ('downtime_causes',               '停机原因目录(MES-7a-1):code 是原因代号(类别 failure · planned · external),停机记录引用它'),\n")
assert "downtime_causes" in mirror("db/check_mirrors.py")
assert "'dictionary_downtime_causes'" in mirror("db/functions/trail_subjects.sql")
assert "v_issuer := coa_issuer();" in mirror("db/functions/issue_coa.sql")
assert "'snapshot', v_data);" in mirror("db/functions/issue_cod.sql")

HEADER = """-- db/migrations/2026-10-15-mes7a1-equipment-reliability.sql
-- MES-7a-1 —— 设备可靠性:停机原因与来源、设备记录只经函数、MTBF / MTTR;分析证书签发人先过字体(F9);销毁证书从快照渲染(F10)
--   (MES 组的第十六刀,v1.4.52;发布那一行在 docs/handbacks/MES-7a-1.md 的抬头)。由 db/scripts/build_mes7a1_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-15:MES-7a Step 0 的 Q1 拆两刀,本刀是前一半;Q3–Q9 · Q18–Q22 · Q24–Q26 照推荐裁定;Q6:记设备的码仍是
--   module.processing.edit,不加仓库)
--   ① downtime_causes(停机原因字典,类别 failure · planned · external,没有 other;引导每一类一行:breakdown · planned_maintenance ·
--      external;被引用之后类别冻住)。equipment_downtime 多两列:cause_code(→ 字典;插入时必填 —— 本刀之前那一行留空,读作"未分类")
--      与 source(manual · device;device 保留,今天每一行都是 manual)。reason 照旧是自由文本的说明。
--   ② 五支函数取代直连写(Q6):open_ · close_ · correct_equipment_downtime · record_equipment_maintenance(可以点名同一台机器、没有作废的
--      一段停机)· save_equipment_service_interval —— 按名拒,不再是约束名。三张表的 INSERT 与 UPDATE 策略拿掉;直连写由
--      guard_equipment_direct_write 按名拒(EQUIPMENT_THROUGH_FUNCTION_ONLY);作废照旧 void_equipment_downtime;停机照旧删不掉;
--      间隔的 DELETE 策略留着(删一条 = 回到「未监控」)。
--   ③ equipment_reliability(Q5):运转小时 = 已提交未冲销的加工单 [开始, 结束) 的并集;一次故障 = 未作废、原因属于 failure 类、开始落在
--      区间里的停机;MTBF = 小时 ÷ 次数,MTTR = 已关上的故障的平均时长;零次故障 / 零小时不给数,给一个状态;区间默认整段记录。
--   ④ F9(Q8):coa_issuer() —— 签发人的唯一一份解析,issue_coa 改调它(同样的拒绝、同样的次序);路由在铸号之前用它过字体。
--   ⑤ F10(Q9):issue_cod 的返回值多一个 snapshot(与写进证书的同一份);路由照它渲染,不再回读。
--   ⑥ 审计:字典段 dictionary_downtime_causes(与别的字典同一个形状;停机的原因与来源在 equipment 主语下说 —— 没有新的记录主语);
--      downtime_causes 进变更记录(豁免仍是 8;没有遮蔽的列)。过时的注释就地更正(停机表注 · 保养表注 · 间隔的公斤列注 · 提交加工单)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权一行不动;不写、不改任何一段既有的停机、保养、间隔、资产、加工单、证书、
--   字节档案;不建任何停机、保养、间隔、关联、分析证书或销毁证书;不往任何桶里放对象;不回填(Q94)—— 线上那一段 "Test-1" 停机的原因
--   留空、仍然开着;require_calibrated_since 保持空。线上由本迁移造出的只有:原因字典与它的三行引导、单据例外一行(downtime_causes)、停机的两列(旧行 NULL 与 'manual')。
--
-- 【破窗】(Q21,照推荐接受并写明)旧应用的 /finance/assets/[id] 直连写三张设备表 —— 策略拿掉、原因必填之后,**从旧应用记停机、
--   保养与间隔会失败,直到部署**(旧应用读到的是 EQUIPMENT_THROUGH_FUNCTION_ONLY 那一句)。线上用这条路的只有八月的三行测试数据。
--   分析证书的签发:签名与拒绝不变。销毁证书:issue_cod 多一个返回键,旧路由不读它。代码先行、迁移最后,窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动,admin 持目录里每一个码(79);在途单据一张不少、一张不多,
--   每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的停机(减掉两列新列)、保养、间隔、资产、加工单、证书、字节档案、
--   申请、员工、职位、公司资料、批次、费用、审批留痕、分录、付款、流水逐字未变;旧的停机每一行原因为空、来源 manual;字典恰好三行引导;
--   三张设备表上没有 INSERT / UPDATE 策略、守卫都在;本事务往变更记录只写了单据例外那一行(字典的引导在绑定之前种下);七支对外的函数员工调得到、
--   五支内层与触发器调不到;anon 能执行的【恰好】两支;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);
--   单据登记 59 行、例外 46 行;提醒 66 支、待定值 23 行;298 张表。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES7A1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.downtime_causes') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'equipment_downtime'
                    AND column_name IN ('cause_code', 'source'))
       OR to_regprocedure('public.coa_issuer()') IS NOT NULL
       OR to_regprocedure('public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone)') IS NOT NULL
       OR to_regprocedure('public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PRE|MES-7a-1 objects already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
          AND tablename IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals')
          AND cmd IN ('INSERT', 'UPDATE')) <> 6 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected the six direct INSERT / UPDATE policies on the equipment tables';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected a catalogue of 79 codes, all held by admin';
    END IF;
    IF (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.issue_coa') IS DISTINCT FROM 'admin,cco' THEN
        RAISE EXCEPTION 'MES7A1_PRE|action.issue_coa is expected to be held by admin and cco';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 59 OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 59 document types and 45 exceptions';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66 THEN
        RAISE EXCEPTION 'MES7A1_PRE|operations_now should have 66 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES7A1_PRE|pending_values should have 23 arms';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 297 THEN
        RAISE EXCEPTION 'MES7A1_PRE|expected 297 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, m)} AS {t}" for t, m in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes7a1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes7a1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes7a1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes7a1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes7a1_downtime_ids_before ON COMMIT DROP AS
SELECT id FROM equipment_downtime;
CREATE TEMP TABLE mes7a1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新函数(镜像原样),先于新表与新列:原因类别冻住 · 停机的原因与来源 · 设备表只经函数(三支触发器函数)─────\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append("\n-- ── 2 · 新表(镜像原样):停机原因字典与它的三行引导 ─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))
parts.append(f"""
-- 它带 code 列而不是一张单据:登记进 document_type_exceptions(与 db/tables/document_type_exceptions.sql 那一行逐字同一份;fixture 102)
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
{EXC_ROW.rstrip().rstrip(',')};
""")

parts.append(f"""
-- ── 3 · 三张设备表(与 db/tables/equipment_*.sql 逐字同一份的列、注释、触发器)──────────────────────────────
--   停机的两列加在末尾(镜像照"后加的列在最后"排);旧行:cause_code 为空("未分类"),source 取默认 'manual'(列默认值,不经触发器 ——
--   这不是回填,是新列在旧行上的值)。三张表各拿掉 INSERT 与 UPDATE 两条策略(Q6);间隔的 DELETE 策略留着。
ALTER TABLE public.equipment_downtime ADD COLUMN
{DT_CAUSE.rstrip().rstrip(',')};
ALTER TABLE public.equipment_downtime ADD COLUMN
{DT_SOURCE.rstrip().rstrip(',')};
{DT_COMMENT}{DT_COMMENT_CAUSE}{DT_COMMENT_SOURCE}DROP POLICY "equipment_downtime insert by permission" ON public.equipment_downtime;
DROP POLICY "equipment_downtime update by permission" ON public.equipment_downtime;
{DT_TRG_CAUSE}{DT_TRG_DIRECT}
{EM_COMMENT}DROP POLICY "equipment_maintenance insert by permission" ON public.equipment_maintenance;
DROP POLICY "equipment_maintenance update by permission" ON public.equipment_maintenance;
{EM_TRG_DIRECT}
{ESI_COMMENT_KG}DROP POLICY "equipment_service_intervals insert by permission" ON public.equipment_service_intervals;
DROP POLICY "equipment_service_intervals update by permission" ON public.equipment_service_intervals;
{ESI_TRG_DIRECT}""")

parts.append("\n-- ── 4 · 新函数(镜像原样),新表与新列之后:两句共用判据 · 五支记录函数 · 可靠性 · 签发人 ─────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 5 · 换掉的函数(镜像原样,同签名):签发分析证书改调 coa_issuer · 签发销毁证书多返回 snapshot · 审计主语多一本字典 · 提交加工单的一句注释 ─\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 6 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份;字典的引导在这之前种下,所以不进变更记录)──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 7 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in PUBLIC_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO service_role;\n")
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes7a1_pending_decider_check")
parts.append("\n-- ── 8 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

public_checks = "\n".join(
    f"""    IF NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|{sig} must be callable by staff and not by anon';
    END IF;""" for sig in PUBLIC_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(f"{digest(t, m)} IS DISTINCT FROM (SELECT {t} FROM mes7a1_rows_before)" for t, m in DIGEST_TABLES.items())
TRIGGERS = [("equipment_downtime", "trg_equipment_downtime_cause"), ("equipment_downtime", "trg_equipment_downtime_direct"),
            ("equipment_downtime", "trg_equipment_downtime_period"), ("equipment_downtime", "trg_equipment_downtime_write"),
            ("equipment_downtime", "trg_equipment_downtime_no_delete"),
            ("equipment_maintenance", "trg_equipment_maintenance_direct"),
            ("equipment_service_intervals", "trg_equipment_service_intervals_direct"),
            ("downtime_causes", "trg_downtime_causes_class")]
for t, g in TRIGGERS:
    assert g in mirror(f"db/tables/{t}.sql"), (t, g)
trigger_checks = "\n       OR ".join(
    f"NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '{g}' AND tgrelid = 'public.{t}'::regclass)" for t, g in TRIGGERS)

parts.append(f"""
CREATE TEMP TABLE mes7a1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行没动;admin 持目录里每一个码(79);action.issue_coa 仍是 admin 与 cco
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes7a1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes7a1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a grant changed: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|admin does not hold every one of the 79 codes';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES7A1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes7a1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes7a1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(停机比对时减掉两列新列);旧停机原因为空、来源 manual;没有新停机
    IF EXISTS ((SELECT b.k, b.id FROM mes7a1_pending_before b EXCEPT SELECT a.k, a.id FROM mes7a1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes7a1_pending_after a EXCEPT SELECT b.k, b.id FROM mes7a1_pending_before b)) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a pre-existing downtime, maintenance, interval, asset, run, certificate, byte record, request, employee, position, company, batch, expense, approval, journal, payment or movement changed';
    END IF;
    IF EXISTS (SELECT 1 FROM equipment_downtime WHERE cause_code IS NOT NULL OR source <> 'manual')
       OR EXISTS (SELECT id FROM equipment_downtime EXCEPT SELECT id FROM mes7a1_downtime_ids_before) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|existing downtime must stay unclassified and manual, and none may be added';
    END IF;

    -- ④ 字典恰好三行引导,每一类一行
    IF (SELECT string_agg(code || ':' || class, ',' ORDER BY code) FROM downtime_causes)
         IS DISTINCT FROM 'breakdown:failure,external:external,planned_maintenance:planned' THEN
        RAISE EXCEPTION 'MES7A1_PROOF|downtime_causes must hold exactly the three seeded causes';
    END IF;

    -- ⑤ 三张设备表上没有 INSERT / UPDATE 策略;读策略在;间隔的 DELETE 策略在;守卫都在
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals')
                 AND cmd IN ('INSERT', 'UPDATE', 'ALL')) THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a direct write policy remains on an equipment table';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
          AND tablename IN ('equipment_downtime', 'equipment_maintenance', 'equipment_service_intervals') AND cmd = 'SELECT') <> 3
       OR NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'equipment_service_intervals' AND cmd = 'DELETE') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|the read policies and the interval delete policy must remain';
    END IF;
    IF {trigger_checks} THEN
        RAISE EXCEPTION 'MES7A1_PROOF|a guard trigger is missing';
    END IF;

    -- ⑥ 本事务没有往变更记录写一行(按 txid 认 —— 同一时刻同事们在线上的写不算在本刀头上);require_calibrated_since 仍空
    SELECT string_agg(c.table_name || ':' || c.op, ', ' ORDER BY c.seq) INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes7a1_log_before), 0) AND c.txid = txid_current();
    IF v_bad IS DISTINCT FROM 'document_type_exceptions:INSERT' THEN
        RAISE EXCEPTION 'MES7A1_PROOF|change_log rows of this transaction: % (expected only the one exception row)', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:单据登记 59 行、例外 46 行;提醒 66 支、待定值 23 行;298 张表;字典段在册;销毁证书一张没动
    IF (SELECT count(*) FROM document_types) <> 59 OR (SELECT count(*) FROM document_type_exceptions) <> 46
       OR NOT EXISTS (SELECT 1 FROM document_type_exceptions WHERE table_name = 'downtime_causes') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|document_types should stay 59 and exceptions be 46 with downtime_causes';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|operations_now should have 66 arms and pending_values 23';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 298 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|expected 298 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'dictionary_downtime_causes') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|trail subject dictionary_downtime_causes is not registered';
    END IF;

    -- ⑧ 函数面:七支员工调得到;五支内层与触发器调不到;anon 能执行的【恰好】两支;新表 anon 读不到
{public_checks}
{internal_checks}
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES7A1_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.downtime_causes'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES7A1_PROOF|anon reads downtime_causes';
    END IF;

    -- ⑨ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(字典记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑪ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes7a1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES7A1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes7a1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES7A1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes7a1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

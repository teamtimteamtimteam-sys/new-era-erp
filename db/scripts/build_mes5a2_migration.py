#!/usr/bin/env python3
"""MES-5a-2(v1.4.44):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有对象的改动(一个科目升成引擎科目、换函数体、换视图)在这里逐句写出或原样抽出,
并先断言镜像里那几行真的是这个样子。照抄 build_mes5a1_migration.py 的形状。
跑法:python3 db/scripts/build_mes5a2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-08-mes5a2-energy.sql"

NEW_TABLES = ["meter_readings", "electricity_settings", "electricity_allocations", "electricity_allocation_lines"]
NEW_VIEWS = ["meter_readings_current", "electricity_allocations_masked", "electricity_allocation_lines_masked", "processing_run_energy"]
NEW_FUNCS = ["meter_reading_internal", "record_meter_reading", "correct_meter_reading", "electricity_allocation_compute",
             "preview_electricity_allocation", "post_electricity_allocation", "set_electricity_shared_pool_rule"]
REPLACED_FUNCS = ["reverse_expense", "trail_subjects", "trail_subject_members", "change_log_mask_rules"]
REPLACED_VIEWS = ["pending_values", "processing_cost_variance"]

STAFF_SIGS = ["public.record_meter_reading(uuid, timestamp with time zone, numeric, boolean, text, text)",
              "public.correct_meter_reading(bigint, text, timestamp with time zone, numeric, boolean, text, boolean, text)",
              "public.preview_electricity_allocation(date, date, numeric, numeric, text, text, text)",
              "public.post_electricity_allocation(date, date, date, text, numeric, numeric, text, text, text, uuid, text, text)",
              "public.set_electricity_shared_pool_rule(text)"]
INTERNAL_SIGS = ["public.meter_reading_internal(uuid, timestamp with time zone, numeric, boolean, text, text, boolean, bigint, text)",
                 "public.electricity_allocation_compute(date, date, numeric, numeric, text, text, text)"]


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


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


HEADER = """-- db/migrations/2026-10-08-mes5a2-energy.sql
-- MES-5a-2 —— 电表与读数、一炉分到的电、一张电费单只过一次账(MES 组的第八刀,v1.4.44;发布那一行在 docs/handbacks/MES-5a-2.md 的抬头)。
-- 由 db/scripts/build_mes5a2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-08:MES-5a Step 0 的能源那一半 —— Q19–Q28 · Q35 与 Q1 · Q29–Q34 · Q36 的能源部分 —— 全部照建议裁定,
--   Q22 与 Q24 是他自己定的;docs/surveys/MES-5a/STEP0-HANDBACK.md)
--   ① 电表(Q19):一台 kind = meter 的设备,它的机器 = devices.equipment_id,空 = 共用池 —— 设备页上已有的那一格(save_device,
--      action.manage_devices),本刀不加列。
--   ② 读数(Q20):meter_readings(累计寄存器,只追加;比前一条小拒,除非标成寄存器清零并写理由;更正 / 撤回是新行)·
--      record / correct_meter_reading(action.confirm_capture)· meter_readings_current。设备转换器【没有建】(没有电表给过格式 ——
--      MES-3b Q25 · MES-4a Q14);读数行的来源 / 收件箱 / 草稿 / 现场数据那几列已经在。
--   ③ 一炉的电(Q21 · Q22 · Q23):processing_run_energy(自己记的 energy_kwh 优先;没记才用分到的;每吨 ÷ 投入;放电回收另列)。
--   ④ 电费单(Q24 · Q25 · Q26 · Q27 · Q28):electricity_allocations + electricity_allocation_lines(金额遮蔽:列 + 列级授权 + _masked 视图 +
--      遮蔽规则,一支迁移)· electricity_allocation_compute(规则只住在这里)· preview / post_electricity_allocation · electricity_settings(V25)·
--      set_electricity_shared_pool_rule · 科目 6200 升成引擎科目(分摊的余数按 code 借进它)· reverse_expense 不许单独冲一次分摊的费用单 ·
--      processing_cost_variance 不再把分摊冲掉的估计拿去比整张账单。
--   ⑤ 读者与登记(Q29–Q32):pending_values +1 支(V25)· 审计记录(电表上的读数 · 一张单与它的行 · 一炉上分到的那一行 · V25)·
--      变更记录绑四张新表 · 遮蔽规则 +6 行。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据、加工单、成本行、
--   费用单、分录或设备;不把任何设备变成电表、不挂任何机器;不记任何读数、分摊或账单;V25 保持空;require_calibrated_since 保持空。
--   只播:electricity_settings 的那一行(规则为空)与 6200 的 is_system。
--
-- 【破窗】见 docs/surveys/MES-5a/STEP0-HANDBACK.md §8:只有新表、新函数、新视图;旧应用调的东西一个都没有改签名或改行为
--   (reverse_expense 只多拒一种它今天碰不到的单 —— 线上没有一次分摊)。窗口里旧页面看不到电表读数与分摊,其余照旧。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的加工单、成本行、费用单、分录、设备逐字未变;变更记录只在 accounts 上动了、恰好 1 行(6200 的标记);新的数据表是空的、
--   设定那一行的规则是空的;一台电表都没有;anon 能执行的【恰好】两支;内层谁都调不到;那 44 条开着的读策略还是 44 条;
--   变更记录覆盖与遮蔽零缺口(豁免仍是 8、规则 111 条);提醒臂 59 支不变;待补的值 19 支;每一张在途单据仍有一个不是它当事人的决定人。
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

# 6200 在镜像里已经是引擎科目那一组里的一行(名字与线上逐字相同)
must("db/tables/accounts.sql", "    ('6200', 'Utilities', '水电杂费', 'expense', true, false);")
# 两张遮蔽表的列级授权与 _masked 视图都在镜像里(三件事一支迁移)—— 下面原样抽出
for t in ("electricity_allocations", "electricity_allocation_lines"):
    must(f"db/tables/{t}.sql", f"REVOKE SELECT ON public.{t} FROM authenticated, anon;")
    assert (ROOT / f"db/views/{t}_masked.sql").exists(), t

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5A2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.meter_readings') IS NOT NULL OR to_regclass('public.electricity_allocations') IS NOT NULL
       OR to_regclass('public.electricity_allocation_lines') IS NOT NULL OR to_regclass('public.electricity_settings') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A2_PRE|MES-5a-2 tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM devices WHERE kind = 'meter') THEN
        RAISE EXCEPTION 'MES5A2_PRE|a meter already exists (none expected)';
    END IF;
    IF (SELECT is_system FROM accounts WHERE code = '6200') IS DISTINCT FROM false
       OR (SELECT count(*) FROM accounts WHERE is_system) <> 35 THEN
        RAISE EXCEPTION 'MES5A2_PRE|expected 6200 present and not yet a system account, 35 system accounts';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5A2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES5A2_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5A2_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 18 THEN
        RAISE EXCEPTION 'MES5A2_PRE|pending_values should have 18 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A2_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT transform_function FROM ingest_data_classes WHERE code = 'meter_reading') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A2_PRE|the meter_reading class already has a transform';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5a2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes5a2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5a2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5a2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5a2_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) AS runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_cost_entries t) AS costs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_run_values t) AS run_values,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM journal_entries t) AS journals,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM devices t) AS devices,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM payments t) AS payments;
""")

parts.append("""
-- ── 1 · 科目 6200 升成引擎科目:分摊的余数(不计量 / 共用池 / 有表无单的电)按 code 借进它(Q24 · Q25)──────────────
--   名字、类型、货币性逐字不动;只打 is_system(guard_system_account 只拦摘标记,不拦打标记)。
UPDATE public.accounts SET is_system = true WHERE code = '6200';
""")

parts.append("\n-- ── 2 · 四张新表(镜像原样:读数 · 设定(V25)· 一张电费单 · 分给一炉的那一份)──────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append("\n-- ── 3 · 四张新视图(镜像原样:当前读数 · 两张遮蔽伴生 · 一炉的电)──────────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v, False))
parts.append("\n-- ── 4 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 5 · 改过的函数(镜像原样,同签名):reverse_expense 的一道拒 · 审计记录的两张登记表 · 遮蔽规则 +6 ──────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 6 · 改过的视图(镜像原样):待补的值 +V25 · 估算与实际的偏差不再算分摊冲掉的估计 ──────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, True))

parts.append("\n-- ── 7 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)——绑在设定那一行播下【之后】,所以那一行不进记录 ──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 8 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes5a2_pending_decider_check")
parts.append("\n-- ── 9 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A2_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5A2_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)

parts.append(f"""
CREATE TEMP TABLE mes5a2_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5a2_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes5a2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A2_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5A2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5a2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5a2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5A2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的加工单、成本行、值、费用单、分录、设备、付款逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes5a2_pending_before b EXCEPT SELECT a.k, a.id FROM mes5a2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5a2_pending_after a EXCEPT SELECT b.k, b.id FROM mes5a2_pending_before b)) THEN
        RAISE EXCEPTION 'MES5A2_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT runs FROM mes5a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_cost_entries t) IS DISTINCT FROM (SELECT costs FROM mes5a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM processing_run_values t) IS DISTINCT FROM (SELECT run_values FROM mes5a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes5a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journals FROM mes5a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes5a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM devices t) IS DISTINCT FROM (SELECT devices FROM mes5a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY t.id), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes5a2_rows_before) THEN
        RAISE EXCEPTION 'MES5A2_PROOF|a pre-existing run, cost line, run value, expense, journal, device or payment changed';
    END IF;

    -- ④ 变更记录只在 accounts 上动了,恰好 1 行(6200 打上 is_system);四张新表的绑定在建表与播种之后,它们都没有进记录
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes5a2_log_before), 0) AND c.table_name <> 'accounts';
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A2_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5a2_log_before), 0)) <> 1 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|expected 1 change-log row, got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5a2_log_before), 0));
    END IF;
    IF NOT (SELECT is_system FROM accounts WHERE code = '6200') OR (SELECT count(*) FROM accounts WHERE is_system) <> 36 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|6200 should now be a system account (36 in all)';
    END IF;

    -- ⑤ 新的数据表是空的;设定那一行在、规则是空的;一台电表都没有;设备转换器没有建
    IF EXISTS (SELECT 1 FROM meter_readings) OR EXISTS (SELECT 1 FROM electricity_allocations) OR EXISTS (SELECT 1 FROM electricity_allocation_lines) THEN
        RAISE EXCEPTION 'MES5A2_PROOF|a new data table is not empty';
    END IF;
    IF (SELECT count(*) FROM electricity_settings) <> 1 OR (SELECT shared_pool_rule FROM electricity_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A2_PROOF|electricity_settings should be one row with no rule (V25 not set)';
    END IF;
    IF EXISTS (SELECT 1 FROM devices WHERE kind = 'meter') THEN
        RAISE EXCEPTION 'MES5A2_PROOF|a meter exists (none may be set by this cut)';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A2_PROOF|require_calibrated_since was set';
    END IF;
    IF (SELECT transform_function FROM ingest_data_classes WHERE code = 'meter_reading') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5A2_PROOF|a meter_reading transform appeared';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5A2_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A2_PROOF|anon can read %', v_bad; END IF;
    -- 金额不在列级授权里,kWh 在
    IF has_column_privilege('authenticated', 'public.electricity_allocations'::regclass, 'bill_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_lines'::regclass, 'amount', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.electricity_allocations'::regclass, 'bill_kwh', 'SELECT') THEN
        RAISE EXCEPTION 'MES5A2_PROOF|the allocation amounts must be out of the column grant and the kWh in it';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;四张新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ({", ".join(f"'{t}'" for t in NEW_TABLES)}) AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES5A2_PROOF|a write policy exists on a new energy table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(四张新表都记,豁免仍是 8);遮蔽零缺口(105 → 111 条);每一张被记录的表的绑定键都是它的主键
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 111 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
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
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5A2_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑨ 提醒臂 59 不变;待补的值 18 → 19 支;V25 今天零行(一台电表都没有)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|operations_now should still have 59 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 19 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|pending_values should have 19 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5a2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5A2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5a2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5A2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5a2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

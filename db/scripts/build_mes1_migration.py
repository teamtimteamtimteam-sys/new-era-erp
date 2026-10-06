#!/usr/bin/env python3
"""MES-1(v1.4.37):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。种子行(权限码、单据种类、例外表)与授权在这里逐句写出,并与镜像里那几行逐字同义
(check_mirrors 在重建侧对照)。
跑法:python3 db/scripts/build_mes1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-06-mes1-entry-point.sql"

# 表的触发器要先有它们的函数(其余函数在表之后建 —— plpgsql 的校验会解析 %ROWTYPE,表要先在)
TRIGGER_FUNCS = ["generate_device_code", "guard_devices_write", "guard_gateway_keys_write",
                 "guard_ingest_transmissions_write", "guard_ingest_inbox_write", "guard_gateway_outages_append_only"]
TABLES = ["ingest_data_classes", "devices", "gateway_keys", "ingest_settings", "ingest_transmissions", "ingest_inbox",
          "gateway_outages"]
NEW_FUNCS = ["transform_connection_test_v1", "ingest_transform_row", "ingest_submit", "issue_gateway_key", "revoke_gateway_key",
             "save_device", "retire_device", "set_ingest_settings", "ingest_process_pending", "retry_inbox_row", "discard_inbox_row"]
REPLACED_FUNCS = ["change_log_exclusions", "change_log_mask_rules", "change_log_rule_visible", "trail_subjects",
                  "trail_subject_members"]
NEW_VIEWS = ["gateway_keys_masked", "gateway_health", "ingest_sequence_gaps", "ingest_transmission_anomalies", "pending_values"]
REPLACED_VIEWS = ["operations_now"]
LOGGED = {"devices": "id", "gateway_keys": "id", "ingest_settings": "id", "ingest_data_classes": "code"}

# 员工那几支:与 zzz_function_grants.sql 同一套话 —— 先从 PUBLIC/anon 收回,再授 authenticated 与 service_role
STAFF_SIGS = ["public.issue_gateway_key(uuid)", "public.revoke_gateway_key(uuid, text)", "public.save_device(jsonb, uuid)",
              "public.retire_device(uuid, text)", "public.set_ingest_settings(jsonb)", "public.ingest_process_pending(integer)",
              "public.retry_inbox_row(bigint)", "public.discard_inbox_row(bigint, text)"]
INTERNAL_SIGS = ["public.ingest_transform_row(bigint)", "public.transform_connection_test_v1(jsonb)"]
TRIGGER_SIGS = [f"public.{f}()" for f in TRIGGER_FUNCS]
SUBMIT_SIG = "public.ingest_submit(text, text, jsonb)"


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


HEADER = """-- db/migrations/2026-10-06-mes1-entry-point.sql
-- MES-1 —— 车间设备的数据入口(MES 组的第一刀,v1.4.37;发布那一行在 docs/handbacks/MES-1.md 的抬头)。
-- 由 db/scripts/build_mes1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-06:MES-1 Step 0 的 Q1–Q30 全部照建议裁定;MES-0 的 Q1–Q96 照旧成立)
--   ① 七张表:devices(设备与网关登记)· gateway_keys(网关钥匙,只存 sha256)· ingest_settings(传输上限,单行)·
--      ingest_data_classes(数据类字典,只经迁移改)· ingest_inbox(收件箱)· ingest_transmissions(传输日志与两种桶)·
--      gateway_outages(网关中断)。后三张只追加、不进变更记录(MES-0 Q14);前四张进变更记录,钥匙的哈希用 never 规则遮住(Q20)。
--   ② 一支给 anon 的函数:ingest_submit —— 网关唯一够得着的东西(MES-0 Q4)。只插入三份日志(两种桶的四个计数列除外),
--      一行设备都不改,不跑转换代码,只回调用者自己的序号与固定的码;authenticated 与 service_role 都调不到(Q4)。
--   ③ 员工那一侧:登记 / 停用设备、发 / 撤钥匙、改上限、处理收件箱、重试 / 丢弃(action.manage_devices;处理只要 module.processing.view,Q11)。
--   ④ 一个码:action.manage_devices → admin · cto(admin 拿到每一个新码 —— 常设裁定)。
--   ⑤ 单据种类 DEV(有洞,device_code_seq;Q28);document_type_exceptions 多一行 ingest_data_classes。
--   ⑥ 视图:gateway_keys_masked · gateway_health · ingest_sequence_gaps · ingest_transmission_anomalies · pending_values;
--      operations_now 多两支(gateway_silent · capture_inbox_failed),列契约一字未动。
--   ⑦ 变更记录:四张新表各两条绑定;三张日志表豁免(带理由);遮蔽规则多 never 一行;审计记录多两个主语(device · ingest_settings)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不写、不改任何一张既有单据。
--   唯一的数据写入:权限码一行与它的两条授权 · 单据种类一行 · 例外表一行 · 两张新表的种子(数据类九行、上限一行)。
--
-- 【破窗】一切都是新的,部署之前的旧应用一样东西都不读它们:operations_now 列不变,旧的提醒页按它自己的清单画牌子,
--   两支新臂被跳过、不印成键名;trail_subjects 等同签名原地替换。匿名函数从 COMMIT 起就在,但在新页面部署之前没有人发得出
--   一把钥匙,所以没有一台网关认证得过。预计窗口里什么都不坏。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权只多那两行;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在那几张种子表上动了;anon 能执行的【恰好】两支;ingest_submit 对 authenticated / service_role 关着;
--   那 44 条开着的读策略还是 44 条、没有一条落在新表上;变更记录覆盖与遮蔽零缺口;每一张在途单据仍有一个不是它当事人的决定人。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

perm_rows = re.findall(r"^    (\('action\.manage_devices'.*?\))[,;]?$", mirror("db/tables/permissions.sql"), re.M)
assert len(perm_rows) == 1, perm_rows
dt_row = re.findall(r"^    (\('device', 'DEV'.*?\))[,;]?$", mirror("db/tables/document_types.sql"), re.M)
assert len(dt_row) == 1, dt_row
ex_row = re.findall(r"^    (\('ingest_data_classes',\s+'.*?'\))[,;]?$", mirror("db/tables/document_type_exceptions.sql"), re.M)
assert len(ex_row) == 1, ex_row
bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t, pk in LOGGED.items():
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m and f"change_log_capture('{pk}')" in m.group(0), t
    bind_sql.append(m.group(0))

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES1_PRE|approvals are expected ON';
    END IF;
    IF current_setting('server_version_num')::int < 130000 THEN
        RAISE EXCEPTION 'MES1_PRE|built-in sha256 / gen_random_uuid need PostgreSQL 13+ (Q5)';
    END IF;
    IF to_regclass('public.devices') IS NOT NULL OR to_regclass('public.ingest_inbox') IS NOT NULL
       OR to_regclass('public.gateway_keys') IS NOT NULL OR to_regprocedure('public.ingest_submit(text, text, jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES1_PRE|MES-1 objects already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'action.manage_devices') OR EXISTS (SELECT 1 FROM document_types WHERE key = 'device') THEN
        RAISE EXCEPTION 'MES1_PRE|the code or the document type already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM roles WHERE code = 'cto') OR NOT EXISTS (SELECT 1 FROM roles WHERE code = 'admin') THEN
        RAISE EXCEPTION 'MES1_PRE|roles admin and cto are expected';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 104 THEN
        RAISE EXCEPTION 'MES1_PRE|expected 104 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
""")

parts.append(f"""
-- ── 1 · 一个码(镜像原样)与授权 —— admin 拿到每一个新码(常设裁定,2026-09-24);cto 是 MES-0 Q90 点名的持有人。幂等。──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    {perm_rows[0]};

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'action.manage_devices' FROM roles r WHERE r.code IN ('admin', 'cto')
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append("\n-- ── 2 · 触发器函数(镜像原样)—— 表上的触发器要先有它们 ──────────────────────────\n")
for f in TRIGGER_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 3 · 七张表(镜像原样:表 · 种子 · 触发器 · RLS · 授权)────────────────────────\n")
for t in TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 4 · 单据种类 DEV 与例外表一行(镜像原样)────────────────────────────────────
INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)
VALUES
    {dt_row[0]};
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    {ex_row[0]}
ON CONFLICT (table_name) DO NOTHING;
""")

parts.append("\n-- ── 5 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 6 · 改过的函数:变更记录的豁免与遮蔽、审计记录的主语与成员(镜像原样,同签名)──────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 7 · 新视图(镜像原样)──────────────────────────────────────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v, False))
parts.append("\n-- ── 8 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, True))

parts.append("\n-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)────────────────\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
--   下面的自证跑在本体【里面】,所以权限要在这里先落好,自证才问得到真值。
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS + TRIGGER_SIGS + [SUBMIT_SIG]:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
acl.append(f"GRANT EXECUTE ON FUNCTION {SUBMIT_SIG} TO anon;\n")
acl.append(f"REVOKE EXECUTE ON FUNCTION {SUBMIT_SIG} FROM authenticated, service_role;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes1_pending_decider_check")
parts.append("\n-- ── 11 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|{sig} must not be callable from outside';
    END IF;""" for sig in INTERNAL_SIGS)

parts.append(f"""
CREATE TEMP TABLE mes1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权只多那两行(admin · cto ← action.manage_devices),一行没少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes1_grants_before
         EXCEPT SELECT unnest(ARRAY['admin:action.manage_devices', 'cto:action.manage_devices']))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES1_PROOF|unexpected grant change: %', v_bad; END IF;
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.manage_devices') <> 2 THEN
        RAISE EXCEPTION 'MES1_PROOF|action.manage_devices should be held by exactly admin and cto';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在种子那几张表上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes1_pending_before b EXCEPT SELECT a.k, a.id FROM mes1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes1_pending_after a EXCEPT SELECT b.k, b.id FROM mes1_pending_before b)) THEN
        RAISE EXCEPTION 'MES1_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes1_log_before)
       AND c.table_name NOT IN ('permissions', 'role_permissions', 'document_types', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES1_PROOF|change_log moved on %', v_bad; END IF;

    -- ④ 新表:除了两张种子表,一行都没有;种子是九类数据、一行上限
    IF EXISTS (SELECT 1 FROM devices) OR EXISTS (SELECT 1 FROM gateway_keys) OR EXISTS (SELECT 1 FROM ingest_inbox)
       OR EXISTS (SELECT 1 FROM ingest_transmissions) OR EXISTS (SELECT 1 FROM gateway_outages) THEN
        RAISE EXCEPTION 'MES1_PROOF|a new log or register table is not empty';
    END IF;
    IF (SELECT count(*) FROM ingest_data_classes) <> 9
       OR (SELECT count(*) FROM ingest_data_classes WHERE transform_function IS NOT NULL) <> 1
       OR (SELECT count(*) FROM ingest_settings) <> 1 THEN
        RAISE EXCEPTION 'MES1_PROOF|the seeds are not nine classes (one transformer) and one settings row';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 42 THEN RAISE EXCEPTION 'MES1_PROOF|document_types is not 42 rows'; END IF;

    -- ⑤ 匿名面:anon 能执行的【恰好】两支;ingest_submit 对 authenticated 与 service_role 关着;员工那几支 anon 调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES1_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_function_privilege('authenticated', '{SUBMIT_SIG}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('service_role', '{SUBMIT_SIG}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES1_PROOF|ingest_submit is callable by authenticated or service_role';
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('devices', 'gateway_keys', 'ingest_settings', 'ingest_data_classes', 'ingest_inbox',
           'ingest_transmissions', 'gateway_outages', 'gateway_keys_masked', 'gateway_health', 'ingest_sequence_gaps',
           'ingest_transmission_anomalies', 'pending_values')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES1_PROOF|anon can read %', v_bad; END IF;
    IF has_column_privilege('authenticated', 'public.gateway_keys', 'key_hash', 'SELECT') THEN
        RAISE EXCEPTION 'MES1_PROOF|gateway_keys.key_hash is readable by authenticated';
    END IF;

    -- ⑥ 那 44 条开着的读策略还是 44 条,没有一条落在新表上
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND qual = 'true'
                AND tablename IN ('devices', 'gateway_keys', 'ingest_settings', 'ingest_data_classes', 'ingest_inbox',
                                  'ingest_transmissions', 'gateway_outages')) THEN
        RAISE EXCEPTION 'MES1_PROOF|an open read policy sits on a MES-1 table';
    END IF;

    -- ⑦ 变更记录:覆盖零缺口(四张记、三张豁免);遮蔽零缺口(105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 7 THEN
        RAISE EXCEPTION 'MES1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

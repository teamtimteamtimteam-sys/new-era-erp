#!/usr/bin/env python3
"""MES-2(v1.4.38):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。种子行(权限码、单据种类)与授权在这里逐句写出,并与镜像里那几行逐字同义
(check_mirrors 在重建侧对照)。照抄 build_mes1_migration.py 的形状。
跑法:python3 db/scripts/build_mes2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql"

TRIGGER_FUNCS = ["guard_capture_append_only", "guard_capture_drafts_write", "guard_weighbridge_tickets_write",
                 "generate_weighbridge_ticket_code", "guard_ticket_photos_write", "guard_instrument_calibrations_write"]
TABLES = ["capture_drafts", "capture_draft_changes", "weighbridge_tickets", "weighings", "weighbridge_ticket_shares",
          "weighbridge_ticket_photos", "instrument_calibrations"]
NEW_FUNCS = ["transform_weighing_v1", "calibration_status_from", "capture_confirm_internal", "confirm_capture_draft",
             "reject_capture_draft", "submit_manual_capture", "correct_weighing", "weighbridge_share_internal",
             "share_weighbridge_ticket", "void_weighbridge_ticket", "record_ticket_photo", "withdraw_ticket_photo",
             "record_instrument_calibration", "void_instrument_calibration", "assert_receipt_reading_calibrated"]
REPLACED_FUNCS = ["ingest_transform_row", "ingest_process_pending", "set_ingest_settings", "reprice_inbound_batch",
                  "preview_reprice_inbound_batch", "issue_cod", "trail_subjects", "trail_subject_members"]
# 签名变了 —— preflight 不许 CREATE OR REPLACE 换签名(那是重载),所以 DROP 旧的、CREATE 新的
RESIGNED = {
    "create_inbound_batch": "public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, "
                            "numeric, text[], text, text, text, text)",
    "receive_inbound_batch_against_po": "public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, "
                                        "numeric, text[], text, text, text)",
}
NEW_VIEWS = ["weighing_calibration_all", "weighing_calibration", "instrument_calibration_now", "weighbridge_ticket_weights"]
REPLACED_VIEWS = ["operations_now", "pending_values"]

STAFF_SIGS = ["public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb)", "public.reject_capture_draft(uuid, text)",
              "public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb)",
              "public.correct_weighing(uuid, numeric, text)", "public.share_weighbridge_ticket(uuid, numeric, uuid, uuid)",
              "public.void_weighbridge_ticket(uuid, text)", "public.record_ticket_photo(uuid, text, text, text, integer)",
              "public.withdraw_ticket_photo(uuid, text)",
              "public.record_instrument_calibration(uuid, date, date, text, text, text, text)",
              "public.void_instrument_calibration(bigint, text)",
              "public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], "
              "text, text, text, text, uuid, numeric, text)",
              "public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, "
              "text, text, uuid, numeric, text)"]
INTERNAL_SIGS = ["public.transform_weighing_v1(jsonb)",
                 "public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text)",
                 "public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text)",
                 "public.assert_receipt_reading_calibrated(uuid)"]
PURE_SIGS = ["public.calibration_status_from(text, date, date)"]
TRIGGER_SIGS = [f"public.{f}()" for f in TRIGGER_FUNCS]


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


HEADER = """-- db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql
-- MES-2 —— 确认、称重与校准(MES 组的第二刀,v1.4.38;发布那一行在 docs/handbacks/MES-2.md 的抬头)。
-- 由 db/scripts/build_mes2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-06:MES-2 Step 0 的 Q1–Q35 全部照建议裁定;MES-0 Q1–Q96 与 MES-1 Q1–Q30 照旧成立)
--   ① 七张表:capture_drafts(草稿)· capture_draft_changes(确认时改过的值)· weighings(称重的正式记录)·
--      weighbridge_tickets(地磅单 WB-)· weighbridge_ticket_shares(分给收货单 / 发货行的份)· weighbridge_ticket_photos ·
--      instrument_calibrations(校准记录)。七张都进变更记录,没有一列遮蔽。
--   ② 两张既有表各加列:ingest_settings(require_calibrated_since —— 校准规则的开关,空 = 关;calibration_lead_days —— V8);
--      ingest_data_classes(creates_draft)。weighing 那一行接上 transform_weighing_v1、手工录入码 action.confirm_capture、落草稿。
--   ③ 分派器落草稿;"Process received" 也取已有转换器的 awaiting_transform 行;手工录入、确认 / 驳回 / 更正;地磅单、份、照片;
--      校准记录;校准闸(reprice_inbound_batch · 它的试算 · issue_cod)—— 开关空着时什么都不拒。
--   ④ 两支收货函数末尾多三个参数(地磅单的份 + 数量的理由):DROP + CREATE,参数都带默认值,旧应用的调用照样解析。
--   ⑤ 一个码:action.confirm_capture → admin · cto · warehouse。单据种类 WB(有洞)。
--   ⑥ 视图:weighing_calibration_all(基视图,不给人读)· weighing_calibration · instrument_calibration_now ·
--      weighbridge_ticket_weights;operations_now 多三支(capture_draft_pending · instrument_calibration_due ·
--      instrument_calibration_approaching),列契约一字未动;pending_values 多两支(V8 · V33)。
--   ⑦ 私有桶 capture-photos 与它的两条策略(读:收货或物流查看码;传:action.confirm_capture;不能改、不能删)。
--      桶不在镜像里(AGENTS.md),它的证明是 db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不写、不改任何一张既有单据;require_calibrated_since 保持空。
--   唯一的数据写入:权限码一行与它的三条授权 · 单据种类一行 · 数据类 weighing 那一行的三格 · 一个桶。
--
-- 【破窗】旧应用调两支收货函数时不传新参数 —— 它们带默认值,照样解析(DROP + CREATE 之后 NOTIFY pgrst 重载);
--   reprice_inbound_batch 与 issue_cod 在开关为空时与从前逐字同一个结果;新表、新视图旧应用一样都不读;
--   operations_now 列不变,旧的提醒页按它自己的清单画牌子,三支新臂被跳过。线上没有一行 weighing 类的收件箱(MES-1 的探针只发
--   connection_test),所以分派器从这一刻起落草稿,也没有东西可落。预计窗口里什么都不坏。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权只多那三行;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在种子那几张表上动了;anon 能执行的【恰好】两支;员工那几支 anon 调不到、内层谁都调不到;那 44 条开着的读策略
--   还是 44 条、没有一条落在新表上;变更记录覆盖与遮蔽零缺口;每一张在途单据仍有一个不是它当事人的决定人;开关是空的。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

perm_rows = re.findall(r"^    (\('action\.confirm_capture'.*?\))[,;]?$", mirror("db/tables/permissions.sql"), re.M)
assert len(perm_rows) == 1, perm_rows
dt_row = re.findall(r"^    (\('weighbridge_ticket', 'WB'.*?\))[,;]?$", mirror("db/tables/document_types.sql"), re.M)
assert len(dt_row) == 1, dt_row
weighing_row = re.findall(r"^    (\('weighing', 'Weighing'.*?\))[,;]?$", mirror("db/tables/ingest_data_classes.sql"), re.M)
assert len(weighing_row) == 1 and "'transform_weighing_v1', 'action.confirm_capture', true, 20, true" in weighing_row[0], weighing_row
bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m and "change_log_capture('id')" in m.group(0), t
    bind_sql.append(m.group(0))

# 两张既有表的列与注释,从镜像抽(ALTER 加的列在镜像的 CREATE 末尾)
settings_mirror = mirror("db/tables/ingest_settings.sql")
classes_mirror = mirror("db/tables/ingest_data_classes.sql")
assert "    require_calibrated_since date,\n    calibration_lead_days    integer CHECK (calibration_lead_days > 0)\n" in settings_mirror
assert "    creates_draft      boolean NOT NULL DEFAULT false\n" in classes_mirror
comments = []
for src, pat in ((settings_mirror, r"COMMENT ON COLUMN public\.ingest_settings\.(?:require_calibrated_since|calibration_lead_days) IS\n    '.*?';\n"),
                 (classes_mirror, r"COMMENT ON COLUMN public\.ingest_data_classes\.creates_draft IS\n    '.*?';\n")):
    found = re.findall(pat, src, re.S)
    assert found, pat
    comments.extend(found)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.capture_drafts') IS NOT NULL OR to_regclass('public.weighings') IS NOT NULL
       OR to_regclass('public.weighbridge_tickets') IS NOT NULL OR to_regclass('public.instrument_calibrations') IS NOT NULL THEN
        RAISE EXCEPTION 'MES2_PRE|MES-2 objects already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code = 'action.confirm_capture')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'weighbridge_ticket') THEN
        RAISE EXCEPTION 'MES2_PRE|the code or the document type already exists';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cto', 'warehouse')) <> 3 THEN
        RAISE EXCEPTION 'MES2_PRE|roles admin, cto and warehouse are expected';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES2_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM document_types) <> 42 THEN
        RAISE EXCEPTION 'MES2_PRE|expected 42 document types';
    END IF;
    IF EXISTS (SELECT 1 FROM ingest_inbox WHERE data_class = 'weighing') THEN
        RAISE EXCEPTION 'MES2_PRE|weighing rows already wait in the inbox';
    END IF;
    IF EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'capture-photos') THEN
        RAISE EXCEPTION 'MES2_PRE|bucket capture-photos already exists';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
""")

parts.append(f"""
-- ── 1 · 一个码(镜像原样)与授权 —— admin 拿到每一个新码(常设裁定);warehouse · cto 是 MES-0 Q11 / Q90 点名的持有人。幂等。──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    {perm_rows[0]};

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, 'action.confirm_capture' FROM roles r WHERE r.code IN ('admin', 'cto', 'warehouse')
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append("\n-- ── 2 · 触发器函数(镜像原样)—— 表上的触发器要先有它们 ──────────────────────────\n")
for f in TRIGGER_FUNCS:
    parts.append(fn(f))

parts.append("""
-- ── 3 · 两张既有表各加列(ALTER 加的列,镜像里在 CREATE 的末尾)与注释;weighing 那一行接上转换器 ────────────────
ALTER TABLE public.ingest_settings ADD COLUMN require_calibrated_since date;
ALTER TABLE public.ingest_settings ADD COLUMN calibration_lead_days integer CHECK (calibration_lead_days > 0);
ALTER TABLE public.ingest_data_classes ADD COLUMN creates_draft boolean NOT NULL DEFAULT false;
""")
parts.append("".join(comments))
m = re.match(r"\('weighing', 'Weighing', '称重', '(.*?)', '(transform_weighing_v1)', '(action\.confirm_capture)', true, 20, true\)",
             weighing_row[0])
assert m, weighing_row[0]
parts.append(f"""UPDATE public.ingest_data_classes
   SET target_en = '{m.group(1)}', transform_function = '{m.group(2)}', manual_entry_code = '{m.group(3)}', creates_draft = true
 WHERE code = 'weighing';
""")

parts.append("\n-- ── 4 · 七张表(镜像原样:表 · 触发器 · RLS · 授权)────────────────────────────────\n")
for t in TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 5 · 单据种类 WB(镜像原样)──────────────────────────────────────────────────
INSERT INTO public.document_types
    (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission)
VALUES
    {dt_row[0]};
""")

parts.append("\n-- ── 6 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 7 · 改过的函数(镜像原样,同签名)────────────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 8 · 换了签名的两支收货函数:DROP 旧签名、CREATE 新的(镜像原样;新参数都在末尾、都带默认值)──────────\n")
for f, old in RESIGNED.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))
parts.append("\n-- ── 9 · 新视图(镜像原样)──────────────────────────────────────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v, False))
parts.append("\n-- ── 10 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, True))

parts.append("\n-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)────────────────\n")
parts.append("".join(bind_sql))

parts.append("""
-- ── 12 · 私有桶 capture-photos(MES-0 Q20 · MES-2 Step 0 Q21)—— 不在镜像里(AGENTS.md);证明在 db/scripts/2026-10-06-mes2-capture-photos-policy-proof.sql ──
--   本仓库第一个【按权限码读】的桶:此前每一个桶都只按 bucket_id 读,真正的门是它的登记表;这一个两道都有(登记表 + 桶)。
--   不给 UPDATE / DELETE 策略:照片不改、不删,拍错的在登记行上撤下。
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('capture-photos', 'capture-photos', false, 10485760, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "capture-photos read by inbound or logistics view"
    ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
    USING (bucket_id = 'capture-photos'::text
           AND (public.has_permission('module.inbound.view'::text) OR public.has_permission('module.logistics.view'::text)));

CREATE POLICY "capture-photos upload by confirm_capture"
    ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'capture-photos'::text AND public.has_permission('action.confirm_capture'::text));
""")

acl = ["""
-- ── 13 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
--   下面的自证跑在本体【里面】,所以权限要在这里先落好,自证才问得到真值。
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS + PURE_SIGS + TRIGGER_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes2_pending_decider_check")
parts.append("\n-- ── 14 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure) THEN
        RAISE EXCEPTION 'MES2_PROOF|{sig} must be an internal function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
new_rel = TABLES + NEW_VIEWS
rel_list = ", ".join(f"'{r}'" for r in new_rel)
tbl_list = ", ".join(f"'{t}'" for t in TABLES)

parts.append(f"""
CREATE TEMP TABLE mes2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权只多那三行(admin · cto · warehouse ← action.confirm_capture),一行没少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes2_grants_before
         EXCEPT SELECT unnest(ARRAY['admin:action.confirm_capture', 'cto:action.confirm_capture', 'warehouse:action.confirm_capture']))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|unexpected grant change: %', v_bad; END IF;
    IF (SELECT count(*) FROM role_permissions rp WHERE rp.permission_code = 'action.confirm_capture') <> 3 THEN
        RAISE EXCEPTION 'MES2_PROOF|action.confirm_capture should be held by exactly admin, cto and warehouse';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在种子那几张表上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes2_pending_before b EXCEPT SELECT a.k, a.id FROM mes2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes2_pending_after a EXCEPT SELECT b.k, b.id FROM mes2_pending_before b)) THEN
        RAISE EXCEPTION 'MES2_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes2_log_before)
       AND c.table_name NOT IN ('permissions', 'role_permissions', 'document_types', 'ingest_data_classes');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|change_log moved on %', v_bad; END IF;

    -- ④ 新表一行都没有;数据类九行、两支转换器、一类落草稿;开关与 V8 都是空的;单据种类 43
    SELECT string_agg(t, ', ') INTO v_bad FROM unnest(ARRAY[{tbl_list}]) t
     WHERE (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', t), false, true, '')))[1]::text <> '0';
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|new tables not empty: %', v_bad; END IF;
    IF (SELECT count(*) FROM ingest_data_classes) <> 9
       OR (SELECT count(*) FROM ingest_data_classes WHERE transform_function IS NOT NULL) <> 2
       OR (SELECT string_agg(code, ',') FROM ingest_data_classes WHERE creates_draft) IS DISTINCT FROM 'weighing'
       OR (SELECT manual_entry_code FROM ingest_data_classes WHERE code = 'weighing') IS DISTINCT FROM 'action.confirm_capture' THEN
        RAISE EXCEPTION 'MES2_PROOF|the data classes are not as built';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL
       OR (SELECT calibration_lead_days FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES2_PROOF|require_calibrated_since and calibration_lead_days must start empty';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 43 THEN RAISE EXCEPTION 'MES2_PROOF|document_types is not 43 rows'; END IF;

    -- ⑤ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES2_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    IF NOT has_function_privilege('authenticated', 'public.calibration_status_from(text, date, date)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES2_PROOF|calibration_status_from must stay executable (owner views call it as the reader)';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES2_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.weighing_calibration_all', 'SELECT') THEN
        RAISE EXCEPTION 'MES2_PROOF|weighing_calibration_all must not be readable by authenticated';
    END IF;

    -- ⑥ 那 44 条开着的读策略还是 44 条,没有一条落在新表上
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND tablename IN ({tbl_list})) THEN
        RAISE EXCEPTION 'MES2_PROOF|an open read policy sits on a MES-2 table';
    END IF;

    -- ⑦ 变更记录:覆盖零缺口(七张新表都记,豁免仍是 7);遮蔽零缺口(仍是 105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 7 THEN
        RAISE EXCEPTION 'MES2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑧ 提醒臂 52 支;桶是私有的、带两条策略
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 52 THEN
        RAISE EXCEPTION 'MES2_PROOF|operations_now should have 52 arms';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'capture-photos' AND NOT public) THEN
        RAISE EXCEPTION 'MES2_PROOF|bucket capture-photos missing or public';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'
          AND policyname LIKE 'capture-photos %') <> 2 THEN
        RAISE EXCEPTION 'MES2_PROOF|capture-photos should carry exactly two storage policies';
    END IF;

    -- ⑨ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

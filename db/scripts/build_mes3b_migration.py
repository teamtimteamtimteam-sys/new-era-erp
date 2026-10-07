#!/usr/bin/env python3
"""MES-3b(v1.4.40):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表的改动(加列、换绑定)在这里逐句写出,并与镜像里那几行逐字同义
(check_mirrors 在重建侧对照)。照抄 build_mes3a_migration.py 的形状。
跑法:python3 db/scripts/build_mes3b_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-07-mes3b-labels-scanning.sql"

TRIGGER_FUNCS = ["guard_append_only_log"]
NEW_TABLES = ["dangerous_goods_codes", "label_templates", "label_prints", "scan_events"]
LOGGED_NEW = ["dangerous_goods_codes", "label_templates", "label_prints"]       # scan_events 豁免(Q20)
NEW_FUNCS = ["label_object_data", "label_print_context", "label_print_preview", "record_label_print",
             "resolve_scan_code", "batch_quarantine_states"]
REPLACED_FUNCS = ["shipment_document", "ship_order", "change_log_exclusions", "trail_subjects", "trail_subject_members"]
# 返回类型变了(末尾多三列)—— CREATE OR REPLACE 换不了返回类型,所以 DROP 旧的、CREATE 新的
RESIGNED = {"shipping_queue_rows": "public.shipping_queue_rows()"}
REPLACED_VIEWS = ["pending_values"]

STAFF_SIGS = ["public.label_print_preview(text, uuid, text)", "public.record_label_print(text, uuid, text, integer, text)",
              "public.resolve_scan_code(text, text, text)", "public.shipping_queue_rows()"]
INTERNAL_SIGS = ["public.label_object_data(text, uuid)", "public.label_print_context(text, uuid, text)",
                 "public.batch_quarantine_states(uuid)"]
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


def comment_on(path, target):
    """镜像里 COMMENT ON <target> IS '...'; 那一句,原样。"""
    m = re.search(rf"COMMENT ON {re.escape(target)} IS\n(?:    )?'.*?';\n", mirror(path), re.S)
    assert m, (path, target)
    return m.group(0)


HEADER = """-- db/migrations/2026-10-07-mes3b-labels-scanning.sql
-- MES-3b —— 标签与扫码(MES 组的第四刀,v1.4.40;发布那一行在 docs/handbacks/MES-3b.md 的抬头)。
-- 由 db/scripts/build_mes3b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-07:MES-3b Step 0 的 Q0–Q31 全部照建议裁定;docs/surveys/MES-3b/STEP0-HANDBACK.md §11)
--   ① 标签(功能 7):四张新表里的三张 —— label_templates(固定形状的模板字典,引导六行:三种东西 × A6 / A5)·
--      label_prints(每一次印标签,只追加;第一次之后都是补印,要理由)· dangerous_goods_codes(UN3480 · UN3481 · UN3090 · UN3091,
--      第 9 类;标记文字等三列从空开始 —— V30)。materials 加 dg_code(V35)与 hs_code(V31,形状检查)。
--      label_object_data / label_print_context / label_print_preview / record_label_print:标签印什么、谁能印、模板、补印 ——
--      物料名与供应商名以属主身份读(Q2 的并入:仓库印出来的标签不再缺物料名)。
--   ② 扫码(功能 8):scan_events(只追加,不进变更记录)与 resolve_scan_code(四种写法、四种结果,只返回、不抛;看不见的人拿不到 id)。
--      ship_order 认一个可选的核对扫码(SHIP_SCAN_MISMATCH)。
--   ③ 发货的数据:shipment_document 每一行多带危险品、HS 与开着的要隔离的状态;shipping_queue_rows 末尾三列(返回类型变了 → DROP + CREATE)。
--      要隔离的状态只【标出来】,不拒(Q16);危险品编号没选只提示,不拒(Q15)。
--   ④ 视图:pending_values 多三个值(V30 · V31 · V35)。
--   ⑤ 并入:nea_waste_categories 的变更记录绑定从 'id' 改成它真正的主键 'code'(MES-3a 绑错了一列 —— 那张表没有 id,
--      每一次改动都会记下一个空的键;线上 0 行,所以没有一行要补)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据;
--   不给任何物料选危险品编号或 HS 编码,不填任何标记文字;不碰任何类别、上限、滞留天数、隔离库位;require_calibrated_since 保持空。
--   只播两本字典的引导行(四个 UN 编号、六张模板)与两行例外表登记。
--
-- 【破窗】见 docs/surveys/MES-3b/STEP0-HANDBACK.md §9:只加东西。旧的标签路由照样印(只是那段时间不留印的记录);
--   旧的发货页不带 scanned_code(可选);旧页面按列名读 shipping_queue_rows,末尾三列不碍事;shipment_document 多出来的键旧页面不读。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在两本新字典(引导)与例外表(两行)上动了;两张日志表是空的;没有一种物料有危险品编号或 HS 编码;MES-3a 的东西一样都没设;
--   开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 7 → 8);
--   每一张被记录的表的绑定键都是它的主键;提醒臂 55 支;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in LOGGED_NEW:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))
assert "public.scan_events" not in bindings
nea_bind = re.search(r"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.nea_waste_categories\n.*?\n", bindings).group(0)
assert "change_log_capture('code')" in nea_bind

# 既有表镜像里那几行,与下面逐句写出的 ALTER 逐字同义 —— 先断言镜像真的是这个样子
mat = mirror("db/tables/materials.sql")
assert "    dg_code                 text REFERENCES public.dangerous_goods_codes (code),\n" in mat
assert ("    hs_code                 text CONSTRAINT materials_hs_code_shape\n"
        "                                 CHECK (hs_code ~ '^[0-9]+(\\.[0-9]+)*$' AND length(replace(hs_code, '.', '')) BETWEEN 6 AND 12)\n);") in mat

dte = mirror("db/tables/document_type_exceptions.sql")
dte_rows = [re.search(rf"^    (\('{t}',.*?\))[,;]?$", dte, re.M).group(1) for t in ("dangerous_goods_codes", "label_templates")]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES3B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.dangerous_goods_codes') IS NOT NULL OR to_regclass('public.label_templates') IS NOT NULL
       OR to_regclass('public.label_prints') IS NOT NULL OR to_regclass('public.scan_events') IS NOT NULL THEN
        RAISE EXCEPTION 'MES3B_PRE|MES-3b tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'materials'
                 AND column_name IN ('dg_code', 'hs_code')) THEN
        RAISE EXCEPTION 'MES3B_PRE|MES-3b columns already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3B_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3B_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES3B_PRE|operations_now should have 55 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 10 THEN
        RAISE EXCEPTION 'MES3B_PRE|pending_values should have 10 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3B_PRE|require_calibrated_since must be empty';
    END IF;
    IF EXISTS (SELECT 1 FROM nea_waste_categories) THEN
        RAISE EXCEPTION 'MES3B_PRE|nea_waste_categories is expected empty (its change-log binding is re-keyed with no rows to repair)';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes3b_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes3b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes3b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes3b_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
""")

parts.append("\n-- ── 1 · 触发器函数(镜像原样)—— 表上的触发器要先有它 ──────────────────────────\n")
for f in TRIGGER_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 2 · 两本字典(镜像原样,带引导)与两张只追加的日志表 ──────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    {dte_rows[0]},
    {dte_rows[1]};
""")

parts.append("""
-- ── 3 · 物料上的危险品编号与 HS 编码(Q12 · Q17)────────────────────────────────────
ALTER TABLE public.materials ADD COLUMN dg_code text REFERENCES public.dangerous_goods_codes (code);
ALTER TABLE public.materials ADD COLUMN hs_code text CONSTRAINT materials_hs_code_shape
    CHECK (hs_code ~ '^[0-9]+(\\.[0-9]+)*$' AND length(replace(hs_code, '.', '')) BETWEEN 6 AND 12);
""")
parts.append(comment_on("db/tables/materials.sql", "COLUMN public.materials.dg_code"))
parts.append(comment_on("db/tables/materials.sql", "COLUMN public.materials.hs_code"))

parts.append("""
-- ── 4 · 并入:nea_waste_categories 的变更记录绑定换成它真正的主键 code(MES-3a 绑的是一列不存在的 id)──────────
DROP TRIGGER zzz_change_log ON public.nea_waste_categories;
""" + nea_bind)

parts.append("\n-- ── 5 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 6 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 7 · 返回类型变了的一支:DROP 旧的、CREATE 新的(末尾三列)────────────────────────\n")
for f, old in RESIGNED.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))

parts.append("\n-- ── 8 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, True))

parts.append("\n-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份;scan_events 豁免)────────────\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS + TRIGGER_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes3b_pending_decider_check")
parts.append("\n-- ── 11 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3B_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure) THEN
        RAISE EXCEPTION 'MES3B_PROOF|{sig} must be an internal function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES)

parts.append(f"""
CREATE TEMP TABLE mes3b_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM mes3b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes3b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES3B_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes3b_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes3b_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES3B_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在两本新字典的引导与例外表的两行上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes3b_pending_before b EXCEPT SELECT a.k, a.id FROM mes3b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes3b_pending_after a EXCEPT SELECT b.k, b.id FROM mes3b_pending_before b)) THEN
        RAISE EXCEPTION 'MES3B_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes3b_log_before)
       AND c.table_name NOT IN ('dangerous_goods_codes', 'label_templates', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|change_log moved on %', v_bad; END IF;
    -- 两本字典的引导行在它们的绑定之前插入(第 2 段 → 第 9 段),所以只有例外表那两行进了变更记录
    IF (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes3b_log_before)) <> 2 THEN
        RAISE EXCEPTION 'MES3B_PROOF|expected 2 change-log rows (the two document_type_exceptions rows), got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes3b_log_before));
    END IF;

    -- ④ 两本字典恰好是引导;两张日志表是空的;没有一种物料有编号;MES-3a 的东西一样都没设;开关是空的
    IF (SELECT string_agg(code || ':' || dg_class, ',' ORDER BY code) FROM dangerous_goods_codes)
       IS DISTINCT FROM 'UN3090:9,UN3091:9,UN3480:9,UN3481:9'
       OR EXISTS (SELECT 1 FROM dangerous_goods_codes WHERE marking_text IS NOT NULL OR packing_instruction IS NOT NULL OR label_size IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3B_PROOF|the DG dictionary is not exactly its bootstrap';
    END IF;
    IF (SELECT string_agg(code || ':' || object_kind || ':' || page_size, ',' ORDER BY sort_order) FROM label_templates)
       IS DISTINCT FROM 'inbound_a6:inbound_batch:A6,inbound_a5:inbound_batch:A5,output_a6:output_batch:A6,output_a5:output_batch:A5,location_a6:storage_location:A6,location_a5:storage_location:A5' THEN
        RAISE EXCEPTION 'MES3B_PROOF|the label templates are not exactly their bootstrap';
    END IF;
    IF EXISTS (SELECT 1 FROM label_prints) OR EXISTS (SELECT 1 FROM scan_events) THEN
        RAISE EXCEPTION 'MES3B_PROOF|a log table is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM materials WHERE dg_code IS NOT NULL OR hs_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3B_PROOF|a material got a DG or HS code';
    END IF;
    IF EXISTS (SELECT 1 FROM nea_waste_categories) OR EXISTS (SELECT 1 FROM licence_storage_limits)
       OR EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine)
       OR EXISTS (SELECT 1 FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL)
       OR (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3B_PROOF|a category, ceiling, quarantine location, dwell period or the calibration switch was set';
    END IF;

    -- ⑤ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES3B_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|anon can read %', v_bad; END IF;

    -- ⑥ 那 44 条开着的读策略还是 44 条;两张日志表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3B_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('label_prints', 'scan_events')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES3B_PROOF|a write policy exists on a log table';
    END IF;

    -- ⑦ 变更记录:覆盖零缺口(三张新表都记,scan_events 豁免 —— 7 → 8);遮蔽零缺口(仍是 105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES3B_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3B_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    -- ⑦b 每一张被记录的表,绑定的键就是它的主键(nea_waste_categories 那一处之后,一处都不许再错)
    SELECT string_agg(t.relname, ', ') INTO v_bad
      FROM (SELECT c.relname, substring(pg_get_triggerdef(tg.oid) FROM 'change_log_capture\\((.*)\\)') AS args
              FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND tg.tgname = 'zzz_change_log') t
      LEFT JOIN (SELECT c.relname, string_agg(quote_literal(a.attname), ', ' ORDER BY array_position(i.indkey::int2[], a.attnum)) AS cols
                   FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey)
                  WHERE n.nspname = 'public' AND i.indisprimary GROUP BY c.relname) pk ON pk.relname = t.relname
     WHERE t.args IS DISTINCT FROM pk.cols;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑧ 提醒臂 55 支(本刀一支不加);待补的值 10 → 13 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES3B_PROOF|operations_now should still have 55 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 13 THEN
        RAISE EXCEPTION 'MES3B_PROOF|pending_values should have 13 arms';
    END IF;

    -- ⑨ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes3b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES3B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes3b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES3B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes3b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

#!/usr/bin/env python3
"""MES-3a(v1.4.39):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、函数、视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表的改动(加列、换主键、拿掉策略)在这里逐句写出,并与镜像里那几行逐字同义
(check_mirrors 在重建侧对照)。照抄 build_mes2_migration.py 的形状。
跑法:python3 db/scripts/build_mes3a_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-06-mes3a-storage-safety.sql"

TRIGGER_FUNCS = ["guard_safety_state_rows", "guard_ceiling_check_append_only", "guard_movement_direct_insert"]
NEW_TABLES = ["nea_waste_categories", "licence_storage_limits", "receipt_ceiling_checks"]
NEW_FUNCS = ["quantity_in_tonnes", "storage_licence_in_force", "assert_quarantine_landing", "receipt_ceiling_check_internal",
             "set_output_safety_states"]
REPLACED_FUNCS = ["create_inbound_batch", "receive_inbound_batch_against_po", "create_output_batch", "create_stock_transfer",
                  "commit_processing_run", "rollback_processing_run_internal", "assert_receipt_reading_calibrated",
                  "reprice_inbound_batch", "trail_subjects", "trail_subject_members"]
# 签名变了 —— preflight 不许 CREATE OR REPLACE 换签名(那是重载),所以 DROP 旧的、CREATE 新的
RESIGNED = {
    "set_inbound_safety_states": "public.set_inbound_safety_states(uuid, text[])",
    "save_storage_location": "public.save_storage_location(text, text, text[], uuid, text, text)",
}
DROPPED = ["public.licence_storage_within_limit()", "public.hazardous_qty_on_hand_tonnes()"]
NEW_VIEWS = ["nea_category_on_hand_all", "storage_ceiling_status", "safety_state_dwell", "quarantine_exposure"]
REPLACED_VIEWS = ["processing_wip", "pending_values", "operations_now"]

STAFF_SIGS = ["public.set_inbound_safety_states(uuid, text[], text)", "public.set_output_safety_states(uuid, text[], text)",
              "public.save_storage_location(text, text, text[], uuid, text, text, boolean)"]
INTERNAL_SIGS = ["public.receipt_ceiling_check_internal(uuid, uuid)", "public.assert_quarantine_landing(text[], uuid)"]
OPEN_SIGS = ["public.quantity_in_tonnes(numeric, text)", "public.storage_licence_in_force(date)"]
TRIGGER_SIGS = [f"public.{f}()" for f in TRIGGER_FUNCS]
FACT = {"inbound_batch_safety_states": ("inbound", "module.inbound.edit"),
        "output_batch_safety_states": ("output", "module.output.edit")}


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


HEADER = """-- db/migrations/2026-10-06-mes3a-storage-safety.sql
-- MES-3a —— 仓储安全(MES 组的第三刀,v1.4.39;发布那一行在 docs/handbacks/MES-3a.md 的抬头)。
-- 由 db/scripts/build_mes3a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-06:MES-3a Step 0 的 Q1–Q33 全部照建议裁定;裁定 1–5 见 docs/surveys/MES-3a/STEP0-HANDBACK.md §0)
--   ① 库存上限(功能 4):三张新表 nea_waste_categories(NEA 废物类别,从空开始 —— V29)· licence_storage_limits(执照 × 类别的上限,V2)·
--      receipt_ceiling_checks(每一张收货 / 手工产出进来时怎么判的,只追加);materials 加 nea_waste_category_code。
--      两支收货函数与 create_output_batch 落库之后判一次:超过给了的上限按名拒,没给就照收、记下是哪一种(Q33)。
--      licence_storage_within_limit / hazardous_qty_on_hand_tonnes 删掉(没有调用方,而且"读到空就拒绝作判断"与 Q33 相反)。
--   ② 滞留提醒(功能 5):inbound_safety_states 加 dwell_warning_days(V3);视图 safety_state_dwell;提醒臂 safety_state_dwell。
--   ③ 隔离(功能 6):storage_locations 加 is_quarantine;inbound_safety_states 加 requires_quarantine(鼓包或漏液 = 要,
--      已放电 = 不要,其余没定 —— V4);收货与转移在写入之前按名拒 QUARANTINE_LOCATION_REQUIRED;视图 quarantine_exposure;
--      提醒臂 quarantine_required;库存流水的直连插入关上(MOVEMENTS_THROUGH_FUNCTION_ONLY,Q3)。
--   ④ 安全状态有历史(Q36 · Q22–Q25):两张状态表换成 id 主键,加 ended_at / ended_by / end_reason / ended_by_run_id /
--      created_by_run_id / reopened_from_id;开着的 (批次, 状态) 只有一条(部分唯一索引);只经函数写、只结束一次、永不删;
--      set_inbound_safety_states 只加新勾上的、只结束拿掉的(结束要理由);新的 set_output_safety_states;加工提交结束它解决掉的状态,
--      回滚把它们重新开出来、并结束它写上的那一条(Q2)。
--   ⑤ 并入:校准规则还原(Tim 的裁定 1)—— 不在校准期内的读数永远拒,开关只管两种缺席。
--   ⑥ 视图:operations_now 多三支(52 → 55,列契约一字未动)· pending_values 多五个值(V2 · V29 · V3 · V4 · V34)·
--      processing_wip 只数开着的状态 · 新视图 storage_ceiling_status。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据;
--   不给任何类别、上限、滞留天数、隔离库位(只播两个状态的 requires_quarantine,Q34 / Q18);require_calibrated_since 保持空。
--   线上那两条安全状态行原样开着(Q24)。
--
-- 【破窗】见 docs/surveys/MES-3a/STEP0-HANDBACK.md §12:产出批页面的安全状态面板直连插 / 删,那两条策略拿掉之后它在窗口里存不进去;
--   批次页面的到货状态面板勾上照样能存,拿掉一个会被要理由拒(旧页面不传理由);新拒绝码在旧页面上显示原文;
--   旧的审计记录把"结束一条状态"说成"记下一条状态"。定价与证书:线上 0 条称重,还原的校准规则什么都不拒。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在 inbound_safety_states(两行引导)上动了;三张新表与类别都是空的;没有一个库位被标成隔离、没有一个滞留天数;
--   开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口;
--   提醒臂 55 支;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

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
    assert m and "change_log_capture('id')" in m.group(0), t
    bind_sql.append(m.group(0))
for t in FACT:
    assert re.search(rf"ON public\.{t}\n    FOR EACH ROW EXECUTE FUNCTION public\.change_log_capture\('id'\);", bindings), t

# 既有表镜像里那几行,与下面逐句写出的 ALTER 逐字同义 —— 先断言镜像真的是这个样子
mat = mirror("db/tables/materials.sql")
assert "    nea_waste_category_code text REFERENCES public.nea_waste_categories (code)\n);" in mat
loc = mirror("db/tables/storage_locations.sql")
assert "    is_quarantine boolean NOT NULL DEFAULT false\n);" in loc
iss = mirror("db/tables/inbound_safety_states.sql")
assert ("    dwell_warning_days  integer CHECK (dwell_warning_days > 0),\n" in iss
        and "    requires_quarantine boolean\n);" in iss)
mov = mirror("db/tables/inventory_movements.sql")
assert '"inventory_movements insert by permission"' not in mov and "trg_inventory_movements_through_function" in mov
for t in FACT:
    src = mirror(f"db/tables/{t}.sql")
    for frag in ("    id                uuid NOT NULL DEFAULT gen_random_uuid(),\n",
                 "    created_by_run_id uuid REFERENCES public.processing_runs (id),\n",
                 "    reopened_from_id  uuid,\n", f"CONSTRAINT {t}_pkey PRIMARY KEY (id)",
                 f"{t}_open_once", "guard_safety_state_rows", f"CONSTRAINT {t}_end_shape"):
        assert frag in src, (t, frag)
    assert (f'"{t} insert by permission"' not in src and f'"{t} delete by permission"' not in src
            and "EXECUTE FUNCTION public.enforce_write_permission" not in src), t

pi_src = mirror("db/tables/processing_inputs.sql")
i = pi_src.index("CREATE OR REPLACE FUNCTION public.guard_processing_input()")
j = pi_src.index("$function$\n;\n", i) + len("$function$\n;\n")
guard_input = pi_src[i:j]
assert guard_input.count("ended_at IS NULL") == 6

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES3A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.nea_waste_categories') IS NOT NULL OR to_regclass('public.licence_storage_limits') IS NOT NULL
       OR to_regclass('public.receipt_ceiling_checks') IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PRE|MES-3a tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND ((table_name = 'inbound_batch_safety_states' AND column_name = 'ended_at')
                      OR (table_name = 'storage_locations' AND column_name = 'is_quarantine'))) THEN
        RAISE EXCEPTION 'MES3A_PRE|MES-3a columns already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3A_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3A_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 52 THEN
        RAISE EXCEPTION 'MES3A_PRE|operations_now should have 52 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes3a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes3a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes3a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes3a_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes3a_states_before ON COMMIT DROP AS
SELECT 'inbound'::text AS k, inbound_batch_id AS b, safety_state_code AS c, created_at, created_by FROM inbound_batch_safety_states
UNION ALL
SELECT 'output', output_batch_id, safety_state_code, created_at, created_by FROM output_batch_safety_states;
""")

parts.append("\n-- ── 1 · 触发器函数(镜像原样)—— 表上的触发器要先有它们 ──────────────────────────\n")
for f in TRIGGER_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 2 · NEA 类别字典(镜像原样,从空开始)与物料上的类别列 ───────────────────────────\n")
parts.append("\n" + mirror("db/tables/nea_waste_categories.sql"))
parts.append("""
ALTER TABLE public.materials ADD COLUMN nea_waste_category_code text REFERENCES public.nea_waste_categories (code);
""")
parts.append(comment_on("db/tables/materials.sql", "COLUMN public.materials.nea_waste_category_code"))

dte = re.findall(r"^    (\('nea_waste_categories',.*?\))[,;]?$", mirror("db/tables/document_type_exceptions.sql"), re.M)
assert len(dte) == 1, dte
parts.append(f"""
-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    {dte[0]};
""")
parts.append("\n-- ── 3 · 上限与判法两张表(镜像原样)────────────────────────────────────────────\n")
for t in NEW_TABLES[1:]:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append("""
-- ── 4 · 隔离库位;安全状态字典的两列(Q14 · Q18)与它们的引导值 ──────────────────────────────
ALTER TABLE public.storage_locations ADD COLUMN is_quarantine boolean NOT NULL DEFAULT false;
""")
parts.append(comment_on("db/tables/storage_locations.sql", "COLUMN public.storage_locations.is_quarantine"))
parts.append("""ALTER TABLE public.inbound_safety_states ADD COLUMN dwell_warning_days integer CHECK (dwell_warning_days > 0);
ALTER TABLE public.inbound_safety_states ADD COLUMN requires_quarantine boolean;
""")
parts.append(comment_on("db/tables/inbound_safety_states.sql", "COLUMN public.inbound_safety_states.dwell_warning_days"))
parts.append(comment_on("db/tables/inbound_safety_states.sql", "COLUMN public.inbound_safety_states.requires_quarantine"))
parts.append("""-- 引导(与镜像的 INSERT 逐字同义):鼓包或漏液 = 要隔离(Q34);已放电并核验 = 不要;其余三个留空(V4)。没有一个滞留天数(V3)。
UPDATE public.inbound_safety_states SET requires_quarantine = true  WHERE code = 'swollen_leaking';
UPDATE public.inbound_safety_states SET requires_quarantine = false WHERE code = 'discharged_verified';
""")
parts.append(comment_on("db/tables/company_compliance.sql", "COLUMN public.company_compliance.approved_storage_limit_tonnes"))
parts.append(comment_on("db/tables/ingest_settings.sql", "COLUMN public.ingest_settings.require_calibrated_since"))

parts.append("\n-- ── 5 · 两张安全状态表:有历史(Q22)—— 主键换成 id,开着的只有一条,只经函数写,只结束一次,永不删 ──────────\n")
for t, (side, code) in FACT.items():
    short = side
    parts.append(f"""
DROP TRIGGER enforce_write_permission ON public.{t};
DROP POLICY "{t} insert by permission" ON public.{t};
DROP POLICY "{t} delete by permission" ON public.{t};
ALTER TABLE public.{t} DROP CONSTRAINT {t}_pkey;
ALTER TABLE public.{t} ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.{t} ADD COLUMN created_by_run_id uuid REFERENCES public.processing_runs (id);
ALTER TABLE public.{t} ADD COLUMN ended_at timestamptz;
ALTER TABLE public.{t} ADD COLUMN ended_by uuid;
ALTER TABLE public.{t} ADD COLUMN end_reason text;
ALTER TABLE public.{t} ADD COLUMN ended_by_run_id uuid REFERENCES public.processing_runs (id);
ALTER TABLE public.{t} ADD COLUMN reopened_from_id uuid;
ALTER TABLE public.{t} ADD CONSTRAINT {t}_pkey PRIMARY KEY (id);
ALTER TABLE public.{t} ADD CONSTRAINT {t}_reopened_from_fkey
    FOREIGN KEY (reopened_from_id) REFERENCES public.{t} (id);
ALTER TABLE public.{t} ADD CONSTRAINT {t}_end_shape
    CHECK ((ended_at IS NULL AND ended_by IS NULL AND end_reason IS NULL AND ended_by_run_id IS NULL)
           OR (ended_at IS NOT NULL AND end_reason IS NOT NULL AND btrim(end_reason) <> ''));
CREATE UNIQUE INDEX {t}_open_once
    ON public.{t} ({side}_batch_id, safety_state_code) WHERE ended_at IS NULL;
CREATE TRIGGER trg_{short}_safety_states_rows
    BEFORE INSERT OR UPDATE ON public.{t}
    FOR EACH ROW EXECUTE FUNCTION public.guard_safety_state_rows();
CREATE TRIGGER trg_{short}_safety_states_statement
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.{t}
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_safety_state_rows();
DROP TRIGGER zzz_change_log ON public.{t};
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.{t}
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
""")
    parts.append(comment_on(f"db/tables/{t}.sql", f"TABLE public.{t}"))

parts.append("""
-- ── 6 · 库存流水的直连插入关上(Q3)────────────────────────────────────────────
DROP POLICY "inventory_movements insert by permission" ON public.inventory_movements;
CREATE TRIGGER trg_inventory_movements_through_function
    BEFORE INSERT ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_movement_direct_insert();
""")

parts.append("\n-- ── 7 · 新函数(镜像原样)──────────────────────────────────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 8 · 改过的函数(镜像原样,同签名);投料闸住在 processing_inputs 的表镜像里 ────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n" + guard_input)
parts.append("\n-- ── 9 · 换了签名的两支:DROP 旧签名、CREATE 新的(新参数都在末尾、都带默认值)──────────\n")
for f, old in RESIGNED.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))
parts.append("\n-- ── 10 · 删掉的两支(Q11):没有调用方,而且读到空就拒绝作判断 —— 与 Q33 相反 ─────────────\n")
for sig in DROPPED:
    parts.append(f"DROP FUNCTION {sig};\n")

parts.append("\n-- ── 11 · 新视图(镜像原样)──────────────────────────────────────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v, False))
parts.append("\n-- ── 12 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, True))

parts.append("\n-- ── 13 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)────────────────\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 14 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS + OPEN_SIGS + TRIGGER_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes3a_pending_decider_check")
parts.append("\n-- ── 15 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3A_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure) THEN
        RAISE EXCEPTION 'MES3A_PROOF|{sig} must be an internal function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)
tbl_list = ", ".join(f"'{t}'" for t in NEW_TABLES)

parts.append(f"""
CREATE TEMP TABLE mes3a_pending_after ON COMMIT DROP AS
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
         EXCEPT SELECT role_code || ':' || permission_code FROM mes3a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes3a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES3A_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes3a_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes3a_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES3A_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在两行引导上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes3a_pending_before b EXCEPT SELECT a.k, a.id FROM mes3a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes3a_pending_after a EXCEPT SELECT b.k, b.id FROM mes3a_pending_before b)) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes3a_log_before) AND c.table_name NOT IN ('inbound_safety_states', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|change_log moved on %', v_bad; END IF;

    -- ④ 新表与类别都是空的;没有一个库位被标成隔离、没有一个滞留天数、没有一种物料有类别;引导只是那两格;开关是空的
    SELECT string_agg(t, ', ') INTO v_bad FROM unnest(ARRAY[{tbl_list}]) t
     WHERE (xpath('/row/n/text()', query_to_xml(format('SELECT count(*) AS n FROM public.%I', t), false, true, '')))[1]::text <> '0';
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|new tables not empty: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine)
       OR EXISTS (SELECT 1 FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL)
       OR EXISTS (SELECT 1 FROM materials WHERE nea_waste_category_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a quarantine location, dwell period or category was set';
    END IF;
    IF (SELECT string_agg(code || '=' || COALESCE(requires_quarantine::text, 'null'), ',' ORDER BY code) FROM inbound_safety_states)
       IS DISTINCT FROM 'charged_not_discharged=null,damaged_deformed=null,discharged_verified=false,swollen_leaking=true,water_exposed=null' THEN
        RAISE EXCEPTION 'MES3A_PROOF|requires_quarantine bootstrap is not as ruled';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PROOF|require_calibrated_since must stay empty';
    END IF;

    -- ⑤ 两张状态表:原来的行一行不少、原样开着(批次、状态、记录时刻、记录人),没有一行结束
    IF EXISTS ((SELECT sb.k, sb.b, sb.c, sb.created_at, sb.created_by FROM mes3a_states_before sb
                EXCEPT
                SELECT 'inbound', inbound_batch_id, safety_state_code, created_at, created_by FROM inbound_batch_safety_states WHERE ended_at IS NULL
                EXCEPT
                SELECT 'output', output_batch_id, safety_state_code, created_at, created_by FROM output_batch_safety_states WHERE ended_at IS NULL)) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a safety-state row did not survive the re-key';
    END IF;
    IF EXISTS (SELECT 1 FROM inbound_batch_safety_states WHERE ended_at IS NOT NULL)
       OR EXISTS (SELECT 1 FROM output_batch_safety_states WHERE ended_at IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3A_PROOF|a safety state was ended by the migration';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到;旧的两支没了
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES3A_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    IF to_regprocedure('public.licence_storage_within_limit()') IS NOT NULL
       OR to_regprocedure('public.hazardous_qty_on_hand_tonnes()') IS NOT NULL
       OR to_regprocedure('public.set_inbound_safety_states(uuid, text[])') IS NOT NULL
       OR to_regprocedure('public.save_storage_location(text, text, text[], uuid, text, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES3A_PROOF|an old function or signature survived';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3A_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.nea_category_on_hand_all', 'SELECT') THEN
        RAISE EXCEPTION 'MES3A_PROOF|nea_category_on_hand_all must not be readable by authenticated';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条,没有一条落在新表上;两张状态表与库存流水上再没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3A_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('inbound_batch_safety_states', 'output_batch_safety_states', 'inventory_movements')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES3A_PROOF|a write policy remains on a state table or on inventory_movements';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表都记,豁免仍是 7);遮蔽零缺口(仍是 105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 7 THEN
        RAISE EXCEPTION 'MES3A_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3A_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 55 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES3A_PROOF|operations_now should have 55 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes3a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES3A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes3a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES3A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes3a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

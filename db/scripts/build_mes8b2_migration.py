#!/usr/bin/env python3
"""MES-8b-2(v1.4.58):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数、新视图与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(目录一行、角色一行、三行授权)在这里逐句写出,并先断言镜像里那几行真的是这个样子。
照抄 build_mes8b1_migration.py 的形状。
跑法:python3 db/scripts/build_mes8b2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-17-mes8b2-wall-display.sql"

NEW_TABLES = ["floor_board_settings"]
NEW_VIEWS = ["operations_arms_all"]
NEW_FUNCS = ["floor_board_arms", "floor_board", "session_is_floor_display_only", "set_floor_board_settings"]
# 同签名替换:F18
REPLACED_FUNCS = ["inventory_metal_exposure"]
REPLACED_VIEWS = ["operations_now", "pending_values"]

STAFF_SIGS = ["public.floor_board()",
              "public.session_is_floor_display_only()",
              "public.set_floor_board_settings(integer, text[])"]
PLAIN_SIGS = ["public.floor_board_arms()"]

CODE = "data.view_floor_board"
ROLE = "floor_display"
# MES-0 Q90:data.view_floor_board → floor_display · admin(每一个码都给 admin,常设裁定)· cfo(「CFO 读得到每一样东西」:每一个 data.view_*,
#   docs/role-matrix.md §13 —— 本刀的决定,写在交回报告里)
GRANTS = {CODE: ["admin", "cfo", ROLE]}
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]

# 前后比对的表(既有的行逐字未变)。目录、角色、授权只比本刀那几行以外的。
DIGEST_TABLES = {
    "inbound_batches": ("", []), "output_batches": ("", []), "inventory_movements": ("", []), "processing_runs": ("", []),
    "processing_inputs": ("", []), "processing_outputs": ("", []), "sales_records": ("", []),
    "metal_prices": ("", []), "inbound_batch_metals": ("", []), "output_batch_metals": ("", []),
    "substances": ("", []), "materials": ("", []), "material_kinds": ("", []),
    "journal_entries": ("", []), "journal_lines": ("", []), "payments": ("", []), "expenses": ("", []),
    "suppliers": ("", []), "purchase_orders": ("", []), "customers": ("", []), "stocktakes": ("", []),
    "incidents": ("", []), "environmental_results": ("", []), "inspection_templates": ("", []), "inspection_runs": ("", []),
    "inspection_findings": ("", []), "compliance_packs": ("", []), "compliance_settings": ("", []), "supplier_score_settings": ("", []),
    "certificates_of_destruction": ("", []), "cod_issues": ("", []), "approval_log": ("", []), "employees": ("", []),
    "permissions": (f"WHERE code <> '{CODE}'", []),
    "role_permissions": (f"WHERE permission_code <> '{CODE}'", []),
    "roles": (f"WHERE code <> '{ROLE}'", []),
    "user_roles": ("", []),
    "document_types": ("", []), "ingest_settings": ("", []), "finance_settings": ("", []), "safety_settings": ("", []),
}


def fn(name, create=False):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    if create:
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


def digest(t, where, drop):
    j = "to_jsonb(t)" + "".join(f" - '{k}'" for k in drop)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t {where})"


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
m = re.search(r"    \('data\.view_floor_board', 'data', .*?, 290\),", mirror("db/tables/permissions.sql"), re.S)
assert m, "permission row data.view_floor_board"
PERM_ROW = m.group(0).rstrip(",")
m = re.search(r"    \('floor_display', 'Floor display', .*?, false, 110\);", mirror("db/tables/roles.sql"), re.S)
assert m, "role row floor_display"
ROLE_ROW = m.group(0).rstrip(";")
must("db/tables/role_permissions.sql", "SELECT r.id, 'data.view_floor_board' FROM roles r WHERE r.code = 'floor_display';")

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m2 = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                   rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m2, t
    bind_sql.append(m2.group(0))
grants = mirror("db/views/zzz_function_grants.sql")
for sig in STAFF_SIGS + PLAIN_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" not in grants, sig
assert "'V28'::text AS value_code" in mirror("db/views/pending_values.sql")
assert mirror("db/views/operations_arms_all.sql").count("AS item_type") == 72
assert "FROM operations_arms_all a" in mirror("db/views/operations_now.sql")
assert "'kind_not_stated', v_kind_not_stated" in mirror("db/functions/inventory_metal_exposure.sql")

HEADER = """-- db/migrations/2026-10-17-mes8b2-wall-display.sql
-- MES-8b-2 —— 车间大屏:一个新的 floor_display 角色看一块只读的牌子(加工、安全与库存此刻各有几件事在等人 —— 只有数,没有钱、没有名字、
--   没有健康信息),只挂这个角色的屏空闲时不被登出,别的账号照旧;价格敞口页把物料种类没说的库存列出来,而不是丢掉(F18)。
--   (MES 组的第二十二刀,v1.4.58;发布那一行在 docs/handbacks/MES-8b-2.md 的抬头。)由 db/scripts/build_mes8b2_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-17:MES-8 Step 0 的 Q19 · Q20 · Q29,以及 Q21–Q24 里 8b-2 那一半,照推荐裁定;F18 与月结页 390 px 的并入)
--   ① 角色 floor_display(不是系统角色)与码 data.view_floor_board(data 类,不声明查看码)—— 授 floor_display · admin · cfo(三行);
--      本刀【不建任何账号】(Q29:一块屏一个账号,由 admin 经 /settings/accounts 建)。
--   ② 一张新表 floor_board_settings(单行;V28 = 自己刷新的间隔与画哪几块牌子,全空引导,两样一起给一起清)。
--   ③ 视图 operations_arms_all(operations_now 的全部支,不按读者过滤 —— 基视图,不给人读);operations_now 换成"它 + 按读者的那一句过滤"
--      (列、列序、每一行都与之前相同 —— 支的定义从此只有一份,floor_board() 从它计数)。
--   ④ 函数 floor_board_arms(大屏画哪 23 支,纯函数)· floor_board(只吐计数,门 data.view_floor_board)· session_is_floor_display_only
--      (空闲豁免与"别的页一律拒"的唯一判据)· set_floor_board_settings(给 / 清 V28,门 action.manage_permissions)。
--   ⑤ pending_values 加 V28 一支(有一个在用的大屏账号、设定有一样空着时一行;线上没有大屏账号 → 0 行)。
--   ⑥ F18:inventory_metal_exposure 把【物料种类没说】的在库批列进 kind_not_stated(代码与 kg),不估值,complete 因此为 false;
--      种类说了而不可投料的照旧不进来。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多上面那三行;不给任何物料定种类;不给 V28;不写、不改任何一批、任何流水、价、
--   含量、盘点、事故、巡检、分录、包、证书(两张已签发的 COD 的字节与档案一个字不动);不回填;require_calibrated_since 保持空。
--   线上由本迁移造出的只有:一个角色、一个码、三行授权、一张设定表(那一行全空)、一张基视图、四支函数,与 V28 那一支。
--
-- 【破窗】(Q23:这一窗什么都不坏)旧应用读 operations_now 的行与之前逐行相同;读 inventory_metal_exposure 多两个键(旧页面不认,
--   照旧不画种类没说的批 —— 就是今天的样子,直到部署);旧应用的待补值页不认 V28,但线上没有大屏账号,那一支一行都不出;
--   空闲豁免是【应用代码】(中间件),部署之前一个大屏会话仍会被登出 —— 线上没有这样的会话。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那三行,admin 持目录里每一个码(85);没有任何人挂 floor_display;
--   七个账号一个都没被停、角色一个没变,而且对它们每一个,session_is_floor_display_only() 都是假(空闲登出照旧);在途单据一张不少、一张不多,
--   每一张仍有一个不是它当事人的决定人;既有的行逐字未变(见 DIGEST_TABLES);anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 119);支 72(基视图)、待补的值 34 支;321 张表;
--   没有一张视图对 anon / authenticated 带写授权;基视图对 authenticated 关着;两张 COD 的存储对象一个字节不动。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

VIEW_WRITE_SQL = """(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')))"""

acct_list = ", ".join(f"'{a}'" for a in REAL_ACCOUNTS)

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子(开场读数,docs/surveys/MES-8b-2/live-readings.sql)──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES8B2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.floor_board_settings') IS NOT NULL OR to_regclass('public.operations_arms_all') IS NOT NULL
       OR to_regprocedure('public.floor_board()') IS NOT NULL OR to_regprocedure('public.session_is_floor_display_only()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM permissions WHERE code = '{CODE}') OR EXISTS (SELECT 1 FROM roles WHERE code = '{ROLE}') THEN
        RAISE EXCEPTION 'MES8B2_PRE|MES-8b-2 objects already exist';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 84
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected a catalogue of 84 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cfo') AND is_active AND deleted_at IS NULL) <> 2 THEN
        RAISE EXCEPTION 'MES8B2_PRE|the roles admin and cfo must exist and be active';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 63 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 63 document types';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 119 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 72 THEN
        RAISE EXCEPTION 'MES8B2_PRE|operations_now should have 72 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 33 THEN
        RAISE EXCEPTION 'MES8B2_PRE|pending_values should have 33 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 320 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected 320 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B2_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES8B2_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes8b2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes8b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes8b2_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes8b2_cod_objects_before ON COMMIT DROP AS
SELECT name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects WHERE bucket_id = 'cod-documents';
CREATE TEMP TABLE mes8b2_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新表(镜像原样):车间大屏的设定(V28,一行,全空)─────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

grant_sql = "".join(
    f"""INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, '{code}' FROM roles r WHERE r.code IN ({", ".join(f"'{x}'" for x in roles)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
""" for code, roles in GRANTS.items())
parts.append(f"""
-- ── 2 · 权限目录一行(与 db/tables/permissions.sql 逐字同一份)· 角色一行(与 db/tables/roles.sql 逐字同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROW};
INSERT INTO public.roles (code, name_en, name_zh, description_en, description_zh, is_system, sort_order) VALUES
{ROLE_ROW};

-- ── 3 · 授权(MES-0 Q90 · 常设裁定):data.view_floor_board → floor_display · admin · cfo —— 本刀唯一的授权改动(三行)──
{grant_sql}""")

parts.append("\n-- ── 4 · 基视图(镜像原样):operations_now 的全部支,不按读者过滤;不给人读 ──\n")
for v in NEW_VIEWS:
    parts.append(view(v))

parts.append("\n-- ── 5 · 新函数(镜像原样)──────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 6 · 换掉的函数(镜像原样,同签名):F18 —— 物料种类没说的在库批列出来,不再丢掉 ──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 7 · 换掉的视图(镜像原样):operations_now = 基视图 + 按读者的过滤;待补的值 +V28 ──\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append("\n-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + PLAIN_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes8b2_pending_decider_check")
parts.append("\n-- ── 10 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
plain_checks = "\n".join(
    f"""    IF (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|{sig}: expected a plain function, authenticated yes, anon no';
    END IF;""" for sig in PLAIN_SIGS)
digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes8b2_rows_before)" for t, (w, d) in DIGEST_TABLES.items())
holder_checks = "\n".join(
    f"""    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = '{code}';
    IF v_bad IS DISTINCT FROM '{",".join(sorted(roles))}' THEN
        RAISE EXCEPTION 'MES8B2_PROOF|{code} is held by % (ruled: {",".join(sorted(roles))})', COALESCE(v_bad, '<nobody>');
    END IF;""" for code, roles in GRANTS.items())
n_grants = sum(len(v) for v in GRANTS.values())

parts.append(f"""
CREATE TEMP TABLE mes8b2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
    a       record;
    v_ex    boolean;
BEGIN
    -- ① 授权:恰好多了那三行;目录 85 个码,admin 持每一个;floor_display 只持那一个;没有任何人挂 floor_display
    IF (SELECT count(*) FROM permissions) <> 85
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|admin does not hold every one of the 85 codes';
    END IF;
{holder_checks}
    IF (SELECT string_agg(rp.permission_code, ',') FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = '{ROLE}')
         IS DISTINCT FROM '{CODE}'
       OR (SELECT is_system OR NOT is_active FROM roles WHERE code = '{ROLE}') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|floor_display must be an active, non-system role holding exactly {CODE}';
    END IF;
    IF EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.id = ur.role_id WHERE r.code = '{ROLE}') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|no account may hold floor_display (Q29: an admin creates one per screen later)';
    END IF;
    SELECT string_agg(r.code || ':' || p.code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B2_PROOF|an action code is held without its declared view: %', v_bad;
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES8B2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes8b2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes8b2_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|an account or its roles changed';
    END IF;

    -- ③ 七个真账号:每一个的会话问 session_is_floor_display_only() 都是假 —— 空闲登出照旧(Q19:只有大屏豁免)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ({acct_list}) ORDER BY email LOOP
        PERFORM set_config('request.jwt.claims', format('{{"sub":"%s","role":"authenticated"}}', a.id), true);
        v_ex := session_is_floor_display_only();
        RAISE NOTICE 'MES8B2 idle-exempt % = %', a.email, v_ex;
        IF v_ex IS NOT FALSE THEN
            RAISE EXCEPTION 'MES8B2_PROOF|% would be exempt from the idle logout', a.email;
        END IF;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);

    -- ④ 在途单据一张不少、一张不多;既有的行逐字未变;两张 COD 的存储对象一个字节不动
    IF EXISTS ((SELECT b.k, b.id FROM mes8b2_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes8b2_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes8b2_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes8b2_pending_before b)) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES8B2_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS ((SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents'
                EXCEPT SELECT name, size, etag FROM mes8b2_cod_objects_before)
               UNION ALL
               (SELECT name, size, etag FROM mes8b2_cod_objects_before
                EXCEPT SELECT name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects WHERE bucket_id = 'cod-documents')) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|a COD object changed';
    END IF;

    -- ⑤ V28 那一行在、两样全空;线上没有大屏账号,所以 V28 那一支的条件不成立
    IF (SELECT count(*) FROM floor_board_settings) <> 1
       OR EXISTS (SELECT 1 FROM floor_board_settings WHERE refresh_seconds IS NOT NULL OR tiles IS NOT NULL) THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the settings row must exist with V28 empty (nothing is guessed)';
    END IF;

    -- ⑥ 本事务往变更记录只写了:目录一行、角色一行、三行授权、设定那一行(按 txid 认)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes8b2_log_before), 0) AND c.txid = txid_current()
       AND NOT (c.op = 'INSERT' AND c.table_name IN ('permissions', 'roles', 'role_permissions', 'floor_board_settings'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES8B2_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes8b2_log_before), 0) AND c.txid = txid_current()
          AND c.table_name = 'role_permissions') <> {n_grants} THEN
        RAISE EXCEPTION 'MES8B2_PROOF|expected exactly {n_grants} role_permissions rows written';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES8B2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:321 张表;支 72 在基视图里,operations_now 读基视图;基视图不给人读;待补的值 34 支;floor_board_arms 23 支、每一支都在基视图里
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 321 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|expected 321 public tables';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_arms_all'::regclass), 'AS item_type', 'g')) <> 72
       OR position('operations_arms_all' IN pg_get_viewdef('public.operations_now'::regclass)) = 0
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 34 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|arms 72 in the base view, operations_now reading it, pending-value arms 34 expected';
    END IF;
    IF has_table_privilege('authenticated', 'public.operations_arms_all', 'SELECT') OR has_table_privilege('anon', 'public.operations_arms_all', 'SELECT') THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the arms view must be readable by nobody but its owner';
    END IF;
    SELECT string_agg(f.item_type, ', ') INTO v_bad FROM floor_board_arms() f
     WHERE position(quote_literal(f.item_type) || '::text AS item_type' IN pg_get_viewdef('public.operations_arms_all'::regclass)) = 0;
    IF v_bad IS NOT NULL OR (SELECT count(*) FROM floor_board_arms()) <> 23 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the floor board lists an arm that does not exist: %', v_bad;
    END IF;

    -- ⑧ 匿名面与函数面
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES8B2_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{plain_checks}
    IF has_table_privilege('anon', 'public.floor_board_settings', 'SELECT') THEN RAISE EXCEPTION 'MES8B2_PROOF|anon can read floor_board_settings'; END IF;

    -- ⑨ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(新表记,豁免仍是 8);遮蔽零缺口(规则仍 119 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 119 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑫ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes8b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES8B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes8b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES8B2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes8b2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

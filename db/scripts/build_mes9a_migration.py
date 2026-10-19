#!/usr/bin/env python3
"""MES-9a(v1.4.60):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数、新视图与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(联系人那一列与一条约束、三张表上的守卫触发器、目录一行、两行授权、一个角色)
在这里逐句写出,并先断言镜像里那几行真的是这个样子。照抄 build_mes8b2_migration.py 的形状。
跑法:python3 db/scripts/build_mes9a_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql"

GUARD_FUNC = "guard_portal_account_separation"
NEW_TABLES = ["supplier_portal_users", "account_settings"]
NEW_FUNCS = ["portal_access_token_hook", "portal_require_link", "portal_me", "portal_export_my_data",
             "portal_user_create_link", "portal_user_revoke", "portal_contact_anonymise", "portal_actor_labels",
             "set_account_setting"]
REPLACED_FUNCS = ["change_log_redactable_columns", "trail_actor", "trail_subject_members"]
NEW_VIEWS = ["supplier_portal_accounts"]
REPLACED_VIEWS = ["pending_values", "user_directory"]

STAFF_SIGS = ["public.portal_user_create_link(uuid, uuid, uuid)", "public.portal_user_revoke(uuid, text)",
              "public.portal_contact_anonymise(uuid)", "public.portal_actor_labels(uuid[])", "public.set_account_setting(text, integer)"]
PORTAL_SIGS = ["public.portal_me()", "public.portal_export_my_data()"]
NOBODY_SIGS = ["public.portal_require_link()"]
HOOK_SIG = "public.portal_access_token_hook(jsonb)"

CODE = "action.manage_portal_users"
# MES-0 Q87 · MES-9 Step 0 Q7:admin(每一个码都给 admin,常设裁定)· cco
GRANTS = {CODE: ["admin", "cco"]}
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]

# 前后比对的表(既有的行逐字未变)。目录、授权只比本刀那几行以外的;联系人多出来的那一列(anonymised_at,全空)不进比对。
DIGEST_TABLES = {
    "suppliers": ("", []), "counterparty_contacts": ("", ["anonymised_at"]), "supplier_compliance": ("", []),
    "supplier_attachments": ("", []), "supplier_status_history": ("", []), "supplier_scorecard_reviews": ("", []),
    "customers": ("", []), "employees": ("", []), "employee_accounts": ("", []),
    "inbound_batches": ("", []), "purchase_orders": ("", []), "po_issues": ("", []), "cod_issues": ("", []),
    "certificates_of_destruction": ("", []), "supplier_statements": ("", []), "journal_entries": ("", []),
    "journal_lines": ("", []), "payments": ("", []), "expenses": ("", []), "approval_log": ("", []),
    "permissions": (f"WHERE code <> '{CODE}'", []),
    "role_permissions": (f"WHERE permission_code <> '{CODE}'", []),
    "roles": ("", []), "user_roles": ("", []),
    "finance_settings": ("", []), "ingest_settings": ("", []), "floor_board_settings": ("", []), "document_types": ("", []),
}


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    assert body.count("CREATE OR REPLACE FUNCTION") == 1, name
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
m = re.search(r"    \('action\.manage_portal_users', 'action', .*?, 1280\);", mirror("db/tables/permissions.sql"), re.S)
assert m, "permission row action.manage_portal_users"
PERM_ROW = m.group(0).rstrip(";")
must("db/tables/permissions.sql", "    ('action.manage_portal_users',      ARRAY['module.suppliers.view']),")
TRIGGERS = []
for path, name in (("db/tables/user_roles.sql", "trg_user_roles_not_portal_account"),
                   ("db/tables/employees.sql", "trg_employees_not_portal_account"),
                   ("db/tables/employee_accounts.sql", "trg_employee_accounts_not_portal_account")):
    m = re.search(rf"CREATE TRIGGER {name}\n.*?;\n", mirror(path), re.S)
    assert m, name
    TRIGGERS.append(m.group(0))
CONTACT_CHECK = "CHECK (email IS NOT NULL OR phone IS NOT NULL OR anonymised_at IS NOT NULL)"
must("db/tables/counterparty_contacts.sql", CONTACT_CHECK)
must("db/tables/counterparty_contacts.sql", "    anonymised_at  timestamptz\n);")

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m2 = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                   rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m2, t
    bind_sql.append(m2.group(0))
grants = mirror("db/views/zzz_function_grants.sql")
for line in ("REVOKE EXECUTE ON FUNCTION public.portal_me() FROM authenticated, service_role;",
             "GRANT EXECUTE ON FUNCTION public.portal_me() TO supplier_portal;",
             "REVOKE EXECUTE ON FUNCTION public.portal_require_link() FROM authenticated, service_role;",
             "GRANT EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) TO supabase_auth_admin;"):
    assert line in grants, line
assert "'V40'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "FROM supplier_portal_users p" in mirror("db/views/user_directory.sql")
assert "('supplier',            7, 'supplier_portal_users'" in mirror("db/functions/trail_subject_members.sql")
assert "'state', 'portal'" in mirror("db/functions/trail_actor.sql")
assert "WHEN 'counterparty_contacts' THEN" in mirror("db/functions/change_log_redactable_columns.sql")
assert "CREATE ROLE supplier_portal NOLOGIN NOINHERIT" in mirror("db/platform-prelude.sql")

HEADER = """-- db/migrations/2026-10-19-mes9a-supplier-portal-identity.sql
-- MES-9a —— 供应商门户的身份与隔离:admin 或 CCO 在供应商页上给一家供应商的一位联系人开一个门户登录;那个登录在库里是一个【单独的
--   Postgres 角色 supplier_portal】(Supabase Auth 的 access token hook 写进令牌),只够得着按名授给它的两支门户函数,看不见公司的任何内部东西;
--   初始密码当面交、第一次登录必须换;撤销立刻生效。员工的登录与空闲登出不变。(MES 组的第二十三刀,v1.4.60;发布那一行在
--   docs/handbacks/MES-9a.md 的抬头。)由 db/scripts/build_mes9a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-19:MES-9 Step 0 §15 —— Q1 切三刀、Q2 角色取代 MES-0 Q86、Q12 免费档、Q23 不要 MFA;其余 9a 那几条照推荐)
--   ① 角色 supplier_portal(NOLOGIN NOINHERIT,不是任何角色的成员)并授给 authenticator(PostgREST 要切得过去)。不另授任何架构 ——
--      public 的 USAGE 是 PostgreSQL 对 PUBLIC 的默认(Q27:只给干跑证明需要的;门户在 9a 不碰存储)。
--   ② 两张新表:supplier_portal_users(一个门户账号 = 一家供应商 + 它的一位联系人)· account_settings(V38 · V40,单行,全空)。
--   ③ counterparty_contacts 加一列 anonymised_at,"够得着"那条约束对已匿名化的联系人让路(Q20)。
--   ④ 守卫 guard_portal_account_separation 挂在四张表上:门户账号永远不持角色、不是员工;反过来也一样(Q5)。
--   ⑤ 函数:hook(只授 supabase_auth_admin;员工的令牌原样返回,里面失败也原样返回 —— 绝不抛)· portal_require_link(谁都不授)·
--      portal_me / portal_export_my_data(只授 supplier_portal)· 开 / 撤销 / 匿名化 / 显示标签 / V38·V40(员工那一侧,自己查码)。
--   ⑥ 码 action.manage_portal_users(声明 module.suppliers.view)—— 授 admin · cco(两行)。
--   ⑦ 视图 supplier_portal_accounts(供应商页那一块,module.suppliers.view);user_directory 不再列门户账号;pending_values 加 V38 · V40。
--   ⑧ 审计:trail_actor 认得门户账号(「Supplier portal — <供应商名>」);供应商的审计记录挂上门户链接;变更记录可以涂抹匿名化的联系人。
--
-- 【不做什么】不建任何门户账号(第一个真实供应商账号要等付费档、生产域名、V38 · V39 · V40 —— Step 0 §15);不建、不停、不改七个账号中的任何一个;
--   不碰审批开关;授权只多上面那两行;不碰任何存储桶与存储策略;不改任何既有的行(联系人只多一列空的);不回填;require_calibrated_since 保持空。
--   【hook 不由本迁移打开】它是 Supabase 的项目设置(Management API / 后台),在本迁移之后、证明了每一个员工的令牌原样之后才开 ——
--   见 docs/fresh-install-checklist.md 与交回报告;关掉它是一步。
--
-- 【破窗】这一窗什么都不坏:旧应用不读任何新东西;user_directory 少的只有门户账号(线上 0 个);pending_values 多两支(V38 · V40,读
--   action.manage_permissions —— 旧的待补值页照常把它们列出来,只是去处 /settings/accounts 上还没有那块面板,直到部署);hook 在部署之前打开时,
--   一个员工的令牌逐字节不变(自证 ③ 与开 hook 之后的逐账号登录检查),而线上没有门户账号。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了那两行,admin 持目录里每一个码(86);七个账号一个都没被停、角色一个没变,
--   而且对它们每一个,hook 返回的 event 与传进去的逐字节相同;没有任何门户账号;supplier_portal 能执行的恰好是两支门户函数、不是任何角色的成员、
--   由 authenticator 持有;hook 只给 supabase_auth_admin;在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;既有的行逐字未变;
--   anon 能执行的【恰好】两支;员工那几支 DEFINER、调得到;变更记录覆盖零缺口(豁免 8);待补的值 36 支;323 张表;没有一张视图对 anon /
--   authenticated 带写授权;存储策略仍是 52 条;两张 COD 的存储对象一个字节不动。断言失败 = 整笔回滚。

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
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES9A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.supplier_portal_users') IS NOT NULL OR to_regclass('public.account_settings') IS NOT NULL
       OR to_regprocedure('{HOOK_SIG}') IS NOT NULL OR EXISTS (SELECT 1 FROM permissions WHERE code = '{CODE}')
       OR EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supplier_portal') THEN
        RAISE EXCEPTION 'MES9A_PRE|MES-9a objects already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
        RAISE EXCEPTION 'MES9A_PRE|the platform roles authenticator / supabase_auth_admin are missing';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 85
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES9A_PRE|expected a catalogue of 85 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco') AND is_active AND deleted_at IS NULL) <> 2 THEN
        RAISE EXCEPTION 'MES9A_PRE|the roles admin and cco must exist and be active';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 321 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected 321 public tables';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 34 THEN
        RAISE EXCEPTION 'MES9A_PRE|pending_values should have 34 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 52 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected 52 storage policies';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9A_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'MES9A_PRE|expected the two recorded COD byte strings';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes9a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes9a_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes9a_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE mes9a_objects_before ON COMMIT DROP AS
SELECT bucket_id, name, metadata ->> 'size' AS size, metadata ->> 'eTag' AS etag FROM storage.objects;
CREATE TEMP TABLE mes9a_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("""
-- ── 1 · 角色:supplier_portal —— 不能登录、不继承、不是任何角色的成员;authenticator 持有它(PostgREST 按令牌切过去)──
CREATE ROLE supplier_portal NOLOGIN NOINHERIT;
GRANT supplier_portal TO authenticator;
""")

parts.append(f"""
-- ── 2 · 联系人:一列 anonymised_at,"够得着"那条约束对已匿名化的联系人让路(与 db/tables/counterparty_contacts.sql 同一句)──
ALTER TABLE public.counterparty_contacts ADD COLUMN anonymised_at timestamptz;
ALTER TABLE public.counterparty_contacts DROP CONSTRAINT counterparty_contacts_reachable;
ALTER TABLE public.counterparty_contacts ADD CONSTRAINT counterparty_contacts_reachable
    {CONTACT_CHECK};
""")

parts.append("\n-- ── 3 · 守卫(镜像原样):门户账号永远不持角色、不是员工;反过来也一样 ──\n")
parts.append(fn(GUARD_FUNC))

parts.append("\n-- ── 4 · 新表(镜像原样):门户链接 · 账号那一侧的待补的值(V38 · V40,一行,全空)──\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append("\n-- ── 5 · 既有三张表上的守卫触发器(与它们的镜像逐字同一句)──\n")
parts.append("\n".join(TRIGGERS))

grant_sql = "".join(
    f"""INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, '{code}' FROM roles r WHERE r.code IN ({", ".join(f"'{x}'" for x in roles)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
""" for code, roles in GRANTS.items())
parts.append(f"""
-- ── 6 · 权限目录一行(与 db/tables/permissions.sql 逐字同一份)+ 它声明的查看码 ──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROW};
UPDATE public.permissions SET requires_view_any = ARRAY['module.suppliers.view'] WHERE code = '{CODE}';

-- ── 7 · 授权(MES-0 Q87):action.manage_portal_users → admin · cco —— 本刀唯一的授权改动(两行)──
{grant_sql}""")

parts.append("\n-- ── 8 · 新函数(镜像原样)──────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 9 · 换掉的函数(镜像原样,同签名):涂抹名单 · 谁做的 · 供应商的审计记录 ──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 10 · 新视图与换掉的视图(镜像原样)──\n")
for v in NEW_VIEWS:
    parts.append(view(v))
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append("\n-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in PORTAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon, authenticated, service_role;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO supplier_portal;\n")
for sig in NOBODY_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon, authenticated, service_role;\n")
acl.append(f"REVOKE EXECUTE ON FUNCTION {HOOK_SIG} FROM PUBLIC, anon, authenticated, service_role;\n")
acl.append(f"GRANT EXECUTE ON FUNCTION {HOOK_SIG} TO supabase_auth_admin;\n")
acl.append(f"REVOKE EXECUTE ON FUNCTION public.{GUARD_FUNC}() FROM PUBLIC, anon;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes9a_pending_decider_check")
parts.append("\n-- ── 13 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('supplier_portal', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon and supplier_portal no';
    END IF;""" for sig in STAFF_SIGS)
digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM mes9a_rows_before)" for t, (w, d) in DIGEST_TABLES.items())
holder_checks = "\n".join(
    f"""    SELECT string_agg(r.code, ',' ORDER BY r.code) INTO v_bad FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
     WHERE rp.permission_code = '{code}';
    IF v_bad IS DISTINCT FROM '{",".join(sorted(roles))}' THEN
        RAISE EXCEPTION 'MES9A_PROOF|{code} is held by % (ruled: {",".join(sorted(roles))})', COALESCE(v_bad, '<nobody>');
    END IF;""" for code, roles in GRANTS.items())
n_grants = sum(len(v) for v in GRANTS.values())

parts.append(f"""
CREATE TEMP TABLE mes9a_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_ev    jsonb;
    k       text;
    a       record;
BEGIN
    -- ① 授权:恰好多了那两行;目录 86 个码,admin 持每一个;每一个动作码的持有人都持它声明的查看码
    IF (SELECT count(*) FROM permissions) <> 86
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|admin does not hold every one of the 86 codes';
    END IF;
{holder_checks}
    SELECT string_agg(r.code || ':' || p.code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES9A_PROOF|an action code is held without its declared view: %', v_bad;
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变;没有任何门户账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES9A_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM mes9a_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM mes9a_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|an account or its roles changed';
    END IF;
    IF EXISTS (SELECT 1 FROM supplier_portal_users) THEN RAISE EXCEPTION 'MES9A_PROOF|no portal account may exist'; END IF;

    -- ③ 七个真账号:hook 返回的 event 与传进去的逐字节相同(员工的令牌一个字节都不变)
    FOR a IN SELECT id, email FROM auth.users WHERE email IN ({acct_list}) ORDER BY email LOOP
        v_ev := jsonb_build_object('user_id', a.id, 'authentication_method', 'password',
                    'claims', jsonb_build_object('aud', 'authenticated', 'exp', 2000000000, 'iat', 1900000000, 'sub', a.id, 'email', a.email,
                                                 'phone', '', 'role', 'authenticated', 'aal', 'aal1', 'session_id', gen_random_uuid(),
                                                 'is_anonymous', false, 'app_metadata', jsonb_build_object('provider', 'email'),
                                                 'user_metadata', '{{}}'::jsonb, 'amr', '[]'::jsonb));
        v_j := portal_access_token_hook(v_ev);
        RAISE NOTICE 'MES9A hook % unchanged = %', a.email, (v_j = v_ev);
        IF v_j IS DISTINCT FROM v_ev THEN
            RAISE EXCEPTION 'MES9A_PROOF|the hook changed the claims of %', a.email;
        END IF;
    END LOOP;

    -- ④ 门户角色:不能登录、不继承、不绕过 RLS;不是任何角色的成员;authenticator 持有它;能执行的恰好是两支门户函数
    IF (SELECT rolcanlogin OR rolinherit OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = 'supplier_portal') THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal must be NOLOGIN NOINHERIT, no superuser / bypassrls / createrole / createdb';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_auth_members m WHERE m.member = 'supplier_portal'::regrole)
       OR NOT pg_has_role('authenticator', 'supplier_portal', 'MEMBER') THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal must be a member of nothing and held by authenticator';
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_export_my_data, portal_me' THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal executes: %', v_bad;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'public' AND has_table_privilege('supplier_portal', c.oid, 'SELECT,INSERT,UPDATE,DELETE')) THEN
        RAISE EXCEPTION 'MES9A_PROOF|supplier_portal holds a privilege on a public relation';
    END IF;
    IF NOT has_function_privilege('supabase_auth_admin', '{HOOK_SIG}', 'EXECUTE')
       OR has_function_privilege('authenticated', '{HOOK_SIG}', 'EXECUTE') OR has_function_privilege('anon', '{HOOK_SIG}', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.portal_require_link()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.portal_me()', 'EXECUTE') THEN
        RAISE EXCEPTION 'MES9A_PROOF|function grants on the hook / portal functions are wrong';
    END IF;
    IF NOT has_table_privilege('supabase_auth_admin', 'public.supplier_portal_users', 'SELECT') THEN
        RAISE EXCEPTION 'MES9A_PROOF|supabase_auth_admin cannot read supplier_portal_users (the hook would fall back for everyone)';
    END IF;

    -- ⑤ 在途单据一张不少、一张不多;既有的行逐字未变;存储对象一个都没动
    IF EXISTS ((SELECT b.k, b.id FROM mes9a_pending_before b EXCEPT SELECT a2.k, a2.id FROM mes9a_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM mes9a_pending_after a2 EXCEPT SELECT b.k, b.id FROM mes9a_pending_before b)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES9A_PROOF|a pre-existing row changed';
    END IF;
    IF EXISTS ((SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects
                EXCEPT SELECT bucket_id, name, size, etag FROM mes9a_objects_before)
               UNION ALL
               (SELECT bucket_id, name, size, etag FROM mes9a_objects_before
                EXCEPT SELECT bucket_id, name, metadata ->> 'size', metadata ->> 'eTag' FROM storage.objects)) THEN
        RAISE EXCEPTION 'MES9A_PROOF|a stored object changed';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 52 THEN
        RAISE EXCEPTION 'MES9A_PROOF|storage policies are no longer 52';
    END IF;

    -- ⑥ V38 · V40 那一行在、全空;两支待补的值从第一天起各一行
    IF (SELECT count(*) FROM account_settings) <> 1
       OR EXISTS (SELECT 1 FROM account_settings WHERE initial_password_valid_days IS NOT NULL OR password_min_length IS NOT NULL) THEN
        RAISE EXCEPTION 'MES9A_PROOF|account_settings must be one empty row';
    END IF;

    -- ⑦ 本事务往变更记录只写了:目录一行(新增与它的查看码)、两行授权、设定那一行(按 txid 认)
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes9a_log_before), 0) AND c.txid = txid_current()
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'account_settings'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES9A_PROOF|unexpected change_log rows: %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes9a_log_before), 0) AND c.txid = txid_current()
          AND c.table_name = 'role_permissions') <> {n_grants} THEN
        RAISE EXCEPTION 'MES9A_PROOF|expected exactly {n_grants} role_permissions rows written';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES9A_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑧ 结构:323 张表;待补的值 36 支
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 323 THEN
        RAISE EXCEPTION 'MES9A_PROOF|expected 323 public tables';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 36 THEN
        RAISE EXCEPTION 'MES9A_PROOF|pending-value arms 36 expected';
    END IF;

    -- ⑨ 匿名面与员工那几支函数
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES9A_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
    IF has_table_privilege('anon', 'public.supplier_portal_users', 'SELECT') OR has_table_privilege('anon', 'public.account_settings', 'SELECT') THEN
        RAISE EXCEPTION 'MES9A_PROOF|anon can read a new table';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(两张新表记,豁免仍是 8);遮蔽零缺口
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES9A_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'MES9A_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;

    -- ⑪ F16:没有一张视图对 anon / authenticated 带写授权
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'MES9A_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑫ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes9a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES9A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes9a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES9A_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes9a_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")

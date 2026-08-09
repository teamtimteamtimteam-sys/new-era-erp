#!/usr/bin/env python3
"""镜像漂移体检:把 db/tables + db/functions + db/views 整套重放进一个临时 schema,
与线上目录逐对象比对,报告漂移与覆盖缺口。

用法
    python3 db/check_mirrors.py            # 人类可读摘要
    python3 db/check_mirrors.py --json     # 完整 JSON 报告
退出码:0 = 全部一致;1 = 有漂移或覆盖缺口;2 = 执行失败(SQL 报错/连不上等)。

═══════════════════════════════════════════════════════════════════════════════
安全性 —— 这两段是本脚本的立身之本,改动本文件前先读懂:

1. 【回滚保证】整个重放 + 比对跑在【一个】事务里,脚本生成的 SQL 从不包含 COMMIT,
   末尾是显式 ROLLBACK;psql 以 ON_ERROR_STOP 运行,中途任何报错都会中断会话,
   而连接断开 = 事务中止 = 自动回滚。所以无论成功、失败还是半途被杀,线上库都
   不会留下任何东西(临时 schema、表、函数、种子行,统统随事务蒸发)。

2. 【CREATE OR REPLACE FUNCTION 陷阱】表镜像文件里【混着函数定义】(守卫触发器
   函数、code 生成函数……)。谁要是图省事把镜像文件直接灌进线上库"看看能不能跑",
   这些 CREATE OR REPLACE 会【当场覆盖同名线上函数】—— 若镜像恰好落后于线上,
   这一下就把漂移写进了生产,而且没有任何报错。本脚本因此把每个文件里的
   `public.` 全部改写为临时 schema 前缀后才执行,任何语句都不触碰 public 下的
   对象;比对时再把两侧的 schema 前缀归一化掉。【绝不要】绕过改写直接重放镜像。
═══════════════════════════════════════════════════════════════════════════════

方法概要
  * 重放顺序:先 db/functions(SET check_function_bodies=off,函数体不在创建时
    校验,故可先于表存在)→ 再 db/tables(按 FK / 跨表触发器依赖拓扑排序)→
    最后 db/views(按视图间引用排序)。
  * 比对维度:表 = 列(名/类型/可空/默认值/生成列/【列注释】,按 attnum 顺序)+ 约束 +
    索引 + 触发器 + RLS 开关 + 策略;函数 = pg_get_functiondef;视图 = pg_get_viewdef +
    reloptions(security_invoker)。
    【列注释为什么要比】OPS-1 的重建实验发现 7 条 COMMENT ON COLUMN 只存在于线上,
    镜像里一条都没有 —— 其中就有 HR-3b 那句界定"月固定工资总额不含加班"的说明。
    照镜像重建出来的库,那些说明【整条丢失】,而当时的检查看不见。注释是写在数据库里
    的规格说明,不是排版;它跟着列走,就该跟着列一起比。定义文本先把 schema 前缀(mir./public.)剥掉
    再比,因此文件里的排版、约束写法(IN vs = ANY)都不影响结果 —— 目录归一化
    之后是二元的:一致,或不一致。
  * 覆盖:public 里存在而重放结果里没有 = 缺镜像;反之 = 镜像的对象已不在线上。
    表/视图/函数/序列/枚举都查,双向。排除扩展自带的对象(pg_depend deptype 'e')。
  * 【种子行 / SEED ROWS】(OPS-1 增补)结构一致不等于装得起来 —— 照镜像重建出来的
    库曾经【一个会计科目都没有】,财务模块过不了任何一笔账,而本脚本一路是绿的。
    现在按 SEED_TABLES 清单逐行比对【安装种子】表(见该常量的分类规则):
      INSTALL SEED  —— 操作员在应用里【改不了】的行,与代码版本绑定 ⇒ 逐行比对线上。
      RUNTIME CONFIG —— 操作员改得了的行 ⇒ 镜像里的是"全新安装默认值",【不与线上比】。
  * 【镜像自洽 / INTEGRITY】(OPS-1 增补)不看线上,只看镜像这一套自己首尾相顾:
      - 每条 has_permission('X') 里的 X 必须在 permissions 的种子里;
      - role_permissions 种子引用的每个码必须在 permissions 的种子里;
      - 镜像里出现的每个科目字面量必须在 accounts 的种子里,【且必须打了 is_system】。
    这三条里的任何一条,单独就能抓住 OPS-1 那个 bug,而且完全不需要连线上。
  * 【看不见的东西 —— 这一条比"不比"更要紧】本脚本把镜像重放进【线上库里】的一个
    临时 schema(mir),并把文件里的 `public.` 改写成 `mir.`。于是任何【没有加架构
    前缀】的引用会顺着 search_path 落到【线上的 public】上,借到一个真实存在的对象,
    然后一路绿灯 —— 哪怕空库里根本没有它。
    实例:`RETURNS performance_reviews`(未加前缀)在这里解析到线上那张表,本脚本
    报"体检通过",而照镜像重建一个空库【当场失败】。
    能抓住这一类的只有 db/verify_rebuild.py —— 它真的建进一个空库,没有东西可借。
    所以【动了数据库的每一切,两个都要跑】。
  * 【不比】:约束名(只比定义)、GRANT、序列参数与当前值、表存储参数。文件级排版(如尾随换行)也不在此查 —— 目录里没有这个概念。

约定(与 AGENTS.md 呼应):动了表的迁移必须在【同一个提交】里更新该表的镜像;
拿不准就跑本脚本。
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCHEMA = "mir"  # 临时 schema 名;若与真实 schema 撞名请改(线上不该有叫这个的)

# 连接串:host/port/user/db 与 ~/evoltrya-backups/backup.sh 一致,密码走 ~/.pgpass。
# 需要指向别处时用环境变量 CHECK_MIRRORS_DSN 覆盖。
DEFAULT_DSN = (
    "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 "
    "user=postgres.wvywpohbwkiinmipmuku dbname=postgres"
)

MARKER = "<<<MIRROR_REPORT>>>"
SEED_MARKER = "<<<SEED_REPORT>>>"

# ═══════════════════════════════════════════════════════════════════════════
# 种子行清单。分类的判据【只有一句话】:操作员能不能通过应用的正常使用改动这些行?
#   不能 → INSTALL SEED:行与代码版本绑定,镜像逐行跟踪线上,不一致即失败。
#          这些表【只许迁移写】,db/scripts/ 的数据脚本永远不许碰 —— 于是
#          db/scripts/README.md 那句"脚本不涉及镜像"继续成立。
#   能   → RUNTIME CONFIG:线上理应与文件不同,那是系统在正常工作。不比对。
# 判据要有证据(哪个页面 / RPC / 脚本在写),不靠直觉。证据见各镜像文件的抬头。
# ═══════════════════════════════════════════════════════════════════════════
SEED_TABLES = {
    # table: (WHERE 子句 or None, 比对的列)
    "permissions": (None, "code, category, name_en, name_zh, "
                          "COALESCE(description_en,'') AS description_en, "
                          "COALESCE(description_zh,'') AS description_zh, sort_order"),
    "currencies":  (None, "code, name, is_base"),
    # accounts 是【混合表】:引擎点名的 22 行跟踪线上,其余是建账的人的地盘。
    # FIN-30:is_cash / cash_flow_section 也纳入比对 —— 它们决定现金流量表取哪些
    # 科目、归哪一段;线上被人翻了标记而无人察觉,报表会安静地算错一整类活动。
    "accounts":    ("is_system", "code, name_en, name_zh, account_type, is_system, "
                                 "is_cash, COALESCE(cash_flow_section,'') AS cash_flow_section"),
}

RUNTIME_CONFIG_TABLES = [
    "roles", "role_permissions", "leave_types", "public_holidays",
    "review_rating_scale", "company_profile", "finance_settings", "hr_settings",
    # HR-2c:HR 会在界面上加 override 行(一份谈定的年假是合同条款),
    # 逐行跟踪线上会让第一个 override 就把 check_mirrors 变红,那样这个检查就没人信了。
    "leave_accrual_rates",
]

# 【引导默认值一行都不许是空的】RUNTIME CONFIG 的种子不与线上比对(那是对的:界面改得动),
# 但"不比对"把另一类失败也一起藏了起来 —— 一条 INSERT ... SELECT 只要 WHERE 不再匹配,
# 就会【安安静静地插入零行】,不报错、不漂移。实测:把 role_permissions 里 admin 的
# 那条 WHERE 改成一个错的角色码,重建出来的库管理员一个权限都没有,而本脚本报"体检通过"。
# 所以对每张 RUNTIME CONFIG 表:重放之后行数必须 > 0。
# 若将来某张表【确实】应当空着引导,把它写进下面这个集合,让那件事是一次明写的决定。
BOOTSTRAP_MAY_BE_EMPTY: set = set()

# ═══════════════════════════════════════════════════════════════════════════
# 【SECURITY DEFINER 必须自己查调用者】(OPS-3)
# DEFINER 函数以属主身份运行,而 public 架构里的函数默认把 EXECUTE 授给 PUBLIC ——
# 所以"内部函数"只是命名上内部,任何登录用户都调得到。OPS-3 实测:七个假期函数
# 让零权限员工读到了别人的余额,而对外的包装函数是拒绝的。
#
# 这个扫描【只看得见有没有"像样的检查"】,看不见检查得对不对:
#   * 认得出:require_permission( / has_permission( / current_user_employee( /
#             is_reviewer_of( / require_reviewer_of( / require_leave_visibility(
#   * 认不出:检查写错了对象、检查了却没 RAISE、状态门当权限用(OPS-3 叫它"(e) 侥幸")
# 所以它是一张网,不是一份证明。放行项必须写进下面的名单并说明理由。
DEFINER_NO_CHECK_ALLOWED = {
    # 权限判断本身的原语 —— 它们就是"检查",不可能再检查自己
    "has_permission": "the permission check itself",
    "current_user_permissions": "resolves the caller's own permission set",
    "current_user_employee": "resolves the caller's own employee row",
    "is_reviewer_of": "the identity check itself",
    "require_permission": "raises on behalf of its callers",
    "require_reviewer_of": "raises on behalf of its callers",
    # 触发器函数:返回 trigger,调不动;闸门是触发它的那次基表写入(perm2a 的设计)
    # —— 由返回类型自动排除,不需要列在这里。
    # 已收回 EXECUTE 的内层函数(ACL 里没有 PUBLIC 项)
    "calculate_metal_price_internal": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "reverse_journal_entry_internal": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # FIN-27 的内层算子:条款解析、计价算术、承诺写入。同上,靠"调不到"而非"查调用者"
    "pricing_terms_of_formula": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "pricing_terms_of_commitment": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "calculate_metal_price_from_terms": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "commit_pricing_terms": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "resolve_pricing_commitment": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "committed_terms_price": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # APR-1:审批留痕的唯一写入口。同上 —— 靠"调不到"而非"查调用者":它只从五个
    # 各自已把过关的 HR 决定函数体内以属主身份被调用。给了 authenticated 就等于
    # 任何登录用户都能伪造一行留痕。
    "record_approval_decision": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # APR-2:审批引擎的内层算子。同上 —— 靠"调不到"而非"查调用者";
    # 公开入口 approve_purchase_order / reject_purchase_order 各自 require_permission。
    "approval_level_for": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "require_approver_for": "EXECUTE revoked from PUBLIC/authenticated/anon",
}

CHECK_PATTERNS = ("require_permission(", "has_permission(", "current_user_employee(",
                  "is_reviewer_of(", "require_reviewer_of(")


def definer_without_caller_check() -> list:
    """扫 db/functions:SECURITY DEFINER 且看不出任何调用者检查的函数。"""
    bad = []
    for f in sorted((REPO / "db" / "functions").glob("*.sql")):
        txt = f.read_text()
        for m in re.finditer(r"CREATE OR REPLACE FUNCTION\s+public\.([a-z0-9_]+)\s*\((.*?)\)\s*\n(.*?)(?=\nCREATE OR REPLACE FUNCTION|\Z)",
                             txt, re.S):
            name, body = m.group(1), m.group(3)
            if "SECURITY DEFINER" not in body:
                continue
            if re.search(r"\bRETURNS\s+trigger\b", body, re.I):
                continue          # 触发器函数:闸门是基表写入
            if name in DEFINER_NO_CHECK_ALLOWED:
                continue
            if any(p in body for p in CHECK_PATTERNS):
                continue
            bad.append(f"{name}  ({f.name})")
    return sorted(set(bad))

# 科目字面量扫描的例外名单。【只放误伤,不放"懒得处理"】,每条必须写明理由。
# 空着是对的 —— 现在一条都不需要。
ACCOUNT_LITERAL_ALLOWLIST = {
    # "1234": "reason why this four-digit literal is not an account code",
}


def account_codes_in_text(sql: str) -> set:
    """一段 SQL 里【引用到的科目码】。注释行不算 —— 注释里提一句不是依赖。

    【本仓库里科目码的判据只有这一处】正则与例外名单都在这里。OPS-7 的迁移预检
    (db/preflight_migration.py)导入它,不另写第二份 —— 两份判据迟早会各说各话,
    而那正是"再检查一遍"这类提醒失效的方式。
    """
    out = set()
    for line in sql.splitlines():
        if line.lstrip().startswith("--"):
            continue
        out.update(re.findall(r"'(\d{4})'", line))
    return out - set(ACCOUNT_LITERAL_ALLOWLIST)


def scan_literals() -> dict:
    """扫描镜像文件里的三类字面量。注释行不算 —— 注释里提一句不是依赖。"""
    perms, accounts, roles = set(), set(), set()
    for sub in ("functions", "views", "tables"):
        for f in sorted((REPO / "db" / sub).glob("*.sql")):
            txt = f.read_text()
            for line in txt.splitlines():
                if line.lstrip().startswith("--"):
                    continue
                perms.update(re.findall(r"has_permission\(\s*'([^']+)'", line))
                perms.update(re.findall(r"require_permission\(\s*'([^']+)'", line))
            # 科目码:定义科目表的那个文件不算"引用"—— FIN-3-fu2 的引导默认值
            # (非 is_system 的整套科目)就住在 accounts.sql 的种子里,把种子行
            # 当引擎引用会逼着给权益科目打 is_system。引擎引用都在函数/视图里。
            if f.name != "accounts.sql":
                accounts |= account_codes_in_text(txt)
    # role_permissions 种子里 IN (...) 与 p.code = '...' 引用到的码
    rp = (REPO / "db" / "tables" / "role_permissions.sql").read_text()
    rp = "\n".join(l for l in rp.splitlines() if not l.lstrip().startswith("--"))
    perms.update(re.findall(r"'((?:module|data|action)\.[a-z_.]+)'", rp))
    # 【外键的另一侧】OPS-1 加了"授权引用的权限码必须存在",却没加对称的那一条:
    # 授权引用的【角色码】也必须存在。少了它,把 WHERE r.code = 'admin' 打错成
    # 'admin_TYPO' 会安安静静地少插 33 行,重建出来的库管理员一个权限都没有,
    # 而行数仍然大于零,所以连"引导不能为空"那条也拦不住。实测确认过。
    roles.update(re.findall(r"r\.code\s*=\s*'([^']+)'", rp))
    for grp in re.findall(r"r\.code\s+IN\s*\(([^)]*)\)", rp):
        roles.update(re.findall(r"'([^']+)'", grp))
    return {"permission_codes": sorted(perms), "account_codes": sorted(accounts),
            "role_codes": sorted(roles)}


def rewrite(sql: str) -> str:
    """把文件里的 public. 全部指到临时 schema —— 见文件头【安全性】第 2 条。

    另:pg_get_functiondef 的原样输出【不带结尾分号】(单函数镜像文件按约定就是
    原样字节),拼接重放时必须补上,否则下一条语句会被吞进同一条里报语法错。
    只补"整行恰为 $function$"的行,已带分号的文件不受影响。
    """
    sql = re.sub(r"^\$function\$$", "$function$;", sql, flags=re.M)
    return sql.replace("public.", f"{SCHEMA}.")


def created_tables(sql: str) -> set:
    return set(re.findall(r"CREATE TABLE\s+public\.([a-z0-9_]+)", sql, re.I))


def table_deps(sql: str, own: set, all_tables: set) -> set:
    """本文件依赖哪些【别的文件创建的】表:FK 引用 + 挂在别的表上的触发器。"""
    refs = set(re.findall(r"REFERENCES\s+public\.([a-z0-9_]+)", sql, re.I))
    refs |= set(re.findall(r"ON\s+public\.([a-z0-9_]+)", sql, re.I))
    return (refs & all_tables) - own


def toposort(files: dict) -> list:
    """files: path -> (own_tables, dep_tables)。Kahn,按文件名保证确定性。"""
    owner = {}
    for f, (own, _) in files.items():
        for t in own:
            owner[t] = f
    edges = {f: sorted({owner[d] for d in deps if d in owner} - {f}) for f, (_, deps) in files.items()}
    order, placed = [], set()
    pending = sorted(files)
    while pending:
        progressed = False
        for f in list(pending):
            if all(d in placed for d in edges[f]):
                order.append(f)
                placed.add(f)
                pending.remove(f)
                progressed = True
        if not progressed:
            sys.exit(f"表镜像之间存在循环依赖,无法排序:{pending}")
    return order


def build_sql() -> str:
    fn_files = sorted((REPO / "db" / "functions").glob("*.sql"))
    tbl_files = sorted((REPO / "db" / "tables").glob("*.sql"))
    view_files = sorted((REPO / "db" / "views").glob("*.sql"))

    tbl_txt = {f: f.read_text() for f in tbl_files}
    all_tables = set().union(*(created_tables(t) for t in tbl_txt.values()))
    tbl_meta = {
        f: (created_tables(t), table_deps(t, created_tables(t), all_tables))
        for f, t in tbl_txt.items()
    }
    tbl_order = toposort(tbl_meta)

    # 视图排序:正文里引用了别的视图名的排后面(目前仅一层,通用写法防患未然)
    view_txt = {f: f.read_text() for f in view_files}
    view_names = {f.stem for f in view_files}
    view_order = sorted(
        view_files,
        key=lambda f: (len([v for v in view_names - {f.stem} if re.search(rf"\b{v}\b", view_txt[f])]), f.name),
    )

    parts = [
        "BEGIN;",
        f"CREATE SCHEMA {SCHEMA};",
        "SET LOCAL check_function_bodies = off;",
        f"SET LOCAL search_path = {SCHEMA}, public;",
    ]
    for f in fn_files:
        parts.append(f"-- ═══ replay {f.relative_to(REPO)} ═══")
        parts.append(rewrite(f.read_text()))
    for f in tbl_order:
        parts.append(f"-- ═══ replay {f.relative_to(REPO)} ═══")
        parts.append(rewrite(tbl_txt[f]))
    for f in view_order:
        parts.append(f"-- ═══ replay {f.relative_to(REPO)} ═══")
        parts.append(rewrite(view_txt[f]))

    compare = COMPARE_SQL.replace("'mir'", f"'{SCHEMA}'").replace("'mir.'", f"'{SCHEMA}.'")
    parts.append(compare)
    parts.append(seed_sql())
    parts.append("ROLLBACK;")  # 万无一失:正常路径也显式回滚(本脚本永不 COMMIT)
    return "\n".join(parts)


# 比对查询:一个 SELECT 产出整份 jsonb 报告。norm() 剥掉 schema 前缀再比。
COMPARE_SQL = r"""
SELECT '""" + MARKER + r"""' || (
WITH
norm AS (SELECT 1),  -- 占位,归一化直接内联 replace(replace(x,'mir.',''),'public.','')
live_tables AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
mir_tables AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'mir' AND c.relkind = 'r'),
tbl_sig AS (
  SELECT ns.nspname AS sch, c.relname, jsonb_build_object(
    'columns', (SELECT jsonb_agg(a.attname || ' | ' || replace(replace(format_type(a.atttypid, a.atttypmod),'mir.',''),'public.','')
                       || ' | ' || CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE 'NULL' END
                       || ' | ' || COALESCE(replace(replace(pg_get_expr(d.adbin, d.adrelid),'mir.',''),'public.',''), '')
                       -- 列注释是写在库里的规格说明;镜像丢了它,重建出来的库就少了那句话。
                       || ' | comment=' || COALESCE(col_description(c.oid, a.attnum), '-')
                       ORDER BY a.attnum)
       FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
       WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
    'constraints', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT replace(replace(pg_get_constraintdef(oid),'mir.',''),'public.','') x
        FROM pg_constraint WHERE conrelid = c.oid) s),
    'indexes', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT replace(replace(pg_get_indexdef(indexrelid),'mir.',''),'public.','') x
        FROM pg_index WHERE indrelid = c.oid) s),
    'triggers', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT replace(replace(pg_get_triggerdef(oid),'mir.',''),'public.','') x
        FROM pg_trigger WHERE tgrelid = c.oid AND NOT tgisinternal) s),
    'rls', c.relrowsecurity,
    'policies', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT polname || ' | ' || polpermissive::text || ' | ' || polcmd::text
               || ' | ' || COALESCE((SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles WHERE oid = ANY (polroles)), '-')
               || ' | ' || COALESCE(replace(replace(pg_get_expr(polqual, polrelid),'mir.',''),'public.',''), '-')
               || ' | ' || COALESCE(replace(replace(pg_get_expr(polwithcheck, polrelid),'mir.',''),'public.',''), '-') x
        FROM pg_policy WHERE polrelid = c.oid) s)
  ) AS sig
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
  WHERE ns.nspname IN ('public', 'mir') AND c.relkind = 'r'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
tbl_drift AS (
  SELECT l.relname, (SELECT jsonb_object_agg(k.key, jsonb_build_object('live', l.sig->k.key, 'mirror', m.sig->k.key))
                     FROM jsonb_object_keys(l.sig) k(key)
                     WHERE l.sig->k.key IS DISTINCT FROM m.sig->k.key) AS diff
  FROM tbl_sig l JOIN tbl_sig m ON m.relname = l.relname AND m.sch = 'mir'
  WHERE l.sch = 'public' AND l.sig IS DISTINCT FROM m.sig),
live_fns AS (
  SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig,
         replace(replace(pg_get_functiondef(p.oid),'mir.',''),'public.','') AS def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')),
mir_fns AS (
  SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig,
         replace(replace(pg_get_functiondef(p.oid),'mir.',''),'public.','') AS def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'mir' AND p.prokind = 'f'),
live_views AS (
  SELECT c.relname,
         replace(replace(pg_get_viewdef(c.oid, true),'mir.',''),'public.','') AS def,
         COALESCE(array_to_string(c.reloptions, ','), '') AS opts
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'v'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
mir_views AS (
  SELECT c.relname,
         replace(replace(pg_get_viewdef(c.oid, true),'mir.',''),'public.','') AS def,
         COALESCE(array_to_string(c.reloptions, ','), '') AS opts
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'mir' AND c.relkind = 'v'),
live_seqs AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'S'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
mir_seqs AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'mir' AND c.relkind = 'S'),
live_enums AS (
  SELECT t.typname, (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid) AS labels
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typtype = 'e'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')),
mir_enums AS (
  SELECT t.typname, (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid) AS labels
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'mir' AND t.typtype = 'e')
SELECT jsonb_build_object(
  'summary', jsonb_build_object(
     'tables',    jsonb_build_object('live', (SELECT count(*) FROM live_tables), 'mirrored', (SELECT count(*) FROM mir_tables),
                                     'drifted', (SELECT count(*) FROM tbl_drift)),
     'functions', jsonb_build_object('live', (SELECT count(*) FROM live_fns), 'mirrored', (SELECT count(*) FROM mir_fns),
                                     'drifted', (SELECT count(*) FROM live_fns l JOIN mir_fns m USING (sig) WHERE l.def <> m.def)),
     'views',     jsonb_build_object('live', (SELECT count(*) FROM live_views), 'mirrored', (SELECT count(*) FROM mir_views),
                                     'drifted', (SELECT count(*) FROM live_views l JOIN mir_views m USING (relname)
                                                 WHERE l.def <> m.def OR l.opts <> m.opts))),
  'table_drift', COALESCE((SELECT jsonb_object_agg(relname, diff) FROM tbl_drift), '{}'::jsonb),
  'function_drift', COALESCE((SELECT jsonb_object_agg(l.sig, 'definition differs')
                              FROM live_fns l JOIN mir_fns m USING (sig) WHERE l.def <> m.def), '{}'::jsonb),
  'view_drift', COALESCE((SELECT jsonb_object_agg(l.relname,
                              CASE WHEN l.def <> m.def THEN 'definition differs' ELSE 'options differ: ' || l.opts || ' vs ' || m.opts END)
                          FROM live_views l JOIN mir_views m USING (relname)
                          WHERE l.def <> m.def OR l.opts <> m.opts), '{}'::jsonb),
  'coverage', jsonb_build_object(
     'tables_without_mirror',      COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM live_tables WHERE relname NOT IN (SELECT relname FROM mir_tables)), '[]'::jsonb),
     'mirrors_without_live_table', COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM mir_tables  WHERE relname NOT IN (SELECT relname FROM live_tables)), '[]'::jsonb),
     'functions_without_mirror',   COALESCE((SELECT jsonb_agg(sig ORDER BY sig) FROM live_fns WHERE sig NOT IN (SELECT sig FROM mir_fns)), '[]'::jsonb),
     'mirrors_without_live_fn',    COALESCE((SELECT jsonb_agg(sig ORDER BY sig) FROM mir_fns  WHERE sig NOT IN (SELECT sig FROM live_fns)), '[]'::jsonb),
     'views_without_mirror',       COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM live_views WHERE relname NOT IN (SELECT relname FROM mir_views)), '[]'::jsonb),
     'mirrors_without_live_view',  COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM mir_views  WHERE relname NOT IN (SELECT relname FROM live_views)), '[]'::jsonb),
     'sequences_without_mirror',   COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM live_seqs WHERE relname NOT IN (SELECT relname FROM mir_seqs)), '[]'::jsonb),
     'mirrors_without_live_seq',   COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM mir_seqs  WHERE relname NOT IN (SELECT relname FROM live_seqs)), '[]'::jsonb),
     'enums_without_mirror',       COALESCE((SELECT jsonb_agg(typname ORDER BY typname) FROM live_enums WHERE typname NOT IN (SELECT typname FROM mir_enums)), '[]'::jsonb),
     'mirrors_without_live_enum',  COALESCE((SELECT jsonb_agg(typname ORDER BY typname) FROM mir_enums  WHERE typname NOT IN (SELECT typname FROM live_enums)), '[]'::jsonb),
     'enum_label_drift',           COALESCE((SELECT jsonb_object_agg(l.typname, jsonb_build_object('live', l.labels, 'mirror', m.labels))
                                             FROM live_enums l JOIN mir_enums m USING (typname) WHERE l.labels <> m.labels), '{}'::jsonb))
))::text AS report;
"""


def seed_sql() -> str:
    """种子行 + 镜像自洽,一条 SELECT 一份 jsonb 报告。"""
    lit = scan_literals()
    perm_arr = "ARRAY[" + ",".join(f"'{c}'" for c in lit["permission_codes"]) + "]::text[]" \
        if lit["permission_codes"] else "ARRAY[]::text[]"
    acct_arr = "ARRAY[" + ",".join(f"'{c}'" for c in lit["account_codes"]) + "]::text[]" \
        if lit["account_codes"] else "ARRAY[]::text[]"
    role_arr = "ARRAY[" + ",".join(f"'{c}'" for c in lit["role_codes"]) + "]::text[]" \
        if lit["role_codes"] else "ARRAY[]::text[]"

    blocks = []
    for tbl, (where, cols) in SEED_TABLES.items():
        w = f" WHERE {where}" if where else ""
        blocks.append(f"""
    '{tbl}', (
      WITH l AS (SELECT to_jsonb(x) j FROM (SELECT {cols} FROM public.{tbl}{w}) x),
           m AS (SELECT to_jsonb(x) j FROM (SELECT {cols} FROM {SCHEMA}.{tbl}{w}) x)
      SELECT jsonb_build_object(
        'live_rows',   (SELECT count(*) FROM l),
        'mirror_rows', (SELECT count(*) FROM m),
        'missing_from_mirror', COALESCE((SELECT jsonb_agg(j ORDER BY j::text) FROM (SELECT j FROM l EXCEPT SELECT j FROM m) s), '[]'::jsonb),
        'extra_in_mirror',     COALESCE((SELECT jsonb_agg(j ORDER BY j::text) FROM (SELECT j FROM m EXCEPT SELECT j FROM l) s), '[]'::jsonb))
    )""")

    integ = (
        "  'integrity', jsonb_build_object(\n"
        f"    'permission_codes_referenced', array_length({perm_arr}, 1),\n"
        f"    'permission_codes_missing_from_seed', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({perm_arr}) c "
        f"WHERE c NOT IN (SELECT code FROM {SCHEMA}.permissions)), '[]'::jsonb),\n"
        f"    'account_codes_referenced', array_length({acct_arr}, 1),\n"
        f"    'account_codes_missing_from_seed', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({acct_arr}) c "
        f"WHERE c NOT IN (SELECT code FROM {SCHEMA}.accounts)), '[]'::jsonb),\n"
        # 【自维护的那一条】被代码点名、线上存在、却没打 is_system 的科目 = 名单漏了一个。
        # 宁可多打标记也不能漏 —— 漏掉的那一个正是 OPS-1 这个 bug 换一层楼重演。
        f"    'account_codes_referenced_but_not_is_system', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({acct_arr}) c "
        f"WHERE EXISTS (SELECT 1 FROM public.accounts a WHERE a.code = c AND NOT a.is_system)), '[]'::jsonb),\n"
        f"    'role_codes_referenced', array_length({role_arr}, 1),\n"
        f"    'role_codes_missing_from_seed', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({role_arr}) c "
        f"WHERE c NOT IN (SELECT code FROM {SCHEMA}.roles)), '[]'::jsonb)\n"
        "  )"
    )
    boot = ",".join(
        f"'{t}', (SELECT count(*) FROM {SCHEMA}.{t})" for t in sorted(RUNTIME_CONFIG_TABLES))
    return ("SELECT '" + SEED_MARKER + "' || (SELECT jsonb_build_object(\n"
            "  'seed', jsonb_build_object(" + ",".join(blocks) + "\n  ),\n"
            "  'bootstrap', jsonb_build_object(" + boot + "),\n"
            + integ + "))::text AS seed_report;\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="输出完整 JSON 报告")
    ap.add_argument("--dsn", default=None, help="覆盖连接串(默认走 CHECK_MIRRORS_DSN 或内置值)")
    args = ap.parse_args()

    import os
    dsn = args.dsn or os.environ.get("CHECK_MIRRORS_DSN") or DEFAULT_DSN

    sql = build_sql()
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as tf:
        tf.write(sql)
        script = tf.name

    proc = subprocess.run(
        ["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-t", "-A", "-f", script],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.stderr.write(f"\n重放失败(线上库未被改动 —— 见文件头【回滚保证】)。生成的 SQL 留在:{script}\n")
        return 2

    report = seed = None
    for line in proc.stdout.splitlines():
        if line.startswith(MARKER):
            report = json.loads(line[len(MARKER):])
        elif line.startswith(SEED_MARKER):
            seed = json.loads(line[len(SEED_MARKER):])
    if report is None or seed is None:
        sys.stderr.write("没有在输出里找到报告标记 —— psql 输出异常。\n")
        return 2
    report["seed"] = seed["seed"]
    report["integrity"] = seed["integrity"]
    report["bootstrap"] = seed["bootstrap"]

    Path(script).unlink(missing_ok=True)

    seed_dirty = any(v["missing_from_mirror"] or v["extra_in_mirror"]
                     for v in report["seed"].values())
    unchecked = definer_without_caller_check()
    empty_bootstraps = sorted(t for t, n in report["bootstrap"].items()
                              if n == 0 and t not in BOOTSTRAP_MAY_BE_EMPTY)
    integ_dirty = any(report["integrity"][k] for k in (
        "permission_codes_missing_from_seed",
        "account_codes_missing_from_seed",
        "account_codes_referenced_but_not_is_system",
        "role_codes_missing_from_seed"))
    dirty = (
        report["table_drift"] or report["function_drift"] or report["view_drift"]
        or any(v for v in report["coverage"].values())
        or seed_dirty or integ_dirty or empty_bootstraps or unchecked
    )

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        s = report["summary"]
        print(f"tables    live {s['tables']['live']:3d}  mirrored {s['tables']['mirrored']:3d}  drifted {s['tables']['drifted']}")
        print(f"functions live {s['functions']['live']:3d}  mirrored {s['functions']['mirrored']:3d}  drifted {s['functions']['drifted']}")
        print(f"views     live {s['views']['live']:3d}  mirrored {s['views']['mirrored']:3d}  drifted {s['views']['drifted']}")
        # 【种子行的覆盖面要在每次输出里看得见】—— 不然"比了什么"又变成一个没人查的假设。
        for tbl in sorted(report["seed"]):
            v = report["seed"][tbl]
            bad = len(v["missing_from_mirror"]) + len(v["extra_in_mirror"])
            print(f"seed:{tbl:<11s} live {v['live_rows']:3d}  mirrored {v['mirror_rows']:3d}  drifted {bad}")
        ig = report["integrity"]
        print(f"integrity  permission codes {ig['permission_codes_referenced'] or 0:3d}"
              f"  role codes {ig['role_codes_referenced'] or 0:3d}"
              f"  account codes {ig['account_codes_referenced'] or 0:3d}"
              f"  unresolved {len(ig['permission_codes_missing_from_seed']) + len(ig['account_codes_missing_from_seed']) + len(ig['account_codes_referenced_but_not_is_system']) + len(ig['role_codes_missing_from_seed'])}")
        # 引导默认值【不与线上比对】,但要看得见它到底装进去了多少行 ——
        # 一个悄悄变成零行的引导,是这套豁免唯一藏得住的失败。
        print(f"definer    {len(unchecked)} SECURITY DEFINER function(s) with no recognisable caller check"
              f"  ({len(DEFINER_NO_CHECK_ALLOWED)} allowlisted, trigger functions excluded by return type)")
        print("bootstrap  (runtime config, not compared against live; rows must be > 0)")
        print("           " + "  ".join(f"{t}={report['bootstrap'][t]}"
                                        for t in sorted(report["bootstrap"])))
        for section in ("table_drift", "function_drift", "view_drift"):
            for k, v in report[section].items():
                print(f"  DRIFT [{section}] {k}: {json.dumps(v, ensure_ascii=False)[:400]}")
        for k, v in report["coverage"].items():
            if v:
                print(f"  COVERAGE {k}: {json.dumps(v, ensure_ascii=False)}")
        for tbl, v in sorted(report["seed"].items()):
            for row in v["missing_from_mirror"]:
                print(f"  SEED [{tbl}] MISSING FROM MIRROR: {json.dumps(row, ensure_ascii=False)}")
            for row in v["extra_in_mirror"]:
                print(f"  SEED [{tbl}] EXTRA IN MIRROR:     {json.dumps(row, ensure_ascii=False)}")
        for k, v in report["integrity"].items():
            if k.endswith("_referenced") or not v:
                continue
            print(f"  INTEGRITY {k}: {json.dumps(v, ensure_ascii=False)}")
        for u in unchecked:
            print(f"  DEFINER {u}: SECURITY DEFINER with no caller check — add one, or allowlist it with a reason")
        for t in empty_bootstraps:
            print(f"  BOOTSTRAP {t}: seeded ZERO rows — a rebuilt database would start without them")
        print("clean bill of health ✓" if not dirty else "drift / coverage gaps found ✗")

    return 1 if dirty else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""重建体检:把 db/ 的镜像整套建进一个【空库】,再与线上逐项比对。

check_mirrors.py 回答的是"镜像与线上一致吗";本脚本回答的是【另一个问题】——
"照着这个仓库,能不能真的把库建起来"。OPS-1 第一次做这个实验时,答案是【不能】,
而且连撞三堵墙,每一堵此前都没有写下来过(见 db/platform-prelude.sql 的抬头)。
那三件事修好之后,这个实验就应该【一直可重复】,而不是只做过一次。

用法
    python3 db/verify_rebuild.py --target "<空库的连接串>"
    python3 db/verify_rebuild.py --target "<空库>" --live "<线上连接串>"
    python3 db/verify_rebuild.py --target "<空库>" --skip-diff   # 只建,不比

退出码:0 = 全过;1 = 镜像与线上有差异;2 = 建不起来(重放失败);3 = 不变式被破坏。
【三种失败是三件不同的事】"镜像漂了"、"仓库建不起来"、"权限不变式破了" 各有各的修法。

前提
  * 一个【空的】目标库。本脚本会往里面建东西,不要指向线上。
  * psql 在 PATH 上。
  * 想比对时:能连上线上(默认走 check_mirrors.py 的 DEFAULT_DSN)。
  本地起一个一次性集群的做法:
      initdb -D /tmp/pg -U postgres --no-locale --encoding=UTF8
      pg_ctl -D /tmp/pg -o "-p 55432 -k /tmp/pgsock -c listen_addresses=''" -l /tmp/pg.log start
      createdb -h /tmp/pgsock -p 55432 -U postgres scratch
  ⚠️ unix socket 目录要短(<103 字节),放在 /tmp 下,不要放在很深的临时目录里。
"""

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("cm", REPO / "db" / "check_mirrors.py")
cm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cm)

PRELUDE = REPO / "db" / "platform-prelude.sql"
DB_SETTINGS = REPO / "db" / "database-settings.sql"

# 重放失败时,把"缺了什么"直接指出来 —— 这就是【前置文件是否仍然够用】的答案。
MISSING_PATTERNS = [
    (r'schema "([^"]+)" does not exist', 'schema'),
    (r'role "([^"]+)" does not exist', 'role'),
    (r'relation "([^"]+)" does not exist', 'relation'),
    (r'function ([a-z_.]+\([^)]*\)) does not exist', 'function'),
    (r'type "([^"]+)" does not exist', 'type'),
    (r'extension "([^"]+)" is not available', 'extension'),
]


def mirror_object_names() -> set:
    """镜像集自己会创建的对象名 —— 用来判断"缺的东西"是平台的,还是我们自己的。

    自己的对象缺了,说明【重放顺序】不对(或签名里用了表复合类型),
    不是前置文件少了什么。把它写进 platform-prelude.sql 是错误修法。
    """
    names = set()
    for sub, pats in (("tables", (r"CREATE TABLE\s+(?:IF NOT EXISTS\s+)?public\.([a-z0-9_]+)",
                                  r"CREATE SEQUENCE\s+(?:IF NOT EXISTS\s+)?public\.([a-z0-9_]+)")),
                      ("views", (r"CREATE(?:\s+OR\s+REPLACE)?\s+VIEW\s+public\.([a-z0-9_]+)",)),
                      ("functions", (r"CREATE OR REPLACE FUNCTION\s+public\.([a-z0-9_]+)",))):
        for f in (REPO / "db" / sub).glob("*.sql"):
            t = f.read_text()
            for pat in pats:
                names.update(re.findall(pat, t, re.I))
    return names


def fixup(sql: str) -> str:
    """pg_get_functiondef 的原样输出不带结尾分号 —— 与 check_mirrors.rewrite() 同一行代码。"""
    return re.sub(r"^\$function\$$", "$function$;", sql, flags=re.M)


def psql(dsn: str, sql: str):
    return subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", "-"],
                          input=sql, capture_output=True, text=True)


def replay_order():
    fn = sorted((REPO / "db" / "functions").glob("*.sql"))
    tbl = sorted((REPO / "db" / "tables").glob("*.sql"))
    vw = sorted((REPO / "db" / "views").glob("*.sql"))
    txt = {f: f.read_text() for f in tbl}
    allt = set().union(*(cm.created_tables(t) for t in txt.values()))
    meta = {f: (cm.created_tables(t), cm.table_deps(t, cm.created_tables(t), allt))
            for f, t in txt.items()}
    tbl_order = cm.toposort(meta)
    vtxt = {f: f.read_text() for f in vw}
    vnames = {f.stem for f in vw}
    vw_order = sorted(vw, key=lambda f: (
        len([v for v in vnames - {f.stem} if re.search(rf"\b{v}\b", vtxt[f])]), f.name))
    return fn, tbl_order, vw_order


PLATFORM_PROBE = """SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='auth' AND p.proname='uid';"""


def platform_present(dsn: str) -> bool:
    """目标库是不是【已经】是一个 Supabase 项目?

    真实的 Supabase 项目自带 auth 架构、auth.users、auth.uid() 与三个角色,而且 auth
    架构【属于 supabase_auth_admin】—— 连接用的 postgres 角色对它没有 CREATE 权限。
    所以对着真项目跑前置文件不是多余,是【会直接报错】:
        ERROR: permission denied for schema auth
    前置文件是给【裸 postgres】用的。这里自己认出来,免得照着清单做的人被这条错误挡住。
    """
    r = subprocess.run(["psql", dsn, "-X", "-A", "-t", "-c", PLATFORM_PROBE],
                       capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "1"


def rebuild(dsn: str, prelude: str = "auto") -> int:
    if prelude == "auto":
        prelude = "skip" if platform_present(dsn) else "run"
        kind = "already present (a real Supabase project)" if prelude == "skip" else "absent (bare postgres)"
        print("== platform substrate: " + kind)
    if prelude == "skip":
        print("== prelude: SKIPPED - the platform already provides auth, the roles and the default privileges")
    else:
        print("== prelude: db/platform-prelude.sql")
        p = psql(dsn, fixup(PRELUDE.read_text()))
        if p.returncode != 0:
            sys.stderr.write(p.stderr)
            print("\nPRELUDE FAILED - the platform substrate could not be created.")
            return 2

    # ── 数据库级 GUC(FIN-20):应用配置,【无论平台在不在都要跑】────────────────
    # prelude 是平台基座,真 Supabase 项目会跳过;这份不是 —— 新项目不会自带我们的
    # 时区设定,漏掉它重建出来的库就回到 UTC 的"每天八小时今天是昨天"。
    print("== database settings: db/database-settings.sql")
    p = psql(dsn, DB_SETTINGS.read_text())
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        print("\nDATABASE SETTINGS FAILED - db/database-settings.sql did not apply.")
        return 2

    fn, tbl, vw = replay_order()
    for label, files, pre in (("functions", fn, "SET check_function_bodies = off;\n"),
                              ("tables", tbl, ""), ("views", vw, "")):
        print(f"== replay db/{label} ({len(files)} files)")
        # 【一组一个连接,不是一个文件一个连接】对本地集群无所谓,但对着远端项目
        # 每个文件重连一次会把这一步拖到十几分钟 —— 走安装清单时实测。
        # \echo 标记保住了出错归属:失败时最后一个标记就是出问题的文件。
        script = pre + "\n".join(
            f"\\echo '>>> {f.name}'\n" + fixup(f.read_text()) for f in files)
        r = psql(dsn, script)
        if r.returncode != 0:
            err = r.stderr.strip()
            done = [l[4:] for l in r.stdout.splitlines() if l.startswith(">>> ")]
            culprit = done[-1] if done else "(first file)"
            print(f"\nREPLAY FAILED in db/{label}/{culprit}")
            for line in err.splitlines()[:6]:
                print("    " + line)
            # 【前置文件够不够用】的判定就在这里:缺的是不是平台对象?
            missing = []
            for pat, kind in MISSING_PATTERNS:
                for m in re.findall(pat, err):
                    missing.append((kind, m))
            # 【把两类"缺东西"分开】说错了比不说更糟:把镜像自己会建的对象
            # 写进 platform-prelude.sql 是【实实在在的错误修法】。
            own = mirror_object_names()
            platform = [f"{k} {m}" for k, m in missing if m.split('(')[0] not in own]
            ordering = [f"{k} {m}" for k, m in missing if m.split('(')[0] in own]
            if ordering:
                print("\n  REPLAY ORDERING PROBLEM - these are objects the mirror set itself creates,")
                print("  referenced before their own replay position:")
                for m in sorted(set(ordering)):
                    print(f"      {m}")
                print("  Replay order is functions -> tables -> views, and check_function_bodies=off")
                print("  exempts a function BODY but not its SIGNATURE. A table composite type in a")
                print("  RETURNS or parameter list can therefore never work. Use a built-in type.")
                print("  Do NOT add these to db/platform-prelude.sql - they are not platform objects.")
            if platform:
                print("\n  db/platform-prelude.sql IS NOT SUFFICIENT - missing platform objects:")
                for m in sorted(set(platform)):
                    print(f"      {m}")
                print("  Add it to the prelude, or explain in that file why the mirrors may rely on it.")
            if not ordering and not platform:
                print("\n  (not a missing-object error - the mirror itself is broken)")
            return 2
    if prelude == "run":
        print("\nREBUILD OK - db/platform-prelude.sql is SUFFICIENT for the current mirror set.")
    else:
        print("\nREBUILD OK - replayed onto an existing Supabase platform (prelude not needed).")
    return 0


SIG_SQL = r"""
SELECT jsonb_build_object(
 'tables', COALESCE((SELECT jsonb_object_agg(c.relname, jsonb_build_object(
     'columns', (SELECT jsonb_agg(a.attname||' | '||format_type(a.atttypid,a.atttypmod)
                    ||' | '||CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE 'NULL' END
                    ||' | '||COALESCE(pg_get_expr(d.adbin,d.adrelid),'')
                    ||' | gen='||COALESCE(NULLIF(a.attgenerated::text,''),'-')
                    ||' | comment='||COALESCE(col_description(c.oid,a.attnum),'-')
                    ORDER BY a.attnum)
        FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
     -- 【按 C 排序规则排,不按库的 locale】线上是 en_US.UTF-8、一次性 scratch 库是
     -- --no-locale(C),同一组约束文本在两边的【顺序】不同 —— 于是结构完全一致的表
     -- 也会被报成 DIFFERS。APR-1 的 approval_log 是第一张同时有大写开头(NOT ...)
     -- 与小写开头(amount_ccy ...)CHECK 的表,把这个潜伏的假阳性顶了出来。
     -- 比的是结构,就不能让它依赖跑在哪个 locale 上。
     'constraints', (SELECT COALESCE(jsonb_agg(x ORDER BY x COLLATE "C"),'[]'::jsonb) FROM
        (SELECT DISTINCT pg_get_constraintdef(oid) x FROM pg_constraint WHERE conrelid=c.oid) s),
     'indexes', (SELECT COALESCE(jsonb_agg(x ORDER BY x COLLATE "C"),'[]'::jsonb) FROM
        (SELECT DISTINCT pg_get_indexdef(indexrelid) x FROM pg_index WHERE indrelid=c.oid) s),
     'triggers', (SELECT COALESCE(jsonb_agg(x ORDER BY x COLLATE "C"),'[]'::jsonb) FROM
        (SELECT DISTINCT pg_get_triggerdef(oid) x FROM pg_trigger WHERE tgrelid=c.oid AND NOT tgisinternal) s),
     'rls', c.relrowsecurity,
     'policies', (SELECT COALESCE(jsonb_agg(x ORDER BY x COLLATE "C"),'[]'::jsonb) FROM
        (SELECT DISTINCT polname||' | '||polpermissive::text||' | '||polcmd::text
             ||' | '||COALESCE((SELECT string_agg(rolname,',' ORDER BY rolname) FROM pg_roles WHERE oid=ANY(polroles)),'-')
             ||' | '||COALESCE(pg_get_expr(polqual,polrelid),'-')
             ||' | '||COALESCE(pg_get_expr(polwithcheck,polrelid),'-') x
         FROM pg_policy WHERE polrelid=c.oid) s),
     'table_grants', (SELECT COALESCE(jsonb_agg(g.grantee||':'||g.privilege_type ORDER BY g.grantee,g.privilege_type),'[]'::jsonb)
        FROM information_schema.table_privileges g WHERE g.table_schema='public' AND g.table_name=c.relname
          AND g.grantee IN ('authenticated','anon','service_role','PUBLIC')),
     'column_grants', (SELECT COALESCE(jsonb_agg(g.grantee||':'||g.privilege_type||':'||g.column_name
                          ORDER BY g.grantee,g.privilege_type,g.column_name),'[]'::jsonb)
        FROM information_schema.column_privileges g WHERE g.table_schema='public' AND g.table_name=c.relname
          AND g.grantee IN ('authenticated','anon','service_role','PUBLIC'))))
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='r'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')),'{}'::jsonb),
 'functions', COALESCE((SELECT jsonb_object_agg(p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',
                          pg_get_functiondef(p.oid))
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prokind='f'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')),'{}'::jsonb),
 'views', COALESCE((SELECT jsonb_object_agg(c.relname, jsonb_build_object(
       'def', pg_get_viewdef(c.oid,true),
       'opts', COALESCE(array_to_string(c.reloptions,','),'')))
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='v'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')),'{}'::jsonb),
 'sequences', COALESCE((SELECT jsonb_agg(c.relname ORDER BY c.relname)
   FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='S'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=c.oid AND d.deptype='e')),'[]'::jsonb)
)::text;
"""


def signature(dsn: str):
    # 【要显式解掉语句超时】线上走的是连接池,默认有 statement_timeout;
    # 这条目录快照查得比较重,不解会被掐断,而那看起来像"比对失败"而不是"超时"。
    r = subprocess.run(["psql", dsn, "-X", "-q", "-A", "-t", "-f", "-"],
                       input="SET statement_timeout = 0;\n" + SIG_SQL,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(2)
    return json.loads(r.stdout.strip())


def diff(live, scratch) -> list:
    out = []

    def cmp(kind, l, s, nested=False):
        for k in sorted(set(l) - set(s)):
            out.append((kind, k, "MISSING FROM REBUILD", ""))
        for k in sorted(set(s) - set(l)):
            out.append((kind, k, "EXTRA IN REBUILD", ""))
        for k in sorted(set(l) & set(s)):
            if l[k] == s[k]:
                continue
            if nested and isinstance(l[k], dict):
                for sub in sorted(set(l[k]) | set(s[k])):
                    if l[k].get(sub) != s[k].get(sub):
                        out.append((kind, f"{k}.{sub}", "DIFFERS", _fmt(l[k].get(sub), s[k].get(sub))))
            else:
                out.append((kind, k, "DIFFERS", _fmt(l[k], s[k])))

    def _fmt(lv, sv):
        if isinstance(lv, list) or isinstance(sv, list):
            lv, sv = lv or [], sv or []
            a = [x for x in lv if x not in sv]
            b = [x for x in sv if x not in lv]
            parts = []
            if a: parts.append("live only: " + json.dumps(a, ensure_ascii=False))
            if b: parts.append("rebuild only: " + json.dumps(b, ensure_ascii=False))
            return " | ".join(parts)
        return f"live={json.dumps(lv, ensure_ascii=False)[:240]} rebuild={json.dumps(sv, ensure_ascii=False)[:240]}"

    cmp("table", live["tables"], scratch["tables"], nested=True)
    cmp("function", live["functions"], scratch["functions"])
    cmp("view", live["views"], scratch["views"], nested=True)
    ls, ss = set(live["sequences"]), set(scratch["sequences"])
    for k in sorted(ls - ss):
        out.append(("sequence", k, "MISSING FROM REBUILD", ""))
    for k in sorted(ss - ls):
        out.append(("sequence", k, "EXTRA IN REBUILD", ""))
    return out



# ═══════════════════════════════════════════════════════════════════════════
# 【两条不变式】(OPS-5)。都要【对线上和对重建各跑一遍】——
# OPS-4 的全部发现就是这两边曾经差了 8 个函数(含冲销分录的引擎),
# 而只有重建那一侧看得见。任何一边违反都算失败。
#
# 【为什么不是"安全默认"】试过了:
#     ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
#         REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;
# 记录进 pg_default_acl 了,但新建函数的 ACL 里 `=X/postgres`(给 PUBLIC 的那条)
# 照样在,anon 仍然调得到 —— PostgreSQL 对函数内建的 "EXECUTE TO PUBLIC"
# 不受默认权限的 REVOKE 压制。所以预防做不到,只能靠这两条断言检测。
# ═══════════════════════════════════════════════════════════════════════════

# B1:anon 在 public 架构里不该能执行任何函数。anon 就是互联网。
# 【空的】—— 未登录的界面(登录页、设置密码页)走 Supabase auth 端点,不调 public 的函数;
# 实测:注销状态下 /login、/set-password、/ 都渲染正常,服务端日志零条 permission denied。
# 将来真有函数必须给 anon,在这里加一行【并写清楚为什么】。
ANON_EXECUTE_ALLOWED: dict = {}

# B2:SECURITY DEFINER 函数要么自己查调用者,要么谁都执行不了。
# 下面三个是【权限判断本身的原语】:它们解析的是【调用者自己的】上下文,
# 对 anon 来说返回的是空,所以"没有调用者检查"对它们不是漏洞 —— 它们就是检查。
DEFINER_UNCHECKED_EXEC_ALLOWED: dict = {
    "has_permission":
        "the permission check itself; returns false for anyone holding nothing",
    "current_user_permissions":
        "resolves the CALLER's own permission set; returns an empty array for anon",
    "current_user_employee":
        "resolves the CALLER's own employee row; returns NULL for anon",
}

CALLER_CHECK_RE = ("require_permission\\(|has_permission\\(|current_user_employee\\("
                   "|is_reviewer_of\\(|require_reviewer_of\\(")

B1_SQL = """
SELECT coalesce(string_agg(p.proname, ',' ORDER BY p.proname), '')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f'
  AND has_function_privilege('anon', p.oid, 'EXECUTE');
"""

B2_SQL = """
SELECT coalesce(string_agg(p.proname, ',' ORDER BY p.proname), '')
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef
  -- 触发器函数调不动;闸门是触发它的那次基表写入(perm2a 的设计)
  AND pg_get_function_result(p.oid) <> 'trigger'
  AND p.prosrc !~ '""" + CALLER_CHECK_RE + """'
  AND (p.proacl IS NULL                                   -- 内建默认 = 给 PUBLIC
       OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                  WHERE a.grantee = 0 AND a.privilege_type = 'EXECUTE')   -- 显式给 PUBLIC
       OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
       OR has_function_privilege('anon', p.oid, 'EXECUTE'));
"""


def scalar(dsn: str, sql: str) -> set:
    r = subprocess.run(["psql", dsn, "-X", "-q", "-A", "-t", "-f", "-"],
                       input="SET statement_timeout = 0;\n" + sql,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        return {"<query failed>"}
    out = [l for l in r.stdout.strip().splitlines() if l and l != "SET"]
    return {x for x in (out[-1].split(",") if out else []) if x}


def assert_invariants(live_dsn: str, target_dsn: str) -> bool:
    """B1 + B2,两侧各跑一遍。返回 True 表示都过。"""
    ok = True
    print("\n== invariants (checked against BOTH live and the rebuild)")
    for label, dsn in (("live", live_dsn), ("rebuild", target_dsn)):
        b1 = scalar(dsn, B1_SQL) - set(ANON_EXECUTE_ALLOWED)
        b2 = scalar(dsn, B2_SQL) - set(DEFINER_UNCHECKED_EXEC_ALLOWED)
        print(f"   {label:8s} B1 anon-executable: {len(b1)}   "
              f"B2 definer-unchecked-and-callable: {len(b2)}")
        for n in sorted(b1):
            print(f"      B1 VIOLATION [{label}] {n}: anon can EXECUTE it — "
                  f"revoke, or allowlist it in ANON_EXECUTE_ALLOWED with a reason")
            ok = False
        for n in sorted(b2):
            print(f"      B2 VIOLATION [{label}] {n}: SECURITY DEFINER, no caller check, "
                  f"and executable — add a check, revoke EXECUTE, or allowlist with a reason")
            ok = False
    print(f"   allowlisted: B1 {len(ANON_EXECUTE_ALLOWED)}, B2 {len(DEFINER_UNCHECKED_EXEC_ALLOWED)}"
          f" ({', '.join(sorted(DEFINER_UNCHECKED_EXEC_ALLOWED))})")
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--target", required=True, help="空库的连接串(会被写入,别指向线上)")
    ap.add_argument("--live", default=None, help="线上连接串(默认用 check_mirrors 的 DEFAULT_DSN)")
    ap.add_argument("--skip-diff", action="store_true", help="只重建,不与线上比对")
    ap.add_argument("--prelude", choices=("auto", "run", "skip"), default="auto",
                    help="auto(默认)= 目标已是 Supabase 项目就跳过;裸 postgres 才跑")
    args = ap.parse_args()

    rc = rebuild(args.target, args.prelude)
    if rc != 0:
        return rc
    import os as _os
    if args.skip_diff:
        live_dsn = args.live or _os.environ.get("CHECK_MIRRORS_DSN") or cm.DEFAULT_DSN
        return 0 if assert_invariants(live_dsn, args.target) else 3

    import os
    live_dsn = args.live or os.environ.get("CHECK_MIRRORS_DSN") or cm.DEFAULT_DSN
    print("\n== comparing the rebuilt database against live")
    d = diff(signature(live_dsn), signature(args.target))
    inv_ok = assert_invariants(live_dsn, args.target)
    if not d:
        print("\nNO DIFFERENCES — the rebuild matches live ✓")
        return 0 if inv_ok else 3
    print(f"\n{len(d)} DIFFERENCE(S):\n")
    for kind, k, verdict, detail in d:
        print(f"[{kind}] {k}\n    {verdict}")
        if detail:
            print(f"    {detail[:500]}")
    return 1 if inv_ok else 3


if __name__ == "__main__":
    sys.exit(main())

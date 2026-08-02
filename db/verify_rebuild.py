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

退出码:0 = 建得起来且与线上一致;1 = 有差异;2 = 建不起来(重放失败)。

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

# 重放失败时,把"缺了什么"直接指出来 —— 这就是【前置文件是否仍然够用】的答案。
MISSING_PATTERNS = [
    (r'schema "([^"]+)" does not exist', 'schema'),
    (r'role "([^"]+)" does not exist', 'role'),
    (r'relation "([^"]+)" does not exist', 'relation'),
    (r'function ([a-z_.]+\([^)]*\)) does not exist', 'function'),
    (r'type "([^"]+)" does not exist', 'type'),
    (r'extension "([^"]+)" is not available', 'extension'),
]


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
                    missing.append(f"{kind} {m}")
            if missing:
                print("\n  db/platform-prelude.sql IS NOT SUFFICIENT - missing:")
                for m in sorted(set(missing)):
                    print(f"      {m}")
                print("  Add it to the prelude, or explain in that file why the mirrors may rely on it.")
            else:
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
     'constraints', (SELECT COALESCE(jsonb_agg(x ORDER BY x),'[]'::jsonb) FROM
        (SELECT DISTINCT pg_get_constraintdef(oid) x FROM pg_constraint WHERE conrelid=c.oid) s),
     'indexes', (SELECT COALESCE(jsonb_agg(x ORDER BY x),'[]'::jsonb) FROM
        (SELECT DISTINCT pg_get_indexdef(indexrelid) x FROM pg_index WHERE indrelid=c.oid) s),
     'triggers', (SELECT COALESCE(jsonb_agg(x ORDER BY x),'[]'::jsonb) FROM
        (SELECT DISTINCT pg_get_triggerdef(oid) x FROM pg_trigger WHERE tgrelid=c.oid AND NOT tgisinternal) s),
     'rls', c.relrowsecurity,
     'policies', (SELECT COALESCE(jsonb_agg(x ORDER BY x),'[]'::jsonb) FROM
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
    if args.skip_diff:
        return 0

    import os
    live_dsn = args.live or os.environ.get("CHECK_MIRRORS_DSN") or cm.DEFAULT_DSN
    print("\n== comparing the rebuilt database against live")
    d = diff(signature(live_dsn), signature(args.target))
    if not d:
        print("NO DIFFERENCES — the rebuild matches live ✓")
        return 0
    print(f"{len(d)} DIFFERENCE(S):\n")
    for kind, k, verdict, detail in d:
        print(f"[{kind}] {k}\n    {verdict}")
        if detail:
            print(f"    {detail[:500]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""db/check_portal.py — 判词八【门户面】(MES-9a,2026-10-19;MES-9 Step 0 Q3 · Q28,Tim)

════════════════════════════════════════════════════════════════════════════
它问的那一件事
════════════════════════════════════════════════════════════════════════════
一个供应商门户会话在库里是一个【单独的 Postgres 角色】supplier_portal(access token hook 把它写进令牌,PostgREST 照它 SET ROLE)。
这个角色【不是】authenticated 的成员 —— 所以它够得着什么,不是"员工那一面减掉一些",而是【按名字授给它的那几样,一样不多】。
本脚本每一次都从目录里把那几样【逐条列出来】,与 db/portal-grants-baseline.tsv 比:

    【相等,两个方向都要】—— 多一条(有人授了它一张表、一支函数、一条策略)→ 红,点名;
                           少一条(基线里有、目录里没有 —— 门户的一支函数没了)→ 也红,点名。
    这与判词六 / 七"只许是子集"不同:门户的面是一份【约定】,不是一个上限(Q3 原文:"equal a baseline file")。

列的是什么(两侧都问:线上,与重建库 —— 镜像里的 GRANT 必须建出同一张面):
  role      这个角色自己的属性(不能登录 · 不继承 · 不是超级用户 · 不绕过 RLS ……)
  member_of 它是谁的成员(必须一个都没有 —— 它一旦是 authenticated 的成员,整张员工那一面就漏过来了)
  held_by   谁持有它,连同三个选项(admin · inherit · set):authenticator 要 set(PostgREST 切得过去);postgres 只有 admin
            (PostgreSQL 16 让一个非超级用户的建角色者自动成为它的成员 —— 只能管理它,不能变成它)
  schema    它能 USAGE / CREATE 的每一个架构
  relation  每一张表、视图、序列(在它能 USAGE 的架构里,系统目录除外)上它的每一种表级权限,以及任何一列上的列级权限
  function  每一支它能 EXECUTE 的函数(同上)
  policy    每一条点了它的名的 RLS 策略(以及 TO public 的策略 —— 只在它对那张表有权限时才够得着,所以只在那时列)
【系统目录】pg_catalog / information_schema 里的关系与函数不逐条列:PostgreSQL 对 PUBLIC 开着它们,对每一个角色都一样
  (anon 也一样),它们只有元数据、没有一行业务数据,PostgREST 也不暴露它们。它们的架构 USAGE 照列 —— 那是一行,不是一千行。

════════════════════════════════════════════════════════════════════════════
它自己怎么证明自己没瞎(每一次都跑)
════════════════════════════════════════════════════════════════════════════
  ① 基线读不到 → 抛,绝不当成空基线;
  ② 把关系与函数那两条查询打瞎(恒假)→ universe 为 0 → 必须红(零是一次失明,不是一次测量);
  ③ 探针(重建库上,一笔回滚的事务里):建一张 zz_portal_probe 并 GRANT SELECT 给 supplier_portal —— 必须被点名为"多出来的";
  ④ 从基线里拿掉一条目录里确实有的 → 必须红并点名它("少了的"那一个方向);
  ⑤ 两条独立的路:函数与关系各用 has_*_privilege() 与 aclexplode(*acl)(连 PUBLIC 与 proacl IS NULL 一起认)各求一次,两边不一样 = 红;
  ⑥ 覆盖面下限:关系 ≥ 300 · 函数 ≥ 400(线上与重建各自)。
  故障注入(由 db/gate.py 做):GATE_PORTAL_FAULT=grant 在重建库上把 suppliers 授给 supplier_portal → 必须红并点名;
  GATE_PORTAL_FAULT=revoke 收回 portal_me() 的 EXECUTE → 必须红并点名"少了"。

用法:
    python3 db/check_portal.py --live <dsn> --rebuild <dsn>     # 整门(gate 调它)
    python3 db/check_portal.py --rebuild <dsn> --offline        # 迁移前那一相:只问重建侧
    python3 db/check_portal.py --live <dsn> --list              # 把一侧的读数印出来(写基线时用;不写文件)
退出码:0 两侧都与基线逐条相等 / 1 不等(或自证没咬人、或覆盖面不足、或两条路对不上)/ 5 够不到线上
"""
import argparse
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINE = HERE / "portal-grants-baseline.tsv"
ROLE = "supplier_portal"
FLOORS = {"relations": 300, "functions": 400}
KINDS = ("role", "member_of", "held_by", "schema", "relation", "function", "policy")


class Unreachable(RuntimeError):
    pass


def psql(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-F", "\t"], input=sql,
                       capture_output=True, text=True)
    if p.returncode != 0:
        err = (p.stderr or "").strip()
        if any(s in err for s in ("could not connect", "could not translate", "server closed the connection",
                                  "timeout expired", "Connection refused", "no pg_hba.conf entry")):
            raise Unreachable(err[:300])
        raise RuntimeError(err[:600])
    return p.stdout


# 一次枚举:每一行 kind \t object \t privilege;最后一行 universe
ENUM_SQL = r"""
BEGIN READ ONLY;
SET LOCAL statement_timeout = '120s';
@@PROBE@@
WITH sys AS (SELECT oid FROM pg_namespace WHERE nspname IN ('pg_catalog', 'information_schema') OR nspname LIKE 'pg_toast%' OR nspname LIKE 'pg_temp%'),
usable AS (SELECT n.oid, n.nspname FROM pg_namespace n
            WHERE has_schema_privilege('@@ROLE@@', n.oid, 'USAGE') AND n.oid NOT IN (SELECT oid FROM sys)),
rels AS (SELECT c.oid, n.nspname, c.relname, c.relkind, c.relacl FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f', 'S') AND n.oid NOT IN (SELECT oid FROM sys) AND NOT @@BLIND@@),
fns AS (SELECT p.oid, n.nspname, p.proacl, p.pronamespace FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.oid NOT IN (SELECT oid FROM sys) AND NOT @@BLIND@@)
SELECT * FROM (
    SELECT 'role' AS k, r.rolname AS o,
           concat_ws(' ', CASE WHEN r.rolcanlogin THEN 'login' ELSE 'nologin' END, CASE WHEN r.rolinherit THEN 'inherit' ELSE 'noinherit' END,
                     CASE WHEN r.rolsuper THEN 'superuser' ELSE 'nosuperuser' END, CASE WHEN r.rolcreatedb THEN 'createdb' ELSE 'nocreatedb' END,
                     CASE WHEN r.rolcreaterole THEN 'createrole' ELSE 'nocreaterole' END,
                     CASE WHEN r.rolreplication THEN 'replication' ELSE 'noreplication' END,
                     CASE WHEN r.rolbypassrls THEN 'bypassrls' ELSE 'nobypassrls' END) AS p
      FROM pg_roles r WHERE r.rolname = '@@ROLE@@'
    UNION ALL
    SELECT 'member_of', g.rolname, 'member' FROM pg_auth_members m JOIN pg_roles g ON g.oid = m.roleid
     WHERE m.member = (SELECT oid FROM pg_roles WHERE rolname = '@@ROLE@@')
    UNION ALL
    SELECT 'held_by', h.rolname, 'member admin=' || m.admin_option || ' inherit=' || m.inherit_option || ' set=' || m.set_option
      FROM pg_auth_members m JOIN pg_roles h ON h.oid = m.member
     WHERE m.roleid = (SELECT oid FROM pg_roles WHERE rolname = '@@ROLE@@')
    UNION ALL
    SELECT 'schema', n.nspname, x.priv FROM pg_namespace n CROSS JOIN (VALUES ('USAGE'), ('CREATE')) x(priv)
     WHERE n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%' AND has_schema_privilege('@@ROLE@@', n.oid, x.priv)
    UNION ALL
    SELECT 'relation', r.nspname || '.' || r.relname, x.priv FROM rels r
      CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER')) x(priv)
     WHERE r.relkind <> 'S' AND r.nspname IN (SELECT nspname FROM usable) AND has_table_privilege('@@ROLE@@', r.oid, x.priv)
    UNION ALL
    SELECT 'relation', r.nspname || '.' || r.relname, x.priv FROM rels r
      CROSS JOIN (VALUES ('USAGE'), ('SELECT'), ('UPDATE')) x(priv)
     WHERE r.relkind = 'S' AND r.nspname IN (SELECT nspname FROM usable) AND has_sequence_privilege('@@ROLE@@', r.oid, x.priv)
    UNION ALL
    SELECT 'relation', r.nspname || '.' || r.relname || '.' || a.attname, 'column ' || x.priv FROM rels r
      JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
      CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')) x(priv)
     WHERE r.relkind <> 'S' AND r.nspname IN (SELECT nspname FROM usable)
       AND has_column_privilege('@@ROLE@@', r.oid, a.attnum, x.priv) AND NOT has_table_privilege('@@ROLE@@', r.oid, x.priv)
    UNION ALL
    SELECT 'function', f.nspname || '.' || (SELECT proname FROM pg_proc WHERE oid = f.oid) || '(' || pg_get_function_identity_arguments(f.oid) || ')',
           'EXECUTE' FROM fns f
     WHERE f.nspname IN (SELECT nspname FROM usable) AND has_function_privilege('@@ROLE@@', f.oid, 'EXECUTE')
    UNION ALL
    SELECT 'policy', pol.schemaname || '.' || pol.tablename, pol.policyname FROM pg_policies pol
     WHERE '@@ROLE@@' = ANY (pol.roles)
        OR ('public' = ANY (pol.roles) AND pol.schemaname IN (SELECT nspname FROM usable)
            AND has_table_privilege('@@ROLE@@', (quote_ident(pol.schemaname) || '.' || quote_ident(pol.tablename))::regclass,
                                    'SELECT,INSERT,UPDATE,DELETE'))
) t ORDER BY 1, 2, 3;
-- 第二条路:不问 has_*_privilege,直接拆 ACL(PUBLIC = grantee 0;proacl IS NULL = 内建的 EXECUTE TO PUBLIC)
WITH sys AS (SELECT oid FROM pg_namespace WHERE nspname IN ('pg_catalog', 'information_schema') OR nspname LIKE 'pg_toast%' OR nspname LIKE 'pg_temp%'),
usable AS (SELECT n.oid FROM pg_namespace n WHERE has_schema_privilege('@@ROLE@@', n.oid, 'USAGE') AND n.oid NOT IN (SELECT oid FROM sys)),
me AS (SELECT oid FROM pg_roles WHERE rolname = '@@ROLE@@')
SELECT 'B', 'function', (SELECT nspname FROM pg_namespace WHERE oid = p.pronamespace) || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  FROM pg_proc p
 WHERE p.pronamespace IN (SELECT oid FROM usable) AND NOT @@BLIND@@
   AND (p.proacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                                     WHERE a.privilege_type = 'EXECUTE' AND (a.grantee = 0 OR a.grantee = (SELECT oid FROM me))))
UNION ALL
SELECT 'B', 'relation', n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relnamespace IN (SELECT oid FROM usable) AND c.relkind IN ('r', 'v', 'm', 'p', 'f', 'S') AND NOT @@BLIND@@
   AND (EXISTS (SELECT 1 FROM aclexplode(c.relacl) a WHERE a.grantee = 0 OR a.grantee = (SELECT oid FROM me))
        OR EXISTS (SELECT 1 FROM pg_attribute at CROSS JOIN LATERAL aclexplode(at.attacl) a
                    WHERE at.attrelid = c.oid AND at.attnum > 0 AND (a.grantee = 0 OR a.grantee = (SELECT oid FROM me))))
ORDER BY 1, 2, 3;
SELECT 'universe', 'relations=' || (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                                     WHERE c.relkind IN ('r', 'v', 'm', 'p', 'f', 'S') AND n.nspname = 'public' AND NOT @@BLIND@@),
                   'functions=' || (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                     WHERE n.nspname = 'public' AND NOT @@BLIND@@),
                   'role=' || (SELECT count(*) FROM pg_roles WHERE rolname = '@@ROLE@@');
ROLLBACK;
"""

PROBE_SQL = ("CREATE TABLE public.zz_portal_probe (id int);\n"
             "GRANT SELECT ON public.zz_portal_probe TO " + ROLE + ";\n")
PROBE_MUST = {("relation", "public.zz_portal_probe", "SELECT")}


def enumerate_side(dsn: str, blind: bool = False, probe: bool = False) -> tuple:
    sql = (ENUM_SQL.replace("@@ROLE@@", ROLE).replace("@@BLIND@@", "true" if blind else "false")
           .replace("@@PROBE@@", PROBE_SQL if probe else ""))
    if probe:
        sql = sql.replace("BEGIN READ ONLY;", "BEGIN;")
    out = psql(dsn, sql)
    items, second, universe = set(), set(), {}
    for line in out.splitlines():
        p = line.split("\t")
        if len(p) == 3 and p[0] in KINDS:
            items.add((p[0], p[1], p[2]))
        elif len(p) == 3 and p[0] == "B":
            second.add((p[1], p[2]))
        elif p[0] == "universe":
            universe = {kv.split("=")[0]: int(kv.split("=")[1]) for kv in p[1:]}
    if not universe:
        raise RuntimeError("the enumeration printed no universe line — it did not run to the end; that is blindness, not a reading")
    return items, second, universe


def read_baseline(path: Path) -> dict:
    """★ 读不到基线 = 失败,不是空基线。每一行 kind \\t object \\t privilege \\t reason;没有理由的一行 = 读不懂 = 红。"""
    if not path.exists():
        raise RuntimeError("baseline unreadable: %s — refusing to read it as an empty baseline" % path)
    out = {}
    for raw in path.read_text().splitlines():
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 4 or parts[0] not in KINDS or not parts[3].strip():
            raise RuntimeError("baseline line not understood (kind · object · privilege · reason): %r" % raw)
        out[(parts[0], parts[1], parts[2])] = parts[3]
    if not out:
        raise RuntimeError("baseline parsed to zero lines: %s — an empty baseline and a blind parser look the same" % path)
    return out


def coverage_problems(label: str, u: dict) -> list:
    out = []
    for k, floor in FLOORS.items():
        if u.get(k, 0) < floor:
            out.append("%s: coverage %s = %d (floor %d) — a short count is blindness, not a clean reading" % (label, k, u.get(k, 0), floor))
    if u.get("role", 0) != 1:
        out.append("%s: the role %s does not exist on this side" % (label, ROLE))
    return out


def two_roads(label: str, items: set, second: set) -> list:
    """第一条路(has_*_privilege)与第二条路(拆 ACL)对函数与关系给出的集合必须一样。"""
    a_fn = {o for (k, o, _) in items if k == "function"}
    b_fn = {o for (k, o) in second if k == "function"}
    a_rel = {o.rsplit(".", 1)[0] if o.count(".") >= 2 else o for (k, o, p) in items if k == "relation"}
    b_rel = {o for (k, o) in second if k == "relation"}
    out = []
    if a_fn != b_fn:
        out.append("%s: the two roads disagree on functions — privilege() only %s; ACL only %s"
                   % (label, sorted(a_fn - b_fn)[:5] or "-", sorted(b_fn - a_fn)[:5] or "-"))
    if a_rel != b_rel:
        out.append("%s: the two roads disagree on relations — privilege() only %s; ACL only %s"
                   % (label, sorted(a_rel - b_rel)[:5] or "-", sorted(b_rel - a_rel)[:5] or "-"))
    return out


def compare(items: set, base: dict) -> tuple:
    extra = sorted(items - set(base))
    missing = sorted(set(base) - items)
    return extra, missing


def fmt(i: tuple) -> str:
    return " ".join(i)


def main() -> int:
    ap = argparse.ArgumentParser(description="verdict 8 — what a supplier portal session reaches, equal to a baseline")
    ap.add_argument("--live")
    ap.add_argument("--rebuild")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--baseline", default=str(BASELINE))
    args = ap.parse_args()
    problems, notes = [], []
    try:
        print("== db/check_portal.py —— 判词八【门户面】(supplier_portal 的权限 = 基线,逐条)")
        if args.list:
            dsn = args.live or args.rebuild
            items, _, u = enumerate_side(dsn)
            for i in sorted(items):
                print("\t".join(i))
            print("universe", u)
            return 0
        # ① 读不到的基线必须抛
        try:
            read_baseline(HERE / "__no_such_portal_baseline__.tsv")
            problems.append("self-test ①: an unreadable baseline was read as an empty one")
        except RuntimeError:
            pass
        base = read_baseline(Path(args.baseline))
        sides = []
        if args.rebuild:
            sides.append(("rebuild", args.rebuild))
        if args.live and not args.offline:
            sides.append(("live", args.live))
        if not sides:
            raise RuntimeError("nothing to check: give --rebuild (and --live unless --offline)")
        for label, dsn in sides:
            items, second, u = enumerate_side(dsn)
            problems += coverage_problems(label, u)
            problems += two_roads(label, items, second)
            extra, missing = compare(items, base)
            for i in extra:
                problems.append("★ %s: supplier_portal reaches what the baseline does not name: %s" % (label, fmt(i)))
            for i in missing:
                problems.append("★ %s: the baseline names what supplier_portal does not reach: %s" % (label, fmt(i)))
            notes.append("%-7s %d privilege line(s) · universe relations %d · functions %d"
                         % (label, len(items), u.get("relations", 0), u.get("functions", 0)))
            # ④ 拿掉一条这一侧确实有的 → 必须红("少了的"那个方向自己会红;这一格证"多出来的"那个方向也咬)
            present = sorted(i for i in items if i in base)
            if present:
                cut = dict(base); cut.pop(present[0])
                ex, _ = compare(items, cut)
                if present[0] not in ex:
                    problems.append("self-test ④ (%s): removing the baseline line %r did not go red" % (label, fmt(present[0])))
            else:
                problems.append("self-test ④ (%s): no baseline line is present on this side — nothing to remove; blindness?" % label)
        # ② 打瞎的查询必须读成失明
        _, _, ub = enumerate_side(sides[0][1], blind=True)
        if not coverage_problems("blind", ub):
            problems.append("self-test ②: the blinded enumeration (universe 0) was not reported as blindness")
        # ③ 探针:一张多授的表必须被点名(只在重建库上 —— 它在一笔回滚的事务里建一张表)
        if args.rebuild:
            pitems, _, _ = enumerate_side(args.rebuild, probe=True)
            ex, _ = compare(pitems, base)
            if not PROBE_MUST <= set(ex):
                problems.append("self-test ③: the probe table granted to supplier_portal was not named")
        for n in notes:
            print("   " + n)
        print("   self-tests: unreadable baseline · blinded query · probe grant · removed baseline line —"
              + (" all bit" if not any(p.startswith("self-test") for p in problems) else " ✗ one did not bite"))
        if problems:
            print("判词【门户面】:✗")
            for p in problems:
                print("   " + p)
            return 1
        print("判词【门户面】:✓ %s 的 supplier_portal 权限与基线逐条相等(基线 %d 条,每条带理由)"
              % (" · ".join(l for l, _ in sides), len(base)))
        return 0
    except Unreachable as e:
        print("判词【门户面】:够不到线上 —— 环境故障,不是仓库的毛病:%s" % e)
        return 5
    except Exception as e:
        print("判词【门户面】:✗ 检查本身出错(这也是红的,不是通过):%s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())

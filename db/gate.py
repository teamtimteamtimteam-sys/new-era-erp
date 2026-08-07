#!/usr/bin/env python3
"""db/gate.py — 合并后的数据库门(OPS-6):一次【本地】重建,两个判词。

此前是两个工具各干一半:check_mirrors 把 ~14,000 行重放整个运到线上的
pooler 里跑(40+ 分钟,先后死于 DNS 与 socket 耗尽),verify_rebuild 在本地
两分钟干完同一类活。两者的建库步骤完全相同 —— 做两遍是纯浪费。

本工具:自建一次性本地 postgres → 跑 verify_rebuild(建得起来吗?与线上
结构一致吗?B1/B2 断言,双侧)→ 再把 check_mirrors 独有的四项对着【同一个
本地重建】跑完:种子行比对(线上侧只拉几张小表)、RUNTIME CONFIG 引导行数、
镜像自洽(权限/角色/科目码)、SECURITY DEFINER 调用者检查扫描。
网络用量:线上目录读取 + 几张种子小表,没有任何大载荷。

【两个判词分开报,退出码不合并】——"镜像相对线上漂了"与"仓库根本建不出库"
是两种病、两种药,本周就有一天,把它们区分开就是全部发现。
  exit 0 = 三个判词都干净
  exit 1 = 建得起来,但镜像相对线上有漂移(结构 / 种子 / 自洽 / definer)
  exit 2 = 仓库建不出库(或本工具自身的环境故障)
  exit 3 = B1/B2 不变量断言失败(verify_rebuild 的判词,此前【被本脚本吞掉了】)
  exit 4 = 行为断言失败(db/fixtures/*.sql —— 建出来的库跑起来不对)
"""
import difflib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_mirrors as cm  # SEED_TABLES / RUNTIME_CONFIG / definer 扫描 / DEFAULT_DSN


def psql(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[:500])
    return p.stdout.strip()


def rows_json(dsn: str, table: str, where, cols: str) -> list:
    w = f" WHERE {where}" if where else ""
    out = psql(dsn, f"SELECT COALESCE(json_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text), '[]'::json) "
                    f"FROM (SELECT {cols} FROM public.{table}{w}) x;")
    return json.loads(out)


# ── 列权限缺口 ───────────────────────────────────────────────────────────────
# 【为什么有这一条】表级 INSERT/UPDATE 授权会自动延伸到新加的列,列清单 SELECT
# 授权【不会】。于是给被遮蔽的表 ALTER 加一列,那列对 authenticated 就是有写无读:
# 任何选它或按它过滤的查询 42501,页面 `?? []` 把错误变成空数组,门全绿而页面全空。
# FIN-6 给 processing_cost_entries 加了四列结算列,/finance/processing-costs 与
# /finance/month-end 的成本步骤因此从上线起就是空的,没人发现。
# 判据:被遮蔽表的每一列,要么【授了 SELECT】,要么【在 _masked 视图里】(刻意遮蔽)。
# 两样都不是 = 缺口,当场点名。check_mirrors 不比对 GRANT,所以这一条只能在这里做。
GRANT_GAP_SQL = """
WITH cg AS (
    SELECT DISTINCT cp.table_name
    FROM information_schema.column_privileges cp
    WHERE cp.grantee = 'authenticated' AND cp.privilege_type = 'SELECT'
      AND cp.table_schema = 'public'
      AND NOT EXISTS (
          SELECT 1 FROM information_schema.table_privileges tp
          WHERE tp.grantee = 'authenticated' AND tp.privilege_type = 'SELECT'
            AND tp.table_schema = 'public' AND tp.table_name = cp.table_name)
),
flags AS (
    SELECT c.table_name, c.column_name, c.ordinal_position,
        EXISTS (SELECT 1 FROM information_schema.column_privileges p
                WHERE p.table_schema='public' AND p.table_name=c.table_name
                  AND p.column_name=c.column_name AND p.grantee='authenticated'
                  AND p.privilege_type='SELECT') AS granted,
        EXISTS (SELECT 1 FROM information_schema.columns v
                WHERE v.table_schema='public' AND v.table_name=c.table_name||'_masked'
                  AND v.column_name=c.column_name) AS in_view,
        EXISTS (SELECT 1 FROM information_schema.tables v
                WHERE v.table_schema='public' AND v.table_name=c.table_name||'_masked') AS has_view
    FROM information_schema.columns c JOIN cg ON cg.table_name = c.table_name
    WHERE c.table_schema = 'public'
)
SELECT COALESCE(string_agg(line, ' | ' ORDER BY line), '') FROM (
    SELECT table_name || ': ' || string_agg(column_name, ', ' ORDER BY ordinal_position)
           || CASE WHEN bool_or(NOT granted AND NOT in_view) THEN ' [无 SELECT 且不在遮蔽视图]'
                   ELSE ' [不在遮蔽视图]' END AS line
    FROM flags
    WHERE (NOT granted AND NOT in_view) OR (has_view AND NOT in_view)
    GROUP BY table_name
) q;
"""


# ── 生成类型 vs 线上 schema(OPS-10)────────────────────────────────────────
# 【为什么归入"镜像 vs 线上"这一判词】lib/database.types.ts 是 schema 的【另一份
# 镜像】—— db/tables/*.sql 是给重建用的,它是给编译器用的。问的是同一个问题:
# 仓库里的这份副本还等于线上吗。药也一样:重新生成、提交。所以不另开退出码。
#
# 【它坏起来的样子】类型一旦落后,TypeScript 就在拿一个数据库已经不是的形状做校验:
# 改名或删掉的列【编译干净】,到运行时才炸。FIN-28 改了四列名字是被抓住的,
# 因为那正是那一切的主题;下一次不会有人正好在看。
#
# 生成是确定性的(同一 schema 连跑两次逐字节相同,实测),所以可以直接比字节。
# 拿不到就【报错,不是跳过】—— 缺 CLI、没网、认证过期都算查不了,而查不了
# 不等于没问题(同 restRows / mustRows / check-i18n 对"失败不是空集"的一贯口径)。
def check_generated_types(dsn: str) -> str:
    m = re.search(r"user=postgres\.([a-z0-9]+)", dsn)
    if not m:
        return "无法从连接串解析 project ref —— 查不了,不当作通过"
    ref = m.group(1)
    committed = pathlib.Path(HERE).parent / "lib" / "database.types.ts"
    if not committed.is_file():
        return "lib/database.types.ts 不存在"
    if shutil.which("supabase") is None:
        return "supabase CLI 不在 PATH —— 查不了,不当作通过"
    # 【重试一次,然后才认输】实测过一次:CLI 无缘无故 exit 1 且 stderr 为空,
    # 重跑立刻成功。为一次网络抖动把门变红,人就会学会"红了先重跑一遍" ——
    # 那正是让门失效的方式。所以抖一次不算数,抖两次才算,而且把两条流都打出来:
    # 上一版只打 stderr,而那次 stderr 恰好是空的,报出来的是"失败(exit 1):"
    # 后面什么都没有 —— 一条查不下去的错误信息等于没有错误信息。
    last = None
    for _ in range(2):
        r = subprocess.run(["supabase", "gen", "types", "typescript", "--project-id", ref],
                           capture_output=True, text=True)
        if r.returncode == 0:
            break
        last = r
    if r.returncode != 0:
        detail = (last.stderr.strip() or last.stdout.strip() or "(stdout 与 stderr 都是空的)")
        return f"supabase gen types 连续两次失败(exit {last.returncode}): {detail[:200]}"
    fresh = r.stdout
    have = committed.read_text()
    if fresh == have:
        return ""
    # 说清楚差在哪:只报行数会让人再跑一遍才知道改了什么
    diff = list(difflib.unified_diff(have.splitlines(), fresh.splitlines(),
                                     "lib/database.types.ts", "supabase gen types", lineterm="", n=0))
    changed = [l for l in diff if l[:1] in "+-" and l[:3] not in ("+++", "---")]
    head = "; ".join(l.strip()[:70] for l in changed[:6])
    return (f"lib/database.types.ts 与线上 schema 不一致({len(changed)} 行差异):{head}"
            + (" …" if len(changed) > 6 else "")
            + "  → 跑 npm run types:gen 并提交")


# ── 谁在读那些被收回的列(OPS-13)──────────────────────────────────────────
# 【上面那条判据问错了一半】它问"被遮蔽表的每一列是否要么授权、要么在遮蔽视图里",
# 那是在查【列的状态】。它从来不问【谁在读这些列】—— 于是一个
# security_invoker 视图去读一列【故意收回】的敏感列时,它两条都满足、判词全绿,
# 而任何 authenticated 调用者都撞 42501。
#
# 实例:processing_cost_variance 从上线那天起就是坏的(OPS-12 发现)——
# 页面一直安静地回 HTTP 200 + 一张空表,因为那处 `?? []` 把 42501 吞成了空集,
# 冒烟断言 2xx 又正好从旁边走过去。三道检查同时看不见同一件事。
#
# 判据:invoker 视图 × 它依赖的列 × 该列对 authenticated 是否可读。
# 用 pg_depend 的【列级】依赖(refobjsubid > 0),不解析 SQL —— 视图引用哪些列
# 是目录里记着的事实。
#
# 【security_invoker 有两种拼法】reloptions 里既可能是 'on' 也可能是 'true'。
# 只认其中一个,就会安安静静地只检查一部分视图 —— 那正是本条要消灭的失败方式,
# 写这条检查时先踩了一次:漏掉 'on' 会让 15 个 invoker 视图里的 14 个不被看。
#
# 属主权限视图读被收回的列是【正常的】(遮蔽视图正是这么工作的),所以只查 invoker。
READER_GAP_SQL = """
WITH v AS (
    SELECT c.oid, c.relname,
           COALESCE((SELECT o.option_value FROM pg_options_to_table(c.reloptions) o
                     WHERE o.option_name='security_invoker'), 'off') AS invoker
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='v'
), dep AS (
    SELECT DISTINCT v.relname AS view_name, v.invoker, t.relname AS src_table, a.attname AS col
    FROM v
    JOIN pg_rewrite r ON r.ev_class = v.oid
    JOIN pg_depend d ON d.objid = r.oid AND d.refobjsubid > 0
    JOIN pg_class t ON t.oid = d.refobjid AND t.relkind = 'r'
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
    JOIN pg_namespace tn ON tn.oid = t.relnamespace AND tn.nspname='public'
)
SELECT COALESCE(string_agg(DISTINCT view_name || ' 读 ' || src_table || '.' || col, ' | '), '')
FROM dep
WHERE invoker IN ('on','true')
  AND NOT has_column_privilege('authenticated', src_table::regclass, col, 'SELECT');
"""


def check_reader_gaps(dsn: str) -> str:
    return psql(dsn, READER_GAP_SQL)


def check_grant_gaps(dsn: str) -> str:
    return psql(dsn, GRANT_GAP_SQL)


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="一次本地重建,两个判词(镜像漂移 / 可重建性)")
    ap.add_argument("--live", default=os.environ.get("CHECK_MIRRORS_DSN") or cm.DEFAULT_DSN)
    args = ap.parse_args()
    t0 = time.time()

    # ── 一次性本地集群(socket 路径必须短,见 AGENTS.md)─────────────────────
    workdir = tempfile.mkdtemp(prefix="gate", dir="/tmp")
    datadir, sock = os.path.join(workdir, "pg"), os.path.join(workdir, "s")
    os.makedirs(sock)
    port = "55433"
    try:
        subprocess.run(["initdb", "-D", datadir, "-U", "postgres", "--no-locale",
                        "--encoding=UTF8"], capture_output=True, check=True)
        subprocess.run(["pg_ctl", "-D", datadir, "-o",
                        f"-p {port} -k {sock} -c listen_addresses=''",
                        "-l", os.path.join(workdir, "pg.log"), "start"],
                       capture_output=True, check=True)
        subprocess.run(["createdb", "-h", sock, "-p", port, "-U", "postgres", "gate"],
                       capture_output=True, check=True)
        local = f"host={sock} port={port} user=postgres dbname=gate"

        # ── 判词一的基座:verify_rebuild(建库 + 结构比对 + B1/B2 双侧断言)──
        vr = subprocess.run([sys.executable, os.path.join(HERE, "verify_rebuild.py"),
                             "--target", local, "--live", args.live], text=True)
        if vr.returncode == 2:
            print("\n判词【可重建性】:✗ 仓库建不出库 —— 先修这个,别的判词无从谈起")
            return 2
        # 【此前这里漏了 3】verify_rebuild 用 3 表示 B1/B2 不变量断言失败,而本脚本
        # 只认 1 和 2,于是 3 落进 structural_drift=(3==1)=False,门照样绿 ——
        # 本会话里就真的发生过:B1 VIOLATION 打印出来了,退出码却是 0。
        invariant_failed = (vr.returncode == 3)
        structural_drift = (vr.returncode == 1)

        # ── check_mirrors 独有的四项,对着同一个本地重建 ───────────────────────
        print("\n== seeds / bootstrap / integrity / definer(对本地重建;线上只拉小表)")
        problems = []

        for tbl, (where, cols) in cm.SEED_TABLES.items():
            lv = {json.dumps(r, sort_keys=True) for r in rows_json(args.live, tbl, where, cols)}
            mi = {json.dumps(r, sort_keys=True) for r in rows_json(local, tbl, where, cols)}
            bad = lv ^ mi
            print(f"seed:{tbl:<12s} live {len(lv):3d}  mirrored {len(mi):3d}  drifted {len(bad)}")
            if bad:
                problems.append(f"seed:{tbl}: {sorted(bad)[:3]}")

        empties = []
        for tbl in sorted(cm.RUNTIME_CONFIG_TABLES):
            n = int(psql(local, f"SELECT count(*) FROM public.{tbl};"))
            if n == 0 and tbl not in cm.BOOTSTRAP_MAY_BE_EMPTY:
                empties.append(tbl)
        print("bootstrap  " + ("全部 > 0 ✓" if not empties else f"✗ 引导后为空:{empties}"))
        # FIN-3-fu2:科目表的引导默认值 —— 全新安装必须建出【完整】的账:
        # 有权益部分、有非 is_system 的常规科目。缺了配不平,不算能用的安装。
        n_eq = int(psql(local, "SELECT count(*) FROM public.accounts WHERE account_type='equity';"))
        n_ns = int(psql(local, "SELECT count(*) FROM public.accounts WHERE NOT is_system;"))
        print(f"chart      equity {n_eq}  non-system bootstrap {n_ns}" + ("  ✓" if n_eq > 0 and n_ns > 0 else "  ✗"))
        if n_eq == 0 or n_ns == 0:
            problems.append(f"chart incomplete on rebuild: equity={n_eq} non_system={n_ns}")
        if empties:
            problems.append(f"bootstrap empty: {empties}")

        lit = cm.scan_literals()
        integ_bad = []
        for kind, codes, table in (("permission", lit["permission_codes"], "permissions"),
                                   ("role", lit["role_codes"], "roles"),
                                   ("account", lit["account_codes"], "accounts")):
            if not codes:
                continue
            arr = ",".join(f"'{c}'" for c in codes)
            missing = psql(local, f"SELECT COALESCE(string_agg(c, ','), '') FROM unnest(ARRAY[{arr}]) c "
                                  f"WHERE c NOT IN (SELECT code FROM public.{table});")
            if missing:
                integ_bad.append(f"{kind} codes missing from seed: {missing}")
        # 被代码点名却没打 is_system 的科目 —— 这一条特意问【线上】(名单漏网之鱼)
        if lit["account_codes"]:
            arr = ",".join(f"'{c}'" for c in lit["account_codes"])
            loose = psql(args.live, f"SELECT COALESCE(string_agg(c, ','), '') FROM unnest(ARRAY[{arr}]) c "
                                    f"WHERE EXISTS (SELECT 1 FROM public.accounts a WHERE a.code = c AND NOT a.is_system);")
            if loose:
                integ_bad.append(f"account codes referenced but not is_system (live): {loose}")
        print("integrity  " + ("unresolved 0 ✓" if not integ_bad else "✗ " + "; ".join(integ_bad)))
        problems.extend(integ_bad)

        # 列权限缺口:问【线上】(操作员真正撞上的那份)和【本地重建】(全新安装会
        # 得到的那份)。前者抓"加了列忘了授权",后者抓"镜像里的授权清单已过时"。
        for label, dsn in (("live", args.live), ("rebuild", local)):
            gaps = check_grant_gaps(dsn)
            print(f"colgrant   {label}: " + ("无缺口 ✓" if not gaps else f"✗ {gaps}"))
            if gaps:
                problems.append(f"column grant gap ({label}): {gaps}")

        # OPS-13:谁在读被收回的列 —— colgrant 问列的状态,这一条问读它的人。
        # 同样两侧都问:线上是操作员真正撞上的那份,重建是全新安装会得到的那份。
        for label, dsn in (("live", args.live), ("rebuild", local)):
            rg = check_reader_gaps(dsn)
            print(f"colreader  {label}: " + ("无 invoker 视图读被收回的列 ✓" if not rg else f"✗ {rg}"))
            if rg:
                problems.append(f"invoker view reads revoked column ({label}): {rg}")

        # ── 吞掉查询错误(OPS-12)────────────────────────────────────────────
        # `?? []` 把失败读成空集,页面回 200 说"没有数据" —— 冒烟断言 2xx,
        # 正好从旁边走过去。清扫完必须装上检查,否则只买到一个干净的计数。
        swallow = subprocess.run(["node", os.path.join(HERE, "..", "scripts", "check-error-swallowing.mjs")],
                                 capture_output=True, text=True)
        sw_line = (swallow.stdout.strip().splitlines() or [""])[-1]
        print("swallow    " + ("无吞错 ✓" if swallow.returncode == 0 else f"✗ {sw_line}"))
        if swallow.returncode != 0:
            problems.append("swallowed query errors (see check-error-swallowing.mjs)")

        # ── 生成类型 vs 线上 schema(OPS-10)──────────────────────────────────
        types_gap = check_generated_types(args.live)
        print("types      " + ("lib/database.types.ts 与线上一致 ✓" if not types_gap else f"✗ {types_gap}"))
        if types_gap:
            problems.append(f"generated types: {types_gap}")

        # ── 库级 GUC:线上 vs 重建逐条比对(FIN-20)──────────────────────────
        # 行为在配置里也能藏:数据库时区决定 CURRENT_DATE,而本地重建继承开发机
        # 时区(+08)、线上跑 UTC —— 两边对"今天是哪天"的语义分歧了整整一个项目周期,
        # 没有任何检查在看。与 OPS-4 之前的函数 ACL 同一个形状:影响行为的配置,
        # 线上有、重建没有(或反过来),对每个检查都不可见。一个 fixture 钉住一个
        # GUC(fixture 15 钉时区);这里比对【全部】,把这一类关掉。
        # 例外要列名并写理由 —— 与 check-currency-literals 的 ALLOWLIST 同一个做法。
        GUC_ALLOWLIST = {
            "app.settings.jwt_exp":
                "Supabase 平台开项目时写入的 JWT 有效期,裸集群重建没有;真正的"
                "生产重建是新 Supabase 项目,平台会自己带上 —— 平台负责,不入库管。",
        }
        GUC_SQL = ("SELECT COALESCE(string_agg(x, ';' ORDER BY x), '') FROM ("
                   "SELECT unnest(s.setconfig) AS x FROM pg_db_role_setting s "
                   "JOIN pg_database d ON d.oid = s.setdatabase "
                   "WHERE d.datname = current_database() AND s.setrole = 0) q;")
        guc_live = {g for g in psql(args.live, GUC_SQL).split(";") if g}
        guc_local = {g for g in psql(local, GUC_SQL).split(";") if g}
        guc_diff = sorted(g for g in (guc_live ^ guc_local)
                          if g.split("=", 1)[0] not in GUC_ALLOWLIST)
        n_allowed = len((guc_live ^ guc_local)) - len(guc_diff)
        if guc_diff:
            sides = [f"{g} ({'仅线上' if g in guc_live else '仅重建'})" for g in guc_diff]
            print(f"guc        ✗ 线上与重建的库级 GUC 不一致: {'; '.join(sides)}")
            problems.append(f"database GUC drift: {'; '.join(sides)}")
        else:
            print(f"guc        库级 GUC 一致 ✓ (allowlisted {n_allowed})")

        # 币种写死:界面把 'USD'/'SGD' 当常量用过四次,每次都是 FIN-0 改本位币后
        # 没人记得改的残留。名单在 scripts/check-currency-literals.mjs 里,例外要写理由。
        cur = subprocess.run(["node", os.path.join(HERE, "..", "scripts", "check-currency-literals.mjs")],
                             capture_output=True, text=True)
        print("currency   " + ("无写死 ✓" if cur.returncode == 0
                               else "✗ " + cur.stdout.strip().split(chr(10))[-3][:160]))
        if cur.returncode != 0:
            problems.append("currency literals in app code (see check-currency-literals.mjs)")

        # ── 判词三:行为断言(建出来的库跑起来对不对)────────────────────────
        # verify_rebuild 问"结构一不一致";这里问"跑起来对不对"。同一个本地重建。
        fx_dir = os.path.join(HERE, "fixtures")
        fixture_fails = []
        if os.path.isdir(fx_dir):
            for name in sorted(f for f in os.listdir(fx_dir) if f.endswith(".sql")):
                fp = os.path.join(fx_dir, name)
                fr = subprocess.run(["psql", local, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", fp],
                                    capture_output=True, text=True)
                if fr.returncode != 0:
                    msg = (fr.stderr or fr.stdout).strip().split(chr(10))
                    hit = next((l for l in msg if "FIXTURE" in l or "ERROR" in l), msg[0] if msg else "")
                    fixture_fails.append(f"{name}: {hit[:200]}")
                    print(f"fixture   {name:<44s} ✗")
                else:
                    print(f"fixture   {name:<44s} ✓")

        unchecked = cm.definer_without_caller_check()
        print(f"definer    {len(unchecked)} SECURITY DEFINER function(s) with no recognisable caller check"
              f"  ({len(cm.DEFINER_NO_CHECK_ALLOWED)} allowlisted)")
        if unchecked:
            problems.append(f"definer: {unchecked}")

        # ── 两个判词,分开说 ────────────────────────────────────────────────
        elapsed = time.time() - t0
        print(f"\n== 三个判词(wall-clock {elapsed:.0f}s)")
        print("判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)")
        mirrors_dirty = structural_drift or bool(problems)
        if mirrors_dirty:
            print("判词【镜像 vs 线上】:✗ 有漂移" +
                  ("(结构差异见 verify_rebuild 段)" if structural_drift else "") +
                  (f";另 {len(problems)} 项:" + " | ".join(p[:120] for p in problems) if problems else ""))
            if invariant_failed:
                print("判词【不变量 B1/B2】:✗ 失败(详见 verify_rebuild 段)")
            if fixture_fails:
                print(f"判词【行为断言】:✗ {len(fixture_fails)} 个 fixture 失败")
                for f in fixture_fails:
                    print("   " + f)
            return 1
        print("判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)")
        if invariant_failed:
            print("判词【不变量 B1/B2】:✗ 失败(详见 verify_rebuild 段)")
            return 3
        if fixture_fails:
            print(f"判词【行为断言】:✗ {len(fixture_fails)} 个 fixture 失败:")
            for f in fixture_fails:
                print("   " + f)
            return 4
        print("判词【行为断言】:✓ db/fixtures 全部通过(建出来的库跑起来是对的)")
        return 0
    finally:
        subprocess.run(["pg_ctl", "-D", datadir, "stop", "-m", "immediate"], capture_output=True)
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

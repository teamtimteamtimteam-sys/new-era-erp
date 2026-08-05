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
  exit 0 = 两个判词都干净
  exit 1 = 建得起来,但镜像相对线上有漂移(结构 / 种子 / 自洽 / definer)
  exit 2 = 仓库建不出库(或本工具自身的环境故障)
"""
import json
import os
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

        # 币种写死:界面把 'USD'/'SGD' 当常量用过四次,每次都是 FIN-0 改本位币后
        # 没人记得改的残留。名单在 scripts/check-currency-literals.mjs 里,例外要写理由。
        cur = subprocess.run(["node", os.path.join(HERE, "..", "scripts", "check-currency-literals.mjs")],
                             capture_output=True, text=True)
        print("currency   " + ("无写死 ✓" if cur.returncode == 0
                               else "✗ " + cur.stdout.strip().split(chr(10))[-3][:160]))
        if cur.returncode != 0:
            problems.append("currency literals in app code (see check-currency-literals.mjs)")

        unchecked = cm.definer_without_caller_check()
        print(f"definer    {len(unchecked)} SECURITY DEFINER function(s) with no recognisable caller check"
              f"  ({len(cm.DEFINER_NO_CHECK_ALLOWED)} allowlisted)")
        if unchecked:
            problems.append(f"definer: {unchecked}")

        # ── 两个判词,分开说 ────────────────────────────────────────────────
        elapsed = time.time() - t0
        print(f"\n== 两个判词(wall-clock {elapsed:.0f}s)")
        print("判词【可重建性】:✓ 仓库能从零建出库(prelude 足够,B1/B2 双侧断言见上)")
        mirrors_dirty = structural_drift or bool(problems)
        if mirrors_dirty:
            print("判词【镜像 vs 线上】:✗ 有漂移" +
                  ("(结构差异见 verify_rebuild 段)" if structural_drift else "") +
                  (f";另 {len(problems)} 项:" + " | ".join(p[:120] for p in problems) if problems else ""))
            return 1
        print("判词【镜像 vs 线上】:✓ 一致(结构、种子、引导、自洽、definer)")
        return 0
    finally:
        subprocess.run(["pg_ctl", "-D", datadir, "stop", "-m", "immediate"], capture_output=True)
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

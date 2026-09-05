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
  exit 2 = 仓库建不出库
  exit 3 = B1/B2 不变量断言失败(verify_rebuild 的判词,此前【被本脚本吞掉了】)
  exit 4 = 行为断言失败(db/fixtures/*.sql —— 建出来的库跑起来不对)
  exit 5 = 【够不到线上】本工具自身的环境故障 —— 不是仓库的毛病,原样重跑即可
           (VERIFY-1:此前它混在 2 里,见 db/verify_rebuild.py 抬头那一段)

════════════════════════════════════════════════════════════════════════════
★★【--offline 是【多出来的一相】,不是"门,但快一点"】★★(VERIFY-1,2026-09-05)

  python3 db/gate.py --offline     # 迁移【之前】跑,13 秒,全程不碰线上
  python3 db/gate.py               # 迁移【之后】跑,原样跑完【全部】判词

**--offline 不替代任何东西。** 整门在它原来的相位上照跑,断言的东西一件不少 ——
两条路径调的是同一份代码,--offline 只是把【够不到线上的那些】跳过去。
读到这里的人如果想的是"那以后跑 --offline 就行了" —— 不行,而且那正是这段话
存在的理由:**一条被绕过去的检查等于没有检查**(AGENTS.md 反复付过这个账)。

【为什么值得多跑一相】实测(2026-09-05,同一台机器同一个下午):
  * 整门 `GATE_OWN_EXIT=0` **310s**;本相位 `--offline` **44s**。
    差额几乎全是对线上的往返 —— 光重建 + 193 支 fixture 本身只要 13s
    (单独量过:建集群 0s · 重建 7s · fixture 6s),剩下的 31s 是重建侧的
    列权限/读者/跨模块/导入模板目录查询与每支 fixture 的泄漏指纹。
  * C-2 被门抓到的五件事里【四件不需要新库】:镜像列序、一句 `?? []`、
    两支 fixture 漏填必填列、fixture 146 的位置参数错位。
    它们全都落在这 44 秒能回答的范围里,却等到迁移之后才被问。
  * 于是盈亏平衡点是 44/310 ≈ **14.2%** —— 每 7 刀里有 1 刀被它抓到一次,
    这一相就回本。C-2 那一刀的命中率是 100%。
  ★ 44 这个数是【量出来的,不是估的】,而且它比先前写在这里的 13s 悲观 ——
    13s 只量了重建与 fixture,漏掉了本相位真正会跑的那几组目录查询。
    留下这句话是因为本仓库的账正是这么欠下的:**写下来的成本必须是量过的成本**。
  * 而省下的不只是时间:那一轮重跑发生在【破窗里】(C-2 破窗 1h05m57s)。
    这一相把那四件事挪到窗口【打开之前】,省下的秒同时也是风险。
════════════════════════════════════════════════════════════════════════════
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
import check_mirrors as cm
import live_lock  # FIX-3:一次只有一个东西对着线上库跑  # SEED_TABLES / RUNTIME_CONFIG / definer 扫描 / DEFAULT_DSN


def psql(dsn: str, sql: str, statement_timeout=None) -> str:
    # ★【提高 statement_timeout 必须走一条【SET 语句】,不能走 PGOPTIONS】★
    #   第一版用了 `PGOPTIONS=-c statement_timeout=…`,而它**一点用都没有** ——
    #   这条连接走的是 Supabase 的连接池,**启动参数在那一层就被丢掉了**
    #   (实测:PGOPTIONS 版本照旧在同一处超时;而把 SET 作为一条语句发过去,
    #    同一句查询 136 秒跑完)。
    #   代价是 psql 会把 `SET` 这个命令标签也打到 stdout 上,而调用方读的是整个
    #   stdout —— 所以下面把它**按名剥掉**,而不是让它混进结果里冒充一处缺口。
    if statement_timeout:
        sql = f"SET statement_timeout = '{statement_timeout}';\n" + sql
    p = subprocess.run(["psql", dsn, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[:500])
    out = p.stdout.strip()
    if statement_timeout:
        lines = out.split("\n")
        # 【只剥掉开头那一个 SET,而且只在它确实是 SET 的时候】
        # 无条件剥第一行会在查询结果的第一行上撒谎。
        if lines and lines[0].strip() == "SET":
            out = "\n".join(lines[1:]).strip()
        else:
            raise RuntimeError(
                "psql:抬高 statement_timeout 之后,stdout 的第一行不是 SET —— "
                "拒绝猜哪一行是结果(前 200 字符:%s)" % out[:200])
    return out


# ── fixture 泄漏检查(PROC-CLEANUP)────────────────────────────────────────────
# 【为什么有这一条】README 第 2 条要求每支 fixture 自带数据【且不留痕】——
# 整支包在 BEGIN/ROLLBACK 里。PROC-5 给 fixture 54 补的一行 INSERT 落在 `BEGIN;`
# 【之前】,于是它**提交进了重建库**,泄漏给后面每一支。
# **门看不见它**:每支 fixture 只跑一次,没有第二个人撞上那一行。
#
# 【为什么是"每支前后比指纹",而不是"整套跑两遍"】两条都试过、都量过:
#   * 跑两遍:118 支 3.07 秒,再跑一遍还是 3 秒 —— 便宜。但它只抓得住
#     **会撞车的**泄漏(比如主键冲突);一行带随机 uuid 的泄漏跑两遍照样全绿。
#     而且它只会说"第二遍红了",不说是谁泄漏的。
#   * 前后比指纹:一次 32 毫秒,118 支合计约 3.8 秒 —— 一样便宜,
#     **而且它抓【任何】泄漏,并当场点名是哪一支、多了几行**。
# 后者严格更强,所以只做后者。加起来约占 gate 总时长的 1%(gate 实测 333–436s)。
_LEAK_SQL = """SELECT md5(string_agg(t || '=' || n::text, ',' ORDER BY t)) || '|' || sum(n)::text
FROM (SELECT c.relname AS t,
             (xpath('/row/c/text()', query_to_xml(
                format('SELECT count(*) c FROM public.%I', c.relname), false, true, '')))[1]::text::bigint AS n
        FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
       WHERE ns.nspname = 'public' AND c.relkind = 'r') x;"""


def _leak_digest(dsn: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", _LEAK_SQL],
                       capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else "(指纹取不到)"


def rows_json(dsn: str, table: str, where, cols: str) -> list:
    w = f" WHERE {where}" if where else ""
    # 【{S} 一律替成 public,而这里【两侧都对】】本工具把镜像建进【另一个库】,
    # 两个库各有自己的 public —— 与 check_mirrors 把镜像放进同一个库的 mir schema
    # 不同。占位符的存在正是为了让这个差别显式:那边替成 mir,这边替成 public。
    # (CHECK-1:此前 SEED_TABLES 里写死 public.,让 check_mirrors 报了一整张
    #  kpi_position_templates 的假漂移,而本工具因为"碰巧对"一直是绿的。)
    cols = cols.replace("{S}", "public")
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


# ── 谁的【行】会消失(OPS-14)──────────────────────────────────────────────
# colreader 问 invoker 视图读的【列】调用者读不读得到 —— 读不到就 42501,响亮。
# 这一条问另一半:它读的【行】调用者读不读得到 —— 读不到就【安静地消失】。
# 内连接掉整行、外连接掉成 NULL、聚合掉成 0,而视图的派生列正是从这些行算出来的。
# 没有报错,只有一个错的答案,而且【每个读者拿到的答案不一样】。
#
# 实例(OPS-14 之前全部为真,探针实测):processing_run_allocation_status 的
# safe_to_reallocate 对 postgres 是 true、对 operations 是 NULL,而页面在这个布尔上
# 分支、NULL 是 falsy —— 一张完全可以重跑的加工单挂着红色"不能安全重跑"。
# hr_alerts 的 system_start_not_set 写成 NOT EXISTS(finance_settings ...),行一消失
# 条件恒真,于是 hr 角色永远看见一条【清不掉】的假告警。
#
# 判据:invoker 视图 × 它依赖的基表 × 那些基表 SELECT 策略里出现的 module.<x>.view。
# 模块数 > 1 即点名。用 pg_depend(视图→基表)与 pg_policy(策略表达式),
# 不解析视图 SQL —— 视图依赖哪些表、表挂哪些策略,都是目录里记着的事实。
#
# 【两个陷阱,都在 OPS-13 踩过,这里先验后信】
#  * security_invoker 在 reloptions 里既可能是 'on' 也可能是 'true'。全库 15 个
#    invoker 视图里,processing_metal_recovery 是【唯一】拼 'true' 的 —— 只认 'on'
#    会检查 14 个并报干净。所以下面 IN ('on','true'),并且 check_xmodule_views()
#    在返回"没有缺口"之前【先断言自己确实看见了视图和依赖】:零必须是测量,不是缺席。
#  * 只看直接依赖。invoker 视图 A 读 invoker 视图 B 读跨模块基表 —— 点名的是 B。
#
# 【它看不见什么,写出来免得绿被读成"到处都干净"】另一个模块【经属主权限视图】
# (<表>_masked)进来时,pg_policy 里看不到它 —— 目录里那个视图只有一个模块。
# po_prepayment_applicable 正是这样:采购/进料侧走 masked 视图,财务侧走 RLS 基表,
# 判据只数出一个模块。它的病一样真实(没有财务的读者把 settled 读成 0),
# OPS-14 顺手修了,但判据【不会】替你抓下一个。masked 视图之所以不算,是因为它们的
# 把关是 has_permission() 谓词 —— 按调用者解析、不会逐行消失,那是【预期机制】。
XMODULE_SQL = """
WITH v AS (
    SELECT c.oid, c.relname,
           COALESCE((SELECT o.option_value FROM pg_options_to_table(c.reloptions) o
                     WHERE o.option_name='security_invoker'), 'off') AS invoker
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='v'
), dep AS (
    SELECT DISTINCT v.relname AS view_name, t.relname AS src_table
    FROM v
    JOIN pg_rewrite r ON r.ev_class = v.oid
    JOIN pg_depend d ON d.objid = r.oid
    JOIN pg_class t ON t.oid = d.refobjid AND t.relkind = 'r'
    JOIN pg_namespace tn ON tn.oid = t.relnamespace AND tn.nspname='public'
    WHERE v.invoker IN ('on','true') AND t.oid <> v.oid
), m AS (
    SELECT dep.view_name, mods.mod
    FROM dep
    JOIN pg_policy p ON p.polrelid = dep.src_table::regclass AND p.polcmd IN ('r','*')
    CROSS JOIN LATERAL regexp_matches(pg_get_expr(p.polqual, p.polrelid),
                                      'module\\.([a-z_]+)\\.view', 'g') AS mods(mod)
)
SELECT COALESCE(string_agg(x.view_name || ' 跨 ' || x.mods, ' | ' ORDER BY x.view_name), '')
FROM (
    SELECT view_name, array_to_string(array_agg(DISTINCT mod[1] ORDER BY mod[1]), '+') AS mods,
           count(DISTINCT mod[1]) AS n
    FROM m GROUP BY view_name
) x
WHERE x.n > 1;
"""

# 探测器的自证:invoker 视图数、被它们依赖的基表数。任何一个是 0 都说明这条检查
# 什么也没看,而"什么也没看"与"没有缺口"在输出上长得一模一样 —— 那正是要消灭的。
XMODULE_SELFTEST_SQL = """
WITH v AS (
    SELECT c.oid, c.relname,
           COALESCE((SELECT o.option_value FROM pg_options_to_table(c.reloptions) o
                     WHERE o.option_name='security_invoker'), 'off') AS invoker
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='v'
)
SELECT (SELECT count(*) FROM v WHERE invoker IN ('on','true'))::text || ',' ||
       (SELECT count(*) FROM (
            SELECT DISTINCT v.relname, t.relname AS t
            FROM v JOIN pg_rewrite r ON r.ev_class=v.oid
            JOIN pg_depend d ON d.objid=r.oid
            JOIN pg_class t ON t.oid=d.refobjid AND t.relkind='r'
            JOIN pg_namespace tn ON tn.oid=t.relnamespace AND tn.nspname='public'
            WHERE v.invoker IN ('on','true') AND t.oid <> v.oid) z)::text;
"""


def check_xmodule_views(dsn: str) -> tuple:
    """returns (gaps, n_invoker, n_deps) —— 先自证看得见,再报缺口。"""
    n_invoker, n_deps = (int(x) for x in psql(dsn, XMODULE_SELFTEST_SQL).split(","))
    return psql(dsn, XMODULE_SQL), n_invoker, n_deps


# ── IMPORT-2:模板发出去的文件,导入必须收得下 ─────────────────────────────────
# 【为什么这条检查在 gate 而不在 build】它要问【线上目录】三件事(GENERATED、
# NOT NULL 有没有默认值、CHECK 闭集),而那三件只有数据库知道。
# 这正是 check-masked-reads 只进 build 的镜像:那一条只需要仓库里的文件。
#
# 【它断言的不是"模板等于目录"】那会是一句同义反复(模板就是从目录来的)。
# 它断言的是 2.3 那条【规矩】仍然成立,而规矩是可以被一次"顺手"改坏的:
#   ① 模板【不许】发出数据库会拒收的列(GENERATED);
#   ② 数据库要求的列(NOT NULL 且无默认值)【必须】发出来【而且标成必填】;
#   ③ 取值受限的列【必须】带着它的取值集合。
# 六张表全查,不抽查 —— 走查只碰到 suppliers,而实测六张全中。
IMPORT_TEMPLATE_SQL = r"""
WITH t(tbl) AS (VALUES ('materials'),('suppliers'),('customers'),
                       ('departments'),('employees'),('storage_locations')),
tpl AS (
    SELECT t.tbl, x.column_name, x.is_required, x.accepted_values
      FROM t, LATERAL master_import_template_columns(t.tbl) x
),
live AS (
    SELECT c.relname::text tbl, a.attname::text nm,
           a.attnotnull AND ad.adbin IS NULL AS must_supply,
           a.attgenerated <> '' AS generated
      FROM pg_attribute a
      JOIN pg_class c ON c.oid=a.attrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace
      LEFT JOIN pg_attrdef ad ON ad.adrelid=a.attrelid AND ad.adnum=a.attnum
     WHERE n.nspname='public' AND c.relname IN (SELECT tbl FROM t)
       AND a.attnum>0 AND NOT a.attisdropped
),
sets AS (
    SELECT rel.relname::text tbl, a.attname::text nm
      FROM pg_constraint con
      JOIN pg_class rel ON rel.oid=con.conrelid
      JOIN pg_namespace n ON n.oid=rel.relnamespace
      JOIN unnest(con.conkey) k(num) ON true
      JOIN pg_attribute a ON a.attrelid=con.conrelid AND a.attnum=k.num
     WHERE con.contype='c' AND n.nspname='public'
       AND rel.relname IN (SELECT tbl FROM t) AND array_length(con.conkey,1)=1
       AND pg_get_constraintdef(con.oid) LIKE '%''%'
     GROUP BY 1,2
)
SELECT string_agg(msg, '; ') FROM (
    -- ① 发出了数据库拒收的列
    SELECT tpl.tbl||'.'||tpl.column_name||' is GENERATED but emitted' AS msg
      FROM tpl JOIN live ON live.tbl=tpl.tbl AND live.nm=tpl.column_name
     WHERE live.generated
    UNION ALL
    -- ② 数据库要求它,而模板没发
    SELECT live.tbl||'.'||live.nm||' is required but NOT emitted'
      FROM live LEFT JOIN tpl ON tpl.tbl=live.tbl AND tpl.column_name=live.nm
     WHERE live.must_supply AND NOT live.generated AND tpl.column_name IS NULL
       AND NOT (live.nm = ANY (master_import_forbidden_columns()))
    UNION ALL
    -- ②b 发了,却没标成必填
    SELECT tpl.tbl||'.'||tpl.column_name||' is required but NOT marked'
      FROM tpl JOIN live ON live.tbl=tpl.tbl AND live.nm=tpl.column_name
     WHERE live.must_supply AND NOT tpl.is_required
    UNION ALL
    -- ③ 取值受限,却没有带上取值
    SELECT tpl.tbl||'.'||tpl.column_name||' has a CHECK set but no accepted_values'
      FROM tpl JOIN sets ON sets.tbl=tpl.tbl AND sets.nm=tpl.column_name
     WHERE tpl.accepted_values IS NULL OR cardinality(tpl.accepted_values)=0
) q
"""


def check_import_template(dsn: str) -> str:
    return psql(dsn, IMPORT_TEMPLATE_SQL)


def check_grant_gaps(dsn: str) -> str:
    # ★【这一条要比服务端默认的 statement_timeout 更长,而那是【量出来的】,不是猜的】★
    #   GRANT_GAP_SQL 走 information_schema.column_privileges,而那个视图会把 ACL
    #   在**每一列**上展开 —— 它一直是这套门里最贵的一句。
    #   2026-08-30 实测:**136 秒**,而这个角色的服务端默认上限是 **2min = 120 秒**。
    #   也就是说它此前一直贴着线跑,而 SETTLE-1 新增四张表把它推过了线 ——
    #   连着两次 `canceling statement due to statement timeout`,**同一处、可复现**,
    #   不是网络抖动(同时段 select 1 是 2.4–3.1 秒,库里没有锁等待、没有残留事务)。
    #
    #   **这里【只】把上限抬高,不重写那句 SQL。** 真正的修法是改用 pg_catalog +
    #   aclexplode(information_schema 的权限视图慢是众所周知的),而**在一次刚被它
    #   绊倒的切次里现写一个新查询,正是本仓库点名过的「匆忙的检查者」** ——
    #   那条已排进 docs/known-issues.md,带着这次的实测数字。
    return psql(dsn, GRANT_GAP_SQL, statement_timeout="600s")


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="一次本地重建,两个判词(镜像漂移 / 可重建性)")
    ap.add_argument("--live", default=os.environ.get("CHECK_MIRRORS_DSN") or cm.DEFAULT_DSN)
    ap.add_argument("--offline", action="store_true",
                    help="迁移【之前】的一相:只跑够不到线上也能回答的判据。"
                         "★ 增加的一相,不替代整门 —— 见本文件抬头。")
    args = ap.parse_args()
    OFF = args.offline
    t0 = time.time()
    if OFF:
        print("== db/gate.py --offline:迁移前相位 —— 只跑【不需要线上】的判据。\n"
              "   ★ 这不是整门。迁移之后仍然要原样跑一次 `python3 db/gate.py`。")

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
        vr_cmd = [sys.executable, os.path.join(HERE, "verify_rebuild.py"), "--target", local]
        vr_cmd += ["--offline"] if OFF else ["--live", args.live]
        vr = subprocess.run(vr_cmd, text=True)
        if vr.returncode == 2:
            print("\n判词【可重建性】:✗ 仓库建不出库 —— 先修这个,别的判词无从谈起")
            return 2
        # 【5 不是 1、也不是 2】够不到线上是环境故障:重建那一半可能完全是好的。
        # 把它报成漂移会让人去改镜像,报成 2 会让人去改仓库 —— 两条都是白工。
        if vr.returncode == 5:
            print("\n判词【无法作出】:✗ 够不到线上目录 —— 这是【环境故障】,不是仓库的毛病。\n"
                  "   重建那一半的结论见上(若印着 REBUILD OK,它是好的)。原样重跑。")
            return 5
        # 【此前这里漏了 3】verify_rebuild 用 3 表示 B1/B2 不变量断言失败,而本脚本
        # 只认 1 和 2,于是 3 落进 structural_drift=(3==1)=False,门照样绿 ——
        # 本会话里就真的发生过:B1 VIOLATION 打印出来了,退出码却是 0。
        invariant_failed = (vr.returncode == 3)
        structural_drift = (vr.returncode == 1)

        # ── check_mirrors 独有的四项,对着同一个本地重建 ───────────────────────
        print("\n== seeds / bootstrap / integrity / definer(对本地重建;线上只拉小表)")
        problems = []

        for tbl, (where, cols) in ({} if OFF else cm.SEED_TABLES).items():
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
        if lit["account_codes"] and not OFF:
            arr = ",".join(f"'{c}'" for c in lit["account_codes"])
            loose = psql(args.live, f"SELECT COALESCE(string_agg(c, ','), '') FROM unnest(ARRAY[{arr}]) c "
                                    f"WHERE EXISTS (SELECT 1 FROM public.accounts a WHERE a.code = c AND NOT a.is_system);")
            if loose:
                integ_bad.append(f"account codes referenced but not is_system (live): {loose}")
        print("integrity  " + ("unresolved 0 ✓" if not integ_bad else "✗ " + "; ".join(integ_bad)))
        problems.extend(integ_bad)

        # 列权限缺口:问【线上】(操作员真正撞上的那份)和【本地重建】(全新安装会
        # 得到的那份)。前者抓"加了列忘了授权",后者抓"镜像里的授权清单已过时"。
        # 【--offline 只问得到重建侧】线上那一侧由迁移之后的整门原样跑,一件不少。
        # ★ 顺带修掉一处旧疏漏:import-template 那一轮此前写的是 `("rebuild", dsn)`,
        #   而 `dsn` 是上面几个 for 循环漏出来的循环变量(恰好等于 local),
        #   一处【靠上文残留才碰巧正确】的引用。改成同一份 SIDES,名字有主了。
        SIDES = (("rebuild", local),) if OFF else (("live", args.live), ("rebuild", local))
        for label, dsn in SIDES:
            gaps = check_grant_gaps(dsn)
            print(f"colgrant   {label}: " + ("无缺口 ✓" if not gaps else f"✗ {gaps}"))
            if gaps:
                problems.append(f"column grant gap ({label}): {gaps}")

        # OPS-13:谁在读被收回的列 —— colgrant 问列的状态,这一条问读它的人。
        # 同样两侧都问:线上是操作员真正撞上的那份,重建是全新安装会得到的那份。
        for label, dsn in SIDES:
            rg = check_reader_gaps(dsn)
            print(f"colreader  {label}: " + ("无 invoker 视图读被收回的列 ✓" if not rg else f"✗ {rg}"))
            if rg:
                problems.append(f"invoker view reads revoked column ({label}): {rg}")

        # OPS-14:谁的【行】会消失 —— colreader 问列,这一条问行。两侧都问,理由同上。
        # 【零必须是测量】先要探测器自证看得见 invoker 视图和它们的基表依赖,
        # 看不见就当场判失败,而不是安静地报"无缺口"。
        for label, dsn in SIDES:
            xm, n_inv, n_dep = check_xmodule_views(dsn)
            if n_inv == 0 or n_dep == 0:
                print(f"xmodule    {label}: ✗ 探测器什么也没看见(invoker={n_inv} deps={n_dep})")
                problems.append(f"xmodule detector saw nothing ({label}): invoker={n_inv} deps={n_dep}")
            else:
                print(f"xmodule    {label}: "
                      + (f"{n_inv} 个 invoker 视图 / {n_dep} 条基表依赖,无跨模块 ✓" if not xm
                         else f"✗ {xm}"))
                if xm:
                    problems.append(f"invoker view spans modules ({label}): {xm}")

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
        if not OFF:
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
        guc_live = set() if OFF else {g for g in psql(args.live, GUC_SQL).split(";") if g}
        guc_local = {g for g in psql(local, GUC_SQL).split(";") if g}
        guc_diff = [] if OFF else sorted(g for g in (guc_live ^ guc_local)
                                         if g.split("=", 1)[0] not in GUC_ALLOWLIST)
        n_allowed = 0 if OFF else len((guc_live ^ guc_local)) - len(guc_diff)
        if OFF:
            print("guc        (跳过 —— 需要线上;由迁移之后的整门跑)")
        elif guc_diff:
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
            before = _leak_digest(local)
            for name in sorted(f for f in os.listdir(fx_dir) if f.endswith(".sql")):
                fp = os.path.join(fx_dir, name)
                fr = subprocess.run(["psql", local, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", fp],
                                    capture_output=True, text=True)
                after = _leak_digest(local)
                if fr.returncode != 0:
                    msg = (fr.stderr or fr.stdout).strip().split(chr(10))
                    hit = next((l for l in msg if "FIXTURE" in l or "ERROR" in l), msg[0] if msg else "")
                    fixture_fails.append(f"{name}: {hit[:200]}")
                    print(f"fixture   {name:<44s} ✗")
                elif after != before:
                    # 【跑通了,但留下了痕迹】—— 那是 README 第 2 条的另一半。
                    nb = before.split("|")[-1]
                    na = after.split("|")[-1]
                    fixture_fails.append(
                        f"{name}: 【泄漏】跑通了,但库里多/少了行(总行数 {nb} → {na})。"
                        f"整支 fixture 必须包在 BEGIN/ROLLBACK 里 —— "
                        f"落在 BEGIN 之前的 INSERT 会提交进重建库,泄漏给后面每一支"
                        f"(PROC-5 的 fixture 54 就是这么漏的,而门当时看不见)。")
                    print(f"fixture   {name:<44s} ✗ 泄漏({nb} → {na} 行)")
                else:
                    print(f"fixture   {name:<44s} ✓")
                before = after

        unchecked = cm.definer_without_caller_check()
        print(f"definer    {len(unchecked)} SECURITY DEFINER function(s) with no recognisable caller check"
              f"  ({len(cm.DEFINER_NO_CHECK_ALLOWED)} allowlisted)")
        if unchecked:
            problems.append(f"definer: {unchecked}")

        # IMPORT-2:模板与线上目录的三条规矩(见 IMPORT_TEMPLATE_SQL 抬头)
        for label, d in SIDES:
            tmpl_gap = check_import_template(d)
            print(f"   import-template  {label:8} {'✓ 模板与目录一致' if not tmpl_gap else '✗ ' + tmpl_gap}")
            if tmpl_gap:
                problems.append(f"import template ({label}): {tmpl_gap}")

        # ── 两个判词,分开说 ────────────────────────────────────────────────
        elapsed = time.time() - t0
        if OFF:
            print(f"\n== 迁移前相位(wall-clock {elapsed:.0f}s)—— ★ 这【不是】三个判词 ★")
            print("   跑过的:可重建性 · B1/B2(重建侧)· 行为断言(db/fixtures 全套)·")
            print("           引导/科目 · 自洽 · 列权限/读者/跨模块/导入模板(重建侧)·")
            print("           吞错 · 币种写死 · definer")
            print("   ★ 没跑的(都需要线上,一件都没有被取消):种子行比对 · 生成类型 ·")
            print("     库级 GUC · 上面四项的【线上侧】· 科目 is_system 的线上核对。")
            print("   ★★ 迁移之后必须再跑一次不带 --offline 的整门。★★")
            if problems or fixture_fails or invariant_failed:
                if fixture_fails:
                    print(f"迁移前相位:✗ {len(fixture_fails)} 个 fixture 失败:")
                    for f in fixture_fails:
                        print("   " + f)
                if problems:
                    print(f"迁移前相位:✗ {len(problems)} 项:" + " | ".join(p[:120] for p in problems))
                if invariant_failed:
                    print("迁移前相位:✗ B1/B2(重建侧)失败")
                return 4 if (fixture_fails and not problems and not invariant_failed) else 1
            print("迁移前相位:✓ 干净 —— 可以往下走(备份 → 迁移 → 整门)")
            return 0
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
    # FIX-3:整个 gate 期间持有 live-lock,退出必释放(异常与 SIGINT/SIGTERM 也释放)。
    # 见 db/live_lock.py 抬头:这条规矩被破过两次,所以它不再是文档。
    # 【--offline 不持锁】它一次线上都不碰,占着那把锁只会挡住别人(见 db/live_lock.py)。
    # 一把"其实不需要"的锁,与一条"其实不跑"的检查是同一类谎。
    if "--offline" in sys.argv:
        sys.exit(main())
    with live_lock.Held("db/gate.py"):
        sys.exit(main())

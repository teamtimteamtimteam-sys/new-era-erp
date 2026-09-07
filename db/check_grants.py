#!/usr/bin/env python3
"""db/check_grants.py — 【谁看着匿名那一面】(COD-2,2026-09-08)

════════════════════════════════════════════════════════════════════════════
★★★ 先说这个脚本【不是】什么 —— 免得有人把它当成重复的东西退休掉 ★★★
════════════════════════════════════════════════════════════════════════════
仓库里有两个名字听起来已经覆盖了这件事的脚本,而**两个都不覆盖**:

  * `scripts/sweep-ghost-grants.mjs` —— 它管的是 `user_roles` 里那些 `user_id`
    已经不在 `auth.users` 里的行,也就是**应用层的角色授予**。它名字里的
    "grant" 和 SQL 的 GRANT 是两个不同的词。它一行 ACL 都不看。
  * `scripts/check-permission-predicate.mjs` —— 它是对 `app/` 与 `lib/` 的
    纯文本检查,问的是**前端**的权限判断有没有收在一处。它不看视图定义,
    不看角色,不连数据库。

而 `db/check_mirrors.py` 在它自己的【不比】清单里(第 59 行)写着:**不比 GRANT**。
那句话是准确的,也正是这个缺口的由来。本仓库为它付过一次账:
`db/views/batch_lineage_all.sql` 记着一条只住在迁移里的 REVOKE ——
**"线上收着,重建出来的库开着"**。

【与 db/verify_rebuild.py 的 B1 是什么关系 —— 照直写,不冒充全新】
  B1 断言的是"anon 在 public 里【一个函数都不能执行】,除非在 ANON_EXECUTE_ALLOWED
  里写明理由",而且它**两侧都跑**。所以【函数那一半一直有人看着】——
  COD-2 的那条 GRANT 第一次跑 gate 时就是被 B1 拦下来的。
  本脚本与它不重复的地方有三处,而那三处此前【没有任何东西在看】:
    ① **关系**(表与视图)—— 2,272 条 anon 授权,没有任何检查看过一眼;
    ② **公开存储桶** —— avatars 曾经是公开的,而这件事只写在一份迁移的注释里;
    ③ **列级 ACL** —— ANON-0 的方法论明写着:一旦出现一条列级授权,
       它自己那套 `select=*` 的探法就不再是完整的测试。今天是 0 条。
  再加一条形状上的不同:B1 是"必须是零(加白名单)",本脚本是
  **"必须是基线的子集,而基线只许缩小"** —— 后者管得住一份会长的清单。

════════════════════════════════════════════════════════════════════════════
四条断言,每一条都自己数两遍(而两遍的坏法不一样)
════════════════════════════════════════════════════════════════════════════
本仓库的法则:**一个瞎掉的解析器和一棵干净的树,都打印 EXIT 0。**
所以覆盖面本身必须被断言,而不是被假设。每一条断言都:

  · 用【两条独立的路】各求一次结果,两边不一致 = 失败,不是警告;
  · 先数一遍"我这次到底看了多少个对象"(universe),**数出 0 就是失败**——
    空结果长得和一条断掉的连接一模一样;
  · 与基线比,而基线**只许缩小**:线上不是基线的子集 → 红。
    基线里有、线上没有(基线过宽)→ **大声点名,但不变红** ——
    一次刻意的 REVOKE 不该让门红着等人改文件,而一道常红的门等于没有门。

【两条路必须坏得不一样,这是被本仓库的疤逼出来的】
一次逐行的交叉核对报了 311,而解析器报了 470 —— 因为按行切,恰好打败了一个
自身带换行的模式。所以下面每一对都不是"同一句 SQL 写两遍":
  · 关系:information_schema.role_table_grants  ⟷  pg_class.relacl + aclexplode
  · 函数:has_function_privilege()             ⟷  aclexplode(proacl),
          **并且显式把 proacl IS NULL 当成"PUBLIC 可执行"** —— 那正是
          db/verify_rebuild.py 抬头记下的那个洞:新建函数 ACL 为空时,
          内建的 EXECUTE TO PUBLIC 照样让 anon 调得到,而一个天真的
          aclexplode 会把这类函数整个漏掉。
  · 桶:  storage.buckets.public  ⟷  **对着存储 API 真的发一次匿名请求**
          (目录不是答案 —— 这正是 ANON-0 整套方法的立论,而 COD-2 当天就
          撞到一次:桶已经翻成私有,Cloudflare 边缘仍然按旧的 max-age 命中着
          缓存。目录说私有,边缘还在发字节。)
  · 列:  aclexplode(attacl)  ⟷  attacl::text 里的字面匹配

════════════════════════════════════════════════════════════════════════════
【必须连得上线上,而且它【不装】自己能离线跑】
════════════════════════════════════════════════════════════════════════════
镜像里【根本没有 GRANT】—— 那正是这个缺口的全部内容。一个离线版本会
什么都不断言却打印绿色,而那是本仓库反复写下的那种失败。所以:
连不上线上 = 退出码 5(环境故障),不是 0。

用法:
    python3 db/check_grants.py                 # 正常跑(gate 会调它)
    python3 db/check_grants.py --write-baseline # 把当前线上写成基线(慎用)
    python3 db/check_grants.py --injections-only # 只跑自检那两格

退出码:0 干净 / 1 有违规(线上不是基线的子集,或两条路对不上,或覆盖面为 0)
        5 够不到线上
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
BASELINE = HERE / "anon-grants-baseline.tsv"

sys.path.insert(0, str(HERE))
import check_mirrors as cm  # noqa: E402  (DEFAULT_DSN 只有一处定义)


class Unreachable(RuntimeError):
    """够不到线上 —— 这是环境故障,不是仓库的毛病(退出码 5)。"""


def q(dsn: str, sql: str) -> list:
    """跑一句 SQL,回 JSON 行。连不上与查询出错【分开】—— 前者是 5,后者是 1。"""
    p = subprocess.run(
        ["psql", dsn, "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c",
         "SELECT COALESCE(json_agg(t), '[]')::text FROM (%s) t" % sql.rstrip().rstrip(";")],
        capture_output=True, text=True)
    if p.returncode != 0:
        err = (p.stderr or "").strip()
        if any(s in err for s in ("could not connect", "could not translate",
                                  "server closed the connection", "timeout expired",
                                  "Connection refused", "no pg_hba.conf entry")):
            raise Unreachable(err[:300])
        raise RuntimeError(err[:500])
    return json.loads(p.stdout.strip() or "[]")


# ════════════════════════════════════════════════════════════════════════════
# 四条断言的 SQL —— 每条两句,而两句的坏法不一样
# ════════════════════════════════════════════════════════════════════════════

# ① 关系
REL_A = """
SELECT DISTINCT g.table_name AS name
  FROM information_schema.role_table_grants g
 WHERE g.grantee = 'anon' AND g.table_schema = 'public'
"""
REL_B = """
SELECT DISTINCT c.relname AS name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(c.relacl) a
 WHERE n.nspname = 'public'
   AND c.relkind IN ('r','v','m','p','f')
   AND a.grantee = 'anon'::regrole
"""
# universe:两条路各数一次"我看了多少个关系"
REL_UNIV_A = """
SELECT count(*)::int AS n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r','v','p','f')
"""
REL_UNIV_B = """
SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema = 'public'
"""
# 【物化视图会让上面两个数【合法地】对不上】information_schema.tables 不显示它们。
# 今天线上一个都没有(ANON-0 实测)。真出现了,这个交叉核对必须被扩写 ——
# 所以这里【拒绝】而不是悄悄容忍:一个自己知道自己不完整的检查必须说出来。
REL_MATVIEW = """
SELECT count(*)::int AS n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind = 'm'
"""

# ② 函数
FN_A = """
SELECT p.oid::regprocedure::text AS name
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f'
   AND has_function_privilege('anon', p.oid, 'EXECUTE')
"""
# ★ 第二条路必须自己处理 proacl IS NULL ★ —— ACL 为空时 PostgreSQL 给的是
#   内建默认(EXECUTE TO PUBLIC),anon 照样调得到,而 aclexplode(NULL) 一行都不吐。
#   verify_rebuild 的抬头正是为这个洞写的。
FN_B = """
SELECT p.oid::regprocedure::text AS name
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f'
   AND (p.proacl IS NULL
        OR EXISTS (SELECT 1 FROM aclexplode(p.proacl) a
                    WHERE a.privilege_type = 'EXECUTE'
                      AND (a.grantee = 'anon'::regrole OR a.grantee = 0)))
"""
FN_UNIV_A = """
SELECT count(*)::int AS n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.prokind = 'f'
"""
FN_UNIV_B = """
SELECT count(*)::int AS n FROM information_schema.routines
 WHERE specific_schema = 'public' AND routine_type = 'FUNCTION'
"""

# ③ 存储桶
BUCKET_A = "SELECT id AS name FROM storage.buckets WHERE public IS TRUE"
BUCKET_ALL = "SELECT id AS name FROM storage.buckets"

# ④ 列级 ACL
COL_A = """
SELECT (c.relname || '.' || a.attname) AS name
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  CROSS JOIN LATERAL aclexplode(a.attacl) x
 WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
   AND x.grantee = 'anon'::regrole
"""
COL_B = """
SELECT (c.relname || '.' || a.attname) AS name
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
   AND a.attacl IS NOT NULL AND a.attacl::text LIKE '%anon=%'
"""
COL_UNIV_A = """
SELECT count(*)::int AS n FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND a.attnum > 0 AND NOT a.attisdropped
   AND c.relkind IN ('r','v','p','f')
"""
COL_UNIV_B = """
SELECT count(*)::int AS n FROM information_schema.columns WHERE table_schema = 'public'
"""


def names(rows) -> set:
    return {r["name"] for r in rows}


def one(rows) -> int:
    if not rows:
        raise RuntimeError("universe 查询【一行都没回】—— 那是坏了,不是零")
    return int(rows[0]["n"])


# ── 桶的第二条路:对着存储 API 真的问一次(目录不是答案)────────────────────
def buckets_public_over_http(bucket_ids, base_url: str) -> set:
    """匿名 GET 一个【肯定不存在】的对象名。桶私有 → NoSuchBucket;
    桶公开 → 对象不存在。两种回答分得开,而且它问的是【发字节的那一层】。

    ★ 必须带一个绕开缓存的查询串 ★ —— COD-2 当天实测:桶翻成私有之后,
      不带缓存串的同一个地址仍然从 Cloudflare 边缘拿到 HTTP 200 与真正的字节
      (cf-cache-status: HIT),而回源是 400 NoSuchBucket。**一个会命中 CDN
      缓存的探针,量的是过去,不是现在。**
    """
    out = set()
    for b in sorted(bucket_ids):
        url = ("%s/storage/v1/object/public/%s/__grantcheck_does_not_exist__?cb=cg"
               % (base_url.rstrip("/"), b))
        req = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read(4000).decode("utf-8", "replace")
                code = r.status
        except urllib.error.HTTPError as e:
            body = e.read(4000).decode("utf-8", "replace")
            code = e.code
        except Exception as e:                       # 网络够不着 —— 环境故障
            raise Unreachable("storage probe %s: %s" % (b, e))
        if "NoSuchBucket" in body or "Bucket not found" in body:
            continue                                  # 私有
        # 公开桶对一个不存在的对象回 "Object not found" / 404 NoSuchKey
        if code in (200, 400, 404) and ("NoSuchKey" in body or "not found" in body.lower()):
            out.add(b)
        else:
            raise RuntimeError("桶 %s 的探测回了一个认不出的答案(%s):%s"
                               % (b, code, body[:200]))
    return out


def supabase_url() -> str:
    env = REPO / ".env.local"
    if env.exists():
        for line in env.read_text().splitlines():
            if line.startswith("NEXT_PUBLIC_SUPABASE_URL="):
                return line.split("=", 1)[1].strip().strip('"')
    v = os.environ.get("NEXT_PUBLIC_SUPABASE_URL")
    if v:
        return v
    raise Unreachable("找不到 NEXT_PUBLIC_SUPABASE_URL —— 桶的第二条路跑不了")


# ── 基线 ────────────────────────────────────────────────────────────────────
def read_baseline(path: Path) -> dict:
    """★ 读不到基线 = 失败,不是空基线 ★ —— 一个把缺席读成"没有条目"的读法,
    会在文件被删掉的那一天把所有东西都判成违规、或者(更坏)判成通过。
    这里选择【抛】,而"blind the parser" 那一格注入的正是这条路。"""
    if not path.exists():
        raise RuntimeError("基线文件读不到:%s —— 拒绝把它当成空基线" % path)
    out = {"relation": set(), "function": set(), "bucket": set(), "column": set()}
    n = 0
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or parts[0] not in out:
            raise RuntimeError("基线里有一行读不懂:%r" % raw)
        out[parts[0]].add(parts[1])
        n += 1
    if n == 0:
        raise RuntimeError("基线一条都没解析出来:%s —— 空基线与瞎掉的解析器分不开" % path)
    return out


def write_baseline(path: Path, live: dict) -> None:
    lines = [
        "# db/anon-grants-baseline.tsv —— anon 够得着的东西,一行一个。",
        "# 由 db/check_grants.py 断言:**线上必须是它的子集,而它只许缩小。**",
        "# 删一行是普通提交;加一行是一次要写下理由的刻意行为(理由写在迁移里,",
        "# 函数那一条还要写进 db/verify_rebuild.py 的 ANON_EXECUTE_ALLOWED)。",
        "# 生成:python3 db/check_grants.py --write-baseline",
        "#",
        "# kind\tidentity",
    ]
    for kind in ("function", "bucket", "column", "relation"):
        lines.append("# ── %s:%d ──" % (kind, len(live[kind])))
        for v in sorted(live[kind]):
            lines.append("%s\t%s" % (kind, v))
    path.write_text("\n".join(lines) + "\n")


# ── 一次完整的量取 ──────────────────────────────────────────────────────────
def measure(dsn: str, blind_relations: bool = False, skip_http: bool = False) -> tuple:
    """回 (live, problems, notes)。blind_relations 是注入格用的:
    把关系那条查询打瞎(恒假),于是 universe 变成 0 —— 必须变红。

    skip_http 【只给注入格用】:那一格瞄的是基线读取与关系覆盖面,
    而桶那条路要对 15 个桶各发一次匿名 HTTP —— 在注入格里再跑一遍
    只是把这个检查的耗时翻一倍,量不到任何新东西。**正常运行永远跑它。**"""
    problems, notes = [], []

    rel_univ_a_sql = REL_UNIV_A + (" AND false" if blind_relations else "")
    rel_univ_a, rel_univ_b = one(q(dsn, rel_univ_a_sql)), one(q(dsn, REL_UNIV_B))
    matviews = one(q(dsn, REL_MATVIEW))

    live = {
        "relation": names(q(dsn, REL_A)),
        "function": names(q(dsn, FN_A)),
        "bucket": names(q(dsn, BUCKET_A)),
        "column": names(q(dsn, COL_A)),
    }
    second = {
        "relation": names(q(dsn, REL_B)),
        "function": names(q(dsn, FN_B)),
        "column": names(q(dsn, COL_B)),
    }
    all_buckets = names(q(dsn, BUCKET_ALL))
    second["bucket"] = (live["bucket"] if skip_http
                        else buckets_public_over_http(all_buckets, supabase_url()))

    fn_univ_a, fn_univ_b = one(q(dsn, FN_UNIV_A)), one(q(dsn, FN_UNIV_B))
    col_univ_a, col_univ_b = one(q(dsn, COL_UNIV_A)), one(q(dsn, COL_UNIV_B))

    # ── 覆盖面:数出 0 就是失败,两条路对不上也是失败 ──────────────────────
    for label, a, b in (("relation", rel_univ_a, rel_univ_b),
                        ("function", fn_univ_a, fn_univ_b),
                        ("column", col_univ_a, col_univ_b)):
        if a == 0 or b == 0:
            problems.append("覆盖面【为零】:%s universe = %d / %d —— "
                            "空结果长得和一条断掉的连接一模一样,所以它是失败,不是通过"
                            % (label, a, b))
        elif a != b:
            problems.append("覆盖面【两条路对不上】:%s pg_catalog=%d vs information_schema=%d"
                            % (label, a, b))
        else:
            notes.append("%-9s universe %d(两条路一致)" % (label, a))
    if len(all_buckets) == 0:
        problems.append("覆盖面【为零】:一个存储桶都没数到 —— 那是坏了,不是零")
    else:
        notes.append("%-9s universe %d(两条路一致)" % ("bucket", len(all_buckets)))
    if matviews:
        problems.append("出现了 %d 个物化视图 —— 关系那条交叉核对【看不见它们】"
                        "(information_schema.tables 不显示物化视图)。"
                        "必须先扩写这个检查,而不是让它接着打印绿色。" % matviews)

    # ── 两条路的【结果】也必须一致 ────────────────────────────────────────
    for kind in ("relation", "function", "bucket", "column"):
        if live[kind] != second[kind]:
            only_a = sorted(live[kind] - second[kind])[:8]
            only_b = sorted(second[kind] - live[kind])[:8]
            problems.append("两条路对不上(%s):只在第一条里 %s;只在第二条里 %s"
                            % (kind, only_a or "—", only_b or "—"))
    return live, problems, notes


def compare(live: dict, base: dict) -> tuple:
    """线上必须是基线的子集。基线过宽只点名,不变红(见抬头)。"""
    problems, stale = [], []
    for kind in ("relation", "function", "bucket", "column"):
        extra = sorted(live[kind] - base[kind])
        if extra:
            problems.append("★ 线上多出基线之外的 %s:%s —— "
                            "给 anon 开一扇门必须是一件写下来的事" % (kind, extra))
        gone = sorted(base[kind] - live[kind])
        if gone:
            stale.append("基线里有、线上没有的 %s(基线过宽,请在下一次提交里删掉这几行):%s"
                         % (kind, gone))
    return problems, stale


# ── 注入格:两格都必须变红,而它们【每次都跑】────────────────────────────────
def injections(dsn: str) -> list:
    """★【"把解析器打瞎"是强制的一格】★(ANON-0 立的规矩)

    两格,坏法不一样:
      ① 把基线指向一个读不到的路径 —— 读基线那一步必须【抛】,不许当成空基线;
      ② 把关系那条查询打瞎(恒假)—— universe 变 0,必须变红。
    两格都跑在【每一次】正常运行之前。一个只在有人想起来时才跑的注入,
    与没有注入是同一件东西。
    """
    fails = []
    try:
        read_baseline(HERE / "__no_such_baseline__.tsv")
        fails.append("注入格①【没有变红】:一个读不到的基线被当成了空基线")
    except RuntimeError:
        pass
    _, problems, _ = measure(dsn, blind_relations=True, skip_http=True)
    if not any("为零" in p for p in problems):
        fails.append("注入格②【没有变红】:关系那条查询被打瞎(universe=0)之后仍然干净")
    return fails


def main() -> int:
    ap = argparse.ArgumentParser(description="anon 够得着什么 —— 基线只许缩小")
    ap.add_argument("--dsn", default=os.environ.get("CHECK_MIRRORS_DSN") or cm.DEFAULT_DSN)
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--injections-only", action="store_true")
    args = ap.parse_args()

    try:
        print("== db/check_grants.py —— anon 够得着什么(线上)")
        inj = injections(args.dsn)
        for f in inj:
            print("   ✗ " + f)
        print("   注入自检:%s(基线打瞎 · 查询打瞎)" % ("✗ 有一格没变红" if inj else "✓ 两格都变红"))
        if args.injections_only:
            return 1 if inj else 0

        live, problems, notes = measure(args.dsn)
        for n in notes:
            print("   " + n)
        print("   anon 够得着:关系 %d · 函数 %d · 公开桶 %d · 列级 ACL %d"
              % (len(live["relation"]), len(live["function"]),
                 len(live["bucket"]), len(live["column"])))
        if live["function"]:
            print("   函数(逐个点名,这一格【应该很短】):" + ", ".join(sorted(live["function"])))

        if args.write_baseline:
            write_baseline(BASELINE, live)
            print("   基线已写:%s" % BASELINE)
            return 0

        base = read_baseline(BASELINE)
        sub_problems, stale = compare(live, base)
        problems += inj + sub_problems
        for s in stale:
            print("   ⚠ " + s)
        if problems:
            print("判词【匿名面】:✗")
            for p in problems:
                print("   " + p)
            return 1
        print("判词【匿名面】:✓ 线上是基线的子集(基线 %d 条)"
              % sum(len(v) for v in base.values()))
        return 0
    except Unreachable as e:
        print("判词【匿名面】:够不到线上 —— 这是环境故障,不是仓库的毛病:%s" % e)
        print("   ★ 它【没有】离线版本,而那是刻意的:镜像里根本没有 GRANT,")
        print("     一个离线版本会什么都不断言却打印绿色。")
        return 5
    except Exception as e:
        print("判词【匿名面】:✗ 检查本身出错(这也是红的,不是通过):%s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())

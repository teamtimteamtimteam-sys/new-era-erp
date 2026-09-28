#!/usr/bin/env python3
"""HISTORY-1:生成 db/views/zzz_change_log_triggers.sql —— 每一张被记录的表两条触发器。

  zzz_change_log          AFTER INSERT OR UPDATE OR DELETE FOR EACH ROW  → change_log_capture(<主键列…>)
  zzz_change_log_truncate AFTER TRUNCATE FOR EACH STATEMENT              → change_log_capture()

【主键列从目录读】(pg_index.indisprimary,按 indkey 顺序)—— 241 张表里 19 张是复合主键、43 张是非 uuid
  的单列主键,所以主键不能假设成 id。读的是【只读】事务,不写任何东西。
【豁免名单只有一份】从 db/functions/change_log_exclusions.sql 的 VALUES 里读(与构建检查同一个解析)。
【为什么名字以 zzz 开头】同一张表上的 AFTER 触发器按名字排序触发 —— 让记录总是最后一个看到那一行。

跑法(仓库根目录):
    python3 db/scripts/gen_change_log_bindings.py                 # 读线上目录(只读)
    python3 db/scripts/gen_change_log_bindings.py --dsn "<dsn>"   # 读别的库
    python3 db/scripts/gen_change_log_bindings.py --only t1,t2    # 只为新表生成两行(贴进迁移与本文件)
新建一张表时:在迁移里给它这两条触发器,并把同样两行加进 db/views/zzz_change_log_triggers.sql;
或者在 change_log_exclusions() 里写一行带理由的豁免。两者都没有,构建与 gate 都会红(docs/change-log.md)。
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "db/views/zzz_change_log_triggers.sql"
DEFAULT_DSN = ("host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 "
               "user=postgres.wvywpohbwkiinmipmuku dbname=postgres")


def exclusions() -> list:
    src = (ROOT / "db/functions/change_log_exclusions.sql").read_text()
    code = "\n".join(l for l in src.splitlines() if not l.lstrip().startswith("--"))   # 注释里也有 "VALUES" 这个词
    body = code.split("VALUES")[-1]
    names = re.findall(r"\(\s*'([a-z0-9_]+)'(?:::text)?\s*,", body)
    if not names:
        sys.exit("gen_change_log_bindings: 豁免名单解析出 0 条 —— 解析器坏了,不是名单空了")
    return names


def pk_map(dsn: str) -> dict:
    sql = """
BEGIN READ ONLY;
SELECT c.relname || '|' || string_agg(a.attname, ',' ORDER BY k.ord)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_index i ON i.indrelid = c.oid AND i.indisprimary
  CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
 GROUP BY c.relname ORDER BY c.relname;
SELECT '#' || count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p');
ROLLBACK;
"""
    out = subprocess.run(["psql", dsn, "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"],
                         input=sql, capture_output=True, text=True, check=True).stdout
    pks, total = {}, None
    for line in out.splitlines():
        if line.startswith("#"):
            total = int(line[1:])
        elif "|" in line:
            t, cols = line.split("|", 1)
            pks[t] = cols.split(",")
    # 【覆盖率本身是一条断言】两条独立的数:有主键的表 vs 全部表。对不上 = 有表没主键,生成器不猜。
    if total is None or total != len(pks):
        sys.exit(f"gen_change_log_bindings: {total} 张表,{len(pks)} 张有主键 —— 没有主键的表记录不了 row_key,先处理它")
    return pks


def binding(t: str, cols: list) -> str:
    args = ", ".join(f"'{c}'" for c in cols)
    return (f"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.{t}\n"
            f"    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture({args});\n"
            f"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.{t}\n"
            f"    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();\n")


HEADER = """-- db/views/zzz_change_log_triggers.sql
-- HISTORY-1(2026-09-28):通用变更记录的触发器绑定 —— 每一张被记录的表两条。
-- ★ 生成的文件:db/scripts/gen_change_log_bindings.py。不要手改;新表用 --only 生成两行再贴进来。
--
-- 【为什么住在 db/views/ 而不是各自的表镜像里】与 zzz_function_grants.sql 同一个理由:重放顺序是
--   functions → tables → views,而 views 阶段按名字排、zzz 排最后 —— 到这里每一张表都已经建好。
--   一份文件放 {n} 张表的绑定,比在 {n} 个表镜像里各塞两行好审;check_mirrors 按表比对触发器清单,
--   与它们写在哪个文件里无关。
-- 【豁免】change_log_exclusions() 里那 {x} 张不在这里(理由写在那支函数里)。
-- 【名字以 zzz 开头】同一张表上的 AFTER 触发器按名字排序触发 —— 记录最后一个看到那一行。
-- 【参数是主键列名】change_log_capture 用它们拼 row_key;复合主键就是多个参数。

"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", default=DEFAULT_DSN)
    ap.add_argument("--only", default="")
    ap.add_argument("--stdout", action="store_true")
    a = ap.parse_args()
    ex = set(exclusions())
    pks = pk_map(a.dsn)
    # change_log 本身在它的迁移落地之前不在目录里 —— 那一条不算"点了不存在的表"。
    unknown = ex - set(pks) - {"change_log"}
    if unknown:
        sys.exit(f"gen_change_log_bindings: 豁免名单点了不存在的表 {sorted(unknown)}")
    only = [t for t in a.only.split(",") if t]
    tables = only or [t for t in sorted(pks) if t not in ex]
    body = "".join(binding(t, pks[t]) for t in tables)
    if only or a.stdout:
        sys.stdout.write(body)
        return 0
    OUT.write_text(HEADER.format(n=len(tables), x=len(ex)) + body)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(tables)} tables bound, {len(ex)} excluded, {len(pks)} in catalog")
    return 0


if __name__ == "__main__":
    sys.exit(main())

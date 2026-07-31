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
  * 比对维度:表 = 列(名/类型/可空/默认值,【按 attnum 顺序】)+ 约束 + 索引 +
    触发器 + RLS 开关 + 策略;函数 = pg_get_functiondef;视图 = pg_get_viewdef +
    reloptions(security_invoker)。定义文本先把 schema 前缀(mir./public.)剥掉
    再比,因此文件里的排版、约束写法(IN vs = ANY)都不影响结果 —— 目录归一化
    之后是二元的:一致,或不一致。
  * 覆盖:public 里存在而重放结果里没有 = 缺镜像;反之 = 镜像的对象已不在线上。
    表/视图/函数/序列/枚举都查,双向。排除扩展自带的对象(pg_depend deptype 'e')。
  * 【不比】:约束名(只比定义)、注释(COMMENT ON)、GRANT、序列参数与当前值、
    表存储参数。文件级排版(如尾随换行)也不在此查 —— 目录里没有这个概念。

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

    report = None
    for line in proc.stdout.splitlines():
        if line.startswith(MARKER):
            report = json.loads(line[len(MARKER):])
            break
    if report is None:
        sys.stderr.write("没有在输出里找到报告标记 —— psql 输出异常。\n")
        return 2

    Path(script).unlink(missing_ok=True)

    dirty = (
        report["table_drift"] or report["function_drift"] or report["view_drift"]
        or any(v for v in report["coverage"].values())
    )

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        s = report["summary"]
        print(f"tables    live {s['tables']['live']:3d}  mirrored {s['tables']['mirrored']:3d}  drifted {s['tables']['drifted']}")
        print(f"functions live {s['functions']['live']:3d}  mirrored {s['functions']['mirrored']:3d}  drifted {s['functions']['drifted']}")
        print(f"views     live {s['views']['live']:3d}  mirrored {s['views']['mirrored']:3d}  drifted {s['views']['drifted']}")
        for section in ("table_drift", "function_drift", "view_drift"):
            for k, v in report[section].items():
                print(f"  DRIFT [{section}] {k}: {json.dumps(v, ensure_ascii=False)[:400]}")
        for k, v in report["coverage"].items():
            if v:
                print(f"  COVERAGE {k}: {json.dumps(v, ensure_ascii=False)}")
        print("clean bill of health ✓" if not dirty else "drift / coverage gaps found ✗")

    return 1 if dirty else 0


if __name__ == "__main__":
    sys.exit(main())

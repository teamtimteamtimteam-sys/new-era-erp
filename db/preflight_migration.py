#!/usr/bin/env python3
"""迁移预检(OPS-7)—— 在 db/apply_migration.sh 动库之前,先读一遍迁移文件本身。

【为什么存在】同两个缺陷已经重演过:

  * 新函数留在 anon 可执行 —— 三次(FIN-22 / FIN-23 / FIN-27)。这一条【不由本
    脚本检测】,由 apply_migration.sh 在同一个事务里重跑
    db/views/zzz_function_grants.sql 直接消灭:线上不可能再出现没收权的新函数。
    预防比检测强,所以那一半不在这里。
  * 硬编码了一个还没打 is_system 的科目码 —— 两次。重建出来的库不带这个科目,
    引擎却点名要它。
  * CREATE OR REPLACE FUNCTION 的签名与线上同名函数【不一致】—— 那不是替换,
    是【重载】:旧签名原样活着,变成没人知道的漂移。FIN-21 被这个咬过。

前两次之后,这些都被写进了"下次记得检查"。写下来的提醒对下一次没有作用 ——
它恰恰是又犯一次的原因。所以改成工具做。

【两条判据,两种处置,理由不同】

  科目码 → 警告并继续。因为【预检读的是还没执行的文件】:一支迁移完全可以在同
    一个文件里既引用 4100 又把它 promote 成 is_system,那时"还没 is_system"是真
    的、拒绝却是错的。预检看不到执行后的状态,所以它没有资格下拒绝。
    它的职责是把这件事说出来,让人当场决定,而不是等一个月后 check_mirrors
    在别人的机器上变红。

  重载 → 拒绝。两个签名同名共存,在这个仓库里【没有任何一种情况是故意的】:
    函数镜像是一文件一函数、一函数一签名(pg_get_functiondef 的原样字节),
    check_mirrors 比对的是目录,多出来的那个旧签名会一直在线上活着而镜像里
    没有它。而且这一条不需要看执行后的状态就能判定 —— 线上现在有什么签名,
    现在就查得到。判据确定 ⇒ 可以拒绝。

【只对"现在要应用的这一支"有意义】重载判据比对的是【此刻的线上目录】。把它拿去
扫历史迁移会大量误报:一支 7 月的迁移当然带着 7 月的签名,而那个签名后来被更宽的
版本取代了(record_expense、record_output_sale 都是这样)。历史迁移在本仓库是
changelog,不重放 —— 别把这个脚本当成对历史的审计。

用法:
    python3 db/preflight_migration.py db/migrations/<file>.sql [--dsn ...]

退出码:0 = 放行(可能带警告)· 2 = 拒绝 · 3 = 预检本身失败(连不上/解析不出)
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# 【复用,不另写第二份】科目码的判据(正则 + 例外名单)只有 check_mirrors 那一处。
from check_mirrors import DEFAULT_DSN, account_codes_in_text  # noqa: E402


# ── 函数签名 ────────────────────────────────────────────────────────────────
# 只认【行首】的 CREATE [OR REPLACE] FUNCTION:函数体里的注释与字符串不会顶到行首
# (本仓库的排版惯例),而注释行在下面显式跳过。
FUNC_RE = re.compile(
    r"^[ \t]*CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:([a-z0-9_]+)\.)?([a-z0-9_]+)\s*\(",
    re.I | re.M)


def _split_top_level(s: str) -> list:
    """按【顶层】逗号切分参数表 —— numeric(10,2) 里的逗号不算。"""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [a.strip() for a in out if a.strip()]


def parse_signatures(sql: str) -> list:
    """→ [(schema, name, [参数原文, ...]), ...];注释行不参与。"""
    body = noncomment(sql)
    sigs = []
    for m in FUNC_RE.finditer(body):
        schema = (m.group(1) or "public").lower()
        name = m.group(2).lower()
        # 从左括号起做括号配平,取出完整参数表
        i, depth = m.end() - 1, 0
        for j in range(m.end() - 1, len(body)):
            if body[j] == "(":
                depth += 1
            elif body[j] == ")":
                depth -= 1
                if depth == 0:
                    i = j
                    break
        sigs.append((schema, name, _split_top_level(body[m.end():i])))
    return sigs


def arg_type_candidates(arg: str) -> list:
    """一个参数原文 → 候选类型串,先"去掉参数名"再"原样"。

    参数模式:OUT 不进签名(pg_get_function_identity_arguments 不含它),
    VARIADIC 要保留关键字,IN/INOUT 去掉。
    """
    a = re.sub(r"\s+DEFAULT\s+.*$", "", arg, flags=re.I | re.S).strip()
    a = re.sub(r"\s*:=.*$", "", a).strip()
    toks = a.split()
    if not toks:
        return []
    prefix = ""
    if toks[0].upper() == "OUT":
        return []                      # 不进签名
    if toks[0].upper() == "VARIADIC":
        prefix, toks = "VARIADIC ", toks[1:]
    elif toks[0].upper() in ("IN", "INOUT"):
        toks = toks[1:]
    rest = " ".join(toks)
    cands = []
    if len(toks) > 1:                  # 多半是 "p_foo uuid":先试去掉参数名
        cands.append(prefix + " ".join(toks[1:]))
    cands.append(prefix + rest)
    return cands


def psql(dsn: str, sql: str, cols: int = 2) -> list:
    """跑一段 SQL,取制表符分隔的行。

    【只剥换行,不要 .strip()】末列为空时输出以制表符结尾,整体 .strip() 会把
    那个制表符一并吃掉,于是最后一行少一列 —— 解包当场炸,而且只在"最后一个
    候选恰好解析不出"时才炸。行按 cols 补齐,形状由调用方说了算,不由数据决定。
    """
    r = subprocess.run(["psql", dsn, "-X", "-q", "-A", "-t", "-F", "\t", "-f", "-"],
                       input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        raise SystemExit(3)
    out = []
    for l in r.stdout.strip("\n").splitlines():
        if not l:
            continue
        f = l.split("\t")
        out.append((f + [""] * cols)[:cols])
    return out


HELPERS = """
-- 会话内的安全解析器:to_regtype / to_regprocedure 对【语法不合法】的串是抛错而
-- 不是返回 NULL,所以包一层。pg_temp 里,断开即消失,线上目录不留痕。
CREATE FUNCTION pg_temp.safe_regtype(t text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN RETURN to_regtype(t)::text; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
CREATE FUNCTION pg_temp.safe_regprocedure(t text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN RETURN to_regprocedure(t)::text; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
"""


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def noncomment(sql: str) -> str:
    """去掉整行注释 —— 注释里提一句不是一次改动(与科目码扫描同一条规矩)。"""
    return "\n".join(l for l in sql.splitlines() if not l.lstrip().startswith("--"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("migration")
    ap.add_argument("--dsn", default=os.environ.get("CHECK_MIRRORS_DSN") or DEFAULT_DSN)
    args = ap.parse_args()

    path = Path(args.migration)
    if not path.is_file():
        print(f"✗ 预检:读不到 {path}", file=sys.stderr)
        return 3
    sql = path.read_text()

    print(f"== 预检 {path.name}")
    warnings, refusals = [], []

    # ── 1. 科目码:引用了却没打 is_system(或压根不在 accounts 里)────────────
    codes = sorted(account_codes_in_text(sql))
    if codes:
        rows = psql(args.dsn, HELPERS + "SELECT c, "
                    "coalesce((SELECT CASE WHEN a.is_system THEN 'is_system' ELSE 'plain' END "
                    "FROM public.accounts a WHERE a.code = c), 'absent') "
                    f"FROM unnest(ARRAY[{','.join(q(c) for c in codes)}]::text[]) c ORDER BY c;")
        bad = [(c, st) for c, st in rows if st != "is_system"]
        ok = len(rows) - len(bad)
        print(f"account    引用 {len(rows)} 个科目码,{ok} 个已 is_system"
              + ("" if not bad else f",{len(bad)} 个不是 ✗"))
        for c, st in bad:
            what = "不在 accounts 里" if st == "absent" else "存在但没打 is_system"
            warnings.append(f"科目 {c}:{what} —— 重建出来的库不会带它,而这支迁移点名要它")
        # 只看【非注释行】:抬头里写一句"没打 is_system"不是一次 promote。
        # (第一版就这么误报过 —— 判据必须落在会执行的那部分文本上。)
        if bad and re.search(r"is_system", noncomment(sql), re.I):
            warnings.append("本迁移自己动了 is_system —— 若上面这些码就是它 promote 的,"
                            "这条警告即可忽略(预检读的是执行【前】的库)")
    else:
        print("account    未引用任何科目码")

    # ── 2. 重载:同名、不同签名 ──────────────────────────────────────────────
    sigs = parse_signatures(sql)
    n_stmts = len(re.findall(r"^[ \t]*CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION",
                             noncomment(sql), re.I | re.M))
    if n_stmts and not sigs:
        # 【解析出零个不是"没有函数"】—— 与 check-i18n 对解析器的要求同一条规矩
        print(f"✗ 预检:文件里有 {n_stmts} 条 CREATE FUNCTION,解析器一条签名都没取出来 —— "
              "解析器坏了,不是文件里没有", file=sys.stderr)
        return 3

    if sigs:
        # 一次问清:每个参数的类型串怎么解析、每个完整签名线上有没有、同名的线上有什么
        cand_list, cand_idx = [], []
        for si, (_, _, argl) in enumerate(sigs):
            for ai, a in enumerate(argl):
                for c in arg_type_candidates(a):
                    cand_idx.append((si, ai, c))
                    cand_list.append(c)
        resolved = {}
        if cand_list:
            rows = psql(args.dsn, HELPERS + "SELECT c, coalesce(pg_temp.safe_regtype(c),'') "
                        f"FROM unnest(ARRAY[{','.join(q(c) for c in cand_list)}]::text[]) c;")
            resolved = {c: t for c, t in rows}

        built, unparsed = [], []
        for si, (schema, name, argl) in enumerate(sigs):
            types, ok = [], True
            for ai, a in enumerate(argl):
                hit = next((c for c in arg_type_candidates(a) if resolved.get(c)), None)
                if hit is None:
                    ok = False
                    break
                types.append(resolved[hit])
            if ok:
                built.append((si, f"{schema}.{name}({','.join(types)})"))
            else:
                unparsed.append(f"{schema}.{name}")

        names = sorted({f"{s}.{n}" for s, n, _ in sigs})
        rows = psql(args.dsn, HELPERS
                    + "SELECT v.sig, coalesce(pg_temp.safe_regprocedure(v.sig),'') "
                    f"FROM (VALUES {','.join('(' + q(s) + ')' for _, s in built)}) v(sig);"
                    if built else HELPERS + "SELECT '',''; ")
        exists = {sig: got for sig, got in rows if sig}

        live = {}
        for nm, sig in psql(args.dsn,
                            "SELECT n.nspname||'.'||p.proname, p.oid::regprocedure::text "
                            "FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace "
                            f"WHERE n.nspname||'.'||p.proname IN ({','.join(q(n) for n in names)}) "
                            "AND p.prokind='f' ORDER BY 1,2;"):
            live.setdefault(nm, []).append(sig)

        new, repl = 0, 0
        for si, sig in built:
            schema, name, _ = sigs[si]
            key = f"{schema}.{name}"
            if exists.get(sig):
                repl += 1
            elif key in live:
                refusals.append(
                    f"{sig} 与线上同名函数【签名不同】—— 这是重载,不是替换。"
                    f"线上现有:{', '.join(live[key])}。旧签名会原样活下去,"
                    f"而镜像里只有一个 —— 先 DROP 旧签名(在同一支迁移里),或对齐签名")
            else:
                new += 1
        print(f"function   {len(sigs)} 条 CREATE FUNCTION:{repl} 替换 · {new} 新建"
              + (f" · {len(refusals)} 重载 ✗" if refusals else "")
              + (f" · {len(unparsed)} 条签名解析不出({', '.join(unparsed)})" if unparsed else ""))
        for u in unparsed:
            warnings.append(f"{u}:参数类型解析不出,重载这一条【没查】—— 请自己确认签名与线上一致")
    else:
        print("function   本迁移不建函数")

    for w in warnings:
        print(f"  ⚠ {w}")
    for r in refusals:
        print(f"  ✗ {r}")

    if refusals:
        print("✗ 预检拒绝:重载会在线上留下两个版本的同名函数,而镜像只记得一个", file=sys.stderr)
        return 2
    print("✓ 预检通过" + (f"(带 {len(warnings)} 条警告,已放行)" if warnings else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

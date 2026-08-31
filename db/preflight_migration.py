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


def _dropped_before(dropped_fn, schema, name, si, sigs, sql):
    """本文件里、在这条 CREATE 之前,是否 DROP 掉了同名函数的【另一个】签名。

    比名字 + 参数个数;个数相同再比【类型序列】(PROC-1b):把参数挪进默认值区是
    合法的替换 —— 个数没变、顺序变了 —— 而被显式 DROP 的旧签名不可能活下去。
    放行不牺牲安全:DROP 打错签名会让整支迁移在单事务里当场中止(apply_migration
    的 all-or-nothing),留不下半个库。仍然拦住的是【类型序列也相同】的情形 ——
    那是在 DROP 自己要建的东西,线上真正的旧签名照样活下去。
    """
    want = (schema.lower(), name.lower())
    n_new = len(sigs[si][2])
    new_types = []
    for a in sigs[si][2]:
        c = arg_type_candidates(a)
        new_types.append(re.sub(r"\s+", " ", (c[0] if c else a)).lower())
    for pos, dsch, dname, dargs in dropped_fn:
        if (dsch, dname) != want:
            continue
        if len(dargs) != n_new:
            return True
        d_types = [re.sub(r"\s+", " ", d).lower() for d in dargs]
        if d_types != new_types:
            return True
    return False



# ── CHECK-1:遮蔽表加列 —— 【与 gate 同一条规矩,只是把钟拨早】 ─────────────────
# 【为什么这一条在预检,而 gate 明明已经有了】
# db/gate.py 的 colgrant(GRANT_GAP_SQL)一直看得见这件事,而且【线上与重建两侧
# 都问】。三次事故(PROC-COST-1 fu2 / PROC-WIRE-1B-i fu1 / PROC-1B-iii fu1)
# **没有一次是它漏了** —— 它每一次都会红。问题是它红得【太晚】:gate 是收尾的门,
# 那时 DDL 已经在线上了,于是每一次都要再写一支 fu 迁移去补,中间是一段
# 「列存在、每个用户都读不到」的窗口。而那个症状会伪装 —— 读出来是"未记录",
# 而"未记录"往往是一个合法状态,所以没有人会去查。
#
# 所以本条不是新判据,是【同一条判据、更早的钟】:apply_migration.sh 在动库
# 【之前】读这支迁移,不合规就【拒绝】,DDL 根本不落地。
#
# 【判据必须与 gate 逐字相同,这一条是决定性的】
#   (granted OR in_view) AND (has_view → in_view)
# 一支比 gate 更严的预检,会拒掉 gate 本来会放行的迁移 —— 而人学到的不是
# "写对",是 `PREFLIGHT=0`。**一个被人关掉的检查比没有检查更坏。**
# 由于这里 has_view 恒为真(不是遮蔽表就不查),它收敛成一句:
#   **这一列必须出现在 <表>_masked 里** —— 授不授权都一样。
#   授权是【第二个问题】:授了 = 原样透出,没授 = 视图里用 has_permission CASE
#   遮起来。**没授权不是缺陷** —— 一列价格本来就该是没授权的。
#   (委托书原本要求"缺授权即失败";那会把每一列刻意遮蔽的价格列都判红。)
#
# 【它看得见什么】ALTER TABLE <表> ADD COLUMN <列>,而 <表> 在线上有 _masked 伴生
#   (或本迁移自己建了那张伴生视图)。
# 【它看不见什么 —— 点名】
#   ✗ 动态 DDL(EXECUTE format(...) 拼出来的 ALTER)—— 文本里没有 ADD COLUMN;
#   ✗ 【本迁移新建】一张遮蔽表:那是 CREATE TABLE,不走 ADD COLUMN 这条路;
#   ✗ 列【在视图里但没被 has_permission 包住】—— 那是反过来的病(该遮的没遮),
#     gate 也不看,本条不冒充看得见;
#   ✗ 视图输出列靠文本识别(`AS <列>` 或独占一行的列名)。视图体若不是
#     pg_get_viewdef 那种一列一行的排版,可能【放过】一处 —— 宁可漏,不可误拒。
def _added_columns(sql: str) -> list:
    """(表名, 列名) —— 本迁移 ALTER TABLE ... ADD COLUMN 加的列。"""
    out = []
    for m in re.finditer(r"\bALTER\s+TABLE\s+(?:ONLY\s+)?(?:public\s*\.\s*)?"
                         r"([a-zA-Z_][\w$]*)([^;]*);", noncomment(sql), re.I):
        tbl, body = m.group(1).lower(), m.group(2)
        for c in re.finditer(r"\bADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?"
                             r"([a-zA-Z_][\w$]*)", body, re.I):
            out.append((tbl, c.group(1).lower()))
    return out


def _granted_columns(sql: str) -> set:
    """(表名, 列名) —— 本迁移 GRANT SELECT (…) ON <表> 授出去的列。"""
    out = set()
    for m in re.finditer(r"\bGRANT\s+SELECT\s*\(([^)]*)\)\s*ON\s+(?:TABLE\s+)?"
                         r"(?:public\s*\.\s*)?([a-zA-Z_][\w$]*)", noncomment(sql), re.I):
        tbl = m.group(2).lower()
        for c in m.group(1).split(","):
            c = c.strip().lower()
            if c:
                out.add((tbl, c))
    return out


def _masked_view_bodies(sql: str) -> dict:
    """<表> → 本迁移里 <表>_masked 的视图体(CREATE [OR REPLACE] VIEW ... ;)。"""
    out = {}
    for m in re.finditer(r"\bCREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+"
                         r"(?:public\s*\.\s*)?([a-zA-Z_][\w$]*)_masked\b([^;]*);",
                         noncomment(sql), re.I):
        out[m.group(1).lower()] = m.group(2)
    return out


def _view_output_columns(body: str) -> set:
    """视图体里【输出列】的名字 —— 按顶层逗号切 SELECT 列表,而不是按行。

    【为什么不能按行切】第一版是"独占一行的标识符算一列"。它在本仓库大多数
    _masked 视图上碰巧对(pg_get_viewdef 一列一行),而 CHECK-1 的红/绿演示里
    **一行写两列就当场误拒了一支完全正确的迁移**。误拒比漏报坏得多:
    漏报只是没抓到,误拒会让人去关掉这道预检。所以改成真的切列表。
    """
    m = re.search(r"\bSELECT\b", body, re.I)
    if not m:
        return set()
    items, depth, cur, k, n = [], 0, [], m.end(), len(body)
    while k < n:
        ch = body[k]
        if ch == "'":                      # 跳过字符串字面量
            cur.append(ch); k += 1
            while k < n and body[k] != "'":
                cur.append(body[k]); k += 1
            if k < n:
                cur.append(body[k]); k += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif depth == 0:
            if ch == ",":
                items.append("".join(cur)); cur = []; k += 1; continue
            # 顶层 FROM 结束选择列表
            if ch.upper() == "F" and re.match(r"FROM\b", body[k:k + 5], re.I) \
                    and (k == 0 or not (body[k - 1].isalnum() or body[k - 1] == "_")):
                break
        cur.append(ch); k += 1
    items.append("".join(cur))

    cols = set()
    for it in items:
        it = re.sub(r"--[^\n]*", " ", it).strip()
        if not it:
            continue
        a = re.search(r"\bAS\s+([a-zA-Z_][\w$]*)\s*$", it, re.I | re.S)
        if a:
            cols.add(a.group(1).lower()); continue
        # 没有别名:输出名就是最后一个标识符(处理 x、t.x、schema.t.x)
        idents = re.findall(r"[a-zA-Z_][\w$]*", it)
        if idents:
            cols.add(idents[-1].lower())
    return cols


def check_masked_columns(sql: str, dsn: str) -> tuple:
    """返回 (状态行, refusals)。见上方抬头:与 gate 的 colgrant 同一条判据。"""
    added = _added_columns(sql)
    if not added:
        return "masked     本迁移不加列", []

    tables = sorted({t for t, _ in added})
    rows = psql(dsn, "SELECT t, (EXISTS (SELECT 1 FROM information_schema.tables v "
                     "WHERE v.table_schema='public' AND v.table_name = t || '_masked'))::text "
                     f"FROM unnest(ARRAY[{','.join(q(t) for t in tables)}]::text[]) t ORDER BY t;")
    # 【解析出零行不是"没有表"】—— 与本仓库对"零必须是测量"的一贯口径一致。
    if len(rows) != len(tables):
        raise SystemExit(f"✗ 预检:问了 {len(tables)} 张表的遮蔽状态,只回来 {len(rows)} 行 —— "
                         "查不了不等于没问题,不放行")
    in_migration_views = _masked_view_bodies(sql)
    masked = {t for t, has in rows if has == "true"} | set(in_migration_views)

    granted = _granted_columns(sql)
    view_cols = {t: _view_output_columns(b) for t, b in in_migration_views.items()}

    refusals, checked = [], 0
    for tbl, col in added:
        if tbl not in masked:
            continue
        checked += 1
        in_view = col in view_cols.get(tbl, set())
        if in_view:
            continue
        how = "已在本迁移里授权" if (tbl, col) in granted else "本迁移没有授权它"
        refusals.append(
            f"{tbl}.{col}:{tbl} 是【遮蔽表】(有 {tbl}_masked 伴生),而这一列不在 "
            f"{tbl}_masked 里({how})。\n"
            f"      一张表一旦有了 _masked 伴生,**每一列都必须在那张视图里** —— "
            f"授权与否是第二个问题(授了=原样透出,没授=视图里用 has_permission CASE 遮住)。\n"
            f"      不补上的后果:这一列写得进、【每一个登录用户都读不出】,"
            f"而屏幕上它长得和「未填写」一模一样 —— 一个字的报错都不会有。\n"
            f"      【怎么改】在同一支迁移里 CREATE OR REPLACE VIEW public.{tbl}_masked,"
            f"把 {col} 加进去(CREATE OR REPLACE 只允许在末尾追加列,而 ALTER 加的列"
            f"本来就排在末尾,顺序天然对得上)。")
    line = (f"masked     加了 {len(added)} 列,其中 {checked} 列落在遮蔽表上"
            + ("" if not refusals else f",{len(refusals)} 列不在 _masked 视图里 ✗"))
    return line, refusals


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
    # 【先认下本文件自己的 DROP】预检读的是执行【前】的库,所以一支合法的
    # "DROP 旧签名 → CREATE 新签名" 迁移在这里看上去和一次重载一模一样 ——
    # 而这正是本检查自己的错误信息让人去做的事(FIN-36 第一次撞上)。
    # 只认【本文件里、在该 CREATE 之前】出现的 DROP:顺序错了,线上照样留两个版本。
    dropped_fn = []
    for m in re.finditer(r"\bDROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?"
                         r"([a-zA-Z_][\w$]*)\s*\.\s*([a-zA-Z_][\w$]*)\s*\(([^)]*)\)",
                         noncomment(sql), re.I):
        dropped_fn.append((m.start(), m.group(1).lower(), m.group(2).lower(),
                           [a.strip() for a in m.group(3).split(',') if a.strip()]))

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
            elif key in live and not _dropped_before(dropped_fn, schema, name, si, sigs, sql):
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

    # ── 3. DROP 而不 CREATE:警告,不拒绝(SAL-A 的半份迁移事故)──────────────
    # 组装脚本在断言上失败、而文件里已经写好了 DROP —— 迁移带着 DROP、缺着 CREATE
    # 落到线上,record_output_sale 消失了几分钟。镜像判词【会】在下一次 gate 抓到它
    # (mirrors_without_live_fn),所以这条警告买到的是【那几分钟】,不是正确性 ——
    # 但那几分钟里线上函数是缺的,五行代码换它值得。
    # 【只警告】:永久移除一个函数是正当的(全史 113 支迁移里有 4 次,HR-2c 退役了
    # 三个 GrantRunner 时代的函数、FIN-22b 退役了 record_expense),而文件自己分不清
    # "有意退役"与"组装漏了半截"。有意的读一行警告继续走;decidable-now-may-refuse
    # 在这里反着切 —— 可判定的是"没重建",不可判定的是"该不该"。
    dropped_names = set()
    for m in re.finditer(r"\bDROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?"
                         r"(?:([a-zA-Z_][\w$]*)\s*\.\s*)?([a-zA-Z_][\w$]*)",
                         noncomment(sql), re.I):
        dropped_names.add(m.group(2).lower())
    created_names = {n.lower() for _, n, _ in sigs}
    for name in sorted(dropped_names - created_names):
        warnings.append(f"本迁移 DROP 了 {name} 而没有再 CREATE 它 —— 若是有意退役,"
                        f"照常继续;若你以为文件里有新版本,它不在(组装漏了半截,"
                        f"SAL-A 那次线上函数缺了几分钟)")

    # ── 4. 遮蔽表加列(CHECK-1)—— 与 gate 的 colgrant 同一条判据,只是更早 ────
    masked_line, masked_refusals = check_masked_columns(sql, args.dsn)
    print(masked_line)
    refusals.extend(masked_refusals)

    for w in warnings:
        print(f"  ⚠ {w}")
    for r in refusals:
        print(f"  ✗ {r}")

    if refusals:
        print("✗ 预检拒绝 —— 见上面的 ✗ 条目(重载 / 遮蔽表缺列)", file=sys.stderr)
        return 2
    print("✓ 预检通过" + (f"(带 {len(warnings)} 条警告,已放行)" if warnings else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""SEARCH-2b · 迁移 B 的生成器 —— 44 支函数体的【机械变换】,连同它自己的证明。

════════════════════════════════════════════════════════════════════════════
★ 为什么是生成器,不是手写的迁移 ★
════════════════════════════════════════════════════════════════════════════
T1 的裁定是 prefix-as-data:43 处各自保留算法,前缀从表里读。落到函数体上,
这是一次【机械变换】—— 每一支把它那一个前缀字面量换成 document_type_prefix('<key>'),
**别的一个字节都不许动**。

手写 44 支函数体(合计 20 万字节)会在某一支里顺手改掉别的东西,而没有任何一道闸
看得见:签名没变、镜像会被一起改成新的样子、fixture 只证"下一个号"。
☞ 所以变换由脚本做,而脚本【断言自己只改了那些位置】:
  每一支变换前后的文本,除去被替换的那些字面量之外必须逐字节相同。
  这条断言就是 (g) 的另一半 —— fixture 证的是【下一个号相等】,
  它证的是【别处什么都没动】。

★★ 而这一支比上一会话点名的多【一支】:44,不是 43 ★★
  SEARCH-2 的六轮统计出 20 + 9 + 13 + 1 = 43。那个 1 是 fin_next_payment_code,
  它【本身没有字面量】(前缀是参数),要改的是它的调用方。上一会话找到了
  record_payment:635 的 CASE WHEN … 'RCPT' … 'PMT',**没有找到 reverse_payment:26
  那一条一模一样的**。实测(对全部 public 函数逐支扫 40 个前缀,见抬头的 SQL):
  reverse_payment 同样带着 'RCPT' 与 'PMT'。
  ☞ 这正是 AGENTS.md 「42 支 → 45 支,差的 5 支不叫那个名字」那一条的重演:
    按名字枚举的清单会漏掉不叫那个名字的成员。这里按【字面量所在的空间】枚举。
  T1 说「任何前缀字面量不许活在种子之外」—— 那是一条裁定,而 reverse_payment
  落在它管的范围里。**这不是重开裁定,是把它应用完。**

用法:
    python3 db/migrations/2026-09-13-search2b-document-types.build.py --check
        只做变换与断言,不写任何文件(变换前的库上可跑,变换后也可跑)。
    python3 db/migrations/2026-09-13-search2b-document-types.build.py --emit
        写出迁移文件 + 44 个镜像的新内容。
"""

import argparse
import contextlib
import importlib.util
import io
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DSN = ("host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 "
       "user=postgres.wvywpohbwkiinmipmuku dbname=postgres")

SEED_PY = Path(__file__).with_name("2026-09-13-search2b-document-types.seed.py")
MIGRATION = Path(__file__).with_name("2026-09-13-search2b-document-types.sql")

# ── 44 支函数体,逐支写明【它带的是哪个 key 的前缀,带了几处】──────────────
#    数量是断言,不是注释:变换实际替换掉的处数与这里不符 ⇒ 脚本失败。
#    '-' 结尾的那一族写成 <PFX>- ;RCPT/PMT 那两处是【裸字面量】,单独一族。
DASHED = {
    # ── A · 20 支专职 next_*_code(gapless · MAX(split_part)+1 + advisory lock)
    "next_assay_code":             [("assay_result", 2)],
    "next_chase_code":             [("collection_chase", 2)],
    "next_cod_code":               [("cod", 2)],
    "next_container_code":         [("container", 2)],
    "next_credit_note_code":       [("credit_note", 2)],
    "next_employee_code":          [("employee", 2)],
    "next_expense_claim_code":     [("expense_claim", 2)],
    "next_fixed_asset_code":       [("fixed_asset", 2)],
    "next_forecast_code":          [("cash_forecast", 2)],
    "next_leave_request_code":     [("leave_request", 2)],
    "next_medical_claim_code":     [("medical_claim", 2)],
    "next_payroll_code":           [("payroll_period", 2)],
    "next_pricing_formula_code":   [("pricing_formula", 2)],
    "next_purchase_order_code":    [("purchase_order", 2)],
    "next_quote_code":             [("quote", 2)],
    "next_sales_order_code":       [("sales_order", 2)],
    "next_shipment_code":          [("shipment", 2)],
    "next_statement_code":         [("customer_statement", 2)],
    "next_traceability_report_code": [("traceability_report", 2)],
    "next_work_order_code":        [("work_order", 2)],
    # ── B · 9 支触发器(gapped · nextval —— 镜像住在 db/tables/*.sql 里)
    "assign_contract_code":        [("contract", 1)],
    "generate_customer_code":      [("customer", 1)],
    "generate_inbound_code":       [("inbound_batch", 1)],
    "generate_material_code":      [("material", 1)],
    "generate_output_code":        [("output_batch", 1)],
    "generate_processing_code":    [("processing_run", 1)],
    "generate_stocktake_code":     [("stocktake", 1)],
    "generate_supplier_code":      [("supplier", 1)],
    "generate_task_code":          [("task", 1)],
    # ── C · 13 支内联(住在业务函数体里)
    "create_invoice":              [("invoice", 2)],
    "create_order_invoice":        [("invoice", 2)],
    "freeze_management_pack":      [("management_pack", 1)],
    "import_bank_statement":       [("bank_statement", 2)],
    "open_attendance_period":      [("attendance_period", 1)],
    "open_gst_period":             [("gst_period", 1)],
    "post_journal_entry":          [("journal_entry", 2)],
    "record_expense":              [("expense", 2)],
    "record_export_freight_document": [("freight_document", 2)],
    "record_freight_document":     [("freight_document", 2)],
    "relieve_processing_accruals": [("expense", 2)],
    "remit_wht":                   [("wht_remittance", 1)],
    "reverse_expense":             [("expense", 2)],
}
# ── D · 参数化那一族的【两个调用方】—— 裸字面量,没有尾随的 '-'
BARE = {
    "record_payment":  [("payment_receipt", 1), ("payment_out", 1)],
    "reverse_payment": [("payment_receipt", 1), ("payment_out", 1)],
}

# 镜像住在 db/tables/<表>.sql 里的那 9 支(其余 35 支在 db/functions/<名>.sql)
IN_TABLE_MIRROR = {
    "assign_contract_code":     "contracts",
    "generate_customer_code":   "customers",
    "generate_inbound_code":    "inbound_batches",
    "generate_material_code":   "materials",
    "generate_output_code":     "output_batches",
    "generate_processing_code": "processing_runs",
    "generate_stocktake_code":  "stocktakes",
    "generate_supplier_code":   "suppliers",
    "generate_task_code":       "tasks",
}


def load_seed():
    # 种子脚本在模块层就 print 出 INSERT —— 导入它是为了拿 ROWS,不是为了那段输出。
    spec = importlib.util.spec_from_file_location("seed", SEED_PY)
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()):
        spec.loader.exec_module(mod)
    return mod


def live_def(name):
    out = subprocess.run(
        ["psql", DSN, "-X", "-q", "-A", "-t", "-c",
         "select pg_get_functiondef(p.oid) from pg_proc p "
         "join pg_namespace n on n.oid=p.pronamespace "
         f"where n.nspname='public' and p.proname='{name}'"],
        capture_output=True, text=True, check=True)
    body = out.stdout
    if not body.strip():
        sys.exit(f"✗ 线上找不到函数 {name}")
    return body


def transform(text, name, key_prefix):
    """把 name 这一支里的前缀字面量换成 document_type_prefix('<key>')。

    ★ 断言在这里,不在别处:替换处数必须与 DASHED/BARE 里写死的数字一致,
      而且【除掉被替换的那些位置之外,前后逐字节相同】。
    """
    subs = []
    for key, n in DASHED.get(name, []):
        pfx = key_prefix[key]
        subs.append((f"'{pfx}-'", f"document_type_prefix('{key}') || '-'", n))
    for key, n in BARE.get(name, []):
        pfx = key_prefix[key]
        subs.append((f"'{pfx}'", f"document_type_prefix('{key}')", n))

    new = text
    for old, repl, expected in subs:
        hits = new.count(old)
        if hits != expected:
            sys.exit(f"✗ {name}: 期待 {expected} 处 {old},实测 {hits} 处 —— 不替换,停")
        new = new.replace(old, repl)

    # ── 逐字节复核:把替换【倒回去】,必须复原成原文 ──────────────────────
    back = new
    for old, repl, _ in subs:
        back = back.replace(repl, old)
    if back != text:
        sys.exit(f"✗ {name}: 反向复原与原文不符 —— 变换动了不该动的字节,停")
    return new


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", action="store_true")
    ap.add_argument("--from-mirrors", action="store_true",
                    help="迁移体从镜像读,不连线上(B 应用之后复现用)")
    args = ap.parse_args()

    seed = load_seed()
    key_prefix = {r[0]: r[1] for r in seed.ROWS}
    assert len(key_prefix) == 40

    names = sorted(set(DASHED) | set(BARE))
    assert len(names) == 44, f"expected 44 bodies, got {len(names)}"

    # 40 个 key 必须全部被至少一处函数体引用 —— 否则种子里有一行没人用,
    # 或者有一支函数体没被点名。这条断言是【覆盖率本身也是一条断言】。
    used = {k for v in DASHED.values() for k, _ in v} | {k for v in BARE.values() for k, _ in v}
    missing = set(key_prefix) - used
    if missing:
        sys.exit(f"✗ 种子里这些 key 没有任何函数体引用:{sorted(missing)}")

    bodies = {}
    for name in names:
        src = live_def(name)
        bodies[name] = transform(src, name, key_prefix)
    print(f"✓ 44 支函数体变换完成,每一支的反向复原都逐字节等于原文")

    # ── 镜像:同一次替换落在镜像文件上(它们带自己的抬头注释,要保住)────
    mirror_writes = []
    for name in names:
        if name in IN_TABLE_MIRROR:
            p = REPO / "db" / "tables" / f"{IN_TABLE_MIRROR[name]}.sql"
        else:
            p = REPO / "db" / "functions" / f"{name}.sql"
        if not p.exists():
            sys.exit(f"✗ 找不到镜像 {p}")
        txt = p.read_text()
        new = transform(txt, name, key_prefix)
        mirror_writes.append((p, new))

    print(f"✓ 44 个镜像的替换也各自反向复原成功")

    if not args.emit:
        print("== --check 模式:一个文件都没写")
        return

    bodies_sql = "\n\n".join(
        f"-- ── {name} ──────────────────────────────────────────────────────\n"
        + bodies[name].rstrip("\n") + ";"
        for name in names)
    seed_sql = subprocess.run([sys.executable, str(SEED_PY)],
                              capture_output=True, text=True, check=True).stdout.rstrip("\n")

    MIGRATION.write_text(HEADER + TABLE_SQL + "\n" + seed_sql + "\n\n"
                         + BODIES_BANNER + bodies_sql + "\n\nCOMMIT;\n")
    print(f"✓ 写出 {MIGRATION.relative_to(REPO)}  ({MIGRATION.stat().st_size} bytes)")
    for p, new in mirror_writes:
        p.write_text(new)
    print(f"✓ 写出 {len(mirror_writes)} 个镜像(35 个 db/functions/ + 9 个 db/tables/)")


HEADER = """\
-- SEARCH-2b · 迁移 B —— document_types,以及 44 支函数体的机械变换
-- ════════════════════════════════════════════════════════════════════════════
--
-- ★★★ 这一支是【一笔事务,不可再分】★★★
--   表、40 行种子、44 支函数体,三者【必须同生同死】。少一行种子而新函数体已经
--   上线,生产上就是【开不出任何单据】—— document_type_prefix() 找不到那一行就抛。
--   所以它们写在同一个 BEGIN/COMMIT 里,而这不是风格,是这支迁移唯一安全的形状。
--
-- ★★★ 它【不是】增量的 —— 破窗在这里是真的 ★★★
--   A / C / D 都只是加东西,旧代码看不见也碰不到。B 重写了 44 支函数体:
--   提交的那一刻起,生产上每一次开单据走的都是新路径,而新代码还没部署。
--   安全性由三件事撑着,缺一不可:
--     ① 签名一个字没变(调用方不必知道这件事发生过);
--     ② 种子与函数体同一笔事务(见上);
--     ③ (g) fixture 逐前缀证过【下一个号相等】,而 build.py 逐字节证过
--        【除了前缀字面量,别处一个字节都没动】。
--   ☞ 已知的界限,写在这里而不是藏着:(g) 证的是【下一个号】,不是并发取号。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★ RLS:这张表必须【开 RLS 且 SELECT USING (true)】,而这一条闸抓不到 ★★
-- ════════════════════════════════════════════════════════════════════════════
--   9 支触发器铸码函数是 INVOKER(prosecdef=f,实测)。它们在生产上以
--   `authenticated` 跑。document_types 若没有一条 SELECT 策略,它们【读不到前缀】。
--   而 db/fixtures 以 postgres 跑 —— postgres 的 rolbypassrls=t,RLS 被绕过,
--   **fixture 会一路绿,生产上铸码全部失败。** 这是门【按构造】看不见的那一格。
--   ☞ 处置两条,都在这支迁移里:
--     · 策略 + 授权都写出来(默认权限已经给了 authenticated,写出来是为了让
--       重建那一侧与线上走同一段文本;anon 不在默认权限里,所以匿名面不变宽,
--       db/anon-grants-baseline.tsv 一行都不用动);
--     · ★ document_type_prefix() 读不到就【抛】,不返回 NULL。
--       这是这个仓库量过的那条:一个读返回值的判据,在 RLS 挡住的时候拿到的是
--       NULL 而不是拒绝 —— 于是 code 会变成 NULL,而不是变成一次响亮的失败。
--       (同 ALERT-1「被 RLS 挡下的 UPDATE 不是错误,是一次成功的空操作」。)
--   ☞ 而【验证】不许靠读策略然后自己同意自己:见 db/fixtures 与切次报告里
--     那次以 authenticated 真的跑过一遍的记录。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 44 支,不是 43
-- ════════════════════════════════════════════════════════════════════════════
--   六轮统计出的 43 支里,参数化那一支(fin_next_payment_code)本身没有字面量,
--   要改的是它的调用方。上一会话点了 record_payment:635,**漏了 reverse_payment:26
--   那一条一模一样的 CASE WHEN … 'RCPT' … 'PMT'**。
--   本支按【字面量住的那个空间】逐支扫过全部 public 函数,得到 44。
--   T1「任何前缀字面量不许活在种子之外」是裁定;这是把它应用完,不是重开它。
--
-- 生成:db/migrations/2026-09-13-search2b-document-types.build.py --emit
--   (函数体不是手打的。44 支合计 20 万字节,手打必然在某一支里顺手改掉别的东西,
--    而签名没变 + 镜像一起改 ⇒ 没有任何一道闸看得见。生成器自己断言
--    "把替换倒回去必须逐字节复原成原文"。)

BEGIN;

"""

TABLE_SQL = """\
-- ── 表 ──────────────────────────────────────────────────────────────────────
-- 【安装种子 / INSTALL SEED】操作员在应用里改不了它,它与代码版本绑定 ⇒
-- check_mirrors.py 逐行比对线上。加一种单据是迁移级动作,天生如此。
CREATE TABLE public.document_types (
    key           text PRIMARY KEY,
    prefix        text NOT NULL UNIQUE,
    table_name    text NOT NULL,
    -- ★ T1:两套编号语义都留,存成这一列。收敛任何一边都会改掉那一边的输出,
    --   而那正是停止条件 (g)。'gapless' = MAX(split_part)+1(号码之间没有洞);
    --   'gapped'  = nextval(回滚不还号 —— 线上已经烧掉 1,177 个号,实测)。
    numbering     text NOT NULL CHECK (numbering IN ('gapless', 'gapped')),
    sequence_name text,
    route         text NOT NULL,
    link_mode     text NOT NULL CHECK (link_mode IN ('detail', 'list', 'list_q')),
    label_column  text,
    match_columns text[] NOT NULL DEFAULT '{}'::text[],
    -- 有洞的必须指名它那条序列;无洞的不许有 —— 一行自相矛盾的登记会让
    -- (g) 的期望值算在错的分支上,而那正是「suppliers 存着 0095、下一个是 0445」
    -- 那条实测要防的事。
    CONSTRAINT document_types_sequence_shape CHECK (
        (numbering = 'gapped'  AND sequence_name IS NOT NULL) OR
        (numbering = 'gapless' AND sequence_name IS NULL))
);

COMMENT ON TABLE public.document_types IS
    'SEARCH-2:这套系统能铸的单据种类。前缀是数据,不是字面量(T1)。'
    '定义的是【能铸什么】,不是【铸过什么】—— 8 张今天还没有行的表照样在册。';

ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;

-- ★ 见抬头:没有这条策略,9 支 INVOKER 触发器在生产上读不到前缀,而 fixture
--   以 postgres 跑、rolbypassrls=t,一路绿。前缀不是秘密,读它没有门槛。
CREATE POLICY "document_types select by anyone signed in"
    ON public.document_types
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

-- 写:一条策略都不给 —— 与 permissions / tax_codes / wht_rates 同一类
--（它们也都只有 SELECT 策略,实测)。改它要走迁移。
GRANT SELECT ON public.document_types TO authenticated;

-- ── 前缀读取器 ──────────────────────────────────────────────────────────────
-- ★★ 读不到就【抛】,不返回 NULL ★★
--   返回 NULL 会让 'X' || NULL || '-' 整体变成 NULL,于是 code 变成 NULL ——
--   一次安静的错误,而不是一次响亮的失败。RLS 挡住读的那一刻正是这个函数
--   唯一有可能读不到的时刻,所以它必须在那里出声。
CREATE OR REPLACE FUNCTION public.document_type_prefix(p_key text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_prefix text;
BEGIN
    SELECT prefix INTO v_prefix FROM public.document_types WHERE key = p_key;
    IF v_prefix IS NULL THEN
        RAISE EXCEPTION 'DOCUMENT_TYPE_PREFIX_MISSING|%', p_key
            USING HINT = 'document_types 里没有这一行,或者当前角色读不到它'
                         '(RLS / GRANT)。铸码在此停下,而不是铸出一个 NULL 号。';
    END IF;
    RETURN v_prefix;
END;
$function$;

-- ── 40 行种子 ───────────────────────────────────────────────────────────────
-- 生成:db/migrations/2026-09-13-search2b-document-types.seed.py
"""

BODIES_BANNER = """\
-- ════════════════════════════════════════════════════════════════════════════
-- 44 支函数体 —— 逐支只换掉它那一个前缀字面量,别处一个字节都没动
-- (生成器断言过:把替换倒回去,逐字节复原成线上现在的定义。)
-- ════════════════════════════════════════════════════════════════════════════

"""

if __name__ == "__main__":
    main()

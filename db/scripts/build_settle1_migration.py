#!/usr/bin/env python3
"""SETTLE-1:从镜像拼出迁移文件(与 CONTRACT-1 / PRICE-1 同一条:镜像是真源)。"""
import pathlib, re
ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-08-30-settle1-the-settlement-basis.sql"

HEADER = """-- SETTLE-1:结算口径 —— **四条条款是同一条公式里的四项**,一次做完。
--
-- 销售重量基准(G25)· 按买方化验最终结算(G23)· 化验方轴的【谁说了算】(U12)
-- · 精炼费(G20)与有害元素惩罚(G21)—— 合并是刻意的:它们在
-- index-pricing-spec §3 的那条公式里彼此相邻,拆开做会把一条公式拆成四次半成品。
--
-- ★★【本刀【记下决定】,它【不过账】】★★
--   sales_settlements 记的是:这次结算**用了谁的化验、按哪种重量基准、
--   依据哪一份冻结的条款**,以及算出来的金额与逐项拆解。
--   **一分钱都不进总账。** 两个各自独立的理由:
--     ① 会计政策 **5.7 自己标着 NOT BUILT** —— 差额科目已裁定,过账路径没有;
--     ② PRICE-1 **声明过它的断点**,两阶段开票还不存在 ——
--        **没有开票,就没有东西可以喂给一条过账路。**
--   所以不要把"结算上线了"读成"结算会过账"。
--
-- ★★【本刀的中心句,三张表都是它的实例】★★
--   **【没有声明】与【声明了"没有"】是两个不同的事实,而只有后者可以拿来算。**
--   assay_results.weight_basis 早就在用它(PROC-6:留空 = 没人说过);
--   本刀把它推到精炼费与惩罚的口径声明上。
--
-- 【本刀只加不删】新表四张、新函数三支、既有表加一列(可空有默认)、
--   一支既有函数 CREATE OR REPLACE(签名不变)。**没有 DROP、没有 RENAME。**
--   依赖清点:contract_document_terms **没有** _masked 孪生视图(实测),
--   所以那一列不触发 WO-1a 的"三件一起";flat_discount_pct **一个字都没动**
--   (它有活着的使用者,而 FIN-27 的已承诺副本必须保持原义)。

BEGIN;
"""

def strip_note(t):
    return re.sub(r"^-- NOTE: introduced by.*\n-- First-run script.*\n", "", t, flags=re.M)

parts = [HEADER]
parts.append("\n-- ═══ 0. 触发器要用的守卫函数(必须先于建表)════════════════════════════\n")
parts.append((ROOT / "db/functions/guard_sales_settlement_immutable.sql").read_text())

parts.append("\n-- ═══ 1. 结算口径:合同的第五个兄弟 ═══════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/contract_settlement_terms.sql").read_text()))
parts.append("\n-- ═══ 2. 精炼费(按【含金属】吨数)════════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/contract_refining_charges.sql").read_text()))
parts.append("\n-- ═══ 3. 有害元素惩罚(按【结算重量】吨数)════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/contract_penalty_elements.sql").read_text()))
parts.append("\n-- ═══ 4. 结算记录(记决定,不过账)════════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/sales_settlements.sql").read_text()))

parts.append("""
-- ═══ 5. 单据抄下来的那一份,多抄一段结算口径 ═════════════════════════════
-- 【为什么不触发"三件一起"】contract_document_terms **没有** _masked 孪生视图,
-- 也没有列清单 SELECT 授权(清点过,不是假定)——表级授权自动覆盖后加的列。
ALTER TABLE public.contract_document_terms
    ADD COLUMN settlement_terms jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE public.contract_document_terms
    ADD CONSTRAINT contract_document_terms_settlement_terms_is_object
        CHECK (jsonb_typeof(settlement_terms) = 'object');

COMMENT ON COLUMN public.contract_document_terms.settlement_terms IS
    'SETTLE-1:挂上去那一刻抄下来的**结算口径**快照 —— 一个**对象**(一份合同一套口径),里面装 contract_settlement_terms 那一行的值,**外加**它两张子表的行(精炼费 / 惩罚元素)。**三样一起冻**,因为结算靠它们一起算钱,而分开冻会让「我按哪一份算的」变成三个不同的时刻。**空对象 {} 合法**(合同可以没有结算口径),NULL 不合法 —— **「没有口径」与「没抄」必须分得开**。冻结的时刻与品位规格、计价条款相同:**挂接那一刻**,不是下单那一刻。';
""")

parts.append("\n-- ═══ 6. 挂接时把结算口径一并抄下 ═════════════════════════════════════\n")
parts.append((ROOT / "db/functions/link_document_to_contract.sql").read_text())
parts.append("\n-- ═══ 7. 结算的算法(一处实现,两个调用者)════════════════════════════\n")
parts.append((ROOT / "db/functions/sale_settlement_compute.sql").read_text())
parts.append("\n-- ═══ 8. 把一次结算记下来(definer,自己先问权限)══════════════════════\n")
parts.append((ROOT / "db/functions/record_sale_settlement.sql").read_text())

parts.append("\nCOMMIT;\n")
OUT.write_text("".join(parts))
print("written:", OUT, sum(1 for _ in OUT.open()), "lines")

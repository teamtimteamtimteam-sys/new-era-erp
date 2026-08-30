#!/usr/bin/env python3
"""PRICE-1:从镜像拼出迁移文件。理由与 CONTRACT-1 的拼装脚本同一条 ——
镜像是真源,迁移是它的一次投影;手抄两份迟早各说各话。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-08-30-price1-index-linked-pricing.sql"

HEADER = """-- PRICE-1:指数挂钩定价(M+1 / M+3)—— 规则记得住、价格算得出,而**缺一天就拒**。
--
-- 规格:docs/index-pricing-spec.md。§6 七问 Tim 已于 2026-08-29 全部裁定 ——
-- 建的时候读它,不要再推导一遍。
--
-- ★★【本刀停在 §7 第 2 步之后,而那是规格自己命名的诚实断点】★★
--   规格 §7 写着:「如果刀 4 装不下全部,**在 2 之后停是一个诚实的断点**:
--   那时候系统能记住规则、能算出价格,只是还没有两阶段开票 —— 这是一个可用的
--   中间状态。」本刀就停在那里,而且是**事先决定**的,不是做着做着停下的。
--
--   **停在这里之后,系统【会】做的:**
--     · 把计价期当成一条**合同条款**记下来(基准事件 / M+n / 指数 / 计价系数)
--     · 单据挂上合同那一刻把它**抄**进副本(FIN-26/27 的形状,与品位规格同一次动作)
--     · 算一个计价期的**指数均价**,交易日逐日,**缺一天按名拒**
--   **它【不会】做的(不要把"指数定价上线了"读成"我们能按指数开票了"):**
--     · 两阶段开票(暂定价发票 / 最终结算单)—— **没有**
--     · 计价期到期提醒(3 个工作日、Choo Er Teh)—— **没有**
--     · 最终结算的差额入账 —— **没有**(科目已裁定并写进会计政策 5.6,但**没建**)
--
-- ★【本刀只做【卖方向】】§9 明说「采购侧要不要也用指数联动,本文件没有答案,
--   需要 Tim 说明」。所以本刀不碰 pricing_term_commitments(买方向的承诺表)——
--   扩它等于替 Tim 把那个问题答了,而**一条被暗示的裁定比一个敞着的问题坏**。
--
-- 【本刀只加不删】新表两张、新函数两支、既有表加一列(可空有默认)、
--   两支既有函数 CREATE OR REPLACE(签名不变)。**没有 DROP、没有 RENAME。**
--   依赖清点:contract_document_terms **没有** _masked 孪生视图(实测),
--   所以那一列不触发 WO-1a 的"三件一起"(ADD COLUMN / GRANT / _masked);
--   它也没有列清单 SELECT 授权,表级授权自动覆盖新列。

BEGIN;
"""


def strip_note(text):
    return re.sub(r"^-- NOTE: introduced by.*\n-- First-run script.*\n", "", text, flags=re.M)


parts = [HEADER]

parts.append("\n-- ═══ 1. 开市日历 —— 唯一能说出「那天市场关着」的东西 ══════════════════\n")
parts.append(strip_note((ROOT / "db/tables/index_market_calendar.sql").read_text()))

parts.append("\n-- ═══ 2. 计价条款:合同的第四个兄弟子表 ═══════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/contract_pricing_terms.sql").read_text()))

parts.append("""
-- ═══ 3. 单据抄下来的那一份,多抄一段计价条款 ═════════════════════════════
-- 【为什么不触发"三件一起"】contract_document_terms **没有** _masked 孪生视图,
-- 也没有列清单 SELECT 授权(实测),所以表级授权自动覆盖后加的列。
-- WO-1a 那一课(列清单 SELECT 不会自动扩展到新列)在这里【不适用】,
-- 而这句话是清点过才写下的,不是假定的。
ALTER TABLE public.contract_document_terms
    ADD COLUMN pricing_terms jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.contract_document_terms
    ADD CONSTRAINT contract_document_terms_pricing_terms_is_array
        CHECK (jsonb_typeof(pricing_terms) = 'array');

COMMENT ON COLUMN public.contract_document_terms.pricing_terms IS
    'PRICE-1:挂上去那一刻抄下来的**计价条款**快照 —— 与 grade_specs 同一形状、同一理由(抄不是引用)。★★**冻结的时刻是【挂接】,不是【下单】**★★:CONTRACT-1 刻意允许**回填挂接**(单据日期落在合同期外不拒,因为回填是正当操作),所以一次事后补挂会把**挂接当时**在效的条款冻上去,而不是下单当天的。**对品位规格这条边不算锋利,对钱锋利** —— 所以 link_document_to_contract 的返回里带 terms_frozen_as_of 与 TERMS_FROZEN_AT_LINK_TIME,/contracts 页也把它印出来,好让挂接的人**当场看见自己冻的是哪一份**。**不要去"修"回填权限** —— 那是 CONTRACT-1 裁过的,它站得住。★**它没有暂定价**★:暂定价逐笔谈(§6.2),不是条款。';
""")

parts.append("\n-- ═══ 4. 计价期的首尾(算,不存)══════════════════════════════════════\n")
parts.append((ROOT / "db/functions/quotational_period.sql").read_text())

parts.append("\n-- ═══ 5. ★ 计价期均价:交易日逐日,缺一天按名拒 ★ ═══════════════════\n")
parts.append((ROOT / "db/functions/index_period_average.sql").read_text())

parts.append("\n-- ═══ 6. 挂接时把计价条款一并抄下 ═════════════════════════════════════\n")
parts.append((ROOT / "db/functions/link_document_to_contract.sql").read_text())

parts.append("""
-- ═══ 7. 既有均价那一支:加上"两条规矩不是两份实现"的对称注释 ═══════════════
-- 【为什么它也进这次迁移】函数镜像是 pg_get_functiondef 的逐字节副本,
-- 而注释在函数体里 —— 改了注释就是改了定义,线上不跟着改,check_mirrors 会红。
""")
parts.append((ROOT / "db/functions/calculate_metal_price_from_terms.sql").read_text())

parts.append("\nCOMMIT;\n")
OUT.write_text("".join(parts))
print("written:", OUT, sum(1 for _ in OUT.open()), "lines")

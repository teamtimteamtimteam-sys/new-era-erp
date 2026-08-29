#!/usr/bin/env python3
"""CONTRACT-1:从镜像拼出迁移文件。拼装用机器,理由与 KPI-1 同一条。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-08-30-contract1-the-contract-register.sql"

HEADER = """-- CONTRACT-1:合同登记簿 + 卖方已承诺条款 + 保险 + 目标品位与公差。
--
-- ★★【一张采购单不是一份合同 —— 这一刀补的就是那个缺掉的概念】★★
--   此前本仓库只有【单据】(purchase_orders / sales_orders / quotes)与
--   【不挂对手方、没有期限的可复用条款集】(pricing_formulas / payment_term_templates)。
--   **"合同"这个东西一张表都没有**,而后三件(卖方条款、保险、目标品位)
--   全都是【合同条款】—— 它们该待在合同上,所以合成一刀。
--
-- ★【它凭什么不是一个文件柜】★(Tim 2026-08-29 裁定 A1)
--   purchase_orders 与 sales_orders 各加一列 contract_id,
--   而 link_document_to_contract 有两条拒绝:对手方对不上、合同不是 active。
--   **两条都是【不一致】不是【政策】** —— AGENTS.md 给
--   ALLOC_CURRENCY_MISMATCH 与 ALLOC_EXCEEDS 划过这条线。
--   **刻意不拒的那一条**:单据日期落在合同期之外不拒(回填正当,而
--   "能不能背靠未生效的合同下单"没有人裁过)。
--   **而覆盖率必须被说出来**:没有任何东西强制一张单据挂合同,所以
--   "没有合同被违反"很可能只是"没有人挂过东西" —— contract_coverage 给出分母。
--
-- ★【6.2 的清点:本刀【只加不删】,而依赖仍然先数了一遍】★
--   动的是两处 ADD COLUMN(purchase_orders.contract_id / sales_orders.contract_id),
--   **没有任何 DROP 或 RENAME**。清点结果:
--     · purchase_orders **是遮蔽表**(有 purchase_orders_masked + 列授权)——
--       所以按 WO-1a 那一课,ADD COLUMN / GRANT / _masked **三件事都在本迁移里**。
--       (KPI-1 为漏掉后两件付过一次账,窗口 4 小时 44 分。)
--     · sales_orders 没有 _masked 视图,ADD + GRANT 两件。
--     · 依赖这两张表的视图共 8 个(deleted_records / grn_discrepancies /
--       operations_now / purchase_orders_masked / container_overview / quote_status
--       等)—— **加列不会破坏它们中的任何一个**(只有删列/改名会),
--       但仍然先数出来再动手,那是本刀的规矩。
--
-- 【顺序】contracts 必须先于两处 ADD COLUMN(外键指向它);
--   contract_document_terms 必须后于两张单据表拿到列;函数与视图最后。

BEGIN;
"""


def strip_note(text):
    return re.sub(r"^-- NOTE: introduced by.*\n-- First-run script.*\n", "", text, flags=re.M)


parts = [HEADER]

parts.append("\n-- ═══ 1. 合同本体 ═══════════════════════════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/contracts.sql").read_text()))

parts.append("\n-- ═══ 2. 条款:三个【兄弟】子表(第 4 刀的定价是第四个)══════════════════\n")
for t in ["contract_grade_specs", "contract_insurance_obligations",
          "contract_volume_commitments"]:
    parts.append(strip_note((ROOT / f"db/tables/{t}.sql").read_text()))
    parts.append("\n")

parts.append("""
-- ═══ 3. 两张单据表挂得上合同 —— ADD / GRANT / _masked,三件一起 ════════════
-- 【为什么三件一起】purchase_orders 是遮蔽表,而列清单 SELECT 授权
-- **不会自动扩展到后加的列**(表级 INSERT/UPDATE 会,SELECT 不会)。
-- 漏掉 GRANT 或 _masked,就会造出一个"写得进、读不出"的列 ——
-- FIN-6 就是这么让 /finance/processing-costs 从上线那天起就是空的,而所有闸都是绿的。
ALTER TABLE public.purchase_orders
    ADD COLUMN contract_id uuid REFERENCES public.contracts (id) ON DELETE RESTRICT;
ALTER TABLE public.sales_orders
    ADD COLUMN contract_id uuid REFERENCES public.contracts (id) ON DELETE RESTRICT;

GRANT SELECT (contract_id) ON public.purchase_orders TO authenticated;
GRANT SELECT (contract_id) ON public.sales_orders TO authenticated;

COMMENT ON COLUMN public.purchase_orders.contract_id IS
    'CONTRACT-1:这张单据挂在哪一份合同之下。**可空** —— 现货采购本来就没有合同。★**它是导航,不是条款的来源**★:条款读 contract_document_terms 那份【挂上去那一刻抄下来的】副本,顺着这一列回查合同"现在"的条款就是把抄退化成引用。';
COMMENT ON COLUMN public.sales_orders.contract_id IS
    'CONTRACT-1:这张单据挂在哪一份合同之下。**可空** —— 现货销售本来就没有合同。★**它是导航,不是条款的来源**★:条款读 contract_document_terms 那份副本。';
""")

parts.append("\n-- ═══ 4. 遮蔽视图跟着加列(必须与 ADD COLUMN 同一次迁移)══════════════\n")
parts.append((ROOT / "db/views/purchase_orders_masked.sql").read_text()
             .replace("CREATE VIEW public.purchase_orders_masked",
                      "CREATE OR REPLACE VIEW public.purchase_orders_masked", 1))

parts.append("\n-- ═══ 5. 挂上去那一刻抄下来的条款(FIN-27 的形状)═══════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/contract_document_terms.sql").read_text()))

parts.append("\n-- ═══ 6. 唯一的写入口 ══════════════════════════════════════════════════\n")
parts.append((ROOT / "db/functions/link_document_to_contract.sql").read_text())

parts.append("""
-- ═══ 7. 保险 = 既有的证书机制,加一个类型 ═════════════════════════════════
-- ★【不建第二套到期机制】★(Tim 2026-08-29 裁定 A3)
--   certificate_types 是 RUNTIME CONFIG(check_mirrors 不逐行比对),
--   所以【加一种证书本来就是编辑一行,不是跑迁移】。这里插一行是因为
--   **线上不会自己长出它** —— 引导默认值只在全新安装时被种下。
--   ON CONFLICT DO NOTHING:操作员可能已经自己加过同名的一行,
--   而那一行是他的地盘,本迁移不该覆盖它。
INSERT INTO public.certificate_types (code, name_en, name_zh, disposition, warn_lead_days, sort_order, notes)
VALUES ('insurance', 'Insurance Policy', '保险单', 'warn', 60, 8,
        '默认 warn 是【默认值】不是决定:过期保单要立刻处理,但"停不停收货"是经营决定,disposition 在界面上改得动')
ON CONFLICT (code) DO NOTHING;
""")

parts.append("\n-- ═══ 8. 派生视图:违反与覆盖率 ════════════════════════════════════════\n")
for v in ["contract_grade_breaches", "contract_coverage"]:
    parts.append((ROOT / f"db/views/{v}.sql").read_text())
    parts.append("\n")

parts.append("\nCOMMIT;\n")
OUT.write_text("".join(parts))
print("written:", OUT, sum(1 for _ in OUT.open()), "lines")

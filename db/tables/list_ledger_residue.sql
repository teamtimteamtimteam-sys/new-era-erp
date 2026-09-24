-- db/tables/list_ledger_residue.sql
-- ════════════════════════════════════════════════════════════════════════════
-- AP-RECON-1 Batch B(2026-09-24):清单与总账之间【逐单据】的已知残留 —— 只有迁移能写
-- ════════════════════════════════════════════════════════════════════════════
--
-- 【它是什么】list_ledger_reconciliation() 把每一张未结清单(应付 ↔ 2000、应收 ↔ 1100)
-- 与它的总账科目【全账、不截日】比一遍。两边之间允许的差只有三种:
--   · 本表里的行 —— 测试库上逐张单据的已知残留(Tim AP-RECON-1 Q9);
--   · 重估 —— 一条【算出来的】、有名字的行(Q10),不在本表;
--   · 挂账的收付款 —— 一条【算出来的】、有名字的行(Q6 / Batch B Q2),不在本表。
-- 其余一律是"未解释",而且没有兜底桶。
--
-- 【为什么它【只能】由迁移写】这张表的每一行都是在说"这一笔差,我们知道、我们不修"。
-- 一张界面写得进去的残留表,就是一张"让它变绿"的按钮 —— 与 document_type_exceptions
-- 同一条理由,更强:那边写错一行只是少搜一张表,这边写错一行是把一笔真差额藏起来。
--   ★ RLS 开着;写:一条策略都不给;加一行是迁移级动作,天生如此。
--   ★ 读:module.finance.view(与勾稽函数同一道门)。
--   ★ anon:不给。
--
-- 【重建出来的库上它是空的 —— 这是设计,不是遗漏】本镜像【不带】种子行。
-- 这些行描述的是测试库上切换之前的历史(docs/known-wrong-until-cutover.md 逐行有记),
-- 生产全新重建时那段历史不存在,本表也就该是空的。于是 db/fixtures/213 在重建库上
-- 要求的是【严格相等】—— 没有任何一行可以拿来解释差额。
-- 线上的 7 行由 db/migrations/2026-09-24-aprecon1b-the-list-and-the-ledger-agree.sql 写入。
--
-- 【amount_base 的符号】与勾稽函数同一个约定:它对"清单 − 总账"的贡献。
-- 正 = 清单上有、总账上没有;负 = 总账上有、清单上没有。
--
-- 行为断言:db/fixtures/213-the-list-and-the-ledger-agree-and-a-difference-has-a-name.sql

CREATE TABLE public.list_ledger_residue (
    side            text    NOT NULL CHECK (side IN ('ap', 'ar')),
    doc_code        text    NOT NULL,
    amount_base     numeric NOT NULL CHECK (amount_base <> 0),
    residue_class   text    NOT NULL CHECK (residue_class IN (
                        'priced_before_payable_posting',
                        'deleted_while_owing',
                        'fin2_backfill_units',
                        'sold_before_sales_posting')),
    -- ★ 一句话,而且【不许为空】—— 与 document_type_exceptions 同一条:
    --   一张能塞进空理由的残留表,就是一张"不要红"的名单。
    reason          text    NOT NULL,
    known_wrong_ref text    NOT NULL,
    PRIMARY KEY (side, doc_code),
    CONSTRAINT list_ledger_residue_reason_present CHECK (btrim(reason) <> ''),
    CONSTRAINT list_ledger_residue_ref_present    CHECK (btrim(known_wrong_ref) <> '')
);

COMMENT ON TABLE public.list_ledger_residue IS
    'AP-RECON-1 Batch B:清单与总账之间逐单据的已知残留(测试库的切换前历史)。只有迁移能写;重建库上为空。';

ALTER TABLE public.list_ledger_residue ENABLE ROW LEVEL SECURITY;

CREATE POLICY list_ledger_residue_select ON public.list_ledger_residue
    FOR SELECT TO authenticated USING (has_permission('module.finance.view'));

REVOKE ALL ON public.list_ledger_residue FROM anon;
GRANT SELECT ON public.list_ledger_residue TO authenticated;

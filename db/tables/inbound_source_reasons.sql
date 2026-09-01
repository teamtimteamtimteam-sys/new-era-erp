-- db/tables/inbound_source_reasons.sql
-- RECV-SOURCE-1:一张【没有采购行】的收货,为什么没有 —— 理由字典。
--
-- 【RUNTIME CONFIG】加一个理由是加一行(与 material_sources / certificate_types
-- 同形,check_mirrors 不逐行比对内容)。R2 的原话:第五个理由必须是一行,
-- 不是一次改码。
--
-- 【规则列 requires_explanation】这个理由要不要一句书面说明(R3)。做成列而
-- 不是把 'other' 写死在触发器里:否则"第五个理由也要说明"就是一次改码 ——
-- R2 与 R3 打架。guard_receipt_source_stated 读本列拒绝
-- (SOURCE_REASON_EXPLANATION_REQUIRED)。
--
-- NOTE: introduced by db/migrations/2026-09-01-recvsource1-a-receipt-must-say-where-it-came-from.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inbound_source_reasons (
    code                 text PRIMARY KEY,
    name_en              text NOT NULL,
    name_zh              text NOT NULL,
    -- 【规则列】见文件抬头。播种时只有 other 为真。
    requires_explanation boolean NOT NULL,
    is_active            boolean NOT NULL DEFAULT true,
    sort_order           integer NOT NULL DEFAULT 0,
    notes                text
);

COMMENT ON TABLE public.inbound_source_reasons IS
'RECV-SOURCE-1:一张【没有采购行】的收货,为什么没有。RUNTIME CONFIG,加一个理由是加一行。

【与 material_sources 不是同一张表,不设外键,也永远不要"统一"它们】
基数就不对:那张表答"这一【种】物料从哪来",是【物料种类】的属性;
本表答"这一【张】收货为什么没挂采购行",是【这一票货】的属性。
一种厂内边角料(production_scrap)的货,完全可以以盘盈(stocktake_gain)的
方式出现在收货台上 —— 两个问题独立成立,谁也推不出谁。
(material_sources 的表注为它与 supplier_types 的独立写过三条理由;
本条与它同形,记在这里省得下一个人重推一遍。)

【is_active 只管表单下拉,触发器不看它】停用一个理由是"以后别再用",
不是"用过它的行从此非法" —— certificate_types 的处置同一条。';

COMMENT ON COLUMN public.inbound_source_reasons.requires_explanation IS
'RECV-SOURCE-1 R3:这个理由必须带一句书面说明才算说了话。播种时只有 other 为真 ——
一个没有句子的 other 什么都没说(损耗类别拒绝匿名 other 桶的同一条推理)。
guard_receipt_source_stated 读本列拒绝,所以"第五个理由也要说明"是一行数据。';

INSERT INTO public.inbound_source_reasons (code, name_en, name_zh, requires_explanation, sort_order, notes) VALUES
    ('return',         'Customer return', '客户退货', false, 1, '客户退回的货 —— 出过厂又回来,来路是那一单销售,不是一张采购单。'),
    ('sample',         'Free sample',     '免费样品', false, 2, '供应商送验的样品 —— 没有对价,所以没有采购单。'),
    ('stocktake_gain', 'Stocktake gain',  '盘盈',     false, 3, '盘点发现的多出之数 —— 货在,纸不在。它的"从哪来"只能诚实到这一步。'),
    ('other',          'Other',           '其他',     true,  4, 'R3:必须带书面说明(requires_explanation)。没有句子的 other 什么都没说。');

ALTER TABLE public.inbound_source_reasons ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 material_sources / certificate_types 同一处置。
CREATE POLICY "inbound_source_reasons select all"
    ON public.inbound_source_reasons AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- 编辑权跟收货走(module.inbound.edit)—— 这本字典管的是收货台上的一个必答项。
CREATE POLICY "inbound_source_reasons insert by permission"
    ON public.inbound_source_reasons AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));
CREATE POLICY "inbound_source_reasons update by permission"
    ON public.inbound_source_reasons AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text))
    WITH CHECK (has_permission('module.inbound.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inbound_source_reasons TO authenticated;

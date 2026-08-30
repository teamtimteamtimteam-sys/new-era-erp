-- db/tables/contract_pricing_terms.sql
-- PRICE-1:指数挂钩定价的条款 —— **合同的第四个兄弟子表**。
--
-- 【它落在这里,是 CONTRACT-1 指定的位置】那一刀的 contracts 表注写着:
--   「第 4 刀的指数挂钩定价应当落成第四个兄弟(建议 contract_pricing_terms,
--     同样以 contract_id 为键)」,并且刻意**不**把定价的列加在 contracts 那一行上
--   —— 那正是本刀要迁走的形状。本刀照办,没有改那个判断。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【这张表装的是【条款】,而条款与【每一笔的谈判】是两件事】(§6,Tim 2026-08-29)
--
--   § 6.1 基准月由哪个事件定义 → **逐合同不同**,是一条合同条款  → base_event(在这里)
--   § 6.3 计价系数从哪来       → **写在合同里**                  → payable_pct(在这里)
--   § 6.2 暂定价怎么定         → **逐笔谈**,不设固定折扣,
--                                 **也不设合同级默认值**          → ★ 不在这里 ★
--
-- ★★【这张表【没有】暂定价那一列,而那个缺席是本表最要紧的一件事】★★
--   §6 第 2 条裁定得很干脆:暂定价是**那一笔交易本身**的属性,不是条款,
--   **而且没有默认值可猜** —— 成交时没谈暂定价,就按名拒,不要替人填一个折扣。
--   在这里加一列 `default_provisional_pct`,哪怕留空,都会变成一个**看起来该填的格子**;
--   而一旦有人填了它,「逐笔谈」就在事实上变成了「合同级默认值」——
--   **正是那条裁定明说不要的东西**。所以这一列不存在,理由写在这里,
--   免得下一个人把它当成遗漏补上。
--
-- 【为什么是逐元素一行】一份合同对镍和钴的计价系数通常不同,而
--   pricing_formula_metals 早就是这个形状(每种金属一行、各带 payable_pct)——
--   跟着既有形状走,而不是发明第二种。
--
-- 【它【不】表达什么,而这些是【没人裁过】,不是漏了】
--   · **按料号分别定价**:同一份合同下不同物料用不同系数 —— 没有人裁过,
--     而猜一个粒度出来会把一个待答的问题伪装成已实现的功能。今天是
--     (合同 × 元素)一行,要更细,先要一次裁定。
--   · **采购侧**:§9 明说「采购侧要不要也用指数联动,本文件没有答案,
--     需要 Tim 说明」。所以本刀**只做卖方向**,而且刻意**不**去扩
--     pricing_term_commitments(那是买方向的承诺表)—— 扩它等于**替 Tim 把
--     那个问题答了**,而一条被暗示的裁定比一个敞着的问题坏。
--
-- NOTE: introduced by db/migrations/2026-08-30-price1-index-linked-pricing.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_pricing_terms (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 与 contract_grade_specs.metal / assay_result_metals.metal 同一个字典
    metal        text NOT NULL REFERENCES public.substances (code),
    -- ── §6.1:哪个事件定义基准月 M ── 逐合同不同,所以它是一列,不是一个全局设定
    base_event   text NOT NULL
                 CHECK (base_event IN ('shipment', 'arrival', 'assay_complete')),
    -- ── M+n 的 n ── M+1 → 1,M+3 → 3。允许 0(= 基准月本身,现实中确有这么写的)
    qp_months    integer NOT NULL CHECK (qp_months >= 0 AND qp_months <= 12),
    -- ── 用哪一条指数序列 ── §6 要求算的是"那个市场"的均价,所以它必须具名
    index_code   text NOT NULL REFERENCES public.metal_price_indices (code) ON DELETE RESTRICT,
    -- ── §6.3:计价系数,写在合同里 ── 买方只按含量的一定比例付钱
    payable_pct  numeric NOT NULL CHECK (payable_pct > 0 AND payable_pct <= 100),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    -- 同一份合同同一种元素只规定一次 —— 否则"哪一条说了算"又变成按写入顺序破平局
    -- (CONTRACT-1 的 fu1 为这件事付过一次账,那次是 NULL ≠ NULL;
    --  这里两列都 NOT NULL,所以一条普通的 UNIQUE 就咬得住)
    CONSTRAINT contract_pricing_terms_one_per_metal UNIQUE (contract_id, metal)
);

CREATE INDEX idx_contract_pricing_terms_contract ON public.contract_pricing_terms (contract_id);

ALTER TABLE public.contract_pricing_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract pricing terms select by owner permission"
    ON public.contract_pricing_terms AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract pricing terms write by owner permission"
    ON public.contract_pricing_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_pricing_terms IS
    'PRICE-1:指数挂钩定价的条款 —— **合同的第四个兄弟子表**,位置是 CONTRACT-1 的 contracts 表注指定的(定价的列**不**加在 contracts 那一行上,那正是本刀要迁走的形状)。装的是【条款】:base_event(§6.1 基准月由哪个事件定义 —— **逐合同不同**)与 payable_pct(§6.3 计价系数 —— **写在合同里**),外加 M+n 与指数序列。★★**它没有暂定价那一列,而那个缺席是本表最要紧的一件事**★★:§6 第 2 条裁定暂定价**逐笔谈**、不设固定折扣、**也不设合同级默认值** —— 在这里加一列哪怕留空,都会变成一个看起来该填的格子,而一旦有人填了它,「逐笔谈」在事实上就变成了「合同级默认值」,正是那条裁定明说不要的东西。**逐元素一行**,跟 pricing_formula_metals 既有形状走。★**它不表达什么,而这些是没人裁过、不是漏了**★:按料号分别定价(粒度没人裁过);**采购侧** —— §9 明说采购侧要不要用指数联动「本文件没有答案,需要 Tim 说明」,所以本刀只做卖方向,并**刻意不扩 pricing_term_commitments**(买方向的承诺表),因为扩它等于**替 Tim 把那个问题答了**,而**一条被暗示的裁定比一个敞着的问题坏**。';

COMMENT ON COLUMN public.contract_pricing_terms.base_event IS
    'PRICE-1:哪个事件定义基准月 M —— 发货 / 到货 / 化验完成。**§6.1 裁定它逐合同不同**,所以它是合同上的一列,**不是一个全局设定**。它也正是 known-issues 里数量承诺那一条在等的同一个判断(「跨月的一船算哪个月」)—— 两处问的是同一件事,分开裁会裁出两个口径。';

COMMENT ON COLUMN public.contract_pricing_terms.qp_months IS
    'PRICE-1:M+n 的 n。M+1 → 1,M+3 → 3;**允许 0**(= 基准月本身,现实中确有这么约的)。计价期 = 基准月往后第 n 个整月的【自然月首尾】,由 quotational_period() 算,不在这里存 —— 存下来就是同一个事实的第二份,而它会与 base_event 漂开。';

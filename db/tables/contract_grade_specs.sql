-- db/tables/contract_grade_specs.sql
-- CONTRACT-1:目标品位与公差 —— **一条合同条款**,不是物料主数据上的一个字段。
--
-- 【为什么它挂在合同上】(proc-reality 的 G11 被 U8 挡着,而 U8 写的是
--  「第一份带规格的供货合同」)—— **本刀建的正是那样一份合同**,所以 G11 的
--  前置条件由这一刀满足,而不是另外再裁一次。
--  同一种物料在两份合同下可以有两套规格,而 materials.spec 是一段自由文本、
--  一种物料只有一份 —— 它表达不了"这一份合同要求的是什么"。
--
-- ★★【min / max,而不是 target ± tolerance】★★(Tim 2026-08-29 裁定 A2)
--   真实合同写的多半是**单边**的:「Ni ≥ 18%」「Cu ≤ 0.5%」。
--   而 target±tolerance 是 min/max 的一个对称特例 —— 用 min/max 表达得了,
--   反过来不行。**两种都存就是同一个事实两个写法**,而两个写法迟早会各说各话。
--   两个界至少要有一个(下面那条 CHECK),因为**一条两边都不设限的"规格"
--   什么也没规定**。
--
-- ★★【它【报告】违反,不【拒绝】交货 —— 而理由是具体的,不是胆小】★★(A2)
--   化验结果回来的时候,**货已经在场上了**。而这套系统里**没有"质量暂扣"这个状态**
--   (全库 0 张相关表;那是阶段 6 的 G29)。
--   **拒绝一样自己没有地方安放的东西,不是一道控制** —— 它只是把一批物理上
--   已经躺在仓库里的货的单据流程堵住。所以本刀把违反做成一个【看得见的、具名的发现】
--   (contract_grade_breaches 视图),而不是一道闸。
--   **升成闸的触发条件已经排进队列:G29 的质量暂扣落地那一天。**
--
-- 【它拿什么去比】assay_result_metals.content_pct(0–100 的 numeric,
--   metal 外键指向 substances)—— 那是这套系统里**真正量出来的**含量,
--   而化验挂在 inbound_batch 或 output_batch 上(恰好一个)。
--   所以"这批货有没有达到这份合同的规格"是一个答得出来的问题。
--
-- NOTE: introduced by db/migrations/2026-08-30-contract1-the-contract-register.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_grade_specs (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 【物料可空】一份合同可以只规定"镍不低于 18%",不指定具体料号。
    material_id uuid REFERENCES public.materials (id) ON DELETE RESTRICT,
    -- 比的是哪一种元素 —— 与 assay_result_metals.metal 同一个字典
    metal       text NOT NULL REFERENCES public.substances (code),
    min_pct     numeric CHECK (min_pct IS NULL OR (min_pct >= 0 AND min_pct <= 100)),
    max_pct     numeric CHECK (max_pct IS NULL OR (max_pct >= 0 AND max_pct <= 100)),
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid(),
    -- 【唯一性放在下面两个【部分索引】里,而不是这里的一条 UNIQUE】
    -- 理由是本刀自己的 fixture 抓到的:`UNIQUE (contract_id, material_id, metal)`
    -- 在 material_id 为 NULL 时【不咬】—— 因为唯一索引里 NULL ≠ NULL。
    -- 而 material_id 为空恰恰是【最常见】的写法(合同只写"Ni ≥ 18%",不指料号),
    -- 于是同一份合同可以同时存在 Ni≥18 与 Ni≥20 两行,
    -- 「哪一条说了算」就变成一次按写入顺序的破平局 —— 正是本表注释声称躲开的那个坑。
    -- ★ 至少一个界:两边都不设限的"规格"什么也没规定
    CONSTRAINT contract_grade_specs_needs_a_bound
        CHECK (min_pct IS NOT NULL OR max_pct IS NOT NULL),
    -- 下界不能高于上界 —— 否则这条规格【永远】不可能被满足,
    -- 而它会安静地把每一批货都报成违反
    CONSTRAINT contract_grade_specs_bounds_ordered
        CHECK (min_pct IS NULL OR max_pct IS NULL OR min_pct <= max_pct)
);

CREATE INDEX idx_contract_grade_specs_contract ON public.contract_grade_specs (contract_id);

-- ★【同一种元素只规定一次 —— 两个部分索引,因为 NULL ≠ NULL】★
-- 指定了料号的那些:同一份合同 + 同一料号 + 同一元素只一行。
CREATE UNIQUE INDEX contract_grade_specs_one_per_material_metal
    ON public.contract_grade_specs (contract_id, material_id, metal)
    WHERE material_id IS NOT NULL;
-- 没指定料号的那些(合同层的通用规格):同一份合同 + 同一元素只一行。
-- **这一条是本刀的 fixture 抓出来的** —— 少了它,最常见的写法反而没有唯一性。
CREATE UNIQUE INDEX contract_grade_specs_one_per_metal_no_material
    ON public.contract_grade_specs (contract_id, metal)
    WHERE material_id IS NULL;

ALTER TABLE public.contract_grade_specs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract grade specs select by owner permission"
    ON public.contract_grade_specs AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract grade specs write by owner permission"
    ON public.contract_grade_specs AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_grade_specs IS
    'CONTRACT-1:目标品位与公差 —— **一条合同条款**,不是物料主数据上的字段(同一种物料在两份合同下可以有两套规格,而 materials.spec 是自由文本且一种物料只有一份)。★**min/max,不是 target ± tolerance**★:真实合同多半是单边的(Ni ≥ 18%、Cu ≤ 0.5%),而 target±tolerance 是 min/max 的对称特例 —— 用 min/max 表达得了,反过来不行,**两种都存就是同一个事实两个写法**。至少要有一个界,因为两边都不设限的规格什么也没规定。★★**它报告违反,不拒绝交货,而理由是具体的**★★:化验回来时**货已经在场上**,而这套系统里没有"质量暂扣"这个状态(阶段 6 的 G29)—— **拒绝一样自己没有地方安放的东西不是控制**,只是把物理上已在仓库的货的单据流程堵住。违反做成具名发现(contract_grade_breaches),升成闸的触发条件是 G29 落地。它拿 assay_result_metals.content_pct 去比 —— 那是这套系统里真正量出来的含量。**G11 此前被 U8 挡着,而 U8 的触发条件写的正是「第一份带规格的供货合同」—— 本刀建的就是那个。**';

COMMENT ON COLUMN public.contract_grade_specs.max_pct IS
    'CONTRACT-1:上界。**与 min_pct 至少有一个**。杂质条款(Cu ≤ 0.5%)只有上界、品位条款(Ni ≥ 18%)只有下界,两者都是常态 —— 逼两个都填就是逼人编一个界出来,而编出来的界会被当成谈成的条款。';

-- db/tables/contract_settlement_terms.sql
-- SETTLE-1:结算口径 —— **一份合同一行**,合同的第五个兄弟子表。
--
-- 【位置照 CONTRACT-1 与 PRICE-1 的先例】条款是**兄弟子表**,不是 contracts 上
--   越加越多的列;而**冻结的时刻是【挂接】**,与品位规格、计价条款同一次动作 ——
--   **一份合同不许有两套冻结语义**(PRICE-1 第二轮为这件事拒过一个更"精确"的方案)。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★★【本表的中心句,四条列都是它的实例】★★★
--
--   **【没有声明】与【声明了"没有"】是两个不同的事实,而只有后者可以拿来算。**
--
--   这不是一句格言,它是 `assay_results.weight_basis` 已经在用的那条(PROC-6:
--   留空 = 没有人说过,而不是"按惯例是干基")。本表把同一条推到另外三处:
--     · sale_weight_basis        —— 结算按湿基还是干基,**必须声明**(NOT NULL)
--     · refining_charge_basis    —— 'none_agreed' 是一次**声明**,不是一次留空
--     · penalty_basis            —— 同上
--   于是"这份合同没有精炼费"是一个**记录下来的决定**,而不是"没人填过"。
--
-- 【为什么不让"没有子行"直接当成零 —— 后果是具体的】
--   黑粉承购里**精炼费近乎普遍**(proc-reality 的加工访谈)。把"没有子行"读成
--   "没有精炼费",会算出一张**看起来完全正常、而金额是错的发票** ——
--   **不是任何人会注意到的那种错误**。这正是本仓库反复清理的"静悄悄的默认值"。
--
-- 【为什么也不让"没有子行"一律拒 —— 那会教人绕过它】
--   一份**真的没有精炼费**的合同必须仍然结算得了。
--   **一条在正当情形上开火的拒绝,教会的是绕过它的办法**,而不是安全(WHT-1 那一课)。
--
-- NOTE: introduced by db/migrations/2026-08-30-settle1-the-settlement-basis.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_settlement_terms (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,

    -- ── 结算按哪种重量 ── ★ 必须声明,永远不给默认值 ★
    --   GO-3 量过:全库【只有】guard_assay_basis_stated 与 record_assay_result
    --   提到 weight_basis,**没有任何计价或结算函数按它分支** —— 于是一张按干基
    --   出的化验单被乘在湿重上,含金属被**高估**,而没有任何东西会响。
    --   那是一个**钱的错误**,不是一个政策缺口。
    sale_weight_basis text NOT NULL
        CHECK (sale_weight_basis IN ('as_received', 'dry')),

    -- ── 谁的化验说了算 ── U12 的那条条款(返回条件写的正是"第一份写明化验条款的合同")
    --   'umpire' **不在这里**:仲裁是一次**升级**,不是一份合同的常设约定。
    --   哪一份结果真的被用了,记在 sales_settlements 上,而不是从这里推导。
    settling_party text NOT NULL
        CHECK (settling_party IN ('ours', 'counterparty')),

    -- ── 分歧容差(splitting limit)── ★ 可空,而【空永远不会变成一个决定】★
    --   Tim 2026-08-29 裁定:争议**送第三方独立检测机构复检**。那条裁定命名的是
    --   **升级路径**,不是一个阈值 —— 所以容差**没有人裁过**,这一列留空是常态。
    --   ★【为什么系统【不】按它自动选】★ 让系统按容差自动选,等于**让系统决定
    --   谁的数字是钱**;而容差为空时,它还得**编一个默认值**才做得到那件事。
    --   所以:容差只用来**指出**两份结果差得超过了它,**永远不自己选**。
    --   两份结果有分歧、又没有声明容差时,结算**按名拒**,并说出该做什么。
    splitting_limit_pct numeric
        CHECK (splitting_limit_pct IS NULL OR (splitting_limit_pct > 0 AND splitting_limit_pct <= 100)),

    -- ── 留样【义务】── 这是一条**合同条款**;留样这件**实物**不在本刀射程内。
    --   ★【一个说出来的未满足前提,而不是一个沉默的】★
    --   Tim 的裁定要求争议时送第三方复检,而**第三方复检要有一个罐子** ——
    --   这套系统今天**说不出某个样品还在不在**(只有 assay_results.sample_ref
    --   一段自由文本)。留样的实物模型是**实验室工作流**那一件(proc-reality N26),
    --   与本刀同源但不同件。**所以这里记的是"合同要不要求留样",不是"样品在哪"。**
    sample_retention_required boolean NOT NULL,
    -- 留多久也是一条条款;没约定就是 NULL,同样不给默认值。
    sample_retention_days integer
        CHECK (sample_retention_days IS NULL OR sample_retention_days > 0),

    -- ── 精炼费与惩罚元素的【口径声明】── 见抬头那条中心句
    --   'none_agreed' = 这份合同**声明了没有**;'per_metal'/'per_element' = 有,
    --   而具体数值在子表里。声明了有、子表却是空的 → 结算**按名拒**。
    refining_charge_basis text NOT NULL
        CHECK (refining_charge_basis IN ('none_agreed', 'per_metal')),
    penalty_basis text NOT NULL
        CHECK (penalty_basis IN ('none_agreed', 'per_element')),

    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    -- 一份合同一套结算口径
    CONSTRAINT contract_settlement_terms_one_per_contract UNIQUE (contract_id)
);

CREATE INDEX idx_contract_settlement_terms_contract
    ON public.contract_settlement_terms (contract_id);

ALTER TABLE public.contract_settlement_terms ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract settlement terms select by owner permission"
    ON public.contract_settlement_terms AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract settlement terms write by owner permission"
    ON public.contract_settlement_terms AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_settlement_terms IS
    'SETTLE-1:结算口径 —— 合同的第五个兄弟子表,一份合同一行,冻结时刻与品位规格/计价条款相同(挂接那一刻),**一份合同不许有两套冻结语义**。★★**本表的中心句**★★:**【没有声明】与【声明了"没有"】是两个不同的事实,而只有后者可以拿来算。** 那正是 assay_results.weight_basis 已经在用的规矩(PROC-6:留空 = 没人说过),本表把它推到精炼费与惩罚的口径声明上 —— refining_charge_basis = ''none_agreed'' 是一次**声明**,不是一次留空。★**为什么不让"没有子行"当成零**★:黑粉承购里精炼费近乎普遍,把没有子行读成没有精炼费,会算出一张**看起来完全正常而金额是错的发票**,不是任何人会注意到的那种错误。★**为什么也不一律拒**★:一份真的没有精炼费的合同必须仍然结算得了 —— 一条在正当情形上开火的拒绝,教会的是绕过它的办法。★**splitting_limit_pct 可空,而空永远不会变成一个决定**★:让系统按容差自动选,等于**让系统决定谁的数字是钱**,而容差为空时它还得**编一个默认值**才做得到 —— 所以它只用来指出差距,永远不自己选;有分歧又没声明容差时结算按名拒。★**留样**★:这里记的是**合同要不要求留样**(一条条款),不是样品在哪 —— 实物模型属于实验室工作流(N26),**而它今天不存在,所以仲裁路径有一个【说出来的】未满足前提:第三方复检要有一个罐子,而系统说不出某个样品还在不在**。';

COMMENT ON COLUMN public.contract_settlement_terms.sale_weight_basis IS
    'SETTLE-1:结算按湿基(as_received)还是干基(dry)。**必须声明,永远不给默认值。** GO-3 量过:全库只有 guard_assay_basis_stated 与 record_assay_result 提到 weight_basis,**没有任何计价或结算函数按它分支** —— 于是一张按干基出的化验单被乘在湿重上,含金属被高估,而没有任何东西会响。**那是一个钱的错误,不是一个政策缺口。**';

COMMENT ON COLUMN public.contract_settlement_terms.settling_party IS
    'SETTLE-1:哪一方的化验结果用于最终结算(U12 那条条款;它的返回条件写的正是「第一份写明化验条款的合同」,而本刀建的就是那个)。★**''umpire'' 不是这里的合法值**★:仲裁是一次**升级**,不是一份合同的常设约定。**哪一份结果真的被用了,记在 sales_settlements 上** —— 那是一次被记录的选择,不是从本列推导出来的。';

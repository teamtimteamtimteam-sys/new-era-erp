-- db/tables/contract_penalty_elements.sql
-- SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。
--
-- 【前置条件已经完成】惩罚要指名一种物质,而物质字典(`substances`)是
--   PROC 那一刀记下的前置条件,今天 7 条全部在册 —— 所以这一张挂得上外键,
--   而不是又一列自由文本(F7 那条规律:自由文本迟早要变字典,而拖延很贵)。
--   黑粉承购里**首推的两个惩罚元素是氟与氯**(proc-reality 的访谈),
--   而**它们今天不在 substances 里** —— 见下面那条注释,那是一个具名的缺席。
--
-- ★★【费率的形状是【一种】写法,而不是唯一一种 —— 说出来,不假装】★★
--   本表表达的是:**超过阈值之后,每超 1 个百分点、每吨结算重量收多少美元**。
--   真实合同还有别的写法(整段阶梯、封顶、按批一口价)。**Tim 没有给条款清单**,
--   所以本刀**只建这一种**,并把这句话写在这里 —— 下一个拿到真合同的人
--   要么发现它够用,要么知道该在哪儿加,而不是以为这就是全部。
--
-- ★【惩罚按【结算重量】收,所以它随湿基/干基变】★
--   这与 RC 相反(RC 按含金属吨数,含金属是不变量)。两条合起来才解释了
--   为什么同一批货按湿基与按干基结算出**不同的金额** —— 而那正是 GO-3
--   点名的那个"钱的错误"之所以是钱的错误。
--
-- NOTE: introduced by db/migrations/2026-08-30-settle1-the-settlement-basis.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_penalty_elements (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 指名一种物质 —— 外键,不是自由文本
    substance    text NOT NULL REFERENCES public.substances (code),
    -- 超过这个含量(%)才开始罚
    threshold_pct numeric NOT NULL CHECK (threshold_pct >= 0 AND threshold_pct <= 100),
    -- 每超 1 个百分点、每吨【结算重量】多少美元
    usd_per_tonne_per_pct_over numeric NOT NULL CHECK (usd_per_tonne_per_pct_over >= 0),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT contract_penalty_elements_one_per_substance UNIQUE (contract_id, substance)
);

CREATE INDEX idx_contract_penalty_elements_contract
    ON public.contract_penalty_elements (contract_id);

ALTER TABLE public.contract_penalty_elements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract penalty elements select by owner permission"
    ON public.contract_penalty_elements AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract penalty elements write by owner permission"
    ON public.contract_penalty_elements AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_penalty_elements IS
    'SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。前置条件(substances 字典)已完成,所以这里挂的是**外键而不是又一列自由文本**(F7:自由文本迟早要变字典,拖延很贵)。★★**费率的形状是【一种】写法,不是唯一一种**★★:本表表达「超过阈值后,每超 1 个百分点、每吨**结算重量**收多少美元」;真实合同还有阶梯、封顶、按批一口价等写法 —— **Tim 没有给条款清单**,所以本刀只建这一种,并把这句话写在这里,好让下一个拿到真合同的人知道该在哪儿加,而不是以为这就是全部。★**惩罚按结算重量收,所以它随湿基/干基变**★(与 RC 相反,RC 按含金属吨数、而含金属是不变量)—— 两条合起来解释了为什么同一批货按湿基与按干基结算出**不同的金额**。★**具名的缺席**★:访谈点名的头两个惩罚元素是**氟与氯**,而它们**今天不在 substances 里**(在册 7 条:al/co/cu/fe/li/mn/ni)—— 所以一条氟或氯的惩罚条款**今天填不进来**,那不是本表的缺陷,是字典还缺两行。';

COMMENT ON COLUMN public.contract_penalty_elements.usd_per_tonne_per_pct_over IS
    'SETTLE-1:每超阈值 1 个百分点、每吨【结算重量】多少美元。**「结算重量」= contract_settlement_terms.sale_weight_basis 选定的那个重量**(湿基取毛重,干基取扣水后重量)—— 所以**同一份惩罚条款在两种基准下收出不同的钱**,而那是对的:罚的是随货一起进来的杂质,而水也是随货一起进来的。';

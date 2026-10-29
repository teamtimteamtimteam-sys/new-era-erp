-- db/tables/contract_penalty_elements.sql
-- SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。
--
-- 【前置条件已经完成】惩罚要指名一种物质,而物质字典(`substances`)是
--   PROC 那一刀记下的前置条件 —— 所以这一张挂得上外键,
--   而不是又一列自由文本(F7 那条规律:自由文本迟早要变字典,而拖延很贵)。
--   黑粉承购里**首推的两个惩罚元素是氟与氯**(proc-reality 的访谈)。
--   ~~而它们今天不在 substances 里~~ —— ★ MES-6a-2(2026-10-10,Step 0 Q27 · Q31)加上了(role = penalty_element),
--   ~~而本表从那一刀起【只】收惩罚元素~~ ★ MES-6b-1(2026-10-15,F4;MES-6b Step 0 Q15,Tim):本表收惩罚元素【或可计价的金属】
--   (铜、铝在镍黑粉里是杂质)—— other 照拒(下面的 trg_contract_penalty_elements_substance_role)。一种物质在同一份合同里
--   既计价又罚按名拒 SUBSTANCE_PRICED_AND_PENALISED(trg_contract_penalty_elements_unpriced,计价条款那一侧同一支)。
--   结算的计价圈跳过一种被这份合同列为惩罚元素的可计价金属(sale_settlement_compute,Q34)。
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
                     AND ((c.customer_id IS NOT NULL AND (SELECT has_permission('module.customers.view'::text)))
                       OR (c.supplier_id IS NOT NULL AND (SELECT has_permission('module.suppliers.view'::text))))));
-- ★ ROLE-1 Batch 2b(Batch 2 grilling Q12 · Batch 2b grilling Q1):写条款只归 cco(action.contract_terms)。
CREATE POLICY "contract penalty elements write by owner permission"
    ON public.contract_penalty_elements AS PERMISSIVE FOR ALL TO authenticated
    USING ((SELECT has_permission('action.contract_terms'::text)))
    WITH CHECK ((SELECT has_permission('action.contract_terms'::text)));

COMMENT ON TABLE public.contract_penalty_elements IS
    'SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。前置条件(substances 字典)已完成,所以这里挂的是**外键而不是又一列自由文本**(F7:自由文本迟早要变字典,拖延很贵)。★★**费率的形状是【一种】写法,不是唯一一种**★★:本表表达「超过阈值后,每超 1 个百分点、每吨**结算重量**收多少美元」;真实合同还有阶梯、封顶、按批一口价等写法 —— **Tim 没有给条款清单**,所以本刀只建这一种,并把这句话写在这里,好让下一个拿到真合同的人知道该在哪儿加,而不是以为这就是全部。★**惩罚按结算重量收,所以它随湿基/干基变**★(与 RC 相反,RC 按含金属吨数、而含金属是不变量)—— 两条合起来解释了为什么同一批货按湿基与按干基结算出**不同的金额**。★**曾经的具名缺席,已经补上**★:访谈点名的头两个惩罚元素是**氟与氯**;MES-6a-2(2026-10-10)把它们加进了 substances(role = penalty_element)。★**MES-6b-1(F4,Q15)起本表收惩罚元素或可计价的金属**★(铜、铝在镍黑粉里是杂质;守卫 guard_substance_role,other 按名拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>);同一份合同里一种物质既计价又罚按名拒 SUBSTANCE_PRICED_AND_PENALISED|<码>,结算的计价圈跳过被列为惩罚元素的可计价金属。阈值以 % 记(惩罚元素的阈值屏幕上旁带 ppm;可计价金属的阈值只写 %),费率仍是每超 1 个百分点。';

COMMENT ON COLUMN public.contract_penalty_elements.usd_per_tonne_per_pct_over IS
    'SETTLE-1:每超阈值 1 个百分点、每吨【结算重量】多少美元。**「结算重量」= contract_settlement_terms.sale_weight_basis 选定的那个重量**(湿基取毛重,干基取扣水后重量)—— 所以**同一份惩罚条款在两种基准下收出不同的钱**,而那是对的:罚的是随货一起进来的杂质,而水也是随货一起进来的。';

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
-- 双码:持有其中任何一个即放行;一个都不持才抛。
-- 这道闸【只】管模块级的没权限;这张表的策略还判【行】,那一半仍由应用层兜着。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.contract_penalty_elements
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('action.contract_terms');

-- ★ APR-8(2026-09-26,grilling Q2 · Q5):合同生效中、或挂着一张在等的生效申请时,本表任何直连写按名拒
--   CONTRACT_TERMS_FROZEN|合同编号|active 或那一张申请。改条款 = 暂停、编辑、申请重新生效。属主路径放行。
CREATE TRIGGER trg_contract_penalty_elements_frozen
    BEFORE INSERT OR UPDATE OR DELETE ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_contract_terms_frozen();

-- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q27,Tim):惩罚条款只收惩罚元素 —— 别的按名拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>。
--    ★ MES-6b-1(2026-10-15,F4;MES-6b Step 0 Q15,Tim):收惩罚元素【或可计价的金属】—— 守卫的第一个参数是一组角色;other 照拒,话不变。
--    插入与改到 substance 的那一次才判;既有的行不回头判(substances.role 的列注)。不在字典里的码照旧由外键拒。
CREATE TRIGGER trg_contract_penalty_elements_substance_role
    BEFORE INSERT OR UPDATE OF substance ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal,penalty_element', 'substance');

-- ── MES-6b-1(2026-10-15,F4;MES-6b Step 0 Q33,Tim):一种物质在一份合同里要么计价、要么罚 —— 计价条款里已经有它就按名拒
--    SUBSTANCE_PRICED_AND_PENALISED|<码>(计价条款那一侧挂着同一支)。
--    ★ 名字排在 …_substance_role 之后(同一张表上的 BEFORE 触发器按名字排序触发):一种不在惩罚条款之列的物质先听到角色那一句。
CREATE TRIGGER trg_contract_penalty_elements_unpriced
    BEFORE INSERT OR UPDATE OF substance, contract_id ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_priced_and_penalised();

-- ★ GOLIVE-1 第 12 行(Tim 2026-10-25 TABLE-EXPORT-3c Q3 · 2026-10-29 Q9):价格那几列不再随行一起给 —— 列级 SELECT 授权只列不是钱的那些,
--   被遮的 usd_per_tonne_per_pct_over 只经 contract_penalty_elements_masked 读(按合同那一侧的价格码置空)。
--   写(INSERT / UPDATE / DELETE)的表级授权不变 —— PostgreSQL 的列级 SELECT 不跟着新加的列走,加列时记得同一支迁移里补进来(AGENTS.md)。
REVOKE SELECT ON public.contract_penalty_elements FROM authenticated, anon;
GRANT SELECT (id, contract_id, substance, threshold_pct, notes, created_at, created_by, updated_at, updated_by) ON public.contract_penalty_elements TO authenticated;

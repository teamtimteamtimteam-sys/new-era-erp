-- db/tables/commission_agreements.sql
-- COMM-1:付给中间商 / 代理人的佣金【条款】。
--
-- NOTE: introduced by db/migrations/2026-08-30-comm1-commission-terms-and-price-exposure.sql.
-- First-run script (plain CREATEs).
--
-- ★★【本表【不过账、也不算账】,而这是一条裁定,不是一个未完成】★★
--   先例明确:forwarder_rate_quotes「什么都不入账 —— 报价是"他说要多少",
--   实际运费是 freight_documents 那张凭证,两者是两件事」;
--   equipment_maintenance「指着钱、自己不过账」。**指着钱不等于要进总账。**
--
--   一笔佣金真的要付时,走【既有的路】:一张开给该 service_vendor 的 expenses ——
--   它已经会过账、日期必填(EXPENSE_DATE_REQUIRED)、已经带 WHT
--   (付给非居民代理人的佣金正是 wht_nature 的用处)。**本刀没有造第二条付款路。**
--
-- 【从协议算出金额那一半【没有建】,断点名 COMM-ACCRUAL-1】
--   理由:**一笔佣金都没有付过**,一条计提公式会被拟合到【零个案例】上。
--   记在 docs/forward-queue.md,带触发条件。

CREATE TABLE public.commission_agreements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- 【他是一个 supplier,而这不是将就】一个中间商既不是我们的客户、也不卖货给
    -- 我们,他【提供服务】—— 而 suppliers.counterparty_type 里 'service_vendor'
    -- 这一档本来就在。先例是货代:一个不卖货的第三方照样住在 suppliers 里,
    -- 于是应付账龄 / 付款 / 预付冲抵 / 外币重估整条链一个字都不用改。
    -- **所以本刀不需要 parties 主表** —— COUNTERPARTY-ONE-PARTY 仍然开着,
    -- 它的触发条件是批量导入,与本刀无关。
    agent_supplier_id uuid NOT NULL REFERENCES public.suppliers (id),

    -- free_standing = 既不挂采购也不挂销售的一般代理约定(例如一份年度居间协议)。
    -- 【它不指向某一张单据】—— 那是 COMM-ACCRUAL-1 的活。
    side text NOT NULL
        CHECK (side IN ('purchase', 'sale', 'free_standing')),

    basis text NOT NULL
        CHECK (basis IN ('percentage_of_value', 'per_tonne', 'fixed_amount')),

    -- 百分比与金额【互斥】,由 commission_agreements_basis_fields 强制。
    rate_pct   numeric CHECK (rate_pct IS NULL OR (rate_pct > 0 AND rate_pct <= 100)),
    amount_ccy numeric CHECK (amount_ccy IS NULL OR amount_ccy > 0),
    currency text REFERENCES public.currencies (code),

    -- ★ 义务何时产生 —— NOT NULL,【没有默认值】。见列注释。
    recognition_trigger text NOT NULL
        CHECK (recognition_trigger IN ('on_shipment', 'on_invoice', 'on_counterparty_payment')),

    valid_from date NOT NULL,
    valid_to   date NOT NULL,

    remarks text,

    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid(),

    CONSTRAINT commission_agreements_validity_order
        CHECK (valid_to >= valid_from),

    CONSTRAINT commission_agreements_basis_fields CHECK (
        (basis = 'percentage_of_value'
             AND rate_pct IS NOT NULL AND amount_ccy IS NULL AND currency IS NULL)
     OR (basis IN ('per_tonne', 'fixed_amount')
             AND rate_pct IS NULL AND amount_ccy IS NOT NULL AND currency IS NOT NULL)
    )
);

CREATE INDEX idx_commission_agreements_agent
    ON public.commission_agreements (agent_supplier_id);

COMMENT ON TABLE public.commission_agreements IS
'COMM-1:付给中间商 / 代理人的佣金【条款】。**它不过账、也不算账** —— 先例是 forwarder_rate_quotes(「什么都不入账」)与 equipment_maintenance(「指着钱、自己不过账」):指着钱不等于要进总账。一笔佣金真的要付时,走既有的路 —— 一张开给该 service_vendor 的 expenses,它已经会过账、已经带 WHT。**从协议算出金额那一半没有建**,断点名 COMM-ACCRUAL-1:一笔佣金都没有付过,一条计提公式会被拟合到零个案例上。代理人住在 suppliers 里(counterparty_type = service_vendor,先例是货代),所以本刀【不需要】parties 主表,COUNTERPARTY-ONE-PARTY 仍然开着。';

COMMENT ON COLUMN public.commission_agreements.recognition_trigger IS
'COMM-1:这笔佣金的义务【什么时候产生】—— 发运时 / 开票时 / 对方付款时。
★【NOT NULL 而且【没有默认值】,这是本表最要紧的一句】★
不同代理人签的条款不同,所以它是一条【逐协议的条款】,不是一个可以由系统猜的规矩。
给它一个默认值,等于系统替一个【没有人签过】的商业立场做主 —— 而这个立场决定确认期间,
正是 FIN-10 一族(十一支函数把 CURRENT_DATE 默认换成具名拒绝)反复付账的那一类。
说不出来就拒,不要替人填一个。';

COMMENT ON COLUMN public.commission_agreements.agent_supplier_id IS
'COMM-1:代理人 —— 一个 counterparty_type = ''service_vendor'' 的 supplier(由 guard_commission_agreement_agent() 强制)。他既不是客户也不卖货给我们,而 service_vendor 这一档本来就在。先例是货代:一个不卖货的第三方住在 suppliers 里,应付账龄 / 付款 / 预付冲抵 / 外币重估整条链因此一个字都不用改。';

COMMENT ON COLUMN public.commission_agreements.side IS
'COMM-1:这份协议挂在采购侧、销售侧,还是独立(free_standing,例如一份年度居间协议)。**它不指向某一张单据** —— 把协议连到具体那笔交易是 COMM-ACCRUAL-1 的活。';

COMMENT ON COLUMN public.commission_agreements.basis IS
'COMM-1:计费口径。percentage_of_value 填 rate_pct;per_tonne 与 fixed_amount 填 amount_ccy + currency。互斥由 commission_agreements_basis_fields 强制 —— 一行同时写着 2% 和 5000 元,读的人说不出哪个算数。';

CREATE TRIGGER trg_commission_agreements_agent
    BEFORE INSERT OR UPDATE ON public.commission_agreements
    FOR EACH ROW EXECUTE FUNCTION guard_commission_agreement_agent();

CREATE TRIGGER trg_commission_agreements_updated_at
    BEFORE UPDATE ON public.commission_agreements
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 【为什么是 suppliers 而不是 purchasing / sales】这一行的【主语是代理人】,
-- 而代理人是一个 supplier;每一行都有代理人,无论它挂哪一侧。
-- 按 side 分权限会让 free_standing 那一档【无家可归】,
-- 而按 purchasing 分会让一份销售侧的居间协议落在采购的门后面。
-- 与 CONTRACT-1 把 /contracts 归在供应商模块之下是同一条判断。
ALTER TABLE public.commission_agreements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "commission_agreements select" ON public.commission_agreements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.suppliers.view'::text));
CREATE POLICY "commission_agreements write" ON public.commission_agreements
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.suppliers.edit'::text))
    WITH CHECK (has_permission('module.suppliers.edit'::text));

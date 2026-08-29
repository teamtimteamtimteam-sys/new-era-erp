-- db/tables/contract_insurance_obligations.sql
-- CONTRACT-1:合同里那条【谁来投保、保到多少】的义务。
--
-- ★★【这【不是】保险登记簿的第二个家 —— 它们是两件事,而判据是它们能各自为真】★★
--   (Tim 2026-08-29 裁定 A3)
--
--   · **我们持有的保单**:一份有【到期日】的东西,由既有那套机制管着 ——
--     `certificate_types`(RUNTIME CONFIG:加一种证书是在界面上加一行,不是跑迁移)
--     + `company_compliance`(我们自己那一侧,已经有 cert_no / issuing_body /
--     scope / valid_from / valid_until / document_path,而且它的表注写着
--     "第一张真执照进来不需要任何 schema 变更")。
--     **它已经有两个消费方**:`operations_now` 的看板臂与 `supplier_receiving_blocked`
--     的收货闸。给保险再造一套到期机制,就是把这两样又写一遍。
--
--   · **合同里那条义务**:一件【没有自己的到期日】的事。它约束的是【对手方】,
--     而它被违反的方式是**一份保单不存在**,不是一份保单过期。
--
--   两者能各自为真:我们可以持有一份保单而没有任何合同要求它;
--   一份合同可以要求投保而我们(或对方)一张保单都没有。
--   **所以它们是两个事实,不是一个事实的两个家。**
--
-- ★【本刀【刻意不建】那条连接:哪一份保单满足哪一条义务】★
--   "policy P 满不满足 contract C 的这条义务"是一次**判断**(险种对不对得上、
--   保额够不够、保障区间盖不盖得住、被保险人是不是对的那一方)——
--   **没有人裁过它**。而一条猜出来的自动连接会把一份【没有保障的合同报成已保障】,
--   那比不连坏得多。见 docs/known-issues.md 里那一条,附上它需要什么才答得了。
--
-- NOTE: introduced by db/migrations/2026-08-30-contract1-the-contract-register.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_insurance_obligations (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id    uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 【谁投保】这份义务落在哪一方身上 —— 合同里最常被记错的一格。
    insured_by     text NOT NULL CHECK (insured_by IN ('us','counterparty')),
    -- 险种。**不做成枚举**:货运险/产品责任/环境责任……各家合同的叫法不一样,
    -- 一个猜出来的枚举会逼人把真实险种塞进最近的那一格(与 role 那一列同一条)。
    cover_type     text NOT NULL CHECK (btrim(cover_type) <> ''),
    -- 最低保额。**可空** —— 有些条款只写"须投保",不写金额;
    -- 填了金额就必须有币种(下面那条 CHECK),否则那个数会被读错。
    min_amount     numeric CHECK (min_amount IS NULL OR min_amount >= 0),
    currency       text REFERENCES public.currencies (code),
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid(),
    -- 【一个没有单位的金额不是金额,是一个会被读错的数】—— 与 review_goals 的
    -- unit_required、payment_term_templates 的币种是同一条(FIN-29)。
    CONSTRAINT contract_insurance_amount_needs_currency
        CHECK (min_amount IS NULL OR currency IS NOT NULL)
);

CREATE INDEX idx_contract_insurance_contract
    ON public.contract_insurance_obligations (contract_id);

ALTER TABLE public.contract_insurance_obligations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract insurance select by owner permission"
    ON public.contract_insurance_obligations AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract insurance write by owner permission"
    ON public.contract_insurance_obligations AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_insurance_obligations IS
    'CONTRACT-1:合同里那条「谁来投保、保到多少」的义务。★★**它不是保险登记簿的第二个家 —— 两件事,判据是它们能各自为真**★★(Tim 2026-08-29):**我们持有的保单**是一件有到期日的东西,由既有机制管着(certificate_types 是 RUNTIME CONFIG,加一种证书是界面上加一行;company_compliance 已有 cert_no/issuing_body/scope/valid_from/valid_until/document_path,且已经有两个消费方 —— operations_now 的看板臂与 supplier_receiving_blocked 的收货闸)。**给保险再造一套到期机制,就是把那两样又写一遍。** 而**合同里那条义务没有自己的到期日**,它约束对手方,被违反的方式是**一份保单不存在**而不是一份保单过期。两者能各自为真:可以持有保单而无合同要求,也可以有要求而一张保单都没有。★**本刀刻意不建那条连接(哪份保单满足哪条义务)**★ —— 那是一次判断(险种、保额、保障区间、被保险人),没有人裁过,而一条猜出来的自动连接会把一份没有保障的合同报成已保障,比不连坏得多;记在 known-issues,附上它需要什么才答得了。';

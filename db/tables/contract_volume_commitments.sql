-- db/tables/contract_volume_commitments.sql
-- CONTRACT-1:卖方已承诺的量 —— 「每月不少于 200 吨」这一类条款。
--
-- 【为什么这一张与品位、保险并列而不是塞在合同行上】(A5)
--   它们都是【条款】,而条款天然是一串:一份合同可以承诺两种物料、
--   可以按月也可以按季。塞进合同那一行就得覆盖,而覆盖会让"当初承诺的是什么"消失。
--
-- ★【承诺的是【谁】—— 这一列不是装饰】★
--   在一份采购合同里,承诺供货的是【对方】;在一份销售合同里,承诺供货的是【我们】。
--   两者的下一步完全不同(前者是"催他交",后者是"我们排产"),
--   而只存一个数字的实现说不出是哪一种。
--
-- 【period 是【口径】,不是日历】'month'/'quarter'/'year'/'total' ——
--   'total' 表示"整个合同期内合计",那是框架协议的常见写法。
--   **本刀不算达成率**:算达成率要先回答"哪些单据算进这份承诺"
--   (下单算还是收货算?跨月的一船算哪个月?)—— 没有人裁过,
--   而一个算得出数、口径没人定过的达成率,比没有更坏。
--   记在 known-issues,带触发条件。
--
-- NOTE: introduced by db/migrations/2026-08-30-contract1-the-contract-register.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.contract_volume_commitments (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contract_id  uuid NOT NULL REFERENCES public.contracts (id) ON DELETE CASCADE,
    -- 谁承诺的 —— 见抬头
    committed_by_party text NOT NULL CHECK (committed_by_party IN ('us','counterparty')),
    material_id  uuid REFERENCES public.materials (id) ON DELETE RESTRICT,
    quantity     numeric NOT NULL CHECK (quantity > 0),
    unit         text NOT NULL CHECK (btrim(unit) <> ''),
    period       text NOT NULL CHECK (period IN ('month','quarter','year','total')),
    -- 承诺是"不少于"还是"不超过" —— 供货承诺与产能上限都是真实条款
    direction    text NOT NULL DEFAULT 'min' CHECK (direction IN ('min','max')),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid()
);

CREATE INDEX idx_contract_volume_contract ON public.contract_volume_commitments (contract_id);

ALTER TABLE public.contract_volume_commitments ENABLE ROW LEVEL SECURITY;
CREATE POLICY "contract volume select by owner permission"
    ON public.contract_volume_commitments AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.view'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.view'::text)))));
CREATE POLICY "contract volume write by owner permission"
    ON public.contract_volume_commitments AS PERMISSIVE FOR ALL TO authenticated
    USING (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))))
    WITH CHECK (EXISTS (SELECT 1 FROM contracts c WHERE c.id = contract_id
                     AND ((c.customer_id IS NOT NULL AND has_permission('module.customers.edit'::text))
                       OR (c.supplier_id IS NOT NULL AND has_permission('module.suppliers.edit'::text)))));

COMMENT ON TABLE public.contract_volume_commitments IS
    'CONTRACT-1:卖方已承诺的量(「每月不少于 200 吨」这一类)。与品位、保险并列是因为它们都是【条款】,而条款天然是一串 —— 塞进合同那一行就得覆盖,覆盖会让"当初承诺的是什么"消失。`committed_by_party` 不是装饰:采购合同里承诺供货的是对方,销售合同里是我们,而两者的下一步完全不同(催他交 vs 我们排产),只存一个数字的实现说不出是哪一种。★**本刀不算达成率**★:那要先回答"哪些单据算进这份承诺"(下单算还是收货算?跨月的一船算哪个月?)—— 没有人裁过,而**一个算得出数、口径没人定过的达成率比没有更坏**;记在 known-issues,带触发条件。';

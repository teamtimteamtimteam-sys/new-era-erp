-- db/tables/freight_documents.sql + freight_allocations
-- 运费单据与它的分摊行(FRT-1)。运费【资本化进批次成本】—— 第二个成本组件,
-- 不是更高的 unit_price(那是应付之锚,并进去等于让系统以为欠材料供应商更多钱,
-- 而运费欠的是货代)。
--
-- NOTE: introduced by db/migrations/2026-08-11-frt1-freight-capitalised-into-batch-cost.sql.
-- First-run script (plain CREATEs).
--
-- 【资本化的代价,原样记着】一次错的分摊【藏在存货里】,而不是显示在损益表上。
-- 所以分摊口径逐单申报、value 口径遇未计价批次点名拒绝、basis_qty 记下这一份是
-- 从什么数算出来的 —— 一个无法被重新导出的分摊,是一个只能被相信的数字。

-- ── 1 · 运费单据 ────────────────────────────────────────────────────────────
CREATE TABLE public.freight_documents (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code              text NOT NULL UNIQUE,   -- 'FRT-YYYY-NNNN',无缝编号
    doc_date          date NOT NULL,
    -- 【货代,不是材料供应商】这一列就是本刀最要紧的那个区别所在
    supplier_id       uuid NOT NULL REFERENCES public.suppliers (id),
    amount_ccy        numeric NOT NULL CHECK (amount_ccy > 0),
    currency          text NOT NULL REFERENCES public.currencies (code),
    fx_rate           numeric NOT NULL CHECK (fx_rate > 0),
    amount_base       numeric NOT NULL,       -- round(amount_ccy × fx_rate, 2)
    -- 【逐单申报的分摊口径,没有 schema 默认值】(FIN-36 的判别法:
    -- 看得见的默认值才不是假设)。weight / value / stated 各自的拒绝见写入函数。
    allocation_basis  text NOT NULL CHECK (allocation_basis IN ('weight','value','stated')),
    payment_status    text NOT NULL CHECK (payment_status IN ('paid','unpaid')),
    bank_account_code text CHECK (bank_account_code IN ('1000','1010')),
    notes             text,
    journal_entry_id  uuid REFERENCES public.journal_entries (id),
    status            text NOT NULL DEFAULT 'posted' CHECK (status IN ('posted','reversed')),
    deleted_at        timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        uuid DEFAULT auth.uid(),
    -- 与 expenses 同形:已付必须有银行科目;未付必须有供应商(它因此成为一张应付单据)
    -- 且不能有银行科目。supplier_id 在本表恒非空(运费总有货代),所以未付分支只挡银行科目。
    CONSTRAINT freight_documents_payment_shape CHECK (
        (payment_status = 'paid'   AND bank_account_code IS NOT NULL) OR
        (payment_status = 'unpaid' AND bank_account_code IS NULL)
    ),
    -- ── LOG-4a 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【direction 没有 schema 默认值】看得见的默认值才不是假设(FIN-36)。
    -- 一个默认成 inbound 的出口运费会安静地钻进存货 —— 那正是
    -- docs/landed-cost-scoping.md 说的"看不见的错误"。
    direction         text NOT NULL CHECK (direction IN ('inbound','outbound')),
    -- 出口运费【可以】指向一个箱子,但单据本身才是钱的对象(Tim 定)。
    container_id      uuid REFERENCES public.containers (id),
    -- 冲销的留痕(AUDEL 家族:谁、为什么、哪一张冲销分录)
    reversed_at       timestamptz,
    reversed_by       uuid,
    reversal_reason   text,
    reversal_entry_id uuid REFERENCES public.journal_entries (id)
);

COMMENT ON COLUMN public.freight_documents.supplier_id IS
    'FRT-1:【货代】,不是材料供应商。未付运费的贷方(2000)记在这个对手方名下 —— 既有的每一条差额路径都贷 2000 且意指材料供应商,照抄会把运费账记到错的人头上,而分录仍然是平的。fixture 51 A 臂两半各钉一次。';
COMMENT ON COLUMN public.freight_documents.allocation_basis IS
    'FRT-1:这一单怎么分到各批 —— weight(按重量)/ value(按货值)/ stated(单据自己列明)。【逐单申报,不给 schema 默认值】:重量口径与货值口径【恰恰在最要紧的时候分歧最大】(一批轻而贵的货与一批重而便宜的货同船)。stated 不是点缀:货代常常自己列明,而对一张已经回答了这个问题的单据再去分摊,是在编造一个分法。';

COMMENT ON COLUMN public.freight_documents.direction IS
    'LOG-4a:这张运费单是【进货运费】还是【出口运费】。两者【不是同一种成本】:
inbound 资本化进批次成本(借 1200/5000,分摊到进料批);outbound 是期间费用(借 6300),
永不进存货、永不进 COGS、【永远没有分摊行】(freight_allocations 上的守卫按名拒)。
没有 schema 默认值 —— 一个默认成 inbound 的出口运费会安静地钻进存货,
而那正是 docs/landed-cost-scoping.md 说的"看不见的错误"。';
COMMENT ON COLUMN public.freight_documents.container_id IS
    'LOG-4a:出口运费【可以】指向一个箱子,但单据本身才是钱的对象(Tim 定)——
所以这一列可空:货代的一张账单可能同时覆盖几个箱子,也可能在箱子建档之前就到。
指了就必须指得中:箱子不存在或已软删【按名拒】(EXPORT_FREIGHT_CONTAINER_NOT_FOUND)。
进货运费不用这一列 —— 它的归属是分摊行指向的那些进料批。';
COMMENT ON COLUMN public.freight_documents.reversal_reason IS
    'LOG-4a:冲销的理由,必填(AUDEL 家族)。没有理由的冲销,事后没人答得出为什么。';

CREATE TRIGGER trg_freight_documents_updated_at
    BEFORE UPDATE ON public.freight_documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- LOG-4a:运费的对手方只能是货代。containers.forwarder_id 与
-- forwarder_rate_quotes.supplier_id 早就有这条守卫,【唯独运费单没有】——
-- FRT-1 早于 counterparty_type,那是时间差,不是决定。
CREATE TRIGGER trg_freight_documents_forwarder
    BEFORE INSERT OR UPDATE OF supplier_id ON public.freight_documents
    FOR EACH ROW EXECUTE FUNCTION guard_freight_document_forwarder();

-- LOG-4a:status 不再是手改得到的 —— 'reversed' 只能由 reverse_freight_document
-- 写进去,它会记下理由、经手人,并冲掉那张分录。
CREATE TRIGGER trg_freight_documents_status_guard
    BEFORE UPDATE ON public.freight_documents
    FOR EACH ROW EXECUTE FUNCTION guard_freight_status_transition();

ALTER TABLE public.freight_documents ENABLE ROW LEVEL SECURITY;
CREATE POLICY "freight_documents select by permission"
    ON public.freight_documents AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view') OR has_permission('module.finance.view'));
CREATE POLICY "freight_documents write by permission"
    ON public.freight_documents AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.finance.edit'))
    WITH CHECK (has_permission('module.finance.edit'));

-- ── 2 · 分摊行 ──────────────────────────────────────────────────────────────
CREATE TABLE public.freight_allocations (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    freight_document_id uuid NOT NULL REFERENCES public.freight_documents (id) ON DELETE RESTRICT,
    inbound_batch_id    uuid NOT NULL REFERENCES public.inbound_batches (id),
    amount_base         numeric NOT NULL CHECK (amount_base >= 0),
    -- 【这一列是"可审计"与"只是碰巧算对了"的分界】
    basis_qty           numeric,
    -- 过账那一刻的在库比例:拆账用的就是它,事后 remaining_qty 会继续变
    in_stock_ratio      numeric NOT NULL CHECK (in_stock_ratio >= 0 AND in_stock_ratio <= 1),
    created_at          timestamptz NOT NULL DEFAULT now(),
    created_by          uuid DEFAULT auth.uid(),
    UNIQUE (freight_document_id, inbound_batch_id)
);

COMMENT ON COLUMN public.freight_allocations.basis_qty IS
    'FRT-1:这一份是【从什么数算出来的】—— weight 口径记该批重量,value 口径记该批货值(quantity × unit_price),stated 口径为空(金额是人直接列明的,没有可再导出的中间量)。这一列是"可审计"与"只是碰巧算对了"的分界:一个无法被重新导出的分摊,是一个只能被相信的数字,而这个仓库已经花了好几刀把那一类拆掉(FIN-26 的 price_source、METAL-3 的 fx_legs 同源)。';
COMMENT ON COLUMN public.freight_allocations.in_stock_ratio IS
    'FRT-1:过账那一刻的 remaining_qty / quantity。拆账按它分:在库份额进 1200,已耗份额进 5000。【记下来而不是事后重算】—— remaining_qty 之后还会变,事后算出来的是另一个答案(与 metal_prices.anomaly_check 同一条论证)。收货即到的运费在这里就是 1,那是同一条路径的边界情形,不是另一条路径。';

ALTER TABLE public.freight_allocations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "freight_allocations select by permission"
    ON public.freight_allocations AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view') OR has_permission('module.finance.view'));
CREATE POLICY "freight_allocations write by permission"
    ON public.freight_allocations AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.finance.edit'))
    WITH CHECK (has_permission('module.finance.edit'));

CREATE INDEX idx_freight_allocations_batch ON public.freight_allocations (inbound_batch_id);

-- LOG-4a:出境单据【没有分摊行】—— 在表上拒,不是靠"RPC 没提供那条路"。
-- RPC 不提供只是没铺路,守卫才是墙,而直插是这套系统里真实存在的一条路。
CREATE TRIGGER trg_freight_allocations_direction
    BEFORE INSERT OR UPDATE ON public.freight_allocations
    FOR EACH ROW EXECUTE FUNCTION guard_freight_allocation_direction();

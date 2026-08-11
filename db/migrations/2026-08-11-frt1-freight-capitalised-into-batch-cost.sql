-- FRT-1(2026-08-11):运费【资本化进批次成本】—— 第二个成本组件,不是更高的单价
--
-- Doc 1 把 "transport-cost accounting(freight, duties, insurance —— capitalized
-- into material cost?)" 打了个问号,Doc 2 把"运费分摊进批次成本"列为已知难题。
-- 两处都没建。它现在要紧,是因为批次毛利刚上线:运费落在批次之外,
-- 每一个毛利数就被【它花了多少钱运到这里】那么多地高估着。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么资本化 —— 以及这个选择的代价,原样记下】
-- Tim 的决定:资本化。理由不是"准则这么说"(虽然准则确实这么说),而是这门生意上
-- 运费相对货值【不可能不重大】,而费用化会让每批毛利【系统性地、且无声地】高估 ——
-- Tim 永远不会看见高估了多少。
--
-- **代价照记,它是真的,不是理论上的**:资本化之后,一次错的分摊【藏在存货里】,
-- 而不是显示在损益表上。费用化的错误看得见,资本化的错误看不见。所以:
--   * 分摊口径【逐单申报】,不给 schema 默认值;
--   * value 口径遇到未计价批次【点名拒绝】,不悄悄给零份额;
--   * fixture 的份量大半压在"分摊本身"而不是"过账本身"。
--
-- 【为什么是第二个成本组件,绝不并进 unit_price】
-- inbound_batches.unit_price 是【应付之锚】:ap_open_items 按 quantity × unit_price
-- 算我们欠供应商多少,reprice_inbound_batch 的每一次价差都贷 2000。把运费并进去,
-- 就等于让系统认为我们欠【材料供应商】更多钱 —— 而运费是欠【货代】的,那是另一个
-- 对手方。落地成本 = quantity × unit_price + 运费,两个组件、两个对手方、两张单据。
--
-- 【迟到的运费是主路径,不是例外】
-- 收货 → 加工 → 卖出 → 运费发票才到,是【正常】顺序。所以拆账比例
-- (remaining_qty / quantity)取【过账那一刻】的值,于是收货时就到的运费只是
-- ratio = 1 这个边界情形 —— 只有一条代码路径,没有两条需要保持同步的实现。
--
-- 【差额算术可以借,过账不可以】
--   借 1200 在库份额 / 借 5000 已耗份额  ← 与 reprice_split 同一份算术(同一个问题)
--   贷 1010|1000(已付)/ 贷 2000(未付)  ← 【新写的】:对手方是货代
-- 既有的每一条差额路径都贷 2000 且意指【材料供应商】的应付 —— 照抄会把一张运费账
-- 记到错的对手方名下,分录还是平的,不报任何错。fixture 的 A 臂两半都断言:
-- 贷方点名货代,【且材料供应商的应付分毫未动】(只断言前半,一个"两边都贷"的
-- 实现照样通过)。
--
-- 【已耗份额进 5000,与既有惯例一致】重分摊随后把属于未售产出的那部分从 5000
-- 拨进 1220(FIN-24),两套机制因此是【组合】而不是【重复计数】—— fixture 18 钉着
-- 那个组合,本刀不动它。
--
-- 【过期传播不是可选项 —— 漏了它就是本刀的头号缺陷】
-- processing_run_allocation_status.last_cost_change 原本看三个来源(成本条目、
-- 输入批的 price_history、上游分摊)。迟到的运费改变的是【已被消耗的批次】的成本,
-- 它若不是第四个来源,吃过那批货的加工单永远不会标过期,batch_margin 会一直停在
-- 运费之前的那个数 —— 而运费过账本身完全正确。
-- 【一个过账全对、只是忘了标过期的实现,能通过其它每一条断言】,所以 fixture 有
-- 一臂专门打它。
--
-- 【GST 是一道闸门,不是一句备注】进口 GST 是【可抵扣的进项税】(1400),
-- 资本化它会同时高估存货【并】毁掉抵扣。今天 gst_registered = false、税率 0,
-- 所以这里直接【点名拒收】任何 GST 组件;将来登记之后该怎么走(拆进 1400、
-- 不参与分摊)写在下面的注释里,而不是留给人猜。
--
-- 【关税与保险:另外两种形状,本刀不建】见 docs/landed-cost-scoping.md。
-- 关税【天然按批】—— 它是按那批货的完税价格、常常按材料各异的税率课的,
-- 在混装货上分摊它是【错的】,不是"另一种口径"。保险则取决于 Tim 的保单怎么写,
-- 而他还没说 —— 那份文件里记的是问题,不是答案。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

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
    )
);

COMMENT ON COLUMN public.freight_documents.supplier_id IS
    'FRT-1:【货代】,不是材料供应商。未付运费的贷方(2000)记在这个对手方名下 —— 既有的每一条差额路径都贷 2000 且意指材料供应商,照抄会把运费账记到错的人头上,而分录仍然是平的。fixture 51 A 臂两半各钉一次。';
COMMENT ON COLUMN public.freight_documents.allocation_basis IS
    'FRT-1:这一单怎么分到各批 —— weight(按重量)/ value(按货值)/ stated(单据自己列明)。【逐单申报,不给 schema 默认值】:重量口径与货值口径【恰恰在最要紧的时候分歧最大】(一批轻而贵的货与一批重而便宜的货同船)。stated 不是点缀:货代常常自己列明,而对一张已经回答了这个问题的单据再去分摊,是在编造一个分法。';

CREATE TRIGGER trg_freight_documents_updated_at
    BEFORE UPDATE ON public.freight_documents
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

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

-- ── 3 · 每批的运费合计:一处实现,派生而非冗余列 ──────────────────────────────
CREATE OR REPLACE FUNCTION public.batch_freight_base(p_inbound_batch_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    -- 【派生,不存冗余列】落地成本 = quantity × unit_price + 本函数。
    -- 冲销掉的运费单不计(status = 'reversed')。
    SELECT COALESCE(SUM(fa.amount_base), 0)
    FROM freight_allocations fa
    JOIN freight_documents fd ON fd.id = fa.freight_document_id
    WHERE fa.inbound_batch_id = p_inbound_batch_id
      AND fd.deleted_at IS NULL AND fd.status = 'posted';
$function$;

COMMIT;

-- db/tables/inventory_movements.sql
-- Inventory movement ledger — immutable, append-only. THE source of truth for stock.
-- Core invariant: for every batch, remaining_qty = Σ qty_delta of its movements
-- (enforced by a DEFERRABLE INITIALLY DEFERRED constraint trigger; remaining_qty is a
-- guarded cache). Movements are NEVER updated or deleted.
--
-- Its two triggers below reference functions defined in
-- db/functions/inventory_ledger_triggers.sql (reject_movement_mutation, check_ledger_invariant)
-- — run that file first.
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut1-inventory-ledger.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.inventory_movements (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id  uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    -- STK-1:末尾两个是状态变更的两条腿。【为什么是 out/in 而不是 hold/release】
    -- 暂扣 = 出 available + 进 on_hold,释放 = 出 on_hold + 进 available:
    -- 两者形状相同,方向由每条腿的 stock_status 表达。用 hold/release 命名会把
    -- 方向编码两遍(类型里一次、状态里一次),而两处编码同一件事总有对不上的那天。
    movement_type    text NOT NULL CHECK (movement_type IN
        ('receipt','processing_consume','processing_produce','reversal_restore','reversal_void','sale','writeoff','adjustment',
         'status_change_out','status_change_in',
         -- IOD-1:转移的两条腿。转移【保留状态】—— 搬的是位置不是状态,
         -- 一批被扣住的货换个货架仍然是被扣住的。
         'transfer_out','transfer_in')),
    qty_delta        numeric NOT NULL CHECK (qty_delta <> 0),
    run_id           uuid REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    location_id      uuid REFERENCES public.storage_locations (id) ON DELETE RESTRICT,
    business_date    date,   -- FIN-32:见文末 COMMENT 与 NOT VALID 约束
    notes            text,
    occurred_at      timestamptz NOT NULL DEFAULT now(),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    -- ── STK-1 追加(ALTER 加的列排在末尾,与线上 ordinal 一致)──────────────
    -- 这一行进入/离开的是哪个库存桶。DEFAULT 'available':既有的五个写入者
    -- (收货/加工/销售/盘点/冲销)动的都是可用库存 —— 那本来就是它们的语义,
    -- 所以它们一个字都不用改。【不要与 inbound_batches.status / output_batches.status
    -- 混淆】,那两列与库存无关且无人写入(见 docs/known-issues.md)。
    -- 【库位与合规:闸在哪里 —— IOD-2 起】(2026-08-13)
    -- location_id 从 IOD-1 起由收货/转移/排空三条路写入。从 IOD-2 起,**货落进
    -- 某个库位的那一刻会被检查**:判词是 check_location_class(库位, 物料),
    -- 四个落地点共用(三个建批次 RPC 与 create_stock_transfer 的【入】腿)。
    -- 三态见 storage_location_allowed_classes 表头 —— 只有"配了、且不含这一类"
    -- 才拒绝;未配置的库位与未分类的物料【告警而不拒绝】。
    -- 【这里写的是它管不到什么,因为那才是容易误会的一半】:出库腿(transfer_out
    -- /销售排空/投料消耗)与状态变更(暂扣/释放)**一个字都不查** —— 分类管的是
    -- 货可以待在哪里,不是能不能离开。而【已经躺在某个库位上的货,不会因为那个
    -- 库位的配置后来改了而被重新检查】,今天也没有任何东西会把这种存量冲突说出来
    -- (归告警/通知那一刀)。看见 location_id 的人最容易以为"合规都在管了"。
    -- ┌─ 【三个桶,以及它们之间允许走哪几条边 —— 逐条写出来】──────────────────┐
    -- │     available → on_hold      hold_stock                               │
    -- │     on_hold   → available    release_stock                            │
    -- │     available → committed    reserve_stock        (SO-2)              │
    -- │     committed → available    release_reservation  (SO-2)              │
    -- │     on_hold  ↔  committed    【不存在,而这是一个决定】                │
    -- │ 暂扣说的是"这批货现在不能动"(品控、争议、等复检),预留说的是"这批货  │
    -- │ 许给了某张订单"。直接从一个跳到另一个,等于让系统替人回答"那个暂扣的   │
    -- │ 理由还成不成立"—— 它不知道。要走这条路:先释放,再预留,两步各留各的   │
    -- │ 理由。                                                                 │
    -- ├─ 【SO-2 之前这里写的是"committed 没有写入者,等销售单落地那一刀再加"】─┤
    -- │ 那句话已经【退役】,因为它的前提消失了(SO-1 落地了销售订单,SO-2 落地  │
    -- │ 了 reserve_stock)。留着一句描述已不存在的空缺的注释,与断言一个不可能  │
    -- │ 发生的危险同罪 —— 读的人会因此相信这里仍然没有写入者。                 │
    -- ├─ 【要加第四种状态?先读这一条 —— 它是想过之后明确不放这里的】──────────┤
    -- │ * awaiting_assay(待化验)【不属于这里,它是派生的】。今天由           │
    -- │   db/views/operations_now.sql 的 awaiting_assay 支给出,判据是         │
    -- │   batch_assay_status.assay_count = 0 —— "这批货有没有化验单"本身就     │
    -- │   存在 assay_results 里,现算即可。把它固化成一个【存下来的】状态,     │
    -- │   等于给一个已有唯一真相的事实开第二个副本,而两份副本迟早不一致 ——    │
    -- │   `?? 0` / COALESCE 那类病的反向版本:不是把缺失伪装成零,而是把       │
    -- │   【算得出来的】变成【要维护的】。                                     │
    -- │ 判据一句话:一个新状态要进这里,它必须有一个【写入者】,而且那个写入者 │
    -- │ 记的事实无法从别处现算出来。committed 两条都满足(预留是一个决定,      │
    -- │ 不是一个可推导的事实);awaiting_assay 第二条不满足。                   │
    -- └──────────────────────────────────────────────────────────────────────┘
    stock_status     text NOT NULL DEFAULT 'available'
                     CHECK (stock_status IN ('available','on_hold','committed')),
    -- 【成对流水】的两条腿由它连起来。今天两种成对:状态变更(换状态桶)与
    -- 转移(换库位)。四种成对类型当且仅当带 pair_id。
    pair_id          uuid,
    -- exactly one batch reference
    CONSTRAINT inventory_movements_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL)),
    -- sign must match movement_type
    CONSTRAINT inventory_movements_sign CHECK (CASE movement_type
        WHEN 'receipt' THEN qty_delta > 0
        WHEN 'processing_produce' THEN qty_delta > 0
        WHEN 'reversal_restore' THEN qty_delta > 0
        WHEN 'processing_consume' THEN qty_delta < 0
        WHEN 'reversal_void' THEN qty_delta < 0
        WHEN 'sale' THEN qty_delta < 0
        WHEN 'writeoff' THEN qty_delta < 0
        WHEN 'status_change_out' THEN qty_delta < 0
        WHEN 'status_change_in' THEN qty_delta > 0
        WHEN 'transfer_out' THEN qty_delta < 0
        WHEN 'transfer_in' THEN qty_delta > 0
        ELSE true END),
    -- batch side must match movement_type
    -- FIN-25b:consume/restore 放开为任一侧(再加工耗产出批);恰一批次由
    -- one_batch XOR 把守。produce/void/sale 仍钉产出侧。
    CONSTRAINT inventory_movements_side CHECK (CASE movement_type
        WHEN 'processing_produce' THEN output_batch_id IS NOT NULL
        WHEN 'reversal_void' THEN output_batch_id IS NOT NULL
        WHEN 'sale' THEN output_batch_id IS NOT NULL
        ELSE true END),
    -- STK-1:配对列【当且仅当】状态变更行才有值 —— 两个方向都管:状态变更行漏了
    -- 配对 id,与普通行误带配对 id,撞的是同一条 CHECK。
    CONSTRAINT inventory_movements_pair CHECK (
        (movement_type IN ('status_change_out','status_change_in','transfer_out','transfer_in'))
        = (pair_id IS NOT NULL))
);
-- No deleted_at, no updated_at: immutable by design.

CREATE INDEX idx_inventory_movements_inbound  ON public.inventory_movements (inbound_batch_id);
CREATE INDEX idx_inventory_movements_output   ON public.inventory_movements (output_batch_id);
CREATE INDEX idx_inventory_movements_run      ON public.inventory_movements (run_id);
CREATE INDEX idx_inventory_movements_occurred ON public.inventory_movements (occurred_at);
CREATE INDEX idx_inventory_movements_status_pair ON public.inventory_movements (pair_id);
CREATE INDEX idx_inventory_movements_bucket
    ON public.inventory_movements (inbound_batch_id, output_batch_id, location_id, stock_status);

-- RLS: authenticated may SELECT and INSERT only — no UPDATE/DELETE policies exist.
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inventory_movements select by permission"
    ON public.inventory_movements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'::text));

CREATE POLICY "inventory_movements insert by permission"
    ON public.inventory_movements
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inventory.edit'::text));

-- Its own triggers (functions live in db/functions/inventory_ledger_triggers.sql):
--   * immutability belt-and-braces
CREATE TRIGGER trg_inventory_movements_immutable
    BEFORE UPDATE OR DELETE ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.reject_movement_mutation();
--   * the shared remaining_qty invariant (deferred)
CREATE CONSTRAINT TRIGGER trg_inventory_movements_invariant
    AFTER INSERT ON public.inventory_movements
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_ledger_invariant();
--   * STK-1:任何一个桶都不许为负(守卫函数在 db/functions/check_no_negative_bucket.sql)
--     同样 DEFERRABLE:成对写入的两行必须一起看,分开看必有一瞬为负。
--     它顺带挡住"把已扣住的货卖掉"—— 那不是另写的规则,是桶不许为负的结果。
CREATE CONSTRAINT TRIGGER trg_inventory_movements_no_negative_bucket
    AFTER INSERT ON public.inventory_movements
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_no_negative_bucket();

-- FIN-32:业务日 —— 每条写入路径都要写,而且写的是【记录里的那个日期】,不是时钟。
-- 新行必填、老行放过:CHECK ... NOT VALID 对【新插入与更新】强制,不回头校验既有
-- 15 行历史空值(它们不回填 —— 按今天补一个业务日是编造一条没人记录过的事实)。
-- 本表由 reject_movement_mutation 挡住 UPDATE/DELETE,所以老行不会被"更新"撞上它。
ALTER TABLE public.inventory_movements
    ADD CONSTRAINT inventory_movements_business_date_required
    CHECK (business_date IS NOT NULL) NOT VALID;

COMMENT ON COLUMN public.inventory_movements.business_date IS '这件事【在业务上发生在哪一天】,与 created_at(什么时候被记进系统)是两回事。收货取 arrival_date、加工取 process_date、销售取销售日、注销取 deleted_at 那天、盘点调整取过账日(stocktakes.started_at 只是建单时间戳,与 created_at 逐微秒相等,不是盘点日 —— FIN-32-fu1 查证);冲销/还原取【原加工单的 process_date】—— 回滚是在更正一次记错的加工单,不是一次物理事件,所以一错一改在同一天对消。【注意两个账会给出两个日期】:同一次更正,分录侧按显式传入的冲销日入账(期间锁使然),本表按原加工日 —— 价值账带锁、数量账不带,各自回答不同的问题。NULL = FIN-32 之前写入的行,当时这条路径根本没写它 —— 【不回填】,界面读作"未知"。新行由 inventory_movements_business_date_required(NOT VALID)强制必填。';

-- STK-1:两列的说明写进数据库,重建出来的库也带着(与 business_date 同办)。
COMMENT ON COLUMN public.inventory_movements.stock_status IS
    'STK-1:这一行进入/离开的是哪个库存桶(available / on_hold / committed)。状态是流水的属性,不是批次的字段 —— 一个批次同时可以有"60 可用、40 暂扣",一个字段答不了。【三个桶各自的写入者】:on_hold 由 hold_stock / release_stock 成对写;committed 由 reserve_stock / release_reservation 成对写(SO-2,销售订单预留)。【on_hold 与 committed 之间没有直达的边】—— 那是一个决定:暂扣说"现在不能动",预留说"许给了某张单",系统无从判断跳过去之后那个暂扣的理由还成不成立;要走这条路,先释放再预留,两步各留各的理由。【不要与 inbound_batches.status / output_batches.status 混淆】—— 那两列与库存无关(且无人写入),见 docs/known-issues.md。';

COMMENT ON COLUMN public.inventory_movements.pair_id IS
    'IOD-1(STK-1 起名为 status_pair_id):把一次【成对流水】的两条腿连起来。今天有两种成对:状态变更(出一个状态桶、进另一个,同批次同库位)与转移(出一个库位、进另一个,同批次同状态)。两者形状相同 —— 一出一进、数量相反,所以物理总量按构造不动,不需要任何人记得。四种成对类型当且仅当带 pair_id,由 inventory_movements_pair 双向强制。';

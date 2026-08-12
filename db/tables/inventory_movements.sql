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
         'status_change_out','status_change_in')),
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
    stock_status     text NOT NULL DEFAULT 'available'
                     CHECK (stock_status IN ('available','on_hold')),
    -- 状态变更是【成对】的两行,这一列把它们绑在一起(只有状态变更行带它)
    status_pair_id   uuid,
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
    CONSTRAINT inventory_movements_status_pair CHECK (
        (movement_type IN ('status_change_out','status_change_in'))
        = (status_pair_id IS NOT NULL))
);
-- No deleted_at, no updated_at: immutable by design.

CREATE INDEX idx_inventory_movements_inbound  ON public.inventory_movements (inbound_batch_id);
CREATE INDEX idx_inventory_movements_output   ON public.inventory_movements (output_batch_id);
CREATE INDEX idx_inventory_movements_run      ON public.inventory_movements (run_id);
CREATE INDEX idx_inventory_movements_occurred ON public.inventory_movements (occurred_at);
CREATE INDEX idx_inventory_movements_status_pair ON public.inventory_movements (status_pair_id);
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
    'STK-1:这一行进入/离开的是哪个库存桶(available / on_hold)。状态是流水的属性,不是批次的字段 —— 一个批次同时可以有"60 可用、40 暂扣",一个字段答不了。既有 68 行回填 available:本刀之前系统里根本不存在"暂扣"概念,所以那是它一直在断言的事,不是猜测。【不要与 inbound_batches.status / output_batches.status 混淆】—— 那两列与库存无关(且无人写入),见 docs/known-issues.md。';

COMMENT ON COLUMN public.inventory_movements.status_pair_id IS
    'STK-1:状态变更是【成对】的两行(出一个桶、进另一个桶,同批次同库位、数量相反),这一列把它们绑在一起。只有 status_change_out / status_change_in 带它,其余类型必须为空 —— 由 inventory_movements_status_pair 强制。成对是【结构性】的保证:物理总量 = Σ qty_delta,一出一进相加为零,所以一次状态变更按构造改不动物理总量,不需要任何人记得。';

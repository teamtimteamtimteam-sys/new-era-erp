-- db/tables/maintenance_part_issues.sql
-- MES-7a-2(2026-10-16,MES-0 Q70 · Q89;MES-7a Step 0 Q2 · Q10–Q15 · Q20,Tim):【一件备件出给了哪一条保养记录 —— 以及退回来多少】。
--   一行 = 一次出库的一条明细(kind = issue:哪一条保养记录、哪一批备件、多少),或一次退回(kind = return:引用它退的那一行出库,带理由)。
--   ★ 只可追加(Q12):没有改、没有删(trg_maintenance_part_issues_immutable 按名拒 PART_ISSUE_IMMUTABLE);一次出错的出库靠一行退回更正。
--   ★ 只经两支函数写(issue_spare_parts / return_spare_parts,码 module.inventory.edit);会话里直连插入按名拒 PART_ISSUES_THROUGH_FUNCTION_ONLY。
--   ★ 备件是【按批收货】的(Q2):一批备件就是一张进料批,有数量、库位与成本,但没有逐件追溯 —— 这里记的是"从哪一批出的",不是"哪一件"。
--   ★ 【这张表不带钱】(Q20):价值在那一张分录上(借 6800 / 贷 1200,按那一批的落地单价 × 数量;退回反过来),journal_entry_id 指着它;
--     读得到总账的人读得到金额(AGENTS.md 常设决定 1),保养页面上只给持 data.view_prices 的人照落地单价现算。于是没有遮蔽的列。
--   ★ movement_ids:这一行写下的那几条库存流水(drain_stock 可能跨几个库位桶,于是一次出库可以是几条流水);退回恰好一条。
--     流水自己不带指针 —— 是这一行指着它们,而 trg_inventory_movements_maintenance_ctx 保证那两种流水只由这两支函数写。
--   读:module.processing.view(保养记录在加工那边)或 module.inventory.view(批次的库存那一侧)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7a2-spare-parts.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.maintenance_part_issues (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    maintenance_id   uuid NOT NULL REFERENCES public.equipment_maintenance (id),
    inbound_batch_id uuid NOT NULL REFERENCES public.inbound_batches (id),
    kind             text NOT NULL CHECK (kind IN ('issue', 'return')),
    -- 一行退回引用它退的那一行出库(同一条保养记录、同一批 —— 函数照抄那一行的两个外键)
    returns_issue_id uuid REFERENCES public.maintenance_part_issues (id),
    quantity         numeric NOT NULL CHECK (quantity > 0),
    -- 【世界侧的日期,必填、不默认】件是哪天出 / 退的;它也是那张分录的记账日(期间锁按它判)。
    business_date    date NOT NULL,
    reason           text,
    movement_ids     uuid[] NOT NULL CHECK (cardinality(movement_ids) >= 1),
    -- 一批落地单价为零的件出库没有分录(金额为 0 不过账,注销的先例)—— 于是可以为空
    journal_entry_id uuid REFERENCES public.journal_entries (id),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    -- 出库不带理由、不引用别的行;退回必须引用一行出库,并且说出理由(Q12)
    CONSTRAINT maintenance_part_issues_shape CHECK (
        (kind = 'issue' AND returns_issue_id IS NULL AND reason IS NULL)
        OR (kind = 'return' AND returns_issue_id IS NOT NULL AND reason IS NOT NULL AND btrim(reason) <> ''))
);

CREATE INDEX idx_maintenance_part_issues_maintenance ON public.maintenance_part_issues (maintenance_id);
CREATE INDEX idx_maintenance_part_issues_batch ON public.maintenance_part_issues (inbound_batch_id);
CREATE INDEX idx_maintenance_part_issues_returns ON public.maintenance_part_issues (returns_issue_id);

COMMENT ON TABLE public.maintenance_part_issues IS
    'MES-7a-2:备件出给一条保养记录(kind = issue)与它的退回(kind = return,引用那一行出库、带理由)。只可追加;只经 issue_spare_parts / return_spare_parts 写(module.inventory.edit)。不带钱:价值在 journal_entry_id 那张分录上(借 6800 / 贷 1200,退回反过来)。movement_ids 是这一行写下的库存流水(maintenance_issue / maintenance_return)。';

COMMENT ON COLUMN public.maintenance_part_issues.business_date IS
    'MES-7a-2:件是哪天出 / 退的 —— 必填,不默认(AGENTS.md「决定期间的日期必填、永不默认」);那张分录按它记账,流水的 business_date 也是它。';

ALTER TABLE public.maintenance_part_issues ENABLE ROW LEVEL SECURITY;
CREATE POLICY "maintenance_part_issues select by permission" ON public.maintenance_part_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.processing.view'::text)) OR (SELECT has_permission('module.inventory.view'::text)));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.maintenance_part_issues TO authenticated;
REVOKE ALL ON public.maintenance_part_issues FROM anon;

-- 会话里直连插入按名拒(行级 BEFORE INSERT 先于 RLS 的 WITH CHECK);属主路径(那两支函数)放行。
CREATE TRIGGER trg_maintenance_part_issues_direct
    BEFORE INSERT ON public.maintenance_part_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_part_issue_write();
-- 只可追加:改与删对谁都按名拒 —— 语句级,所以 RLS 让一句 UPDATE 碰不到任何一行时它照样抛,不是一次"成功的空操作"(ALERT-1)。
CREATE TRIGGER trg_maintenance_part_issues_immutable
    BEFORE UPDATE OR DELETE ON public.maintenance_part_issues
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_part_issue_write();
